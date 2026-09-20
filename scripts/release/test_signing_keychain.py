#!/usr/bin/env python3
"""Exercise keychain registration without certificates or a real keychain."""

import shlex
import subprocess
import unittest
from pathlib import Path


class SigningKeychainTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.script = (Path(__file__).resolve().parents[1] / "sign-import-certificates.sh").read_text()
        body = cls.script.split("add_signing_keychain_to_search_list() {\n", 1)[1].split("\n}\n", 1)[0]
        cls.function = ("add_signing_keychain_to_search_list() {\n" + body + "\n}\n").replace(
            "/usr/bin/security", "mock_security"
        )

    def register(self, current, read_status=0, write_status=0):
        shell = self.function + """
set -eu
die() { printf '%s\\n' "$*" >&2; exit 1; }
mock_security() {
    [[ "$1" == list-keychains && "$2" == -d && "$3" == user ]] || exit 90
    if [[ "$#" -eq 3 ]]; then
        printf '%s\\n' "$current"
        return "$read_status"
    fi
    [[ "$4" == -s ]] || exit 91
    shift 4
    printf '%s\\n' "$@"
    return "$write_status"
}
"""
        shell += f"current={shlex.quote(current)}\nread_status={read_status}\nwrite_status={write_status}\n"
        shell += 'add_signing_keychain_to_search_list "/temporary/signing keychain-db"\n'
        return subprocess.run(["/bin/bash", "-c", shell], capture_output=True, text=True, timeout=5)

    def test_preserves_existing_entries_and_spaces(self):
        result = self.register('    "/user/login.keychain-db"\n    "/other/with spaces.keychain-db"')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), [
            "/temporary/signing keychain-db", "/user/login.keychain-db", "/other/with spaces.keychain-db"
        ])

    def test_temporary_entry_is_not_duplicated(self):
        result = self.register('    "/temporary/signing keychain-db"\n    "/user/login.keychain-db"')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), ["/temporary/signing keychain-db", "/user/login.keychain-db"])

    def test_empty_search_list_is_supported(self):
        result = self.register("")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), ["/temporary/signing keychain-db"])

    def test_read_failure_does_not_replace_the_search_list(self):
        result = self.register("", read_status=1)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")

    def test_malformed_output_is_rejected_without_a_write(self):
        result = self.register("unquoted /user/login.keychain-db")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")

    def test_write_failure_is_not_ignored(self):
        self.assertNotEqual(self.register("", write_status=1).returncode, 0)

    def test_import_registers_keychain_and_checks_code_signing_policy(self):
        register = self.script.index('add_signing_keychain_to_search_list "$keychain"')
        first_import = self.script.index('/usr/bin/security import "$application_p12"')
        first_emit = self.script.index('emit_env RIMES_SIGNING_TEMP_DIR')
        policy = self.script.index('find-identity -v -p codesigning "$keychain"')
        self.assertLess(register, first_import)
        self.assertLess(policy, first_emit)
        self.assertNotIn("security default-keychain", self.script)


if __name__ == "__main__":
    unittest.main()
