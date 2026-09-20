#!/usr/bin/env python3
"""Keep universality checks in the form every lipo accepts.

Xcode 27's lipo reads a second architecture after -verify_arch as another
input file and fails with "requires exactly one input file", so a genuinely
universal binary is reported as thin. Xcode 26.3 accepts the same line, which
is why CI never sees it and only local builds break.
"""

import re
import unittest
from pathlib import Path

ARCH = re.compile(r"^(arm64e?|x86_64|i386)$")
ROOT = Path(__file__).resolve().parents[2]
SHELL_SCRIPTS = sorted(
    [*ROOT.glob("scripts/*.sh"), *ROOT.glob("*.sh"), *ROOT.glob("scripts/pkg/scripts/*")]
)
# Each of these verifies a shipped binary is universal and must keep doing so.
UNIVERSAL_CHECKS = (
    "scripts/fetch-rime.sh",
    "scripts/make-pkg.sh",
    "scripts/rehearse-release-pkg.sh",
)


class LipoArchCheckTests(unittest.TestCase):
    def test_no_script_passes_two_architectures_to_verify_arch(self):
        for script in SHELL_SCRIPTS:
            if not script.is_file():
                continue
            for number, line in enumerate(script.read_text(errors="ignore").splitlines(), 1):
                match = re.search(r"-verify_arch\s+(.*)$", line)
                if not match:
                    continue
                archs = []
                for token in match.group(1).split():
                    if not ARCH.match(token):
                        break
                    archs.append(token)
                with self.subTest(script=script.relative_to(ROOT), line=number):
                    self.assertLessEqual(
                        len(archs), 1,
                        f"{script.relative_to(ROOT)}:{number} passes {archs} to one "
                        "-verify_arch; Xcode 27 rejects that. Use one call per arch.",
                    )

    def test_release_scripts_still_verify_both_architectures(self):
        for relative in UNIVERSAL_CHECKS:
            text = (ROOT / relative).read_text()
            for arch in ("arm64", "x86_64"):
                with self.subTest(script=relative, arch=arch):
                    # assertRegex would print the whole script on failure.
                    self.assertTrue(
                        re.search(rf"-verify_arch\s+{arch}\b", text),
                        f"{relative} no longer verifies {arch}",
                    )


if __name__ == "__main__":
    unittest.main()
