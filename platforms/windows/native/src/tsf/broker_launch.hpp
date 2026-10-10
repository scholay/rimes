#pragma once
#include <windows.h>
#include <string>

namespace rimes::windows::tsf {
// A cached DLL must not resurrect a retired/uninstalled sibling Broker.
inline bool IsRegisteredTsfModule(const std::wstring& module_path,
    HKEY root = HKEY_LOCAL_MACHINE,
    const wchar_t* key = L"SOFTWARE\\Classes\\CLSID\\{0B2C570B-9811-45DF-989B-EA306281F6B4}\\InprocServer32") {
  wchar_t registered[MAX_PATH]{};
  DWORD bytes = sizeof(registered);
  DWORD type = 0;
  const auto result = RegGetValueW(root, key, nullptr, RRF_RT_REG_SZ | RRF_NOEXPAND,
                                  &type, registered, &bytes);
  return result == ERROR_SUCCESS && type == REG_SZ && !module_path.empty() &&
         _wcsicmp(registered, module_path.c_str()) == 0;
}
}
