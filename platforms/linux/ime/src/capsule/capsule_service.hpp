#pragma once

#include <atomic>
#include <functional>
#include <sys/types.h>
#include <memory>
#include <mutex>
#include <string>
#include <string_view>
#include <thread>
#include <vector>

#include <fcitx-utils/event.h>
#include <fcitx/event.h>
#include <fcitx/inputcontext.h>
#include <fcitx/instance.h>

#include "capsule_model.hpp"
#include "capsule_protocol.hpp"
#include "capsule_store.hpp"

namespace fcitx {

class CapsuleService {
public:
    using PostFn = std::function<void(std::function<void()>)>;

    CapsuleService(Instance* instance, PostFn post);
    ~CapsuleService();

    CapsuleService(const CapsuleService&) = delete;
    CapsuleService& operator=(const CapsuleService&) = delete;

    rimes::capsule::CapsuleModel& model() { return model_; }
    const rimes::capsule::CapsuleModel& model() const { return model_; }

    bool HandleEarlyKey(KeyEvent& event);
    void OnActivate(InputContext* ic);
    void OnDeactivate(InputContext* ic, bool switching_im);
    void OnInputContextDestroyed(InputContext* ic);
    void OnPasswordField(InputContext* ic, bool password);
    void OnSessionProtection(bool protected_session);

    void Toggle(InputContext* ic);
    void Show(InputContext* ic);
    void Close();
    void SetEnabled(bool enabled);
    bool Activate();
    bool CopySelected();

    std::string SocketPath() const { return socket_path_; }
    void Publish();

private:
    bool session_protected_ = false;
    bool field_protected_ = false;
    struct Client {
        int fd = -1;
        std::string incoming;
    };

    static std::string TokenFor(InputContext* ic);
    static bool IsToggleHotkey(const KeyEvent& event);
    static bool IsReturnKey(const Key& key);
    static bool IsPrintableAscii(const KeyEvent& event, char* out);

    InputContext* LiveTarget() const;
    bool ArmedFor(InputContext* ic) const;
    void ReloadNotes();
    void DropSession(std::string_view reason);
    void ArmFocusGraceTimer();
    void CancelFocusGraceTimer();
    bool DeliverNote(const rimes::capsule::Card& card);
    void HandleCommand(const rimes::capsule::Command& command);
    void EnsureUi();
    void ReapUi();
    void ReplaceDroppedUi();
    int UiClientCount();
    void StartSocket();
    void StopSocket();
    void SocketLoop();
    void AcceptClient();
    void ReadClient(Client* client);
    void CloseClient(int fd);
    void WriteAll(const std::string& payload);
    void ScheduleUiRespawn();
    void ArmUiRespawnTimer(int delay_us);
    bool HasUiClients();

    Instance* instance_;
    PostFn post_;
    rimes::capsule::ContentStore store_;
    rimes::capsule::CapsuleModel model_;
    std::string socket_path_;
    std::string dump_path_;
    bool enabled_ = true;
    int listen_fd_ = -1;
    std::vector<Client> clients_;
    std::recursive_mutex clients_mu_;
    std::thread socket_thread_;
    std::atomic<bool> running_{false};
    std::unique_ptr<EventSourceTime> focus_grace_timer_;
    std::unique_ptr<EventSourceTime> ui_respawn_timer_;
    pid_t ui_pid_ = 0;
    pid_t dropped_ui_pid_ = 0;
    int ui_respawn_attempt_ = 0;
    int focus_grace_ms_ = 5000;
    std::string pending_unfocus_token_;
    bool headless_ = false;
};

}  // namespace fcitx
