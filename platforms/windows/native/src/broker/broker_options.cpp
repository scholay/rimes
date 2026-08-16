#include "broker_options.hpp"

#include <filesystem>
#include <string_view>

namespace rimes::windows::broker {
namespace {

void SetError(std::wstring* error, std::wstring_view message) noexcept {
  if (error == nullptr) {
    return;
  }
  try {
    error->assign(message);
  } catch (...) {
  }
}

bool ReadUniquePath(int argc,
                    wchar_t** argv,
                    int* index,
                    bool* seen,
                    std::filesystem::path* output,
                    std::wstring_view option,
                    std::wstring* error) {
  if (*seen) {
    SetError(error, std::wstring(L"duplicate option: ") +
                        std::wstring(option));
    return false;
  }
  if (*index + 1 >= argc || argv[*index + 1] == nullptr ||
      argv[*index + 1][0] == L'\0') {
    SetError(error, std::wstring(L"missing value for ") +
                        std::wstring(option));
    return false;
  }
  const std::wstring_view value(argv[*index + 1]);
  if (value.starts_with(L"--")) {
    SetError(error, std::wstring(L"missing value for ") +
                        std::wstring(option));
    return false;
  }
  *output = std::filesystem::path(value);
  *seen = true;
  ++*index;
  return true;
}

bool RequireAbsolute(const std::filesystem::path& path,
                     std::wstring_view option,
                     std::wstring* error) {
  if (!path.empty() && path.is_absolute()) {
    return true;
  }
  SetError(error, std::wstring(option) +
                      L" requires an absolute local path");
  return false;
}

}  // namespace

bool ParseBrokerOptions(int argc,
                        wchar_t** argv,
                        BrokerOptions* options,
                        std::wstring* error) noexcept {
  if (options == nullptr || argc < 1 || argv == nullptr) {
    SetError(error, L"broker option output or process arguments are invalid");
    return false;
  }

  try {
    *options = BrokerOptions{};
    BrokerOptions parsed;
    bool saw_once = false;
    bool saw_endpoint = false;
    bool saw_help = false;
    bool saw_full_maintenance = false;
    bool saw_dll = false;
    bool saw_shared = false;
    bool saw_user = false;
    bool saw_log = false;

    for (int index = 1; index < argc; ++index) {
      if (argv[index] == nullptr) {
        SetError(error, L"broker argument is null");
        return false;
      }
      const std::wstring_view argument(argv[index]);
      if (argument == L"--once") {
        if (saw_once) {
          SetError(error, L"duplicate option: --once");
          return false;
        }
        saw_once = true;
        parsed.serve_once = true;
      } else if (argument == L"--print-endpoint") {
        if (saw_endpoint) {
          SetError(error, L"duplicate option: --print-endpoint");
          return false;
        }
        saw_endpoint = true;
        parsed.print_endpoint = true;
      } else if (argument == L"--help" || argument == L"-h" ||
                 argument == L"/?") {
        if (saw_help) {
          SetError(error, L"duplicate help option");
          return false;
        }
        saw_help = true;
        parsed.show_help = true;
      } else if (argument == L"--full-maintenance-check") {
        if (saw_full_maintenance) {
          SetError(error, L"duplicate option: --full-maintenance-check");
          return false;
        }
        saw_full_maintenance = true;
        parsed.engine.full_maintenance_check = true;
      } else if (argument == L"--rime-dll") {
        if (!ReadUniquePath(argc, argv, &index, &saw_dll,
                            &parsed.engine.dll_path, argument, error)) {
          return false;
        }
      } else if (argument == L"--shared-data-dir") {
        if (!ReadUniquePath(argc, argv, &index, &saw_shared,
                            &parsed.engine.shared_data_dir, argument, error)) {
          return false;
        }
      } else if (argument == L"--user-data-dir") {
        if (!ReadUniquePath(argc, argv, &index, &saw_user,
                            &parsed.engine.user_data_dir, argument, error)) {
          return false;
        }
      } else if (argument == L"--log-dir") {
        if (!ReadUniquePath(argc, argv, &index, &saw_log,
                            &parsed.engine.log_dir, argument, error)) {
          return false;
        }
      } else {
        SetError(error, std::wstring(L"unknown option: ") +
                            std::wstring(argument));
        return false;
      }
    }

    if (parsed.show_help) {
      if (argc != 2) {
        SetError(error, L"the help option must be used by itself");
        return false;
      }
      *options = std::move(parsed);
      return true;
    }

    const bool has_any_engine_option = saw_dll || saw_shared || saw_user ||
                                       saw_log || saw_full_maintenance;
    if (parsed.print_endpoint) {
      if (parsed.serve_once || has_any_engine_option) {
        SetError(error,
                 L"--print-endpoint cannot be combined with serving or engine options");
        return false;
      }
      *options = std::move(parsed);
      return true;
    }

    if (!saw_dll || !saw_shared || !saw_user || !saw_log) {
      SetError(error,
               L"serving requires --rime-dll, --shared-data-dir, "
               L"--user-data-dir, and --log-dir; no paths are inferred");
      return false;
    }
    if (!RequireAbsolute(parsed.engine.dll_path, L"--rime-dll", error) ||
        !RequireAbsolute(parsed.engine.shared_data_dir, L"--shared-data-dir",
                         error) ||
        !RequireAbsolute(parsed.engine.user_data_dir, L"--user-data-dir",
                         error) ||
        !RequireAbsolute(parsed.engine.log_dir, L"--log-dir", error)) {
      return false;
    }

    *options = std::move(parsed);
    return true;
  } catch (...) {
    SetError(error, L"exception while parsing broker options");
    return false;
  }
}

}  // namespace rimes::windows::broker
