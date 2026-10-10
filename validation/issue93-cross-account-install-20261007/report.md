# Windows standard-user installation: issue #93

Date: 2026-10-07. Base commit: `f4811ad85edad979fe51363451376d6df0c97a35`. Branch: `codex/windows-standard-user-install`.

## Change

The setup UI remains in the initiating Windows account. Clicking Install starts an elevated machine worker, which may run as a different administrator. The worker handles VC++ runtimes, immutable program files, both TSF registrations, and Installed Apps metadata. It records the initiating SID and never runs the Broker or accesses the administrator's startup/Start Menu.

After that worker succeeds, the original process verifies the exact installed package, deploys dictionaries under its own token, and applies its own startup preference and shortcut. Deployment holds the existing Broker user/session mutex so another engine cannot start concurrently in that session. A user-stage failure restores the old startup/shortcut, reports incomplete setup, and supports retry; the successful machine installation remains present. A required runtime reboot is reported even when user initialization fails.

Uninstall snapshots and removes the original user's launch entries, elevates machine unregistration, and restores the exact original entries on cancellation or failure. Installation ownership remains enforced across upgrade, repair, rollback and uninstall. The original user's startup snapshot crosses elevation as bounded Base64 JSON, bound to the initiating SID, for legacy recovery; it is not executed by the administrator. Managed machine rollback can be followed by original-user initialization. Cross-account rollback to unmanaged legacy registration is explicitly refused before mutation because there is no original-user completion coordinator for that legacy layout.

## Verification

Executed on the verified YOUNG-HOME Windows host, Windows PowerShell 5.1 / .NET Framework x64. Source fingerprints are in `source-sha256.json`.

- All transferred PowerShell scripts parse successfully.
- `Test-SetupPayload.ps1`: production Setup.cs compiles with warnings as errors; **17 tests pass**, including payload path/hash rejection, failed/cancelled machine phase gating, original-context completion and runtime restart propagation.
- `Test-SetupResult.ps1`: normal and recovered installations each return one structured result, without diagnostics polluting it.
- `Test-InstalledAppsLifecycle.ps1`: **64 checks pass**. Existing recovery, immutable package, registry ownership, downgrade, dangling-link and missing-DLL cases remain covered. New cases cover different account SIDs, no administrator user-profile access, retained startup snapshots, original-user retry, failed upgrade restoration, current-user deployment exclusion, uninstall cancellation/error restoration, machine rollback and damaged-state uninstall.
- The lifecycle regression is added to the x64 Windows CI job. That newly edited CI workflow has not run remotely in this task.
- `git diff --check` passes.

The lifecycle suite writes a dedicated test registry key and temporary files and uses fake native registrars/Broker programs. It does not install, unregister or replace the daily RIMES input method, or edit its real user dictionaries/settings. Different SID tests model the credential boundary; they do not create or log in to another account.

## Repair history and remaining acceptance

An intermediate expanded test expected deletion of a shortcut deliberately customized by an earlier fixture scenario. Production correctly preserved it. The new independent-account fixture now clears that test-only shortcut before starting; final checks pass, including both customized-shortcut preservation and owned-shortcut cleanup.

Not performed in the original run: real standard-user credential UAC, full packaged-EXE installation/uninstallation under two real accounts, original reporter's device, or an actual full dictionary deployment through the new coordinator. The native Broker/TSF were not changed or rebuilt. No release, installation on the daily device, Issue closure, or remote PR publication is implied by those results.

## 2026-10-09 recheck and Windows handoff

The branch was fast-forwarded to main `ea24bb7c64dc38626b42636e3c04fd059cc6d0bb` without changing any of the 18 original modified/untracked files. The 14 installer/test source fingerprints in `source-sha256.json` still match exactly. Those same 14 fingerprints were independently checked on YOUNG-HOME before rerunning PowerShell parsing, payload, result and lifecycle regressions; all passed again. See `recheck-20261009.json`.

Local native-data tests also pass (11 cases), the Windows workflow parses as YAML, and `git diff --check` passes. The running daily Broker remains the existing 1.1.2 package; the isolated suite did not install or replace it. Real cross-account UAC, full EXE install/uninstall and dictionary deployment remain pending. The source and these records are being published on the development branch for continuation from Windows, not as a public installer fix. Build and remaining acceptance instructions are in [the Windows handoff](../../platforms/windows/DEVELOPMENT-HANDOFF.md).
