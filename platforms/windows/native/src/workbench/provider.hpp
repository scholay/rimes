#pragma once
#include <Windows.h>

#include <cstdint>
#include <functional>
#include <string>

#include "model.hpp"
namespace rimes::windows::workbench {
struct Settings {
  std::uint64_t revision = 1;
  std::string schema = "rime_ice", base_url, model, target_language = "English";
  std::string ai_connector = "openai-compatible", codex_path, codex_model;
  // Persisted appearance colorway: night|day|quiet|rasta. Default night.
  std::string theme = "night";
  bool ascii = false, traditional = false, ascii_punctuation = false;
  unsigned candidate_count = 9;
  bool vertical_candidates = false;
  unsigned font_size = 16, hotkey_modifiers = MOD_CONTROL | MOD_SHIFT,
           hotkey_key = 'B';
};
std::wstring Wide(const std::string& text);
std::string Utf8(const std::wstring& text);
bool LoadSettings(Settings* value, std::string* error);
bool SaveSettings(const Settings& value, std::string* error);
bool SaveSecret(const std::wstring& key, const std::string& endpoint,
                std::string* error);
bool HasSecret();
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
