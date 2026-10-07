#include "engine/rime_user_lock.hpp"

#include <csignal>
#include <cstdlib>
#include <filesystem>
#include <iostream>
#include <string>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

namespace {
void Expect(bool condition, const char* message) {
    if (!condition) {
        std::cerr << "FAIL: " << message << '\n';
        std::exit(1);
    }
}

int Probe(const char* executable, const std::filesystem::path& root) {
    const pid_t child = fork();
    Expect(child >= 0, "fork failed");
    if (child == 0) {
        execl(executable, executable, "--probe", root.c_str(), nullptr);
        _exit(99);
    }
    int status = 0;
    Expect(waitpid(child, &status, 0) == child && WIFEXITED(status), "probe did not exit");
    return WEXITSTATUS(status);
}
}  // namespace

int main(int argc, char** argv) {
    using rimes::linuxime::RimeUserLock;
    if (argc >= 3) {
        RimeUserLock child_lock;
        if (!child_lock.Acquire(argv[2])) {
            return 2;
        }
        if (argc == 4 && std::string(argv[1]) == "--hold") {
            const int ready_fd = std::stoi(argv[3]);
            if (write(ready_fd, "1", 1) != 1) {
                return 3;
            }
            close(ready_fd);
            for (;;) {
                pause();
            }
        }
        return 0;
    }

    auto pattern = (std::filesystem::temp_directory_path() / "rimes-lock-XXXXXX").string();
    Expect(mkdtemp(pattern.data()) != nullptr, "mkdtemp failed");
    const std::filesystem::path root(pattern);
    std::filesystem::create_directory(root / "other");
    RimeUserLock owner;
    RimeUserLock competitor;
    std::string error;
    Expect(owner.Acquire(root, &error), "first owner failed");
    struct stat info {};
    Expect(stat((root / ".rimes-engine.lock").c_str(), &info) == 0 &&
               (info.st_mode & 0777) == 0600,
           "lock is not private");
    Expect(!competitor.Acquire(root, &error), "same-process competing owner acquired lock");
    Expect(Probe(argv[0], root) == 2, "exec'd process acquired occupied directory");
    Expect(Probe(argv[0], root / "other") == 0, "different directory was blocked");
    Expect(!owner.Acquire(root), "double acquire changed lock ownership");
    owner.Release();
    Expect(Probe(argv[0], root) == 0, "released lock stayed busy or leaked across exec");
    Expect(competitor.Acquire(root), "replacement could not acquire after release");
    competitor.Release();
    Expect(std::filesystem::exists(root / ".rimes-engine.lock"), "lock inode was removed");

    int ready[2];
    Expect(pipe(ready) == 0, "pipe failed");
    const auto fd_arg = std::to_string(ready[1]);
    const pid_t child = fork();
    Expect(child >= 0, "owner fork failed");
    if (child == 0) {
        close(ready[0]);
        execl(argv[0], argv[0], "--hold", root.c_str(), fd_arg.c_str(), nullptr);
        _exit(99);
    }
    close(ready[1]);
    char signal = 0;
    Expect(read(ready[0], &signal, 1) == 1 && signal == '1', "child owner did not lock");
    close(ready[0]);
    Expect(Probe(argv[0], root) == 2, "child ownership was not exclusive");
    Expect(kill(child, SIGKILL) == 0, "could not stop test child");
    int status = 0;
    Expect(waitpid(child, &status, 0) == child && WIFSIGNALED(status), "test child not reaped");
    Expect(owner.Acquire(root), "crashed process leaked lock ownership");
    owner.Release();

    std::filesystem::remove(root / "other" / ".rimes-engine.lock");
    std::filesystem::create_symlink(root / ".rimes-engine.lock",
                                    root / "other" / ".rimes-engine.lock");
    Expect(!owner.Acquire(root / "other"), "symlink lock accepted");
    std::filesystem::remove(root / "other" / ".rimes-engine.lock");
    std::filesystem::create_hard_link(root / ".rimes-engine.lock",
                                     root / "other" / ".rimes-engine.lock");
    Expect(!owner.Acquire(root / "other"), "hard-linked lock accepted");
    std::filesystem::remove_all(root);
    std::cout << "ok: directory isolation, competing processes, crash/release, exec and unsafe locks\n";
}
