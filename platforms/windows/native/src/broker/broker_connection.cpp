#include "broker_connection.hpp"

#include "key_translation.hpp"

#include <iostream>
#include <limits>
#include <string_view>
#include <utility>

#include "../engine/rime_snapshot.hpp"

namespace rimes::windows::broker {
namespace {

inline constexpr std::string_view kBrokerVersion = "0.2.0-dev";
inline constexpr std::size_t kMaxSessionsPerConnection = 64;

constexpr std::uint32_t Flag(core::KeyEventFlags flag) noexcept {
  return static_cast<std::uint32_t>(flag);
}

constexpr std::uint32_t StateFlag(core::InputStateFlags flag) noexcept {
  return static_cast<std::uint32_t>(flag);
}

constexpr bool HasFlag(std::uint32_t value, std::uint32_t flag) noexcept {
  return (value & flag) != 0;
}

void LogEngineFailure(std::string_view operation,
                      std::uint64_t broker_session_id,
                      std::string_view error) {
  std::clog << "RIMES broker " << operation << " failed for session "
            << broker_session_id;
  if (!error.empty()) {
    std::clog << ": " << error;
  }
  std::clog << '\n';
}

}  // namespace

BrokerConnection::BrokerConnection(DWORD broker_session_id,
                                   engine::RimeEngine* engine) noexcept
    : broker_session_id_(broker_session_id), engine_(engine) {}

BrokerConnection::~BrokerConnection() {
  CloseAllSessions();
}

ClientAction BrokerConnection::Handle(const core::Frame& request,
                                      DWORD verified_client_process_id,
                                      core::Frame* response) {
  if (response == nullptr) {
    return ClientAction::kCloseAfterResponse;
  }
  if (request.header.request_id == 0 || request.header.flags != 0) {
    MakeError(request, core::BrokerErrorCode::kMalformedPayload,
              "requests require a non-zero request_id and zero flags",
              response);
    return ClientAction::kCloseAfterResponse;
  }
  if (!hello_received_) {
    if (request.header.message_type != core::MessageType::kClientHello) {
      MakeError(request, core::BrokerErrorCode::kUnauthorizedClient,
                "ClientHello must be the first frame", response);
      return ClientAction::kCloseAfterResponse;
    }
    return HandleHello(request, verified_client_process_id, response);
  }

  switch (request.header.message_type) {
    case core::MessageType::kPing:
      if (!request.payload.empty()) {
        MakeError(request, core::BrokerErrorCode::kMalformedPayload,
                  "Ping payload must be empty", response);
        return ClientAction::kCloseAfterResponse;
      }
      MakeResponse(request, core::MessageType::kPong, {}, response);
      return ClientAction::kContinue;

    case core::MessageType::kOpenInputSession:
      return HandleOpenSession(request, response);

    case core::MessageType::kCloseInputSession:
      return HandleCloseSession(request, response);

    case core::MessageType::kKeyEvent:
      return HandleKeyEvent(request, response);

    case core::MessageType::kClientHello:
      MakeError(request, core::BrokerErrorCode::kMalformedPayload,
                "ClientHello may only be sent once", response);
      return ClientAction::kCloseAfterResponse;

    default:
      MakeError(request, core::BrokerErrorCode::kUnsupportedMessage,
                "message type is not a broker request", response);
      return ClientAction::kCloseAfterResponse;
  }
}

ClientAction BrokerConnection::HandleHello(
    const core::Frame& request,
    DWORD verified_client_process_id,
    core::Frame* response) {
  core::ClientHello hello;
  std::string error;
  if (!core::DecodeClientHello(request.payload, &hello, &error) ||
      hello.process_id != verified_client_process_id ||
      hello.session_id != broker_session_id_ || hello.client_name.empty()) {
    MakeError(request, core::BrokerErrorCode::kUnauthorizedClient,
              "ClientHello identity does not match the verified pipe client",
              response);
    return ClientAction::kCloseAfterResponse;
  }

  core::BrokerHello broker_hello;
  broker_hello.process_id = GetCurrentProcessId();
  broker_hello.session_id = broker_session_id_;
  broker_hello.capabilities = 0;
  broker_hello.broker_version = std::string(kBrokerVersion);
  std::vector<std::byte> payload;
  if (!core::EncodeBrokerHello(broker_hello, &payload)) {
    MakeError(request, core::BrokerErrorCode::kInternalError,
              "failed to encode BrokerHello", response);
    return ClientAction::kCloseAfterResponse;
  }
  hello_received_ = true;
  MakeResponse(request, core::MessageType::kBrokerHello, std::move(payload),
               response);
  return ClientAction::kContinue;
}

ClientAction BrokerConnection::HandleOpenSession(const core::Frame& request,
                                                 core::Frame* response) {
  core::OpenInputSession open;
  if (!core::DecodeOpenInputSession(request.payload, &open)) {
    MakeError(request, core::BrokerErrorCode::kMalformedPayload,
              "invalid OpenInputSession payload", response);
    return ClientAction::kCloseAfterResponse;
  }
  if (sessions_.size() >= kMaxSessionsPerConnection) {
    MakeError(request, core::BrokerErrorCode::kMalformedPayload,
              "input session limit reached", response);
    return ClientAction::kContinue;
  }
  if (!open.schema_id.empty()) {
    MakeError(request, core::BrokerErrorCode::kUnsupportedMessage,
              "explicit schema selection is not available at this engine boundary",
              response);
    return ClientAction::kContinue;
  }
  if (engine_ == nullptr || !engine_->IsHealthy()) {
    MakeError(request, core::BrokerErrorCode::kInternalError,
              "Rime engine is unavailable", response);
    return ClientAction::kContinue;
  }

  std::string engine_error;
  const engine::RimeEngine::SessionId engine_session =
      engine_->CreateSession(&engine_error);
  if (engine_session == 0) {
    LogEngineFailure("CreateSession", 0, engine_error);
    MakeError(request, core::BrokerErrorCode::kInternalError,
              "failed to create the Rime input session", response);
    return ClientAction::kContinue;
  }

  const std::uint64_t session_id = AllocateSessionId();
  if (session_id == 0) {
    engine_->DestroySession(engine_session, nullptr);
    MakeError(request, core::BrokerErrorCode::kInternalError,
              "could not allocate a broker input session identifier",
              response);
    return ClientAction::kContinue;
  }

  try {
    SessionState state;
    state.context_id = open.context_id;
    state.engine_session_id = engine_session;
    state.schema_id = open.schema_id;
    sessions_.emplace(session_id, std::move(state));
  } catch (...) {
    engine_->DestroySession(engine_session, nullptr);
    MakeError(request, core::BrokerErrorCode::kInternalError,
              "could not retain the new input session", response);
    return ClientAction::kCloseAfterResponse;
  }

  core::InputSessionOpened opened;
  opened.session_id = session_id;
  // RimeEngine does not yet expose schema selection/query APIs. Empty is an
  // honest "engine default" response; never echo an unverified requested ID.
  opened.active_schema_id.clear();
  std::vector<std::byte> payload;
  if (!core::EncodeInputSessionOpened(opened, &payload)) {
    const auto session = sessions_.find(session_id);
    if (session != sessions_.end()) {
      engine_->DestroySession(session->second.engine_session_id, nullptr);
      sessions_.erase(session);
    }
    MakeError(request, core::BrokerErrorCode::kInternalError,
              "failed to encode InputSessionOpened", response);
    return ClientAction::kCloseAfterResponse;
  }
  MakeResponse(request, core::MessageType::kInputSessionOpened,
               std::move(payload), response);
  return ClientAction::kContinue;
}

ClientAction BrokerConnection::HandleCloseSession(const core::Frame& request,
                                                  core::Frame* response) {
  core::CloseInputSession close;
  if (!core::DecodeCloseInputSession(request.payload, &close)) {
    MakeError(request, core::BrokerErrorCode::kMalformedPayload,
              "invalid CloseInputSession payload", response);
    return ClientAction::kCloseAfterResponse;
  }
  const auto session = sessions_.find(close.session_id);
  if (session == sessions_.end()) {
    MakeError(request, core::BrokerErrorCode::kMalformedPayload,
              "unknown input session", response);
    return ClientAction::kContinue;
  }

  const engine::RimeEngine::SessionId engine_session =
      session->second.engine_session_id;
  sessions_.erase(session);
  std::string engine_error;
  if (engine_ == nullptr ||
      !engine_->DestroySession(engine_session, &engine_error)) {
    LogEngineFailure("DestroySession", close.session_id, engine_error);
    MakeError(request, core::BrokerErrorCode::kInternalError,
              "failed to destroy the Rime input session", response);
    return ClientAction::kContinue;
  }

  core::InputSessionClosed closed{close.session_id};
  std::vector<std::byte> payload;
  if (!core::EncodeInputSessionClosed(closed, &payload)) {
    MakeError(request, core::BrokerErrorCode::kInternalError,
              "failed to encode InputSessionClosed", response);
    return ClientAction::kCloseAfterResponse;
  }
  MakeResponse(request, core::MessageType::kInputSessionClosed,
               std::move(payload), response);
  return ClientAction::kContinue;
}

ClientAction BrokerConnection::HandleKeyEvent(const core::Frame& request,
                                              core::Frame* response) {
  core::KeyEvent key;
  if (!core::DecodeKeyEvent(request.payload, &key)) {
    MakeError(request, core::BrokerErrorCode::kMalformedPayload,
              "invalid KeyEvent payload", response);
    return ClientAction::kCloseAfterResponse;
  }
  const auto session_iterator = sessions_.find(key.session_id);
  if (session_iterator == sessions_.end()) {
    MakeError(request, core::BrokerErrorCode::kMalformedPayload,
              "KeyEvent references an unknown input session", response);
    return ClientAction::kContinue;
  }
  SessionState& session = session_iterator->second;
  if (key.sequence_id <= session.last_sequence_id) {
    MakeError(request, core::BrokerErrorCode::kMalformedPayload,
              "KeyEvent sequence_id is stale or duplicated", response);
    return ClientAction::kCloseAfterResponse;
  }
  session.last_sequence_id = key.sequence_id;

  const bool key_down =
      HasFlag(key.event_flags, Flag(core::KeyEventFlags::kKeyDown));
  const bool test_only =
      HasFlag(key.event_flags, Flag(core::KeyEventFlags::kTestOnly));
  const bool preserved =
      HasFlag(key.event_flags, Flag(core::KeyEventFlags::kPreservedKey));

  if (test_only) {
    core::InputState state;
    state.session_id = key.session_id;
    state.sequence_id = key.sequence_id;
    state.revision = session.revision;
    const bool likely_handled =
        key_down ? IsLikelyHandledForTest(key, session.composing)
                 : session.handled_key_downs.test(key.virtual_key);
    if (likely_handled) {
      state.state_flags = StateFlag(core::InputStateFlags::kHandled);
    }
    return RespondWithInputState(request, std::move(state), response);
  }

  if (preserved) {
    if (!key_down) {
      session.handled_key_downs.reset(key.virtual_key);
    }
    return RespondPassThrough(request, key, session, response);
  }
  const std::optional<RimeKeyEvent> translated = TranslateWindowsKey(key);
  if (!translated.has_value() || engine_ == nullptr || !engine_->IsHealthy()) {
    if (!key_down) {
      session.handled_key_downs.reset(key.virtual_key);
    }
    return RespondPassThrough(request, key, session, response);
  }
  // Refuse the event before touching librime if the wire revision cannot be
  // advanced. Checking after process_key would violate fail-open by mutating
  // an engine state that TSF can no longer identify.
  if (session.revision == std::numeric_limits<std::uint64_t>::max()) {
    LogEngineFailure("revision overflow", key.session_id, {});
    return RespondPassThrough(request, key, session, response);
  }

  engine::EngineSnapshot snapshot;
  std::string engine_error;
  if (!engine_->ProcessKey(session.engine_session_id, translated->keycode,
                           translated->modifiers, &snapshot, &engine_error)) {
    LogEngineFailure("ProcessKey", key.session_id, engine_error);
    if (!key_down) {
      session.handled_key_downs.reset(key.virtual_key);
    }
    return RespondPassThrough(request, key, session, response);
  }

  std::uint64_t next_revision = session.revision;
  if (snapshot.handled) {
    ++next_revision;
  }

  core::InputState state;
  std::string mapping_error;
  if (!engine::MapSnapshotToInputState(key.session_id, key.sequence_id,
                                       next_revision, snapshot, &state,
                                       &mapping_error)) {
    LogEngineFailure("MapSnapshotToInputState", key.session_id,
                     mapping_error);
    return RespondPassThrough(request, key, session, response);
  }

  session.revision = next_revision;
  session.composing = snapshot.composing;
  if (key_down && snapshot.handled) {
    session.handled_key_downs.set(key.virtual_key);
  } else if (!key_down) {
    session.handled_key_downs.reset(key.virtual_key);
  }
  return RespondWithInputState(request, std::move(state), response);
}

ClientAction BrokerConnection::RespondWithInputState(
    const core::Frame& request,
    core::InputState state,
    core::Frame* response) {
  std::vector<std::byte> payload;
  if (!core::EncodeInputState(state, &payload)) {
    MakeError(request, core::BrokerErrorCode::kInternalError,
              "failed to encode InputState", response);
    return ClientAction::kCloseAfterResponse;
  }
  MakeResponse(request, core::MessageType::kInputState, std::move(payload),
               response);
  return ClientAction::kContinue;
}

ClientAction BrokerConnection::RespondPassThrough(
    const core::Frame& request,
    const core::KeyEvent& key,
    const SessionState& session,
    core::Frame* response) {
  core::InputState state;
  state.session_id = key.session_id;
  state.sequence_id = key.sequence_id;
  state.revision = session.revision;
  return RespondWithInputState(request, std::move(state), response);
}

std::uint64_t BrokerConnection::AllocateSessionId() noexcept {
  for (std::size_t attempt = 0; attempt <= kMaxSessionsPerConnection;
       ++attempt) {
    const std::uint64_t candidate = next_session_id_;
    if (next_session_id_ == std::numeric_limits<std::uint64_t>::max()) {
      next_session_id_ = 1;
    } else {
      ++next_session_id_;
    }
    if (candidate != 0 && !sessions_.contains(candidate)) {
      return candidate;
    }
  }
  return 0;
}

void BrokerConnection::CloseAllSessions() noexcept {
  if (engine_ != nullptr) {
    for (const auto& [broker_session_id, session] : sessions_) {
      std::string error;
      if (!engine_->DestroySession(session.engine_session_id, &error)) {
        LogEngineFailure("DestroySession during disconnect", broker_session_id,
                         error);
      }
    }
  }
  sessions_.clear();
}

void BrokerConnection::MakeResponse(const core::Frame& request,
                                    core::MessageType type,
                                    std::vector<std::byte> payload,
                                    core::Frame* response) {
  response->header.message_type = type;
  response->header.flags =
      static_cast<std::uint32_t>(core::FrameFlags::kResponse);
  response->header.request_id = request.header.request_id;
  response->payload = std::move(payload);
}

void BrokerConnection::MakeError(const core::Frame& request,
                                 core::BrokerErrorCode code,
                                 std::string message,
                                 core::Frame* response) {
  core::ErrorResponse error_dto{code, std::move(message)};
  std::vector<std::byte> payload;
  core::EncodeErrorResponse(error_dto, &payload);
  MakeResponse(request, core::MessageType::kError, std::move(payload),
               response);
  response->header.flags |=
      static_cast<std::uint32_t>(core::FrameFlags::kError);
}

}  // namespace rimes::windows::broker
