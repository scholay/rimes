#!/usr/bin/env python3
"""Verify independent Windows patch releases preserve the shared product baseline."""
import importlib.util
import plistlib
import tempfile
import unittest
from pathlib import Path


SPEC = importlib.util.spec_from_file_location(
    'check_product_versions', Path(__file__).with_name('check-product-versions.py'))
VERSIONS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VERSIONS)


class ProductVersionTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.windows = self.root / 'windows-worktree'
        self.write_baseline('1.1.0')
        self.windows_base = self.windows / 'platforms/windows/native'
        self.write(self.windows_base / 'VERSION', '1.1.0\n')
        self.write(self.windows_base / 'CMakeLists.txt',
                   'file(READ "${CMAKE_CURRENT_SOURCE_DIR}/VERSION" RIMES_PRODUCT_VERSION)\n'
                   'project(RIMESWindows VERSION ${RIMES_PRODUCT_VERSION} LANGUAGES CXX)\n')

    def write(self, path, content):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)

    def write_baseline(self, version):
        self.write(self.root / 'VERSION', version + '\n')
        (self.root / 'Info.plist').write_bytes(plistlib.dumps(
            {'CFBundleShortVersionString': version}))
        self.write(self.root / 'platforms/ios/project.yml',
                   f'  MARKETING_VERSION: "{version}"\n  CURRENT_PROJECT_VERSION: "48"\n')
        self.write(self.root / 'platforms/ios/RIMES.xcodeproj/project.pbxproj',
                   f'MARKETING_VERSION = {version};\nCURRENT_PROJECT_VERSION = 48;\n')
        self.write(self.root / 'platforms/android/VERSION', version + '\n')
        self.write(self.root / 'platforms/android/app/build.gradle.kts',
                   'val rimesVersion = rootProject.file("VERSION").readText().trim()\n'
                   'versionName = rimesVersion\nversionCode = 48\n')

    def check(self):
        return VERSIONS.check(self.root, self.root, self.windows, require_all=True)

    def test_matching_versions_pass(self):
        result = self.check()
        self.assertEqual(result['windows'], {'version': '1.1.0', 'fileVersion': '1.1.0.0'})

    def test_windows_patch_advance_preserves_other_product_versions(self):
        self.write(self.windows_base / 'VERSION', '1.1.1\n')
        result = self.check()
        self.assertEqual(result['target'], '1.1.0')
        self.assertEqual(result['macos']['version'], '1.1.0')
        self.assertEqual(result['ios']['version'], '1.1.0')
        self.assertEqual(result['android']['version'], '1.1.0')
        self.assertEqual(result['windows'], {'version': '1.1.1', 'fileVersion': '1.1.1.0'})

    def test_patch_versions_compare_numerically(self):
        self.write_baseline('1.1.9')
        self.write(self.windows_base / 'VERSION', '1.1.10\n')
        self.assertEqual(self.check()['windows']['version'], '1.1.10')

    def test_windows_patch_rollback_is_rejected(self):
        self.write_baseline('1.1.2')
        self.write(self.windows_base / 'VERSION', '1.1.1\n')
        with self.assertRaisesRegex(ValueError, 'Windows patch version must not be lower'):
            self.check()

    def test_windows_cannot_change_major_or_minor_line(self):
        for version in ('1.2.0', '1.0.99', '2.1.0', '0.1.99'):
            with self.subTest(version=version):
                self.write(self.windows_base / 'VERSION', version + '\n')
                with self.assertRaisesRegex(ValueError, 'Windows VERSION must stay'):
                    self.check()

    def test_windows_requires_strict_product_semver(self):
        for version in ('01.1.0', '1.01.0', '1.1.01', '1.1', '1.1.1.0',
                        '1.1.1-preview.1', '1.1.1+build', 'v1.1.1', '-1.1.1',
                        '1.1.1\n1.1.2', ''):
            with self.subTest(version=version):
                self.write(self.windows_base / 'VERSION', version + '\n')
                with self.assertRaisesRegex(ValueError, 'Windows VERSION must be'):
                    self.check()

    def test_cmake_must_read_and_consume_windows_version(self):
        for cmake in (
            'project(RIMESWindows VERSION 1.1.1 LANGUAGES CXX)\n',
            'set(RIMES_PRODUCT_VERSION "1.1.1")\n'
            'project(RIMESWindows VERSION ${RIMES_PRODUCT_VERSION} LANGUAGES CXX)\n',
            'file(READ "${CMAKE_CURRENT_SOURCE_DIR}/VERSION" RIMES_PRODUCT_VERSION)\n'
            'project(RIMESWindows VERSION 1.1.1 LANGUAGES CXX)\n',
        ):
            with self.subTest(cmake=cmake):
                self.write(self.windows_base / 'CMakeLists.txt', cmake)
                with self.assertRaisesRegex(ValueError, 'Windows must consume its VERSION'):
                    self.check()

    def test_android_still_requires_the_shared_baseline(self):
        self.write(self.root / 'platforms/android/VERSION', '1.1.1\n')
        with self.assertRaisesRegex(ValueError, 'Android version drift'):
            self.check()

    def test_macos_and_ios_still_require_the_shared_baseline(self):
        (self.root / 'Info.plist').write_bytes(plistlib.dumps(
            {'CFBundleShortVersionString': '1.1.1'}))
        with self.assertRaisesRegex(ValueError, 'macOS Info.plist version drift'):
            self.check()
        self.write_baseline('1.1.0')
        self.write(self.root / 'platforms/ios/project.yml',
                   '  MARKETING_VERSION: "1.1.1"\n  CURRENT_PROJECT_VERSION: "48"\n')
        with self.assertRaisesRegex(ValueError, 'iOS project.yml version drift'):
            self.check()


if __name__ == '__main__':
    unittest.main()
