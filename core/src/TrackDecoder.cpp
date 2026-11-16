#include "TrackDecoder.h"

#include <AudioToolbox/AudioToolbox.h>

#include <cctype>
#include <cmath>

namespace closure::detail
{
namespace
{
CFURLRef createFileURL(const std::string& path)
{
    return CFURLCreateFromFileSystemRepresentation(nullptr,
                                                   reinterpret_cast<const UInt8*>(path.data()),
                                                   static_cast<CFIndex>(path.size()),
                                                   false);
}

ExtAudioFileRef openFile(const std::string& path, std::string& error)
{
    const auto url = createFileURL(path);
    if (url == nullptr)
    {
        error = "Invalid path";
        return nullptr;
    }

    ExtAudioFileRef file = nullptr;
    const auto status = ExtAudioFileOpenURL(url, &file);
    CFRelease(url);
    if (status != noErr)
    {
        error = "Cannot open file (" + describeStatus(status) + ")";
        return nullptr;
    }

    return file;
}

AudioStreamBasicDescription floatClientFormat(double sampleRate, std::uint32_t channels)
{
    AudioStreamBasicDescription format {};
    format.mSampleRate = sampleRate;
    format.mFormatID = kAudioFormatLinearPCM;
    format.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    format.mBitsPerChannel = 32;
    format.mChannelsPerFrame = channels;
    format.mFramesPerPacket = 1;
    format.mBytesPerFrame = 4 * channels;
    format.mBytesPerPacket = format.mBytesPerFrame;
    return format;
}

int bitDepthOf(const AudioStreamBasicDescription& format)
{
    if (format.mFormatID == kAudioFormatLinearPCM)
        return static_cast<int>(format.mBitsPerChannel);

    if (format.mFormatID == kAudioFormatAppleLossless || format.mFormatID == kAudioFormatFLAC)
    {
        // ALAC and FLAC share the same source bit depth flag values.
        switch (format.mFormatFlags)
        {
            case 1: return 16;
            case 2: return 20;
            case 3: return 24;
            case 4: return 32;
            default: return 0;
        }
    }

    return 0;
}
} // namespace

std::string describeStatus(OSStatus status)
{
    const auto code = static_cast<std::uint32_t>(status);
    char fourCC[5] = { static_cast<char>(code >> 24), static_cast<char>(code >> 16),
                       static_cast<char>(code >> 8), static_cast<char>(code), 0 };
    for (int index = 0; index < 4; ++index)
    {
        if (!std::isprint(static_cast<unsigned char>(fourCC[index])))
            return std::to_string(status);
    }

    return std::string("'") + fourCC + "'";
}

bool TrackDecoder::open(const std::string& path, double outputSampleRate, std::string& error)
{
    close();

    file = openFile(path, error);
    if (file == nullptr)
        return false;

    AudioStreamBasicDescription fileFormat {};
    auto size = static_cast<UInt32>(sizeof(fileFormat));
    auto status = ExtAudioFileGetProperty(file, kExtAudioFileProperty_FileDataFormat, &size, &fileFormat);

    SInt64 fileLength = 0;
    if (status == noErr)
    {
        size = sizeof(fileLength);
        status = ExtAudioFileGetProperty(file, kExtAudioFileProperty_FileLengthFrames, &size, &fileLength);
    }

    if (status != noErr)
    {
        error = "Cannot read file format (" + describeStatus(status) + ")";
        close();
        return false;
    }

    if (fileFormat.mChannelsPerFrame < 1 || fileFormat.mChannelsPerFrame > 2)
    {
        error = "Only mono and stereo files are supported";
        close();
        return false;
    }

    fileRate = fileFormat.mSampleRate;
    outputRate = outputSampleRate;
    clientChannels = fileFormat.mChannelsPerFrame;
    resampling = std::abs(fileRate - outputRate) > 0.5;

    const auto client = floatClientFormat(outputRate, clientChannels);
    status = ExtAudioFileSetProperty(file, kExtAudioFileProperty_ClientDataFormat, sizeof(client), &client);
    if (status != noErr)
    {
        error = "Cannot decode to float (" + describeStatus(status) + ")";
        close();
        return false;
    }

    if (resampling)
        useHighQualityResampler();

    outputLength = resampling
                 ? static_cast<std::int64_t>(std::llround(static_cast<double>(fileLength) * outputRate / fileRate))
                 : fileLength;
    return true;
}

void TrackDecoder::useHighQualityResampler() noexcept
{
    AudioConverterRef converter = nullptr;
    auto size = static_cast<UInt32>(sizeof(converter));
    if (ExtAudioFileGetProperty(file, kExtAudioFileProperty_AudioConverter, &size, &converter) != noErr
        || converter == nullptr)
    {
        return;
    }

    // Decoding runs ahead of playback in bursts, so the slower mastering-grade
    // converter is affordable. Fall back to the normal algorithm where it is missing.
    UInt32 complexity = kAudioConverterSampleRateConverterComplexity_Mastering;
    if (AudioConverterSetProperty(converter, kAudioConverterSampleRateConverterComplexity,
                                  sizeof(complexity), &complexity) != noErr)
    {
        complexity = kAudioConverterSampleRateConverterComplexity_Normal;
        AudioConverterSetProperty(converter, kAudioConverterSampleRateConverterComplexity,
                                  sizeof(complexity), &complexity);
    }

    UInt32 quality = kAudioConverterQuality_Max;
    AudioConverterSetProperty(converter, kAudioConverterSampleRateConverterQuality, sizeof(quality), &quality);

    // ExtAudioFile rebuilds its converter from this config; null keeps the new settings.
    CFArrayRef config = nullptr;
    ExtAudioFileSetProperty(file, kExtAudioFileProperty_ConverterConfig, sizeof(config), &config);
}

void TrackDecoder::close() noexcept
{
    if (file != nullptr)
    {
        ExtAudioFileDispose(file);
        file = nullptr;
    }

    outputLength = 0;
    resampling = false;
}

bool TrackDecoder::seek(std::int64_t outputFrame) noexcept
{
    if (file == nullptr)
        return false;

    // ExtAudioFileSeek takes a frame in the file's own sample rate.
    const auto fileFrame = resampling
                         ? static_cast<SInt64>(std::llround(static_cast<double>(outputFrame) * fileRate / outputRate))
                         : static_cast<SInt64>(outputFrame);
    return ExtAudioFileSeek(file, fileFrame) == noErr;
}

std::size_t TrackDecoder::read(float* interleavedStereo, std::size_t maxFrames)
{
    if (file == nullptr || maxFrames == 0)
        return 0;

    auto* destination = interleavedStereo;
    if (clientChannels == 1)
    {
        monoScratch.resize(maxFrames);
        destination = monoScratch.data();
    }

    AudioBufferList buffers {};
    buffers.mNumberBuffers = 1;
    buffers.mBuffers[0].mNumberChannels = clientChannels;
    buffers.mBuffers[0].mDataByteSize = static_cast<UInt32>(maxFrames * clientChannels * sizeof(float));
    buffers.mBuffers[0].mData = destination;

    auto frames = static_cast<UInt32>(maxFrames);
    if (ExtAudioFileRead(file, &frames, &buffers) != noErr)
        return 0;

    if (clientChannels == 1)
    {
        for (UInt32 frame = 0; frame < frames; ++frame)
        {
            interleavedStereo[frame * 2] = monoScratch[frame];
            interleavedStereo[frame * 2 + 1] = monoScratch[frame];
        }
    }

    return frames;
}
} // namespace closure::detail

namespace closure
{
SourceInfo probeSource(const std::string& path)
{
    SourceInfo info;
    auto* file = detail::openFile(path, info.error);
    if (file == nullptr)
        return info;

    AudioStreamBasicDescription format {};
    auto size = static_cast<UInt32>(sizeof(format));
    auto status = ExtAudioFileGetProperty(file, kExtAudioFileProperty_FileDataFormat, &size, &format);

    SInt64 length = 0;
    if (status == noErr)
    {
        size = sizeof(length);
        status = ExtAudioFileGetProperty(file, kExtAudioFileProperty_FileLengthFrames, &size, &length);
    }

    ExtAudioFileDispose(file);

    if (status != noErr)
    {
        info.error = "Cannot read file format (" + detail::describeStatus(status) + ")";
        return info;
    }

    info.ok = true;
    info.sampleRate = format.mSampleRate;
    info.channels = static_cast<int>(format.mChannelsPerFrame);
    info.lengthFrames = length;
    info.formatID = format.mFormatID;
    info.bitDepth = detail::bitDepthOf(format);
    info.lossless = format.mFormatID == kAudioFormatLinearPCM
                 || format.mFormatID == kAudioFormatAppleLossless
                 || format.mFormatID == kAudioFormatFLAC;
    return info;
}
} // namespace closure
