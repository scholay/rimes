"""Installer watchdog regressions, using real subprocess groups on macOS."""
import concurrent.futures
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[3]
SOURCE = ROOT / "scripts/pkg/helpers/rimes-timeout.c"


@unittest.skipUnless(os.uname().sysname == "Darwin", "Darwin installer helper")
class TimeoutTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.TemporaryDirectory(prefix="rimes-timeout-test-")
        cls.root = Path(cls.directory.name)
        cls.helpers = {}
        for mode in ("normal", "eperm-established", "eperm-denied", "eperm-denied-stop"):
            source = SOURCE
            if mode != "normal":
                source = cls.root / (mode + ".c")
                establish = "(void)setpgid(pid, group);" if mode == "eperm-established" else "(void)pid; (void)group;"
                if mode == "eperm-denied-stop":
                    establish += (' if (pid == 0) { int fd = open(getenv("RIMES_TEST_CHILD_PID"), O_WRONLY | O_CREAT, 0600);'
                                  ' if (fd >= 0) { (void)dprintf(fd, "%d\\n", getpid()); close(fd); } raise(SIGSTOP); }')
                source.write_text(
                    '#include <errno.h>\n#include <fcntl.h>\n#include <signal.h>\n#include <stdio.h>\n#include <stdlib.h>\n#include <sys/types.h>\n#include <unistd.h>\n'
                    'static int injected_setpgid(pid_t pid, pid_t group) {\n'
                    f'    {establish}\n'
                    '    errno = EPERM; return -1;\n}\n'
                    '#define setpgid injected_setpgid\n'
                    f'#include "{SOURCE}"\n'
                )
            helper = cls.root / mode
            subprocess.run(["clang", "-std=c11", "-Wall", "-Wextra", "-Werror", "-mmacosx-version-min=13.0", str(source), "-o", str(helper)], check=True)
            cls.helpers[mode] = helper

    @classmethod
    def tearDownClass(cls):
        cls.directory.cleanup()

    def run_helper(self, mode, *command, seconds=3):
        return subprocess.run([str(self.helpers[mode]), str(seconds), *command], capture_output=True, timeout=seconds + 3)

    def assert_process_retired(self, pid):
        deadline = time.monotonic() + 2
        while time.monotonic() < deadline:
            check = subprocess.run(["/bin/ps", "-p", str(pid), "-o", "stat="], capture_output=True, text=True)
            if check.returncode != 0 or check.stdout.strip().startswith("Z"):
                return
            time.sleep(0.025)
        self.fail(f"supervised descendant {pid} survived")

    def test_eperm_only_accepted_after_real_group_is_established(self):
        # Both the parent and child see EPERM, after actually creating the group.
        for mode in ("normal", "eperm-established"):
            result = self.run_helper(mode, "/bin/sh", "-c", 'group=$(/bin/ps -p $$ -o pgid=); test "$group" -eq "$$" || exit 99; echo grouped; exit 23')
            self.assertEqual(result.returncode, 23, result.stderr)
            self.assertEqual(result.stdout, b"grouped\n")

    def test_genuine_group_failure_rejects_command_and_reaps_child(self):
        marker = self.root / "must-not-execute"
        started = time.monotonic()
        result = self.run_helper("eperm-denied", "/usr/bin/touch", str(marker))
        self.assertEqual(result.returncode, 125, result)
        self.assertFalse(marker.exists())
        self.assertLess(time.monotonic() - started, 2)

    def test_genuine_failure_kills_a_child_stopped_before_group_creation(self):
        pid_file = self.root / "ungrouped-child.pid"
        environment = dict(os.environ, RIMES_TEST_CHILD_PID=str(pid_file))
        result = subprocess.run([str(self.helpers["eperm-denied-stop"]), "3", "/usr/bin/true"],
                                env=environment, capture_output=True, timeout=3)
        self.assertEqual(result.returncode, 125, result)
        self.assertTrue(pid_file.exists())
        self.assert_process_retired(int(pid_file.read_text().strip()))

    def test_fast_serial_parallel_and_nested_commands(self):
        for mode in ("normal", "eperm-established"):
            for _ in range(32):
                self.assertEqual(self.run_helper(mode, "/usr/bin/true").returncode, 0)
            with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
                results = list(pool.map(lambda _: self.run_helper(mode, "/usr/bin/true").returncode, range(64)))
            self.assertEqual(set(results), {0})
            for _ in range(16):
                self.assertEqual(self.run_helper(mode, str(self.helpers[mode]), "2", "/usr/bin/true").returncode, 0)

    def test_timeout_cleans_group_and_releases_lock_after_eperm(self):
        lock = self.root / "cleanup.lock"
        helper = self.helpers["eperm-established"]
        result = subprocess.run([str(helper), "--lock", str(lock), "1", "/bin/sh", "-c", 'trap "" TERM; /bin/sleep 30 & echo $!; wait'], capture_output=True, timeout=4)
        self.assertEqual(result.returncode, 124, result)
        self.assert_process_retired(int(result.stdout.strip()))
        self.assertEqual(subprocess.run([str(helper), "--lock", str(lock), "2", "/usr/bin/true"], capture_output=True, timeout=4).returncode, 0)

    def test_exited_leader_cleans_descendants_after_eperm(self):
        result = self.run_helper("eperm-established", "/bin/sh", "-c", '/bin/sleep 30 & echo $!')
        self.assertEqual(result.returncode, 0, result)
        self.assert_process_retired(int(result.stdout.strip()))

    def test_signal_cleans_group_after_eperm(self):
        pid_file = self.root / "signal-child.pid"
        helper = self.helpers["eperm-established"]
        with subprocess.Popen([str(helper), "5", "/bin/sh", "-c", f'trap "" TERM; /bin/sleep 30 & echo $! > "{pid_file}"; wait'], stdout=subprocess.PIPE, stderr=subprocess.PIPE) as child:
            deadline = time.monotonic() + 2
            while not pid_file.exists() and time.monotonic() < deadline:
                time.sleep(0.025)
            self.assertTrue(pid_file.exists())
            child.send_signal(signal.SIGTERM)
            child.communicate(timeout=3)
            self.assertEqual(child.returncode, 128 + signal.SIGTERM)
        self.assert_process_retired(int(pid_file.read_text().strip()))

    def test_nested_lock_exec_remains_owned_by_outer_timeout(self):
        helper = self.helpers["eperm-established"]
        result = self.run_helper("eperm-established", str(helper), "--lock-exec", str(self.root / "outer.lock"), "/bin/sh", "-c", 'trap "" TERM; /bin/sleep 30 & echo $!; wait', seconds=1)
        self.assertEqual(result.returncode, 124, result)
        self.assert_process_retired(int(result.stdout.strip()))

    def test_command_may_write_its_own_files_past_the_output_bound(self):
        # The installed RIMES executable appends to a multi-megabyte log and can copy user
        # data during --install. A file-size rlimit killed it with SIGXFSZ (status 153).
        written = self.root / "command-owned.bin"
        result = self.run_helper("normal", "/bin/dd", "if=/dev/zero", f"of={written}", "bs=1024", "count=1024")
        self.assertEqual(result.returncode, 0, result)
        self.assertEqual(written.stat().st_size, 1024 * 1024)

    def test_runaway_captured_output_is_terminated_and_relay_is_bounded(self):
        for stream in ("", " >&2"):
            started = time.monotonic()
            result = self.run_helper("normal", "/bin/sh", "-c", f'trap "" TERM; /usr/bin/yes rimes-timeout-flood{stream} & echo $! > "{self.root / "flood.pid"}"; wait')
            self.assertEqual(result.returncode, 125, result.stderr[-200:])
            self.assertLess(time.monotonic() - started, 3)
            self.assertLessEqual(len(result.stdout), 256 * 1024)
            self.assertLessEqual(len(result.stderr), 256 * 1024 + 128)
            self.assertIn(b"captured output exceeded", result.stderr)
            self.assert_process_retired(int((self.root / "flood.pid").read_text().strip()))


if __name__ == "__main__":
    unittest.main()
