#pragma once

namespace juce { class ComponentPeer; }

#if JUCE_MAC || defined(__APPLE__)
namespace MacGlassWindow
{
/** Attach NSVisualEffectView frosted glass behind the JUCE content. */
void enable(juce::ComponentPeer* peer);
}
#endif
