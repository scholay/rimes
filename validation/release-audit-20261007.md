# Public package audit — 2026-10-07

This audit compares public distribution with main and this maintenance patch.
A matching version string alone does not establish that later fixes are in a package.

| Platform | Public distribution | Source/build comparison |
|---|---|---|
| macOS | [1.1.0 (84)](https://github.com/scholay/rimes/releases/tag/v1.1.0), 2026-10-04 | BUILD-INFO source `3fa9e40`. Later Glass/Capsule, imported-scheme and installation-guidance fixes are absent. The local development bundle is not public-package evidence. |
| iOS | [App Store 1.1.0 (48)](https://apps.apple.com/us/app/lingxi-ime/id6814620242); external TestFlight 48 | Live ASC GET at 08:09 UTC: 1.1.1 (49) is valid but waiting for App Review and external beta review. Its source `958c030` precedes PR #89 clipboard and handoff fixes. Main still declares 1.1.0 (48); 49 used a build override. |
| Android | [1.1.0 / code12](https://github.com/scholay/rimes/releases/tag/android-v1.1.0), 2026-10-04 | APK runtime source `a641efc` / release tag source `3fa9e40`. Main code14 and subsequent clipboard fixes are newer. Code14's device checks do not establish that the public code12 APK contains them. |
| Windows | [1.1.1](https://github.com/scholay/rimes/releases/tag/windows-v1.1.1), 2026-10-07 07:19 UTC | Public package source `625616a`, frozen snapshot `a6908891…`; includes prior community fixes. This maintenance patch's Shift/Buffer repairs are newer and are absent from it. |
| Linux | [Platform data preview](https://github.com/scholay/rimes/releases/tag/platform-preview-v0.1.0), 2026-08-09 | This is scheme data, not the native Fcitx5 application. No public native .deb was found; successful native CI does not constitute a released installer. |

## Downloaded-artifact verification

macOS package SHA256SUMS and the current GitHub asset digest match the actual
PKG (`1fdc88d1725327aa29b0fe9ef1cc7c087fccdcb76ccf28d81564ddb0d671d415`).
The packaged app declares 1.1.0 (84), includes arm64/x86_64 and passes strict
codesign verification. The package signature, Gatekeeper notarization and
stapled ticket checks passed. These checks do not install the package.

Android APK and AAB match the actual downloaded files and SHA256SUMS. The APK
SHA-256 is `419bc875155a78af699508b39285ba3796407b54784f69f5f068b243307e55e6`;
its manifest declares version 1.1.0/code12. APK v2 signature verification passed
and its certificate matches BUILD-INFO. The AAB SHA-256 is
`08af73b3e99a0ea351ad3db01151918a2d36ca346ab2853118d8057de6b02855`.
This audit does not establish new device-install or typing acceptance.

### Windows

The actual public EXE and ZIP, BUILD-INFO and release notes were downloaded and
matched SHA256SUMS. ZIP integrity and all 109 PACKAGE.json file hashes/sizes passed.
Both packaged build-identity files agree with version 1.1.1, source `625616a`
and the published snapshot. The EXE SHA-256 is
`4ac890bf5a1ba860cba498a38ff75d6ec4de041b297ef2737cb6647316c616e2`;
the ZIP SHA-256 is
`9b5711237c3c551f2a68b8de6cfe5d36fa079b1307c7a7cc4b77720876958d23`.
This audit did not install or uninstall them. Their BUILD-INFO separately records
the actual EXE upgrade and Settings acceptance, while sign-out, full host typing,
and actual production uninstall remain pending.

The actual Linux data TAR matches its published checksum
(`48ecbbe57524988ab5173627a6a49fdf7538bfd371baf12069d922d523b7623e`).
Its 66 archive members contain scheme data and preview scripts; there is no
native .deb or .rpm. The archive was inspected without running its scripts.

## Issue disposition

#75 meets its stated candidate-count and vertical-layout requirements: the
settings controls, persistence, candidate-index layout and real Rime pagination
have regression evidence, and the feature is available in public Windows 1.1.1.
Closing that discrete request does not establish every host/DPI combination.

Keep #79/#83, #87, #67 and #93 open for their stated remaining scenarios.
Keep Linux #43/#44 and mobile #76 open; partial source fixes and simulated tests
are not completion of those reports. #3/#8 remain ongoing acceptance trackers,
#5 needs a reproduction, #90 still needs independent crash evidence, and new
feature #7 stays deferred. Already closed Android issues need no duplicate closure;
the old public APK still lacks their later code14 fixes.

No release was edited or published by this audit. New packages must be built from
the consolidated source and pass their platform installation/device gates.
