#pragma once

#include <JuceHeader.h>
#include "audio/GaplessPlaylistSource.h"
#include "audio/TrackMetadata.h"

#include <functional>
#include <map>
#include <string>
#include <vector>

/** Owns device, playlist and transport. The UI never touches audio sources. */
class AudioEngine : private juce::ChangeListener
{
public:
    using RepeatMode = GaplessPlaylistSource::RepeatMode;

    struct State
    {
        bool hasFile = false;
        bool isPlaying = false;
        double positionSeconds = 0.0;
        double lengthSeconds = 0.0;
        juce::String fileName;
        juce::String filePath;
        int currentTrackIndex = -1;
        RepeatMode repeatMode = RepeatMode::playlist;
        bool gaplessPlayback = true;
        juce::StringArray playlistNames;
        juce::StringArray playlistPaths;
        std::vector<TrackMetadataPtr> playlistMetadata;
    };

    using StateCallback = std::function<void(const State&)>;

    AudioEngine();
    ~AudioEngine() override;

    int addFiles(const juce::Array<juce::File>& files, bool startPlaybackIfEmpty = true);
    bool removeTrack(int index);
    void clearPlaylist();
    void playTrack(int index);
    void setRepeatMode(RepeatMode mode);
    void setGaplessPlayback(bool shouldBeGapless);
    void play();
    void pause();
    void stop();
    void togglePlayPause();
    void playPrevious();
    void playNext();
    void setPosition(double seconds);
    void setGain(float gain01);

    State getState() const;
    void setStateCallback(StateCallback cb);

private:
    void changeListenerCallback(juce::ChangeBroadcaster*) override;
    void notifyState();
    void startPositionTimer();
    void stopPositionTimer();
    void configureProperties();
    void restorePlaylist();
    void savePlaylist();
    void scheduleMetadataRead(const juce::File& file);
    void metadataReady(TrackMetadata metadata);

    juce::AudioDeviceManager deviceManager;
    juce::AudioFormatManager formatManager;
    juce::TimeSliceThread readAheadThread;
    GaplessPlaylistSource playlistSource;
    juce::AudioTransportSource transportSource;
    juce::AudioSourcePlayer sourcePlayer;
    juce::ApplicationProperties applicationProperties;

    StateCallback stateCallback;

    class PositionTimer;
    std::unique_ptr<PositionTimer> positionTimer;
    TrackMetadataReader metadataReader;
    mutable juce::CriticalSection metadataLock;
    std::map<std::string, TrackMetadataPtr> metadataByPath;

    JUCE_DECLARE_NON_COPYABLE_WITH_LEAK_DETECTOR(AudioEngine)
};
