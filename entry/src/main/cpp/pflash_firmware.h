#ifndef AETHERIUM_PFLASH_FIRMWARE_H
#define AETHERIUM_PFLASH_FIRMWARE_H

#include <cerrno>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <string>
#include <sys/stat.h>
#include <unistd.h>
#include <vector>

namespace aetherium {

constexpr off_t kArmVirtPflashBytes = 64 * 1024 * 1024;

inline bool ValidatePflashFile(const std::string &path, bool writable, std::string &error)
{
    const int fd = open(path.c_str(), writable ? O_RDWR : O_RDONLY);
    if (fd < 0) {
        error = "Cannot open pflash image '" + path + "': " + std::strerror(errno);
        return false;
    }
    struct stat status {};
    const bool valid = fstat(fd, &status) == 0 && S_ISREG(status.st_mode) &&
                       status.st_size == kArmVirtPflashBytes;
    close(fd);
    if (!valid) {
        error = "aarch64 virt pflash image must be exactly 67108864 bytes: " + path;
    }
    return valid;
}

// Never truncate an existing NVRAM image, including during installation. Publish
// a new image only after a complete durable copy; link() makes this no-clobber.
inline bool EnsureVmPflashVars(const std::string &source, const std::string &target,
                              std::string &error)
{
    struct stat status {};
    if (lstat(target.c_str(), &status) == 0) {
        return ValidatePflashFile(target, true, error);
    }
    if (errno != ENOENT) {
        error = "Cannot inspect VM NVRAM: " + std::string(std::strerror(errno));
        return false;
    }
    if (!ValidatePflashFile(source, false, error)) {
        return false;
    }
    const int input = open(source.c_str(), O_RDONLY);
    if (input < 0) {
        error = "Cannot open VARS template: " + std::string(std::strerror(errno));
        return false;
    }
    std::string pattern = target + ".tmp.XXXXXX";
    std::vector<char> name(pattern.begin(), pattern.end());
    name.push_back('\0');
    const int output = mkstemp(name.data());
    if (output < 0) {
        close(input);
        error = "Cannot stage VM NVRAM: " + std::string(std::strerror(errno));
        return false;
    }
    bool copied = true;
    off_t total = 0;
    char buffer[64 * 1024];
    while (copied) {
        const ssize_t count = read(input, buffer, sizeof(buffer));
        if (count < 0 && errno == EINTR) {
            continue;
        }
        if (count <= 0) {
            copied = count == 0;
            break;
        }
        total += count;
        if (total > kArmVirtPflashBytes) {
            copied = false;
            break;
        }
        ssize_t offset = 0;
        while (offset < count) {
            const ssize_t written = write(output, buffer + offset, count - offset);
            if (written < 0 && errno == EINTR) {
                continue;
            }
            if (written <= 0) {
                copied = false;
                break;
            }
            offset += written;
        }
    }
    copied = copied && total == kArmVirtPflashBytes && fsync(output) == 0;
    close(input);
    if (close(output) != 0) {
        copied = false;
    }
    if (copied && link(name.data(), target.c_str()) != 0 && errno != EEXIST) {
        copied = false;
    }
    unlink(name.data());
    if (!copied) {
        error = "Cannot create a complete private VM NVRAM image: " + target;
        return false;
    }
    return ValidatePflashFile(target, true, error);
}

} // namespace aetherium

#endif
