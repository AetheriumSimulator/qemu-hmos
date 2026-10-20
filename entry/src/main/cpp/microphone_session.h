#pragma once

#include <cstdint>
#include <mutex>
#include <string>

// Serialize controls from NAPI and VM completion. Consent belongs to one running
// VM generation; a late permission result cannot enable a restarted VM.
class MicrophoneSession {
public:
    using SetEnabled = int (*)(bool);
    using GetStatus = int (*)();

    void Bind(SetEnabled set, GetStatus status)
    {
        std::lock_guard<std::mutex> lock(mutex_);
        Disable();
        set_ = set;
        status_ = status;
        Disable();
    }

    bool Available()
    {
        std::lock_guard<std::mutex> lock(mutex_);
        return set_ && status_;
    }

    uint32_t Begin(const std::string &name)
    {
        std::lock_guard<std::mutex> lock(mutex_);
        Disable();
        name_ = name;
        active_ = false;
        if (++generation_ == 0) {
            ++generation_;
        }
        return generation_;
    }

    void Running(uint32_t generation)
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (generation == generation_ && !name_.empty()) {
            active_ = true;
        }
    }

    void End(uint32_t generation)
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (generation == generation_) {
            Disable();
            active_ = false;
            name_.clear();
        }
    }

    void Stop(const std::string &name)
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (name == name_) {
            Disable();
            active_ = false;
            name_.clear();
        }
    }

    uint32_t Session(const std::string &name)
    {
        std::lock_guard<std::mutex> lock(mutex_);
        return active_ && name == name_ ? generation_ : 0;
    }

    bool Enable(const std::string &name, uint32_t generation, bool enable)
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (!active_ || name != name_ || generation != generation_ || !set_ || !status_) {
            return false;
        }
        return set_(enable) != 0;
    }

    const char *Status(const std::string &name)
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (!active_ || name != name_ || !set_ || !status_) {
            return "unavailable";
        }
        switch (status_()) {
            case 0: return "disabled";
            case 1: return "armed";
            case 2: return "capturing";
            case 3: return "blocked";
            case 4: return "error";
            default: Disable(); return "unavailable";
        }
    }

private:
    void Disable()
    {
        if (set_) {
            set_(false);
        }
    }
    std::mutex mutex_;
    std::string name_;
    uint32_t generation_ = 0;
    bool active_ = false;
    SetEnabled set_ = nullptr;
    GetStatus status_ = nullptr;
};
