#include "runtime.hpp"
#include "local_translation.hpp"
#include "official_features.hpp"
#include "../core/buffer_keys.hpp"

#include <algorithm>
#include <chrono>
namespace rimes::windows::workbench {
using core::Json;
Runtime::Runtime(APIGenerator generate) : generate_(std::move(generate)) {
  std::string error;
  settings_valid_ = LoadSettings(&settings_, &error);
  if (!settings_valid_) model_.status = error;
  api_worker_ = std::jthread([this] { RunAPI(); });
}
Runtime::~Runtime() {
  Stop();
  if (api_worker_.joinable()) api_worker_.join();
  if (plugin_worker_.joinable()) plugin_worker_.join();
}
void Runtime::Changed() {
  if (notify_) notify_();
}
void Runtime::SetNotify(std::function<void()> notify) {
  std::lock_guard lock(mutex_);
  notify_ = std::move(notify);
}
bool Runtime::Stopping() {
  std::lock_guard lock(mutex_);
  return stopping_;
}
Target Runtime::Register(std::uint32_t process, std::uint64_t session,
                         std::uint64_t context) {
  std::lock_guard lock(mutex_);
  Target target{process, session, context};
  sessions_.emplace(session, Entry{target, {}});
  return target;
}
void Runtime::Remove(Target target) {
  std::lock_guard lock(mutex_);
  model_.Revoke(target);
  sessions_.erase(target.session);
  CaptureChanged();
  event_.notify_all();
  Changed();
}
void Runtime::Focus(Target target) {
  std::lock_guard lock(mutex_);
  if (target.process == GetCurrentProcessId()) target = {};
  model_.Focus(target);
  CaptureChanged();
  Changed();
}
bool Runtime::Capturing(Target target) {
  std::lock_guard lock(mutex_);
  return model_.capture && model_.bound == target && model_.live == target;
}
bool Runtime::IsSendChord(const core::KeyEvent& key) {
  std::lock_guard lock(mutex_);
  return core::IsBufferSendChord(key.virtual_key, key.modifiers,
                                  settings_.send_key, settings_.send_modifiers);
}
void Runtime::CaptureChanged() {
  // A focus/configuration/visibility transition cancels delivery, including
  // leaving and returning to the same target before the held key is released.
  return_sent_ = true;
  auto_since_ = 0;
  clipboard_action_ = 0;
  buffer_caret_ = {};
  for (auto& [id, entry] : sessions_) {
    (void)id;
    // Replace obsolete capture notifications but never replace a delivery.
    std::erase_if(entry.events, [](const Json& e) {
      return e.value("kind", "") == "capture";
    });
    entry.events.push_back(
        {{"kind", "capture"},
         {"context", entry.target.context},
         {"openingRevision", opening_revision_},
         {"font", settings_.font_size},
         {"candidateWidth", settings_.candidate_width}, {"candidateHeight", settings_.candidate_height},
         {"candidateLabelSize", settings_.candidate_label_size},
         {"verticalCandidates", settings_.vertical_candidates},
         {"theme", EffectiveTheme(settings_)},
         {"sendKey", settings_.send_key},
         {"sendModifiers", settings_.send_modifiers},
         {"enabled", model_.capture && model_.bound == entry.target &&
                         model_.live == entry.target}});
  }
  event_.notify_all();
}
void Runtime::Queue(const std::optional<Delivery>& delivery) {
  if (!delivery) return;
  auto found = sessions_.find(delivery->target.session);
  if (found == sessions_.end()) {
    model_.LostAcknowledgement();
    return;
  }
  found->second.events.push_back({{"kind", "deliver"},
                                  {"request", delivery->request},
                                  {"context", delivery->target.context},
                                  {"text", delivery->block.text}});
  pending_since_ = GetTickCount64();
  event_.notify_all();
  Changed();
}
bool Runtime::BeforeKey(Target target, const core::KeyEvent& key,
                        bool composing) {
  std::lock_guard lock(mutex_);
  const bool down = (key.event_flags &
                     static_cast<unsigned>(core::KeyEventFlags::kKeyDown)) != 0;
  if (return_held_ && key.virtual_key == return_key_ &&
      return_target_ == target) {
    if (!down) {
      if (!return_sent_ && model_.capture && model_.bound == target)
        Queue(SendAuthorized(GetTickCount64() - pressed_at_ >= settings_.send_hold_ms));
      return_held_ = false;
    }
    return true;
  }
  const bool send = core::IsBufferSendChord(key.virtual_key, key.modifiers,
                                            settings_.send_key, settings_.send_modifiers);
  const auto modifiers = key.modifiers & ~static_cast<unsigned>(core::KeyModifiers::kCapsLock);
  if (model_.capture && model_.bound == target && model_.live == target &&
      modifiers == static_cast<unsigned>(core::KeyModifiers::kControl) &&
      (key.virtual_key == 'A' || key.virtual_key == 'V' || key.virtual_key == 'C')) {
    if (down && !composing) {
      if (key.virtual_key == 'A') model_.SelectAll();
      else { clipboard_action_ = key.virtual_key; clipboard_target_ = target; }
      Changed();
    }
    return true;
  }
  if (core::HasHostCommandModifier(key.modifiers) && !send) return false;
  if (!model_.capture || model_.bound != target || model_.live != target)
    return false;
  if (!composing && !core::HasHostCommandModifier(key.modifiers) &&
      (key.virtual_key == VK_LEFT || key.virtual_key == VK_RIGHT ||
       key.virtual_key == VK_HOME || key.virtual_key == VK_END || key.virtual_key == VK_DELETE)) {
    if (down) {
      if (key.virtual_key == VK_DELETE) model_.DeleteForward();
      else if (key.virtual_key == VK_HOME) model_.SetInsertion(0);
      else if (key.virtual_key == VK_END) model_.SetInsertion(model_.source.size());
      else model_.MoveInsertion(key.virtual_key == VK_LEFT ? -1 : 1);
      Changed();
    }
    return true;
  }
  if (!send && key.virtual_key != VK_ESCAPE && key.virtual_key != VK_RETURN &&
      key.virtual_key != VK_BACK &&
      (model_.SourceText().size() > Model::kLimit - core::kMaxCommitTextBytes ||
       (model_.Pending() && !model_.result.empty()))) {
    model_.status =
        "Buffer is full or a result is being delivered. Input paused.";
    Changed();
    return true;
  }
  if (!send && key.virtual_key == VK_ESCAPE) {
    if (down) {
      model_.Close();
      CaptureChanged();
      Changed();
    }
    return true;
  }
  if (!send && key.virtual_key == VK_BACK && !composing) {
    if (down) {
      model_.Backspace();
      edited_at_ = GetTickCount64();
      Changed();
    }
    return true;
  }
  if (send) {
    if (down && !(key.event_flags &
                  static_cast<unsigned>(core::KeyEventFlags::kRepeat))) {
      return_held_ = true;
      return_key_ = key.virtual_key;
      return_sent_ = composing;
      pressed_at_ = GetTickCount64();
      return_target_ = target;
      // Settle composition through Rime, then suppress repeats/release for
      // this physical press even when the configured key is not Enter.
      if (composing) return false;
      if ((ai_mode_ || model_.translate) && (model_.busy || model_.result.empty())) {
        // Generation owns this entire press. Never send the retained source
        // on key-up/hold, even if the connector finishes during that press.
        return_sent_ = true;
        if (!model_.busy) StartGeneration(model_.translate);
      }
    }
    return true;
  }
  // Ordinary Return only settles composition. It cannot send or submit the
  // host field while Buffer owns input; sending uses the configured chord.
  if (key.virtual_key == VK_RETURN && !composing) return true;
  return false;
}
void Runtime::Capture(Target target, engine::EngineSnapshot* snapshot,
                      bool direct_input) {
  std::lock_guard lock(mutex_);
  if (!model_.capture || model_.bound != target || model_.live != target)
    return;
  if (ai_mode_ && (!snapshot->composition.empty() || !snapshot->commit_text.empty()) &&
      (model_.busy || !model_.result.empty())) model_.ReturnToEdit();
  model_.preedit = snapshot->composition;
  preedit_caret_ = snapshot->caret_utf16;
  if (!snapshot->commit_text.empty()) {
    if (!model_.Append(snapshot->commit_text,
                       direct_input ? InputKind::kDirect : InputKind::kCommit))
      throw std::runtime_error("Buffer capacity invariant");
    snapshot->commit_text.clear();
    edited_at_ = GetTickCount64();
  }
  Changed();
}
Json Runtime::Control(const Json& message, std::uint32_t process) {
  std::unique_lock lock(mutex_);
  const auto id = message.value("session", 0ULL);
  auto found = sessions_.find(id);
  if (found == sessions_.end() || found->second.target.process != process)
    return {{"kind", "disconnected"}};
  const auto target = found->second.target;
  const auto op = message.value("op", "");
  if (op == "geometry") {
    // Geometry is presentation only, and only an answer to this explicit
    // opening from its authenticated exact session can reposition the panel.
    const auto rect = message.find("caret");
    if (!opening_at_ || GetTickCount64() - opening_at_ > 1000 || opening_caret_ ||
        !model_.visible || !model_.capture || model_.bound != target || model_.live != target ||
        model_.revision != opening_source_revision_ || !model_.preedit.empty() ||
        message.value("context", 0ULL) != target.context ||
        message.value("openingRevision", 0ULL) != opening_revision_ ||
        rect == message.end() || !rect->is_array() || rect->size() != 4 ||
        !std::all_of(rect->begin(), rect->end(), [](const Json& n) { return n.is_number(); }))
      return {{"kind", "stale"}};
    BufferRect caret{(*rect)[0].get<double>(), (*rect)[1].get<double>(),
                     (*rect)[2].get<double>(), (*rect)[3].get<double>()};
    if (!FiniteBufferRect(caret) || std::abs(caret.x) > 1000000 ||
        std::abs(caret.y) > 1000000 || caret.width < 0 || caret.width > 2000 ||
        caret.height <= 2 || caret.height >= 600) return {{"kind", "error"}};
    opening_caret_ = caret;
    ++placement_revision_;
    Changed();
    return {{"kind", "ok"}};
  }
  if (op == "focus") {
    model_.Focus(target.process == GetCurrentProcessId() ? Target{} : target);
    CaptureChanged();
    Changed();
    return {{"kind", "ok"}};
  }
  if (op == "ack") {
    CheckPluginAuthorization();
    const bool was_pending = model_.Pending();
    Queue(model_.Acknowledge(message.value("request", 0ULL), target,
                             message.value("accepted", false)));
    CheckPluginAuthorization();
    if (was_pending && settings_.close_after_send && !model_.Pending() && !model_.busy &&
        model_.source.empty() && model_.result.empty() && model_.preedit.empty()) {
      model_.Close(); CaptureChanged();
    }
    Changed();
    return {{"kind", "ok"}};
  }
  if (op == "wait") {
    event_.wait_for(lock, std::chrono::seconds(10), [&] {
      auto i = sessions_.find(id);
      return stopping_ || i == sessions_.end() || !i->second.events.empty();
    });
    found = sessions_.find(id);
    if (stopping_ || found == sessions_.end())
      return {{"kind", "disconnected"}};
    if (found->second.events.empty()) return {{"kind", "heartbeat"}};
    Json value = std::move(found->second.events.front());
    found->second.events.pop_front();
    return value;
  }
  return {{"kind", "error"}};
}
Json Runtime::Snapshot() {
  std::lock_guard lock(mutex_);
  Json source = Json::array(), result = Json::array();
  for (const auto& b : model_.source)
    source.push_back({{"id", b.id}, {"text", b.text}});
  for (const auto& b : model_.result)
    result.push_back({{"id", b.id}, {"text", b.text}});
  return {{"source_blocks", source},
          {"result_blocks", result},
          {"visible", model_.visible},
          {"capture", model_.capture},
          {"busy", model_.busy},
          {"uncertain", model_.uncertain},
          {"source", model_.SourceText()},
          {"result", model_.ResultText()},
          {"preview", model_.preview},
          {"preedit", model_.preedit},
          {"preedit_caret", preedit_caret_},
          {"insertion", model_.insertion},
          {"selected", model_.selected},
          {"revision", model_.revision},
          {"generation", model_.GenerationID()},
          {"pending", model_.Pending()},
          {"complete_result", model_.CompleteResult()},
          {"mode", ai_mode_ ? 1 : model_.translate ? 2 : 0},
          {"auto_send_seconds", settings_.auto_send_seconds},
          {"close_after_send", settings_.close_after_send},
          {"auto_remaining_ms", auto_since_ && settings_.auto_send_seconds
              ? (std::max)(0LL, static_cast<long long>(settings_.auto_send_seconds * 1000ULL) -
                  static_cast<long long>(GetTickCount64() - auto_since_)) : 0LL},
          {"status", model_.status},
          {"translate", model_.translate},
          {"opening_revision", opening_revision_},
          {"placement_revision", placement_revision_},
          {"target_pid", model_.capture && model_.bound == model_.live
                             ? model_.bound.process : 0}};
}
Target Runtime::PlacementTarget() {
  std::lock_guard lock(mutex_);
  const auto found = sessions_.find(model_.live.session);
  if (!model_.visible || !model_.capture || model_.bound != model_.live ||
      found == sessions_.end() || found->second.target != model_.bound) return {};
  return model_.bound;
}
std::optional<BufferRect> Runtime::PlacementCaret(Target target) {
  std::lock_guard lock(mutex_);
  if (!target || !model_.capture || !model_.visible || model_.bound != target ||
      model_.live != target || model_.revision != opening_source_revision_ ||
      !model_.preedit.empty()) return {};
  return opening_caret_;
}
void Runtime::CancelOpeningPlacement() {
  std::lock_guard lock(mutex_);
  opening_at_ = 0;
  opening_caret_.reset();
}
void Runtime::SetImportedSchema(std::string schema) {
  std::lock_guard lock(mutex_); imported_schema_ = std::move(schema);
}
std::uint64_t Runtime::ConfigurationRevision() { std::lock_guard lock(mutex_); return settings_.revision; }
void Runtime::AppearanceChanged() { std::lock_guard lock(mutex_); CaptureChanged(); Changed(); }
Settings Runtime::Configuration() {
  std::lock_guard lock(mutex_);
  auto effective = settings_;
  if (effective.schema == official::kChordSchema && plugins_.Grant(official::kChord).empty()) effective.schema = "rime_ice";
  if (!imported_schema_.empty()) { effective.schema = imported_schema_; effective.imported_scheme = true; }
  return effective;
}
bool Runtime::Configure(Settings value, const std::wstring& key,
                        bool replace_key, std::string* error, const std::map<std::string, std::wstring>& secrets) {
  std::lock_guard lock(mutex_);
  if (!settings_valid_) {
    if (error)
      *error =
          "Settings file is unreadable. Preserve it and resolve before saving.";
    return false;
  }
  if (!imported_schema_.empty()) value.schema = settings_.schema;
  MigrateConnections(&value);
  if (!SelectConnection(&value, value.active_connection)) {
    if (error) *error = "连接器配置无效。";
    return false;
  }
  value.revision = settings_.revision + 1;
  if (!SaveSettings(value, error)) return false;
  auto updates = secrets;
  if (replace_key) updates[CredentialIdentity(value)] = key;
  const bool secrets_saved = SaveConnectionSecrets(value, updates, error);
  for (auto& [id, secret] : updates) if (!secret.empty()) SecureZeroMemory(secret.data(), secret.size() * sizeof(wchar_t));
  if (!secrets_saved) {
    if (!SaveSettings(settings_, nullptr)) {
      settings_valid_ = false;
      model_.Cancel();
    }
    return false;
  }
  settings_ = std::move(value);
  model_.InvalidatePluginResults();
  result_plugin_.clear(); result_grant_.clear();
  result_connector_.clear(); result_connector_grant_.clear();
  model_.capture = false;
  CaptureChanged();
  Changed();
  return true;
}
void Runtime::BindLocked(std::uint32_t foreground_process) {
  // A tray/menu or delayed TSF focus notification is not authority to capture
  // input from a background process. Never revive the previous bound target.
  const auto found = sessions_.find(model_.live.session);
  if (!foreground_process || foreground_process == GetCurrentProcessId() ||
      model_.live.process != foreground_process || found == sessions_.end() ||
      found->second.target != model_.live)
    model_.Focus({});
  model_.Open();
  ++opening_revision_;
  opening_caret_.reset();
  opening_at_ = GetTickCount64();
  opening_source_revision_ = model_.revision;
}
void Runtime::Bind(std::uint32_t foreground_process) {
  std::lock_guard lock(mutex_);
  BindLocked(foreground_process);
  CaptureChanged();
  Changed();
}
void Runtime::Toggle(std::uint32_t foreground_process) {
  std::lock_guard lock(mutex_);
  if (model_.visible && model_.capture)
    model_.Close();
  else
    BindLocked(foreground_process);
  CaptureChanged();
  Changed();
}
void Runtime::PauseCapture() {
  std::lock_guard lock(mutex_);
  if (!model_.capture) return;
  model_.capture = false;
  model_.preedit.clear();
  CaptureChanged();
  Changed();
}
void Runtime::Close() {
  std::lock_guard lock(mutex_);
  model_.Close();
  CaptureChanged();
  Changed();
}
void Runtime::Protect() {
  std::lock_guard lock(mutex_);
  model_.Protect();
  CaptureChanged();
  Changed();
}
void Runtime::DiscardBufferLocked() {
  api_job_.reset();
  model_.Discard();
  for (auto& [id, entry] : sessions_) { (void)id; entry.events.clear(); }
  return_held_ = false; return_sent_ = false; return_target_ = {};
  pressed_at_ = 0; pending_since_ = 0;
  result_plugin_.clear(); result_grant_.clear();
  result_connector_.clear(); result_connector_grant_.clear();
  CaptureChanged();
}
void Runtime::DiscardBuffer() {
  std::lock_guard lock(mutex_);
  DiscardBufferLocked();
  Changed();
}
void Runtime::Paste(std::string text) {
  std::lock_guard lock(mutex_);
  if (model_.visible) {
    if (!model_.Append(std::move(text), InputKind::kExternal))
      model_.status = "Paste exceeds Buffer capacity or delivery is pending.";
    edited_at_ = GetTickCount64();
    Changed();
  }
}
void Runtime::Send(bool all) {
  std::lock_guard lock(mutex_);
  Queue(SendAuthorized(all));
  Changed();
}
bool Runtime::ShortcutDown(std::uint32_t foreground_process) {
  Target target;
  core::KeyEvent key;
  {
    std::lock_guard lock(mutex_);
    if (!foreground_process || foreground_process != model_.live.process ||
        !model_.capture || model_.bound != model_.live || !model_.preedit.empty()) return false;
    target = model_.live;
    key.virtual_key = settings_.send_key;
    key.modifiers = core::ShortcutModifiers(settings_.send_modifiers);
    key.event_flags = static_cast<unsigned>(core::KeyEventFlags::kKeyDown);
  }
  return BeforeKey(target, key, false);
}
void Runtime::ShortcutUp() {
  Target target;
  core::KeyEvent key;
  {
    std::lock_guard lock(mutex_);
    if (!return_held_) return;
    target = return_target_; key.virtual_key = return_key_;
  }
  BeforeKey(target, key, false);
}
void Runtime::SetInsertion(std::size_t index) {
  std::lock_guard lock(mutex_);
  if (model_.preedit.empty() && model_.capture) {
    model_.SetInsertion(index); Changed();
  }
}
void Runtime::ReturnToEdit() {
  std::lock_guard lock(mutex_);
  model_.ReturnToEdit(); auto_since_ = 0; Changed();
}
void Runtime::SetAutoSend(unsigned seconds, bool close_after) {
  std::lock_guard lock(mutex_);
  auto next = settings_;
  next.auto_send_seconds = seconds; next.close_after_send = close_after;
  std::string error;
  if (SaveSettings(next, &error)) { settings_ = next; auto_since_ = 0; }
  else model_.status = error;
  Changed();
}
unsigned Runtime::TakeClipboardAction() {
  std::lock_guard lock(mutex_);
  const auto action = clipboard_action_; clipboard_action_ = 0;
  return model_.capture && model_.visible && clipboard_target_ == model_.live &&
      model_.bound == model_.live ? action : 0;
}
Json Runtime::CopyTicketLocked() {
  CheckPluginAuthorization();
  if (!model_.visible || model_.busy || model_.Pending() || model_.uncertain || !model_.preedit.empty()) return {};
  const bool result = !model_.result.empty();
  if (result && !model_.CompleteResult()) return {};
  if (!result && !model_.selected && model_.capture) return {};
  const auto text = result ? model_.ResultText() : model_.SourceText();
  if (text.empty()) return {};
  return {{"revision", model_.revision}, {"generation", model_.GenerationID()},
          {"text", text}, {"session", model_.bound.session},
          {"context", model_.bound.context}, {"capture", model_.capture}};
}
Json Runtime::PrepareCopy() { std::lock_guard lock(mutex_); return CopyTicketLocked(); }
bool Runtime::ValidateCopy(const Json& ticket) {
  std::lock_guard lock(mutex_);
  return !ticket.is_null() && ticket == CopyTicketLocked();
}
bool Runtime::CommitCopy(const Json& ticket, const std::function<bool()>& write) {
  std::lock_guard lock(mutex_);
  if (!ticket.is_null() && ticket == CopyTicketLocked() && write()) {
    model_.Close(); CaptureChanged(); Changed();
    return true;
  }
  return false;
}
void Runtime::PublishCaret(const RECT& caret) {
  std::lock_guard lock(mutex_);
  if (!model_.visible || !model_.capture || model_.bound != model_.live ||
      caret.bottom <= caret.top || EqualRect(&caret, &buffer_caret_)) return;
  auto found = sessions_.find(model_.bound.session);
  if (found == sessions_.end()) return;
  buffer_caret_ = caret;
  std::erase_if(found->second.events, [](const Json& e) { return e.value("kind", "") == "buffer_caret"; });
  found->second.events.push_back({{"kind", "buffer_caret"}, {"context", model_.bound.context},
      {"openingRevision", opening_revision_},
      {"rect", {caret.left, caret.top, caret.right, caret.bottom}}});
  event_.notify_all();
}
void Runtime::StartGeneration(bool translation, bool complete_sentence_only) {
  if (!settings_valid_ || stopping_ || model_.busy || model_.Pending() ||
      (!translation && !model_.result.empty()))
    return;
  CheckPluginAuthorization();
  const std::string plugin = translation ? official::kTranslation
      : settings_.ai_connector == "codex-cli" ? official::kCodex : official::kAI;
  const auto grant = plugins_.Grant(plugin);
  if (grant.empty()) { failed_translation_revision_ = model_.revision; model_.status = "Install and enable the plugin in Settings > Official plugins."; Changed(); return; }
  const bool local = translation && settings_.translation_provider == "local";
  const std::string connector = !local && settings_.ai_connector == "codex-cli" ? official::kCodex : "";
  const auto connector_grant = connector.empty() ? std::string{} : plugins_.Grant(connector);
  if (!connector.empty() && connector_grant.empty()) {
    failed_translation_revision_ = model_.revision; model_.status = "Enable the Codex connector in Settings > Official plugins."; Changed(); return;
  }
  std::string instruction;
  try { instruction = official::Instruction(plugins_.Package(plugin), settings_.target_language); }
  catch (...) { model_.status = "Plugin package unavailable."; Changed(); return; }
  auto job = model_.Generate(settings_.revision, translation,
                             complete_sentence_only);
  if (!model_.busy) return;
  if (local) model_.status = LocalTranslationReady() ? "正在本机翻译…" : "首次下载中英翻译资源（约 182 MiB）…";
  job.plugin_id = plugin; job.plugin_grant = grant; job.instruction = instruction;
  job.connector_id = connector; job.connector_grant = connector_grant;
  result_plugin_ = plugin; result_grant_ = grant;
  result_connector_ = connector; result_connector_grant_ = connector_grant;
  api_job_ = std::make_pair(settings_, std::move(job));
  api_event_.notify_one();
  Changed();
}
void Runtime::Generate(bool translation) {
  std::lock_guard lock(mutex_);
  ai_mode_ = !translation;
  model_.generated_mode = !translation;
  failed_translation_revision_ = 0;
  model_.translate = translation;
  StartGeneration(translation);
}
void Runtime::SelectAIMode() {
  std::lock_guard lock(mutex_);
  ai_mode_ = true;
  model_.generated_mode = true;
  Changed();
}
void Runtime::SelectTranslationMode() {
  std::lock_guard lock(mutex_);
  ai_mode_ = false;
  model_.generated_mode = false;
  model_.translate = true;
  // Selection arms the debounced sentence pipeline, including an empty
  // workspace. It does not require a first click on the Translate button.
  edited_at_ = GetTickCount64();
  Changed();
}
void Runtime::ReturnToInput() {
  std::lock_guard lock(mutex_);
  const bool was_busy = model_.busy;
  ai_mode_ = false;
  model_.generated_mode = false;
  api_job_.reset();
  model_.Cancel();
  model_.translate = false;
  if (!model_.Pending() && was_busy)
    model_.status = "Processing stopped. Source retained.";
  Changed();
}
void Runtime::Cancel() {
  std::lock_guard lock(mutex_);
  model_.Cancel();
  model_.translate = false;
  Changed();
}
void Runtime::Tick() {
  std::lock_guard lock(mutex_);
  CheckPluginAuthorization();
  const auto now = GetTickCount64();
  if (return_held_ && !return_sent_ && now - pressed_at_ >= settings_.send_hold_ms) {
    return_sent_ = true;
    if (model_.capture && return_target_ == model_.bound)
      Queue(SendAuthorized(true));
  }
  if (model_.Pending() && pending_since_ && now - pending_since_ > 10000) {
    model_.LostAcknowledgement();
    pending_since_ = 0;
    CaptureChanged();
    Changed();
  }
  if (model_.visible && model_.capture && model_.bound == model_.live &&
      model_.translate && !model_.busy &&
      model_.revision != failed_translation_revision_ &&
      !model_.source.empty() && model_.preedit.empty() &&
      now - edited_at_ >= 800)
    StartGeneration(true, true);
  const auto& queue = !model_.result.empty() ? model_.result : model_.source;
  const bool ready = settings_.auto_send_seconds && model_.visible && model_.capture &&
      model_.bound == model_.live && !model_.Pending() && !model_.uncertain &&
      !queue.empty() && (!model_.result.empty() ||
        (!model_.translate && !ai_mode_ && !model_.busy && model_.preedit.empty()));
  if (!ready) { auto_since_ = 0; }
  else {
    const auto& head = queue.front();
    if (!auto_since_ || auto_head_ != head.id || auto_text_ != head.text) {
      auto_since_ = now; auto_head_ = head.id; auto_text_ = head.text;
    } else if (now - auto_since_ >= settings_.auto_send_seconds * 1000ULL) {
      Queue(SendAuthorized(false)); auto_since_ = 0;
    }
    Changed();
  }
}
void Runtime::Stop() {
  std::lock_guard lock(mutex_);
  stopping_ = true;
  DiscardBufferLocked();
  api_event_.notify_all();
  event_.notify_all();
  Changed();
}
void Runtime::CheckPluginAuthorization() {
  if ((!result_plugin_.empty() && plugins_.Grant(result_plugin_) != result_grant_) ||
      (!result_connector_.empty() && plugins_.Grant(result_connector_) != result_connector_grant_)) {
    model_.InvalidatePluginResults();
    if (!model_.Pending()) { result_plugin_.clear(); result_grant_.clear(); result_connector_.clear(); result_connector_grant_.clear(); }
    Changed();
  }
}
std::optional<Delivery> Runtime::SendAuthorized(bool all) {
  const bool revoked = (!result_plugin_.empty() && plugins_.Grant(result_plugin_) != result_grant_) ||
      (!result_connector_.empty() && plugins_.Grant(result_connector_) != result_connector_grant_);
  CheckPluginAuthorization();
  return revoked ? std::nullopt : model_.Send(all);
}
std::vector<PluginView> Runtime::Plugins() { return plugins_.Entries(); }
std::string Runtime::PluginStatus() { std::lock_guard lock(mutex_); return plugin_status_; }
bool Runtime::ManagePlugin(const std::string& id, const std::string& action, std::string* error) {
  std::lock_guard lock(mutex_);
  if (stopping_ || model_.Pending()) { if(error) *error = "Wait for the current insertion to finish."; return false; }
  if (action == "install") {
    if (plugin_installing_) { if(error) *error = "A plugin download is already running."; return false; }
    plugin_installing_ = true; plugin_status_ = "Downloading and verifying...";
    plugin_worker_ = std::jthread([this, id] {
      std::string failure; const bool ok = plugins_.Install(id, &failure);
      std::lock_guard guard(mutex_); plugin_installing_ = false;
      plugin_status_ = ok ? "Installed. Enable the plugin to use it." : failure; Changed();
    });
    Changed(); return true;
  }
  const bool ok = action == "uninstall" ? plugins_.Uninstall(id, error)
      : action == "enable" || action == "disable" ? plugins_.Enable(id, action == "enable", error) : false;
  if (ok) {
    ++settings_.revision;
    CheckPluginAuthorization();
    plugin_status_ = action == "uninstall" ? "Uninstalled. User data retained." : action == "enable" ? "Enabled." : "Disabled.";
    CaptureChanged(); Changed();
  }
  return ok;
}
void Runtime::RunAPI() {
  for (;;) {
    std::unique_lock lock(mutex_);
    api_event_.wait(lock, [&] { return stopping_ || api_job_.has_value(); });
    if (stopping_) return;
    auto [config, job] = std::move(*api_job_);
    api_job_.reset();
    lock.unlock();
    std::string error;
    const bool ok = generate_(
        config, job,
        [&](const std::string& text) {
          std::lock_guard l(mutex_);
          const bool accepted = plugins_.Grant(job.plugin_id) == job.plugin_grant &&
              (job.connector_id.empty() || plugins_.Grant(job.connector_id) == job.connector_grant) &&
              model_.Stream(job, settings_.revision, text);
          Changed();
          return accepted;
        },
        [&] {
          std::lock_guard l(mutex_);
          return stopping_ || plugins_.Grant(job.plugin_id) != job.plugin_grant ||
              (!job.connector_id.empty() && plugins_.Grant(job.connector_id) != job.connector_grant) ||
              !model_.Accepts(job, settings_.revision);
        },
        &error);
    lock.lock();
    if (plugins_.Grant(job.plugin_id) == job.plugin_grant &&
        (job.connector_id.empty() || plugins_.Grant(job.connector_id) == job.connector_grant) && model_.Accepts(job, settings_.revision)) {
      const bool finished = model_.Finish(job, settings_.revision, ok);
      if (!finished && job.translation) failed_translation_revision_ = model_.revision;
      if (!ok) {
        model_.status = error;
        if (job.translation) failed_translation_revision_ = model_.revision;
      }
      Changed();
    }
  }
}
}  // namespace rimes::windows::workbench
