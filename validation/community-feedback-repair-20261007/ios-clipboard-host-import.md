# iOS clipboard browser and asynchronous host-import handoff

The follow-up review of PR #89 reproduced a second pause-state ownership bug at base `f5bb1e2`. The empty Buffer row can still offer host text while Local clipboard is visible. Starting that explicit import captures the browser's temporary `autoSuspended = true`; closing browsing restores the original policy, but asynchronous import completion subsequently writes the captured temporary pause back. Ordinary editing then stays paused for the session.

The repair ends unchanged clipboard browsing before host import snapshots its prior pause policy. This is a single ownership handoff after the existing import guards succeed: the clipboard presentation and its panel close, the ordinary-edit gate remains in place, and the import continues with its existing target, plugin, cancellation and source-retention safeguards. Completion still restores the genuine prior policy. It never forces a paused policy to resume, and imported text cannot start a timer merely because the import or panel closes. A later ordinary edit receives a complete new delay period.

Three asynchronous regressions cover the handoff followed by an immediate close before import completion; an earlier explicit history-import pause that must remain paused after subsequent ordinary editing; and a document change during host deletion that cancels the old import without altering or automatically delivering into the new field. The existing Buffer-import tests continue to check delayed/ignored deletion, truncated context, stale previews and native paste authorization. Current paste does not capture and restore `autoSuspended`, while selecting a history entry still pauses it explicitly, so those paths have no equivalent stale pause snapshot to restore. Android has no corresponding automatic Buffer timer and is unchanged.

Verification:

- Before repair, the new positive regression failed exactly at the expected later-edit delivery assertion: one test, one failure (`.build/mobile-clipboard-host-import-repro.log`).
- After repair, the targeted clipboard and Buffer-import suites passed all 28 tests with zero failures (`.build/mobile-clipboard-host-import-targeted.log`).
- The final full iOS simulator regression completed 229 tests with zero failures and one existing opt-in promo-capture test skipped (`.build/mobile-clipboard-host-import-final.log`).
- The unsigned generic iOS device build succeeded (`.build/mobile-clipboard-host-import-device.log`).
- Resource/source-parity/privacy verification, privacy log lint and `git diff --check` passed.

Build logs are ignored task artifacts. This follow-up did not install or control a physical phone, read a real clipboard, use a paid AI service, or publish an app version. The earlier Android USB-install rejection remains unchanged.
