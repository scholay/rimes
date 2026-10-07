#include "rime_user_lock.hpp"

#include <fcntl.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>

namespace rimes::linuxime {
namespace {
void SetError(std::string* error, const char* message) noexcept {
    if (error != nullptr) {
        try {
            error->assign(message);
        } catch (...) {
        }
    }
}
}  // namespace

RimeUserLock::~RimeUserLock() { Release(); }

bool RimeUserLock::Acquire(const std::filesystem::path& user_dir,
                          std::string* error) noexcept {
    if (fd_ >= 0) {
        SetError(error, "librime user directory lock already held");
        return false;
    }
    try {
        const auto path = user_dir / ".rimes-engine.lock";
        const int fd = open(path.c_str(), O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0600);
        if (fd < 0) {
            SetError(error, "could not open librime user directory lock");
            return false;
        }
        struct stat info {};
        if (fstat(fd, &info) != 0 || !S_ISREG(info.st_mode) ||
            info.st_uid != geteuid() || info.st_nlink != 1) {
            close(fd);
            SetError(error, "unsafe librime user directory lock file");
            return false;
        }
        if (flock(fd, LOCK_EX | LOCK_NB) != 0) {
            close(fd);
            SetError(error, "librime user directory is locked by another RIMES process");
            return false;
        }
        fd_ = fd;
        return true;
    } catch (...) {
        SetError(error, "exception while locking librime user directory");
        return false;
    }
}

void RimeUserLock::Release() noexcept {
    if (fd_ >= 0) {
        close(fd_);
        fd_ = -1;
    }
    // Keep the inode. Unlinking would let a replacement acquire a new inode
    // while an existing owner still holds the old one.
}

}  // namespace rimes::linuxime
