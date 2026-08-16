#include "win32_security.hpp"

#include <sddl.h>

#include <iomanip>
#include <memory>
#include <sstream>
#include <utility>

namespace rimes::windows::broker {
namespace {

class HandleCloser {
 public:
  void operator()(void* handle) const {
    if (handle != nullptr && handle != INVALID_HANDLE_VALUE) {
      CloseHandle(handle);
    }
  }
};

using UniqueHandle = std::unique_ptr<void, HandleCloser>;

std::uint64_t HashSid(std::wstring_view sid) {
  // FNV-1a is not an authorization boundary; it only keeps the kernel object
  // name compact and avoids publishing the full SID. The DACL is the boundary.
  std::uint64_t hash = 14695981039346656037ULL;
  for (const wchar_t code_unit : sid) {
    hash ^= static_cast<std::uint16_t>(code_unit);
    hash *= 1099511628211ULL;
  }
  return hash;
}

bool ReadTokenUser(HANDLE token,
                   std::vector<std::byte>* storage,
                   TOKEN_USER** token_user,
                   std::wstring* error) {
  DWORD required = 0;
  GetTokenInformation(token, TokenUser, nullptr, 0, &required);
  if (required == 0 || GetLastError() != ERROR_INSUFFICIENT_BUFFER) {
    if (error != nullptr) {
      *error = L"GetTokenInformation(size) failed: " +
               FormatWindowsError(GetLastError());
    }
    return false;
  }
  storage->resize(required);
  if (!GetTokenInformation(token, TokenUser, storage->data(), required,
                           &required)) {
    if (error != nullptr) {
      *error = L"GetTokenInformation(TokenUser) failed: " +
               FormatWindowsError(GetLastError());
    }
    return false;
  }
  *token_user = reinterpret_cast<TOKEN_USER*>(storage->data());
  return true;
}

}  // namespace

std::wstring FormatWindowsError(DWORD error_code) {
  wchar_t* raw_message = nullptr;
  const DWORD length = FormatMessageW(
      FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_SYSTEM |
          FORMAT_MESSAGE_IGNORE_INSERTS,
      nullptr, error_code, 0, reinterpret_cast<wchar_t*>(&raw_message), 0,
      nullptr);
  if (length == 0 || raw_message == nullptr) {
    return L"Windows error " + std::to_wstring(error_code);
  }
  std::wstring message(raw_message, length);
  LocalFree(raw_message);
  while (!message.empty() &&
         (message.back() == L'\r' || message.back() == L'\n' ||
          message.back() == L' ')) {
    message.pop_back();
  }
  return message + L" (" + std::to_wstring(error_code) + L")";
}

UserSecurityContext::~UserSecurityContext() {
  if (descriptor_ != nullptr) {
    LocalFree(descriptor_);
  }
}

bool UserSecurityContext::Initialize(std::wstring* error) {
  if (descriptor_ != nullptr) {
    if (error != nullptr) {
      *error = L"UserSecurityContext was already initialized";
    }
    return false;
  }

  HANDLE raw_token = nullptr;
  if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &raw_token)) {
    if (error != nullptr) {
      *error = L"OpenProcessToken failed: " +
               FormatWindowsError(GetLastError());
    }
    return false;
  }
  UniqueHandle token(raw_token);

  std::vector<std::byte> token_storage;
  TOKEN_USER* token_user = nullptr;
  if (!ReadTokenUser(token.get(), &token_storage, &token_user, error)) {
    return false;
  }
  if (!IsValidSid(token_user->User.Sid)) {
    if (error != nullptr) {
      *error = L"the current process token contains an invalid SID";
    }
    return false;
  }

  const DWORD sid_length = GetLengthSid(token_user->User.Sid);
  sid_bytes_.resize(sid_length);
  if (!CopySid(sid_length, sid_bytes_.data(), token_user->User.Sid)) {
    if (error != nullptr) {
      *error = L"CopySid failed: " + FormatWindowsError(GetLastError());
    }
    return false;
  }

  wchar_t* raw_sid_string = nullptr;
  if (!ConvertSidToStringSidW(sid(), &raw_sid_string)) {
    if (error != nullptr) {
      *error = L"ConvertSidToStringSid failed: " +
               FormatWindowsError(GetLastError());
    }
    return false;
  }
  sid_string_ = raw_sid_string;
  LocalFree(raw_sid_string);

  if (!ProcessIdToSessionId(GetCurrentProcessId(), &session_id_)) {
    if (error != nullptr) {
      *error = L"ProcessIdToSessionId failed: " +
               FormatWindowsError(GetLastError());
    }
    return false;
  }

  // D:P protects the DACL from inheritance. The sole ACE grants generic all
  // to the current user's SID. Do not broaden this to Authenticated Users.
  const std::wstring sddl = L"D:P(A;;GA;;;" + sid_string_ + L")";
  if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(
          sddl.c_str(), SDDL_REVISION_1, &descriptor_, nullptr)) {
    if (error != nullptr) {
      *error = L"creating the per-user security descriptor failed: " +
               FormatWindowsError(GetLastError());
    }
    return false;
  }

  attributes_.nLength = sizeof(attributes_);
  attributes_.lpSecurityDescriptor = descriptor_;
  attributes_.bInheritHandle = FALSE;

  std::wostringstream suffix;
  suffix << L".v1.session-" << session_id_ << L".user-" << std::hex
         << std::setw(16) << std::setfill(L'0') << HashSid(sid_string_);
  pipe_name_ = L"\\\\.\\pipe\\RIMES.Broker" + suffix.str();
  mutex_name_ = L"Local\\RIMES.Broker" + suffix.str();
  return true;
}

bool UserSecurityContext::VerifyConnectedPipeClient(
    HANDLE pipe,
    std::wstring* error) const {
  ULONG client_process_id = 0;
  if (!GetNamedPipeClientProcessId(pipe, &client_process_id)) {
    if (error != nullptr) {
      *error = L"GetNamedPipeClientProcessId failed: " +
               FormatWindowsError(GetLastError());
    }
    return false;
  }

  DWORD client_session_id = 0;
  if (!ProcessIdToSessionId(client_process_id, &client_session_id) ||
      client_session_id != session_id_) {
    if (error != nullptr) {
      *error = L"the pipe client is not in the broker's logon session";
    }
    return false;
  }

  UniqueHandle process(OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE,
                                   client_process_id));
  if (!process) {
    if (error != nullptr) {
      *error = L"OpenProcess(client) failed: " +
               FormatWindowsError(GetLastError());
    }
    return false;
  }
  HANDLE raw_token = nullptr;
  if (!OpenProcessToken(process.get(), TOKEN_QUERY, &raw_token)) {
    if (error != nullptr) {
      *error = L"OpenProcessToken(client) failed: " +
               FormatWindowsError(GetLastError());
    }
    return false;
  }
  UniqueHandle token(raw_token);

  std::vector<std::byte> token_storage;
  TOKEN_USER* token_user = nullptr;
  if (!ReadTokenUser(token.get(), &token_storage, &token_user, error)) {
    return false;
  }
  if (!EqualSid(sid(), token_user->User.Sid)) {
    if (error != nullptr) {
      *error = L"the pipe client SID does not match the broker user";
    }
    return false;
  }
  return true;
}

}  // namespace rimes::windows::broker
