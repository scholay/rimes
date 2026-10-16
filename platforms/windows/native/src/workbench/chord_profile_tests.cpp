#include "chord_profile.hpp"
#include <iostream>
#include <stdexcept>

using namespace rimes::windows::workbench;
using rimes::windows::core::Json;
namespace {
void Check(bool ok, const char *reason) {
  if (!ok)
    throw std::runtime_error(reason);
}
void Reject(const Json &value) {
  bool rejected = false;
  try {
    (void)ChordProfile::Parse(value);
  } catch (...) {
    rejected = true;
  }
  Check(rejected, "malformed or unsupported keymap must be rejected");
}
} // namespace
int main() {
  try {
    const auto source = BuiltinChordProfile();
    const auto p = ChordProfile::Parse(source);
    Check(p.name == "isaac2026" && p.Find("ivd") &&
              p.Find("ivd")->output == "ni",
          "portable built-in mapping and name");
    Check(!p.Find("dvi!"),
          "unknown keys cannot silently select another mapping");
    for (const auto &m : p.mappings)
      Check(p.Find(m.keys) != nullptr, "all built-in combinations resolve");
    auto invalid = source;
    invalid["mappings"].push_back(invalid["mappings"].front());
    Reject(invalid);
    invalid = source;
    invalid["leftKeys"] = "aa";
    Reject(invalid);
    invalid = source;
    invalid["mappings"][0]["output"] = "n;exit";
    Reject(invalid);
    invalid = source;
    invalid["mappings"][0]["keys"] = "dd";
    Reject(invalid);
    invalid = source;
    invalid["nativeSchemeID"] = "custom";
    Reject(invalid);
    invalid = source;
    invalid["outputEncoding"] = "ziranma";
    Reject(invalid);
    invalid = source;
    invalid["formatVersion"] = 2;
    Reject(invalid);
    invalid = source;
    invalid["name"] = std::string("name\0tail", 9);
    Reject(invalid);
    ChordComposer composer;
    Check(composer.Key(p, 'd', true, 0, 50).handled, "first down is owned");
    Check(composer.Key(p, 'v', true, 20, 50).text.empty(),
          "chord waits for physical release");
    Check(composer.Key(p, 'd', true, 30, 50).text.empty(), "repeat is ignored");
    Check(composer.Key(p, 'd', false, 35, 50).text.empty(),
          "partial release does not settle");
    auto out = composer.Key(p, 'v', false, 40, 50);
    Check(out.text == "n'" && !out.replace,
          "left fragment uses legacy batch boundary");
    composer.Key(p, 'i', true, 60, 50);
    out = composer.Key(p, 'i', false, 65, 50);
    Check(out.replace && out.raw == "ni'" && out.text == "i",
          "adjacent right batch replaces only owned preedit; fallback stays "
          "available");
    Check(!composer.Key(p, 'i', false, 70, 50).handled,
          "late release cannot duplicate a chord");
    composer.Reset();
    composer.Key(p, 'd', true, 0, 50);
    composer.Key(p, 'v', true, 10, 50);
    composer.Key(p, 'i', true, 20, 50);
    composer.Key(p, 'v', false, 30, 50);
    composer.Key(p, 'd', false, 35, 50);
    out = composer.Key(p, 'i', false, 40, 50);
    Check(out.text == "ni'" && !out.replace,
          "simultaneous full syllable needs no rewrite");
    composer.Reset();
    composer.Key(p, 'd', true, 0, 50);
    composer.Key(p, 'v', true, 10, 50);
    Check(composer.Pending(), "batch is pending before context switch");
    composer.Reset();
    Check(!composer.Key(p, 'v', false, 30, 50).handled && !composer.Pending(),
          "context reset drops delayed old releases");
    composer.Key(p, 'i', true, 40, 50);
    out = composer.Key(p, 'i', false, 45, 50);
    Check(out.text == "i" && !out.replace,
          "new context cannot pair with old left keys");
    composer.Reset();
    composer.Key(p, 'd', true, 0, 50);
    out = composer.Key(p, 'v', true, 100, 50);
    Check(out.text == "d" && composer.Pending(),
          "interval splits non-simultaneous batches");
    auto explicit_source = source;
    explicit_source["boundaryPolicy"] = "explicitSyllables";
    const auto explicit_profile = ChordProfile::Parse(explicit_source);
    composer.Reset();
    composer.Key(explicit_profile, 'd', true, 0, 50);
    composer.Key(explicit_profile, 'v', true, 10, 50);
    out = composer.Flush(explicit_profile);
    Check(out.text == "n",
          "explicit boundaries preserve fragments without a separator");
    composer.RevokePair();
    composer.Key(explicit_profile, 'i', true, 20, 50);
    composer.Key(explicit_profile, 'd', false, 30, 50);
    composer.Key(explicit_profile, 'v', false, 31, 50);
    out = composer.Key(explicit_profile, 'i', false, 32, 50);
    Check(!out.replace, "selection or external edit revokes adjacent rewrite");
    std::cout << "isaac2026 keymap validation, physical batches, interval, "
                 "pairing and revocation passed\n";
    return 0;
  } catch (const std::exception &e) {
    std::cerr << e.what() << '\n';
    return 1;
  }
}
