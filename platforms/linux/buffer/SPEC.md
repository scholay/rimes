# Linux Buffer behavior spec

This is the acceptance baseline for the Linux Default Buffer. It is derived
from macOS `BufferModel`, `RimeBufferController.drainCommit`,
`BufferDeliveryCoordinator`, and `.codex/skills/rimebuffer-project/references/buffer-ui.md`.
Linux implements the **Default** workbench only. AI / translation / stream /
music plugins and Mailbox are out of scope. Capsule is a sibling component
documented in `platforms/linux/capsule/SPEC.md`.

The macOS hunch is confirmed: `RimesIme::commitText` is the single Fcitx5
commit path, the analogue of `drainCommit` before `Delivery.insert`. When
Buffer capture owns the focused input context, that text is appended as a
block and is **not** committed to the host.

## Three independent states

| State | Meaning | Linux field |
|---|---|---|
| Visibility | Is the workbench shown? | `BufferModel.visible` |
| Content | Are there unsent blocks? | `BufferModel.blocks` |
| Input route | Do keys/commits go to Buffer or the host? | `capture_enabled` + `capture_token` |

Showing the workbench does not by itself steal keys. Closing pauses capture
and **preserves** staged blocks. Switching to another field while capturing
returns the route to the host and keeps blocks. Process restart drops
content; blocks are not persisted.

## Blocks

- A Rime commit is one block (`origin=rime`). Commit boundaries are
  meaningful and are not re-diffed.
- Unhandled printable ASCII while capturing may join a growing `local` tail
  (short Latin phrases), matching macOS `appendDirectInputFragment`.
- Clipboard import is `origin=clipboard`.
- Each block has a stable id, text, origin, and `created_at_ms`.
- Successful delivery consumes that block immediately. There is no send
  history and no undo.
- Empty / hidden / paused / password / secure intervals do not auto-send.

## Capture and delivery

1. `Ctrl+Shift+B` or `Super+Shift+B` (hidden → visible) grants capture to the
   current Fcitx5 input context and shows the workbench. The host stays the
   delivery anchor; the workbench does not take keyboard focus.
2. The same hotkey, unmodified Escape **on the captured IC**, or Close
   pauses capture, hides the workbench, and keeps blocks.
3. While capturing, Space/number commits go to Buffer, not the host.
4. While capturing, a composing Return is fed to Rime so it can settle into a
   block. rime_ice uses `commit_raw_input`, so `nihao` + Return stages
   `nihao`. That same physical press must not send.
5. A ready Return tap (`< 1.2s`) is `sendNext`. Holding Return for 1.2s is
   `sendAll`. The paper-plane button is `sendNext` only. After send-all
   closes the workbench (default close-after-last), leftover Return
   auto-repeats and the key-up stay consumed until that physical key is
   released, so Enter cannot leak into the host.
6. Unmodified Escape is consumed **only** for the captured input context.
   Escape in any other field or window must reach that app. Switching away
   returns the route to the host and keeps the workbench visible with its
   staged chips.
7. Backspace edits an open direct tail or removes the last block. It never
   reaches the host while capturing.
8. Delivery calls `ic->commitString` on the **same** captured input context
   after re-checking that it is still focused. Focus change, password fields,
   and secure state fail closed and leave remaining blocks in place.
9. “Close after last delivery” defaults on: only a successful drain of the
   last pending block close-and-pauses.
10. The companion `rimes-buffer` process is a renderer. If it dies (including
    `kill -9`) or its socket drops, the addon treats `waitpid` `ECHILD` /
    `ESRCH` as dead. A dropped socket starts a retry/backoff (50 ms, then
    2 s waits). Only the pid that dropped the socket is force-replaced; a
    child this retry already started is given several seconds to connect
    (GTK can take well over 150 ms on slow hardware). The old child is
    reaped or killed before a replacement is forked. There is at most one
    UI process. Fcitx5's SIGCHLD handler may already have reaped the pid.
11. Destroying the captured input context (app exit) pauses capture, clears
    the toolbar target, and keeps any staged chips. The workbench stays
    visible as Paused with target `·` until the user closes it.
12. A same-IC reactivation keeps capture **only** while the IME still has an
    explicit toolbar drag pending. The UI detects the end of the WM move-grab:
    it polls pointer button 1 about every 50 ms after `begin_move_drag` and
    sends `drag_end` on release or a 30 s safety cap. It does **not**
    treat configure-idle or grab-broken as the end — xfwm fires
    grab-broken when it *takes* the move-grab, while the button is
    still down. Once the IME **receives** `drag_end`, the next same-IC
    reactivation pauses capture immediately; there is no post-drag tail.
    Before that message arrives, the **first** same-IC reactivation after
    `drag_begin` keeps capture and consumes the pending drag, so a later
    reactivation is a field switch and pauses. Physical button release and
    receipt of `drag_end` are different events: the 50 ms UI poll and socket
    dispatch can leave a window in which a fast field click is still taken
    for the drag's focus return ([#44](https://github.com/scholay/rimes/issues/44)).
    The command-order regression covers the IME after receipt, not this
    physical-release window. Every other same-IC reactivation is a field
    switch. A gedit hamburger-menu focus blip pauses capture (expected). Another IC
    activating, or a focus-out grace (`RIMES_BUFFER_FOCUS_GRACE_MS`,
    default 5000) without the same IC returning, also drops capture. A
    key must never be routed into Buffer when the focused field may have
    changed since capture started; the unresolved physical-release window
    remains an acceptance gap for that requirement.
13. An unresolved composition at a real field switch is staged as a `local`
    block using librime `get_input` (raw spelling, e.g. `zhongguoren`), the
    same text composing Return / `commit_raw_input` would settle. Syllable
    spaces in the display preedit (`zhong guo ren`) are not kept. The Rime
    session is then reset. The text is not committed to the host and is not
    the highlighted candidate.

## Workbench chrome

- ~760×78 window: 33px toolbar + divider + one full-width rail.
- Toolbar: Default label, status, passive target name, Close. Empty chrome
  is the X11 drag region.
- Rail: placeholder when idle and empty; otherwise chips + inline preedit.
- Trailing overlay: clipboard import (`edit-paste` icon) and send next
  (`go-next` icon). They must not shrink the rail. Do not use U+2398; Debian
  fonts often lack that glyph.
- Hold progress is a 2px bar along the bottom, not extra height.
- Password / secure snapshots scrub plaintext.

## Placement, focus, always-on-top

### X11 (Xfce and the CI Xvfb path)

- Borderless, skip-taskbar, `keep_above`, `accept_focus=false`.
- Window type is `UTILITY` (not `DOCK`) so xfwm can honor
  `gtk_window_begin_move_drag` on the toolbar. DOCK windows on Xfce are not
  user-movable.
- On first show, if Fcitx5 reports a caret rect, center horizontally on it.
  Stock Fcitx5 candidates are ~250 px (9 rows). They grow downward unless
  caret-bottom + ~260 px exceeds the workarea, in which case the popup
  **flips upward**. Place the panel on the opposite side of the popup:
  prefer **above** the caret when the list opens down; when it would flip
  up, sit **below** the caret if that fits, otherwise dock to the **top**
  of the monitor. Never sit a small gap on the same side as the popup.
- A user drag moves the window for this showing only. The next open uses
  the caret rule again; the dragged position is **not** remembered (no
  layout file, and Wayland compositors own placement).
- The window does not follow later caret motion on the same display.
  Dragging the toolbar must not pause capture, including a tiny move
  or holding still for several seconds before release. A non-drag
  same-IC focus blip (for example gedit's hamburger menu) **does**
  pause capture — that is the safe default.

### wlroots Wayland (labwc / sway)

- `gtk-layer-shell` overlay layer, bottom-anchored **and** left/right
  stretched with ~80px side margins and a 48px bottom margin, plus a
  760×78 **minimum** size request. On a typical 1280-wide output the
  allocated size is about 1118×77 — that is expected, not a shrink to
  ~184×75. Keyboard interactivity none.
- The compositor owns vertical position. There is no reliable “10px under
  the caret” API on stock layer-shell.

### Other Wayland (GNOME, KDE)

- Without layer-shell the window is a normal xdg-toplevel. Position,
  always-on-top, and non-activating behavior are compositor-defined and
  **not** claimed.

## Deliberate macOS mismatches

| macOS behavior | Linux | Reason |
|---|---|---|
| Single IMK process owns UI | Companion `rimes-buffer` process + event-driven Unix socket | Fcitx5 addons must not assume a GTK display; a UI crash must not kill typing |
| Nonactivating `NSPanel` + Spaces | X11 keep-above / Wayland layer-shell | No AppKit / Spaces; Wayland clients cannot place or steal focus freely |
| Caret-anchored 10pt open | X11 only | wlroots layer-shell cannot place relative to a text caret |
| Invisible U+200B IMK guard | **No client-preedit ZWSP** | GTK, VTE and Gecko commit a leftover client preedit on focus-out, including into password fields. Real preedit is shown only in the workbench while capturing. |
| Custom detached `CandidateWindow` | Stock Fcitx5 candidate panel | IME step 1 already uses Fcitx5 UI; a second chrome is a later port |
| Exact `FocusToken` + PID/bundle/AX box lock | IC pointer + focused-IC recheck | No IMK client identity and no Accessibility tree |
| `Command+Shift+B` while another IM is active | Only while RIMES is current | No LaunchAgent analogue in this step |
| AI / translation / stream / music plugins | Default only | Later components (and Capsule / Mailbox) |
| Secure Input + session lock/sleep | Password capability + snapshot scrub | No Carbon Secure Event Input; lock/sleep hide is manual-test only. **Firefox disables the IM on `<input type=password>`**, so `CapabilityFlag::Password` never reaches the addon and captured chips can stay visible. Scrub cannot run. Escape / Return / preedit must still not touch an uncaptured field. |
| Command+C generated-result copy | Not implemented | No generated-result workspace |
| Pin to all Spaces / display recovery | Not implemented | No Spaces |
| Themes 墨竹 / 翡翠 / 静谧 / Rasta | One Classic-like dark chrome | Visual port, not a theme engine |

## IPC

Length-prefixed JSON (4-byte big-endian + UTF-8) on
`$XDG_RUNTIME_DIR/rimes-buffer.sock` (override: `RIMES_BUFFER_SOCKET`).
The IME owns the model. The UI and `rimes-buffer-ctl` are clients.

Commands: `hello`, `status`, `toggle`, `show`, `close`, `send_next`,
`send_all`, `remove_last`, `select_all`, `paste`, `set_insertion`,
`drag_begin`, `drag_end`.
Connecting publishes the current snapshot immediately; mutating commands
are applied on the Fcitx thread and publish again. `rimes-buffer-ctl`
and the DBus e2e client drain the connect snapshot before treating a
mutating op as done.

Environment for tests: `RIMES_BUFFER_HEADLESS=1` (no GTK spawn),
`RIMES_BUFFER_AUTO_CAPTURE=1` (capture on activate),
`RIMES_BUFFER_CLOSE_AFTER_LAST=0`,
`RIMES_BUFFER_FOCUS_GRACE_MS` (same-IC unfocus grace; default 5000),
`RIMES_BUFFER_UI=/path` (override the GTK binary, used by the respawn e2e),
`RIMES_BUFFER_CONNECT_DELAY_MS` (UI sleeps before connecting; simulates
slow GTK startup),
`RIMES_BUFFER_DUMP=/path.json` (atomic snapshot file for in-process e2e).
