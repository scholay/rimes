# RIMES Design System · Design QA

## Evidence

- Source visual truth:
  - `/tmp/rimes-design-source.fmRCbL/night/settings/core-appearance--theme.png`
  - `/tmp/rimes-design-source.fmRCbL/day/settings/core-plugins--buffer-plugins.png`
  - `/tmp/rimes-design-source.fmRCbL/night/buffer-translation.png`
  - `/Users/isaac/Documents/05-dev/apps/rime-buffer-design-system/images/Pencil 2026-07-04 23.09.43.png`
- Source implementation anchors:
  - `Sources/RimeBuffer/RimeUI.swift`
  - `Sources/RimeBuffer/SettingsWindow.swift`
  - `Sources/RimeBuffer/CandidateWindow.swift`
  - `Sources/RimeBuffer/BufferWindowController.swift`
- Implementation URL attempted: `http://terminal.local:4173/`
- Implementation screenshot path: unavailable; the browser runtime reported that no browser was connected.
- Intended browser viewport: 1440 × 1000 CSS px at device scale factor 1.
- Source dimensions and normalization:
  - Settings source: 1960 × 1360 px at 2×, normalized target 980 × 680 CSS px.
  - Buffer translation source: 1520 × 224 px at 2×, normalized target 760 × 112 CSS px.
  - Historical candidate reference: 1028 × 140 px; used as product-language reference, while current geometry is taken from native layout constants (460 × 59 logical pt default).
- Intended comparison state: 墨竹 theme; appearance page, buffer-plugin page, translation Buffer, compact candidate; default fixture data.

## Full-view comparison evidence

The native source captures were generated and opened during implementation. The React project builds and the local URL serves correctly, but a browser-rendered implementation screenshot could not be captured because the environment exposed no in-app or extension browser. A visual comparison cannot be represented as complete without that second artifact.

## Focused region comparison evidence

Blocked for the same reason. The planned focused regions are:

- Settings sidebar, segmented subpage control, theme cards and plugin rows.
- Candidate preedit, selected candidate, pagination and Buffer action strip.
- Buffer toolbar, source/target rails, translation language swap and protected state.
- Clipboard 40 pt rail, selected/active cards and protected placeholder.

## Findings

- [P0] Browser-rendered implementation evidence is missing.
  - Location: all five React surfaces.
  - Evidence: browser discovery returned an empty browser list; no implementation pixels or console log could be captured.
  - Impact: typography, clipping, contrast, focus treatment and responsive behavior cannot receive the required visual sign-off.
  - Fix: connect the in-app browser, or receive explicit permission to use direct Playwright automation; capture all five surfaces in 墨竹 and 翡翠, then compare the matching source and implementation images in a combined artifact.

## Static and functional checks completed

- `npm run typecheck`: passed.
- `npm run build`: passed.
- `npm run test:sites`: 4/4 passed.
- `npm run tokens:swift`: passed.
- Five-surface CSS class coverage: no missing product selectors.
- Plugin configuration is shared between Settings and Extensions.
- Optional Buffer plugins are unavailable until installed and enabled.
- Translation language swap updates both source and target state.
- Buffer generation is invalidated on mode, source and privacy changes.
- Candidate keyboard routing excludes its own layout, pagination and settings controls.

## Required fidelity surfaces

- Fonts and typography: token and CSS definitions use the macOS system-font stack; pixel fidelity remains unverified.
- Spacing and layout rhythm: native logical dimensions are encoded; browser clipping and wrapping remain unverified.
- Colors and visual tokens: native 墨竹 / 翡翠 / 静谧 values and fixed product accent are encoded; rendered contrast remains unverified.
- Image quality and asset fidelity: UI uses the Phosphor icon adapter and no placeholder imagery; rendered icon alignment remains unverified.
- Copy and content: preset plugin names, versions, default install state and native UI terminology were checked against the repository.

## Comparison history

- Pass 0: source captures available; implementation browser capture unavailable. No visual fixes can be certified from a combined comparison input.

## Implementation checklist

- Capture 1440 × 1000 full-workbench screenshots for all five surfaces.
- Capture 1:1 focused regions for Settings 980 × 680, Candidate 460 × 59 and Buffer 760 × 112.
- Exercise theme switching and core interactions while checking the browser console.
- Place each native source and matching React capture into a single comparison image.
- Fix any P0/P1/P2 findings, recapture and update this report.

final result: blocked
