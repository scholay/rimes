#pragma once

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <string>
#include <string_view>
#include <vector>

#include "theme.hpp"

namespace rimes::windows::ui {

// Compact horizontal candidate strip metrics (macOS CandidateLayout parity).
// 96 DPI = one macOS point. Separators stay one physical pixel at paint time.
struct CandidateStripMetrics {
  int max_strip_width_dip = 460;
  int strip_height_dip = 34;
  int pill_height_dip = 24;
  int bar_horizontal_padding_dip = 4;
  int pill_padding_dip = 6;
  int inter_pill_spacing_dip = 3;
  int separator_width_dip = 8;
  int label_font_dip = 10;
  int candidate_font_dip = 16;
  int annotation_font_dip = 9;
  int strip_radius_dip = 6;
  int pill_radius_dip = 6;
  int preedit_radius_dip = 5;
  int preedit_height_dip = 20;
  int preedit_gap_dip = 5;
  int preedit_inset_dip = 6;
  int preedit_font_dip = 12;
  int caret_gap_dip = 6;
};

[[nodiscard]] inline CandidateStripMetrics MakeCandidateMetrics(
    unsigned font_size) noexcept {
  CandidateStripMetrics metrics;
  metrics.candidate_font_dip =
      static_cast<int>((std::clamp)(font_size, 10U, 40U));
  metrics.pill_height_dip = (std::max)(24, metrics.candidate_font_dip + 8);
  metrics.strip_height_dip = (std::max)(34, metrics.pill_height_dip + 10);
  return metrics;
}

struct CandidateStripItem {
  std::wstring label;
  std::wstring text;
  std::wstring comment;
  int content_width_dip = 0;  // semibold-reserved text width excluding padding
};

struct DipRect {
  float left = 0;
  float top = 0;
  float right = 0;
  float bottom = 0;

  [[nodiscard]] float width() const noexcept { return right - left; }
  [[nodiscard]] float height() const noexcept { return bottom - top; }
  [[nodiscard]] bool contains(float x, float y) const noexcept {
    return x >= left && x < right && y >= top && y < bottom;
  }
};

struct CandidateStripLayout {
  float width_dip = 0;
  float height_dip = 0;
  bool show_preedit = false;
  DipRect preedit{};
  DipRect strip{};
  std::vector<DipRect> pills;   // parallel to input items
  std::vector<std::size_t> order;  // paint/hit order by visual row
  int row_count = 0;
};

// Reserve each item inside the actual viewport, including a single very long
// candidate. Painting and hit testing use these exact rectangles. Wrapped rows
// preserve page order, and semibold width is supplied by the native measurer.
[[nodiscard]] inline CandidateStripLayout LayoutCandidateStripMeasured(
    const std::vector<CandidateStripItem>& items,
    float measured_preedit_width_dip, bool show_preedit,
    const CandidateStripMetrics& metrics, float available_width_dip, bool vertical = false, float available_height_dip = 0.f) {
  CandidateStripLayout layout;
  const float max_width = (std::max)(1.f, (std::min)(
      static_cast<float>(metrics.max_strip_width_dip),
      available_width_dip > 0.f ? available_width_dip
                               : static_cast<float>(metrics.max_strip_width_dip)));
  const float pad = (std::min)(static_cast<float>(metrics.bar_horizontal_padding_dip),
                               max_width * 0.2f);
  const float inner = max_width - 2.f * pad;
  const float gap = static_cast<float>(metrics.inter_pill_spacing_dip * 2 +
                                        metrics.separator_width_dip);
  const float strip_h = static_cast<float>(metrics.strip_height_dip);
  const float pill_h = static_cast<float>(metrics.pill_height_dip);
  const float preedit_h = show_preedit
      ? static_cast<float>(metrics.preedit_height_dip) : 0.f;
  const float strip_top = show_preedit && !items.empty()
      ? preedit_h + static_cast<float>(metrics.preedit_gap_dip) : 0.f;
  const int vertical_rows = vertical && available_height_dip > 0.f
      ? (std::max)(1, static_cast<int>((available_height_dip - strip_top) / strip_h))
      : static_cast<int>((std::max)(std::size_t{1}, items.size()));
  const int vertical_columns = vertical
      ? (std::max)(1, (static_cast<int>(items.size()) + vertical_rows - 1) / vertical_rows) : 1;
  const float column_width = inner / static_cast<float>(vertical_columns);
  float row_end = 0.f, widest = 0.f;
  int row = 0;
  layout.pills.reserve(items.size());
  layout.order.reserve(items.size());
  for (std::size_t i = 0; i < items.size(); ++i) {
    const float content = static_cast<float>((std::max)(0, items[i].content_width_dip));
    const float width = (std::min)(vertical ? column_width : inner, (std::max)(
        2.f * static_cast<float>(metrics.pill_padding_dip),
        content + 2.f * static_cast<float>(metrics.pill_padding_dip)));
    float x = row_end == 0.f ? 0.f : row_end + gap;
    if (vertical) {
      row = static_cast<int>(i) % vertical_rows;
      x = static_cast<float>(static_cast<int>(i) / vertical_rows) * column_width;
    } else if (row_end > 0.f && x + width > inner + 0.01f) {
      ++row;
      x = 0.f;
    }
    const float y = strip_top + strip_h * static_cast<float>(row) +
                    (strip_h - pill_h) * 0.5f;
    layout.pills.push_back({pad + x, y, pad + x + width, y + pill_h});
    layout.order.push_back(i);
    row_end = x + width;
    widest = (std::max)(widest, row_end);
  }
  layout.row_count = items.empty() ? 0 : vertical ? (std::min)(vertical_rows, static_cast<int>(items.size())) : row + 1;
  layout.show_preedit = show_preedit;
  const float preedit_w = show_preedit ? (std::min)(max_width, (std::max)(24.f,
      (std::max)(0.f, measured_preedit_width_dip) +
          2.f * static_cast<float>(metrics.preedit_inset_dip))) : 0.f;
  const float strip_w = items.empty() ? 0.f : widest + 2.f * pad;
  layout.width_dip = (std::min)(max_width, (std::max)(preedit_w, strip_w));
  layout.strip = {0.f, strip_top, layout.width_dip,
                  strip_top + strip_h * static_cast<float>(layout.row_count)};
  layout.preedit = show_preedit ? DipRect{0.f, 0.f, preedit_w, preedit_h} : DipRect{};
  layout.height_dip = items.empty() ? preedit_h : layout.strip.bottom;
  return layout;
}

[[nodiscard]] inline CandidateStripLayout LayoutCandidateStrip(
    const std::vector<CandidateStripItem>& items, std::wstring_view preedit,
    const CandidateStripMetrics& metrics, float available_width_dip) {
  return LayoutCandidateStripMeasured(items,
      static_cast<float>(preedit.size()) *
          static_cast<float>(metrics.preedit_font_dip) * 0.6f,
      !preedit.empty(), metrics, available_width_dip);
}

[[nodiscard]] inline int HitTestCandidateStrip(
    const CandidateStripLayout& layout, float x_dip, float y_dip) noexcept {
  if (x_dip < 0.f || y_dip < 0.f || x_dip >= layout.width_dip ||
      y_dip >= layout.height_dip) return -1;
  for (std::size_t i = 0; i < layout.pills.size(); ++i) {
    if (layout.pills[i].contains(x_dip, y_dip)) return static_cast<int>(i);
  }
  return -1;
}

[[nodiscard]] inline int ScaleDip(int value, unsigned dpi) noexcept {
  if (dpi == 0) dpi = 96;
  return static_cast<int>((static_cast<long long>(value) * dpi) / 96);
}

[[nodiscard]] inline float ScaleDipF(float value, unsigned dpi) noexcept {
  if (dpi == 0) dpi = 96;
  return value * (static_cast<float>(dpi) / 96.0f);
}

}  // namespace rimes::windows::ui
