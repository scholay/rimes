#pragma once
#include <condition_variable>
#include <deque>
#include <functional>
#include <map>
#include <mutex>
#include <thread>

#include "../core/control.hpp"
#include "../engine/rime_snapshot.hpp"
#include "model.hpp"
#include "provider.hpp"
#include "official_plugins.hpp"
namespace rimes::windows::workbench {
class Runtime {
 public:
  using APIGenerator = std::function<bool(const Settings&, const Generation&,
      const std::function<bool(const std::string&)>&, const std::function<bool()>&, std::string*)>;
  explicit Runtime(APIGenerator generate = GenerateText);
  ~Runtime();
  Target Register(std::uint32_t process, std::uint64_t session,
                  std::uint64_t context);
  void Remove(Target target);
  void Focus(Target target);
  bool Capturing(Target target);
  bool BeforeKey(Target target, const core::KeyEvent& key, bool composing);
  void Capture(Target target, engine::EngineSnapshot* snapshot);
  core::Json Control(const core::Json& message, std::uint32_t process);
  core::Json Snapshot();
  Target PlacementTarget();
  Settings Configuration();
  bool Configure(Settings value, const std::wstring& key, bool replace_key,
                 std::string* error);
  void Toggle(std::uint32_t foreground_process);
  void Bind(std::uint32_t foreground_process);
  // A settings window takes keyboard focus without closing the workbench or
  // invalidating a request frozen against the unchanged source/configuration.
  void PauseCapture();
  void Close();
  void Protect();
  void DiscardBuffer();
  void Paste(std::string text);
  void Send(bool all);
  void Generate(bool translation);
  void SelectAIMode();
  // Stop queued/in-flight automatic translation when changing the displayed
  // mode. Source, completed results and an issued delivery/ack are retained;
  // selecting a mode does not dispatch a new request or deliver content.
  void ReturnToInput();
  void Cancel();
  void Tick();
  void Stop();
  void SetNotify(std::function<void()> notify);
  bool Stopping();
  std::vector<PluginView> Plugins();
  bool ManagePlugin(const std::string& id, const std::string& action, std::string* error);
  std::string PluginStatus();

 private:
  struct Entry {
    Target target;
    std::deque<core::Json> events;
  };
  std::mutex mutex_;
  std::condition_variable event_, api_event_;
  std::map<std::uint64_t, Entry> sessions_;
  Model model_;
  Settings settings_;
  OfficialPluginStore plugins_;
  std::string result_plugin_, result_grant_, plugin_status_;
  std::string result_connector_, result_connector_grant_;
  bool plugin_installing_ = false;
  std::jthread plugin_worker_;
  std::function<void()> notify_;
  bool stopping_ = false, settings_valid_ = true;
  std::jthread api_worker_;
  APIGenerator generate_;
  std::optional<std::pair<Settings, Generation>> api_job_;
  std::uint64_t pressed_at_ = 0, pending_since_ = 0, edited_at_ = 0;
  Target return_target_;
  std::uint64_t opening_revision_ = 0;
  bool return_held_ = false, return_sent_ = false;
  bool ai_mode_ = false;
  void Changed();
  void DiscardBufferLocked();
  void CheckPluginAuthorization();
  std::optional<Delivery> SendAuthorized(bool all);
  void Queue(const std::optional<Delivery>& delivery);
  void CaptureChanged();
  void BindLocked(std::uint32_t foreground_process);
  void StartGeneration(bool translation, bool complete_sentence_only = false);
  void RunAPI();
};
}  // namespace rimes::windows::workbench
