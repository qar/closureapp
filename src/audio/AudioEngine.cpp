#include "AudioEngine.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstring>

namespace
{
bool isSupportedAudioFile(const juce::File& file)
{
    const auto extension = file.getFileExtension().toLowerCase();
    return extension == ".mp3" || extension == ".flac" || extension == ".wav"
        || extension == ".aiff" || extension == ".aif" || extension == ".m4a"
        || extension == ".alac" || extension == ".ogg";
}

struct FilePathComparator
{
    int compareElements(const juce::File& first, const juce::File& second) const
    {
        return first.getFullPathName().compareIgnoreCase(second.getFullPathName());
    }
};

juce::Array<juce::File> expandAudioInputs(const juce::Array<juce::File>& inputs)
{
    juce::Array<juce::File> expanded;

    for (const auto& input : inputs)
    {
        if (input.existsAsFile())
        {
            if (isSupportedAudioFile(input))
                expanded.add(input);
            continue;
        }

        if (!input.isDirectory())
            continue;

        juce::Array<juce::File> children;
        input.findChildFiles(children, juce::File::findFiles, true, "*");
        FilePathComparator comparator;
        children.sort(comparator, true);

        for (const auto& child : children)
        {
            if (isSupportedAudioFile(child))
                expanded.add(child);
        }
    }

    return expanded;
}
}

class AudioEngine::AnalysisAudioSource final : public juce::AudioSource
{
public:
    explicit AnalysisAudioSource(juce::AudioSource& sourceIn)
        : source(sourceIn), fifo(analysisBufferSize)
    {
    }

    void prepareToPlay(int samplesPerBlockExpected, double sampleRate) override
    {
        source.prepareToPlay(samplesPerBlockExpected, sampleRate);
        fifo.reset();
    }

    void releaseResources() override
    {
        source.releaseResources();
    }

    void getNextAudioBlock(const juce::AudioSourceChannelInfo& info) override
    {
        source.getNextAudioBlock(info);

        if (info.buffer == nullptr || info.numSamples <= 0 || info.buffer->getNumChannels() == 0)
            return;

        int startIndex1 = 0;
        int blockSize1 = 0;
        int startIndex2 = 0;
        int blockSize2 = 0;
        fifo.prepareToWrite(info.numSamples, startIndex1, blockSize1, startIndex2, blockSize2);

        const auto samplesToWrite = blockSize1 + blockSize2;
        if (samplesToWrite <= 0)
            return;

        const auto sourceOffset = info.numSamples - samplesToWrite;
        const auto* left = info.buffer->getReadPointer(0, info.startSample + sourceOffset);
        const auto* right = info.buffer->getNumChannels() > 1
                          ? info.buffer->getReadPointer(1, info.startSample + sourceOffset)
                          : nullptr;

        auto writeBlock = [left, right](float* destination, int sourceOffsetInBlock, int count)
        {
            for (int index = 0; index < count; ++index)
            {
                const auto leftSample = left[sourceOffsetInBlock + index];
                destination[index] = right != nullptr
                                   ? (leftSample + right[sourceOffsetInBlock + index]) * 0.5f
                                   : leftSample;
            }
        };

        writeBlock(audioBuffer.data() + startIndex1, 0, blockSize1);
        writeBlock(audioBuffer.data() + startIndex2, blockSize1, blockSize2);
        fifo.finishedWrite(samplesToWrite);
    }

    int readSamples(float* destination, int maxSamples)
    {
        if (destination == nullptr || maxSamples <= 0)
            return 0;

        int startIndex1 = 0;
        int blockSize1 = 0;
        int startIndex2 = 0;
        int blockSize2 = 0;
        fifo.prepareToRead(maxSamples, startIndex1, blockSize1, startIndex2, blockSize2);

        const auto samplesRead = blockSize1 + blockSize2;
        if (samplesRead <= 0)
            return 0;

        std::memcpy(destination, audioBuffer.data() + startIndex1,
                    static_cast<size_t>(blockSize1) * sizeof(float));
        std::memcpy(destination + blockSize1, audioBuffer.data() + startIndex2,
                    static_cast<size_t>(blockSize2) * sizeof(float));
        fifo.finishedRead(samplesRead);
        return samplesRead;
    }

private:
    static constexpr int analysisBufferSize = 32768;

    juce::AudioSource& source;
    juce::AbstractFifo fifo;
    std::array<float, analysisBufferSize> audioBuffer {};
};

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
      playlistSource(formatManager, readAheadThread),
      analysisSource(std::make_unique<AnalysisAudioSource>(transportSource))
{
    formatManager.registerBasicFormats();
    jassert(readAheadThread.startThread());

    configureProperties();

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
    sourcePlayer.setSource(analysisSource.get());
    deviceManager.addAudioCallback(&sourcePlayer);
    transportSource.addChangeListener(this);

    positionTimer = std::make_unique<PositionTimer>(*this);
    restorePlaylist();
}

AudioEngine::~AudioEngine()
{
    stopPositionTimer();
    transportSource.stop();
    transportSource.setSource(nullptr);
    transportSource.removeChangeListener(this);
    deviceManager.removeAudioCallback(&sourcePlayer);
    sourcePlayer.setSource(nullptr);
    applicationProperties.saveIfNeeded();
    readAheadThread.stopThread(2000);
}

int AudioEngine::addFiles(const juce::Array<juce::File>& files, bool startPlaybackIfEmpty)
{
    const auto expandedFiles = expandAudioInputs(files);
    if (expandedFiles.isEmpty())
        return 0;

    const auto wasEmpty = playlistSource.getState().trackCount == 0;
    const auto added = playlistSource.addFiles(expandedFiles);
    if (added <= 0)
        return 0;

    for (const auto& file : expandedFiles)
        scheduleMetadataRead(file);

    savePlaylist();
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

    if (juce::isPositiveAndBelow(index, stateBefore.trackPaths.size()))
    {
        const juce::ScopedLock sl(metadataLock);
        metadataByPath.erase(stateBefore.trackPaths[index].toStdString());
    }

    savePlaylist();
    notifyState();
    return true;
}

void AudioEngine::clearPlaylist()
{
    transportSource.stop();
    playlistSource.clear();
    {
        const juce::ScopedLock sl(metadataLock);
        metadataByPath.clear();
    }
    stopPositionTimer();
    savePlaylist();
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

void AudioEngine::setRepeatMode(RepeatMode mode)
{
    playlistSource.setRepeatMode(mode);
    notifyState();
}

void AudioEngine::setGaplessPlayback(bool shouldBeGapless)
{
    playlistSource.setGaplessPlayback(shouldBeGapless);
    notifyState();
}

void AudioEngine::play()
{
    const auto state = playlistSource.getState();
    if (state.trackCount == 0)
        return;

    if (state.isAtEnd && state.repeatMode == RepeatMode::off)
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

void AudioEngine::playPrevious()
{
    const auto state = playlistSource.getState();
    if (!juce::isPositiveAndBelow(state.currentTrackIndex, state.trackCount))
        return;

    if (state.currentPositionSamples > static_cast<int64>(state.sampleRate * 3.0))
    {
        setPosition(0.0);
        return;
    }

    auto previousIndex = state.currentTrackIndex - 1;
    if (previousIndex < 0)
    {
        if (state.repeatMode != RepeatMode::playlist)
        {
            setPosition(0.0);
            return;
        }

        previousIndex = state.trackCount - 1;
    }

    playTrack(previousIndex);
}

void AudioEngine::playNext()
{
    const auto state = playlistSource.getState();
    if (!juce::isPositiveAndBelow(state.currentTrackIndex, state.trackCount))
        return;

    auto nextIndex = state.currentTrackIndex + 1;
    if (nextIndex >= state.trackCount)
    {
        if (state.repeatMode != RepeatMode::playlist)
        {
            stop();
            return;
        }

        nextIndex = 0;
    }

    playTrack(nextIndex);
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

int AudioEngine::readAnalysisSamples(float* destination, int maxSamples)
{
    return analysisSource != nullptr ? analysisSource->readSamples(destination, maxSamples) : 0;
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
    s.repeatMode = playlistState.repeatMode;
    s.gaplessPlayback = playlistState.gaplessPlayback;
    s.playlistNames = playlistState.trackNames;
    s.playlistPaths = playlistState.trackPaths;

    {
        const juce::ScopedLock sl(metadataLock);
        for (const auto& path : s.playlistPaths)
        {
            const auto found = metadataByPath.find(path.toStdString());
            s.playlistMetadata.push_back(found != metadataByPath.end() ? found->second : nullptr);
        }
    }

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

void AudioEngine::configureProperties()
{
    juce::PropertiesFile::Options options;
    options.applicationName = "Closure";
    options.filenameSuffix = ".settings";
    options.folderName = "Closure";
    options.storageFormat = juce::PropertiesFile::storeAsXML;
    options.millisecondsBeforeSaving = 0;

#if JUCE_MAC
    options.osxLibrarySubFolder = "Application Support";
#endif

    applicationProperties.setStorageParameters(options);
}

void AudioEngine::restorePlaylist()
{
    auto* settings = applicationProperties.getUserSettings();
    if (settings == nullptr)
        return;

    juce::Array<juce::File> files;
    juce::StringArray paths;
    paths.addLines(settings->getValue("playlistPaths"));

    for (const auto& path : paths)
    {
        const auto trimmedPath = path.trim();
        const juce::File file(trimmedPath);
        if (trimmedPath.isNotEmpty() && file.existsAsFile())
            files.add(file);
    }

    if (!files.isEmpty())
        addFiles(files, false);

    // Remove paths for files that no longer exist.
    savePlaylist();
}

void AudioEngine::savePlaylist()
{
    auto* settings = applicationProperties.getUserSettings();
    if (settings == nullptr)
        return;

    const auto state = playlistSource.getState();
    settings->setValue("playlistPaths", state.trackPaths.joinIntoString("\n"));
    applicationProperties.saveIfNeeded();
}

void AudioEngine::scheduleMetadataRead(const juce::File& file)
{
    if (!file.existsAsFile())
        return;

    {
        const juce::ScopedLock sl(metadataLock);
        metadataByPath[file.getFullPathName().toStdString()] =
            std::make_shared<const TrackMetadata>(TrackMetadataUtil::fallbackForFile(file));
    }

    metadataReader.readAsync(file, [this](TrackMetadata metadata)
    {
        metadataReady(std::move(metadata));
    });
}

void AudioEngine::metadataReady(TrackMetadata metadata)
{
    const auto key = metadata.file.getFullPathName().toStdString();
    {
        const juce::ScopedLock sl(metadataLock);
        metadataByPath[key] = std::make_shared<const TrackMetadata>(std::move(metadata));
    }

    notifyState();
}
