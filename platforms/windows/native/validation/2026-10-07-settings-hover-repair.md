# Windows settings hover and uninstall completion follow-up

## Scope

- [#87](https://github.com/scholay/rimes/issues/87): Windows 11 / Honor Notebook
  16 / public 1.1.0, sidebar hover flicker with Buffer and clipboard closed.
  The source cleared and repainted the whole settings client directly for each
  changed hover target. The patch paints a complete memory bitmap, transfers it
  once, and invalidates only the old/new hover bounds. The existing paint DC
  retains its update-region and native-child clipping.
- [#88](https://github.com/scholay/rimes/pull/88) review: an unknown recovery
  state incorrectly produced a message claiming applications still had a DLL
  loaded. Exclusive access to surviving active DLLs cannot prove that a deleted
  or previously upgraded DLL has left every application. Recovery stays
  conservative, and a previously recorded sign-out requirement is retained.
  Completion now distinguishes failed exclusive DLL access, a recorded pending
  sign-out, unknown installation history, and a known unlocked installation. File access
  failure can also be caused by permissions, so it describes possible use rather
  than claiming confirmed loading.

`WM_PRINTCLIENT` uses the same buffered renderer for standard client capture.
The native fixture exercises that real GDI path without needing a visible
desktop. It checks complete client coverage, navigation-only pixel changes,
identical repeated hover frames, and resource release after 64 actual renders.
Those completed-frame checks cannot establish screen presentation timing.

## Exact source and tests

Young was probed as `YOUNG-HOME`, user `young`, PowerShell 5.1.22621.6133. Both
runners used isolated directories, verified every transferred source hash, and
parsed the Windows PowerShell scripts. No daily input method was installed,
unregistered, stopped, restarted, or replaced.

Native build snapshot:

- Commit `1f00e8631ab3e2c23244e01998147505422bfd3a`.
- Directory `D:\AI\rimes-community-repair-20261007\source-1f00e86-v5`.
- ZIP SHA-256 `aded60e158f077e9edfb48f93f14a0eb9e3ba0b2bbdb61fdf5a456a910b12b22`.
- Snapshot SHA-256 `3ebba8cbddc32037018c31677f483c3522c661905e8107a40d8eb78df0faabc8`.
- MSVC Release CMake `windows-x64` / `windows-x86` configure, matching Release
  build presets (`--parallel 8`), and matching CTest presets: **18/18 groups
  passed per architecture**, runner exit **0**, October 7 at 12:17 (+08:00).

Final installer snapshot:

- Commit `773092b6484d8f9129e2ecf02f8e9994e92de564`.
- Directory `D:\AI\rimes-community-repair-20261007\source-773092b-v7`.
- ZIP SHA-256 `f11faef5536c1bd827c91352ce92d4768e85b8b803f788d05807b32c71922efc`.
- Snapshot SHA-256 `5d9915a46983db7322ed30ca6f229a1e73c64734e4104807b84a6bbe18a0d8f8`.
- `Test-InstalledAppsLifecycle.ps1`: **36/36 checks**, runner exit **0**, using
  fake native registration and a private registry key. Four completion assertions
  cover failed exclusive access, missing history, known false, and known true
  with the active DLL unlocked. Prior damaged-install recovery checks also remain passed.
- Source comparison verified all **198 transferred native-tree files** are
  byte-identical to the native build snapshot. The only changed transferred files are
  `Package.Common.ps1`, `Uninstall.ps1`, and `Test-InstalledAppsLifecycle.ps1`;
  these were rerun after the final pending-sign-out correction. C++ binaries
  retain the first snapshot's compiled commit identity.

Both architectures executed the offscreen GDI assertions. The interactive
**HWND dirty-region assertions were not executed**: SSH Session 0 makes the
fixture window invisible and returns `NULLREGION`. An exploratory x64 run first
failed those assertions (17/18 groups); native diagnostics established the
visibility limitation. The final fixture explicitly reports it instead of
claiming desktop coverage. Actual Honor flicker/blur reproduction and visual
acceptance remain outstanding, so #87 should remain open.

Read-only process evidence still found the daily Broker PID **66352**, at the
existing `1.1.0-preview.2-58fc4bcf8319-ecab591174ef` path. No new release package
or interactive desktop installation was performed. The earlier real test-GUID
Registrar and real-librime acceptance in
[the original report](2026-10-07-community-repair.md) remain separate historical
evidence; those unchanged product/registration checks were not repeated here.

See [native build result](2026-10-07-settings-hover-repair/native-build-result.json),
[x64 CTest](2026-10-07-settings-hover-repair/ctest-x64.xml),
[x86 CTest](2026-10-07-settings-hover-repair/ctest-x86.xml),
[final installer/source comparison](2026-10-07-settings-hover-repair/installer-build-result.json),
and [36-check sandbox](2026-10-07-settings-hover-repair/installer-sandbox.json).
Exports normalize UTF-8/LF; original hashes and source identities are recorded
in [provenance](2026-10-07-settings-hover-repair/evidence-provenance.json), and
[SHA256SUMS](2026-10-07-settings-hover-repair/SHA256SUMS) covers normalized files.

## Community PR comparison

[PR #84](https://github.com/scholay/rimes/pull/84), by `c990china`, was reviewed
read-only at `b5bcbf7013342434fc57c93261f8052528b12533`. It identifies the valid
missing-state uninstall problem and supplies Windows 10 syntax-parse evidence;
its implementation was not executed in this follow-up. It sorts retained version
directory names and chooses the first complete package. After rollback, a newer
retained package can differ from the registered package, so the Registrar's
path-ownership guard refuses that target. It also treats unknown sign-out state
as false; corrupt state and missing DLLs are explicitly outside its scope.

The registered-version recovery in #88 covers that scenario: the sandbox keeps
an unused complete `zzzz-newer-looking-unused` package and verifies recovery
selects the exact registered package. It also covers corrupted state, missing
DLLs, missing manifest, and conservative unknown sign-out. No independent code
from #84 was adopted or altered. Its diagnosis and contributor deserve credit;
merging its directory-selection algorithm would regress the recovery contract.

The deterministic Capsule fixture commit `808d05d` is preserved through merge
commit `1f00e86`; its macOS test result belongs to the separate macOS validation.
This final evidence/attribution update does not change the tested implementation.
