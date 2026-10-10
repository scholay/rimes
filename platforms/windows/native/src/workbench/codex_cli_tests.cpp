#include "codex_cli.hpp"
#include <algorithm>
#include <cstdlib>
#include <iostream>
using namespace rimes::windows::workbench;
void Check(bool ok, const char* reason) { if (!ok) { std::cerr << reason << '\n'; std::exit(1); } }
int main(int argc, char** argv) {
  Check(argc == 2, "fixture path required");
  const std::string events = "{\"type\":\"turn.started\"}\n{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"你好💡\"}}\n{\"type\":\"turn.completed\"}";
  CodexJsonDecoder bytewise;
  for (const auto c : events) Check(bytewise.Feed(std::string_view(&c, 1)), "split UTF-8 JSONL");
  Check(bytewise.Finish() && bytewise.Text() == "你好💡", "authoritative Unicode final");
  for (const auto* line : {"{\"type\":\"turn.completed\"}\n", "{\"type\":\"turn.failed\"}\n", "broken\n",
      "{\"type\":\"item.started\",\"item\":{\"type\":\"mcp_tool_call\"}}\n"}) {
    CodexJsonDecoder decoder;
    Check(!decoder.Feed(line) && !decoder.Finish(), "reject malformed, failed, tool, missing final");
  }
  CodexJsonDecoder overflow;
  Check(!overflow.Feed(std::string(4 * 1024 * 1024 + 1, 'x')) && !overflow.Finish(), "bound output");
  Check(QuoteWindowsArgument(L"a b\\\"c\\") == L"\"a b\\\\\\\"c\\\\\"", "Windows quote/backslash rules");
  auto workspace = std::filesystem::temp_directory_path() /
      (L"rimes-codex-test-" + std::to_wstring(GetCurrentProcessId()) + L"-" + std::to_wstring(GetTickCount64()));
  std::filesystem::create_directory(workspace);
  const auto args = CodexTextArguments(workspace, "fixture model");
  Check(std::find(args.begin(), args.end(), L"--ignore-user-config") != args.end() &&
      std::find(args.begin(), args.end(), L"--strict-config") != args.end() &&
      std::find(args.begin(), args.end(), L"--ephemeral") != args.end() && args.back() == L"-", "isolated stdin invocation");
  const auto executable = std::filesystem::absolute(std::filesystem::path(Wide(argv[1])));
  for (const auto* mode : {L"success", L"malformed", L"tool", L"unfinished", L"nonzero", L"stderr", L"delay", L"blocked", L"cancel"}) {
    std::cout << "Process scenario: " << Utf8(mode) << std::endl;
    std::string result, error;
    const auto start = GetTickCount64(); const std::wstring value(mode);
    const bool ok = RunCodexTextProcess(executable, {value == L"cancel" ? L"delay" : value}, workspace,
        value == L"blocked" ? std::string(Model::kLimit, 'x') : "synthetic source & ; \"中文💡\"",
        [&](const auto& text) { result += text; return true; },
        [&] { return value == L"cancel" && GetTickCount64() - start > 50; }, &error, 500);
    Check(ok == (value == L"success"), "process success/failure contract");
    Check(result == (ok ? "你好💡" : ""), "never expose failed, partial, reasoning, or tool output");
    Check(GetTickCount64() - start < 2500, "prompt writer and process tree cancellation bounded");
    std::cout << "Scenario passed: " << Utf8(mode) << std::endl;
  }
  bool rejected = false;
  try { (void)ResolveCodex("C:/missing/codex.cmd"); } catch (...) { rejected = true; }
  Check(rejected, "explicit .cmd path fails closed without fallback");
  std::error_code cleanup_error;
  Check(std::filesystem::remove(workspace, cleanup_error) && !cleanup_error, "cancel waits for child exit and releases workspace");
  std::cout << "Codex decoder, isolation, Unicode, pipe, cancel, timeout, and failure tests passed\n";
}
