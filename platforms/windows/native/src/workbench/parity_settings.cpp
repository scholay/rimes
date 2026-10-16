#include "parity_settings.hpp"
#include "chord_profile.hpp"
#include <commctrl.h>
#include <commdlg.h>
#include <filesystem>
#include <fstream>
#include <mutex>
#include <objbase.h>
#include <thread>

namespace rimes::windows::workbench {
namespace {
std::wstring Text(HWND h) {
  const auto n = GetWindowTextLengthW(h);
  std::wstring s(static_cast<std::size_t>(n) + 1, 0);
  GetWindowTextW(h, s.data(), n + 1);
  s.resize(n);
  return s;
}
void Set(HWND h, const std::wstring &s) { SetWindowTextW(h, s.c_str()); }
unsigned Number(HWND h) {
  const auto s = Text(h);
  std::size_t n = 0;
  auto v = std::stoul(s, &n);
  if (n != s.size() || v > 100000)
    throw std::runtime_error("数字格式无效。");
  return static_cast<unsigned>(v);
}
std::string ID() {
  GUID id{};
  if (FAILED(CoCreateGuid(&id)))
    throw std::runtime_error("无法新建配置。");
  wchar_t s[40]{};
  StringFromGUID2(id, s, 40);
  auto value = Utf8(std::wstring(s + 1, 36));
  for (auto &c : value)
    if (c >= 'A' && c <= 'F')
      c = static_cast<char>(c - 'A' + 'a');
  return value;
}
} // namespace
struct ParitySettings::Impl {
  HWND parent = nullptr;
  Settings config;
  std::map<unsigned, HWND> controls;
  std::vector<ui::DipRect> edit_frames;
  std::map<std::string, std::wstring> secrets;
  std::size_t selected = 0;
  core::Json profile;
  struct Probe {
    std::mutex mutex;
    bool done = false;
    std::string id;
    ConnectionProbeResult result;
  };
  std::shared_ptr<Probe> probe;
  bool syncing = false;
  unsigned generation = 0, probe_generation = 0;
  ~Impl() {
    for (auto &[id, key] : secrets)
      if (!key.empty())
        SecureZeroMemory(key.data(), key.size() * sizeof(wchar_t));
  }
  HWND H(unsigned id) const {
    auto it = controls.find(id);
    return it == controls.end() ? nullptr : it->second;
  }
  HWND Add(unsigned id, const wchar_t *type, const wchar_t *text, DWORD style) {
    const auto h =
        CreateWindowExW(0, type, text, WS_CHILD | style, 0, 0, 1, 1, parent,
                        reinterpret_cast<HMENU>(static_cast<INT_PTR>(id)),
                        GetModuleHandleW(nullptr), nullptr);
    controls[id] = h;
    return h;
  }
  void Label(unsigned id, const wchar_t *text) {
    Add(id, L"STATIC", text, SS_LEFT);
  }
  void Edit(unsigned id, bool secret = false) {
    Add(id, L"EDIT", L"",
        WS_TABSTOP | ES_AUTOHSCROLL | (secret ? ES_PASSWORD : 0));
  }
  void Button(unsigned id, const wchar_t *text) {
    Add(id, L"BUTTON", text, WS_TABSTOP | BS_OWNERDRAW);
  }
  void Combo(unsigned id, std::initializer_list<const wchar_t *> entries = {},
             bool editable = false) {
    auto h = Add(id, L"COMBOBOX", L"",
                 WS_TABSTOP | WS_VSCROLL |
                     (editable ? CBS_DROPDOWN : CBS_DROPDOWNLIST) |
                     CBS_HASSTRINGS | CBS_OWNERDRAWFIXED);
    SetWindowLongPtrW(h, GWL_STYLE,
                      GetWindowLongPtrW(h, GWL_STYLE) & ~WS_BORDER);
    SetWindowPos(h, nullptr, 0, 0, 0, 0,
                 SWP_FRAMECHANGED | SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER |
                     SWP_NOACTIVATE);
    for (const auto *text : entries)
      SendMessageW(h, CB_ADDSTRING, 0, reinterpret_cast<LPARAM>(text));
  }
  void Status(const std::wstring &text) { Set(H(6099), text); }
  void CaptureConnection() {
    if (config.connections.empty())
      return;
    auto &p = config.connections.at(selected);
    p.name = Utf8(Text(H(6004)));
    if (p.kind == "codex-cli")
      p.executable = Utf8(Text(H(6006)));
    else
      p.base_url = Utf8(Text(H(6006)));
    p.model = Utf8(Text(H(6007)));
    auto key = Text(H(6008));
    if (p.kind == "openai-compatible") {
      auto prior = secrets.find(p.id);
      if (prior != secrets.end()) {
        if (!prior->second.empty())
          SecureZeroMemory(prior->second.data(),
                           prior->second.size() * sizeof(wchar_t));
        secrets.erase(prior);
      }
      // A blank field preserves the credential already in the vault, not a
      // draft the user typed and subsequently erased in this dialog.
      if (!key.empty())
        secrets.emplace(p.id, key);
    }
    if (!key.empty())
      SecureZeroMemory(key.data(), key.size() * sizeof(wchar_t));
  }
  void ShowConnection() {
    syncing = true;
    SendMessageW(H(6000), CB_RESETCONTENT, 0, 0);
    for (const auto &p : config.connections) {
      const auto text = Wide(p.name);
      SendMessageW(H(6000), CB_ADDSTRING, 0,
                   reinterpret_cast<LPARAM>(text.c_str()));
    }
    SendMessageW(H(6000), CB_SETCURSEL, selected, 0);
    const auto &p = config.connections.at(selected);
    Set(H(6004), Wide(p.name));
    SendMessageW(H(6005), CB_SETCURSEL, p.kind == "codex-cli" ? 1 : 0, 0);
    Set(H(6006), Wide(p.kind == "codex-cli" ? p.executable : p.base_url));
    SendMessageW(H(6007), CB_RESETCONTENT, 0, 0);
    Set(H(6007), Wide(p.model));
    Set(H(6008), secrets.contains(p.id) ? secrets.at(p.id) : L"");
    EnableWindow(H(6008), p.kind != "codex-cli");
    Set(H(6106), p.kind == "codex-cli" ? L"Codex 路径" : L"API 地址");
    Set(H(6009), p.kind == "codex-cli" ? L"检查安装与登录" : L"读取模型列表");
    syncing = false;
  }
  void ShowMappings() {
    SendMessageW(H(6020), LB_RESETCONTENT, 0, 0);
    for (const auto &row : profile.at("mappings")) {
      const auto line =
          Wide(row.at("keys").get<std::string>() + "   →   " +
               row.at("output").get<std::string>() +
               (row.at("kind") == "syllable" ? "  · 音节" : "  · 片段"));
      SendMessageW(H(6020), LB_ADDSTRING, 0,
                   reinterpret_cast<LPARAM>(line.c_str()));
    }
    Set(H(6010), Wide(profile.value("name", "isaac2026")));
    Set(H(6014), Wide(profile.at("leftKeys")));
    Set(H(6015), Wide(profile.at("rightKeys")));
  }
  void CaptureProfile() {
    profile["name"] = Utf8(Text(H(6010)));
    profile["leftKeys"] = Utf8(Text(H(6014)));
    profile["rightKeys"] = Utf8(Text(H(6015)));
  }
  void File(bool save) {
    CaptureProfile();
    wchar_t path[32768] = L"isaac2026-keymap.json";
    OPENFILENAMEW dialog{};
    dialog.lStructSize = sizeof(dialog);
    dialog.hwndOwner = parent;
    dialog.lpstrFilter = L"并击键位 JSON\0*.json\0\0";
    dialog.lpstrDefExt = L"json";
    dialog.lpstrFile = path;
    dialog.nMaxFile = 32768;
    dialog.Flags = OFN_NOCHANGEDIR | OFN_PATHMUSTEXIST |
                   (save ? OFN_OVERWRITEPROMPT : OFN_FILEMUSTEXIST);
    if (!(save ? GetSaveFileNameW(&dialog) : GetOpenFileNameW(&dialog)))
      return;
    const std::filesystem::path file(path);
    if (std::filesystem::is_symlink(file))
      throw std::runtime_error("不能使用符号链接。");
    if (save) {
      (void)ChordProfile::Parse(profile);
      auto temporary = file;
      temporary += L".xsime-" + Wide(ID()) + L".tmp";
      std::ofstream out(temporary, std::ios::binary);
      out << profile.dump(2);
      out.close();
      if (!out ||
          !MoveFileExW(temporary.c_str(), file.c_str(),
                       MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)) {
        std::filesystem::remove(temporary);
        throw std::runtime_error("导出失败。");
      }
      Status(L"已导出键位配置。应用到输入法仍需点击保存。");
    } else {
      if (!std::filesystem::is_regular_file(file) ||
          std::filesystem::file_size(file) > 2 * 1024 * 1024)
        throw std::runtime_error("键位文件过大或类型无效。");
      std::ifstream in(file, std::ios::binary);
      auto imported = core::Json::parse(
          in, [](int depth, core::Json::parse_event_t, core::Json &) {
            if (depth > 16)
              throw std::runtime_error("键位文件嵌套过深。");
            return true;
          });
      (void)ChordProfile::Parse(imported);
      imported["id"] = ID();
      profile = std::move(imported);
      ShowMappings();
      Status(L"已导入为新键位草稿。点击保存后生效；取消保留原配置。");
    }
  }
};
ParitySettings::ParitySettings() : impl_(std::make_unique<Impl>()) {}
ParitySettings::~ParitySettings() = default;
void ParitySettings::Create(HWND parent, const Settings &settings) {
  auto &p = *impl_;
  p.parent = parent;
  p.config = settings;
  MigrateConnections(&p.config);
  for (std::size_t i = 0; i < p.config.connections.size(); ++i)
    if (p.config.connections[i].id == p.config.active_connection)
      p.selected = i;
  p.profile = settings.chord_profile.is_null() ? BuiltinChordProfile()
                                               : settings.chord_profile;
  p.Combo(6000);
  p.Button(6001, L"新增 API");
  p.Button(6002, L"新增 Codex");
  p.Button(6003, L"删除");
  p.Edit(6004);
  p.Combo(6005, {L"OpenAI 兼容 API", L"Codex CLI"});
  p.Edit(6006);
  p.Combo(6007, {}, true);
  p.Edit(6008, true);
  p.Button(6009, L"读取模型列表");
  p.Label(6104, L"配置名称");
  p.Label(6105, L"连接方式");
  p.Label(6106, L"API 地址");
  p.Label(6107, L"模型");
  p.Label(6108, L"密钥（留空保留已保存密钥）");
  p.Label(
      6110,
      L"保存后，该配置用于 AI 生成与 AI 翻译。每个 API 的密钥独立存储。\nCodex "
      L"路径和模型可留空；复用本机 codex login 登录，不需要填写 API 密钥。");
  p.Edit(6010);
  p.Combo(6011, {L"开启并击", L"关闭并击 · 使用全拼"});
  p.Edit(6012);
  p.Button(6013, L"恢复 isaac2026");
  p.Edit(6014);
  p.Edit(6015);
  p.Button(6016, L"导入 JSON…");
  p.Button(6017, L"导出 JSON…");
  p.Label(6111, L"键位名称");
  p.Label(6112, L"并击开关");
  p.Label(6113, L"组键间隔（10–300 ms）");
  p.Label(6114, L"左手键区");
  p.Label(6115, L"右手键区");
  p.Label(6116, L"选择输入法 → isaac2026 "
                L"后使用。左右相邻批次可按完整音节映射重组。\n编辑、焦点或方案"
                L"变化会结束配对；所有改动在保存后生效。");
  p.Add(6020, L"LISTBOX", L"",
        WS_TABSTOP | WS_VSCROLL | LBS_NOTIFY | LBS_NOINTEGRALHEIGHT);
  p.Edit(6021);
  p.Edit(6022);
  p.Combo(6023, {L"完整音节", L"拼音片段"});
  p.Button(6024, L"新增 / 更新映射");
  p.Button(6025, L"删除所选");
  p.Label(6121, L"组合键，例如 dv");
  p.Label(6122, L"全拼输出，例如 n");
  p.Edit(6026);
  p.Button(6027, L"检查组合");
  p.Label(6126, L"组合预览：输入组合键，检查映射输出；不写入宿主或词库。");
  p.Edit(6030);
  p.Edit(6031);
  p.Combo(6032, {L"固定所选主题", L"跟随 Windows 明暗"});
  p.Edit(6033);
  p.Edit(6034);
  p.Edit(6035);
  p.Label(6130, L"工作台默认宽度（520–1100）");
  p.Label(6131, L"长按发送全部（500–3000 ms）");
  p.Label(6132, L"系统外观");
  p.Label(6133, L"候选最大宽度（240–1200）");
  p.Label(6134, L"候选条最小高度（28–72）");
  p.Label(6135, L"序号字号（8–24）");
  p.Label(6099, L"");
  Set(p.H(6030), std::to_wstring(settings.buffer_width));
  Set(p.H(6031), std::to_wstring(settings.send_hold_ms));
  Set(p.H(6033), std::to_wstring(settings.candidate_width));
  Set(p.H(6034), std::to_wstring(settings.candidate_height));
  Set(p.H(6035), std::to_wstring(settings.candidate_label_size));
  SendMessageW(p.H(6032), CB_SETCURSEL, settings.follow_system_theme ? 1 : 0,
               0);
  SendMessageW(p.H(6011), CB_SETCURSEL, settings.chord_enabled ? 0 : 1, 0);
  Set(p.H(6012), std::to_wstring(settings.chord_interval_ms));
  SendMessageW(p.H(6023), CB_SETCURSEL, 0, 0);
  p.ShowConnection();
  p.ShowMappings();
}
void ParitySettings::Layout(ui::SettingsPage page, int subpage,
                            const ui::DipRect &body, unsigned dpi, HFONT font) {
  auto &p = *impl_;
  p.edit_frames.clear();
  for (auto [id, h] : p.controls) {
    ShowWindow(h, SW_HIDE);
    SendMessageW(h, WM_SETFONT, reinterpret_cast<WPARAM>(font), TRUE);
  }
  const float x = body.left, y = body.top, w = body.width();
  auto put = [&](unsigned id, float left, float top, float width,
                 float height) {
    const float scale = static_cast<float>(dpi) / 96;
    wchar_t kind[20]{};
    GetClassNameW(p.H(id), kind, 20);
    if (_wcsicmp(kind, L"EDIT") == 0) {
      p.edit_frames.push_back(
          {x + left, y + top, x + left + width, y + top + height});
      left += 8;
      top += 6;
      width -= 16;
      height -= 11;
    }
    MoveWindow(p.H(id), static_cast<int>((x + left) * scale),
               static_cast<int>((y + top) * scale),
               static_cast<int>(width * scale),
               static_cast<int>(height * scale), TRUE);
    if (std::wstring(kind) == L"ComboBox") {
      SendMessageW(p.H(id), CB_SETITEMHEIGHT, static_cast<WPARAM>(-1),
                   static_cast<LPARAM>(23 * scale));
      SendMessageW(p.H(id), CB_SETITEMHEIGHT, 0,
                   static_cast<LPARAM>(23 * scale));
      if ((GetWindowLongPtrW(p.H(id), GWL_STYLE) & 3) == CBS_DROPDOWN) {
        COMBOBOXINFO info{sizeof(info)};
        RECT client{};
        if (GetComboBoxInfo(p.H(id), &info) &&
            GetClientRect(p.H(id), &client)) {
          const int inset = static_cast<int>(8 * scale);
          const int text_height = static_cast<int>(17 * scale);
          SetWindowPos(info.hwndItem, nullptr, inset,
                       (client.bottom - text_height) / 2,
                       client.right - static_cast<int>(36 * scale), text_height,
                       SWP_NOZORDER | SWP_NOACTIVATE);
        }
      }
    }
    ShowWindow(p.H(id), SW_SHOW);
  };
  auto row = [&](unsigned id, unsigned label, float top, bool combo = false) {
    put(label, 16, top + 5, 210, 24);
    const bool number =
        id == 6012 || id == 6030 || id == 6031 || (id >= 6033 && id <= 6035);
    put(id, 232, top, number ? 96.f : w - 248, combo ? 150.f : 29.f);
  };
  if (page == ui::SettingsPage::kApi) {
    if (subpage == 0) {
      put(6000, 16, 0, w - 332, 200);
      put(6001, w - 304, 0, 96, 30);
      put(6002, w - 200, 0, 104, 30);
      put(6003, w - 88, 0, 72, 30);
      row(6004, 6104, 48);
      row(6005, 6105, 90, true);
      row(6006, 6106, 132);
      row(6007, 6107, 174, true);
      row(6008, 6108, 216);
      put(6009, 232, 258, 180, 32);
      put(6099, 16, 308, w - 32, 60);
    } else {
      put(6110, 16, 0, w - 32, 110);
      put(6009, 16, 128, 190, 34);
      put(6099, 16, 180, w - 32, 90);
    }
  } else if (page == ui::SettingsPage::kChord) {
    if (subpage == 0) {
      row(6010, 6111, 0);
      row(6011, 6112, 44, true);
      row(6012, 6113, 88);
      row(6014, 6114, 132);
      row(6015, 6115, 176);
      put(6016, 16, 226, 130, 32);
      put(6017, 154, 226, 130, 32);
      put(6013, 292, 226, 150, 32);
      put(6116, 16, 276, w - 32, 58);
      put(6099, 16, 340, w - 32, 45);
    } else {
      put(6020, 16, 0, w - 32, 155);
      put(6121, 16, 170, 180, 24);
      put(6122, 210, 170, 180, 24);
      put(6021, 16, 198, 178, 29);
      put(6022, 210, 198, 178, 29);
      put(6023, 404, 198, w - 420, 130);
      put(6024, 16, 240, 160, 30);
      put(6025, 186, 240, 120, 30);
      put(6126, 16, 282, w - 32, 24);
      put(6026, 16, 314, 180, 29);
      put(6027, 210, 314, 180, 30);
      put(6099, 16, 355, w - 32, 38);
    }
  } else if (page == ui::SettingsPage::kAppearance) {
    if (subpage == 1) {
      row(6033, 6133, 146);
      row(6034, 6134, 190);
      row(6035, 6135, 234);
      row(6030, 6130, 278);
    } else
      row(6032, 6132, 292, true);
  } else if (page == ui::SettingsPage::kBuffer && subpage == 0)
    row(6031, 6131, 326);
}
void ParitySettings::PaintFields(HDC dc, ui::ThemeId theme,
                                 unsigned dpi) const {
  const auto &palette = ui::Palette(theme);
  const float scale = static_cast<float>(dpi) / 96;
  for (const auto &box : impl_->edit_frames) {
    const RECT pixels{static_cast<LONG>(box.left * scale),
                      static_cast<LONG>(box.top * scale),
                      static_cast<LONG>(box.right * scale),
                      static_cast<LONG>(box.bottom * scale)};
    ui::FillRoundRect(dc, pixels, MulDiv(8, static_cast<int>(dpi), 96),
                      ui::ToColorRef(palette.surface));
    ui::StrokeRoundRect(dc, pixels, MulDiv(8, static_cast<int>(dpi), 96),
                        ui::ToColorRef(palette.border));
  }
}
bool ParitySettings::Command(unsigned id, unsigned notification) {
  auto &p = *impl_;
  if (id < 6000 || id >= 6100 || p.syncing)
    return false;
  if (id >= 6000 && id <= 6008 &&
      (notification == EN_CHANGE || notification == CBN_EDITCHANGE ||
       notification == CBN_SELCHANGE))
    ++p.generation;
  try {
    if (id == 6000 && notification == CBN_SELCHANGE) {
      auto selected = SendMessageW(p.H(6000), CB_GETCURSEL, 0, 0);
      p.CaptureConnection();
      if (selected >= 0 &&
          static_cast<std::size_t>(selected) < p.config.connections.size())
        p.selected = static_cast<std::size_t>(selected);
      p.ShowConnection();
      p.Status(L"当前显示的是配置草稿；保存后切换连接器。");
    } else if (id == 6005 && notification == CBN_SELCHANGE) {
      const bool codex = SendMessageW(p.H(6005), CB_GETCURSEL, 0, 0) == 1;
      p.CaptureConnection();
      auto &c = p.config.connections[p.selected];
      c.kind = codex ? "codex-cli" : "openai-compatible";
      Set(p.H(6006), Wide(codex ? c.executable : c.base_url));
      p.ShowConnection();
    } else if ((id == 6001 || id == 6002) && notification == BN_CLICKED) {
      ++p.generation;
      p.CaptureConnection();
      if (p.config.connections.size() >= 32)
        throw std::runtime_error("最多保存 32 个连接器。");
      p.config.connections.push_back(
          {ID(), id == 6002 ? "Codex" : "新的 API",
           id == 6002 ? "codex-cli" : "openai-compatible", "", "", ""});
      p.selected = p.config.connections.size() - 1;
      p.ShowConnection();
    } else if (id == 6003 && notification == BN_CLICKED) {
      if (p.config.connections.size() < 2)
        throw std::runtime_error("至少保留一个连接器。");
      ++p.generation;
      p.config.connections.erase(p.config.connections.begin() +
                                 static_cast<std::ptrdiff_t>(p.selected));
      p.selected = 0;
      p.ShowConnection();
    } else if (id == 6009 && notification == BN_CLICKED) {
      if (p.probe)
        return true;
      p.CaptureConnection();
      const auto profile = p.config.connections[p.selected];
      auto state = std::make_shared<Impl::Probe>();
      state->id = profile.id;
      p.probe = state;
      p.probe_generation = p.generation;
      auto key = p.secrets.contains(profile.id) ? p.secrets.at(profile.id)
                                                : std::wstring();
      p.Status(L"正在检查连接…输入法继续可用。");
      std::thread([state, profile, key = std::move(key)]() mutable {
        auto result = ProbeConnection(profile, key);
        if (!key.empty())
          SecureZeroMemory(key.data(), key.size() * sizeof(wchar_t));
        std::lock_guard lock(state->mutex);
        state->result = std::move(result);
        state->done = true;
      }).detach();
    } else if ((id == 6016 || id == 6017) && notification == BN_CLICKED)
      p.File(id == 6017);
    else if (id == 6013 && notification == BN_CLICKED) {
      p.profile = BuiltinChordProfile();
      p.ShowMappings();
      p.Status(L"已恢复 isaac2026 草稿。点击保存后生效。");
    } else if (id == 6020 && notification == LBN_SELCHANGE) {
      auto row = SendMessageW(p.H(6020), LB_GETCURSEL, 0, 0);
      if (row >= 0) {
        const auto &m =
            p.profile.at("mappings").at(static_cast<std::size_t>(row));
        Set(p.H(6021), Wide(m.at("keys")));
        Set(p.H(6022), Wide(m.at("output")));
        SendMessageW(p.H(6023), CB_SETCURSEL,
                     m.at("kind") == "syllable" ? 0 : 1, 0);
      }
    } else if (id == 6024 && notification == BN_CLICKED) {
      p.CaptureProfile();
      auto candidate = p.profile;
      const auto parsed = ChordProfile::Parse(candidate);
      const auto keys = Utf8(Text(p.H(6021)));
      auto &rows = candidate["mappings"];
      auto found = std::find_if(rows.begin(), rows.end(), [&](const auto &r) {
        return parsed.Canonical(r.at("keys")) == parsed.Canonical(keys);
      });
      core::Json row = {
          {"keys", keys},
          {"output", Utf8(Text(p.H(6022)))},
          {"kind", SendMessageW(p.H(6023), CB_GETCURSEL, 0, 0) == 0
                       ? "syllable"
                       : "fragment"}};
      if (found == rows.end())
        rows.push_back(row);
      else
        *found = row;
      candidate["id"] = candidate.value("id", "") == "builtin.flyyao"
                            ? ID()
                            : candidate.at("id").get<std::string>();
      (void)ChordProfile::Parse(candidate);
      p.profile = std::move(candidate);
      p.ShowMappings();
      p.Status(L"映射草稿已更新。保存后用于输入。");
    } else if (id == 6025 && notification == BN_CLICKED) {
      auto row = SendMessageW(p.H(6020), LB_GETCURSEL, 0, 0);
      if (row >= 0 && p.profile["mappings"].size() > 1) {
        p.profile["mappings"].erase(static_cast<std::size_t>(row));
        p.ShowMappings();
      }
    } else if (id == 6027 && notification == BN_CLICKED) {
      p.CaptureProfile();
      const auto profile = ChordProfile::Parse(p.profile);
      const auto keys = Utf8(Text(p.H(6026)));
      const auto *mapping = profile.Find(keys);
      p.Status(mapping
                   ? Wide(profile.Canonical(keys) + " → " + mapping->output +
                          (mapping->kind == "syllable" ? " · 完整音节"
                                                       : " · 拼音片段"))
                   : L"此组合没有映射；检查左右键区或新增映射。");
    } else
      return false;
  } catch (const std::exception &error) {
    p.Status(Wide(error.what()));
  }
  return true;
}
void ParitySettings::Tick() {
  auto &p = *impl_;
  if (!p.probe)
    return;
  auto state = p.probe;
  std::lock_guard lock(state->mutex);
  if (!state->done)
    return;
  if (state->id == p.config.connections[p.selected].id &&
      p.probe_generation == p.generation) {
    const auto current = Text(p.H(6007));
    SendMessageW(p.H(6007), CB_RESETCONTENT, 0, 0);
    for (const auto &model : state->result.models) {
      const auto name = Wide(model);
      SendMessageW(p.H(6007), CB_ADDSTRING, 0,
                   reinterpret_cast<LPARAM>(name.c_str()));
    }
    Set(p.H(6007), current);
    p.Status(Wide(state->result.message));
  }
  p.probe.reset();
}
bool ParitySettings::Read(Settings *settings, std::string *error) {
  auto &p = *impl_;
  try {
    p.CaptureConnection();
    p.CaptureProfile();
    (void)ChordProfile::Parse(p.profile);
    settings->connections = p.config.connections;
    if (!SelectConnection(settings, p.config.connections[p.selected].id))
      return false;
    settings->buffer_width = Number(p.H(6030));
    settings->send_hold_ms = Number(p.H(6031));
    settings->follow_system_theme =
        SendMessageW(p.H(6032), CB_GETCURSEL, 0, 0) == 1;
    settings->candidate_width = Number(p.H(6033));
    settings->candidate_height = Number(p.H(6034));
    settings->candidate_label_size = Number(p.H(6035));
    settings->chord_enabled = SendMessageW(p.H(6011), CB_GETCURSEL, 0, 0) == 0;
    settings->chord_interval_ms = Number(p.H(6012));
    settings->chord_profile = p.profile;
    if (!ValidSettings(*settings))
      throw std::runtime_error(
          "请检查连接器名称、数字范围和键位配置；原设置保持不变。");
    return true;
  } catch (const std::exception &e) {
    if (error)
      *error = e.what();
    return false;
  }
}
const std::map<std::string, std::wstring> &ParitySettings::Secrets() const {
  return impl_->secrets;
}
std::vector<HWND> ParitySettings::VisibleControls() const {
  std::vector<HWND> result;
  for (const auto &[id, control] : impl_->controls)
    if ((GetWindowLongPtrW(control, GWL_STYLE) & (WS_VISIBLE | WS_TABSTOP)) ==
            (WS_VISIBLE | WS_TABSTOP) &&
        IsWindowEnabled(control))
      result.push_back(control);
  return result;
}
} // namespace rimes::windows::workbench
