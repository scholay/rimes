#include "runtime.hpp"
#include "official_features.hpp"

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
void Runtime::CaptureChanged() {
  for (auto& [id, entry] : sessions_) {
    (void)id;
    // Replace obsolete capture notifications but never replace a delivery.
    std::erase_if(entry.events, [](const Json& e) {
      return e.value("kind", "") == "capture";
    });
    entry.events.push_back(
        {{"kind", "capture"},
         {"context", entry.target.context},
         {"font", settings_.font_size},
         {"verticalCandidates", settings_.vertical_candidates},
         {"theme", settings_.theme},
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
  if (return_held_ && key.virtual_key == VK_RETURN &&
      return_target_ == target) {
    if (!down) {
      if (!return_sent_ && model_.capture && model_.bound == target)
        Queue(SendAuthorized(GetTickCount64() - pressed_at_ >= 1200));
      return_held_ = false;
    }
    return true;
  }
  // A Return already owned above keeps its repeat/release lifecycle even if
  // modifiers change. New host shortcuts must not become Buffer commands.
  constexpr auto command_modifiers =
      static_cast<unsigned>(core::KeyModifiers::kControl) |
      static_cast<unsigned>(core::KeyModifiers::kAlt) |
      static_cast<unsigned>(core::KeyModifiers::kWindows) |
      static_cast<unsigned>(core::KeyModifiers::kAltGr);
  if ((key.modifiers & command_modifiers) != 0) return false;
  if (!model_.capture || model_.bound != target || model_.live != target)
    return false;
  if (key.virtual_key != VK_ESCAPE && key.virtual_key != VK_RETURN &&
      key.virtual_key != VK_BACK &&
      (model_.SourceText().size() > Model::kLimit - core::kMaxCommitTextBytes ||
       (model_.Pending() && !model_.result.empty()))) {
    model_.status =
        "Buffer is full or a result is being delivered. Input paused.";
    Changed();
    return true;
  }
  if (key.virtual_key == VK_ESCAPE) {
    if (down) {
      model_.Close();
      CaptureChanged();
      Changed();
    }
    return true;
  }
  if (key.virtual_key == VK_BACK && !composing) {
    if (down) {
      model_.Backspace();
      edited_at_ = GetTickCount64();
      Changed();
    }
    return true;
  }
  if (key.virtual_key == VK_RETURN && !composing) {
    if (down && !(key.event_flags &
                  static_cast<unsigned>(core::KeyEventFlags::kRepeat))) {
      return_held_ = true;
      return_sent_ = false;
      pressed_at_ = GetTickCount64();
      return_target_ = target;
    }
    return true;
  }
  return false;
}
void Runtime::Capture(Target target, engine::EngineSnapshot* snapshot) {
  std::lock_guard lock(mutex_);
  if (!model_.capture || model_.bound != target || model_.live != target)
    return;
  model_.preedit = snapshot->composition;
  if (!snapshot->commit_text.empty()) {
    if (!model_.Append(snapshot->commit_text))
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
  if (op == "focus") {
    model_.Focus(target.process == GetCurrentProcessId() ? Target{} : target);
    CaptureChanged();
    Changed();
    return {{"kind", "ok"}};
  }
  if (op == "ack") {
    CheckPluginAuthorization();
    Queue(model_.Acknowledge(message.value("request", 0ULL), target,
                             message.value("accepted", false)));
    CheckPluginAuthorization();
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
          {"status", model_.status},
          {"translate", model_.translate},
          {"target_pid", model_.capture && model_.bound == model_.live
                             ? model_.bound.process : 0}};
}
Settings Runtime::Configuration() {
  std::lock_guard lock(mutex_);
  auto effective = settings_;
  if (effective.schema == official::kChordSchema && plugins_.Grant(official::kChord).empty()) effective.schema = "rime_ice";
  return effective;
}
bool Runtime::Configure(Settings value, const std::wstring& key,
                        bool replace_key, std::string* error) {
  std::lock_guard lock(mutex_);
  if (!settings_valid_) {
    if (error)
      *error =
          "Settings file is unreadable. Preserve it and resolve before saving.";
    return false;
  }
  value.revision = settings_.revision + 1;
  if (!SaveSettings(value, error)) return false;
  if (replace_key && !SaveSecret(key, value.base_url, error)) {
    if (!SaveSettings(settings_, nullptr)) {
      settings_valid_ = false;
      model_.Cancel();
    }
    return false;
  }
  settings_ = std::move(value);
  model_.InvalidatePluginResults();
  result_plugin_.clear(); result_grant_.clear();
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
void Runtime::Paste(std::string text) {
  std::lock_guard lock(mutex_);
  if (model_.visible) {
    if (!model_.Append(std::move(text)))
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
void Runtime::StartGeneration(bool translation, bool complete_sentence_only) {
  if (!settings_valid_ || stopping_ || model_.busy || model_.Pending() ||
      (!translation && !model_.result.empty()))
    return;
  CheckPluginAuthorization();
  const std::string plugin = translation ? official::kTranslation : official::kAI;
  const auto grant = plugins_.Grant(plugin);
  if (grant.empty()) { model_.translate = false; model_.status = "Install and enable the plugin in Settings > Official plugins."; Changed(); return; }
  std::string instruction;
  try { instruction = official::Instruction(plugins_.Package(plugin), settings_.target_language); }
  catch (...) { model_.status = "Plugin package unavailable."; Changed(); return; }
  auto job = model_.Generate(settings_.revision, translation,
                             complete_sentence_only);
  if (!model_.busy) return;
  job.plugin_id = plugin; job.plugin_grant = grant; job.instruction = instruction;
  result_plugin_ = plugin; result_grant_ = grant;
  api_job_ = std::make_pair(settings_, std::move(job));
  api_event_.notify_one();
  Changed();
}
void Runtime::Generate(bool translation) {
  std::lock_guard lock(mutex_);
  model_.translate = translation;
  StartGeneration(translation);
}
void Runtime::ReturnToInput() {
  std::lock_guard lock(mutex_);
  api_job_.reset();
  model_.Cancel();
  model_.translate = false;
  if (!model_.Pending() &&
      (model_.status == "Waiting for response..." ||
       model_.status == "Receiving..."))
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
  if (return_held_ && !return_sent_ && now - pressed_at_ >= 1200) {
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
  if (model_.visible && model_.translate && !model_.busy &&
      !model_.source.empty() && model_.preedit.empty() &&
      now - edited_at_ >= 800)
    StartGeneration(true, true);
}
void Runtime::Stop() {
  std::lock_guard lock(mutex_);
  stopping_ = true;
  model_.Protect();
  api_event_.notify_all();
  event_.notify_all();
  Changed();
}
void Runtime::CheckPluginAuthorization() {
  if (!result_plugin_.empty() && plugins_.Grant(result_plugin_) != result_grant_) {
    model_.InvalidatePluginResults();
    if (!model_.Pending()) { result_plugin_.clear(); result_grant_.clear(); }
    Changed();
  }
}
std::optional<Delivery> Runtime::SendAuthorized(bool all) {
  const bool revoked = !result_plugin_.empty() && plugins_.Grant(result_plugin_) != result_grant_;
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
          const bool accepted = plugins_.Grant(job.plugin_id) == job.plugin_grant && model_.Stream(job, settings_.revision, text);
          Changed();
          return accepted;
        },
        [&] {
          std::lock_guard l(mutex_);
          return stopping_ || plugins_.Grant(job.plugin_id) != job.plugin_grant || !model_.Accepts(job, settings_.revision);
        },
        &error);
    lock.lock();
    if (plugins_.Grant(job.plugin_id) == job.plugin_grant && model_.Accepts(job, settings_.revision)) {
      const bool finished = model_.Finish(job, settings_.revision, ok);
      if (!finished) model_.translate = false;
      if (!ok) {
        model_.status = error;
        model_.translate = false;
      }
      Changed();
    }
  }
}
}  // namespace rimes::windows::workbench
