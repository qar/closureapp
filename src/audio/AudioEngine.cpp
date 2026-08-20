#include "AudioEngine.h"
#include "audio/AudioFileFormats.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstring>

namespace
{
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
            if (AudioFileFormats::isSupported(input))
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
            if (AudioFileFormats::isSupported(child))
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
      analysisSource(std::make_unique<AnalysisAudioSource>(transportSource))
{
    formatManager.registerBasicFormats();
    jassert(readAheadThread.startThread());

    configureProperties();

    auto queue = createPlaylistContext("queue", "Queue");
    activePlaylist = queue.get();
    playlists.push_back(std::move(queue));

    auto result = deviceManager.initialiseWithDefaultDevices(0, 2);
    jassert(result.isEmpty());

    // Prefer lower latency when the device allows it.
    if (deviceManager.getCurrentAudioDevice() != nullptr)
    {
        auto setup = deviceManager.getAudioDeviceSetup();
        setup.bufferSize = juce::jmin(setup.bufferSize, 256);
        deviceManager.setAudioDeviceSetup(setup, true);
    }

    transportSource.setSource(activePlaylist->source.get());
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

std::unique_ptr<AudioEngine::PlaylistContext>
AudioEngine::createPlaylistContext(const juce::String& id, const juce::String& name)
{
    auto context = std::make_unique<PlaylistContext>();
    context->id = id;
    context->name = name;
    context->source = std::make_unique<GaplessPlaylistSource>(formatManager, readAheadThread);
    context->source->setRepeatMode(currentRepeatMode);
    context->source->setGaplessPlayback(currentGaplessPlayback);
    return context;
}

AudioEngine::PlaylistContext& AudioEngine::queuePlaylist()
{
    jassert(!playlists.empty());
    return *playlists.front();
}

const AudioEngine::PlaylistContext& AudioEngine::queuePlaylist() const
{
    jassert(!playlists.empty());
    return *playlists.front();
}

AudioEngine::PlaylistContext* AudioEngine::findPlaylist(const juce::String& id)
{
    for (const auto& playlist : playlists)
    {
        if (playlist->id == id)
            return playlist.get();
    }

    return nullptr;
}

GaplessPlaylistSource& AudioEngine::activeSource()
{
    jassert(activePlaylist != nullptr && activePlaylist->source != nullptr);
    return *activePlaylist->source;
}

const GaplessPlaylistSource& AudioEngine::activeSource() const
{
    jassert(activePlaylist != nullptr && activePlaylist->source != nullptr);
    return *activePlaylist->source;
}

void AudioEngine::switchToPlaylist(PlaylistContext& context)
{
    if (activePlaylist == &context)
        return;

    transportSource.stop();
    transportSource.setSource(context.source.get());
    activePlaylist = &context;
}

int AudioEngine::addFiles(const juce::Array<juce::File>& files, bool startPlaybackIfEmpty)
{
    const auto expandedFiles = expandAudioInputs(files);
    if (expandedFiles.isEmpty())
        return 0;

    auto& queue = queuePlaylist();
    const auto wasEmpty = queue.source->getState().trackCount == 0;
    const auto added = queue.source->addFiles(expandedFiles);
    if (added <= 0)
        return 0;

    for (const auto& file : expandedFiles)
        scheduleMetadataRead(file);

    savePlaylist();
    notifyState();

    if (wasEmpty && startPlaybackIfEmpty && activePlaylist == &queue)
        play();

    return added;
}

int AudioEngine::playAlbumPlaylist(const juce::String& playlistId,
                                   const juce::String& playlistName,
                                   const juce::Array<juce::File>& files)
{
    if (playlistId.isEmpty() || files.isEmpty())
        return 0;

    auto* context = findPlaylist(playlistId);
    if (context == nullptr)
    {
        auto created = createPlaylistContext(playlistId, playlistName);
        context = created.get();
        playlists.push_back(std::move(created));
    }

    context->name = playlistName;
    context->source->clear();
    const auto added = context->source->addFiles(files);
    if (added <= 0)
        return 0;

    for (const auto& file : files)
        scheduleMetadataRead(file);

    switchToPlaylist(*context);
    context->source->selectTrack(0);
    savePlaylist();
    play();
    return added;
}

bool AudioEngine::removeTrack(int index)
{
    auto& queue = queuePlaylist();
    const auto stateBefore = queue.source->getState();
    const auto removed = queue.source->removeTrack(index);
    if (!removed)
        return false;

    if (stateBefore.trackCount == 1 && activePlaylist == &queue)
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
    auto& queue = queuePlaylist();
    const auto removedPaths = queue.source->getState().trackPaths;

    if (activePlaylist == &queue)
    {
        transportSource.stop();
        stopPositionTimer();
    }

    queue.source->clear();

    {
        const juce::ScopedLock sl(metadataLock);
        for (const auto& path : removedPaths)
            metadataByPath.erase(path.toStdString());
    }

    savePlaylist();
    notifyState();
}

void AudioEngine::playTrack(int index)
{
    auto& queue = queuePlaylist();
    switchToPlaylist(queue);
    playActiveTrack(index);
}

void AudioEngine::playActiveTrack(int index)
{
    if (!activeSource().selectTrack(index))
        return;

    transportSource.start();
    startPositionTimer();
    notifyState();
}

void AudioEngine::setRepeatMode(RepeatMode mode)
{
    currentRepeatMode = mode;
    for (const auto& playlist : playlists)
        playlist->source->setRepeatMode(mode);
    notifyState();
}

void AudioEngine::setGaplessPlayback(bool shouldBeGapless)
{
    currentGaplessPlayback = shouldBeGapless;
    for (const auto& playlist : playlists)
        playlist->source->setGaplessPlayback(shouldBeGapless);
    notifyState();
}

void AudioEngine::play()
{
    auto& source = activeSource();
    const auto state = source.getState();
    if (state.trackCount == 0)
        return;

    if (state.isAtEnd && state.repeatMode == RepeatMode::off)
        source.resetCurrentTrack();

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
    activeSource().resetCurrentTrack();
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
    const auto state = activeSource().getState();
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

    playActiveTrack(previousIndex);
}

void AudioEngine::playNext()
{
    const auto state = activeSource().getState();
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

    playActiveTrack(nextIndex);
}

void AudioEngine::setPosition(double seconds)
{
    const auto state = activeSource().getState();
    const auto samples = static_cast<int64>(std::llround(
        juce::jmax(0.0, seconds) * state.sampleRate));
    activeSource().setCurrentTrackPosition(samples);
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
    const auto activeState = activeSource().getState();
    const auto queueState = queuePlaylist().source->getState();
    State s;
    s.hasFile = activeState.trackCount > 0;
    s.isPlaying = transportSource.isPlaying();
    s.positionSeconds = activeState.sampleRate > 0.0
                      ? static_cast<double>(activeState.currentPositionSamples) / activeState.sampleRate
                      : 0.0;
    s.lengthSeconds = activeState.sampleRate > 0.0
                    ? static_cast<double>(activeState.currentLengthSamples) / activeState.sampleRate
                    : 0.0;
    s.fileName = activeState.currentFileName;
    s.filePath = activeState.currentFilePath;
    s.currentTrackIndex = activeState.currentTrackIndex;
    s.repeatMode = currentRepeatMode;
    s.gaplessPlayback = currentGaplessPlayback;
    s.activePlaylistId = activePlaylist->id;
    s.activePlaylistName = activePlaylist->name;
    s.queueIsActive = activePlaylist == &queuePlaylist();
    s.playlistNames = queueState.trackNames;
    s.playlistPaths = queueState.trackPaths;

    {
        const juce::ScopedLock sl(metadataLock);
        for (const auto& path : s.playlistPaths)
        {
            const auto found = metadataByPath.find(path.toStdString());
            s.playlistMetadata.push_back(found != metadataByPath.end() ? found->second : nullptr);
        }

        const auto current = metadataByPath.find(s.filePath.toStdString());
        if (current != metadataByPath.end())
            s.currentTrackMetadata = current->second;
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

    const auto loadExistingFiles = [](const juce::String& value)
    {
        juce::Array<juce::File> files;
        juce::StringArray paths;
        paths.addLines(value);

        for (const auto& path : paths)
        {
            const auto trimmedPath = path.trim();
            const juce::File file(trimmedPath);
            if (trimmedPath.isNotEmpty() && file.existsAsFile())
                files.add(file);
        }

        return files;
    };

    auto& queue = queuePlaylist();
    const auto queueFiles = loadExistingFiles(settings->getValue("playlistPaths"));
    if (!queueFiles.isEmpty())
    {
        queue.source->addFiles(queueFiles);
        for (const auto& file : queueFiles)
            scheduleMetadataRead(file);
    }

    juce::StringArray albumIds;
    albumIds.addLines(settings->getValue("albumPlaylistIds"));
    for (const auto& rawId : albumIds)
    {
        const auto id = rawId.trim();
        if (id.isEmpty())
            continue;

        const auto files = loadExistingFiles(settings->getValue("albumPlaylist." + id));
        if (files.isEmpty())
            continue;

        auto context = createPlaylistContext(id, settings->getValue("albumPlaylistName." + id, id));
        context->source->addFiles(files);
        for (const auto& file : files)
            scheduleMetadataRead(file);
        playlists.push_back(std::move(context));
    }

    if (auto* saved = findPlaylist(settings->getValue("activePlaylistId")))
        switchToPlaylist(*saved);

    // Remove paths for files that no longer exist.
    savePlaylist();
}

void AudioEngine::savePlaylist()
{
    auto* settings = applicationProperties.getUserSettings();
    if (settings == nullptr)
        return;

    settings->setValue("playlistPaths",
                       queuePlaylist().source->getState().trackPaths.joinIntoString("\n"));

    const auto properties = settings->getAllProperties();
    for (const auto& key : properties.getAllKeys())
    {
        if (key.startsWith("albumPlaylist."))
            settings->removeValue(key);
    }

    juce::StringArray albumIds;
    for (const auto& playlist : playlists)
    {
        if (playlist.get() == &queuePlaylist())
            continue;

        albumIds.add(playlist->id);
        settings->setValue("albumPlaylist." + playlist->id,
                           playlist->source->getState().trackPaths.joinIntoString("\n"));
        settings->setValue("albumPlaylistName." + playlist->id, playlist->name);
    }

    settings->setValue("albumPlaylistIds", albumIds.joinIntoString("\n"));
    settings->setValue("activePlaylistId", activePlaylist->id);
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
