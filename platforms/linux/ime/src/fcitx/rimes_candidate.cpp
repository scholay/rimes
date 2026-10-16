#include "rimes_candidate.hpp"

#include <stdexcept>

#include <fcitx-utils/textformatflags.h>

#include "rimes_ime.hpp"
#include "rimes_state.hpp"

namespace fcitx {

RimesCandidateWord::RimesCandidateWord(RimesIme* ime, int index, Text text,
                                     const std::string& comment)
    : CandidateWord(), ime_(ime), index_(index) {
#ifdef RIMES_FCITX_HAS_CANDIDATE_COMMENT
    // Native comment text lets compatible panels apply their smaller annotation
    // font. Keep the candidate text separate for accessibility and selection.
    setComment(Text(comment, TextFormatFlag::DontCommit));
#else
    // Older distro panels have no annotation API. Preserve readable code hints.
    if (!comment.empty()) {
        text.append(" ", TextFormatFlag::DontCommit);
        text.append(comment, TextFormatFlag::DontCommit);
    }
#endif
    setText(std::move(text));
}

void RimesCandidateWord::select(InputContext* inputContext) const {
    if (ime_ == nullptr || inputContext == nullptr) {
        return;
    }
    auto* state = inputContext->propertyFor(&ime_->factory());
    if (state != nullptr) {
        state->selectCandidate(index_);
    }
}

RimesCandidateList::RimesCandidateList(RimesIme* ime,
                                       InputContext* ic,
                                       const rimes::linuxime::EngineSnapshot& snapshot)
    : ime_(ime),
      ic_(ic),
      cursor_(snapshot.highlighted),
      has_prev_(snapshot.page_no > 0),
      has_next_(!snapshot.is_last_page) {
    setPageable(this);
    labels_.reserve(snapshot.candidates.size());
    words_.reserve(snapshot.candidates.size());
    for (std::size_t index = 0; index < snapshot.candidates.size(); ++index) {
        const auto& candidate = snapshot.candidates[index];
        std::string label = candidate.label.empty()
                                ? std::to_string((index + 1) % 10)
                                : candidate.label;
        if (!label.empty() && label.back() != ' ') {
            label.push_back(' ');
        }
        labels_.emplace_back(std::move(label));
        Text word(candidate.text);
        words_.emplace_back(std::make_unique<RimesCandidateWord>(
            ime_, static_cast<int>(index), std::move(word), candidate.comment));
    }
}

const Text& RimesCandidateList::label(int idx) const {
    checkIndex(idx);
    return labels_[static_cast<std::size_t>(idx)];
}

const CandidateWord& RimesCandidateList::candidate(int idx) const {
    checkIndex(idx);
    return *words_[static_cast<std::size_t>(idx)];
}

int RimesCandidateList::size() const { return static_cast<int>(words_.size()); }

int RimesCandidateList::cursorIndex() const { return cursor_; }

CandidateLayoutHint RimesCandidateList::layoutHint() const {
    return ime_->verticalCandidates() ? CandidateLayoutHint::Vertical : CandidateLayoutHint::Horizontal;
}

void RimesCandidateList::prev() {
    if (auto* state = ic_->propertyFor(&ime_->factory())) {
        state->page(false);
    }
}

void RimesCandidateList::next() {
    if (auto* state = ic_->propertyFor(&ime_->factory())) {
        state->page(true);
    }
}

void RimesCandidateList::checkIndex(int idx) const {
    if (idx < 0 || idx >= size()) {
        throw std::invalid_argument("candidate index out of range");
    }
}

}  // namespace fcitx
