#include "single_instance.hpp"

#include "win32_security.hpp"

namespace rimes::windows::broker {

SingleInstance::~SingleInstance() {
  if (mutex_ != nullptr) {
    if (acquired_) {
      ReleaseMutex(mutex_);
    }
    CloseHandle(mutex_);
  }
}

bool SingleInstance::Acquire(const std::wstring& mutex_name,
                             SECURITY_ATTRIBUTES* security,
                             std::wstring* error) {
  if (mutex_ != nullptr) {
    if (error != nullptr) {
      *error = L"SingleInstance was already initialized";
    }
    return false;
  }

  SetLastError(ERROR_SUCCESS);
  mutex_ = CreateMutexW(security, TRUE, mutex_name.c_str());
  const DWORD creation_error = GetLastError();
  if (mutex_ == nullptr) {
    if (error != nullptr) {
      *error = L"CreateMutex failed: " + FormatWindowsError(creation_error);
    }
    return false;
  }
  if (creation_error == ERROR_ALREADY_EXISTS) {
    already_running_ = true;
    CloseHandle(mutex_);
    mutex_ = nullptr;
    return true;
  }
  acquired_ = true;
  return true;
}

}  // namespace rimes::windows::broker
