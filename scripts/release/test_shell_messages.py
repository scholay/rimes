#!/usr/bin/env python3
"""Keep localized release diagnostics safe under macOS Bash 3.2 nounset."""

import re
import subprocess
import unittest
from pathlib import Path


class LocalizedShellMessageTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.script = (Path(__file__).resolve().parents[1] / "release.sh").read_text()

    def test_braces_delimit_variables_before_non_ascii_punctuation(self):
        self.assertNotRegex(self.script, r"\$[A-Za-z_][A-Za-z_0-9]*[^\x00-\x7f]")

    def test_all_ci_gate_messages_expand_with_nounset_enabled(self):
        messages = re.findall(r'"([^"\n]*\$\{workflow\}[^"\n]*)"', self.script)
        self.assertEqual(len(messages), 3)
        for message in messages:
            with self.subTest(message=message):
                result = subprocess.run(
                    ["/bin/bash", "-uc", 'workflow=CI; printf "%s\\n" "' + message + '"'],
                    capture_output=True, text=True, timeout=5,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("「CI」", result.stdout)


if __name__ == "__main__":
    unittest.main()
