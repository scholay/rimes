#include "broker_launch.hpp"
#include <cstdlib>
#include <iostream>

int main() {
  const auto name = L"SOFTWARE\\Scholay\\RIMES-BrokerLaunch-Tests\\" +
                    std::to_wstring(GetCurrentProcessId());
  HKEY key = nullptr;
  DWORD disposition = 0;
  if (RegCreateKeyExW(HKEY_CURRENT_USER, name.c_str(), 0, nullptr,
          REG_OPTION_VOLATILE, KEY_ALL_ACCESS, nullptr, &key,
          &disposition) != ERROR_SUCCESS || disposition != REG_CREATED_NEW_KEY)
    return EXIT_FAILURE;
  struct Cleanup {
    HKEY key;
    std::wstring name;
    ~Cleanup() { RegCloseKey(key); RegDeleteKeyW(HKEY_CURRENT_USER, name.c_str()); }
  } cleanup{key, name};
  int failures = 0;
  auto check = [&](bool value, const char* message) {
    if (!value) { std::cerr << message << '\n'; ++failures; }
  };
  const std::wstring module = L"C:\\fixture\\active\\x64\\RimesTsf.dll";
  const auto active = [&] { return rimes::windows::tsf::IsRegisteredTsfModule(
      module, HKEY_CURRENT_USER, name.c_str()); };
  check(!active(), "uninstalled DLL must not auto-launch a Broker");
  auto write = [&](const std::wstring& path, DWORD type = REG_SZ) {
    check(RegSetValueExW(key, nullptr, 0, type,
        reinterpret_cast<const BYTE*>(path.c_str()),
        static_cast<DWORD>((path.size() + 1) * sizeof(wchar_t))) == ERROR_SUCCESS,
        "fixture registry write failed");
  };
  write(module);
  check(active(), "the active exact DLL can auto-launch");
  write(L"c:\\FIXTURE\\ACTIVE\\x64\\rimestsf.dll");
  check(active(), "Windows path case does not change identity");
  write(L"C:\\fixture\\retired\\x64\\RimesTsf.dll");
  check(!active(), "a cached retired DLL cannot resurrect its old Broker");
  write(module, REG_EXPAND_SZ);
  check(!active(), "unexpected registry value types fail closed");
  RegDeleteValueW(key, nullptr);
  check(!active(), "removing registration retires launch authority immediately");
  return failures ? EXIT_FAILURE : EXIT_SUCCESS;
}
