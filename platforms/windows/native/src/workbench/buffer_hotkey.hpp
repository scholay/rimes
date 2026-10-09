#pragma once

#include <Windows.h>
#include "buffer_hotkey_config.hpp"

namespace rimes::windows::workbench {

enum class HotkeyUpdate { kSaved, kInvalid, kUnavailable, kSaveFailed };

// Owned and used only by the Broker window thread. Keeping the current chord
// registered until the candidate and settings save succeed avoids a restore
// race. No fallback chord is silently substituted after a conflict.
class BufferHotkeyRegistration {
 public:
  explicit BufferHotkeyRegistration(HWND window) : window_(window) {}
  ~BufferHotkeyRegistration() { Reset(); }
  BufferHotkeyRegistration(const BufferHotkeyRegistration&) = delete;
  BufferHotkeyRegistration& operator=(const BufferHotkeyRegistration&) = delete;

  bool RegisterInitial(unsigned modifiers, unsigned key) {
    return Update(modifiers, key, [] { return true; }) == HotkeyUpdate::kSaved;
  }
  bool Registered() const noexcept { return id_ != 0; }

  template <typename Save>
  HotkeyUpdate Update(unsigned modifiers, unsigned key, Save save) {
    // A rejected/malformed setting must never reserve an ordinary typing key
    // or a system shortcut. MOD_NOREPEAT is internal, not a user modifier.
    if (!ValidBufferHotkeyModifiers(modifiers) || key < 'A' || key > 'Z')
      return HotkeyUpdate::kInvalid;
    if (Registered() && modifiers == modifiers_ && key == key_)
      return save() ? HotkeyUpdate::kSaved : HotkeyUpdate::kSaveFailed;
    const int candidate = id_ == 1 ? 2 : 1;
    // A failed cleanup stays tracked for Reset; never accumulate another
    // registration under an id whose release was not confirmed.
    if (owned_[candidate - 1]) return HotkeyUpdate::kUnavailable;
    if (!RegisterHotKey(window_, candidate, modifiers | MOD_NOREPEAT, key))
      return HotkeyUpdate::kUnavailable;
    owned_[candidate - 1] = true;
    bool saved = false;
    try {
      saved = save();
    } catch (...) {
      Release(candidate);
      throw;
    }
    if (!saved) {
      Release(candidate);
      return HotkeyUpdate::kSaveFailed;
    }
    if (Registered()) Release(id_);
    id_ = candidate;
    modifiers_ = modifiers;
    key_ = key;
    return HotkeyUpdate::kSaved;
  }

  bool Matches(WPARAM id, LPARAM chord) const noexcept {
    return Registered() && id == static_cast<WPARAM>(id_) &&
           (static_cast<unsigned>(LOWORD(chord)) &
            ~static_cast<unsigned>(MOD_NOREPEAT)) == modifiers_ &&
           HIWORD(chord) == key_;
  }
  void Reset() noexcept {
    Release(1);
    Release(2);
    id_ = 0;
    modifiers_ = key_ = 0;
  }

 private:
  void Release(int id) noexcept {
    if (owned_[id - 1] && UnregisterHotKey(window_, id))
      owned_[id - 1] = false;
  }
  HWND window_;
  int id_ = 0;
  unsigned modifiers_ = 0, key_ = 0;
  bool owned_[2] = {false, false};
};

}  // namespace rimes::windows::workbench
