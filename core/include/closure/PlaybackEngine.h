#pragma once

#include <cstdint>
#include <functional>
#include <memory>
#include <string>
#include <vector>

namespace closure
{
/** Facts about one audio file, read without decoding it. */
struct SourceInfo
{
    bool ok = false;
    std::string error;
    double sampleRate = 0.0;
    int channels = 0;
    std::int64_t lengthFrames = 0; // In the file's own sample rate.
    std::uint32_t formatID = 0;    // Core Audio format ID, e.g. 'flac', 'alac', 'aac '.
    int bitDepth = 0;              // 0 when the format has no fixed bit depth (lossy).
    bool lossless = false;

    double durationSeconds() const { return sampleRate > 0.0 ? static_cast<double>(lengthFrames) / sampleRate : 0.0; }
};

SourceInfo probeSource(const std::string& path);

enum class RepeatMode
{
    off,
    all,
    one
};

enum class OutputMode
{
    device,  // Real-time output through the system output audio unit.
    offline  // No device. Tests pull audio with renderOffline().
};

struct EngineOptions
{
    OutputMode outputMode = OutputMode::device;
    /** Short gain ramps on start, pause and jumps, so cuts do not click. */
    bool declick = true;
    /** Decoded audio held ahead of the output. The decoder refills in bursts when half
        of it has played, so the CPU can sleep between bursts. */
    double bufferSeconds = 4.0;
};

struct EngineStatus
{
    bool playing = false;
    bool ended = false;
    int trackIndex = -1;
    int trackCount = 0;
    double positionSeconds = 0.0;
    double durationSeconds = 0.0;
    double outputSampleRate = 0.0;
    double sourceSampleRate = 0.0;
    bool resampling = false; // True when this app converts the sample rate.
    double bufferedSeconds = 0.0;
    std::uint64_t underruns = 0;
};

struct EngineEvent
{
    enum class Type
    {
        trackChanged,
        ended,
        error
    };

    Type type = Type::trackChanged;
    int trackIndex = -1;
    std::string message;
};

/**
    Gapless local-file player.

    A decoder thread reads files with ExtAudioFile into one lock-free ring of
    interleaved stereo float frames. Track changes are written back to back into
    that ring, so they are sample exact. The real-time render callback only copies
    from the ring: it never locks, allocates or touches files.

    The digital path is unity gain. Volume belongs to the system. The app converts
    the sample rate only when a file's rate differs from the output rate; the
    platform layer should first try to make them equal.

    Control methods are for one thread (normally the main thread). Event handlers
    run on the decoder thread.
*/
class PlaybackEngine final
{
public:
    using EventHandler = std::function<void(const EngineEvent&)>;

    explicit PlaybackEngine(EngineOptions options = {});
    ~PlaybackEngine();

    PlaybackEngine(const PlaybackEngine&) = delete;
    PlaybackEngine& operator=(const PlaybackEngine&) = delete;

    /** Opens the output at this rate. Call before play(), and again when the
        hardware rate changes. Playback continues from the same position. */
    bool setOutputSampleRate(double sampleRate, std::string* error = nullptr);

    /** Drops the output unit, e.g. after the system reset its media services. The next
        setOutputSampleRate() builds a new one and resumes if playback was on. */
    void resetOutput();

    void setQueue(std::vector<std::string> paths, int startIndex = 0);

    /** Replaces the queue around the track being heard, e.g. to shuffle or unshuffle
        what comes after it. `currentIndex` is that track's place in `paths`. The track
        keeps playing without a break; only the tracks after it change. */
    void replaceQueue(std::vector<std::string> paths, int currentIndex);
    bool play(std::string* error = nullptr);
    void pause();
    void togglePlayPause();
    void playIndex(int index);
    void next();
    void previous();
    void seek(double seconds);
    void setRepeatMode(RepeatMode mode);

    EngineStatus status() const;
    void setEventHandler(EventHandler handler);

    /** Offline mode only. Renders up to `frames` stereo frames into `interleaved`,
        waiting for the decoder as needed. Returns the frames of real audio; fewer
        than requested means the queue ended. */
    std::size_t renderOffline(float* interleaved, std::size_t frames);

private:
    struct Impl;
    std::unique_ptr<Impl> impl;
};
} // namespace closure
