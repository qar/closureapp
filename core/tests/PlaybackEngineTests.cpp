// Closure core tests. Each test writes its own audio files with the system encoders,
// plays them through PlaybackEngine in offline mode and checks the output samples.

#include "closure/PlaybackEngine.h"

#include <AudioToolbox/AudioToolbox.h>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstdio>
#include <cstdlib>
#include <functional>
#include <mutex>
#include <string>
#include <thread>
#include <unistd.h>
#include <vector>

using namespace closure;

namespace
{
int failures = 0;

bool check(bool condition, const std::string& message)
{
    if (!condition)
    {
        std::fprintf(stderr, "  FAIL: %s\n", message.c_str());
        ++failures;
    }

    return condition;
}

std::string tempDirectory()
{
    static const std::string directory = []
    {
        char pattern[] = "/tmp/closure-core-tests-XXXXXX";
        const char* created = mkdtemp(pattern);
        return std::string(created != nullptr ? created : "/tmp");
    }();
    return directory;
}

std::string tempPath(const std::string& name)
{
    return tempDirectory() + "/" + name;
}

AudioStreamBasicDescription floatFormat(double rate, UInt32 channels)
{
    AudioStreamBasicDescription format {};
    format.mSampleRate = rate;
    format.mFormatID = kAudioFormatLinearPCM;
    format.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    format.mBitsPerChannel = 32;
    format.mChannelsPerFrame = channels;
    format.mFramesPerPacket = 1;
    format.mBytesPerFrame = 4 * channels;
    format.mBytesPerPacket = format.mBytesPerFrame;
    return format;
}

AudioStreamBasicDescription encodedFormat(UInt32 formatID, UInt32 flags, double rate, UInt32 channels)
{
    AudioStreamBasicDescription format {};
    format.mSampleRate = rate;
    format.mFormatID = formatID;
    format.mFormatFlags = flags;
    format.mChannelsPerFrame = channels;
    auto size = static_cast<UInt32>(sizeof(format));
    AudioFormatGetProperty(kAudioFormatProperty_FormatInfo, 0, nullptr, &size, &format);
    return format;
}

/** Writes interleaved float samples through ExtAudioFile, which encodes them. */
bool writeFile(const std::string& path,
               AudioFileTypeID type,
               const AudioStreamBasicDescription& fileFormat,
               const std::vector<float>& interleaved)
{
    const auto channels = fileFormat.mChannelsPerFrame;
    const auto url = CFURLCreateFromFileSystemRepresentation(nullptr,
                                                             reinterpret_cast<const UInt8*>(path.data()),
                                                             static_cast<CFIndex>(path.size()), false);
    ExtAudioFileRef file = nullptr;
    auto status = ExtAudioFileCreateWithURL(url, type, &fileFormat, nullptr, kAudioFileFlags_EraseFile, &file);
    CFRelease(url);
    if (status != noErr)
    {
        std::fprintf(stderr, "  cannot create %s (%d)\n", path.c_str(), static_cast<int>(status));
        return false;
    }

    const auto client = floatFormat(fileFormat.mSampleRate, channels);
    status = ExtAudioFileSetProperty(file, kExtAudioFileProperty_ClientDataFormat, sizeof(client), &client);

    const auto frames = static_cast<UInt32>(interleaved.size() / channels);
    AudioBufferList buffers {};
    buffers.mNumberBuffers = 1;
    buffers.mBuffers[0].mNumberChannels = channels;
    buffers.mBuffers[0].mDataByteSize = static_cast<UInt32>(interleaved.size() * sizeof(float));
    buffers.mBuffers[0].mData = const_cast<float*>(interleaved.data());
    if (status == noErr)
        status = ExtAudioFileWrite(file, frames, &buffers);

    ExtAudioFileDispose(file);
    if (status != noErr)
        std::fprintf(stderr, "  cannot write %s (%d)\n", path.c_str(), static_cast<int>(status));
    return status == noErr;
}

std::string writeFloatWav(const std::string& name, double rate, UInt32 channels, const std::vector<float>& samples)
{
    const auto path = tempPath(name);
    return writeFile(path, kAudioFileWAVEType, floatFormat(rate, channels), samples) ? path : std::string();
}

/** Stereo track with a constant value on the left and its negation on the right. */
std::vector<float> constantStereo(std::size_t frames, float value)
{
    std::vector<float> samples(frames * 2);
    for (std::size_t frame = 0; frame < frames; ++frame)
    {
        samples[frame * 2] = value;
        samples[frame * 2 + 1] = -value;
    }
    return samples;
}

/** Sample n is n / 2^20, exact in float32 and unique per frame. */
std::vector<float> rampMono(std::size_t frames)
{
    std::vector<float> samples(frames);
    for (std::size_t frame = 0; frame < frames; ++frame)
        samples[frame] = static_cast<float>(frame) / 1048576.0f;
    return samples;
}

/** Values that 24-bit integer formats store exactly. */
std::vector<float> random24BitStereo(std::size_t frames, unsigned seed)
{
    std::vector<float> samples(frames * 2);
    auto state = seed;
    for (auto& sample : samples)
    {
        state = state * 1664525u + 1013904223u;
        const auto value = static_cast<int>(state >> 8) - (1 << 23);
        sample = static_cast<float>(value) / 8388608.0f;
    }
    return samples;
}

std::vector<float> sineStereo(std::size_t frames, double rate, double frequency, float amplitude)
{
    std::vector<float> samples(frames * 2);
    for (std::size_t frame = 0; frame < frames; ++frame)
    {
        const auto value = amplitude * static_cast<float>(std::sin(2.0 * M_PI * frequency * frame / rate));
        samples[frame * 2] = value;
        samples[frame * 2 + 1] = value;
    }
    return samples;
}

EngineOptions offlineOptions()
{
    EngineOptions options;
    options.outputMode = OutputMode::offline;
    options.declick = false;
    options.bufferSeconds = 1.0; // Small ring, so tests cross its wrap point many times.
    return options;
}

std::vector<float> renderAll(PlaybackEngine& engine, std::size_t maxFrames, std::size_t& rendered)
{
    std::vector<float> output(maxFrames * 2, 7.0f);
    rendered = engine.renderOffline(output.data(), maxFrames);
    return output;
}

bool segmentEquals(const std::vector<float>& output, std::size_t start, std::size_t frames, float left, float right)
{
    for (std::size_t frame = start; frame < start + frames; ++frame)
    {
        if (output[frame * 2] != left || output[frame * 2 + 1] != right)
        {
            std::fprintf(stderr, "  frame %zu: got (%g, %g), want (%g, %g)\n",
                         frame, output[frame * 2], output[frame * 2 + 1], left, right);
            return false;
        }
    }
    return true;
}

/** Collects engine events, which arrive on the decoder thread. */
struct EventLog
{
    std::mutex mutex;
    std::condition_variable changed;
    std::vector<EngineEvent> events;

    void attach(PlaybackEngine& engine)
    {
        engine.setEventHandler([this](const EngineEvent& event)
        {
            std::lock_guard<std::mutex> lock(mutex);
            events.push_back(event);
            changed.notify_all();
        });
    }

    bool waitFor(EngineEvent::Type type)
    {
        std::unique_lock<std::mutex> lock(mutex);
        return changed.wait_for(lock, std::chrono::seconds(5), [this, type]
        {
            for (const auto& event : events)
                if (event.type == type)
                    return true;
            return false;
        });
    }

    std::vector<int> trackChanges()
    {
        std::lock_guard<std::mutex> lock(mutex);
        std::vector<int> indices;
        for (const auto& event : events)
            if (event.type == EngineEvent::Type::trackChanged)
                indices.push_back(event.trackIndex);
        return indices;
    }

    bool waitForTrackChanges(std::size_t count)
    {
        std::unique_lock<std::mutex> lock(mutex);
        return changed.wait_for(lock, std::chrono::seconds(5), [this, count]
        {
            return std::count_if(events.begin(), events.end(), [](const EngineEvent& event)
            {
                return event.type == EngineEvent::Type::trackChanged;
            }) >= static_cast<std::ptrdiff_t>(count);
        });
    }
};

// -------------------------------------------------------------------------------------

void testGaplessConcatenation()
{
    const std::size_t lengths[] = { 1000, 44107, 3001 };
    const float values[] = { 0.1f, 0.2f, 0.3f };
    std::vector<std::string> paths;
    for (int track = 0; track < 3; ++track)
        paths.push_back(writeFloatWav("gapless" + std::to_string(track) + ".wav", 44100.0, 2,
                                      constantStereo(lengths[track], values[track])));

    EventLog log; // Declared first: it must outlive the engine's decoder thread.
    PlaybackEngine engine(offlineOptions());
    log.attach(engine);
    engine.setRepeatMode(RepeatMode::off);
    check(engine.setOutputSampleRate(44100.0), "set output rate");
    engine.setQueue(paths, 0);
    check(engine.play(), "play");

    const auto total = lengths[0] + lengths[1] + lengths[2];
    std::size_t rendered = 0;
    const auto output = renderAll(engine, total + 500, rendered);

    check(rendered == total, "rendered " + std::to_string(rendered) + " frames, want " + std::to_string(total));
    std::size_t start = 0;
    for (int track = 0; track < 3; ++track)
    {
        check(segmentEquals(output, start, lengths[track], values[track], -values[track]),
              "track " + std::to_string(track) + " samples are exact and gapless");
        start += lengths[track];
    }
    check(segmentEquals(output, total, 500, 0.0f, 0.0f), "silence after the end");

    check(log.waitFor(EngineEvent::Type::ended), "ended event");
    const auto status = engine.status();
    check(status.ended && !status.playing, "status reports ended");
    check(log.trackChanges() == std::vector<int>({ 0, 1, 2 }), "track change events 0, 1, 2");
    check(status.underruns == 0, "no underruns");
}

void testLosslessBitExact()
{
    const double rate = 96000.0;
    const std::size_t frames = 50000;
    const auto samples = random24BitStereo(frames, 42);

    struct Case
    {
        const char* name;
        AudioFileTypeID type;
        UInt32 formatID;
    };

    const Case cases[] = {
        { "lossless.flac", kAudioFileFLACType, kAudioFormatFLAC },
        { "lossless.m4a", kAudioFileM4AType, kAudioFormatAppleLossless },
    };

    for (const auto& item : cases)
    {
        const auto path = tempPath(item.name);
        if (!check(writeFile(path, item.type, encodedFormat(item.formatID, 3, rate, 2), samples),
                   std::string("encode ") + item.name))
            continue;

        const auto info = probeSource(path);
        check(info.ok && info.lossless && info.bitDepth == 24 && info.sampleRate == rate
                  && info.lengthFrames == static_cast<std::int64_t>(frames),
              std::string(item.name) + " probe: 24-bit, 96 kHz, exact length");

        PlaybackEngine engine(offlineOptions());
        engine.setRepeatMode(RepeatMode::off);
        engine.setOutputSampleRate(rate);
        engine.setQueue({ path });
        engine.play();
        std::size_t rendered = 0;
        const auto output = renderAll(engine, frames + 100, rendered);

        check(rendered == frames, std::string(item.name) + " length");
        bool exact = true;
        for (std::size_t index = 0; index < frames * 2 && exact; ++index)
            exact = output[index] == samples[index];
        check(exact, std::string(item.name) + " decodes bit exact");
        check(!engine.status().resampling, std::string(item.name) + " is not resampled");
    }
}

void testMonoPlaysOnBothChannels()
{
    const auto samples = rampMono(5000);
    const auto path = writeFloatWav("mono.wav", 44100.0, 1, samples);

    PlaybackEngine engine(offlineOptions());
    engine.setRepeatMode(RepeatMode::off);
    engine.setOutputSampleRate(44100.0);
    engine.setQueue({ path });
    engine.play();
    std::size_t rendered = 0;
    const auto output = renderAll(engine, 6000, rendered);

    bool same = rendered == samples.size();
    for (std::size_t frame = 0; frame < samples.size() && same; ++frame)
        same = output[frame * 2] == samples[frame] && output[frame * 2 + 1] == samples[frame];
    check(same, "mono samples appear unchanged on both channels");
}

void testSeekIsFrameAccurate()
{
    const std::size_t frames = 200000;
    const auto path = writeFloatWav("ramp.wav", 44100.0, 1, rampMono(frames));

    PlaybackEngine engine(offlineOptions());
    engine.setRepeatMode(RepeatMode::off);
    engine.setOutputSampleRate(44100.0);
    engine.setQueue({ path });

    // Seek while stopped.
    engine.seek(1.0);
    check(std::abs(engine.status().positionSeconds - 1.0) < 1e-9, "position after seek while stopped");
    engine.play();
    std::vector<float> block(1000 * 2);
    engine.renderOffline(block.data(), 1000);
    check(block[0] == 44100.0f / 1048576.0f, "first frame after seek is frame 44100");
    check(block[999 * 2] == 45099.0f / 1048576.0f, "frames continue in order");

    // Seek while playing.
    engine.seek(3.0);
    engine.renderOffline(block.data(), 10);
    check(block[0] == 132300.0f / 1048576.0f, "first frame after seek while playing is frame 132300");
    check(std::abs(engine.status().positionSeconds - (132310.0 / 44100.0)) < 1e-9, "position follows rendering");
}

void testNavigation()
{
    std::vector<std::string> paths;
    for (int track = 0; track < 3; ++track)
        paths.push_back(writeFloatWav("nav" + std::to_string(track) + ".wav", 44100.0, 2,
                                      constantStereo(44100 * 5, 0.1f * static_cast<float>(track + 1))));

    PlaybackEngine engine(offlineOptions());
    engine.setRepeatMode(RepeatMode::off);
    engine.setOutputSampleRate(44100.0);
    engine.setQueue(paths, 0);

    engine.playIndex(2);
    check(engine.status().trackIndex == 2 && engine.status().playing, "playIndex(2) plays track 2");

    std::vector<float> block(2 * 2);
    engine.renderOffline(block.data(), 2);
    check(block[0] == 0.3f, "track 2 audio after playIndex");

    engine.previous();
    check(engine.status().trackIndex == 1, "previous goes to track 1 near the start");

    std::vector<float> longBlock(44100 * 4 * 2);
    engine.renderOffline(longBlock.data(), 44100 * 4);
    engine.previous();
    check(engine.status().trackIndex == 1 && engine.status().positionSeconds < 0.01,
          "previous after 4 s restarts the same track");

    engine.next();
    engine.next();
    check(engine.status().trackIndex == 2, "next stops at the last track when repeat is off");
}

void testRepeatModes()
{
    const auto first = writeFloatWav("repeatA.wav", 44100.0, 2, constantStereo(3000, 0.25f));
    const auto second = writeFloatWav("repeatB.wav", 44100.0, 2, constantStereo(5000, 0.5f));

    {
        PlaybackEngine engine(offlineOptions());
        engine.setRepeatMode(RepeatMode::all);
        engine.setOutputSampleRate(44100.0);
        engine.setQueue({ first, second });
        engine.play();
        std::size_t rendered = 0;
        const auto output = renderAll(engine, 16000, rendered);
        check(rendered == 16000, "repeat all keeps playing");
        check(segmentEquals(output, 0, 3000, 0.25f, -0.25f) && segmentEquals(output, 3000, 5000, 0.5f, -0.5f)
                  && segmentEquals(output, 8000, 3000, 0.25f, -0.25f)
                  && segmentEquals(output, 11000, 5000, 0.5f, -0.5f),
              "repeat all loops the queue without gaps");
    }

    {
        PlaybackEngine engine(offlineOptions());
        engine.setRepeatMode(RepeatMode::one);
        engine.setOutputSampleRate(44100.0);
        engine.setQueue({ first, second });
        engine.play();
        std::size_t rendered = 0;
        const auto output = renderAll(engine, 9000, rendered);
        check(rendered == 9000 && segmentEquals(output, 0, 9000, 0.25f, -0.25f), "repeat one loops track 0");
        check(engine.status().trackIndex == 0, "repeat one stays on track 0");
    }
}

void testReplaceQueueKeepsTheCurrentTrackPlaying()
{
    // A long first track, so the change lands mid-track; a short one, so it lands
    // after the next track is already decoded.
    for (const std::size_t firstLength : { std::size_t(400000), std::size_t(3000) })
    {
        const auto a = writeFloatWav("replaceA" + std::to_string(firstLength) + ".wav", 44100.0, 2,
                                     constantStereo(firstLength, 0.1f));
        const auto b = writeFloatWav("replaceB.wav", 44100.0, 2, constantStereo(5000, 0.2f));
        const auto c = writeFloatWav("replaceC.wav", 44100.0, 2, constantStereo(7000, 0.3f));

        EventLog log;
        PlaybackEngine engine(offlineOptions());
        log.attach(engine);
        engine.setRepeatMode(RepeatMode::off);
        engine.setOutputSampleRate(44100.0);
        engine.setQueue({ a, b, c }, 0);
        engine.play();

        std::size_t rendered = 0;
        auto head = renderAll(engine, 1000, rendered);
        // Wait until the decoder has run ahead as far as it will.
        std::this_thread::sleep_for(std::chrono::milliseconds(200));
        engine.replaceQueue({ c, a, b }, 1);
        check(engine.status().trackIndex == 1, "the current track has its new index");

        std::size_t restRendered = 0;
        const auto rest = renderAll(engine, firstLength - 1000 + 5000 + 1000, restRendered);
        const auto label = " (first track " + std::to_string(firstLength) + " frames)";
        check(rendered + restRendered == firstLength + 5000, "the current track plays to its end, then b" + label);
        check(segmentEquals(rest, 0, firstLength - 1000, 0.1f, -0.1f), "no break in the current track" + label);
        check(segmentEquals(rest, firstLength - 1000, 5000, 0.2f, -0.2f), "b follows in the new order" + label);
        // Renumbering the track being heard is not a track change.
        check(log.waitForTrackChanges(2), "track changes arrive" + label);
        const auto changes = log.trackChanges();
        std::string seen;
        for (const auto index : changes)
            seen += std::to_string(index) + " ";
        check(changes == std::vector<int>({ 0, 2 }), "events: 0, then b at its new index; got " + seen + label);
    }
}

void testResampling()
{
    const double sourceRate = 48000.0;
    const double outputRate = 44100.0;
    const std::size_t frames = 48000;
    const auto path = writeFloatWav("sine48k.wav", sourceRate, 2, sineStereo(frames, sourceRate, 1000.0, 0.5f));

    PlaybackEngine engine(offlineOptions());
    engine.setRepeatMode(RepeatMode::off);
    engine.setOutputSampleRate(outputRate);
    engine.setQueue({ path });
    engine.play();
    check(engine.status().resampling && engine.status().sourceSampleRate == sourceRate, "status reports resampling");

    std::size_t rendered = 0;
    const auto output = renderAll(engine, 50000, rendered);
    check(std::llabs(static_cast<long long>(rendered) - 44100) <= 2,
          "resampled length " + std::to_string(rendered) + " is about 44100");

    // Measure frequency and level away from the filter's start-up region.
    int crossings = 0;
    float peak = 0.0f;
    const std::size_t from = 2000, to = 42000;
    for (std::size_t frame = from + 1; frame < to; ++frame)
    {
        const auto previous = output[(frame - 1) * 2];
        const auto current = output[frame * 2];
        if (previous < 0.0f && current >= 0.0f)
            ++crossings;
        peak = std::max(peak, std::abs(current));
    }

    const auto frequency = crossings * outputRate / static_cast<double>(to - from);
    check(std::abs(frequency - 1000.0) < 5.0, "resampled tone is 1 kHz (measured " + std::to_string(frequency) + ")");
    check(std::abs(peak - 0.5f) < 0.005f, "resampled level is kept (peak " + std::to_string(peak) + ")");
}

void testAacPrimingIsTrimmed()
{
    const double rate = 44100.0;
    const std::size_t frames = 44100;
    const auto path = tempPath("tone.m4a");
    if (!check(writeFile(path, kAudioFileM4AType, encodedFormat(kAudioFormatMPEG4AAC, 0, rate, 2),
                         sineStereo(frames, rate, 440.0, 0.5f)),
               "encode AAC"))
        return;

    const auto info = probeSource(path);
    check(info.ok && !info.lossless, "AAC probe");
    check(info.lengthFrames == static_cast<std::int64_t>(frames),
          "AAC length without priming and padding (got " + std::to_string(info.lengthFrames) + ")");

    PlaybackEngine engine(offlineOptions());
    engine.setRepeatMode(RepeatMode::off);
    engine.setOutputSampleRate(rate);
    engine.setQueue({ path });
    engine.play();
    std::size_t rendered = 0;
    renderAll(engine, frames + 5000, rendered);
    check(rendered == frames, "AAC renders exactly the encoded frames (got " + std::to_string(rendered) + ")");
}

void testMissingFileIsSkipped()
{
    const auto good = writeFloatWav("good.wav", 44100.0, 2, constantStereo(2000, 0.4f));

    EventLog log; // Declared first: it must outlive the engine's decoder thread.
    PlaybackEngine engine(offlineOptions());
    log.attach(engine);
    engine.setRepeatMode(RepeatMode::off);
    engine.setOutputSampleRate(44100.0);
    engine.setQueue({ good, tempPath("missing.flac"), good });
    engine.play();
    std::size_t rendered = 0;
    const auto output = renderAll(engine, 6000, rendered);
    check(rendered == 4000 && segmentEquals(output, 0, 4000, 0.4f, -0.4f), "missing file is skipped without a gap");
    check(log.waitFor(EngineEvent::Type::error), "error event for the missing file");
}

void benchmarkDecoding()
{
    const double rate = 96000.0;
    const std::size_t frames = static_cast<std::size_t>(rate * 60);
    const auto path = tempPath("bench.flac");
    if (!writeFile(path, kAudioFileFLACType, encodedFormat(kAudioFormatFLAC, 3, rate, 2), random24BitStereo(frames, 7)))
        return;

    for (const double outputRate : { 96000.0, 48000.0 })
    {
        PlaybackEngine engine(offlineOptions());
        engine.setRepeatMode(RepeatMode::off);
        engine.setOutputSampleRate(outputRate);
        engine.setQueue({ path });
        engine.play();

        std::vector<float> output(static_cast<std::size_t>(outputRate) * 61 * 2);
        const auto started = std::chrono::steady_clock::now();
        engine.renderOffline(output.data(), output.size() / 2);
        const auto elapsed = std::chrono::duration<double>(std::chrono::steady_clock::now() - started).count();
        std::printf("  bench: 60 s FLAC 24/96 -> %.0f Hz in %.3f s (%.0fx real time)\n",
                    outputRate, elapsed, 60.0 / elapsed);
    }
}

void run(const char* name, const std::function<void()>& test)
{
    const auto before = failures;
    std::printf("%s\n", name);
    test();
    std::printf("  %s\n", failures == before ? "ok" : "FAILED");
}
} // namespace

int main(int argc, char** argv)
{
    const bool bench = argc > 1 && std::string(argv[1]) == "--bench";

    run("gapless concatenation", testGaplessConcatenation);
    run("lossless FLAC and ALAC are bit exact", testLosslessBitExact);
    run("mono plays on both channels", testMonoPlaysOnBothChannels);
    run("seek is frame accurate", testSeekIsFrameAccurate);
    run("navigation", testNavigation);
    run("repeat modes", testRepeatModes);
    run("replace queue keeps the current track playing", testReplaceQueueKeepsTheCurrentTrackPlaying);
    run("high quality resampling", testResampling);
    run("AAC priming is trimmed", testAacPrimingIsTrimmed);
    run("missing file is skipped", testMissingFileIsSkipped);
    if (bench)
        run("decode benchmark", benchmarkDecoding);

    std::printf(failures == 0 ? "\nAll tests passed\n" : "\n%d check(s) failed\n", failures);
    return failures == 0 ? EXIT_SUCCESS : EXIT_FAILURE;
}
