#pragma once

#include <Windows.h>

#include <functional>
#include <string>

#include "../ui/settings_layout.hpp"
#include "../ui/settings_paint.hpp"
#include "provider.hpp"
#include "official_plugins.hpp"

namespace rimes::windows::workbench {

struct SettingsUiCallbacks {
  std::function<Settings()> load;
  std::function<bool(Settings, const std::wstring& key, bool replace_key,
                     std::string* error)>
      save;
  // Theme is owned by parent capture/JSON pipeline; UI keeps a local preview
  // until Save, then notifies the host. Close without Save restores this.
  std::function<ui::ThemeId()> load_theme;
  std::function<void()> on_closed;
  std::function<void(ui::ThemeId)> on_theme_preview;
  std::wstring about_text;
  std::function<std::vector<PluginView>()> plugins;
  std::function<bool(const std::string&, const std::string&, std::string*)> manage_plugin;
  std::function<std::string()> plugin_status;
};

// Production and visual-preview share this host. Preview passes fixture
// callbacks that never touch Runtime, Credential Manager, or settings.json.
class SettingsUiHost {
 public:
  explicit SettingsUiHost(SettingsUiCallbacks callbacks);
  ~SettingsUiHost();

  void Open(HWND owner);
  void Close(bool persist);
  [[nodiscard]] bool IsOpen() const noexcept { return hwnd_ != nullptr; }
  [[nodiscard]] HWND hwnd() const noexcept { return hwnd_; }
  bool HandleDialogMessage(MSG* message);

 private:
  void SyncDraftFromConfig(const Settings& config);
  void Relayout();
  void CreateOrUpdateChildren();
  void ApplyControlTheme();
  void ThemeEdits();
  void UpdatePlugins();
  bool CommitSave();
  void Paint(HDC dc);
  void InvalidateHover(int hit);
  void ActivateHit(int hit);
  static LRESULT CALLBACK Procedure(HWND, UINT, WPARAM, LPARAM);

  SettingsUiCallbacks callbacks_;
  ui::SettingsDraft draft_{};
  ui::SettingsLayout layout_{};
  ui::SettingsFonts fonts_{};
  ui::ThemeId opened_theme_ = ui::ThemeId::kNight;
  bool saved_ = false;
  HWND hwnd_ = nullptr;
  HWND owner_ = nullptr;
  HWND edit_font_ = nullptr;
  HWND edit_candidate_count_ = nullptr;
  HWND check_vertical_ = nullptr;
  HWND edit_hotkey_ = nullptr;
  HWND combo_hotkey_modifiers_ = nullptr;
  HWND edit_base_ = nullptr;
  HWND combo_connector_ = nullptr, edit_codex_path_ = nullptr, edit_codex_model_ = nullptr;
  HWND edit_model_ = nullptr;
  HWND edit_key_ = nullptr;
  HWND edit_lang_ = nullptr;
  HWND check_ascii_ = nullptr;
  HWND check_trad_ = nullptr;
  HWND check_punct_ = nullptr;
  std::array<HWND,4> plugin_labels_{}, plugin_install_{}, plugin_enable_{}, plugin_remove_{};
  HWND plugin_status_ = nullptr;
  std::vector<PluginView> plugin_rows_;
  HBRUSH edit_brush_ = nullptr;
  unsigned dpi_ = 96;
  int pressed_hit_ = -2;
};

}  // namespace rimes::windows::workbench
