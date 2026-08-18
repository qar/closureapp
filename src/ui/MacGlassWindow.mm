// AppKit before any JUCE headers — avoids Component/Point name clashes with Carbon.
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

    window.titlebarAppearsTransparent = YES;
    window.titleVisibility = NSWindowTitleHidden;
    window.styleMask |= NSWindowStyleMaskFullSizeContentView;
    window.backgroundColor = [NSColor clearColor];
    window.opaque = NO;
    window.hasShadow = YES;

    if (@available(macOS 11.0, *))
        window.titlebarSeparatorStyle = NSTitlebarSeparatorStyleNone;

    NSView* juceView = window.contentView;
    if (juceView == nil || juceView != nsView)
        return;

    // JUCE owns the window's root view. Put both JUCE and the effect view in a
    // separate container so the effect can be a real background sibling.
    NSView* container = [[NSView alloc] initWithFrame:juceView.bounds];
    container.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [window setContentView:container];

    NSVisualEffectView* effect = [[NSVisualEffectView alloc] initWithFrame:container.bounds];
    effect.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    effect.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    effect.state = NSVisualEffectStateActive;
    effect.material = NSVisualEffectMaterialHUDWindow;
    effect.wantsLayer = YES;

    [container addSubview:effect positioned:NSWindowBelow relativeTo:nil];

    juceView.frame = container.bounds;
    juceView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [container addSubview:juceView positioned:NSWindowAbove relativeTo:effect];

    [effect release];
    [container release];
}

} // namespace MacGlassWindow
