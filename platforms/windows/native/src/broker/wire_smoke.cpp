#include "win32_security.hpp"

#include <algorithm>
#include <array>
#include <cerrno>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <limits>
#include <memory>
#include <span>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

#include "../core/broker_protocol.hpp"

namespace rimes::windows::broker::wire_smoke {
namespace {

class HandleCloser {
 public:
  void operator()(void* handle) const noexcept {
    if (handle != nullptr && handle != INVALID_HANDLE_VALUE) {
      CloseHandle(handle);
    }
  }
};

using UniqueHandle = std::unique_ptr<void, HandleCloser>;

struct Options {
  DWORD timeout_millis = 5000;
  std::size_t minimum_candidates = 0;
  bool show_help = false;
};

void PrintUsage() {
  std::wcout
      << L"Usage: RimesBrokerWireSmoke [--timeout-ms 5000] "
         L"[--min-candidates 0]\n"
      << L"Connects to the current user's already-running RIMES Broker.\n";
}

bool ParseUnsigned(std::wstring_view text,
                   unsigned long long maximum,
                   unsigned long long* value) {
  if (text.empty() || value == nullptr) {
    return false;
  }
  std::wstring owned(text);
  wchar_t* end = nullptr;
  errno = 0;
  const unsigned long long parsed = std::wcstoull(owned.c_str(), &end, 10);
  if (errno == ERANGE || end == owned.c_str() || *end != L'\0' ||
      parsed > maximum) {
    return false;
  }
  *value = parsed;
  return true;
}

bool ParseOptions(int argc,
                  wchar_t** argv,
                  Options* options,
                  std::wstring* error) {
  if (options == nullptr || argv == nullptr || argc < 1) {
    if (error != nullptr) {
      *error = L"invalid process arguments";
    }
    return false;
  }
  Options parsed;
  bool saw_timeout = false;
  bool saw_minimum = false;
  for (int index = 1; index < argc; ++index) {
    const std::wstring_view argument(argv[index]);
    if (argument == L"--help" || argument == L"-h" || argument == L"/?") {
      if (argc != 2) {
        if (error != nullptr) {
          *error = L"help must be used by itself";
        }
        return false;
      }
      parsed.show_help = true;
      *options = parsed;
      return true;
    }
    if (argument != L"--timeout-ms" && argument != L"--min-candidates") {
      if (error != nullptr) {
        *error = L"unknown option: " + std::wstring(argument);
      }
      return false;
    }
    if (index + 1 >= argc) {
      if (error != nullptr) {
        *error = L"missing value for " + std::wstring(argument);
      }
      return false;
    }
    unsigned long long value = 0;
    if (!ParseUnsigned(argv[++index],
                       argument == L"--timeout-ms" ? 60000ULL :
                                                       core::kMaxCandidateCount,
                       &value)) {
      if (error != nullptr) {
        *error = L"invalid numeric value for " + std::wstring(argument);
      }
      return false;
    }
    if (argument == L"--timeout-ms") {
      if (saw_timeout || value < 100) {
        if (error != nullptr) {
          *error = saw_timeout ? L"duplicate --timeout-ms"
                               : L"--timeout-ms must be at least 100";
        }
        return false;
      }
      saw_timeout = true;
      parsed.timeout_millis = static_cast<DWORD>(value);
    } else {
      if (saw_minimum) {
        if (error != nullptr) {
          *error = L"duplicate --min-candidates";
        }
        return false;
      }
      saw_minimum = true;
      parsed.minimum_candidates = static_cast<std::size_t>(value);
    }
  }
  *options = parsed;
  return true;
}

DWORD RemainingTimeout(ULONGLONG deadline) noexcept {
  const ULONGLONG now = GetTickCount64();
  if (now >= deadline) {
    return 0;
  }
  const ULONGLONG remaining = deadline - now;
  return static_cast<DWORD>((std::min)(
      remaining, static_cast<ULONGLONG>(std::numeric_limits<DWORD>::max())));
}

bool TransferExact(HANDLE pipe,
                   void* buffer,
                   std::size_t size,
                   bool write,
                   DWORD timeout_millis,
                   std::wstring* error) {
  auto* bytes = static_cast<std::byte*>(buffer);
  std::size_t offset = 0;
  const ULONGLONG deadline = GetTickCount64() + timeout_millis;
  while (offset < size) {
    const DWORD timeout = RemainingTimeout(deadline);
    if (timeout == 0) {
      if (error != nullptr) {
        *error = write ? L"timed out writing a broker frame"
                       : L"timed out reading a broker frame";
      }
      return false;
    }

    UniqueHandle event(CreateEventW(nullptr, TRUE, FALSE, nullptr));
    if (!event) {
      if (error != nullptr) {
        *error = L"CreateEvent failed: " +
                 FormatWindowsError(GetLastError());
      }
      return false;
    }
    OVERLAPPED overlapped{};
    overlapped.hEvent = event.get();
    const DWORD requested = static_cast<DWORD>((std::min)(
        size - offset,
        static_cast<std::size_t>(std::numeric_limits<DWORD>::max())));
    const BOOL started =
        write ? WriteFile(pipe, bytes + offset, requested, nullptr, &overlapped)
              : ReadFile(pipe, bytes + offset, requested, nullptr, &overlapped);
    if (!started && GetLastError() != ERROR_IO_PENDING) {
      if (error != nullptr) {
        *error = (write ? L"WriteFile failed: " : L"ReadFile failed: ") +
                 FormatWindowsError(GetLastError());
      }
      return false;
    }

    const DWORD wait_result = WaitForSingleObject(event.get(), timeout);
    if (wait_result != WAIT_OBJECT_0) {
      const DWORD wait_error =
          wait_result == WAIT_FAILED ? GetLastError() : ERROR_SUCCESS;
      CancelIoEx(pipe, &overlapped);
      DWORD ignored = 0;
      GetOverlappedResult(pipe, &overlapped, &ignored, TRUE);
      if (error != nullptr) {
        *error = wait_result == WAIT_TIMEOUT
                     ? (write ? L"timed out writing a broker frame"
                              : L"timed out reading a broker frame")
                     : L"waiting for broker I/O failed: " +
                           FormatWindowsError(wait_error);
      }
      return false;
    }

    DWORD transferred = 0;
    if (!GetOverlappedResult(pipe, &overlapped, &transferred, FALSE)) {
      if (error != nullptr) {
        *error = L"broker overlapped I/O failed: " +
                 FormatWindowsError(GetLastError());
      }
      return false;
    }
    if (transferred == 0 || transferred > requested) {
      if (error != nullptr) {
        *error = L"broker I/O completed without valid progress";
      }
      return false;
    }
    offset += transferred;
  }
  return true;
}

bool WriteFrame(HANDLE pipe,
                const core::Frame& frame,
                DWORD timeout_millis,
                std::wstring* error) {
  std::vector<std::byte> encoded;
  std::string codec_error;
  if (!core::EncodeFrame(frame, &encoded, &codec_error) ||
      encoded.size() > core::kMaxFrameSize) {
    if (error != nullptr) {
      *error = L"refused to write an invalid or oversized broker frame";
    }
    return false;
  }
  return TransferExact(pipe, encoded.data(), encoded.size(), true,
                       timeout_millis, error);
}

bool ReadFrame(HANDLE pipe,
               core::Frame* frame,
               DWORD timeout_millis,
               std::wstring* error) {
  if (frame == nullptr) {
    return false;
  }
  std::array<std::byte, core::kFrameHeaderSize> header_bytes{};
  if (!TransferExact(pipe, header_bytes.data(), header_bytes.size(), false,
                     timeout_millis, error)) {
    return false;
  }
  const core::HeaderDecodeResult header =
      core::DecodeFrameHeader(header_bytes);
  if (header.status != core::DecodeStatus::kComplete ||
      header.header.payload_size > core::kMaxPayloadSize) {
    if (error != nullptr) {
      *error = L"broker returned an invalid frame header";
    }
    return false;
  }

  const std::size_t frame_size =
      core::kFrameHeaderSize + header.header.payload_size;
  if (frame_size > core::kMaxFrameSize) {
    if (error != nullptr) {
      *error = L"broker returned an oversized frame";
    }
    return false;
  }
  std::vector<std::byte> encoded(frame_size);
  std::memcpy(encoded.data(), header_bytes.data(), header_bytes.size());
  if (header.header.payload_size != 0 &&
      !TransferExact(pipe, encoded.data() + core::kFrameHeaderSize,
                     header.header.payload_size, false, timeout_millis,
                     error)) {
    return false;
  }
  core::FrameDecodeResult decoded = core::DecodeFrame(encoded);
  if (decoded.status != core::DecodeStatus::kComplete ||
      decoded.bytes_consumed != encoded.size()) {
    if (error != nullptr) {
      *error = L"broker returned a malformed frame";
    }
    return false;
  }
  *frame = std::move(decoded.frame);
  return true;
}

UniqueHandle Connect(const std::wstring& pipe_name,
                     DWORD timeout_millis,
                     std::wstring* error) {
  const ULONGLONG deadline = GetTickCount64() + timeout_millis;
  for (;;) {
    HANDLE pipe = CreateFileW(
        pipe_name.c_str(), GENERIC_READ | GENERIC_WRITE, 0, nullptr,
        OPEN_EXISTING,
        FILE_FLAG_OVERLAPPED | SECURITY_SQOS_PRESENT | SECURITY_IDENTIFICATION,
        nullptr);
    if (pipe != INVALID_HANDLE_VALUE) {
      return UniqueHandle(pipe);
    }

    const DWORD code = GetLastError();
    const DWORD remaining = RemainingTimeout(deadline);
    if (remaining == 0) {
      if (error != nullptr) {
        *error = L"timed out connecting to " + pipe_name;
      }
      return {};
    }
    if (code == ERROR_PIPE_BUSY) {
      if (!WaitNamedPipeW(pipe_name.c_str(), remaining) &&
          GetLastError() != ERROR_SEM_TIMEOUT) {
        if (error != nullptr) {
          *error = L"WaitNamedPipe failed: " +
                   FormatWindowsError(GetLastError());
        }
        return {};
      }
      continue;
    }
    if (code == ERROR_FILE_NOT_FOUND) {
      Sleep((std::min)(remaining, 25UL));
      continue;
    }
    if (error != nullptr) {
      *error = L"CreateFile(pipe) failed: " + FormatWindowsError(code);
    }
    return {};
  }
}

bool ReadTokenUser(HANDLE token,
                   std::vector<std::byte>* storage,
                   TOKEN_USER** token_user,
                   std::wstring* error) {
  DWORD required = 0;
  GetTokenInformation(token, TokenUser, nullptr, 0, &required);
  if (required == 0 || GetLastError() != ERROR_INSUFFICIENT_BUFFER) {
    if (error != nullptr) {
      *error = L"GetTokenInformation(server size) failed: " +
               FormatWindowsError(GetLastError());
    }
    return false;
  }
  storage->resize(required);
  if (!GetTokenInformation(token, TokenUser, storage->data(), required,
                           &required)) {
    if (error != nullptr) {
      *error = L"GetTokenInformation(server user) failed: " +
               FormatWindowsError(GetLastError());
    }
    return false;
  }
  *token_user = reinterpret_cast<TOKEN_USER*>(storage->data());
  return true;
}

bool VerifyPipeServerIdentity(HANDLE pipe,
                              const UserSecurityContext& security,
                              DWORD* server_process_id,
                              std::wstring* error) {
  if (server_process_id == nullptr) {
    return false;
  }
  ULONG process_id = 0;
  if (!GetNamedPipeServerProcessId(pipe, &process_id) || process_id == 0) {
    if (error != nullptr) {
      *error = L"GetNamedPipeServerProcessId failed: " +
               FormatWindowsError(GetLastError());
    }
    return false;
  }

  DWORD session_id = 0;
  if (!ProcessIdToSessionId(process_id, &session_id) ||
      session_id != security.session_id()) {
    if (error != nullptr) {
      *error = L"the pipe server is not in the current logon session";
    }
    return false;
  }

  UniqueHandle process(OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE,
                                   process_id));
  if (!process) {
    if (error != nullptr) {
      *error = L"OpenProcess(server) failed: " +
               FormatWindowsError(GetLastError());
    }
    return false;
  }
  HANDLE raw_token = nullptr;
  if (!OpenProcessToken(process.get(), TOKEN_QUERY, &raw_token)) {
    if (error != nullptr) {
      *error = L"OpenProcessToken(server) failed: " +
               FormatWindowsError(GetLastError());
    }
    return false;
  }
  UniqueHandle token(raw_token);
  std::vector<std::byte> token_storage;
  TOKEN_USER* token_user = nullptr;
  if (!ReadTokenUser(token.get(), &token_storage, &token_user, error) ||
      !IsValidSid(token_user->User.Sid) ||
      !EqualSid(security.sid(), token_user->User.Sid)) {
    if (error != nullptr && error->empty()) {
      *error = L"the pipe server SID does not match the current user";
    }
    return false;
  }

  *server_process_id = process_id;
  return true;
}

core::Frame MakeRequest(core::MessageType type,
                        std::uint32_t request_id,
                        std::vector<std::byte> payload) {
  core::Frame frame;
  frame.header.message_type = type;
  frame.header.request_id = request_id;
  frame.payload = std::move(payload);
  return frame;
}

bool Exchange(HANDLE pipe,
              const core::Frame& request,
              core::MessageType expected_type,
              DWORD timeout_millis,
              core::Frame* response) {
  std::wstring io_error;
  if (!WriteFrame(pipe, request, timeout_millis, &io_error) ||
      !ReadFrame(pipe, response, timeout_millis, &io_error)) {
    std::wcerr << L"Broker wire I/O failed: " << io_error << L'\n';
    return false;
  }
  if (response->header.request_id != request.header.request_id) {
    std::cerr << "Broker response request_id mismatch\n";
    return false;
  }
  const std::uint32_t response_flag =
      static_cast<std::uint32_t>(core::FrameFlags::kResponse);
  const std::uint32_t error_flag =
      static_cast<std::uint32_t>(core::FrameFlags::kError);
  if ((response->header.flags & error_flag) != 0) {
    core::ErrorResponse broker_error;
    std::string decode_error;
    if (core::DecodeErrorResponse(response->payload, &broker_error,
                                  &decode_error)) {
      std::cerr << "Broker error " << static_cast<std::uint32_t>(broker_error.code)
                << ": " << broker_error.message << '\n';
    } else {
      std::cerr << "Broker returned an undecodable error: " << decode_error
                << '\n';
    }
    return false;
  }
  if (response->header.flags != response_flag ||
      response->header.message_type != expected_type) {
    std::cerr << "Broker response type or flags did not match the request\n";
    return false;
  }
  return true;
}

bool EncodeOrReport(bool encoded, std::string_view operation,
                    const std::string& error) {
  if (!encoded) {
    std::cerr << "Could not encode " << operation;
    if (!error.empty()) {
      std::cerr << ": " << error;
    }
    std::cerr << '\n';
  }
  return encoded;
}

bool ValidateInputState(const core::InputState& state,
                        std::uint64_t session_id,
                        std::uint64_t sequence_id,
                        std::uint64_t* revision,
                        bool* observed_handled,
                        bool* observed_semantic_state,
                        std::size_t* maximum_candidates) {
  if (state.session_id != session_id || state.sequence_id != sequence_id) {
    std::cerr << "InputState session_id or sequence_id mismatch\n";
    return false;
  }
  const bool handled =
      (state.state_flags &
       static_cast<std::uint32_t>(core::InputStateFlags::kHandled)) != 0;
  const std::uint64_t expected_revision = *revision + (handled ? 1U : 0U);
  if (state.revision != expected_revision) {
    std::cerr << "InputState revision did not match handled semantics\n";
    return false;
  }
  *revision = state.revision;
  *observed_handled = *observed_handled || handled;
  *observed_semantic_state =
      *observed_semantic_state || !state.composition.empty() ||
      !state.candidates.empty();
  *maximum_candidates =
      (std::max)(*maximum_candidates, state.candidates.size());
  return true;
}

int Run(const Options& options) {
  UserSecurityContext security;
  std::wstring security_error;
  if (!security.Initialize(&security_error)) {
    std::wcerr << L"Could not derive the current user's Broker endpoint: "
               << security_error << L'\n';
    return EXIT_FAILURE;
  }

  std::wstring connect_error;
  UniqueHandle pipe =
      Connect(security.pipe_name(), options.timeout_millis, &connect_error);
  if (!pipe) {
    std::wcerr << L"Could not connect to the RIMES Broker: " << connect_error
               << L'\n';
    return EXIT_FAILURE;
  }
  DWORD verified_server_process_id = 0;
  std::wstring server_identity_error;
  if (!VerifyPipeServerIdentity(pipe.get(), security,
                                &verified_server_process_id,
                                &server_identity_error)) {
    std::wcerr << L"Broker server identity verification failed: "
               << server_identity_error << L'\n';
    return EXIT_FAILURE;
  }

  std::uint32_t request_id = 1;
  core::ClientHello hello;
  hello.process_id = GetCurrentProcessId();
  hello.session_id = security.session_id();
  hello.client_name = "RimesBrokerWireSmoke";
  std::vector<std::byte> payload;
  std::string codec_error;
  if (!EncodeOrReport(core::EncodeClientHello(hello, &payload, &codec_error),
                      "ClientHello", codec_error)) {
    return EXIT_FAILURE;
  }
  core::Frame response;
  if (!Exchange(pipe.get(),
                MakeRequest(core::MessageType::kClientHello, request_id++,
                            std::move(payload)),
                core::MessageType::kBrokerHello, options.timeout_millis,
                &response)) {
    return EXIT_FAILURE;
  }
  core::BrokerHello broker_hello;
  if (!core::DecodeBrokerHello(response.payload, &broker_hello, &codec_error) ||
      broker_hello.process_id != verified_server_process_id ||
      broker_hello.session_id != security.session_id()) {
    std::cerr << "BrokerHello identity validation failed\n";
    return EXIT_FAILURE;
  }

  core::OpenInputSession open;
  open.context_id = GetTickCount64();
  if (open.context_id == 0) {
    open.context_id = 1;
  }
  payload.clear();
  codec_error.clear();
  if (!EncodeOrReport(
          core::EncodeOpenInputSession(open, &payload, &codec_error),
          "OpenInputSession", codec_error) ||
      !Exchange(pipe.get(),
                MakeRequest(core::MessageType::kOpenInputSession,
                            request_id++, std::move(payload)),
                core::MessageType::kInputSessionOpened,
                options.timeout_millis, &response)) {
    return EXIT_FAILURE;
  }
  core::InputSessionOpened opened;
  if (!core::DecodeInputSessionOpened(response.payload, &opened,
                                      &codec_error) ||
      opened.session_id == 0) {
    std::cerr << "InputSessionOpened validation failed\n";
    return EXIT_FAILURE;
  }

  std::uint64_t sequence_id = 0;
  std::uint64_t revision = 0;
  bool observed_handled = false;
  bool observed_semantic_state = false;
  std::size_t maximum_candidates = 0;
  const auto send_key = [&](std::uint32_t virtual_key, bool key_down,
                            core::InputState* state) -> bool {
    core::KeyEvent key;
    key.session_id = opened.session_id;
    key.sequence_id = ++sequence_id;
    key.timestamp_millis = GetTickCount64();
    key.virtual_key = virtual_key;
    key.scan_code = MapVirtualKeyW(virtual_key, MAPVK_VK_TO_VSC) & 0xffffU;
    key.repeat_count = 1;
    if (key_down) {
      key.event_flags =
          static_cast<std::uint32_t>(core::KeyEventFlags::kKeyDown);
    }

    payload.clear();
    codec_error.clear();
    if (!EncodeOrReport(core::EncodeKeyEvent(key, &payload, &codec_error),
                        "KeyEvent", codec_error) ||
        !Exchange(pipe.get(),
                  MakeRequest(core::MessageType::kKeyEvent, request_id++,
                              std::move(payload)),
                  core::MessageType::kInputState, options.timeout_millis,
                  &response)) {
      return false;
    }
    if (!core::DecodeInputState(response.payload, state, &codec_error) ||
        !ValidateInputState(*state, opened.session_id, sequence_id, &revision,
                            &observed_handled, &observed_semantic_state,
                            &maximum_candidates)) {
      if (!codec_error.empty()) {
        std::cerr << "InputState decode failed: " << codec_error << '\n';
      }
      return false;
    }
    return true;
  };

  constexpr std::array<std::uint32_t, 4> keys = {'R', 'I', 'M', 'E'};
  for (const std::uint32_t virtual_key : keys) {
    for (const bool key_down : {true, false}) {
      core::InputState state;
      if (!send_key(virtual_key, key_down, &state)) {
        return EXIT_FAILURE;
      }
    }
  }

  core::InputState selection_down;
  if (!send_key(VK_SPACE, true, &selection_down)) {
    return EXIT_FAILURE;
  }
  const bool selection_down_handled =
      (selection_down.state_flags &
       static_cast<std::uint32_t>(core::InputStateFlags::kHandled)) != 0;
  const bool selection_down_composing =
      (selection_down.state_flags &
       static_cast<std::uint32_t>(core::InputStateFlags::kComposing)) != 0;
  if (!selection_down_handled) {
    std::cerr << "Selection key-down was not handled\n";
    return EXIT_FAILURE;
  }
  if (selection_down.commit_text.empty()) {
    std::cerr << "Selection key-down did not produce committed text\n";
    return EXIT_FAILURE;
  }
  if (selection_down_composing || !selection_down.composition.empty()) {
    std::cerr << "Composition remained active after selection\n";
    return EXIT_FAILURE;
  }

  core::InputState selection_up;
  if (!send_key(VK_SPACE, false, &selection_up)) {
    return EXIT_FAILURE;
  }
  const bool selection_up_handled =
      (selection_up.state_flags &
       static_cast<std::uint32_t>(core::InputStateFlags::kHandled)) != 0;
  // An unhandled release is expected from librime and is valid only as a
  // no-mutation response. DecodeInputState and ValidateInputState already
  // enforce empty commit/composition data and an unchanged revision here.
  if (!selection_up_handled &&
      (!selection_up.commit_text.empty() ||
       !selection_up.composition.empty() || !selection_up.candidates.empty())) {
    std::cerr << "Unhandled selection key-up mutated input state\n";
    return EXIT_FAILURE;
  }

  core::CloseInputSession close{opened.session_id};
  payload.clear();
  codec_error.clear();
  if (!EncodeOrReport(
          core::EncodeCloseInputSession(close, &payload, &codec_error),
          "CloseInputSession", codec_error) ||
      !Exchange(pipe.get(),
                MakeRequest(core::MessageType::kCloseInputSession,
                            request_id++, std::move(payload)),
                core::MessageType::kInputSessionClosed,
                options.timeout_millis, &response)) {
    return EXIT_FAILURE;
  }
  core::InputSessionClosed closed;
  if (!core::DecodeInputSessionClosed(response.payload, &closed,
                                      &codec_error) ||
      closed.session_id != opened.session_id) {
    std::cerr << "InputSessionClosed validation failed\n";
    return EXIT_FAILURE;
  }

  if (!observed_handled) {
    std::cerr << "Rime did not handle any smoke key\n";
    return EXIT_FAILURE;
  }
  if (!observed_semantic_state) {
    std::cerr << "Rime produced neither composition nor candidates\n";
    return EXIT_FAILURE;
  }
  if (maximum_candidates < options.minimum_candidates) {
    std::cerr << "Maximum candidate count " << maximum_candidates
              << " was below the requested minimum "
              << options.minimum_candidates << '\n';
    return EXIT_FAILURE;
  }

  std::cout << "RIMES Broker wire smoke passed; sequence=" << sequence_id
            << ", revision=" << revision
            << ", max_candidates=" << maximum_candidates << '\n';
  return EXIT_SUCCESS;
}

}  // namespace
}  // namespace rimes::windows::broker::wire_smoke

int wmain(int argc, wchar_t** argv) {
  rimes::windows::broker::wire_smoke::Options options;
  std::wstring error;
  if (!rimes::windows::broker::wire_smoke::ParseOptions(argc, argv, &options,
                                                        &error)) {
    std::wcerr << error << L'\n';
    rimes::windows::broker::wire_smoke::PrintUsage();
    return EXIT_FAILURE;
  }
  if (options.show_help) {
    rimes::windows::broker::wire_smoke::PrintUsage();
    return EXIT_SUCCESS;
  }
  return rimes::windows::broker::wire_smoke::Run(options);
}
