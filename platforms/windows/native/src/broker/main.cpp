#include "broker_connection.hpp"
#include "broker_options.hpp"
#include "named_pipe_server.hpp"
#include "single_instance.hpp"
#include "win32_security.hpp"

#include <iostream>
#include <memory>
#include <string>

#include "../engine/rime_engine.hpp"

namespace rimes::windows::broker {
namespace {

void PrintUsage() {
  std::wcout
      << L"RIMES Windows Broker 0.1.0-dev\n\n"
      << L"Usage:\n"
      << L"  RimesBroker --print-endpoint\n"
      << L"  RimesBroker [--once] --rime-dll <absolute-path>\n"
      << L"      --shared-data-dir <absolute-path>\n"
      << L"      --user-data-dir <absolute-path>\n"
      << L"      --log-dir <absolute-path> [--full-maintenance-check]\n\n"
      << L"  --once                  Serve one verified client, then exit.\n"
      << L"  --print-endpoint        Print this user's pipe name, then exit.\n"
      << L"  --full-maintenance-check  Ask librime for a full maintenance pass.\n";
}

}  // namespace
}  // namespace rimes::windows::broker

int wmain(const int argc, wchar_t** argv) {
  using namespace rimes::windows;
  using namespace rimes::windows::broker;

  BrokerOptions options;
  std::wstring error;
  if (!ParseBrokerOptions(argc, argv, &options, &error)) {
    std::wcerr << L"Invalid broker options: " << error << L'\n';
    PrintUsage();
    return 2;
  }
  if (options.show_help) {
    PrintUsage();
    return 0;
  }

  UserSecurityContext security;
  if (!security.Initialize(&error)) {
    std::wcerr << L"Failed to initialize broker security: " << error << L'\n';
    return 3;
  }
  if (options.print_endpoint) {
    std::wcout << security.pipe_name() << L'\n';
    return 0;
  }

  SingleInstance instance;
  if (!instance.Acquire(security.mutex_name(), security.attributes(), &error)) {
    std::wcerr << L"Failed to acquire the broker mutex: " << error << L'\n';
    return 4;
  }
  if (instance.already_running()) {
    std::wcerr << L"The per-user RIMES broker is already running.\n";
    return 0;
  }

  engine::RimeEngine engine;
  std::string engine_error;
  if (!engine.Start(options.engine, &engine_error)) {
    std::cerr << "Failed to start the RIME engine: " << engine_error << '\n';
    return 5;
  }

  NamedPipeServer server(&security);
  error.clear();
  const ServeResult result = server.ServeClients(
      [&security, &engine](DWORD) {
        auto connection = std::make_shared<BrokerConnection>(
            security.session_id(), &engine);
        return [connection](const core::Frame& request,
                            const DWORD client_process_id,
                            core::Frame* response) {
          return connection->Handle(request, client_process_id, response);
        };
      },
      options.serve_once, &error);
  if (result == ServeResult::kFatalError) {
    std::wcerr << L"Broker pipe failure: " << error << L'\n';
    return 6;
  }
  if (result == ServeResult::kClientRejected && !error.empty()) {
    std::wcerr << L"Rejected broker client: " << error << L'\n';
  }
  return 0;
}
