#pragma once
#include "BrokerClient.h"
#include "../../../../../Shared/CandidateMatrix/navigation.hpp"

namespace rimes::windows::tsf {
struct CandidatePageTraits {
  static bool visible(const BrokerInputState& page) { return page.candidates_visible; }
  static std::size_t highlighted(const BrokerInputState& page) { return page.highlighted_candidate; }
  static std::uint32_t pageId(const BrokerInputState& page) {
    return page.candidates.empty() ? 0 : page.candidates.front().id;
  }
};
using CandidateNavigation = rimes::candidates::Navigation<BrokerInputState, CandidatePageTraits>;
}  // namespace rimes::windows::tsf
