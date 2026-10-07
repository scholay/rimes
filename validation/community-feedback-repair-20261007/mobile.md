# Mobile clipboard follow-up, 2026-10-07

This source follow-up implements the bounded scope recorded on [issue #76](https://github.com/scholay/rimes/issues/76): explicit collection, local text history, viewing, deletion, clearing and adding a record to Buffer. It does not create a clipboard listener or sync service. The branch starts from Android feedback integration `4e59ae1`; it does not change the published application versions.

## Behavior and boundaries

- Android offers an explicit current-text paste button in the Buffer source row. Local clipboard is available in keyboard settings and by holding that paste button. ClipboardManager is queried only after an explicit action; only plain text is accepted, without URI coercion or attachment loading.
- iOS retains its native `UIPasteControl` current-text paste. Local clipboard is available in the keyboard menu and Buffer settings. Collect current text uses the same system paste provider and requires Full Access; opening or using saved local history does not read the system clipboard and works without Full Access.
- Both histories retain at most 40 entries, 16 KiB of UTF-8 text per entry and 128 KiB of text overall. Exact duplicates move to the front; oldest entries are removed when limits are reached. Unicode and whitespace are preserved, including distinct NFC/NFD sequences. Records can be deleted or cleared. Adding history to Buffer neither inserts into the host nor starts a plugin or automatic delivery.
- Android stores records under the app-private `no_backup/text-clipboard/history-v1.json`, using AtomicFile and private file/directory modes. iOS uses the keyboard extension's private Application Support `TextClipboard/history-v1.json`, atomic protected writes and backup exclusion; it does not use the shared App Group. Privacy/help text describes the persistent history separately from ephemeral Buffer drafts.
- Android rejects private/direct-only fields and binds operations to the current editor epoch and connection; importing a record also checks the Buffer revision/capacity. iOS binds provider results to the original document, plugin and Buffer revision, rechecks Full Access, and preserves the draft across a same-field system paste permission alert. Hidden/changed targets and canceled providers cannot follow a later editor. Closing the history redacts the displayed text.

## Verification

- Android: 79 JVM tests passed with zero failures/errors; Debug APK, lintDebug, app instrumentation APK and test-host instrumentation APK built successfully. The new model tests cover verbatim text, deduplication, deletion/clear, bounded eviction, malformed restores and immutable returned snapshots. Existing explicit import tests exercise denied reads, draft/target changes, capacity and preserved blocks.
- Android's `clipboard-store` instrumentation mode compiles 12 synthetic filesystem assertions, including private modes, reopening, deletion/clear, malformed JSON, symlink refusal, `.bak` recovery with a missing/incomplete base and preservation of an outside file. This mode was **not run on a physical device** in this task.
- iOS: all 223 RIMES simulator tests on iPhone 17 Pro / iOS 26.5 completed with zero failures and one existing opt-in promo-capture test skipped. New tests cover private store limits/round-trip/corrupt files, NFC/NFD byte preservation, explicit native collection, Full Access denial/revocation, late callback changes, system paste-alert lifecycle, draft/cursor preservation, local use without Full Access, history deletion/clear and no automatic host insertion. Portrait/narrow/landscape-width fixtures use the existing keyboard panel without increasing its laid-out height.
- iOS: unsigned generic iOS device build succeeded. `platforms/ios/scripts/verify.py` passed resource/source-parity/privacy checks.
- Shared: 82 Swift tests passed with zero failures. Privacy log lint and `git diff --check` passed.
- An independent source review identified and rechecked the AtomicFile recovery and canonical-equivalence issues; both have corresponding regressions and no remaining blocking findings.

Local logs: `.build/mobile-community-ios-final.log`, `.build/mobile-community-ios-device.log`, `.build/mobile-community-android-history.log` and `.build/mobile-community-shared.log`. These are ignored build artifacts, not published delivery records.

## Remaining acceptance

No physical phone was installed or controlled, no real AI request was made and no store/release package was published. OS paste permission dialogs on an actual iPhone, Android IME presentation/field transitions on a handset, and the synthetic Android filesystem instrumentation require later device acceptance. Simulator and source checks do not establish every manufacturer, old Android version or actual 16 KB environment.

Issue #75 explicitly requests Windows candidate layout/count settings and is handled separately. Issue #3 remains the Android follow-up tracker; already-merged code14 repairs and this clipboard implementation do not replace the public code12 APK or finish the remaining Android custom-scheme, animation and wider-device work.
