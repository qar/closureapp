#include "DefaultOutputFollower.h"

#if JUCE_MAC
#include <CoreAudio/CoreAudio.h>
#include <dispatch/dispatch.h>

#include <atomic>

namespace
{
const AudioObjectPropertyAddress defaultOutputAddress {
    kAudioHardwarePropertyDefaultOutputDevice,
    kAudioObjectPropertyScopeGlobal,
    0 // main element (kAudioObjectPropertyElementMain needs the macOS 12 SDK names)
};
}

struct DefaultOutputFollower::Listener
{
    explicit Listener(DefaultOutputFollower& owner)
    {
        // The block runs on the main queue, which is JUCE's message thread on macOS.
        // `alive` stops a block that was already queued from touching a destroyed owner.
        auto aliveFlag = alive;
        auto* ownerPtr = &owner;
        block = Block_copy(^(UInt32, const AudioObjectPropertyAddress*) {
            if (aliveFlag->load())
                ownerPtr->followDefaultOutput();
        });

        registered = AudioObjectAddPropertyListenerBlock(kAudioObjectSystemObject,
                                                         &defaultOutputAddress,
                                                         dispatch_get_main_queue(),
                                                         block) == noErr;
    }

    ~Listener()
    {
        alive->store(false);

        if (registered)
            AudioObjectRemovePropertyListenerBlock(kAudioObjectSystemObject,
                                                   &defaultOutputAddress,
                                                   dispatch_get_main_queue(),
                                                   block);
        Block_release(block);
    }

    std::shared_ptr<std::atomic<bool>> alive = std::make_shared<std::atomic<bool>>(true);
    AudioObjectPropertyListenerBlock block = nullptr;
    bool registered = false;
};
#else
struct DefaultOutputFollower::Listener
{
    explicit Listener(DefaultOutputFollower&) {}
};
#endif

DefaultOutputFollower::DefaultOutputFollower(juce::AudioDeviceManager& manager)
    : deviceManager(manager),
      listener(std::make_unique<Listener>(*this))
{
    if (auto* current = deviceManager.getCurrentAudioDevice())
        activeDeviceName = current->getName();
}

DefaultOutputFollower::~DefaultOutputFollower() = default;

void DefaultOutputFollower::followDefaultOutput()
{
    JUCE_ASSERT_MESSAGE_THREAD

    auto* type = deviceManager.getCurrentDeviceTypeObject();
    if (type == nullptr)
        return;

    // The new default can be a device that just appeared, so refresh the list first.
    type->scanForDevices();
    const auto names = type->getDeviceNames(false);

    // Track the device ourselves: JUCE may already have reopened a fallback device
    // by the time this runs, so its current device does not tell us what was lost.
    if (activeDeviceName.isNotEmpty() && !names.contains(activeDeviceName))
    {
        activeDeviceName.clear();
        if (onOutputDeviceLost)
            onOutputDeviceLost();
    }

    const auto defaultIndex = type->getDefaultDeviceIndex(false);
    if (!juce::isPositiveAndBelow(defaultIndex, names.size()))
        return;

    const auto& defaultName = names[defaultIndex];
    auto* current = deviceManager.getCurrentAudioDevice();
    if (current == nullptr || current->getName() != defaultName)
    {
        auto setup = deviceManager.getAudioDeviceSetup();
        setup.outputDeviceName = defaultName;
        const auto error = deviceManager.setAudioDeviceSetup(setup, true);
        if (error.isNotEmpty())
            DBG("DefaultOutputFollower: could not open " << defaultName << ": " << error);
    }

    if (auto* now = deviceManager.getCurrentAudioDevice())
        activeDeviceName = now->getName();
}
