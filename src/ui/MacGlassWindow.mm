// AppKit before any JUCE headers avoids Component/Point name clashes with Carbon.
#import <AppKit/AppKit.h>

#include "MacGlassWindow.h"
#include <juce_gui_basics/juce_gui_basics.h>

namespace MacGlassWindow
{

void enable(juce::ComponentPeer* peer)
{
    if (peer == nullptr)
        return;

    auto* nsView = (NSView*) peer->getNativeHandle();
    if (nsView == nil)
        return;

    NSWindow* window = nsView.window;
    if (window == nil)
        return;

    // Keep the native traffic-light buttons, but let the app content paint under
    // the titlebar so there is no separate black strip above the player.
    window.titleVisibility = NSWindowTitleHidden;
    window.titlebarAppearsTransparent = YES;
    window.styleMask |= NSWindowStyleMaskFullSizeContentView;
    window.backgroundColor = [NSColor clearColor];
    window.opaque = NO;
    window.hasShadow = YES;
    nsView.frame = window.contentView.bounds;
    nsView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
}

} // namespace MacGlassWindow
