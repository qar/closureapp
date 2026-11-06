#pragma once

#include <juce_audio_devices/juce_audio_devices.h>

#include <functional>
#include <memory>

/** Keeps an AudioDeviceManager on the system default output device.

    JUCE opens a concrete device and only falls back to the default when that device
    disappears. It does not follow later default-output changes. Example: headphones
    are unplugged (JUCE falls back to the speakers), then plugged in again (macOS
    makes the headphones the default, but JUCE stays on the speakers, which the
    headphone jack mutes). Playback keeps running with no audible output.

    Closure has no output-device picker, so the system default is always the target.
    On macOS this listens for default-output changes; other platforms do nothing yet.

    When the device in use disappears (headphones unplugged, Bluetooth disconnected),
    onOutputDeviceLost is called before switching, so playback can pause instead of
    continuing on the speakers. A returning device does not resume anything.
*/
class DefaultOutputFollower final
{
public:
    explicit DefaultOutputFollower(juce::AudioDeviceManager& manager);
    ~DefaultOutputFollower();

    /** Reopen the system default output if the manager uses a different device.
        Must be called on the message thread. */
    void followDefaultOutput();

    /** Called on the message thread when the output device in use has disappeared. */
    std::function<void()> onOutputDeviceLost;

private:
    struct Listener;

    juce::AudioDeviceManager& deviceManager;
    juce::String activeDeviceName;
    std::unique_ptr<Listener> listener;

    JUCE_DECLARE_NON_COPYABLE(DefaultOutputFollower)
};
