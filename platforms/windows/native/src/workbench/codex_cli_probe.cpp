// Opt-in real CLI probe. NOT part of CTest: sends only a synthetic prompt and
// exercises Runtime -> process -> result -> synthetic acknowledgement.
#include "runtime.hpp"
#include <filesystem>
#include <iostream>
using namespace rimes::windows::workbench;
int wmain(int argc, wchar_t** argv) {
  if (argc != 2) return 2;
  const auto root = std::filesystem::temp_directory_path() /
      (L"rimes-codex-probe-" + std::to_wstring(GetCurrentProcessId()) + L"-" + std::to_wstring(GetTickCount64()));
  std::filesystem::create_directory(root);
  SetEnvironmentVariableW(L"LOCALAPPDATA", root.c_str());
  bool success = false;
  {
    Runtime runtime;
    auto config = runtime.Configuration(); config.ai_connector = "codex-cli"; config.codex_path = Utf8(argv[1]);
    std::string error;
    if (!runtime.Configure(config, {}, false, &error)) { std::cerr << "configuration failed\n"; return 1; }
    const auto peer = GetCurrentProcessId() + 1;
    auto target = runtime.Register(peer, 1, 1); runtime.Focus(target); runtime.Bind(peer);
    const std::string source = "Reply exactly: RIMES_CODEX_OK";
    runtime.Paste(source); runtime.Generate(false);
    const auto start = GetTickCount64();
    while (runtime.Snapshot().value("busy", false) && GetTickCount64() - start < 125000) Sleep(20);
    const auto state = runtime.Snapshot();
    success = state.value("result", "") == "RIMES_CODEX_OK" && state.value("source", "") == source;
    if (success) {
      runtime.Send(false);
      auto event = runtime.Control({{"op", "wait"}, {"session", 1}}, peer);
      if (event.value("kind", "") == "capture") event = runtime.Control({{"op", "wait"}, {"session", 1}}, peer);
      success = event.value("kind", "") == "deliver" && event.value("text", "") == "RIMES_CODEX_OK";
      if (success) {
        runtime.Control({{"op", "ack"}, {"session", 1}, {"request", event["request"]}, {"accepted", true}}, peer);
        success = runtime.Snapshot().value("source", "") == "" && runtime.Snapshot().value("result", "") == "";
      }
    }
    // Diagnostic codes are host-produced, never CLI output or login secrets.
    if (!success) std::cerr << state.value("status", "Probe failed") << '\n';
    runtime.Stop();
  }
  std::error_code ignored; std::filesystem::remove_all(root, ignored);
  std::cout << "Runtime -> Codex CLI -> Buffer result -> synthetic delivery/ACK: " << (success ? "PASS" : "FAIL") << '\n';
  return success ? 0 : 1;
}
