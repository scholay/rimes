#pragma once

#include <fcitx/event.h>
#include <fcitx/inputcontext.h>
#include <fcitx/inputcontextproperty.h>

#include "engine/rime_engine.hpp"
#include "rimes_ime.hpp"
#include "candidate_navigation.hpp"
#include "candidate_matrix_window.hpp"
#include <set>

namespace fcitx {

class RimesState : public InputContextProperty {
public:
    RimesState(RimesIme* ime, InputContext* ic);
    ~RimesState() override;

    void keyEvent(KeyEvent& event);
    void activate();
    void reset();
    void deactivate(const InputContextEvent& event);
    void selectCandidate(int index);
    void page(bool next);
    void refreshCandidates();
    void applySnapshot(const rimes::linuxime::EngineSnapshot& snapshot);
    std::string schemaId() const { return schema_id_; }
    bool composing() const { return composing_; }

private:
    rimes::linuxime::RimeEngine::SessionId EnsureSession();
    std::int32_t ModifierMask(const KeyEvent& event) const;
    bool HandleCandidateKey(KeyEvent& event);
    std::optional<rimes::linuxime::EngineSnapshot> StepCandidatePage(int delta);
    void SelectMatrixIndex(std::size_t index);
    void MoveMatrixRow(int delta);
    void UpdateUI(const rimes::linuxime::EngineSnapshot& snapshot);

    CandidateNavigation navigation_;
    std::unique_ptr<CandidateMatrixWindow> matrix_;
    rimes::linuxime::EngineSnapshot snapshot_;
    std::set<std::uint32_t> owned_keys_;
    std::uint64_t candidate_epoch_ = 0;
    bool matrix_visible_ = false;
    RimesIme* ime_;
    InputContext* ic_;
    rimes::linuxime::RimeEngine::SessionId session_ = 0;
    std::string schema_id_;
    bool composing_ = false;
};

}  // namespace fcitx
