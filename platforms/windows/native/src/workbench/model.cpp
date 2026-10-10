#include "model.hpp"

#include <algorithm>
#include <string_view>

namespace rimes::windows::workbench {
namespace {
std::string Join(const std::deque<Block>& blocks) {
  std::string text;
  for (const auto& block : blocks) text += block.text;
  return text;
}
bool EndsSentence(std::string_view text) {
  while (!text.empty() && (text.back() == ' ' || text.back() == '\t' ||
                           text.back() == '\r'))
    text.remove_suffix(1);
  return text.ends_with("。") || text.ends_with("！") ||
         text.ends_with("？") || text.ends_with(".") || text.ends_with("!") ||
         text.ends_with("?") || text.ends_with("\n");
}
}  // namespace
std::vector<std::string> Sentences(const std::string& text) {
  std::vector<std::string> parts;
  std::size_t start = 0;
  for (std::size_t i = 0; i < text.size(); ++i) {
    std::size_t end = 0;
    if (text[i] == '\n' || text[i] == '!' || text[i] == '?' || text[i] == '.')
      end = i + 1;
    for (const auto* mark : {"。", "！", "？"})
      if (text.compare(i, 3, mark) == 0) end = i + 3;
    if (end) {
      while (end < text.size() &&
             (text[end] == '\r' || text[end] == '\n' || text[end] == ' '))
        ++end;
      parts.push_back(text.substr(start, end - start));
      start = end;
      i = end - 1;
    }
  }
  if (start < text.size()) parts.push_back(text.substr(start));
  return parts;
}
void Model::Focus(Target target) {
  if (live == target) return;
  live = target;
  if (capture && bound != live) {
    capture = false;
    preedit.clear();
    status = "Target changed. Rebind to send.";
    Cancel();
  }
}
void Model::Revoke(Target target) {
  if (live == target) Focus({});
  if (bound == target) {
    capture = false;
    preedit.clear();
  }
}
void Model::Open() {
  visible = true;
  bound = live;
  capture = static_cast<bool>(bound);
  status = capture ? "Buffer" : "Copy only - no input target";
}
void Model::Close() {
  visible = false;
  capture = false;
  preedit.clear();
  Cancel();
}
void Model::Protect() {
  Close();
  live = {};
  bound = {};
  preview.clear();
  status = "Protected";
}
void Model::Discard() {
  Protect();
  source.clear(); result.clear(); source_links_.clear();
  translated_source_.clear(); pending_.reset();
  send_all_ = false; send_until_ = 0;
  uncertain = false; translate = false;
  ++revision;
  status = "Buffer reset";
  // Keep request/block identities monotonic: a late pre-reset ack must never
  // consume new content or continue an old multi-block send.
}
std::string Model::SourceText() const { return Join(source); }
std::string Model::ResultText() const { return Join(result); }
bool Model::Append(std::string text) {
  if (text.empty()) return true;
  if (SourceText().size() + text.size() > kLimit ||
      (pending_ && pending_->result))
    return false;
  // Completed translation output is immutable until delivered or explicitly
  // cancelled.
  if (!translate) {
    Cancel();
    result.clear();
    source_links_.clear();
    translated_source_.clear();
  }
  // Adjacent raw keystrokes form sentence blocks; never mutate an in-flight
  // prefix.
  if (!source.empty() &&
      (!pending_ || pending_->block.id != source.back().id)) {
    const auto& tail = source.back().text;
    const bool complete = EndsSentence(tail);
    if (!complete) {
      text = std::move(source.back().text) + text;
      source.pop_back();
    }
  }
  for (auto& part : Sentences(text))
    source.push_back({next_id_++, std::move(part)});
  ++revision;
  return true;
}
bool Model::Backspace() {
  if (source.empty() || pending_) return false;
  Cancel();
  result.clear();
  source_links_.clear();
  translated_source_.clear();
  auto& text = source.back().text;
  auto last = text.size() - 1;
  while (last > 0 && (static_cast<unsigned char>(text[last]) & 0xc0) == 0x80)
    --last;
  text.erase(last);
  if (text.empty()) source.pop_back();
  ++revision;
  return true;
}
Generation Model::Generate(std::uint64_t settings_revision, bool translation,
                            bool complete_sentence_only) {
  Cancel();
  Generation job{
      generation_, revision, settings_revision, SourceText(), translation,
      0,           {}};
  if (translation) {
    job.source_offset = translated_source_.size();
    job.prefix = translated_source_;
    if (!job.source.starts_with(job.prefix)) return job;
    job.source.erase(0, job.source_offset);
    const auto parts = Sentences(job.source);
    if (!parts.empty()) job.source = parts.front();
    if (complete_sentence_only && !EndsSentence(job.source)) job.source.clear();
  }
  busy = !job.source.empty() && !pending_ && (translation || result.empty());
  if (busy) {
    preview.clear();
    status = "Waiting for response...";
  }
  return job;
}
bool Model::Accepts(const Generation& job,
                    std::uint64_t settings_revision) const {
  if (!busy || job.id != generation_ ||
      job.settings_revision != settings_revision)
    return false;
  if (!job.translation)
    return job.revision == revision && job.source == SourceText();
  return SourceText().starts_with(job.prefix + job.source);
}
bool Model::Stream(const Generation& job, std::uint64_t settings_revision,
                   std::string text) {
  if (!Accepts(job, settings_revision) ||
      ResultText().size() + preview.size() + text.size() > kLimit)
    return false;
  preview += text;
  status = "Receiving...";
  return true;
}
bool Model::Finish(const Generation& job, std::uint64_t settings_revision,
                   bool success) {
  if (!Accepts(job, settings_revision)) return false;
  busy = false;
  if (!success || preview.empty()) {
    preview.clear();
    status = "Request failed. Source retained.";
    return false;
  }
  for (auto& text : Sentences(preview))
    result.push_back({next_id_++, std::move(text)});
  source_links_[result.back().id] = job.source;
  translated_source_ += job.source;
  preview.clear();
  status = "Ready";
  return true;
}
void Model::Cancel() {
  ++generation_;
  busy = false;
  preview.clear();
}
void Model::InvalidatePluginResults() {
  Cancel(); translate = false; send_all_ = false;
  // An already-issued insertion must still be acknowledged exactly once.
  // Prevent continuation, then discard remaining results after that ack.
  if (pending_) return;
  result.clear(); source_links_.clear(); translated_source_.clear();
  status = "Plugin authorization changed. Source retained.";
}
std::optional<Delivery> Model::Send(bool all) {
  if (!visible || !capture || !bound || bound != live || pending_ ||
      uncertain || (busy && result.empty()))
    return {};
  const bool output = !result.empty();
  const auto& blocks = output ? result : source;
  if (blocks.empty()) return {};
  if (output && !translated_source_.empty() &&
      !SourceText().starts_with(translated_source_))
    return {};
  if (!send_all_) send_until_ = blocks.back().id;
  send_all_ = all;
  pending_ = Delivery{next_request_++, bound, blocks.front(), output};
  status = "Sending...";
  return pending_;
}
void Model::RemoveSourcePrefix(std::size_t bytes) {
  while (bytes && !source.empty()) {
    auto& b = source.front();
    auto take = (std::min)(bytes, b.text.size());
    b.text.erase(0, take);
    bytes -= take;
    if (b.text.empty()) source.pop_front();
  }
  ++revision;
}
std::optional<Delivery> Model::Acknowledge(std::uint64_t request, Target target,
                                           bool accepted) {
  if (!pending_ || pending_->request != request || pending_->target != target)
    return {};
  const auto delivered = *pending_;
  pending_.reset();
  auto& blocks = delivered.result ? result : source;
  if (!accepted) {
    send_all_ = false;
    status = "Delivery failed. Content retained.";
    return {};
  }
  if (blocks.empty() || blocks.front().id != delivered.block.id ||
      blocks.front().text != delivered.block.text) {
    uncertain = true;
    send_all_ = false;
    status = "Delivery state changed. Check the target before retrying.";
    return {};
  }
  blocks.pop_front();
  if (delivered.result) {
    const auto link = source_links_.find(delivered.block.id);
    if (link != source_links_.end()) {
      if (!SourceText().starts_with(link->second)) {
        uncertain = true;
        send_all_ = false;
        return {};
      }
      const auto bytes = link->second.size();
      RemoveSourcePrefix(bytes);
      translated_source_.erase(0, bytes);
      source_links_.erase(link);
      Cancel();
    }
  }
  if (!delivered.result) ++revision;
  if (send_all_ && !blocks.empty() && blocks.front().id <= send_until_ &&
      live == bound && capture)
    return Send(true);
  send_all_ = false;
  status = "Delivered";
  return {};
}
void Model::LostAcknowledgement() {
  if (pending_) {
    uncertain = true;
    send_all_ = false;
    capture = false;
    status =
        "Delivery unconfirmed. Check the target; automatic retry disabled.";
  }
}
}  // namespace rimes::windows::workbench
