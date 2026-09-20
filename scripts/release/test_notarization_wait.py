#!/usr/bin/env python3
"""Keep the notary wait observable: an id in the log and a bounded wait.

v0.5.1 submitted to Apple, printed nothing for 33 minutes, and was cancelled.
`notarytool submit --wait --output-format json >file` is why: the submission
id only appears when Apple answers, so a cancelled or timed-out job leaves no
handle to query and no way to separate a backlog from a rejection.
"""

import re
import subprocess
import unittest
from pathlib import Path


class NotarizationWaitTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.path = Path(__file__).resolve().parents[1] / "notarize-macos.sh"
        cls.script = cls.path.read_text()

    def test_submit_does_not_block_before_reporting_the_id(self):
        submit = re.search(r"notarytool submit [^\n]*(\n[^\n]*\\\n)*[^\n]*", self.script)
        self.assertIsNotNone(submit, "no notarytool submit call found")
        self.assertIn("--no-wait", submit.group(0))
        self.assertNotRegex(submit.group(0), r"(?<!-)\B--wait\b")

    def test_submission_id_is_printed_before_the_wait(self):
        echo = self.script.find('echo "notarize-macos: submission id=$submission_id')
        wait = self.script.find("notarytool wait ")
        self.assertNotEqual(echo, -1, "the submission id is never printed")
        self.assertNotEqual(wait, -1, "no notarytool wait call found")
        self.assertLess(echo, wait, "the id must reach the log before the wait begins")

    def test_the_wait_is_bounded(self):
        wait = re.search(r"notarytool wait [^\n]*(\n[^\n]*\\\n)*[^\n]*", self.script)
        self.assertIsNotNone(wait)
        self.assertIn('--timeout "$notary_timeout"', wait.group(0))
        self.assertIn('notary_timeout="${RIMES_NOTARY_TIMEOUT:-30m}"', self.script)

    def test_a_failed_or_timed_out_wait_reports_what_apple_knows(self):
        failure = self.script.split('if [[ "$wait_status" -ne 0', 1)
        self.assertEqual(len(failure), 2, "no failure branch after the wait")
        branch = failure[1].split("\nfi\n", 1)[0]
        self.assertIn('notarytool info "$submission_id"', branch)
        self.assertIn('notarytool log "$submission_id"', branch)
        self.assertIn("id=$submission_id", branch, "the id must survive into the error")

    def test_the_timeout_value_is_validated(self):
        guard = re.search(
            r'\[\[ "\$notary_timeout" =~ [^\n]*\n[^\n]*die "invalid RIMES_NOTARY_TIMEOUT[^\n]*',
            self.script,
        )
        self.assertIsNotNone(guard, "RIMES_NOTARY_TIMEOUT is not validated")
        for value, accepted in (("30m", True), ("90", True), ("2h", True),
                                ("", False), ("30 m", False), ("$(id)", False)):
            with self.subTest(value=value):
                shell = 'die() { exit 9; }\nnotary_timeout="$1"\n' + guard.group(0) + "\n"
                result = subprocess.run(
                    ["/bin/bash", "-c", shell, "bash", value],
                    capture_output=True, timeout=5,
                )
                self.assertEqual(result.returncode == 0, accepted)


if __name__ == "__main__":
    unittest.main()
