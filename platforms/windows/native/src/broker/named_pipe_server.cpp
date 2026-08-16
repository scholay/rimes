#include "named_pipe_server.hpp"

#include "win32_security.hpp"

#include <algorithm>
#include <atomic>
#include <array>
#include <chrono>
#include <cstddef>
#include <cstring>
#include <limits>
#include <memory>
#include <mutex>
#include <span>
#include <stop_token>
#include <thread>
#include <utility>
#include <vector>

namespace rimes::windows::broker {
namespace {

#ifndef PIPE_REJECT_REMOTE_CLIENTS
#define PIPE_REJECT_REMOTE_CLIENTS 0x00000008
#endif

class PipeCloser {
 public:
  void operator()(void* handle) const {
    if (handle != nullptr && handle != INVALID_HANDLE_VALUE) {
      CloseHandle(handle);
    }
  }
};

using UniquePipe = std::unique_ptr<void, PipeCloser>;

inline constexpr DWORD kConnectPollMilliseconds = 250;
inline constexpr DWORD kFrameIoTimeoutMilliseconds = 15'000;
inline constexpr std::size_t kMaxConcurrentClients = 64;

enum class IoResult {
  kOk,
  kDisconnected,
  kTimedOut,
  kError,
};

IoResult CompleteOverlappedIo(HANDLE pipe,
                              OVERLAPPED* overlapped,
                              std::stop_token stop_token,
                              DWORD timeout_milliseconds,
                              DWORD* transferred,
                              std::wstring* error) {
  const auto deadline = std::chrono::steady_clock::now() +
                        std::chrono::milliseconds(timeout_milliseconds);
  for (;;) {
    if (stop_token.stop_requested()) {
      CancelIoEx(pipe, overlapped);
      GetOverlappedResult(pipe, overlapped, transferred, TRUE);
      return IoResult::kDisconnected;
    }

    const auto now = std::chrono::steady_clock::now();
    if (now >= deadline) {
      CancelIoEx(pipe, overlapped);
      GetOverlappedResult(pipe, overlapped, transferred, TRUE);
      if (error != nullptr) {
        *error = L"named-pipe frame I/O timed out";
      }
      return IoResult::kTimedOut;
    }
    const auto remaining = std::chrono::duration_cast<std::chrono::milliseconds>(
        deadline - now);
    const DWORD wait_milliseconds = static_cast<DWORD>(
        (std::min)(remaining.count(),
                   static_cast<decltype(remaining.count())>(
                       kConnectPollMilliseconds)));
    const DWORD wait_result =
        WaitForSingleObject(overlapped->hEvent, (std::max)(1UL, wait_milliseconds));
    if (wait_result == WAIT_TIMEOUT) {
      continue;
    }
    if (wait_result != WAIT_OBJECT_0) {
      const DWORD code = GetLastError();
      CancelIoEx(pipe, overlapped);
      GetOverlappedResult(pipe, overlapped, transferred, TRUE);
      if (error != nullptr) {
        *error = L"WaitForSingleObject(pipe I/O) failed: " +
                 FormatWindowsError(code);
      }
      return IoResult::kError;
    }
    if (GetOverlappedResult(pipe, overlapped, transferred, FALSE)) {
      return IoResult::kOk;
    }
    const DWORD code = GetLastError();
    if (code == ERROR_BROKEN_PIPE || code == ERROR_NO_DATA ||
        code == ERROR_PIPE_NOT_CONNECTED || code == ERROR_OPERATION_ABORTED) {
      return IoResult::kDisconnected;
    }
    if (error != nullptr) {
      *error = L"GetOverlappedResult(pipe I/O) failed: " +
               FormatWindowsError(code);
    }
    return IoResult::kError;
  }
}

IoResult Transfer(HANDLE pipe,
                  void* buffer,
                  DWORD requested,
                  bool write,
                  std::stop_token stop_token,
                  DWORD timeout_milliseconds,
                  DWORD* transferred,
                  std::wstring* error) {
  UniquePipe event(CreateEventW(nullptr, TRUE, FALSE, nullptr));
  if (event.get() == nullptr) {
    if (error != nullptr) {
      *error = L"CreateEvent(pipe I/O) failed: " +
               FormatWindowsError(GetLastError());
    }
    return IoResult::kError;
  }
  OVERLAPPED overlapped{};
  overlapped.hEvent = event.get();
  *transferred = 0;
  const BOOL started =
      write ? WriteFile(pipe, buffer, requested, transferred, &overlapped)
            : ReadFile(pipe, buffer, requested, transferred, &overlapped);
  if (started) {
    return IoResult::kOk;
  }
  const DWORD code = GetLastError();
  if (code == ERROR_BROKEN_PIPE || code == ERROR_NO_DATA ||
      code == ERROR_PIPE_NOT_CONNECTED) {
    return IoResult::kDisconnected;
  }
  if (code != ERROR_IO_PENDING) {
    if (error != nullptr) {
      *error = std::wstring(write ? L"WriteFile(pipe) failed: "
                                  : L"ReadFile(pipe) failed: ") +
               FormatWindowsError(code);
    }
    return IoResult::kError;
  }
  return CompleteOverlappedIo(pipe, &overlapped, stop_token,
                              timeout_milliseconds, transferred, error);
}

IoResult ReadExact(HANDLE pipe,
                   std::span<std::byte> destination,
                   std::stop_token stop_token,
                   std::wstring* error) {
  const auto deadline = std::chrono::steady_clock::now() +
                        std::chrono::milliseconds(kFrameIoTimeoutMilliseconds);
  std::size_t offset = 0;
  while (offset < destination.size()) {
    const auto remaining = std::chrono::duration_cast<std::chrono::milliseconds>(
        deadline - std::chrono::steady_clock::now());
    if (remaining.count() <= 0) {
      if (error != nullptr) {
        *error = L"named-pipe frame read timed out";
      }
      return IoResult::kTimedOut;
    }
    const DWORD requested = static_cast<DWORD>(std::min<std::size_t>(
        destination.size() - offset, std::numeric_limits<DWORD>::max()));
    DWORD bytes_read = 0;
    const IoResult transfer =
        Transfer(pipe, destination.data() + offset, requested, false,
                 stop_token, static_cast<DWORD>(remaining.count()),
                 &bytes_read, error);
    if (transfer != IoResult::kOk) {
      return transfer;
    }
    if (bytes_read == 0) {
      return IoResult::kDisconnected;
    }
    offset += bytes_read;
  }
  return IoResult::kOk;
}

IoResult WriteExact(HANDLE pipe,
                    std::span<const std::byte> source,
                    std::stop_token stop_token,
                    std::wstring* error) {
  const auto deadline = std::chrono::steady_clock::now() +
                        std::chrono::milliseconds(kFrameIoTimeoutMilliseconds);
  std::size_t offset = 0;
  while (offset < source.size()) {
    const auto remaining = std::chrono::duration_cast<std::chrono::milliseconds>(
        deadline - std::chrono::steady_clock::now());
    if (remaining.count() <= 0) {
      if (error != nullptr) {
        *error = L"named-pipe frame write timed out";
      }
      return IoResult::kTimedOut;
    }
    const DWORD requested = static_cast<DWORD>(std::min<std::size_t>(
        source.size() - offset, std::numeric_limits<DWORD>::max()));
    DWORD bytes_written = 0;
    const IoResult transfer =
        Transfer(pipe, const_cast<std::byte*>(source.data() + offset),
                 requested, true, stop_token,
                 static_cast<DWORD>(remaining.count()), &bytes_written, error);
    if (transfer != IoResult::kOk) {
      return transfer;
    }
    if (bytes_written == 0) {
      if (error != nullptr) {
        *error = L"WriteFile(pipe) completed without progress";
      }
      return IoResult::kError;
    }
    offset += bytes_written;
  }
  return IoResult::kOk;
}

IoResult ReadFrame(HANDLE pipe,
                   core::Frame* frame,
                   std::stop_token stop_token,
                   std::wstring* error) {
  std::array<std::byte, core::kFrameHeaderSize> header_bytes{};
  const IoResult header_io = ReadExact(pipe, header_bytes, stop_token, error);
  if (header_io != IoResult::kOk) {
    return header_io;
  }

  const core::HeaderDecodeResult header =
      core::DecodeFrameHeader(header_bytes);
  if (header.status != core::DecodeStatus::kComplete) {
    if (error != nullptr) {
      *error = L"invalid broker frame header";
    }
    return IoResult::kError;
  }

  std::vector<std::byte> encoded(core::kFrameHeaderSize +
                                 header.header.payload_size);
  std::memcpy(encoded.data(), header_bytes.data(), header_bytes.size());
  if (header.header.payload_size != 0) {
    const IoResult payload_io = ReadExact(
        pipe,
        std::span<std::byte>(encoded).subspan(core::kFrameHeaderSize),
        stop_token, error);
    if (payload_io != IoResult::kOk) {
      return payload_io;
    }
  }

  core::FrameDecodeResult decoded = core::DecodeFrame(encoded);
  if (decoded.status != core::DecodeStatus::kComplete ||
      decoded.bytes_consumed != encoded.size()) {
    if (error != nullptr) {
      *error = L"invalid broker frame";
    }
    return IoResult::kError;
  }
  *frame = std::move(decoded.frame);
  return IoResult::kOk;
}

IoResult WriteFrame(HANDLE pipe,
                    const core::Frame& frame,
                    std::stop_token stop_token,
                    std::wstring* error) {
  std::vector<std::byte> encoded;
  std::string codec_error;
  if (!core::EncodeFrame(frame, &encoded, &codec_error)) {
    if (error != nullptr) {
      *error = L"refused to encode an invalid broker response";
    }
    return IoResult::kError;
  }
  return WriteExact(pipe, encoded, stop_token, error);
}

ServeResult ServeConnectedClient(UniquePipe pipe,
                                 DWORD client_process_id,
                                 const FrameHandler& handler,
                                 std::stop_token stop_token,
                                 std::wstring* error) {
  for (;;) {
    core::Frame request;
    const IoResult read_result =
        ReadFrame(pipe.get(), &request, stop_token, error);
    if (read_result == IoResult::kDisconnected) {
      DisconnectNamedPipe(pipe.get());
      return ServeResult::kClientDisconnected;
    }
    if (read_result == IoResult::kTimedOut || read_result == IoResult::kError) {
      DisconnectNamedPipe(pipe.get());
      return ServeResult::kClientRejected;
    }

    core::Frame response;
    const ClientAction action = handler(request, client_process_id, &response);
    const IoResult write_result =
        WriteFrame(pipe.get(), response, stop_token, error);
    if (write_result != IoResult::kOk) {
      DisconnectNamedPipe(pipe.get());
      return write_result == IoResult::kDisconnected
                 ? ServeResult::kClientDisconnected
                 : ServeResult::kClientRejected;
    }
    if (action == ClientAction::kCloseAfterResponse) {
      DisconnectNamedPipe(pipe.get());
      return ServeResult::kClientDisconnected;
    }
  }
}

bool ConnectPipe(HANDLE pipe, std::wstring* error) {
  UniquePipe event(CreateEventW(nullptr, TRUE, FALSE, nullptr));
  if (event.get() == nullptr) {
    if (error != nullptr) {
      *error = L"CreateEvent(pipe connect) failed: " +
               FormatWindowsError(GetLastError());
    }
    return false;
  }
  OVERLAPPED overlapped{};
  overlapped.hEvent = event.get();
  if (ConnectNamedPipe(pipe, &overlapped)) {
    return true;
  }
  DWORD code = GetLastError();
  if (code == ERROR_PIPE_CONNECTED) {
    return true;
  }
  if (code != ERROR_IO_PENDING) {
    if (error != nullptr) {
      *error = L"ConnectNamedPipe failed: " + FormatWindowsError(code);
    }
    return false;
  }
  const DWORD wait_result = WaitForSingleObject(event.get(), INFINITE);
  DWORD transferred = 0;
  if (wait_result == WAIT_OBJECT_0 &&
      GetOverlappedResult(pipe, &overlapped, &transferred, FALSE)) {
    return true;
  }
  code = wait_result == WAIT_FAILED ? GetLastError() : GetLastError();
  CancelIoEx(pipe, &overlapped);
  GetOverlappedResult(pipe, &overlapped, &transferred, TRUE);
  if (error != nullptr) {
    *error = L"overlapped ConnectNamedPipe failed: " + FormatWindowsError(code);
  }
  return false;
}

struct ClientWorker {
  std::shared_ptr<std::atomic_bool> complete;
  std::jthread thread;
};

}  // namespace

ServeResult NamedPipeServer::ServeClients(
    const FrameHandlerFactory& handler_factory,
    const bool serve_once,
    std::wstring* error) {
  if (security_ == nullptr || handler_factory == nullptr) {
    if (error != nullptr) {
      *error =
          L"NamedPipeServer is missing its security context or handler factory";
    }
    return ServeResult::kFatalError;
  }

  const DWORD pipe_mode =
      PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT |
      PIPE_REJECT_REMOTE_CLIENTS;
  bool first_instance = true;
  std::vector<ClientWorker> workers;
  for (;;) {
    std::erase_if(workers, [](ClientWorker& worker) {
      if (!worker.complete->load(std::memory_order_acquire)) {
        return false;
      }
      if (worker.thread.joinable()) {
        worker.thread.join();
      }
      return true;
    });

    const DWORD access = PIPE_ACCESS_DUPLEX | FILE_FLAG_OVERLAPPED |
                         (first_instance ? FILE_FLAG_FIRST_PIPE_INSTANCE : 0);
    UniquePipe pipe(CreateNamedPipeW(
        security_->pipe_name().c_str(), access, pipe_mode,
        PIPE_UNLIMITED_INSTANCES, 64U * 1024U, 64U * 1024U, 0,
        security_->attributes()));
    first_instance = false;
    if (pipe.get() == INVALID_HANDLE_VALUE) {
      pipe.release();
      if (error != nullptr) {
        *error = L"CreateNamedPipe failed: " +
                 FormatWindowsError(GetLastError());
      }
      return ServeResult::kFatalError;
    }

    if (!ConnectPipe(pipe.get(), error)) {
      return ServeResult::kFatalError;
    }
    if (!security_->VerifyConnectedPipeClient(pipe.get(), error)) {
      DisconnectNamedPipe(pipe.get());
      if (serve_once) {
        return ServeResult::kClientRejected;
      }
      continue;
    }
    ULONG client_process_id = 0;
    if (!GetNamedPipeClientProcessId(pipe.get(), &client_process_id)) {
      if (error != nullptr) {
        *error = L"GetNamedPipeClientProcessId failed after verification: " +
                 FormatWindowsError(GetLastError());
      }
      DisconnectNamedPipe(pipe.get());
      if (serve_once) {
        return ServeResult::kClientRejected;
      }
      continue;
    }

    FrameHandler handler = handler_factory(client_process_id);
    if (handler == nullptr) {
      if (error != nullptr) {
        *error = L"handler factory rejected the verified pipe client";
      }
      DisconnectNamedPipe(pipe.get());
      if (serve_once) {
        return ServeResult::kClientRejected;
      }
      continue;
    }
    if (serve_once) {
      return ServeConnectedClient(std::move(pipe), client_process_id, handler,
                                  {}, error);
    }

    if (workers.size() >= kMaxConcurrentClients) {
      DisconnectNamedPipe(pipe.get());
      continue;
    }
    auto complete = std::make_shared<std::atomic_bool>(false);
    ClientWorker worker;
    worker.complete = complete;
    worker.thread = std::jthread(
        [pipe = std::move(pipe), client_process_id,
         handler = std::move(handler), complete](std::stop_token stop_token) mutable {
          std::wstring worker_error;
          ServeConnectedClient(std::move(pipe), client_process_id, handler,
                               stop_token, &worker_error);
          complete->store(true, std::memory_order_release);
        });
    workers.push_back(std::move(worker));
  }
}

}  // namespace rimes::windows::broker
