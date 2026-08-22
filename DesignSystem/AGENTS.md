# Prototype Instructions

Run the local server yourself and open the preview in the browser available to this environment. Do not give the user server-start instructions when you can run it.

Before making substantial visual changes, use the Product Design plugin's `get-context` skill when the visual source is unclear or no longer matches the current goal. When the user gives durable prototype-specific design feedback, preferences, or decisions, record them in `AGENTS.md`.

## RIMES Design System Contract

- This project is the interactive React design source for RIMES. It documents and exercises settings, extension configuration, the candidate window, the Buffer workbench, and clipboard history.
- Match the current native product language: system typography, compact macOS density, the 墨竹 / 翡翠 / 静谧 palettes, and the product-owned accent defined by `Sources/RimeBuffer/RimeUI.swift`.
- Keep production input behavior native. This React project may model focus, delivery, privacy, and plugin states, but it must never become the runtime IME window or introduce WebView dependencies into ETInput.
- Components must be built from shared tokens and reusable primitives. Avoid screen-local color, radius, spacing, and typography literals when a semantic token exists.
- Every primary control in the five showcase surfaces should work with realistic local state. No network, clipboard, or input-field access is required in the design lab.
- Preserve the Sites-ready worker/build files so the design lab can be previewed locally or shared later without restructuring it.

## Confirmed Product Decisions

- Keep the input-source menu limited to exactly three destinations: Settings, External Source Inbox, and Maintenance. Do not restore the former Buffer visibility, pinning, movement, update, deployment, reinstall, restart, or log actions in this menu.
- Keep core Input Method settings limited to Input Schemes and Dictionaries. The ordinary scheme catalog is Full Pinyin, Natural Code double pinyin, Xiaohe double pinyin, Wubi86, and English; do not restore the former Typing Mode page. Keep `builtin.fly-chord-learning` as the stable internal ID, but present it as the bundled `并击` 2.0 extension with Settings, Courses, Practice, and Progress. Its enable state is the sole gate for chord processing: Stream Input accepts chord-to-full-pinyin only while the extension is enabled, and otherwise remains sequential full-pinyin.
- Keep the current Buffer catalog limited to AI Generation 2.1, Real-time Translation 2.1, and Stream Input 1.3. My Prompt, Remarkable, and Marine Chrome are retired from current cards, configuration branches, and Buffer modes. Keep External Source Inbox independent of those retired plugins and use neutral local-pairing fixtures.
- The Buffer result-count contract is 1–5, the current design defaults to five results, and five-result presentation uses an in-rail pager. The native runtime now implements the same contract; future changes must keep the React design source and AppKit implementation synchronized.
- The Buffer design master may remain fixed at 760 logical points wide. Responsive width behavior is not required for this prototype unless the user revises this decision.
- Single-exchange is an accepted Buffer interaction pattern: a source rail may visually exchange into a result rail. Preserve both source and result state until delivery has been confirmed successful; a request or delivery failure must not discard either state.
- Routine Buffer states render no toolbar status element and reserve no status width. Actionable progress, protection, failure, or delivery feedback may render the fixed 88pt status slot.
- The Buffer main action is a 22×22 icon-only control. Its visible icon changes with generation and delivery state, while its accessible label and tooltip retain the complete action or progress text.
- Controlled Buffer hosts must round-trip the `requestID` and `contextKey` emitted by `onGenerate`, keep `activeRequestID` aligned with the displayed result, honor generation/delivery `AbortSignal`s, and treat only an explicit `true` send acknowledgement as delivery success.

When implementing from a selected generated mock, treat that image as the source of truth for layout, component anatomy, density, spacing, color, typography, visible content, and hierarchy.

Build app UI in `src/`. Keep `.openai/hosting.json`, `worker/index.js`, `scripts/prepare-sites-build.mjs`, and `tests/sites-worker.test.mjs` intact so the same local prototype can be handed to Sites. Before a Sites handoff, run `npm run build` and `npm run test:sites`; the build must leave `dist/client/index.html`, `dist/server/index.js`, and `dist/.openai/hosting.json`.
