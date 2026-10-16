#include <iostream>

#include "provider.hpp"
#include "parity_settings.hpp"
using namespace rimes::windows::workbench;
int wmain(int argc, wchar_t** argv) {
  if (argc != 3) return 2;
  Settings config;
  config.base_url = Utf8(argv[1]);
  config.model = "local-test";
  const auto mode = Utf8(argv[2]);
  if (mode.starts_with("models_")) {
    const auto started = GetTickCount64();
    const ConnectionProfile profile{"transport-test", "Transport fixture", "openai-compatible", config.base_url, "", ""};
    const auto result = ProbeConnection(profile, L"rimes-loopback-test");
    const bool expected = mode == "models_success";
    if (result.success != expected || (expected && result.models != std::vector<std::string>{"alpha", "beta"}) ||
        GetTickCount64() - started > 15000) {
      std::cerr << "Model discovery contract failed: " << mode << '\n'; return 1;
    }
    std::cout << "Model discovery scenario passed: " << mode << '\n'; return 0;
  }
  Generation job{1, 1, 1, "Hello.", false, 0, {}};
  job.instruction = "Respond to the user text. Return only the requested answer.";
  std::string result, error;
  const auto started = GetTickCount64();
  bool cancelled = false;
  const bool success = GenerateWithKey(
      config, job, L"rimes-loopback-test",
      [&](const auto& value) {
        result += value;
        if (mode == "cancel") cancelled = true;
        return !cancelled;
      },
      [&] { return cancelled; }, &error);
  const bool expected = mode == "success";
  if (success != expected || (success && result != "你好💡") ||
      GetTickCount64() - started > 15000) {
    std::cerr << "Transport assertion failed: " << mode << '\n';
    return 1;
  }
  std::cout << "Transport scenario passed: " << mode << '\n';
  return 0;
}
