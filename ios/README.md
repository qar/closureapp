# Closure for iOS (prototype)

This folder holds the iOS app. The playback engine lives in `../core`. It is
C++17 on Apple's AudioToolbox, with no JUCE and no third-party code.

## Build

```bash
# Core tests (runs on macOS, no device needed)
cmake -S core -B core/build -DCMAKE_BUILD_TYPE=Release
cmake --build core/build -j
./core/build/closure_core_tests            # add --bench for decode speed

# Listen through the Mac's output
./core/build/closure-play a.flac b.flac

# iOS app (XcodeGen generates the project from project.yml)
cd ios && xcodegen generate && open Closure.xcodeproj
```

Set your team under Signing & Capabilities before you run it on a device.

## Getting music in

- Tap **+** to import files or folders from the Files app. The app copies them.
- In Finder, select the iPhone, open **Files › Closure**, and drop files or folders
  there. The app moves them into its library the next time it becomes active.
- "Open in Closure" from the share sheet.

The library lives in `Library/Application Support/Music` and is excluded from the
device's iCloud backup. The index (`library.json`) stores paths relative to that
folder, because the app container path can change after an update.

## Debug launch arguments

`-ClosureAutoplay` plays the first album; add `-ClosureShowNowPlaying` to open the
now playing sheet. Both exist only in Debug builds.

## What the prototype does not do yet

Product requirements, with the status on each platform, live in
[`docs/features.yml`](../docs/features.yml).

- Ogg Vorbis and files with more than two channels.
- Sample-rate switching inside a queue. The rate is chosen when a queue starts.
- Artwork, editing, playlists, search, sync.
