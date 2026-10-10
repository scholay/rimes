#include "broker_connection.hpp"
#include "../core/control.hpp"
#include "../workbench/window.hpp"

#include <cstdlib>
#include <iostream>

namespace {
using namespace rimes::windows;
int failures = 0;
void Check(bool condition, const char* reason) {
  if (!condition) { std::cerr << "FAIL: " << reason << '\n'; ++failures; }
}
core::Frame Frame(core::MessageType type, std::vector<std::byte> payload,
                  std::uint32_t id = 1) {
  core::Frame result;
  result.header.message_type = type;
  result.header.request_id = id;
  result.payload = std::move(payload);
  return result;
}
core::Frame Hello(DWORD process, DWORD session = 42) {
  core::ClientHello hello;
  hello.process_id = process;
  hello.session_id = session;
  hello.client_name = "settings command test";
  std::vector<std::byte> payload;
  Check(core::EncodeClientHello(hello, &payload), "hello encodes");
  return Frame(core::MessageType::kClientHello, std::move(payload));
}
core::Frame Command(core::Json value = {{"op", "open_settings"}}) {
  return Frame(core::MessageType::kControl, core::EncodeControl(value), 2);
}
void TestAuthenticatedCommandWithoutInputSession() {
  int requests = 0;
  // No engine or Runtime: opening settings must not create an input session,
  // change host focus, capture keys or read real preferences/credentials.
  broker::BrokerConnection connection(42, nullptr, nullptr,
                                      [&] { ++requests; return true; });
  core::Frame response;
  Check(connection.Handle(Hello(100), 100, &response) ==
            broker::ClientAction::kContinue &&
        response.header.message_type == core::MessageType::kBrokerHello,
        "verified hello succeeds");
  Check(connection.Handle(Command(), 100, &response) ==
            broker::ClientAction::kContinue,
        "settings command succeeds without an engine session");
  const auto output = core::DecodeControl(response.payload);
  Check(output && output->value("kind", "") == "ok" && requests == 1,
        "accepted settings request posts once");
  connection.Handle(Command(), 100, &response);
  Check(requests == 2, "a second explicit request can foreground settings");
}
void TestCommandRequiresVerifiedHelloAndInteractiveHandler() {
  int requests = 0;
  core::Frame response;
  broker::BrokerConnection unverified(42, nullptr, nullptr,
                                      [&] { ++requests; return true; });
  Check(unverified.Handle(Command(), 100, &response) ==
            broker::ClientAction::kCloseAfterResponse,
        "command before hello is rejected");
  Check(requests == 0, "unverified command never reaches UI");
  broker::BrokerConnection wrong_identity(42, nullptr, nullptr,
                                         [&] { ++requests; return true; });
  Check(wrong_identity.Handle(Hello(101), 100, &response) ==
            broker::ClientAction::kCloseAfterResponse,
        "claimed PID must match pipe peer");
  Check(requests == 0, "incorrect identity never reaches UI");
  broker::BrokerConnection wrong_session(42, nullptr, nullptr,
                                        [&] { ++requests; return true; });
  Check(wrong_session.Handle(Hello(100, 41), 100, &response) ==
            broker::ClientAction::kCloseAfterResponse,
        "claimed logon session must match the broker");
  Check(requests == 0, "incorrect logon session never reaches UI");
  broker::BrokerConnection headless(42, nullptr);
  headless.Handle(Hello(100), 100, &response);
  Check(headless.Handle(Command(), 100, &response) ==
            broker::ClientAction::kCloseAfterResponse &&
        response.header.message_type == core::MessageType::kError,
        "headless broker rejects UI commands");
}
void TestLatePeerAndMalformedCommandsCannotOpenSettings() {
  int requests = 0;
  broker::BrokerConnection connection(42, nullptr, nullptr,
                                      [&] { ++requests; return true; });
  core::Frame response;
  connection.Handle(Hello(100), 100, &response);
  Check(connection.Handle(Command(), 101, &response) ==
            broker::ClientAction::kCloseAfterResponse,
        "a changed peer identity cannot use a previous hello");
  Check(requests == 0, "late mismatched peer does not reach UI");
  Check(connection.Handle(Command({{"op", "open_settings"}, {"session", 7}}),
                          100, &response) ==
            broker::ClientAction::kCloseAfterResponse,
        "UI command refuses a manufactured input target");
  Check(requests == 0, "malformed command does not reach UI");
  auto invalid = Command();
  invalid.header.request_id = 0;
  Check(connection.Handle(invalid, 100, &response) ==
            broker::ClientAction::kCloseAfterResponse,
        "zero request identity is rejected");
  Check(requests == 0, "invalid request identity does not reach UI");
}
void TestStartupRetry() {
  bool ready = false;
  int posts = 0;
  broker::BrokerConnection connection(42, nullptr, nullptr, [&] {
    if (!ready) return false;
    ++posts; return true;
  });
  core::Frame response;
  connection.Handle(Hello(100), 100, &response);
  connection.Handle(Command(), 100, &response);
  auto output = core::DecodeControl(response.payload);
  Check(output && output->value("kind", "") == "starting" && posts == 0,
        "UI startup asks for bounded retry without pretending to post");
  ready = true;
  connection.Handle(Command(), 100, &response);
  output = core::DecodeControl(response.payload);
  Check(output && output->value("kind", "") == "ok" && posts == 1,
        "retry posts only after UI becomes ready");
}
int posted_commands = 0;
LRESULT CALLBACK FixtureProcedure(HWND window, UINT message, WPARAM wparam,
                                  LPARAM lparam) {
  if (message >= WM_APP && message < 0xc000) {
    ++posted_commands;
    return 0;
  }
  return DefWindowProcW(window, message, wparam, lparam);
}
void TestUiDispatcherRetiresItsWindow() {
  workbench::UiCommands commands;
  Check(!commands.RequestSettings(), "dispatcher waits for UI creation");
  Check(!commands.RequestExit(), "maintenance exit waits for UI creation");
  WNDCLASSW fixture{};
  fixture.lpfnWndProc = FixtureProcedure;
  fixture.hInstance = GetModuleHandleW(nullptr);
  fixture.lpszClassName = L"Rimes.UiCommandFixture";
  RegisterClassW(&fixture);
  HWND window = CreateWindowW(fixture.lpszClassName, L"", 0, 0, 0, 0, 0,
                              HWND_MESSAGE, nullptr, fixture.hInstance, nullptr);
  Check(window != nullptr, "disposable message-only UI destination created");
  if (!window) return;
  commands.Attach(window);
  Check(commands.RequestSettings(), "ready dispatcher posts a settings request");
  Check(posted_commands == 0, "request never executes UI work on the caller thread");
  MSG message{};
  while (PeekMessageW(&message, window, 0, 0, PM_REMOVE))
    DispatchMessageW(&message);
  Check(posted_commands == 1, "one request reaches the UI thread once");
  Check(commands.RequestExit(), "maintenance exit posts without saving Buffer");
  while (PeekMessageW(&message, window, 0, 0, PM_REMOVE))
    DispatchMessageW(&message);
  Check(posted_commands == 2, "maintenance exit is handled by the UI thread");
  commands.Attach(nullptr);
  Check(!commands.RequestSettings(), "retired HWND cannot receive a late request");
  Check(!commands.RequestExit(), "retired HWND cannot receive a late exit");
  DestroyWindow(window);
  UnregisterClassW(fixture.lpszClassName, fixture.hInstance);
}
}
int main() {
  TestAuthenticatedCommandWithoutInputSession();
  TestCommandRequiresVerifiedHelloAndInteractiveHandler();
  TestLatePeerAndMalformedCommandsCannotOpenSettings();
  TestStartupRetry();
  TestUiDispatcherRetiresItsWindow();
  return failures ? EXIT_FAILURE : EXIT_SUCCESS;
}
