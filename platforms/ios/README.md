# RIMES iOS 0.1

Native iPhone application and keyboard extension (iOS 17+). The current local
development build is **0.1.0 (22)**. App Store build **10** was submitted on
22 September 2026; this development round does not change that submission.
The iPhone 15 Pro was updated in place and its version read back as **0.1.0 (22)**.
Physical thumb ergonomics and haptics still need user confirmation. See `VALIDATION.md`
for build 22 checks and `AppStore/README.md` for the separate store handoff.
macOS input-method source and installation are unchanged.

## Implemented

- Offline simplified Pinyin, Ziranma, Wubi 86 and English; local Rime learning.
- Extension-private last-scheme memory, independent of Full Access. An explicit
  app selection overrides it once; ordinary app configuration saves do not.
- Uppercase mechanical keycaps, depressed states and 30% opacity for unreachable
  chord keys. Haptics distinguish presses, changed combinations and commits;
  toggle them in the Settings menu. Letter, utility and tool keys share the mechanical
  cap style; candidates are borderless text with a transient touch highlight.
- Default chord now runs through the desktop-style Ziranma encoding layer:
  sequential G then H produces gang; EF maps sh to u, then H produces shang.
  Default one-finger left-to-right shortcuts: TY → ting, GH → gang, BN → bin;
  TYU → tu, GHJ → gan, BNM → bian; BH → bang, TH → tang, GY → guai. Second/third endpoints update preview;
  blank/unmapped positions preserve it, returning to the start resets the slide.
  Stored mapping JSON remains unchanged; imported profiles retain their encoding.
- The Default chord example and imported JSON mappings, with per-hand start/end sliding, live chord
  preview and a single commit when both hands release. Unmapped slide endpoints
  preserve the last valid combination; returning to the start or reaching another
  valid combination updates it. No traversed-key accumulation.
- Only two chord layouts remain: gapless orthogonal and 12 pt split orthogonal.
  Removed staggered/stacked preferences migrate to gapless orthogonal without
  resetting other settings. Chord letter caps are square, with 2 pt horizontal
  and 1 pt vertical frame gaps. Wide landscape layouts center a grid capped at
  480 pt so square caps do not inflate the keyboard height. The bottom row keeps
  its wider Space/function keys. Imported mappings and blank-slide protection remain.
- Haptics offer Off, Light, Strong and Stronger. The two stronger levels use
  medium/heavy UIKit impact generators and persist independently of the off switch;
  combination deduplication and the 35 ms minimum interval remain active.
- Backspace deletes immediately, then after 400 ms repeats every 75 ms; lifting,
  leaving the key, cancellation, target changes, rotation and hiding stop it.
  Each deletion tick emits feedback at the selected haptic strength.
- Outside chord resolution (QWERTY, numbers, Shift or EN), the cap under the finger
  at release is typed and the highlight follows the finger; taps in the 6 pt gutters
  between caps snap to the nearest cap. Chord hit testing is unchanged.
- Hold Space for 0.35 s, then drag: each 10 pt moves the caret one character (an
  emoji counts as one) in the host field or the Buffer, with a haptic tick. Releasing
  after a hold types no space. Holding during composition does not start it.
- Touches near the screen edges are no longer held back by the system's edge-swipe
  recognizers; their touch delay is released while the gestures stay enabled.
- Shift latches uppercase ASCII entry while preserving the chord layout. Return
  commits the engine's raw code without choosing a candidate or adding a newline;
  only automatically added chord separators are omitted. Space chooses a candidate.
- 中/EN toggles direct English and the previous Chinese scheme. Simplified/
  Traditional output is retained in More. Emoji remains in the right-side grid
  cell, or More outside the chord grid; the palette contains 29 local items.
  In the chord grid, Delete (with repeat) takes the right-hand cell below Emoji and
  中/EN takes Delete's place in the bottom row; numbers and emoji keep the usual order.
- While a chord is held the candidate row shows, mirrored about the centre: left keys,
  left mapping, the combined result in a teal pill, right mapping, right keys. `?`
  marks an unmapped hand and `—` an idle one. It is display only; release commits
  exactly the combined result.
- Explicit Buffer mode, character cursor editing, ordered next/all insertion,
  in-memory drafts and manual result confirmation. The fixed order above the keys
  is output → input → candidates. Send, plugin and the Buffer toggle form one
  right-hand column (output, input and candidate rows). Buffer shows both rows
  when enabled and hides both when disabled. Every mode uses the same two single
  lines that never wrap and scroll horizontally: a grey display-only output line
  and a teal-outlined input line with the caret. Candidates wrap by measured text
  width when expanded, including while Buffer is open; choosing a candidate or
  typing collapses them to one row until expanded again.
  Tap the paper plane for one block; hold it for one second for all remaining blocks.
  The More menu contains explicit source insertion, cursor movement and Clear.
- Composition appears inline as native marked text in the host, or at the Buffer
  cursor. Confirming a candidate replaces it once; unconfirmed text stays out of
  Buffer source revisions and translation requests. There is no separate preedit row.
- Settings is a gear at candidate-row left; input schemes and translation languages
  are nested in its menu. There is no top toolbar. A conditional system-required globe and wide Space
  key. The candidate row always reserves at least 32 pt, even when empty;
  the typing block stays anchored to the bottom while auxiliaries grow upward.
- Default Buffer shows committed characters/minute, touch starts/character,
  touch starts/second and backspace presses centered in the output line.
  Default does not duplicate source text there. Its input line is the same plain
  line as plugins; desktop clause/phrase segmentation still splits delivery blocks,
  without drawing them. Repeats do not
  inflate touch counts; a six-second idle gap starts a new burst. No accuracy is
  inferred for free typing. Gear → Default automatic insertion offers Off/1/2/3/5 s
  (default Off). Blocks age separately, edited text restarts, composition pauses,
  and only the head is delivered through the existing proxy. Switching targets
  suspends automatic delivery until explicitly re-enabled; hiding clears drafts
  and timers. Translation/AI output remains explicitly inserted.
- Compiled-in Buffer plugins with serial, cancellable, revision-bound execution.
  Apple on-device translation on iOS 26+ previews after a 400 ms pause; defaults
  to Simplified Chinese → English. Download languages in the containing app first.
  iOS 17–25 retain offline input and existing AI. No automatic cloud fallback.
- Multiple HTTPS Chat Completions providers, manual model IDs, optional model lookup,
  endpoint consent, shared device-only Keychain credentials, cancellable streaming.
- Containing app with keyboard setup, typing playground, profile editor/import/export,
  privacy and license notices. English and simplified Chinese interface, light/dark,
  compact landscape keyboard. Layout remains provisional until physical thumb testing.

Excluded: Xiaohe, Yoyo/Zhemei/Hanmei, runtime scripts, Mailbox, Capsule, clipboard
monitoring, dictation, music, cloud accounts/sync, subscriptions and auto-send.

## Build

Requires macOS, full Xcode with iOS SDK (Xcode 27 was used locally), CMake, Python
3.12+, Git and network access for the pinned build dependencies. The script sets
`DEVELOPER_DIR` per process and does not change `xcode-select` or install the macOS IME.

From the repository root:

```sh
platforms/ios/scripts/build.sh
```

The bootstrap verifies source revisions and archive SHA-256 values. librime 1.17.0
and pinned dependencies compile locally for arm64 iPhone and arm64 Simulator;
no macOS binaries are repackaged as iOS libraries. Logging and external plugin
loading are disabled. Dictionary deployment runs on the Mac build host, never on
first keyboard presentation. Simulator builds use ad-hoc signing so Keychain
entitlements can be exercised; device builds are unsigned until a team is configured.

Open `RIMES.xcodeproj` in Xcode after building. `project.yml` is the editable project
source; regenerate with `Vendor/ios-build/xcodegen/bin/xcodegen generate --spec
platforms/ios/project.yml` from the repository root. `Shared/` is a local Swift package.
The project now selects the development team verified during the first physical
iPhone installation. Other maintainers should select their own team in Xcode or
override `DEVELOPMENT_TEAM` when building. No credentials or profiles are committed.

For core tests only:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path Shared
```

For iOS hosted tests on a correctly configured Xcode installation:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project platforms/ios/RIMES.xcodeproj -scheme RIMES \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```

The debug app accepts `--engine-smoke` to run real on-device engine and Keychain
checks against synthetic inputs and write `Documents/development-smoke.json`.
It sends nothing over the network, and the hook is excluded from release builds.
This smoke is not a substitute for keyboard-extension lifecycle or physical testing.

## Architecture and boundaries

- `RimesCore` has no AppKit/InputMethodKit/CLI dependency. It owns portable keymaps,
  gesture reduction, Buffer state, provider requests and bounded SSE decoding.
- The original desktop encoding algorithm is preserved in a standalone mobile
  port. `scripts/verify.py` enforces source parity and the 426 mapping fixture.
  Desktop imports/build products are deliberately not restructured in this version.
- UIKit owns key hit testing, candidate UI and `UITextDocumentProxy` insertion.
  Each controller has one Rime session; initialization happens once per process.
- The containing app alone writes App Group configuration. A missing/inaccessible
  group falls back to offline defaults. Keyboard-local user dictionaries are never
  shared with the app, never synchronized, and excluded from backup.
- Keys use `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` and an explicit shared
  Keychain group. They are not in JSON, exports, logs, source, screenshots or tests.
- API redirects are refused. Only explicit Buffer source text enters the request.
  Errors, partial streams, editing and lifecycle changes never auto-insert results.
- Switching fields while the keyboard stays visible cancels outstanding AI work
  and preserves pending blocks for a fresh Insert action. Hiding/resigning the
  keyboard ends the session and clears its in-memory draft.
- iOS's proxy gives no host acknowledgement of successful application-level send.
  RIMES makes one explicit proxy insertion and consumes that local block; it does
  not retry, synthesize Return or claim a message was sent.
- Basic typing and Buffer work without Full Access. AI requires both Full Access
  and separate recipient consent. Password fields and opting-out host apps use the
  system keyboard. No unsupported mechanisms are used to bypass those limits.

## Distribution gate

`distribution-audit.json` records evidence and outstanding physical acceptance.
The Wubi license/source packaging and the publisher's representation about the
functional default chord mapping are documented in `AppStore/RESOURCE_CLEARANCE.md`.
App Store Content Rights and review contact are saved. The owner explicitly
requested release; this does not mark unexecuted physical acceptance checks passed.
The strict local `--distribution` checklist remains incomplete for those checks.
Current upload/review state is recorded in `AppStore/README.md`.

All planned schemes remain present; public default chord naming preserves existing
configuration IDs and JSON import. Third-party terms remain bundled.

Once ready, set the real team through `RIMES_DEVELOPMENT_TEAM` and run
`scripts/archive.sh` from this directory. The script checks the gate before creating
a release archive; it does not upload. In Xcode Organizer review signing, archive
contents, privacy declarations and the intended App Store Connect record before
uploading for internal TestFlight testing. External testing additionally requires
Beta App Review. Never commit provisioning profiles, certificates or credentials.

See `VALIDATION.md` for actual results and remaining acceptance, and
`PRIVACY.md` for the published policy and saved App Store privacy declarations.
`RESOURCE_INVENTORY.md` records the source, changes and license obligations of each
shipped dependency. `TESTFLIGHT.md` contains prepared signing, beta description,
review notes and device-acceptance handoff materials.

## Historical physical acceptance: build 5

Version 0.1.0 (5) removes the extra chord-center gutter, makes candidates borderless,
and moves composition into the host field or Buffer cursor. The equal-size grid,
Emoji, script toggle and tap/hold insertion from earlier builds remain intact.
See `validation/build5-status.json` and `validation/build5/COMPARISON.md` for current
build/device evidence and screenshots. All 25 shared-core and 22 hosted iOS tests
pass. Eleven layout fixtures use UIKit with a test proxy; actual simulator extension
captures verify native host typing, Buffer composition and refocusing separately.
Physical thumb/haptic and cross-app acceptance remain device tasks.

In the tested simulator, a field that has lost focus can retain its visual marked
underline until it regains focus. RIMES ends stale marking during UIKit's document
reset before starting new composition; the field's existing text is preserved.
The earlier refocus failure caused by a temporarily missing document ID is fixed.
This host-rendering behavior and physical cross-app coverage are recorded in
`VALIDATION.md`, rather than counted as fully passed device acceptance.

Choose Buffer → Plugins → Apple translation to enable automatic previews for the
current session. Choose a language pair from the adjacent direction menu. The paper plane inserts the active result; explicit source insertion lives in More; incomplete translation never falls
back to source insertion. First insertion retires the translated source and keeps
remaining translated blocks, preventing retranslating already-inserted material.
Hiding the keyboard clears drafts and disables the active plugin for that session.

The DEBUG-only `--translation-smoke` app argument checks the actual Apple service
with synthetic Chinese text and writes `Documents/translation-smoke.json`; it does
not download missing models. Extension debug metrics contain only aggregate
controller presentation, synchronous input-processing timings and sampled memory,
not input text. They do not establish OS-level cold-start or frame latency targets.
