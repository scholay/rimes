# Linux Buffer — real-desktop checklist

Automated CI covers the C++ model, the in-process Fcitx5 `testfrontend` Buffer
suite, and a headless DBus/Xvfb path. It does **not** replace a real session.
Run this on Debian 13 Xfce (X11) and a wlroots Wayland session (labwc or sway).

Record distro, session type, compositor, and host for every row.

## Machines

| Distro | Session | Compositor | Host | Result |
|---|---|---|---|---|
| Debian 13 | X11 | Xfce | gedit | |
| Debian 13 | X11 | Xfce | kate | |
| Debian 13 | X11 | Xfce | Firefox | |
| Debian 13 | X11 | Xfce | xfce4-terminal / GNOME Terminal | |
| Debian 13 | Wayland | labwc | gedit | |
| Debian 13 | Wayland | labwc | kate | |
| Debian 13 | Wayland | labwc | Firefox | |
| Debian 13 | Wayland | labwc | foot / kitty / GNOME Terminal | |
| Debian 13 | Wayland | sway | gedit | |
| Ubuntu 24.04 | X11 or Wayland | any | one GTK + one terminal | |

Also try one machine with stock `fcitx5-rime` still installed: RIMES must stay
a separate IM, and `~/.local/share/rimes` must stay distinct from
`~/.local/share/fcitx5/rime`.

## Per-host cases

For each host above, switch to **RIMES** (雾凇全拼) first.

1. **Direct still works.** With Buffer hidden, type `nihao` + Space. The field
   contains `你好` and no leftover `nihao`.
2. **Open Buffer.** Press `Ctrl+Shift+B` (or `Super+Shift+B`). The workbench
   appears. The host keeps keyboard focus — the next key must not type into
   the Buffer window itself.
3. **Stage, do not leak.** Type `nihao` + Space. `你好` appears as a chip in
   Buffer. The host field is unchanged.
4. **Second block.** Type `shijie` + Space. Two chips: `你好` then `世界`.
5. **Send next.** Press Return once (or click the paper plane). Only `你好`
   is inserted. `世界` remains. No extra newline.
6. **Send all.** Stage two more commits. Hold Return about 1.2 seconds. Both
   remaining chips are inserted in order and disappear. The 2px progress bar
   appears while holding. Keep holding to ~1.7s: the host must **not**
   receive extra Enter / newlines (a terminal must not execute the line).
7. **Settle without sending.** Type `nihao` (do not press Space) then Return.
   rime_ice maps Return to `commit_raw_input`, so the chip is `nihao` (not
   `你好`). That same press must not insert into the host. A second Return
   sends the chip.
8. **Backspace.** Stage one chip, press Backspace. The chip is gone. The host
   does not delete existing text.
9. **Escape / hotkey close.** Stage a chip, press Escape **in that same
   field** (or the hotkey, or Close). Buffer hides. The chip is still there
   when you reopen. The host did not receive it.
10. **Focus change.** Open Buffer, stage a chip, click another field or
    window — including **another text field on the same Firefox / Chromium
    page** (one IC per window). Status must leave capturing even if you
    wait a few seconds before typing. Later typing goes to the new field
    (direct) and must **not** become a chip. The old chip stays. Sending
    must not write into the new field until you reopen Buffer on it. The
    field you leave must **not** gain U+200B / ZWSP. In the new field
    (including a Firefox password box) press Escape: that app must receive
    Escape; Buffer must stay visible. Dragging the X11 toolbar must **not**
    count as a field switch. Opening gedit's hamburger menu then Esc may
    pause capture (acceptable).
11. **Password.** Click a password field in a GTK host that keeps the IM
    enabled. Buffer must hide or scrub chips. Typed secrets must not appear
    in the workbench. **Firefox-esr disables the IM on
    `<input type=password>`**, so the password flag never reaches the addon:
    chips can stay visible and scrub will not run. Still confirm bugs 2/3
    do not inject ZWSP or swallow Escape in that field.
12. **Close after last.** With the default on, sending the last chip hides
    Buffer.
13. **X11 placement.** On Xfce, the first open sits **above** the caret
    when the 9-row candidate list has room below the caret (type `shi` —
    the popup must not cover chips). If the caret is at the very top, the
    panel docks to the **bottom**. If the caret is low so the popup would
    flip upward (~260 px of room missing below), the panel sits **below**
    the caret when that fits, otherwise it docks to the **top** of the
    monitor. Drag the toolbar: the body rail does not drag, **capture
    stays on**, and the next key still stages. Also check a **tiny**
    move (~3 px over ~0.8 s), and drags that **hold still 2 s and 5 s**
    before release — the next key must still go to Buffer. After a
    finished drag, clicking another Firefox field on the same page must
    pause capture. The dragged position is forgotten on the next open
    (expected).
14. **Wayland placement.** On labwc/sway the panel is overlay / always
    visible, at least 760 px wide (stretched with side margins; ~1118×77
    on a 1280-wide output is fine), chips are readable, and it does not
    steal focus. It sits at the bottom, not under the caret — expected.
15. **UI respawn.** While capturing, `kill -9` the `rimes-buffer` process
    and press no keys. After a few seconds `pgrep -x rimes-buffer` must
    show **exactly one** process. There must be one panel, not a stack of
    copies. Staging/send must keep working; do not restart fcitx5.
16. **Stale target.** Quit the captured app (e.g. Firefox) while the
    panel is open. Capture pauses, the target must not stay `firefox-esr`,
    chips remain.
17. **Composition on switch.** Start a composition (`zhongguoren`, do not
    Space), click another field. The chip is the raw input `zhongguoren`
    (no syllable spaces). It is not inserted into the old field. Switching
    away no longer silently drops it.

## X11 drag-release timing (#44)

Run this separately from the headless `rimes-buffer-fcitx-e2e` test. That
test injects socket commands and covers a same-IC activation after
`drag_end` is dispatched; it does not operate a pointer, a WM move-grab,
GTK's release detection, or Firefox's frontend.

Use the originally affected stack: X11, xfwm4 and Firefox, with two text
areas on one page (one IC shared by both). Record the build/commit, GTK,
Fcitx5, WM and browser versions. Enable Buffer capture in the first area,
stage harmless text, then drag the toolbar about 80 px. An input driver
should release button 1 and click the second area at the following delays:

| Nominal delay after physical button release | Repetitions | Required result |
| --- | --- | --- |
| 0, 5, 10 ms | At least 30 per delay | The field click pauses capture; the next text goes to the second area. |
| 30, 50, 100 ms | At least 10 per delay | The same result, with no stale drag or lost staged chip. |

Record the observed event timing, not just the requested sleep: WM grabs,
the test driver and IPC can change the actual interval. Fcitx's
`rimes.buffer` log records `toolbar drag_begin received`,
`toolbar drag_end received`, and activation with `drag=0/1`; correlate these
with the driver's physical release/click events. Do not log user text.
Distinguish these two orderings in the report:

- `drag_end` received before the field activation: capture must pause even
  at the shortest interval. This is the command-order fix's contract.
- Field activation before `drag_end` received: this is the remaining
  physical-release race. Keeping capture here is a failure of #44, even
  if another activation or Escape recovers it.

Also repeat a drag with a pause of 2 s and 5 s while button 1 remains down,
and a tiny 3 px drag: the WM's own focus return during a live drag must
keep capture. After release without a field click, the next key should
still stage. Check that the field-switch failure never commits a staged
chip to the wrong field; Escape must pause capture and preserve the chip.
Do not treat passing the >=50 ms cases or the headless test as proof of
the 0–10 ms case. Keep #44 open until the physical-release matrix passes.

Wayland layer-shell disables toolbar move-drag, so this X11 result does
not establish a Wayland drag contract. Still run the independent Wayland
focus-switch, password and Escape checks above.

## Session notes

- Xfce X11: confirm `gtk_window` keep-above above a maximized gedit.
- labwc/sway: if the panel is missing, check `libgtk-layer-shell0` is
  installed and `journalctl --user -u fcitx5` / `~/.local/share/rimes` logs.
- Firefox and terminals sometimes need `GTK_IM_MODULE=fcitx` in the session,
  not only the shell that launched the test.
- Electron/Chromium: if preedit leaks raw letters into the page while Buffer
  is capturing, record it. Linux no longer installs a client-preedit ZWSP
  (GTK/VTE/Gecko would commit it on focus-out).
- Clipboard button is a GTK `edit-paste` icon. An empty box means the icon
  theme is missing, not U+2398 tofu.

## What this checklist does not cover

Mailbox, AI / translation / stream / music plugins, IBus, and a custom
candidate window that follows the Buffer caret. Capsule has its own list in
[`../capsule/MANUAL-TEST.md`](../capsule/MANUAL-TEST.md).
