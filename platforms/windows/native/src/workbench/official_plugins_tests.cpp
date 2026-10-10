#include "official_plugins.hpp"
#include "official_features.hpp"
#include <Windows.h>
#include <cstdlib>
#include <fstream>
#include <iostream>

namespace {
using namespace rimes::windows;
void Check(bool value, const char* reason) {
  if (!value) { std::cerr << "FAIL: " << reason << '\n'; std::exit(1); }
}
std::string GrantFor(workbench::OfficialPluginStore& store, const std::string& id) {
  for (const auto& entry : store.Entries()) if (entry.id == id) return entry.grant;
  return {};
}
}
int main() {
  const auto root = std::filesystem::temp_directory_path() /
      (L"rimes-plugin-test-" + std::to_wstring(GetCurrentProcessId()) + L"-" + std::to_wstring(GetTickCount64()));
  std::filesystem::create_directories(root);
  std::ofstream(root / L"settings.json") << "private settings";
  std::ofstream(root / L"user.db") << "private words";
  std::string error;
  const auto data = workbench::OfficialPluginStore::BundledData(official::kAI);
  const auto location = root / L"fresh" / L"plugins";
  {
    workbench::OfficialPluginStore store(location);
    Check(store.Entries().size() == 4, "exact Windows catalog");
    Check(!store.Grant(official::kCodex).empty(), "bundled Codex connector available offline");
    Check(official::Instruction(store.Package(official::kCodex), "English").find("Respond") != std::string::npos, "Codex package supplies text instruction");
    Check(!store.Grant(official::kTranslation).empty() && !store.Grant(official::kChord).empty(), "bundled features available offline");
    Check(store.Grant(official::kAI).empty(), "fresh optional AI not enabled");
    auto absent = GrantFor(store, official::kAI);
    Check(!absent.empty(), "absent package has an install generation");
    Check(!store.InstallData(official::kAI, data + " ", absent, &error), "tampered download rejected");
    Check(!store.InstallData(official::kChord, data, GrantFor(store, official::kChord), &error), "wrong identity rejected");
    Check(!store.Uninstall("../user.db", &error), "unknown traversal cannot delete data");
    Check(store.InstallData(official::kAI, data, absent, &error), "verified package installation");
    Check(store.Grant(official::kAI).empty(), "download does not enable itself");
    Check(store.Enable(official::kAI, true, &error), "explicit enable");
    const auto active = store.Grant(official::kAI);
    Check(!active.empty() && active != absent, "enable creates fresh authority");
    Check(store.Enable(official::kAI, false, &error) && store.Grant(official::kAI).empty(), "disable revokes authority");
    Check(store.Enable(official::kAI, true, &error) && store.Grant(official::kAI) != active, "re-enable cannot revive old jobs");
    const auto downloading = GrantFor(store, official::kAI);
    Check(store.Uninstall(official::kAI, &error), "uninstall writes tombstone");
    Check(!store.InstallData(official::kAI, data, downloading, &error), "late download cannot undo uninstall");
    Check(store.Uninstall(official::kTranslation, &error), "bundled package can be uninstalled");
  }
  {
    workbench::OfficialPluginStore restarted(location);
    Check(restarted.Grant(official::kAI).empty() && restarted.Grant(official::kTranslation).empty(), "restart preserves tombstones");
    Check(restarted.Install(official::kTranslation, &error), "bundled restore works offline");
    Check(restarted.Grant(official::kTranslation).empty(), "bundled restore remains disabled");
    Check(restarted.Enable(official::kTranslation, true, &error), "bundled restore explicit enable");
    auto package = restarted.Package(official::kTranslation);
    Check(official::Instruction(package, "Chinese").find("Chinese") != std::string::npos, "package instruction consumed");
    Check(restarted.InstallData(official::kAI, data, GrantFor(restarted, official::kAI), &error), "reinstall current generation");
    Check(restarted.Enable(official::kAI, true, &error), "reinstall enable");
    std::ofstream(location / L"builtin.openai-compatible.json", std::ios::trunc) << "corrupt";
    Check(restarted.Grant(official::kAI).empty(), "installed file is reverified before execution");
    Check(!restarted.Enable(official::kAI, true, &error), "corrupt file cannot be enabled");
    Check(restarted.Uninstall(official::kAI, &error), "corrupt package is removable");
    for (const bool obsolete : {false, true}) {
      Check(restarted.Enable(official::kTranslation, true, &error), "prepare repair fixture");
      const auto old = GrantFor(restarted, official::kTranslation);
      const auto receipt = location / L"builtin.apple-translation.state.json";
      std::string bytes = "corrupt receipt";
      if (obsolete) {
        std::ifstream input(receipt);
        auto value = core::Json::parse(input); value["sha256"] = std::string(64, '0'); bytes = value.dump();
      }
      std::ofstream(receipt, std::ios::trunc) << bytes;
      Check(restarted.Grant(official::kTranslation).empty(), "bad receipt remains unauthorized");
      Check(restarted.Install(official::kTranslation, &error), "explicit restore repairs bad receipt");
      Check(restarted.Grant(official::kTranslation).empty(), "repair does not enable execution");
      Check(!restarted.InstallData(official::kTranslation, workbench::OfficialPluginStore::BundledData(official::kTranslation), old, &error), "stale download cannot replace repaired installation");
    }
  }
  {
    workbench::OfficialPluginStore legacy(root / L"plugins");
    Check(!legacy.Grant(official::kAI).empty(), "old installation stays available without a download");
    Check(legacy.Uninstall(official::kAI, &error), "legacy removal");
    workbench::OfficialPluginStore again(root / L"plugins");
    Check(again.Grant(official::kAI).empty(), "migration never overrides explicit removal");
    Check(std::filesystem::file_size(root / L"settings.json") == 16 &&
          std::filesystem::file_size(root / L"user.db") == 13, "uninstall preserves private data");
  }
  std::ofstream(location / L"migration.json", std::ios::trunc) << "corrupt";
  std::filesystem::remove(location / L"builtin.fly-chord-learning.state.json");
  workbench::OfficialPluginStore corrupt(location);
  Check(corrupt.Grant(official::kChord).empty(), "corrupt migration fails closed");
  std::filesystem::remove_all(root);
  std::cout << "Official plugin install, integrity, migration, grants and tombstone tests passed\n";
}
