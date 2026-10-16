#pragma once
#include <functional>
#include <memory>
#include <utility>
#include <vector>
#include <fcitx-utils/event.h>
#include <fcitx/inputcontext.h>
#include <fcitx/instance.h>
#include "candidate_navigation.hpp"

namespace fcitx {
// Native nonactivating renderer on the Fcitx thread. It never owns an engine or
// delivers text; callbacks are validated against the current input-context lease.
class CandidateMatrixWindow {
public:
    explicit CandidateMatrixWindow(Instance* instance);
    ~CandidateMatrixWindow();
    bool show(InputContext* ic, const CandidateNavigation& navigation,
              std::function<void(std::size_t)> select, std::function<void(int)> move);
    void hide();
    std::optional<std::size_t> digit(std::size_t index) const;
private:
    class Impl;
    std::unique_ptr<Impl> impl_;
};
}
