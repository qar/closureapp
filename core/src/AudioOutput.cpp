#include "AudioOutput.h"
#include "TrackDecoder.h"

#include <TargetConditionals.h>

#include <cstring>

namespace closure::detail
{
bool AudioOutput::open(double sampleRate, RenderFunction render, void* context, std::string& error)
{
    close();

    AudioComponentDescription description {};
    description.componentType = kAudioUnitType_Output;
#if TARGET_OS_IPHONE
    description.componentSubType = kAudioUnitSubType_RemoteIO;
#else
    description.componentSubType = kAudioUnitSubType_DefaultOutput;
#endif
    description.componentManufacturer = kAudioUnitManufacturer_Apple;

    auto* component = AudioComponentFindNext(nullptr, &description);
    if (component == nullptr)
    {
        error = "No output audio unit";
        return false;
    }

    auto status = AudioComponentInstanceNew(component, &unit);
    if (status != noErr)
    {
        unit = nullptr;
        error = "Cannot create output unit (" + describeStatus(status) + ")";
        return false;
    }

    AudioStreamBasicDescription format {};
    format.mSampleRate = sampleRate;
    format.mFormatID = kAudioFormatLinearPCM;
    format.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    format.mBitsPerChannel = 32;
    format.mChannelsPerFrame = 2;
    format.mFramesPerPacket = 1;
    format.mBytesPerFrame = 8;
    format.mBytesPerPacket = 8;

    // 4096 frames per slice lets iOS use large buffers while the screen is locked.
    const UInt32 maximumFrames = 4096;
    renderFunction = render;
    renderContext = context;
    const AURenderCallbackStruct callback { &AudioOutput::renderCallback, this };

    status = AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0,
                                  &format, sizeof(format));
    if (status == noErr)
        status = AudioUnitSetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0,
                                      &maximumFrames, sizeof(maximumFrames));
    if (status == noErr)
        status = AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0,
                                      &callback, sizeof(callback));
    if (status == noErr)
        status = AudioUnitInitialize(unit);

    if (status != noErr)
    {
        error = "Cannot configure output unit (" + describeStatus(status) + ")";
        close();
        return false;
    }

    return true;
}

void AudioOutput::close() noexcept
{
    if (unit == nullptr)
        return;

    stop();
    AudioUnitUninitialize(unit);
    AudioComponentInstanceDispose(unit);
    unit = nullptr;
}

bool AudioOutput::start() noexcept
{
    if (unit == nullptr)
        return false;

    if (!running)
        running = AudioOutputUnitStart(unit) == noErr;

    return running;
}

void AudioOutput::stop() noexcept
{
    if (unit != nullptr && running)
        AudioOutputUnitStop(unit);

    running = false;
}

OSStatus AudioOutput::renderCallback(void* refCon,
                                     AudioUnitRenderActionFlags*,
                                     const AudioTimeStamp*,
                                     UInt32,
                                     UInt32 frames,
                                     AudioBufferList* buffers)
{
    auto& output = *static_cast<AudioOutput*>(refCon);
    if (buffers->mNumberBuffers == 1 && buffers->mBuffers[0].mNumberChannels == 2
        && buffers->mBuffers[0].mDataByteSize >= frames * 8)
    {
        output.renderFunction(output.renderContext, static_cast<float*>(buffers->mBuffers[0].mData), frames);
        return noErr;
    }

    for (UInt32 index = 0; index < buffers->mNumberBuffers; ++index)
        std::memset(buffers->mBuffers[index].mData, 0, buffers->mBuffers[index].mDataByteSize);
    return noErr;
}
} // namespace closure::detail
