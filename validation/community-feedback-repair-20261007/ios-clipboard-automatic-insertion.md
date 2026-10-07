# iOS clipboard dismissal and automatic insertion

The review follow-up to mobile PR #89 reproduced an iOS regression at base `9e4c2b4`: opening Local clipboard stops the default Buffer timer and sets `autoSuspended`, but closing the browser never restores the prior policy. The configured delay is retained while automatic insertion remains paused for the session. Android has no corresponding automatic Buffer-insertion timer or pause flag; its history actions remain explicit, so this fix does not modify Android source.

The corrected behavior distinguishes browsing from inserting a saved entry:

- Normal dismissal of unchanged browsing or collection restores the previous automatic-insertion policy, bound to the original document, plugin, source revision, delay and observed Full Access state. A previously paused policy remains paused.
- Closing the browser does not arm a timer for the text already in Buffer. The existing draft stays idle through renders and ticks; only a later ordinary text edit can start a new complete delay period. Neither an old deadline nor its elapsed age is restored. Manual delivery, cursor movement, empty deletion, host capture/import, current paste and plugin/settings changes do not unlock this waiting state. Ordinary insert/delete unlock it only after actually changing the source.
- Adding a historical entry continues to pause automatic insertion, including after another browse/dismiss cycle and subsequent edits. Changing the document, draft, plugin, permissions or lifecycle during browsing never resumes the old policy or target. An observed permission withdrawal invalidates restoration even if permission returns before closing.
- Reopening an already open browser cannot replace the saved prior policy with its temporary pause. Switching to the same plugin's settings can dismiss browsing safely with the same revision lock.

Regression coverage exercises browse-only, explicit collection, opening while Buffer was off, ten seconds without insertion after dismissal, later ordinary typing/deletion followed by a full one-second delay, actual history import versus browsing, and field/draft/plugin/permission/lifecycle invalidation. A further test manually inserts one block after dismissal, moves the cursor and attempts an empty deletion, then checks that the remainder stays idle until a real later edit. The clipboard/provider and host-import suites retain the original late-callback and paste-permission-alert checks.

Initial source reproduction failed as expected before the repair. An intermediate revision-lock implementation passed 225 existing/regression cases but failed the newly added manual-consumption test; that intermediate result is not the final acceptance evidence. The final implementation uses an ordinary-edit gate instead of treating every source revision change as an edit. Final verification is recorded below; build logs are ignored task artifacts. No physical phone was installed or controlled in this follow-up, and the earlier Android USB-install rejection remains unchanged.

- Targeted clipboard and Buffer-import suites: 25 tests passed, zero failures (`.build/mobile-clipboard-auto-targeted-final.log`).
- Final full simulator regression: 226 tests completed with zero failures and one existing opt-in promo-capture test skipped (`.build/mobile-clipboard-auto-final.log`). The unsigned generic iOS device build succeeded (`.build/mobile-clipboard-auto-device.log`).
- Resource/source-parity/privacy verification, privacy log lint and `git diff --check` passed.
