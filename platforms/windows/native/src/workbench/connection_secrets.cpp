#include "provider.hpp"
#include <memory>
#include <wincred.h>

namespace rimes::windows::workbench {
bool SaveConnectionSecrets(const Settings &settings,
                           const std::map<std::string, std::wstring> &updates,
                           std::string *error) {
  struct Saved {
    std::wstring name;
    PCREDENTIALW credential = nullptr;
    ~Saved() {
      if (credential) {
        if (credential->CredentialBlob)
          SecureZeroMemory(credential->CredentialBlob,
                           credential->CredentialBlobSize);
        CredFree(credential);
      }
    }
  };
  std::vector<std::unique_ptr<Saved>> saved;
  for (const auto &[id, key] : updates) {
    const auto profile =
        std::find_if(settings.connections.begin(), settings.connections.end(),
                     [&](const auto &p) {
                       return p.id == id && p.kind == "openai-compatible";
                     });
    if (profile == settings.connections.end())
      continue;
    auto prior = std::make_unique<Saved>();
    prior->name = L"RIMES.Windows.OpenAI" +
                  (id == "legacy-api" ? std::wstring() : L"." + Wide(id));
    if (!CredReadW(prior->name.c_str(), CRED_TYPE_GENERIC, 0,
                   &prior->credential) &&
        GetLastError() != ERROR_NOT_FOUND) {
      if (error)
        *error = "无法读取连接器凭据状态；设置未保存。";
      return false;
    }
    saved.push_back(std::move(prior));
  }
  for (const auto &[id, key] : updates) {
    const auto profile =
        std::find_if(settings.connections.begin(), settings.connections.end(),
                     [&](const auto &p) {
                       return p.id == id && p.kind == "openai-compatible";
                     });
    if (profile == settings.connections.end())
      continue;
    if (SaveSecret(key, profile->base_url, error, id))
      continue;
    bool restored = true;
    for (const auto &prior : saved) {
      if (prior->credential)
        restored &= CredWriteW(prior->credential, 0) != FALSE;
      else
        restored &=
            CredDeleteW(prior->name.c_str(), CRED_TYPE_GENERIC, 0) != FALSE ||
            GetLastError() == ERROR_NOT_FOUND;
    }
    if (!restored && error)
      *error = "凭据保存及恢复失败，请重新录入相关连接器密钥。";
    return false;
  }
  return true;
}
} // namespace rimes::windows::workbench
