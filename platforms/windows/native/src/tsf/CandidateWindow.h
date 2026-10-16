#pragma once

#include <Windows.h>

#include <cstdint>
#include <functional>
#include <optional>
#include <string>
#include <vector>

#include "../ui/candidate_strip.hpp"
#include "../ui/theme.hpp"

namespace rimes::windows::tsf {

struct CandidateItem {
  std::wstring label;
  std::wstring text;
  std::wstring comment;
  bool operator==(const CandidateItem&) const = default;
};

struct CandidateSnapshot {
  bool visible = false;
  std::uint16_t highlighted = 0xffff;
  std::uint16_t page_start = 0;
  std::uint16_t page_size = 0;
  RECT window_rect{};
  RECT caret_rect{};
  std::wstring composition;
  std::vector<CandidateItem> items;
  std::vector<std::size_t> matrix_rows;
};

class CandidateWindow {
 public:
  CandidateWindow() noexcept = default;
  ~CandidateWindow();

  CandidateWindow(const CandidateWindow&) = delete;
  CandidateWindow& operator=(const CandidateWindow&) = delete;

  void Update(const CandidateSnapshot& snapshot) noexcept;
  void Hide() noexcept;
  void SetOwner(HWND owner) noexcept {
    owner_ = owner;
    if (window_) SetWindowLongPtrW(window_, GWLP_HWNDPARENT,
                                  reinterpret_cast<LONG_PTR>(owner));
  }
  bool IsVisible() const noexcept { return window_ && IsWindowVisible(window_); }
  void SetSelect(std::function<void(std::size_t)> select) {
    select_ = std::move(select);
  }
  void SetFont(unsigned size) {
    size = (std::clamp)(size, 10U, 40U);
    if (font_size_ == size) return;
    font_size_ = size;
    pressed_index_ = -1;
    if (window_ && GetCapture() == window_) ReleaseCapture();
    if (snapshot_.visible) Update(snapshot_);
  }
  void SetVertical(bool vertical) {
    if (vertical_ == vertical) return;
    vertical_ = vertical;
    pressed_index_ = -1;
    if (window_ && GetCapture() == window_) ReleaseCapture();
    if (snapshot_.visible) Update(snapshot_);
  }
  void SetTheme(ui::ThemeId theme) {
    if (theme_ == theme) return;
    theme_ = theme;
    if (window_) InvalidateRect(window_, nullptr, FALSE);
  }
  [[nodiscard]] CandidateSnapshot snapshot() const noexcept;

  std::optional<std::size_t> MatrixDigitIndex(std::size_t digit) const noexcept;

  static bool GetLastSnapshot(CandidateSnapshot* snapshot) noexcept;

 private:
  bool EnsureWindow() noexcept;
  void LayoutAndShow(const CandidateSnapshot& snapshot);
  void Paint(HDC device) const;
  int HitIndex(int x_px, int y_px) const noexcept;

  static LRESULT CALLBACK WindowProcedure(HWND window, UINT message,
                                          WPARAM wparam, LPARAM lparam);
  static void PublishSnapshot(const CandidateSnapshot& snapshot) noexcept;

  std::function<void(std::size_t)> select_;
  unsigned font_size_ = 16;
  bool vertical_ = false;
  ui::ThemeId theme_ = ui::ThemeId::kNight;
  int hover_index_ = -1;
  int pressed_index_ = -1;
  HWND window_ = nullptr;
  HWND owner_ = nullptr;
  CandidateSnapshot snapshot_{};
  // Last computed DIP hit rectangles in window client space (DIP).
  mutable std::vector<ui::DipRect> hit_pills_;
  std::vector<std::wstring> matrix_labels_;
  mutable float layout_width_dip_ = 0;
  mutable float layout_height_dip_ = 0;
};

}  // namespace rimes::windows::tsf
