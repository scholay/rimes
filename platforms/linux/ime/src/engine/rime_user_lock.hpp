#pragma once

#include <filesystem>
#include <string>

namespace rimes::linuxime {

// Hold through librime finalization, not only deployment: another process
// must not deploy over this process's live tables or user dictionaries.
class RimeUserLock final {
public:
    ~RimeUserLock();
    RimeUserLock() = default;
    RimeUserLock(const RimeUserLock&) = delete;
    RimeUserLock& operator=(const RimeUserLock&) = delete;

    bool Acquire(const std::filesystem::path& user_dir,
                 std::string* error = nullptr) noexcept;
    void Release() noexcept;

private:
    int fd_ = -1;
};

}  // namespace rimes::linuxime
