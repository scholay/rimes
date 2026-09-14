---
name: rimebuffer-project
description: RimeBuffer macOS IME architecture and implementation guidance. Use when working in this project to modify the Swift/InputMethodKit input method, librime bridge, marked-text composition session, candidate window, chord handling, status menu, settings, or buffer UI; use to preserve the Fable-era design intent and avoid regressions in IMK insertion, Rime sessions, userdb isolation, and nonactivating panels.
---

# RimeBuffer Project

## Start Here

Use this skill for code changes in `~/Documents/05-dev/apps/rime-buffer`.

Before editing, read the relevant local source and `ARCHITECTURE.md`. For nontrivial IME, Rime, candidate-window, or install changes, also read `references/fable-architecture.md`. For buffer mode, staging strip, flush behavior, or block display changes, read `references/buffer-ui.md`.

## Project Rules

- Keep RimeBuffer single-process: IMK controller, librime bridge, candidate window, buffer, status menu, and settings live inside the IME app.
- Never revive external UI polling, `state.json`, paste injection, or Accessibility text injection for normal commits.
- Keep `Delivery.insert` as the only text delivery path into the focused client.
- Keep marked text active while composing; this prevents raw-letter leaks and makes caret rect lookup reliable.
- Keep one Rime session per `IMKInputController`; do not reintroduce a shared session.
- Treat `CRimeBridge.cpp` vtable order as load-bearing; only append wrappers unless the ABI is revalidated.
- Keep `~/Library/RIMES` isolated from Squirrel's `~/Library/Rime` until a deliberate sync/direct-use migration is implemented.
- Do not run `build_install.sh` unless the user wants a live install/restart. It kills/replaces the running input method.

## Workflow

1. Identify the layer being changed: key routing, composition, candidate window, bridge, buffer, menu/settings, install, or docs.
2. Read the matching files before editing. Prefer local patterns over new abstractions.
3. Make scoped edits. Avoid unrelated cleanup in IME code because small timing changes can alter input behavior.
4. Validate with `swift build -c debug`. Run `.build/debug/RimeBuffer smoke` when touching Rime startup, bridge, schema, or key processing.
5. Check `git diff --check` and inspect the diff. Confirm `.build/` and `*.app/` remain ignored.
6. When installing for manual testing, tell the user that the input method process will restart.

## Debugging

Use `~/rimebuffer.log` for high-level behavior and `~/Library/RIMES/*.log` for librime logs. For real typing issues, capture: active app bundle id, schema id, key path, Rime handled flag, commit path, composition mode, candidate window rect source, and whether buffer mode is enabled.

## References

- `references/fable-architecture.md`: Fable-era architecture intent, failure modes, and non-negotiable IME/Rime contracts.
- `references/buffer-ui.md`: Buffer model/surface behavior, display requirements, and safe extension points.
