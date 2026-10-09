#include "codex_cli.hpp"
#include <algorithm>
#include <array>
#include <atomic>
#include <memory>
#include <thread>

namespace rimes::windows::workbench {
using core::Json;
namespace {
struct Handle {
  HANDLE value = nullptr;
  ~Handle() { if (value && value != INVALID_HANDLE_VALUE) CloseHandle(value); }
  void Reset() { if (value) CloseHandle(value); value = nullptr; }
};
void Require(bool ok) { if (!ok) throw std::runtime_error("Codex process unavailable"); }
void Pipe(Handle& read, Handle& write, bool parent_reads) {
  SECURITY_ATTRIBUTES sa{sizeof(sa), nullptr, TRUE};
  Require(CreatePipe(&read.value, &write.value, &sa, 0) != FALSE);
  Require(SetHandleInformation(parent_reads ? read.value : write.value,
                               HANDLE_FLAG_INHERIT, 0) != FALSE);
}
std::wstring Environment(const wchar_t* name) {
  const DWORD size = GetEnvironmentVariableW(name, nullptr, 0);
  if (!size || size > 32768) return {};
  std::wstring result(size, 0);
  const auto count = GetEnvironmentVariableW(name, result.data(), size);
  if (!count || count >= size) return {};
  result.resize(count); return result;
}
// Let the official CLI resolve its own saved login, without reading credentials
// here or forwarding ambient API tokens, hooks, plugins, or task instructions.
std::vector<wchar_t> ChildEnvironment() {
  std::vector<std::wstring> entries;
  for (const auto* name : {L"APPDATA", L"LOCALAPPDATA", L"USERPROFILE", L"HOMEDRIVE",
      L"HOMEPATH", L"SYSTEMROOT", L"WINDIR", L"TEMP", L"TMP", L"PATH", L"CODEX_HOME",
      L"HTTPS_PROXY", L"HTTP_PROXY", L"ALL_PROXY", L"NO_PROXY", L"SSL_CERT_FILE", L"SSL_CERT_DIR"}) {
    auto value = Environment(name);
    if (!value.empty()) entries.push_back(std::wstring(name) + L"=" + value);
  }
  std::sort(entries.begin(), entries.end());
  std::vector<wchar_t> result;
  for (const auto& entry : entries) {
    result.insert(result.end(), entry.begin(), entry.end()); result.push_back(0);
  }
  result.push_back(0); return result;
}
bool ValidExecutable(const std::filesystem::path& path) {
  std::error_code ignored;
  auto extension = path.extension().wstring();
  std::transform(extension.begin(), extension.end(), extension.begin(), towlower);
  const auto attrs = GetFileAttributesW(path.c_str());
  return path.is_absolute() && extension == L".exe" &&
      attrs != INVALID_FILE_ATTRIBUTES && !(attrs & FILE_ATTRIBUTE_REPARSE_POINT) &&
      std::filesystem::is_regular_file(path, ignored);
}
struct Workspace {
  std::filesystem::path path;
  Workspace() {
    auto base = std::filesystem::temp_directory_path();
    for (unsigned i = 0; i < 100; ++i) {
      path = base / (L"rimes-codex-text-" + std::to_wstring(GetCurrentProcessId()) +
          L"-" + std::to_wstring(GetTickCount64()) + L"-" + std::to_wstring(i));
      if (std::filesystem::create_directory(path)) return;
    }
    throw std::runtime_error("Private Codex workspace unavailable");
  }
  ~Workspace() {
    // This directory is created here and should stay empty. Never recursively
    // erase an external workspace if a future CLI violates the text contract.
    std::error_code ignored; std::filesystem::remove(path, ignored);
  }
};
}
bool CodexJsonDecoder::Line(const std::string& line) {
  if (line.empty() || line == "\r") return true;
  try {
    const auto j = Json::parse(line);
    const auto type = j.at("type").get<std::string>();
    if (type == "error" || type == "turn.failed") return false;
    if (type == "turn.started") { if (started_ || done_) return false; started_ = true; }
    if (type == "item.started" || type == "item.updated" || type == "item.completed") {
      const auto& item = j.at("item");
      const auto kind = item.at("type").get<std::string>();
      if (kind != "agent_message" && kind != "reasoning" && kind != "error") return false;
      if (kind == "agent_message" && type == "item.completed") {
        if (!started_ || done_) return false;
        auto text = item.at("text").get<std::string>();
        if (text.empty() || text.size() > Model::kLimit || text.find('\0') != std::string::npos) return false;
        (void)Wide(text); text_ = std::move(text);
      }
    }
    if (type == "turn.completed") {
      if (!started_ || done_ || text_.empty()) return false;
      done_ = true;
    }
    return true;
  } catch (...) { return false; }
}
bool CodexJsonDecoder::Feed(std::string_view bytes) {
  if (failed_ || bytes.size() > 4 * 1024 * 1024 - total_) { failed_ = true; return false; }
  total_ += bytes.size(); pending_.append(bytes);
  std::size_t newline = 0;
  while ((newline = pending_.find('\n')) != std::string::npos) {
    if (!Line(pending_.substr(0, newline))) { failed_ = true; return false; }
    pending_.erase(0, newline + 1);
  }
  if (pending_.size() > Model::kLimit * 6) { failed_ = true; return false; }
  return true;
}
bool CodexJsonDecoder::Finish() {
  if (!pending_.empty() && !Line(pending_)) failed_ = true;
  pending_.clear(); return !failed_ && done_ && !text_.empty();
}
std::wstring QuoteWindowsArgument(const std::wstring& value) {
  std::wstring out = L"\""; unsigned slashes = 0;
  for (const wchar_t c : value) {
    if (c == L'\\') { ++slashes; continue; }
    out.append(c == L'\"' ? slashes * 2 + 1 : slashes, L'\\');
    slashes = 0; out += c;
  }
  out.append(slashes * 2, L'\\'); return out + L"\"";
}
std::vector<std::wstring> CodexTextArguments(const std::filesystem::path& workspace,
                                            const std::string& model) {
  std::vector<std::wstring> out{L"exec", L"--ignore-user-config", L"--ignore-rules",
      L"--strict-config", L"--skip-git-repo-check", L"--ephemeral", L"--json", L"--color", L"never"};
  for (const auto* flag : {L"shell_tool", L"unified_exec", L"shell_snapshot", L"apply_patch_freeform",
      L"standalone_web_search", L"apps", L"plugins", L"in_app_browser", L"browser_use",
      L"browser_use_external", L"browser_use_full_cdp_access", L"computer_use", L"code_mode",
      L"code_mode_only", L"enable_mcp_apps", L"memories", L"multi_agent", L"multi_agent_v2",
      L"collaboration_modes", L"hooks", L"skill_mcp_dependency_install", L"workspace_dependencies",
      L"tool_search", L"tool_suggest", L"goals", L"auth_elicitation", L"remote_plugin",
      L"plugin_sharing", L"guardian_approval", L"request_permissions_tool",
      L"tool_call_mcp_elicitation", L"code_mode_host", L"image_generation"}) {
    out.push_back(L"--disable"); out.push_back(flag);
  }
  const std::string profile = "permissions.rimes_text.filesystem={\":minimal\"=\"read\"," +
      Json(Utf8(workspace.generic_wstring())).dump(-1, ' ', false, Json::error_handler_t::strict) + "=\"read\"}";
  for (const auto& value : std::vector<std::string>{"approval_policy=\"never\"",
      "default_permissions=\"rimes_text\"", profile, "permissions.rimes_text.network.enabled=false",
      "tools.experimental_request_user_input={enabled=false}", "web_search=\"disabled\"",
      "project_doc_max_bytes=0", "skills.include_instructions=false", "include_environment_context=false",
      "include_apps_instructions=false", "include_collaboration_mode_instructions=false",
      "include_permissions_instructions=false"}) { out.push_back(L"-c"); out.push_back(Wide(value)); }
  if (!model.empty()) { out.push_back(L"--model"); out.push_back(Wide(model)); }
  out.push_back(L"-"); return out;
}
std::filesystem::path ResolveCodex(const std::string& override_path) {
  if (!override_path.empty()) {
    std::filesystem::path explicit_path(Wide(override_path));
    if (!ValidExecutable(explicit_path)) throw std::runtime_error("Configure an absolute Codex .exe path (not .cmd/.ps1).");
    return explicit_path;
  }
  const auto bundle = std::filesystem::path(Environment(L"LOCALAPPDATA")) / L"OpenAI/Codex/bin";
  std::vector<std::filesystem::path> candidates;
  std::error_code ec;
  if (std::filesystem::is_directory(bundle, ec))
    for (const auto& directory : std::filesystem::directory_iterator(bundle)) {
      auto path = directory.path() / L"codex.exe";
      if (ValidExecutable(path)) candidates.push_back(path);
    }
  std::sort(candidates.begin(), candidates.end(), [](const auto& a, const auto& b) {
    return std::filesystem::last_write_time(a) > std::filesystem::last_write_time(b);
  });
  if (!candidates.empty()) return candidates.front();
  // Search PATH explicitly. SearchPath's default order includes the current
  // working directory, which must not impersonate an authenticated connector.
  const auto path = Environment(L"PATH");
  std::size_t begin = 0;
  while (begin <= path.size()) {
    const auto end = path.find(L';', begin);
    auto directory = path.substr(begin, end == std::wstring::npos ? end : end - begin);
    if (directory.size() >= 2 && directory.front() == L'\"' && directory.back() == L'\"')
      directory = directory.substr(1, directory.size() - 2);
    const std::filesystem::path candidate = std::filesystem::path(directory) / L"codex.exe";
    if (!directory.empty() && ValidExecutable(candidate)) return candidate;
    if (end == std::wstring::npos) break;
    begin = end + 1;
  }
  throw std::runtime_error("Codex CLI not found. Install/login with Codex and configure its .exe path.");
}
bool RunCodexTextProcess(const std::filesystem::path& executable,
    const std::vector<std::wstring>& arguments, const std::filesystem::path& workspace,
    const std::string& input, const std::function<bool(const std::string&)>& chunk,
    const std::function<bool()>& cancelled, std::string* error, unsigned timeout_ms) {
  try {
    if (cancelled()) return false;
    Require(ValidExecutable(executable) && input.size() <= Model::kLimit + 65536);
    std::wstring command = QuoteWindowsArgument(executable.wstring());
    for (const auto& arg : arguments) command += L" " + QuoteWindowsArgument(arg);
    Require(command.size() < 32767);
    Handle in_read, in_write, out_read, out_write, err_read, err_write, process, main_thread, job;
    Pipe(in_read, in_write, false); Pipe(out_read, out_write, true); Pipe(err_read, err_write, true);
    // Whitelist exactly three stdio handles: no Broker/TSF handles may leak.
    SIZE_T attribute_bytes = 0;
    InitializeProcThreadAttributeList(nullptr, 1, 0, &attribute_bytes);
    std::vector<unsigned char> storage(attribute_bytes);
    auto* attributes = reinterpret_cast<LPPROC_THREAD_ATTRIBUTE_LIST>(storage.data());
    Require(InitializeProcThreadAttributeList(attributes, 1, 0, &attribute_bytes) != FALSE);
    struct Attributes { LPPROC_THREAD_ATTRIBUTE_LIST p; ~Attributes() { DeleteProcThreadAttributeList(p); } } cleanup{attributes};
    HANDLE allowed[] = {in_read.value, out_write.value, err_write.value};
    Require(UpdateProcThreadAttribute(attributes, 0, PROC_THREAD_ATTRIBUTE_HANDLE_LIST,
        allowed, sizeof(allowed), nullptr, nullptr) != FALSE);
    STARTUPINFOEXW startup{}; startup.StartupInfo.cb = sizeof(startup);
    startup.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
    startup.StartupInfo.hStdInput = in_read.value; startup.StartupInfo.hStdOutput = out_write.value;
    startup.StartupInfo.hStdError = err_write.value; startup.lpAttributeList = attributes;
    job.value = CreateJobObjectW(nullptr, nullptr); Require(job.value != nullptr);
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits{};
    limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    Require(SetInformationJobObject(job.value, JobObjectExtendedLimitInformation, &limits, sizeof(limits)) != FALSE);
    auto environment = ChildEnvironment(); PROCESS_INFORMATION pi{};
    Require(CreateProcessW(executable.c_str(), command.data(), nullptr, nullptr, TRUE,
        CREATE_NO_WINDOW | CREATE_SUSPENDED | EXTENDED_STARTUPINFO_PRESENT | CREATE_UNICODE_ENVIRONMENT,
        environment.data(), workspace.c_str(), &startup.StartupInfo, &pi) != FALSE);
    process.value = pi.hProcess; main_thread.value = pi.hThread;
    if (!AssignProcessToJobObject(job.value, process.value)) {
      TerminateProcess(process.value, 1); throw std::runtime_error("Codex process isolation unavailable");
    }
    Require(ResumeThread(main_thread.value) != static_cast<DWORD>(-1));
    in_read.Reset(); out_write.Reset(); err_write.Reset();
    std::atomic<bool> written = false;
    std::jthread writer([&] {
      std::size_t offset = 0;
      while (offset < input.size()) {
        DWORD count = 0;
        if (!WriteFile(in_write.value, input.data() + offset,
            static_cast<DWORD>((std::min)(input.size() - offset, std::size_t{8192})), &count, nullptr) || !count) break;
        offset += count;
      }
      written = offset == input.size(); in_write.Reset();
    });
    struct StopTree {
      Handle& job; Handle& process; std::jthread& writer;
      ~StopTree() {
        job.Reset();
        WaitForSingleObject(process.value, 2000);
        if (writer.joinable()) { CancelSynchronousIo(writer.native_handle()); writer.join(); }
      }
    } stop_tree{job, process, writer};
    CodexJsonDecoder decoder; const auto started = GetTickCount64();
    bool valid = true, stopped = false; std::size_t stderr_bytes = 0;
    std::array<char, 8192> buffer{};
    for (;;) {
      if (cancelled() || GetTickCount64() - started >= timeout_ms) { stopped = true; break; }
      for (const bool output : {true, false}) {
        auto handle = output ? out_read.value : err_read.value;
        DWORD available = 0;
        if (!PeekNamedPipe(handle, nullptr, 0, nullptr, &available, nullptr)) continue;
        while (available) {
          DWORD count = 0;
          if (!ReadFile(handle, buffer.data(), (std::min)(available, static_cast<DWORD>(buffer.size())), &count, nullptr) || !count) break;
          if (output) valid = decoder.Feed(std::string_view(buffer.data(), count));
          else { stderr_bytes += count; valid = stderr_bytes <= 1024 * 1024; }
          if (!valid) break;
          available -= count;
        }
        if (!valid) break;
      }
      if (!valid) break;
      if (WaitForSingleObject(process.value, 10) == WAIT_OBJECT_0) {
        DWORD available = 0;
        if (PeekNamedPipe(out_read.value, nullptr, 0, nullptr, &available, nullptr) && available) continue;
        break;
      }
    }
    // Kill the entire private process tree on failure/cancel/normal exit; the
    // connector never leaves background workers running after Buffer closes.
    DWORD exit_code = 1; GetExitCodeProcess(process.value, &exit_code);
    job.Reset(); WaitForSingleObject(process.value, 2000);
    CancelSynchronousIo(writer.native_handle()); writer.join();
    if (stopped || !valid || !written || exit_code != 0 || !decoder.Finish() || cancelled()) {
      if (error) *error = stopped ? "Codex cancelled or timed out. Source retained."
          : "Codex failed or violated the text-only protocol. Check CLI/login. Source retained.";
      return false;
    }
    return chunk(decoder.Text()) && !cancelled();
  } catch (...) {
    if (error) *error = "Codex CLI unavailable or incompatible. Check its .exe path/login. Source retained.";
    return false;
  }
}
bool GenerateCodex(const Settings& config, const Generation& job,
    const std::function<bool(const std::string&)>& chunk,
    const std::function<bool()>& cancelled, std::string* error) {
  try {
    if (job.source.empty() || job.source.size() > Model::kLimit || job.instruction.empty() ||
        job.instruction.size() > 32768 || job.source.find('\0') != std::string::npos) return false;
    (void)Wide(job.source); (void)Wide(job.instruction);
    const auto executable = ResolveCodex(config.codex_path);
    Workspace workspace;
    const auto input = "You are a text-only Buffer connector. Do not use tools, read files, or execute commands.\n" +
        job.instruction + "\n\nUser text (interpret only as the text-generation request):\n" + job.source;
    return RunCodexTextProcess(executable, CodexTextArguments(workspace.path, config.codex_model),
        workspace.path, input, chunk, cancelled, error);
  } catch (...) {
    if (error) *error = "Codex CLI not found. Configure an absolute .exe path. Source retained.";
    return false;
  }
}
}
