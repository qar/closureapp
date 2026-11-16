#pragma once

#include <algorithm>
#include <atomic>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <vector>

namespace closure::detail
{
/**
    Single-producer, single-consumer ring of interleaved stereo float frames.

    The read and write indices are monotonic frame counters, so they also serve as
    the stream timeline: frame N of the stream is the N-th frame ever written.

    A jump (seek, track change) must drop audio that is already written. Only the
    consumer may move the read index while it runs, so the producer side marks a
    discard target and the consumer applies it. When the consumer is known to be
    idle, the control side may apply it directly.
*/
class FrameRing final
{
public:
    static constexpr std::size_t channels = 2;

    void allocate(std::size_t minimumFrames)
    {
        std::size_t frames = 1024;
        while (frames < minimumFrames)
            frames <<= 1;

        storage.assign(frames * channels, 0.0f);
        capacity = frames;
        mask = frames - 1;
        writeIndex.store(0);
        readIndex.store(0);
        discardTarget.store(0);
    }

    std::size_t capacityFrames() const noexcept { return capacity; }
    std::uint64_t writePosition() const noexcept { return writeIndex.load(std::memory_order_acquire); }
    std::uint64_t readPosition() const noexcept { return readIndex.load(std::memory_order_acquire); }

    /** Producer: frames that can be written now. Stale frames still count until dropped. */
    std::size_t freeFrames() const noexcept
    {
        return capacity - static_cast<std::size_t>(writePosition() - readPosition());
    }

    /** Frames that will still play, not counting frames marked for discard. */
    std::size_t liveFrames() const noexcept
    {
        const auto write = writePosition();
        const auto start = std::max(readPosition(), discardTarget.load(std::memory_order_acquire));
        return write > start ? static_cast<std::size_t>(write - start) : 0;
    }

    /** Producer. `count` must not exceed freeFrames(). */
    void push(const float* frames, std::size_t count) noexcept
    {
        const auto write = writeIndex.load(std::memory_order_relaxed);
        const auto offset = static_cast<std::size_t>(write & mask);
        const auto first = std::min(count, capacity - offset);
        std::memcpy(storage.data() + offset * channels, frames, first * channels * sizeof(float));
        std::memcpy(storage.data(), frames + first * channels, (count - first) * channels * sizeof(float));
        writeIndex.store(write + count, std::memory_order_release);
    }

    /** Control side, while the producer is idle: all frames written so far are stale. */
    void requestDiscard() noexcept
    {
        discardTarget.store(writeIndex.load(std::memory_order_acquire), std::memory_order_release);
    }

    bool discardPending() const noexcept
    {
        return discardTarget.load(std::memory_order_acquire) > readPosition();
    }

    /** Consumer (or control side while the consumer is idle). */
    void applyDiscard() noexcept
    {
        const auto target = discardTarget.load(std::memory_order_acquire);
        if (target > readIndex.load(std::memory_order_relaxed))
            readIndex.store(target, std::memory_order_release);
    }

    /** Consumer: frames that can be read before the discard target, if one is pending. */
    std::size_t readableFrames() const noexcept
    {
        const auto read = readIndex.load(std::memory_order_relaxed);
        const auto target = discardTarget.load(std::memory_order_acquire);
        const auto end = target > read ? target : writeIndex.load(std::memory_order_acquire);
        return static_cast<std::size_t>(end - read);
    }

    /** Consumer. Never reads past a pending discard target. */
    std::size_t pop(float* out, std::size_t count) noexcept
    {
        const auto frames = std::min(count, readableFrames());
        const auto read = readIndex.load(std::memory_order_relaxed);
        const auto offset = static_cast<std::size_t>(read & mask);
        const auto first = std::min(frames, capacity - offset);
        std::memcpy(out, storage.data() + offset * channels, first * channels * sizeof(float));
        std::memcpy(out + first * channels, storage.data(), (frames - first) * channels * sizeof(float));
        readIndex.store(read + frames, std::memory_order_release);
        return frames;
    }

private:
    std::vector<float> storage;
    std::size_t capacity = 0;
    std::uint64_t mask = 0;
    std::atomic<std::uint64_t> writeIndex { 0 };
    std::atomic<std::uint64_t> readIndex { 0 };
    std::atomic<std::uint64_t> discardTarget { 0 };
};
} // namespace closure::detail
