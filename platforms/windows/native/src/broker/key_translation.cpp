#include "key_translation.hpp"

#include <limits>

namespace rimes::windows::broker {
namespace {

inline constexpr std::int32_t kShiftMask = 1 << 0;
inline constexpr std::int32_t kLockMask = 1 << 1;
inline constexpr std::int32_t kControlMask = 1 << 2;
inline constexpr std::int32_t kAltMask = 1 << 3;
inline constexpr std::int32_t kMod2Mask = 1 << 4;  // Num Lock
inline constexpr std::int32_t kSuperMask = 1 << 6;
inline constexpr std::int32_t kReleaseMask = 1 << 30;

inline constexpr std::int32_t kBackspace = 0xff08;
inline constexpr std::int32_t kTab = 0xff09;
inline constexpr std::int32_t kClear = 0xff0b;
inline constexpr std::int32_t kReturn = 0xff0d;
inline constexpr std::int32_t kPause = 0xff13;
inline constexpr std::int32_t kScrollLock = 0xff14;
inline constexpr std::int32_t kEscape = 0xff1b;
inline constexpr std::int32_t kHome = 0xff50;
inline constexpr std::int32_t kLeft = 0xff51;
inline constexpr std::int32_t kUp = 0xff52;
inline constexpr std::int32_t kRight = 0xff53;
inline constexpr std::int32_t kDown = 0xff54;
inline constexpr std::int32_t kPageUp = 0xff55;
inline constexpr std::int32_t kPageDown = 0xff56;
inline constexpr std::int32_t kEnd = 0xff57;
inline constexpr std::int32_t kPrint = 0xff61;
inline constexpr std::int32_t kInsert = 0xff63;
inline constexpr std::int32_t kMenu = 0xff67;
inline constexpr std::int32_t kHelp = 0xff6a;
inline constexpr std::int32_t kNumLock = 0xff7f;
inline constexpr std::int32_t kKeypadEnter = 0xff8d;
inline constexpr std::int32_t kKeypadMultiply = 0xffaa;
inline constexpr std::int32_t kKeypadAdd = 0xffab;
inline constexpr std::int32_t kKeypadSeparator = 0xffac;
inline constexpr std::int32_t kKeypadSubtract = 0xffad;
inline constexpr std::int32_t kKeypadDecimal = 0xffae;
inline constexpr std::int32_t kKeypadDivide = 0xffaf;
inline constexpr std::int32_t kKeypad0 = 0xffb0;
inline constexpr std::int32_t kF1 = 0xffbe;
inline constexpr std::int32_t kShiftLeft = 0xffe1;
inline constexpr std::int32_t kShiftRight = 0xffe2;
inline constexpr std::int32_t kControlLeft = 0xffe3;
inline constexpr std::int32_t kControlRight = 0xffe4;
inline constexpr std::int32_t kCapsLock = 0xffe5;
inline constexpr std::int32_t kAltLeft = 0xffe9;
inline constexpr std::int32_t kAltRight = 0xffea;
inline constexpr std::int32_t kSuperLeft = 0xffeb;
inline constexpr std::int32_t kSuperRight = 0xffec;
inline constexpr std::int32_t kDelete = 0xffff;

inline constexpr std::uint32_t kVirtualKeyBack = 0x08;
inline constexpr std::uint32_t kVirtualKeyTab = 0x09;
inline constexpr std::uint32_t kVirtualKeyClear = 0x0c;
inline constexpr std::uint32_t kVirtualKeyReturn = 0x0d;
inline constexpr std::uint32_t kVirtualKeyShift = 0x10;
inline constexpr std::uint32_t kVirtualKeyControl = 0x11;
inline constexpr std::uint32_t kVirtualKeyMenu = 0x12;
inline constexpr std::uint32_t kVirtualKeyPause = 0x13;
inline constexpr std::uint32_t kVirtualKeyCapital = 0x14;
inline constexpr std::uint32_t kVirtualKeyEscape = 0x1b;
inline constexpr std::uint32_t kVirtualKeySpace = 0x20;
inline constexpr std::uint32_t kVirtualKeyPageUp = 0x21;
inline constexpr std::uint32_t kVirtualKeyPageDown = 0x22;
inline constexpr std::uint32_t kVirtualKeyEnd = 0x23;
inline constexpr std::uint32_t kVirtualKeyHome = 0x24;
inline constexpr std::uint32_t kVirtualKeyLeft = 0x25;
inline constexpr std::uint32_t kVirtualKeyUp = 0x26;
inline constexpr std::uint32_t kVirtualKeyRight = 0x27;
inline constexpr std::uint32_t kVirtualKeyDown = 0x28;
inline constexpr std::uint32_t kVirtualKeyPrint = 0x2a;
inline constexpr std::uint32_t kVirtualKeySnapshot = 0x2c;
inline constexpr std::uint32_t kVirtualKeyInsert = 0x2d;
inline constexpr std::uint32_t kVirtualKeyDelete = 0x2e;
inline constexpr std::uint32_t kVirtualKeyHelp = 0x2f;
inline constexpr std::uint32_t kVirtualKey0 = 0x30;
inline constexpr std::uint32_t kVirtualKey9 = 0x39;
inline constexpr std::uint32_t kVirtualKeyA = 0x41;
inline constexpr std::uint32_t kVirtualKeyZ = 0x5a;
inline constexpr std::uint32_t kVirtualKeyLeftWindows = 0x5b;
inline constexpr std::uint32_t kVirtualKeyRightWindows = 0x5c;
inline constexpr std::uint32_t kVirtualKeyApps = 0x5d;
inline constexpr std::uint32_t kVirtualKeyNumpad0 = 0x60;
inline constexpr std::uint32_t kVirtualKeyNumpad9 = 0x69;
inline constexpr std::uint32_t kVirtualKeyMultiply = 0x6a;
inline constexpr std::uint32_t kVirtualKeyAdd = 0x6b;
inline constexpr std::uint32_t kVirtualKeySeparator = 0x6c;
inline constexpr std::uint32_t kVirtualKeySubtract = 0x6d;
inline constexpr std::uint32_t kVirtualKeyDecimal = 0x6e;
inline constexpr std::uint32_t kVirtualKeyDivide = 0x6f;
inline constexpr std::uint32_t kVirtualKeyF1 = 0x70;
inline constexpr std::uint32_t kVirtualKeyF24 = 0x87;
inline constexpr std::uint32_t kVirtualKeyNumLock = 0x90;
inline constexpr std::uint32_t kVirtualKeyScroll = 0x91;
inline constexpr std::uint32_t kVirtualKeyLeftShift = 0xa0;
inline constexpr std::uint32_t kVirtualKeyRightShift = 0xa1;
inline constexpr std::uint32_t kVirtualKeyLeftControl = 0xa2;
inline constexpr std::uint32_t kVirtualKeyRightControl = 0xa3;
inline constexpr std::uint32_t kVirtualKeyLeftMenu = 0xa4;
inline constexpr std::uint32_t kVirtualKeyRightMenu = 0xa5;
inline constexpr std::uint32_t kVirtualKeyOem1 = 0xba;
inline constexpr std::uint32_t kVirtualKeyOemPlus = 0xbb;
inline constexpr std::uint32_t kVirtualKeyOemComma = 0xbc;
inline constexpr std::uint32_t kVirtualKeyOemMinus = 0xbd;
inline constexpr std::uint32_t kVirtualKeyOemPeriod = 0xbe;
inline constexpr std::uint32_t kVirtualKeyOem2 = 0xbf;
inline constexpr std::uint32_t kVirtualKeyOem3 = 0xc0;
inline constexpr std::uint32_t kVirtualKeyOem4 = 0xdb;
inline constexpr std::uint32_t kVirtualKeyOem5 = 0xdc;
inline constexpr std::uint32_t kVirtualKeyOem6 = 0xdd;
inline constexpr std::uint32_t kVirtualKeyOem7 = 0xde;
inline constexpr std::uint32_t kVirtualKeyOem102 = 0xe2;

constexpr bool HasFlag(std::uint32_t value, std::uint32_t flag) noexcept {
  return (value & flag) != 0;
}

constexpr std::uint32_t Flag(core::KeyModifiers modifier) noexcept {
  return static_cast<std::uint32_t>(modifier);
}

constexpr std::uint32_t Flag(core::KeyEventFlags flag) noexcept {
  return static_cast<std::uint32_t>(flag);
}

std::optional<std::int32_t> TranslateVirtualKey(
    const core::KeyEvent& event) noexcept {
  const std::uint32_t virtual_key = event.virtual_key;
  const bool extended =
      HasFlag(event.event_flags, Flag(core::KeyEventFlags::kExtended));

  if (virtual_key >= kVirtualKeyA && virtual_key <= kVirtualKeyZ) {
    return static_cast<std::int32_t>('a' + virtual_key - kVirtualKeyA);
  }
  if (virtual_key >= kVirtualKey0 && virtual_key <= kVirtualKey9) {
    return static_cast<std::int32_t>('0' + virtual_key - kVirtualKey0);
  }
  if (virtual_key >= kVirtualKeyNumpad0 &&
      virtual_key <= kVirtualKeyNumpad9) {
    return kKeypad0 +
           static_cast<std::int32_t>(virtual_key - kVirtualKeyNumpad0);
  }
  if (virtual_key >= kVirtualKeyF1 && virtual_key <= kVirtualKeyF24) {
    return kF1 + static_cast<std::int32_t>(virtual_key - kVirtualKeyF1);
  }

  switch (virtual_key) {
    case kVirtualKeyBack:
      return kBackspace;
    case kVirtualKeyTab:
      return kTab;
    case kVirtualKeyClear:
      return kClear;
    case kVirtualKeyReturn:
      return extended ? kKeypadEnter : kReturn;
    case kVirtualKeyShift:
      return (event.scan_code & 0xffU) == 0x36U ? kShiftRight : kShiftLeft;
    case kVirtualKeyControl:
      return extended ? kControlRight : kControlLeft;
    case kVirtualKeyMenu:
      return extended ? kAltRight : kAltLeft;
    case kVirtualKeyPause:
      return kPause;
    case kVirtualKeyCapital:
      return kCapsLock;
    case kVirtualKeyEscape:
      return kEscape;
    case kVirtualKeySpace:
      return static_cast<std::int32_t>(' ');
    case kVirtualKeyPageUp:
      return kPageUp;
    case kVirtualKeyPageDown:
      return kPageDown;
    case kVirtualKeyEnd:
      return kEnd;
    case kVirtualKeyHome:
      return kHome;
    case kVirtualKeyLeft:
      return kLeft;
    case kVirtualKeyUp:
      return kUp;
    case kVirtualKeyRight:
      return kRight;
    case kVirtualKeyDown:
      return kDown;
    case kVirtualKeyPrint:
    case kVirtualKeySnapshot:
      return kPrint;
    case kVirtualKeyInsert:
      return kInsert;
    case kVirtualKeyDelete:
      return kDelete;
    case kVirtualKeyHelp:
      return kHelp;
    case kVirtualKeyLeftWindows:
      return kSuperLeft;
    case kVirtualKeyRightWindows:
      return kSuperRight;
    case kVirtualKeyApps:
      return kMenu;
    case kVirtualKeyMultiply:
      return kKeypadMultiply;
    case kVirtualKeyAdd:
      return kKeypadAdd;
    case kVirtualKeySeparator:
      return kKeypadSeparator;
    case kVirtualKeySubtract:
      return kKeypadSubtract;
    case kVirtualKeyDecimal:
      return kKeypadDecimal;
    case kVirtualKeyDivide:
      return kKeypadDivide;
    case kVirtualKeyNumLock:
      return kNumLock;
    case kVirtualKeyScroll:
      return kScrollLock;
    case kVirtualKeyLeftShift:
      return kShiftLeft;
    case kVirtualKeyRightShift:
      return kShiftRight;
    case kVirtualKeyLeftControl:
      return kControlLeft;
    case kVirtualKeyRightControl:
      return kControlRight;
    case kVirtualKeyLeftMenu:
      return kAltLeft;
    case kVirtualKeyRightMenu:
      return kAltRight;
    case kVirtualKeyOem1:
      return static_cast<std::int32_t>(';');
    case kVirtualKeyOemPlus:
      return static_cast<std::int32_t>('=');
    case kVirtualKeyOemComma:
      return static_cast<std::int32_t>(',');
    case kVirtualKeyOemMinus:
      return static_cast<std::int32_t>('-');
    case kVirtualKeyOemPeriod:
      return static_cast<std::int32_t>('.');
    case kVirtualKeyOem2:
      return static_cast<std::int32_t>('/');
    case kVirtualKeyOem3:
      return static_cast<std::int32_t>('`');
    case kVirtualKeyOem4:
      return static_cast<std::int32_t>('[');
    case kVirtualKeyOem5:
    case kVirtualKeyOem102:
      return static_cast<std::int32_t>('\\');
    case kVirtualKeyOem6:
      return static_cast<std::int32_t>(']');
    case kVirtualKeyOem7:
      return static_cast<std::int32_t>('\'');
    default:
      return std::nullopt;
  }
}

std::int32_t TranslateModifiers(const core::KeyEvent& event) noexcept {
  const std::uint32_t modifiers = event.modifiers;
  std::int32_t result = 0;
  if (HasFlag(modifiers, Flag(core::KeyModifiers::kShift))) {
    result |= kShiftMask;
  }
  if (HasFlag(modifiers, Flag(core::KeyModifiers::kCapsLock))) {
    result |= kLockMask;
  }
  if (HasFlag(modifiers, Flag(core::KeyModifiers::kControl))) {
    result |= kControlMask;
  }
  if (HasFlag(modifiers, Flag(core::KeyModifiers::kAlt))) {
    result |= kAltMask;
  }
  if (HasFlag(modifiers, Flag(core::KeyModifiers::kNumLock))) {
    result |= kMod2Mask;
  }
  if (HasFlag(modifiers, Flag(core::KeyModifiers::kWindows))) {
    result |= kSuperMask;
  }
  if (!HasFlag(event.event_flags, Flag(core::KeyEventFlags::kKeyDown))) {
    result |= kReleaseMask;
  }
  return result;
}

bool IsPrintableBaseKey(std::int32_t keycode) noexcept {
  return keycode >= 0x20 && keycode <= 0x7e;
}

bool IsCompositionEditingKey(std::int32_t keycode) noexcept {
  switch (keycode) {
    case kBackspace:
    case kTab:
    case kReturn:
    case kEscape:
    case kHome:
    case kLeft:
    case kUp:
    case kRight:
    case kDown:
    case kPageUp:
    case kPageDown:
    case kEnd:
    case kDelete:
      return true;
    default:
      return false;
  }
}

}  // namespace

std::optional<RimeKeyEvent> TranslateWindowsKey(
    const core::KeyEvent& event) noexcept {
  // The protocol does not carry the Unicode scalar produced by an AltGr
  // layout. Treating RightAlt+Ctrl as an ASCII OEM key would corrupt input, so
  // fail open until the protocol has a committed-text key field.
  if (HasFlag(event.modifiers, Flag(core::KeyModifiers::kAltGr))) {
    return std::nullopt;
  }
  const std::optional<std::int32_t> keycode = TranslateVirtualKey(event);
  if (!keycode.has_value() || *keycode <= 0 ||
      *keycode > std::numeric_limits<std::int32_t>::max()) {
    return std::nullopt;
  }
  return RimeKeyEvent{*keycode, TranslateModifiers(event)};
}

bool IsLikelyHandledForTest(const core::KeyEvent& event,
                            bool session_is_composing) noexcept {
  if (!HasFlag(event.event_flags, Flag(core::KeyEventFlags::kKeyDown)) ||
      HasFlag(event.event_flags, Flag(core::KeyEventFlags::kPreservedKey))) {
    return false;
  }
  const std::optional<RimeKeyEvent> translated = TranslateWindowsKey(event);
  if (!translated.has_value()) {
    return false;
  }

  // Do not pre-claim host or application shortcuts. Rime may bind some of
  // these combinations, but a false positive at OnTestKeyDown loses the key
  // before process_key has had a chance to reject it.
  const std::uint32_t command_modifiers =
      Flag(core::KeyModifiers::kControl) | Flag(core::KeyModifiers::kAlt) |
      Flag(core::KeyModifiers::kWindows) | Flag(core::KeyModifiers::kAltGr);
  if ((event.modifiers & command_modifiers) != 0) {
    return false;
  }

  if (translated->keycode >= 'a' && translated->keycode <= 'z') {
    return true;
  }
  return session_is_composing &&
         (IsPrintableBaseKey(translated->keycode) ||
          IsCompositionEditingKey(translated->keycode));
}

}  // namespace rimes::windows::broker
