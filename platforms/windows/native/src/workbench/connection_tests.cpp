#include "chord_profile.hpp"
#include "provider.hpp"
#include "runtime.hpp"
#include <atomic>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <wincred.h>

using namespace rimes::windows::workbench;
namespace {
void Check(bool ok, const char *reason) {
  if (!ok)
    throw std::runtime_error(reason);
}
struct Fixture {
  std::wstring previous;
  std::filesystem::path directory;
  std::string prefix;
  Fixture() {
    const auto size = GetEnvironmentVariableW(L"LOCALAPPDATA", nullptr, 0);
    if (size) {
      previous.resize(size);
      GetEnvironmentVariableW(L"LOCALAPPDATA", previous.data(), size);
      previous.resize(wcslen(previous.c_str()));
    }
    prefix = "xsime-test-" + std::to_string(GetCurrentProcessId()) + "-" +
             std::to_string(GetTickCount64());
    directory = std::filesystem::temp_directory_path() / prefix;
    std::filesystem::create_directories(directory / L"RIMES");
    Check(SetEnvironmentVariableW(L"LOCALAPPDATA", directory.c_str()) != FALSE,
          "isolate settings");
  }
  ~Fixture() {
    for (const auto *suffix : {"-a", "-b"})
      CredDeleteW((L"RIMES.Windows.OpenAI." + Wide(prefix + suffix)).c_str(),
                  CRED_TYPE_GENERIC, 0);
    SetEnvironmentVariableW(L"LOCALAPPDATA",
                            previous.empty() ? nullptr : previous.c_str());
    std::error_code ignored;
    std::filesystem::remove_all(directory, ignored);
  }
};
bool Stored(const std::string &id, const std::wstring &key,
            const std::wstring &endpoint) {
  PCREDENTIALW credential = nullptr;
  if (!CredReadW((L"RIMES.Windows.OpenAI." + Wide(id)).c_str(),
                 CRED_TYPE_GENERIC, 0, &credential))
    return false;
  const bool same =
      credential->UserName && endpoint == credential->UserName &&
      key ==
          std::wstring(reinterpret_cast<wchar_t *>(credential->CredentialBlob),
                       credential->CredentialBlobSize / sizeof(wchar_t));
  if (credential->CredentialBlob)
    SecureZeroMemory(credential->CredentialBlob,
                     credential->CredentialBlobSize);
  CredFree(credential);
  return same;
}
} // namespace
int main() {
  try {
    Fixture fixture;
    const auto path = fixture.directory / L"RIMES/settings.json";
    std::ofstream(path)
        << R"({"version":4,"base_url":"https://old.invalid/v1","model":"legacy-model","ai_connector":"codex-cli","codex_path":"C:/Codex/codex.exe","codex_model":"cli-model"})";
    Settings s;
    Check(LoadSettings(&s, nullptr) && s.connections.size() == 2 &&
              s.active_connection == "codex",
          "v4 migration retains CLI selection");
    Check(SelectConnection(&s, "legacy-api") &&
              s.base_url == "https://old.invalid/v1" &&
              s.model == "legacy-model" &&
              CredentialIdentity(s) == "legacy-api",
          "migration retains old API and vault identity");
    const auto a = fixture.prefix + "-a", b = fixture.prefix + "-b";
    s.connections.push_back({a, "Provider A", "openai-compatible",
                             "https://a.invalid/v1", "a-model", ""});
    s.connections.push_back({b, "Provider B", "openai-compatible",
                             "https://b.invalid/v1", "b-model", ""});
    Check(SelectConnection(&s, b) && s.model == "b-model" &&
              s.ai_connector == "openai-compatible",
          "select profile projects provider request fields");
    s.buffer_width = 920;
    s.send_hold_ms = 1500;
    s.candidate_width = 720;
    s.candidate_height = 42;
    s.candidate_label_size = 12;
    s.follow_system_theme = true;
    s.chord_profile = BuiltinChordProfile();
    s.chord_interval_ms = 70;
    Check(SaveSettings(s, nullptr), "persist extended settings");
    Settings restored;
    Check(
        LoadSettings(&restored, nullptr) && restored.active_connection == b &&
            restored.connections.size() == 4 && restored.buffer_width == 920 &&
            restored.send_hold_ms == 1500 && restored.candidate_width == 720 &&
            restored.candidate_height == 42 &&
            restored.candidate_label_size == 12 &&
            restored.follow_system_theme &&
            restored.chord_profile == s.chord_profile &&
            restored.chord_interval_ms == 70,
        "restart preserves all profile, Buffer, appearance and keymap fields");
    std::string error;
    Check(SaveConnectionSecrets(s, {{a, L"synthetic-a"}, {b, L"synthetic-b"}},
                                &error),
          "save isolated test credentials");
    Check(Stored(a, L"synthetic-a", L"https://a.invalid/v1") &&
              Stored(b, L"synthetic-b", L"https://b.invalid/v1"),
          "credentials bind separately to profile and endpoint");
    Check(
        !SaveConnectionSecrets(
            s, {{a, L"replacement-a"}, {b, std::wstring(4096, L'x')}}, &error),
        "invalid second secret fails transaction");
    Check(Stored(a, L"synthetic-a", L"https://a.invalid/v1") &&
              Stored(b, L"synthetic-b", L"https://b.invalid/v1"),
          "failed transaction restores both previous credentials");
    auto invalid = s;
    invalid.connections.push_back(s.connections.front());
    Check(!SaveSettings(invalid, nullptr),
          "reject duplicate identity without replacing saved settings");
    invalid = s;
    invalid.active_connection = "missing";
    Check(!SaveSettings(invalid, nullptr), "reject unknown active profile");
    invalid = s;
    invalid.connections.back().model = std::string("bad\0model", 9);
    Check(!ValidSettings(invalid), "reject embedded NUL in model");
    invalid = s;
    invalid.chord_profile["mappings"][0]["keys"] = "aa";
    Check(!SaveSettings(invalid, nullptr),
          "invalid imported keymap cannot overwrite saved preferences");
    Check(LoadSettings(&restored, nullptr) &&
              restored.chord_profile == s.chord_profile &&
              restored.active_connection == b,
          "failed save preserves applied keymap and connector");
    std::ifstream input(path);
    const std::string bytes{std::istreambuf_iterator<char>(input), {}};
    input.close(); // Windows replacement requires the reader to release its handle.
    Check(bytes.find("synthetic-a") == std::string::npos &&
              bytes.find("synthetic-b") == std::string::npos,
          "settings never serialize credentials");
    std::atomic<unsigned> calls{0};
    std::atomic<bool> release{false}, finished{false}, frozen{false},
        rejected{false};
    Runtime runtime([&](const Settings &config, const Generation &,
                        const auto &chunk, const auto &cancelled,
                        std::string *) {
      frozen = config.active_connection == b &&
               config.base_url == "https://b.invalid/v1" &&
               config.model == "b-model";
      ++calls;
      const auto start = GetTickCount64();
      while (!release && GetTickCount64() - start < 3000)
        Sleep(2);
      rejected = cancelled() && !chunk("obsolete provider result");
      finished = true;
      return false;
    });
    const auto peer = GetCurrentProcessId() + 1;
    const auto target = runtime.Register(peer, 91, 92);
    runtime.Focus(target);
    runtime.Bind(peer);
    runtime.Paste("synthetic source");
    runtime.Generate(false);
    auto started = GetTickCount64();
    while (!calls && GetTickCount64() - started < 2500)
      Sleep(2);
    Check(calls == 1, "start a frozen request against provider B");
    auto replacement = runtime.Configuration();
    Check(SelectConnection(&replacement, a), "switch provider");
    Check(runtime.Configure(replacement, {}, false, nullptr),
          "apply a different active connector");
    release = true;
    started = GetTickCount64();
    while (!finished && GetTickCount64() - started < 2500)
      Sleep(2);
    Check(finished && frozen && rejected &&
              runtime.Snapshot()["result"] == "" &&
              runtime.Snapshot()["source"] == "synthetic source",
          "switching connectors cancels old output without consuming source");
    std::cout << "Connection migration, selection, credential "
                 "isolation/rollback and parity preferences passed\n";
    return 0;
  } catch (const std::exception &e) {
    std::cerr << e.what() << '\n';
    return 1;
  }
}
