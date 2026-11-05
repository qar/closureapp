// AppKit before any JUCE headers avoids Component/Point name clashes with Carbon.
#import <AppKit/AppKit.h>

#include "MacGlassWindow.h"
#include <juce_gui_basics/juce_gui_basics.h>

namespace MacGlassWindow
{

namespace
{
/** Put a behind-window blur under the JUCE view.

    JUCE installs its NSView as the window content view. A subview always draws
    above its superview, so the blur view must become the content view and the
    JUCE view moves inside it. JUCE keeps its own retain on the view and reads
    bounds relative to the superview, so this reparenting is safe.
*/
void installVisualEffectView(NSWindow* window, NSView* juceView)
{
    if ([window.contentView isKindOfClass:[NSVisualEffectView class]])
        return;

    const auto frame = window.contentView.frame;
    auto* glass = [[NSVisualEffectView alloc] initWithFrame:frame];
    glass.material = NSVisualEffectMaterialUnderWindowBackground;
    glass.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    glass.state = NSVisualEffectStateFollowsWindowActiveState;
    // The UI palette is light only, so keep the blur light in Dark Mode too.
    glass.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
    glass.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

    [juceView retain];
    window.contentView = glass;
    [glass addSubview:juceView];
    juceView.frame = glass.bounds;
    juceView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [window makeFirstResponder:juceView];
    [juceView release];
    [glass release];
}
} // namespace

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

    installVisualEffectView(window, nsView);
}

} // namespace MacGlassWindow
