#include "rime_engine.hpp"

#include <algorithm>
#include <cstdlib>
#include <filesystem>
#include <iostream>
#include <string>

namespace {

inline constexpr std::int32_t kRimeReleaseMask = 1 << 30;

void PrintUsage() {
  std::wcerr
      << L"Usage: RimesEngineSmoke <absolute-rime.dll> <shared-data-dir> "
         L"<user-data-dir> [log-dir]\n";
}

}  // namespace

int wmain(int argc, wchar_t** argv) {
  if (argc != 4 && argc != 5) {
    PrintUsage();
    return EXIT_FAILURE;
  }

  rimes::windows::engine::RimeEngineOptions options;
  options.dll_path = argv[1];
  options.shared_data_dir = argv[2];
  options.user_data_dir = argv[3];
  if (argc == 5) {
    options.log_dir = argv[4];
  }

  std::error_code filesystem_error;
  std::filesystem::create_directories(options.user_data_dir, filesystem_error);
  if (filesystem_error) {
    std::cerr << "Could not create isolated smoke user directory\n";
    return EXIT_FAILURE;
  }
  if (!options.log_dir.empty()) {
    std::filesystem::create_directories(options.log_dir, filesystem_error);
    if (filesystem_error) {
      std::cerr << "Could not create smoke log directory\n";
      return EXIT_FAILURE;
    }
  }

  rimes::windows::engine::RimeEngine engine;
  std::string error;
  if (!engine.Start(options, &error)) {
    std::cerr << "Engine start failed: " << error << '\n';
    return EXIT_FAILURE;
  }

  const auto session = engine.CreateSession(&error);
  if (session == 0) {
    std::cerr << "Session creation failed: " << error << '\n';
    return EXIT_FAILURE;
  }

  bool observed_handled_key = false;
  std::size_t maximum_candidates = 0;
  std::size_t maximum_composition_bytes = 0;
  for (const std::int32_t keycode : {'r', 'i', 'm', 'e'}) {
    // RIMES' primary schema uses librime's chord_composer. A smoke that sends
    // key-down only can pass against ordinary pinyin while never settling a
    // chord, so exercise both halves of every physical key event.
    for (const std::int32_t modifiers : {0, kRimeReleaseMask}) {
      rimes::windows::engine::EngineSnapshot snapshot;
      if (!engine.ProcessKey(session, keycode, modifiers, &snapshot, &error)) {
        std::cerr << "Key processing failed: " << error << '\n';
        return EXIT_FAILURE;
      }
      observed_handled_key = observed_handled_key || snapshot.handled;
      maximum_candidates =
          (std::max)(maximum_candidates, snapshot.candidates.size());
      maximum_composition_bytes =
          (std::max)(maximum_composition_bytes, snapshot.composition.size());
    }
  }

  rimes::windows::engine::EngineSnapshot selection_down;
  if (!engine.ProcessKey(session, ' ', 0, &selection_down, &error)) {
    std::cerr << "Selection key-down processing failed: " << error << '\n';
    return EXIT_FAILURE;
  }
  if (!selection_down.handled) {
    std::cerr << "Selection key-down was not handled\n";
    return EXIT_FAILURE;
  }
  if (selection_down.commit_text.empty()) {
    std::cerr << "Selection key-down did not produce committed text\n";
    return EXIT_FAILURE;
  }
  if (selection_down.composing || !selection_down.composition.empty()) {
    std::cerr << "Composition remained active after selection\n";
    return EXIT_FAILURE;
  }

  rimes::windows::engine::EngineSnapshot selection_up;
  if (!engine.ProcessKey(session, ' ', kRimeReleaseMask, &selection_up,
                         &error)) {
    std::cerr << "Selection key-up processing failed: " << error << '\n';
    return EXIT_FAILURE;
  }
  // librime commonly reports the release half as unhandled. That is a valid
  // no-mutation response; do not require it to advance the engine state.
  if (!selection_up.handled &&
      (selection_up.composing || !selection_up.composition.empty() ||
       !selection_up.commit_text.empty() || !selection_up.candidates.empty())) {
    std::cerr << "Unhandled selection key-up mutated input state\n";
    return EXIT_FAILURE;
  }

  if (!engine.DestroySession(session, &error)) {
    std::cerr << "Session destruction failed: " << error << '\n';
    return EXIT_FAILURE;
  }
  engine.Stop();

  if (!observed_handled_key) {
    std::cerr << "librime loaded but no smoke key was handled\n";
    return EXIT_FAILURE;
  }
  std::cout << "Rime engine smoke passed; max composition bytes="
            << maximum_composition_bytes
            << ", max current-page candidates=" << maximum_candidates << '\n';
  return EXIT_SUCCESS;
}
