# Public package refresh, 2026-10-07

This record follows the [pre-refresh package audit](release-audit-20261007.md), which remains a historical snapshot. Source was integrated by PR #100 as `41d38d0788714bf783bd6ad18dcd403e48e0c9f2`. Mobile and Windows build source `6d2227335c0ffd2a0240f10db406410cab2fe86f` is preserved as an ancestor of that merge; their tracked trees are identical.

| Platform | Public state | Refresh evidence |
| --- | --- | --- |
| Android | [1.1.1 / code15](https://github.com/scholay/rimes/releases/tag/android-v1.1.1) | Published 2026-10-07 09:24:50 UTC. Exact production APK upgraded the Xiaomi 17 Pro running Android 16 from 1.1.0/code12 without clearing data. Public downloads match the accepted files. |
| macOS | 1.1.0 remains public; 1.1.1 in progress | Formal tag v1.1.1 targets main `41d38d0`; build/sign/notarize/staged-package installation/publication follow the protected release workflow. A tag is not a public installer. |
| Windows | 1.1.1 remains public; 1.1.2 draft | Exact x64/x86 source freeze built and verified on YOUNG-HOME. Actual production upgrade acceptance remains pending; the old Broker must exit after preserving unsent Buffer content. |
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
