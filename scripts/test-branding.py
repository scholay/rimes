#!/usr/bin/env python3
"""Display-name migration checks; intentionally freeze installed identities."""
import pathlib
import plistlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
NAMES = {"en": "XSIME", "zh-Hans": "犀术IME", "zh-Hant": "犀術IME"}

def text(path):
    return (ROOT / path).read_text()

class BrandingTests(unittest.TestCase):
    def test_macos_identity_is_not_brand(self):
        with (ROOT / "Info.plist").open("rb") as f:
            p = plistlib.load(f)
        self.assertEqual(p["CFBundleDisplayName"], "XSIME")
        self.assertEqual(p["CFBundleExecutable"], "RIMES")
        self.assertEqual(p["CFBundleIdentifier"], "com.scholay.inputmethod.isaac")
        self.assertEqual(p["TISInputSourceID"], "com.scholay.inputmethod.isaac")
        self.assertEqual(p["InputMethodConnectionName"], p["CFBundleIdentifier"] + "_Connection")
        self.assertEqual(p["InputMethodServerControllerClass"], "RIMESController")
        mode = p["ComponentInputModeDict"]["tsInputModeListKey"]["com.scholay.inputmethod.isaac.Hans"]
        self.assertEqual(mode["TISInputSourceID"], "com.scholay.inputmethod.isaac.Hans")
        self.assertEqual(mode["tsInputModeAlternateMenuTitleKey"], "XSIME")
        for fragment in ['productName = "RIMES"', 'directoryName = "RIMES"', 'preferenceKeyPrefix = "RIMES."']:
            self.assertIn(fragment, text("Sources/RimeBuffer/RimesPaths.swift"))

    def test_localized_names(self):
        for locale, name in NAMES.items():
            for directory in ["Resources", "platforms/ios/App", "platforms/ios/Keyboard"]:
                resource = text(f"{directory}/{locale}.lproj/InfoPlist.strings")
                self.assertIn(f'"CFBundleDisplayName" = "{name}";', resource)
            store_locale = "en-US" if locale == "en" else locale
            self.assertEqual(text(f"platforms/ios/AppStore/metadata/{store_locale}/name.txt").strip(), name)
        for qualifier, name in [("values", "XSIME"), ("values-zh", "犀术IME"), ("values-b+zh+Hant", "犀術IME")]:
            self.assertIn(f'<string name="app_name">{name}</string>', text(f"platforms/android/app/src/main/res/{qualifier}/strings.xml"))

    def test_mobile_identity(self):
        project = text("platforms/ios/project.yml")
        for identity in ["org.scholay.rimes.ios", "org.scholay.rimes.ios.keyboard", "group.org.scholay.rimes.ios", "org.scholay.rimes.ios.shared"]:
            self.assertIn(identity, project)
        self.assertIn('applicationId = "org.scholay.rimes.android"', text("platforms/android/app/build.gradle.kts"))
        for path in ["rime-data/lingxi_wubi.schema.yaml", "platforms/ios/Resources/EngineData/lingxi_wubi.schema.yaml"]:
            self.assertIn("schema_id: lingxi_wubi", text(path))

    def test_windows_and_linux_identity(self):
        # Windows PowerShell 5.1 decodes BOM-less scripts using the ANSI code page.
        self.assertTrue((ROOT / "platforms/windows/installer/Package.Common.ps1").read_bytes().startswith(b"\xef\xbb\xbf"))
        guid = text("platforms/windows/native/src/tsf/Guids.h")
        self.assertIn("{0B2C570B-9811-45DF-989B-EA306281F6B4}", guid)
        self.assertIn("{CD791B35-640F-4F1C-A3D3-624099E15ACB}", guid)
        self.assertIn('kDllFileName[] = L"RimesTsf.dll"', guid)
        self.assertIn("CurrentVersion\\Uninstall\\RIMES", text("platforms/windows/installer/Package.Common.ps1"))
        for line in ["Icon=rimes", "Addon=rimes", "Name=XSIME", "Name[zh_CN]=犀术IME", "Name[zh_TW]=犀術IME"]:
            self.assertIn(line, text("platforms/linux/ime/data/rimes.conf.in"))
        self.assertIn("Exec=rimes-schemes", text("platforms/linux/ime/data/org.scholay.rimes.schemes.desktop"))

    def test_updater_keeps_package_contract(self):
        source = text("Sources/RimeBuffer/UpdateManager.swift")
        for fragment in ['repositoryID = "1327328463"', '["rimes", "xsime"]', 'githubRepo = "xsime"', 'return "RIMES-\\(version).pkg"', 'matchingAssets.count == 1']:
            self.assertIn(fragment, source)

    def test_official_homepage_does_not_change_compatibility_links(self):
        for path in ["Sources/RimeBuffer/SettingsWindow.swift",
                     "platforms/android/app/src/main/java/org/scholay/rimes/android/SetupActivity.java",
                     "platforms/windows/installer/Package.Common.ps1",
                     "platforms/linux/ime/data/org.fcitx.Fcitx5.Addon.Rimes.metainfo.xml.in",
                     "platforms/linux/ime/scripts/package-deb.sh"]:
            self.assertIn("https://xsime.com", text(path))
        package = text("platforms/linux/ime/scripts/package-deb.sh")
        self.assertIn("Package: fcitx5-rimes", package)
        self.assertIn("~/.local/share/rimes", package)
        for locale in ["en-US", "zh-Hans", "zh-Hant"]:
            self.assertIn("scholay.github.io/rimes/ios/", text(
                f"platforms/ios/AppStore/metadata/{locale}/privacy_url.txt"))

    def test_ci_and_release_agree_on_display_and_executable(self):
        for workflow in ["ci.yml", "release.yml"]:
            source = text(".github/workflows/" + workflow)
            self.assertIn('test "$DISPLAY_NAME" = \'XSIME\'', source)
            self.assertIn('test "$MENU_TITLE" = \'XSIME\'', source)
            self.assertIn('test "$EXECUTABLE" = \'RIMES\'', source)
            for name in NAMES.values():
                self.assertIn('EXPECTED_NAME="' + name + '"', source)

if __name__ == "__main__":
    unittest.main()
