#include <Windows.h>
#include <msctf.h>
#include <oleauto.h>

#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>

#include "Guids.h"

namespace {

enum class Imports { kStatic, kShared, kInvalid };

// The delay-load descriptor uses RVAs when bit 0 of Attributes is set, or VAs
// for the legacy PE32 format. Do not overlook /DELAYLOAD runtime dependencies.
struct DelayDescriptor {
  DWORD attributes;
  DWORD name;
  DWORD module;
  DWORD address_table;
  DWORD name_table;
  DWORD bound_table;
  DWORD unload_table;
  DWORD timestamp;
};

bool SharedCrt(const char* name) {
  return _strnicmp(name, "msvcp", 5) == 0 ||
         _strnicmp(name, "vcruntime", 9) == 0 ||
         _strnicmp(name, "msvcr", 5) == 0 ||
         _strnicmp(name, "api-ms-win-crt-", 15) == 0 ||
         _stricmp(name, "ucrtbase.dll") == 0 ||
         _stricmp(name, "ucrtbased.dll") == 0;
}

bool Within(const std::size_t offset, const std::size_t bytes,
            const std::size_t image_size) {
  return offset <= image_size && bytes <= image_size - offset;
}

Imports CheckImports(HMODULE module) {
  const auto* base = reinterpret_cast<const unsigned char*>(module);
  const auto* dos = reinterpret_cast<const IMAGE_DOS_HEADER*>(base);
  // These are loader-mapped images, not arbitrary files. Still bound the
  // descriptor/name traversal so a malformed directory cannot pass the guard.
  if (dos->e_magic != IMAGE_DOS_SIGNATURE || dos->e_lfanew <= 0)
    return Imports::kInvalid;
  const auto* nt = reinterpret_cast<const IMAGE_NT_HEADERS*>(
      base + static_cast<std::size_t>(dos->e_lfanew));
  if (nt->Signature != IMAGE_NT_SIGNATURE ||
      nt->OptionalHeader.Magic != IMAGE_NT_OPTIONAL_HDR_MAGIC ||
      static_cast<std::size_t>(nt->FileHeader.SizeOfOptionalHeader) <
          sizeof(IMAGE_OPTIONAL_HEADER) ||
      nt->OptionalHeader.NumberOfRvaAndSizes <= IMAGE_DIRECTORY_ENTRY_DELAY_IMPORT)
    return Imports::kInvalid;
  const auto image_size = static_cast<std::size_t>(nt->OptionalHeader.SizeOfImage);
  if (!Within(static_cast<std::size_t>(dos->e_lfanew), sizeof(*nt), image_size))
    return Imports::kInvalid;

  bool shared = false;
  const auto inspect_name = [&](const std::size_t offset) {
    if (!Within(offset, 1, image_size)) return false;
    const auto* name = reinterpret_cast<const char*>(base + offset);
    if (std::memchr(name, '\0', image_size - offset) == nullptr) return false;
    if (SharedCrt(name)) {
      std::fprintf(stderr, "Shared CRT import: %s\n", name);
      shared = true;
    }
    return true;
  };
  for (const DWORD index : {IMAGE_DIRECTORY_ENTRY_IMPORT,
                            IMAGE_DIRECTORY_ENTRY_DELAY_IMPORT}) {
    const auto& directory = nt->OptionalHeader.DataDirectory[index];
    if (directory.VirtualAddress == 0 && directory.Size == 0) continue;
    const auto descriptor_size = index == IMAGE_DIRECTORY_ENTRY_IMPORT
                                     ? sizeof(IMAGE_IMPORT_DESCRIPTOR)
                                     : sizeof(DelayDescriptor);
    if (directory.Size < descriptor_size ||
        !Within(directory.VirtualAddress, directory.Size, image_size))
      return Imports::kInvalid;
    bool terminated = false;
    for (std::size_t offset = 0;
         offset <= static_cast<std::size_t>(directory.Size) - descriptor_size;
         offset += descriptor_size) {
      const auto* entry = base + directory.VirtualAddress + offset;
      std::size_t name_offset = 0;
      if (index == IMAGE_DIRECTORY_ENTRY_IMPORT) {
        const auto* descriptor =
            reinterpret_cast<const IMAGE_IMPORT_DESCRIPTOR*>(entry);
        if (descriptor->Name == 0) {
          terminated = true;
          break;
        }
        name_offset = descriptor->Name;
      } else {
        const auto* descriptor = reinterpret_cast<const DelayDescriptor*>(entry);
        if (descriptor->name == 0) {
          terminated = true;
          break;
        }
        if ((descriptor->attributes & ~1U) != 0) return Imports::kInvalid;
        name_offset = descriptor->name;
        if ((descriptor->attributes & 1U) == 0) {
          const auto image_base = reinterpret_cast<std::uintptr_t>(base);
          if (name_offset < image_base) return Imports::kInvalid;
          name_offset -= image_base;
        }
      }
      if (!inspect_name(name_offset)) return Imports::kInvalid;
    }
    if (!terminated) return Imports::kInvalid;
  }
  return shared ? Imports::kShared : Imports::kStatic;
}

std::wstring AbsolutePath(const wchar_t* path) {
  const DWORD required = GetFullPathNameW(path, 0, nullptr, nullptr);
  if (required == 0) return {};
  std::wstring full(required, L'\0');
  const DWORD length = GetFullPathNameW(path, required, full.data(), nullptr);
  if (length == 0 || length >= required) return {};
  full.resize(length);
  return full;
}

bool SameFile(const wchar_t* first, const wchar_t* second) {
  const auto open = [](const wchar_t* path) {
    return CreateFileW(path, FILE_READ_ATTRIBUTES,
                       FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                       nullptr, OPEN_EXISTING, 0, nullptr);
  };
  HANDLE left = open(first);
  HANDLE right = open(second);
  BY_HANDLE_FILE_INFORMATION left_info{}, right_info{};
  const bool read = left != INVALID_HANDLE_VALUE && right != INVALID_HANDLE_VALUE &&
                    GetFileInformationByHandle(left, &left_info) &&
                    GetFileInformationByHandle(right, &right_info);
  if (left != INVALID_HANDLE_VALUE) CloseHandle(left);
  if (right != INVALID_HANDLE_VALUE) CloseHandle(right);
  return read && left_info.dwVolumeSerialNumber == right_info.dwVolumeSerialNumber &&
         left_info.nFileIndexHigh == right_info.nFileIndexHigh &&
         left_info.nFileIndexLow == right_info.nFileIndexLow;
}

HMODULE PreloadRuntime(const wchar_t* path) {
  const auto full = AbsolutePath(path);
  const auto slash = full.find_last_of(L"\\/");
  if (full.empty() || slash == std::wstring::npos ||
      _wcsicmp(full.c_str() + slash + 1, L"MSVCP140.dll") != 0) {
    std::fprintf(stderr, "Host runtime must name an existing MSVCP140.dll.\n");
    return nullptr;
  }
  HMODULE module = LoadLibraryExW(full.c_str(), nullptr,
      LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_SYSTEM32);
  if (module == nullptr) {
    std::fprintf(stderr, "Cannot preload matching-architecture host runtime: %lu\n",
                 GetLastError());
    return nullptr;
  }
  wchar_t loaded[32768]{};
  const DWORD length = GetModuleFileNameW(module, loaded, 32768);
  if (length == 0 || length >= 32768 || !SameFile(full.c_str(), loaded)) {
    std::fprintf(stderr, "The requested host runtime was not the DLL loaded.\n");
    FreeLibrary(module);
    return nullptr;
  }
  std::printf("Preloaded host runtime: %ls\n", loaded);
  return module;
}

template <class T> struct ComPointer {
  T* value = nullptr;
  ~ComPointer() { if (value != nullptr) value->Release(); }
};

bool CheckComBoundary(IUnknown* service) {
  ComPointer<ITfDisplayAttributeProvider> provider;
  if (FAILED(service->QueryInterface(IID_ITfDisplayAttributeProvider,
                reinterpret_cast<void**>(&provider.value))) || !provider.value)
    return false;
  ComPointer<IEnumTfDisplayAttributeInfo> enumerator;
  if (FAILED(provider.value->EnumDisplayAttributeInfo(&enumerator.value)) ||
      !enumerator.value) return false;
  ComPointer<ITfDisplayAttributeInfo> attribute;
  ULONG fetched = 0;
  if (enumerator.value->Next(1, &attribute.value, &fetched) != S_OK ||
      fetched != 1 || !attribute.value) return false;
  BSTR description = nullptr;
  const HRESULT described = attribute.value->GetDescription(&description);
  const bool description_ok = SUCCEEDED(described) && description != nullptr &&
                             SysStringLen(description) != 0;
  // The DLL allocates using the COM allocator, and the /MT host frees it using
  // the same documented allocator, rather than either module's private CRT.
  SysFreeString(description);
  GUID guid{};
  TF_DISPLAYATTRIBUTE display{};
  return description_ok && SUCCEEDED(attribute.value->GetGUID(&guid)) &&
         InlineIsEqualGUID(guid, rimes::windows::tsf::kInputDisplayAttributeGuid) &&
         SUCCEEDED(attribute.value->GetAttributeInfo(&display)) &&
         display.bAttr == TF_ATTR_INPUT;
}

using GetClassObject = HRESULT(STDAPICALLTYPE*)(REFCLSID, REFIID, void**);
using CanUnload = HRESULT(STDAPICALLTYPE*)();

bool RunLifecycles(GetClassObject get_class, const int iterations) {
  const HRESULT initialized = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  if (FAILED(initialized)) return false;
  bool passed = true;
  {
    ComPointer<IClassFactory> factory;
    passed = SUCCEEDED(get_class(rimes::windows::tsf::kTextServiceClsid,
        IID_IClassFactory, reinterpret_cast<void**>(&factory.value))) && factory.value;
    for (int i = 0; passed && i < iterations; ++i) {
      ComPointer<IUnknown> service;
      passed = SUCCEEDED(factory.value->CreateInstance(nullptr, IID_IUnknown,
          reinterpret_cast<void**>(&service.value))) && service.value &&
          CheckComBoundary(service.value);
      // Release destroys NamedPipeBrokerClient and locks its mutex. This must
      // remain safe with the host's older MSVCP140.dll already in the process.
    }
  }
  CoUninitialize();
  return passed;
}

DWORD WINAPI ThreadLifecycles(void* parameter) {
  const auto* get_class = static_cast<const GetClassObject*>(parameter);
  return RunLifecycles(*get_class, 25) ? 0 : 1;
}

bool ConcurrentLifecycles(GetClassObject get_class) {
  HANDLE threads[4]{};
  bool passed = true;
  for (auto& thread : threads) {
    thread = CreateThread(nullptr, 0, ThreadLifecycles, &get_class, 0, nullptr);
    if (thread == nullptr) passed = false;
  }
  // Join every thread before unloading the DLL, even if another creation failed.
  for (HANDLE thread : threads) {
    if (!thread) continue;
    DWORD result = 1;
    if (WaitForSingleObject(thread, INFINITE) != WAIT_OBJECT_0 ||
        !GetExitCodeThread(thread, &result) || result != 0) passed = false;
    CloseHandle(thread);
  }
  return passed;
}

template <typename Function>
Function ResolveProcedure(HMODULE module, const char* name) {
  static_assert(sizeof(Function) == sizeof(FARPROC));
  const FARPROC raw = GetProcAddress(module, name);
  Function resolved = nullptr;
  std::memcpy(&resolved, &raw, sizeof(resolved));
  return resolved;
}

}  // namespace

int wmain(int argc, wchar_t** argv) {
  if (argc < 2 || argc > 3) {
    std::fprintf(stderr, "Usage: RimesTsfRuntimeTests TSF_DLL [HOST_MSVCP140_DLL]\n"
        "       RimesTsfRuntimeTests --check-static-crt DLL\n"
        "       RimesTsfRuntimeTests --expect-shared-crt DLL\n");
    return 2;
  }
  SetErrorMode(SEM_FAILCRITICALERRORS | SEM_NOGPFAULTERRORBOX);
  const bool check_only = argc == 3 && _wcsicmp(argv[1], L"--check-static-crt") == 0;
  const bool negative = argc == 3 && _wcsicmp(argv[1], L"--expect-shared-crt") == 0;
  const auto dll = AbsolutePath(check_only || negative ? argv[2] : argv[1]);
  // Inspect the actual PE before resolving imports or executing DllMain. The
  // negative control must not run its /MD mutex code under a poisoned runtime.
  HMODULE image = LoadLibraryExW(dll.c_str(), nullptr, DONT_RESOLVE_DLL_REFERENCES);
  if (!image) {
    std::fprintf(stderr, "Cannot map DLL: %lu\n", GetLastError());
    return 1;
  }
  const Imports imports = CheckImports(image);
  FreeLibrary(image);
  if (negative) return imports == Imports::kShared ? 0 : 1;
  if (imports == Imports::kInvalid) {
    std::fprintf(stderr, "Invalid PE import directory.\n");
    return 1;
  }
#ifdef _MSC_VER
  if (imports != Imports::kStatic ||
      CheckImports(GetModuleHandleW(nullptr)) != Imports::kStatic) {
    std::fprintf(stderr, "TSF and its test host must not import a shared MSVC CRT.\n");
    return 1;
  }
#endif
  if (check_only) return imports == Imports::kStatic ? 0 : 1;
  HMODULE runtime = argc == 3 ? PreloadRuntime(argv[2]) : nullptr;
  if (argc == 3 && !runtime) return 1;
  HMODULE module = LoadLibraryExW(dll.c_str(), nullptr,
      LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_SYSTEM32);
  if (!module) {
    std::fprintf(stderr, "Cannot load TSF: %lu\n", GetLastError());
    if (runtime) FreeLibrary(runtime);
    return 1;
  }
  const auto get_class = ResolveProcedure<GetClassObject>(module, "DllGetClassObject");
  const auto can_unload = ResolveProcedure<CanUnload>(module, "DllCanUnloadNow");
  const bool passed = get_class && can_unload && can_unload() == S_OK &&
      RunLifecycles(get_class, 100) && ConcurrentLifecycles(get_class) &&
      can_unload() == S_OK;
  FreeLibrary(module);
  if (runtime) FreeLibrary(runtime);
  if (!passed) {
    std::fprintf(stderr, "TSF COM lifecycle or allocation ownership check failed.\n");
    return 1;
  }
  std::puts("TSF runtime isolation: 100 main-thread + 100 concurrent-thread "
            "COM lifecycles passed; COM-owned strings freed by host.");
  return 0;
}
