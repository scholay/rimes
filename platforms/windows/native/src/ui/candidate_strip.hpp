#pragma once

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

#include "theme.hpp"

namespace rimes::windows::ui {

// Candidate strip metrics in device-independent pixels (96 DPI).
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
  DipRect strip{};
  std::vector<DipRect> pills;   // parallel to input items
  std::vector<std::size_t> order;  // paint/hit order by visual row
  int row_count = 0;
};

// Reserve each item inside the actual viewport, including a single very long
// candidate. Horizontal pages stay on one row, using the monitor width before
// clipping long entries. Painting and hit testing use these exact rectangles;
// semibold width is supplied by the native measurer. Composition stays inline
// in the host editor, so this layout contains only candidates.
[[nodiscard]] inline CandidateStripLayout LayoutCandidateStripMeasured(
    const std::vector<CandidateStripItem>& items,
    const CandidateStripMetrics& metrics, float available_width_dip, bool vertical = false, float available_height_dip = 0.f) {
  CandidateStripLayout layout;
  if (items.empty()) return layout;
  const float viewport = available_width_dip > 0.f ? available_width_dip
      : static_cast<float>(metrics.max_strip_width_dip);
  const float max_width = (std::max)(1.f, vertical ? (std::min)(viewport,
      static_cast<float>(metrics.max_strip_width_dip)) : viewport);
  const float pad = (std::min)(static_cast<float>(metrics.bar_horizontal_padding_dip),
                               max_width * 0.2f);
  const float inner = max_width - 2.f * pad;
  // Leave space for every hit target even in an exceptionally narrow viewport.
  const float gap = (std::min)(
      static_cast<float>(metrics.inter_pill_spacing_dip * 2 +
                         metrics.separator_width_dip),
      inner / static_cast<float>(2 * items.size() - 1));
  const float strip_h = static_cast<float>(metrics.strip_height_dip);
  const float pill_h = static_cast<float>(metrics.pill_height_dip);
  const int vertical_rows = vertical && available_height_dip > 0.f
      ? (std::max)(1, static_cast<int>(available_height_dip / strip_h))
      : static_cast<int>((std::max)(std::size_t{1}, items.size()));
  const int vertical_columns = vertical
      ? (std::max)(1, (static_cast<int>(items.size()) + vertical_rows - 1) / vertical_rows) : 1;
  const float column_width = inner / static_cast<float>(vertical_columns);
  std::vector<float> widths;
  widths.reserve(items.size());
  for (const auto& item : items) {
    widths.push_back(static_cast<float>((std::max)(0, item.content_width_dip)) +
                     2.f * static_cast<float>(metrics.pill_padding_dip));
  }
  float width_limit = column_width;
  if (!vertical) {
    // Share the remaining width among long entries, preserving short entries
    // at their natural width instead of letting one long phrase crowd them out.
    auto sorted = widths;
    std::sort(sorted.begin(), sorted.end());
    float remaining = inner - gap * static_cast<float>(items.size() - 1);
    for (std::size_t i = 0; i < sorted.size(); ++i) {
      width_limit = remaining / static_cast<float>(sorted.size() - i);
      if (sorted[i] >= width_limit) break;
      remaining -= sorted[i];
    }
  }
  float row_end = 0.f, widest = 0.f;
  int row = 0;
  layout.pills.reserve(items.size());
  layout.order.reserve(items.size());
  for (std::size_t i = 0; i < items.size(); ++i) {
    const float width = (std::min)(width_limit, widths[i]);
    float x = row_end == 0.f ? 0.f : row_end + gap;
    if (vertical) {
      row = static_cast<int>(i) % vertical_rows;
      x = static_cast<float>(static_cast<int>(i) / vertical_rows) * column_width;
    }
    const float y = strip_h * static_cast<float>(row) +
                    (strip_h - pill_h) * 0.5f;
    const float right = (std::min)(max_width - pad, pad + x + width);
    layout.pills.push_back({pad + x, y, right, y + pill_h});
    layout.order.push_back(i);
    row_end = right - pad;
    widest = (std::max)(widest, row_end);
  }
  layout.row_count = vertical ? (std::min)(vertical_rows, static_cast<int>(items.size())) : 1;
  layout.width_dip = (std::min)(max_width, widest + 2.f * pad);
  layout.height_dip = strip_h * static_cast<float>(layout.row_count);
  layout.strip = {0.f, 0.f, layout.width_dip, layout.height_dip};
  return layout;
}

// Matrix rows preserve natural text widths. Only a consecutive visible range
// is drawn; moving the selection reveals overflow without squeezing every word.
[[nodiscard]] inline CandidateStripLayout LayoutCandidateMatrixMeasured(
    const std::vector<CandidateStripItem>& items,
    const std::vector<std::size_t>& row_sizes,
    const CandidateStripMetrics& metrics, float available_width_dip,
    std::size_t highlighted = 0) {
  CandidateStripLayout matrix;
  matrix.pills.resize(items.size()); // hidden entries have empty hit rectangles
  std::size_t offset = 0;
  const float viewport = (std::max)(1.f, available_width_dip);
  const float pad = (std::min)(static_cast<float>(metrics.bar_horizontal_padding_dip), viewport * .2f);
  const float available = viewport - 2 * pad;
  const float gap = static_cast<float>(metrics.inter_pill_spacing_dip * 2 + metrics.separator_width_dip);
  for (const auto count : row_sizes) {
    if (offset > items.size() || count == 0 || count > items.size() - offset) return {};
    auto endFrom = [&](std::size_t start) {
      float used = 0;
      auto end = start;
      while (end < count && end - start < 9) {
        const float width = (std::min)(available, items[offset + end].content_width_dip + 2.f * metrics.pill_padding_dip);
        const float next = width + (end > start ? gap : 0);
        if (end > start && used + next > available) break;
        used += next; ++end;
      }
      return end;
    };
    std::size_t start = 0;
    if (highlighted >= offset && highlighted < offset + count) {
      const auto selected = highlighted - offset;
      while (selected >= endFrom(start) && start < selected) ++start;
    }
    const auto end = endFrom(start);
    const std::vector<CandidateStripItem> row(items.begin() + offset + start, items.begin() + offset + end);
    const auto layout = LayoutCandidateStripMeasured(row, metrics, viewport);
    const float top = matrix.height_dip + (offset == 0 ? 0.f : 3.f);
    for (std::size_t column = 0; column < layout.pills.size(); ++column) {
      auto pill = layout.pills[column]; pill.top += top; pill.bottom += top;
      const auto index = offset + start + column;
      matrix.pills[index] = pill; matrix.order.push_back(index);
    }
    matrix.width_dip = (std::max)(matrix.width_dip, layout.width_dip);
    matrix.height_dip = top + layout.height_dip;
    ++matrix.row_count; offset += count;
  }
  if (offset != items.size()) return {};
  matrix.strip = {0, 0, matrix.width_dip, matrix.height_dip};
  return matrix;
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
