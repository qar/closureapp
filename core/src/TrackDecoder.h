#pragma once

#include "closure/PlaybackEngine.h"

#include <AudioToolbox/ExtendedAudioFile.h>

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace closure::detail
{
/**
    Decodes one file to interleaved stereo float at the output sample rate.

    ExtAudioFile uses the system decoders (FLAC, ALAC, AAC, MP3, WAV, AIFF, CAF) and
    trims encoder priming and padding when the file records them. When the file
    rate differs from the output rate, its converter runs at the highest quality
    the system offers. Mono files play on both channels. Files with more than two
    channels are rejected for now.

    Not thread safe. The engine uses it only from its decoder thread or while it
    holds the engine lock.
*/
class TrackDecoder final
{
public:
    TrackDecoder() = default;
    ~TrackDecoder() { close(); }

    TrackDecoder(const TrackDecoder&) = delete;
    TrackDecoder& operator=(const TrackDecoder&) = delete;

    bool open(const std::string& path, double outputSampleRate, std::string& error);
    void close() noexcept;
    bool isOpen() const noexcept { return file != nullptr; }

    /** Position in output-rate frames. */
    bool seek(std::int64_t outputFrame) noexcept;

    /** Returns 0 at the end of the file or on a read error. */
    std::size_t read(float* interleavedStereo, std::size_t maxFrames);

    std::int64_t lengthFrames() const noexcept { return outputLength; }
    double sourceSampleRate() const noexcept { return fileRate; }
    bool isResampling() const noexcept { return resampling; }

private:
    void useHighQualityResampler() noexcept;

    ExtAudioFileRef file = nullptr;
    double fileRate = 0.0;
    double outputRate = 0.0;
    std::uint32_t clientChannels = 2;
    std::int64_t outputLength = 0;
    bool resampling = false;
    std::vector<float> monoScratch;
};

std::string describeStatus(OSStatus status);
} // namespace closure::detail
