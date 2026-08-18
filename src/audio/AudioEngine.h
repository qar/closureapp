#pragma once

#include <JuceHeader.h>
#include "audio/GaplessPlaylistSource.h"
#include <functional>

/** Owns device, playlist and transport. The UI never touches audio sources. */
class AudioEngine : private juce::ChangeListener
{
public:
    struct State
    {
        bool hasFile = false;
        bool isPlaying = false;
        double positionSeconds = 0.0;
        double lengthSeconds = 0.0;
        juce::String fileName;
        juce::String filePath;
        int currentTrackIndex = -1;
        bool loopPlaylist = true;
        juce::StringArray playlistNames;
    };

    using StateCallback = std::function<void(const State&)>;

    AudioEngine();
    ~AudioEngine() override;

    int addFiles(const juce::Array<juce::File>& files, bool startPlaybackIfEmpty = true);
    bool removeTrack(int index);
    void clearPlaylist();
    void playTrack(int index);
    void setLoopPlaylist(bool shouldLoop);
    void play();
    void pause();
    void stop();
    void togglePlayPause();
    void setPosition(double seconds);
    void setGain(float gain01);

    State getState() const;
    void setStateCallback(StateCallback cb);

private:
    void changeListenerCallback(juce::ChangeBroadcaster*) override;
    void notifyState();
    void startPositionTimer();
    void stopPositionTimer();

    juce::AudioDeviceManager deviceManager;
    juce::AudioFormatManager formatManager;
    juce::TimeSliceThread readAheadThread;
    GaplessPlaylistSource playlistSource;
    juce::AudioTransportSource transportSource;
    juce::AudioSourcePlayer sourcePlayer;

    StateCallback stateCallback;

    class PositionTimer;
    std::unique_ptr<PositionTimer> positionTimer;

    JUCE_DECLARE_NON_COPYABLE_WITH_LEAK_DETECTOR(AudioEngine)
};
