#ifndef AETHERIUM_OHAUDIO_ARGS_H
#define AETHERIUM_OHAUDIO_ARGS_H

#include <string>

// Fixed playback format; direct guest input delivery is required so QEMU's
// mixing/resampling queues cannot retain microphone samples after revocation.
// Input negotiates guest S16LE rate/channels; other input formats fail closed.
inline std::string BuildOHAudioArgs(const std::string &id) {
    return "aether-soundkit-hmos,id=" + id +
           ",out.frequency=48000,out.channels=2,out.format=s16" +
           ",in.mixing-engine=off,in.voices=1";
}

#endif
