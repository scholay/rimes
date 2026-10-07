#include <filesystem>
#include <iostream>
#include <vector>

#include "rime_engine.hpp"
#include "../broker/key_translation.hpp"
#include "../broker/broker_connection.hpp"
using namespace rimes::windows::engine;
int wmain(int argc, wchar_t** argv) {
  if (argc != 5) return 2;
  RimeEngineOptions options;
  options.dll_path = argv[1];
  options.shared_data_dir = argv[2];
  options.user_data_dir = argv[3];
  options.log_dir = argv[4];
  options.full_maintenance_check = true;
  std::filesystem::create_directories(options.user_data_dir);
  std::filesystem::create_directories(options.log_dir);
  RimeEngine engine;
  std::string error;
  if (!engine.Start(options, &error)) {
    std::cerr << error;
    return 1;
  }
  auto session = engine.CreateSession(&error);
  if (!session) return 1;
  struct Case {
    const char* schema;
    const char* keys;
    bool traditional;
    const char* expected;
  };
  const std::vector<Case> cases = {{"rime_ice", "nihao", false, "你好"},
                                   {"double_pinyin", "ni", false, "你"},
                                   {"double_pinyin_flypy", "ni", false, "你"},
                                   {"wubi86", "wq", false, "你"},
                                   {"english", "hello", false, "hello"},
                                   {"rime_ice", "han", true, "漢"},
                                   {"wubi86", "ic", true, "漢"}};
  for (const auto& item : cases) {
    if (!engine.Configure(session, item.schema, false, item.traditional, false,
                          &error)) {
      std::cerr << "Configure failed " << item.schema;
      return 1;
    }
    EngineSnapshot snapshot;
    std::string committed;
    for (const char* key = item.keys; *key; ++key) {
      if (!engine.ProcessKey(session, *key, 0, &snapshot, &error)) return 1;
      committed += snapshot.commit_text;
    }
    bool found = committed.find(item.expected) != std::string::npos;
    for (const auto& candidate : snapshot.candidates)
      if (candidate.text == item.expected) found = true;
    if (!found) {
      std::cerr << "Product candidate assertion failed: " << item.schema
                << " traditional=" << item.traditional
                << " candidate_count=" << snapshot.candidates.size() << '\n';
      return 1;
    }
    std::cout << "Product scheme passed: " << item.schema
              << " traditional=" << item.traditional << '\n';
  }
  for (const unsigned count : {1U, 5U, 9U}) {
    if (!engine.Configure(session, "rime_ice", false, false, false, &error, count)) return 1;
    EngineSnapshot page;
    if (!engine.ProcessKey(session, 'n', 0, &page, &error) ||
        !engine.ProcessKey(session, 'i', 0, &page, &error) ||
        page.page_size != count || page.candidates.empty() || page.candidates.size() > count) {
      std::cerr << "Engine candidate page size is not the requested count: " << count
                << " actual=" << page.page_size << " candidates=" << page.candidates.size(); return 1;
    }
    std::cout << "Candidate page size passed: " << count << '\n';
  }
  if (!engine.Configure(session, "my_combo", false, false, false, &error)) {
    std::cerr << "Configure failed my_combo: " << error; return 1;
  }
  EngineSnapshot chord;
  constexpr int released = 1 << 30;
  for (const char key : {'d', 'v', 'i'}) {
    if (!engine.ProcessKey(session, key, 0, &chord, &error) || !chord.commit_text.empty()) {
      std::cerr << "Chord key-down committed prematurely"; return 1;
    }
  }
  for (const char key : {'v', 'd', 'i'}) {
    if (!engine.ProcessKey(session, key, released, &chord, &error) || !chord.commit_text.empty()) {
      std::cerr << "Chord release failed or bypassed selection"; return 1;
    }
    if (key != 'i' && !chord.candidates.empty()) {
      std::cerr << "Chord resolved before the final key-up"; return 1;
    }
  }
  if (chord.candidates.empty() || chord.candidates.front().text != "你") {
    std::cerr << "Chord d+v+i did not resolve to ni / 你"; return 1;
  }
  if (!engine.ProcessKey(session, ' ', 0, &chord, &error) || chord.commit_text != "你") {
    std::cerr << "Chord candidate failed to commit exactly once"; return 1;
  }
  if (!engine.ProcessKey(session, ' ', released, &chord, &error) || !chord.commit_text.empty()) {
    std::cerr << "Chord space release duplicated commit"; return 1;
  }
  std::cout << "Product scheme passed: my_combo chord down/up and commit\n";
  // Exercise the actual Windows-to-Rime boundary, not only hand-written
  // keysyms. A shifted slash previously remained '/' on this path (#59).
  using namespace rimes::windows;
  constexpr auto shift = static_cast<std::uint32_t>(core::KeyModifiers::kShift);
  constexpr auto caps = static_cast<std::uint32_t>(core::KeyModifiers::kCapsLock);
  auto windows_key = [&](std::uint32_t vk, std::uint32_t modifiers,
                         bool down, EngineSnapshot* snapshot) {
    core::KeyEvent event;
    event.virtual_key = vk;
    event.modifiers = modifiers;
    event.event_flags = down ? static_cast<std::uint32_t>(core::KeyEventFlags::kKeyDown) : 0;
    const auto translated = broker::TranslateWindowsKey(event);
    return translated && engine.ProcessKey(session, translated->keycode,
                                          translated->modifiers, snapshot, &error);
  };
  for (const bool ascii_punctuation : {false, true}) {
    if (!engine.Configure(session, "rime_ice", false, false, ascii_punctuation, &error)) return 1;
    EngineSnapshot punctuation;
    // ascii_punct deliberately leaves ASCII punctuation to the host. The
    // translated symbol must still be '?' so Buffer can use the same fallback.
    const auto question = broker::TranslateWindowsKey(core::KeyEvent{
        .virtual_key = 0xbf, .modifiers = shift,
        .event_flags = static_cast<std::uint32_t>(core::KeyEventFlags::kKeyDown)});
    if (!question || question->keycode != '?' ||
        !windows_key(0xbf, shift, true, &punctuation) ||
        (ascii_punctuation ? (punctuation.handled || !punctuation.commit_text.empty())
                           : (!punctuation.handled || punctuation.commit_text != "？"))) {
      std::cerr << "Shift+/ did not commit the configured question mark: ascii="
                << ascii_punctuation << " handled=" << punctuation.handled
                << " commit=" << punctuation.commit_text
                << " composition=" << punctuation.composition
                << " candidates=" << punctuation.candidates.size()
                << " error=" << error << '\n';
      for (const auto& candidate : punctuation.candidates)
        std::cerr << "Punctuation candidate=" << candidate.text << '\n';
      return 1;
    }
    // Releasing Shift first must not cause a slash or a duplicate commit.
    if (!windows_key(0xbf, 0, false, &punctuation) || !punctuation.commit_text.empty()) {
      std::cerr << "Question mark key-up duplicated text"; return 1;
    }
    if (!windows_key(0xbf, 0, true, &punctuation) ||
        (ascii_punctuation ? (punctuation.handled || !punctuation.commit_text.empty())
                           : punctuation.commit_text != "/")) {
      std::cerr << "Unshifted slash changed"; return 1;
    }
    if (!windows_key(0xbf, 0, false, &punctuation) || !punctuation.commit_text.empty()) return 1;
  }
  if (!engine.Configure(session, "english", false, false, false, &error)) return 1;
  EngineSnapshot english;
  for (const auto& [vk, modifiers] : std::vector<std::pair<std::uint32_t, std::uint32_t>>{
           {'H', shift}, {'E', 0}, {'L', shift}, {'L', 0}, {'O', 0}}) {
    EngineSnapshot release;
    if (!windows_key(vk, modifiers, true, &english) ||
        !windows_key(vk, 0, false, &release) || !release.commit_text.empty()) return 1;
  }
  bool exact_case = english.composition == "HeLlo";
  for (const auto& candidate : english.candidates)
    exact_case = exact_case || candidate.text == "HeLlo";
  if (!exact_case) {
    std::cerr << "English discarded Shift/Caps capitalization"; return 1;
  }
  // The shared English schema uses good_old_caps_lock: Caps letters are direct
  // host input rather than schema composition, with Shift inverting their case.
  for (const auto modifiers : {caps, shift | caps}) {
    if (!engine.Configure(session, "english", false, false, false, &error)) return 1;
    core::KeyEvent event;
    event.virtual_key = 'L';
    event.modifiers = modifiers;
    event.event_flags = static_cast<std::uint32_t>(core::KeyEventFlags::kKeyDown);
    const auto translated = broker::TranslateWindowsKey(event);
    EngineSnapshot direct;
    if (!translated || translated->keycode != (modifiers == caps ? 'L' : 'l') ||
        !windows_key('L', modifiers, true, &direct) || direct.handled ||
        !direct.commit_text.empty()) {
      std::cerr << "English Caps direct input changed"; return 1;
    }
    if (!windows_key('L', 0, false, &direct) || !direct.commit_text.empty()) return 1;
  }
  std::cout << "Windows printable keys passed: question/slash, Shift release, English case\n";
  // ascii_composer returns kNoop for both Shift phases even when release
  // commits existing raw input. A successful process_key call alone cannot
  // prove that the resulting text was collected promptly.
  for (const auto* schema : {"rime_ice", "double_pinyin", "double_pinyin_flypy", "wubi86", "english"}) {
    if (!engine.Configure(session, schema, false, false, false, &error)) return 1;
    const std::string code = std::string(schema) == "wubi86" ? "wq" : "ni";
    EngineSnapshot before;
    for (const char key : code)
      if (!engine.ProcessKey(session, key, 0, &before, &error)) return 1;
    EngineSnapshot down, up;
    if (!engine.ProcessKey(session, 0xffe1, 1, &down, &error) ||
        !engine.ProcessKey(session, 0xffe1, released, &up, &error) ||
        down.handled || up.handled || up.commit_text != code || up.composing) {
      std::cerr << "Shift raw-code snapshot lost: " << schema
                << " commit=" << up.commit_text; return 1;
    }
    EngineSnapshot ascii;
    if (!engine.ProcessKey(session, 'a', 0, &ascii, &error) || ascii.handled ||
        !ascii.commit_text.empty()) {
      std::cerr << "Shift mode did not pass ASCII through cleanly: " << schema; return 1;
    }
  }
  std::cout << "Product Shift raw-code and ASCII passthrough passed\n";

  for (const auto side : {0xffe1, 0xffe2}) {
    if (!engine.Configure(session, "my_combo", false, false, false, &error)) return 1;
    EngineSnapshot composed;
    for (const char key : {'d', 'v', 'i'})
      if (!engine.ProcessKey(session, key, 0, &composed, &error)) return 1;
    for (const char key : {'v', 'd', 'i'})
      if (!engine.ProcessKey(session, key, released, &composed, &error)) return 1;
    if (!engine.ProcessShiftTap(session, side, released, &composed, &error) ||
        composed.handled || !composed.modifier_snapshot ||
        composed.commit_text != "ni" || composed.composing) {
      std::cerr << "Chord qualified Shift tap lost raw code: " << side
                << " commit=" << composed.commit_text << " error=" << error; return 1;
    }
  }
  std::cout << "Both product chord Shift styles passed\n";
  // Leave the isolated engine's default schema in Chinese before opening
  // real BrokerConnection sessions. The direct frames exercise negotiation
  // without modifying pipe authentication or registering an input method.
  if (!engine.Configure(session, "rime_ice", false, false, false, &error)) return 1;
  engine.DestroySession(session);
  for (const auto capabilities : {0ULL, core::kModifierSnapshotsCapability}) {
    broker::BrokerConnection connection(0, &engine);
    std::uint32_t request_id = 1;
    auto exchange = [&](core::MessageType type, std::vector<std::byte> payload,
                        core::Frame* response) {
      core::Frame frame;
      frame.header.message_type = type;
      frame.header.request_id = request_id++;
      frame.payload = std::move(payload);
      return connection.Handle(frame, GetCurrentProcessId(), response) ==
             broker::ClientAction::kContinue;
    };
    core::Frame response;
    std::vector<std::byte> payload;
    core::ClientHello hello{GetCurrentProcessId(), 0, capabilities, "ProductProbe"};
    core::BrokerHello broker_hello;
    if (!core::EncodeClientHello(hello, &payload) ||
        !exchange(core::MessageType::kClientHello, std::move(payload), &response) ||
        !core::DecodeBrokerHello(response.payload, &broker_hello) ||
        !(broker_hello.capabilities & core::kModifierSnapshotsCapability)) return 1;
    core::InputSessionOpened opened;
    if (!core::EncodeOpenInputSession({1, {}}, &payload) ||
        !exchange(core::MessageType::kOpenInputSession, std::move(payload), &response) ||
        !core::DecodeInputSessionOpened(response.payload, &opened)) return 1;
    std::uint64_t sequence = 1;
    auto key = [&](std::uint32_t vk, std::uint32_t flags, std::uint32_t modifiers,
                   core::InputState* state) {
      core::KeyEvent event;
      event.session_id = opened.session_id;
      event.sequence_id = sequence++;
      event.virtual_key = vk;
      event.event_flags = flags;
      event.modifiers = modifiers;
      return core::EncodeKeyEvent(event, &payload) &&
             exchange(core::MessageType::kKeyEvent, std::move(payload), &response) &&
             core::DecodeInputState(response.payload, state);
    };
    constexpr auto down = static_cast<std::uint32_t>(core::KeyEventFlags::kKeyDown);
    constexpr auto tap = static_cast<std::uint32_t>(core::KeyEventFlags::kShiftTap);
    constexpr auto modifier_state = static_cast<std::uint32_t>(core::InputStateFlags::kModifierSnapshot);
    core::InputState state;
    if (!key('N', down, 0, &state) || !key('I', down, 0, &state) ||
        state.composition.empty()) return 1;
    if (capabilities == 0) {
      // The old client has neither the new flag nor a Shift gesture contract.
      if (!key(VK_LSHIFT, down, shift, &state) || state.state_flags != 0 ||
          !key(VK_LSHIFT, 0, 0, &state) || state.state_flags != 0 ||
          !state.commit_text.empty()) {
        std::cerr << "Legacy client received a new modifier snapshot"; return 1;
      }
      // Even an unnegotiated gesture must not arm the engine.
      if (!key(VK_LSHIFT, tap, 0, &state) || state.state_flags != 0 ||
          !key('H', down, 0, &state) || !key('A', down, 0, &state) ||
          !key('O', down, 0, &state) || !key(VK_SPACE, down, 0, &state) ||
          state.commit_text != "你好") {
        std::cerr << "Legacy Shift modified the new Broker's input session"; return 1;
      }
    } else {
      if (!key(VK_LSHIFT, tap, 0, &state) ||
          state.state_flags != modifier_state || state.commit_text != "ni" ||
          !key('A', down, 0, &state) || state.state_flags != 0 ||
          !state.commit_text.empty()) {
        std::cerr << "Negotiated Shift tap failed its real Broker snapshot contract"; return 1;
      }
    }
    if (!core::EncodeCloseInputSession({opened.session_id}, &payload) ||
        !exchange(core::MessageType::kCloseInputSession, std::move(payload), &response)) return 1;
  }
  std::cout << "Real Broker legacy/new client capability negotiation passed\n";
  return 0;
}
