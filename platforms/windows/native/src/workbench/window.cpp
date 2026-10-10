#include "rimes_version.hpp"
#include "window.hpp"

#include <commctrl.h>
#include <d2d1.h>
#include <dwrite.h>
#include <shellapi.h>
#include <wtsapi32.h>

#include <algorithm>
#include <atomic>
#include <map>
#include <memory>
#include <string>
#include <thread>
#include <vector>

#include "../broker/autostart.hpp"
#include "../broker/default_paths.hpp"
#include "../ui/buffer_layout.hpp"
#include "../ui/buffer_paint.hpp"
#include "../ui/icons.hpp"
#include "../ui/menu_draw.hpp"
#include "../ui/theme.hpp"
#include "buffer_hotkey.hpp"
#include "buffer_anchor.hpp"
#include "settings_ui.hpp"

#pragma comment(lib, "comctl32.lib")

namespace rimes::windows::workbench {
namespace {
constexpr UINT kChanged = WM_APP + 80, kTray = WM_APP + 81;
constexpr UINT kOpenSettings = WM_APP + 82;
constexpr UINT kUpdateBufferZOrder = WM_APP + 83;
constexpr UINT kMaintenanceExit = WM_APP + 84;
constexpr int kToggle = 100, kSettings = 101, kDeploy = 102, kStartup = 103,
              kAbout = 105, kExit = 104, kPasteMenu = 106;
constexpr int kModeInput = 110, kModeGenerate = 111, kModeTranslate = 112;

std::wstring BufferHotkeyTitle(const Settings& settings) {
  const auto choice = BufferHotkeyChoiceIndex(settings.hotkey_modifiers);
  return std::wstring(choice >= 0 ? kBufferHotkeyChoices[static_cast<std::size_t>(choice)].label : L"") +
         static_cast<wchar_t>(settings.hotkey_key);
}

DWORD ForegroundProcess() {
  DWORD process = 0;
  GetWindowThreadProcessId(GetForegroundWindow(), &process);
  return process;
}

BufferRect DipFrame(const RECT& rect, double scale) {
  return {rect.left / scale, rect.top / scale,
          (static_cast<double>(rect.right) - rect.left) / scale,
          (static_cast<double>(rect.bottom) - rect.top) / scale};
}
BufferRect DipFrame(BufferRect rect, double scale) {
  return {rect.x / scale, rect.y / scale, rect.width / scale, rect.height / scale};
}
struct BufferMonitor {
  RECT work{};
  double scale = 1;
};
RECT BufferMonitorWorkArea(HMONITOR monitor) {
  MONITORINFO info{sizeof(info)};
  RECT work{};
  if (monitor && GetMonitorInfoW(monitor, &info)) work = info.rcWork;
  else SystemParametersInfoW(SPI_GETWORKAREA, 0, &work, 0);
  return work;
}
BufferMonitor BufferMonitorInfo(HMONITOR monitor) {
  BufferMonitor result;
  result.work = BufferMonitorWorkArea(monitor);
  // GetDpiForWindow on our own invisible PMv2 window measures the destination
  // display, even when the host or previous Buffer is on a different DPI.
  const HWND probe = CreateWindowExW(WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE,
      L"STATIC", L"", WS_POPUP, result.work.left, result.work.top, 1, 1,
      nullptr, nullptr, GetModuleHandleW(nullptr), nullptr);
  if (probe) {
    const auto dpi = GetDpiForWindow(probe);
    if (dpi) result.scale = static_cast<double>(dpi) / 96;
    DestroyWindow(probe);
  }
  return result;
}
HMONITOR BufferFallbackMonitor() {
  POINT mouse{};
  GetCursorPos(&mouse);
  return MonitorFromPoint(mouse, MONITOR_DEFAULTTOPRIMARY);
}
ui::BufferLayout WorkbenchLayout(const ui::BufferPaintState& paint, float width) {
  ui::BufferMetrics metrics;
  // Match macOS on work areas narrower than the normal readable minimum.
  metrics.min_width_dip = (std::min)(metrics.min_width_dip,
                                    (std::max)(1, static_cast<int>(width)));
  return ui::LayoutBuffer(paint, width, metrics);
}

struct Window {
  Runtime& runtime;
  std::function<void()> stop, deploy;
  UiCommands* commands = nullptr;
  UINT taskbar_created = RegisterWindowMessageW(L"TaskbarCreated");
  HWND window = nullptr;
  bool destroying = false;
  std::unique_ptr<SettingsUiHost> settings;
  std::atomic<HWND> notification{nullptr};
  ID2D1Factory* factory = nullptr;
  IDWriteFactory* write = nullptr;
  ID2D1HwndRenderTarget* render = nullptr;
  ID2D1SolidColorBrush* brush = nullptr;
  IDWriteTextFormat* format = nullptr;
  IDWriteTextFormat* label_format = nullptr;
  NOTIFYICONDATAW tray{};
  float scroll[2] = {0, 0};
  ui::BufferMode mode = ui::BufferMode::kInput;
  ui::ThemeId theme = ui::ThemeId::kNight;
  ui::BufferLayout last_layout{};
  ui::BufferHitKind pressed_hit = ui::BufferHitKind::kNone;
  int hover = -1;
  HWND tooltip = nullptr;
  std::jthread maintenance;
  std::atomic_bool deploying = false;
  HICON product_icon = nullptr;
  HFONT menu_font = nullptr;
  std::map<UINT, std::wstring> menu_labels;
  std::unique_ptr<BufferHotkeyRegistration> buffer_hotkey;
  std::uint64_t placed_opening_revision = 0;
  BufferOpeningSide opening_side = BufferOpeningSide::kBottomFallback;
  bool positioning = false;
  double positioning_scale = 1;
  RECT positioning_work{};

  Window(Runtime& r, std::function<void()> s, std::function<void()> d,
         UiCommands* c)
      : runtime(r), stop(std::move(s)), deploy(std::move(d)), commands(c) {}
  ~Window() {
    if (maintenance.joinable()) maintenance.join();
    if (product_icon) DestroyIcon(product_icon);
    if (menu_font) DeleteObject(menu_font);
    if (label_format) label_format->Release();
    if (format) format->Release();
    if (brush) brush->Release();
    if (render) render->Release();
    if (write) write->Release();
    if (factory) factory->Release();
  }

  ui::ThemeId ActiveTheme() const {
    return ui::ThemeIdOrDefault(runtime.Configuration().theme);
  }
  void EnsureSettings();
  void OpenSettings();
  void UpdateBufferZOrder();
  void Paint();
  void Update();
  void PositionForOpening(const core::Json& state);
  void Action(int index);
  void Copy();
  void Paste();
  void ApplyHit(ui::BufferHitKind hit);
  void PopupModeMenu();
  void PopupMoreMenu();
  void PopupTrayMenu();
  void AddTrayIcon();
  HMENU BuildOwnerMenu(const std::vector<ui::OwnerMenuItem>& items);
  void UpdateTooltip(int hit);
  ui::BufferPaintState MakePaintState(const core::Json& state) const;
  static LRESULT CALLBACK Procedure(HWND, UINT, WPARAM, LPARAM);
};

ui::BufferPaintState Window::MakePaintState(const core::Json& state) const {
  ui::BufferPaintState paint{};
  paint.theme = theme;
  paint.mode = mode;
  paint.busy = state.value("busy", false);
  paint.translate = state.value("translate", false);
  paint.capturing = state.value("capture", false);
  paint.bound = state.value("target_pid", 0) != 0;
  const auto status = state.value("status", std::string());
  static const std::map<std::string, std::wstring> messages = {
      {"Buffer", L"已绑定"}, {"Ready", L"结果就绪"},
      {"Copy only - no input target", L"未绑定：先选输入框，再点原文区"},
      {"Target changed. Rebind to send.", L"输入已暂停：点击原文区重新绑定"},
      {"Protected", L"已暂停"},
      {"Waiting for response...", L"等待响应…"},
      {"Receiving...", L"接收中…"},
      {"Processing stopped. Source retained.", L"已停止处理，原文已保留"},
      {"Request failed. Source retained.", L"请求失败，原文已保留"},
      {"Sending...", L"发送中…"}, {"Delivered", L"已发送"},
      {"Delivery failed. Content retained.", L"发送失败，内容已保留"},
      {"Delivery state changed. Check the target before retrying.",
       L"发送状态已变化，请先检查输入框"},
      {"Delivery unconfirmed. Check the target; automatic retry disabled.",
       L"发送未确认，请先检查输入框"},
      {"Paste exceeds Buffer capacity or delivery is pending.",
       L"粘贴内容过长，或正在发送"}};
  const auto message = messages.find(status);
  paint.status = message != messages.end() ? message->second : Wide(status);
  if (paint.status.empty())
    paint.status = paint.capturing ? L"已绑定" : L"等待输入框";
  const bool has_result = !state.value("result", std::string()).empty();
  const bool has_source = !state.value("source", std::string()).empty();
  if (has_result && !paint.translate)
    paint.status += L" · 待发结果已保留";
  paint.copy_enabled = has_result || has_source;
  paint.send_enabled = paint.capturing && paint.bound &&
                       !state.value("uncertain", false) &&
                       (has_result || has_source) &&
                       (!paint.busy || has_result) && status != "Sending...";
  if (mode == ui::BufferMode::kGenerate && !has_result)
    paint.send_enabled = has_source && !paint.busy &&
        state.value("preedit", std::string()).empty() && status != "Sending...";
  paint.paste_enabled = status != "Sending...";
  paint.preedit = Wide(state.value("preedit", std::string()));
  paint.preview = Wide(state.value("preview", std::string()));
  paint.scroll_source = scroll[0];
  paint.scroll_result = scroll[1];
  paint.hover = hover;
  paint.pressed = static_cast<int>(pressed_hit);
  paint.empty_hint = paint.capturing ? L"等待输入"
      : L"先点击宿主输入框，再点击这里开始输入（需选中 RIMES）";
  for (const auto& block : state["source_blocks"])
    paint.source_blocks.push_back(
        {Wide(block.value("text", std::string())), false});
  for (const auto& block : state["result_blocks"])
    paint.result_blocks.push_back(
        {Wide(block.value("text", std::string())), false});
  // Do NOT append preview into result_blocks — painter draws preview as the
  // single streaming tail to avoid duplicated waiting output.
  return paint;
}

void Window::EnsureSettings() {
  if (settings) return;
  SettingsUiCallbacks cb;
  cb.load = [this] { return runtime.Configuration(); };
  cb.save = [this](Settings value, const std::wstring& key, bool replace,
                   std::string* error) {
    const auto result = buffer_hotkey->Update(
        value.hotkey_modifiers, value.hotkey_key,
        [&] { return runtime.Configure(value, key, replace, error); });
    if (result == HotkeyUpdate::kInvalid) {
      if (error) *error = "快捷键必须为 Ctrl+Shift、Ctrl+Alt 或 Alt+Shift 加 A–Z 字母；设置未保存。";
      return false;
    }
    if (result == HotkeyUpdate::kUnavailable) {
      if (error) *error = Utf8(BufferHotkeyTitle(value) +
          (buffer_hotkey->Registered()
              ? L" 不可用，设置未保存；原快捷键仍有效。请选择其他组合或字母。"
              : L" 不可用，设置未保存。请使用托盘打开 Buffer，或选择其他组合或字母。"));
      return false;
    }
    if (result == HotkeyUpdate::kSaveFailed) return false;
    wcscpy_s(tray.szTip, L"RIMES 输入法与 Buffer");
    Shell_NotifyIconW(NIM_MODIFY, &tray);
    if (product_icon) {
      DestroyIcon(product_icon);
      product_icon = ui::CreateProductIcon(16);
      tray.hIcon =
          product_icon ? product_icon : LoadIconW(nullptr, IDI_APPLICATION);
      Shell_NotifyIconW(NIM_MODIFY, &tray);
    }
    InvalidateRect(window, nullptr, FALSE);
    return true;
  };
  cb.plugins = [this] { return runtime.Plugins(); };
  cb.manage_plugin = [this](const std::string& id, const std::string& action, std::string* error) { return runtime.ManagePlugin(id, action, error); };
  cb.plugin_status = [this] { return runtime.PluginStatus(); };
  cb.load_theme = [this] { return ActiveTheme(); };
  cb.on_theme_preview = [this](ui::ThemeId preview) {
    theme = preview;
    InvalidateRect(window, nullptr, FALSE);
  };
  cb.on_closed = [this] {
    // Settings' WM_DESTROY callback runs before DestroyWindow has finished.
    // Defer native placement until that operation has unwound; a reentrant
    // SetWindowPos can succeed without applying the topmost style change.
    if (!destroying && window)
      PostMessageW(window, kUpdateBufferZOrder, 0, 0);
  };
  cb.about_text = std::wstring(L"RIMES Windows ") + kProductVersionWide + L"\nCommit: " + Wide(RIMES_BUILD_COMMIT) +
                  L"\n协议 v2\n词库：%APPDATA%\\RIMES\n设置与日志：%LOCALAPPDATA%"
                  L"\\RIMES";
  settings = std::make_unique<SettingsUiHost>(std::move(cb));
}

void Window::OpenSettings() {
  // Settings revoke the old host's capture authority. They do not hide the
  // Buffer, consume its blocks, or cancel its source/configuration-frozen job.
  runtime.PauseCapture();
  EnsureSettings();
  // The host retains Settings' lifetime; this HWND is only a placement anchor.
  settings->Open(window);
  UpdateBufferZOrder();
}

void Window::UpdateBufferZOrder() {
  if (destroying || !window) return;
  constexpr UINT flags = SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE;
  const bool topmost =
      (GetWindowLongPtrW(window, GWL_EXSTYLE) & WS_EX_TOPMOST) != 0;
  if (settings && settings->IsOpen()) {
    // A retained Buffer must not cover the ordinary Settings window. Repeat
    // its relative placement after ShowWindow/stream updates, without making
    // Settings topmost or moving either window above other applications.
    if (topmost) SetWindowPos(window, HWND_NOTOPMOST, 0, 0, 0, 0, flags);
    SetWindowPos(window, settings->hwnd(), 0, 0, 0, 0, flags);
  } else if (!topmost) {
    // The deferred close message also restores a hidden Buffer without showing
    // it, activating it, or resuming its revoked capture authority.
    SetWindowPos(window, HWND_TOPMOST, 0, 0, 0, 0, flags);
  }
}

void Window::AddTrayIcon() {
  if (!Shell_NotifyIconW(NIM_ADD, &tray))
    Shell_NotifyIconW(NIM_MODIFY, &tray);
}

HMENU Window::BuildOwnerMenu(const std::vector<ui::OwnerMenuItem>& items) {
  HMENU menu = CreatePopupMenu();
  menu_labels.clear();
  for (const auto& item : items) {
    if (item.separator) {
      AppendMenuW(menu, MF_SEPARATOR | MF_OWNERDRAW, 0, nullptr);
      continue;
    }
    menu_labels[item.id] = item.text;
    UINT flags = MF_OWNERDRAW | (item.enabled ? 0 : MF_GRAYED);
    if (item.checked) flags |= MF_CHECKED;
    AppendMenuW(menu, flags, item.id, MAKEINTRESOURCEW(item.id));
  }
  return menu;
}

void Window::PopupModeMenu() {
  auto menu = BuildOwnerMenu({{kModeInput, L"输入", mode == ui::BufferMode::kInput},
                              {kModeGenerate, L"生成",
                               mode == ui::BufferMode::kGenerate},
                              {kModeTranslate, L"翻译",
                               mode == ui::BufferMode::kTranslate}});
  POINT cursor{};
  GetCursorPos(&cursor);
  const auto command =
      TrackPopupMenu(menu, TPM_RETURNCMD | TPM_NONOTIFY, cursor.x, cursor.y, 0,
                     window, nullptr);
  DestroyMenu(menu);
  if (command == kModeInput || command == kModeGenerate ||
      command == kModeTranslate) {
    // Selection is a real processing boundary, not an API request. Cancel
    // the previous automatic translation/queued producer first; reviewed
    // results and an issued insertion remain available for explicit sending.
    runtime.ReturnToInput();
    mode = command == kModeInput ? ui::BufferMode::kInput
        : command == kModeGenerate ? ui::BufferMode::kGenerate
                                   : ui::BufferMode::kTranslate;
    if (mode == ui::BufferMode::kGenerate) runtime.SelectAIMode();
  }
  InvalidateRect(window, nullptr, FALSE);
}

void Window::PopupMoreMenu() {
  auto menu = BuildOwnerMenu({{1, L"绑定 / 暂停"},
                              {kPasteMenu, L"粘贴"},
                              {2, L"生成"},
                              {3, L"翻译"},
                              {4, L"取消"},
                              {5, L"下一块"},
                              {6, L"全部发送"},
                              {0, L"", false, true},
                              {7, L"设置"}});
  POINT cursor{};
  GetCursorPos(&cursor);
  const auto command =
      TrackPopupMenu(menu, TPM_RETURNCMD | TPM_NONOTIFY, cursor.x, cursor.y, 0,
                     window, nullptr);
  DestroyMenu(menu);
  switch (command) {
    case 1:
      Action(0);
      break;
    case kPasteMenu:
      Paste();
      break;
    case 2:
      Action(2);
      break;
    case 3:
      Action(3);
      break;
    case 4:
      Action(4);
      break;
    case 5:
      Action(5);
      break;
    case 6:
      Action(6);
      break;
    case 7:
      Action(8);
      break;
    default:
      break;
  }
}

void Window::PopupTrayMenu() {
  std::wstring startup_command;
  bool startup_enabled = false;
  broker::QueryBrokerAutostart(&startup_command, &startup_enabled);
  auto menu = BuildOwnerMenu(
      {{kToggle, L"打开 / 绑定 Buffer"},
       {kSettings, L"设置"},
       {kDeploy, L"重新部署词库"},
       {kStartup, L"登录时启动", startup_enabled},
       {kAbout, L"版本与诊断"},
       {0, L"", false, true},
       {kExit, L"退出"}});
  POINT cursor{};
  GetCursorPos(&cursor);
  SetForegroundWindow(window);
  const auto command =
      TrackPopupMenu(menu, TPM_RETURNCMD | TPM_NONOTIFY, cursor.x, cursor.y, 0,
                     window, nullptr);
  DestroyMenu(menu);
  // The tray's foreground requirement can raise a demoted Buffer. Restore
  // its relative order even when the menu is cancelled and no action updates
  // the Runtime; never force Settings back above another application.
  UpdateBufferZOrder();
  PostMessageW(window, WM_COMMAND, command, 0);
}

void Window::UpdateTooltip(int hit) {
  if (!tooltip) return;
  const wchar_t* text = L"";
  switch (static_cast<ui::BufferHitKind>(hit)) {
    case ui::BufferHitKind::kMode:
      text = L"模式";
      break;
    case ui::BufferHitKind::kMore:
      text = L"更多";
      break;
    case ui::BufferHitKind::kClose:
      text = L"关闭";
      break;
    case ui::BufferHitKind::kPaste:
      text = L"粘贴";
      break;
    case ui::BufferHitKind::kCopy:
      text = L"复制";
      break;
    case ui::BufferHitKind::kSend:
      text = runtime.Snapshot().value("result", std::string()).empty()
                 ? L"发送下一块" : L"发送下一块待发结果";
      break;
    case ui::BufferHitKind::kBind:
      text = L"在当前输入框接收输入到 Buffer";
      break;
    default:
      break;
  }
  TOOLINFOW info{};
  info.cbSize = sizeof(info);
  info.hwnd = window;
  info.uId = 1;
  info.lpszText = const_cast<wchar_t*>(text);
  SendMessageW(tooltip, TTM_UPDATETIPTEXTW, 0, reinterpret_cast<LPARAM>(&info));
}

void Window::Copy() {
  auto snapshot = runtime.Snapshot();
  auto text = snapshot.value("result", std::string());
  if (text.empty()) text = snapshot.value("source", std::string());
  if (text.empty()) return;
  auto wide = Wide(text);
  if (!OpenClipboard(window)) return;
  HGLOBAL memory =
      GlobalAlloc(GMEM_MOVEABLE, (wide.size() + 1) * sizeof(wchar_t));
  if (memory) {
    auto* data = GlobalLock(memory);
    if (data) {
      memcpy(data, wide.c_str(), (wide.size() + 1) * sizeof(wchar_t));
      GlobalUnlock(memory);
      EmptyClipboard();
      if (!SetClipboardData(CF_UNICODETEXT, memory)) GlobalFree(memory);
    } else
      GlobalFree(memory);
  }
  CloseClipboard();
}

void Window::Paste() {
  if (!OpenClipboard(window)) return;
  auto memory = GetClipboardData(CF_UNICODETEXT);
  std::wstring text;
  if (memory) {
    const auto bytes = GlobalSize(memory);
    if (bytes <= Model::kLimit * 2) {
      auto* data = static_cast<const wchar_t*>(GlobalLock(memory));
      if (data) {
        const auto count = wcsnlen(data, bytes / sizeof(wchar_t));
        if (count < bytes / sizeof(wchar_t)) text.assign(data, count);
        GlobalUnlock(memory);
      }
    }
  }
  CloseClipboard();
  if (!text.empty()) runtime.Paste(Utf8(text));
}

void Window::Action(int index) {
  switch (index) {
    case 0:
      runtime.Toggle(ForegroundProcess());
      break;
    case 1:
      Paste();
      break;
    case 2:
      mode = ui::BufferMode::kGenerate;
      runtime.Generate(false);
      break;
    case 3:
      mode = ui::BufferMode::kTranslate;
      runtime.Generate(true);
      break;
    case 4:
      runtime.Cancel();
      break;
    case 5:
      runtime.Send(false);
      break;
    case 6:
      runtime.Send(true);
      break;
    case 7:
      Copy();
      break;
    case 8:
      OpenSettings();
      break;
    case 9:
      runtime.Close();
      break;
    default:
      break;
  }
}

void Window::ApplyHit(ui::BufferHitKind hit) {
  const auto state = MakePaintState(runtime.Snapshot());
  if ((hit == ui::BufferHitKind::kPaste && !state.paste_enabled) ||
      (hit == ui::BufferHitKind::kCopy && !state.copy_enabled) ||
      (hit == ui::BufferHitKind::kSend && !state.send_enabled))
    return;
  switch (hit) {
    case ui::BufferHitKind::kBind:
      runtime.Bind(ForegroundProcess());
      break;
    case ui::BufferHitKind::kMode:
      PopupModeMenu();
      break;
    case ui::BufferHitKind::kMore:
      PopupMoreMenu();
      break;
    case ui::BufferHitKind::kClose:
      runtime.Close();
      break;
    case ui::BufferHitKind::kPaste:
      Paste();
      break;
    case ui::BufferHitKind::kCopy:
      Copy();
      break;
    case ui::BufferHitKind::kSend:
      if (mode == ui::BufferMode::kGenerate && state.result_blocks.empty()) runtime.Generate(false);
      else runtime.Send(false);
      break;
    default:
      break;
  }
}

void Window::PositionForOpening(const core::Json& state) {
  const auto revision = state.value("opening_revision", 0ULL);
  const auto target = runtime.PlacementTarget();
  auto anchor = ProbeBufferInputAnchor(target.process);
  if (target != runtime.PlacementTarget()) anchor = {};
  HMONITOR monitor = BufferFallbackMonitor();
  if (anchor.caret && FiniteBufferRect(*anchor.caret) &&
      anchor.caret->x >= LONG_MIN && anchor.caret->x <= LONG_MAX &&
      anchor.caret->y >= LONG_MIN && anchor.caret->y <= LONG_MAX) {
    const POINT point{static_cast<LONG>(anchor.caret->x),
                       static_cast<LONG>(anchor.caret->y)};
    const auto candidate = MonitorFromPoint(point, MONITOR_DEFAULTTONULL);
    if (candidate) monitor = candidate;
  }
  auto display = BufferMonitorInfo(monitor);
  auto work = DipFrame(display.work, display.scale);
  if (anchor.caret && !PlausibleBufferCaret(DipFrame(*anchor.caret, display.scale), work)) {
    anchor = {};
    display = BufferMonitorInfo(BufferFallbackMonitor());
    work = DipFrame(display.work, display.scale);
  }
  RECT current_pixels{};
  GetWindowRect(window, &current_pixels);
  const double old_scale = static_cast<double>(GetDpiForWindow(window)) / 96;
  auto current = DipFrame(current_pixels, old_scale > 0 ? old_scale : 1);
  auto paint = MakePaintState(state);
  current.height = WorkbenchLayout(paint, static_cast<float>(current.width)).height_dip;
  const auto placement = BufferOpeningPlacement(current,
      anchor.caret ? std::optional(DipFrame(*anchor.caret, display.scale)) : std::nullopt,
      anchor.box ? std::optional(DipFrame(*anchor.box, display.scale)) : std::nullopt,
      work);
  positioning = true;
  positioning_scale = display.scale;
  positioning_work = display.work;
  SetWindowPos(window, nullptr,
      static_cast<int>(std::lround(placement.frame.x * display.scale)),
      static_cast<int>(std::lround(placement.frame.y * display.scale)),
      static_cast<int>(std::lround(placement.frame.width * display.scale)),
      static_cast<int>(std::lround(placement.frame.height * display.scale)),
      SWP_NOZORDER | SWP_NOACTIVATE);
  positioning = false;
  opening_side = placement.side;
  placed_opening_revision = revision;
}

void Window::Update() {
  if (runtime.Stopping()) {
    PostMessageW(window, WM_CLOSE, 0, 0);
    return;
  }
  // Keep unsaved settings theme preview while the settings host is open.
  if (!settings || !settings->IsOpen()) theme = ActiveTheme();
  auto state = runtime.Snapshot();
  if (state.value("visible", false) &&
      placed_opening_revision != state.value("opening_revision", 0ULL))
    PositionForOpening(state);
  ShowWindow(window,
             state.value("visible", false) ? SW_SHOWNOACTIVATE : SW_HIDE);
  if (state.value("visible", false)) {
    RECT rect{};
    GetClientRect(window, &rect);
    const float dpi = static_cast<float>(GetDpiForWindow(window)) / 96.0f;
    auto paint = MakePaintState(state);
    last_layout = WorkbenchLayout(paint, static_cast<float>(rect.right) / dpi);
    const float source_content = ui::MeasureBufferContent(
        write, format, paint.source_blocks, paint.preedit);
    const float result_content = ui::MeasureBufferContent(
        write, format, paint.result_blocks, paint.preview, false);
    scroll[0] = ui::ClampScroll(scroll[0], source_content,
                                last_layout.source_text.width());
    scroll[1] = ui::ClampScroll(scroll[1], result_content,
                                last_layout.result_text.width());
    RECT window_rect{};
    GetWindowRect(window, &window_rect);
    const int height =
        static_cast<int>(last_layout.height_dip * dpi + 0.5f);
    const int width = window_rect.right - window_rect.left;
    if (std::abs((window_rect.bottom - window_rect.top) - height) > 2) {
      const auto work = BufferMonitorWorkArea(MonitorFromWindow(window, MONITOR_DEFAULTTONEAREST));
      const auto frame = BufferResizedOutward(DipFrame(window_rect, dpi),
          static_cast<double>(height) / dpi, opening_side,
          DipFrame(work, dpi));
      SetWindowPos(window, nullptr, window_rect.left,
                   static_cast<int>(std::lround(frame.y * dpi)), width,
                   static_cast<int>(std::lround(frame.height * dpi)),
                   SWP_NOZORDER | SWP_NOACTIVATE);
    }
  }
  UpdateBufferZOrder();
  InvalidateRect(window, nullptr, FALSE);
}

void Window::Paint() {
  PAINTSTRUCT paint{};
  BeginPaint(window, &paint);
  RECT rect{};
  GetClientRect(window, &rect);
  if (!render) {
    factory->CreateHwndRenderTarget(
        D2D1::RenderTargetProperties(),
        D2D1::HwndRenderTargetProperties(
            window, D2D1::SizeU(static_cast<UINT32>(rect.right),
                                static_cast<UINT32>(rect.bottom))),
        &render);
    if (render) {
      const auto dpi = static_cast<float>(GetDpiForWindow(window));
      render->SetDpi(dpi, dpi);
      render->CreateSolidColorBrush(D2D1::ColorF(0, 0, 0), &brush);
    }
  }
  if (render && brush && format && label_format) {
    const auto dpi = static_cast<float>(GetDpiForWindow(window));
    const float width = static_cast<float>(rect.right) * 96.0f / dpi;
    auto state = runtime.Snapshot();
    auto paint_state = MakePaintState(state);
    last_layout = WorkbenchLayout(paint_state, width);
    render->BeginDraw();
    render->Clear(ui::ColorF(0, 0));
    ui::DrawBufferWorkbench(
        ui::BufferPaintContext{render, write, format, label_format, brush, dpi},
        paint_state, last_layout);
    if (render->EndDraw() == D2DERR_RECREATE_TARGET) {
      if (brush) brush->Release();
      brush = nullptr;
      render->Release();
      render = nullptr;
    }
  }
  EndPaint(window, &paint);
}

LRESULT CALLBACK Window::Procedure(HWND hwnd, UINT message, WPARAM wparam,
                                   LPARAM lparam) {
  auto* self =
      reinterpret_cast<Window*>(GetWindowLongPtrW(hwnd, GWLP_USERDATA));
  if (message == WM_NCCREATE) {
    self = static_cast<Window*>(
        reinterpret_cast<CREATESTRUCTW*>(lparam)->lpCreateParams);
    SetWindowLongPtrW(hwnd, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(self));
    self->window = hwnd;
  }
  if (!self) return DefWindowProcW(hwnd, message, wparam, lparam);
  try {
    if (self->taskbar_created && message == self->taskbar_created) {
      self->AddTrayIcon();
      return 0;
    }
    switch (message) {
      case WM_NCCALCSIZE:
        // Keep resize semantics without a native frame subtracting pixels
        // from the 73/105-DIP workbench client area.
        return 0;
      case WM_MOUSEACTIVATE:
        return MA_NOACTIVATE;
      case WM_WINDOWPOSCHANGING: {
        auto* position = reinterpret_cast<WINDOWPOS*>(lparam);
        if (position && !(position->flags & SWP_NOZORDER) &&
            !self->destroying && self->settings && self->settings->IsOpen()) {
          // Constrain native Z-order raises before Windows applies
          // them, including paths that produce no Runtime notification. Keep
          // coordinates and sizing flags intact; DefWindowProc still enforces
          // native thickframe constraints below. NOACTIVATE cannot be changed
          // here: Windows ignores changes to that flag in this message.
          position->hwndInsertAfter = self->settings->hwnd();
        }
        break;
      }
      case WM_PAINT:
        self->Paint();
        return 0;
      case WM_ERASEBKGND:
        return 1;
      case WM_HOTKEY:
        if (self->buffer_hotkey && self->buffer_hotkey->Matches(wparam, lparam))
          self->runtime.Toggle(ForegroundProcess());
        return 0;
      case kChanged:
        self->Update();
        return 0;
      case kOpenSettings:
        self->OpenSettings();
        return 0;
      case kMaintenanceExit:
        // Buffer is disposable IME UI. Stop transient provider work and the
        // input engine through the same shutdown path as the tray's Exit.
        DestroyWindow(hwnd);
        return 0;
      case kUpdateBufferZOrder:
        // Recheck the current lifetime: Settings may have reopened while this
        // close notification was queued, and shutdown must not restore it.
        self->UpdateBufferZOrder();
        return 0;
      case WM_TIMER:
        self->runtime.Tick();
        return 0;
      case WM_MEASUREITEM: {
        auto* measure = reinterpret_cast<MEASUREITEMSTRUCT*>(lparam);
        if (measure->CtlType == ODT_MENU) {
          const auto found = self->menu_labels.find(measure->itemID);
          const std::wstring text =
              found == self->menu_labels.end() ? L"" : found->second;
          return ui::MeasureOwnerMenu(measure, GetDpiForWindow(hwnd), text,
                                      measure->itemID == 0 && text.empty());
        }
        break;
      }
      case WM_DRAWITEM: {
        auto* draw = reinterpret_cast<DRAWITEMSTRUCT*>(lparam);
        if (draw->CtlType == ODT_MENU) {
          const auto found = self->menu_labels.find(draw->itemID);
          const std::wstring text =
              found == self->menu_labels.end() ? L"" : found->second;
          const bool separator = draw->itemID == 0 && text.empty();
          return ui::DrawOwnerMenu(draw, self->theme, text,
                                   (draw->itemState & ODS_CHECKED) != 0,
                                   separator, self->menu_font);
        }
        break;
      }
      case WM_DPICHANGED: {
        if (self->render)
          self->render->SetDpi(static_cast<float>(HIWORD(wparam)),
                               static_cast<float>(HIWORD(wparam)));
        auto* rect = reinterpret_cast<RECT*>(lparam);
        if (!self->positioning) SetWindowPos(hwnd, nullptr, rect->left, rect->top,
                     rect->right - rect->left, rect->bottom - rect->top,
                     SWP_NOZORDER | SWP_NOACTIVATE);
        if (self->menu_font) DeleteObject(self->menu_font);
        self->menu_font = CreateFontW(
            -MulDiv(12, HIWORD(wparam), 96), 0, 0, 0, FW_NORMAL, FALSE, FALSE,
            FALSE, DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
            CLEARTYPE_QUALITY, DEFAULT_PITCH, L"Segoe UI");
        return 0;
      }
      case WM_ENTERSIZEMOVE:
        // Manual placement takes precedence until the next explicit opening.
        self->opening_side = BufferOpeningSide::kBottomFallback;
        return 0;
      case WM_MOUSEMOVE: {
        const float dpi = static_cast<float>(GetDpiForWindow(hwnd)) / 96.0f;
        const float x =
            static_cast<float>(static_cast<short>(LOWORD(lparam))) / dpi;
        const float y =
            static_cast<float>(static_cast<short>(HIWORD(lparam))) / dpi;
        const auto hit = ui::HitTestBuffer(self->last_layout, x, y);
        const int next = static_cast<int>(hit);
        if (next != self->hover) {
          self->hover = next;
          self->UpdateTooltip(next);
          InvalidateRect(hwnd, nullptr, FALSE);
        }
        TRACKMOUSEEVENT track{sizeof(track), TME_LEAVE, hwnd, 0};
        TrackMouseEvent(&track);
        return 0;
      }
      case WM_SETCURSOR:
        if (LOWORD(lparam) == HTCLIENT) {
          POINT cursor{};
          GetCursorPos(&cursor);
          ScreenToClient(hwnd, &cursor);
          const float dpi = static_cast<float>(GetDpiForWindow(hwnd)) / 96.0f;
          const auto hit = ui::HitTestBuffer(self->last_layout,
              static_cast<float>(cursor.x) / dpi,
              static_cast<float>(cursor.y) / dpi);
          SetCursor(LoadCursorW(nullptr, hit == ui::BufferHitKind::kBind
              ? IDC_IBEAM : hit == ui::BufferHitKind::kNone ? IDC_ARROW : IDC_HAND));
          return TRUE;
        }
        break;
      case WM_MOUSELEAVE:
        if (self->hover >= 0 || self->pressed_hit != ui::BufferHitKind::kNone) {
          self->hover = -1;
          self->pressed_hit = ui::BufferHitKind::kNone;
          InvalidateRect(hwnd, nullptr, FALSE);
        }
        return 0;
      case WM_LBUTTONDOWN: {
        const float dpi = static_cast<float>(GetDpiForWindow(hwnd)) / 96.0f;
        const float x =
            static_cast<float>(static_cast<short>(LOWORD(lparam))) / dpi;
        const float y =
            static_cast<float>(static_cast<short>(HIWORD(lparam))) / dpi;
        self->pressed_hit = ui::HitTestBuffer(self->last_layout, x, y);
        InvalidateRect(hwnd, nullptr, FALSE);
        return 0;
      }
      case WM_LBUTTONUP: {
        const float dpi = static_cast<float>(GetDpiForWindow(hwnd)) / 96.0f;
        const float x =
            static_cast<float>(static_cast<short>(LOWORD(lparam))) / dpi;
        const float y =
            static_cast<float>(static_cast<short>(HIWORD(lparam))) / dpi;
        const auto hit = ui::HitTestBuffer(self->last_layout, x, y);
        const auto pressed = self->pressed_hit;
        self->pressed_hit = ui::BufferHitKind::kNone;
        InvalidateRect(hwnd, nullptr, FALSE);
        if (hit != ui::BufferHitKind::kNone && hit == pressed)
          self->ApplyHit(hit);
        return 0;
      }
      case WM_MOUSEWHEEL: {
        POINT point{static_cast<short>(LOWORD(lparam)),
                    static_cast<short>(HIWORD(lparam))};
        ScreenToClient(hwnd, &point);
        const float dpi = static_cast<float>(GetDpiForWindow(hwnd)) / 96.0f;
        const float x = static_cast<float>(point.x) / dpi;
        const float y = static_cast<float>(point.y) / dpi;
        const int lane = self->last_layout.show_result &&
                                 self->last_layout.result_rail.contains(x, y)
                             ? 1
                             : 0;
        auto state = self->runtime.Snapshot();
        auto paint = self->MakePaintState(state);
        const float content =
            lane == 0 ? ui::MeasureBufferContent(self->write, self->format,
                                                 paint.source_blocks,
                                                 paint.preedit)
                      : ui::MeasureBufferContent(self->write, self->format,
                                                 paint.result_blocks,
                                                 paint.preview, false);
        const float visible = lane == 0 ? self->last_layout.source_text.width()
                                        : self->last_layout.result_text.width();
        self->scroll[lane] = ui::ClampScroll(
            self->scroll[lane] -
                static_cast<float>(GET_WHEEL_DELTA_WPARAM(wparam)) /
                    WHEEL_DELTA * 40.0f,
            content, visible);
        InvalidateRect(hwnd, nullptr, FALSE);
        return 0;
      }
      case WM_GETMINMAXINFO: {
        auto* limits = reinterpret_cast<MINMAXINFO*>(lparam);
        const int dpi = self->positioning
            ? static_cast<int>(std::lround(self->positioning_scale * 96))
            : static_cast<int>(GetDpiForWindow(hwnd));
        const auto work = self->positioning ? self->positioning_work
            : BufferMonitorWorkArea(MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST));
        const int available = static_cast<int>(BufferSafeWorkArea(
            DipFrame(work, static_cast<double>(dpi) / 96)).width);
        limits->ptMinTrackSize = {MulDiv((std::min)(520, available), dpi, 96), MulDiv(35, dpi, 96)};
        limits->ptMaxTrackSize = {MulDiv(1100, dpi, 96), MulDiv(400, dpi, 96)};
        return 0;
      }
      case WM_SIZE: {
        if (self->render)
          self->render->Resize(D2D1::SizeU(LOWORD(lparam), HIWORD(lparam)));
        const int dpi = static_cast<int>(GetDpiForWindow(hwnd));
        const int inset = MulDiv(2, dpi, 96);
        const int radius = MulDiv(22, dpi, 96);
        auto region = CreateRoundRectRgn(inset, inset,
                                         LOWORD(lparam) - inset + 1,
                                         HIWORD(lparam) - inset + 1,
                                         radius, radius);
        if (region && !SetWindowRgn(hwnd, region, TRUE)) DeleteObject(region);
        if (self->tooltip) {
          TOOLINFOW info{};
          info.cbSize = sizeof(info);
          info.hwnd = hwnd;
          info.uId = 1;
          GetClientRect(hwnd, &info.rect);
          SendMessageW(self->tooltip, TTM_NEWTOOLRECTW, 0,
                       reinterpret_cast<LPARAM>(&info));
        }
        return 0;
      }
      case WM_NCHITTEST: {
        POINT point{static_cast<short>(LOWORD(lparam)),
                    static_cast<short>(HIWORD(lparam))};
        ScreenToClient(hwnd, &point);
        const float dpi = static_cast<float>(GetDpiForWindow(hwnd)) / 96.0f;
        const float x = static_cast<float>(point.x) / dpi;
        const float y = static_cast<float>(point.y) / dpi;
        RECT client{};
        GetClientRect(hwnd, &client);
        if (x < 5.0f) return HTLEFT;
        if (x >= static_cast<float>(client.right) / dpi - 5.0f) return HTRIGHT;
        if (ui::BufferHitIsCaptionExcluded(
                ui::HitTestBuffer(self->last_layout, x, y)))
          return HTCLIENT;
        if (self->last_layout.toolbar.contains(x, y) &&
            !self->last_layout.mode_chip.contains(x, y) &&
            !self->last_layout.status_label.contains(x, y))
          return HTCAPTION;
        return HTCLIENT;
      }
      case kTray:
        if (lparam == WM_LBUTTONUP) {
          self->runtime.Toggle(ForegroundProcess());
          return 0;
        }
        if (lparam == WM_RBUTTONUP) {
          self->PopupTrayMenu();
          return 0;
        }
        break;
      case WM_COMMAND:
        switch (LOWORD(wparam)) {
          case kToggle:
            self->runtime.Bind(ForegroundProcess());
            break;
          case kSettings:
            self->OpenSettings();
            break;
          case kDeploy:
            if (!self->deploying.exchange(true)) {
              self->runtime.DiscardBuffer();
              self->maintenance = std::jthread([self] {
                self->deploy();
                self->deploying.store(false);
              });
            }
            break;
          case kStartup: {
            broker::DefaultBrokerPaths paths;
            std::wstring error, command;
            bool enabled = false;
            if (broker::QueryBrokerAutostart(&command, &enabled, &error)) {
              if (enabled)
                broker::RemoveBrokerAutostart(&error);
              else if (broker::ResolveDefaultBrokerPaths(&paths, &error))
                broker::InstallBrokerAutostart(paths.broker_exe.wstring(),
                                               &error);
            }
            if (!error.empty())
              MessageBoxW(hwnd, error.c_str(), L"RIMES", MB_OK);
            break;
          }
          case kAbout: {
            const auto about_text =
                std::wstring(L"RIMES Windows ") + kProductVersionWide + L"\nCommit: " + Wide(RIMES_BUILD_COMMIT) +
                L"\n协议 v2\n词库：%APPDATA%\\RIMES\n设置与日志：%LOCALAPPDATA%"
                L"\\RIMES";
            MessageBoxW(hwnd, about_text.c_str(), L"版本与诊断", MB_OK);
            break;
          }
          case kExit:
            DestroyWindow(hwnd);
            break;
          default:
            break;
        }
        return 0;
      case WM_WTSSESSION_CHANGE:
        if (wparam == WTS_SESSION_LOCK || wparam == WTS_SESSION_LOGOFF ||
            wparam == WTS_REMOTE_DISCONNECT || wparam == WTS_CONSOLE_DISCONNECT)
          self->runtime.Protect();
        return 0;
      case WM_POWERBROADCAST:
        if (wparam == PBT_APMSUSPEND) self->runtime.Protect();
        return TRUE;
      case WM_CLOSE:
        DestroyWindow(hwnd);
        return 0;
      case WM_DESTROY:
        self->destroying = true;
        if (self->commands) self->commands->Attach(nullptr);
        self->notification.store(nullptr);
        self->runtime.SetNotify({});
        if (self->buffer_hotkey) self->buffer_hotkey->Reset();
        WTSUnRegisterSessionNotification(hwnd);
        Shell_NotifyIconW(NIM_DELETE, &self->tray);
        self->settings.reset();
        self->runtime.Stop();
        self->stop();
        PostQuitMessage(0);
        return 0;
      default:
        break;
    }
  } catch (...) {
    self->runtime.Close();
  }
  return DefWindowProcW(hwnd, message, wparam, lparam);
}
}  // namespace

void UiCommands::Attach(HWND window) {
  std::lock_guard lock(mutex_);
  window_ = window;
}

bool UiCommands::RequestSettings() {
  std::lock_guard lock(mutex_);
  return window_ && PostMessageW(window_, kOpenSettings, 0, 0);
}

bool UiCommands::RequestExit() {
  std::lock_guard lock(mutex_);
  return window_ && PostMessageW(window_, kMaintenanceExit, 0, 0);
}

void RunWindow(Runtime& runtime, const std::function<void()>& stop,
               const std::function<void()>& deploy, UiCommands* commands,
               bool open_settings) {
  CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  struct Apartment {
    ~Apartment() { CoUninitialize(); }
  } apartment;
  SetThreadDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
  INITCOMMONCONTROLSEX icc{sizeof(icc), ICC_WIN95_CLASSES};
  InitCommonControlsEx(&icc);
  Window ui(runtime, stop, deploy, commands);
  if (FAILED(
          D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED, &ui.factory)) ||
      FAILED(DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED,
                                 __uuidof(IDWriteFactory),
                                 reinterpret_cast<IUnknown**>(&ui.write)))) {
    runtime.Stop();
    stop();
    return;
  }
  ui.write->CreateTextFormat(
      L"Microsoft YaHei UI", nullptr, DWRITE_FONT_WEIGHT_NORMAL,
      DWRITE_FONT_STYLE_NORMAL, DWRITE_FONT_STRETCH_NORMAL, 12, L"zh-CN",
      &ui.format);
  ui.write->CreateTextFormat(
      L"Segoe UI", nullptr, DWRITE_FONT_WEIGHT_SEMI_BOLD,
      DWRITE_FONT_STYLE_NORMAL, DWRITE_FONT_STRETCH_NORMAL, 10, L"zh-CN",
      &ui.label_format);
  if (ui.format) ui.format->SetWordWrapping(DWRITE_WORD_WRAPPING_NO_WRAP);
  if (ui.label_format)
    ui.label_format->SetWordWrapping(DWRITE_WORD_WRAPPING_NO_WRAP);
  WNDCLASSW wc{};
  wc.lpfnWndProc = Window::Procedure;
  wc.hInstance = GetModuleHandleW(nullptr);
  wc.lpszClassName = L"Rimes.Workbench";
  wc.hCursor = LoadCursorW(nullptr, IDC_ARROW);
  wc.hIcon = LoadIconW(wc.hInstance, MAKEINTRESOURCEW(IDI_RIMES));
  RegisterClassW(&wc);
  RECT area{};
  SystemParametersInfoW(SPI_GETWORKAREA, 0, &area, 0);
  const int dpi = [] {
    HDC dc = GetDC(nullptr);
    int v = dc ? GetDeviceCaps(dc, LOGPIXELSX) : 96;
    if (dc) ReleaseDC(nullptr, dc);
    return v ? v : 96;
  }();
  ui.menu_font =
      CreateFontW(-MulDiv(12, dpi, 96), 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE,
                  DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
                  CLEARTYPE_QUALITY, DEFAULT_PITCH, L"Segoe UI");
  HWND window = CreateWindowExW(
      WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW | WS_EX_TOPMOST, wc.lpszClassName,
      L"RIMES Buffer", WS_POPUP | WS_THICKFRAME,
      area.left + ((area.right - area.left) - MulDiv(680, dpi, 96)) / 2,
      area.bottom - MulDiv(120 + 73, dpi, 96), MulDiv(680, dpi, 96),
      MulDiv(73, dpi, 96), nullptr, nullptr, wc.hInstance, &ui);
  if (!window) {
    runtime.Stop();
    stop();
    return;
  }
  ui.notification.store(window);
  runtime.SetNotify([&ui] {
    auto handle = ui.notification.load();
    if (handle) PostMessageW(handle, kChanged, 0, 0);
  });
  auto config = runtime.Configuration();
  ui.theme = ui::ThemeIdOrDefault(config.theme);
  ui.buffer_hotkey = std::make_unique<BufferHotkeyRegistration>(window);
  ui.buffer_hotkey->RegisterInitial(config.hotkey_modifiers, config.hotkey_key);
  ui.product_icon = ui::CreateProductIcon(16);
  ui.tray.cbSize = sizeof(ui.tray);
  ui.tray.hWnd = window;
  ui.tray.uID = 1;
  ui.tray.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP;
  ui.tray.uCallbackMessage = kTray;
  ui.tray.hIcon =
      ui.product_icon ? ui.product_icon : LoadIconW(nullptr, IDI_APPLICATION);
  wcscpy_s(ui.tray.szTip, L"RIMES 输入法与 Buffer");
  if (!ui.buffer_hotkey->Registered())
    wcscpy_s(ui.tray.szTip, L"RIMES · Buffer 快捷键不可用，请使用托盘");
  ui.AddTrayIcon();
  if (!ui.buffer_hotkey->Registered()) {
    const auto notice = BufferHotkeyTitle(config) +
        L" 未能注册。仍可从托盘打开 Buffer，在设置中选择其他组合或字母。";
    wcscpy_s(ui.tray.szInfoTitle, L"Buffer 快捷键未启用");
    wcscpy_s(ui.tray.szInfo, notice.c_str());
    ui.tray.dwInfoFlags = NIIF_WARNING;
    ui.tray.uFlags |= NIF_INFO;
    Shell_NotifyIconW(NIM_MODIFY, &ui.tray);
    ui.tray.uFlags &= ~NIF_INFO;
    OutputDebugStringW(notice.c_str());
  }
  ui.tooltip = CreateWindowExW(0, TOOLTIPS_CLASSW, nullptr,
                               WS_POPUP | TTS_ALWAYSTIP | TTS_NOPREFIX, 0, 0, 0,
                               0, window, nullptr, wc.hInstance, nullptr);
  if (ui.tooltip) {
    TOOLINFOW info{};
    info.cbSize = sizeof(info);
    info.uFlags = TTF_SUBCLASS;
    info.hwnd = window;
    info.uId = 1;
    GetClientRect(window, &info.rect);
    info.lpszText = const_cast<wchar_t*>(L"");
    SendMessageW(ui.tooltip, TTM_ADDTOOLW, 0, reinterpret_cast<LPARAM>(&info));
  }
  WTSRegisterSessionNotification(window, NOTIFY_FOR_THIS_SESSION);
  SetTimer(window, 1, 100, nullptr);
  if (commands) commands->Attach(window);
  if (open_settings) ui.OpenSettings();
  MSG message{};
  while (GetMessageW(&message, nullptr, 0, 0) > 0) {
    if (ui.settings && ui.settings->HandleDialogMessage(&message)) continue;
    TranslateMessage(&message);
    DispatchMessageW(&message);
  }
}
}  // namespace rimes::windows::workbench
