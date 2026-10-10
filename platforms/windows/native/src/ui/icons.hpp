#pragma once

#include <Windows.h>

#include <algorithm>
#include <cmath>
#include <cstring>
#include <iterator>
#include <vector>

#include "theme.hpp"
#include "product_icon.h"

namespace rimes::windows::ui {

enum class IconId {
  kGrid,
  kPaste,
  kCopy,
  kPlane,
  kClose,
  kChevron,
  kMore,
  kSettings,
  kTheme,
  kLanguage,
  kKey,
  kApi,
  kSparkles,
  kCheck,
  kProduct,
  kRadioOn,
  kRadioOff,
  kKeyboard,
  kAlphabet,
  kBird,
  kEnglish,
  kPalette,
  kLink,
  kInfo,
};

[[nodiscard]] inline COLORREF ToColorRef(std::uint32_t rgb) noexcept {
  return RGB(Red(rgb), Green(rgb), Blue(rgb));
}

inline void FillRoundRect(HDC dc, const RECT& rect, int radius,
                          COLORREF fill) noexcept {
  const HBRUSH brush = CreateSolidBrush(fill);
  const HPEN pen = CreatePen(PS_NULL, 0, fill);
  const HGDIOBJ old_brush = SelectObject(dc, brush);
  const HGDIOBJ old_pen = SelectObject(dc, pen);
  RoundRect(dc, rect.left, rect.top, rect.right, rect.bottom, radius * 2,
            radius * 2);
  SelectObject(dc, old_brush);
  SelectObject(dc, old_pen);
  DeleteObject(brush);
  DeleteObject(pen);
}

inline void StrokeRoundRect(HDC dc, const RECT& rect, int radius,
                            COLORREF stroke, int thickness = 1) noexcept {
  const HBRUSH brush = static_cast<HBRUSH>(GetStockObject(NULL_BRUSH));
  const HPEN pen = CreatePen(PS_SOLID, thickness, stroke);
  const HGDIOBJ old_brush = SelectObject(dc, brush);
  const HGDIOBJ old_pen = SelectObject(dc, pen);
  RoundRect(dc, rect.left, rect.top, rect.right - thickness,
            rect.bottom - thickness, radius * 2, radius * 2);
  SelectObject(dc, old_brush);
  SelectObject(dc, old_pen);
  DeleteObject(pen);
}

inline void FillRectColor(HDC dc, const RECT& rect, COLORREF fill) noexcept {
  const HBRUSH brush = CreateSolidBrush(fill);
  FillRect(dc, &rect, brush);
  DeleteObject(brush);
}

inline void DrawIconGlyph(HDC dc, IconId id, const RECT& box,
                          COLORREF color) noexcept {
  const int w = box.right - box.left;
  const int h = box.bottom - box.top;
  if (w <= 2 || h <= 2) return;
  const HPEN pen = CreatePen(PS_SOLID, (std::max)(1, w / 12), color);
  const HBRUSH brush = CreateSolidBrush(color);
  const HGDIOBJ old_pen = SelectObject(dc, pen);
  const HGDIOBJ old_brush = SelectObject(dc, GetStockObject(NULL_BRUSH));
  const int cx = (box.left + box.right) / 2;
  const int cy = (box.top + box.bottom) / 2;
  const int s = (std::min)(w, h) / 2 - 1;

  auto line = [&](int x0, int y0, int x1, int y1) {
    MoveToEx(dc, x0, y0, nullptr);
    LineTo(dc, x1, y1);
  };

  switch (id) {
    case IconId::kInfo:
      Ellipse(dc, cx - s + 1, cy - s + 1, cx + s, cy + s);
      SelectObject(dc, brush);
      Ellipse(dc, cx - 1, cy - s / 2, cx + 2, cy - s / 2 + 3);
      line(cx, cy, cx, cy + s / 2);
      line(cx - 2, cy + s / 2, cx + 3, cy + s / 2);
      break;
    case IconId::kKeyboard: {
      RoundRect(dc, box.left + 1, cy - s / 2 - 1,
                box.right - 1, cy + s / 2 + 2, 3, 3);
      for (int row = 0; row < 2; ++row)
        for (int col = 0; col < 5; ++col) {
          const int x = box.left + 3 + col * (w - 6) / 5;
          const int y = cy - s / 3 + row * (std::max)(2, s / 3);
          line(x, y, x + (std::max)(1, w / 18), y);
        }
      line(cx - s / 2, cy + s / 3, cx + s / 2, cy + s / 3);
      break;
    }
    case IconId::kAlphabet:
    case IconId::kEnglish: {
      const HFONT font = CreateFontW(-(id == IconId::kEnglish ? h * 2 / 3 : h / 2),
          0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE, DEFAULT_CHARSET,
          OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY,
          DEFAULT_PITCH, L"Segoe UI");
      const auto old_font = SelectObject(dc, font);
      SetBkMode(dc, TRANSPARENT);
      SetTextColor(dc, color);
      RECT text = box;
      DrawTextW(dc, id == IconId::kEnglish ? L"AⅠ" : L"Abc", -1, &text,
                DT_CENTER | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX);
      SelectObject(dc, old_font);
      DeleteObject(font);
      break;
    }
    case IconId::kBird: {
      POINT outline[] = {{cx, cy - s}, {cx + s / 2, cy - s / 2},
          {cx + s, cy - s / 3}, {cx + s / 3, cy},
          {cx + s / 4, cy + s / 2}, {cx - s / 3, cy + s},
          {cx - s / 2, cy + s / 2}, {cx - s / 5, cy},
          {cx - s, cy - s / 2}, {cx - s, cy - s},
          {cx - s / 4, cy - s / 2}, {cx, cy - s}};
      Polyline(dc, outline, static_cast<int>(std::size(outline)));
      break;
    }
    case IconId::kPalette:
      Ellipse(dc, cx - s, cy - s, cx + s, cy + s);
      for (const auto point : {POINT{cx - s / 2, cy - s / 3},
                              POINT{cx, cy - s / 2},
                              POINT{cx + s / 2, cy},
                              POINT{cx - s / 3, cy + s / 2}}) {
        const int r = (std::max)(1, s / 6);
        Ellipse(dc, point.x - r, point.y - r, point.x + r + 1, point.y + r + 1);
      }
      break;
    case IconId::kLink:
      Ellipse(dc, cx - s, cy, cx + s / 3, cy + s);
      Ellipse(dc, cx - s / 3, cy - s, cx + s, cy);
      line(cx - s / 3, cy + s / 3, cx + s / 3, cy - s / 3);
      break;
    case IconId::kGrid: {
      const int cell = (std::max)(3, s / 2);
      const int gap = (std::max)(2, s / 5);
      const int x0 = cx - cell - gap / 2;
      const int y0 = cy - cell - gap / 2;
      RoundRect(dc, x0, y0, x0 + cell, y0 + cell, 3, 3);
      RoundRect(dc, x0 + cell + gap, y0, x0 + 2 * cell + gap, y0 + cell, 3, 3);
      RoundRect(dc, x0, y0 + cell + gap, x0 + cell, y0 + 2 * cell + gap, 3, 3);
      RoundRect(dc, x0 + cell + gap, y0 + cell + gap, x0 + 2 * cell + gap,
                y0 + 2 * cell + gap, 3, 3);
      break;
    }
    case IconId::kPaste: {
      RECT board{cx - s + 2, cy - s / 3, cx + s - 2, cy + s};
      RoundRect(dc, board.left, board.top, board.right, board.bottom, 4, 4);
      RECT clip{cx - s / 2, cy - s, cx + s / 2, cy - s / 3};
      RoundRect(dc, clip.left, clip.top, clip.right, clip.bottom, 3, 3);
      line(cx, cy, cx, cy + s / 2);
      line(cx - s / 3, cy + s / 5, cx, cy + s / 2);
      line(cx + s / 3, cy + s / 5, cx, cy + s / 2);
      break;
    }
    case IconId::kCopy: {
      RECT back{cx - s + 4, cy - s / 4, cx + s / 3, cy + s};
      RoundRect(dc, back.left, back.top, back.right, back.bottom, 3, 3);
      line(cx, cy - s / 2, cx + s - 2, cy - s / 2);
      line(cx + s - 2, cy - s / 2, cx + s - 2, cy + s / 4);
      line(cx, cy + s / 4, cx + s - 2, cy - s / 2);
      break;
    }
    case IconId::kPlane:
      line(cx - s, cy + s / 3, cx + s, cy - s / 2);
      line(cx - s, cy + s / 3, cx - s / 3, cy + s / 2);
      line(cx - s, cy + s / 3, cx - s / 4, cy - s / 4);
      break;
    case IconId::kClose:
      line(cx - s + 2, cy - s + 2, cx + s - 2, cy + s - 2);
      line(cx + s - 2, cy - s + 2, cx - s + 2, cy + s - 2);
      break;
    case IconId::kChevron:
      line(cx - s / 2, cy - s / 2, cx + s / 3, cy);
      line(cx + s / 3, cy, cx - s / 2, cy + s / 2);
      break;
    case IconId::kMore:
      for (int i = -1; i <= 1; ++i) {
        const int x = cx + i * (s / 2);
        SelectObject(dc, brush);
        Ellipse(dc, x - 2, cy - 2, x + 2, cy + 2);
        SelectObject(dc, GetStockObject(NULL_BRUSH));
      }
      break;
    case IconId::kSettings:
      Ellipse(dc, cx - s / 2, cy - s / 2, cx + s / 2, cy + s / 2);
      Ellipse(dc, cx - s / 4, cy - s / 4, cx + s / 4, cy + s / 4);
      for (int i = 0; i < 4; ++i) {
        const double a = i * 3.141592653589793 / 2.0;
        line(cx + static_cast<int>(std::cos(a) * (s / 2)),
             cy + static_cast<int>(std::sin(a) * (s / 2)),
             cx + static_cast<int>(std::cos(a) * s),
             cy + static_cast<int>(std::sin(a) * s));
      }
      break;
    case IconId::kTheme:
      Ellipse(dc, cx - s, cy - s, cx + s, cy + s);
      SelectObject(dc, brush);
      Pie(dc, cx - s, cy - s, cx + s, cy + s, cx, cy - s, cx, cy + s);
      SelectObject(dc, GetStockObject(NULL_BRUSH));
      break;
    case IconId::kLanguage:
      // Globe: correct ellipse uses left/top/right/bottom (not cy as right).
      Ellipse(dc, cx - s, cy - s, cx + s, cy + s);
      Ellipse(dc, cx - s / 2, cy - s, cx + s / 2, cy + s);
      line(cx - s, cy, cx + s, cy);
      break;
    case IconId::kKey:
      Ellipse(dc, cx - s, cy - s / 2, cx - 1, cy + s / 2);
      line(cx - 1, cy, cx + s, cy);
      line(cx + s / 2, cy, cx + s / 2, cy + s / 2);
      break;
    case IconId::kApi:
      line(cx - s, cy, cx - s / 3, cy - s / 2);
      line(cx - s / 3, cy - s / 2, cx + s / 3, cy + s / 2);
      line(cx + s / 3, cy + s / 2, cx + s, cy);
      break;
    case IconId::kCheck:
      line(cx - s / 2, cy, cx - s / 6, cy + s / 2);
      line(cx - s / 6, cy + s / 2, cx + s / 2, cy - s / 2);
      break;
    case IconId::kRadioOn:
      Ellipse(dc, cx - s, cy - s, cx + s, cy + s);
      SelectObject(dc, brush);
      Ellipse(dc, cx - s / 2, cy - s / 2, cx + s / 2, cy + s / 2);
      SelectObject(dc, GetStockObject(NULL_BRUSH));
      break;
    case IconId::kRadioOff:
      Ellipse(dc, cx - s, cy - s, cx + s, cy + s);
      break;
    case IconId::kProduct:
      line(cx - s / 2, cy + s, cx - s / 2, cy - s / 3);
      line(cx, cy + s, cx, cy - s);
      line(cx + s / 2, cy + s, cx + s / 2, cy - s / 3);
      SelectObject(dc, brush);
      Ellipse(dc, cx - 2, cy - s, cx + 3, cy - s + 5);
      SelectObject(dc, GetStockObject(NULL_BRUSH));
      break;
  }

  SelectObject(dc, old_brush);
  SelectObject(dc, old_pen);
  DeleteObject(brush);
  DeleteObject(pen);
}

// LoadImage without LR_SHARED returns an owned icon; the tray owner destroys it.
[[nodiscard]] inline HICON CreateProductIcon(int size_px) noexcept {
  return static_cast<HICON>(LoadImageW(GetModuleHandleW(nullptr),
      MAKEINTRESOURCEW(IDI_RIMES), IMAGE_ICON, size_px, size_px, 0));
}

}  // namespace rimes::windows::ui
