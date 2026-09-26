#pragma once

#include "../vendor/plank-client/linuxrawwacom.h"

#include <cstddef>
#include <cstdint>
#include <deque>
#include <functional>
#include <memory>
#include <mutex>
#include <vector>

struct PltrQueuedTabletFrame {
    std::uint64_t capture_time_us;
    std::vector<std::uint8_t> plwh;
};

// Bridges the existing Linux raw-Wacom worker to the bounded Relay output
// queue. The network thread alone encrypts and writes PLTR records; the worker
// thread only appends validated PLWH frames and wakes that thread.
class PltrWorkerBridge {
public:
    explicit PltrWorkerBridge(std::function<void()> wake);
    ~PltrWorkerBridge();
    PltrWorkerBridge(const PltrWorkerBridge&) = delete;
    PltrWorkerBridge& operator=(const PltrWorkerBridge&) = delete;

    void setActive(bool active);
    void beginReconnect();
    void finishReconnect();
    void handleControl(const std::uint8_t *bytes, std::size_t size);
    bool pop(PltrQueuedTabletFrame &frame);
    bool failed() const;

    // Exposed for focused queue tests; production calls this from the worker.
    bool enqueue(const std::uint8_t *bytes, std::size_t size);

private:
    static constexpr std::size_t MaxFrames = 256;
    static constexpr std::size_t MaxBytes = 256 * 1024;
    mutable std::mutex mutex_;
    std::deque<PltrQueuedTabletFrame> queue_;
    std::size_t queued_bytes_ = 0;
    bool failed_ = false;
    std::function<void()> wake_;
    std::unique_ptr<LinuxRawWacomInput> worker_;
    void markFailed();
};
