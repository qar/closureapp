#include "GaplessPlaylistSource.h"

#include <algorithm>
#include <cmath>
#include <vector>

namespace
{
constexpr int readAheadSamples = 131072;
constexpr int introCacheSamples = 65536;

int64 outputLengthFor(int64 inputLength, double inputRate, double outputRate)
{
    if (inputLength <= 0 || inputRate <= 0.0 || outputRate <= 0.0)
        return 0;

    return static_cast<int64>(std::ceil(static_cast<double>(inputLength) * outputRate / inputRate));
}
} // namespace

class GaplessPlaylistSource::TrackSource final
{
public:
    TrackSource(juce::File fileIn,
                juce::AudioFormatReader* reader,
                juce::TimeSliceThread& readAheadThreadIn)
        : file(std::move(fileIn)),
          readerSource(std::make_unique<juce::AudioFormatReaderSource>(reader, true)),
          bufferingSource(std::make_unique<juce::BufferingAudioSource>(readerSource.get(),
                                                                        readAheadThreadIn,
                                                                        false,
                                                                        readAheadSamples,
                                                                        2,
                                                                        true)),
          sourceRate(reader->sampleRate),
          sourceLength(reader->lengthInSamples)
    {
        const auto introLength = static_cast<int>(juce::jmin<int64>(sourceLength, introCacheSamples));
        if (introLength > 0)
        {
            introBuffer.setSize(2, introLength);
            reader->read(&introBuffer, 0, introLength, 0, true, true);
            introNativeLength = introLength;
        }
    }

    ~TrackSource()
    {
        releaseResources();
    }

    bool prepareToPlay(int samplesPerBlockExpected, double outputRate)
    {
        if (prepared && juce::approximatelyEqual(preparedOutputRate, outputRate)
            && preparedBlockSize == samplesPerBlockExpected)
        {
            return true;
        }

        releaseResources();

        if (sourceRate <= 0.0 || sourceLength <= 0)
            return false;

        const auto needsResampling = !juce::approximatelyEqual(sourceRate, outputRate);

        introMemorySource = std::make_unique<juce::MemoryAudioSource>(introBuffer, false, false);
        if (needsResampling)
        {
            introResamplingSource = std::make_unique<juce::ResamplingAudioSource>(introMemorySource.get(),
                                                                                    false,
                                                                                    2);
            introResamplingSource->setResamplingRatio(sourceRate / outputRate);
            introResamplingSource->prepareToPlay(samplesPerBlockExpected, outputRate);
            introRenderSource = introResamplingSource.get();
        }
        else
        {
            introMemorySource->prepareToPlay(samplesPerBlockExpected, outputRate);
            introRenderSource = introMemorySource.get();
        }

        if (needsResampling)
        {
            resamplingSource = std::make_unique<juce::ResamplingAudioSource>(bufferingSource.get(),
                                                                               false,
                                                                               2);
            resamplingSource->setResamplingRatio(sourceRate / outputRate);
            resamplingSource->prepareToPlay(samplesPerBlockExpected, outputRate);
            renderSource = resamplingSource.get();
        }
        else
        {
            bufferingSource->prepareToPlay(samplesPerBlockExpected, outputRate);
            renderSource = bufferingSource.get();
        }

        preparedOutputRate = outputRate;
        preparedBlockSize = samplesPerBlockExpected;
        outputLength = outputLengthFor(sourceLength, sourceRate, outputRate);
        introOutputLength = outputLengthFor(introNativeLength, sourceRate, outputRate);
        prepared = renderSource != nullptr && outputLength > 0;
        resetToStart();
        return prepared;
    }

    void releaseResources()
    {
        if (resamplingSource != nullptr)
            resamplingSource->releaseResources();
        else if (bufferingSource != nullptr)
            bufferingSource->releaseResources();

        if (introResamplingSource != nullptr)
            introResamplingSource->releaseResources();
        else if (introMemorySource != nullptr)
            introMemorySource->releaseResources();

        resamplingSource.reset();
        introResamplingSource.reset();
        introMemorySource.reset();
        introRenderSource = nullptr;
        renderSource = nullptr;
        prepared = false;
    }

    void resetToStart()
    {
        setOutputPosition(0);
        forwardPositionInitialised = false;
    }

    void setOutputPosition(int64 position)
    {
        const auto clamped = juce::jlimit<int64>(0, outputLength, position);
        if (!prepared || preparedOutputRate <= 0.0)
        {
            bufferingSource->setNextReadPosition(0);
            return;
        }

        const auto nativePosition = static_cast<int64>(std::llround(
            static_cast<double>(clamped) * sourceRate / preparedOutputRate));
        bufferingSource->setNextReadPosition(nativePosition);

        if (resamplingSource != nullptr)
            resamplingSource->flushBuffers();

        forwardPositionInitialised = true;
    }

    void render(const juce::AudioSourceChannelInfo& info, int64 outputPosition)
    {
        auto remaining = info.numSamples;
        auto offset = 0;

        if (introRenderSource != nullptr && outputPosition < introOutputLength)
        {
            const auto introSamples = juce::jmin<int64>(introOutputLength - outputPosition, remaining);
            const auto nativePosition = static_cast<int64>(std::llround(
                static_cast<double>(outputPosition) * sourceRate / preparedOutputRate));
            introMemorySource->setNextReadPosition(nativePosition);

            if (introResamplingSource != nullptr)
                introResamplingSource->flushBuffers();

            const juce::AudioSourceChannelInfo introInfo(info.buffer,
                                                         info.startSample,
                                                         static_cast<int>(introSamples));
            introRenderSource->getNextAudioBlock(introInfo);
            remaining -= static_cast<int>(introSamples);
            offset += static_cast<int>(introSamples);
        }

        if (remaining > 0 && renderSource != nullptr)
        {
            if (!forwardPositionInitialised)
                setOutputPosition(outputPosition + offset);

            const juce::AudioSourceChannelInfo sourceInfo(info.buffer,
                                                          info.startSample + offset,
                                                          remaining);
            renderSource->getNextAudioBlock(sourceInfo);
        }
        else if (remaining > 0)
        {
            info.buffer->clear(info.startSample + offset, remaining);
        }
    }

    juce::File file;
    std::unique_ptr<juce::AudioFormatReaderSource> readerSource;
    std::unique_ptr<juce::BufferingAudioSource> bufferingSource;
    std::unique_ptr<juce::ResamplingAudioSource> resamplingSource;
    juce::AudioBuffer<float> introBuffer;
    std::unique_ptr<juce::MemoryAudioSource> introMemorySource;
    std::unique_ptr<juce::ResamplingAudioSource> introResamplingSource;
    juce::AudioSource* renderSource = nullptr;
    juce::AudioSource* introRenderSource = nullptr;
    double sourceRate = 0.0;
    int64 sourceLength = 0;
    int64 introNativeLength = 0;
    double preparedOutputRate = 0.0;
    int preparedBlockSize = 0;
    int64 introOutputLength = 0;
    int64 outputLength = 0;
    bool prepared = false;
    bool forwardPositionInitialised = false;
};

GaplessPlaylistSource::GaplessPlaylistSource(juce::AudioFormatManager& formatManagerIn,
                                             juce::TimeSliceThread& readAheadThreadIn)
    : formatManager(formatManagerIn),
      readAheadThread(readAheadThreadIn)
{
}

GaplessPlaylistSource::~GaplessPlaylistSource()
{
    releaseResources();
    clear();
}

int GaplessPlaylistSource::addFiles(const juce::Array<juce::File>& files)
{
    int added = 0;

    for (const auto& file : files)
    {
        if (!file.existsAsFile())
            continue;

        bool duplicate = false;
        {
            const juce::ScopedLock sl(stateLock);
            const auto path = file.getFullPathName();
            duplicate = std::any_of(tracks.begin(), tracks.end(), [&path](const auto& track)
            {
                return track != nullptr && track->file.getFullPathName() == path;
            });
        }

        if (duplicate)
            continue;

        auto track = createTrackSource(file);
        if (track == nullptr)
            continue;

        double rate = 0.0;
        int blockSize = 0;
        bool shouldPrepare = false;
        {
            const juce::ScopedLock sl(stateLock);
            rate = outputSampleRate;
            blockSize = expectedBlockSize;
            shouldPrepare = prepared;
        }

        if (shouldPrepare && !track->prepareToPlay(blockSize, rate))
            continue;

        {
            const juce::ScopedLock sl(stateLock);
            const auto path = file.getFullPathName();
            const auto becameDuplicate = std::any_of(tracks.begin(), tracks.end(), [&path](const auto& existing)
            {
                return existing != nullptr && existing->file.getFullPathName() == path;
            });

            if (becameDuplicate)
                continue;

            tracks.push_back(std::move(track));
            ++added;

            if (currentTrackIndex < 0)
                selectTrackLocked(0);
        }
    }

    return added;
}

std::unique_ptr<GaplessPlaylistSource::TrackSource>
GaplessPlaylistSource::createTrackSource(const juce::File& file) const
{
    auto* reader = formatManager.createReaderFor(file);
    if (reader == nullptr)
        return nullptr;

    return std::make_unique<TrackSource>(file, reader, readAheadThread);
}

bool GaplessPlaylistSource::removeTrack(int index)
{
    const juce::ScopedLock sl(stateLock);
    if (!juce::isPositiveAndBelow(index, static_cast<int>(tracks.size())))
        return false;

    const auto wasCurrent = index == currentTrackIndex;
    tracks.erase(tracks.begin() + index);

    if (tracks.empty())
    {
        currentTrackIndex = -1;
        currentPositionSamples = 0;
        totalPositionSamples = 0;
        return true;
    }

    if (index < currentTrackIndex)
        --currentTrackIndex;
    else if (wasCurrent)
        currentTrackIndex = juce::jmin(currentTrackIndex, static_cast<int>(tracks.size()) - 1);

    currentPositionSamples = juce::jmin(currentPositionSamples,
                                        tracks[static_cast<size_t>(currentTrackIndex)]->outputLength);
    resetTrackLocked(currentTrackIndex);
    updateGlobalPositionLocked();
    return true;
}

void GaplessPlaylistSource::clear()
{
    const juce::ScopedLock sl(stateLock);
    tracks.clear();
    currentTrackIndex = -1;
    currentPositionSamples = 0;
    totalPositionSamples = 0;
    pendingGapSamples = 0;
    pendingTrackIndex = -1;
}

bool GaplessPlaylistSource::selectTrack(int index)
{
    const juce::ScopedLock sl(stateLock);
    if (!juce::isPositiveAndBelow(index, static_cast<int>(tracks.size())))
        return false;

    selectTrackLocked(index);
    return true;
}

void GaplessPlaylistSource::selectTrackLocked(int index)
{
    currentTrackIndex = index;
    currentPositionSamples = 0;
    pendingGapSamples = 0;
    pendingTrackIndex = -1;
    resetTrackLocked(index);
    updateGlobalPositionLocked();
}

void GaplessPlaylistSource::resetCurrentTrack()
{
    const juce::ScopedLock sl(stateLock);
    if (currentTrackIndex < 0 && !tracks.empty())
        currentTrackIndex = 0;

    if (currentTrackIndex >= 0)
    {
        currentPositionSamples = 0;
        pendingGapSamples = 0;
        pendingTrackIndex = -1;
        resetTrackLocked(currentTrackIndex);
        updateGlobalPositionLocked();
    }
}

void GaplessPlaylistSource::setCurrentTrackPosition(int64 positionSamples)
{
    const juce::ScopedLock sl(stateLock);
    if (!juce::isPositiveAndBelow(currentTrackIndex, static_cast<int>(tracks.size())))
        return;

    currentPositionSamples = juce::jlimit<int64>(
        0,
        tracks[static_cast<size_t>(currentTrackIndex)]->outputLength,
        positionSamples);
    pendingGapSamples = 0;
    pendingTrackIndex = -1;
    resetTrackLocked(currentTrackIndex);
    tracks[static_cast<size_t>(currentTrackIndex)]->setOutputPosition(currentPositionSamples);
    updateGlobalPositionLocked();
}

void GaplessPlaylistSource::setRepeatMode(RepeatMode mode)
{
    const juce::ScopedLock sl(stateLock);
    repeatMode = mode;
}

void GaplessPlaylistSource::setLooping(bool shouldLoop)
{
    setRepeatMode(shouldLoop ? RepeatMode::playlist : RepeatMode::off);
}

void GaplessPlaylistSource::setGaplessPlayback(bool shouldBeGapless)
{
    const juce::ScopedLock sl(stateLock);
    if (gaplessPlayback == shouldBeGapless)
        return;

    gaplessPlayback = shouldBeGapless;
    pendingGapSamples = 0;
    pendingTrackIndex = -1;

    if (juce::isPositiveAndBelow(currentTrackIndex, static_cast<int>(tracks.size())))
    {
        currentPositionSamples = juce::jlimit<int64>(
            0,
            tracks[static_cast<size_t>(currentTrackIndex)]->outputLength,
            currentPositionSamples);
        resetTrackLocked(currentTrackIndex);
        tracks[static_cast<size_t>(currentTrackIndex)]->setOutputPosition(currentPositionSamples);
    }

    updateGlobalPositionLocked();
}

GaplessPlaylistSource::State GaplessPlaylistSource::getState() const
{
    const juce::ScopedLock sl(stateLock);
    State result;
    result.currentTrackIndex = currentTrackIndex;
    result.trackCount = static_cast<int>(tracks.size());
    result.currentPositionSamples = currentPositionSamples;
    result.totalPositionSamples = totalPositionSamples;
    result.sampleRate = outputSampleRate;
    result.repeatMode = repeatMode;
    result.gaplessPlayback = gaplessPlayback;
    result.isLooping = repeatMode != RepeatMode::off;
    result.totalLengthSamples = getTotalLengthLocked();

    for (const auto& track : tracks)
    {
        if (track != nullptr)
        {
            result.trackNames.add(track->file.getFileName());
            result.trackPaths.add(track->file.getFullPathName());
        }
    }

    if (juce::isPositiveAndBelow(currentTrackIndex, static_cast<int>(tracks.size())))
    {
        const auto& track = tracks[static_cast<size_t>(currentTrackIndex)];
        result.currentLengthSamples = track->outputLength;
        result.currentFileName = track->file.getFileName();
        result.currentFilePath = track->file.getFullPathName();
        result.isAtEnd = currentPositionSamples >= track->outputLength;
    }

    return result;
}

void GaplessPlaylistSource::prepareToPlay(int samplesPerBlockExpected, double sampleRate)
{
    const juce::ScopedLock sl(stateLock);
    expectedBlockSize = samplesPerBlockExpected;
    outputSampleRate = sampleRate > 0.0 ? sampleRate : 44100.0;

    for (auto& track : tracks)
    {
        if (track != nullptr)
            track->prepareToPlay(expectedBlockSize, outputSampleRate);
    }

    prepared = true;
    currentPositionSamples = 0;
    pendingGapSamples = 0;
    pendingTrackIndex = -1;
    if (!tracks.empty())
        currentTrackIndex = juce::jlimit(0, static_cast<int>(tracks.size()) - 1, currentTrackIndex);
    else
        currentTrackIndex = -1;

    if (currentTrackIndex >= 0)
        resetTrackLocked(currentTrackIndex);
    updateGlobalPositionLocked();
}

void GaplessPlaylistSource::releaseResources()
{
    const juce::ScopedLock sl(stateLock);
    for (auto& track : tracks)
    {
        if (track != nullptr)
            track->releaseResources();
    }

    prepared = false;
}

void GaplessPlaylistSource::getNextAudioBlock(const juce::AudioSourceChannelInfo& info)
{
    const juce::ScopedLock sl(stateLock);

    if (info.numSamples <= 0 || currentTrackIndex < 0 || tracks.empty())
    {
        info.clearActiveBufferRegion();
        return;
    }

    auto samplesRemaining = info.numSamples;
    auto destinationOffset = 0;

    while (samplesRemaining > 0 && currentTrackIndex >= 0)
    {
        if (pendingGapSamples > 0)
        {
            const auto silenceSamples = juce::jmin<int64>(pendingGapSamples, samplesRemaining);
            info.buffer->clear(info.startSample + destinationOffset,
                               static_cast<int>(silenceSamples));
            pendingGapSamples -= silenceSamples;
            totalPositionSamples += silenceSamples;
            destinationOffset += static_cast<int>(silenceSamples);
            samplesRemaining -= static_cast<int>(silenceSamples);

            if (pendingGapSamples == 0 && pendingTrackIndex >= 0)
            {
                const auto nextTrack = pendingTrackIndex;
                pendingTrackIndex = -1;
                selectTrackLocked(nextTrack);
            }

            continue;
        }

        auto& track = tracks[static_cast<size_t>(currentTrackIndex)];
        const auto trackRemaining = track->outputLength - currentPositionSamples;

        if (trackRemaining <= 0)
        {
            if (!advanceToNextTrack())
            {
                info.buffer->clear(info.startSample + destinationOffset, samplesRemaining);
                break;
            }
            continue;
        }

        const auto samplesToRender = juce::jmin<int64>(trackRemaining, samplesRemaining);
        const juce::AudioSourceChannelInfo trackInfo(info.buffer,
                                                     info.startSample + destinationOffset,
                                                     static_cast<int>(samplesToRender));
        track->render(trackInfo, currentPositionSamples);

        currentPositionSamples += samplesToRender;
        totalPositionSamples += samplesToRender;
        destinationOffset += static_cast<int>(samplesToRender);
        samplesRemaining -= static_cast<int>(samplesToRender);
    }
}

bool GaplessPlaylistSource::advanceToNextTrack()
{
    if (tracks.empty() || currentTrackIndex < 0)
        return false;

    auto nextIndex = currentTrackIndex + 1;
    if (repeatMode == RepeatMode::single)
    {
        nextIndex = currentTrackIndex;
    }
    else if (nextIndex >= static_cast<int>(tracks.size()))
    {
        if (repeatMode == RepeatMode::off)
        {
            totalPositionSamples = getTotalLengthLocked();
            return false;
        }

        nextIndex = 0;
    }

    if (!gaplessPlayback)
    {
        pendingGapSamples = transitionGapSamplesLocked();
        pendingTrackIndex = nextIndex;
        currentTrackIndex = nextIndex;
        currentPositionSamples = 0;
        resetTrackLocked(currentTrackIndex);
        return true;
    }

    selectTrackLocked(nextIndex);
    return true;
}

void GaplessPlaylistSource::setNextReadPosition(int64 newPosition)
{
    const juce::ScopedLock sl(stateLock);
    const auto totalLength = getTotalLengthLocked();
    const auto clamped = juce::jlimit<int64>(0, totalLength, newPosition);

    int64 positionInTrack = 0;
    const auto trackIndex = findTrackForPositionLocked(clamped, positionInTrack);
    if (trackIndex < 0)
        return;

    pendingGapSamples = 0;
    pendingTrackIndex = -1;
    currentTrackIndex = trackIndex;
    currentPositionSamples = positionInTrack;
    resetTrackLocked(currentTrackIndex);
    tracks[static_cast<size_t>(currentTrackIndex)]->setOutputPosition(currentPositionSamples);
    totalPositionSamples = clamped;
}

int64 GaplessPlaylistSource::getNextReadPosition() const
{
    const juce::ScopedLock sl(stateLock);
    return totalPositionSamples;
}

int64 GaplessPlaylistSource::getTotalLength() const
{
    const juce::ScopedLock sl(stateLock);
    return getTotalLengthLocked();
}

int64 GaplessPlaylistSource::getTotalLengthLocked() const
{
    int64 total = 0;
    for (int index = 0; index < static_cast<int>(tracks.size()); ++index)
    {
        const auto& track = tracks[static_cast<size_t>(index)];
        if (track != nullptr)
        {
            total += track->outputLength;

            if (!gaplessPlayback && index + 1 < static_cast<int>(tracks.size()))
                total += transitionGapSamplesLocked();
        }
    }
    return total;
}

bool GaplessPlaylistSource::isLooping() const
{
    const juce::ScopedLock sl(stateLock);
    return repeatMode != RepeatMode::off && !tracks.empty();
}

bool GaplessPlaylistSource::isGaplessPlayback() const
{
    const juce::ScopedLock sl(stateLock);
    return gaplessPlayback;
}

void GaplessPlaylistSource::resetTrackLocked(int index)
{
    if (juce::isPositiveAndBelow(index, static_cast<int>(tracks.size())))
        tracks[static_cast<size_t>(index)]->resetToStart();
}

void GaplessPlaylistSource::updateGlobalPositionLocked()
{
    totalPositionSamples = trackStartPositionLocked(currentTrackIndex) + currentPositionSamples;
}

int64 GaplessPlaylistSource::trackStartPositionLocked(int index) const
{
    int64 position = 0;
    for (int i = 0; i < index && i < static_cast<int>(tracks.size()); ++i)
    {
        if (tracks[static_cast<size_t>(i)] != nullptr)
        {
            position += tracks[static_cast<size_t>(i)]->outputLength;

            if (!gaplessPlayback && i + 1 < static_cast<int>(tracks.size()))
                position += transitionGapSamplesLocked();
        }
    }
    return position;
}

int64 GaplessPlaylistSource::transitionGapSamplesLocked() const
{
    return static_cast<int64>(std::llround(outputSampleRate * 0.08));
}

int GaplessPlaylistSource::findTrackForPositionLocked(int64 position,
                                                       int64& positionInTrack) const
{
    int64 start = 0;
    for (int index = 0; index < static_cast<int>(tracks.size()); ++index)
    {
        const auto length = tracks[static_cast<size_t>(index)]->outputLength;
        if (position < start + length || (position == start + length && index == static_cast<int>(tracks.size()) - 1))
        {
            positionInTrack = position - start;
            return index;
        }
        start += length;

        if (!gaplessPlayback && index + 1 < static_cast<int>(tracks.size()))
        {
            const auto gap = transitionGapSamplesLocked();
            if (position < start + gap)
            {
                positionInTrack = 0;
                return index + 1;
            }

            start += gap;
        }
    }

    positionInTrack = 0;
    return tracks.empty() ? -1 : static_cast<int>(tracks.size()) - 1;
}
