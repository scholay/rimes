#pragma once
#include <cstdint>
#include <deque>
#include <map>
#include <optional>
#include <string>
#include <vector>

namespace rimes::windows::workbench {
struct Target {
  std::uint32_t process = 0;
  std::uint64_t session = 0;
  std::uint64_t context = 0;
  bool operator==(const Target&) const = default;
  explicit operator bool() const { return process && session && context; }
};
struct Block {
  std::uint64_t id = 0;
  std::string text;
};
struct Delivery {
  std::uint64_t request = 0;
  Target target;
  Block block;
  bool result = false;
};
struct Generation {
  std::uint64_t id = 0, revision = 0, settings_revision = 0;
  std::string source;
  bool translation = false;
  std::size_t source_offset = 0;
  std::string prefix;
  std::string plugin_id, plugin_grant, instruction;
  std::string connector_id, connector_grant;
};
// Pure state machine. Broker serializes calls. Nothing here persists source
// text.
class Model {
 public:
  static constexpr std::size_t kLimit = 256 * 1024;
  bool visible = false, capture = false, busy = false, translate = false;
  bool uncertain = false;
  Target live, bound;
  std::deque<Block> source, result;
  std::string preview, preedit, status;
  std::uint64_t revision = 1;
  void Focus(Target target);
  void Revoke(Target target);
  void Open();
  void Close();
  void Protect();
  bool Append(std::string text);
  bool Backspace();
  std::string SourceText() const;
  std::string ResultText() const;
  Generation Generate(std::uint64_t settings_revision, bool translation,
                      bool complete_sentence_only = false);
  bool Accepts(const Generation& job, std::uint64_t settings_revision) const;
  bool Stream(const Generation& job, std::uint64_t settings_revision,
              std::string text);
  bool Finish(const Generation& job, std::uint64_t settings_revision,
              bool success);
  void Cancel();
  void InvalidatePluginResults();
  std::optional<Delivery> Send(bool all);
  std::optional<Delivery> Acknowledge(std::uint64_t request, Target target,
                                      bool accepted);
  void LostAcknowledgement();
  bool Pending() const { return pending_.has_value(); }
  std::uint64_t GenerationID() const { return generation_; }

 private:
  std::optional<Delivery> pending_;
  std::uint64_t next_id_ = 1, next_request_ = 1, generation_ = 0;
  bool send_all_ = false;
  std::map<std::uint64_t, std::string> source_links_;
  std::uint64_t send_until_ = 0;
  std::string translated_source_;
  void RemoveSourcePrefix(std::size_t bytes);
};
std::vector<std::string> Sentences(const std::string& text);
}  // namespace rimes::windows::workbench
