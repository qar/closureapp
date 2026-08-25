#pragma once

#include <JuceHeader.h>

#include <atomic>
#include <functional>
#include <memory>
#include <optional>

namespace Lyrics
{
struct Query
{
    juce::String title;
    juce::String artist;
    juce::String album;
    double durationSeconds = 0.0;

    bool isValid() const;
    juce::String cacheKey() const;
};

struct Result
{
    bool found = false;
    juce::String plainLyrics;
    juce::String syncedLyrics;
    juce::String error;

    bool hasLyrics() const
    {
        return plainLyrics.isNotEmpty() || syncedLyrics.isNotEmpty();
    }
};
}

struct LyricsNetworkState;

class LyricsClient final
{
public:
    using Callback = std::function<void(Lyrics::Result)>;

    LyricsClient();
    ~LyricsClient();

    void fetchAsync(Lyrics::Query query, Callback callback);

private:
    class Job;

    juce::ThreadPool threadPool { 1 };
    std::shared_ptr<std::atomic_bool> lifetime;
    std::shared_ptr<LyricsNetworkState> networkState;

    JUCE_DECLARE_NON_COPYABLE_WITH_LEAK_DETECTOR(LyricsClient)
};
