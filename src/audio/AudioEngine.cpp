#include "AudioEngine.h"

#include <cmath>

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
    : readAheadThread("Closure Audio Read Ahead"),
      playlistSource(formatManager, readAheadThread)
{
    formatManager.registerBasicFormats();
    jassert(readAheadThread.startThread());

    auto result = deviceManager.initialiseWithDefaultDevices(0, 2);
    jassert(result.isEmpty());

    // Prefer lower latency when the device allows it.
    if (deviceManager.getCurrentAudioDevice() != nullptr)
    {
        auto setup = deviceManager.getAudioDeviceSetup();
        setup.bufferSize = juce::jmin(setup.bufferSize, 256);
        deviceManager.setAudioDeviceSetup(setup, true);
    }

    transportSource.setSource(&playlistSource);
    sourcePlayer.setSource(&transportSource);
    deviceManager.addAudioCallback(&sourcePlayer);
    transportSource.addChangeListener(this);

    positionTimer = std::make_unique<PositionTimer>(*this);
}

AudioEngine::~AudioEngine()
{
    stopPositionTimer();
    transportSource.stop();
    transportSource.setSource(nullptr);
    transportSource.removeChangeListener(this);
    deviceManager.removeAudioCallback(&sourcePlayer);
    sourcePlayer.setSource(nullptr);
    readAheadThread.stopThread(2000);
}

int AudioEngine::addFiles(const juce::Array<juce::File>& files, bool startPlaybackIfEmpty)
{
    const auto wasEmpty = playlistSource.getState().trackCount == 0;
    const auto added = playlistSource.addFiles(files);
    if (added <= 0)
        return 0;

    notifyState();

    if (wasEmpty && startPlaybackIfEmpty)
        play();

    return added;
}

bool AudioEngine::removeTrack(int index)
{
    const auto stateBefore = playlistSource.getState();
    const auto removed = playlistSource.removeTrack(index);
    if (!removed)
        return false;

    if (stateBefore.trackCount == 1)
        transportSource.stop();

    notifyState();
    return true;
}

void AudioEngine::clearPlaylist()
{
    transportSource.stop();
    playlistSource.clear();
    stopPositionTimer();
    notifyState();
}

void AudioEngine::playTrack(int index)
{
    if (!playlistSource.selectTrack(index))
        return;

    transportSource.start();
    startPositionTimer();
    notifyState();
}

void AudioEngine::setLoopPlaylist(bool shouldLoop)
{
    playlistSource.setLooping(shouldLoop);
    notifyState();
}

void AudioEngine::play()
{
    const auto state = playlistSource.getState();
    if (state.trackCount == 0)
        return;

    if (state.isAtEnd && !state.isLooping)
        playlistSource.resetCurrentTrack();

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
    playlistSource.resetCurrentTrack();
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
    const auto state = playlistSource.getState();
    const auto samples = static_cast<int64>(std::llround(
        juce::jmax(0.0, seconds) * state.sampleRate));
    playlistSource.setCurrentTrackPosition(samples);
    notifyState();
}

void AudioEngine::setGain(float gain01)
{
    transportSource.setGain(juce::jlimit(0.0f, 1.0f, gain01));
}

AudioEngine::State AudioEngine::getState() const
{
    const auto playlistState = playlistSource.getState();
    State s;
    s.hasFile = playlistState.trackCount > 0;
    s.isPlaying = transportSource.isPlaying();
    s.positionSeconds = playlistState.sampleRate > 0.0
                      ? static_cast<double>(playlistState.currentPositionSamples) / playlistState.sampleRate
                      : 0.0;
    s.lengthSeconds = playlistState.sampleRate > 0.0
                    ? static_cast<double>(playlistState.currentLengthSamples) / playlistState.sampleRate
                    : 0.0;
    s.fileName = playlistState.currentFileName;
    s.filePath = playlistState.currentFilePath;
    s.currentTrackIndex = playlistState.currentTrackIndex;
    s.loopPlaylist = playlistState.isLooping;
    s.playlistNames = playlistState.trackNames;
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
