#include "provider.hpp"

#include <filesystem>
#include <fstream>
#include <iostream>
#include <iterator>
#include <stdexcept>

using namespace rimes::windows::workbench;
namespace {
void Check(bool ok, const char* reason) {
  if (!ok) throw std::runtime_error(reason);
}
bool SameSettings(const Settings& a, const Settings& b) {
  return a.revision == b.revision && a.schema == b.schema &&
         a.base_url == b.base_url && a.model == b.model &&
         a.target_language == b.target_language && a.theme == b.theme &&
         a.ascii == b.ascii && a.traditional == b.traditional &&
         a.ascii_punctuation == b.ascii_punctuation &&
         a.font_size == b.font_size && a.candidate_count == b.candidate_count &&
         a.vertical_candidates == b.vertical_candidates &&
         a.hotkey_modifiers == b.hotkey_modifiers && a.hotkey_key == b.hotkey_key;
}

// Exercise the production load/save functions without reading real settings,
// touching credentials, or retaining API keys in any test artifact.
struct IsolatedSettings {
  std::filesystem::path root;
  std::wstring previous;
  bool had_previous = false;
  IsolatedSettings() {
    const DWORD size = GetEnvironmentVariableW(L"LOCALAPPDATA", nullptr, 0);
    if (size) {
      previous.resize(size);
      GetEnvironmentVariableW(L"LOCALAPPDATA", previous.data(), size);
      previous.resize(wcslen(previous.c_str()));
      had_previous = true;
    }
    root = std::filesystem::temp_directory_path() /
        (L"rimes-settings-test-" + std::to_wstring(GetCurrentProcessId()) +
         L"-" + std::to_wstring(GetTickCount64()));
    Check(!std::filesystem::exists(root), "test directory must be new");
    std::filesystem::create_directories(root / L"RIMES");
    Check(SetEnvironmentVariableW(L"LOCALAPPDATA", root.c_str()) != FALSE,
          "isolate LOCALAPPDATA");
  }
  ~IsolatedSettings() {
    SetEnvironmentVariableW(L"LOCALAPPDATA",
                             had_previous ? previous.c_str() : nullptr);
    std::error_code ignored;
    std::filesystem::remove_all(root, ignored);
  }
  std::filesystem::path path() const { return root / L"RIMES/settings.json"; }
};
}  // namespace

int main() {
  try {
    IsolatedSettings test;
    Settings settings;
    Check(LoadSettings(&settings, nullptr) && settings.theme == "night" &&
              settings.hotkey_modifiers == (MOD_CONTROL | MOD_SHIFT) &&
              settings.hotkey_key == 'B',
          "absent file uses night and Ctrl+Shift+B");
    for (const auto* theme : {"night", "day", "quiet", "rasta"}) {
      settings.theme = theme;
      settings.model = "fixture-model";
      Check(SaveSettings(settings, nullptr), "save theme");
      Settings restored;
      Check(LoadSettings(&restored, nullptr) && restored.theme == theme &&
                restored.model == settings.model,
            "round trip retains theme and unrelated settings");
    }
    settings.candidate_count = 5;
    settings.vertical_candidates = true;
    Check(SaveSettings(settings, nullptr), "save candidate options");
    Settings candidate_options;
    Check(LoadSettings(&candidate_options, nullptr) && candidate_options.candidate_count == 5 &&
          candidate_options.vertical_candidates, "candidate options persist");
    for (unsigned invalid : {0U, 10U}) {
      settings.candidate_count = invalid;
      Check(!SaveSettings(settings, nullptr), "reject invalid candidate counts");
    }
    settings.candidate_count = 5;
    settings.theme = "neon";
    Check(!SaveSettings(settings, nullptr), "reject unknown theme on save");
    Settings retained;
    Check(LoadSettings(&retained, nullptr) && retained.theme == "rasta",
          "failed save preserves previous file");
    for (const auto* json : {"{}", "{\"theme\":\"unknown\"}"}) {
      std::ofstream(test.path(), std::ios::trunc) << json;
      Settings legacy;
      Check(LoadSettings(&legacy, nullptr) && legacy.theme == "night" && legacy.candidate_count == 9 && !legacy.vertical_candidates &&
                legacy.hotkey_modifiers == (MOD_CONTROL | MOD_SHIFT) &&
                legacy.hotkey_key == 'B',
            "legacy and unknown themes fall back safely");
    }
    for (const unsigned modifiers : {MOD_CONTROL | MOD_ALT,
                                     MOD_CONTROL | MOD_SHIFT}) {
      for (const unsigned key : {'B', 'J'}) {
        std::ofstream(test.path(), std::ios::trunc)
            << "{\"version\":1,\"hotkey_modifiers\":" << modifiers
            << ",\"hotkey_key\":" << key << ",\"model\":\"retained-model\"}";
        Settings legacy;
        Check(LoadSettings(&legacy, nullptr) &&
                  legacy.hotkey_modifiers == modifiers && legacy.hotkey_key == key &&
                  legacy.model == "retained-model",
              "explicit legacy and new chords are never silently reassigned");
        Check(SaveSettings(legacy, nullptr), "save a preserved legacy chord");
        Settings restored;
        Check(LoadSettings(&restored, nullptr) &&
                  restored.hotkey_modifiers == modifiers && restored.hotkey_key == key &&
                  restored.model == "retained-model",
              "saving another preference retains the complete chord");
      }
    }
    for (const char* json : {"{\"hotkey_key\":74}",
                             "{\"version\":1,\"hotkey_key\":74}"}) {
      std::ofstream(test.path(), std::ios::trunc) << json;
      Settings legacy;
      Check(LoadSettings(&legacy, nullptr) &&
                legacy.hotkey_modifiers == (MOD_CONTROL | MOD_ALT) &&
                legacy.hotkey_key == 'J',
            "early key-only files retain their Ctrl+Alt shortcut");
    }
    std::ofstream(test.path(), std::ios::trunc)
        << "{\"version\":2,\"hotkey_key\":74}";
    Settings modern;
    Check(LoadSettings(&modern, nullptr) &&
              modern.hotkey_modifiers == (MOD_CONTROL | MOD_SHIFT) &&
              modern.hotkey_key == 'J',
          "modern key-only files use Ctrl+Shift");
    modern.hotkey_modifiers = MOD_CONTROL | MOD_ALT;
    Check(SaveSettings(modern, nullptr), "retain legacy before explicit migration");
    modern.hotkey_modifiers = MOD_CONTROL | MOD_SHIFT;
    Check(SaveSettings(modern, nullptr), "user explicitly chooses Ctrl+Shift");
    Settings migrated;
    Check(LoadSettings(&migrated, nullptr) &&
              migrated.hotkey_modifiers == (MOD_CONTROL | MOD_SHIFT) &&
              migrated.hotkey_key == 'J',
          "explicit migration preserves the custom letter");
    const unsigned invalid_modifiers[] = {
        0U, MOD_CONTROL, MOD_ALT | MOD_SHIFT,
        MOD_CONTROL | MOD_ALT | MOD_SHIFT};
    for (unsigned modifiers : invalid_modifiers) {
      migrated.hotkey_modifiers = modifiers;
      Check(!SaveSettings(migrated, nullptr), "unsupported modifier sets are rejected");
    }
    Settings after_rejection;
    Check(LoadSettings(&after_rejection, nullptr) &&
              after_rejection.hotkey_modifiers == (MOD_CONTROL | MOD_SHIFT) &&
              after_rejection.hotkey_key == 'J',
          "rejected modifier changes preserve the saved shortcut");
    Settings trusted;
    trusted.revision = 77;
    trusted.schema = "english";
    trusted.base_url = "https://example.invalid/v1";
    trusted.model = "trusted-model";
    trusted.target_language = "Chinese";
    trusted.theme = "quiet";
    trusted.ascii = trusted.traditional = trusted.ascii_punctuation = true;
    trusted.font_size = 21;
    trusted.candidate_count = 5;
    trusted.vertical_candidates = true;
    trusted.hotkey_modifiers = MOD_CONTROL | MOD_ALT;
    trusted.hotkey_key = 'J';
    for (const char* bad_json : {
             "{\"revision\":55,\"model\":\"partial\",\"hotkey_modifiers\":0,\"hotkey_key\":66}",
             "{\"hotkey_modifiers\":-1,\"hotkey_key\":66}",
             "{\"hotkey_modifiers\":6,\"hotkey_key\":-1}",
             "{\"revision\":55,\"font_size\":-1}",
             "{\"model\":\"partial\",\"theme\":5}",
             "{\"hotkey_modifiers\":\"6\"}", "[1,2]", "{"}) {
      std::ofstream(test.path(), std::ios::trunc) << bad_json;
      Settings current = trusted;
      std::string error;
      Check(!LoadSettings(&current, &error) && !error.empty() &&
                SameSettings(current, trusted),
            "invalid or partially parsed settings leave the complete trusted caller state intact");
      Settings defaults, initial_defaults = defaults;
      Check(!LoadSettings(&defaults, nullptr) && SameSettings(defaults, initial_defaults),
            "failed startup load cannot leak a bare or invalid global hotkey");
      std::ifstream original(test.path());
      const std::string original_json{std::istreambuf_iterator<char>(original),
                                      std::istreambuf_iterator<char>()};
      Check(original_json == bad_json, "failed load preserves the original file verbatim");
    }
    std::ofstream(test.path(), std::ios::trunc) << "{\"theme\":5}";
    Check(!LoadSettings(&retained, nullptr), "wrong JSON type fails load");
    std::cout << "Settings theme persistence and legacy compatibility passed\n";
    return 0;
  } catch (const std::exception& error) {
    std::cerr << error.what() << '\n';
    return 1;
  }
}
