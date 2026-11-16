// Plays files through the real output device: closure-play file1 [file2 ...]
// Prints the engine status every second, so a listening test can check gapless
// transitions and the underrun count.

#include "closure/PlaybackEngine.h"

#include <chrono>
#include <cstdio>
#include <string>
#include <thread>
#include <vector>

int main(int argc, char** argv)
{
    if (argc < 2)
    {
        std::fprintf(stderr, "usage: closure-play <file> [file ...]\n");
        return 2;
    }

    std::vector<std::string> paths(argv + 1, argv + argc);
    const auto info = closure::probeSource(paths.front());
    if (!info.ok)
    {
        std::fprintf(stderr, "cannot open %s: %s\n", paths.front().c_str(), info.error.c_str());
        return 1;
    }

    closure::PlaybackEngine engine;
    engine.setRepeatMode(closure::RepeatMode::off);
    engine.setEventHandler([](const closure::EngineEvent& event)
    {
        const char* names[] = { "track", "ended", "error" };
        std::printf("event: %s %d %s\n", names[static_cast<int>(event.type)], event.trackIndex, event.message.c_str());
    });

    std::string error;
    if (!engine.setOutputSampleRate(info.sampleRate, &error))
    {
        std::fprintf(stderr, "output: %s\n", error.c_str());
        return 1;
    }

    engine.setQueue(paths, 0);
    if (!engine.play(&error))
    {
        std::fprintf(stderr, "play: %s\n", error.c_str());
        return 1;
    }

    for (;;)
    {
        std::this_thread::sleep_for(std::chrono::seconds(1));
        const auto status = engine.status();
        std::printf("track %d/%d  %6.1f / %6.1f s  out %.0f Hz  src %.0f Hz%s  buffer %.1f s  underruns %llu\n",
                    status.trackIndex + 1, status.trackCount, status.positionSeconds, status.durationSeconds,
                    status.outputSampleRate, status.sourceSampleRate, status.resampling ? " (SRC)" : "",
                    status.bufferedSeconds, static_cast<unsigned long long>(status.underruns));
        std::fflush(stdout);
        if (status.ended)
            return 0;
    }
}
