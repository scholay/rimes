#include "rime_engine.hpp"
#include "rime_snapshot.hpp"

#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <string>
#include <vector>

namespace rimes::windows::engine {
namespace {

int failures = 0;

void Check(bool condition, const char* message) {
  if (!condition) {
    std::cerr << "FAIL: " << message << '\n';
    ++failures;
  }
}

void TestUtf8AndSnapshotConversion() {
  const std::string composition =
      "a\xE4\xB8\xAD\xF0\x9F\x98\x80";  // a, CJK, supplementary scalar
  const std::vector<RawCandidateView> candidates = {
      {"\xE5\x80\x99\xE9\x80\x89\xE4\xB8\x80", "note", "1"},
      {"second", "\xF0\x9F\x8C\x9F", "2"},
  };

  RawSnapshotView raw;
  raw.handled = true;
  raw.has_context = true;
  raw.composition = composition;
  raw.commit_text = "";
  raw.caret_utf8 = composition.size();
  raw.selection_start_utf8 = 1;
  raw.selection_end_utf8 = 4;
  raw.page_number = 2;
  raw.page_size = 5;
  raw.highlighted_candidate = 1;
  raw.candidates = candidates;

  EngineSnapshot snapshot;
  std::string error;
  Check(BuildEngineSnapshot(raw, &snapshot, &error),
        "valid UTF-8 snapshot should convert");
  Check(error.empty(), "valid conversion should not report an error");
  Check(snapshot.handled && snapshot.composing,
        "handled composition flags should survive conversion");
  Check(snapshot.caret_utf16 == 4,
        "UTF-8 caret should convert to four UTF-16 code units");
  Check(snapshot.selection_start_utf16 == 1 &&
            snapshot.selection_length_utf16 == 1,
        "CJK selection should convert from byte to UTF-16 offsets");
  Check(snapshot.candidates.size() == 2 &&
            snapshot.candidates[0].id == 10 &&
            snapshot.candidates[1].id == 11,
        "candidate IDs should preserve the librime page offset");

  core::InputState state;
  Check(MapSnapshotToInputState(7, 9, 3, snapshot, &state, &error),
        "valid snapshot should map to the broker DTO");
  Check(state.caret_utf16 == 4 && state.selection_length_utf16 == 0,
        "mapper should preserve caret when selection has a different start");
  Check(state.page_start == 0 && state.page_size == 2,
        "wire page should describe the transmitted current-page candidates");
  Check(state.candidates.size() == 2 && state.candidates[0].id == 10,
        "wire candidate should retain its global engine ID");
}

void TestMalformedUtf8FailsClosed() {
  const std::string malformed("\xED\xA0\x80", 3);  // UTF-8 surrogate
  RawSnapshotView raw;
  raw.handled = true;
  raw.has_context = true;
  raw.composition = malformed;
  raw.caret_utf8 = malformed.size();
  raw.selection_start_utf8 = malformed.size();
  raw.selection_end_utf8 = malformed.size();

  EngineSnapshot snapshot;
  std::string error;
  Check(!BuildEngineSnapshot(raw, &snapshot, &error),
        "surrogate UTF-8 must be rejected");
  Check(!snapshot.handled && snapshot.composition.empty(),
        "failed conversion must clear its output");
}

void TestMidScalarOffsetFailsClosed() {
  const std::string composition = "\xE4\xB8\xAD";
  RawSnapshotView raw;
  raw.handled = true;
  raw.has_context = true;
  raw.composition = composition;
  raw.caret_utf8 = 1;
  raw.selection_start_utf8 = 0;
  raw.selection_end_utf8 = composition.size();

  EngineSnapshot snapshot;
  Check(!BuildEngineSnapshot(raw, &snapshot),
        "offset inside a UTF-8 scalar must be rejected");
}

void TestCandidateLimitsFailClosed() {
  std::vector<RawCandidateView> candidates(core::kMaxCandidateCount + 1,
                                           {"x", "", "1"});
  RawSnapshotView raw;
  raw.handled = true;
  raw.has_context = true;
  raw.composition = "x";
  raw.caret_utf8 = 1;
  raw.selection_start_utf8 = 1;
  raw.selection_end_utf8 = 1;
  raw.page_size = static_cast<std::uint32_t>(candidates.size());
  raw.highlighted_candidate = 0;
  raw.candidates = candidates;

  EngineSnapshot snapshot;
  Check(!BuildEngineSnapshot(raw, &snapshot),
        "oversized candidate pages must be rejected");
}

void TestUnhandledInputIsMutationFree() {
  RawSnapshotView raw;
  raw.handled = false;
  raw.has_context = true;
  raw.composition = std::string_view("\xFF", 1);

  EngineSnapshot snapshot;
  Check(BuildEngineSnapshot(raw, &snapshot),
        "unhandled input should fail open without parsing mutations");
  Check(!snapshot.handled && snapshot.composition.empty() &&
            snapshot.candidates.empty(),
        "unhandled snapshot must be empty");
}

#ifdef _WIN32
void TestDllPathGate() {
  RimeEngine engine;
  RimeEngineOptions options;
  options.dll_path = L"rime.dll";
  options.shared_data_dir = L"C:\\RIMES-test-shared";
  options.user_data_dir = L"C:\\RIMES-test-user";

  std::string error;
  Check(!engine.Start(options, &error),
        "relative DLL path must be rejected before loading");
  Check(!error.empty(), "rejected DLL path should report a reason");
  Check(!engine.IsHealthy(), "failed load must leave the engine unhealthy");
}
#endif

}  // namespace
}  // namespace rimes::windows::engine

int main() {
  using namespace rimes::windows::engine;
  TestUtf8AndSnapshotConversion();
  TestMalformedUtf8FailsClosed();
  TestMidScalarOffsetFailsClosed();
  TestCandidateLimitsFailClosed();
  TestUnhandledInputIsMutationFree();
#ifdef _WIN32
  TestDllPathGate();
#endif

  if (failures != 0) {
    std::cerr << failures << " engine test(s) failed\n";
    return EXIT_FAILURE;
  }
  std::cout << "Rime engine tests passed\n";
  return EXIT_SUCCESS;
}
