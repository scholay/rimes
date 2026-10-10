#include <cstdlib>
#include <iostream>

#include "model.hpp"
using namespace rimes::windows::workbench;
void Check(bool ok, const char* message) {
  if (!ok) {
    std::cerr << message << '\n';
    std::exit(1);
  }
}
int main() {
  Target a{10, 1, 1}, b{10, 2, 2};
  Model m;
  m.Focus(a);
  m.Open();
  m.Append("你好。");
  m.Append("第二句。");
  auto d = m.Send(true);
  Check(d.has_value(), "send starts");
  Check(m.source.size() == 2, "enqueue does not consume");
  Check(!m.Acknowledge(d->request, b, true), "foreign ack rejected");
  Check(m.Pending(), "foreign ack retains pending");
  auto next = m.Acknowledge(d->request, a, true);
  Check(next.has_value() && m.source.size() == 1, "confirmed prefix consumed");
  m.Acknowledge(next->request, a, false);
  Check(m.source.size() == 1, "failed suffix retained");
  m.Focus(b);
  Check(!m.Send(false), "cannot redirect old target");
  m.Open();
  auto job = m.Generate(2, false);
  Check(m.Stream(job, 2, "result"), "stream accepted");
  m.Append("new");
  Check(!m.Stream(job, 2, "stale"), "source edit retires generation");
  m.result.clear();
  job = m.Generate(3, false);
  Check(!m.Stream(job, 4, "wrong route"), "route revision frozen");
  m.Cancel();
  Check(!m.Stream(job, 3, "late"), "cancel retires generation");
  Model t;
  t.translate = true;
  t.Focus(a);
  t.Open();
  t.Append("第一句。");
  job = t.Generate(1, true);
  t.Append("第二句。");
  Check(t.Stream(job, 1, "First sentence."), "stable prefix survives append");
  Check(t.Finish(job, 1, true), "translation completes");
  d = t.Send(false);
  Check(d.has_value(), "translation deliverable");
  t.Acknowledge(d->request, a, true);
  Check(t.SourceText() == "第二句。", "translation retires exact prefix once");
  t.Append("💡");
  Check(t.Backspace() && t.SourceText() == "第二句。",
        "backspace preserves UTF-8");
  d = t.Send(false);
  t.LostAcknowledgement();
  Check(t.uncertain && !t.Send(false), "lost ack never retries");
  t.Protect();
  Check(!t.visible && !t.capture && !t.live, "protection revokes authority");
  Check(Sentences("a.\nb。c").size() == 3,
        "sentence boundaries retain newlines");
  Model incremental;
  incremental.translate = true;
  incremental.Focus(a);
  incremental.Open();
  incremental.Append("One. Two.");
  auto first = incremental.Generate(1, true);
  incremental.Stream(first, 1, "一。");
  Check(incremental.Finish(first, 1, true), "first incremental result");
  auto second = incremental.Generate(1, true);
  Check(second.source == "Two.",
        "translation only processes unprocessed suffix");
  incremental.Stream(second, 1, "二。");
  Check(incremental.Finish(second, 1, true),
        "append translation without requiring a send");
  Check(incremental.result.size() == 2, "two translated blocks coexist");
  d = incremental.Send(true);
  next = incremental.Acknowledge(d->request, a, true);
  Check(incremental.SourceText() == "Two." && next.has_value(),
        "first result consumes only its original sentence");
  incremental.Acknowledge(next->request, a, true);
  Check(incremental.source.empty() && incremental.result.empty(),
        "translated output drains exactly once");
  Model stable;
  stable.translate = true;
  stable.Append("半句");
  auto waiting = stable.Generate(1, true, true);
  Check(!stable.busy && waiting.source.empty(),
        "automatic translation waits for a sentence boundary");
  stable.Append("结束。  ");
  auto complete = stable.Generate(1, true, true);
  Check(stable.busy && complete.source == "半句结束。  ",
        "automatic translation freezes a complete sentence including spaces");
  stable.Append("下一句尚未完成");
  Check(stable.Stream(complete, 1, "Completed.") &&
            stable.Finish(complete, 1, true),
        "appending a new sentence preserves the completed prefix");
  Check(stable.Generate(1, true, true).source.empty() && !stable.busy,
        "unfinished suffix is not automatically sent");
  Check(!stable.Generate(1, true).source.empty() && stable.busy,
        "explicit translation can send an unfinished suffix");
  Model disposable;
  disposable.Focus(a); disposable.Open(); disposable.Append("Temporary.");
  auto obsolete = disposable.Generate(1, false);
  disposable.Stream(obsolete, 1, "Temporary result.");
  disposable.Finish(obsolete, 1, true);
  auto old_delivery = disposable.Send(true);
  disposable.Discard();
  Check(disposable.source.empty() && disposable.result.empty() &&
            !disposable.Pending() && !disposable.capture && !disposable.visible,
        "maintenance discards pending Buffer content without a confirmation");
  Check(!disposable.Stream(obsolete, 1, "Late text"),
        "a pre-reset generation cannot repopulate the Buffer");
  disposable.Focus(a); disposable.Open(); disposable.Append("New.");
  auto new_delivery = disposable.Send(false);
  Check(new_delivery && old_delivery && new_delivery->request > old_delivery->request,
        "reset preserves monotonic delivery identities");
  disposable.Acknowledge(old_delivery->request, a, true);
  Check(disposable.SourceText() == "New." && disposable.Pending(),
        "late reset acknowledgement never consumes new content");
  std::cout << "Workbench model tests passed\n";
}
