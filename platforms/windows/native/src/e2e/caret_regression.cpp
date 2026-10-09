#include <Windows.h>

#include <iostream>

#include "TextService.h"
#include "candidate_layout.hpp"
#include "fake_tsf.hpp"

namespace rimes::windows::tsf {
struct CaretRegressionProbe {
  static bool Bind(TextService& service, ITfContext* context) {
    service.client_id_ = 1;
    return service.BindContext(context);
  }
  static HRESULT Apply(TextService& service, ITfContext* context,
                       const BrokerInputState& state) {
    return service.ApplyDocumentState(context, state);
  }
  static bool Retains(TextService& service, ITfContext* context,
                      std::uint64_t revision) {
    return service.active_context_ == context && service.edit_valid_ &&
           service.edit_valid_->load() && service.last_state_.revision == revision;
  }
  static RECT Query(TextService& service, ITfContext* context) {
    return service.QueryCaretRect(context, 0);
  }
  static CandidateSnapshot Present(TextService& service, ITfContext* context) {
    BrokerInputState state;
    state.candidates_visible = true;
    state.composing = true;
    state.composition = L"ni";
    state.page_size = 5;
    state.candidates.push_back({0, L"test", L"", L"1"});
    service.UpdateCandidateWindow(context, state, 0);
    return service.candidate_window_.snapshot();
  }
};
}  // namespace rimes::windows::tsf

int main() {
  using namespace rimes::windows;
  const auto com = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  if (FAILED(com)) {
    std::cerr << "FAIL: COM initialization failed\n";
    return 1;
  }
  e2e::FakeDocument document;
  auto* context = new e2e::FakeContext(&document);
  auto* service = new tsf::TextService();
  int failures = 0;
  auto expect = [&](bool ok, const char* message) {
    if (!ok) {
      ++failures;
      std::cerr << "FAIL: " << message << '\n';
    }
  };
  document.refuse_caret = true;
  expect(!tsf::CaretRegressionProbe::Present(*service, context).visible,
         "first candidates without verified geometry remain hidden");
  document.refuse_caret = false;
  const RECT known = tsf::CaretRegressionProbe::Query(*service, context);
  expect(EqualRect(&known, &document.caret_rect),
         "TSF caret geometry is retained");
  const auto initial = tsf::CaretRegressionProbe::Present(*service, context);
  expect(initial.visible && EqualRect(&initial.caret_rect, &known),
         "verified TSF geometry anchors the candidate window");
  HWND frame = CreateWindowExW(0, L"STATIC", L"", WS_POPUP, 700, 420,
                               600, 400, nullptr, nullptr,
                               GetModuleHandleW(nullptr), nullptr);
  expect(frame != nullptr, "native host frame exists");
  expect(CreateCaret(frame, nullptr, 2, 20) != FALSE, "dummy native caret exists");
  expect(SetCaretPos(0, 0) != FALSE, "dummy native caret uses the frame origin");
  document.view_window = frame;
  document.refuse_caret = true;
  const RECT unknown = tsf::CaretRegressionProbe::Query(*service, context);
  expect(unknown.bottom <= unknown.top,
         "failed TSF geometry does not use the native frame origin");
  tsf::ScreenRect resolved{};
  expect(tsf::ResolveCandidateCaret(
             {unknown.left, unknown.top, unknown.right, unknown.bottom},
             {known.left, known.top, known.right, known.bottom}, &resolved)
         && resolved.left == known.left && resolved.top == known.top,
         "candidate placement stays at the last verified TSF caret");
  const auto cached = tsf::CaretRegressionProbe::Present(*service, context);
  expect(cached.visible && EqualRect(&cached.caret_rect, &known),
         "candidate update does not jump to the native host frame");
  document.write_caret_before_failure = true;
  document.caret_rect = {700, 420, 702, 440};
  const RECT failed_output = tsf::CaretRegressionProbe::Query(*service, context);
  expect(failed_output.bottom <= failed_output.top,
         "failed GetTextExt output cannot supply candidate geometry");
  const auto failed_cached = tsf::CaretRegressionProbe::Present(*service, context);
  expect(failed_cached.visible && EqualRect(&failed_cached.caret_rect, &known),
         "failed GetTextExt output cannot replace verified placement");
  document.write_caret_before_failure = false;
  document.refuse_caret = false;
  document.caret_rect = {300, 260, 302, 284};
  const auto moved = tsf::CaretRegressionProbe::Present(*service, context);
  expect(moved.visible && EqualRect(&moved.caret_rect, &document.caret_rect),
         "resumed TSF geometry moves candidates to the new caret");
  document.caret_rect = {0, 0, 0, 20};
  const RECT origin = tsf::CaretRegressionProbe::Query(*service, context);
  expect(EqualRect(&origin, &document.caret_rect),
         "valid TSF geometry at the screen origin still works");
  DestroyCaret();
  DestroyWindow(frame);

  // An idle Shift tap returns an authoritative modifier snapshot but has no
  // document mutation. Hosts can refuse write locks at this point; this must
  // not revoke the context (which would reset the just-toggled ASCII session).
  e2e::FakeDocument idle_document;
  auto* idle_context = new e2e::FakeContext(&idle_document);
  auto* idle_service = new tsf::TextService(nullptr);
  expect(tsf::CaretRegressionProbe::Bind(*idle_service, idle_context),
         "idle modifier fixture binds without a live Broker");
  idle_context->refuse_write_edits = true;
  tsf::BrokerInputState idle;
  idle.has_snapshot = true;
  idle.revision = 7;
  expect(SUCCEEDED(tsf::CaretRegressionProbe::Apply(
             *idle_service, idle_context, idle)),
         "idle modifier snapshot needs no host write lock");
  expect(idle_context->write_requests == 0 && idle_document.text.empty(),
         "idle modifier snapshot cannot request or queue a document edit");
  expect(tsf::CaretRegressionProbe::Retains(*idle_service, idle_context, 7),
         "idle modifier snapshot retains its context and authoritative revision");

  idle_context->refuse_write_edits = false;
  tsf::CaretRegressionProbe::Bind(*idle_service, idle_context);
  tsf::BrokerInputState preedit;
  preedit.has_snapshot = true;
  preedit.composing = true;
  preedit.composition = L"ni";
  preedit.caret_utf16 = 2;
  expect(SUCCEEDED(tsf::CaretRegressionProbe::Apply(
             *idle_service, idle_context, preedit)) && idle_document.composing,
         "nonempty preedit still obtains a write session");
  const auto before_cancel = idle_context->write_requests;
  expect(SUCCEEDED(tsf::CaretRegressionProbe::Apply(
             *idle_service, idle_context, idle)) && !idle_document.composing &&
             idle_document.text.empty() &&
             idle_context->write_requests > before_cancel,
         "empty state still clears an existing host composition under a write lock");
  tsf::BrokerInputState commit;
  commit.has_snapshot = true;
  commit.commit_text = L"123";
  const auto before_commit = idle_context->write_requests;
  expect(SUCCEEDED(tsf::CaretRegressionProbe::Apply(
             *idle_service, idle_context, commit)) && idle_document.text == L"123" &&
             idle_context->write_requests > before_commit,
         "an idle commit still writes text exactly once");
  idle_service->Release();
  idle_context->Release();
  service->Release();
  context->Release();
  if (SUCCEEDED(com)) CoUninitialize();
  if (!failures) std::cout << "Caret placement and idle modifier snapshot regression passed\n";
  return failures ? 1 : 0;
}
