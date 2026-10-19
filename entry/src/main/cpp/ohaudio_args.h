#ifndef AETHERIUM_OHAUDIO_ARGS_H
#define AETHERIUM_OHAUDIO_ARGS_H

#include <string>

// Matches the QEMU backend's signed 16-bit little-endian PCM contract.
inline std::string BuildOHAudioArgs(const std::string &id) {
    return "aether-soundkit-hmos,id=" + id +
           ",out.frequency=48000,out.channels=2,out.format=s16" +
           ",in.frequency=48000,in.channels=1,in.format=s16";
}

#endif
