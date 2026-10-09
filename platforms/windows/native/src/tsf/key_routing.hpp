#pragma once

#include <Windows.h>
#include "../core/broker_protocol.hpp"

namespace rimes::windows::tsf::detail {

// OnTestKeyDown must not advertise ownership of keys that the product's idle
// engine will decline: dialog hosts can drop such keys before OnKeyDown can
// fail open. No IPC or engine mutation occurs in this prediction.
inline bool RoutePrintableKey(WPARAM key, std::uint32_t modifiers,
                              bool composing, bool capturing,
                              bool ascii_mode) noexcept {
  if (composing || capturing) return true;
  if (ascii_mode) return false;
  const bool shifted = (modifiers & static_cast<std::uint32_t>(
      core::KeyModifiers::kShift)) != 0;
  const bool digit = (key >= '0' && key <= '9') ||
                     (key >= VK_NUMPAD0 && key <= VK_NUMPAD9);
  // Shift+number is punctuation, not an idle digit. Preserve the schema's
  // punctuation mapping, candidate numbers, and Buffer's own text capture.
  return (shifted || !digit) && key != VK_SPACE;
}

}  // namespace rimes::windows::tsf::detail
