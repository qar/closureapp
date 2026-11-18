#include "closure/PlaybackEngine.h"

#include "AudioOutput.h"
#include "FrameRing.h"
#include "TrackDecoder.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstring>
#include <deque>
#include <limits>
#include <mutex>
#include <thread>

namespace closure
{
namespace
{
constexpr std::size_t decodeChunkFrames = 16384;
constexpr std::size_t minimumWriteFrames = 1024;
constexpr std::uint64_t noEnd = std::numeric_limits<std::uint64_t>::max();
constexpr double rampSeconds = 0.005;
constexpr double prerollSeconds = 0.25;
constexpr double restartThresholdSeconds = 3.0;

/** Where a track starts in the stream timeline. */
struct Boundary
{
    std::uint64_t streamFrame = 0;
    int trackIndex = -1;
    std::int64_t trackStartFrame = 0; // Non-zero after a seek.
    std::int64_t trackLengthFrames = 0;
    double sourceRate = 0.0;
    bool resampling = false;
    bool announced = false;
};

enum class Ramp
{
    none,
    up,
    downForDiscard,
    downForPause,
    silent
};
} // namespace

struct PlaybackEngine::Impl
{
    explicit Impl(EngineOptions optionsIn)
        : options(optionsIn)
    {
        scratch.resize(decodeChunkFrames * detail::FrameRing::channels);
        worker = std::thread([this] { run(); });
    }

    ~Impl()
    {
        {
            std::lock_guard<std::mutex> lock(mutex);
            quit = true;
            stopConsumerLocked();
        }

        wake.notify_all();
        progress.notify_all();
        worker.join();
        output.close();
    }

    // ---------------------------------------------------------------------------------
    // Real-time side. Touches only the ring, atomics and the ramp state.

    static void renderThunk(void* context, float* out, std::uint32_t frames) noexcept
    {
        static_cast<Impl*>(context)->render(out, frames);
    }

    std::size_t render(float* out, std::size_t frames) noexcept
    {
        // Paired with stopConsumerLocked(): once that sees inRender == false after
        // clearing consumerRunning, this function will not touch the ring again.
        inRender.store(true);
        if (!consumerRunning.load())
        {
            std::memset(out, 0, frames * 2 * sizeof(float));
            inRender.store(false);
            return 0;
        }

        std::size_t done = 0;
        std::size_t popped = 0;
        while (done < frames)
        {
            if (ring.discardPending())
            {
                if (!options.declick || gain <= 0.0f || ring.readableFrames() == 0)
                {
                    ring.applyDiscard();
                    ramp = options.declick ? Ramp::up : Ramp::none;
                    gain = options.declick ? 0.0f : 1.0f;
                    continue;
                }

                ramp = Ramp::downForDiscard;
            }

            if (pauseRequested.load(std::memory_order_acquire) && ramp != Ramp::silent && ramp != Ramp::downForPause)
                ramp = options.declick && gain > 0.0f ? Ramp::downForPause : Ramp::silent;

            if (ramp == Ramp::silent)
            {
                std::memset(out + done * 2, 0, (frames - done) * 2 * sizeof(float));
                pauseAcknowledged.store(true, std::memory_order_release);
                break;
            }

            auto wanted = frames - done;
            if (ramp != Ramp::none)
                wanted = std::min(wanted, rampFramesRemaining());

            const auto count = ring.pop(out + done * 2, wanted);
            if (count == 0)
            {
                if (ramp == Ramp::downForPause)
                {
                    ramp = Ramp::silent;
                    continue;
                }

                if (ring.readPosition() < endFrame.load(std::memory_order_acquire))
                    underruns.fetch_add(1, std::memory_order_relaxed);

                std::memset(out + done * 2, 0, (frames - done) * 2 * sizeof(float));
                break;
            }

            if (ramp != Ramp::none)
                applyRamp(out + done * 2, count);

            done += count;
            popped += count;
        }

        inRender.store(false);
        return popped;
    }

    std::size_t rampFramesRemaining() const noexcept
    {
        const auto distance = ramp == Ramp::up ? 1.0f - gain : gain;
        return std::max<std::size_t>(1, static_cast<std::size_t>(std::ceil(distance / gainStep)));
    }

    void applyRamp(float* frames, std::size_t count) noexcept
    {
        const bool rising = ramp == Ramp::up;
        for (std::size_t frame = 0; frame < count; ++frame)
        {
            gain = rising ? std::min(1.0f, gain + gainStep) : std::max(0.0f, gain - gainStep);
            frames[frame * 2] *= gain;
            frames[frame * 2 + 1] *= gain;
        }

        if (rising && gain >= 1.0f)
        {
            gain = 1.0f;
            ramp = Ramp::none;
        }
        else if (ramp == Ramp::downForPause && gain <= 0.0f)
        {
            ramp = Ramp::silent;
        }
    }

    // ---------------------------------------------------------------------------------
    // Consumer control. Called with the mutex held.

    void startConsumerLocked()
    {
        if (consumerRunning.load())
            return;

        // The consumer is idle here, so its ramp state can be reset directly.
        gain = options.declick ? 0.0f : 1.0f;
        ramp = options.declick ? Ramp::up : Ramp::none;
        pauseRequested.store(false);
        pauseAcknowledged.store(false);
        consumerRunning.store(true);

        if (options.outputMode == OutputMode::device)
            output.start();
    }

    void stopConsumerLocked()
    {
        if (!consumerRunning.load())
            return;

        consumerRunning.store(false);
        while (inRender.load())
            std::this_thread::yield();

        if (options.outputMode == OutputMode::device)
            output.stop();
    }

    // ---------------------------------------------------------------------------------
    // Decoder thread.

    void run()
    {
        std::unique_lock<std::mutex> lock(mutex);
        while (!quit)
        {
            commandPending = false;
            fillLocked(lock);
            announceLocked();

            if (!pendingEvents.empty())
            {
                auto events = std::move(pendingEvents);
                pendingEvents.clear();
                auto handlerCopy = handler;
                lock.unlock();
                if (handlerCopy)
                {
                    for (const auto& event : events)
                        handlerCopy(event);
                }
                lock.lock();
                continue;
            }

            wake.wait_for(lock, nextWakeLocked(), [this] { return quit || commandPending; });
        }
    }

    void fillLocked(std::unique_lock<std::mutex>& lock)
    {
        if (outputRate <= 0.0 || decodingIndex < 0 || streamFinished)
            return;

        // Refill in one burst once half of the buffer has played.
        if (ring.liveFrames() > ring.capacityFrames() / 2)
            return;

        while (!quit && decodingIndex >= 0 && !streamFinished)
        {
            const auto space = ring.freeFrames();
            if (space < minimumWriteFrames)
                break;

            const auto frames = decoder.read(scratch.data(), std::min(space, decodeChunkFrames));
            if (frames > 0)
            {
                ring.push(scratch.data(), frames);
                progress.notify_all();
                // Let control calls in between chunks.
                lock.unlock();
                lock.lock();
                continue;
            }

            advanceAfterEndOfTrackLocked();
            progress.notify_all();
        }
    }

    void advanceAfterEndOfTrackLocked()
    {
        auto next = nextIndexLocked(decodingIndex, true);
        for (std::size_t attempt = 0; next >= 0 && attempt < queue.size(); ++attempt)
        {
            std::string error;
            if (openTrackLocked(next, 0, error))
            {
                boundaries.push_back(makeBoundaryLocked(next, 0, false));
                return;
            }

            pendingEvents.push_back({ EngineEvent::Type::error, next, error });
            next = nextIndexLocked(next, true);
        }

        decoder.close();
        streamFinished = true;
        endFrame.store(ring.writePosition(), std::memory_order_release);
    }

    void announceLocked()
    {
        const auto read = ring.readPosition();
        for (auto& boundary : boundaries)
        {
            if (!boundary.announced && boundary.streamFrame <= read)
            {
                boundary.announced = true;
                announcedIndex = boundary.trackIndex;
                pendingEvents.push_back({ EngineEvent::Type::trackChanged, boundary.trackIndex, {} });
            }
        }

        while (boundaries.size() > 1 && boundaries[1].streamFrame <= read)
            boundaries.pop_front();

        if (streamFinished && !endedAnnounced && read >= endFrame.load(std::memory_order_acquire))
        {
            endedAnnounced = true;
            userPlaying = false;
            stopConsumerLocked();
            pendingEvents.push_back({ EngineEvent::Type::ended, announcedIndex, {} });
        }
    }

    /** Sleep until the buffer needs a refill or the next track change or end is
        heard, whichever comes first. No polling while playback is idle. */
    std::chrono::duration<double> nextWakeLocked() const
    {
        using Seconds = std::chrono::duration<double>;
        if (options.outputMode == OutputMode::offline || !consumerRunning.load() || outputRate <= 0.0)
            return std::chrono::hours(1);

        const auto read = ring.readPosition();
        double seconds = 3600.0;

        if (!streamFinished && decodingIndex >= 0)
        {
            const auto live = ring.liveFrames();
            const auto half = ring.capacityFrames() / 2;
            seconds = live > half ? static_cast<double>(live - half) / outputRate : 0.0;
        }

        for (const auto& boundary : boundaries)
        {
            if (!boundary.announced)
            {
                const auto frames = boundary.streamFrame > read ? boundary.streamFrame - read : 0;
                seconds = std::min(seconds, static_cast<double>(frames) / outputRate);
                break;
            }
        }

        if (streamFinished && !endedAnnounced)
        {
            const auto end = endFrame.load(std::memory_order_acquire);
            seconds = std::min(seconds, end > read ? static_cast<double>(end - read) / outputRate : 0.0);
        }

        // Small floor: covers the stale audio still draining after a jump.
        return Seconds(std::max(seconds, 0.002));
    }

    // ---------------------------------------------------------------------------------
    // Queue and stream helpers. Called with the mutex held.

    int nextIndexLocked(int from, bool automatic) const
    {
        const auto count = static_cast<int>(queue.size());
        if (count == 0 || from < 0)
            return -1;

        if (automatic && repeatMode == RepeatMode::one)
            return from;

        if (from + 1 < count)
            return from + 1;

        return repeatMode == RepeatMode::off ? -1 : 0;
    }

    bool openTrackLocked(int index, std::int64_t startFrame, std::string& error)
    {
        decodingIndex = -1;
        if (!decoder.open(queue[static_cast<std::size_t>(index)], outputRate, error))
            return false;

        if (startFrame > 0 && !decoder.seek(startFrame))
        {
            error = "Cannot seek";
            decoder.close();
            return false;
        }

        decodingIndex = index;
        return true;
    }

    Boundary makeBoundaryLocked(int index, std::int64_t startFrame, bool announced) const
    {
        Boundary boundary;
        boundary.streamFrame = ring.writePosition();
        boundary.trackIndex = index;
        boundary.trackStartFrame = startFrame;
        boundary.trackLengthFrames = decoder.lengthFrames();
        boundary.sourceRate = decoder.sourceSampleRate();
        boundary.resampling = decoder.isResampling();
        boundary.announced = announced;
        return boundary;
    }

    /** Drops buffered audio and continues from `index` at `startFrame`. */
    void jumpLocked(int index, std::int64_t startFrame)
    {
        ring.requestDiscard();
        // Offline, renderOffline() runs on the control thread, so the consumer is idle here.
        if (!consumerRunning.load() || options.outputMode == OutputMode::offline)
            ring.applyDiscard();

        boundaries.clear();
        streamFinished = false;
        endedAnnounced = false;
        endFrame.store(noEnd, std::memory_order_release);
        selectedIndex = index;

        if (outputRate > 0.0)
        {
            std::string error;
            if (openTrackLocked(index, startFrame, error))
            {
                boundaries.push_back(makeBoundaryLocked(index, startFrame, true));
            }
            else
            {
                pendingEvents.push_back({ EngineEvent::Type::error, index, error });
                streamFinished = true;
                endFrame.store(ring.writePosition(), std::memory_order_release);
            }
        }

        if (announcedIndex != index)
        {
            announcedIndex = index;
            pendingEvents.push_back({ EngineEvent::Type::trackChanged, index, {} });
        }

        notifyWorkerLocked();
    }

    void notifyWorkerLocked()
    {
        commandPending = true;
        wake.notify_one();
    }

    struct Position
    {
        int trackIndex = -1;
        std::int64_t frame = 0;
        const Boundary* boundary = nullptr;
    };

    Position currentPositionLocked() const
    {
        Position position;
        if (boundaries.empty())
        {
            position.trackIndex = selectedIndex;
            return position;
        }

        const auto read = ring.readPosition();
        const Boundary* current = &boundaries.front();
        for (const auto& boundary : boundaries)
        {
            if (boundary.streamFrame <= read)
                current = &boundary;
        }

        position.trackIndex = current->trackIndex;
        position.boundary = current;
        const auto played = read > current->streamFrame ? static_cast<std::int64_t>(read - current->streamFrame) : 0;
        position.frame = std::min(current->trackStartFrame + played, current->trackLengthFrames);
        return position;
    }

    bool playLocked(std::unique_lock<std::mutex>& lock, std::string* error)
    {
        if (queue.empty())
        {
            if (error != nullptr)
                *error = "Queue is empty";
            return false;
        }

        if (outputRate <= 0.0)
        {
            if (error != nullptr)
                *error = "Output sample rate is not set";
            return false;
        }

        if (endedAnnounced)
            jumpLocked(0, 0);
        else if (boundaries.empty() && decodingIndex < 0)
            jumpLocked(std::max(selectedIndex, 0), 0);

        userPlaying = true;
        if (consumerRunning.load())
            return true;

        notifyWorkerLocked();
        const auto preroll = std::min(static_cast<std::size_t>(outputRate * prerollSeconds),
                                      ring.capacityFrames() / 2);
        progress.wait_for(lock, std::chrono::milliseconds(500), [this, preroll]
        {
            return quit || streamFinished || decodingIndex < 0 || ring.liveFrames() >= preroll;
        });

        startConsumerLocked();
        return true;
    }

    // ---------------------------------------------------------------------------------

    EngineOptions options;

    // Shared with the render thread.
    detail::FrameRing ring;
    std::atomic<std::uint64_t> endFrame { noEnd };
    std::atomic<bool> consumerRunning { false };
    std::atomic<bool> inRender { false };
    std::atomic<bool> pauseRequested { false };
    std::atomic<bool> pauseAcknowledged { false };
    std::atomic<std::uint64_t> underruns { 0 };

    // Render-thread state. Reset by control code only while the consumer is idle.
    Ramp ramp = Ramp::none;
    float gain = 1.0f;
    float gainStep = 1.0f;

    // Guarded by mutex.
    mutable std::mutex mutex;
    std::condition_variable wake;
    std::condition_variable progress;
    bool quit = false;
    bool commandPending = false;
    std::vector<std::string> queue;
    RepeatMode repeatMode = RepeatMode::all;
    double outputRate = 0.0;
    detail::TrackDecoder decoder;
    int decodingIndex = -1;
    int selectedIndex = -1;
    int announcedIndex = -1;
    bool streamFinished = false;
    bool endedAnnounced = false;
    bool userPlaying = false;
    std::deque<Boundary> boundaries;
    std::vector<EngineEvent> pendingEvents;
    std::vector<float> scratch;
    EventHandler handler;
    detail::AudioOutput output;

    std::thread worker;
};

PlaybackEngine::PlaybackEngine(EngineOptions options)
    : impl(std::make_unique<Impl>(options))
{
}

PlaybackEngine::~PlaybackEngine() = default;

bool PlaybackEngine::setOutputSampleRate(double sampleRate, std::string* error)
{
    if (sampleRate <= 0.0)
    {
        if (error != nullptr)
            *error = "Invalid sample rate";
        return false;
    }

    std::unique_lock<std::mutex> lock(impl->mutex);
    const auto sameRate = std::abs(sampleRate - impl->outputRate) < 0.5;
    if (sameRate && (impl->options.outputMode == OutputMode::offline || impl->output.isOpen()))
        return true;

    const auto position = impl->currentPositionLocked();
    const auto positionSeconds = impl->outputRate > 0.0 ? static_cast<double>(position.frame) / impl->outputRate : 0.0;
    const auto wasPlaying = impl->userPlaying;

    impl->stopConsumerLocked();
    impl->decoder.close();
    impl->decodingIndex = -1;
    impl->output.close();

    if (impl->options.outputMode == OutputMode::device)
    {
        std::string openError;
        if (!impl->output.open(sampleRate, &Impl::renderThunk, impl.get(), openError))
        {
            impl->outputRate = 0.0;
            impl->userPlaying = false;
            if (error != nullptr)
                *error = openError;
            return false;
        }
    }

    impl->outputRate = sampleRate;
    impl->gainStep = 1.0f / std::max(1.0f, static_cast<float>(sampleRate * rampSeconds));
    impl->ring.allocate(static_cast<std::size_t>(sampleRate * impl->options.bufferSeconds));
    impl->endFrame.store(noEnd);
    impl->boundaries.clear(); // Their stream frames refer to the old ring.

    if (position.trackIndex >= 0 && !impl->queue.empty())
    {
        impl->jumpLocked(position.trackIndex,
                         static_cast<std::int64_t>(std::llround(positionSeconds * sampleRate)));
        if (wasPlaying)
            impl->playLocked(lock, nullptr);
    }

    return true;
}

void PlaybackEngine::resetOutput()
{
    std::lock_guard<std::mutex> lock(impl->mutex);
    impl->stopConsumerLocked();
    impl->output.close();
}

void PlaybackEngine::setQueue(std::vector<std::string> paths, int startIndex)
{
    std::lock_guard<std::mutex> lock(impl->mutex);
    impl->queue = std::move(paths);

    if (impl->queue.empty())
    {
        impl->stopConsumerLocked();
        impl->userPlaying = false;
        impl->decoder.close();
        impl->decodingIndex = -1;
        impl->selectedIndex = -1;
        impl->announcedIndex = -1;
        impl->boundaries.clear();
        impl->ring.requestDiscard();
        impl->ring.applyDiscard();
        return;
    }

    const auto index = std::clamp(startIndex, 0, static_cast<int>(impl->queue.size()) - 1);
    impl->jumpLocked(index, 0);
}

void PlaybackEngine::replaceQueue(std::vector<std::string> paths, int currentIndex)
{
    std::lock_guard<std::mutex> lock(impl->mutex);
    if (paths.empty() || currentIndex < 0 || currentIndex >= static_cast<int>(paths.size()))
        return;

    const auto position = impl->currentPositionLocked();
    impl->queue = std::move(paths);

    if (impl->boundaries.empty() || impl->endedAnnounced)
    {
        // Nothing decoded (or the queue has ended): the next play starts here.
        impl->selectedIndex = currentIndex;
        if (impl->endedAnnounced)
            impl->announcedIndex = currentIndex;
        return;
    }

    // Audio of the old next track may already be in the buffer. Then decode again from
    // the current position, as a repeat mode change does.
    const auto decodedAhead = impl->streamFinished
                           || impl->decodingIndex != position.trackIndex
                           || std::any_of(impl->boundaries.begin(), impl->boundaries.end(),
                                          [](const Boundary& boundary) { return !boundary.announced; });
    if (decodedAhead)
    {
        impl->announcedIndex = currentIndex; // Same track: no track change event.
        impl->jumpLocked(currentIndex, position.frame);
        return;
    }

    // Only the current track is buffered: renumber it. The audio is untouched.
    for (auto& boundary : impl->boundaries)
        boundary.trackIndex = currentIndex;
    impl->decodingIndex = currentIndex;
    impl->selectedIndex = currentIndex;
    impl->announcedIndex = currentIndex;
}

bool PlaybackEngine::play(std::string* error)
{
    std::unique_lock<std::mutex> lock(impl->mutex);
    return impl->playLocked(lock, error);
}

void PlaybackEngine::pause()
{
    std::lock_guard<std::mutex> lock(impl->mutex);
    impl->userPlaying = false;
    if (!impl->consumerRunning.load())
        return;

    if (impl->options.outputMode == OutputMode::device && impl->options.declick)
    {
        // Let the render thread fade out (5 ms) before the unit stops.
        impl->pauseRequested.store(true, std::memory_order_release);
        const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(100);
        while (!impl->pauseAcknowledged.load(std::memory_order_acquire)
               && std::chrono::steady_clock::now() < deadline)
        {
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
        }
    }

    impl->stopConsumerLocked();
    impl->notifyWorkerLocked();
}

void PlaybackEngine::togglePlayPause()
{
    bool playing = false;
    {
        std::lock_guard<std::mutex> lock(impl->mutex);
        playing = impl->userPlaying;
    }

    if (playing)
        pause();
    else
        play();
}

void PlaybackEngine::playIndex(int index)
{
    std::unique_lock<std::mutex> lock(impl->mutex);
    if (index < 0 || index >= static_cast<int>(impl->queue.size()))
        return;

    impl->jumpLocked(index, 0);
    impl->playLocked(lock, nullptr);
}

void PlaybackEngine::next()
{
    std::lock_guard<std::mutex> lock(impl->mutex);
    const auto position = impl->currentPositionLocked();
    const auto next = impl->nextIndexLocked(position.trackIndex, false);
    if (next >= 0)
        impl->jumpLocked(next, 0);
}

void PlaybackEngine::previous()
{
    std::lock_guard<std::mutex> lock(impl->mutex);
    const auto position = impl->currentPositionLocked();
    if (position.trackIndex < 0)
        return;

    const auto restartFrames = static_cast<std::int64_t>(impl->outputRate * restartThresholdSeconds);
    auto target = position.trackIndex - 1;
    if (position.frame > restartFrames || (target < 0 && impl->repeatMode != RepeatMode::all))
        target = position.trackIndex;
    else if (target < 0)
        target = static_cast<int>(impl->queue.size()) - 1;

    impl->jumpLocked(target, 0);
}

void PlaybackEngine::seek(double seconds)
{
    std::lock_guard<std::mutex> lock(impl->mutex);
    const auto position = impl->currentPositionLocked();
    if (position.trackIndex < 0 || impl->outputRate <= 0.0)
        return;

    auto frame = static_cast<std::int64_t>(std::llround(std::max(0.0, seconds) * impl->outputRate));
    if (position.boundary != nullptr)
        frame = std::min(frame, std::max<std::int64_t>(0, position.boundary->trackLengthFrames - 1));

    impl->jumpLocked(position.trackIndex, frame);
}

void PlaybackEngine::setRepeatMode(RepeatMode mode)
{
    std::lock_guard<std::mutex> lock(impl->mutex);
    if (impl->repeatMode == mode)
        return;

    impl->repeatMode = mode;

    // Audio after the current track may already be decoded under the old mode.
    const auto decidedAhead = impl->streamFinished
                           || std::any_of(impl->boundaries.begin(), impl->boundaries.end(),
                                          [](const Boundary& boundary) { return !boundary.announced; });
    if (decidedAhead && !impl->endedAnnounced)
    {
        const auto position = impl->currentPositionLocked();
        if (position.trackIndex >= 0)
            impl->jumpLocked(position.trackIndex, position.frame);
    }
}

EngineStatus PlaybackEngine::status() const
{
    std::lock_guard<std::mutex> lock(impl->mutex);
    EngineStatus status;
    const auto position = impl->currentPositionLocked();
    status.playing = impl->userPlaying;
    status.ended = impl->endedAnnounced;
    status.trackIndex = position.trackIndex;
    status.trackCount = static_cast<int>(impl->queue.size());
    status.outputSampleRate = impl->outputRate;
    status.underruns = impl->underruns.load(std::memory_order_relaxed);

    if (impl->outputRate > 0.0)
    {
        status.positionSeconds = static_cast<double>(position.frame) / impl->outputRate;
        status.bufferedSeconds = static_cast<double>(impl->ring.liveFrames()) / impl->outputRate;
        if (position.boundary != nullptr)
        {
            status.durationSeconds = static_cast<double>(position.boundary->trackLengthFrames) / impl->outputRate;
            status.sourceSampleRate = position.boundary->sourceRate;
            status.resampling = position.boundary->resampling;
        }
    }

    return status;
}

void PlaybackEngine::setEventHandler(EventHandler handler)
{
    std::lock_guard<std::mutex> lock(impl->mutex);
    impl->handler = std::move(handler);
}

std::size_t PlaybackEngine::renderOffline(float* interleaved, std::size_t frames)
{
    if (impl->options.outputMode != OutputMode::offline)
        return 0;

    std::size_t total = 0;
    while (total < frames)
    {
        std::size_t chunk = 0;
        {
            std::unique_lock<std::mutex> lock(impl->mutex);
            if (!impl->consumerRunning.load())
                break;

            chunk = std::min(frames - total, impl->ring.capacityFrames() / 2);
            impl->notifyWorkerLocked();
            impl->progress.wait_for(lock, std::chrono::seconds(10), [this, chunk]
            {
                return impl->quit || impl->streamFinished || impl->decodingIndex < 0
                    || impl->ring.liveFrames() >= chunk;
            });
        }

        const auto rendered = impl->render(interleaved + total * 2, chunk);
        total += rendered;

        {
            std::lock_guard<std::mutex> lock(impl->mutex);
            impl->notifyWorkerLocked();
        }

        if (rendered < chunk)
            break;
    }

    return total;
}
} // namespace closure
