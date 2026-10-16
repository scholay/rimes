#include <cstdlib>
#include <iostream>
#include <atomic>
#include <filesystem>

#include "runtime.hpp"
#include "official_features.hpp"
#include "../core/buffer_keys.hpp"
using namespace rimes::windows;
void Check(bool ok, const char* reason) {
  if (!ok) {
    std::cerr << reason << '\n';
    std::exit(1);
  }
}
void TestTargets() {
  workbench::Runtime runtime;
  const auto peer = GetCurrentProcessId() + 1;
  auto target = runtime.Register(peer, 1, 1);
  runtime.Focus(target);
  runtime.Toggle(peer);
  Check(runtime.Capturing(target), "explicit binding captures input");
  engine::EngineSnapshot text;
  text.handled = true;
  text.commit_text = "First. ";
  runtime.Capture(target, &text);
  text.commit_text = "Second.";
  runtime.Capture(target, &text);
  Check(text.commit_text.empty(), "captured input does not leak into host");
  runtime.Send(false);
  auto event = runtime.Control({{"op", "wait"}, {"session", 1}}, peer);
  if (event.value("kind", "") == "capture")
    event = runtime.Control({{"op", "wait"}, {"session", 1}}, peer);
  Check(event.value("kind", "") == "deliver",
        "separate notification carries delivery");
  Check(runtime.Snapshot()["source"] == "First. Second.",
        "sending does not consume");
  auto foreign = runtime.Control({{"op", "ack"},
                                  {"session", 1},
                                  {"request", event["request"]},
                                  {"accepted", true}},
                                 peer + 1);
  Check(foreign["kind"] == "disconnected",
        "foreign process cannot acknowledge");
  runtime.Control({{"op", "ack"},
                   {"session", 1},
                   {"request", event["request"]},
                   {"accepted", true}},
                  peer);
  Check(runtime.Snapshot()["source"] == "Second.",
        "actual host acceptance consumes only first block");
  runtime.Control({{"op", "ack"},
                   {"session", 1},
                   {"request", event["request"]},
                   {"accepted", true}},
                  peer);
  Check(runtime.Snapshot()["source"] == "Second.",
        "duplicate ack does not consume again");
  core::KeyEvent key;
  key.virtual_key = VK_RETURN;
  key.event_flags = static_cast<unsigned>(core::KeyEventFlags::kKeyDown);
  Check(runtime.BeforeKey(target, key, false), "Return down owned");
  key.event_flags = static_cast<unsigned>(core::KeyEventFlags::kKeyDown) |
                    static_cast<unsigned>(core::KeyEventFlags::kRepeat);
  Check(runtime.BeforeKey(target, key, false), "Return repeat owned");
  key.event_flags = 0;
  Check(runtime.BeforeKey(target, key, false), "Return up owned");
  auto other = runtime.Register(peer, 2, 2);
  runtime.Focus(other);
  Check(!runtime.Capturing(target) && !runtime.Capturing(other),
        "focus change pauses without automatic retarget");
  Check(runtime.Snapshot()["target_pid"] == 0,
        "paused snapshot never advertises the saved target as bound");
  runtime.Bind(peer + 2);
  Check(!runtime.Capturing(other), "background target cannot bind from a tray");
  runtime.Focus(other);
  runtime.Bind(peer);
  Check(runtime.Capturing(other), "source click explicitly binds the new field");
  runtime.Bind(peer);
  Check(runtime.Capturing(other) && runtime.Snapshot()["visible"] == true,
        "repeated source clicks keep capture open instead of toggling closed");
  runtime.Remove(other);
  runtime.Bind(peer);
  Check(!runtime.Snapshot()["capture"].get<bool>() &&
            runtime.Snapshot()["target_pid"] == 0,
        "removed context cannot be revived by a click");
  auto own = runtime.Register(GetCurrentProcessId(), 3, 3);
  runtime.Focus(own);
  runtime.Bind(GetCurrentProcessId());
  Check(!runtime.Capturing(own), "settings window never becomes a Buffer target");
  runtime.Close();
  Check(runtime.Snapshot()["source"] == "Second.", "close retains content");
  runtime.Protect();
  Check(!runtime.Snapshot()["visible"].get<bool>(),
        "locked session hides Buffer");
  runtime.Stop();
  std::cout << "Runtime target/control/Return tests passed\n";
}

template <typename Predicate> void Wait(Predicate predicate, const char* reason) {
  const auto start = GetTickCount64();
  while (!predicate() && GetTickCount64() - start < 3000) Sleep(2);
  Check(predicate(), reason);
}
void TestCommandModifiersDoNotBecomeBufferCommands() {
  workbench::Runtime runtime;
  const auto peer = GetCurrentProcessId() + 1;
  const auto target = runtime.Register(peer, 20, 20);
  runtime.Focus(target); runtime.Bind(peer); runtime.Paste("First. Second.");
  for (const auto modifier : {core::KeyModifiers::kControl,
                             core::KeyModifiers::kAlt,
                             core::KeyModifiers::kWindows,
                             core::KeyModifiers::kAltGr}) {
    for (const auto extra : {0U, static_cast<unsigned>(core::KeyModifiers::kShift)}) {
      for (const auto virtual_key : {VK_RETURN, VK_BACK, VK_ESCAPE}) {
        if (virtual_key == VK_RETURN && modifier == core::KeyModifiers::kAlt && extra)
          continue;  // This exact chord is deliberately a Buffer send action.
        core::KeyEvent key;
        key.virtual_key = static_cast<std::uint32_t>(virtual_key);
        key.modifiers = static_cast<unsigned>(modifier) | extra;
        key.event_flags = static_cast<unsigned>(core::KeyEventFlags::kKeyDown);
        Check(!runtime.BeforeKey(target, key, false), "modified command down must pass through");
        key.event_flags |= static_cast<unsigned>(core::KeyEventFlags::kRepeat);
        Check(!runtime.BeforeKey(target, key, false), "modified command repeat must pass through");
        key.event_flags = 0;
        Check(!runtime.BeforeKey(target, key, false), "modified command release must pass through");
        const auto state = runtime.Snapshot();
        Check(state["source"] == "First. Second." && state["result"] == "" &&
              state["capture"] == true && state["visible"] == true &&
              state["status"] == "Buffer", "host shortcut cannot send, edit, or close Buffer");
      }
    }
  }
  // A modified press must not acquire the release after its modifier is gone.
  core::KeyEvent released;
  released.virtual_key = VK_RETURN;
  runtime.BeforeKey(target, released, false);
  Check(runtime.Snapshot()["status"] == "Buffer", "unowned plain release must not deliver");
  runtime.Stop();
}
void TestUnhandledModifierCommitIsCapturedWithoutChangingKeyOwnership() {
  workbench::Runtime runtime;
  const auto peer = GetCurrentProcessId() + 1;
  const auto target = runtime.Register(peer, 26, 26);
  runtime.Focus(target); runtime.Bind(peer);
  engine::EngineSnapshot preedit;
  preedit.handled = true;
  preedit.composing = true;
  preedit.composition = "ni";
  runtime.Capture(target, &preedit);
  Check(runtime.Snapshot()["source"] == "" && runtime.Snapshot()["preedit"] == "ni",
        "uncommitted engine composition is only the Buffer preedit");
  // ascii_composer can commit raw code on a qualified Shift tap while librime
  // still reports that physical modifier as unhandled. The broker's modifier
  // snapshot path supplies this commit without acquiring host key ownership.
  engine::EngineSnapshot modifier;
  modifier.handled = false;
  modifier.commit_text = "ni";
  runtime.Capture(target, &modifier);
  Check(runtime.Snapshot()["source"] == "ni" && runtime.Snapshot()["preedit"] == "" &&
        modifier.commit_text.empty() && !modifier.handled && !modifier.composing,
        "modifier commit enters Buffer once without leaking text or consuming the host key");
  runtime.Capture(target, &modifier);
  Check(runtime.Snapshot()["source"] == "ni" && !modifier.handled,
        "the cleared snapshot cannot append or deliver the same modifier commit twice");
  runtime.Stop();
}
void CheckPausedShiftDoesNotProcessOrChangeDraft(workbench::Runtime& runtime,
                                               workbench::Target target) {
  const auto before = runtime.Snapshot();
  for (const auto virtual_key : {VK_SHIFT, VK_LSHIFT, VK_RSHIFT}) {
    for (const bool composing : {false, true}) {
      core::KeyEvent key;
      key.virtual_key = static_cast<std::uint32_t>(virtual_key);
      key.modifiers = static_cast<unsigned>(core::KeyModifiers::kShift);
      for (const auto flags : {
               static_cast<unsigned>(core::KeyEventFlags::kKeyDown),
               static_cast<unsigned>(core::KeyEventFlags::kKeyDown) |
                   static_cast<unsigned>(core::KeyEventFlags::kRepeat),
               0U}) {
        key.event_flags = flags;
        key.modifiers = flags ? static_cast<unsigned>(core::KeyModifiers::kShift) : 0U;
        // This result stops engine processing. The broker separately preserves
        // physical Shift pass-through; forwarding it to librime could commit
        // raw preedit into a full draft or an immutable pending result.
        Check(runtime.BeforeKey(target, key, composing),
              "paused Buffer must block Shift engine processing");
        const auto after = runtime.Snapshot();
        for (const auto* field : {"source", "result", "source_blocks", "result_blocks",
                                  "preedit", "preview", "busy", "translate", "uncertain",
                                  "capture", "visible", "target_pid"})
          Check(after[field] == before[field],
                "blocked Shift must retain source, results, preedit, and target");
      }
    }
  }
}
void TestFullBufferBlocksShiftWithoutChangingDraft() {
  workbench::Runtime runtime;
  const auto peer = GetCurrentProcessId() + 1;
  const auto target = runtime.Register(peer, 27, 27);
  runtime.Focus(target); runtime.Bind(peer);
  engine::EngineSnapshot preedit;
  preedit.handled = true; preedit.composing = true; preedit.composition = "ni";
  runtime.Capture(target, &preedit);
  runtime.Paste(std::string(workbench::Model::kLimit, 'x'));
  Check(runtime.Snapshot()["source"].get<std::string>().size() == workbench::Model::kLimit,
        "the full-draft fixture reaches the production capacity");
  CheckPausedShiftDoesNotProcessOrChangeDraft(runtime, target);
  runtime.Stop();
}
void TestPendingResultBlocksShiftAndRetainsOriginalAcknowledgement() {
  std::atomic<unsigned> calls{0};
  workbench::Runtime runtime([&](const workbench::Settings&, const workbench::Generation&,
      const std::function<bool(const std::string&)>& chunk,
      const std::function<bool()>&, std::string*) {
    ++calls;
    return chunk("Translated output.");
  });
  const auto peer = GetCurrentProcessId() + 1;
  const auto target = runtime.Register(peer, 28, 28);
  runtime.Focus(target); runtime.Bind(peer); runtime.Paste("原文。");
  runtime.Generate(true);
  Wait([&] { return runtime.Snapshot()["result"] == "Translated output."; },
       "the pending-result fixture receives a completed translation");
  engine::EngineSnapshot preedit;
  preedit.handled = true; preedit.composing = true; preedit.composition = "ni";
  runtime.Capture(target, &preedit);
  runtime.Send(false);
  auto delivery = runtime.Control({{"op", "wait"}, {"session", 28}}, peer);
  if (delivery.value("kind", "") == "capture")
    delivery = runtime.Control({{"op", "wait"}, {"session", 28}}, peer);
  Check(delivery["kind"] == "deliver" && delivery["text"] == "Translated output.",
        "the pending-result fixture issues exactly the reviewed result");
  CheckPausedShiftDoesNotProcessOrChangeDraft(runtime, target);
  runtime.Control({{"op", "ack"}, {"session", 28}, {"request", delivery["request"]},
                   {"accepted", true}}, peer);
  const auto accepted = runtime.Snapshot();
  Check(accepted["source"] == "" && accepted["result"] == "" &&
        accepted["status"] == "Delivered" && calls == 1,
        "blocked Shift retains the original result request and linked source for its ack");
  runtime.Control({{"op", "ack"}, {"session", 28}, {"request", delivery["request"]},
                   {"accepted", true}}, peer);
  Check(runtime.Snapshot() == accepted,
        "the original result ack still consumes exactly once after blocked Shift");
  runtime.Stop();
}
void TestOwnedSendKeepsItsLifecycleAcrossModifierChanges() {
  workbench::Runtime runtime;
  const auto peer = GetCurrentProcessId() + 1;
  const auto target = runtime.Register(peer, 21, 21);
  runtime.Focus(target); runtime.Bind(peer); runtime.Paste("First. Second.");
  core::KeyEvent key;
  key.virtual_key = VK_RETURN;
  key.modifiers = core::ShortcutModifiers(MOD_ALT | MOD_SHIFT);
  key.event_flags = static_cast<unsigned>(core::KeyEventFlags::kKeyDown);
  Check(runtime.BeforeKey(target, key, false), "send chord press is owned");
  key.modifiers = static_cast<unsigned>(core::KeyModifiers::kControl);
  key.event_flags |= static_cast<unsigned>(core::KeyEventFlags::kRepeat);
  Check(runtime.BeforeKey(target, key, false), "owned Return repeat survives modifier change");
  Check(runtime.Snapshot()["status"] == "Buffer", "repeat cannot send a block early");
  key.event_flags = 0;
  Check(runtime.BeforeKey(target, key, false), "owned Return release survives modifier change");
  auto delivery = runtime.Control({{"op", "wait"}, {"session", 21}}, peer);
  if (delivery.value("kind", "") == "capture")
    delivery = runtime.Control({{"op", "wait"}, {"session", 21}}, peer);
  Check(delivery["kind"] == "deliver" && delivery["text"] == "First. ",
        "owned Return sends exactly the first block");
  runtime.Control({{"op", "ack"}, {"session", 21}, {"request", delivery["request"]},
                   {"accepted", true}}, peer);
  Check(runtime.Snapshot()["source"] == "Second.", "ack consumes exactly one owned block");
  key.modifiers = 0;
  runtime.BeforeKey(target, key, false);
  Check(runtime.Snapshot()["status"] == "Delivered" &&
        runtime.Snapshot()["source"] == "Second.", "late release cannot deliver the remainder");
  runtime.Stop();
}
void TestAltShiftReturnTapHoldAndComposition() {
  workbench::Runtime runtime;
  const auto peer = GetCurrentProcessId() + 1;
  const auto target = runtime.Register(peer, 30, 30);
  runtime.Focus(target); runtime.Bind(peer);
  auto commit = [&](const char* value) {
    engine::EngineSnapshot snapshot;
    snapshot.commit_text = value;
    runtime.Capture(target, &snapshot);
  };
  commit("一"); commit("二"); commit("三");
  core::KeyEvent key;
  key.virtual_key = VK_RETURN;
  key.modifiers = core::ShortcutModifiers(MOD_ALT | MOD_SHIFT);
  key.event_flags = static_cast<unsigned>(core::KeyEventFlags::kKeyDown);
  Check(core::IsBufferSendChord(VK_RETURN, key.modifiers), "TSF and Broker recognize the same Alt+Shift+Enter chord");
  Check(runtime.BeforeKey(target, key, false), "Alt+Shift+Enter down owned");
  key.modifiers = 0; key.event_flags = 0;
  Check(runtime.BeforeKey(target, key, false), "modifier released first does not lose the owned Return up");
  auto take = [&] {
    auto event = runtime.Control({{"op", "wait"}, {"session", 30}}, peer);
    if (event.value("kind", "") == "capture")
      event = runtime.Control({{"op", "wait"}, {"session", 30}}, peer);
    Check(event.value("kind", "") == "deliver", "send gesture emits a delivery");
    return event;
  };
  auto ack = [&](const core::Json& delivery) {
    runtime.Control({{"op", "ack"}, {"session", 30}, {"request", delivery["request"]},
                     {"accepted", true}}, peer);
  };
  auto first = take();
  Check(first["text"] == "一", "Alt+Shift+Enter tap sends one commit block");
  ack(first);
  Check(runtime.Snapshot()["source"] == "二三", "tap keeps unsent suffix");
  key.modifiers = core::ShortcutModifiers(MOD_ALT | MOD_SHIFT);
  key.event_flags = static_cast<unsigned>(core::KeyEventFlags::kKeyDown);
  runtime.BeforeKey(target, key, false);
  Sleep(1250); runtime.Tick();
  auto second = take();
  Check(second["text"] == "二", "held Alt+Shift+Enter starts ordered drain");
  ack(second); auto third = take();
  Check(third["text"] == "三", "hold advances only after the previous ack");
  ack(third);
  key.event_flags = 0; runtime.BeforeKey(target, key, false);
  Check(runtime.Snapshot()["source"] == "", "hold key-up cannot send twice");
  commit("保留");
  key.event_flags = static_cast<unsigned>(core::KeyEventFlags::kKeyDown);
  Check(!runtime.BeforeKey(target, key, true), "composing chord is left to Rime settlement");
  key.event_flags |= static_cast<unsigned>(core::KeyEventFlags::kRepeat);
  runtime.BeforeKey(target, key, false);
  key.event_flags = 0; runtime.BeforeKey(target, key, false);
  Check(runtime.Snapshot()["source"] == "保留" && runtime.Snapshot()["status"] != "Sending...",
        "settling composition never arms a send on the same physical press");
  runtime.Close();
  key.event_flags = static_cast<unsigned>(core::KeyEventFlags::kKeyDown);
  Check(!runtime.BeforeKey(target, key, false), "closed Buffer leaves Alt+Shift+Enter with the host");
  runtime.Stop();
}
void TestTranslationModeArmsAutomaticSentencePipeline() {
  std::atomic<unsigned> calls{0};
  workbench::Runtime runtime([&](const workbench::Settings&, const workbench::Generation& job,
      const std::function<bool(const std::string&)>& chunk,
      const std::function<bool()>&, std::string*) {
    ++calls;
    Check(job.translation && job.source == "完整句。", "automatic job freezes the complete sentence");
    return chunk("A sentence.");
  });
  const auto peer = GetCurrentProcessId() + 1;
  const auto target = runtime.Register(peer, 31, 31);
  runtime.Focus(target); runtime.Bind(peer);
  runtime.SelectTranslationMode();
  Check(runtime.Snapshot()["translate"] == true && calls == 0,
        "selecting Translation arms the empty workspace without a Generate click");
  runtime.Paste("完整句"); Sleep(850); runtime.Tick();
  Check(calls == 0, "unfinished sentence is not prematurely translated");
  runtime.Paste("。"); Sleep(850); runtime.Tick();
  Wait([&] { return runtime.Snapshot()["result"] == "A sentence."; },
       "completed input automatically produces a translation");
  runtime.Paste("完整句。"); runtime.PauseCapture();
  Sleep(850); runtime.Tick();
  Check(calls == 1, "paused capture cannot start new automatic network work");
  runtime.ReturnToInput(); runtime.Bind(peer); runtime.Tick();
  Check(calls == 1 && runtime.Snapshot()["translate"] == false,
        "returning to input disarms automatic translation");
  runtime.Stop();
}
void TestConfiguredSendAndCancellation() {
  workbench::Runtime runtime;
  const auto original = runtime.Configuration();
  auto config = original;
  config.send_key = VK_F8; config.send_modifiers = MOD_CONTROL | MOD_SHIFT;
  Check(runtime.Configure(config, {}, false, nullptr), "save custom send chord");
  const auto peer = GetCurrentProcessId() + 1;
  const auto target = runtime.Register(peer, 37, 37);
  runtime.Focus(target); runtime.Bind(peer); runtime.Paste("First. Second.");
  auto capture = runtime.Control({{"op", "wait"}, {"session", 37}}, peer);
  Check(capture["sendKey"] == VK_F8 && capture["sendModifiers"] == (MOD_CONTROL | MOD_SHIFT),
        "the exact saved shortcut travels with capture notifications to TSF prediction");
  core::KeyEvent key;
  key.virtual_key = VK_RETURN;
  key.event_flags = static_cast<unsigned>(core::KeyEventFlags::kKeyDown);
  Check(runtime.BeforeKey(target, key, false), "ordinary Enter stays in Buffer");
  key.event_flags = 0; runtime.BeforeKey(target, key, false);
  Check(runtime.Snapshot()["status"] == "Buffer", "ordinary Enter cannot send staged blocks");
  key.modifiers = core::ShortcutModifiers(MOD_ALT | MOD_SHIFT);
  key.event_flags = static_cast<unsigned>(core::KeyEventFlags::kKeyDown);
  Check(!runtime.BeforeKey(target, key, false), "replaced default chord is no longer intercepted");
  key.virtual_key = VK_F8;
  key.modifiers = core::ShortcutModifiers(config.send_modifiers);
  Check(runtime.IsSendChord(key) && runtime.BeforeKey(target, key, false), "custom non-Enter key arms delivery");
  key.modifiers = 0; key.event_flags = 0;
  Check(runtime.BeforeKey(target, key, false), "custom physical release is owned after modifiers lift");
  auto delivery = runtime.Control({{"op", "wait"}, {"session", 37}}, peer);
  Check(delivery["kind"] == "deliver" && delivery["text"] == "First. ", "custom tap sends one block");
  runtime.Control({{"op", "ack"}, {"session", 37}, {"request", delivery["request"]}, {"accepted", true}}, peer);
  for (const bool configure : {false, true}) {
    key.modifiers = core::ShortcutModifiers(config.send_modifiers);
    key.event_flags = static_cast<unsigned>(core::KeyEventFlags::kKeyDown);
    Check(runtime.BeforeKey(target, key, false), "arm next custom gesture");
    if (configure) Check(runtime.Configure(config, {}, false, nullptr), "configuration cancels the held gesture");
    else runtime.Focus({});
    runtime.Focus(target); runtime.Bind(peer);
    Sleep(1250); runtime.Tick();
    key.event_flags = 0;
    runtime.BeforeKey(target, key, false);
    Check(runtime.Snapshot()["source"] == "Second." && runtime.Snapshot()["status"] != "Sending...",
          "returning to the same target never revives a cancelled hold");
  }
  key.modifiers = core::ShortcutModifiers(config.send_modifiers);
  key.event_flags = static_cast<unsigned>(core::KeyEventFlags::kKeyDown);
  Check(!runtime.BeforeKey(target, key, true), "composing custom chord requests Rime settlement only");
  key.event_flags |= static_cast<unsigned>(core::KeyEventFlags::kRepeat);
  Check(runtime.BeforeKey(target, key, false), "composition-settling repeat remains owned");
  key.event_flags = 0; runtime.BeforeKey(target, key, false);
  Check(runtime.Snapshot()["source"] == "Second." && runtime.Snapshot()["status"] != "Sending...",
        "custom settling key cannot deliver on the same release");
  Check(runtime.Configure(original, {}, false, nullptr), "restore isolated configuration");
}
void TestOpeningGeometryIsBoundToOneExactSummon() {
  workbench::Runtime runtime;
  const auto peer = GetCurrentProcessId() + 1;
  const auto target = runtime.Register(peer, 32, 32);
  runtime.Focus(target); runtime.Bind(peer);
  auto geometry = [&] {
    return core::Json{{"op", "geometry"}, {"session", 32}, {"context", 32},
        {"openingRevision", runtime.Snapshot()["opening_revision"]},
        {"caret", {400, 500, 0, 22}}};
  };
  auto request = geometry();
  Check(runtime.Control(request, peer + 1)["kind"] == "disconnected" &&
        !runtime.PlacementCaret(target), "foreign process cannot supply opening geometry");
  request["context"] = 33;
  Check(runtime.Control(request, peer)["kind"] == "stale", "geometry cannot cross TSF contexts");
  request = geometry(); request["caret"] = {0, 0, 0, 0};
  Check(runtime.Control(request, peer)["kind"] == "error", "dummy zero caret does not move Buffer");
  request = geometry();
  Check(runtime.Control(request, peer)["kind"] == "ok" &&
        runtime.PlacementCaret(target) == workbench::BufferRect{400, 500, 0, 22},
        "fresh zero-width TSF caret is valid");
  const auto placed = runtime.Snapshot()["placement_revision"];
  Check(runtime.Control(request, peer)["kind"] == "stale" &&
        runtime.Snapshot()["placement_revision"] == placed,
        "each summon accepts geometry once, never follows typing");
  runtime.Bind(peer);
  Check(!runtime.PlacementCaret(target) && runtime.Control(request, peer)["kind"] == "stale",
        "a new summon cannot reuse the last opening's geometry");
  runtime.CancelOpeningPlacement(); request = geometry();
  Check(runtime.Control(request, peer)["kind"] == "stale",
        "manual dragging defeats a late opening reply");
  runtime.Bind(peer); request = geometry(); runtime.Paste("typed before geometry arrived");
  Check(runtime.Control(request, peer)["kind"] == "stale", "late geometry cannot jump the panel after typing");
  runtime.Bind(peer); request = geometry();
  const auto other = runtime.Register(peer, 33, 33);
  runtime.Focus(other);
  Check(runtime.Control(request, peer)["kind"] == "stale" && !runtime.PlacementCaret(target),
        "same-process focus change revokes old opening geometry");
  runtime.Stop();
}
void TestPluginAuthority() {
  std::atomic<unsigned> calls{0}, completed{0};
  std::atomic<bool> hold{false}, release{false}, accepted{false}, correct_instruction{false};
  workbench::Runtime runtime([&](const workbench::Settings&, const workbench::Generation& job,
      const std::function<bool(const std::string&)>& chunk, const std::function<bool()>& cancelled, std::string*) {
    ++calls;
    correct_instruction = job.instruction.find("English") != std::string::npos;
    if (hold) {
      const auto start = GetTickCount64();
      while (!release && GetTickCount64() - start < 2500) Sleep(2);
    }
    accepted = chunk("First. Second.");
    const bool ok = accepted && !cancelled();
    ++completed;
    return ok;
  });
  const auto peer = GetCurrentProcessId() + 1;
  const auto target = runtime.Register(peer, 10, 10);
  runtime.Focus(target); runtime.Bind(peer); runtime.Paste("第一句。第二句。");
  runtime.Generate(false);
  Check(!runtime.Snapshot()["busy"].get<bool>() && calls == 0, "absent optional plugin cannot dispatch a network job");
  runtime.Generate(true);
  Wait([&] { return !runtime.Snapshot()["busy"].get<bool>(); }, "translation completion");
  Check(calls == 1 && correct_instruction && runtime.Snapshot()["result"] == "First. Second.", "verified package supplies runtime instructions");
  std::string error;
  Check(runtime.ManagePlugin(official::kTranslation, "disable", &error), "disable completed plugin");
  Check(runtime.Snapshot()["result"] == "" && runtime.Snapshot()["source"] == "第一句。第二句。", "disable clears old result and retains source");
  Check(runtime.ManagePlugin(official::kTranslation, "enable", &error), "reenable translation");
  hold = true; runtime.Generate(true);
  Wait([&] { return calls == 2; }, "in-flight mock started");
  Check(runtime.ManagePlugin(official::kTranslation, "disable", &error), "disable during generation");
  Check(runtime.ManagePlugin(official::kTranslation, "enable", &error), "re-enable during generation");
  release = true;
  Wait([&] { return completed == 2; }, "late callback completed");
  Check(!accepted && runtime.Snapshot()["result"] == "", "re-enable cannot authorize an old in-flight callback");
  runtime.Stop();
  // Destructor joins the test transport; its callback must reject the stale
  // grant even though the exact same package has already been re-enabled.
}
void TestReturningToInputRejectsLateResultsAndDropsQueuedTranslation() {
  std::atomic<unsigned> calls{0}, completed{0};
  std::atomic<bool> release{false}, stale_cancelled{false}, stale_accepted{false};
  workbench::Runtime runtime([&](const workbench::Settings&, const workbench::Generation&,
      const std::function<bool(const std::string&)>& chunk,
      const std::function<bool()>& cancelled, std::string*) {
    ++calls;
    chunk("Partial output.");
    while (!release) Sleep(2);
    stale_cancelled = cancelled();
    stale_accepted = chunk("Late output.");
    ++completed;
    return true;
  });
  const auto peer = GetCurrentProcessId() + 1;
  const auto target = runtime.Register(peer, 22, 22);
  runtime.Focus(target); runtime.Bind(peer); runtime.Paste("第一句。第二句。");
  runtime.Generate(true);
  Wait([&] { return calls == 1 && runtime.Snapshot()["status"] == "Receiving..."; },
       "fake translation starts streaming");
  runtime.ReturnToInput();
  Check(!runtime.Snapshot()["translate"].get<bool>() && !runtime.Snapshot()["busy"].get<bool>() &&
        runtime.Snapshot()["status"] == "Processing stopped. Source retained.",
        "returning to input stops automatic translation and retires generation");
  // A second explicit request queues behind the first provider. A subsequent
  // mode selection must cancel that queue before the provider can dispatch it.
  runtime.Generate(true);
  Check(runtime.Snapshot()["busy"] == true && calls == 1,
        "second translation is queued");
  runtime.ReturnToInput();
  Check(runtime.Snapshot()["status"] == "Processing stopped. Source retained.",
        "cancelled queued work no longer claims to be waiting for a response");
  release = true;
  Wait([&] { return completed == 1; }, "stale fake provider returns");
  Sleep(850); runtime.Tick(); Sleep(50);
  const auto state = runtime.Snapshot();
  Check(calls == 1 && stale_cancelled && !stale_accepted,
        "mode switch drops queued work and rejects stale provider callbacks");
  Check(state["source"] == "第一句。第二句。" && state["result"] == "" &&
        state["preview"] == "" && state["busy"] == false && state["translate"] == false &&
        state["status"] == "Processing stopped. Source retained." &&
        state["capture"] == true && state["visible"] == true,
        "returning to input retains the draft and binding without restarting requests");
  runtime.Stop();
  runtime.ReturnToInput();
  Check(runtime.Snapshot()["status"] == "Buffer reset" &&
        runtime.Snapshot()["source"] == "" && runtime.Snapshot()["result"] == "",
        "mode selection cannot revive content discarded by IME shutdown");
}
void TestReturningToInputRetainsCompletedResultsAndAnIssuedDelivery() {
  std::atomic<unsigned> calls{0};
  workbench::Runtime runtime([&](const workbench::Settings&, const workbench::Generation&,
      const std::function<bool(const std::string&)>& chunk,
      const std::function<bool()>&, std::string*) {
    ++calls;
    return chunk("Translated output.");
  });
  const auto peer = GetCurrentProcessId() + 1;
  const auto target = runtime.Register(peer, 23, 23);
  runtime.Focus(target); runtime.Bind(peer); runtime.Paste("原文。");
  runtime.Generate(true);
  Wait([&] { return runtime.Snapshot()["result"] == "Translated output."; }, "completed result arrives");
  runtime.ReturnToInput();
  Check(runtime.Snapshot()["source"] == "原文。" &&
        runtime.Snapshot()["result"] == "Translated output." &&
        runtime.Snapshot()["status"] == "Ready",
        "mode selection cannot discard reviewed unsubmitted output");
  Sleep(850); runtime.Tick();
  Check(calls == 1 && runtime.Snapshot()["translate"] == false,
        "selecting input does not resume or start automatic requests");
  runtime.Send(false);
  auto delivery = runtime.Control({{"op", "wait"}, {"session", 23}}, peer);
  if (delivery.value("kind", "") == "capture")
    delivery = runtime.Control({{"op", "wait"}, {"session", 23}}, peer);
  Check(delivery["kind"] == "deliver" && delivery["text"] == "Translated output.",
        "retained result is delivered only by explicit Send");
  runtime.ReturnToInput();
  Check(runtime.Snapshot()["source"] == "原文。" &&
        runtime.Snapshot()["result"] == "Translated output." &&
        runtime.Snapshot()["status"] == "Sending...", "mode switch preserves issued delivery metadata");
  runtime.Paste("Rejected edit.");
  core::KeyEvent pending_backspace;
  pending_backspace.virtual_key = VK_BACK;
  pending_backspace.event_flags = static_cast<unsigned>(core::KeyEventFlags::kKeyDown);
  runtime.BeforeKey(target, pending_backspace, false);
  Check(runtime.Snapshot()["source"] == "原文。" &&
        runtime.Snapshot()["result"] == "Translated output.",
        "editing cannot alter an already-issued result delivery or its linked source");
  runtime.Control({{"op", "ack"}, {"session", 23}, {"request", delivery["request"]},
                   {"accepted", true}}, peer);
  Check(runtime.Snapshot()["source"] == "" && runtime.Snapshot()["result"] == "" &&
        runtime.Snapshot()["status"] == "Delivered", "the original ack consumes the issued result exactly once");
  runtime.Control({{"op", "ack"}, {"session", 23}, {"request", delivery["request"]},
                   {"accepted", true}}, peer);
  Check(runtime.Snapshot()["source"] == "" && runtime.Snapshot()["result"] == "",
        "duplicate ack after selection cannot repeat delivery");
  runtime.Stop();
}
void TestReturningToInputInvalidatesReadyResultOnRealEdit() {
  for (const bool backspace : {false, true}) {
    std::atomic<unsigned> calls{0};
    workbench::Runtime runtime([&](const workbench::Settings&, const workbench::Generation&,
        const std::function<bool(const std::string&)>& chunk,
        const std::function<bool()>&, std::string*) {
      ++calls;
      return chunk("Reviewed output.");
    });
    const auto peer = GetCurrentProcessId() + 1;
    const std::uint64_t session = backspace ? 25 : 24;
    const auto target = runtime.Register(peer, session, session);
    runtime.Focus(target); runtime.Bind(peer); runtime.Paste("原文。尾");
    runtime.Generate(true);
    Wait([&] { return runtime.Snapshot()["result"] == "Reviewed output."; },
         "completed output arrives before changing mode");
    runtime.ReturnToInput();
    Check(runtime.Snapshot()["result"] == "Reviewed output.",
          "changing mode alone keeps the reviewed result");
    if (backspace) {
      core::KeyEvent key;
      key.virtual_key = VK_BACK;
      key.event_flags = static_cast<unsigned>(core::KeyEventFlags::kKeyDown);
      Check(runtime.BeforeKey(target, key, false), "plain Backspace edits the bound source");
    } else {
      runtime.Paste("追加");
    }
    const auto state = runtime.Snapshot();
    Check(state["source"] == (backspace ? "原文。" : "原文。尾追加") &&
          state["result"] == "" && state["preview"] == "" &&
          state["translate"] == false && state["busy"] == false,
          "a real input-mode edit invalidates old result and linked translation state");
    runtime.Send(false);
    auto delivery = runtime.Control({{"op", "wait"}, {"session", session}}, peer);
    if (delivery.value("kind", "") == "capture")
      delivery = runtime.Control({{"op", "wait"}, {"session", session}}, peer);
    Check(delivery["kind"] == "deliver" && delivery["text"] == "原文。" && calls == 1,
          "Send after editing uses current source without requesting or sending old output");
    runtime.Stop();
  }
}
void TestChordFallback() {
  workbench::Runtime runtime;
  auto settings = runtime.Configuration(); settings.schema = "my_combo";
  std::string error;
  Check(runtime.Configure(settings, L"", false, &error), "save chord selection");
  Check(runtime.Configuration().schema == "my_combo", "enabled chord selected");
  Check(runtime.ManagePlugin(official::kChord, "disable", &error), "disable chord");
  Check(runtime.Configuration().schema == "rime_ice", "disabled chord falls back to full pinyin");
  Check(runtime.ManagePlugin(official::kChord, "enable", &error), "re-enable chord");
  Check(runtime.Configuration().schema == "my_combo", "re-enable preserves the saved choice");
}
void TestExplicitOpeningPlacementRevision() {
  workbench::Runtime runtime;
  const auto peer = GetCurrentProcessId() + 1;
  const auto target = runtime.Register(peer, 901, 902);
  Check(!runtime.PlacementTarget(), "hidden buffer has no geometry authority");
  runtime.Focus(target);
  runtime.Bind(peer);
  const auto first = runtime.Snapshot()["opening_revision"].get<std::uint64_t>();
  Check(first > 0 && runtime.PlacementTarget() == target,
        "explicit opening publishes its exact live target");
  runtime.PublishCaret({300, 240, 301, 258}); runtime.PublishCaret({340, 240, 341, 258});
  auto geometry_event = runtime.Control({{"op", "wait"}, {"session", 901}}, peer);
  if (geometry_event["kind"] == "capture") geometry_event = runtime.Control({{"op", "wait"}, {"session", 901}}, peer);
  Check(geometry_event["kind"] == "buffer_caret" && geometry_event["rect"][0] == 340 &&
        geometry_event["context"] == 902 && geometry_event["openingRevision"] == first,
        "Buffer caret updates coalesce and retain exact session/context/opening identity");
  runtime.Paste("Synthetic geometry test.");
  Check(runtime.Snapshot()["opening_revision"] == first,
        "ordinary content updates cannot reposition a manually placed buffer");
  runtime.PauseCapture();
  Check(!runtime.PlacementTarget(), "paused capture cannot probe an old input target");
  runtime.Bind(peer);
  Check(runtime.Snapshot()["opening_revision"] == first + 1,
        "explicit rebind creates a fresh opening placement");
  const auto other = runtime.Register(peer, 903, 904);
  runtime.Focus(other);
  Check(!runtime.PlacementTarget(), "new context revokes old placement target");
  runtime.Close();
  Check(!runtime.PlacementTarget(), "closed buffer has no placement target");
}
void TestCodexConnectorAndReturn() {
  std::atomic<unsigned> calls{0};
  std::atomic<bool> release{false}, cancelled_old{false};
  workbench::Runtime runtime([&](const workbench::Settings& config, const workbench::Generation& job,
      const std::function<bool(const std::string&)>& chunk,
      const std::function<bool()>& cancelled, std::string*) {
    Check(config.ai_connector == "codex-cli" &&
        job.plugin_id == (job.translation ? official::kTranslation : official::kCodex) &&
        !job.plugin_grant.empty() && job.connector_id == official::kCodex && !job.connector_grant.empty(), "Codex selected and granted");
    ++calls;
    while (!release && !cancelled()) Sleep(2);
    if (cancelled()) { cancelled_old = true; return false; }
    return chunk("Generated only.");
  });
  auto config = runtime.Configuration();
  Check(workbench::SelectConnection(&config, "codex"), "select saved Codex profile");
  config.translation_provider = "ai";
  Check(runtime.Configure(config, {}, false, nullptr), "save Codex configuration");
  const auto peer = GetCurrentProcessId() + 1;
  const auto target = runtime.Register(peer, 950, 951);
  runtime.Focus(target); runtime.Bind(peer); runtime.Paste("Original request."); runtime.SelectAIMode();
  core::KeyEvent key; key.virtual_key = VK_RETURN;
  key.modifiers = core::ShortcutModifiers(MOD_ALT | MOD_SHIFT);
  key.event_flags = static_cast<unsigned>(core::KeyEventFlags::kKeyDown);
  Check(runtime.BeforeKey(target, key, false), "AI Return requests generation");
  Wait([&] { return calls == 1; }, "first Codex job issued");
  release = true;
  Wait([&] { return runtime.Snapshot()["result"] == "Generated only."; }, "fake CLI result ready");
  key.event_flags = 0; Check(runtime.BeforeKey(target, key, false), "generation key-up owned");
  Check(runtime.Snapshot()["status"] == "Ready" && runtime.Snapshot()["source"] == "Original request.", "generation press never sends on release");
  key.event_flags = static_cast<unsigned>(core::KeyEventFlags::kKeyDown); runtime.BeforeKey(target, key, false);
  key.event_flags = 0; runtime.BeforeKey(target, key, false);
  auto event = runtime.Control({{"op", "wait"}, {"session", 950}}, peer);
  if (event["kind"] == "capture") event = runtime.Control({{"op", "wait"}, {"session", 950}}, peer);
  Check(event["kind"] == "deliver" && event["text"] == "Generated only.", "second Return sends result, not request");
  runtime.Control({{"op", "ack"}, {"session", 950}, {"request", event["request"]}, {"accepted", true}}, peer);
  Check(runtime.Snapshot()["source"] == "" && runtime.Snapshot()["result"] == "", "final accepted result consumes frozen source");
  release = false; runtime.Paste("Another request."); runtime.Generate(false);
  Wait([&] { return calls == 2; }, "next Codex job started");
  runtime.Close(); Wait([&] { return cancelled_old.load(); }, "close cancels producer");
  Check(runtime.Snapshot()["result"] == "" && runtime.Snapshot()["source"] == "Another request.", "close cannot publish stale result or lose request");
  runtime.Bind(peer);
  Check(runtime.ManagePlugin(official::kCodex, "disable", nullptr), "disable connector");
  runtime.Generate(true);
  Check(!runtime.Snapshot().value("busy", false) && calls == 2, "translation cannot bypass a disabled connector");
  Check(runtime.ManagePlugin(official::kCodex, "enable", nullptr), "enable connector");
  release = true; runtime.Generate(true);
  Wait([&] { return runtime.Snapshot()["result"] == "Generated only."; }, "translation uses selected Codex connector");
  Check(runtime.ManagePlugin(official::kCodex, "disable", nullptr), "revoke completed connector result");
  Check(runtime.Snapshot()["result"] == "" && runtime.Snapshot()["source"] == "Another request.", "connector revocation rejects completed results from another plugin owner");
  runtime.Stop();
}
void TestDisposableMaintenanceContent() {
  workbench::Runtime runtime;
  const auto peer = GetCurrentProcessId() + 1;
  const auto target = runtime.Register(peer, 995, 1);
  runtime.Focus(target); runtime.Bind(peer); runtime.Paste("Disposable Buffer.");
  runtime.Send(true);
  runtime.DiscardBuffer();
  auto state = runtime.Snapshot();
  Check(state["source"] == "" && state["result"] == "" &&
            !runtime.Capturing(target),
        "explicit redeployment reset discards Buffer without a content gate");
  auto event = runtime.Control({{"op", "wait"}, {"session", 995}}, peer);
  Check(event.value("kind", "") == "capture",
        "reset replaces a queued delivery with revoked capture authority");
  runtime.Focus(target); runtime.Bind(peer); runtime.Paste("Next session.");
  runtime.Stop();
  state = runtime.Snapshot();
  Check(state["source"] == "" && state["result"] == "",
        "IME shutdown discards temporary UI content instead of preserving it");
}
void TestNativeShortcutAutoSendAndCopy() {
  workbench::Runtime runtime([](const workbench::Settings&, const workbench::Generation&,
      const auto& chunk, const auto&, std::string*) { return chunk("Answer. Second."); });
  auto fixture_config = workbench::Settings{}; fixture_config.close_after_send = false;
  Check(runtime.Configure(fixture_config, {}, false, nullptr), "reset fixture preferences");
  const auto peer = GetCurrentProcessId() + 1;
  const auto target = runtime.Register(peer, 998, 999);
  runtime.Focus(target); runtime.Bind(peer); runtime.Paste("One. Two.");
  auto next_event = [&] {
    auto event = runtime.Control({{"op", "wait"}, {"session", 998}}, peer);
    while (event.value("kind", "") == "capture" || event.value("kind", "") == "buffer_caret")
      event = runtime.Control({{"op", "wait"}, {"session", 998}}, peer);
    return event;
  };
  auto acknowledge = [&](const core::Json& event) {
    Check(event.value("kind", "") == "deliver", "native path enqueues TSF delivery");
    runtime.Control({{"op", "ack"}, {"session", 998}, {"request", event.at("request")}, {"accepted", true}}, peer);
  };
  Check(!runtime.ShortcutDown(peer + 1), "global shortcut rejects foreign foreground process");
  Check(runtime.ShortcutDown(peer) && !runtime.Snapshot()["pending"].get<bool>(), "global key-down defers send until release or configured 1.2-second hold");
  runtime.ShortcutUp(); auto event = next_event(); Check(event["text"] == "One. ", "tap sends first block"); acknowledge(event);
  Check(runtime.Snapshot()["source"] == "Two.", "tap retains unsent suffix");
  runtime.Paste(" Three."); Check(runtime.ShortcutDown(peer), "second gesture starts");
  Sleep(1250); runtime.Tick(); runtime.ShortcutUp();
  event = next_event(); acknowledge(event); event = next_event(); acknowledge(event);
  Check(runtime.Snapshot()["source"] == "", "configured 1.2-second hold drains exactly the frozen blocks");
  runtime.Paste("Automatic."); runtime.SetAutoSend(1, true); runtime.Tick();
  Check(runtime.Snapshot()["auto_remaining_ms"].get<long long>() > 0, "automatic send exposes countdown");
  runtime.PauseCapture(); Sleep(1020); runtime.Tick(); Check(!runtime.Snapshot()["pending"].get<bool>(), "focus pause cancels countdown delivery");
  runtime.Bind(peer); runtime.Tick(); Check(!runtime.Snapshot()["pending"].get<bool>(), "rebind restarts full countdown");
  Sleep(1020); runtime.Tick(); event = next_event(); acknowledge(event);
  Check(!runtime.Snapshot()["visible"].get<bool>(), "close-after-send waits for final acknowledgement");
  auto copy_config = fixture_config; copy_config.ai_connector = "codex-cli";
  Check(runtime.Configure(copy_config, {}, false, nullptr), "use bundled fixture connector");
  runtime.Bind(peer); runtime.Paste("Request."); runtime.Generate(false);
  Wait([&] { return runtime.Snapshot()["result"] == "Answer. Second."; }, "copy fixture generated");
  auto ticket = runtime.PrepareCopy(); Check(!ticket.is_null() && runtime.ValidateCopy(ticket), "complete result copy freezes identity and text");
  Check(!runtime.CommitCopy(ticket, [] { return false; }) && runtime.Snapshot()["visible"] == true,
        "clipboard write failure does not close or consume Buffer");
  runtime.Paste("Edit."); Check(!runtime.ValidateCopy(ticket), "editing invalidates old clipboard ticket");
  runtime.Generate(false); Wait([&] { return runtime.Snapshot()["result"] == "Answer. Second."; }, "copy fixture regenerated");
  ticket = runtime.PrepareCopy(); Check(runtime.CommitCopy(ticket, [] { return true; }), "copy write committed atomically");
  Check(!runtime.Snapshot()["capture"].get<bool>() && !runtime.Snapshot()["visible"].get<bool>() &&
        runtime.Snapshot()["result"] == "Answer. Second.", "successful result copy pauses and hides while retaining session contents");
  Check(runtime.Configure(fixture_config, {}, false, nullptr), "restore fixture connector");
}
int main() {
  const auto root = std::filesystem::temp_directory_path() /
      (L"rimes-runtime-test-" + std::to_wstring(GetCurrentProcessId()) + L"-" + std::to_wstring(GetTickCount64()));
  std::filesystem::create_directories(root);
  Check(SetEnvironmentVariableW(L"LOCALAPPDATA", root.c_str()) != 0, "isolated runtime preferences");
  auto fixture = workbench::Settings{}; fixture.close_after_send = false;
  TestTargets();
  Check(workbench::SaveSettings(fixture, nullptr), "retain Buffer for multi-step runtime fixtures");
  TestNativeShortcutAutoSendAndCopy();
  TestDisposableMaintenanceContent();
  TestExplicitOpeningPlacementRevision();
  TestCommandModifiersDoNotBecomeBufferCommands();
  TestUnhandledModifierCommitIsCapturedWithoutChangingKeyOwnership();
  TestFullBufferBlocksShiftWithoutChangingDraft();
  TestPendingResultBlocksShiftAndRetainsOriginalAcknowledgement();
  TestOwnedSendKeepsItsLifecycleAcrossModifierChanges();
  TestAltShiftReturnTapHoldAndComposition();
  TestConfiguredSendAndCancellation();
  TestTranslationModeArmsAutomaticSentencePipeline();
  TestOpeningGeometryIsBoundToOneExactSummon();
  TestPluginAuthority();
  TestReturningToInputRejectsLateResultsAndDropsQueuedTranslation();
  TestReturningToInputRetainsCompletedResultsAndAnIssuedDelivery();
  TestReturningToInputInvalidatesReadyResultOnRealEdit();
  TestChordFallback();
  TestCodexConnectorAndReturn();
  std::filesystem::remove_all(root);
  std::cout << "Runtime plugin authority and chord fallback tests passed\n";
}
