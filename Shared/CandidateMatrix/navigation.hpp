#pragma once

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <vector>


namespace rimes::candidates {

// Candidate selection is presentation state. The engine remains on the active
// row; previewing adjacent pages always restores that row before returning.
template <typename Page, typename Traits>
class Navigation {
 public:
  void Reset(const Page& state) {
    ++generation_;
    pages_.clear();
    row_ = base_ = column_ = 0;
    expanded_ = false;
    if (Traits::visible(state) && !state.candidates.empty()) {
      pages_.push_back(state);
      column_ = Traits::highlighted(state) < state.candidates.size()
          ? Traits::highlighted(state) : 0;
    }
  }

  bool empty() const { return pages_.empty(); }
  bool expanded() const { return expanded_; }
  std::size_t column() const { return column_; }
  std::size_t row() const { return row_; }
  std::size_t base() const { return expanded_ ? base_ : row_; }
  std::size_t end() const {
    return (std::min)(pages_.size(), base() + (expanded_ ? 3U : 1U));
  }
  const Page& page(std::size_t row) const { return pages_[row]; }

  // The wire page_start is local to the transmitted candidate vector (zero).
  // Candidate IDs retain the absolute librime offset across pages.
  static std::uint32_t PageId(const Page& state) {
    return Traits::pageId(state);
  }

  void MoveColumn(int delta) {
    if (empty()) return;
    column_ = static_cast<std::size_t>((std::clamp)(
        static_cast<int>(column_) + delta, 0,
        static_cast<int>(pages_[row_].candidates.size()) - 1));
  }

  void Collapse() {
    if (empty()) return;
    auto current = pages_[row_];
    const auto column = column_;
    Reset(current);
    column_ = column;
  }

  // Escape returns to the page that opened the matrix, matching macOS.
  template <typename Step>
  bool CollapseToAnchor(Step&& step) {
    const auto generation = generation_;
    while (!empty() && row_ > 0) {
      const auto previous = step(-1);
      if (generation != generation_ || !previous || previous->candidates.empty() ||
          PageId(*previous) != PageId(pages_[row_ - 1])) return false;
      --row_;
      pages_[row_] = *previous;
    }
    if (!empty()) column_ = (std::min)(column_, pages_[row_].candidates.size() - 1);
    Collapse();
    return true;
  }

  // step(delta) returns the authoritative page after one complete PageUp/Down
  // tap, or nullopt on transport/context failure. An unchanged page is the end
  // of the candidate list, not permission to wrap around or invent candidates.
  template <typename Step>
  bool MoveRow(int delta, Step&& step) {
    if (empty()) return false;
    const auto generation = generation_;
    if (!expanded_) {
      if (delta < 0) {
        const auto previous = step(-1);
        if (generation != generation_ || !previous) return false;
        Reset(*previous);
        return true;
      }
      if (!PreviewFollowing(step)) return false;
      expanded_ = pages_.size() > 1;
      return true;
    }
    if (delta < 0 && row_ == 0) {
      Collapse();
      return true;
    }
    if (delta > 0 && row_ + 1 == pages_.size()) {
      if (!PreviewFollowing(step)) return false;
      if (row_ + 1 == pages_.size()) return true;
    }
    const auto target = delta < 0 ? row_ - 1 : row_ + 1;
    const auto next = step(delta);
    if (generation != generation_ || !next || next->candidates.empty() ||
        PageId(*next) != PageId(pages_[target])) return false;
    row_ = target;
    pages_[row_] = *next;
    column_ = (std::min)(column_, next->candidates.size() - 1);
    if (row_ < base_) base_ = row_;
    if (row_ >= base_ + 3) base_ = row_ - 2;
    return true;
  }

  struct Selection { std::uint32_t page_id; std::size_t index; };
  template <typename Step>
  bool SelectVisibleIndex(std::size_t index, Step&& step) {
    const auto generation = generation_;
    for (auto row = base(); row < end(); ++row) {
      if (index < pages_[row].candidates.size()) {
        // Host UI selection can cross preview rows. Keep the engine on the
        // selected row so later keyboard navigation starts from the same page.
        while (row_ != row) {
          const int delta = row < row_ ? -1 : 1;
          const auto target = delta < 0 ? row_ - 1 : row_ + 1;
          const auto next = step(delta);
          if (generation != generation_ || !next || next->candidates.empty() || target >= pages_.size() ||
              PageId(*next) != PageId(pages_[target])) return false;
          row_ = target;
          pages_[row_] = *next;
        }
        if (index >= pages_[row_].candidates.size()) return false;
        column_ = index;
        return true;
      }
      index -= pages_[row].candidates.size();
    }
    return false;
  }
  std::optional<Selection> AtVisibleIndex(std::size_t index) const {
    for (auto row = base(); row < end(); ++row) {
      if (index < pages_[row].candidates.size())
        return Selection{PageId(pages_[row]), index};
      index -= pages_[row].candidates.size();
    }
    return std::nullopt;
  }
  std::optional<Selection> Selected(std::optional<std::size_t> digit = {}) const {
    if (empty()) return std::nullopt;
    const auto index = digit.value_or(column_);
    if (index >= pages_[row_].candidates.size()) return std::nullopt;
    return Selection{PageId(pages_[row_]), index};
  }

 private:
  template <typename Step>
  bool PreviewFollowing(Step& step) {
    const auto generation = generation_;
    const auto anchor = PageId(pages_[row_]);
    auto last = anchor;
    std::size_t moved = 0;
    bool valid = true;
    for (int i = 0; i < 2; ++i) {
      auto next = step(1);
      // A callback can synchronously retire the context or apply a custom
      // schema's commit. Stop immediately; even a restoring key is now stale.
      if (generation != generation_ || !next) return false;
      if (PageId(*next) == last) break;
      ++moved;
      if (PageId(*next) <= last || next->candidates.empty()) {
        valid = false;
        break;
      }
      pages_.push_back(*next);
      last = PageId(*next);
    }
    while (moved > 0) {
      const auto previous = step(-1);
      if (generation != generation_ || !previous) return false;
      --moved;
      if (moved == 0 && PageId(*previous) != anchor) return false;
      if (moved == 0) pages_[row_] = *previous;
    }
    return valid;
  }

  std::vector<Page> pages_;
  std::uint64_t generation_ = 0;
  std::size_t row_ = 0, column_ = 0, base_ = 0;
  bool expanded_ = false;
};

}  // namespace rimes::candidates
