#pragma once

#include <JuceHeader.h>

#include <atomic>
#include <functional>
#include <memory>
#include <optional>
#include <vector>

namespace MusicBrainz
{
juce::String formatArtistCredit(const juce::var& value);

struct ReleaseCandidate
{
    juce::String id;
    juce::String title;
    juce::String artist;
    juce::String date;
    juce::String country;
    juce::String status;
    juce::String disambiguation;
    int score = 0;
    int trackCount = 0;
};

struct Track
{
    juce::String recordingId;
    juce::String title;
    juce::String artist;
    juce::String genre;
    int discNumber = 0;
    int trackNumber = 0;
    double durationSeconds = 0.0;
};

struct ReleaseMetadata
{
    ReleaseCandidate release;
    juce::String releaseGroupId;
    juce::String genre;
    std::vector<Track> tracks;
    std::shared_ptr<const juce::Image> artwork;
};
}

struct MusicBrainzNetworkState;

class MusicBrainzClient final
{
public:
    using SearchCallback = std::function<void(std::vector<MusicBrainz::ReleaseCandidate>,
                                               juce::String)>;
    using FetchCallback = std::function<void(std::optional<MusicBrainz::ReleaseMetadata>,
                                              juce::String)>;

    MusicBrainzClient();
    ~MusicBrainzClient();

    void searchReleases(const juce::String& albumTitle,
                        const juce::String& artist,
                        SearchCallback callback);
    void fetchRelease(const juce::String& releaseId, FetchCallback callback);

private:
    class Job;

    juce::ThreadPool threadPool { 1 };
    std::shared_ptr<std::atomic_bool> lifetime;
    std::shared_ptr<MusicBrainzNetworkState> networkState;

    JUCE_DECLARE_NON_COPYABLE_WITH_LEAK_DETECTOR(MusicBrainzClient)
};
