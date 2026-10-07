#include <Windows.h>

#include <cstdlib>
#include <iostream>
#include <string>
#include <string_view>
#include <vector>

#include "CandidateWindow.h"
#include "ModuleState.h"
#include "TextService.h"
#include "fake_tsf.hpp"

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

}  // namespace
#include "focus_tests.hpp"
namespace {

void DumpDocument(std::string_view label,
                  const rimes::windows::e2e::FakeDocument& document) {
  rimes::windows::tsf::CandidateSnapshot snapshot;
  rimes::windows::tsf::CandidateWindow::GetLastSnapshot(&snapshot);
  std::cerr << label << ": composing=" << document.composing
            << " preedit_units=" << document.composition.size()
            << " text_units=" << document.text.size()
            << " candidates=" << snapshot.items.size()
            << " visible=" << snapshot.visible << '\n';
}

void ClearCapsLockIfLatched() {
  if ((GetKeyState(VK_CAPITAL) & 1) == 0) {
    return;
  }
  keybd_event(VK_CAPITAL, 0x45, KEYEVENTF_EXTENDEDKEY, 0);
  keybd_event(VK_CAPITAL, 0x45, KEYEVENTF_EXTENDEDKEY | KEYEVENTF_KEYUP, 0);
}

void TypeVirtualKey(rimes::windows::tsf::TextService* service,
                    ITfContext* context, WPARAM virtual_key, bool require_eaten,
                    rimes::windows::e2e::FakeDocument* document = nullptr,
                    bool dump_after_key_down = false) {
  using rimes::windows::tsf::TextService;
  BOOL eaten = FALSE;
  service->OnTestKeyDown(context, virtual_key, 0, &eaten);
  eaten = FALSE;
  const HRESULT down = service->OnKeyDown(context, virtual_key, 0, &eaten);
  if (FAILED(down)) {
    Fail("OnKeyDown failed");
    return;
  }
  if (require_eaten && eaten == FALSE) {
    Fail("expected key down to be consumed: vk=" + std::to_string(virtual_key));
  }
  if (dump_after_key_down && document != nullptr) {
    DumpDocument("after keydown vk=" + std::to_string(virtual_key), *document);
  }
  eaten = FALSE;
  service->OnTestKeyUp(context, virtual_key, 0, &eaten);
  eaten = FALSE;
  service->OnKeyUp(context, virtual_key, 0, &eaten);
}

void TypeLatin(rimes::windows::tsf::TextService* service, ITfContext* context,
               std::string_view letters,
               rimes::windows::e2e::FakeDocument* document = nullptr) {
  bool first = true;
  for (const char letter : letters) {
    const WPARAM virtual_key =
        static_cast<WPARAM>(static_cast<unsigned char>(letter) & ~0x20U);
    TypeVirtualKey(service, context, virtual_key, true, document, first);
    first = false;
  }
}

bool WaitForBroker(rimes::windows::tsf::TextService* service,
                   DWORD timeout_millis) {
  const DWORD started = GetTickCount();
  while (GetTickCount() - started < timeout_millis) {
    if (service->IsBrokerConnected()) {
      return true;
    }
    Sleep(50);
  }
  return service->IsBrokerConnected();
}

std::vector<std::wstring> CandidateTexts() {
  rimes::windows::tsf::CandidateSnapshot snapshot;
  rimes::windows::tsf::CandidateWindow::GetLastSnapshot(&snapshot);
  std::vector<std::wstring> texts;
  texts.reserve(snapshot.items.size());
  for (const auto& item : snapshot.items) {
    texts.push_back(item.text);
  }
  return texts;
}

bool ContainsText(const std::vector<std::wstring>& texts,
                  std::wstring_view expected) {
  for (const std::wstring& text : texts) {
    if (text == expected) {
      return true;
    }
  }
  return false;
}

void ResetDocument(rimes::windows::e2e::FakeDocument* document) {
  *document = rimes::windows::e2e::FakeDocument{};
}

// SetContext has a bounded wait while the connection/control worker
// owns its mutex. Transport readiness alone does not mean a focus binding has
// completed. Wait for that setup boundary before sending test keys; never
// retry or replay an input event.
bool WaitForContext(rimes::windows::tsf::BrokerClient* client,
                    std::uint64_t context) {
  const auto started = GetTickCount64();
  while (GetTickCount64() - started < 2000) {
    if (client->IsConnected() && client->SetContext(context)) return true;
    Sleep(10);
  }
  return false;
}

// Documents the intentional cold/unavailable contract: keys before the Broker
// is ready fail open immediately, are never marked consumed without processing,
// and are never replayed after a later successful connect.
void CheckUnavailablePassThroughAndNoReplay() {
  using namespace rimes::windows::tsf;
  auto client = CreateBrokerClient();
  Expect(client != nullptr, "unavailable-contract client created");
  if (!client) {
    return;
  }

  Expect(!client->IsConnected(), "contract client starts disconnected");
  BrokerInputState cold;
  Expect(client->HandleKey({BrokerKeyPhase::kTestKeyDown, 'N', 0}, nullptr) ==
             BrokerKeyResult::kUnavailable,
         "cold TestKeyDown fails open");
  Expect(client->HandleKey({BrokerKeyPhase::kKeyDown, 'N', 1}, &cold) ==
             BrokerKeyResult::kUnavailable,
         "cold KeyDown fails open");
  Expect(!cold.has_snapshot, "cold KeyDown must not invent a snapshot");
  Expect(client->HandleKey({BrokerKeyPhase::kKeyDown, 'I', 1}, &cold) ==
             BrokerKeyResult::kUnavailable,
         "second cold KeyDown fails open");
  Expect(!cold.has_snapshot, "second cold KeyDown has no snapshot to replay");

  client->BeginConnect();
  const auto connected_at = GetTickCount64();
  while (!client->IsConnected() && GetTickCount64() - connected_at < 15000) {
    Sleep(50);
  }
  Expect(client->IsConnected(), "contract client connects for positive control");
  if (!client->IsConnected()) {
    client->Disconnect();
    return;
  }
  Expect(WaitForContext(client.get(), 1001), "connected context bound");

  BrokerInputState live;
  Expect(client->HandleKey({BrokerKeyPhase::kKeyDown, 'N', 1}, &live) ==
             BrokerKeyResult::kConsumed,
         "connected KeyDown is processed");
  Expect(live.has_snapshot && live.composing,
         "connected KeyDown yields a live snapshot");
  Expect(live.composition == L"n" && live.commit_text.empty(),
         "first connected key has no replay of unavailable NI");
  client->HandleKey({BrokerKeyPhase::kKeyUp, 'N', 0}, &live);
  // Cancel any preedit so the next reconnect assertion is unambiguous.
  BrokerInputState cancelled;
  client->HandleKey({BrokerKeyPhase::kKeyDown, VK_ESCAPE, 1}, &cancelled);
  client->HandleKey({BrokerKeyPhase::kKeyUp, VK_ESCAPE, 0}, &cancelled);

  client->Disconnect();
  Expect(!client->IsConnected(), "Disconnect returns to unavailable");

  BrokerInputState dropped;
  Expect(client->HandleKey({BrokerKeyPhase::kKeyDown, 'X', 1}, &dropped) ==
             BrokerKeyResult::kUnavailable,
         "post-disconnect KeyDown fails open");
  Expect(client->HandleKey({BrokerKeyPhase::kKeyDown, 'Y', 1}, &dropped) ==
             BrokerKeyResult::kUnavailable,
         "second post-disconnect KeyDown fails open");
  Expect(!dropped.has_snapshot,
         "disconnected letters are not retained for replay");

  client->BeginConnect();
  const auto reconnected_at = GetTickCount64();
  while (!client->IsConnected() && GetTickCount64() - reconnected_at < 15000) {
    Sleep(50);
  }
  Expect(client->IsConnected(), "contract client reconnects");
  if (!client->IsConnected()) {
    client->Disconnect();
    return;
  }
  Expect(client->SetContext(1002), "fresh context after reconnect");

  BrokerInputState after;
  Expect(client->HandleKey({BrokerKeyPhase::kKeyDown, 'N', 1}, &after) ==
             BrokerKeyResult::kConsumed,
         "first key after reconnect is processed fresh");
  Expect(after.has_snapshot, "reconnect KeyDown has a snapshot");
  Expect(after.composition == L"n" && after.commit_text.empty(),
         "no delayed replay of unavailable or prior cancelled input");
  client->HandleKey({BrokerKeyPhase::kKeyUp, 'N', 0}, &after);
  Expect(client->HandleKey({BrokerKeyPhase::kKeyDown, 'I', 1}, &after) ==
             BrokerKeyResult::kConsumed,
         "second fresh key after reconnect is processed");
  Expect(after.composition == L"ni" && after.commit_text.empty(),
         "fresh reconnect composition contains exactly the new NI");
  client->HandleKey({BrokerKeyPhase::kKeyUp, 'I', 0}, &after);
  client->HandleKey({BrokerKeyPhase::kKeyDown, VK_ESCAPE, 1}, &after);
  client->HandleKey({BrokerKeyPhase::kKeyUp, VK_ESCAPE, 0}, &after);
  client->Disconnect();
}

void CheckCandidateGuardAfterKeyRelease() {
  using namespace rimes::windows::tsf;
  auto client = CreateBrokerClient();
  Expect(client != nullptr, "candidate regression client created");
  if (!client) return;
  client->BeginConnect();
  const auto started = GetTickCount64();
  while (!client->IsConnected() && GetTickCount64() - started < 15000)
    Sleep(50);
  Expect(client->IsConnected(), "candidate regression client connected");
  if (!client->IsConnected()) return;
  Expect(WaitForContext(client.get(), 1), "candidate regression context bound");
  BrokerInputState shown;
  for (const auto key : {'N', 'I'}) {
    BrokerInputState down, up;
    Expect(client->HandleKey({BrokerKeyPhase::kKeyDown,
                             static_cast<WPARAM>(key), 1}, &down) ==
               BrokerKeyResult::kConsumed,
           "candidate regression letter consumed");
    if (down.has_snapshot) shown = down;
    Expect(client->HandleKey({BrokerKeyPhase::kKeyUp,
                             static_cast<WPARAM>(key), 0}, &up) ==
               BrokerKeyResult::kConsumed,
           "candidate regression matching release consumed");
    if (up.has_snapshot) shown = up;
  }
  Expect(shown.composing && !shown.candidates.empty(),
         "candidate remains displayed after letter release");
  Expect(client->Control({{"op", "candidate_guard"},
                          {"revision", shown.revision}, {"index", 0}}),
         "current mouse candidate accepted after unhandled KeyUp");
  BrokerInputState selected, released;
  Expect(client->HandleKey({BrokerKeyPhase::kKeyDown, '1', 1}, &selected) ==
             BrokerKeyResult::kConsumed,
         "guarded candidate selection consumed");
  if (!shown.candidates.empty())
    Expect(selected.commit_text == shown.candidates[0].text,
           "guarded candidate commits exactly the displayed item");
  client->HandleKey({BrokerKeyPhase::kKeyUp, '1', 0}, &released);
  Expect(!client->Control({{"op", "candidate_guard"},
                           {"revision", shown.revision}, {"index", 0}}),
         "old candidate rejected after commit");
  client->Disconnect();
}

int RunTypingScenarios() {
  using rimes::windows::e2e::FakeContext;
  using rimes::windows::e2e::FakeDocument;
  using rimes::windows::e2e::FakeThreadMgr;
  using rimes::windows::tsf::CandidateSnapshot;
  using rimes::windows::tsf::CandidateWindow;
  using rimes::windows::tsf::TextService;
  using rimes::windows::tsf::module::SetInstance;

  SetInstance(GetModuleHandleW(nullptr));
  const HRESULT com = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  if (FAILED(com) && com != RPC_E_CHANGED_MODE) {
    std::cerr << "CoInitializeEx failed\n";
    return EXIT_FAILURE;
  }

  FakeDocument document;
  auto* thread_manager = new FakeThreadMgr();
  auto* context = new FakeContext(&document);
  auto* service = new TextService();

  const HRESULT activated = service->Activate(thread_manager, 1);
  if (FAILED(activated)) {
    std::cerr << "TextService::Activate failed\n";
    service->Release();
    context->Release();
    thread_manager->Release();
    if (SUCCEEDED(com)) {
      CoUninitialize();
    }
    return EXIT_FAILURE;
  }

  if (!WaitForBroker(service, 15000)) {
    Fail("TSF client did not connect to the Broker within 15s");
    service->Deactivate();
    service->Release();
    context->Release();
    thread_manager->Release();
    if (SUCCEEDED(com)) {
      CoUninitialize();
    }
    return EXIT_FAILURE;
  }

  ClearCapsLockIfLatched();
  CheckFocusRestoration();
  std::cerr << "caps_lock=" << ((GetKeyState(VK_CAPITAL) & 1) != 0)
            << " shift=" << ((GetKeyState(VK_SHIFT) & 0x8000) != 0) << '\n';

  CheckUnavailablePassThroughAndNoReplay();
  CheckCandidateGuardAfterKeyRelease();

  TypeLatin(service, context, "nihao", &document);
  DumpDocument("after nihao", document);
  Expect(document.composing, "nihao should start an inline composition");
  Expect(!document.composition.empty(),
         "nihao should produce a non-empty preedit");
  const std::vector<std::wstring> after_nihao = CandidateTexts();
  Expect(!after_nihao.empty(), "nihao should show a candidate page");
  Expect(ContainsText(after_nihao, L"你好"),
         "nihao candidates should include 你好");
  CandidateSnapshot snapshot;
  CandidateWindow::GetLastSnapshot(&snapshot);
  Expect(snapshot.visible, "candidate window snapshot should be visible");
  Expect(snapshot.caret_rect.left == document.caret_rect.left &&
             snapshot.caret_rect.top == document.caret_rect.top,
         "candidate window should use ITfContextView::GetTextExt caret");

  TypeVirtualKey(service, context, VK_SPACE, true);
  Expect(document.last_commit == L"你好", "Space should commit 你好");
  Expect(document.text == L"你好", "document text should contain 你好");
  Expect(!document.composing, "Space should end the composition");
  CandidateWindow::GetLastSnapshot(&snapshot);
  Expect(!snapshot.visible, "candidate window should hide after commit");

  ResetDocument(&document);
  TypeLatin(service, context, "nihao");
  const std::vector<std::wstring> before_number = CandidateTexts();
  Expect(before_number.size() >= 2,
         "nihao should offer at least two candidates");
  const std::wstring second =
      before_number.size() >= 2 ? before_number[1] : std::wstring();
  TypeVirtualKey(service, context, static_cast<WPARAM>('2'), true);
  Expect(document.last_commit == second,
         "number 2 should commit the second candidate");
  Expect(!document.composing, "number selection should end the composition");

  ResetDocument(&document);
  TypeLatin(service, context, "nihao");
  const std::vector<std::wstring> page_one = CandidateTexts();
  TypeVirtualKey(service, context, VK_NEXT, true);
  const std::vector<std::wstring> page_two = CandidateTexts();
  Expect(!page_one.empty() && !page_two.empty(),
         "paging should keep a candidate page visible");
  Expect(page_one != page_two,
         "PageDown should replace the current candidate page");
  Expect(document.composing, "paging should keep the composition active");
  TypeVirtualKey(service, context, VK_ESCAPE, true);
  Expect(document.text.empty(), "Escape after paging should not commit");
  Expect(!document.composing, "Escape should cancel the composition");
  CandidateWindow::GetLastSnapshot(&snapshot);
  Expect(!snapshot.visible, "Escape should hide the candidate window");

  ResetDocument(&document);
  TypeLatin(service, context, "nihao");
  TypeVirtualKey(service, context, VK_ESCAPE, true);
  Expect(document.text.empty() && document.last_commit.empty(),
         "Escape during preedit should not commit");
  Expect(!document.composing, "Escape should clear composing state");

  // Native Edit controls may terminate preedit before notifying focus loss.
  for (int iteration = 0; iteration < 25; ++iteration) {
    ResetDocument(&document);
    TypeLatin(service, context, "ni");
    context->TerminateComposition();
    Expect(document.text.empty() && document.composition.empty() &&
               !document.composing,
           "host termination must erase preedit before it becomes raw text");
    // The minimal E2E dictionary contains nihao and ni, not standalone hao.
    TypeLatin(service, context, "nihao");
    TypeVirtualKey(service, context, VK_SPACE, true);
    Expect(document.text == L"你好",
           "host termination must reset the old engine context too");
  }

  // A host that refuses every caret source must not move the popup to the
  // screen origin. QueryCaretRect yields an all-zero rectangle, which used to
  // be indistinguishable from a caret at (0, 0) and produced a visible jump to
  // the top-left corner before the real caret arrived on the next frame.
  ResetDocument(&document);
  TypeLatin(service, context, "ni");
  CandidateWindow::GetLastSnapshot(&snapshot);
  Expect(snapshot.visible, "candidate window is visible before the host refuses");
  const RECT known_caret = snapshot.caret_rect;
  Expect(known_caret.left != 0 || known_caret.top != 0,
         "the baseline caret is anchored next to the input field");
  document.refuse_caret = true;
  TypeLatin(service, context, "hao");
  CandidateWindow::GetLastSnapshot(&snapshot);
  Expect(snapshot.visible,
         "an unknown caret must not hide an otherwise valid candidate page");
  Expect(snapshot.caret_rect.left == known_caret.left &&
             snapshot.caret_rect.top == known_caret.top,
         "an unresolvable caret must reuse the previous placement, not (0, 0)");
  Expect(!(snapshot.caret_rect.left == 0 && snapshot.caret_rect.top == 0),
         "the candidate window must never be anchored at the screen origin");
  document.refuse_caret = false;
  TypeVirtualKey(service, context, VK_SPACE, true);
  Expect(document.last_commit == L"你好",
         "a host that briefly hides its caret must not break composition");

  // An asynchronous edit accepted by RequestEditSession is still revocable.
  ResetDocument(&document);
  context->defer_edits = true;
  TypeLatin(service, context, "nihao");
  Expect(!context->delayed_edits.empty(),
         "host queued asynchronous composition edits");
  FakeDocument other_document;
  auto* other = new FakeContext(&other_document);
  TypeLatin(service, other, "nihao");
  context->DrainEdits();
  context->defer_edits = false;
  Expect(document.text.empty() && !document.composing,
         "old context edits revoked before execution");
  TypeVirtualKey(service, other, VK_SPACE, true);
  Expect(other_document.text == L"你好", "new context commits independently");
  other->read_only = true;
  BOOL protected_eaten = TRUE;
  service->OnKeyDown(other, 'N', 0, &protected_eaten);
  Expect(!protected_eaten, "read-only context never forwards input");
  other->Release();

  service->Deactivate();
  service->Release();
  context->Release();
  thread_manager->Release();
  if (SUCCEEDED(com)) {
    CoUninitialize();
  }
  return g_failures == 0 ? EXIT_SUCCESS : EXIT_FAILURE;
}

}  // namespace

int wmain() { return RunTypingScenarios(); }
