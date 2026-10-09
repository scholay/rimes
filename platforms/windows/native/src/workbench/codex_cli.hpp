#pragma once
#include "provider.hpp"
#include "../core/control.hpp"
#include <filesystem>
#include <string_view>
#include <vector>

namespace rimes::windows::workbench {
// Pure protocol decoder: only a successful terminal turn can authorize text.
// Reasoning and diagnostics are discarded; tool-shaped items fail closed.
class CodexJsonDecoder {
 public:
  bool Feed(std::string_view bytes);
  bool Finish();
  const std::string& Text() const { return text_; }
 private:
  bool Line(const std::string& line);
  std::string pending_, text_;
  std::size_t total_ = 0;
  bool started_ = false, done_ = false, failed_ = false;
};
std::wstring QuoteWindowsArgument(const std::wstring& value);
std::vector<std::wstring> CodexTextArguments(const std::filesystem::path& workspace,
                                            const std::string& model);
std::filesystem::path ResolveCodex(const std::string& override_path);
bool GenerateCodex(const Settings&, const Generation&,
                   const std::function<bool(const std::string&)>&,
                   const std::function<bool()>&, std::string*);
// Explicit test seam: runs the same pipe/job/timeout implementation with an
// inert fixture executable. Production always uses ResolveCodex.
bool RunCodexTextProcess(const std::filesystem::path& executable,
                         const std::vector<std::wstring>& arguments,
                         const std::filesystem::path& workspace,
                         const std::string& input,
                         const std::function<bool(const std::string&)>& chunk,
                         const std::function<bool()>& cancelled,
                         std::string* error, unsigned timeout_ms = 120000);
}
