#pragma once

#include <AudioToolbox/AudioToolbox.h>

#include <cstdint>
#include <string>

namespace closure::detail
{
/**
    The system output audio unit: RemoteIO on iOS, the default output on macOS.

    The unit takes interleaved stereo float at the given rate. On iOS the platform
    layer sets the AVAudioSession rate first, so this rate equals the hardware rate
    and the system does not convert it again.
*/
class AudioOutput final
{
public:
    using RenderFunction = void (*)(void* context, float* interleavedStereo, std::uint32_t frames) noexcept;

    AudioOutput() = default;
    ~AudioOutput() { close(); }

    AudioOutput(const AudioOutput&) = delete;
    AudioOutput& operator=(const AudioOutput&) = delete;

    bool open(double sampleRate, RenderFunction render, void* context, std::string& error);
    void close() noexcept;
    bool start() noexcept;
    void stop() noexcept;
    bool isOpen() const noexcept { return unit != nullptr; }

private:
    static OSStatus renderCallback(void* refCon,
                                   AudioUnitRenderActionFlags* flags,
                                   const AudioTimeStamp* timeStamp,
                                   UInt32 bus,
                                   UInt32 frames,
                                   AudioBufferList* buffers);

    AudioComponentInstance unit = nullptr;
    RenderFunction renderFunction = nullptr;
    void* renderContext = nullptr;
    bool running = false;
};
} // namespace closure::detail
