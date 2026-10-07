#include "settings_ui.hpp"
#include "buffer_hotkey.hpp"
#include "window.hpp"

#include <algorithm>
#include <atomic>
#include <cstdint>
#include <cstdlib>
#include <filesystem>
#include <iostream>
#include <thread>
#include <vector>

namespace {
using namespace rimes::windows;
int failures = 0;
void Check(bool value, const char* message) {
  if (!value) { std::cerr << "FAIL: " << message << '\n'; ++failures; }
}

LPARAM Point(HWND window, float x, float y) {
  const float dpi = static_cast<float>(GetDpiForWindow(window));
  return MAKELPARAM(static_cast<WORD>(x * dpi / 96.0f + 0.5f),
                    static_cast<WORD>(y * dpi / 96.0f + 0.5f));
}
void Click(HWND window, const ui::DipRect& box) {
  const auto point = Point(window, (box.left + box.right) / 2,
                          (box.top + box.bottom) / 2);
  SendMessageW(window, WM_LBUTTONDOWN, MK_LBUTTON, point);
  SendMessageW(window, WM_LBUTTONUP, 0, point);
}
ui::SettingsLayout Layout(HWND window, const ui::SettingsDraft& draft) {
  RECT client{};
  GetClientRect(window, &client);
  const float scale = 96.0f / static_cast<float>(GetDpiForWindow(window));
  return ui::LayoutSettings(static_cast<float>(client.right) * scale,
                             static_cast<float>(client.bottom) * scale, draft);
}

bool IsVisibleWithinFixture(HWND control, HWND fixture) {
  if (!control || !fixture) return false;
  for (HWND ancestor = control; ancestor; ancestor = GetParent(ancestor)) {
    if ((GetWindowLongPtrW(ancestor, GWL_STYLE) & WS_VISIBLE) == 0)
      return false;
    if (ancestor == fixture) return true;
  }
  return false;
}

template <typename Predicate>
bool WaitUntil(Predicate predicate, const char* message) {
  const auto start = GetTickCount64();
  bool ready = predicate();
  while (!ready && GetTickCount64() - start < 3000) {
    Sleep(2);
    ready = predicate();
  }
  Check(ready, message);
  return ready;
}

struct FixtureWindows {
  HWND buffer = nullptr, settings = nullptr;
};
FixtureWindows WindowsOnFixtureThread(DWORD thread) {
  FixtureWindows windows;
  if (!thread) return windows;
  EnumThreadWindows(thread, [](HWND window, LPARAM context) -> BOOL {
    auto& found = *reinterpret_cast<FixtureWindows*>(context);
    wchar_t kind[64]{};
    GetClassNameW(window, kind, 64);
    if (std::wstring(kind) == L"Rimes.Workbench") found.buffer = window;
    if (std::wstring(kind) == L"Rimes.SettingsHost") found.settings = window;
    return TRUE;
  }, reinterpret_cast<LPARAM>(&windows));
  return windows;
}

void TestNestedHitTargets() {
  ui::SettingsDraft draft;
  draft.page = ui::SettingsPage::kAppearance;
  for (const float width : {860.0f, 980.0f, 1300.0f}) {
    for (int index = 0; index < 4; ++index) {
      draft.theme_detail = index;
      const auto layout = ui::LayoutSettings(width, 600, draft);
      const auto& detail = layout.theme_details[static_cast<std::size_t>(index)];
      Check(ui::HitTestSettings(layout, detail.left + 1, detail.top + 1) == 400 + index,
            "details own their hit region before the parent card");
      const auto& popup = layout.theme_popover;
      Check(popup.left > layout.content.left && popup.right < width &&
                popup.bottom < layout.save.top,
            "theme details remain inside content and clear Save");
      Check(ui::HitTestSettings(layout, popup.left + 3, popup.top + 3) == 600,
            "popover shields underlying card clicks");
    }
  }
  draft.subpage = 1;
  const auto hidden = ui::LayoutSettings(980, 680, draft);
  Check(hidden.theme_details.empty() && hidden.theme_popover.width() == 0,
        "size subpage has no stale theme hit targets");
}

void TestOwnedClicksAndTransientDetails() {
  int saves = 0;
  int previews = 0;
  ui::ThemeId preview = ui::ThemeId::kNight;
  workbench::SettingsUiCallbacks callbacks;
  callbacks.load = [] { return workbench::Settings{}; };
  callbacks.load_theme = [] { return ui::ThemeId::kNight; };
  callbacks.save = [&](workbench::Settings, const std::wstring&, bool, std::string*) {
    ++saves;
    return true;
  };
  callbacks.on_theme_preview = [&](ui::ThemeId value) { preview = value; ++previews; };
  // Own, disposable windows only. No Runtime, preferences, credentials, input
  // registration or installed Broker. CTest runs in the isolated build session.
  workbench::SettingsUiHost host(std::move(callbacks));
  host.Open(nullptr);
  HWND window = host.hwnd();
  Check(window != nullptr, "isolated settings host opens");
  if (!window) return;
  ui::SettingsDraft draft;
  auto layout = Layout(window, draft);
  SendMessageW(window, WM_LBUTTONUP, 0,
               Point(window, layout.save.left + 2, layout.save.top + 2));
  Check(host.IsOpen() && saves == 0, "unowned mouse release cannot Save");
  if (!host.IsOpen()) return;
  Click(window, layout.nav[1]);
  draft.page = ui::SettingsPage::kAppearance;
  layout = Layout(window, draft);
  Click(window, layout.theme_details[1]);
  Check(previews == 0, "theme details do not select or preview a theme");
  SendMessageW(window, WM_KEYDOWN, VK_ESCAPE, 0);
  Check(host.IsOpen(), "Escape dismisses details before the settings window");
  if (!host.IsOpen()) return;

  const auto a = Point(window, layout.theme_cards[0].left + 4,
                       layout.theme_cards[0].top + 4);
  const auto b = Point(window, layout.theme_cards[1].left + 4,
                       layout.theme_cards[1].top + 4);
  SendMessageW(window, WM_LBUTTONDOWN, MK_LBUTTON, a);
  SendMessageW(window, WM_LBUTTONUP, 0, b);
  Check(previews == 0, "dragging between cards never selects the release card");
  SendMessageW(window, WM_LBUTTONDOWN, MK_LBUTTON, b);
  SendMessageW(window, WM_CANCELMODE, 0, 0);
  SendMessageW(window, WM_LBUTTONUP, 0, b);
  Check(previews == 0, "cancelled capture revokes a late release");

  Click(window, layout.theme_details[0]);
  Click(window, layout.theme_cards[3]);
  Check(previews == 0, "outside click dismisses details without choosing another theme");
  Click(window, layout.theme_cards[3]);
  Check(preview == ui::ThemeId::kRasta && previews == 1,
        "normal owned card click still previews exactly once");
  host.Close(false);
  Check(preview == ui::ThemeId::kNight && saves == 0,
        "closing unsaved settings restores the original theme");
}
void TestCandidateSettingsControls() {
  workbench::Settings saved;
  int saves = 0;
  workbench::SettingsUiCallbacks callbacks;
  callbacks.load = [] { workbench::Settings s; s.candidate_count = 5; return s; };
  callbacks.save = [&](workbench::Settings s, const std::wstring&, bool, std::string*) { saved = s; ++saves; return true; };
  workbench::SettingsUiHost host(std::move(callbacks));
  host.Open(nullptr);
  const auto window = host.hwnd();
  if (!window) { Check(false, "candidate settings fixture opens"); return; }
  ShowWindow(window, SW_SHOWNOACTIVATE);
  ui::SettingsDraft draft;
  auto layout = Layout(window, draft);
  Click(window, layout.nav[1]);
  draft.page = ui::SettingsPage::kAppearance;
  layout = Layout(window, draft);
  Click(window, layout.subpage_tabs[1]);
  draft.subpage = 1;
  layout = Layout(window, draft);
  const auto vertical = GetDlgItem(window, 404);
  Check(IsVisibleWithinFixture(vertical, window), "vertical candidate option is exposed in appearance size settings");
  SendMessageW(window, WM_COMMAND, MAKEWPARAM(404, BN_CLICKED), reinterpret_cast<LPARAM>(vertical));
  host.Close(true);
  Check(saves == 1 && saved.candidate_count == 5 && saved.vertical_candidates,
        "candidate controls save the requested count and arrangement");
}

void TestBufferHotkeyRegistrationLifecycle() {
  // Real Win32 registration, disposable message-only windows, no synthesized
  // input. The native suite runs in the isolated build session, not a desktop
  // user session. Discover free letter chords rather than assuming availability.
  struct Fixture {
    HWND owner = CreateWindowExW(0, L"STATIC", L"", 0, 0, 0, 0, 0,
                                  HWND_MESSAGE, nullptr, nullptr, nullptr);
    HWND contender = CreateWindowExW(0, L"STATIC", L"", 0, 0, 0, 0, 0,
                                      HWND_MESSAGE, nullptr, nullptr, nullptr);
    ~Fixture() {
      for (int id : {100, 101, 102, 200})
        UnregisterHotKey(contender, id);
      if (owner) DestroyWindow(owner);
      if (contender) DestroyWindow(contender);
    }
  } fixture;
  Check(fixture.owner && fixture.contender, "hotkey fixture owns two isolated windows");
  if (!fixture.owner || !fixture.contender) return;
  struct Chord { unsigned modifiers, key; };
  std::vector<Chord> chords;
  for (unsigned key = 'A'; key <= 'Z' && chords.size() < 3; ++key) {
    const unsigned modifiers = chords.empty() ? MOD_CONTROL | MOD_ALT
                                              : MOD_CONTROL | MOD_SHIFT;
    const int id = 100 + static_cast<int>(chords.size());
    if (RegisterHotKey(fixture.contender, id, modifiers | MOD_NOREPEAT, key))
      chords.push_back({modifiers, key});
  }
  Check(chords.size() == 3, "three real letter chords available in the build session");
  if (chords.size() != 3) return;
  const auto old = chords[0], busy = chords[1], next = chords[2];
  auto can_claim = [&](Chord chord) {
    const bool claimed = RegisterHotKey(fixture.contender, 200,
        chord.modifiers | MOD_NOREPEAT, chord.key) != FALSE;
    if (claimed) UnregisterHotKey(fixture.contender, 200);
    return claimed;
  };
  workbench::BufferHotkeyRegistration hotkey(fixture.owner);
  const Chord bare{0, old.key};
  const bool bare_was_free = can_claim(bare);
  Check(!hotkey.RegisterInitial(bare.modifiers, bare.key) && !hotkey.Registered() &&
            (!bare_was_free || can_claim(bare)),
        "invalid startup settings never reserve a bare typing key");
  Check(!hotkey.RegisterInitial(old.modifiers, old.key) && !hotkey.Registered(),
        "startup conflict reports unavailable rather than a fictitious active chord");
  UnregisterHotKey(fixture.contender, 100);
  Check(hotkey.RegisterInitial(old.modifiers, old.key) && !can_claim(old),
        "startup retry owns the requested real chord");
  int saves = 0;
  const Chord invalid[] = {
      {0, old.key}, {MOD_CONTROL, old.key}, {MOD_WIN, old.key},
      {MOD_CONTROL | MOD_ALT | MOD_SHIFT, old.key},
      {MOD_CONTROL | MOD_SHIFT | MOD_NOREPEAT, old.key},
      {MOD_CONTROL | MOD_SHIFT, 0}, {MOD_CONTROL | MOD_SHIFT, 'b'},
      {MOD_CONTROL | MOD_SHIFT, VK_F1},
      {MOD_CONTROL | MOD_SHIFT, static_cast<unsigned>(-1)}};
  for (const auto chord : invalid) {
    const bool was_free = can_claim(chord);
    const auto result = hotkey.Update(chord.modifiers, chord.key,
                                     [&] { ++saves; return true; });
    Check(result == workbench::HotkeyUpdate::kInvalid && saves == 0 &&
              !can_claim(old) && (!was_free || can_claim(chord)),
          "unsupported modifiers/letters skip Save and registration while retaining the old chord");
  }
  const auto conflict = hotkey.Update(busy.modifiers, busy.key, [&] { ++saves; return true; });
  Check(conflict == workbench::HotkeyUpdate::kUnavailable && saves == 0 && !can_claim(old),
        "new chord conflict skips Save and leaves the old chord registered");
  UnregisterHotKey(fixture.contender, 102);
  const auto failed = hotkey.Update(next.modifiers, next.key, [&] {
    ++saves;
    Check(!can_claim(old) && !can_claim(next), "both chords stay owned while Save runs");
    return false;
  });
  Check(failed == workbench::HotkeyUpdate::kSaveFailed && !can_claim(old) && can_claim(next),
        "failed Save releases the candidate and retains the original real registration");
  const auto saved = hotkey.Update(next.modifiers, next.key, [&] { ++saves; return true; });
  Check(saved == workbench::HotkeyUpdate::kSaved && can_claim(old) && !can_claim(next),
        "successful Save releases the old chord and owns the new chord");
  const auto next_message = MAKELPARAM(next.modifiers, next.key);
  const WPARAM current_id = hotkey.Matches(1, next_message) ? 1 : 2;
  const auto same = hotkey.Update(next.modifiers, next.key, [&] {
    ++saves;
    Check(!can_claim(next), "unchanged chord is continuously registered during Save");
    return true;
  });
  Check(same == workbench::HotkeyUpdate::kSaved && saves == 3 &&
            hotkey.Matches(current_id, next_message),
        "unchanged settings save retains the original registration id");
  Check(!hotkey.Matches(current_id == 1 ? 2 : 1, next_message) &&
            !hotkey.Matches(current_id, MAKELPARAM(old.modifiers, old.key)),
        "queued old ids and mismatched chord messages do not toggle Buffer");
  hotkey.Reset();
  Check(!hotkey.Registered() && can_claim(next), "closing the owner releases its real chord");
}

void TestBufferHotkeyModifierControl() {
  for (const unsigned modifiers : {MOD_CONTROL | MOD_SHIFT,
                                   MOD_CONTROL | MOD_ALT}) {
    workbench::Settings current;
    current.hotkey_modifiers = modifiers;
    current.hotkey_key = 'J';
    workbench::Settings saved;
    int saves = 0;
    workbench::SettingsUiCallbacks callbacks;
    callbacks.load = [&] { return current; };
    callbacks.save = [&](workbench::Settings value, const std::wstring&, bool,
                         std::string*) {
      saved = value;
      ++saves;
      return true;
    };
    workbench::SettingsUiHost host(std::move(callbacks));
    auto open_buffer_page = [&]() -> HWND {
      host.Open(nullptr);
      const auto window = host.hwnd();
      Check(window != nullptr, "shortcut settings fixture opens");
      if (!window) return nullptr;
      ShowWindow(window, SW_SHOWNOACTIVATE);
      ui::SettingsDraft draft;
      Click(window, Layout(window, draft).nav[2]);
      const HWND choices = GetDlgItem(window, 405);
      Check(IsVisibleWithinFixture(choices, window),
            "native modifier selector is exposed only on the shortcut page");
      Check(SendMessageW(choices, CB_GETCOUNT, 0, 0) == 2 &&
                SendMessageW(choices, CB_GETCURSEL, 0, 0) ==
                    (modifiers == (MOD_CONTROL | MOD_ALT) ? 1 : 0),
            "selector displays the complete configured chord without migration");
      return choices;
    };
    HWND choices = open_buffer_page();
    if (!choices) continue;
    for (const WPARAM key : {VK_RETURN, VK_ESCAPE}) {
      SendMessageW(choices, CB_SHOWDROPDOWN, TRUE, 0);
      Check(SendMessageW(choices, CB_GETDROPPEDSTATE, 0, 0) != 0,
            "native shortcut dropdown opens for keyboard interaction");
      MSG message{};
      message.hwnd = choices;
      message.message = WM_KEYDOWN;
      message.wParam = key;
      const bool handled = host.HandleDialogMessage(&message);
      Check(!handled && host.IsOpen() && saves == 0,
            "Return and Escape in an open combo do not Save or close settings");
      if (!handled) {
        TranslateMessage(&message);
        DispatchMessageW(&message);
      }
      Check(SendMessageW(choices, CB_GETDROPPEDSTATE, 0, 0) == 0 &&
                host.IsOpen() && saves == 0,
            "native combo handles popup confirmation/cancellation before the settings window");
    }
    // Saving an unrelated preference must keep the legacy modifier and letter.
    host.Close(true);
    Check(saves == 1 && saved.hotkey_modifiers == modifiers && saved.hotkey_key == 'J',
          "ordinary Save preserves an explicitly configured complete shortcut");
    choices = open_buffer_page();
    if (!choices) continue;
    const auto selected = modifiers == (MOD_CONTROL | MOD_ALT) ? 0 : 1;
    SendMessageW(choices, CB_SETCURSEL, selected, 0);
    SendMessageW(host.hwnd(), WM_COMMAND, MAKEWPARAM(405, CBN_SELCHANGE),
                 reinterpret_cast<LPARAM>(choices));
    host.Close(false);
    Check(saves == 1 && current.hotkey_modifiers == modifiers,
          "cancelled explicit modifier edits never invoke Save");
    choices = open_buffer_page();
    if (!choices) continue;
    SendMessageW(choices, CB_SETCURSEL, selected, 0);
    SendMessageW(host.hwnd(), WM_COMMAND, MAKEWPARAM(405, CBN_SELCHANGE),
                 reinterpret_cast<LPARAM>(choices));
    host.Close(true);
    Check(saves == 2 && saved.hotkey_modifiers ==
              static_cast<unsigned>(selected == 0 ? MOD_CONTROL | MOD_SHIFT : MOD_CONTROL | MOD_ALT) &&
              saved.hotkey_key == 'J',
          "explicit modifier migration keeps the user's custom letter");
  }
}

void TestHoverRepaintScopeAndResources() {
  workbench::SettingsUiCallbacks callbacks;
  callbacks.load = [] { return workbench::Settings{}; };
  workbench::SettingsUiHost host(std::move(callbacks));
  host.Open(nullptr);
  const auto window = host.hwnd();
  Check(window != nullptr, "hover repaint fixture opens");
  if (!window) return;
  ShowWindow(window, SW_SHOWNOACTIVATE);
  UpdateWindow(window);
  ui::SettingsDraft draft;
  const auto layout = Layout(window, draft);
  auto move = [&](int row) {
    const auto& rect = layout.nav[static_cast<std::size_t>(row)];
    SendMessageW(window, WM_MOUSEMOVE, 0,
                 Point(window, (rect.left + rect.right) / 2,
                       (rect.top + rect.bottom) / 2));
  };
  auto sidebar_only = [&] {
    HRGN region = CreateRectRgn(0, 0, 0, 0);
    const int type = GetUpdateRgn(window, region, FALSE);
    RECT dirty{};
    GetRgnBox(region, &dirty);
    const float scale = GetDpiForWindow(window) / 96.0f;
    const bool result = type != ERROR && type != NULLREGION &&
        dirty.right <= static_cast<LONG>(layout.sidebar.right * scale) + 2 &&
        !PtInRegion(region, static_cast<int>((layout.heading.left + 30) * scale),
                    static_cast<int>((layout.heading.top + 10) * scale));
    DeleteObject(region);
    return result;
  };
  // Session 0 discards HWND update regions. Do not claim these desktop
  // assertions ran there; the actual GDI bitmap assertions below still run.
  if (IsWindowVisible(window)) {
    for (const int row : {0, 1, 2, 3}) {
      move(row);
      Check(sidebar_only(), "navigation hover excludes content from the HWND dirty region");
      UpdateWindow(window);
      move(row);
      Check(!GetUpdateRect(window, nullptr, FALSE), "same hovered row does not invalidate again");
    }
    SendMessageW(window, WM_MOUSELEAVE, 0, 0);
    Check(sidebar_only(), "mouse leave invalidates only the previous navigation highlight");
    UpdateWindow(window);
    SendMessageW(window, WM_MOUSELEAVE, 0, 0);
    Check(!GetUpdateRect(window, nullptr, FALSE), "repeated mouse leave does not invalidate again");
    std::cout << "Desktop HWND hover dirty-region assertions executed\n";
  } else {
    std::cout << "NOT EXECUTED: desktop HWND hover dirty-region assertions (invisible Session 0 window)\n";
  }
  SendMessageW(window, WM_MOUSELEAVE, 0, 0);

  RECT client{};
  GetClientRect(window, &client);
  HDC screen = GetDC(window);
  HDC capture = CreateCompatibleDC(screen);
  BITMAPINFO info{};
  info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  info.bmiHeader.biWidth = client.right;
  info.bmiHeader.biHeight = -client.bottom;
  info.bmiHeader.biPlanes = 1;
  info.bmiHeader.biBitCount = 32;
  info.bmiHeader.biCompression = BI_RGB;
  void* pixels = nullptr;
  HBITMAP bitmap = CreateDIBSection(screen, &info, DIB_RGB_COLORS, &pixels, nullptr, 0);
  ReleaseDC(window, screen);
  Check(capture && bitmap && pixels, "native offscreen GDI capture allocates its bitmap and DC");
  if (!capture || !bitmap || !pixels) {
    if (bitmap) DeleteObject(bitmap);
    if (capture) DeleteDC(capture);
    host.Close(false);
    return;
  }
  const auto selected = SelectObject(capture, bitmap);
  const auto count = static_cast<std::size_t>(client.right) * client.bottom;
  const auto bits = static_cast<std::uint32_t*>(pixels);
  auto render = [&] {
    std::fill(bits, bits + count, 0x00112233U);
    SendMessageW(window, WM_PRINTCLIENT, reinterpret_cast<WPARAM>(capture), PRF_CLIENT);
    GdiFlush();
    return std::vector<std::uint32_t>(bits, bits + count);
  };
  auto nav_bounds = [&](int row) {
    RECT rect{};
    if (row >= 0) {
      const auto& dip = layout.nav[static_cast<std::size_t>(row)];
      const auto scale = GetDpiForWindow(window) / 96.0f;
      rect = {static_cast<LONG>(dip.left * scale) - 2,
              static_cast<LONG>(dip.top * scale) - 2,
              static_cast<LONG>(dip.right * scale) + 2,
              static_cast<LONG>(dip.bottom * scale) + 2};
    }
    return rect;
  };
  auto previous = render();
  Check(std::none_of(previous.begin(), previous.end(),
                     [](auto pixel) { return pixel == 0x00112233U; }),
        "buffered settings renderer covers the entire client with a completed frame");
  int old_row = -1;
  for (const int row : {1, 2, 3, 0, -1}) {
    if (row < 0) SendMessageW(window, WM_MOUSELEAVE, 0, 0);
    else move(row);
    const auto current = render();
    const auto old_bounds = nav_bounds(old_row), new_bounds = nav_bounds(row);
    std::size_t changed = 0;
    bool outside_changed = false;
    for (std::size_t i = 0; i < count; ++i) {
      if (current[i] == previous[i]) continue;
      ++changed;
      const POINT point{static_cast<LONG>(i % client.right),
                        static_cast<LONG>(i / client.right)};
      if (!PtInRect(&old_bounds, point) && !PtInRect(&new_bounds, point))
        outside_changed = true;
    }
    // Leaving the already-selected row need not alter its selected styling.
    if (row >= 0) Check(changed > 0, "native hover GDI output changes its navigation highlight");
    Check(!outside_changed, "hover GDI pixel changes stay inside old and new navigation rows");
    if (row < 0) SendMessageW(window, WM_MOUSELEAVE, 0, 0);
    else move(row);
    Check(render() == current, "repeated hover state produces an identical native frame");
    previous = current;
    old_row = row;
  }

  const DWORD resources = GetGuiResources(GetCurrentProcess(), GR_GDIOBJECTS);
  Check(resources > 0, "GDI instrumentation observes the fixture's fonts, bitmap and DC");
  for (int i = 0; i < 64; ++i) {
    move(i % 4);
    render();  // Forces actual buffered drawing even when Session 0 is hidden.
  }
  Check(GetGuiResources(GetCurrentProcess(), GR_GDIOBJECTS) <= resources + 1,
        "64 actual buffered hover renders do not retain GDI bitmaps or DCs");
  std::cout << "Native GDI hover frame coverage, bounded pixel changes and resource assertions executed\n";
  SelectObject(capture, selected);
  DeleteObject(bitmap);
  DeleteDC(capture);
  host.Close(false);
}

void TestPluginManagementAndChordSelection() {
  Check(std::wstring(ui::kSettingsSchemeTitles[5]) == L"isaac2026",
        "chord scheme uses its current product name");
  int changes = 0;
  std::string saved_schema;
  workbench::PluginView fixture{"builtin.apple-translation", "Translation", "1.1.0", "grant", true, true, true};
  workbench::SettingsUiCallbacks callbacks;
  callbacks.load = [] { return workbench::Settings{}; };
  callbacks.plugins = [&] { return std::vector<workbench::PluginView>{fixture}; };
  callbacks.manage_plugin = [&](const std::string& id, const std::string& action, std::string*) {
    Check(id == fixture.id && action == "disable", "plugin control passes the selected identity and action");
    fixture.enabled = false; ++changes; return true;
  };
  callbacks.save = [&](workbench::Settings value, const std::wstring&, bool, std::string*) {
    saved_schema = value.schema; return true;
  };
  workbench::SettingsUiHost host(std::move(callbacks));
  host.Open(nullptr);
  const HWND window = host.hwnd();
  Check(window != nullptr, "plugin fixture window opens");
  if (!window) return;
  // SSH/CTest can inherit STARTF_USESHOWWINDOW=SW_HIDE. Explicitly show the
  // disposable fixture after Open so visibility checks cover the controls.
  ShowWindow(window, SW_SHOWNOACTIVATE);
  ui::SettingsDraft draft;
  auto layout = Layout(window, draft);
  Check(layout.nav.size() == 6, "six settings pages");
  Click(window, layout.nav[4]);
  const HWND toggle = GetDlgItem(window, 5101);
  // SSH/CTest's Session 0 desktop can be hidden even when these owned windows
  // have WS_VISIBLE. Verify every owned ancestor and the child's full native
  // visibility relative to its shown parent. On a visible desktop this also
  // requires IsWindowVisible(toggle); Session 0 cannot prove actual rendering.
  const bool exposed = IsVisibleWithinFixture(toggle, window) &&
                       IsWindowEnabled(toggle) &&
                       IsWindowVisible(toggle) == IsWindowVisible(window);
  if (!exposed) {
    STARTUPINFOW startup{};
    startup.cb = sizeof(startup);
    GetStartupInfoW(&startup);
    RECT client{}, button{};
    GetClientRect(window, &client);
    GetWindowRect(toggle, &button);
    std::cerr << "Plugin fixture state: parent-visible=" << IsWindowVisible(window)
              << " parent-style=" << GetWindowLongPtrW(window, GWL_STYLE)
              << " toggle-exists=" << (toggle != nullptr)
              << " toggle-visible=" << IsWindowVisible(toggle)
              << " toggle-style=" << GetWindowLongPtrW(toggle, GWL_STYLE)
              << " toggle-enabled=" << IsWindowEnabled(toggle)
              << " client=" << client.right << 'x' << client.bottom
              << " toggle-size=" << button.right - button.left << 'x'
              << button.bottom - button.top
              << " dpi=" << GetDpiForWindow(window)
              << " startup-flags=" << startup.dwFlags
              << " startup-show=" << startup.wShowWindow
              << " desktop-visible=" << IsWindowVisible(GetDesktopWindow())
              << " desktop-style=" << GetWindowLongPtrW(GetDesktopWindow(), GWL_STYLE)
              << '\n';
  }
  Check(exposed, "installed plugin exposes its switch");
  SendMessageW(toggle, BM_CLICK, 0, 0);
  Check(changes == 1 && !fixture.enabled, "switch callback occurs exactly once");
  Click(window, layout.nav[0]);
  Check(IsVisibleWithinFixture(window, window), "navigation keeps the fixture parent shown");
  Check((GetWindowLongPtrW(toggle, GWL_STYLE) & WS_VISIBLE) == 0 &&
            !IsWindowVisible(toggle),
        "plugin controls leave other pages clear");
  layout = Layout(window, draft);
  Check(layout.scheme_cards.size() == 6, "chording is the sixth input schema");
  Click(window, layout.scheme_cards[5]);
  Click(window, layout.save);
  Check(saved_schema == "my_combo", "schema control saves chording identity");
  host.Close(false);
}

void TestSettingsPreserveRuntimeAndStreaming() {
  const DWORD original_size = GetEnvironmentVariableW(L"LOCALAPPDATA", nullptr, 0);
  std::wstring original(original_size, L'\0');
  if (original_size) {
    GetEnvironmentVariableW(L"LOCALAPPDATA", original.data(), original_size);
    original.resize(wcslen(original.c_str()));
  }
  const auto root = std::filesystem::temp_directory_path() /
      (L"rimes-settings-ui-test-" + std::to_wstring(GetCurrentProcessId()) +
       L"-" + std::to_wstring(GetTickCount64()));
  std::filesystem::create_directories(root);
  if (!SetEnvironmentVariableW(L"LOCALAPPDATA", root.c_str())) {
    Check(false, "runtime fixture isolates its preferences and plugin state");
    std::filesystem::remove_all(root);
    return;
  }
  {
    std::atomic<unsigned> calls{0}, completed{0};
    std::atomic<bool> release{false}, cancelled_request{false}, accepted{false};
    // Real Runtime and the production window/dispatcher; only the network
    // transport is synthetic. No credentials, input registration or host text.
    workbench::Runtime runtime([&](const workbench::Settings&,
        const workbench::Generation&, const std::function<bool(const std::string&)>& chunk,
        const std::function<bool()>& cancelled, std::string*) {
      const bool initial = chunk("Stream");
      ++calls;
      const auto start = GetTickCount64();
      while (!release && !cancelled() && GetTickCount64() - start < 15000)
        Sleep(2);
      cancelled_request = cancelled();
      accepted = initial && release && !cancelled_request && chunk(" done.");
      ++completed;
      return accepted.load();
    });
    workbench::UiCommands commands;
    std::atomic<DWORD> ui_thread{0};
    std::jthread ui([&] {
      ui_thread = GetCurrentThreadId();
      workbench::RunWindow(runtime, [] {}, [] {}, &commands);
    });
    const auto windows = [&] { return WindowsOnFixtureThread(ui_thread.load()); };
    WaitUntil([&] { return commands.RequestSettings(); }, "production settings dispatcher becomes ready");
    WaitUntil([&] { return windows().settings != nullptr; }, "settings command opens the production settings host");
    Check(!runtime.Snapshot().value("visible", true), "settings do not open a closed Buffer");
    if (const HWND settings = windows().settings) PostMessageW(settings, WM_CLOSE, 0, 0);
    WaitUntil([&] { return windows().settings == nullptr; }, "closing settings retires its own window");

    const auto peer = GetCurrentProcessId() + 1;
    const auto target = runtime.Register(peer, 9001, 9001);
    runtime.Focus(target);
    runtime.Bind(peer);
    runtime.Paste("Fixture source.");
    runtime.Generate(true);
    WaitUntil([&] { return calls == 1 && runtime.Snapshot().value("busy", false); },
              "synthetic streaming request is held in flight");
    const auto before = runtime.Snapshot();
    const auto revision = runtime.Configuration().revision;
    Check(before.value("visible", false) && before.value("capture", false) &&
              before.value("preview", std::string()) == "Stream",
          "real Runtime fixture has visible captured source and a stream preview");
    Check(commands.RequestSettings(), "settings request posts while Buffer is active");
    WaitUntil([&] { return windows().settings && !runtime.Capturing(target); },
              "settings opens and pauses the previous host capture");
    auto after = runtime.Snapshot();
    Check(after["visible"] == before["visible"] &&
              after["source_blocks"] == before["source_blocks"] &&
              after["result_blocks"] == before["result_blocks"] &&
              after["busy"] == before["busy"] && after["preview"] == before["preview"] &&
              after["translate"] == before["translate"] && after["status"] == before["status"],
          "opening settings preserves Buffer visibility, block identities and active request state");
    Check(!after.value("capture", true) && after.value("target_pid", 1U) == 0 &&
              runtime.Configuration().revision == revision,
          "settings pause delivery authority without applying configuration");
    WaitUntil([&] { return IsVisibleWithinFixture(windows().buffer, windows().buffer); },
              "production Buffer window remains shown while settings are open");

    runtime.Focus({});  // The real host can report focus loss after activation.
    Check(runtime.Snapshot().value("busy", false) &&
              runtime.Snapshot().value("preview", std::string()) == "Stream",
          "following host focus loss preserves the already-paused request");
    const HWND first_settings = windows().settings;
    Check(commands.RequestSettings(), "repeated settings command posts");
    WaitUntil([&] { return windows().settings == first_settings; },
              "repeated settings request reuses the existing host");
    if (first_settings) PostMessageW(first_settings, WM_CLOSE, 0, 0);
    WaitUntil([&] { return windows().settings == nullptr; }, "settings can dismiss while streaming continues");
    Check(runtime.Snapshot().value("visible", false) &&
              runtime.Snapshot().value("busy", false) &&
              runtime.Snapshot()["source_blocks"] == before["source_blocks"],
          "dismissing settings preserves source and the active request");
    release = true;
    WaitUntil([&] { return completed == 1 && !runtime.Snapshot().value("busy", true); },
              "original stream finishes after settings is dismissed");
    Check(accepted && !cancelled_request && calls == 1 &&
              runtime.Snapshot().value("result", std::string()) == "Stream done.",
          "original callback remains authorized and completes exactly once");
    runtime.Focus(target);
    runtime.Send(false);
    Check(!runtime.Capturing(target) && runtime.Snapshot().value("target_pid", 1U) == 0 &&
              runtime.Snapshot().value("result", std::string()) == "Stream done.",
          "returning to the old input field does not revive capture or consume output");
    runtime.Bind(peer);
    Check(runtime.Capturing(target), "explicit binding is required to resume host capture");

    engine::EngineSnapshot preedit;
    preedit.composition = "pending preedit";
    runtime.Capture(target, &preedit);
    Check(commands.RequestSettings(), "settings request posts while composing");
    WaitUntil([&] { return windows().settings && !runtime.Capturing(target); },
              "settings pauses an explicitly rebound input context");
    Check(runtime.Snapshot().value("preedit", std::string()) == "" &&
              runtime.Snapshot().value("result", std::string()) == "Stream done." &&
              runtime.Snapshot()["source_blocks"] == before["source_blocks"],
          "capture pause clears only transient preedit and retains committed work");

    release = false;
    cancelled_request = false;
    runtime.Paste("Next source.");
    runtime.Generate(true);
    WaitUntil([&] { return calls == 2 && runtime.Snapshot().value("busy", false); },
              "second synthetic request starts for the appended source");
    auto changed = runtime.Configuration();
    changed.theme = "day";
    std::string error;
    Check(runtime.Configure(changed, L"", false, &error), "explicit settings Apply writes isolated preferences");
    WaitUntil([&] { return completed == 2; }, "configuration change retires the old request");
    Check(cancelled_request && !accepted &&
              !runtime.Snapshot().value("busy", true) &&
              runtime.Snapshot().value("preview", std::string()) == "" &&
              runtime.Snapshot().value("result", std::string()) == "" &&
              runtime.Snapshot().value("source", std::string()) == "Fixture source.Next source.",
          "actual configuration changes still invalidate old API results and retain source");
    release = true;
    runtime.Stop();
    if (const HWND buffer = windows().buffer) PostMessageW(buffer, WM_CLOSE, 0, 0);
    ui.join();
  }
  Check(SetEnvironmentVariableW(L"LOCALAPPDATA", original_size ? original.c_str() : nullptr) != 0,
        "runtime fixture restores the original preferences path after joining its workers");
  std::filesystem::remove_all(root);
}
}  // namespace

int main() {
  TestNestedHitTargets();
  TestOwnedClicksAndTransientDetails();
  TestCandidateSettingsControls();
  TestBufferHotkeyRegistrationLifecycle();
  TestBufferHotkeyModifierControl();
  TestHoverRepaintScopeAndResources();
  TestPluginManagementAndChordSelection();
  TestSettingsPreserveRuntimeAndStreaming();
  if (failures) return EXIT_FAILURE;
  std::cout << "Settings details, mouse ownership and Runtime preservation tests passed\n";
  return EXIT_SUCCESS;
}
