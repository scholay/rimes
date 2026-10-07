# Linux #44 drag-release boundary, 2026-10-07

The repair in `c475407`, followed by the test-fixture correction in
`1a41856`, removes the IME's post-`drag_end` grace period. It does not
establish that physical button release is reported before an immediate
field click. Keep [#44](https://github.com/scholay/rimes/issues/44) open for
that boundary.

## Source contract and remaining window

- `BufferService::HandleCommand(DragEnd)` clears the pending drag and its
  hard timer. `OnActivate` then retires capture on the next activation of
  Firefox's shared input context. There is no one-second tail.
- During a pending drag, the first same-IC activation still consumes the
  pending drag while retaining capture. This preserves the WM's own focus
  return during a real move-grab.
- GTK normally detects release with a 50 ms button-state poll because
  xfwm's move-grab can consume the release event. IPC dispatch adds another
  ordering boundary. A field click between physical release and the IME's
  receipt of `drag_end` can still be mistaken for the WM focus return.
- The headless Fcitx test sends `drag_end` through the command socket before
  requesting a same-IC activation after 10 ms. It tests the command order,
  not GTK, an X11 pointer, xfwm or Firefox. Its comment now makes that scope
  explicit. Non-text drag-command logs make the dispatch order observable
  alongside the existing activation `drag=0/1` log.

The [manual timing matrix](../../platforms/linux/buffer/MANUAL-TEST.md#x11-drag-release-timing-44)
requires actual release-to-click intervals of 0, 5, 10, 30, 50 and 100 ms
on the original X11/xfwm/Firefox stack. It also checks long/tiny live drags,
preserved staged content and Escape recovery. Passing delayed cases alone
does not settle the issue.

## X11 API investigation

Fcitx5's official source at `d82ac1100ee2d125ed61df7c5c287028354bc528`
offers borrowed XCB connections via lifecycle callbacks. Existing
connections are enumerated when the callback is registered. There is no
public module function that directly returns current pointer-button state.
An input context provides its display identity, so a future X11 check must
use that display and track connection closure rather than caching an
unowned connection indefinitely. Sources:
[module API](https://github.com/fcitx/fcitx5/blob/d82ac1100ee2d125ed61df7c5c287028354bc528/src/modules/xcb/xcb_public.h),
[connection callback implementation](https://github.com/fcitx/fcitx5/blob/d82ac1100ee2d125ed61df7c5c287028354bc528/src/modules/xcb/xcbmodule.cpp),
[input-context display](https://github.com/fcitx/fcitx5/blob/d82ac1100ee2d125ed61df7c5c287028354bc528/src/lib/fcitx/inputcontext.h).

The XCB pointer query returns a cookie followed by a reply containing the
button mask. Waiting for a reply that has not arrived blocks; XCB also has
a nonblocking reply-poll API. See the
[pointer API](https://xcb.freedesktop.org/manual/group__XCB____API.html) and
[reply API](https://xcb.freedesktop.org/ProtocolExtensionApi/).
Adding an unbounded reply wait in Fcitx's activation callback could stall
its event loop if the X server stalls. A safe implementation needs a
bounded or asynchronous request, connection-lifetime handling and a clear
policy for input that arrives before the reply. This is an implementation
inference from those APIs, not a verified runtime fix. No pointer query,
per-key wait, subprocess or shorter polling interval was added.

A current button mask alone is also insufficient: the new field click can
press button 1 again before `OnActivate`, making the mask look like the
original drag never ended. A release-event/drag-sequence approach must
distinguish those gestures and be checked under the WM's actual grab.

## Verification and release boundary

The review ran on macOS. There is no running local Linux/xfwm/Firefox
desktop or Docker daemon, so neither the physical-release matrix nor
Fcitx execution was claimed as locally passed. The final Linux PR CI must
compile the addon and run the existing Fcitx command-order regression.
Source diff checks pass. No installed input method or user directory was
changed.

Wayland layer-shell disables this toolbar move-drag path; this investigation
does not prove generic Wayland drag behavior. The independent Wayland
focus-switch, password and Escape checks remain required. The Rime
directory-lock review found no new failure/cleanup/concurrency defect in
`1a41856`; [#43](https://github.com/scholay/rimes/issues/43) still retains
its separate rebuild-time shutdown-delay limitation.
