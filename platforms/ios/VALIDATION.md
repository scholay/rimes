# Validation — 2026-09-22

Historical operational JSON readbacks remain local. The current build 22 UIKit
fixtures and test summary are checked in under validation/build22/.

## Development round after build 22 (2026-09-24, build number unchanged)

Interaction tuning from physical feedback, installed in place on the iPhone 15 Pro
as 0.1.0 (22); no new build number, archive or store submission.

- Expanded candidates collapse after a selection or any typing key and stay one row.
- Held chords show left keys/mapping, combined result, right mapping/keys in the
  candidate row (display only; commit unchanged).
- Buffer output/input are single non-wrapping lines with horizontal scrolling;
  Default adopts the plugin style (stats in the grey output line, plain input line).
  The visible block chips are gone; delivery segmentation is unchanged.
- Settings moved to candidate-row left; Send, plugin and Buffer toggle form the right column.
- Chord grid: Delete takes the 中/EN cell, 中/EN takes Delete's bottom-row slot.
- Space hold-and-drag steps the caret in host or Buffer.
- Ordinary (non-chord) typing commits the cap under the finger and snaps gutter taps.
- Edge-swipe recognizers no longer delay touches on outer keys.
- A blind (unlabelled) chord-cap experiment was reverted at the user's request.

Passed: 36 shared + 43 hosted iOS tests on the iPhone 17 Pro simulator, resource
verification, signed device build and signature check, device install, and the
on-device engine/Keychain smoke. Swift sources build without warnings (librime's
header documentation warnings remain). Physical feel of edge keys, caret dragging
and the chord preview remains user acceptance.

## Build 22: Default row correction and visible semantic blocks

Fixes physical feedback: Default hides its duplicate source/result text view.
The whole output row now contains centered 16 pt portrait / 14 pt landscape
statistics (fit down to 80% for long figures), with Send still at right.
The source row shows horizontally scrollable blocks with the current caret
block outlined. It uses the desktop semantic splitter, preserving clauses,
English phrases, bounded CJK and protected URLs/numbers. Display, pending
delivery and partial consumption share those exact boundaries. Plugin results
retain the prior source/result layout.

The existing 76 pt portrait / 60 pt landscape Buffer panel height is retained.
Tests verify hidden duplicate text, centered full-row stats, visible ordered
blocks, exact text preservation, consumption parity and plugin switching.
35 shared + 34 hosted iOS tests passed, along with resources, simulator/device
builds and signatures. 20 fixtures include Default portrait/narrow/landscape.
Physical installation evidence: validation/build22-status.json; user acceptance
of final readability and scrolling remains pending. Store review unchanged.

## Historical build 21: Default Buffer statistics and delayed block insertion

Ports the desktop live-metric definitions into shared Foundation code. iOS
feeds touch-start and confirmed Buffer-text events, labels the key/character
ratio as touch starts/character rather than desktop physical-key code length,
and excludes repeat deletion from touch counts. Six seconds idle starts a
fresh burst. Metrics occupy 12 pt within the existing output row, with no
additional keyboard height; plugin output keeps its full prior height.

Default automatic insertion is Off by default, with persisted 1/2/3/5-second
choices in Settings. Ordered blocks age independently; changed text restarts
its clock, unchanged text keeps age, and head consumption happens only after
successful proxy delivery. Composition pauses aging. Document identity is
checked before every tick and insertion. A field switch suspends automatic
delivery until an explicit delay selection or Buffer re-enable; hiding cancels
the timer and draft. Translation/AI results and retained plugin blocks are
never eligible for automatic Default delivery.

Passed: 34 shared + 34 hosted iOS tests, including metric burst/repeat rules,
block replacement/pause/order, duplicate-delivery prevention, target switching,
plugin selection and hiding. Simulator and signed-device builds passed.
17 UIKit fixtures include the in-row metrics presentation.
Device readback: validation/build21-status.json. Physical timing/feel remain
user acceptance; Store submission unchanged.

## Historical build 20: BH, TH and GY slide shortcuts

Adds default directional slides BH → bang, TH → tang and GY → guai,
encoded as bh/th/gy through the existing Ziranma layer. The core route tests
and hosted engine tests now cover all nine routes. Last-valid-result protection,
backtracking, cancellation and single commit behavior are unchanged.
Build/test and physical readback evidence: validation/build20-status.json.
Physical slide ergonomics remain user acceptance; App Store review unchanged.

## Historical build 19: six left-to-right slide shortcuts

Default-profile single-touch slides now support TY/ting, GH/gang, BN/bin,
TYU/tu, GHJ/gan and BNM/bian. These are directional gesture routes, separate
from unordered mapping JSON; imported profiles retain their prior behavior.
Three-key paths keep their middle key highlighted. A fast sample directly at
the third key resolves the known route without requiring an intermediate event.
Sliding back to the second key restores its two-key result, returning to the
origin resets, and invalid/blank positions preserve the last result.
Joining an active cross-hand slide with a second finger cancels that gesture
rather than mixing it with a two-hand chord. Explicit cancellation never commits.

Core tests cover all six routes/codes, skipped intermediate samples, preview,
invalid endpoint protection, release exactly once, reverse direction, backtracking,
origin reset and cancellation. Hosted engine tests decode all six to the requested
pinyin with candidates. Test/build and device readback: validation/build19-status.json.
Physical slide ergonomics remain user acceptance. Store review unchanged.

## Historical build 18: default chord uses the Ziranma engine layer

The default mapping stays stored in its compatible full-pinyin JSON format.
Its runtime keyboard profile converts fragments to one Ziranma key and syllables
to two keys, and selects rimes_ziranma. Imported profiles retain their declared
encoding. This mirrors desktop engineOutput(for:) conversion; desktop source
and user data are not modified.

Tests cover encoding every default mapping, sequential G/H -> raw gh -> gang,
EF/H -> raw uh -> shang, a full ni syllable mapping, imported encoding retention,
and host/Buffer composition. Return still commits raw gh as specified by the
existing raw-input contract; Space/candidate selection commits Chinese text.
Results and physical installation readback: validation/build18-status.json.

## Historical build 17: preserve valid chords and repeat deletion feedback

Sliding from EF to unmapped EV/EB preserves EF (sh) for preview and release.
An alternative valid chord replaces it; returning to the start intentionally
collapses that hand. Empty-space protection and explicit cancellation remain.
Tests cover EF → V/B release, EF → ER replacement, return to E, cancellation,
and both release orders for a composed two-hand syllable.

Deletion feedback now runs in the guarded deletion callback on both initial
press and every 75 ms repeat, respecting the existing feedback strength,
off switch and 35 ms gate. An injected feedback clock verifies initial/repeat
pulses and no extra pulse on release; existing deletion tests cover target
changes, drag exit and hiding.

Passed: 31 shared-core + 30 hosted iOS tests, resources, simulator/device builds
and strict app/extension signatures. Installed in place on connected iPhone
15 Pro and read back as **0.1.0 (17)**. Physical repeated haptic feel and sliding
ergonomics require user confirmation. Store submission remains unchanged.

## Historical build 16: candidate-row settings, no toolbar

Scheme selection is now a Settings submenu. The gear is fixed at candidate-row
right, opposite Buffer at left; the separate toolbar is removed, saving 36 pt
portrait / 34 pt landscape. English switching and translation language/direction
selection remain available in Settings. Buffer rows and typing behavior retain
build 15 behavior.

Passed: 29 shared-core and 30 hosted iOS tests, resource checks, simulator and
signed device builds, strict app/extension signature verification. Seventeen
UIKit fixtures cover widths 320/393/852, both orthogonal layouts, dark/light,
empty/expanded candidates and Buffer states. Tests verify the gear position,
scheme selection state, reserved row and absence of toolbar space.
The connected iPhone 15 Pro was updated in place and read back as **0.1.0 (16)**.
Live physical menu interaction and haptic feel remain user acceptance checks.
No App Store submission or CI credential changes.

## Historical build 15: two orthogonal layouts and fixed candidate/Buffer rows

The user rejected the staggered and stacked designs after physical testing.
Version **0.1.0 (15)** removes those layouts, their direction controls and corner
captions from runtime code. Only orthogonal and split orthogonal remain. Legacy
removed selections fall back to orthogonal while retaining scheme, script,
language and feedback preferences. Plugin and imported mapping formats are unchanged.

Chord key frames are square, with 2 pt horizontal / 1 pt vertical gaps; the split
option retains its 12 pt separator. Landscape centers a grid capped at 480 pt to
bound height. The bottom function row keeps its normal proportions.
The candidate row always reserves at least 32 pt, with Buffer toggle at its left.
Above it are the Buffer input row (plugin at left) and output row (Send at right).
Both Buffer rows appear together even when empty; both hide when Buffer is off.
Original mode previews the original text in output; plugin mode previews only
plugin results, preserving existing stale-result and partial-delivery protections.

Haptic choices are Off / Light / Strong / Stronger. Strong uses medium impacts
at 0.85 intensity; Stronger uses heavy impacts at 1.0. Light keeps the prior
press/selection/commit feedback. Deduplication and 35 ms throttling are unchanged.
Actual perceived intensity still requires physical-device confirmation.

Passed: **29 shared-core + 30 hosted iOS tests**, resource/source/privacy checks,
simulator and signed device builds, and strict app/extension signatures. Tests
cover removed-layout migration, strength persistence, square/equal/no-overlap caps,
reserved candidate height and stable key positions, exact Buffer/control order,
visible empty rows, insertion, cancellation and other retained input behavior.
Seventeen UIKit fixtures are in `validation/build15/`; installation and live
checks are recorded in `validation/build15-status.json`. Actual extension checks
confirmed the reserved empty candidate row, Buffer toggle showing both rows,
unchanged letter positions, and all four feedback menu choices. The iPhone 15 Pro
was updated in place and read back as **0.1.0 (15)**. Store review is unchanged.

## Historical build 14: staggered wide blocks matching the supplied diagram

Version **0.1.0 (14)** corrects the interpretation of the user's reference:
upper band = wide left-hand keyboard + narrow right-hand mapping caption;
lower band = narrow left-hand mapping caption + wide right-hand keyboard.
Each keyboard block occupies 75% width and contains all three rows. The blocks
have overlapping horizontal extents, with no shared row or vertical overlap.
The reverse direction exchanges the blocks' vertical order. Letter dimensions
remain equal, and captions never overlap touch/accessibility key frames.

Typing-area height remains 150 pt portrait / 120 pt landscape; the six rows use
25/20 pt pitch. Default key widths increase by about 50% from build 13. Mapping
captions use separate lines to fit the narrow panels and stop exposing empty
accessibility labels when idle. Tight spacing and blank-motion protection remain.
The persisted layout value and imported mapping format are unchanged.

Passed: **28 shared-core + 31 hosted iOS tests**, resources/source/privacy checks,
simulator and development-signed device builds, and strict app/extension signatures.
The tests now assert the 75/25 split, horizontal overlap, vertical separation, equal
caps, both directions, caption size/clearance, toolbar visibility and cancellation.
Twenty-one UIKit fixture screenshots plus the user reference are saved in
`validation/build14/`. The iPhone 15 Pro was updated in place and read back as
**0.1.0 (14)**; the simulator app and extension also read back build 14.
See `validation/build14-status.json` for the installation record.
Physical thumb comfort/haptics and previous live landscape, cross-app and
translation acceptance remain pending. The App Store submission is unchanged.

## Historical build 13: overlapping hand blocks, mapping captions and gap protection

Version **0.1.0 (13)** keeps three rows per hand, moves the lower block up one
band, and uses five total bands (150 pt portrait / 120 pt landscape). The middle
band has keys in both halves, without overlapping frames. Flat equal caps are
separated by 0.5 pt horizontally / 1 pt vertically. All four chord layouts and
the bottom function row use compact caps; the explicit split layout retains its
12 pt central separation. Both stacked directions and imported hand assignments
remain supported. The free corner on each hand's side shows its live mapping,
for example `DV → n` and `KM → ong`; the captions cannot receive key presses.

Blank-space motion and release preserve the last endpoint, including after the
other hand lifts. Crossing to the other hand also preserves it. Returning to the
start collapses that hand to one key; a new same-hand key replaces its endpoint.
A blank initial touch does not start or poison a chord. Explicit cancellation,
context loss and retirement still prevent late commits. Captions and legal-key
highlighting track the retained state and clear with the gesture.

Passed: **28 shared-core + 31 hosted iOS tests**, resource/source/privacy checks,
simulator build, development-signed device build and strict app/extension signature
verification. Tests cover both release orders over blank space, returning to the
start, cancellation, exact shared-band geometry, caption bounds/lifecycle, narrow
and landscape layouts, compact bottom keys and candidate-position stability.
Twenty-one fixture screenshots are in `validation/build13/`. Actual-extension
portrait input also passed: T → blank → release produced `t` and candidates,
without moving the keys. The simulator's rotation command acknowledged success
but actual captures stayed portrait; live landscape rotation is not marked passed.
Landscape geometry/rendering fixtures passed. A toolbar-width regression found
in visual checking was fixed, retested and included in the final reinstallation.

The iPhone 15 Pro was **updated in place**, and `devicectl device info apps`
read back **0.1.0 (13)**. No uninstall or configuration/user-dictionary reset was
performed. Physical thumb comfort and haptics still require user acceptance;
previous translation/cross-app acceptance is not implied by this installation.
The existing App Store submission and paused CI credentials were not changed.

## Historical build 12: two stacked hand blocks, three rows per hand

Version **0.1.0 (12)** corrects the former two-row option to **双层三排 / Stacked
three-row**: `QWERT / ASDFG / ZXCVB` occupies the upper-left half and
`YUIOP / HJKL / NM,.` the lower-right half. The other two quadrants remain empty.
The reverse direction places the right block above and the left block below.
Each hand keeps three rows, and all letter caps have equal dimensions. The typing
area is 240 pt portrait / 180 pt landscape, with flatter 40/30 pt row pitch;
letter typography fits the shorter caps. 中/EN remains in the toolbar, Emoji in More.

The persisted `twoRows` value and direction are unchanged, so existing selections
automatically use the corrected geometry. Imported hand assignments, composition,
continuous deletion and literal-input behavior are retained. Regression geometry
checks now assert all six rows and both empty quadrants in both directions, in
addition to key completeness, equal sizes, hit testing and accessibility frames.
Screenshots and build evidence are in `validation/build12/` and
`validation/build12-status.json`. The App Store submission remains unchanged.

Passed: **28 shared-core tests + 30 hosted iOS tests**, resource/source/privacy
verification, simulator and development-signed device builds, and strict app/
extension signatures. The actual iPhone 17 Pro Max simulator extension restored
the previous layout preference using the new geometry, accepted `ni`, committed
it with Return, and retained the layout through portrait/landscape rotation.
The installed simulator app and extension both read back **0.1.0 (12)**.
The physical iPhone 15 Pro is **unavailable**; build 12 has not been installed
there, and physical thumb/haptic acceptance remains pending.

## Historical build 11: continuous delete, chord layouts and literal input

Local development version **0.1.0 (11)** adds immediate/repeating deletion
(400 ms delay, 75 ms repeat), latched uppercase Shift, raw-code Return, 中/EN
restoration, four persisted chord layouts and both two-row directions. Traditional
output remains in More. Existing mapping JSON and import are unchanged.

Passed: **28 shared-core tests + 30 hosted iOS tests**, resource/source/privacy
verification, simulator build, development-signed device build and strict app/
extension signature verification. Tests cover raw engine code versus formatted
preedit, generated versus typed separators, host/Buffer delivery, repeat timing and
cancel events, target changes (including unavailable identity), old preferences,
custom hand assignment, every layout's hit/accessibility frames, equal key sizes,
composition preservation and fixed typing position when candidates appear.

Fifteen build 11 layout fixtures cover four layouts and two-row directions at
320/393/852 pt with light/dark, Buffer and long candidates. Existing eleven layout
fixtures also cover ordinary typing, empty rows, the emoji palette,
expanded candidates and long Buffer content. See `validation/build11/README.md`.

The actual keyboard extension was also exercised in the iPhone 17 Pro Max / iOS
26.5 simulator: Shift produced `ABC`; holding Delete for one second removed all
three letters; Return committed `ni` and later English input appended `a` to give
`nia` without replacement/duplication. The More menu selected Two rows immediately;
中/EN toggled while preserving it. Portrait/landscape rendering passed. In Buffer,
Return confirmed `ni`, while a later `ni` + Space produced `ni你`, leaving host
text unchanged. Actual extension captures are prefixed `live-`.

The iPhone 15 Pro still reports **unavailable**, so build 11 was not installed on
physical hardware. Physical continuous-delete interruption, thumb ergonomics and
haptics remain pending. Existing cross-app and Apple Translation device acceptance
is not upgraded by these checks. The old SwiftUI host can retain the visual marked
underline until its next input/refresh; the committed text is preserved, as verified
by appending after Return. This known host-rendering detail remains visible.

CI credential setup remains paused. This round neither withdrew the existing App
Store review nor uploaded/submitted a replacement. See `validation/build11-status.json`.

## Build 9: default chord example and rhino icon

The built-in profile is presented as **默认并击 / Default chord**. Its persisted
ID remains compatible and decoding older saved selections migrates the display
name. Custom names, import/export and all 426 mappings remain intact. The new
Scholay Rhino icon uses the owner's existing 2D reference identity, generated with
built-in image_gen and packaged as a 1024 × 1024 opaque PNG. Tool model version
is not exposed. Prompt, original generation and hash are in `AppStore/icon/`.

Passed: **26 shared-core tests + 22 hosted iOS tests**, resources, signed archive,
signed device build and strict signature checks. The iPhone 15 Pro installation
and device inventory confirm **0.1.0 (9)** without uninstalling existing data.
Foreground launch was refused because the phone is locked; no new physical UI,
translation or haptic acceptance is claimed. App Store upload succeeded.
See `validation/build9-status.json` and the current `AppStore/build-proof.json`.

The confirmed review contact and full review notes are saved in App Store
Connect and verified after reload. Content-rights evidence is still pending;
the neutral public profile name does not change that evidence requirement.

## Historical store preparation: build 8, 22 September 2026

Release **0.1.0 (8)** archived, exported with App Store profiles and uploaded through
Xcode. Apple processed build ID `5564646a-9419-495d-9b29-711a3cb44d1f`; the version
page confirms it is selected. Both bundle signatures pass strict verification,
both report `UIDeviceFamily = [1]`, and neither profile permits debugging or lists
development devices. See `AppStore/build-proof.json` for the IPA hash and readback.

Build 6's first upload failed because XcodeGen's iOS target defaults overrode the
project-level device-family setting and advertised iPad support. Target-level
`TARGETED_DEVICE_FAMILY = 1` fixes it in build 7 and later, verified in the signed
archive and exported app/extension. Build 8 adds optional provider-authentication
User ID to the privacy manifest, matching App Store privacy answers.

Release UI omits development-smoke controls and the development-preview footer;
the privacy page links to the live public policy and support site. A Release build
was installed in an iPhone 17 Pro Max / iOS 26.5 simulator, RIMES keyboard enabled
with Full Access off, and actual Pinyin, candidate confirmation and local Buffer
input exercised. Five 1320 × 2868 screenshots were captured there, converted to
JPEG without resizing/compositing and uploaded to the 6.9-inch App Store slot.
Builds 7 and 8 do not change the captured UI. These are simulator checks, not
physical Apple translation, haptic or cross-app acceptance.

Store metadata is saved in English and both Chinese localizations, with free
pricing and 174 selected regions excluding mainland China. Mac and Vision Pro
availability are off. Privacy answers are published. Resource-rights declarations,
complete review contact and EU trader status remain unresolved. There is **no
review submission, TestFlight installation or public release**. See
`AppStore/README.md` for the exact outstanding work; the iPhone remains on build 5.

## Latest physical build: build 5 borderless candidates and inline composition

Version **0.1.0 (5)** removes the extra chord-center gutter. The half regions still
control gesture resolution, but their ordinary key spacing now matches the rest
of the grid. Candidate items and the expansion chevron are borderless text/icons;
only a transient press highlight remains. Fonts, natural widths and wrapping stay
at 20 pt portrait / 18 pt landscape, with 6 pt horizontal and 3 pt vertical padding.

The former preedit/chord-preview row is removed. Normal input uses the public
[UITextDocumentProxy marked-text API](https://developer.apple.com/documentation/uikit/uitextdocumentproxy/setmarkedtext(_:selectedrange:))
in the host. Candidate confirmation replaces the complete marked range and ends
marking. Deleting/cancelling owned input removes only its pending composition.
Buffer mode displays underlined preedit at the Buffer cursor; it does not edit the
confirmed source, source revision or translation input until a candidate is chosen.
Live chord previews use resolved syllables, without debugging key combinations.
The typing block stays at the same screen position when candidates appear/disappear.

Passed: **25 shared-core tests and 22 hosted iOS tests**, including eleven native
layout variants, real UITextView marked-range tests, Unicode/UTF-16 cursor ranges,
whole-composition replacement, backspace/hide cleanup, independent targets,
refocusing during UIKit's nullable document reset, fixed key geometry and borderless
candidate press behavior. Simulator and signed device builds, strict signature
verification, resource checks and whitespace checks pass.

The actual simulator extension also passed `nihao` → inline `ni hao` → exactly one
`你好` in the host, inline Buffer composition without changing host text, candidate
confirmation into Buffer, and field switching/refocusing without carrying the old
engine composition or replacing previous field text. During this check UIKit could
leave a marked field with a nil document identifier after refocusing. Ending the
stale mark during the reset fixes that lost-input path; text insertion and deletion
still require a valid current document identity.

**Remaining host-rendering limitation:** the simulator's SwiftUI text field can
keep its underline while unfocused even after `unmarkText()` is requested. Refocusing
ends the stale mark and preserves the text. Immediate visual cleanup in an inactive
remote field is not counted as passed; physical cross-app behavior remains pending.
No host focus is forced and no current selection is erased to conceal this state.

The signed update was installed over the existing iPhone 15 Pro app. Both signed
bundles report **0.1.0 (5)**, device app inventory readback confirms build 5, and
foreground launch succeeded. Existing app/keyboard data were retained (no uninstall).
Evidence is in `validation/build5-status.json`, `validation/build5/simulator-checks.json`
and `validation/build5/COMPARISON.md`. Physical thumbs/haptics, translation models,
Full Access off/on, cross-app typing and sustained performance remain manual/device
acceptance; this build/install verification does not establish those results.

## Historical build 4 equal-size chord keys

Version **0.1.0 (4)** uses a single column pitch for all six chord rows. Built-in
FlyYao has five columns on each side, with Emoji after L and Simplified/Traditional
after the period. Custom profiles use the same shared pitch across both hands.
Utility controls are excluded from chord hit testing, dim during active chords,
and cannot activate during a held chord or after a cancelled/context-retired press.

Emoji opens a 29-item local palette at the same typing-area height. Selection uses
the existing Buffer/direct delivery path, and the return key restores the chord
layout. Simplified/Traditional choice persists in extension-private preferences;
old preferences migrate without losing scheme, language or haptics choices.
Candidates and committed text use the same local Foundation Hans-Hant transform
([ICU transform reference](https://unicode-org.github.io/icu/userguide/transforms/general/)).
Native Rime candidate indices and learning remain intact; toggling refreshes the
current composition without replaying a previous commit or changing Buffer text.

Passed: **25 shared-core tests and 16 hosted iOS tests**, including eleven native
layout snapshots. New checks cover equal dimensions at 320/375/393-point portrait
and 852-point landscape widths, custom layouts, utility isolation, cancelled taps,
VoiceOver activation, emoji glyph bounds and Buffer delivery, legacy preferences,
and actual Rime `hanzi` candidates/commit changing from `汉字` to `漢字`.
One narrow-screen emoji-label clipping issue found by the glyph-bounds test was
fixed before the final passing run. Simulator and signed device builds, strict
signature verification, resource checks and whitespace checks passed.

The signed update was installed over the existing iPhone 15 Pro app without
uninstalling it. Device app inventory confirms **0.1.0 (4)**, and foreground launch
succeeded. Evidence and screenshots are in `validation/build4/` and
`validation/build4-status.json`. Physical thumb comfort and haptic strength remain
for actual user testing; installation and hosted checks do not count as those tests.

The actual simulator extension also passed Emoji → host `😀`, returning to chord
mode, entering `hanzi`, toggling the live candidate from `汉字` to `漢字`, and Space
committing exactly one `漢字` (host text `😀漢字`). Empty auxiliaries collapsed again;
the typing rows stayed in place. See `validation/build4/simulator-checks.json` and the comparison.

## Historical build 3 keyboard layout and control update

Version **0.1.0 (3)** implements the compact icon toolbar, shared mechanical caps,
conditional system globe, bottom-anchored typing block, collapsing empty auxiliaries,
and text-measured candidates (20 pt portrait / 18 pt landscape). Buffer insertion
is one block on tap, all remaining blocks after a one-second hold; release cannot
repeat the hold action. Source insertion and less frequent tools live in More.

Passed: 24 shared-core tests and 12 hosted iOS tests, including nine native layout
variants. The hosted checks cover real label/glyph bounds, stable global key frames,
globe-dependent Space width, tap/hold/cancel boundaries, stale source/target rejection,
and nullable Objective-C document identity. Simulator and signed device builds,
strict signature verification, resource policy, macOS debug build and diff check pass.

Actual simulator extension checks include uppercase keycaps with lowercase English
output, Pinyin `nihao` → candidate `你好` → host field, expanded candidates, native globe
without a duplicate, collapsing empty rows, Buffer original editing, one-block tap,
and a 1.2-second press inserting the remaining two blocks exactly once. This used
the real extension in the app's practice field; no external AI service was invoked.

Two issues found during real-extension validation were fixed and retested:
- Keycap border geometry reduced label width below the measured glyph width, causing
  a two-character candidate to truncate. Label bounds now reserve the full measured
  width and line height, with a regression test on actual UILabel frames.
- UIKit temporarily returned nil from the supposedly nonnull documentIdentifier
  getter when resetting the host field. This crashed the unconditional Swift UUID
  bridge. The public Objective-C getter is now read as optional before bridging,
  both for lifecycle and delivery; no missing identity becomes a fallback target.

Screenshots and the before/after comparison are under `validation/build3/`. The
component fixtures and actual extension captures are labeled separately. Final
physical installation/readback and remaining manual checks are recorded in
`validation/build3-status.json`; neither simulator gestures nor model fixtures prove
physical haptic strength, two-thumb comfort, or real Apple Translation execution.

## Historical build 2 keyboard experience and translation update

The final **0.1.0 (2)** signed development app and keyboard extension were installed
on the connected iPhone 15 Pro and read back from its app inventory. After the user
unlocked the phone, build 2 launched successfully. Pinyin, Ziranma, Wubi and main-app
Keychain smoke all passed; engine initialization was about 27.4 ms in that synthetic
run. Apple Translation availability reported that Chinese-English language models
are not installed. The user must prepare them in the containing app before real
translation can be checked. See `validation/build2/iphone-engine-smoke.json` and
`iphone-translation-smoke.json`. Actual keyboard acceptance remains pending.

Passed for build 2: 24 shared-core tests; 5 hosted iOS tests (engine, Keychain,
configuration migration/private preferences and five layout variants); simulator
and signed device builds; strict signature verification; resource policy check;
macOS debug build; diff whitespace check. Snapshots under `validation/build2/` are
native component renders using a synthetic text proxy, not real-host/device input.
One early rendering harness crashed because UIKit has no real document proxy in
an ordinary test window; the final test fixture supplies one and all five tests pass.

The new regression cases cover last-scheme persistence and explicit app overrides,
426-map reachable-key hints in both hand orders, fixed released-hand endpoints,
invalid-position recovery, haptic event deduplication, translation debounce,
non-cooperative cancellation serialization and late-response suppression. Partial
translation delivery retires its source; a retained old translation cannot erase
new untranslated text when delivered after a later failure.

Actual UI automation is additionally blocked by this Mac's disabled
`DevToolsSecurity` setting. Enabling it needs the user's administrator password.
No claim is made for physical touch/haptics, real Apple language model execution,
Full Access behavior, Notes/Safari/Messages/WeChat acceptance, full OS cold launch,
display-frame P95 or sustained keyboard memory. DEBUG aggregate metrics explicitly
separate controller/synchronous processing timings from those full-system targets.

Use `validation/build2-status.json` for the historical build 2 result.

## Historical build 1 evidence

Source branch: `codex/ios-v0.1`, based on `20651da`. This is local development
validation, not TestFlight distribution or physical-device acceptance.

## Passed

| Layer | Evidence |
|---|---|
| Dependency build | librime 1.17.0 and pinned dependencies compiled from source for arm64 iPhone and arm64 Simulator; static XCFramework generated |
| Reproducible build entry | `scripts/build.sh` completed bootstrap checksum/revision checks, host dictionary compilation, core tests and both platform builds |
| Core behavior | 15 XCTest cases passed; all 426 built-in mappings tested for reachability, both hand release orders, preview/commit equality and Ziranma encoding; whole-map precedence and valid/invalid fragment composition covered |
| Gesture cancellation | Cross-region recovery, invalid release, third finger, repeated touch, cancellation and late duplicate release covered in core tests |
| Buffer | Source editing invalidates old generations, Unicode cursor editing, lossless block joining and partial delivery remainder covered |
| AI | Real URLSession streaming path exercised with URLProtocol fixtures; endpoint/consent validation, 429 handling, byte-split UTF-8 SSE, bounded multiline events, truncated streams, length termination and redirect refusal covered; no paid provider invoked |
| Host data/engine | Real pinyin `nihao` → `你好`, Ziranma `nihk` → `你好`, Wubi `wq` → `你`; candidate selection commits the expected text |
| iOS native execution | App installed and launched on iPhone 17 Pro / iOS 26.5 simulator. Three real Chinese engine checks and ad-hoc-signed shared-group Keychain read/write/delete passed; see `validation/simulator-smoke.json` |
| App presentation | Home screen rendered and inspected, English and simplified Chinese launches; `validation/home-simulator.png` records the latter |
| iOS build products | Simulator app + keyboard extension and hosted XCTest bundle compile; arm64 iPhone app + keyboard extension compile without device signing |
| Desktop regression | Full macOS `swift build -c debug` passed; `chord-keymap-smoke` (516 permutations), `chord-ziranma-smoke` (98 syllable / 35 fragment samples, 415 inventory codes, 426 mappings), and `ai-text-smoke` passed |
| Resource policy | Asset hashes, shared/desktop encoding source parity, exact mapping fixture parity, schema allowlist, permissions and privacy manifest checks passed |
| Distribution gate | `verify.py --distribution` correctly exits 2 and lists unmet prerequisites |

Simulator timings in the JSON are narrow engine measurements from one synthetic
run. They do not measure full keyboard presentation, physical touch latency,
extension memory pressure, or P95 acceptance on an iPhone.

## Environment blockers and incomplete checks

- Xcode 27.0 build 27A266a is present, but its device/simulator plug-ins do not match
  installed shared components. Xcode expects CoreSimulator 1171.7; installed is
  1051.55. Xcode's CoreDevice plugin also reports a missing CoreDevice symbol.
- Direct simulator service commands can install/launch the app, but Xcode cannot
  enumerate a matching simulator destination. Hosted XCTest builds successfully;
  `test-without-building` could not execute. This is not counted as a passed test run.
- Xcode's bundled Device Hub was found under `Contents/Applications/DeviceHub.app`,
  but did not provide an accessible UI during testing. No successful keyboard UI
  automation or system keyboard activation is claimed.
- No connected, available iPhone was listed. No physical installation, two-thumb
  gesture trial, app-to-extension Keychain readback, real full-access toggle test,
  lock/unlock, host-app compatibility, extension-memory or latency acceptance has
  been performed. User developer membership is not yet ready.
- Live AI-provider compatibility still needs testing with a user-configured endpoint
  and key. Automated networking tests used synthetic responses and no real key.
- CI workflow is added but has not run on GitHub. No app archive uploaded, no
  TestFlight record created, no external testers invited, no App Store submission.

## Remaining acceptance on the signed iPhone

1. Complete Xcode device-component setup and select the actual developer team;
   register the containing app, extension, App Group and shared Keychain group.
2. Add the keyboard and test Pinyin, Ziranma, Wubi, English and chords offline with
   Full Access off. Verify built-in resources do not depend on app-group writes.
3. In Notes, Safari forms, Messages and WeChat verify composition, candidates,
   deletion, numeric/punctuation switching, explicit Buffer next/all insertion and
   switching between two fields. Secure fields must stay with the system keyboard.
4. Test both hand orders, stationary + sliding hand, returning to start, invalid
   release, third touch, rotation and interruption. Inspect portrait/landscape,
   light/dark, expanded candidates, Buffer and custom profile layouts. Tune thumb
   ergonomics on the physical device before treating the layout as final.
5. Enable Full Access and separately consent to a configured provider. Verify
   Keychain sharing, streaming preview, cancellation, source edits, offline/error
   handling and permission revocation; inspect that requests contain only explicit
   Buffer text. Then disable Full Access and recheck offline typing.
6. Measure full cold keyboard presentation (<1 second target), warm key-to-candidate
   P95 (<100 ms target), and peak extension memory during sustained typing and AI.
   Record device/OS/build and repeat across hide/show and lock/unlock cycles.
7. Resolve Wubi/FlyYao distribution evidence and public privacy/support details in
   `distribution-audit.json`. Only then archive for TestFlight, install the processed
   build, and record that separate acceptance result.

The original checkout's ten modified macOS source files were preserved. This work
was performed in a separate worktree, and the running desktop input method was not
replaced or restarted.

## Physical installation update — 2026-09-21

The earlier device/environment blockers above describe the initial validation run.
This later local installation achieved the following additional evidence:

- Xcode 27 can now enumerate physical and simulator destinations. The connected
  device was an iPhone 15 Pro on iOS 26.7; Developer Mode was confirmed enabled.
- After the user renewed Xcode account authentication, both development profiles
  included this iPhone and `group.org.scholay.rimes.ios`. Shared Keychain entitlements
  were present. The project records the verified development team and explicit
  App Group capability to support repeatable local signing.
- Corrected generated bundle metadata that had retained XcodeGen's default `1.0`.
  Both final signed bundles now report **0.1.0 (1)**; source verification checks
  the version/build substitutions.
- The signed app and embedded keyboard extension passed signature verification.
  CoreDevice installed the app successfully, and the device's installed-app query
  read back `org.scholay.rimes.ios`, version 0.1.0, build 1.
- App launch succeeded. Its explicit synthetic engine smoke was copied back from
  the physical app container: Pinyin, Ziranma, Wubi and Keychain read/write/delete
  all passed. See `validation/iphone15pro-local-install.json`.

This is a **local development installation**, not TestFlight. Main-app engine and
Keychain checks do not prove keyboard activation, cross-process sharing, thumb
ergonomics, all host apps, permission revocation, or keyboard latency/memory targets.
Those acceptance items and the distribution-rights gate remain open.
