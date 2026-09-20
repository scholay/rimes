#!/usr/bin/env python3
"""Test the actual GUI receipt wait without opening Installer or installing."""

import shlex
import subprocess
import unittest
from pathlib import Path


class ReceiptWaitTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.script = (Path(__file__).resolve().parents[1] / "rehearse-release-pkg.sh").read_text()
        body = cls.script.split("wait_for_install_receipt() {\n", 1)[1].split("\n}\n", 1)[0]
        cls.function = "wait_for_install_receipt() {\n" + body + "\n}\n"

    def wait(self, before, samples):
        shell = self.function + """
set -eu
sample_index=0
SECONDS=0
read_install_receipt() { printf '%s' "${samples[$sample_index]}"; }
sleep() {
    if (( sample_index + 1 < ${#samples[@]} )); then sample_index=$((sample_index + 1)); fi
    SECONDS=$((SECONDS + 1))
}
"""
        shell += "samples=(" + " ".join(shlex.quote(value) for value in samples) + ")\n"
        shell += "wait_for_install_receipt " + shlex.quote(before) + " 0.5.0 3\n"
        return subprocess.run(["/bin/bash", "-c", shell], capture_output=True, timeout=5).returncode

    def test_updated_receipt_finishes_without_waiting_for_installer_to_quit(self):
        self.assertNotIn('/usr/bin/open -W "$package_path"', self.script)
        before = "version: 0.5.0\ninstall-time: 1"
        after = "version: 0.5.0\ninstall-time: 2"
        self.assertEqual(self.wait(before, [before, after]), 0)

    def test_fresh_install_can_start_without_a_receipt(self):
        self.assertEqual(self.wait("", ["", "version: 0.5.0\ninstall-time: 2"]), 0)

    def test_unchanged_missing_or_wrong_version_receipts_time_out(self):
        before = "version: 0.5.0\ninstall-time: 1"
        for sample in (before, "", "version: 0.5.1\ninstall-time: 2", "version: 0.5.0-preview.1"):
            with self.subTest(sample=sample):
                self.assertEqual(self.wait(before, [sample]), 1)


if __name__ == "__main__":
    unittest.main()
