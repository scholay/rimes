#pragma once
#include <Windows.h>

#include <cstdint>
#include <functional>
#include <string>

#include "model.hpp"
#include "../core/control.hpp"
#include <map>
namespace rimes::windows::workbench {
struct ConnectionProfile {
  std::string id, name, kind = "openai-compatible", base_url, model, executable;
};
struct Settings {
  std::vector<ConnectionProfile> connections;
  std::string active_connection;
  unsigned buffer_width = 680, send_hold_ms = 1200;
  bool follow_system_theme = false;
  unsigned candidate_width = 460, candidate_height = 34, candidate_label_size = 10;
  bool chord_enabled = true;
  unsigned chord_interval_ms = 50;
  core::Json chord_profile; // Applied portable keymap snapshot, never a draft.
  bool imported_scheme = false;  // Runtime-only; never persisted to settings.json.
  std::uint64_t revision = 1;
  std::string schema = "rime_ice", base_url, model, target_language = "English";
  std::string ai_connector = "openai-compatible", codex_path, codex_model;
  std::string translation_provider = "local";
  unsigned auto_send_seconds = 0;
  bool close_after_send = true;
  // Persisted appearance colorway: night|day|quiet|rasta. Default night.
  std::string theme = "night";
  bool ascii = false, traditional = false, ascii_punctuation = false;
  unsigned candidate_count = 9;
  bool vertical_candidates = false;
  unsigned font_size = 16, hotkey_modifiers = MOD_ALT | MOD_SHIFT,
           hotkey_key = 'B';
  unsigned send_modifiers = MOD_ALT | MOD_SHIFT, send_key = VK_RETURN;
};
void MigrateConnections(Settings* settings);
bool SelectConnection(Settings* settings, const std::string& id);
bool ValidConnections(const Settings& settings);
std::string EffectiveTheme(const Settings& settings);
std::string CredentialIdentity(const Settings& settings);
std::wstring Wide(const std::string& text);
std::string Utf8(const std::wstring& text);
bool LoadSettings(Settings* value, std::string* error);
bool ValidSettings(const Settings& value);
bool SaveSettings(const Settings& value, std::string* error);
bool SaveSecret(const std::wstring& key, const std::string& endpoint,
                std::string* error, const std::string& identity = "");
bool HasSecret();
bool SaveConnectionSecrets(const Settings&, const std::map<std::string, std::wstring>&, std::string*);
// Internal dependency seam used by the loopback transport tests; no UI supplies
// a key here.
bool GenerateWithKey(const Settings& config, const Generation& job,
                     std::wstring key,
                     const std::function<bool(const std::string&)>& chunk,
                     const std::function<bool()>& cancelled,
                     std::string* error);
bool GenerateAPI(const Settings& config, const Generation& job,
                 const std::function<bool(const std::string&)>& chunk,
                 const std::function<bool()>& cancelled, std::string* error);
// Common text-connector seam. Both transports obey the frozen Generation and
// cancellation contract; only Runtime may publish or deliver their output.
bool GenerateText(const Settings& config, const Generation& job,
                  const std::function<bool(const std::string&)>& chunk,
                  const std::function<bool()>& cancelled, std::string* error);
}  // namespace rimes::windows::workbench
