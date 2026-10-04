#!/usr/bin/env python3
"""Check the four product anchors without modifying, building or publishing."""
import argparse
import json
import plistlib
import re
from pathlib import Path


def require(condition, message):
    if not condition:
        raise ValueError(message)


def check(root, android=None, windows=None, require_all=False):
    version = (root / 'VERSION').read_text().strip()
    require(re.fullmatch(r'(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)', version),
            'VERSION must be MAJOR.MINOR.PATCH without a preview suffix')
    plist = plistlib.loads((root / 'Info.plist').read_bytes())
    require(plist['CFBundleShortVersionString'] == version, 'macOS Info.plist version drift')
    ios = root / 'platforms/ios'
    spec = (ios / 'project.yml').read_text()
    marketing = re.findall(r"^\s+MARKETING_VERSION: ['\"]([^'\"]+)['\"]", spec, re.M)
    build = re.findall(r"^\s+CURRENT_PROJECT_VERSION: ['\"]([0-9]+)['\"]", spec, re.M)
    require(marketing == [version] and len(build) == 1, 'iOS project.yml version drift')
    project = (ios / 'RIMES.xcodeproj/project.pbxproj').read_text()
    require(set(re.findall(r'MARKETING_VERSION = ([^;]+);', project)) == {version},
            'Generated Xcode project marketing version drift')
    require(set(re.findall(r'CURRENT_PROJECT_VERSION = ([^;]+);', project)) == {build[0]},
            'Generated Xcode project build number drift')
    result = {'target': version, 'macos': {'version': version},
              'ios': {'version': version, 'build': int(build[0])},
              'linux': 'excluded; unchanged'}
    if android:
        base = android / 'platforms/android'
        require((base / 'VERSION').read_text().strip() == version, 'Android version drift')
        gradle = (base / 'app/build.gradle.kts').read_text()
        require('versionName = rimesVersion' in gradle and 'rootProject.file("VERSION")' in gradle,
                'Android must consume its VERSION anchor')
        codes = re.findall(r'versionCode = ([0-9]+)', gradle)
        require(len(codes) == 1, 'Android build code missing or ambiguous')
        result['android'] = {'version': version, 'versionCode': int(codes[0])}
    if windows:
        base = windows / 'platforms/windows/native'
        require((base / 'VERSION').read_text().strip() == version, 'Windows version drift')
        cmake = (base / 'CMakeLists.txt').read_text()
        require('project(RIMESWindows VERSION ${RIMES_PRODUCT_VERSION}' in cmake,
                'Windows must consume its VERSION anchor')
        result['windows'] = {'version': version, 'fileVersion': version + '.0'}
    if require_all:
        require(android is not None and windows is not None,
                'Supply --android-root and --windows-root for the active platform worktrees')
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument('--android-root', type=Path)
    parser.add_argument('--windows-root', type=Path)
    parser.add_argument('--require-all', action='store_true')
    args = parser.parse_args()
    try:
        print(json.dumps(check(args.root, args.android_root, args.windows_root, args.require_all),
                         ensure_ascii=False, indent=2))
    except (OSError, ValueError, KeyError) as error:
        parser.exit(1, f'VERSION CHECK FAILED: {error}\n')
