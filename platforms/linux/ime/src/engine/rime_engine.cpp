#include "rime_engine.hpp"

#include <cstring>
#include <mutex>
#include <thread>
#include <unordered_set>
#include <utility>
#include <vector>

#ifdef __GLIBC__
#include <malloc.h>
#endif

#include <rime_api.h>

#include "rime_key.hpp"
#include "rime_paths.hpp"
#include "rime_user_lock.hpp"

namespace rimes::linuxime {
namespace {

void SetError(std::string* error, std::string_view message) noexcept {
    if (error == nullptr) {
        return;
    }
    try {
        error->assign(message);
    } catch (...) {
    }
}

std::string DefaultLabel(int index) {
    return std::to_string((index + 1) % 10);
}

}  // namespace

class RimeEngine::Impl final {
public:
    bool Start(const RimeEngineOptions& options, std::string* error) noexcept {
        try {
            std::lock_guard<std::mutex> lock(mutex_);
            if (healthy_) {
                return true;
            }

            if (!LooksLikeSharedData(options.shared_data_dir)) {
                SetError(error, "shared data directory has no default.yaml");
                return false;
            }
            if (!EnsureDirectory(options.user_data_dir, error) ||
                !EnsureDirectory(options.log_dir, error)) {
                return false;
            }

            api_ = rime_get_api();
            if (api_ == nullptr || api_->setup == nullptr ||
                api_->initialize == nullptr || api_->finalize == nullptr ||
                api_->start_maintenance == nullptr ||
                api_->join_maintenance_thread == nullptr ||
                api_->create_session == nullptr || api_->destroy_session == nullptr ||
                api_->process_key == nullptr || api_->get_commit == nullptr ||
                api_->get_context == nullptr) {
                SetError(error, "librime API is incomplete");
                return false;
            }

            if (!user_lock_.Acquire(options.user_data_dir, error)) {
                return false;
            }

            shared_data_dir_ = options.shared_data_dir.string();
            user_data_dir_ = options.user_data_dir.string();
            log_dir_ = options.log_dir.string();

            RIME_STRUCT(RimeTraits, traits);
            traits.shared_data_dir = shared_data_dir_.c_str();
            traits.user_data_dir = user_data_dir_.c_str();
            traits.distribution_name = "RIMES";
            traits.distribution_code_name = "rimes";
            traits.distribution_version = "0.1.0";
            traits.app_name = "rime.rimes.linux";
            traits.min_log_level = 2;
            traits.log_dir = log_dir_.c_str();

            // setup() initializes glog. A second call in this process aborts
            // ("You called InitGoogleLogging() twice") after Stop()+Start().
            static bool setup_done = false;
            if (!setup_done) {
                api_->setup(&traits);
                setup_done = true;
            }
            api_->initialize(&traits);
            initialized_ = true;
            if (api_->set_notification_handler != nullptr) {
                api_->set_notification_handler(&Impl::OnRimeNotification, this);
            }

            const bool full_check =
                options.full_maintenance_check ||
                !std::filesystem::exists(options.user_data_dir / "build");
            if (!RunMaintenanceLocked(full_check, options.wait_for_maintenance, error)) {
                StopLocked();
                return false;
            }
            if (deploying_) {
                return true;
            }
            if (!FinishReadyLocked(error)) {
                StopLocked();
                return false;
            }
            return true;
        } catch (...) {
            try {
                std::lock_guard<std::mutex> lock(mutex_);
                StopLocked();
            } catch (...) {
            }
            SetError(error, "exception while starting librime");
            return false;
        }
    }

    void Stop() noexcept {
        try {
            {
                std::lock_guard<std::mutex> lock(mutex_);
                watch_stop_ = true;
            }
            {
                std::lock_guard<std::mutex> lock(callback_mutex_);
                deploy_ready_ = nullptr;
            }
            if (watch_thread_.joinable()) {
                watch_thread_.join();
            }
            std::lock_guard<std::mutex> lock(mutex_);
            StopLocked();
        } catch (...) {
        }
    }

    void SetDeployReadyCallback(RimeEngine::DeployReadyCallback callback) {
        std::lock_guard<std::mutex> lock(callback_mutex_);
        deploy_ready_ = std::move(callback);
    }

    bool IsHealthy() const noexcept {
        try {
            std::lock_guard<std::mutex> lock(mutex_);
            return healthy_ && api_ != nullptr;
        } catch (...) {
            return false;
        }
    }

    bool IsDeploying() const noexcept {
        try {
            std::lock_guard<std::mutex> lock(mutex_);
            return deploying_ && !healthy_;
        } catch (...) {
            return false;
        }
    }

    bool PollMaintenance(std::string* error) noexcept {
        try {
            std::lock_guard<std::mutex> lock(mutex_);
            if (healthy_ && api_ != nullptr) {
                return true;
            }
            if (!initialized_ || api_ == nullptr) {
                SetError(error, "librime is not initialized");
                return false;
            }
            if (api_->is_maintenance_mode != nullptr && api_->is_maintenance_mode() != 0) {
                return false;
            }
            // A live watcher already called (or is calling) join. Do not join
            // from the UI thread — that is the freeze we are avoiding.
            if (!async_watch_started_ && api_->join_maintenance_thread != nullptr) {
                api_->join_maintenance_thread();
                watch_joined_maintenance_ = true;
            }
            deploying_ = false;
            return FinishReadyLocked(error);
        } catch (...) {
            SetError(error, "exception while polling librime maintenance");
            return false;
        }
    }

    bool RunMaintenance(bool full_check, std::string* error) noexcept {
        return StartMaintenance(full_check, true, error);
    }

    bool StartBackgroundMaintenance(bool full_check, std::string* error) noexcept {
        return StartMaintenance(full_check, false, error);
    }

    bool StartMaintenance(bool full_check, bool wait, std::string* error) noexcept {
        try {
            std::lock_guard<std::mutex> lock(mutex_);
            if (!initialized_ || api_ == nullptr) {
                SetError(error, "librime is not initialized");
                return false;
            }
            if (!sessions_.empty()) {
                SetError(error, "librime maintenance requires all sessions to close");
                return false;
            }
            if (!RunMaintenanceLocked(full_check, wait, error)) {
                return false;
            }
            if (wait && !FinishReadyLocked(error)) {
                return false;
            }
            return true;
        } catch (...) {
            SetError(error, "exception while running librime maintenance");
            return false;
        }
    }

    SessionId CreateSession(std::string* error) noexcept {
        try {
            std::lock_guard<std::mutex> lock(mutex_);
            if (!healthy_ || api_ == nullptr) {
                SetError(error, "librime is not initialized");
                return 0;
            }
            const RimeSessionId session = api_->create_session();
            if (session == 0) {
                SetError(error, "librime session creation failed");
                return 0;
            }
            sessions_.insert(session);
            if (api_->select_schema != nullptr) {
                api_->select_schema(session, kDefaultSchemaId);
            }
            if (api_->set_option != nullptr) {
                api_->set_option(session, "ascii_mode", False);
            }
            return session;
        } catch (...) {
            SetError(error, "exception while creating a librime session");
            return 0;
        }
    }

    bool DestroySession(SessionId session, std::string* error) noexcept {
        try {
            std::lock_guard<std::mutex> lock(mutex_);
            if (!healthy_ || api_ == nullptr || session == 0 ||
                sessions_.erase(session) != 1) {
                SetError(error, "unknown or inactive librime session");
                return false;
            }
            api_->destroy_session(session);
            return true;
        } catch (...) {
            SetError(error, "exception while destroying a librime session");
            return false;
        }
    }

    bool SelectSchema(SessionId session,
                      std::string_view schema_id,
                      std::string* error) noexcept {
        try {
            std::lock_guard<std::mutex> lock(mutex_);
            if (!HasSessionLocked(session, error) || api_->select_schema == nullptr) {
                return false;
            }
            schema_storage_.assign(schema_id);
            if (api_->select_schema(session, schema_storage_.c_str()) == 0) {
                SetError(error, "librime rejected schema selection");
                return false;
            }
            return true;
        } catch (...) {
            SetError(error, "exception while selecting a schema");
            return false;
        }
    }

    bool SetOption(SessionId session,
                   std::string_view option,
                   bool value,
                   std::string* error) noexcept {
        try {
            std::lock_guard<std::mutex> lock(mutex_);
            if (!HasSessionLocked(session, error) || api_->set_option == nullptr) {
                return false;
            }
            option_storage_.assign(option);
            api_->set_option(session, option_storage_.c_str(), value ? True : False);
            return true;
        } catch (...) {
            SetError(error, "exception while setting a rime option");
            return false;
        }
    }

    bool ProcessKey(SessionId session,
                    std::int32_t keycode,
                    std::int32_t modifiers,
                    EngineSnapshot* output,
                    std::string* error) noexcept {
        if (output == nullptr) {
            SetError(error, "engine snapshot output is null");
            return false;
        }
        *output = EngineSnapshot{};
        try {
            std::lock_guard<std::mutex> lock(mutex_);
            if (!HasSessionLocked(session, error)) {
                return false;
            }
            output->handled = api_->process_key(session, keycode, modifiers) != 0;
            return CollectSnapshotLocked(session, output, error);
        } catch (...) {
            *output = EngineSnapshot{};
            SetError(error, "exception while processing a librime key event");
            return false;
        }
    }

    bool SelectCandidate(SessionId session,
                         int index_on_page,
                         EngineSnapshot* output,
                         std::string* error) noexcept {
        if (output == nullptr) {
            SetError(error, "engine snapshot output is null");
            return false;
        }
        *output = EngineSnapshot{};
        try {
            std::lock_guard<std::mutex> lock(mutex_);
            if (!HasSessionLocked(session, error)) {
                return false;
            }
            if (index_on_page < 0 || api_->select_candidate_on_current_page == nullptr) {
                SetError(error, "candidate index is out of range");
                return false;
            }
            output->handled =
                api_->select_candidate_on_current_page(
                    session, static_cast<size_t>(index_on_page)) != 0;
            return CollectSnapshotLocked(session, output, error);
        } catch (...) {
            *output = EngineSnapshot{};
            SetError(error, "exception while selecting a candidate");
            return false;
        }
    }

    bool ClearComposition(SessionId session,
                          EngineSnapshot* output,
                          std::string* error) noexcept {
        if (output == nullptr) {
            SetError(error, "engine snapshot output is null");
            return false;
        }
        *output = EngineSnapshot{};
        try {
            std::lock_guard<std::mutex> lock(mutex_);
            if (!HasSessionLocked(session, error)) {
                return false;
            }
            if (api_->clear_composition != nullptr) {
                api_->clear_composition(session);
            }
            output->handled = true;
            return CollectSnapshotLocked(session, output, error);
        } catch (...) {
            *output = EngineSnapshot{};
            SetError(error, "exception while clearing composition");
            return false;
        }
    }

    bool CommitComposition(SessionId session,
                           EngineSnapshot* output,
                           std::string* error) noexcept {
        if (output == nullptr) {
            SetError(error, "engine snapshot output is null");
            return false;
        }
        *output = EngineSnapshot{};
        try {
            std::lock_guard<std::mutex> lock(mutex_);
            if (!HasSessionLocked(session, error)) {
                return false;
            }
            if (api_->commit_composition != nullptr) {
                output->handled = api_->commit_composition(session) != 0;
            }
            return CollectSnapshotLocked(session, output, error);
        } catch (...) {
            *output = EngineSnapshot{};
            SetError(error, "exception while committing composition");
            return false;
        }
    }

    bool Refresh(SessionId session,
                 EngineSnapshot* output,
                 std::string* error) noexcept {
        if (output == nullptr) {
            SetError(error, "engine snapshot output is null");
            return false;
        }
        *output = EngineSnapshot{};
        try {
            std::lock_guard<std::mutex> lock(mutex_);
            if (!HasSessionLocked(session, error)) {
                return false;
            }
            output->handled = true;
            return CollectSnapshotLocked(session, output, error);
        } catch (...) {
            *output = EngineSnapshot{};
            SetError(error, "exception while refreshing engine state");
            return false;
        }
    }

private:
    bool HasSessionLocked(SessionId session, std::string* error) const noexcept {
        if (!healthy_ || api_ == nullptr || session == 0 ||
            sessions_.find(session) == sessions_.end()) {
            SetError(error, "unknown or inactive librime session");
            return false;
        }
        return true;
    }

    bool RunMaintenanceLocked(bool full_check, bool wait, std::string* error) noexcept {
        if (api_->start_maintenance == nullptr) {
            SetError(error, "librime maintenance API is unavailable");
            return false;
        }
        const bool started = api_->start_maintenance(full_check ? True : False) != 0;
        const bool in_maintenance =
            started ||
            (api_->is_maintenance_mode != nullptr && api_->is_maintenance_mode() != 0);
        if (!in_maintenance) {
            deploying_ = false;
            return true;
        }
        if (!wait) {
            deploying_ = true;
            healthy_ = false;
            StartWatchLocked();
            return true;
        }
        if (api_->join_maintenance_thread == nullptr) {
            SetError(error, "librime maintenance API is unavailable");
            return false;
        }
        api_->join_maintenance_thread();
        deploying_ = false;
        return true;
    }

    bool FinishReadyLocked(std::string* error) noexcept {
        const RimeSessionId smoke = api_->create_session();
        if (smoke == 0) {
            SetError(error, "librime smoke session creation failed");
            return false;
        }
        api_->destroy_session(smoke);
        healthy_ = true;
        deploying_ = false;
        ReleaseBuildHeap();
        return true;
    }

    static void ReleaseBuildHeap() noexcept {
#ifdef __GLIBC__
        malloc_trim(0);
#endif
    }

    bool CollectSnapshotLocked(SessionId session,
                               EngineSnapshot* output,
                               std::string* error) noexcept {
        if (api_->get_commit != nullptr && api_->free_commit != nullptr) {
            RIME_STRUCT(RimeCommit, commit);
            if (api_->get_commit(session, &commit) != 0) {
                const bool copied =
                    CopyBoundedUtf8(commit.text, kMaxTextBytes, &output->commit_text, error);
                api_->free_commit(&commit);
                if (!copied) {
                    return false;
                }
            }
        }

        if (api_->get_status != nullptr && api_->free_status != nullptr) {
            RIME_STRUCT(RimeStatus, status);
            if (api_->get_status(session, &status) != 0) {
                output->composing = status.is_composing != 0;
                output->ascii_mode = status.is_ascii_mode != 0;
                const bool copied =
                    CopyBoundedUtf8(status.schema_id, 128, &output->schema_id, error);
                api_->free_status(&status);
                if (!copied) {
                    return false;
                }
            }
        }

        if (api_->get_context == nullptr || api_->free_context == nullptr) {
            return true;
        }

        RIME_STRUCT(RimeContext, context);
        if (api_->get_context(session, &context) == 0) {
            return true;
        }

        bool ok = CopyBoundedUtf8(context.composition.preedit, kMaxTextBytes,
                                  &output->preedit, error);
        if (ok) {
            if (context.composition.cursor_pos < 0 ||
                static_cast<std::size_t>(context.composition.cursor_pos) >
                    output->preedit.size()) {
                SetError(error, "librime caret is outside the preedit");
                ok = false;
            } else {
                output->caret_utf8 =
                    static_cast<std::size_t>(context.composition.cursor_pos);
            }
        }

        if (ok && context.menu.num_candidates < 0) {
            SetError(error, "librime returned a negative candidate count");
            ok = false;
        }
        const int count = ok ? context.menu.num_candidates : 0;
        if (ok && count > static_cast<int>(kMaxCandidateCount)) {
            SetError(error, "librime returned too many candidates");
            ok = false;
        }
        if (ok && count > 0) {
            if (context.menu.candidates == nullptr || context.menu.page_size <= 0) {
                SetError(error, "librime returned inconsistent candidate metadata");
                ok = false;
            } else {
                output->page_no = context.menu.page_no;
                output->page_size = context.menu.page_size;
                output->highlighted = context.menu.highlighted_candidate_index;
                output->is_last_page = context.menu.is_last_page != 0;
                output->candidates.resize(static_cast<std::size_t>(count));
            }
        }

        for (int index = 0; ok && index < count; ++index) {
            EngineCandidate& candidate = output->candidates[static_cast<std::size_t>(index)];
            ok = CopyBoundedUtf8(context.menu.candidates[index].text, kMaxTextBytes,
                                 &candidate.text, error) &&
                 CopyBoundedUtf8(context.menu.candidates[index].comment, kMaxTextBytes,
                                 &candidate.comment, error);
            if (!ok) {
                break;
            }
            if (RIME_STRUCT_HAS_MEMBER(context, context.select_labels) &&
                context.select_labels != nullptr &&
                context.select_labels[index] != nullptr) {
                ok = CopyBoundedUtf8(context.select_labels[index], 16, &candidate.label,
                                     error);
            } else if (context.menu.select_keys != nullptr &&
                       context.menu.select_keys[index] != '\0') {
                candidate.label.assign(1, context.menu.select_keys[index]);
            } else {
                candidate.label = DefaultLabel(index);
            }
        }

        api_->free_context(&context);
        if (!ok) {
            *output = EngineSnapshot{};
            return false;
        }
        if (api_->get_input != nullptr) {
            const char* raw = api_->get_input(session);
            if (raw != nullptr && raw[0] != '\0') {
                if (!CopyBoundedUtf8(raw, kMaxTextBytes, &output->raw_input, error)) {
                    *output = EngineSnapshot{};
                    return false;
                }
            }
        }
        if (!output->preedit.empty()) {
            output->composing = true;
        }
        return true;
    }

    void StartWatchLocked() noexcept {
        if (watch_thread_.joinable()) {
            if (!watch_joined_maintenance_) {
                return;
            }
            watch_thread_.join();
            async_watch_started_ = false;
        }
        watch_stop_ = false;
        async_watch_started_ = true;
        watch_joined_maintenance_ = false;
        try {
            watch_thread_ = std::thread([this] { WatchMaintenance(); });
        } catch (...) {
            async_watch_started_ = false;
        }
    }

    void WatchMaintenance() noexcept {
        RimeApi* api = nullptr;
        try {
            std::lock_guard<std::mutex> lock(mutex_);
            api = api_;
        } catch (...) {
            return;
        }
        if (api != nullptr && api->join_maintenance_thread != nullptr) {
            api->join_maintenance_thread();
        }
        try {
            std::lock_guard<std::mutex> lock(mutex_);
            watch_joined_maintenance_ = true;
            if (watch_stop_) {
                return;
            }
        } catch (...) {
            return;
        }
        NotifyDeployReady();
    }

    void NotifyDeployReady() noexcept {
        // Do not coalesce: deploy/success can fire before
        // is_maintenance_mode() clears. The join watcher notifies again.
        RimeEngine::DeployReadyCallback callback;
        try {
            std::lock_guard<std::mutex> lock(callback_mutex_);
            callback = deploy_ready_;
        } catch (...) {
            return;
        }
        if (callback) {
            try {
                callback();
            } catch (...) {
            }
        }
    }

    static void OnRimeNotification(void* context,
                                   RimeSessionId,
                                   const char* message_type,
                                   const char* message_value) {
        auto* self = static_cast<Impl*>(context);
        if (self == nullptr || message_type == nullptr || message_value == nullptr) {
            return;
        }
        if (std::strcmp(message_type, "deploy") != 0) {
            return;
        }
        if (std::strcmp(message_value, "success") == 0 ||
            std::strcmp(message_value, "failure") == 0) {
            self->NotifyDeployReady();
        }
    }

    void StopLocked() noexcept {
        healthy_ = false;
        if (api_ != nullptr) {
            for (const SessionId session : sessions_) {
                api_->destroy_session(session);
            }
            sessions_.clear();
            if (initialized_ && api_->set_notification_handler != nullptr) {
                api_->set_notification_handler(nullptr, nullptr);
            }
            if (initialized_ && api_->join_maintenance_thread != nullptr &&
                !watch_joined_maintenance_ &&
                (deploying_ ||
                 (api_->is_maintenance_mode != nullptr &&
                  api_->is_maintenance_mode() != 0))) {
                api_->join_maintenance_thread();
                watch_joined_maintenance_ = true;
            }
            if (initialized_ && api_->finalize != nullptr) {
                api_->finalize();
            }
        }
        deploying_ = false;
        initialized_ = false;
        async_watch_started_ = false;
        watch_joined_maintenance_ = false;
        api_ = nullptr;
        shared_data_dir_.clear();
        user_data_dir_.clear();
        log_dir_.clear();
        ReleaseBuildHeap();
        user_lock_.Release();
    }

    RimeUserLock user_lock_;
    mutable std::mutex mutex_;
    std::mutex callback_mutex_;
    RimeApi* api_ = nullptr;
    bool initialized_ = false;
    bool healthy_ = false;
    bool deploying_ = false;
    bool watch_stop_ = false;
    bool async_watch_started_ = false;
    bool watch_joined_maintenance_ = false;
    std::thread watch_thread_;
    RimeEngine::DeployReadyCallback deploy_ready_;
    std::string shared_data_dir_;
    std::string user_data_dir_;
    std::string log_dir_;
    std::string schema_storage_;
    std::string option_storage_;
    std::unordered_set<SessionId> sessions_;
};

RimeEngine::RimeEngine() : impl_(std::make_unique<Impl>()) {}

RimeEngine::~RimeEngine() { Stop(); }

bool RimeEngine::Start(const RimeEngineOptions& options, std::string* error) noexcept {
    return impl_->Start(options, error);
}

void RimeEngine::Stop() noexcept { impl_->Stop(); }

void RimeEngine::SetDeployReadyCallback(DeployReadyCallback callback) {
    impl_->SetDeployReadyCallback(std::move(callback));
}

bool RimeEngine::IsHealthy() const noexcept { return impl_->IsHealthy(); }

bool RimeEngine::IsDeploying() const noexcept { return impl_->IsDeploying(); }

bool RimeEngine::PollMaintenance(std::string* error) noexcept {
    return impl_->PollMaintenance(error);
}

bool RimeEngine::RunMaintenance(bool full_check, std::string* error) noexcept {
    return impl_->RunMaintenance(full_check, error);
}

bool RimeEngine::StartBackgroundMaintenance(bool full_check,
                                            std::string* error) noexcept {
    return impl_->StartBackgroundMaintenance(full_check, error);
}

RimeEngine::SessionId RimeEngine::CreateSession(std::string* error) noexcept {
    return impl_->CreateSession(error);
}

bool RimeEngine::DestroySession(SessionId session, std::string* error) noexcept {
    return impl_->DestroySession(session, error);
}

bool RimeEngine::SelectSchema(SessionId session,
                              std::string_view schema_id,
                              std::string* error) noexcept {
    return impl_->SelectSchema(session, schema_id, error);
}

bool RimeEngine::SetOption(SessionId session,
                           std::string_view option,
                           bool value,
                           std::string* error) noexcept {
    return impl_->SetOption(session, option, value, error);
}

bool RimeEngine::ProcessKey(SessionId session,
                            std::int32_t keycode,
                            std::int32_t modifiers,
                            EngineSnapshot* output,
                            std::string* error) noexcept {
    return impl_->ProcessKey(session, keycode, modifiers, output, error);
}

bool RimeEngine::SelectCandidate(SessionId session,
                                 int index_on_page,
                                 EngineSnapshot* output,
                                 std::string* error) noexcept {
    return impl_->SelectCandidate(session, index_on_page, output, error);
}

bool RimeEngine::ClearComposition(SessionId session,
                                  EngineSnapshot* output,
                                  std::string* error) noexcept {
    return impl_->ClearComposition(session, output, error);
}

bool RimeEngine::CommitComposition(SessionId session,
                                   EngineSnapshot* output,
                                   std::string* error) noexcept {
    return impl_->CommitComposition(session, output, error);
}

bool RimeEngine::Refresh(SessionId session,
                         EngineSnapshot* output,
                         std::string* error) noexcept {
    return impl_->Refresh(session, output, error);
}

}  // namespace rimes::linuxime
