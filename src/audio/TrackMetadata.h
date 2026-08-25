#pragma once

#include <JuceHeader.h>

#include <atomic>
#include <functional>
#include <initializer_list>
#include <memory>
#include <vector>

struct LyricsLine
{
    double timeSeconds = 0.0;
    juce::String text;
};

struct TrackMetadata
{
    juce::File file;
    juce::String title;
    juce::String artist;
    juce::String album;
    juce::String albumArtist;
    juce::String genre;
    int discNumber = 0;
    int trackNumber = 0;
    double durationSeconds = 0.0;
    juce::String lyrics;
    std::vector<LyricsLine> lyricsLines;
    std::shared_ptr<const juce::Image> artwork;

    bool hasArtwork() const
    {
        return artwork != nullptr && artwork->isValid();
    }

    bool hasLyrics() const
    {
        return lyrics.isNotEmpty();
    }
};

using TrackMetadataPtr = std::shared_ptr<const TrackMetadata>;

namespace TrackMetadataUtil
{
juce::String firstValue(const juce::StringPairArray& values,
                        std::initializer_list<const char*> keys);

TrackMetadata fallbackForFile(const juce::File& file);

juce::String sidecarLyricsForFile(const juce::File& file);

std::vector<LyricsLine> parseLyrics(const juce::String& lyrics);
}

class TrackMetadataReader final
{
public:
    using Callback = std::function<void(TrackMetadata)>;

    TrackMetadataReader();
    ~TrackMetadataReader();

    void readAsync(const juce::File& file, Callback callback);

private:
    class Job;

    juce::ThreadPool threadPool { 1 };
    std::shared_ptr<std::atomic_bool> lifetime;

    JUCE_DECLARE_NON_COPYABLE_WITH_LEAK_DETECTOR(TrackMetadataReader)
};
