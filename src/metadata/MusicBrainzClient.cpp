#include "MusicBrainzClient.h"

#include <algorithm>

struct MusicBrainzNetworkState
{
    juce::CriticalSection lock;
    int64_t lastMusicBrainzRequestMs = 0;
    juce::WebInputStream* activeStream = nullptr;
    bool cancelled = false;

    void cancelActiveStream()
    {
        const juce::ScopedLock sl(lock);
        cancelled = true;
        if (activeStream != nullptr)
            activeStream->cancel();
    }
};

namespace
{
constexpr auto musicBrainzEndpoint = "https://musicbrainz.org/ws/2/";
constexpr auto coverArtEndpoint = "https://coverartarchive.org/release/";
constexpr auto userAgent = "Closure/0.2.2 (https://github.com/qiaoanran/closureapp)";

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

int intProperty(const juce::var& value, const char* name)
{
    return stringProperty(value, name).getIntValue();
}

juce::String firstGenre(const juce::var& value)
{
    const auto genres = property(value, "genres");
    const auto* genreArray = genres.getArray();
    if (genreArray == nullptr)
        return {};

    for (const auto& genre : *genreArray)
    {
        const auto name = stringProperty(genre, "name");
        if (name.isNotEmpty())
            return name;
    }

    return {};
}

MusicBrainz::ReleaseCandidate parseCandidate(const juce::var& value)
{
    MusicBrainz::ReleaseCandidate candidate;
    candidate.id = stringProperty(value, "id");
    candidate.title = stringProperty(value, "title");
    candidate.artist = MusicBrainz::formatArtistCredit(value);
    candidate.date = stringProperty(value, "date");
    candidate.country = stringProperty(value, "country");
    candidate.status = stringProperty(value, "status");
    candidate.disambiguation = stringProperty(value, "disambiguation");
    candidate.score = intProperty(value, "score");
    candidate.trackCount = intProperty(value, "track-count");

    if (candidate.trackCount == 0)
    {
        const auto media = property(value, "media");
        if (const auto* mediaArray = media.getArray())
        {
            for (const auto& medium : *mediaArray)
                candidate.trackCount += intProperty(medium, "track-count");
        }
    }

    return candidate;
}

}

juce::String MusicBrainz::formatArtistCredit(const juce::var& value)
{
    juce::String result;
    const auto credits = property(value, "artist-credit");
    const auto* creditArray = credits.getArray();
    if (creditArray == nullptr)
        return result;

    for (const auto& credit : *creditArray)
    {
        auto name = stringProperty(credit, "name");
        if (name.isEmpty())
        {
            const auto artist = property(credit, "artist");
            name = stringProperty(artist, "name");
        }

        // joinphrase is presentation data; preserve its intentional whitespace.
        result << name << property(credit, "joinphrase").toString();
    }

    return result.trim();
}

namespace
{
juce::String searchValue(juce::String value)
{
    return value.trim().replace("\"", "\\\"");
}

bool waitForMusicBrainzRequestSlot(MusicBrainzNetworkState& state)
{
    const juce::ScopedLock sl(state.lock);
    if (state.cancelled)
        return false;

    const auto now = juce::Time::getCurrentTime().toMilliseconds();
    const auto elapsed = now - state.lastMusicBrainzRequestMs;
    if (state.lastMusicBrainzRequestMs > 0 && elapsed < 1000)
        juce::Thread::sleep(static_cast<int>(1000 - elapsed));

    if (state.cancelled)
        return false;

    state.lastMusicBrainzRequestMs = juce::Time::getCurrentTime().toMilliseconds();
    return true;
}
}

namespace
{
std::optional<juce::var> requestJson(const juce::URL& url,
                                     MusicBrainzNetworkState& networkState,
                                     juce::String& error);
std::optional<MusicBrainz::ReleaseMetadata> readRelease(const juce::var& value,
                                                         juce::String& error);
std::shared_ptr<const juce::Image> downloadArtwork(const juce::String& releaseId,
                                                   MusicBrainzNetworkState& networkState);
}

class ActiveStreamRegistration final
{
public:
    ActiveStreamRegistration(MusicBrainzNetworkState& stateIn,
                             juce::WebInputStream& streamIn)
        : state(stateIn),
          stream(streamIn)
    {
        const juce::ScopedLock sl(state.lock);
        if (!state.cancelled)
        {
            state.activeStream = &stream;
            registered = true;
        }
    }

    ~ActiveStreamRegistration()
    {
        const juce::ScopedLock sl(state.lock);
        if (registered && state.activeStream == &stream)
            state.activeStream = nullptr;
    }

    bool isRegistered() const noexcept { return registered; }

private:
    MusicBrainzNetworkState& state;
    juce::WebInputStream& stream;
    bool registered = false;
};

class MusicBrainzClient::Job final : public juce::ThreadPoolJob
{
public:
    Job(std::function<void()> workIn,
        std::shared_ptr<std::atomic_bool> lifetimeIn)
        : ThreadPoolJob("MusicBrainz request"),
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

MusicBrainzClient::MusicBrainzClient()
    : lifetime(std::make_shared<std::atomic_bool>(true)),
      networkState(std::make_shared<MusicBrainzNetworkState>())
{
}

MusicBrainzClient::~MusicBrainzClient()
{
    lifetime->store(false);
    networkState->cancelActiveStream();
    threadPool.removeAllJobs(true, 10000);
}

void MusicBrainzClient::searchReleases(const juce::String& albumTitle,
                                       const juce::String& artist,
                                       SearchCallback callback)
{
    if (!callback)
        return;

    const auto cleanTitle = albumTitle.trim();
    const auto cleanArtist = artist.trim();
    const auto lifetimeCopy = lifetime;

    if (cleanTitle.isEmpty())
    {
        juce::MessageManager::callAsync(
            [lifetimeCopy, callbackForMessage = std::move(callback)]() mutable
        {
            if (lifetimeCopy->load() && callbackForMessage)
                callbackForMessage({}, "The album title is empty.");
        });
        return;
    }

    const auto networkStateCopy = networkState;
    threadPool.addJob(new Job(
        [networkStateCopy,
         cleanTitle,
         cleanArtist,
         callbackForWork = std::move(callback),
         lifetimeCopy]() mutable
        {
            const auto query = cleanArtist.isEmpty()
                             ? "release:\"" + searchValue(cleanTitle) + "\""
                             : "release:\"" + searchValue(cleanTitle) + "\" AND artist:\""
                                   + searchValue(cleanArtist) + "\"";
            const auto url = juce::URL(juce::String(musicBrainzEndpoint) + "release/")
                                 .withParameter("query", query)
                                 .withParameter("fmt", "json")
                                 .withParameter("limit", "8");

            juce::String requestError;
            std::vector<MusicBrainz::ReleaseCandidate> candidateResults;
            if (const auto response = requestJson(url, *networkStateCopy, requestError);
                response.has_value())
            {
                const auto releases = property(*response, "releases");
                if (const auto* releaseArray = releases.getArray())
                {
                    for (const auto& release : *releaseArray)
                    {
                        auto candidate = parseCandidate(release);
                        if (candidate.id.isNotEmpty() && candidate.title.isNotEmpty())
                            candidateResults.push_back(std::move(candidate));
                    }
                }
            }

            juce::MessageManager::callAsync(
                [lifetimeCopy,
                 callbackForMessage = std::move(callbackForWork),
                 resultsForMessage = std::move(candidateResults),
                 errorForMessage = std::move(requestError)]() mutable
                {
                    if (lifetimeCopy->load() && callbackForMessage)
                        callbackForMessage(std::move(resultsForMessage),
                                           std::move(errorForMessage));
                });
        },
        lifetime),
        true);
}

void MusicBrainzClient::fetchRelease(const juce::String& releaseId, FetchCallback callback)
{
    if (!callback)
        return;

    const auto cleanReleaseId = releaseId.trim();
    const auto lifetimeCopy = lifetime;

    if (cleanReleaseId.isEmpty())
    {
        juce::MessageManager::callAsync(
            [lifetimeCopy, callbackForMessage = std::move(callback)]() mutable
        {
            if (lifetimeCopy->load() && callbackForMessage)
                callbackForMessage(std::nullopt, "The MusicBrainz release ID is empty.");
        });
        return;
    }

    const auto networkStateCopy = networkState;
    threadPool.addJob(new Job(
        [networkStateCopy,
         cleanReleaseId,
         callbackForWork = std::move(callback),
         lifetimeCopy]() mutable
        {
            const auto url = juce::URL(juce::String(musicBrainzEndpoint) + "release/"
                                       + cleanReleaseId)
                                 .withParameter("inc", "recordings+artist-credits+release-groups+media+genres")
                                 .withParameter("fmt", "json");

            juce::String requestError;
            std::optional<MusicBrainz::ReleaseMetadata> releaseMetadata;
            if (const auto response = requestJson(url, *networkStateCopy, requestError);
                response.has_value())
            {
                releaseMetadata = readRelease(*response, requestError);
            }

            if (releaseMetadata.has_value() && lifetimeCopy->load())
                releaseMetadata->artwork = downloadArtwork(cleanReleaseId, *networkStateCopy);

            juce::MessageManager::callAsync(
                [lifetimeCopy,
                 callbackForMessage = std::move(callbackForWork),
                 releaseForMessage = std::move(releaseMetadata),
                 errorForMessage = std::move(requestError)]() mutable
                {
                    if (lifetimeCopy->load() && callbackForMessage)
                        callbackForMessage(std::move(releaseForMessage),
                                           std::move(errorForMessage));
                });
        },
        lifetime),
        true);
}

namespace
{
std::optional<juce::var> requestJson(const juce::URL& url,
                                    MusicBrainzNetworkState& networkState,
                                    juce::String& error)
{
    if (!waitForMusicBrainzRequestSlot(networkState))
    {
        error = "MusicBrainz request was cancelled.";
        return std::nullopt;
    }

    auto stream = std::make_unique<juce::WebInputStream>(url, false);
    stream->withExtraHeaders("User-Agent: " + juce::String(userAgent)
                             + "\nAccept: application/json")
          .withConnectionTimeout(12000)
          .withNumRedirectsToFollow(4);
    ActiveStreamRegistration activeStream(networkState, *stream);
    if (!activeStream.isRegistered())
    {
        error = "MusicBrainz request was cancelled.";
        return std::nullopt;
    }

    if (!stream->connect(nullptr))
    {
        error = "MusicBrainz could not be reached.";
        return std::nullopt;
    }

    const auto statusCode = stream->getStatusCode();
    if (statusCode < 200 || statusCode >= 300)
    {
        error = "MusicBrainz returned HTTP " + juce::String(statusCode) + ".";
        return std::nullopt;
    }

    const auto body = stream->readEntireStreamAsString();
    const auto parsed = juce::JSON::parse(body);
    if (parsed.isVoid())
    {
        error = "MusicBrainz returned invalid JSON.";
        return std::nullopt;
    }

    return parsed;
}

std::optional<MusicBrainz::ReleaseMetadata> readRelease(
    const juce::var& value,
    juce::String& error)
{
    MusicBrainz::ReleaseMetadata metadata;
    metadata.release = parseCandidate(value);
    if (metadata.release.id.isEmpty())
    {
        error = "MusicBrainz returned an invalid release.";
        return std::nullopt;
    }

    const auto releaseGroup = property(value, "release-group");
    metadata.releaseGroupId = stringProperty(releaseGroup, "id");
    metadata.genre = firstGenre(releaseGroup);
    if (metadata.genre.isEmpty())
        metadata.genre = firstGenre(value);

    const auto media = property(value, "media");
    if (const auto* mediaArray = media.getArray())
    {
        int fallbackDiscNumber = 1;
        for (const auto& medium : *mediaArray)
        {
            auto discNumber = intProperty(medium, "position");
            if (discNumber <= 0)
                discNumber = fallbackDiscNumber;
            ++fallbackDiscNumber;

            const auto tracks = property(medium, "tracks");
            if (const auto* trackArray = tracks.getArray())
            {
                for (const auto& valueTrack : *trackArray)
                {
                    MusicBrainz::Track track;
                    track.title = stringProperty(valueTrack, "title");
                    track.trackNumber = stringProperty(valueTrack, "number")
                                             .upToFirstOccurrenceOf("/", false, false)
                                             .getIntValue();
                    track.discNumber = discNumber;
                    track.artist = MusicBrainz::formatArtistCredit(valueTrack);

                    const auto recording = property(valueTrack, "recording");
                    track.recordingId = stringProperty(recording, "id");
                    if (track.artist.isEmpty())
                        track.artist = MusicBrainz::formatArtistCredit(recording);
                    track.genre = firstGenre(recording);
                    if (track.genre.isEmpty())
                        track.genre = metadata.genre;

                    auto lengthMs = intProperty(valueTrack, "length");
                    if (lengthMs <= 0)
                        lengthMs = intProperty(recording, "length");
                    if (lengthMs > 0)
                        track.durationSeconds = static_cast<double>(lengthMs) / 1000.0;

                    if (track.title.isNotEmpty())
                        metadata.tracks.push_back(std::move(track));
                }
            }
        }
    }

    return metadata;
}

std::shared_ptr<const juce::Image> downloadArtwork(
    const juce::String& releaseId,
    MusicBrainzNetworkState& networkState)
{
    const auto url = juce::URL(juce::String(coverArtEndpoint) + releaseId + "/front-500.jpg");
    auto stream = std::make_unique<juce::WebInputStream>(url, false);
    stream->withExtraHeaders("User-Agent: " + juce::String(userAgent))
          .withConnectionTimeout(12000)
          .withNumRedirectsToFollow(5);
    ActiveStreamRegistration activeStream(networkState, *stream);
    if (!activeStream.isRegistered())
        return nullptr;

    if (!stream->connect(nullptr))
        return nullptr;

    const auto statusCode = stream->getStatusCode();
    if (statusCode < 200 || statusCode >= 300)
        return nullptr;

    juce::MemoryBlock data;
    if (stream->readIntoMemoryBlock(data, 16 * 1024 * 1024) == 0)
        return nullptr;

    const auto image = juce::ImageFileFormat::loadFrom(data.getData(), data.getSize());
    return image.isValid() ? std::make_shared<const juce::Image>(image) : nullptr;
}
}
