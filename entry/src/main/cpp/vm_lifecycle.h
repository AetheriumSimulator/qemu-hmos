#pragma once

#include <cstdint>
#include <mutex>
#include <string>

namespace aether {

// One object belongs to one runner. A stop request or QMP disconnect is not
// proof that the runner has returned. Only Complete releases active ownership.
class VmLifecycle {
public:
    struct Snapshot {
        bool active;
        bool stopRequested;
        std::string status;
        std::string error;
    };

    Snapshot Read() const
    {
        std::lock_guard<std::mutex> lock(mutex_);
        return {active_, stopRequested_, status_, error_};
    }

    bool IsActive() const { return Read().active; }

    bool BlocksStart() const
    {
        std::lock_guard<std::mutex> lock(mutex_);
        return active_ || stopOwner_;
    }

    bool MarkRunning()
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (!active_ || stopRequested_ || !error_.empty()) {
            return false;
        }
        status_ = "running";
        return true;
    }

    bool ClaimStop()
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (!active_ || stopOwner_) {
            return false;
        }
        stopRequested_ = true;
        stopOwner_ = true;
        status_ = "stopping";
        return true;
    }

    // A failed monitor creation leaves the runner in the original owner map.
    // Keep the stop request and cause, but allow another request to retry.
    void ReleaseStopOwner()
    {
        std::lock_guard<std::mutex> lock(mutex_);
        stopOwner_ = false;
    }

    void Fail(const std::string &reason)
    {
        std::lock_guard<std::mutex> lock(mutex_);
        AppendError(reason);
        stopRequested_ = true;
        status_ = active_ ? "stopping" : "failed";
    }

    void Complete(int exitCode)
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (exitCode != 0) {
            AppendError("VM exited with code " + std::to_string(exitCode));
        }
        active_ = false;
        status_ = error_.empty() ? "stopped" : "failed";
    }

private:
    void AppendError(const std::string &reason)
    {
        if (reason.empty()) {
            return;
        }
        const std::string framed = "; " + error_ + "; ";
        if (error_.empty()) {
            error_ = reason;
        } else if (framed.find("; " + reason + "; ") == std::string::npos) {
            error_ += "; " + reason;
        }
    }

    mutable std::mutex mutex_;
    bool active_ = true;
    bool stopRequested_ = false;
    bool stopOwner_ = false;
    std::string status_ = "starting";
    std::string error_;
};

// QMP is an escalation channel, not a liveness oracle. A deadline records a
// failure while retaining ownership; an in-process runner cannot be SIGKILLed.
template<class Quit, class Now, class Sleep, class Report>
void WaitForVmStop(VmLifecycle &run, Quit quit, Now now, Sleep sleep, Report report,
                  int64_t initialDelayMs = 5000, int64_t graceMs = 7000)
{
    const int64_t started = now();
    int64_t lastAttempt = -1000;
    bool accepted = false;
    bool deadlineReported = false;
    while (run.IsActive()) {
        const int64_t elapsed = now() - started;
        if (!accepted && elapsed >= initialDelayMs && elapsed - lastAttempt >= 1000) {
            lastAttempt = elapsed;
            accepted = quit();
        }
        // The runner can finish while a synchronous QMP exchange is in flight.
        if (!run.IsActive()) {
            break;
        }
        if (!deadlineReported && now() - started >= initialDelayMs + graceMs) {
            const std::string reason = accepted
                ? "VM stop deadline exceeded after QMP quit; runner has not returned"
                : "VM stop deadline exceeded before QMP quit was accepted";
            run.Fail(reason);
            report(reason);
            deadlineReported = true;
        }
        sleep();
    }
}

} // namespace aether
