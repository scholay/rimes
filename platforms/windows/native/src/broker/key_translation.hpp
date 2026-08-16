#pragma once

#include <cstdint>
#include <optional>

#include "../core/broker_protocol.hpp"

namespace rimes::windows::broker {

// X11/IBus keysyms and modifier masks consumed by librime's process_key API.
// The TSF protocol intentionally carries Windows virtual-key data instead, so
// this adapter is the single translation boundary between the two domains.
struct RimeKeyEvent {
  std::int32_t keycode = 0;
  std::int32_t modifiers = 0;
};

std::optional<RimeKeyEvent> TranslateWindowsKey(
    const core::KeyEvent& event) noexcept;

// OnTestKeyDown cannot call process_key because that would mutate librime
// before TSF delivers the real OnKeyDown. This conservative predictor only
// claims keys for which a subsequent real event can reasonably be routed to
// Rime. False negatives pass through; false positives must be avoided.
bool IsLikelyHandledForTest(const core::KeyEvent& event,
                            bool session_is_composing) noexcept;

}  // namespace rimes::windows::broker
