#include "BrokerClient.h"
#include "key_routing.hpp"

#include <Windows.h>

#include <cstdlib>
#include <iostream>
#include <string_view>

// Deterministic console contract checks for BrokerClient while disconnected.
// Does not launch or wait on a Broker: unavailable keys must fail open
// immediately, must not be marked consumed, and must not invent a snapshot
// that could be applied later as delayed replay.

namespace {

int g_failures = 0;

void Fail(std::string_view message) {
  std::cerr << "FAIL: " << message << '\n';
  ++g_failures;
}

void Expect(bool condition, std::string_view message) {
  if (!condition) {
    Fail(message);
  }
}

using rimes::windows::tsf::BrokerClient;
using rimes::windows::tsf::BrokerInputState;
using rimes::windows::tsf::BrokerKeyEvent;
using rimes::windows::tsf::BrokerKeyPhase;
using rimes::windows::tsf::BrokerKeyResult;
using rimes::windows::tsf::CreateBrokerClient;

void ExpectUnavailable(BrokerClient* client, BrokerKeyPhase phase,
                       WPARAM virtual_key, LPARAM key_data,
                       std::string_view label) {
  BrokerInputState state;
  state.has_snapshot = true;  // poison; Unavailable must clear/replace
  state.composing = true;
  state.composition = L"stale";
  state.commit_text = L"stale_commit";
  const BrokerKeyResult result =
      client->HandleKey({phase, virtual_key, key_data}, &state);
  Expect(result == BrokerKeyResult::kUnavailable, label);
  Expect(!state.has_snapshot,
         "unavailable must not leave a snapshot for later apply/replay");
  Expect(!state.composing,
         "unavailable must not retain a stale composing flag");
  Expect(state.composition.empty(),
         "unavailable must not retain composition text");
  Expect(state.commit_text.empty(),
         "unavailable must not retain commit text");
}

int RunContractTests() {
  using rimes::windows::tsf::detail::RoutePrintableKey;
  const auto shift = static_cast<std::uint32_t>(
      rimes::windows::core::KeyModifiers::kShift);
  for (const auto key : {'0', '1', '2', '3', '4', '5', '6', '7', '8', '9'}) {
    Expect(!RoutePrintableKey(key, 0, false, false, false),
           "idle number row is never claimed before engine pass-through");
    Expect(RoutePrintableKey(key, shift, false, false, false),
           "Shift+digit retains schema punctuation");
    Expect(RoutePrintableKey(key, 0, true, false, false),
           "number selection during composition remains an IME key");
    Expect(RoutePrintableKey(key, 0, false, true, true),
           "Buffer still captures idle ASCII numbers");
  }
  for (WPARAM key = VK_NUMPAD0; key <= VK_DIVIDE; ++key) {
    for (const auto modifiers : {std::uint32_t{0}, shift}) {
      Expect(!RoutePrintableKey(key, modifiers, false, false, false),
             "idle keypad digits, decimal and operators stay with the native editor, including Shift");
      Expect(RoutePrintableKey(key, modifiers, true, false, false),
             "keypad commands during composition remain an IME key");
      Expect(RoutePrintableKey(key, modifiers, false, true, true),
             "Buffer still captures keypad input in ASCII mode");
    }
  }
  for (const WPARAM key : std::vector<WPARAM>{'A', 'Z', VK_SPACE, VK_OEM_2}) {
    Expect(!RoutePrintableKey(key, 0, false, false, true),
           "authoritative ASCII mode does not claim host printable keys");
    Expect(RoutePrintableKey(key, 0, false, true, true),
           "Buffer retains ASCII letters and punctuation");
  }
  Expect(RoutePrintableKey('N', 0, false, false, false),
         "Chinese letters still start a composition");
  auto client = CreateBrokerClient();
  Expect(client != nullptr, "CreateBrokerClient returns a client");
  if (!client) {
    return EXIT_FAILURE;
  }

  Expect(!client->IsConnected(), "fresh client is disconnected");

  ExpectUnavailable(client.get(), BrokerKeyPhase::kTestKeyDown, 'N', 0,
                    "disconnected TestKeyDown is unavailable (fail-open)");
  ExpectUnavailable(client.get(), BrokerKeyPhase::kKeyDown, 'N', 1,
                    "disconnected KeyDown is unavailable (fail-open)");
  ExpectUnavailable(client.get(), BrokerKeyPhase::kTestKeyDown, 'I', 0,
                    "second disconnected letter is also unavailable");
  ExpectUnavailable(client.get(), BrokerKeyPhase::kKeyDown, 'I', 1,
                    "second disconnected KeyDown is unavailable");

  // Matching releases while never connected must not be consumed either:
  // nothing was processed, so the host keeps the key.
  BrokerInputState up_state;
  Expect(client->HandleKey({BrokerKeyPhase::kKeyUp, 'N', 0}, &up_state) ==
             BrokerKeyResult::kPassThrough,
         "KeyUp with no prior consumed KeyDown passes through");
  Expect(!up_state.has_snapshot, "unhandled KeyUp has no snapshot");

  Expect(client->HandleKey({BrokerKeyPhase::kTestKeyUp, 'N', 0}, nullptr) ==
             BrokerKeyResult::kUnavailable,
         "disconnected TestKeyUp is unavailable");

  // Never BeginConnect here: CTest must not launch Session Broker or wait.
  client->Disconnect();
  Expect(!client->IsConnected(), "Disconnect leaves the client disconnected");
  ExpectUnavailable(client.get(), BrokerKeyPhase::kKeyDown, 'A', 1,
                    "after Disconnect, keys remain unavailable");

  if (g_failures != 0) {
    std::cerr << g_failures << " broker-client contract failure(s)\n";
    return EXIT_FAILURE;
  }
  std::cerr << "broker-client unavailable/fail-open contract ok\n";
  return EXIT_SUCCESS;
}

}  // namespace

int wmain() { return RunContractTests(); }
