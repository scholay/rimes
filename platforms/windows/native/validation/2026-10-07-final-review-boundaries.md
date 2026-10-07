# Windows final review: missing registered DLL and candidate context

## Review decisions

The missing-DLL uninstall finding is valid. Exclusive access to the remaining
files cannot establish that a deleted registered DLL is absent from application
memory. Commit `d3152d9` checks only the exact owned registration entries already
resolved by `Get-RimesInstallation`. A missing registered DLL now keeps the
sign-out requirement even when the saved state was false. Its message describes
uncertainty about a deleted copy, rather than claiming it is loaded. A missing
file in an unregistered architecture does not independently require sign-out.
No path-selection, registration-removal, or file-repair scope was broadened.

The allegation that a fresh TSF context can borrow the preceding context's
candidate caret is a false positive for the current implementation:

- `OnSetFocus(ITfDocumentMgr*, ...)` reads `GetTop` and calls `BindContext`.
- `BindContext` compares canonical `IID_IUnknown` identities. A changed identity
  executes `RevokeContext` before binding the new context, including when a key
  arrives before its focus notification.
- `RevokeContext` calls `CandidateWindow::Hide`, which clears the entire snapshot
  including cached caret geometry, and invalidates pending composition edits.
- `OnPopContext` also revokes the active context. `OnLayoutChange` ignores an old
  context after another context becomes active.

Commit `650762b` changes only the fake TSF host and E2E regression in the native
tree; it does not change candidate product logic. The fake host now models
document-manager ownership and pop/push membership. Microsoft documents that
[GetDocumentMgr](https://learn.microsoft.com/en-us/windows/win32/api/msctf/nf-msctf-itfcontext-getdocumentmgr)
reports the containing manager and returns no manager after a pop; a
[Push](https://learn.microsoft.com/en-us/windows/win32/api/msctf/nf-msctf-itfdocumentmgr-push)
also invokes the thread-manager stack notification. The regression follows those
focus/stack paths instead of assuming a foreground-loss event between fields.

Fourteen new direct E2E assertions cover same-thread document A to B without a
BOOL foreground loss, failed first geometry in B, recovery using B's own caret,
late layout callbacks from A, key-context changes before focus notification,
pop/re-push of a context, and independent composition commits. Duplicate focus
and ordinary selection changes in the same context retain the original transient
geometry fallback. These are simulated TSF lifecycle checks, not a real browser
DOM-field or desktop visual acceptance claim. No real-host failure was reproduced
that would justify weakening the same-context fallback.

## Exact source and acceptance

- Commit: `650762b27ebae5dafc380fc47e24341d3973ab11`.
- Isolated source: `D:\AI\rimes-community-repair-20261007\source-650762b-v8`.
- ZIP SHA-256: `c2b69771ac6a619658bc78987f0673ce2a6c1164640f502ba908d36af443e2b6`.
- Snapshot SHA-256: `2abfa12a0d7b8e3e8f25bf52fcce03a3274cf3c4ea50c9dd8290312fc899dac3`.
- Young probe: `YOUNG-HOME`, user `young`, PowerShell 5.1.22621.6133.
  Every transferred source hash was checked and all Windows PS scripts parsed.
- `Test-InstalledAppsLifecycle.ps1`: **38/38 checks**, private registry key and
  fake native registration. New positive/negative checks cover known-false state
  with a missing registered x86 DLL and a missing unregistered x86 DLL.
- Fresh x64 and x86 MSVC Release builds used the CMake architecture presets and
  `--parallel 8 --target RimesTsfE2E RimesBroker`.
- `Invoke-RimesImeE2E.ps1` passed the full fake-host / real TextService / real
  Broker / librime **1.17.0** suite in both architectures. The new caret assertions
  executed in each run. Runtime DLL hashes were
  `7478c7caa4ff6b37de86daba1f7ce4a994a4f5ba24872a820fb2b3a9b01fed15` (x64) and
  `af235c26c06152ce09ceb8fe9d9ab9fba7ab43ce30aa952b40174d806f5cc3d9` (x86).
- Runner exit **0**, October 7 at **12:44 (+08:00)**. The unchanged 18 CTest groups
  and native Registrar recovery suite were not repeated in this follow-up; their
  earlier source identities and results remain in the preceding reports.

See [runner result](2026-10-07-final-review-boundaries/build-result.json),
[38-check sandbox](2026-10-07-final-review-boundaries/installer-sandbox.json),
[x64 E2E](2026-10-07-final-review-boundaries/e2e-x64.json),
[x86 E2E](2026-10-07-final-review-boundaries/e2e-x86.json), and
[native console excerpt](2026-10-07-final-review-boundaries/native-e2e-console.txt).
The native child console bypasses the PS redirected E2E log; the excerpt records
both serial architecture runs from the outer runner. Original hashes, extraction
rules and source identities are in
[provenance](2026-10-07-final-review-boundaries/evidence-provenance.json);
[SHA256SUMS](2026-10-07-final-review-boundaries/SHA256SUMS) covers normalized exports.

The daily Broker remains PID **66352** at its original preview.2 path. Tests used
private user/log directories and Session 0; no production registration, installed
IME, user data, foreground app, sign-out, or restart was changed. This follow-up
does not publish or install a release, and it does not satisfy the outstanding
interactive/Honor GUI acceptance for #87. Original PR #82 history and the common
`808d05d` ancestry are retained. This final report commit changes no tested code.
