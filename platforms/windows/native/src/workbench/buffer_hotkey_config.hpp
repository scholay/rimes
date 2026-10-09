#pragma once

#include <Windows.h>
#include <array>

namespace rimes::windows::workbench {
struct BufferHotkeyChoice {
  unsigned modifiers;
  const wchar_t* label;
};
inline constexpr std::array<BufferHotkeyChoice, 3> kBufferHotkeyChoices{{
    {MOD_CONTROL | MOD_SHIFT, L"Ctrl+Shift+"},
    {MOD_CONTROL | MOD_ALT, L"Ctrl+Alt+"},
    {MOD_ALT | MOD_SHIFT, L"Alt+Shift+"}}};

inline int BufferHotkeyChoiceIndex(unsigned modifiers) {
  for (std::size_t i = 0; i < kBufferHotkeyChoices.size(); ++i)
    if (kBufferHotkeyChoices[i].modifiers == modifiers) return static_cast<int>(i);
  return -1;
}
inline bool ValidBufferHotkeyModifiers(unsigned modifiers) {
  return BufferHotkeyChoiceIndex(modifiers) >= 0;
}
}  // namespace rimes::windows::workbench
