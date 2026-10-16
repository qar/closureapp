#import <AppKit/AppKit.h>
#import <Sparkle/Sparkle.h>

#include "MacUpdater.h"

namespace
{
SPUStandardUpdaterController* updaterController = nil;
NSMenuItem* checkUpdatesItem = nil;
}

namespace MacUpdater
{
void start()
{
    if (updaterController != nil)
        return;

    updaterController = [[SPUStandardUpdaterController alloc]
        initWithUpdaterDelegate:nil userDriverDelegate:nil];

    NSMenu* appMenu = [[[NSApp mainMenu] itemAtIndex:0] submenu];
    if (appMenu == nil)
        return;

    checkUpdatesItem = [[NSMenuItem alloc] initWithTitle:@"Check for Updates..."
                                               action:@selector(checkForUpdates:)
                                        keyEquivalent:@""];
    [checkUpdatesItem setTarget:updaterController];
    [appMenu insertItem:checkUpdatesItem atIndex:1];
}

void stop()
{
    if (checkUpdatesItem != nil)
    {
        [[checkUpdatesItem menu] removeItem:checkUpdatesItem];
        [checkUpdatesItem release];
        checkUpdatesItem = nil;
    }

    [updaterController release];
    updaterController = nil;
}
}
