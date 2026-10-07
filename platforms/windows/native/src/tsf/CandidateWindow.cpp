#include "CandidateWindow.h"

#include <algorithm>
#include <cmath>
#include <mutex>

#include "../ui/icons.hpp"
#include "Guids.h"
#include "ModuleState.h"
#include "candidate_layout.hpp"

namespace rimes::windows::tsf {
namespace {

std::mutex g_snapshot_mutex;
CandidateSnapshot g_last_snapshot;

RECT ToRect(const ScreenPoint& origin, long width, long height) noexcept {
  RECT rect{};
  rect.left = origin.x;
  rect.top = origin.y;
  rect.right = origin.x + width;
  rect.bottom = origin.y + height;
  return rect;
}

unsigned int WindowDpi(HWND window) noexcept {
  using GetDpiForWindowFn = UINT(WINAPI*)(HWND);
  const HMODULE user32 = GetModuleHandleW(L"user32.dll");
  if (user32 != nullptr) {
    const auto get_dpi = reinterpret_cast<GetDpiForWindowFn>(
        GetProcAddress(user32, "GetDpiForWindow"));
    if (get_dpi != nullptr && window != nullptr) {
      const UINT dpi = get_dpi(window);
      if (dpi != 0) return dpi;
    }
  }
  const HDC desktop = GetDC(nullptr);
  const int dpi = desktop != nullptr ? GetDeviceCaps(desktop, LOGPIXELSX) : 96;
  if (desktop != nullptr) ReleaseDC(nullptr, desktop);
  return dpi > 0 ? static_cast<unsigned int>(dpi) : 96U;
}

ScreenRect WorkAreaFromCaret(const RECT& caret) noexcept {
  const POINT probe{caret.left, caret.top};
  const HMONITOR monitor = MonitorFromPoint(probe, MONITOR_DEFAULTTONEAREST);
  MONITORINFO info{};
  info.cbSize = sizeof(info);
  if (monitor != nullptr && GetMonitorInfoW(monitor, &info)) {
    return {info.rcWork.left, info.rcWork.top, info.rcWork.right,
            info.rcWork.bottom};
  }
  RECT work{};
  SystemParametersInfoW(SPI_GETWORKAREA, 0, &work, 0);
  return {work.left, work.top, work.right, work.bottom};
}

HFONT MakeFont(int height_px, int weight, bool mono) {
  return CreateFontW(-height_px, 0, 0, 0, weight, FALSE, FALSE, FALSE,
                     DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
                     CLEARTYPE_QUALITY, DEFAULT_PITCH | FF_DONTCARE,
                     mono ? L"Consolas" : L"Segoe UI");
}

int MeasureText(HDC dc, HFONT font, const std::wstring& text) {
  if (text.empty()) return 0;
  const HFONT previous = static_cast<HFONT>(SelectObject(dc, font));
  SIZE size{};
  GetTextExtentPoint32W(dc, text.c_str(), static_cast<int>(text.size()), &size);
  SelectObject(dc, previous);
  return size.cx;
}

}  // namespace

CandidateWindow::~CandidateWindow() {
  Hide();
  if (window_ != nullptr) {
    DestroyWindow(window_);
    window_ = nullptr;
  }
}

bool CandidateWindow::GetLastSnapshot(CandidateSnapshot* snapshot) noexcept {
  if (snapshot == nullptr) return false;
  try {
    std::lock_guard lock(g_snapshot_mutex);
    *snapshot = g_last_snapshot;
    return true;
  } catch (...) {
    return false;
  }
}

void CandidateWindow::PublishSnapshot(
    const CandidateSnapshot& snapshot) noexcept {
  try {
    std::lock_guard lock(g_snapshot_mutex);
    g_last_snapshot = snapshot;
  } catch (...) {
  }
}

CandidateSnapshot CandidateWindow::snapshot() const noexcept {
  return snapshot_;
}

void CandidateWindow::Hide() noexcept {
  snapshot_ = {};
  hover_index_ = -1;
  pressed_index_ = -1;
  if (window_ && GetCapture() == window_) ReleaseCapture();
  hit_pills_.clear();
  PublishSnapshot(snapshot_);
  if (window_ != nullptr) ShowWindow(window_, SW_HIDE);
}

bool CandidateWindow::EnsureWindow() noexcept {
  if (window_ != nullptr) return true;
  HINSTANCE instance = module::Instance();
  if (instance == nullptr) instance = GetModuleHandleW(nullptr);
  if (instance == nullptr) return false;

  WNDCLASSEXW window_class{};
  window_class.cbSize = sizeof(window_class);
  window_class.lpfnWndProc = WindowProcedure;
  window_class.hInstance = instance;
  window_class.lpszClassName = kCandidateWindowClass;
  window_class.hCursor = LoadCursorW(nullptr, IDC_ARROW);
  window_class.hbrBackground =
      static_cast<HBRUSH>(GetStockObject(NULL_BRUSH));
  window_class.style = CS_HREDRAW | CS_VREDRAW | CS_DROPSHADOW;
  RegisterClassExW(&window_class);

  window_ = CreateWindowExW(WS_EX_TOOLWINDOW | WS_EX_TOPMOST |
                                WS_EX_NOACTIVATE | WS_EX_NOINHERITLAYOUT |
                                WS_EX_LAYERED,
                            kCandidateWindowClass, L"", WS_POPUP, 0, 0, 0, 0,
                            nullptr, nullptr, instance, this);
  if (window_ != nullptr) {
    SetLayeredWindowAttributes(window_, 0, 255, LWA_ALPHA);
  }
  return window_ != nullptr;
}

int CandidateWindow::HitIndex(int x_px, int y_px) const noexcept {
  const unsigned dpi = WindowDpi(window_);
  const float x = static_cast<float>(x_px) * 96.0f / static_cast<float>(dpi);
  const float y = static_cast<float>(y_px) * 96.0f / static_cast<float>(dpi);
  if (x < 0 || y < 0 || x >= layout_width_dip_ || y >= layout_height_dip_)
    return -1;
  for (std::size_t i = 0; i < hit_pills_.size(); ++i)
    if (hit_pills_[i].contains(x, y)) return static_cast<int>(i);
  return -1;
}

void CandidateWindow::Update(const CandidateSnapshot& snapshot) noexcept {
  if (!snapshot.visible ||
      (snapshot.items.empty() && snapshot.composition.empty())) {
    Hide();
    return;
  }
  try {
    if (snapshot_.composition != snapshot.composition ||
        snapshot_.items != snapshot.items ||
        snapshot_.page_start != snapshot.page_start) {
      pressed_index_ = -1;
      hover_index_ = -1;
      if (window_ && GetCapture() == window_) ReleaseCapture();
    }
    snapshot_ = snapshot;
    PublishSnapshot(snapshot_);
    if (EnsureWindow()) LayoutAndShow(snapshot_);
  } catch (...) {
    Hide();
  }
}

void CandidateWindow::LayoutAndShow(
    const CandidateSnapshot& snapshot) {
  const unsigned int dpi = WindowDpi(window_);
  const auto metrics = ui::MakeCandidateMetrics(font_size_);
  const ScreenRect work = WorkAreaFromCaret(snapshot.caret_rect);
  const float available_dip =
      static_cast<float>(work.width()) * 96.0f / static_cast<float>(dpi);

  HDC device = GetDC(window_);
  const int cand_px = ui::ScaleDip(metrics.candidate_font_dip, dpi);
  const int label_px = ui::ScaleDip(metrics.label_font_dip, dpi);
  const int ann_px = ui::ScaleDip(metrics.annotation_font_dip, dpi);
  const int pre_px = ui::ScaleDip(metrics.preedit_font_dip, dpi);
  HFONT cand_bold = MakeFont(cand_px, FW_SEMIBOLD, false);
  HFONT label_font = MakeFont(label_px, FW_SEMIBOLD, false);
  HFONT ann_font = MakeFont(ann_px, FW_NORMAL, false);
  HFONT pre_font = MakeFont(pre_px, FW_NORMAL, true);

  std::vector<ui::CandidateStripItem> items;
  items.reserve(snapshot.items.size());
  for (const auto& item : snapshot.items) {
    ui::CandidateStripItem out;
    out.label = item.label;
    if (out.label.empty()) {
      const wchar_t key =
          CandidateSelectionKey(item.label, items.size());
      if (key != 0) out.label.assign(1, key);
    }
    out.text = item.text;
    out.comment = item.comment;
    // Always reserve semibold width so selection never shifts layout.
    int width_px = 0;
    if (device) {
      if (!out.label.empty()) {
        width_px += MeasureText(device, label_font, out.label);
        width_px += ui::ScaleDip(4, dpi);
      }
      width_px += MeasureText(device, cand_bold, out.text);
      if (!out.comment.empty()) {
        width_px += ui::ScaleDip(6, dpi);
        width_px += MeasureText(device, ann_font, out.comment);
      }
    } else {
      width_px = static_cast<int>((out.label.size() + out.text.size() +
                                   out.comment.size()) *
                                  cand_px * 0.6);
    }
    out.content_width_dip =
        static_cast<int>(std::ceil(static_cast<float>(width_px) * 96.0f /
                                  static_cast<float>(dpi)));
    items.push_back(std::move(out));
  }

  float preedit_w_dip = 0;
  const bool show_preedit = !snapshot.composition.empty();
  if (show_preedit && device) {
    const int w = MeasureText(device, pre_font, snapshot.composition);
    preedit_w_dip =
        static_cast<float>(w) * 96.0f / static_cast<float>(dpi);
  }

  if (device) ReleaseDC(window_, device);
  if (cand_bold) DeleteObject(cand_bold);
  if (label_font) DeleteObject(label_font);
  if (ann_font) DeleteObject(ann_font);
  if (pre_font) DeleteObject(pre_font);

  const auto layout = ui::LayoutCandidateStripMeasured(
      items, preedit_w_dip, show_preedit, metrics, available_dip, vertical_,
      static_cast<float>(work.height()) * 96.f / static_cast<float>(dpi));
  hit_pills_ = layout.pills;
  layout_width_dip_ = layout.width_dip;
  layout_height_dip_ = layout.height_dip;
  preedit_dip_ = layout.preedit;
  show_preedit_ = layout.show_preedit;

  const long width = (std::max)(
      1L, static_cast<long>(ui::ScaleDipF(layout.width_dip, dpi) + 0.5f));
  const long height = (std::max)(
      1L, static_cast<long>(ui::ScaleDipF(layout.height_dip, dpi) + 0.5f));
  const ScreenRect caret{snapshot.caret_rect.left, snapshot.caret_rect.top,
                         snapshot.caret_rect.right, snapshot.caret_rect.bottom};
  const ScreenPoint origin = PlaceCandidateWindow(caret, width, height, work,
                            ui::ScaleDip(metrics.caret_gap_dip, dpi));
  snapshot_.window_rect = ToRect(origin, width, height);
  PublishSnapshot(snapshot_);

  // A union of the two rounded surfaces leaves the gap and outer corners
  // transparent. GDI on a layered HWND otherwise fills the entire rectangle.
  auto rounded_region = [dpi](const ui::DipRect& r, int radius) {
    const float scale = static_cast<float>(dpi) / 96.f;
    return CreateRoundRectRgn(static_cast<int>(std::lround(r.left * scale)),
        static_cast<int>(std::lround(r.top * scale)),
        static_cast<int>(std::lround(r.right * scale)) + 1,
        static_cast<int>(std::lround(r.bottom * scale)) + 1,
        ui::ScaleDip(radius * 2, dpi), ui::ScaleDip(radius * 2, dpi));
  };
  HRGN region = nullptr;
  if (!snapshot.items.empty()) region = rounded_region(layout.strip, metrics.strip_radius_dip);
  if (layout.show_preedit) {
    HRGN preedit = rounded_region(layout.preedit, metrics.preedit_radius_dip);
    if (region && preedit) {
      CombineRgn(region, region, preedit, RGN_OR);
      DeleteObject(preedit);
    } else if (preedit) {
      region = preedit;
    }
  }
  if (region && !SetWindowRgn(window_, region, FALSE)) DeleteObject(region);
  SetWindowPos(window_, HWND_TOPMOST, origin.x, origin.y, width, height,
               SWP_NOACTIVATE | SWP_SHOWWINDOW);
  InvalidateRect(window_, nullptr, TRUE);
}

void CandidateWindow::Paint(HDC device) const {
  RECT client{};
  GetClientRect(window_, &client);
  const unsigned dpi = WindowDpi(window_);
  const auto& palette = ui::Palette(theme_);
  const auto metrics = ui::MakeCandidateMetrics(font_size_);

  HDC mem = CreateCompatibleDC(device);
  HBITMAP bitmap =
      CreateCompatibleBitmap(device, client.right, client.bottom);
  HGDIOBJ old_bmp = SelectObject(mem, bitmap);
  ui::FillRectColor(mem, client, ui::ToColorRef(palette.candidate));

  const float scale = static_cast<float>(dpi) / 96.0f;
  auto to_px = [&](const ui::DipRect& r) {
    RECT out{};
    out.left = static_cast<LONG>(r.left * scale + 0.5f);
    out.top = static_cast<LONG>(r.top * scale + 0.5f);
    out.right = static_cast<LONG>(r.right * scale + 0.5f);
    out.bottom = static_cast<LONG>(r.bottom * scale + 0.5f);
    return out;
  };

  if (show_preedit_) {
    RECT pre = to_px(preedit_dip_);
    ui::FillRoundRect(mem, pre, ui::ScaleDip(metrics.preedit_radius_dip, dpi),
                      ui::ToColorRef(palette.candidate));
    ui::StrokeRoundRect(mem, pre, ui::ScaleDip(metrics.preedit_radius_dip, dpi),
                        ui::ToColorRef(palette.border_strong));
    HFONT pre_font =
        MakeFont(ui::ScaleDip(metrics.preedit_font_dip, dpi), FW_NORMAL, true);
    HFONT prev = static_cast<HFONT>(SelectObject(mem, pre_font));
    SetBkMode(mem, TRANSPARENT);
    SetTextColor(mem, ui::ToColorRef(palette.text_primary));
    RECT text = pre;
    text.left += ui::ScaleDip(metrics.preedit_inset_dip, dpi);
    text.right -= ui::ScaleDip(metrics.preedit_inset_dip, dpi);
    DrawTextW(mem, snapshot_.composition.c_str(),
              static_cast<int>(snapshot_.composition.size()), &text,
              DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX | DT_END_ELLIPSIS);
    SelectObject(mem, prev);
    DeleteObject(pre_font);
  }

  // Strip background covering all rows.
  if (!snapshot_.items.empty()) {
    ui::DipRect strip{0,
                      show_preedit_ ? preedit_dip_.bottom +
                                          static_cast<float>(metrics.preedit_gap_dip)
                                    : 0.0f,
                      layout_width_dip_, layout_height_dip_};
    RECT strip_px = to_px(strip);
    ui::FillRoundRect(mem, strip_px, ui::ScaleDip(metrics.strip_radius_dip, dpi),
                      ui::ToColorRef(palette.candidate));
    ui::StrokeRoundRect(mem, strip_px,
                        ui::ScaleDip(metrics.strip_radius_dip, dpi),
                        ui::ToColorRef(palette.border_strong));
  }

  const int cand_px = ui::ScaleDip(metrics.candidate_font_dip, dpi);
  const int label_px = ui::ScaleDip(metrics.label_font_dip, dpi);
  const int ann_px = ui::ScaleDip(metrics.annotation_font_dip, dpi);
  HFONT label_font = MakeFont(label_px, FW_SEMIBOLD, false);
  HFONT cand_font = MakeFont(cand_px, FW_NORMAL, false);
  HFONT cand_bold = MakeFont(cand_px, FW_SEMIBOLD, false);
  HFONT ann_font = MakeFont(ann_px, FW_NORMAL, false);

  for (std::size_t i = 0; i < snapshot_.items.size() && i < hit_pills_.size();
       ++i) {
    RECT pill = to_px(hit_pills_[i]);
    const bool selected =
        snapshot_.highlighted != 0xffff &&
        i == static_cast<std::size_t>(snapshot_.highlighted);
    const bool hovered = hover_index_ >= 0 &&
                         i == static_cast<std::size_t>(hover_index_) && !selected;
    if (selected) {
      ui::FillRoundRect(mem, pill, ui::ScaleDip(metrics.pill_radius_dip, dpi),
                        ui::ToColorRef(palette.selection));
    } else if (hovered) {
      ui::FillRoundRect(mem, pill, ui::ScaleDip(metrics.pill_radius_dip, dpi),
                        ui::ToColorRef(palette.surface_tertiary));
      ui::StrokeRoundRect(mem, pill, ui::ScaleDip(metrics.pill_radius_dip, dpi),
                          ui::ToColorRef(palette.border));
    }

    std::wstring label = snapshot_.items[i].label;
    if (label.empty()) {
      const wchar_t key = CandidateSelectionKey(label, i);
      if (key) label.assign(1, key);
    }
    RECT cursor = pill;
    cursor.left += ui::ScaleDip(metrics.pill_padding_dip, dpi);
    cursor.right -= ui::ScaleDip(metrics.pill_padding_dip, dpi);
    SetBkMode(mem, TRANSPARENT);
    if (!label.empty()) {
      SetTextColor(mem, ui::ToColorRef(selected ? palette.selection_text
                                                : palette.text_secondary));
      HFONT prev = static_cast<HFONT>(SelectObject(mem, label_font));
      DrawTextW(mem, label.c_str(), static_cast<int>(label.size()), &cursor,
                DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX | DT_END_ELLIPSIS);
      SIZE size{};
      GetTextExtentPoint32W(mem, label.c_str(), static_cast<int>(label.size()),
                            &size);
      SelectObject(mem, prev);
      cursor.left += size.cx + ui::ScaleDip(4, dpi);
    }
    {
      HFONT use = selected ? cand_bold : cand_font;
      HFONT prev = static_cast<HFONT>(SelectObject(mem, use));
      SetTextColor(mem, ui::ToColorRef(selected ? palette.selection_text
                                                : palette.text_primary));
      DrawTextW(mem, snapshot_.items[i].text.c_str(),
                static_cast<int>(snapshot_.items[i].text.size()), &cursor,
                DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX | DT_END_ELLIPSIS);
      SIZE size{};
      GetTextExtentPoint32W(mem, snapshot_.items[i].text.c_str(),
                            static_cast<int>(snapshot_.items[i].text.size()),
                            &size);
      SelectObject(mem, prev);
      cursor.left += size.cx;
    }
    if (!snapshot_.items[i].comment.empty()) {
      cursor.left += ui::ScaleDip(6, dpi);
      HFONT prev = static_cast<HFONT>(SelectObject(mem, ann_font));
      SetTextColor(mem, ui::ToColorRef(selected ? palette.selection_text
                                                : palette.text_muted));
      DrawTextW(mem, snapshot_.items[i].comment.c_str(),
                static_cast<int>(snapshot_.items[i].comment.size()), &cursor,
                DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX |
                    DT_END_ELLIPSIS);
      SelectObject(mem, prev);
    }
  }

  HFONT separator_font = MakeFont(label_px, FW_NORMAL, false);
  HFONT previous_separator = static_cast<HFONT>(SelectObject(mem, separator_font));
  SetTextColor(mem, ui::ToColorRef(palette.border_strong));
  for (std::size_t i = 1; i < hit_pills_.size(); ++i) {
    const auto& before = hit_pills_[i - 1];
    const auto& after = hit_pills_[i];
    if (before.top != after.top) continue;
    RECT separator = to_px({before.right, before.top, after.left, after.bottom});
    DrawTextW(mem, L"|", 1, &separator,
              DT_CENTER | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX);
  }
  SelectObject(mem, previous_separator);
  DeleteObject(separator_font);

  if (label_font) DeleteObject(label_font);
  if (cand_font) DeleteObject(cand_font);
  if (cand_bold) DeleteObject(cand_bold);
  if (ann_font) DeleteObject(ann_font);

  BitBlt(device, 0, 0, client.right, client.bottom, mem, 0, 0, SRCCOPY);
  SelectObject(mem, old_bmp);
  DeleteObject(bitmap);
  DeleteDC(mem);
}

LRESULT CALLBACK CandidateWindow::WindowProcedure(HWND window, UINT message,
                                                  WPARAM wparam,
                                                  LPARAM lparam) {
  CandidateWindow* self = nullptr;
  if (message == WM_NCCREATE) {
    const auto* create = reinterpret_cast<CREATESTRUCTW*>(lparam);
    self = static_cast<CandidateWindow*>(create->lpCreateParams);
    SetWindowLongPtrW(window, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(self));
    using EnableNonClientDpiScalingFn = BOOL(WINAPI*)(HWND);
    const HMODULE user32 = GetModuleHandleW(L"user32.dll");
    if (user32 != nullptr) {
      const auto enable = reinterpret_cast<EnableNonClientDpiScalingFn>(
          GetProcAddress(user32, "EnableNonClientDpiScaling"));
      if (enable != nullptr) enable(window);
    }
  } else {
    self = reinterpret_cast<CandidateWindow*>(
        GetWindowLongPtrW(window, GWLP_USERDATA));
  }

  switch (message) {
    case WM_PAINT: {
      PAINTSTRUCT paint{};
      const HDC device = BeginPaint(window, &paint);
      if (self != nullptr && device != nullptr) {
        try { self->Paint(device); } catch (...) { self->Hide(); }
      }
      EndPaint(window, &paint);
      return 0;
    }
    case WM_MOUSEMOVE:
      if (self) {
        const int hit = self->HitIndex(static_cast<short>(LOWORD(lparam)),
                                       static_cast<short>(HIWORD(lparam)));
        if (hit != self->hover_index_) {
          self->hover_index_ = hit;
          InvalidateRect(window, nullptr, FALSE);
        }
        TRACKMOUSEEVENT track{};
        track.cbSize = sizeof(track);
        track.dwFlags = TME_LEAVE;
        track.hwndTrack = window;
        TrackMouseEvent(&track);
      }
      return 0;
    case WM_MOUSELEAVE:
      if (self && self->hover_index_ >= 0) {
        self->hover_index_ = -1;
        InvalidateRect(window, nullptr, FALSE);
      }
      return 0;
    case WM_LBUTTONDOWN:
      if (self && self->snapshot_.visible) {
        self->pressed_index_ = self->HitIndex(static_cast<short>(LOWORD(lparam)),
                                             static_cast<short>(HIWORD(lparam)));
        if (self->pressed_index_ >= 0) SetCapture(window);
      }
      return 0;
    case WM_LBUTTONUP:
      if (self) {
        const int pressed = self->pressed_index_;
        const int hit = self->HitIndex(static_cast<short>(LOWORD(lparam)),
                                       static_cast<short>(HIWORD(lparam)));
        self->pressed_index_ = -1;
        if (GetCapture() == window) ReleaseCapture();
        if (self->snapshot_.visible && self->select_ && hit >= 0 && hit == pressed) {
          try { self->select_(static_cast<std::size_t>(hit)); }
          catch (...) { self->Hide(); }
        }
      }
      return 0;
    case WM_CAPTURECHANGED:
    case WM_CANCELMODE:
      if (self) self->pressed_index_ = -1;
      return 0;
    case WM_DPICHANGED:
      if (self && self->snapshot_.visible) self->LayoutAndShow(self->snapshot_);
      return 0;
    case WM_MOUSEACTIVATE:
      return MA_NOACTIVATE;
    case WM_ERASEBKGND:
      return 1;
    default:
      break;
  }
  return DefWindowProcW(window, message, wparam, lparam);
}

}  // namespace rimes::windows::tsf
