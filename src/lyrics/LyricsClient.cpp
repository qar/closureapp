#include "LyricsClient.h"

#include <cmath>

struct LyricsNetworkState
{
    juce::File cacheDirectory;
    juce::CriticalSection lock;
    int64_t lastRequestMs = 0;
    juce::WebInputStream* activeStream = nullptr;

    void cancelActiveStream()
    {
        const juce::ScopedLock sl(lock);
        if (activeStream != nullptr)
            activeStream->cancel();
    }
};

namespace
{
constexpr auto lyricsEndpoint = "https://lrclib.net/api/get";
constexpr auto userAgent = "Closure/0.2.3 (https://github.com/qar/closureapp)";

juce::var property(const juce::var& value, const char* name)
{
    if (auto* object = value.getDynamicObject())
        return object->getProperty(juce::Identifier(name));

    return {};
}

juce::String stringProperty(const juce::var& value, const char* name)
{
    return property(value, name).toString().trim();
}

std::optional<Lyrics::Result> readCache(const LyricsNetworkState& state,
                                        const Lyrics::Query& query)
{
    const auto cacheFile = state.cacheDirectory.getChildFile(query.cacheKey() + ".xml");
    if (!cacheFile.existsAsFile())
        return std::nullopt;

    const auto document = juce::XmlDocument::parse(cacheFile);
    if (document == nullptr || !document->hasTagName("lyrics"))
        return std::nullopt;

    Lyrics::Result result;
    result.found = document->getBoolAttribute("found", false);
    if (const auto* plain = document->getChildByName("plain"))
        result.plainLyrics = plain->getAllSubText();
    if (const auto* synced = document->getChildByName("synced"))
        result.syncedLyrics = synced->getAllSubText();
    return result;
}

void writeCache(const LyricsNetworkState& state,
                const Lyrics::Query& query,
                const Lyrics::Result& result)
{
    if (!state.cacheDirectory.createDirectory() && !state.cacheDirectory.isDirectory())
        return;

    auto document = std::make_unique<juce::XmlElement>("lyrics");
    document->setAttribute("found", result.hasLyrics());
    if (result.plainLyrics.isNotEmpty())
        document->createNewChildElement("plain")->addTextElement(result.plainLyrics);
    if (result.syncedLyrics.isNotEmpty())
        document->createNewChildElement("synced")->addTextElement(result.syncedLyrics);

    const auto cacheFile = state.cacheDirectory.getChildFile(query.cacheKey() + ".xml");
    const auto temporaryFile = cacheFile.getSiblingFile(cacheFile.getFileName() + ".tmp");
    if (!temporaryFile.replaceWithText(document->toString(), false, false, "\n"))
        return;

    if (cacheFile.existsAsFile())
        temporaryFile.replaceFileIn(cacheFile);
    else
        temporaryFile.moveFileTo(cacheFile);
}

void waitForRequestSlot(LyricsNetworkState& state)
{
    const juce::ScopedLock sl(state.lock);
    const auto now = juce::Time::getCurrentTime().toMilliseconds();
    const auto elapsed = now - state.lastRequestMs;
    if (state.lastRequestMs > 0 && elapsed < 500)
        juce::Thread::sleep(static_cast<int>(500 - elapsed));

    state.lastRequestMs = juce::Time::getCurrentTime().toMilliseconds();
}

class ActiveStreamRegistration final
{
public:
    ActiveStreamRegistration(LyricsNetworkState& stateIn,
                             juce::WebInputStream& streamIn)
        : state(stateIn),
          stream(streamIn)
    {
        const juce::ScopedLock sl(state.lock);
        state.activeStream = &stream;
    }

    ~ActiveStreamRegistration()
    {
        const juce::ScopedLock sl(state.lock);
        if (state.activeStream == &stream)
            state.activeStream = nullptr;
    }

private:
    LyricsNetworkState& state;
    juce::WebInputStream& stream;
};

Lyrics::Result fetchLyrics(LyricsNetworkState& state, const Lyrics::Query& query)
{
    if (const auto cached = readCache(state, query); cached.has_value())
        return *cached;

    waitForRequestSlot(state);

    auto url = juce::URL(lyricsEndpoint)
                   .withParameter("artist_name", query.artist.trim())
                   .withParameter("track_name", query.title.trim());
    if (query.album.trim().isNotEmpty() && query.album.trim() != "Local Files")
        url = url.withParameter("album_name", query.album.trim());
    if (query.durationSeconds > 0.0 && std::isfinite(query.durationSeconds))
    {
        url = url.withParameter("duration",
                                juce::String(static_cast<int>(std::round(query.durationSeconds))));
    }

    auto stream = std::make_unique<juce::WebInputStream>(url, false);
    stream->withExtraHeaders("User-Agent: " + juce::String(userAgent)
                             + "\nAccept: application/json")
          .withConnectionTimeout(8000)
          .withNumRedirectsToFollow(3);
    ActiveStreamRegistration activeStream(state, *stream);

    Lyrics::Result result;
    if (!stream->connect(nullptr))
    {
        result.error = "Lyrics service could not be reached.";
        return result;
    }

    const auto statusCode = stream->getStatusCode();
    if (statusCode == 404)
    {
        writeCache(state, query, result);
        return result;
    }

    if (statusCode < 200 || statusCode >= 300)
    {
        result.error = "Lyrics service returned HTTP " + juce::String(statusCode) + ".";
        return result;
    }

    const auto parsed = juce::JSON::parse(stream->readEntireStreamAsString());
    if (parsed.isVoid())
    {
        result.error = "Lyrics service returned invalid JSON.";
        return result;
    }

    result.plainLyrics = stringProperty(parsed, "plainLyrics");
    result.syncedLyrics = stringProperty(parsed, "syncedLyrics");
    result.found = result.hasLyrics();
    writeCache(state, query, result);
    return result;
}
}

class LyricsClient::Job final : public juce::ThreadPoolJob
{
public:
    Job(std::function<void()> workIn,
        std::shared_ptr<std::atomic_bool> lifetimeIn)
        : ThreadPoolJob("Lyrics request"),
          work(std::move(workIn)),
          lifetime(std::move(lifetimeIn))
    {
    }

    JobStatus runJob() override
    {
        if (lifetime->load() && work)
            work();

        return jobHasFinished;
    }

private:
    std::function<void()> work;
    std::shared_ptr<std::atomic_bool> lifetime;
};

bool Lyrics::Query::isValid() const
{
    return title.trim().isNotEmpty()
        && artist.trim().isNotEmpty()
        && artist.trim() != "Unknown Artist";
}

juce::String Lyrics::Query::cacheKey() const
{
    const auto canonical = artist.trim().toLowerCase() + "\n"
                         + title.trim().toLowerCase() + "\n"
                         + album.trim().toLowerCase() + "\n"
                         + juce::String(static_cast<int>(std::round(durationSeconds)));
    return juce::String::toHexString(canonical.hashCode64());
}

LyricsClient::LyricsClient()
    : lifetime(std::make_shared<std::atomic_bool>(true)),
      networkState(std::make_shared<LyricsNetworkState>())
{
    networkState->cacheDirectory = juce::File::getSpecialLocation(
        juce::File::userApplicationDataDirectory)
                                       .getChildFile("Closure")
                                       .getChildFile("Lyrics");
}

LyricsClient::~LyricsClient()
{
    lifetime->store(false);
    networkState->cancelActiveStream();
    threadPool.removeAllJobs(true, 10000);
}

void LyricsClient::fetchAsync(Lyrics::Query query, Callback callback)
{
    if (!callback)
        return;

    const auto lifetimeCopy = lifetime;
    const auto networkStateCopy = networkState;
    if (!query.isValid())
    {
        juce::MessageManager::callAsync(
            [lifetimeCopy, callbackForMessage = std::move(callback)]() mutable
            {
                if (lifetimeCopy->load() && callbackForMessage)
                {
                    Lyrics::Result result;
                    result.error = "Not enough metadata to search for lyrics.";
                    callbackForMessage(std::move(result));
                }
            });
        return;
    }

    networkState->cancelActiveStream();
    threadPool.addJob(new Job(
        [queryForWork = std::move(query),
         callbackForWork = std::move(callback),
         lifetimeCopy,
         networkStateCopy]() mutable
        {
            auto fetchResult = fetchLyrics(*networkStateCopy, queryForWork);
            juce::MessageManager::callAsync(
                [lifetimeCopy,
                 callbackForMessage = std::move(callbackForWork),
                 resultForMessage = std::move(fetchResult)]() mutable
                {
                    if (lifetimeCopy->load() && callbackForMessage)
                        callbackForMessage(std::move(resultForMessage));
                });
        },
        lifetime),
        true);
}
