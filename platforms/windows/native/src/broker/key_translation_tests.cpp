#include "key_translation.hpp"

#include <cstdlib>
#include <iostream>

namespace rimes::windows::broker::tests {
namespace {

int g_failures = 0;

#define EXPECT(condition)                                                     \
  do {                                                                        \
    if (!(condition)) {                                                       \
      std::cerr << __FILE__ << ':' << __LINE__ << ": expectation failed: "   \
                << #condition << '\n';                                        \
      ++g_failures;                                                           \
    }                                                                         \
  } while (false)

constexpr std::uint32_t Flag(core::KeyModifiers value) {
  return static_cast<std::uint32_t>(value);
}

constexpr std::uint32_t Flag(core::KeyEventFlags value) {
  return static_cast<std::uint32_t>(value);
}

core::KeyEvent Key(std::uint32_t virtual_key) {
  core::KeyEvent key;
  key.session_id = 1;
  key.sequence_id = 1;
  key.virtual_key = virtual_key;
  key.event_flags = Flag(core::KeyEventFlags::kKeyDown);
  return key;
}

void TestLettersAndModifiers() {
  core::KeyEvent key = Key(0x41);
  key.modifiers = Flag(core::KeyModifiers::kShift) |
                  Flag(core::KeyModifiers::kCapsLock) |
                  Flag(core::KeyModifiers::kControl);
  const auto translated = TranslateWindowsKey(key);
  EXPECT(translated.has_value());
  EXPECT(translated->keycode == 'a');
  EXPECT(translated->modifiers == ((1 << 0) | (1 << 1) | (1 << 2)));
}

void TestSpecialAndExtendedKeys() {
  EXPECT(TranslateWindowsKey(Key(0x08))->keycode == 0xff08);
  EXPECT(TranslateWindowsKey(Key(0x70))->keycode == 0xffbe);
  EXPECT(TranslateWindowsKey(Key(0x87))->keycode == 0xffd5);
  EXPECT(TranslateWindowsKey(Key(0xba))->keycode == ';');

  core::KeyEvent keypad_enter = Key(0x0d);
  keypad_enter.event_flags |= Flag(core::KeyEventFlags::kExtended);
  EXPECT(TranslateWindowsKey(keypad_enter)->keycode == 0xff8d);
}

void TestRealKeyUpCarriesReleaseMask() {
  core::KeyEvent key_up = Key(0x41);
  key_up.event_flags = 0;
  const auto translated = TranslateWindowsKey(key_up);
  EXPECT(translated.has_value());
  EXPECT(translated->keycode == 'a');
  EXPECT((translated->modifiers & (1 << 30)) != 0);
}

void TestAltGrFailsOpen() {
  core::KeyEvent key = Key(0x45);
  key.modifiers = Flag(core::KeyModifiers::kAltGr) |
                  Flag(core::KeyModifiers::kControl) |
                  Flag(core::KeyModifiers::kAlt);
  EXPECT(!TranslateWindowsKey(key).has_value());
  EXPECT(!IsLikelyHandledForTest(key, true));
}

void TestNonMutatingPrediction() {
  core::KeyEvent letter = Key(0x52);
  letter.event_flags |= Flag(core::KeyEventFlags::kTestOnly);
  EXPECT(IsLikelyHandledForTest(letter, false));

  core::KeyEvent space = Key(0x20);
  space.event_flags |= Flag(core::KeyEventFlags::kTestOnly);
  EXPECT(!IsLikelyHandledForTest(space, false));
  EXPECT(IsLikelyHandledForTest(space, true));

  letter.modifiers = Flag(core::KeyModifiers::kWindows);
  EXPECT(!IsLikelyHandledForTest(letter, true));
}

}  // namespace

int RunKeyTranslationTests() {
  TestLettersAndModifiers();
  TestSpecialAndExtendedKeys();
  TestRealKeyUpCarriesReleaseMask();
  TestAltGrFailsOpen();
  TestNonMutatingPrediction();
  return g_failures == 0 ? EXIT_SUCCESS : EXIT_FAILURE;
}

}  // namespace rimes::windows::broker::tests

#if defined(RIMES_KEY_TRANSLATION_TEST_MAIN)
int main() {
  return rimes::windows::broker::tests::RunKeyTranslationTests();
}
#endif
