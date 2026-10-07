# Windows community repair — 2026-10-07

Baseline: `4e59ae12b54d575986f58ae385d8e3bd3e3cdf7b` (`origin/main`).
Implementation tested: `bf44117f57714fa1dd8f32e556f9a89ca6454699`.
Work branch: `codex/windows-community-repair-20261007`.

## Scope and contribution history

| Record | Change | Acceptance boundary |
| --- | --- | --- |
| [#79](https://github.com/scholay/rimes/issues/79), [#83](https://github.com/scholay/rimes/issues/83) | Recover a missing/corrupt state from actual owned registration; repair only missing immutable package files; remove owned dangling registrations using verified current registrar tools even when an installed DLL is absent. | Installer fixtures and a separate real TSF identity are tested. The released 1.1.0 installer and a user's externally damaged production installation were not modified. |
| [#75](https://github.com/scholay/rimes/issues/75) | Appearance → Size exposes candidate count 1–9 and vertical layout. Count changes real librime pagination; vertical overflow uses columns within monitor geometry without dropping candidate indexes. | Native settings/layout fixtures and real-engine page-size checks; real desktop visual acceptance remains separate. |
| [PR #82](https://github.com/scholay/rimes/pull/82) | Keep the last known caret during transient host failures; hide before the first reliable caret; retire cached placement on focus/context changes. | Original contributor commit retained, plus simulated TSF focus/caret regressions. Interactive host reproduction remains separate. |
| [#67](https://github.com/scholay/rimes/issues/67) | Existing main implementation detaches the ordinary Broker console and retains diagnostic CLI output. No duplicate code change in this batch. | Prior cold-launch evidence is recorded in the [earlier report](2026-10-07-feedback.md). Actual sign-out and login were not performed; keep that gate open. |

[PR #77](https://github.com/scholay/rimes/pull/77) was closed without merging.
This implementation does not select a retained directory by date or lexical order.
The original PR #82 commit `ac316a881e95c8e3d6d139725ec7662f3e80c78c`
remains an ancestor; merge `2bdd330` retains its author and existing trailer.
CONTRIBUTORS credits XyTT2N2bTc and OpenCode. The historical OpenCode email
was not added to the verified commit-identity list.

## Recovery boundaries

- Recovery targets the fixed RIMES CLSID's exact registered DLL paths, validates
  the direct immutable version directory and architecture, and refuses mixed
  versions or paths outside the supplied managed root.
- Surviving manifested files must match their hashes. Repair cannot overwrite
  changed bytes or accept reparse points, including a dangling file symlink.
- A missing manifest is accepted for cleanup only when actual complete RIMES
  registration still identifies the exact managed immutable directory. No
  search for the newest directory is used. Verification still requires a complete
  package. Missing current uninstall tools produce repair guidance before mutation.
- Native unregister compares the provided absolute path with the current COM
  registration even if the DLL is absent. Without either architecture's ownership
  evidence, it refuses to delete an orphaned shared TSF profile.
- The tests do not stop the daily Broker, uninstall the daily IME, change its
  files or language preference, terminate user apps, sign out, or reboot.

## Exact-source test identity

- Trusted SSH host readback: `YOUNG-HOME`.
- Source directory: `D:\AI\rimes-community-repair-20261007\source-bf44117-v3`.
- Source ZIP SHA-256: `3473fbda1fda8d93c29e9305f0c61cb5407725266bbf6c82ef3854b316b36604`.
- Source snapshot SHA-256: `937f35198f4fdf1250d31e3611d4f3fda6d44ad91face2406b5066450e2b13c6`.
- OfficialPlugins remained pinned to `aecf9c1f505ac83934b01c28c59a29f99707d199`.
  The transfer includes hash-checked prepared Windows imports. Every source file
  is checked after transfer; timestamps are normalized before MSBuild.

Commands use CMake `windows-x64` / `windows-x86` configure presets, Release build
presets with `--parallel 8`, and the matching CTest presets with JUnit output.
`Test-InstalledAppsLifecycle.ps1` uses temporary files, fake native registration,
and a private `HKLM\SOFTWARE\Scholay\RIMES-Installer-Tests` root.
`Test-RegistrarRecovery.ps1` uses test-only binaries compiled with CLSID
`{726F9B64-3421-4B62-8AE9-306959136101}` and profile
`{726F9B64-3421-4B62-8AE9-306959136102}`. These are not the release GUIDs and
are not included in a product package. The test refuses existing test registration,
removes only its own test identity, and compares production paths and the user's
language list before/after.

Product probes use pinned librime 1.17.0 and the existing verified full product
dictionaries with fresh private user/log directories. Simulated TSF E2E uses
real TextService, Broker and librime with a fake host, not an interactive desktop.

## Results

The exact-source runner completed with exit code **0** on October 7 at
11:51 (+08:00). No automated test groups were skipped.

- MSVC x64 and x86 Release builds passed; **18/18 CTest groups per architecture**.
- Installer sandbox **32/32 checks** passed, including missing/corrupt state,
  partial DLL deletion, exact registered-version selection, manifest loss,
  damaged current tools, foreign paths/startup values, and an actual dangling
  NTFS file symlink whose target remains absent after repair is refused.
- Real test-identity Registrar lifecycle **16 expected native operations** passed,
  including intentional rejection of an unowned path, missing x86 DLL cleanup
  while retaining x64 registration, and both DLLs absent. Production registration
  paths and the language list remained identical before/after.
- Both real-librime product probes passed all six schemas, traditional output,
  chording and Windows printable-key checks. Both verified requested **page sizes
  1, 5 and 9** in engine snapshots, rather than truncating the painted list.
- Both simulated TSF E2E runs passed, including first-unresolved-caret suppression,
  transient caret reuse and focus-cache retirement.
- The full shared-data tree still matches its existing manifest: **60 files /
  65,662,811 bytes**. Fresh private user/log directories were used.
- Read-only process check found the same daily Broker **PID 66352** at the previous
  preview.2 path. Tests did not restart or replace it.

See [build result](2026-10-07-community-repair/build-result.json),
[x64 CTest](2026-10-07-community-repair/ctest-x64.xml),
[x86 CTest](2026-10-07-community-repair/ctest-x86.xml),
[installer sandbox](2026-10-07-community-repair/installer-sandbox.json),
[real registrar lifecycle](2026-10-07-community-repair/registrar-recovery.json),
[x64 product probe](2026-10-07-community-repair/product-x64.txt),
[x86 product probe](2026-10-07-community-repair/product-x86.txt),
[x64 E2E](2026-10-07-community-repair/e2e-x64.json),
[x86 E2E](2026-10-07-community-repair/e2e-x86.json), and
[binary/data/process identities](2026-10-07-community-repair/identity.json).
Evidence exports normalize encoding to UTF-8/LF; original report hashes are
recorded in [provenance](2026-10-07-community-repair/evidence-provenance.json).
[SHA256SUMS](2026-10-07-community-repair/SHA256SUMS) covers normalized exports,
not a published package. This final documentation/evidence commit does not
change the tested implementation.

## Remaining delivery gates

No new EXE/ZIP was published or installed in this batch. Source and automated
native acceptance do not establish that the stable 1.1.0 release contains these
fixes. The next candidate still needs installed-package and real desktop checks,
including the original reporter's damaged-install recovery, candidate visual
placement/vertical behavior, and #67 actual login startup. General Windows
host/DPI/multimonitor/lock/resume/day-long acceptance remains under #8.
