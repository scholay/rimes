#include "provider.hpp"

#include <filesystem>
#include <fstream>
#include <iostream>
#include <stdexcept>

using namespace rimes::windows::workbench;
namespace {
void Check(bool ok, const char* reason) {
  if (!ok) throw std::runtime_error(reason);
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
    Check(LoadSettings(&settings, nullptr) && settings.theme == "night",
          "absent file uses night");
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
      Check(LoadSettings(&legacy, nullptr) && legacy.theme == "night" && legacy.candidate_count == 9 && !legacy.vertical_candidates,
            "legacy and unknown themes fall back safely");
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
