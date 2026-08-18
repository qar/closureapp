#pragma once

#include <JuceHeader.h>
#include <functional>

/** Owns device + transport. Deep module: open a file, play/pause/seek, query state. */
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
    };

    using StateCallback = std::function<void(const State&)>;

    AudioEngine();
    ~AudioEngine() override;

    bool openFile(const juce::File& file);
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
    std::unique_ptr<juce::AudioFormatReaderSource> readerSource;
    juce::AudioTransportSource transportSource;
    juce::AudioSourcePlayer sourcePlayer;

    juce::String currentFileName;
    juce::String currentFilePath;
    StateCallback stateCallback;

    class PositionTimer;
    std::unique_ptr<PositionTimer> positionTimer;

    JUCE_DECLARE_NON_COPYABLE_WITH_LEAK_DETECTOR(AudioEngine)
};
