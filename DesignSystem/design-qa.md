# RIMES Design System · Design QA

## Run

- Date: 2026-08-20
- Browser: the user-selected Chrome browser, controlled through the Chrome plugin.
- Browser viewport: 1632 × 967 CSS px.
- Prototype: `http://localhost:4173/?surface=settings&theme=day`
- Native source: current AppKit renderers from the same `design/react-system` worktree.
- Native normalization:
  - Settings: 1960 × 1360 px at 2× → 980 × 680 logical px.
  - Translation Buffer: 1520 × 224 px at 2× → 760 × 112 logical px.

## Evidence

Current-run native sources:

- `/tmp/rimes-react-color-audit/native/day/settings/core-appearance--theme.png`
- `/tmp/rimes-react-color-audit/native/night/settings/core-appearance--theme.png`
- `/tmp/rimes-react-color-audit/native/day/buffer-translation.png`
- `/tmp/rimes-react-color-audit/native/night/buffer-translation.png`

Current-run React captures:

- `/tmp/rimes-react-color-audit/after-01-settings-day.png`
- `/tmp/rimes-react-color-audit/after-02-settings-night.png`
- `/tmp/rimes-react-color-audit/after-03-buffer-night-translation.png`
- `/tmp/rimes-react-color-audit/after-04-buffer-day-translation.png`
- `/tmp/rimes-react-color-audit/after-05-candidate-day.png`
- `/tmp/rimes-react-color-audit/after-06-clipboard-day.png`
- `/tmp/rimes-react-color-audit/after-07-clipboard-protected-day.png`
- `/tmp/rimes-react-color-audit/after-08-extensions-failure-day.png`
- `/tmp/rimes-react-color-audit/after-09-translation-dialog-day.png`
- `/tmp/rimes-react-color-audit/after-10-extensions-quiet.png`

Combined source/implementation comparisons used for visual review:

- `/tmp/rimes-react-color-audit/compare-settings-day-after.png`
- `/tmp/rimes-react-color-audit/compare-settings-night-after.png`
- `/tmp/rimes-react-color-audit/compare-buffer-day-after.png`
- `/tmp/rimes-react-color-audit/compare-buffer-night-after.png`

## Findings and resolution

1. **[P1 · fixed] Accent fill was also used as foreground text.**
   - The fixed product green `#22C55E` is suitable for controls and fills but had only about 2:1 contrast as small text in 翡翠.
   - Added the separate `accentText` semantic: 墨竹 `#22C55E`, 翡翠 `#0F6A3F`, 静谧 `#A3A3A3`.
   - Status labels, small icons, selected borders and focus indicators now use `accentText`; switches and primary fills retain `accent`.

2. **[P1 · fixed] Settings used the generic surface instead of the AppKit window background.**
   - Added `settingsBackground` and `settingsSeparator` tokens matching the current native renderer.
   - Settings chrome now uses `#323232` for 墨竹/静谧 and `#ECECEC` for 翡翠.
   - Each theme choice card now receives its own theme scope, so all three previews remain visually truthful regardless of the active theme.

3. **[P1 · fixed] Candidate selected metadata lost contrast.**
   - Selected index and annotation no longer reduce the native selection foreground with opacity.
   - Unselected indices use the native secondary-text semantic instead of muted text.

4. **[P1 · fixed] Buffer and Clipboard reused unrelated surface/selection colors.**
   - Buffer toolbar, content, divider, source rail, target rail, chips and muted text now have explicit native-derived semantics.
   - The React translation target uses a light accent tint like the AppKit block chip, rather than a deep candidate selection fill.
   - Clipboard inactive, active, selected and protected states now use distinct rail/card semantics.

5. **[P1 · fixed] Warning and error states shared an inaccessible foreground.**
   - Added separate warning and danger foreground/surface/border tokens.
   - 翡翠 warning text now uses `#8A4B00`; errors use the danger semantic instead of warning orange.

## Browser verification

- Switched the same running app through 墨竹, 翡翠 and 静谧.
- Checked Settings, Extensions/menu, Candidate, Buffer, Clipboard, protected state, engine failure state and the realtime-translation configuration dialog.
- Visible bright product green is now used as a fill in 翡翠; the browser scan found no exact `#22C55E` foreground text in that theme.
- Console warnings/errors: none.
- Document horizontal overflow: none.
- Visible elements outside the viewport: none.

## Automated verification

- `npm run tokens:swift`: passed.
- `npm run test:colors`: passed for all three themes.
- `npm run typecheck`: passed.
- `npm run build`: passed.
- `npm run test:sites`: 4/4 passed.
- The color check enforces WCAG 4.5:1 for primary/secondary/muted text, accent text, selected text, Buffer muted text, warnings and danger text against their intended surfaces.

## Accepted implementation boundaries

- The React lab specifies visual tokens, component anatomy and interaction states; AppKit remains authoritative for IME focus, nonactivating panels and text delivery.
- The input-source menu is a design mock of a native `NSMenu`, whose production chrome is controlled by macOS.
- Clipboard is a forward-looking design surface; the current native product does not yet capture a clipboard history.
- Phosphor icons map to semantic icon IDs; production AppKit maps the same intent to SF Symbols, so icon paths are not expected to be pixel-identical.

final result: passed
