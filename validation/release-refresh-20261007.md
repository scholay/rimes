# Public package refresh, 2026-10-07

This record follows the [pre-refresh package audit](release-audit-20261007.md), which remains a historical snapshot. Source was integrated by PR #100 as `41d38d0788714bf783bd6ad18dcd403e48e0c9f2`. Mobile and Windows build source `6d2227335c0ffd2a0240f10db406410cab2fe86f` is preserved as an ancestor of that merge; their tracked trees are identical.

| Platform | Public state | Refresh evidence |
| --- | --- | --- |
| Android | [1.1.1 / code15](https://github.com/scholay/rimes/releases/tag/android-v1.1.1) | Published 2026-10-07 09:24:50 UTC. Exact production APK upgraded the Xiaomi 17 Pro running Android 16 from 1.1.0/code12 without clearing data. Public downloads match the accepted files. |
| macOS | [1.1.1 / build99](https://github.com/scholay/rimes/releases/tag/v1.1.1) | Published 2026-10-07 10:01:14 UTC after normal signing and publication gates. The signed, notarized universal PKG passed local GUI installation and installed-bundle verification. Anonymous public downloads match the accepted package. |
| Windows | 1.1.1 remains public; 1.1.2 draft | Exact x64/x86 source freeze built and verified on YOUNG-HOME. GUI upgrade from 1.1.1 succeeded and retained all 11 dictionary/settings files byte-for-byte. Installed files, registrations and launcher entries verified. Installer requires Windows restart; post-restart runtime acceptance is pending. |
| iOS | App Store 1.1.0/build48 | 1.1.1/build49 remains waiting for review. Build50 was uploaded and processed as VALID, and a development-signed export of the same archive was installed on the test iPhone. Device acceptance and review replacement remain pending. |
| Linux | Experimental scheme-data preview | There is no public native stable Linux installer. This refresh does not promote the existing data preview to one. |

## Android accepted public package

- Source: `6d2227335c0ffd2a0240f10db406410cab2fe86f`; official plugins `aecf9c1f505ac83934b01c28c59a29f99707d199`.
- Version: 1.1.1/code15, production ID `org.scholay.rimes.android`.
- Production certificate SHA-256: `e6228d5b065f1f8c2f1e1162b80ea1a9245ce59a091bb6e403e47936c3820c54`, unchanged from previous public APKs.
- APK SHA-256: `ababb97e32ed9281381d4de18f9256d52994929650d96a1f422bf636759fc1a4`.
- AAB SHA-256: `0c379a02347deb0f2cc6b7bf9ea8a38cf75db91dc45d3acbbb380ec952fd1e2c`.
- Core tests, release lint, signature, ZIP alignment and 16 KB native library alignment checks passed.
- In-place upgrade retained the existing installation; the pulled installed base APK is byte-identical to the release APK. Real soft-key input `nihao` showed and committed `你好`; Buffer toggled normally and was unavailable in a password field.
- Explicit clipboard collection saved the test text only after Collect. Selecting it staged one block in Buffer while the target field stayed empty. Explicit Insert committed to the active second field. Deleting the single test history record passed.
- The 12 previously pending synthetic filesystem assertions now passed on the same device using an isolated host. All three source hashes match main: private modes, reopen/delete/clear, corrupted JSON, AtomicFile backup recovery and symbolic-link refusal. The two temporary test packages were removed; no production clipboard store was read by that test.
- All four public assets (APK, AAB, BUILD-INFO.json, SHA256SUMS) were downloaded without authentication and matched local SHA-256 values. Release metadata and tag point to the recorded build source.

Other Android vendors, long-duration use and iPhone paste/keyboard interaction are separate coverage. No new paid AI request was issued during this package acceptance. Issue #76 retains its iOS acceptance requirement.

## macOS accepted public package

- Workflow [37599723640](https://github.com/scholay/rimes/actions/runs/37599723640), artifact `11473483489` (`RIMES-1.1.1-signed-stage-37599723640-1`).
- Immutable archive SHA-256: `bd94bfb84644d04a465c0ab4fc88792230fa49b5905ffbe84fa37952e3089184`.
- Exact package SHA-256: `1619ff281b788aeabe92a1c9f241c7a706ab4ab3797122085d028aa455658783`, 122,769,532 bytes.
- Manifest binds main `41d38d0`, v1.1.1 and the workflow run. Package and notes hashes match it. Local `rehearse-release-pkg.sh` passive checks passed for Developer ID Application/Installer, team identity, hardened runtime, universal architectures, Gatekeeper and stapled notarization.
- GUI installation of that exact package on macOS 27.0 (26A428) completed after native administrator authorization. `rehearse-release-pkg.sh --install-gui` passed, the PackageKit receipt reports 1.1.1, and `/Library/Input Methods/RIMES.app` reports 1.1.1/build99. One canonical process runs from the system bundle. The foreground input source was ABC at readback; this is installation verification, not a new host-app typing acceptance.
- Both protected release gates were approved in their normal order after verification. The workflow completed successfully and published v1.1.1 as latest; main stayed frozen throughout. The public PKG and SHA256SUMS were downloaded without authentication and matched the exact locally installed staged bytes. The old v1.1.0 release remains available.
- macOS 27 sandboxed WeChat/QQ host crashes in issue #90 remain under investigation; this release does not claim that issue resolved.

## Windows upgrade acceptance

- Exact build source `6d22273`; frozen source snapshot `40de2e9f37aff692af91b4f0ce506b4e6a9e9b8a5fb03770eae844c1e215aedc`.
- EXE SHA-256 `2444c237a22c10e14cc7cb66e85d4cee2658434db68be614251a39a80f121821`; ZIP SHA-256 `ea3cd5dae5686f169187b5f4cf93bacabcd562fdb6f5161eeaf4e1cf69c23318`.
- x64/x86 native builds and 18 tests per architecture passed; real librime product probes, simulated TSF probes, 38 installer sandbox checks and 16 registrar recovery checks passed. Exact EXE payload and all 109 manifest files were verified.
- The old Buffer was visibly empty and the old Broker exited through its tray menu. The exact final EXE upgraded the real installation from 1.1.1 to 1.1.2 with exit code 0. All 11 pre-existing dictionary/settings files retained their hashes. Installed verification passed for both registrations, and Installed Apps/Start Menu entries point to the new version.
- Installer requests Windows restart; `requiresSignOut=true` and post-restart runtime acceptance remains pending. No restart or sign-out was forced. The new release is still a draft. Cross-account installation, damaged-install full lifecycle and physical Ctrl-shortcut behavior remain separate coverage.
