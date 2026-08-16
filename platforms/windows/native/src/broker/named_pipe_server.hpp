#pragma once

#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>

#include <functional>
#include <string>

#include "../core/broker_protocol.hpp"

namespace rimes::windows::broker {

class UserSecurityContext;

enum class ClientAction {
  kContinue,
  kCloseAfterResponse,
};

using FrameHandler = std::function<ClientAction(
    const core::Frame& request,
    DWORD verified_client_process_id,
    core::Frame* response)>;

// A handler owns the protocol/session state for exactly one verified pipe
// connection.  Keeping this as a factory prevents state from being shared
// accidentally when several TSF hosts connect at the same time.
using FrameHandlerFactory =
    std::function<FrameHandler(DWORD verified_client_process_id)>;

enum class ServeResult {
  kClientDisconnected,
  kClientRejected,
  kFatalError,
};

class NamedPipeServer {
 public:
  explicit NamedPipeServer(UserSecurityContext* security)
      : security_(security) {}

  // Accepts verified clients continuously and serves each connection on its
  // own worker.  Pipe I/O is overlapped and bounded, so an idle client or a
  // client that sends only part of a frame cannot stall the accept loop or
  // retain a worker forever.  When serve_once is true, the first verified
  // client is served synchronously and its result is returned.
  ServeResult ServeClients(const FrameHandlerFactory& handler_factory,
                           bool serve_once,
                           std::wstring* error);

 private:
  UserSecurityContext* security_;
};

}  // namespace rimes::windows::broker
