#pragma once

#include <d2d1.h>
#include <dwrite.h>

#include <algorithm>
#include <cmath>
#include <string>
#include <vector>

#include "buffer_layout.hpp"
#include "icons.hpp"
#include "theme.hpp"

namespace rimes::windows::ui {

[[nodiscard]] inline D2D1_COLOR_F ColorF(std::uint32_t rgb,
                                         float a = 1.0f) noexcept {
  return D2D1::ColorF(Rf(rgb), Gf(rgb), Bf(rgb), a);
}

inline void DrawD2DIcon(ID2D1RenderTarget* target, ID2D1SolidColorBrush* brush,
                        IconId id, const DipRect& box, std::uint32_t color,
                        float stroke = 1.25f) {
  if (!target || !brush || box.width() < 4.0f || box.height() < 4.0f) return;
  brush->SetColor(ColorF(color));
  const float cx = (box.left + box.right) * 0.5f;
  const float cy = (box.top + box.bottom) * 0.5f;
  const float s = (std::min)(box.width(), box.height()) * 0.5f - 2.0f;

  auto line = [&](float x0, float y0, float x1, float y1) {
    target->DrawLine(D2D1::Point2F(x0, y0), D2D1::Point2F(x1, y1), brush,
                     stroke);
  };
  auto round_rect = [&](float l, float t, float r, float b, float radius,
                        bool fill) {
    const auto rr =
        D2D1::RoundedRect(D2D1::RectF(l, t, r, b), radius, radius);
    if (fill)
      target->FillRoundedRectangle(rr, brush);
    else
      target->DrawRoundedRectangle(rr, brush, stroke);
  };

  switch (id) {
    case IconId::kSparkles:
      line(cx, cy - s * .8f, cx + s * .24f, cy - s * .24f);
      line(cx + s * .24f, cy - s * .24f, cx + s * .8f, cy);
      line(cx + s * .8f, cy, cx + s * .24f, cy + s * .24f);
      line(cx + s * .24f, cy + s * .24f, cx, cy + s * .8f);
      line(cx, cy + s * .8f, cx - s * .24f, cy + s * .24f);
      line(cx - s * .24f, cy + s * .24f, cx - s * .8f, cy);
      line(cx - s * .8f, cy, cx - s * .24f, cy - s * .24f);
      line(cx - s * .24f, cy - s * .24f, cx, cy - s * .8f);
      break;
    case IconId::kGrid: {
      // Four rounded squares (Mac toolbar grid).
      const float cell = s * 0.72f;
      const float gap = s * 0.28f;
      const float x0 = cx - cell - gap * 0.5f;
      const float y0 = cy - cell - gap * 0.5f;
      round_rect(x0, y0, x0 + cell, y0 + cell, 1.6f, false);
      round_rect(x0 + cell + gap, y0, x0 + 2 * cell + gap, y0 + cell, 1.6f,
                 false);
      round_rect(x0, y0 + cell + gap, x0 + cell, y0 + 2 * cell + gap, 1.6f,
                 false);
      round_rect(x0 + cell + gap, y0 + cell + gap, x0 + 2 * cell + gap,
                 y0 + 2 * cell + gap, 1.6f, false);
      break;
    }
    case IconId::kPaste: {
      // Clipboard import: board + downward arrow.
      round_rect(cx - s * 0.55f, cy - s * 0.25f, cx + s * 0.55f, cy + s * 0.75f,
                 2.0f, false);
      round_rect(cx - s * 0.28f, cy - s * 0.75f, cx + s * 0.28f, cy - s * 0.25f,
                 1.5f, false);
      line(cx, cy - s * 0.05f, cx, cy + s * 0.45f);
      line(cx - s * 0.28f, cy + s * 0.18f, cx, cy + s * 0.45f);
      line(cx + s * 0.28f, cy + s * 0.18f, cx, cy + s * 0.45f);
      break;
    }
    case IconId::kCopy: {
      // Copy-out: square with outward arrow.
      round_rect(cx - s * 0.65f, cy - s * 0.35f, cx + s * 0.25f, cy + s * 0.65f,
                 2.0f, false);
      line(cx - s * 0.05f, cy - s * 0.55f, cx + s * 0.55f, cy - s * 0.55f);
      line(cx + s * 0.55f, cy - s * 0.55f, cx + s * 0.55f, cy + s * 0.05f);
      line(cx - s * 0.05f, cy + s * 0.05f, cx + s * 0.55f, cy - s * 0.55f);
      break;
    }
    case IconId::kPlane: {
      // Paper plane send glyph.
      target->DrawLine(D2D1::Point2F(cx - s * 0.7f, cy + s * 0.15f),
                       D2D1::Point2F(cx + s * 0.75f, cy - s * 0.55f), brush,
                       stroke);
      target->DrawLine(D2D1::Point2F(cx - s * 0.7f, cy + s * 0.15f),
                       D2D1::Point2F(cx - s * 0.05f, cy + s * 0.55f), brush,
                       stroke);
      target->DrawLine(D2D1::Point2F(cx - s * 0.7f, cy + s * 0.15f),
                       D2D1::Point2F(cx + s * 0.05f, cy - s * 0.05f), brush,
                       stroke);
      target->DrawLine(D2D1::Point2F(cx + s * 0.05f, cy - s * 0.05f),
                       D2D1::Point2F(cx - s * 0.05f, cy + s * 0.55f), brush,
                       stroke);
      line(cx - s * 0.05f, cy + s * 0.55f,
           cx + s * 0.75f, cy - s * 0.55f);
      break;
    }
    case IconId::kClose:
      line(cx - s * 0.55f, cy - s * 0.55f, cx + s * 0.55f, cy + s * 0.55f);
      line(cx + s * 0.55f, cy - s * 0.55f, cx - s * 0.55f, cy + s * 0.55f);
      break;
    case IconId::kMore:
      for (int i = -1; i <= 1; ++i) {
        const float x = cx + static_cast<float>(i) * s * 0.45f;
        target->FillEllipse(D2D1::Ellipse(D2D1::Point2F(x, cy), 1.6f, 1.6f),
                            brush);
      }
      break;
    case IconId::kChevron:
      line(cx - s * 0.45f, cy - s * 0.25f, cx, cy + s * 0.35f);
      line(cx, cy + s * 0.35f, cx + s * 0.45f, cy - s * 0.25f);
      break;
    case IconId::kCheck:
      line(cx - s * 0.45f, cy + s * 0.05f, cx - s * 0.1f, cy + s * 0.45f);
      line(cx - s * 0.1f, cy + s * 0.45f, cx + s * 0.5f, cy - s * 0.4f);
      break;
    default:
      round_rect(box.left + 2, box.top + 2, box.right - 2, box.bottom - 2, 3.0f,
                 false);
      break;
  }
}

struct BufferPaintContext {
  ID2D1RenderTarget* target = nullptr;
  IDWriteFactory* write = nullptr;
  IDWriteTextFormat* body = nullptr;
  IDWriteTextFormat* label = nullptr;
  ID2D1SolidColorBrush* brush = nullptr;
  float dpi = 96.0f;
};

// Use the same DirectWrite metrics for horizontal scrolling and drawing.
// No wrapping: a long block remains one rail item and cannot hide its tail
// on an unpainted second line.
inline float MeasureBufferContent(IDWriteFactory* write,
                                  IDWriteTextFormat* body,
                                  const std::vector<BufferBlockView>& blocks,
                                  const std::wstring& tail,
                                  bool source_tail = true) {
  if (!write || !body) return 0;
  float width = 0;
  auto add = [&](const std::wstring& text, bool preedit) {
    if (text.empty()) return;
    IDWriteTextLayout* layout = nullptr;
    if (FAILED(write->CreateTextLayout(text.c_str(),
            static_cast<UINT32>(text.size()), body, 8000, 32, &layout)))
      return;
    layout->SetWordWrapping(DWRITE_WORD_WRAPPING_NO_WRAP);
    if (preedit) layout->SetFontSize(13, {0, static_cast<UINT32>(text.size())});
    DWRITE_TEXT_METRICS metrics{};
    layout->GetMetrics(&metrics);
    width += metrics.widthIncludingTrailingWhitespace + 5.0f;
    layout->Release();
  };
  for (const auto& block : blocks) add(block.text, false);
  add(tail, source_tail);
  return width;
}

inline void DrawBufferWorkbench(const BufferPaintContext& ctx,
                                const BufferPaintState& state,
                                const BufferLayout& layout) {
  auto* target = ctx.target;
  auto* write = ctx.write;
  auto* body = ctx.body;
  auto* label = ctx.label;
  auto* brush = ctx.brush;
  if (!target || !write || !body || !label || !brush) return;

  label->SetParagraphAlignment(DWRITE_PARAGRAPH_ALIGNMENT_CENTER);

  // Never clear the caller's full render target; host clears its canvas.
  const ThemePalette& p = Palette(state.theme);
  const float hairline = 96.0f / (std::max)(ctx.dpi, 1.0f);

  brush->SetColor(ColorF(p.buffer));
  target->FillRoundedRectangle(
      D2D1::RoundedRect(
          D2D1::RectF(layout.chrome.left, layout.chrome.top, layout.chrome.right,
                      layout.chrome.bottom),
          11.0f, 11.0f),
      brush);
  brush->SetColor(ColorF(p.buffer_border));
  target->DrawRoundedRectangle(
      D2D1::RoundedRect(
          D2D1::RectF(layout.chrome.left, layout.chrome.top, layout.chrome.right,
                      layout.chrome.bottom),
          11.0f, 11.0f),
      brush, hairline);

  // Toolbar shares buffer background (not a bright secondary stripe).
  brush->SetColor(ColorF(p.buffer_divider));
  target->DrawLine(D2D1::Point2F(layout.divider.left, layout.divider.top),
                   D2D1::Point2F(layout.divider.right, layout.divider.top),
                   brush, hairline);

  auto icon_color = [&](BufferHitKind kind, bool enabled,
                        std::uint32_t normal) -> std::uint32_t {
    if (!enabled) return Blend(normal, p.buffer, 0.55f);
    if (state.pressed == static_cast<int>(kind))
      return Blend(normal, p.accent, 0.35f);
    if (state.hover == static_cast<int>(kind))
      return Blend(normal, p.text_primary, 0.25f);
    return normal;
  };

  auto draw_control_bg = [&](const DipRect& box, BufferHitKind kind,
                             bool enabled, std::uint32_t base) {
    const bool pressed = enabled && state.pressed == static_cast<int>(kind);
    const bool hovered = enabled && state.hover == static_cast<int>(kind);
    const float fill_alpha = !enabled ? 0.34f : (pressed ? 1.0f : 0.78f);
    std::uint32_t fill = Blend(base, p.surface_secondary, fill_alpha);
    if (hovered) fill = Blend(fill, p.text_primary, pressed ? 0.14f : 0.08f);
    brush->SetColor(ColorF(fill));
    const auto shape = D2D1::RoundedRect(
        D2D1::RectF(box.left + hairline * 0.5f, box.top + hairline * 0.5f,
                    box.right - hairline * 0.5f, box.bottom - hairline * 0.5f),
        6, 6);
    target->FillRoundedRectangle(shape, brush);
    brush->SetColor(ColorF(Blend(base,
        hovered ? p.border_strong : p.border, enabled ? 0.82f : 0.40f)));
    target->DrawRoundedRectangle(shape, brush, hairline);
  };

  draw_control_bg(layout.mode_button, BufferHitKind::kMode, true, p.buffer);
  DrawD2DIcon(target, brush, IconId::kGrid, layout.mode_button,
              icon_color(BufferHitKind::kMode, true, p.text_secondary));

  // The mode popup shares the persistent surface and disclosure separator.
  draw_control_bg(layout.mode_chip, BufferHitKind::kMode, true, p.buffer);
  brush->SetColor(ColorF(p.border));
  const float disclosure_x = layout.mode_chip.right - 20;
  target->DrawLine(D2D1::Point2F(disclosure_x, layout.mode_chip.top + 4),
                   D2D1::Point2F(disclosure_x, layout.mode_chip.bottom - 4),
                   brush, hairline);
  const wchar_t* mode_name = L"输入";
  if (state.mode == BufferMode::kGenerate) mode_name = L"生成";
  if (state.mode == BufferMode::kTranslate) mode_name = L"翻译";
  brush->SetColor(ColorF(p.text_primary));
  target->DrawTextW(mode_name, static_cast<UINT32>(wcslen(mode_name)), label,
                    D2D1::RectF(layout.mode_chip.left + 8, layout.mode_chip.top,
                                disclosure_x - 4,
                                layout.mode_chip.bottom),
                    brush, D2D1_DRAW_TEXT_OPTIONS_CLIP);
  DrawD2DIcon(target, brush, IconId::kChevron,
              {layout.mode_chip.right - 14, layout.mode_chip.top + 4,
               layout.mode_chip.right - 4, layout.mode_chip.bottom - 4},
              p.text_muted, 1.1f);

  if (state.bound || !state.status.empty()) {
    const std::wstring status =
        !state.status.empty()
            ? state.status
            : (state.capturing ? L"已绑定" : L"已暂停");
    const bool danger =
        state.status.find(L"失败") != std::wstring::npos ||
        state.status.find(L"错误") != std::wstring::npos;
    brush->SetColor(ColorF(danger ? p.danger_text
                                  : (state.capturing ? p.accent_text
                                                     : p.warning_text)));
    target->DrawTextW(status.c_str(), static_cast<UINT32>(status.size()), label,
                      D2D1::RectF(layout.status_label.left,
                                  layout.status_label.top,
                                  layout.status_label.right,
                                  layout.status_label.bottom),
                      brush, D2D1_DRAW_TEXT_OPTIONS_CLIP);
  }

  draw_control_bg(layout.more_button, BufferHitKind::kMore, true, p.buffer);
  DrawD2DIcon(target, brush, IconId::kMore, layout.more_button,
              icon_color(BufferHitKind::kMore, true, p.text_secondary));
  draw_control_bg(layout.close_button, BufferHitKind::kClose, true, p.buffer);
  DrawD2DIcon(target, brush, IconId::kClose, layout.close_button,
              icon_color(BufferHitKind::kClose, true, p.text_secondary));

  if (layout.toolbar_only) return;

  auto paint_rail = [&](const DipRect& rail, const DipRect& text_box,
                        std::uint32_t fill,
                        const std::vector<BufferBlockView>& blocks,
                        const std::wstring& tail, bool result_lane,
                        float scroll) {
    brush->SetColor(ColorF(fill));
    target->FillRoundedRectangle(
        D2D1::RoundedRect(
            D2D1::RectF(rail.left, rail.top, rail.right, rail.bottom), 6, 6),
        brush);
    target->PushAxisAlignedClip(
        D2D1::RectF(text_box.left, text_box.top, text_box.right, text_box.bottom),
        D2D1_ANTIALIAS_MODE_PER_PRIMITIVE);
    float x = text_box.left - scroll;
    auto paint_item = [&](const std::wstring& text, bool streaming,
                          bool preedit) {
      if (text.empty()) return;
      IDWriteTextLayout* layout_obj = nullptr;
      if (FAILED(write->CreateTextLayout(
              text.c_str(), static_cast<UINT32>(text.size()), body, 8000.0f,
              text_box.height(), &layout_obj)))
        return;
      layout_obj->SetWordWrapping(DWRITE_WORD_WRAPPING_NO_WRAP);
      layout_obj->SetParagraphAlignment(DWRITE_PARAGRAPH_ALIGNMENT_CENTER);
      if (preedit)
        layout_obj->SetFontSize(13, {0, static_cast<UINT32>(text.size())});
      DWRITE_TEXT_METRICS metrics{};
      layout_obj->GetMetrics(&metrics);
      const float w = metrics.widthIncludingTrailingWhitespace;
      brush->SetColor(ColorF(p.text_primary));
      target->DrawTextLayout(D2D1::Point2F(x, text_box.top), layout_obj,
                             brush, D2D1_DRAW_TEXT_OPTIONS_CLIP);
      brush->SetColor(ColorF(streaming ? p.accent : p.border_strong));
      target->DrawLine(D2D1::Point2F(x, rail.bottom - 4.0f),
                       D2D1::Point2F(x + w, rail.bottom - 4.0f), brush,
                       hairline);
      layout_obj->Release();
      x += w + 5.0f;
    };
    if (blocks.empty() && tail.empty() && !result_lane &&
        !state.empty_hint.empty()) {
      brush->SetColor(ColorF(p.text_muted));
      target->DrawTextW(state.empty_hint.c_str(),
                        static_cast<UINT32>(state.empty_hint.size()), label,
                        D2D1::RectF(text_box.left, text_box.top,
                                    text_box.right, text_box.bottom),
                        brush, D2D1_DRAW_TEXT_OPTIONS_CLIP);
    } else {
      for (const auto& block : blocks)
        paint_item(block.text, block.streaming, false);
      if (!tail.empty()) paint_item(tail, true, !result_lane);
      if (!result_lane && state.capturing) {
        brush->SetColor(ColorF(p.accent));
        target->DrawLine(D2D1::Point2F(x - 3, rail.top + 7),
                         D2D1::Point2F(x - 3, rail.bottom - 7), brush, 2);
      }
    }
    target->PopAxisAlignedClip();
  };

  paint_rail(layout.source_rail, layout.source_text,
             layout.show_result ? p.buffer_source_rail : p.candidate,
             state.source_blocks, state.preedit, false, state.scroll_source);
  if (layout.show_result) {
    // Preview is drawn as the streaming tail only — callers must not also
    // append it into result_blocks.
    paint_rail(layout.result_rail, layout.result_text, p.buffer_target_rail,
               state.result_blocks, state.preview, true, state.scroll_result);
  }

  const auto action_surface = layout.show_result ? p.buffer_target_rail : p.candidate;
  if (layout.show_paste) {
    draw_control_bg(layout.paste, BufferHitKind::kPaste, state.paste_enabled, action_surface);
    DrawD2DIcon(target, brush, IconId::kPaste, layout.paste,
                icon_color(BufferHitKind::kPaste, state.paste_enabled,
                           p.text_secondary));
  }
  if (layout.show_copy) {
    draw_control_bg(layout.copy, BufferHitKind::kCopy, state.copy_enabled, action_surface);
    DrawD2DIcon(target, brush, IconId::kCopy, layout.copy,
                icon_color(BufferHitKind::kCopy, state.copy_enabled,
                           p.text_secondary));
  }
  if (layout.show_send) {
    draw_control_bg(layout.send, BufferHitKind::kSend, state.send_enabled, action_surface);
    // The primary action generates before a final exists; it only sends a
    // reviewed final afterwards. This is shared by API and local CLI routes.
    const auto primary = state.mode == BufferMode::kGenerate && state.result_blocks.empty()
        ? IconId::kSparkles : IconId::kPlane;
    DrawD2DIcon(target, brush, primary, layout.send,
                icon_color(BufferHitKind::kSend, state.send_enabled,
                           p.accent_text));
  }
  if (layout.show_result && state.busy) {
    // Single waiting indicator in the result rail (not on send).
    brush->SetColor(ColorF(p.accent));
    const float cx = (layout.waiting.left + layout.waiting.right) * 0.5f;
    const float cy = (layout.waiting.top + layout.waiting.bottom) * 0.5f;
    target->DrawEllipse(D2D1::Ellipse(D2D1::Point2F(cx, cy), 5.0f, 5.0f), brush,
                        hairline * 1.5f);
  }
}

// Compatibility wrapper used by older call sites.
inline void DrawBufferWorkbench(ID2D1RenderTarget* target, IDWriteFactory* write,
                                IDWriteTextFormat* body,
                                IDWriteTextFormat* label,
                                ID2D1SolidColorBrush* brush,
                                const BufferPaintState& state,
                                const BufferLayout& layout) {
  DrawBufferWorkbench(BufferPaintContext{target, write, body, label, brush, 96},
                      state, layout);
}

}  // namespace rimes::windows::ui
