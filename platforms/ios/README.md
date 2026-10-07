# RIMES iOS 1.1.0 preparation

Native iPhone application and keyboard extension (iOS 17+). The next local
release target is **1.1.0 (40)**; both targets inherit the same marketing version
and build number from `project.yml`. Build 38 passed the maintainer's physical
haptic and iOS acceptance. Build 40 updates the app's home hero, localization and contact links only. Build 35's
external review was withdrawn after a reported regression. The verified build 40
IPA was uploaded to App Store Connect on 2026-10-04; processing and external
review are tracked there.

The [public TestFlight invitation](https://testflight.apple.com/join/Kdj9RB4q)
remains enabled for previously approved builds. See
[1.1.0 acceptance](validation/release-1.1.0/README.md) for the current test scope
and remaining coverage limits. Historical build 22 checks remain in `VALIDATION.md`.
See `CI_RELEASE.md` for the upload workflow.

## Implemented

- Offline simplified Pinyin, Ziranma, Wubi 86 and English; local Rime learning.
- During composition/candidate selection the left Settings button hides while
  the right Buffer button remains available.
- Optional hold-and-swipe symbols in ordinary layouts, off by default. Enable
  in the app's keyboard-layout page or the keyboard's Settings menu; hold for
  320 ms, slide up and release. Q–P insert 1–0; other letters and nine-key groups
  insert their labeled punctuation. Chord layouts retain their own gestures.
- With built-in Chinese input, the standard 123 and #+= pages show and type Chinese
  marks (`，。、？！：；（）“”` and `【】《》—…·‘’「」〈〉`), keeping a half-width
  `.` for decimals. A sentence mark (`，。？！、：；`) typed as the first key after
  opening 123 returns to letters; digits and other marks stay. English, imported
  schemes and the chord number page are unchanged. The nine-key punctuation key
  lists `，。？！、：；…“”（）` in the candidate row instead of a menu. Android uses
  the same table (`PunctuationLayout`), checked on both sides against one fixture.
- Imported Rime packages can be deleted from the package list with confirmation.
  Deleting the selected package restores the previous built-in scheme when the
  keyboard reopens and preserves learned dictionaries.
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
  combinations are deduplicated with a 35 ms interval. Key-down pulses use their
  own 8 ms coalescing interval so a preceding preview cannot suppress a new key.
- Backspace deletes immediately, then after 400 ms repeats every 75 ms; lifting,
  leaving the key, cancellation, target changes, rotation and hiding stop it.
  Each deletion tick emits feedback at the selected haptic strength.
  In the Default Buffer each Delete removes the whole block before the caret (the
  block holding the caret if it is inside one); pinyin in composition, selections,
  plugin input and host fields keep their usual deletion.
- Outside chord resolution (QWERTY, numbers, Shift or EN), the cap under the finger
  at release is typed and the highlight follows the finger; taps in the 6 pt gutters
  between caps snap to the nearest cap. Chord hit testing is unchanged.
- Hold Space for 0.35 s, then drag: each 10 pt moves the caret one character (an
  emoji counts as one) in the host field or the Buffer, with a haptic tick. Releasing
  after a hold types no space. Holding during composition does not start it.
  In the chord grid Space is split: a tap on either half types a space; holding the
  right half moves the caret, holding the left half selects in the Buffer from the
  caret (Delete removes the selection; any other key clears it). iOS gives keyboards
  no API to select host text, so in app fields the left half also moves the caret,
  with a one-time note.
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
- Local clipboard in the keyboard's Settings menu and Buffer settings. Collect
  current text uses an explicit native `UIPasteControl` tap and Full Access;
  opening the list never reads the system clipboard. Up to 40 text entries,
  16 KiB each and 128 KiB total remain in the keyboard's private, backup-excluded
  `TextClipboard/history-v1.json`. Exact duplicates move to the front; old entries
  are evicted. Delete/clear manage the history, and tapping an entry inserts it
  at the Buffer cursor without host insertion, automatic sending or plugin runs.
  Saved history is usable offline without Full Access. Changed fields, drafts,
  plugins, permissions and canceled providers cannot apply a late collection.
- After a Chinese commit, the empty candidate row offers associated words: first
  what you have typed next on this device, then continuations from the bundled Pinyin
  dictionary (`associations.tsv`, built by `scripts/build-associations.py`; e.g.
  谢谢 → 了/大家/合作). Tapping one inserts it and chains; any other key hides them
  (Space still types a space). Learning is keyboard-private, bounded to 600 words ×
  8 next words and excluded from backup. Clearing is available only in the app's
  Data management → Clear learned associations, with a destructive confirmation.
  The app sends a reset revision without reading any learned words; the keyboard
  applies it once on its next presentation. Updating the app does not request a reset.
- Composition appears inline as native marked text in the host, or at the Buffer
  cursor. Confirming a candidate replaces it once; unconfirmed text stays out of
  Buffer source revisions and translation requests. There is no separate preedit row.
- Settings is a gear at candidate-row left; input schemes and translation languages
  are nested in its menu. There is no top toolbar. A conditional system-required globe and wide Space
  key. The candidate row always reserves at least 32 pt, even when empty;
  the typing block stays anchored to the bottom while auxiliaries grow upward.
- Default Buffer shows committed characters/minute, touch starts/character,
  touch starts/second and backspace presses centered in the output line.
  Default does not duplicate source text there. As on the desktop, every commit is
  its own block (one typed word = one block); punctuation and spaces join the block
  before them and direct Latin letters join into one word. Text set whole (restored
  or cleared) falls back to clause segmentation. The input line shows these blocks as
  rounded backgrounds with a gap between them, the caret block outlined, and Send /
  automatic insertion deliver exactly these blocks; plugin output lines show their result
  blocks the same way, head block outlined. Gaps are kerning and the caret is a thin
  blinking overlay, so neither inserts characters or shifts the text. Repeats do not
  inflate touch counts; a six-second idle gap starts a new burst. No accuracy is
  inferred for free typing. Gear → Default automatic insertion offers Off/1/2/3/5 s
  (default Off). Blocks age separately, edited text restarts, composition pauses,
  and only the head is delivered through the existing proxy. Switching targets
  suspends automatic delivery until explicitly re-enabled; hiding clears drafts
  and timers. Translation/AI output remains explicitly inserted.
- Tap the Default Buffer stats readout to choose Emoji blocks, ordinary text, or
  an optional PNG in one preview. Text is inserted only after tapping Insert text;
  the gear menu has no stats-export entry. Emoji frames stay eight cells wide;
  long numbers continue on additional rows, with the complete GitHub link below.
  The preview
  has a complete drawn frame and a full-width hint at the bottom. Save to Photos
  requests add-only authorization on the explicit save; denied/restricted access
  and Photos write errors are shown as failures. Full Access is needed to export
  from the keyboard. The containing app's Typing stats card page also offers Save
  to Photos, system sharing and file export. Image copying is a secondary action.
  Preview pauses automatic insertion and does not consume Buffer or totals. The
  stats tap only previews; images are an opt-in format. Only the latest
  explicitly saved PNG is retained in the App Group, excluded from backup and
  deletable in the app. Photos copies are managed separately in Photos.
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
  port. `scripts/verify.py` enforces source parity and the 427 mapping fixture.
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
- Basic typing, Buffer and card previews work without Full Access. Keyboard image
  export and clipboard access require Full Access; AI also requires separate
  recipient consent. Saving images requests add-only Photos permission, never
  library read access. Password fields and opting-out host apps use the
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
