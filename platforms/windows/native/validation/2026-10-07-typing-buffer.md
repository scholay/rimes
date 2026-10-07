# Windows typing and Buffer maintenance — 2026-10-07

The first acceptance gate is ordinary typing with Buffer disabled. The patch
separates a qualified Shift tap's engine snapshot from ownership of the physical
key, keeps host command shortcuts outside Buffer, and makes shortcut changes
retain their previous registration until the new chord and settings both succeed.

## Source and reproducibility

The candidate integrates main `aa5916d` (Windows 1.1.1 metadata), the P0 typing,
Runtime, and shortcut contributions. The compiled source base is `45a8080`;
its frozen snapshot and exact changed-file hashes are in
[results.json](2026-10-07-typing-buffer/results.json) and
[source-overlay.json](2026-10-07-typing-buffer/source-overlay.json).
Subsequent documentation records these results without changing compiled code.

- VS 2022 / MSVC 19.44, SDK 10.0.26100.0, Release `/W4 /WX`.
- Real librime 1.17.0, official checksum-pinned x64 and x86 archives.
- Official plug-in revision `aecf9c1f505ac83934b01c28c59a29f99707d199`;
  product data verifier passed all 60 files before the probes.
- Source/archive and produced binary hashes were checked. User configuration,
  text, clipboard history, provider credentials and signing keys are not included.

## Executed checks

| Check | Result and execution boundary |
|---|---|
| Release build | All native x64 and x86 targets passed. |
| Native suites | 18/18 groups on each architecture, existing logged-in Young desktop Session 3. Includes real RegisterHotKey conflict/save/rollback/release tests and settings controls. Temporary test tasks removed. |
| Product probe | All six actual schemes, simplified/traditional cases, 1/5/9 pagination, ordinary printable keys, raw-code Shift commits, ASCII pass-through and both official chord Shift styles passed on both architectures. |
| TSF lifecycle | Real TextService/client/Broker with an in-process Fake TSF host in Session 0: ordinary editing, commit/candidates, host shortcuts, right-Shift noop, filtered Test callbacks, long/repeat/dual Shift, focus and disconnect retirement passed. |
| Compatibility | Both clients passed with their current Broker and the pre-patch x64 Broker. New Broker negotiated capability-zero and new-capability clients. Unsupported Shift gestures remain host keys; no queued input is replayed. |
| Buffer | Runtime tests cover host-modified Return/Backspace/Escape, owned Return repeat/release, stopped producers, stale chunks, no implicit new API request, retained reviewed results, edit invalidation and issued delivery acknowledgements. |
| Settings | Invalid JSON leaves trusted/default settings and the original file intact. Unsupported chords never reserve a bare typing key. Existing Ctrl+Alt chords remain unchanged; new defaults are Ctrl+Shift+B. |
| Repository checks | Catalog and privacy checks, nine product-version tests and diff whitespace checks passed. |

The old `e002116` product probe first passed the existing product/data tests,
then failed the new raw-code Shift assertion. Its TSF fixture also reproduced
the corresponding Shift failures. These are negative regression evidence,
not results from the new candidate.

The initial SSH Session 0 registration test failed with Win32 error 1459,
`ERROR_REQUIRES_INTERACTIVE_WINDOWSTATION`. Independent message-only, hidden
window and thread registrations all reproduced that restriction. The test was
kept unchanged and subsequently passed in Session 3; it was not skipped or
replaced with a simulated registration backend.

## Remaining gates

- The TSF harness is simulated; normal typing in actual Office, browser,
  Electron, Win32 and messaging hosts still needs acceptance with Buffer off.
- Session 3 native fixtures are not a full input-method/DPI/multimonitor or
  working-day soak test. The 2 ms TSF lock-contention branches were reviewed,
  but deterministic contention injection has not run.
- Existing Buffer delivery/focus and Mac-aligned Ctrl+Shift use need real host
  acceptance. Complete macOS editing/plugin-cycle parity is not claimed.
- The installed daily Broker remained the same during these isolated runs;
  no daily input method was replaced by this patch and no new package was published.
- Standard-user installation using another administrator's credentials (#93),
  real damaged-install uninstall/reinstall (#79/#83), fresh login (#67), and
  Honor hover presentation (#87) remain separate gates.

The checklist is [MANUAL-TEST.md](../MANUAL-TEST.md). Public installer freshness
is recorded in the [cross-platform audit](../../../../validation/release-audit-20261007.md).
