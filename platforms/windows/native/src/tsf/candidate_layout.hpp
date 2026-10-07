#pragma once

#include <cstddef>
#include <string_view>

namespace rimes::windows::tsf {

struct ScreenRect {
  long left = 0;
  long top = 0;
  long right = 0;
  long bottom = 0;

  [[nodiscard]] long width() const noexcept { return right - left; }
  [[nodiscard]] long height() const noexcept { return bottom - top; }
  [[nodiscard]] bool empty() const noexcept {
    return right <= left || bottom <= top;
  }
};

struct ScreenPoint {
  long x = 0;
  long y = 0;
};

// librime may omit numeric labels; painting and mouse selection must agree.
inline wchar_t CandidateSelectionKey(std::wstring_view label,
                                     std::size_t index) noexcept {
  if (label.empty()) return index < 9 ? static_cast<wchar_t>(L'1' + index) : 0;
  return label.size() == 1 && label[0] >= L'1' && label[0] <= L'9'
             ? label[0]
             : 0;
}

// A caret rectangle that identifies a visible caret: TSF may report a
// collapsed range of zero width, so only the vertical extent is required.
inline bool HasVisibleCaret(const ScreenRect& caret) noexcept {
  return caret.bottom > caret.top && caret.right >= caret.left;
}

// Picks the caret rectangle to place the candidate window at.
//
// The caret query can legitimately fail while a host is mid-composition: it
// refuses the read edit session, or no thread owns the caret for GetCaretPos.
// Treating that unknown state as a real caret would send PlaceCandidateWindow
// to the work-area origin, which shows up as a visible jump to the top-left
// corner of the screen on the frame before the real caret is observed.
// Reusing the last known caret keeps the popup near the input field, and a
// first query that has never succeeded suppresses the popup instead of
// displaying it at a position that is known to be wrong.
inline bool ResolveCandidateCaret(const ScreenRect& queried,
                                  const ScreenRect& previous,
                                  ScreenRect* resolved) noexcept {
  if (resolved == nullptr) {
    return false;
  }
  if (HasVisibleCaret(queried)) {
    *resolved = queried;
    return true;
  }
  if (HasVisibleCaret(previous)) {
    *resolved = previous;
    return true;
  }
  return false;
}

// Places a candidate window near the caret rectangle. Prefers immediately
// below the caret, flips above when the work area cannot hold it, and clamps
// the origin so the window stays on the same monitor.
inline ScreenPoint PlaceCandidateWindow(const ScreenRect& caret,
                                        long window_width,
                                        long window_height,
                                        const ScreenRect& work_area,
                                        long caret_gap_px = 6) noexcept {
  ScreenPoint origin;
  const bool has_caret = HasVisibleCaret(caret);
  if (window_width <= 0) {
    window_width = 1;
  }
  if (window_height <= 0) {
    window_height = 1;
  }

  ScreenRect area = work_area;
  if (area.empty()) {
    area = has_caret ? caret : ScreenRect{0, 0, 1920, 1080};
    if (area.width() < window_width) {
      area.right = area.left + window_width;
    }
    if (area.height() < window_height) {
      area.bottom = area.top + window_height;
    }
  }

  origin.x = has_caret ? caret.left : area.left;
  // macOS CandidatePanelGeometry uses a 6pt caret gap.
  const long below = has_caret ? caret.bottom + caret_gap_px : area.top;
  const long above = has_caret ? caret.top - window_height - caret_gap_px : area.top;
  if (below + window_height <= area.bottom || above < area.top) {
    origin.y = below;
  } else {
    origin.y = above;
  }

  if (origin.x + window_width > area.right) {
    origin.x = area.right - window_width;
  }
  if (origin.x < area.left) {
    origin.x = area.left;
  }
  if (origin.y + window_height > area.bottom) {
    origin.y = area.bottom - window_height;
  }
  if (origin.y < area.top) {
    origin.y = area.top;
  }
  return origin;
}

inline int ScaleForDpi(int value, unsigned int dpi) noexcept {
  if (dpi == 0) {
    dpi = 96;
  }
  return static_cast<int>((static_cast<long long>(value) * dpi) / 96);
}

}  // namespace rimes::windows::tsf
