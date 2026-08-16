#pragma once

#include <Windows.h>

#include <cstdint>
#include <memory>
#include <string>

namespace rimes::windows::tsf {

enum class BrokerKeyPhase {
  kTestKeyDown,
  kKeyDown,
  kTestKeyUp,
  kKeyUp,
  kPreservedKey,
};

struct BrokerKeyEvent {
  BrokerKeyPhase phase;
  WPARAM virtual_key;
  LPARAM key_data;
};

enum class BrokerKeyResult {
  kUnavailable,
  kPassThrough,
  kConsumed,
};

// Text mutations returned atomically with one real key-down request.  Wire
// strings are decoded and validated by the pipe client before they reach TSF.
// Candidate presentation intentionally remains outside this first, commit-only
// TSF milestone.
struct BrokerInputState {
  bool composing = false;
  std::uint64_t revision = 0;
  std::uint32_t caret_utf16 = 0;
  std::uint32_t selection_length_utf16 = 0;
  std::wstring composition;
  std::wstring commit_text;
};

// Boundary between the in-process TSF DLL and the future out-of-process
// broker. Implementations must never load librime in this process and must not
// block the application's input thread. Failure or disconnection must return
// kUnavailable so the caller can pass the key through unchanged.
class BrokerClient {
 public:
  virtual ~BrokerClient() = default;

  virtual void BeginConnect() noexcept = 0;
  virtual void Disconnect() noexcept = 0;
  virtual BrokerKeyResult HandleKey(const BrokerKeyEvent& event,
                                    BrokerInputState* state) noexcept = 0;
};

// Creates a client for the per-user, per-logon-session Broker endpoint.  It
// never launches a process: if an already-running Broker cannot be authenticated
// or does not answer within the small I/O budget, keys are passed through.
std::unique_ptr<BrokerClient> CreateBrokerClient() noexcept;

}  // namespace rimes::windows::tsf
