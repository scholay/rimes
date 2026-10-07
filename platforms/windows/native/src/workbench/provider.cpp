#include "provider.hpp"

#include <wincred.h>
#include <winhttp.h>

#include <filesystem>
#include <fstream>
#include <memory>
#include <vector>

#include "../core/control.hpp"
#include "sse.hpp"

namespace rimes::windows::workbench {
using core::Json;
namespace {
constexpr wchar_t kCredential[] = L"RIMES.Windows.OpenAI";
std::filesystem::path ConfigPath() {
  wchar_t value[32768]{};
  const DWORD size = GetEnvironmentVariableW(L"LOCALAPPDATA", value, 32768);
  if (!size || size >= 32768)
    throw std::runtime_error("LOCALAPPDATA unavailable");
  return std::filesystem::path(value) / L"RIMES" / L"settings.json";
}
std::wstring Secret(const std::string& endpoint) {
  PCREDENTIALW credential = nullptr;
  if (!CredReadW(kCredential, CRED_TYPE_GENERIC, 0, &credential)) return {};
  if (!credential->UserName || Wide(endpoint) != credential->UserName) {
    CredFree(credential);
    return {};
  }
  std::wstring value(reinterpret_cast<wchar_t*>(credential->CredentialBlob),
                     credential->CredentialBlobSize / sizeof(wchar_t));
  CredFree(credential);
  return value;
}
struct Wipe {
  std::wstring& value;
  ~Wipe() {
    if (!value.empty())
      SecureZeroMemory(value.data(), value.size() * sizeof(wchar_t));
  }
};
struct CloseInternet {
  void operator()(void* value) const {
    if (value) WinHttpCloseHandle(value);
  }
};
using Internet = std::unique_ptr<void, CloseInternet>;
void Fail(std::string* error, const char* code) {
  if (error) *error = code;
}
}  // namespace
std::wstring Wide(const std::string& text) {
  if (text.empty()) return {};
  int size = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text.data(),
                                 static_cast<int>(text.size()), nullptr, 0);
  if (size <= 0) throw std::runtime_error("Invalid UTF-8");
  std::wstring result(static_cast<std::size_t>(size), 0);
  MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text.data(),
                      static_cast<int>(text.size()), result.data(), size);
  return result;
}
std::string Utf8(const std::wstring& text) {
  if (text.empty()) return {};
  int size = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, text.data(),
                                 static_cast<int>(text.size()), nullptr, 0,
                                 nullptr, nullptr);
  if (size <= 0) throw std::runtime_error("Invalid UTF-16");
  std::string result(static_cast<std::size_t>(size), 0);
  WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, text.data(),
                      static_cast<int>(text.size()), result.data(), size,
                      nullptr, nullptr);
  return result;
}
bool ValidTheme(const std::string& theme) {
  return theme == "night" || theme == "day" || theme == "quiet" ||
         theme == "rasta";
}
bool ValidSettings(const Settings& value) {
  const bool schema = value.schema == "rime_ice" ||
                      value.schema == "double_pinyin" ||
                      value.schema == "double_pinyin_flypy" ||
                      value.schema == "wubi86" || value.schema == "english" || value.schema == "my_combo";
  return schema && value.candidate_count >= 1 && value.candidate_count <= 9 && ValidTheme(value.theme) && value.font_size >= 10 &&
         value.font_size <= 40 && value.hotkey_key >= 'A' &&
         value.hotkey_key <= 'Z' &&
         value.hotkey_modifiers == (MOD_CONTROL | MOD_ALT) &&
         value.base_url.size() <= 2048 && value.model.size() <= 256 &&
         value.target_language.size() <= 128;
}
bool LoadSettings(Settings* value, std::string* error) {
  try {
    auto path = ConfigPath();
    if (!std::filesystem::exists(path)) return true;
    if (std::filesystem::is_symlink(path) ||
        std::filesystem::file_size(path) > 32768)
      throw std::runtime_error("Invalid settings file");
    std::ifstream file(path);
    auto j = Json::parse(file);
    value->revision = j.value("revision", 1ULL);
    value->schema = j.value("schema", "rime_ice");
    value->base_url = j.value("base_url", "");
    value->model = j.value("model", "");
    value->target_language = j.value("target_language", "English");
    value->ascii = j.value("ascii", false);
    value->traditional = j.value("traditional", false);
    value->ascii_punctuation = j.value("ascii_punctuation", false);
    value->font_size = j.value("font_size", 16U);
    value->candidate_count = j.value("candidate_count", 9U);
    value->vertical_candidates = j.value("vertical_candidates", false);
    value->theme = j.value("theme", "night");
    if (!ValidTheme(value->theme)) value->theme = "night";
    value->hotkey_modifiers = j.value(
        "hotkey_modifiers", static_cast<unsigned>(MOD_CONTROL | MOD_ALT));
    value->hotkey_key = j.value("hotkey_key", static_cast<unsigned>('B'));
    if (!ValidSettings(*value))
      throw std::runtime_error("Invalid settings values");
    return true;
  } catch (...) {
    Fail(error, "Settings unreadable; original file preserved.");
    return false;
  }
}
bool SaveSettings(const Settings& value, std::string* error) {
  try {
    if (!ValidSettings(value)) throw std::runtime_error("invalid settings");
    auto path = ConfigPath();
    std::filesystem::create_directories(path.parent_path());
    Json j = {{"version", 1},
              {"revision", value.revision},
              {"schema", value.schema},
              {"ascii", value.ascii},
              {"traditional", value.traditional},
              {"ascii_punctuation", value.ascii_punctuation},
              {"font_size", value.font_size},
              {"candidate_count", value.candidate_count},
              {"vertical_candidates", value.vertical_candidates},
              {"theme", value.theme},
              {"hotkey_modifiers", value.hotkey_modifiers},
              {"hotkey_key", value.hotkey_key},
              {"base_url", value.base_url},
              {"model", value.model},
              {"target_language", value.target_language}};
    auto temporary = path;
    temporary += L".tmp";
    std::ofstream file(temporary, std::ios::binary | std::ios::trunc);
    file << j.dump(2);
    file.close();
    if (!file) throw std::runtime_error("write failed");
    if (!MoveFileExW(temporary.c_str(), path.c_str(),
                     MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH))
      throw std::runtime_error("replace failed");
    return true;
  } catch (...) {
    Fail(error, "Could not save settings.");
    return false;
  }
}
bool SaveSecret(const std::wstring& key, const std::string& endpoint,
                std::string* error) {
  if (key.empty()) {
    if (CredDeleteW(kCredential, CRED_TYPE_GENERIC, 0) ||
        GetLastError() == ERROR_NOT_FOUND)
      return true;
  } else if (key.size() <= 2048 &&
             key.find_first_of(L"\r\n") == std::wstring::npos) {
    auto endpoint_name = Wide(endpoint);
    CREDENTIALW credential{};
    credential.UserName = endpoint_name.data();
    credential.Type = CRED_TYPE_GENERIC;
    credential.TargetName = const_cast<wchar_t*>(kCredential);
    credential.CredentialBlobSize =
        static_cast<DWORD>(key.size() * sizeof(wchar_t));
    credential.CredentialBlob =
        reinterpret_cast<BYTE*>(const_cast<wchar_t*>(key.data()));
    credential.Persist = CRED_PERSIST_LOCAL_MACHINE;
    if (CredWriteW(&credential, 0)) return true;
  }
  Fail(error, "Could not save API key in Windows Credential Manager.");
  return false;
}
bool HasSecret() {
  PCREDENTIALW value = nullptr;
  if (!CredReadW(kCredential, CRED_TYPE_GENERIC, 0, &value)) return false;
  CredFree(value);
  return true;
}
bool GenerateAPI(const Settings& config, const Generation& job,
                 const std::function<bool(const std::string&)>& chunk,
                 const std::function<bool()>& cancelled, std::string* error) {
  try {
    return GenerateWithKey(config, job, Secret(config.base_url), chunk,
                           cancelled, error);
  } catch (...) {
    Fail(error, "Credential unavailable.");
    return false;
  }
}
bool GenerateWithKey(const Settings& config, const Generation& job,
                     std::wstring key,
                     const std::function<bool(const std::string&)>& chunk,
                     const std::function<bool()>& cancelled,
                     std::string* error) {
  try {
    Wipe wipe_key{key};
    if (key.empty() || config.model.empty()) {
      Fail(error, "Configure an API model and key first.");
      return false;
    }
    std::wstring url = Wide(config.base_url);
    while (!url.empty() && url.back() == L'/') url.pop_back();
    url += L"/chat/completions";
    URL_COMPONENTS parts{};
    parts.dwStructSize = sizeof(parts);
    parts.dwHostNameLength = parts.dwUrlPathLength = parts.dwExtraInfoLength =
        parts.dwUserNameLength = parts.dwPasswordLength =
            static_cast<DWORD>(-1);
    if (!WinHttpCrackUrl(url.c_str(), static_cast<DWORD>(url.size()), 0,
                         &parts)) {
      Fail(error, "Invalid API URL.");
      return false;
    }
    std::wstring host(parts.lpszHostName, parts.dwHostNameLength),
        path(parts.lpszUrlPath, parts.dwUrlPathLength);
    const bool loopback = host == L"localhost" || host == L"127.0.0.1" ||
                          host == L"[::1]" || host == L"::1";
    if (parts.dwUserNameLength || parts.dwPasswordLength ||
        parts.dwExtraInfoLength ||
        (parts.nScheme != INTERNET_SCHEME_HTTPS &&
         !(parts.nScheme == INTERNET_SCHEME_HTTP && loopback))) {
      Fail(error, "Remote API endpoints require HTTPS and no URL credentials.");
      return false;
    }
    Internet session(
        WinHttpOpen(L"RIMES/0.2", WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY,
                    WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0));
    if (!session) throw std::runtime_error("session");
    WinHttpSetTimeouts(session.get(), 5000, 5000, 5000, 5000);
    Internet connection(
        WinHttpConnect(session.get(), host.c_str(), parts.nPort, 0));
    if (!connection) throw std::runtime_error("connect");
    Internet request(WinHttpOpenRequest(
        connection.get(), L"POST", path.c_str(), nullptr, WINHTTP_NO_REFERER,
        WINHTTP_DEFAULT_ACCEPT_TYPES,
        parts.nScheme == INTERNET_SCHEME_HTTPS ? WINHTTP_FLAG_SECURE : 0));
    if (!request) throw std::runtime_error("request");
    DWORD redirects = WINHTTP_OPTION_REDIRECT_POLICY_NEVER;
    WinHttpSetOption(request.get(), WINHTTP_OPTION_REDIRECT_POLICY, &redirects,
                     sizeof(redirects));
    auto headers =
        L"Content-Type: application/json\r\nAccept: "
        L"text/event-stream\r\nAuthorization: Bearer " +
        key + L"\r\n";
    Wipe wipe_headers{headers};
    if (job.instruction.empty() || job.instruction.size() > 32768) {
      Fail(error, "Plugin instruction unavailable."); return false;
    }
    const auto& instruction = job.instruction;
    Json body = {{"model", config.model},
                 {"stream", true},
                 {"messages",
                  Json::array({{{"role", "system"}, {"content", instruction}},
                               {{"role", "user"}, {"content", job.source}}})}};
    auto data = body.dump();
    if (cancelled()) return false;
    if (!WinHttpSendRequest(request.get(), headers.c_str(),
                            static_cast<DWORD>(headers.size()), data.data(),
                            static_cast<DWORD>(data.size()),
                            static_cast<DWORD>(data.size()), 0) ||
        !WinHttpReceiveResponse(request.get(), nullptr))
      throw std::runtime_error("transport");
    SecureZeroMemory(key.data(), key.size() * sizeof(wchar_t));
    SecureZeroMemory(headers.data(), headers.size() * sizeof(wchar_t));
    DWORD status = 0, size = sizeof(status);
    WinHttpQueryHeaders(
        request.get(), WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER,
        WINHTTP_HEADER_NAME_BY_INDEX, &status, &size, WINHTTP_NO_HEADER_INDEX);
    wchar_t type[256]{};
    size = sizeof(type);
    if (status < 200 || status >= 300 ||
        !WinHttpQueryHeaders(request.get(), WINHTTP_QUERY_CONTENT_TYPE,
                             WINHTTP_HEADER_NAME_BY_INDEX, type, &size,
                             WINHTTP_NO_HEADER_INDEX) ||
        std::wstring(type).find(L"text/event-stream") == std::wstring::npos) {
      Fail(error, "API must return a successful SSE response.");
      return false;
    }
    SseDecoder decoder(chunk);
    const auto started = GetTickCount64();
    char buffer[8192];
    while (!cancelled() && GetTickCount64() - started < 120000) {
      DWORD received = 0;
      if (!WinHttpReadData(request.get(), buffer, sizeof(buffer), &received))
        throw std::runtime_error("read");
      if (!received) break;
      if (!decoder.Feed(std::string_view(buffer, received)))
        throw std::runtime_error("SSE");
      if (decoder.Done()) return !cancelled();
    }
    Fail(error,
         cancelled() ? "Cancelled." : "API stream ended before completion.");
    return false;
  } catch (...) {
    Fail(error, "API request failed or exceeded its limits. Source retained.");
    return false;
  }
}
}  // namespace rimes::windows::workbench
