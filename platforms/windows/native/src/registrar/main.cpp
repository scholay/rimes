#include <Windows.h>
#include <msctf.h>
#include <objbase.h>
#include <oleauto.h>

#include <algorithm>
#include <cstdint>
#include <cwchar>
#include <iomanip>
#include <iostream>
#include <limits>
#include <sstream>
#include <string>
#include <string_view>
#include <vector>

#include "tsf/Guids.h"

namespace {

using rimes::windows::tsf::kDisplayName;
using rimes::windows::tsf::kDllFileName;
using rimes::windows::tsf::kLanguageId;
using rimes::windows::tsf::kLanguageProfileGuid;
using rimes::windows::tsf::kLanguageProfileGuidString;
using rimes::windows::tsf::kTextServiceClsid;
using rimes::windows::tsf::kTextServiceClsidString;

constexpr wchar_t kThreadingModel[] = L"Apartment";

enum class Command {
  kMetadata,
  kRegister,
  kUnregister,
  kVerify,
  kVerifyAbsent,
};

struct Options {
  Command command = Command::kMetadata;
  std::wstring dll_path;
  bool dry_run = false;
};

struct ComRegistrationState {
  bool class_key_exists = false;
  bool complete = false;
  std::wstring dll_path;
  std::wstring threading_model;
};

struct RegistrationDelta {
  bool com_created = false;
  bool processor_created = false;
  bool profile_created = false;
  bool category_created = false;
};

class ScopedCoInitialize final {
 public:
  ScopedCoInitialize() : result_(CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED)) {}
  ~ScopedCoInitialize() {
    if (SUCCEEDED(result_)) {
      CoUninitialize();
    }
  }

  ScopedCoInitialize(const ScopedCoInitialize&) = delete;
  ScopedCoInitialize& operator=(const ScopedCoInitialize&) = delete;

  HRESULT result() const { return result_; }

 private:
  HRESULT result_;
};

class ScopedHandle final {
 public:
  explicit ScopedHandle(HANDLE value) : value_(value) {}
  ~ScopedHandle() {
    if (value_ != nullptr && value_ != INVALID_HANDLE_VALUE) {
      CloseHandle(value_);
    }
  }

  ScopedHandle(const ScopedHandle&) = delete;
  ScopedHandle& operator=(const ScopedHandle&) = delete;

  HANDLE Get() const { return value_; }
  bool IsValid() const {
    return value_ != nullptr && value_ != INVALID_HANDLE_VALUE;
  }

 private:
  HANDLE value_;
};

template <typename T>
class ComPtr final {
 public:
  ComPtr() = default;
  ~ComPtr() { Reset(); }

  ComPtr(const ComPtr&) = delete;
  ComPtr& operator=(const ComPtr&) = delete;

  T** Put() {
    Reset();
    return &value_;
  }

  T* operator->() const { return value_; }
  T* Get() const { return value_; }

  void Reset() {
    if (value_ != nullptr) {
      value_->Release();
      value_ = nullptr;
    }
  }

 private:
  T* value_ = nullptr;
};

std::string Utf8(const std::wstring_view value) {
  if (value.empty()) {
    return {};
  }
  const int size = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value.data(),
                                       static_cast<int>(value.size()), nullptr, 0,
                                       nullptr, nullptr);
  if (size <= 0) {
    return "<unicode-conversion-failed>";
  }
  std::string result(static_cast<std::size_t>(size), '\0');
  const int written = WideCharToMultiByte(
      CP_UTF8, WC_ERR_INVALID_CHARS, value.data(), static_cast<int>(value.size()),
      result.data(), size, nullptr, nullptr);
  if (written != size) {
    return "<unicode-conversion-failed>";
  }
  return result;
}

std::string HResultText(const HRESULT result) {
  std::ostringstream stream;
  stream << "0x" << std::hex << std::uppercase << std::setw(8)
         << std::setfill('0') << static_cast<std::uint32_t>(result);
  return stream.str();
}

std::string Win32ErrorText(const LSTATUS result) {
  std::ostringstream stream;
  stream << result << " (0x" << std::hex << std::uppercase << result << ')';
  return stream.str();
}

bool PrintHResultFailure(const char* operation, const HRESULT result) {
  std::cerr << operation << " failed: " << HResultText(result) << '\n';
  return false;
}

bool PrintWin32Failure(const char* operation, const LSTATUS result) {
  std::cerr << operation << " failed: " << Win32ErrorText(result) << '\n';
  return false;
}

void PrintUsage() {
  std::cerr
      << "Usage:\n"
      << "  RimesRegistrar metadata\n"
      << "  RimesRegistrar register --dll <absolute-path> [--dry-run]\n"
      << "  RimesRegistrar unregister --dll <absolute-path> [--dry-run]\n"
      << "  RimesRegistrar verify --dll <absolute-path>\n"
      << "  RimesRegistrar verify-absent --dll <absolute-path>\n";
}

bool ParseOptions(const int argc, wchar_t** argv, Options* options) {
  if (argc < 2 || options == nullptr) {
    return false;
  }

  const std::wstring_view command(argv[1]);
  if (command == L"metadata") {
    options->command = Command::kMetadata;
  } else if (command == L"register") {
    options->command = Command::kRegister;
  } else if (command == L"unregister") {
    options->command = Command::kUnregister;
  } else if (command == L"verify") {
    options->command = Command::kVerify;
  } else if (command == L"verify-absent") {
    options->command = Command::kVerifyAbsent;
  } else {
    return false;
  }

  for (int index = 2; index < argc; ++index) {
    const std::wstring_view argument(argv[index]);
    if (argument == L"--dry-run") {
      if (options->command == Command::kVerify ||
          options->command == Command::kVerifyAbsent ||
          options->command == Command::kMetadata) {
        return false;
      }
      options->dry_run = true;
      continue;
    }
    if (argument == L"--dll" && index + 1 < argc) {
      options->dll_path = argv[++index];
      continue;
    }
    return false;
  }

  if (options->command != Command::kMetadata && options->dll_path.empty()) {
    return false;
  }
  return true;
}

std::wstring FullPath(const std::wstring& value) {
  const DWORD required = GetFullPathNameW(value.c_str(), 0, nullptr, nullptr);
  if (required == 0) {
    return {};
  }
  std::vector<wchar_t> buffer(static_cast<std::size_t>(required));
  const DWORD written =
      GetFullPathNameW(value.c_str(), required, buffer.data(), nullptr);
  if (written == 0 || written >= required) {
    return {};
  }
  return std::wstring(buffer.data(), written);
}

bool PathsEqual(const std::wstring& left, const std::wstring& right) {
  const std::wstring full_left = FullPath(left);
  const std::wstring full_right = FullPath(right);
  if (full_left.empty() || full_right.empty()) {
    return false;
  }
  return CompareStringOrdinal(full_left.c_str(), -1, full_right.c_str(), -1,
                              TRUE) == CSTR_EQUAL;
}

bool ReadFileExactlyAt(HANDLE file, const std::uint64_t offset, void* buffer,
                       const DWORD byte_count) {
  if (offset > static_cast<std::uint64_t>(
                   (std::numeric_limits<LONGLONG>::max)())) {
    return false;
  }
  LARGE_INTEGER position{};
  position.QuadPart = static_cast<LONGLONG>(offset);
  if (!SetFilePointerEx(file, position, nullptr, FILE_BEGIN)) {
    return false;
  }
  DWORD bytes_read = 0;
  return ReadFile(file, buffer, byte_count, &bytes_read, nullptr) &&
         bytes_read == byte_count;
}

bool ValidatePeDll(HANDLE file, const std::wstring& path) {
  LARGE_INTEGER file_size{};
  if (!GetFileSizeEx(file, &file_size) || file_size.QuadPart < 0) {
    std::cerr << "Unable to read TSF DLL size: " << Utf8(path)
              << " (Win32 error " << GetLastError() << ")\n";
    return false;
  }
  const auto size = static_cast<std::uint64_t>(file_size.QuadPart);
  if (size < sizeof(IMAGE_DOS_HEADER)) {
    std::cerr << "TSF DLL is too small to contain a DOS header: "
              << Utf8(path) << '\n';
    return false;
  }

  IMAGE_DOS_HEADER dos_header{};
  if (!ReadFileExactlyAt(file, 0, &dos_header,
                         static_cast<DWORD>(sizeof(dos_header))) ||
      dos_header.e_magic != IMAGE_DOS_SIGNATURE || dos_header.e_lfanew < 0) {
    std::cerr << "TSF DLL has an invalid DOS header: " << Utf8(path) << '\n';
    return false;
  }

  const auto pe_offset = static_cast<std::uint64_t>(dos_header.e_lfanew);
  constexpr std::uint64_t kFixedPeHeaderSize =
      sizeof(DWORD) + sizeof(IMAGE_FILE_HEADER);
  if (pe_offset > size || size - pe_offset < kFixedPeHeaderSize) {
    std::cerr << "TSF DLL has an out-of-bounds PE header offset: "
              << Utf8(path) << '\n';
    return false;
  }

  DWORD signature = 0;
  if (!ReadFileExactlyAt(file, pe_offset, &signature,
                         static_cast<DWORD>(sizeof(signature))) ||
      signature != IMAGE_NT_SIGNATURE) {
    std::cerr << "TSF DLL has an invalid PE signature: " << Utf8(path) << '\n';
    return false;
  }

  IMAGE_FILE_HEADER file_header{};
  const std::uint64_t file_header_offset = pe_offset + sizeof(signature);
  if (!ReadFileExactlyAt(file, file_header_offset, &file_header,
                         static_cast<DWORD>(sizeof(file_header)))) {
    std::cerr << "TSF DLL has a truncated COFF file header: " << Utf8(path)
              << '\n';
    return false;
  }
  if ((file_header.Characteristics & IMAGE_FILE_DLL) == 0) {
    std::cerr << "The supplied PE image is not marked as a DLL: "
              << Utf8(path) << '\n';
    return false;
  }

  WORD expected_optional_magic = 0;
  std::size_t minimum_optional_size = 0;
  const char* image_architecture = nullptr;
  switch (file_header.Machine) {
    case IMAGE_FILE_MACHINE_AMD64:
      expected_optional_magic = IMAGE_NT_OPTIONAL_HDR64_MAGIC;
      minimum_optional_size = sizeof(IMAGE_OPTIONAL_HEADER64);
      image_architecture = "x64";
      break;
    case IMAGE_FILE_MACHINE_I386:
      expected_optional_magic = IMAGE_NT_OPTIONAL_HDR32_MAGIC;
      minimum_optional_size = sizeof(IMAGE_OPTIONAL_HEADER32);
      image_architecture = "x86";
      break;
    default:
      std::cerr << "TSF DLL has an unsupported PE machine (expected x86 or "
                   "x64): "
                << Utf8(path) << '\n';
      return false;
  }

  const std::uint64_t optional_offset =
      file_header_offset + sizeof(file_header);
  const auto optional_size =
      static_cast<std::uint64_t>(file_header.SizeOfOptionalHeader);
  if (optional_size < minimum_optional_size || optional_offset > size ||
      optional_size > size - optional_offset) {
    std::cerr << "TSF DLL has a missing, undersized, or truncated optional "
                 "header: "
              << Utf8(path) << '\n';
    return false;
  }

  WORD optional_magic = 0;
  if (!ReadFileExactlyAt(file, optional_offset, &optional_magic,
                         static_cast<DWORD>(sizeof(optional_magic))) ||
      optional_magic != expected_optional_magic) {
    std::cerr << "TSF DLL optional-header magic does not match its machine "
                 "type: "
              << Utf8(path) << '\n';
    return false;
  }

#if defined(_WIN64)
  constexpr WORD kExpectedMachine = IMAGE_FILE_MACHINE_AMD64;
  constexpr const char* kRegistrarArchitecture = "x64";
#else
  constexpr WORD kExpectedMachine = IMAGE_FILE_MACHINE_I386;
  constexpr const char* kRegistrarArchitecture = "x86";
#endif
  if (file_header.Machine != kExpectedMachine) {
    std::cerr << "Registrar/DLL architecture mismatch; registrar="
              << kRegistrarArchitecture << ", DLL=" << image_architecture
              << ".\n";
    return false;
  }
  return true;
}

bool ValidateDll(const std::wstring& path, std::wstring* full_path) {
  const std::wstring resolved = FullPath(path);
  if (resolved.empty()) {
    std::cerr << "Unable to resolve DLL path.\n";
    return false;
  }

  const DWORD attributes = GetFileAttributesW(resolved.c_str());
  if (attributes == INVALID_FILE_ATTRIBUTES ||
      (attributes & FILE_ATTRIBUTE_DIRECTORY) != 0) {
    std::cerr << "TSF DLL does not exist: " << Utf8(resolved) << '\n';
    return false;
  }

  ScopedHandle file(CreateFileW(resolved.c_str(), GENERIC_READ, FILE_SHARE_READ,
                                nullptr, OPEN_EXISTING,
                                FILE_ATTRIBUTE_NORMAL | FILE_FLAG_SEQUENTIAL_SCAN,
                                nullptr));
  if (!file.IsValid()) {
    std::cerr << "Unable to open TSF DLL for read-only PE validation: "
              << Utf8(resolved) << " (Win32 error " << GetLastError()
              << ")\n";
    return false;
  }
  if (!ValidatePeDll(file.Get(), resolved)) {
    return false;
  }

  *full_path = resolved;
  return true;
}

constexpr REGSAM RegistryView() {
#if defined(_WIN64)
  return KEY_WOW64_64KEY;
#else
  return KEY_WOW64_32KEY;
#endif
}

constexpr REGSAM OtherRegistryView() {
#if defined(_WIN64)
  return KEY_WOW64_32KEY;
#else
  return KEY_WOW64_64KEY;
#endif
}

std::wstring ClassSubkey() {
  return std::wstring(L"SOFTWARE\\Classes\\CLSID\\") +
         kTextServiceClsidString;
}

bool QueryStringValue(HKEY key, const wchar_t* name, std::wstring* value,
                      bool* found) {
  *found = false;
  DWORD type = 0;
  DWORD bytes = 0;
  LSTATUS result =
      RegQueryValueExW(key, name, nullptr, &type, nullptr, &bytes);
  if (result == ERROR_FILE_NOT_FOUND) {
    return true;
  }
  if (result != ERROR_SUCCESS) {
    return PrintWin32Failure("RegQueryValueExW(size)", result);
  }
  if (type != REG_SZ && type != REG_EXPAND_SZ) {
    std::cerr << "Registry value has an unexpected type.\n";
    return false;
  }
  if (bytes < sizeof(wchar_t) || bytes % sizeof(wchar_t) != 0) {
    std::cerr << "Registry value has an invalid string length.\n";
    return false;
  }

  std::vector<wchar_t> buffer(bytes / sizeof(wchar_t), L'\0');
  result = RegQueryValueExW(key, name, nullptr, &type,
                            reinterpret_cast<BYTE*>(buffer.data()), &bytes);
  if (result != ERROR_SUCCESS) {
    return PrintWin32Failure("RegQueryValueExW(data)", result);
  }
  if (buffer.empty() || buffer.back() != L'\0') {
    buffer.push_back(L'\0');
  }
  *value = buffer.data();
  *found = true;
  return true;
}

bool QueryComRegistrationInView(const REGSAM registry_view,
                                ComRegistrationState* state) {
  HKEY class_key = nullptr;
  LSTATUS result = RegOpenKeyExW(HKEY_LOCAL_MACHINE, ClassSubkey().c_str(), 0,
                                 KEY_READ | registry_view, &class_key);
  if (result == ERROR_FILE_NOT_FOUND) {
    *state = {};
    return true;
  }
  if (result != ERROR_SUCCESS) {
    return PrintWin32Failure("RegOpenKeyExW(CLSID)", result);
  }
  RegCloseKey(class_key);
  state->class_key_exists = true;

  HKEY inproc_key = nullptr;
  const std::wstring inproc_subkey = ClassSubkey() + L"\\InprocServer32";
  result = RegOpenKeyExW(HKEY_LOCAL_MACHINE, inproc_subkey.c_str(), 0,
                         KEY_READ | registry_view, &inproc_key);
  if (result == ERROR_FILE_NOT_FOUND) {
    return true;
  }
  if (result != ERROR_SUCCESS) {
    return PrintWin32Failure("RegOpenKeyExW(InprocServer32)", result);
  }

  bool path_found = false;
  bool model_found = false;
  const bool path_ok =
      QueryStringValue(inproc_key, nullptr, &state->dll_path, &path_found);
  const bool model_ok = QueryStringValue(inproc_key, L"ThreadingModel",
                                         &state->threading_model, &model_found);
  RegCloseKey(inproc_key);
  if (!path_ok || !model_ok) {
    return false;
  }
  state->complete = path_found && model_found;
  return true;
}

bool QueryComRegistration(ComRegistrationState* state) {
  return QueryComRegistrationInView(RegistryView(), state);
}

bool SetStringValue(HKEY key, const wchar_t* name, const wchar_t* value) {
  const DWORD bytes =
      static_cast<DWORD>((std::wcslen(value) + 1) * sizeof(wchar_t));
  const LSTATUS result = RegSetValueExW(
      key, name, 0, REG_SZ, reinterpret_cast<const BYTE*>(value), bytes);
  if (result != ERROR_SUCCESS) {
    return PrintWin32Failure("RegSetValueExW", result);
  }
  return true;
}

bool RemoveComRegistration(const std::wstring& expected_dll_path,
                           const bool require_match) {
  ComRegistrationState state;
  if (!QueryComRegistration(&state)) {
    return false;
  }
  if (!state.class_key_exists) {
    return true;
  }
  if (require_match &&
      (!state.complete || !PathsEqual(state.dll_path, expected_dll_path))) {
    std::cerr << "Refusing to remove a CLSID owned by another or incomplete "
                 "registration.\n";
    return false;
  }

  HKEY parent_key = nullptr;
  const LSTATUS open_result = RegOpenKeyExW(
      HKEY_LOCAL_MACHINE, L"SOFTWARE\\Classes\\CLSID", 0,
      DELETE | KEY_ENUMERATE_SUB_KEYS | KEY_QUERY_VALUE | RegistryView(),
      &parent_key);
  if (open_result != ERROR_SUCCESS) {
    return PrintWin32Failure("RegOpenKeyExW(CLSID parent)", open_result);
  }
  const LSTATUS delete_result =
      RegDeleteTreeW(parent_key, kTextServiceClsidString);
  RegCloseKey(parent_key);
  if (delete_result != ERROR_SUCCESS && delete_result != ERROR_FILE_NOT_FOUND) {
    return PrintWin32Failure("RegDeleteTreeW(CLSID)", delete_result);
  }
  return true;
}

bool EnsureComRegistration(const std::wstring& dll_path, bool* created) {
  *created = false;
  ComRegistrationState state;
  if (!QueryComRegistration(&state)) {
    return false;
  }
  if (state.class_key_exists) {
    if (!state.complete || !PathsEqual(state.dll_path, dll_path) ||
        CompareStringOrdinal(state.threading_model.c_str(), -1, kThreadingModel,
                             -1, TRUE) != CSTR_EQUAL) {
      std::cerr << "The TSF CLSID already has a conflicting or incomplete COM "
                   "registration.\n";
      return false;
    }
    return true;
  }

  HKEY class_key = nullptr;
  DWORD class_disposition = 0;
  LSTATUS result = RegCreateKeyExW(
      HKEY_LOCAL_MACHINE, ClassSubkey().c_str(), 0, nullptr,
      REG_OPTION_NON_VOLATILE, KEY_WRITE | RegistryView(), nullptr, &class_key,
      &class_disposition);
  if (result != ERROR_SUCCESS) {
    return PrintWin32Failure("RegCreateKeyExW(CLSID)", result);
  }
  if (class_disposition != REG_CREATED_NEW_KEY) {
    RegCloseKey(class_key);
    std::cerr << "The TSF CLSID appeared during registration; refusing to "
                 "overwrite it.\n";
    return false;
  }
  bool success = SetStringValue(class_key, nullptr, kDisplayName);
  RegCloseKey(class_key);

  HKEY inproc_key = nullptr;
  if (success) {
    const std::wstring inproc_subkey = ClassSubkey() + L"\\InprocServer32";
    result = RegCreateKeyExW(HKEY_LOCAL_MACHINE, inproc_subkey.c_str(), 0,
                             nullptr, REG_OPTION_NON_VOLATILE,
                             KEY_WRITE | RegistryView(), nullptr, &inproc_key,
                             nullptr);
    if (result != ERROR_SUCCESS) {
      success = PrintWin32Failure("RegCreateKeyExW(InprocServer32)", result);
    }
  }
  if (success) {
    success = SetStringValue(inproc_key, nullptr, dll_path.c_str()) &&
              SetStringValue(inproc_key, L"ThreadingModel", kThreadingModel);
  }
  if (inproc_key != nullptr) {
    RegCloseKey(inproc_key);
  }
  if (!success) {
    RemoveComRegistration(dll_path, false);
    return false;
  }
  *created = true;
  return true;
}

bool IsElevated() {
  HANDLE token = nullptr;
  if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token)) {
    return false;
  }
  TOKEN_ELEVATION elevation{};
  DWORD returned = 0;
  const BOOL result = GetTokenInformation(token, TokenElevation, &elevation,
                                          sizeof(elevation), &returned);
  CloseHandle(token);
  return result && elevation.TokenIsElevated != 0;
}

bool CreateProfiles(ComPtr<ITfInputProcessorProfiles>* profiles) {
  const HRESULT result = CoCreateInstance(
      CLSID_TF_InputProcessorProfiles, nullptr, CLSCTX_INPROC_SERVER,
      IID_ITfInputProcessorProfiles,
      reinterpret_cast<void**>(profiles->Put()));
  if (FAILED(result)) {
    return PrintHResultFailure("CoCreateInstance(InputProcessorProfiles)",
                               result);
  }
  return true;
}

bool CreateCategoryManager(ComPtr<ITfCategoryMgr>* categories) {
  const HRESULT result =
      CoCreateInstance(CLSID_TF_CategoryMgr, nullptr, CLSCTX_INPROC_SERVER,
                       IID_ITfCategoryMgr,
                       reinterpret_cast<void**>(categories->Put()));
  if (FAILED(result)) {
    return PrintHResultFailure("CoCreateInstance(CategoryMgr)", result);
  }
  return true;
}

bool EnumContainsGuid(IEnumGUID* enumerator, const GUID& expected,
                      bool* contains) {
  *contains = false;
  while (true) {
    GUID value{};
    ULONG fetched = 0;
    const HRESULT result = enumerator->Next(1, &value, &fetched);
    if (result == S_FALSE || fetched == 0) {
      return true;
    }
    if (FAILED(result)) {
      return PrintHResultFailure("IEnumGUID::Next", result);
    }
    if (IsEqualGUID(value, expected)) {
      *contains = true;
      return true;
    }
  }
}

bool IsProcessorRegistered(ITfInputProcessorProfiles* profiles,
                           bool* registered) {
  ComPtr<IEnumGUID> values;
  const HRESULT result = profiles->EnumInputProcessorInfo(values.Put());
  if (FAILED(result)) {
    return PrintHResultFailure("EnumInputProcessorInfo", result);
  }
  return EnumContainsGuid(values.Get(), kTextServiceClsid, registered);
}

bool IsProfileRegistered(ITfInputProcessorProfiles* profiles,
                         bool* registered) {
  *registered = false;
  BSTR description = nullptr;
  const HRESULT result = profiles->GetLanguageProfileDescription(
      kTextServiceClsid, kLanguageId, kLanguageProfileGuid, &description);
  if (result == S_OK) {
    if (description == nullptr) {
      std::cerr << "GetLanguageProfileDescription succeeded without returning "
                   "a description.\n";
      return false;
    }
    SysFreeString(description);
    *registered = true;
    return true;
  }
  if (description != nullptr) {
    SysFreeString(description);
  }
  // The documented API reports E_FAIL when the exact CLSID/LANGID/profile
  // tuple is absent. Treat only that result as a clean negative; malformed
  // arguments and every other failure remain fatal.
  if (result == E_FAIL) {
    return true;
  }
  return PrintHResultFailure("GetLanguageProfileDescription", result);
}

bool IsKeyboardCategoryRegistered(ITfCategoryMgr* categories,
                                  bool* registered) {
  ComPtr<IEnumGUID> values;
  const HRESULT result = categories->EnumItemsInCategory(
      GUID_TFCAT_TIP_KEYBOARD, values.Put());
  if (FAILED(result)) {
    return PrintHResultFailure("EnumItemsInCategory", result);
  }
  return EnumContainsGuid(values.Get(), kTextServiceClsid, registered);
}

bool LoadClassFactory() {
  ComPtr<IClassFactory> factory;
  const HRESULT result = CoGetClassObject(
      kTextServiceClsid, CLSCTX_INPROC_SERVER, nullptr, IID_IClassFactory,
      reinterpret_cast<void**>(factory.Put()));
  if (FAILED(result)) {
    return PrintHResultFailure("CoGetClassObject(RimesTsf)", result);
  }
  return true;
}

bool VerifyTsf(const std::wstring& dll_path);

bool RollBackRegistration(const std::wstring& dll_path,
                          ITfInputProcessorProfiles* profiles,
                          ITfCategoryMgr* categories,
                          const RegistrationDelta& delta) {
  bool success = true;
  if (delta.category_created) {
    const HRESULT result = categories->UnregisterCategory(
        kTextServiceClsid, GUID_TFCAT_TIP_KEYBOARD, kTextServiceClsid);
    if (FAILED(result)) {
      PrintHResultFailure("rollback UnregisterCategory(TIP_KEYBOARD)", result);
      success = false;
    }
  }
  if (delta.profile_created) {
    const HRESULT result = profiles->RemoveLanguageProfile(
        kTextServiceClsid, kLanguageId, kLanguageProfileGuid);
    if (FAILED(result)) {
      PrintHResultFailure("rollback RemoveLanguageProfile", result);
      success = false;
    }
  }
  if (delta.processor_created) {
    const HRESULT result = profiles->Unregister(kTextServiceClsid);
    if (FAILED(result)) {
      PrintHResultFailure("rollback InputProcessorProfiles::Unregister",
                          result);
      success = false;
    }
  }
  if (delta.com_created && !RemoveComRegistration(dll_path, true)) {
    success = false;
  }
  if (!success) {
    std::cerr << "Precise registration rollback was incomplete; no "
                 "pre-existing registration entries were intentionally "
                 "removed.\n";
  }
  return success;
}

bool RegisterTsf(const std::wstring& dll_path) {
  ComPtr<ITfInputProcessorProfiles> profiles;
  ComPtr<ITfCategoryMgr> categories;
  if (!CreateProfiles(&profiles) || !CreateCategoryManager(&categories)) {
    return false;
  }

  bool processor_exists = false;
  bool profile_exists = false;
  bool category_exists = false;
  if (!IsProcessorRegistered(profiles.Get(), &processor_exists) ||
      !IsProfileRegistered(profiles.Get(), &profile_exists) ||
      !IsKeyboardCategoryRegistered(categories.Get(), &category_exists)) {
    return false;
  }
  if (processor_exists != profile_exists ||
      processor_exists != category_exists) {
    std::cerr << "Refusing to repair a partial pre-existing shared TSF "
                 "registration; exact rollback could not preserve it.\n";
    return false;
  }

  RegistrationDelta delta;
  if (!EnsureComRegistration(dll_path, &delta.com_created)) {
    return false;
  }

  HRESULT result = S_OK;
  if (!processor_exists) {
    result = profiles->Register(kTextServiceClsid);
    if (FAILED(result)) {
      PrintHResultFailure("ITfInputProcessorProfiles::Register", result);
      goto rollback;
    }
    delta.processor_created = true;
  }

  if (!profile_exists) {
    result = profiles->AddLanguageProfile(
        kTextServiceClsid, kLanguageId, kLanguageProfileGuid, kDisplayName,
        static_cast<ULONG>(std::wcslen(kDisplayName)), dll_path.c_str(),
        static_cast<ULONG>(dll_path.size()), 0);
    if (FAILED(result)) {
      PrintHResultFailure("AddLanguageProfile", result);
      goto rollback;
    }
    delta.profile_created = true;
  }

  if (!category_exists) {
    result = categories->RegisterCategory(kTextServiceClsid,
                                          GUID_TFCAT_TIP_KEYBOARD,
                                          kTextServiceClsid);
    if (FAILED(result)) {
      PrintHResultFailure("RegisterCategory(TIP_KEYBOARD)", result);
      goto rollback;
    }
    delta.category_created = true;
  }

  // Verification is part of the registration transaction.  If loading the
  // class factory or any exact TSF-state check fails, roll back only entries
  // observed as absent before this invocation.  This is critical when the
  // other architecture, or a previous same-architecture install, already owns
  // some of the shared TSF state.
  if (!VerifyTsf(dll_path)) {
    std::cerr << "Registration verification failed; rolling back only state "
                 "created by this invocation.\n";
    goto rollback;
  }
  std::cout << "Registered RIMES TSF service (current process registry view).\n";
  return true;

rollback:
  RollBackRegistration(dll_path, profiles.Get(), categories.Get(), delta);
  return false;
}

bool UnregisterTsf(const std::wstring& dll_path) {
  ComRegistrationState com_state;
  ComRegistrationState other_view_state;
  if (!QueryComRegistration(&com_state) ||
      !QueryComRegistrationInView(OtherRegistryView(), &other_view_state)) {
    return false;
  }
  if (com_state.class_key_exists &&
      (!com_state.complete || !PathsEqual(com_state.dll_path, dll_path))) {
    std::cerr << "Refusing to unregister: the current-view CLSID does not "
                 "point to the supplied DLL.\n";
    return false;
  }

  // COM in-proc paths are architecture-specific, while the processor,
  // language profile, and category are shared TSF identity.  Removing either
  // architecture must leave the shared identity intact as long as the other
  // COM registry view still contains this CLSID.  An incomplete other-view
  // key is conservatively treated as installed: preserving shared state is
  // safer than breaking an installation we cannot prove absent.
  if (other_view_state.class_key_exists) {
    if (!RemoveComRegistration(dll_path, true)) {
      return false;
    }
    std::cout << "Unregistered the current RIMES COM architecture; retained "
                 "shared TSF state for the other architecture.\n";
    return true;
  }

  ComPtr<ITfInputProcessorProfiles> profiles;
  ComPtr<ITfCategoryMgr> categories;
  if (!CreateProfiles(&profiles) || !CreateCategoryManager(&categories)) {
    return false;
  }

  bool processor_exists = false;
  bool profile_exists = false;
  bool category_exists = false;
  if (!IsProcessorRegistered(profiles.Get(), &processor_exists) ||
      !IsProfileRegistered(profiles.Get(), &profile_exists) ||
      !IsKeyboardCategoryRegistered(categories.Get(), &category_exists)) {
    return false;
  }

  bool success = true;
  if (category_exists) {
    const HRESULT result = categories->UnregisterCategory(
        kTextServiceClsid, GUID_TFCAT_TIP_KEYBOARD, kTextServiceClsid);
    if (FAILED(result)) {
      PrintHResultFailure("UnregisterCategory(TIP_KEYBOARD)", result);
      success = false;
    }
  }
  if (profile_exists) {
    const HRESULT result = profiles->RemoveLanguageProfile(
        kTextServiceClsid, kLanguageId, kLanguageProfileGuid);
    if (FAILED(result)) {
      PrintHResultFailure("RemoveLanguageProfile", result);
      success = false;
    }
  }
  if (processor_exists) {
    const HRESULT result = profiles->Unregister(kTextServiceClsid);
    if (FAILED(result)) {
      PrintHResultFailure("ITfInputProcessorProfiles::Unregister", result);
      success = false;
    }
  }
  if (success && !RemoveComRegistration(dll_path, true)) {
    success = false;
  }
  if (success) {
    std::cout << "Unregistered RIMES TSF service (current process registry view).\n";
  }
  return success;
}

bool VerifyTsf(const std::wstring& dll_path) {
  ComRegistrationState com_state;
  if (!QueryComRegistration(&com_state)) {
    return false;
  }
  if (!com_state.complete || !PathsEqual(com_state.dll_path, dll_path) ||
      CompareStringOrdinal(com_state.threading_model.c_str(), -1,
                           kThreadingModel, -1, TRUE) != CSTR_EQUAL) {
    std::cerr << "COM registration is absent, incomplete, or points elsewhere.\n";
    return false;
  }

  ComPtr<ITfInputProcessorProfiles> profiles;
  ComPtr<ITfCategoryMgr> categories;
  if (!CreateProfiles(&profiles) || !CreateCategoryManager(&categories)) {
    return false;
  }
  bool processor_exists = false;
  bool profile_exists = false;
  bool category_exists = false;
  if (!IsProcessorRegistered(profiles.Get(), &processor_exists) ||
      !IsProfileRegistered(profiles.Get(), &profile_exists) ||
      !IsKeyboardCategoryRegistered(categories.Get(), &category_exists)) {
    return false;
  }
  if (!processor_exists || !profile_exists || !category_exists) {
    std::cerr << "TSF registration is incomplete: processor="
              << (processor_exists ? "present" : "missing")
              << ", language-profile="
              << (profile_exists ? "present" : "missing")
              << ", keyboard-category="
              << (category_exists ? "present" : "missing") << ".\n";
    return false;
  }
  if (!LoadClassFactory()) {
    return false;
  }
  std::cout << "Verified RIMES COM and TSF registration.\n";
  return true;
}

bool VerifyTsfAbsent() {
  ComRegistrationState com_state;
  ComRegistrationState other_view_state;
  if (!QueryComRegistration(&com_state) ||
      !QueryComRegistrationInView(OtherRegistryView(), &other_view_state)) {
    return false;
  }

  ComPtr<ITfInputProcessorProfiles> profiles;
  ComPtr<ITfCategoryMgr> categories;
  if (!CreateProfiles(&profiles) || !CreateCategoryManager(&categories)) {
    return false;
  }
  bool processor_exists = false;
  bool profile_exists = false;
  bool category_exists = false;
  if (!IsProcessorRegistered(profiles.Get(), &processor_exists) ||
      !IsProfileRegistered(profiles.Get(), &profile_exists) ||
      !IsKeyboardCategoryRegistered(categories.Get(), &category_exists)) {
    return false;
  }
  if (com_state.class_key_exists) {
    std::cerr << "The current-architecture COM registration is still present.\n";
    return false;
  }
  if (!other_view_state.class_key_exists &&
      (processor_exists || profile_exists || category_exists)) {
    std::cerr << "Shared TSF registration remains without either COM "
                 "architecture.\n";
    return false;
  }
  if (other_view_state.class_key_exists &&
      (!processor_exists || !profile_exists || !category_exists)) {
    std::cerr << "The other COM architecture remains, but its shared TSF "
                 "registration is incomplete.\n";
    return false;
  }
  std::cout << "Verified the current RIMES COM architecture is absent"
            << (other_view_state.class_key_exists
                    ? " and shared TSF state is retained for the other view.\n"
                    : " with no shared TSF state remaining.\n");
  return true;
}

void PrintMetadata() {
#if defined(_WIN64)
  constexpr const char* kArchitecture = "x64";
#else
  constexpr const char* kArchitecture = "x86";
#endif
  std::ostringstream language_id;
  language_id << "0x" << std::hex << std::uppercase << std::setw(4)
              << std::setfill('0') << static_cast<unsigned int>(kLanguageId);
  std::cout << "{\n"
            << "  \"formatVersion\": 1,\n"
            << "  \"product\": \"RIMES\",\n"
            << "  \"architecture\": \"" << kArchitecture << "\",\n"
            << "  \"registrar\": \"RimesRegistrar.exe\",\n"
            << "  \"textService\": {\n"
            << "    \"clsid\": \"" << Utf8(kTextServiceClsidString) << "\",\n"
            << "    \"profileGuid\": \""
            << Utf8(kLanguageProfileGuidString) << "\",\n"
            << "    \"languageId\": \"" << language_id.str() << "\",\n"
            << "    \"displayName\": \"" << Utf8(kDisplayName) << "\",\n"
            << "    \"dll\": \"" << Utf8(kDllFileName) << "\"\n"
            << "  }\n"
            << "}\n";
}

}  // namespace

int wmain(const int argc, wchar_t** argv) {
  Options options;
  if (!ParseOptions(argc, argv, &options)) {
    PrintUsage();
    return 2;
  }
  if (options.command == Command::kMetadata) {
    PrintMetadata();
    return 0;
  }

  std::wstring dll_path;
  if (!ValidateDll(options.dll_path, &dll_path)) {
    return 1;
  }
  if (options.dry_run) {
    std::cout << "Dry run: would "
              << (options.command == Command::kRegister ? "register "
                                                        : "unregister ")
              << "RIMES for the current process registry view; DLL="
              << Utf8(dll_path)
              << ". The default keyboard profile would not be changed.\n";
    return 0;
  }
  if ((options.command == Command::kRegister ||
       options.command == Command::kUnregister) &&
      !IsElevated()) {
    std::cerr << "Registration changes require an elevated process.\n";
    return 1;
  }

  ScopedCoInitialize com;
  if (FAILED(com.result())) {
    PrintHResultFailure("CoInitializeEx", com.result());
    return 1;
  }

  bool succeeded = false;
  switch (options.command) {
    case Command::kRegister:
      succeeded = RegisterTsf(dll_path);
      break;
    case Command::kUnregister:
      succeeded = UnregisterTsf(dll_path);
      break;
    case Command::kVerify:
      succeeded = VerifyTsf(dll_path);
      break;
    case Command::kVerifyAbsent:
      succeeded = VerifyTsfAbsent();
      break;
    case Command::kMetadata:
      succeeded = true;
      break;
  }
  return succeeded ? 0 : 1;
}
