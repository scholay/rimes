#include "settings_ui.hpp"

#include <dwmapi.h>

#include <algorithm>
#include <cmath>
#include <stdexcept>

#include "../ui/icons.hpp"
#include "../ui/theme.hpp"
#include "buffer_hotkey_config.hpp"

namespace rimes::windows::workbench {
namespace {

constexpr const wchar_t* kSchemas[] = {L"rime_ice", L"double_pinyin",
                                       L"double_pinyin_flypy", L"wubi86",
                                       L"english", L"my_combo"};

RECT DipToPx(const ui::DipRect& r, unsigned dpi) {
  RECT out{};
  out.left = static_cast<LONG>(r.left * dpi / 96.0f + 0.5f);
  out.top = static_cast<LONG>(r.top * dpi / 96.0f + 0.5f);
  out.right = static_cast<LONG>(r.right * dpi / 96.0f + 0.5f);
  out.bottom = static_cast<LONG>(r.bottom * dpi / 96.0f + 0.5f);
  return out;
}

void Place(HWND hwnd, const ui::DipRect& r, unsigned dpi, bool show) {
  if (!hwnd) return;
  const RECT px = DipToPx(r, dpi);
  SetWindowPos(hwnd, nullptr, px.left, px.top, px.right - px.left,
               px.bottom - px.top, SWP_NOZORDER | SWP_NOACTIVATE |
                                       (show ? SWP_SHOWWINDOW : SWP_HIDEWINDOW));
}

std::wstring GetText(HWND hwnd) {
  if (!hwnd) return {};
  std::wstring text(static_cast<std::size_t>(GetWindowTextLengthW(hwnd)) + 1,
                    L'\0');
  GetWindowTextW(hwnd, text.data(), static_cast<int>(text.size()));
  text.resize(wcslen(text.c_str()));
  return text;
}

}  // namespace

SettingsUiHost::SettingsUiHost(SettingsUiCallbacks callbacks)
    : callbacks_(std::move(callbacks)) {
  draft_.about_text = callbacks_.about_text;
}

SettingsUiHost::~SettingsUiHost() {
  if (hwnd_) DestroyWindow(hwnd_);
  fonts_.Release();
  if (edit_brush_) DeleteObject(edit_brush_);
}

void SettingsUiHost::SyncDraftFromConfig(const Settings& config) {
  draft_.schema_index = 0;
  for (int i = 0; i < 6; ++i) {
    if (config.schema == Utf8(std::wstring(kSchemas[i]))) draft_.schema_index = i;
  }
  draft_.theme = callbacks_.load_theme ? callbacks_.load_theme()
                                       : ui::ThemeIdOrDefault(config.theme);
  draft_.preview_theme = draft_.theme;
  draft_.theme_index = static_cast<int>(draft_.theme);
  draft_.theme_detail = -1;
  opened_theme_ = draft_.theme;
  draft_.ascii = config.ascii;
  draft_.traditional = config.traditional;
  draft_.ascii_punctuation = config.ascii_punctuation;
  draft_.font_size = config.font_size;
  draft_.candidate_count = config.candidate_count;
  draft_.vertical_candidates = config.vertical_candidates;
  draft_.hotkey_modifiers = config.hotkey_modifiers;
  draft_.hotkey = static_cast<wchar_t>(config.hotkey_key);
  draft_.base_url = Wide(config.base_url);
  draft_.model = Wide(config.model);
  draft_.ai_connector_index = config.ai_connector == "codex-cli" ? 1 : 0;
  draft_.codex_path = Wide(config.codex_path);
  draft_.codex_model = Wide(config.codex_model);
  draft_.target_language = Wide(config.target_language);
  draft_.api_key.clear();
  draft_.page = ui::SettingsPage::kInput;
  draft_.subpage = 0;
  draft_.keyboard_focus = false;
  draft_.hover = -1;
  if (!callbacks_.about_text.empty()) draft_.about_text = callbacks_.about_text;
}

void SettingsUiHost::Open(HWND owner) {
  owner_ = owner;
  if (hwnd_) {
    ShowWindow(hwnd_, SW_SHOWNORMAL);
    SetForegroundWindow(hwnd_);
    return;
  }
  if (callbacks_.load) SyncDraftFromConfig(callbacks_.load());
  saved_ = false;
  WNDCLASSW wc{};
  wc.lpfnWndProc = Procedure;
  wc.hInstance = GetModuleHandleW(nullptr);
  wc.lpszClassName = L"Rimes.SettingsHost";
  wc.hCursor = LoadCursorW(nullptr, IDC_ARROW);
  wc.hIcon = LoadIconW(wc.hInstance, MAKEINTRESOURCEW(IDI_RIMES));
  wc.hbrBackground = static_cast<HBRUSH>(GetStockObject(NULL_BRUSH));
  wc.style = CS_HREDRAW | CS_VREDRAW;
  RegisterClassW(&wc);

  dpi_ = 96;
  if (owner) dpi_ = GetDpiForWindow(owner);
  RECT client{0, 0, MulDiv(980, static_cast<int>(dpi_), 96),
              MulDiv(680, static_cast<int>(dpi_), 96)};
  AdjustWindowRectExForDpi(&client, WS_OVERLAPPEDWINDOW, FALSE, 0, dpi_);
  MONITORINFO monitor{sizeof(monitor)};
  GetMonitorInfoW(MonitorFromWindow(owner, MONITOR_DEFAULTTONEAREST), &monitor);
  const int width = (std::min)(client.right - client.left,
                               monitor.rcWork.right - monitor.rcWork.left);
  const int height = (std::min)(client.bottom - client.top,
                                monitor.rcWork.bottom - monitor.rcWork.top);
  const int left = monitor.rcWork.left +
                   (monitor.rcWork.right - monitor.rcWork.left - width) / 2;
  const int top = monitor.rcWork.top +
                  (monitor.rcWork.bottom - monitor.rcWork.top - height) / 2;
  hwnd_ = CreateWindowExW(
      0, wc.lpszClassName, L"RIMES 设置", WS_OVERLAPPEDWINDOW | WS_CLIPCHILDREN,
      left, top, width, height,
      // Use the Buffer only to select initial placement. A native owner would
      // make Settings inherit its topmost state. SettingsUiHost owns this
      // ordinary top-level window and destroys it when the Broker closes.
      nullptr, nullptr, wc.hInstance, this);
  if (!hwnd_) return;
  CreateOrUpdateChildren();
  SetTimer(hwnd_, 11, 500, nullptr);
  Relayout();
  ShowWindow(hwnd_, SW_SHOWNORMAL);
  SetForegroundWindow(hwnd_);
  draft_.focus = static_cast<int>(draft_.page);
  SetFocus(hwnd_);
}

void SettingsUiHost::Close(bool persist) {
  if (!hwnd_) return;
  if (persist && !CommitSave()) return;
  DestroyWindow(hwnd_);
}

bool SettingsUiHost::HandleDialogMessage(MSG* message) {
  if (!hwnd_ || (message->hwnd != hwnd_ && !IsChild(hwnd_, message->hwnd)))
    return false;
  if (message->message == WM_KEYDOWN) {
    draft_.keyboard_focus = true;
    const auto key = message->wParam;
    if ((message->hwnd == combo_hotkey_modifiers_ || message->hwnd == combo_connector_) &&
        (key == VK_RETURN || key == VK_ESCAPE) &&
        SendMessageW(message->hwnd, CB_GETDROPPEDSTATE, 0, 0))
      return false;  // Confirm/cancel the native popup before Save/Close.
    if (key == VK_ESCAPE ||
        (key >= '1' && key <= '6' && (GetKeyState(VK_CONTROL) & 0x8000))) {
      SendMessageW(hwnd_, WM_KEYDOWN, key, message->lParam);
      return true;
    }
    if (key == VK_TAB && (GetKeyState(VK_CONTROL) & 0x8000)) {
      draft_.subpage = 1 - draft_.subpage;
      draft_.focus = static_cast<int>(draft_.page);
      Relayout();
      SetFocus(hwnd_);
      return true;
    }
    if (key == VK_RETURN && GetFocus() != hwnd_) {
      Close(true);
      return true;
    }
    if (key == VK_TAB) {
      std::vector<HWND> controls;
      for (const auto control : {check_ascii_, check_trad_, check_punct_,
                                edit_font_, edit_candidate_count_, check_vertical_, combo_hotkey_modifiers_, edit_hotkey_, edit_base_,
                                edit_model_, edit_key_, edit_lang_, combo_connector_, edit_codex_path_, edit_codex_model_})
        if (control && IsWindowVisible(control)) controls.push_back(control);
      const bool back = (GetKeyState(VK_SHIFT) & 0x8000) != 0;
      const int sidebar = static_cast<int>(draft_.page);
      int grid = sidebar;
      if (draft_.subpage == 0 && draft_.page == ui::SettingsPage::kInput)
        grid = 100 + draft_.schema_index;
      if (draft_.subpage == 0 && draft_.page == ui::SettingsPage::kAppearance)
        grid = 200 + draft_.theme_index;
      auto focus_shell = [&](int next) {
        draft_.focus = next;
        SetFocus(hwnd_);
        InvalidateRect(hwnd_, nullptr, FALSE);
      };
      if (GetFocus() == hwnd_) {
        const int current = draft_.focus;
        if (!back) {
          if (current < ui::kSettingsPageCount && grid != sidebar) focus_shell(grid);
          else if (current >= 200 && current < 204) focus_shell(400 + current - 200);
          else if (current >= 400 && current < 404) focus_shell(300);
          else if (current < 300 && !controls.empty()) SetFocus(controls.front());
          else if (current < 300) focus_shell(300);
          else focus_shell(current == 300 ? 301 : sidebar);
        } else {
          if (current < ui::kSettingsPageCount) focus_shell(301);
          else if (current == 301) focus_shell(300);
          else if (current == 300 && grid >= 200 && grid < 204) focus_shell(400 + grid - 200);
          else if (current >= 400 && current < 404) focus_shell(200 + current - 400);
          else if (current == 300 && !controls.empty()) SetFocus(controls.back());
          else focus_shell(current == 300 ? grid : sidebar);
        }
        return true;
      }
      if (!controls.empty() && GetFocus() ==
          (back ? controls.front() : controls.back())) {
        focus_shell(back ? grid : 300);
        return true;
      }
    }
    // IsDialogMessage eats arrow/space keys for dialog navigation; the painted
    // sidebar/cards own these keys while focus is on the shell.
    if (GetFocus() == hwnd_) return false;
  }
  return IsDialogMessageW(hwnd_, message) != FALSE;
}

void SettingsUiHost::CreateOrUpdateChildren() {
  auto make_edit = [&](HWND* slot, bool secret) {
    if (*slot) return;
    *slot = CreateWindowExW(
        0, L"EDIT", L"",
        WS_CHILD | WS_TABSTOP | ES_AUTOHSCROLL | (secret ? ES_PASSWORD : 0), 0,
        0, 10, 10, hwnd_, nullptr, GetModuleHandleW(nullptr), nullptr);
  };
  auto make_check = [&](HWND* slot, const wchar_t* text, int id) {
    if (*slot) return;
    *slot = CreateWindowExW(0, L"BUTTON", text,
                            WS_CHILD | WS_TABSTOP | BS_OWNERDRAW, 0, 0, 10,
                            10, hwnd_, reinterpret_cast<HMENU>(static_cast<INT_PTR>(id)), GetModuleHandleW(nullptr),
                            nullptr);
  };
  make_edit(&edit_font_, false);
  make_edit(&edit_candidate_count_, false);
  make_edit(&edit_hotkey_, false);
  if (!combo_hotkey_modifiers_) {
    combo_hotkey_modifiers_ = CreateWindowExW(
        0, L"COMBOBOX", L"", WS_CHILD | WS_TABSTOP | WS_VSCROLL | CBS_DROPDOWNLIST,
        0, 0, 130, 130, hwnd_, reinterpret_cast<HMENU>(405),
        GetModuleHandleW(nullptr), nullptr);
    for (const auto& choice : kBufferHotkeyChoices)
      SendMessageW(combo_hotkey_modifiers_, CB_ADDSTRING, 0,
                   reinterpret_cast<LPARAM>(choice.label));
  }
  make_edit(&edit_base_, false);
  make_edit(&edit_codex_path_, false);
  make_edit(&edit_codex_model_, false);
  if (!combo_connector_) {
    combo_connector_ = CreateWindowExW(0, L"COMBOBOX", L"", WS_CHILD | WS_TABSTOP | WS_VSCROLL | CBS_DROPDOWNLIST,
        0, 0, 200, 130, hwnd_, reinterpret_cast<HMENU>(406), GetModuleHandleW(nullptr), nullptr);
    SendMessageW(combo_connector_, CB_ADDSTRING, 0, reinterpret_cast<LPARAM>(L"通用 OpenAI API"));
    SendMessageW(combo_connector_, CB_ADDSTRING, 0, reinterpret_cast<LPARAM>(L"Codex CLI（本机登录）"));
  }
  make_edit(&edit_model_, false);
  make_edit(&edit_key_, true);
  make_edit(&edit_lang_, false);
  make_check(&check_ascii_, L"英文直输", 401);
  make_check(&check_trad_, L"繁体转换", 402);
  make_check(&check_punct_, L"英文标点", 403);
  make_check(&check_vertical_, L"竖向排列候选", 404);
  SetWindowTextW(edit_font_, std::to_wstring(draft_.font_size).c_str());
  SetWindowTextW(edit_candidate_count_, std::to_wstring(draft_.candidate_count).c_str());
  SetWindowTextW(edit_hotkey_, std::wstring(1, draft_.hotkey).c_str());
  SendMessageW(combo_hotkey_modifiers_, CB_SETCURSEL,
               BufferHotkeyChoiceIndex(draft_.hotkey_modifiers), 0);
  SetWindowTextW(edit_base_, draft_.base_url.c_str());
  SetWindowTextW(edit_model_, draft_.model.c_str());
  SendMessageW(combo_connector_, CB_SETCURSEL, draft_.ai_connector_index, 0);
  SetWindowTextW(edit_codex_path_, draft_.codex_path.c_str());
  SetWindowTextW(edit_codex_model_, draft_.codex_model.c_str());
  SetWindowTextW(edit_key_, L"");
  SetWindowTextW(edit_lang_, draft_.target_language.c_str());
  for (std::size_t i = 0; i < plugin_labels_.size(); ++i) {
    auto make = [&](HWND& control, const wchar_t* kind, const wchar_t* title, DWORD style, int action) {
      control = CreateWindowExW(0, kind, title, WS_CHILD | style, 0, 0, 1, 1, hwnd_,
          reinterpret_cast<HMENU>(static_cast<INT_PTR>(action < 0 ? 0 : 5100 + static_cast<int>(i) * 3 + action)), GetModuleHandleW(nullptr), nullptr);
    };
    make(plugin_labels_[i], L"STATIC", L"", SS_LEFT, -1);
    make(plugin_install_[i], L"BUTTON", L"安装", WS_TABSTOP | BS_PUSHBUTTON, 0);
    make(plugin_enable_[i], L"BUTTON", L"启用", WS_TABSTOP | BS_PUSHBUTTON, 1);
    make(plugin_remove_[i], L"BUTTON", L"卸载", WS_TABSTOP | BS_PUSHBUTTON, 2);
  }
  plugin_status_ = CreateWindowExW(0, L"STATIC", L"", WS_CHILD | SS_LEFT, 0, 0, 1, 1, hwnd_, nullptr, GetModuleHandleW(nullptr), nullptr);
  UpdatePlugins(); ThemeEdits();
}

void SettingsUiHost::UpdatePlugins() {
  if (callbacks_.plugins) plugin_rows_ = callbacks_.plugins();
  for (std::size_t i = 0; i < plugin_labels_.size(); ++i) {
    if (i >= plugin_rows_.size()) continue;
    const auto& item = plugin_rows_[i];
    const auto name = item.id == "builtin.apple-translation" ? std::string("翻译") : item.name;
    const auto label = Wide(name + "  " + item.version + "\n" + (item.installed ? item.enabled ? "已启用" : "已停用" : "未安装"));
    SetWindowTextW(plugin_labels_[i], label.c_str());
    SetWindowTextW(plugin_install_[i], item.bundled ? L"恢复安装" : L"下载安装");
    EnableWindow(plugin_install_[i], !item.installed);
    SetWindowTextW(plugin_enable_[i], item.enabled ? L"停用" : L"启用");
    EnableWindow(plugin_enable_[i], item.installed);
  }
  if (callbacks_.plugin_status) SetWindowTextW(plugin_status_, Wide(callbacks_.plugin_status()).c_str());
}

void SettingsUiHost::ThemeEdits() {
  fonts_.Ensure(dpi_);
  const auto& p = ui::Palette(draft_.preview_theme);
  // Documented Windows 11 attributes; older systems keep the native fallback.
  const BOOL dark = p.dark ? TRUE : FALSE;
  const COLORREF caption = ui::ToColorRef(p.settings_background);
  const COLORREF text = ui::ToColorRef(p.text_primary);
  DwmSetWindowAttribute(hwnd_, DWMWA_USE_IMMERSIVE_DARK_MODE, &dark, sizeof(dark));
  DwmSetWindowAttribute(hwnd_, DWMWA_CAPTION_COLOR, &caption, sizeof(caption));
  DwmSetWindowAttribute(hwnd_, DWMWA_TEXT_COLOR, &text, sizeof(text));
  if (edit_brush_) DeleteObject(edit_brush_);
  edit_brush_ = CreateSolidBrush(ui::ToColorRef(p.surface));
  HWND edits[] = {edit_font_, edit_candidate_count_, check_vertical_, combo_hotkey_modifiers_, edit_hotkey_, edit_base_,
                  edit_model_, edit_key_, edit_lang_, combo_connector_, edit_codex_path_, edit_codex_model_};
  for (HWND edit : edits) {
    if (!edit) continue;
    SendMessageW(edit, WM_SETFONT, reinterpret_cast<WPARAM>(fonts_.control),
                 TRUE);
  }
  for (std::size_t i = 0; i < plugin_labels_.size(); ++i) {
    for (const auto control : {plugin_labels_[i], plugin_install_[i], plugin_enable_[i], plugin_remove_[i]})
      SendMessageW(control, WM_SETFONT, reinterpret_cast<WPARAM>(fonts_.body), TRUE);
  }
  SendMessageW(plugin_status_, WM_SETFONT, reinterpret_cast<WPARAM>(fonts_.body), TRUE);
  HWND checks[] = {check_ascii_, check_trad_, check_punct_, check_vertical_};
  for (HWND check : checks) {
    if (!check) continue;
    SendMessageW(check, WM_SETFONT, reinterpret_cast<WPARAM>(fonts_.body), TRUE);
  }
}

void SettingsUiHost::Relayout() {
  pressed_hit_ = -2;
  if (GetCapture() == hwnd_) ReleaseCapture();
  if (draft_.page != ui::SettingsPage::kAppearance || draft_.subpage != 0)
    draft_.theme_detail = -1;
  RECT client{};
  GetClientRect(hwnd_, &client);
  dpi_ = GetDpiForWindow(hwnd_);
  fonts_.Ensure(dpi_);
  const float width = static_cast<float>(client.right) * 96.0f /
                      static_cast<float>(dpi_);
  const float height = static_cast<float>(client.bottom) * 96.0f /
                       static_cast<float>(dpi_);
  layout_ = ui::LayoutSettings(width, height, draft_);
  ThemeEdits();

  const bool input = draft_.page == ui::SettingsPage::kInput && draft_.subpage == 1;
  const bool appearance = draft_.page == ui::SettingsPage::kAppearance && draft_.subpage == 1;
  const bool buffer = draft_.page == ui::SettingsPage::kBuffer && draft_.subpage == 0;
  const bool api = draft_.page == ui::SettingsPage::kApi && draft_.subpage == 0;
  auto place_edit = [&](HWND edit, ui::DipRect box, bool show) {
    if (show) {
      box.left += 8;
      box.right -= 8;
      box.top += 5;
      box.bottom -= 4;
    }
    Place(edit, box, dpi_, show);
  };

  place_edit(edit_font_, layout_.font_edit, appearance);
  place_edit(edit_candidate_count_, layout_.candidate_count_edit, appearance);
  auto hotkey_dropdown = layout_.hotkey_modifiers;
  hotkey_dropdown.bottom += 96.0f;  // Native combo's height also owns its popup.
  Place(combo_hotkey_modifiers_, hotkey_dropdown, dpi_, buffer);
  place_edit(edit_hotkey_, layout_.hotkey_edit, buffer);
  place_edit(edit_base_, layout_.base_edit, api);
  auto connector_dropdown = layout_.connector_combo;
  connector_dropdown.bottom += 96.0f;
  Place(combo_connector_, connector_dropdown, dpi_, api);
  place_edit(edit_codex_path_, layout_.codex_path_edit, api);
  place_edit(edit_codex_model_, layout_.codex_model_edit, api);
  place_edit(edit_model_, layout_.model_edit, api);
  place_edit(edit_key_, layout_.key_edit,
             draft_.page == ui::SettingsPage::kApi && draft_.subpage == 1);
  place_edit(edit_lang_, layout_.lang_edit, api);
  Place(check_ascii_, layout_.check_ascii, dpi_, input);
  Place(check_trad_, layout_.check_trad, dpi_, input);
  Place(check_punct_, layout_.check_punct, dpi_, input);
  Place(check_vertical_, layout_.check_vertical, dpi_, appearance);
  const bool plugins = draft_.page == ui::SettingsPage::kPlugins && draft_.subpage == 0;
  UpdatePlugins();
  for (std::size_t i = 0; i < plugin_labels_.size(); ++i) {
    const float y = layout_.body.top + static_cast<float>(i) * 78.0f;
    const float x = layout_.body.left; const bool visible = plugins && i < plugin_rows_.size();
    Place(plugin_labels_[i], {x,y,x+285,y+52}, dpi_, visible);
    Place(plugin_install_[i], {x+300,y+6,x+414,y+38}, dpi_, visible);
    Place(plugin_enable_[i], {x+426,y+6,x+510,y+38}, dpi_, visible);
    Place(plugin_remove_[i], {x+522,y+6,x+606,y+38}, dpi_, visible);
  }
  Place(plugin_status_, {layout_.body.left,layout_.body.top+320,layout_.body.right,layout_.body.top+370}, dpi_, plugins);
  InvalidateRect(hwnd_, nullptr, FALSE);
}

void SettingsUiHost::ApplyControlTheme() { ThemeEdits(); }

bool SettingsUiHost::CommitSave() {
  if (!callbacks_.save) return true;
  try {
    Settings config = callbacks_.load ? callbacks_.load() : Settings{};
    config.schema = Utf8(std::wstring(kSchemas[draft_.schema_index]));
    config.theme = ui::ThemeIdString(
        static_cast<ui::ThemeId>(draft_.theme_index));
    config.base_url = Utf8(GetText(edit_base_));
    config.model = Utf8(GetText(edit_model_));
    const auto connector = SendMessageW(combo_connector_, CB_GETCURSEL, 0, 0);
    if (connector != 0 && connector != 1) throw std::runtime_error("connector choice");
    config.ai_connector = connector == 1 ? "codex-cli" : "openai-compatible";
    config.codex_path = Utf8(GetText(edit_codex_path_));
    config.codex_model = Utf8(GetText(edit_codex_model_));
    config.target_language = Utf8(GetText(edit_lang_));
    const auto font_text = GetText(edit_font_);
    std::size_t parsed = 0;
    config.font_size = static_cast<unsigned>(std::stoul(font_text, &parsed));
    if (parsed != font_text.size()) throw std::runtime_error("font range");
    const auto count_text = GetText(edit_candidate_count_);
    config.candidate_count = static_cast<unsigned>(std::stoul(count_text, &parsed));
    auto hotkey = GetText(edit_hotkey_);
    if (parsed != count_text.size() || config.candidate_count < 1 || config.candidate_count > 9 || config.font_size < 10 ||
        config.font_size > 40 || hotkey.size() != 1)
      throw std::runtime_error("range");
    config.hotkey_key = static_cast<unsigned>(towupper(hotkey[0]));
    const auto modifier_choice = SendMessageW(combo_hotkey_modifiers_, CB_GETCURSEL, 0, 0);
    if (modifier_choice < 0 || modifier_choice >= static_cast<LRESULT>(kBufferHotkeyChoices.size()))
      throw std::runtime_error("hotkey modifier choice");
    config.hotkey_modifiers = kBufferHotkeyChoices[static_cast<std::size_t>(modifier_choice)].modifiers;
    config.ascii = draft_.ascii;
    config.traditional = draft_.traditional;
    config.ascii_punctuation = draft_.ascii_punctuation;
    config.vertical_candidates = draft_.vertical_candidates;
    auto key = GetText(edit_key_);
    std::string error;
    const bool ok =
        callbacks_.save(config, key, !key.empty(), &error);
    if (!key.empty())
      SecureZeroMemory(key.data(), key.size() * sizeof(wchar_t));
    if (!ok) {
      MessageBoxW(hwnd_, Wide(error).c_str(), L"RIMES", MB_OK);
      return false;
    }
    draft_.theme = static_cast<ui::ThemeId>(draft_.theme_index);
    draft_.preview_theme = draft_.theme;
    opened_theme_ = draft_.theme;
    saved_ = true;
    if (callbacks_.on_theme_preview)
      callbacks_.on_theme_preview(draft_.theme);
    return true;
  } catch (...) {
    MessageBoxW(hwnd_, L"请检查输入方案、候选数（1–9）、字号和快捷键。", L"RIMES", MB_OK);
    return false;
  }
}

void SettingsUiHost::Paint(HDC dc) {
  RECT client{};
  if (!GetClientRect(hwnd_, &client) || client.right <= 0 || client.bottom <= 0)
    return;
  HDC frame = CreateCompatibleDC(dc);
  HBITMAP bitmap = frame
      ? CreateCompatibleBitmap(dc, client.right, client.bottom) : nullptr;
  if (!bitmap) {
    if (frame) DeleteDC(frame);
    ui::PaintSettingsShell(dc, layout_, draft_, fonts_, dpi_);
    return;
  }
  const auto previous = SelectObject(frame, bitmap);
  // Background clearing, text and highlights must reach the window together.
  // WM_ERASEBKGND alone cannot prevent a direct GDI clear/draw sequence from
  // exposing an empty intermediate frame when the mouse crosses navigation.
  ui::PaintSettingsShell(frame, layout_, draft_, fonts_, dpi_);
  BitBlt(dc, 0, 0, client.right, client.bottom, frame, 0, 0, SRCCOPY);
  SelectObject(frame, previous);
  DeleteObject(bitmap);
  DeleteDC(frame);
}

void SettingsUiHost::InvalidateHover(int hit) {
  const ui::DipRect* bounds = nullptr;
  if (hit >= 0 && hit < ui::kSettingsPageCount)
    bounds = &layout_.nav[static_cast<std::size_t>(hit)];
  else if (hit >= 100 && hit < 100 + static_cast<int>(layout_.scheme_cards.size()))
    bounds = &layout_.scheme_cards[static_cast<std::size_t>(hit - 100)];
  else if (hit >= 200 && hit < 200 + static_cast<int>(layout_.theme_cards.size()))
    bounds = &layout_.theme_cards[static_cast<std::size_t>(hit - 200)];
  else if (hit >= 400 && hit < 400 + static_cast<int>(layout_.theme_details.size()))
    bounds = &layout_.theme_details[static_cast<std::size_t>(hit - 400)];
  if (!bounds) return;
  auto rect = DipToPx(*bounds, dpi_);
  InflateRect(&rect, 2, 2);
  InvalidateRect(hwnd_, &rect, FALSE);
}

void SettingsUiHost::ActivateHit(int hit) {
  if (hit >= 0 && hit < ui::kSettingsPageCount) {
    draft_.page = static_cast<ui::SettingsPage>(hit);
    draft_.subpage = 0;
    draft_.focus = hit;
    Relayout();
  } else if (hit >= 500 && hit < 502) {
    draft_.subpage = hit - 500;
    draft_.focus = static_cast<int>(draft_.page);
    Relayout();
  } else if (hit >= 100 && hit < 106 &&
             draft_.page == ui::SettingsPage::kInput && draft_.subpage == 0) {
    draft_.schema_index = hit - 100;
    draft_.focus = hit;
    InvalidateRect(hwnd_, nullptr, FALSE);
  } else if (hit >= 200 && hit < 204 &&
             draft_.page == ui::SettingsPage::kAppearance && draft_.subpage == 0) {
    draft_.theme_index = hit - 200;
    draft_.theme_detail = -1;
    draft_.preview_theme = static_cast<ui::ThemeId>(draft_.theme_index);
    draft_.focus = hit;
    if (callbacks_.on_theme_preview) callbacks_.on_theme_preview(draft_.preview_theme);
    Relayout();
  } else if (hit >= 400 && hit < 404 &&
             draft_.page == ui::SettingsPage::kAppearance && draft_.subpage == 0) {
    draft_.theme_detail = draft_.theme_detail == hit - 400 ? -1 : hit - 400;
    draft_.focus = hit;
    Relayout();
  } else if (hit == 300) {
    Close(true);
  } else if (hit == 301) {
    Close(false);
  }
}

LRESULT CALLBACK SettingsUiHost::Procedure(HWND hwnd, UINT message,
                                           WPARAM wparam, LPARAM lparam) {
  auto* self =
      reinterpret_cast<SettingsUiHost*>(GetWindowLongPtrW(hwnd, GWLP_USERDATA));
  if (message == WM_NCCREATE) {
    self = static_cast<SettingsUiHost*>(
        reinterpret_cast<CREATESTRUCTW*>(lparam)->lpCreateParams);
    SetWindowLongPtrW(hwnd, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(self));
    self->hwnd_ = hwnd;
  }
  if (!self) return DefWindowProcW(hwnd, message, wparam, lparam);

  switch (message) {
    case WM_PRINTCLIENT:
      if (wparam) self->Paint(reinterpret_cast<HDC>(wparam));
      return 0;
    case WM_PAINT: {
      PAINTSTRUCT ps{};
      HDC dc = BeginPaint(hwnd, &ps);
      self->Paint(dc);
      EndPaint(hwnd, &ps);
      return 0;
    }
    case WM_ERASEBKGND:
      return 1;
    case WM_TIMER:
      if (wparam == 11 && self->draft_.page == ui::SettingsPage::kPlugins) self->UpdatePlugins();
      return 0;
    case WM_COMMAND:
      if (LOWORD(wparam) == 405 && HIWORD(wparam) == CBN_SELCHANGE) {
        const auto choice = SendMessageW(self->combo_hotkey_modifiers_, CB_GETCURSEL, 0, 0);
        if (choice >= 0 && choice < static_cast<LRESULT>(kBufferHotkeyChoices.size()))
          self->draft_.hotkey_modifiers = kBufferHotkeyChoices[static_cast<std::size_t>(choice)].modifiers;
        InvalidateRect(hwnd, nullptr, FALSE);
        return 0;
      }
      if (HIWORD(wparam) == BN_CLICKED && LOWORD(wparam) >= 5100 && LOWORD(wparam) < 5112) {
        const auto index = static_cast<std::size_t>((LOWORD(wparam) - 5100) / 3);
        const int action = (LOWORD(wparam) - 5100) % 3;
        if (self->callbacks_.manage_plugin && index < self->plugin_rows_.size()) {
          const auto item = self->plugin_rows_[index]; std::string error;
          const std::string operation = action == 0 ? "install" : action == 2 ? "uninstall" : item.enabled ? "disable" : "enable";
          if (!self->callbacks_.manage_plugin(item.id, operation, &error)) MessageBoxW(hwnd, Wide(error).c_str(), L"RIMES", MB_OK);
          self->UpdatePlugins();
        }
        return 0;
      }
      if (HIWORD(wparam) == BN_CLICKED) {
        switch (LOWORD(wparam)) {
          case 401: self->draft_.ascii = !self->draft_.ascii; break;
          case 402: self->draft_.traditional = !self->draft_.traditional; break;
          case 403: self->draft_.ascii_punctuation = !self->draft_.ascii_punctuation; break;
          case 404: self->draft_.vertical_candidates = !self->draft_.vertical_candidates; break;
          default: return 0;
        }
        InvalidateRect(reinterpret_cast<HWND>(lparam), nullptr, FALSE);
        return 0;
      }
      break;
    case WM_DRAWITEM: {
      const auto* draw = reinterpret_cast<DRAWITEMSTRUCT*>(lparam);
      if (draw->CtlType != ODT_BUTTON) break;
      const auto& p = ui::Palette(self->draft_.preview_theme);
      ui::FillRectColor(draw->hDC, draw->rcItem,
                       ui::ToColorRef(p.settings_background));
      const bool checked = draw->CtlID == 401 ? self->draft_.ascii
          : draw->CtlID == 402 ? self->draft_.traditional
                               : draw->CtlID == 403 ? self->draft_.ascii_punctuation
                                : self->draft_.vertical_candidates;
      RECT box = draw->rcItem;
      const int size = MulDiv(14, static_cast<int>(self->dpi_), 96);
      box.right = box.left + size;
      box.top += (box.bottom - box.top - size) / 2;
      box.bottom = box.top + size;
      ui::FillRoundRect(draw->hDC, box, MulDiv(3, static_cast<int>(self->dpi_), 96),
                        ui::ToColorRef(checked ? p.accent : p.surface));
      ui::StrokeRoundRect(draw->hDC, box, MulDiv(3, static_cast<int>(self->dpi_), 96),
                          ui::ToColorRef(checked ? p.accent : p.border_strong));
      if (checked) ui::DrawIconGlyph(draw->hDC, ui::IconId::kCheck, box,
                                    ui::ToColorRef(p.accent_foreground));
      RECT text_box = draw->rcItem;
      text_box.left = box.right + MulDiv(8, static_cast<int>(self->dpi_), 96);
      const auto label = GetText(draw->hwndItem);
      const auto old = SelectObject(draw->hDC, self->fonts_.body);
      SetBkMode(draw->hDC, TRANSPARENT);
      SetTextColor(draw->hDC, ui::ToColorRef(p.text_primary));
      DrawTextW(draw->hDC, label.c_str(), -1, &text_box,
                DT_LEFT | DT_VCENTER | DT_SINGLELINE);
      SelectObject(draw->hDC, old);
      if (draw->itemState & ODS_FOCUS) DrawFocusRect(draw->hDC, &draw->rcItem);
      return TRUE;
    }
    case WM_GETMINMAXINFO: {
      auto* limits = reinterpret_cast<MINMAXINFO*>(lparam);
      const int dpi = static_cast<int>(GetDpiForWindow(hwnd));
      RECT min_client{0, 0, MulDiv(860, dpi, 96), MulDiv(600, dpi, 96)};
      AdjustWindowRectExForDpi(&min_client, WS_OVERLAPPEDWINDOW, FALSE, 0,
                               dpi);
      limits->ptMinTrackSize = {min_client.right - min_client.left,
                                min_client.bottom - min_client.top};
      return 0;
    }
    case WM_SIZE:
      self->Relayout();
      return 0;
    case WM_DPICHANGED: {
      auto* rect = reinterpret_cast<RECT*>(lparam);
      SetWindowPos(hwnd, nullptr, rect->left, rect->top,
                   rect->right - rect->left, rect->bottom - rect->top,
                   SWP_NOZORDER);
      self->dpi_ = HIWORD(wparam);
      self->Relayout();
      return 0;
    }
    case WM_CTLCOLOREDIT:
    case WM_CTLCOLORSTATIC: {
      const auto& p = ui::Palette(self->draft_.preview_theme);
      HDC dc = reinterpret_cast<HDC>(wparam);
      SetBkColor(dc, ui::ToColorRef(p.surface));
      SetTextColor(dc, ui::ToColorRef(p.text_primary));
      if (!self->edit_brush_)
        self->edit_brush_ = CreateSolidBrush(ui::ToColorRef(p.surface));
      return reinterpret_cast<LRESULT>(self->edit_brush_);
    }
    case WM_LBUTTONDOWN: {
      SetFocus(hwnd);
      self->draft_.keyboard_focus = false;
      const float x = static_cast<float>(static_cast<short>(LOWORD(lparam))) *
                      96.0f / self->dpi_;
      const float y = static_cast<float>(static_cast<short>(HIWORD(lparam))) *
                      96.0f / self->dpi_;
      self->pressed_hit_ = ui::HitTestSettings(self->layout_, x, y);
      SetCapture(hwnd);
      return 0;
    }
    case WM_LBUTTONUP: {
      const int pressed = self->pressed_hit_;
      self->pressed_hit_ = -2;
      if (GetCapture() == hwnd) ReleaseCapture();
      if (pressed == -2) return 0;
      const float x = static_cast<float>(static_cast<short>(LOWORD(lparam))) *
                      96.0f / self->dpi_;
      const float y = static_cast<float>(static_cast<short>(HIWORD(lparam))) *
                      96.0f / self->dpi_;
      const int hit = ui::HitTestSettings(self->layout_, x, y);
      if (hit != pressed) return 0;
      if (self->draft_.theme_detail >= 0 && hit != 600 &&
          !(hit >= 400 && hit < 404)) {
        self->draft_.theme_detail = -1;
        self->Relayout();
        return 0;
      }
      self->ActivateHit(hit);
      return 0;
    }
    case WM_ACTIVATE:
      if (LOWORD(wparam) == WA_INACTIVE && self->draft_.theme_detail >= 0) {
        self->draft_.theme_detail = -1;
        self->Relayout();
      }
      break;
    case WM_CANCELMODE:
      if (GetCapture() == hwnd) ReleaseCapture();
      [[fallthrough]];
    case WM_CAPTURECHANGED:
      self->pressed_hit_ = -2;
      return 0;
    case WM_MOUSEMOVE: {
      const float x = static_cast<float>(static_cast<short>(LOWORD(lparam))) *
                      96.0f / self->dpi_;
      const float y = static_cast<float>(static_cast<short>(HIWORD(lparam))) *
                      96.0f / self->dpi_;
      const int hover = ui::HitTestSettings(self->layout_, x, y);
      if (self->draft_.hover != hover) {
        const int previous = self->draft_.hover;
        self->draft_.hover = hover;
        self->InvalidateHover(previous);
        self->InvalidateHover(hover);
      }
      TRACKMOUSEEVENT track{sizeof(track), TME_LEAVE, hwnd, 0};
      TrackMouseEvent(&track);
      return 0;
    }
    case WM_MOUSELEAVE:
      self->InvalidateHover(self->draft_.hover);
      self->draft_.hover = -1;
      return 0;
    case WM_SETCURSOR:
      if (reinterpret_cast<HWND>(wparam) == hwnd && LOWORD(lparam) == HTCLIENT) {
        POINT point{};
        GetCursorPos(&point);
        ScreenToClient(hwnd, &point);
        const float x = static_cast<float>(point.x) * 96.0f / self->dpi_;
        const float y = static_cast<float>(point.y) * 96.0f / self->dpi_;
        const int hit = ui::HitTestSettings(self->layout_, x, y);
        const bool actionable = hit >= 0 && hit != 600;
        SetCursor(LoadCursorW(nullptr, actionable ? IDC_HAND : IDC_ARROW));
        return TRUE;
      }
      break;
    case WM_KEYDOWN:
      if (wparam == VK_ESCAPE) {
        if (self->draft_.theme_detail >= 0) {
          self->draft_.theme_detail = -1;
          self->Relayout();
          return 0;
        }
        DestroyWindow(hwnd);
        return 0;
      }
      if (wparam >= '1' && wparam <= '6' && (GetKeyState(VK_CONTROL) & 0x8000)) {
        self->draft_.page =
            static_cast<ui::SettingsPage>(static_cast<int>(wparam - '1'));
        self->draft_.focus = static_cast<int>(wparam - '1');
        self->Relayout();
        return 0;
      }
      if (wparam == VK_UP || wparam == VK_DOWN || wparam == VK_LEFT ||
          wparam == VK_RIGHT) {
        auto& focus = self->draft_.focus;
        if (focus < 0) focus = static_cast<int>(self->draft_.page);
        if (focus < ui::kSettingsPageCount) {
          if (wparam == VK_DOWN || wparam == VK_RIGHT)
            focus = (focus + 1) % ui::kSettingsPageCount;
          else
            focus = (focus + ui::kSettingsPageCount - 1) % ui::kSettingsPageCount;
          self->draft_.page = static_cast<ui::SettingsPage>(focus);
          self->Relayout();
          return 0;
        }
        if (self->draft_.page == ui::SettingsPage::kInput &&
            self->draft_.subpage == 0 && focus >= 100 && focus < 106) {
          int idx = focus - 100;
          if (wparam == VK_RIGHT || wparam == VK_DOWN) idx = (idx + 1) % 6;
          else idx = (idx + 5) % 6;
          focus = 100 + idx;
          InvalidateRect(hwnd, nullptr, FALSE);
          return 0;
        }
        if (self->draft_.page == ui::SettingsPage::kAppearance &&
            self->draft_.subpage == 0 &&
            ((focus >= 200 && focus < 204) || (focus >= 400 && focus < 404))) {
          const int base = focus >= 400 ? 400 : 200;
          int idx = focus - base;
          if (wparam == VK_RIGHT || wparam == VK_DOWN) idx = (idx + 1) % 4;
          else idx = (idx + 3) % 4;
          focus = base + idx;
          InvalidateRect(hwnd, nullptr, FALSE);
          return 0;
        }
      }
      if (wparam == VK_SPACE || wparam == VK_RETURN) {
        self->ActivateHit(self->draft_.focus);
        return 0;
      }
      break;
    case WM_DESTROY:
      KillTimer(hwnd, 11);
      self->hwnd_ = nullptr;
      self->edit_font_ = self->edit_candidate_count_ = self->edit_hotkey_ = self->edit_base_ = nullptr;
      self->combo_hotkey_modifiers_ = nullptr;
      self->edit_model_ = self->edit_key_ = self->edit_lang_ = nullptr;
      self->combo_connector_ = self->edit_codex_path_ = self->edit_codex_model_ = nullptr;
      self->check_vertical_ = self->check_ascii_ = self->check_trad_ = self->check_punct_ = nullptr;
      if (!self->saved_ && self->callbacks_.on_theme_preview)
        self->callbacks_.on_theme_preview(self->opened_theme_);
      if (self->callbacks_.on_closed) self->callbacks_.on_closed();
      return 0;
    default:
      break;
  }
  return DefWindowProcW(hwnd, message, wparam, lparam);
}

}  // namespace rimes::windows::workbench
