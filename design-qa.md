# Screenshot UI visual QA — 2026-09-21

## Result

Passed for the four requested native surfaces, as a reference-aligned AppKit adaptation. No known P0/P1/P2 visual defects remain in the inspected states. This is not a claim of pixel-identical reproduction or complete hardware/workflow acceptance.

The user explicitly allowed removing extra controls. Chinese labels, SF Symbols, local-only actions and existing asset storage are retained. The reference cat/photo is screenshot content, not a product asset. No reference bitmap is embedded into the application UI.

## Reference and capture provenance

All references are the four user-provided local images. Their desktop scaling is unspecified, so comparison uses each component's bounds/proportions, not the surrounding desktop or raw screenshot width.

| Surface | Reference source | Implementation capture / state |
| --- | --- | --- |
| Card | `/Users/isaachigher/Library/RIMES/capsule/captures/12DB1E02-FA5E-47FD-9AFB-DC30C788AD28/original.png` (282×214) | `.build/capture-validation/chrome/card-hover-native.png` (416×296 px, 208×148 pt, 2×): hover, native window capture; `card-rest.png`: no hover |
| Editor | `/Users/isaachigher/Library/RIMES/capsule/captures/AB2EF26E-9CEC-418F-AC4B-CFE30231AAFB/original.png` (3197×1944) | `.build/capture-validation/chrome/editor.png` (2400×1560 px, 1200×780 pt, 2×); `editor-compact.png` (2080×1400 px, 1040×700 pt, 2×) |
| Color | `/Users/isaachigher/Library/RIMES/capsule/captures/6F713FE8-4D4D-4EB0-84DC-7E18E18D9F30/original.png` (890×565) | `.build/capture-validation/chrome/color-picker.png` (680×848 px, 340×424 pt, 2×), #2C7FFB; actual editor popover opening and dimensions also exercised |
| Capture bar | `/Users/isaachigher/Library/RIMES/capsule/captures/55B6FB92-C55A-434F-941F-BD35806CF58C/original.png` (967×121) | `.build/capture-validation/chrome/launcher.png` (1506×136 px, 753×68 pt, 2×), idle, automatic dimensions |

Implementation capture root: `/Users/isaachigher/Documents/DEV/rime-buffer-1/`. The captures are generated from real AppKit views, not HTML or drawn mockups. Most use view caching; `card-hover-native.png` uses the actual own-window image because cached views omit the live vibrancy/blur compositor. Test images and preferences are isolated; user captures and general pasteboard are untouched.

## Five-surface check

| Check | Finding |
| --- | --- |
| Fonts | Native system fonts, 12–13 pt controls, consistent label weight; compact toolbar labels fit without wrapping. Native inactive traffic lights are gray in test-window captures. |
| Spacing | Card center actions / corner glyphs, single-row editor tools, expansive canvas, bottom zoom / centered drag / right actions, two-group capture bar and two-column color swatches follow references. Compact editor controls checked against content bounds. |
| Colors | Independent dark neutral chrome, blue active / completion state, light card pills, dimmed and blurred hover preview, neutral canvas. Does not change IME-wide theme. |
| Images and icons | Uses actual bounded current-render previews (not unredacted fallback), SF Symbols and synthetic QA content. Entire thumbnail fits, retaining previous cropping-loss fix. Reference cloud icons intentionally removed. |
| Copy and information hierarchy | Chinese local equivalents; copy/save dominate card. Editor has Save As / Done; no persistent inspector/history rail. Capture bar has seven icon-above-label modes. Color controls include working Hex/RGBA/alpha and custom swatches. |

## Iterations

1. Initial implementation: native editor top/bottom layout and minimum window-size screenshots inspected alongside editor reference. Removed persistent sidebars and history rail, retained all stored documents.
2. Cross-surface comparison found mode icons below text (P2) due to AppKit button coordinates; fixed custom mode orientation. Native button alignment insets made small circular controls oval (P2); overridden for custom-painted controls. Empty custom-color slots changed from tiny glyphs to full dashed swatch circles.
3. Native card capture confirmed actual blurred hover backdrop; cached-only screenshot had not represented compositor blur. Retested all four surfaces and actual editor popover. No overlap or clipping found at tested sizes.

## Behavioral regression evidence

- Debug build passed with only existing AVFoundation deprecation warnings.
- `capture-chrome-smoke`: compact layout, actual popover, pixel zoom including crop/rotation/background/output dimensions, RGBA opacity composition, invalid Hex rollback, custom color persistence/deduplication, six executable capture/recording modes and visual captures.
- `capture-smoke`: asset lifecycles, original preservation, rendering/projects, scroll matcher; selection and overlay suites included.
- Overlay tests: success-only copy dismissal, failed/conflicting clipboard preserves card, history/file retention, late callback cannot close a replacement card, overflow and refresh stability.
- Selection tests: early drag before frame readiness, cancellation, fixed geometry, front-to-back window hit testing and cross-display coordinates.
- Permission, clipboard-policy, clipboard-history, capsule-rail and capsule-window smoke passed.

## Scope boundaries

No claim that all mixed-DPI monitors, Spaces, third-party paste targets, device recording paths or IME composition behavior were end-to-end validated. Real shortcut latency must be measured from installed-process logs. Cloud upload/share, persistent library strip and extra inspector actions were deliberately omitted; restore/project/settings utilities remain in the capture bar's contextual menu so legacy pinned windows can still be managed.

Release installation and installed-process checks are recorded in `CAPTURE.md`: matching UUID, strict deep signature verification, new single process and enabled/selected input source. Release `capture-smoke` and `capture-chrome-smoke` also passed; Release visual captures are under `.build/capture-validation/chrome-release/`.

Installed real-keyboard verification remains unconfirmed: native automation could not attach the background input method by path or bundle ID (timeouts). Sending the launcher shortcut through Finder did not yield an observable RIMES accessibility tree; no real shortcut latency or external-window capture success is claimed.

---

The pre-existing Buffer / Clipboard report below is retained unchanged as historical evidence. Its blockers and acceptance status are independent of the screenshot UI work above.

# Design QA — Clipboard image previews, toggleable Buffer toolbar, and theme families

## Current Acceptance Contract

- Buffer opens collapsed as one compact row: 44pt for ordinary/source-only/target-only and 78pt for live source-plus-target.
- The only leading input/plugin icon toggles a 33pt top toolbar plus a 1pt divider. Expanded heights are 78pt and 112pt.
- Empty toolbar chrome, status, spacing, and flexible spacer drag the window. Controls remain interactive; the body/background do not drag, and there is no dedicated 24pt right-side strip.
- Toolbar state is session-local and resets collapsed on hide or secure/session protection.
- Clipboard image records and image-bearing files show bounded asynchronous previews, real source-application icons, and are discoverable through image aliases. History and previews remain local with no cloud sync.

## Findings

- [Blocked] The source screenshots cannot be opened as an image artifact in this workspace.
  - Location: the two Buffer screenshots attached to the user's request.
  - Evidence: the screenshots are visible in the conversation, but this runtime exposes neither a filesystem path nor an image handle that can be placed in the same comparison input as the rendered implementation.
  - Impact: a valid source-versus-implementation fidelity comparison cannot be completed. Separate visual inspection is not a substitute for the required combined comparison.
  - Fix: reattach or save the two source screenshots as local files, then compose each source and matching implementation state into one comparison image at equal logical size.

The implementation-only evidence below predates the current toggleable-toolbar revision. It remains useful as historical Clipboard/theme evidence, but it is not a current Buffer fidelity pass. Fresh collapsed, expanded, and collapsed-again renders are required after implementation.

## Comparison Target

- Source visual truth path: unavailable — two user-provided conversation attachments, with no filesystem path exposed to this runtime.
- Implementation screenshots:
  - `.build/design-qa-current-20260830/buffer-collapsed.png`
  - `.build/design-qa-current-20260830/buffer-expanded.png`
  - `.build/design-qa-current-20260830/buffer-live-collapsed.png`
  - `.build/design-qa-current-20260830/buffer-live-expanded.png`
  - `.build/design-qa-current-20260830/clipboard-image-preview.png`
  - `/tmp/rimebuffer-design-qa.zEhGCP/buffer-classic.png`
  - `/tmp/rimebuffer-design-qa.zEhGCP/buffer-rasta.png`
  - `/tmp/rimebuffer-design-qa.zEhGCP/buffer-rasta-translation-v2.png`
  - `/tmp/rimebuffer-design-qa.zEhGCP/clipboard-rasta-v2.png`
  - `/tmp/rimebuffer-design-qa.zEhGCP/settings/core-appearance--theme.png`
  - `/tmp/rimebuffer-installed-buffer.png`
  - `/tmp/rimebuffer-installed-clipboard.png`
- Historical state (superseded for Buffer toolbar/geometry comparison):
  - Classic Buffer, ordinary collapsed one-row state.
  - Rasta Buffer, ordinary collapsed one-row state.
  - Rasta Buffer, completed collapsed live source-plus-target translation state with Copy available.
  - Rasta Clipboard History with a real image thumbnail and real Safari source icons.
  - Appearance settings with Classic colorways and the selected Rasta theme.
  - Installed Release bundle in the current Classic colorway: completed translation Buffer and Clipboard History.

## Viewport and Density

| Artifact | Logical size | Pixel dimensions | Density |
| --- | ---: | ---: | ---: |
| Buffer ordinary, collapsed | 760 × 44 pt | 1520 × 88 px | 2× |
| Buffer ordinary, expanded | 760 × 78 pt | 1520 × 156 px | 2× |
| Buffer live source+target, collapsed | 760 × 78 pt | 1520 × 156 px | 2× |
| Buffer live source+target, expanded | 760 × 112 pt | 1520 × 224 px | 2× |
| Rasta Clipboard History | 940 × 224 pt | 1880 × 448 px | 2× |
| Appearance settings | 980 × 680 pt | 1960 × 1360 px | 2× |
| Installed Release Buffer | 760 × 78 pt | 1520 × 156 px | 2× |
| Installed Release Clipboard | 940 × 224 pt | 1880 × 448 px | 2× |
| Source attachments | unavailable | unavailable | unavailable |

The implementation renders are internally normalized at native macOS 2× density. Source normalization could not be performed because the source files are unavailable.

## Full-view Comparison Evidence

A valid combined full-view comparison was not possible. Current implementation-only inspection confirms:

- Fresh AppKit renders verify the 44pt ordinary and 78pt live collapsed states, the 33pt toolbar + 1pt divider, and their 78/112pt expanded states. The expanded toolbar spans the top edge, and the body ends at the primary action without the retired right-side strip.
- The real toolbar hit-test probe verifies actionable controls keep first-click ownership while static status, spacing, flexible spacer, and empty chrome resolve to the window-drag surface. Hide/protection reset and collapsed-again geometry are covered by `buffer-window-smoke`.
- Only one leading input-control icon remains; the generated target has a separate explicit Copy action and the existing Send action.
- Rasta renders red, yellow, and green simultaneously in the workbench chrome.
- Clipboard cards show actual image content and source application icons without changing the horizontal timeline density.
- Appearance settings present Classic as one family with three colorways and Rasta as a separate theme.
- The installed Release evidence reproduced the then-current collapsed Buffer, Copy action, real Clipboard image, and Safari icons. It must not be treated as proof of the later toggleable-toolbar behavior until a new install/runtime pass is captured.

## Installed Functional Evidence

- The final Release bundle was installed with `RB_KEEP_USERDB=1`; the selected input source is `com.isaac.inputmethod.RimeBuffer.Hans`, the bundle passes strict deep code-sign verification, and one live ETInput server remains after audit commands exit.
- A real AppKit RTF + plain-text pasteboard item was captured by the installed process after fixing macOS's unreadable synthesized `public.utf16-external-plain-text` projection. The aggregate audit moved from 2,548 to 2,549 local payload items. The exact artificial QA row was then removed, the prior clipboard archive was restored without printing its content, and SQLite integrity returned `ok` at 2,548 items.
- Lossless rich activation reached the OS permission boundary, but the final TextEdit insertion could not be executed: macOS displayed the system-level “Allow RIMES to enable RIMES?” prompt. This run did not approve or deny that setting on the user's behalf. Therefore installed real-host rich insertion remains a manual acceptance check; smoke/build evidence alone is not represented as proof of final host insertion.

## Focused Region Comparison Evidence

A valid source-aligned focused comparison was not possible for the same blocker. The following implementation regions were inspected at original 2× pixels:

- Current Buffer leading input icon in both toggle states, target Copy action, Send action, 1px border, 33pt toolbar, 1pt divider, draggable empty toolbar chrome, interactive controls, and absence of a right-side strip.
- Clipboard image crop, 16 pt source icon, selected-card border, title wrapping, and right-edge horizontal overflow.
- Theme cards, grouping labels, selected-state outline, typography hierarchy, and footer status.

## Required Fidelity Surfaces

- Fonts and typography: native system and monospaced system faces render sharply at 2×; hierarchy and wrapping are coherent in the inspected states. Source fidelity remains unverified.
- Spacing and layout rhythm: historical 44/78pt collapsed Buffer and 940 × 224pt Clipboard renders were stable. Current QA must verify all four Buffer heights—44/78pt collapsed and 78/112pt expanded—without overlap or persistent-control clipping.
- Colors and tokens: Classic colorways and the independent Rasta semantic palette render with adequate contrast; red/yellow/green appear together in the Rasta Buffer. Source fidelity remains unverified.
- Image quality and assets: the Clipboard thumbnail uses a real raster asset with bounded downsampling, and the source app uses the real Safari icon rather than a placeholder or hand-drawn substitute.
- Copy and content: labels are coherent and the inspected state does not leak request prose into static product copy; dynamic clipboard card content is fixture data.
- Icons and interaction states: visible controls use SF Symbols or real application icons; selected, disabled, and available states are visually distinguishable. Keyboard behavior is covered by smoke tests, but source visual fidelity remains unverified.

## Comparison History

1. Initial implementation render:
   - Finding: the completed derived Buffer preview did not expose the new Copy action, and the Clipboard preview used placeholder source icons.
   - Fix: added a ready translation snapshot to the Buffer preview seam; seeded the Clipboard preview with a real image archive and Safari bundle identifier.
   - Post-fix evidence: `buffer-rasta-translation-v2.png` and `clipboard-rasta-v2.png` show the Copy action, real thumbnail, and real source icons.
2. Final source-aligned pass:
   - Blocked before comparison because the source screenshots are not available as openable image artifacts.
3. Current toolbar revision:
   - Required evidence: collapsed → expanded → collapsed-again native renders; ordinary and live heights; empty-toolbar drag hit testing; interactive controls; no right strip; hide/protection reset. Earlier toolbarless screenshots are historical only.

## Implementation Checklist

- [x] Inspect all implementation screenshots at original resolution.
- [x] Verify the five required fidelity surfaces in implementation-only evidence.
- [x] Fix missing Copy and real-icon evidence in the render fixtures.
- [x] Render and inspect current Buffer collapsed, expanded, and collapsed-again states at 2×.
- [x] Verify 33pt toolbar + 1pt divider, 44/78 and 78/112 geometry, drag/control hit regions, no right strip, and reset on hide/protection.
- [x] Verify Clipboard image records and image-bearing files asynchronously preview, real source App icons render, and image aliases find them without network access.
- [ ] Obtain local source screenshot files.
- [ ] Normalize source and implementation to the same logical size and density.
- [ ] Build combined full-view and focused-region comparisons and rerun fidelity QA.

## Follow-up Polish

- [P3] After the source files are available, validate the input-icon toolbar toggle, toolbar edge/divider/spacing/hover states, drag cursor, control pointer states, and collapsed reset against a captured live state.

implementation result: passed; source-aligned comparison remains blocked
