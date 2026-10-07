# RIMES Fcitx5 input method (Linux)

This is a real RIMES frontend for [Fcitx5](https://fcitx-im.org/): a C++ addon
that links `librime` (with `librime-lua` and OpenCC) and deploys the reviewed
RIMES `rime-data` set. It lives next to the existing
[Linux data preview](../README.md), which still installs into stock
`fcitx5-rime` / `ibus-rime` and is unchanged.

This is step 3 of the Linux port (IME + Default Buffer + Capsule rail).
Mailbox is still later. Buffer and Capsule behavior are specified in
[`../buffer/SPEC.md`](../buffer/SPEC.md) and
[`../capsule/SPEC.md`](../capsule/SPEC.md). Hooks live in
`src/engine/rime_hooks.hpp`.

## What works

- Preedit and Fcitx5 candidate UI (inline XOR popup row, matching stock rime)
- Space commit (`nihao` + Space → `你好` on `rime_ice`)
- Number keys 1–9 select the current page
- Page Up / Page Down
- Escape cancels composition without committing
- First-run (and later rebuild) dictionary deploy runs in the background;
  Fcitx5 stays responsive and keys pass through until librime is ready
  (`subMode` shows `Deploying`). The maintenance thread notifies the Fcitx5
  event loop when deploy finishes — status leaves `Deploying` without a restart.
- A process-lifetime user-directory lock prevents two RIMES instances from
  deploying or opening user dictionaries in the same directory concurrently.
  A replacement reports a locked-directory error until the owner finishes
  exiting. The lock file remains on disk; the OS releases ownership on exit.
- Isolated user directory: `$XDG_DATA_HOME/rimes` (not `…/fcitx5/rime`)
- Shared data: `$prefix/share/rimes/data` (policy-staged 55-file closure)
- Default Buffer workbench (`Ctrl+Shift+B` / `Super+Shift+B`): Rime commits
  stage as blocks, Return tap/hold and the paper plane send through the same
  `commitText` → `commitString` path
- Capsule rail (`Ctrl+Shift+V` / `Super+Shift+V`): local Markdown notes,
  seed card `RIMES 默认词条`, Return inserts the selected note through
  `commitString` after an armed-IC recheck

macOS-only behaviour that is **not** reproduced here: custom candidate chrome,
Mailbox, Capsule clipboard history / iCloud / password vault / media kinds,
Buffer plugins (AI / translation / stream / music), cross-batch chord pairing,
IMK `Delivery.insert`. See [`../buffer/SPEC.md`](../buffer/SPEC.md) and
[`../capsule/SPEC.md`](../capsule/SPEC.md) for the explicit gap lists.

## Maintenance limits

Stopping Fcitx5 during a librime rebuild can still wait for that rebuild to
finish ([#43](https://github.com/scholay/rimes/issues/43)). Do not start a
second instance against the same user directory while waiting. The lock
prevents concurrent RIMES writers; it does not coordinate stock fcitx5-rime,
IBus, or external deploy tools. A bounded shutdown requires deployment
process isolation rather than detaching a thread that still uses librime.

Buffer preserves capture for a same-IC activation only while a toolbar drag
is active. After release, the next activation always retires capture, even
when another field is clicked immediately ([#44](https://github.com/scholay/rimes/issues/44)).

## Dependencies

See `scripts/deps.sh --print` for Debian/Ubuntu, Arch, and Fedora package
lists. On Ubuntu 24.04:

```bash
platforms/linux/ime/scripts/deps.sh --install
```

`librime-plugin-lua` and a distro OpenCC `opencc/s2t.json` are required. The
addon will not bundle those.

## Build and install

```bash
platforms/linux/ime/scripts/build.sh
platforms/linux/ime/scripts/install.sh          # default prefix: ~/.local
# or
sudo RIMES_IME_PREFIX=/usr platforms/linux/ime/scripts/install.sh
fcitx5 -r
```

Then add **RIMES** in Fcitx5 configuration. Restart the compositor/session if
the new input method does not appear.

Environment overrides used by tests and unusual layouts:

| Variable | Meaning |
|---|---|
| `RIMES_SHARED_DIR` | Absolute SharedSupport root (`default.yaml`) |
| `RIMES_USER_DIR` | Isolated user dir (must not be the stock fcitx5-rime path) |
| `RIMES_LOG_DIR` | librime log directory |

## Packaging

```bash
platforms/linux/ime/scripts/package-deb.sh /tmp/rimes-deb
```

writes `fcitx5-rimes_<version>_<arch>.deb` (addon + `rimes-buffer` +
`rimes-buffer-ctl` + `rimes-capsule` + `rimes-capsule-ctl` + reviewed data).
The package `Recommends: libgtk-layer-shell0, wl-clipboard` so a wlroots
session can keep the rail overlay and copy notes without a GTK serial.
Flatpak notes are in
`packaging/flatpak/README.md`. The data preview tarball is a separate artifact
and stays data-only.

## Tests

```bash
platforms/linux/ime/scripts/run-tests.sh
```

1. CTest unit tests (keysyms, UTF-8 snapshot, path isolation)
2. Live `librime` smoke: `nihao` + Space, number selection, paging, Escape
3. In-process Fcitx5 `testfrontend` (no display)
4. Optional Xvfb + live Fcitx5 DBus virtual input context
5. GTK/Qt hosts via `xdotool` (best-effort: headless Xvfb has no window
   manager, so toolkit IM modules may not commit even when DBus does)
6. Weston headless is probed when installed; injecting keys into a
   seat-less compositor is a documented limitation

GitHub Actions workflow `.github/workflows/linux-ime.yml` runs the same
sequence on `ubuntu-latest`. It is **not** a macOS merge/release gate.

## IBus follow-up

An IBus engine can reuse `RimeEngine`, `EngineSnapshot`, and the path resolver.
It would be a new `ibus-rimes` component XML plus a C++ `IBusEngine` that maps
IBus keysyms (already X11) into `ProcessKey` and commits with
`ibus_engine_commit_text`. Estimate: similar size to this addon, no Fcitx5 UI.
Not started in this tree.

## Buffer / Capsule / Mailbox

Buffer and Capsule are implemented: `BufferService` / `CapsuleService` live
in the addon. GTK companions are `rimes-buffer` and `rimes-capsule`, on
`$XDG_RUNTIME_DIR/rimes-buffer.sock` and
`$XDG_RUNTIME_DIR/rimes-capsule.sock`. Mailbox is not started.

See `src/engine/rime_hooks.hpp`. Ordinary Rime commits still go through
`RimesIme::commitText` → `InputContext::commitString` (or into Buffer when
capture owns that IC). Capsule insert calls `commitString` after the armed
token recheck so it cannot become a Buffer chip. One Rime session per
Fcitx5 input context. Do not start a second librime runtime.
