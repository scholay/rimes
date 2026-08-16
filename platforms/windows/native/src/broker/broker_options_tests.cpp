#include "broker_options.hpp"

#include <cstdlib>
#include <iostream>
#include <string>
#include <vector>

namespace rimes::windows::broker::tests {
namespace {

int g_failures = 0;

#if defined(_WIN32)
inline constexpr wchar_t kDllPath[] =
    L"C:\\Program Files\\RIMES\\rime.dll";
inline constexpr wchar_t kSharedPath[] =
    L"C:\\Program Files\\RIMES\\data";
inline constexpr wchar_t kUserPath[] =
    L"C:\\Users\\tester\\AppData\\Roaming\\RIMES";
inline constexpr wchar_t kLogPath[] =
    L"C:\\Users\\tester\\AppData\\Local\\RIMES\\Logs";
inline constexpr wchar_t kSecondDllPath[] = L"C:\\b\\rime.dll";
#else
inline constexpr wchar_t kDllPath[] = L"/opt/rimes/rime.dll";
inline constexpr wchar_t kSharedPath[] = L"/opt/rimes/data";
inline constexpr wchar_t kUserPath[] = L"/tmp/rimes/user";
inline constexpr wchar_t kLogPath[] = L"/tmp/rimes/logs";
inline constexpr wchar_t kSecondDllPath[] = L"/opt/rimes2/rime.dll";
#endif

#define EXPECT(condition)                                                     \
  do {                                                                        \
    if (!(condition)) {                                                       \
      std::cerr << __FILE__ << ':' << __LINE__ << ": expectation failed: "   \
                << #condition << '\n';                                        \
      ++g_failures;                                                           \
    }                                                                         \
  } while (false)

struct Arguments {
  explicit Arguments(std::initializer_list<const wchar_t*> values) {
    for (const wchar_t* value : values) {
      storage.emplace_back(value);
    }
    for (std::wstring& value : storage) {
      argv.push_back(value.data());
    }
  }

  int argc() const { return static_cast<int>(argv.size()); }

  std::vector<std::wstring> storage;
  std::vector<wchar_t*> argv;
};

bool Parse(Arguments* arguments,
           BrokerOptions* options,
           std::wstring* error) {
  return ParseBrokerOptions(arguments->argc(), arguments->argv.data(), options,
                            error);
}

void TestMissingEngineConfigurationFails() {
  Arguments arguments{L"RimesBroker.exe"};
  BrokerOptions options;
  std::wstring error;
  EXPECT(!Parse(&arguments, &options, &error));
  EXPECT(!error.empty());
}

void TestDiagnosticsNeedNoEngine() {
  {
    Arguments arguments{L"RimesBroker.exe", L"--help"};
    BrokerOptions options;
    std::wstring error;
    EXPECT(Parse(&arguments, &options, &error));
    EXPECT(options.show_help);
  }
  {
    Arguments arguments{L"RimesBroker.exe", L"--print-endpoint"};
    BrokerOptions options;
    std::wstring error;
    EXPECT(Parse(&arguments, &options, &error));
    EXPECT(options.print_endpoint);
  }
}

void TestExplicitEngineConfiguration() {
  Arguments arguments{
      L"RimesBroker.exe",
      L"--once",
      L"--full-maintenance-check",
      L"--rime-dll",
      kDllPath,
      L"--shared-data-dir",
      kSharedPath,
      L"--user-data-dir",
      kUserPath,
      L"--log-dir",
      kLogPath,
  };
  BrokerOptions options;
  std::wstring error;
  EXPECT(Parse(&arguments, &options, &error));
  EXPECT(options.serve_once);
  EXPECT(options.engine.full_maintenance_check);
  EXPECT(options.engine.dll_path.filename() == L"rime.dll");
  EXPECT(options.engine.shared_data_dir.is_absolute());
  EXPECT(options.engine.user_data_dir.is_absolute());
  EXPECT(options.engine.log_dir.is_absolute());
}

void TestAmbiguousOrRelativeConfigurationFails() {
  {
    Arguments arguments{L"RimesBroker.exe", L"--print-endpoint", L"--once"};
    BrokerOptions options;
    std::wstring error;
    EXPECT(!Parse(&arguments, &options, &error));
  }
  {
    Arguments arguments{
        L"RimesBroker.exe", L"--rime-dll", L"rime.dll",
        L"--shared-data-dir", L"data", L"--user-data-dir", L"user",
        L"--log-dir", L"logs"};
    BrokerOptions options;
    std::wstring error;
    EXPECT(!Parse(&arguments, &options, &error));
  }
  {
    Arguments arguments{L"RimesBroker.exe", L"--rime-dll", kDllPath,
                        L"--rime-dll", kSecondDllPath};
    BrokerOptions options;
    std::wstring error;
    EXPECT(!Parse(&arguments, &options, &error));
  }
}

}  // namespace

int RunBrokerOptionsTests() {
  TestMissingEngineConfigurationFails();
  TestDiagnosticsNeedNoEngine();
  TestExplicitEngineConfiguration();
  TestAmbiguousOrRelativeConfigurationFails();
  return g_failures == 0 ? EXIT_SUCCESS : EXIT_FAILURE;
}

}  // namespace rimes::windows::broker::tests

#if defined(_WIN32)
int wmain() {
#else
int main() {
#endif
  return rimes::windows::broker::tests::RunBrokerOptionsTests();
}
