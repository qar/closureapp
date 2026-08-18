#pragma once

#include <JuceHeader.h>

#include <memory>
#include <vector>

/**
    Concatenates prepared audio files on the audio thread.

    Each track is read ahead on a TimeSliceThread before it is needed. When a
    block crosses a track boundary, the next source is rendered directly into
    the remainder of that same block instead of waiting for the message thread.
*/
class GaplessPlaylistSource final : public juce::PositionableAudioSource
{
public:
    struct State
    {
        int currentTrackIndex = -1;
        int trackCount = 0;
        int64 currentPositionSamples = 0;
        int64 currentLengthSamples = 0;
        int64 totalPositionSamples = 0;
        int64 totalLengthSamples = 0;
        double sampleRate = 44100.0;
        bool isLooping = true;
        bool isAtEnd = false;
        juce::String currentFileName;
        juce::String currentFilePath;
        juce::StringArray trackNames;
    };

    GaplessPlaylistSource(juce::AudioFormatManager& formatManager,
                          juce::TimeSliceThread& readAheadThread);
    ~GaplessPlaylistSource() override;

    int addFiles(const juce::Array<juce::File>& files);
    bool removeTrack(int index);
    void clear();

    bool selectTrack(int index);
    void resetCurrentTrack();
    void setCurrentTrackPosition(int64 positionSamples);
    void setLooping(bool shouldLoop) override;

    State getState() const;

    void prepareToPlay(int samplesPerBlockExpected, double sampleRate) override;
    void releaseResources() override;
    void getNextAudioBlock(const juce::AudioSourceChannelInfo& info) override;

    void setNextReadPosition(int64 newPosition) override;
    int64 getNextReadPosition() const override;
    int64 getTotalLength() const override;
    bool isLooping() const override;

private:
    class TrackSource;

    std::unique_ptr<TrackSource> createTrackSource(const juce::File& file) const;
    bool advanceToNextTrack();
    void selectTrackLocked(int index);
    void resetTrackLocked(int index);
    void updateGlobalPositionLocked();
    int64 getTotalLengthLocked() const;
    int64 trackStartPositionLocked(int index) const;
    int findTrackForPositionLocked(int64 position, int64& positionInTrack) const;

    juce::AudioFormatManager& formatManager;
    juce::TimeSliceThread& readAheadThread;
    juce::CriticalSection stateLock;
    std::vector<std::unique_ptr<TrackSource>> tracks;

    int currentTrackIndex = -1;
    int64 currentPositionSamples = 0;
    int64 totalPositionSamples = 0;
    double outputSampleRate = 44100.0;
    int expectedBlockSize = 512;
    bool prepared = false;
    bool loopPlaylist = true;

    JUCE_DECLARE_NON_COPYABLE_WITH_LEAK_DETECTOR(GaplessPlaylistSource)
};
