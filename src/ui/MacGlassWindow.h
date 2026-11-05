#pragma once

namespace juce { class ComponentPeer; }

#if JUCE_MAC || defined(__APPLE__)
namespace MacGlassWindow
{
/** Make the native titlebar transparent while retaining macOS window controls,
    and put a native behind-window blur under the JUCE content. */
void enable(juce::ComponentPeer* peer);
}
#endif
