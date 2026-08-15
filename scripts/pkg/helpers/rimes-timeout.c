#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

// PackageKit gives a top-level installer script a much larger timeout. This
// helper gives each potentially blocking command its own process group and
// private output files. A timed-out or leader-less descendant can therefore
// neither outlive the bounded operation unnoticed nor retain PackageKit's log
// descriptors. All waits are nonblocking and bounded, including after KILL.

enum {
    output_limit_bytes = 256 * 1024,
    poll_nanoseconds = 25 * 1000 * 1000,
};

static volatile sig_atomic_t forwarded_signal = 0;

static void remember_signal(int signal_number) {
    forwarded_signal = signal_number;
}

static double monotonic_seconds(void) {
    struct timespec value;
    if (clock_gettime(CLOCK_MONOTONIC, &value) != 0) {
        return 0;
    }
    return (double)value.tv_sec + (double)value.tv_nsec / 1000000000.0;
}

static void pause_briefly(void) {
    struct timespec delay = { .tv_sec = 0, .tv_nsec = poll_nanoseconds };
    while (nanosleep(&delay, &delay) != 0 && errno == EINTR) {
    }
}

static int status_code(int status) {
    if (WIFEXITED(status)) {
        return WEXITSTATUS(status);
    }
    if (WIFSIGNALED(status)) {
        return 128 + WTERMSIG(status);
    }
    return 125;
}

static bool process_group_exists(pid_t leader) {
    errno = 0;
    return kill(-leader, 0) == 0 || errno == EPERM;
}

static bool reap_leader_nonblocking(pid_t leader, int *status) {
    pid_t result;
    do {
        result = waitpid(leader, status, WNOHANG);
    } while (result < 0 && errno == EINTR);
    return result == leader || (result < 0 && errno == ECHILD);
}

static void terminate_group_bounded(pid_t leader, bool leader_reaped) {
    int ignored_status = 0;
    if (process_group_exists(leader)) {
        (void)kill(-leader, SIGTERM);
    }
    const double term_deadline = monotonic_seconds() + 0.25;
    while (monotonic_seconds() < term_deadline) {
        if (!leader_reaped) {
            leader_reaped = reap_leader_nonblocking(leader, &ignored_status);
        }
        if (leader_reaped && !process_group_exists(leader)) {
            return;
        }
        pause_briefly();
    }

    if (process_group_exists(leader)) {
        (void)kill(-leader, SIGKILL);
    }
    // SIGKILL is not an instantaneous completion fence for an uninterruptible
    // filesystem syscall. Poll/reap for a bounded interval, then return. The
    // child owns only unlinked temporary output files, never PackageKit's fds.
    const double kill_deadline = monotonic_seconds() + 1.0;
    while (monotonic_seconds() < kill_deadline) {
        if (!leader_reaped) {
            leader_reaped = reap_leader_nonblocking(leader, &ignored_status);
        }
        if (leader_reaped && !process_group_exists(leader)) {
            return;
        }
        pause_briefly();
    }
}

static int create_output_file(void) {
    char path[] = "/tmp/rimes-timeout-output.XXXXXX";
    int descriptor = mkstemp(path);
    if (descriptor < 0) {
        return -1;
    }
    (void)unlink(path);
    if (fchmod(descriptor, S_IRUSR | S_IWUSR) != 0) {
        close(descriptor);
        return -1;
    }
    return descriptor;
}

static void emit_output(int source, int destination) {
    char buffer[8192];
    off_t offset = 0;
    for (;;) {
        ssize_t count = pread(source, buffer, sizeof(buffer), offset);
        if (count == 0) {
            return;
        }
        if (count < 0) {
            if (errno == EINTR) {
                continue;
            }
            return;
        }
        offset += count;
        ssize_t written = 0;
        while (written < count) {
            ssize_t result = write(
                destination,
                buffer + written,
                (size_t)(count - written)
            );
            if (result > 0) {
                written += result;
            } else if (result < 0 && errno == EINTR) {
                continue;
            } else {
                return;
            }
        }
    }
}

static int acquire_child_lock(const char *path) {
    // This runs inside the supervised process group. open(2) or an NFS lock
    // RPC may itself block, so the watchdog parent must never touch this path.
    int descriptor = open(
        path,
        O_RDWR | O_CREAT | O_NOFOLLOW | O_EXLOCK | O_NONBLOCK,
        S_IRUSR | S_IWUSR
    );
    if (descriptor < 0) {
        perror("rimes-timeout: open lock");
        return -1;
    }
    struct stat metadata;
    if (fstat(descriptor, &metadata) != 0
        || !S_ISREG(metadata.st_mode)
        || metadata.st_uid != geteuid()
        || (metadata.st_mode & (S_IRWXG | S_IRWXO)) != 0) {
        fprintf(
            stderr,
            "rimes-timeout: lock must be a private current-user regular file\n"
        );
        close(descriptor);
        return -1;
    }
    // Deliberately omit O_CLOEXEC: the command holds this advisory lock for
    // its complete lifetime. The watchdog removes any background descendants
    // before returning, so they cannot accidentally retain it indefinitely.
    return descriptor;
}

static void child_main(
    char *const command[],
    const char *lock_path,
    int stdout_file,
    int stderr_file
) {
    if (setpgid(0, 0) != 0) {
        _exit(125);
    }
    (void)signal(SIGTERM, SIG_DFL);
    (void)signal(SIGINT, SIG_DFL);
    (void)signal(SIGHUP, SIG_DFL);

    int null_input = open("/dev/null", O_RDONLY);
    if (null_input < 0
        || dup2(null_input, STDIN_FILENO) < 0
        || dup2(stdout_file, STDOUT_FILENO) < 0
        || dup2(stderr_file, STDERR_FILENO) < 0) {
        _exit(125);
    }
    if (null_input > STDERR_FILENO) {
        close(null_input);
    }
    if (stdout_file > STDERR_FILENO) {
        close(stdout_file);
    }
    if (stderr_file > STDERR_FILENO && stderr_file != stdout_file) {
        close(stderr_file);
    }

    struct rlimit output_limit = {
        .rlim_cur = output_limit_bytes,
        .rlim_max = output_limit_bytes,
    };
    (void)setrlimit(RLIMIT_FSIZE, &output_limit);

    int lock_descriptor = -1;
    if (lock_path != NULL) {
        lock_descriptor = acquire_child_lock(lock_path);
        if (lock_descriptor < 0) {
            _exit(75);
        }
    }

    execvp(command[0], command);
    int code = errno == ENOENT ? 127 : 126;
    perror("rimes-timeout: exec");
    if (lock_descriptor >= 0) {
        close(lock_descriptor);
    }
    _exit(code);
}

int main(int argc, char *argv[]) {
    if (argc == 2 && strcmp(argv[1], "--monotonic") == 0) {
        printf("%.0f\n", monotonic_seconds());
        return 0;
    }
    if (argc > 1 && strcmp(argv[1], "--lock-exec") == 0) {
        if (argc < 4) {
            fprintf(
                stderr,
                "usage: rimes-timeout --lock-exec <path> <command> [args...]\n"
            );
            return 2;
        }
        // Internal mode for a command that is already beneath another
        // rimes-timeout supervisor. Do not fork a nested process group: the
        // outer deadline must be able to terminate lock acquisition and every
        // later file operation as one tree, even when its global budget is
        // shorter than an inner nominal timeout.
        int lock_descriptor = acquire_child_lock(argv[2]);
        if (lock_descriptor < 0) {
            return 75;
        }
        execvp(argv[3], &argv[3]);
        int code = errno == ENOENT ? 127 : 126;
        perror("rimes-timeout: lock exec");
        close(lock_descriptor);
        return code;
    }

    const char *lock_path = NULL;
    int timeout_index = 1;
    int command_index = 2;
    if (argc > 1 && strcmp(argv[1], "--lock") == 0) {
        if (argc < 5) {
            fprintf(
                stderr,
                "usage: rimes-timeout [--lock path] <seconds> <command> [args...]\n"
            );
            return 2;
        }
        lock_path = argv[2];
        timeout_index = 3;
        command_index = 4;
    } else if (argc < 3) {
        fprintf(
            stderr,
            "usage: rimes-timeout [--lock path] <seconds> <command> [args...]\n"
        );
        return 2;
    }

    char *end = NULL;
    errno = 0;
    long timeout_seconds = strtol(argv[timeout_index], &end, 10);
    if (errno != 0 || end == argv[timeout_index] || *end != '\0'
        || timeout_seconds < 1 || timeout_seconds > 300) {
        fprintf(stderr, "rimes-timeout: seconds must be an integer from 1 to 300\n");
        return 2;
    }

    int stdout_file = create_output_file();
    int stderr_file = create_output_file();
    if (stdout_file < 0 || stderr_file < 0) {
        perror("rimes-timeout: temporary output");
        if (stdout_file >= 0) {
            close(stdout_file);
        }
        if (stderr_file >= 0) {
            close(stderr_file);
        }
        return 125;
    }

    struct sigaction action = {0};
    action.sa_handler = remember_signal;
    sigemptyset(&action.sa_mask);
    (void)sigaction(SIGTERM, &action, NULL);
    (void)sigaction(SIGINT, &action, NULL);
    (void)sigaction(SIGHUP, &action, NULL);

    pid_t child = fork();
    if (child < 0) {
        perror("rimes-timeout: fork");
        close(stdout_file);
        close(stderr_file);
        return 125;
    }
    if (child == 0) {
        child_main(
            &argv[command_index],
            lock_path,
            stdout_file,
            stderr_file
        );
    }

    // The child also calls setpgid; doing it from both sides closes the fork /
    // exec race. EACCES means it already exec'd after creating its own group.
    if (setpgid(child, child) != 0
        && errno != EACCES
        && errno != ESRCH) {
        perror("rimes-timeout: parent setpgid");
        terminate_group_bounded(child, false);
        emit_output(stdout_file, STDOUT_FILENO);
        emit_output(stderr_file, STDERR_FILENO);
        close(stdout_file);
        close(stderr_file);
        return 125;
    }

    const double deadline = monotonic_seconds() + (double)timeout_seconds;
    int return_code = 125;
    for (;;) {
        int status = 0;
        pid_t result = waitpid(child, &status, WNOHANG);
        if (result == child) {
            return_code = status_code(status);
            // A command can launch a background descendant and exit first.
            // Terminate the now leader-less group before releasing its lock.
            terminate_group_bounded(child, true);
            break;
        }
        if (result < 0 && errno != EINTR) {
            perror("rimes-timeout: waitpid");
            terminate_group_bounded(child, errno == ECHILD);
            return_code = 125;
            break;
        }
        if (forwarded_signal != 0) {
            int signal_number = forwarded_signal;
            terminate_group_bounded(child, false);
            return_code = 128 + signal_number;
            break;
        }
        if (monotonic_seconds() >= deadline) {
            terminate_group_bounded(child, false);
            return_code = 124;
            break;
        }
        pause_briefly();
    }

    emit_output(stdout_file, STDOUT_FILENO);
    emit_output(stderr_file, STDERR_FILENO);
    close(stdout_file);
    close(stderr_file);
    return return_code;
}
