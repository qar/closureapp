#include "AudioEngine.h"

class AudioEngine::PositionTimer final : public juce::Timer
{
public:
    explicit PositionTimer(AudioEngine& ownerIn) : owner(ownerIn) {}

    void timerCallback() override
    {
        owner.notifyState();
    }

private:
    AudioEngine& owner;
};

AudioEngine::AudioEngine()
{
    formatManager.registerBasicFormats();

    auto result = deviceManager.initialiseWithDefaultDevices(0, 2);
    jassert(result.isEmpty());

    // Prefer lower latency when the device allows it.
    if (auto* device = deviceManager.getCurrentAudioDevice())
    {
        auto setup = deviceManager.getAudioDeviceSetup();
        setup.bufferSize = juce::jmin(setup.bufferSize, 256);
        deviceManager.setAudioDeviceSetup(setup, true);
    }

    sourcePlayer.setSource(&transportSource);
    deviceManager.addAudioCallback(&sourcePlayer);
    transportSource.addChangeListener(this);

    positionTimer = std::make_unique<PositionTimer>(*this);
}

AudioEngine::~AudioEngine()
{
    stopPositionTimer();
    transportSource.setSource(nullptr);
    transportSource.removeChangeListener(this);
    deviceManager.removeAudioCallback(&sourcePlayer);
    sourcePlayer.setSource(nullptr);
}

bool AudioEngine::openFile(const juce::File& file)
{
    if (!file.existsAsFile())
        return false;

    auto* reader = formatManager.createReaderFor(file);
    if (reader == nullptr)
        return false;

    auto newSource = std::make_unique<juce::AudioFormatReaderSource>(reader, true);
    transportSource.setSource(newSource.get(), 0, nullptr, reader->sampleRate);
    readerSource = std::move(newSource);

    currentFileName = file.getFileName();
    currentFilePath = file.getFullPathName();

    notifyState();
    return true;
}

void AudioEngine::play()
{
    if (readerSource == nullptr)
        return;

    transportSource.start();
    startPositionTimer();
    notifyState();
}

void AudioEngine::pause()
{
    transportSource.stop();
    stopPositionTimer();
    notifyState();
}

void AudioEngine::stop()
{
    transportSource.stop();
    transportSource.setPosition(0.0);
    stopPositionTimer();
    notifyState();
}

void AudioEngine::togglePlayPause()
{
    if (transportSource.isPlaying())
        pause();
    else
        play();
}

void AudioEngine::setPosition(double seconds)
{
    transportSource.setPosition(juce::jlimit(0.0, transportSource.getLengthInSeconds(), seconds));
    notifyState();
}

void AudioEngine::setGain(float gain01)
{
    transportSource.setGain(juce::jlimit(0.0f, 1.0f, gain01));
}

AudioEngine::State AudioEngine::getState() const
{
    State s;
    s.hasFile = readerSource != nullptr;
    s.isPlaying = transportSource.isPlaying();
    s.positionSeconds = transportSource.getCurrentPosition();
    s.lengthSeconds = transportSource.getLengthInSeconds();
    s.fileName = currentFileName;
    s.filePath = currentFilePath;
    return s;
}

void AudioEngine::setStateCallback(StateCallback cb)
{
    stateCallback = std::move(cb);
}

void AudioEngine::changeListenerCallback(juce::ChangeBroadcaster*)
{
    if (transportSource.isPlaying())
        startPositionTimer();
    else
        stopPositionTimer();

    notifyState();
}

void AudioEngine::notifyState()
{
    if (stateCallback)
        stateCallback(getState());
}

void AudioEngine::startPositionTimer()
{
    if (positionTimer != nullptr && !positionTimer->isTimerRunning())
        positionTimer->startTimerHz(20);
}

void AudioEngine::stopPositionTimer()
{
    if (positionTimer != nullptr)
        positionTimer->stopTimer();
}
