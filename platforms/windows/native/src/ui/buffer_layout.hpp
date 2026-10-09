#pragma once

#include <algorithm>
#include <cmath>
#include <string>
#include <vector>

#include "candidate_strip.hpp"
#include "theme.hpp"

namespace rimes::windows::ui {

struct BufferMetrics {
  int default_width_dip = 680;
  int min_width_dip = 520;
  int max_width_dip = 1100;
  int ordinary_height_dip = 73;
  int two_rail_height_dip = 105;
  int toolbar_only_height_dip = 35;
  int toolbar_height_dip = 33;
  int chrome_inset_dip = 2;
  int chrome_radius_dip = 11;
  int rail_radius_dip = 6;
  int source_rail_height_dip = 32;
  int rail_spacing_dip = 4;
  int icon_size_dip = 22;
  int icon_gap_dip = 4;
  int block_spacing_dip = 5;
  int rail_inset_dip = 5;
  int action_clearance_dip = 8;
  int body_font_dip = 12;
  int preedit_font_dip = 13;
  int rail_label_font_dip = 10;
};

enum class BufferMode { kInput = 0, kGenerate = 1, kTranslate = 2 };

struct BufferBlockView {
  std::wstring text;
  bool streaming = false;
};

struct BufferPaintState {
  ThemeId theme = ThemeId::kNight;
  BufferMode mode = BufferMode::kInput;
  bool bound = false;
  bool capturing = false;
  bool busy = false;
  bool translate = false;
  bool visible = true;
  // Reserved for an explicit fold feature; unused until implemented.
  bool folded = false;
  bool paste_enabled = true;
  bool copy_enabled = true;
  bool send_enabled = true;
  std::wstring status;
  std::wstring preedit;
  std::wstring preview;
  std::wstring empty_hint = L"等待输入";
  std::vector<BufferBlockView> source_blocks;
  std::vector<BufferBlockView> result_blocks;
  float scroll_source = 0;
  float scroll_result = 0;
  // Hover/pressed control for icon affordances (-1 = none).
  int hover = -1;
  int pressed = -1;
};

enum class BufferHitKind {
  kNone = 0,
  kMode,
  kMore,
  kClose,
  kPaste,
  kCopy,
  kSend,
  kBind,
};

struct BufferLayout {
  float width_dip = 680;
  float height_dip = 73;
  DipRect chrome{};
  DipRect toolbar{};
  DipRect divider{};
  DipRect mode_button{};
  DipRect mode_chip{};
  DipRect more_button{};
  DipRect close_button{};
  DipRect bind_label{};
  DipRect status_label{};
  DipRect source_rail{};
  DipRect result_rail{};
  DipRect source_text{};
  DipRect result_text{};
  DipRect paste{};
  DipRect copy{};
  DipRect send{};
  DipRect waiting{};
  bool show_result = false;
  bool show_paste = false;
  bool show_copy = false;
  bool show_send = false;
  bool toolbar_only = false;
};

[[nodiscard]] inline bool BufferNeedsResultRail(
    const BufferPaintState& state) noexcept {
  return state.mode == BufferMode::kGenerate ||
         state.mode == BufferMode::kTranslate || state.busy ||
         state.translate || !state.result_blocks.empty() ||
         !state.preview.empty();
}

[[nodiscard]] inline float BufferContentWidth(
    const std::vector<BufferBlockView>& blocks, const std::wstring& tail,
    float body_font_dip, float spacing) noexcept {
  float width = 0;
  auto add = [&](const std::wstring& text) {
    if (text.empty()) return;
    // Approximate glyph advance for layout/scroll clamps (paint measures exactly).
    width += static_cast<float>(text.size()) * body_font_dip * 0.92f + spacing;
  };
  for (const auto& block : blocks) add(block.text);
  add(tail);
  return width;
}

[[nodiscard]] inline float ClampScroll(float scroll, float content_width,
                                       float visible_width) noexcept {
  const float max_scroll = (std::max)(0.0f, content_width - visible_width);
  if (scroll < 0.0f) return 0.0f;
  if (scroll > max_scroll) return max_scroll;
  return scroll;
}

[[nodiscard]] inline BufferLayout LayoutBuffer(
    const BufferPaintState& state, float width_dip,
    const BufferMetrics& metrics = {}) {
  BufferLayout layout;
  width_dip = (std::clamp)(width_dip, static_cast<float>(metrics.min_width_dip),
                           static_cast<float>(metrics.max_width_dip));
  layout.width_dip = width_dip;
  const float inset = static_cast<float>(metrics.chrome_inset_dip);
  const float toolbar_h = static_cast<float>(metrics.toolbar_height_dip);
  const float preferred_rail_h = static_cast<float>(metrics.source_rail_height_dip);
  const float icon = static_cast<float>(metrics.icon_size_dip);
  const float gap = static_cast<float>(metrics.icon_gap_dip);
  const float rail_inset = static_cast<float>(metrics.rail_inset_dip);
  const float clearance = static_cast<float>(metrics.action_clearance_dip);

  const bool show_result = BufferNeedsResultRail(state);
  layout.show_result = show_result;
  layout.toolbar_only = state.folded;

  if (state.folded) {
    layout.height_dip = static_cast<float>(metrics.toolbar_only_height_dip);
  } else if (show_result) {
    // Generation, waiting, translation, and any result preview need two rails.
    layout.height_dip = static_cast<float>(metrics.two_rail_height_dip);
  } else {
    // Open Buffer with empty or source-only content stays at ordinary height
    // so the source rail (and empty hint) remain visible.
    layout.height_dip = static_cast<float>(metrics.ordinary_height_dip);
  }

  layout.chrome = {inset, inset, width_dip - inset, layout.height_dip - inset};
  layout.toolbar = {inset, inset, width_dip - inset, inset + toolbar_h};
  // Divider is one DIP at layout time; paint strokes 1 physical pixel.
  layout.divider = {inset, layout.toolbar.bottom, width_dip - inset,
                    layout.toolbar.bottom + 1.0f};

  layout.mode_button = {layout.toolbar.left + 6.0f,
                        layout.toolbar.top + (toolbar_h - icon) * 0.5f,
                        layout.toolbar.left + 6.0f + icon,
                        layout.toolbar.top + (toolbar_h - icon) * 0.5f + icon};
  layout.close_button = {layout.toolbar.right - 6.0f - icon,
                         layout.mode_button.top, layout.toolbar.right - 6.0f,
                         layout.mode_button.bottom};
  layout.more_button = {layout.close_button.left - gap - icon,
                        layout.mode_button.top, layout.close_button.left - gap,
                        layout.mode_button.bottom};
  layout.mode_chip = {layout.mode_button.right + 6.0f, layout.toolbar.top + 6.0f,
                      layout.mode_button.right + 78.0f,
                      layout.toolbar.bottom - 6.0f};
  layout.bind_label = {layout.mode_chip.right + 8.0f, layout.toolbar.top + 8.0f,
                       layout.more_button.left - 8.0f,
                       layout.toolbar.bottom - 8.0f};
  layout.status_label = layout.bind_label;

  if (layout.toolbar_only) {
    // No rail hit targets while folded; paste stays reachable via more menu.
    return layout;
  }

  const float rail_top = layout.divider.bottom;
  const float rail_left = inset + 4.0f;
  const float rail_right = width_dip - inset - 4.0f;
  const float rail_gap = static_cast<float>(metrics.rail_spacing_dip);
  // Both rows must clear the inner chrome, including its bottom stroke.
  const float available = layout.chrome.bottom - 1.0f - rail_top;
  const float rail_h = (std::min)(preferred_rail_h,
      show_result ? (available - rail_gap) * 0.5f : available);
  layout.source_rail = {rail_left, rail_top, rail_right, rail_top + rail_h};
  if (show_result) {
    const float top = layout.source_rail.bottom + rail_gap;
    layout.result_rail = {rail_left, top, rail_right, top + rail_h};
  }

  layout.show_paste = true;
  layout.show_copy = show_result || state.mode != BufferMode::kInput;
  layout.show_send = true;
  // Mac's paste/copy/send cluster overlays the primary (result when present)
  // rail. Hidden copy has no empty slot; neither row's outer width changes.
  const DipRect& primary = show_result ? layout.result_rail : layout.source_rail;
  const float action_y = primary.top + (rail_h - icon) * 0.5f;
  layout.send = {primary.right - icon - rail_inset, action_y,
                 primary.right - rail_inset, action_y + icon};
  float next_right = layout.send.left - gap;
  if (layout.show_copy) {
    layout.copy = {next_right - icon, action_y, next_right, action_y + icon};
    next_right = layout.copy.left - gap;
  }
  layout.paste = {next_right - icon, action_y, next_right, action_y + icon};
  if (show_result && state.busy) {
    layout.waiting = {layout.paste.left - gap - icon, action_y,
                      layout.paste.left - gap, action_y + icon};
  }
  const float text_right = (show_result && state.busy
      ? layout.waiting.left : layout.paste.left) - clearance;
  layout.source_text = {layout.source_rail.left + rail_inset,
                        layout.source_rail.top,
                        show_result ? layout.source_rail.right - rail_inset
                                    : text_right,
                        layout.source_rail.bottom};
  if (show_result) {
    layout.result_text = {layout.result_rail.left + rail_inset,
                          layout.result_rail.top, text_right,
                          layout.result_rail.bottom};
  }

  return layout;
}

[[nodiscard]] inline bool RectInside(const DipRect& inner,
                                     const DipRect& outer) noexcept {
  if (inner.width() <= 0.0f || inner.height() <= 0.0f) return true;
  return inner.left >= outer.left - 0.01f && inner.right <= outer.right + 0.01f &&
         inner.top >= outer.top - 0.01f && inner.bottom <= outer.bottom + 0.01f;
}

[[nodiscard]] inline bool BufferLayoutFullyContained(
    const BufferLayout& layout) noexcept {
  const DipRect bounds{0, 0, layout.width_dip, layout.height_dip};
  if (!RectInside(layout.chrome, bounds)) return false;
  if (!RectInside(layout.toolbar, bounds)) return false;
  if (!RectInside(layout.mode_button, bounds)) return false;
  if (!RectInside(layout.more_button, bounds)) return false;
  if (!RectInside(layout.close_button, bounds)) return false;
  if (layout.toolbar_only) {
    // Folded: rail/action hit targets must be empty / off-window.
    return layout.source_rail.height() <= 0.0f &&
           layout.result_rail.height() <= 0.0f &&
           layout.paste.height() <= 0.0f && layout.copy.height() <= 0.0f &&
           layout.send.height() <= 0.0f;
  }
  if (!RectInside(layout.source_rail, layout.chrome)) return false;
  if (!RectInside(layout.source_text, bounds)) return false;
  if (layout.show_paste && !RectInside(layout.paste, bounds)) return false;
  if (layout.show_result) {
    if (!RectInside(layout.result_rail, layout.chrome)) return false;
    if (!RectInside(layout.result_text, bounds)) return false;
    if (layout.show_copy && !RectInside(layout.copy, bounds)) return false;
    if (layout.show_send && !RectInside(layout.send, bounds)) return false;
  } else {
    if (layout.show_copy && !RectInside(layout.copy, bounds)) return false;
    if (layout.show_send && !RectInside(layout.send, bounds)) return false;
  }
  return true;
}

[[nodiscard]] inline BufferHitKind HitTestBuffer(const BufferLayout& layout,
                                                 float x, float y) noexcept {
  if (layout.mode_button.contains(x, y) || layout.mode_chip.contains(x, y))
    return BufferHitKind::kMode;
  if (layout.more_button.contains(x, y)) return BufferHitKind::kMore;
  if (layout.close_button.contains(x, y)) return BufferHitKind::kClose;
  if (layout.show_paste && layout.paste.contains(x, y))
    return BufferHitKind::kPaste;
  if (layout.show_copy && layout.copy.contains(x, y))
    return BufferHitKind::kCopy;
  if (layout.show_send && layout.send.contains(x, y))
    return BufferHitKind::kSend;
  // Only the source rail establishes capture. Result/status surfaces are
  // passive, and the action overlay keeps priority over the rail below it.
  if (!layout.toolbar_only && layout.source_rail.contains(x, y))
    return BufferHitKind::kBind;
  return BufferHitKind::kNone;
}

[[nodiscard]] inline bool BufferHitIsCaptionExcluded(
    BufferHitKind hit) noexcept {
  return hit != BufferHitKind::kNone;
}

}  // namespace rimes::windows::ui
