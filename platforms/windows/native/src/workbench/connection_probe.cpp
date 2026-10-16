#include "codex_cli.hpp"
#include "parity_settings.hpp"
#include <filesystem>
#include <memory>
#include <wincred.h>
#include <winhttp.h>
namespace rimes::windows::workbench {
ConnectionProbeResult ProbeConnection(const ConnectionProfile &profile,
                                      const std::wstring &draft_key) {
  ConnectionProbeResult result;
  try {
    if (profile.kind == "codex-cli") {
      const auto exe = ResolveCodex(profile.executable);
      const auto directory = std::filesystem::temp_directory_path();
      std::string error;
      result.success = RunLocalTextProcess(
          exe, {L"login", L"status"}, directory, "",
          [](const std::string &) { return true; }, [] { return false; },
          &error, 10000);
      result.message =
          result.success
              ? "Codex 已安装且已登录。模型留空可使用 CLI 默认值。"
              : "Codex 尚未登录或版本不兼容；请在终端运行 codex login。";
      return result;
    }
    std::wstring secret = draft_key;
    struct Wipe {
      std::wstring &value;
      ~Wipe() {
        if (!value.empty())
          SecureZeroMemory(value.data(), value.size() * sizeof(wchar_t));
      }
    } wipe{secret};
    if (secret.empty()) {
      const auto name = L"RIMES.Windows.OpenAI" +
                        (profile.id == "legacy-api" ? std::wstring()
                                                    : L"." + Wide(profile.id));
      PCREDENTIALW credential = nullptr;
      if (CredReadW(name.c_str(), CRED_TYPE_GENERIC, 0, &credential)) {
        if (credential->UserName &&
            profile.base_url == Utf8(credential->UserName))
          secret.assign(reinterpret_cast<wchar_t *>(credential->CredentialBlob),
                        credential->CredentialBlobSize / sizeof(wchar_t));
        if (credential->CredentialBlob)
          SecureZeroMemory(credential->CredentialBlob,
                           credential->CredentialBlobSize);
        CredFree(credential);
      }
    }
    if (secret.find_first_of(L"\r\n") != std::wstring::npos ||
        secret.find(L'\0') != std::wstring::npos)
      throw std::runtime_error("key");
    std::wstring endpoint = Wide(profile.base_url);
    while (!endpoint.empty() && endpoint.back() == L'/')
      endpoint.pop_back();
    endpoint += L"/models";
    URL_COMPONENTSW url{};
    url.dwStructSize = sizeof(url);
    url.dwHostNameLength = url.dwUrlPathLength = url.dwExtraInfoLength =
        url.dwUserNameLength = url.dwPasswordLength = static_cast<DWORD>(-1);
    if (!WinHttpCrackUrl(endpoint.c_str(), 0, 0, &url) ||
        url.dwUserNameLength || url.dwPasswordLength || url.dwExtraInfoLength)
      throw std::runtime_error("url");
    const std::wstring host(url.lpszHostName, url.dwHostNameLength),
        path(url.lpszUrlPath, url.dwUrlPathLength);
    if (url.nScheme != INTERNET_SCHEME_HTTPS &&
        !(url.nScheme == INTERNET_SCHEME_HTTP &&
          (host == L"localhost" || host == L"127.0.0.1" || host == L"[::1]")))
      throw std::runtime_error("url");
    struct Close {
      void operator()(void *p) const {
        if (p)
          WinHttpCloseHandle(p);
      }
    };
    using Handle = std::unique_ptr<void, Close>;
    Handle session(WinHttpOpen(L"XSIME model discovery",
                               WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY, nullptr,
                               nullptr, 0));
    if (!session)
      throw std::runtime_error("network");
    if (!WinHttpSetTimeouts(session.get(), 3000, 3000, 3000, 3000))
      throw std::runtime_error("network");
    Handle connection(
        WinHttpConnect(session.get(), host.c_str(), url.nPort, 0));
    if (!connection)
      throw std::runtime_error("network");
    Handle request(WinHttpOpenRequest(
        connection.get(), L"GET", path.c_str(), nullptr, nullptr,
        WINHTTP_DEFAULT_ACCEPT_TYPES,
        url.nScheme == INTERNET_SCHEME_HTTPS ? WINHTTP_FLAG_SECURE : 0));
    if (!request)
      throw std::runtime_error("network");
    DWORD redirect = WINHTTP_OPTION_REDIRECT_POLICY_NEVER;
    if (!WinHttpSetOption(request.get(), WINHTTP_OPTION_REDIRECT_POLICY, &redirect,
                     sizeof(redirect))) throw std::runtime_error("network");
    std::wstring authorization =
        secret.empty() ? L"" : L"Authorization: Bearer " + secret + L"\r\n";
    Wipe wipe_header{authorization};
    if (!WinHttpSendRequest(request.get(), authorization.c_str(),
                            static_cast<DWORD>(authorization.size()), nullptr,
                            0, 0, 0) ||
        !WinHttpReceiveResponse(request.get(), nullptr))
      throw std::runtime_error("network");
    DWORD status = 0, size = sizeof(status);
    if (!WinHttpQueryHeaders(request.get(),
                             WINHTTP_QUERY_STATUS_CODE |
                                 WINHTTP_QUERY_FLAG_NUMBER,
                             nullptr, &status, &size, nullptr) ||
        status != 200)
      throw std::runtime_error("http");
    std::string bytes;
    const auto started = GetTickCount64();
    for (;;) {
      char block[8192];
      DWORD count = 0;
      if (GetTickCount64() - started > 15000 ||
          !WinHttpReadData(request.get(), block, sizeof(block), &count) ||
          bytes.size() + count > 1024 * 1024)
        throw std::runtime_error("response");
      if (!count)
        break;
      bytes.append(block, count);
    }
    const auto data = core::Json::parse(bytes, [](int depth, core::Json::parse_event_t, core::Json&) {
      if (depth > 16) throw std::runtime_error("models nesting limit");
      return true;
    }).at("data");
    if (!data.is_array() || data.size() > 4096)
      throw std::runtime_error("models");
    for (const auto &item : data) {
      const auto id = item.at("id").get<std::string>();
      if (id.empty() || id.size() > 256 ||
          id.find_first_of("\r\n") != std::string::npos ||
          id.find('\0') != std::string::npos)
        continue;
      (void)Wide(id);
      result.models.push_back(id);
    }
    std::sort(result.models.begin(), result.models.end());
    result.models.erase(std::unique(result.models.begin(), result.models.end()),
                        result.models.end());
    result.success = true;
    result.message = "已读取 " + std::to_string(result.models.size()) +
                     " 个模型。选择模型后保存。";
  } catch (...) {
    result.message = profile.kind == "codex-cli"
        ? "未找到可用的 Codex CLI。请安装官方 CLI，填写 codex.exe 路径，并在终端运行 codex login。"
        : "连接检查失败。请检查地址、密钥、网络和 /models 支持；也可手动填写模型。";
  }
  return result;
}
} // namespace rimes::windows::workbench
