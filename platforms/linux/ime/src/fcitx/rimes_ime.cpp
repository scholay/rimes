#include "rimes_ime.hpp"

#include <filesystem>
#include <functional>

#include <fcitx-utils/log.h>
#include <fcitx-config/iniparser.h>
#include <fcitx/event.h>
#include <fcitx/inputcontextmanager.h>
#include <fcitx/userinterface.h>

#include "engine/rime_hooks.hpp"
#include "engine/rime_paths.hpp"
#include "rimes_state.hpp"

#ifndef RIMES_INSTALL_SHARED_DIR
#define RIMES_INSTALL_SHARED_DIR ""
#endif

namespace fcitx {
namespace {

FCITX_DEFINE_LOG_CATEGORY(rimes_log, "rimes");

}  // namespace

RimesIme::RimesIme(Instance* instance)
    : instance_(instance),
      factory_([this](InputContext& ic) { return new RimesState(this, &ic); }),
      alive_(std::make_shared<std::atomic<bool>>(true)) {
    reloadConfig();
    instance_->inputContextManager().registerProperty("rimesState", &factory_);
    dispatcher_.attach(&instance_->eventLoop());

    // fcitx5 time events are one-shot (sd_event / libuv). A setTime() poll
    // without setOneShot() fires once at +200 ms and never again — that left
    // status stuck on "Deploying". Notify from the maintenance thread instead.
    engine_.SetDeployReadyCallback([this, alive = alive_]() {
        dispatcher_.schedule([this, alive]() {
            if (alive && alive->load()) {
                HandleDeployReady();
            }
        });
    });

    auto paths = rimes::linuxime::ResolveEnginePaths(
        std::filesystem::path(RIMES_INSTALL_SHARED_DIR));
    rimes::linuxime::RimeEngineOptions options;
    options.shared_data_dir = paths.shared_data_dir;
    options.user_data_dir = paths.user_data_dir;
    options.log_dir = paths.log_dir;
    options.wait_for_maintenance = false;
    imported_schema_ = paths.imported_schema;

    std::string error;
    if (!engine_.Start(options, &error)) {
        FCITX_LOGC(rimes_log, Error) << "librime start failed: " << error;
    } else if (engine_.IsDeploying()) {
        FCITX_LOGC(rimes_log, Info)
            << "librime background deploy started; keys pass through until ready";
    }

    auto post = [this, alive = alive_](std::function<void()> work) {
        dispatcher_.schedule([this, alive, work = std::move(work)]() {
            if (alive && alive->load()) {
                work();
            }
        });
    };
    buffer_ = std::make_unique<BufferService>(instance_, post);
    capsule_ = std::make_unique<CapsuleService>(instance_, post);

    destroy_watch_ = instance_->watchEvent(
        EventType::InputContextDestroyed, EventWatcherPhase::Default,
        [this](Event& event) {
            auto& ic_event = static_cast<InputContextEvent&>(event);
            if (buffer_) {
                buffer_->OnInputContextDestroyed(ic_event.inputContext());
            }
            if (capsule_) {
                capsule_->OnInputContextDestroyed(ic_event.inputContext());
            }
        });
    capability_watch_ = instance_->watchEvent(
        EventType::InputContextCapabilityChanged, EventWatcherPhase::Default,
        [this](Event& event) {
            auto& cap = static_cast<CapabilityChangedEvent&>(event);
            const bool password = cap.newFlags().test(CapabilityFlag::Password);
            if (password) {
                if (auto* state = cap.inputContext()->propertyFor(&factory_)) state->reset();
            }
            if (buffer_) {
                buffer_->OnPasswordField(cap.inputContext(), password);
            }
            if (capsule_) {
                capsule_->OnPasswordField(cap.inputContext(), password);
            }
        });
}

void RimesIme::reloadConfig() { readAsIni(config_, "conf/rimes.conf"); }
void RimesIme::setConfig(const RawConfig& config) {
    config_.load(config, true);
    safeSaveAsIni(config_, "conf/rimes.conf");
    instance_->inputContextManager().foreachFocused([this](InputContext* ic) {
        if (auto* state = ic->propertyFor(&factory_)) state->refreshCandidates();
        return true;
    });
}

RimesIme::~RimesIme() {
    if (alive_) {
        alive_->store(false);
    }
    engine_.SetDeployReadyCallback(nullptr);
    engine_.Stop();
    dispatcher_.detach();
}

void RimesIme::HandleDeployReady() {
    std::string error;
    if (!engine_.PollMaintenance(&error)) {
        if (engine_.IsDeploying()) {
            return;
        }
        FCITX_LOGC(rimes_log, Error) << "librime deploy failed: " << error;
        return;
    }
    OnDeployReady();
}

void RimesIme::OnDeployReady() {
    if (deploy_announced_) {
        return;
    }
    deploy_announced_ = true;
    FCITX_LOGC(rimes_log, Info) << "librime deploy finished";
    instance_->inputContextManager().foreachFocused([this](InputContext* ic) {
        if (instance_->inputMethod(ic) == "rimes") {
            instance_->showInputMethodInformation(ic);
            ic->updateUserInterface(UserInterfaceComponent::StatusArea);
        }
        return true;
    });
}

void RimesIme::keyEvent(const InputMethodEntry& entry, KeyEvent& keyEvent) {
    FCITX_UNUSED(entry);
    auto* state = keyEvent.inputContext()->propertyFor(&factory_);
    if (state == nullptr) {
        return;
    }
    if (buffer_ && buffer_->HandleEarlyKey(keyEvent, state->composing())) {
        return;
    }
    if (capsule_ && capsule_->HandleEarlyKey(keyEvent)) {
        return;
    }
    state->keyEvent(keyEvent);
}

void RimesIme::activate(const InputMethodEntry& entry, InputContextEvent& event) {
    FCITX_UNUSED(entry);
    auto* state = event.inputContext()->propertyFor(&factory_);
    if (state != nullptr) {
        state->activate();
    }
    if (buffer_) {
        buffer_->OnActivate(event.inputContext());
    }
    if (capsule_) {
        capsule_->OnActivate(event.inputContext());
    }
}

void RimesIme::deactivate(const InputMethodEntry& entry, InputContextEvent& event) {
    FCITX_UNUSED(entry);
    // Drop capture and wipe client preedit before RimesState::reset paints
    // the input panel, so focus-out cannot commit a leftover guard.
    if (buffer_) {
        buffer_->OnDeactivate(event.inputContext(),
                              event.type() == EventType::InputContextSwitchInputMethod);
    }
    if (capsule_) {
        capsule_->OnDeactivate(event.inputContext(),
                               event.type() == EventType::InputContextSwitchInputMethod);
    }
    auto* state = event.inputContext()->propertyFor(&factory_);
    if (state != nullptr) {
        state->deactivate(event);
    }
}

void RimesIme::reset(const InputMethodEntry& entry, InputContextEvent& event) {
    FCITX_UNUSED(entry);
    auto* state = event.inputContext()->propertyFor(&factory_);
    if (state != nullptr) {
        state->reset();
    }
}

std::string RimesIme::subMode(const InputMethodEntry& entry, InputContext& inputContext) {
    FCITX_UNUSED(entry);
    if (engine_.IsDeploying()) {
        return "Deploying";
    }
    auto* state = inputContext.propertyFor(&factory_);
    if (state == nullptr) {
        return {};
    }
    return state->schemaId();
}

void RimesIme::commitText(InputContext* ic, std::string_view text) {
    static_cast<void>(rimes::linuxime::kCommitHookNote);
    if (ic == nullptr || text.empty()) {
        return;
    }
    if (buffer_ && buffer_->OnCommit(ic, text)) {
        return;
    }
    ic->commitString(std::string(text));
}

void RimesIme::applySnapshot(InputContext* ic,
                             const rimes::linuxime::EngineSnapshot& snapshot) {
    if (ic == nullptr) {
        return;
    }
    if (!snapshot.commit_text.empty()) {
        commitText(ic, snapshot.commit_text);
    }
}

AddonInstance* RimesImeFactory::create(AddonManager* manager) {
    return new RimesIme(manager->instance());
}

}  // namespace fcitx

FCITX_ADDON_FACTORY(fcitx::RimesImeFactory);
