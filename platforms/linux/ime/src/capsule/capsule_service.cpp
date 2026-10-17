#include "session/protected_input.hpp"
#include "capsule_service.hpp"

#include <algorithm>
#include <cerrno>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <poll.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

#include <fcitx-utils/capabilityflags.h>
#include <fcitx-utils/key.h>
#include <fcitx-utils/log.h>
#include <fcitx/inputcontextmanager.h>

#include "buffer_process.hpp"
#include "buffer_protocol.hpp"

namespace fcitx {
namespace {

FCITX_DEFINE_LOG_CATEGORY(rimes_capsule_log, "rimes.capsule");

constexpr int kDefaultFocusGraceMs = 5000;

int FocusGraceMsFromEnv() {
    const char* value = std::getenv("RIMES_CAPSULE_FOCUS_GRACE_MS");
    if (value == nullptr || value[0] == '\0') {
        return kDefaultFocusGraceMs;
    }
    char* end = nullptr;
    const auto parsed = std::strtol(value, &end, 10);
    if (end == value || parsed < 50 || parsed > 30000) {
        return kDefaultFocusGraceMs;
    }
    return static_cast<int>(parsed);
}

std::string DefaultSocketPath() {
    if (const char* override_path = std::getenv("RIMES_CAPSULE_SOCKET")) {
        if (override_path[0] != '\0') {
            return override_path;
        }
    }
    if (const char* runtime = std::getenv("XDG_RUNTIME_DIR")) {
        return std::string(runtime) + "/rimes-capsule.sock";
    }
    return "/tmp/rimes-capsule-" + std::to_string(geteuid()) + ".sock";
}

bool EnvFlag(const char* name) {
    const char* value = std::getenv(name);
    return value != nullptr && value[0] != '\0' && std::strcmp(value, "0") != 0;
}

int SetCloexec(int fd) {
    const int flags = fcntl(fd, F_GETFD, 0);
    if (flags >= 0) {
        fcntl(fd, F_SETFD, flags | FD_CLOEXEC);
    }
    const int status = fcntl(fd, F_GETFL, 0);
    if (status >= 0) {
        fcntl(fd, F_SETFL, status | O_NONBLOCK);
    }
    return fd;
}

std::string FindUiBinary() {
    if (const char* override_path = std::getenv("RIMES_CAPSULE_UI")) {
        if (override_path[0] != '\0') {
            return override_path;
        }
    }
    const char* candidates[] = {
        "/usr/libexec/rimes/rimes-capsule",
        "/usr/lib/rimes/rimes-capsule",
        "/usr/bin/rimes-capsule",
        "/usr/local/bin/rimes-capsule",
        nullptr,
    };
    for (const char* const* path = candidates; *path != nullptr; ++path) {
        if (access(*path, X_OK) == 0) {
            return *path;
        }
    }
    if (const char* path_env = std::getenv("PATH")) {
        std::string remaining = path_env;
        while (!remaining.empty()) {
            const auto split = remaining.find(':');
            const std::string dir = remaining.substr(0, split);
            const std::string candidate = dir + "/rimes-capsule";
            if (access(candidate.c_str(), X_OK) == 0) {
                return candidate;
            }
            if (split == std::string::npos) {
                break;
            }
            remaining = remaining.substr(split + 1);
        }
    }
    return {};
}

}  // namespace

CapsuleService::CapsuleService(Instance* instance, PostFn post)
    : instance_(instance),
      post_(std::move(post)),
      store_(rimes::capsule::ContentStore::DefaultRoot()),
      socket_path_(DefaultSocketPath()),
      dump_path_(std::getenv("RIMES_CAPSULE_DUMP") ? std::getenv("RIMES_CAPSULE_DUMP") : ""),
      focus_grace_ms_(FocusGraceMsFromEnv()),
      headless_(EnvFlag("RIMES_CAPSULE_HEADLESS")) {
    ReloadNotes();
    StartSocket();
    Publish();
}

CapsuleService::~CapsuleService() {
    alive_->store(false); storage_jobs_.Shutdown();
    CancelFocusGraceTimer();
    ui_respawn_timer_.reset();
    StopSocket();
    ReapUi();
}

std::string CapsuleService::TokenFor(InputContext* ic) {
    if (ic == nullptr) {
        return {};
    }
    return std::to_string(reinterpret_cast<std::uintptr_t>(ic));
}

bool CapsuleService::IsToggleHotkey(const KeyEvent& event) {
    if (event.isRelease()) {
        return false;
    }
    const auto& key = event.rawKey();
    const bool shift = key.states().test(KeyState::Shift);
    const bool ctrl = key.states().test(KeyState::Ctrl);
    const bool super = key.states().test(KeyState::Super);
    const bool letter_v = key.check(FcitxKey_V) || key.check(FcitxKey_v) ||
                          key.sym() == FcitxKey_V || key.sym() == FcitxKey_v;
    return letter_v && shift && (ctrl || super) && !(ctrl && super);
}

bool CapsuleService::IsReturnKey(const Key& key) {
    return key.check(FcitxKey_Return) || key.check(FcitxKey_KP_Enter);
}

bool CapsuleService::IsPrintableAscii(const KeyEvent& event, char* out) {
    if (event.isRelease() || out == nullptr) {
        return false;
    }
    const auto states = event.rawKey().states();
    if (states.test(KeyState::Ctrl) || states.test(KeyState::Alt) ||
        states.test(KeyState::Super)) {
        return false;
    }
    const auto sym = static_cast<std::uint32_t>(event.key().sym());
    if (sym < 0x20 || sym > 0x7e) {
        return false;
    }
    *out = static_cast<char>(sym);
    return true;
}

InputContext* CapsuleService::LiveTarget() const {
    InputContext* found = nullptr;
    if (!instance_) return nullptr;
    instance_->inputContextManager().foreachFocused([&](InputContext* ic) {
        if (model_.arms(TokenFor(ic))) {
            found = ic;
            return false;
        }
        return true;
    });
    return found;
}

bool CapsuleService::ArmedFor(InputContext* ic) const {
    return ic != nullptr && model_.arms(TokenFor(ic));
}

void CapsuleService::ReloadNotes(std::string selected_id) {
    if (reload_cancel_) reload_cancel_->store(true);
    reload_cancel_ = std::make_shared<std::atomic<bool>>(false);
    const auto cancelled = reload_cancel_;
    model_.set_loading(true);
    const auto root = store_.root();
    storage_jobs_.Run(cancelled, [this, root, cancelled, alive = alive_, post = post_, selected_id] {
        rimes::capsule::ContentStore store(root);
        std::vector<rimes::capsule::Record> records;
        std::string error;
        auto status = store.SeedIfNeeded(&error);
        if (status == rimes::capsule::StoreStatus::Ok) status = store.ListAll(&records, &error);
        if (!alive->load() || cancelled->load()) return;
        post([this, alive, cancelled, status, selected_id, records = std::move(records)] {
            if (!alive->load() || cancelled->load()) return;
            model_.set_loading(false);
            if (status == rimes::capsule::StoreStatus::Ok) model_.LoadCards(records);
            else model_.LoadCards({});
            if (!selected_id.empty()) { rimes::capsule::Command selection; selection.id = selected_id; SelectIdentity(selection); }
            Publish();
        });
    });
}
void CapsuleService::SetModuleEnabled(rimes::capsule::Module module, bool enabled) {
    model_.EnableModule(module, enabled);
    if (enabled) ReloadNotes();
    Publish();
}
bool CapsuleService::AllowsModule() {
    if (!Enabled() || !model_.ModuleEnabled(model_.module()) || model_.password_field()) return false;
    if (!validate_module_) return true;
    try { return validate_module_(model_.module()) && model_.ModuleEnabled(model_.module()); }
    catch (const std::exception&) { return false; }
}
void CapsuleService::Manage() {
    if (!Enabled() || model_.password_field()) return;
    model_.set_managing(true); model_.Disarm("manage");
    pending_unfocus_token_.clear(); CancelFocusGraceTimer();
    ReloadNotes(); model_.set_visible(true); EnsureUi(); Publish();
}
void CapsuleService::ReturnToRail() {
    model_.set_managing(false); model_.Disarm("rail");
    pending_unfocus_token_.clear(); CancelFocusGraceTimer();
    ReloadNotes(); model_.set_visible(true); EnsureUi(); Publish();
}
bool CapsuleService::SelectIdentity(const rimes::capsule::Command& command) {
    if (command.id.empty()) { if (command.index >= 0) model_.Select(command.index); return true; }
    const auto& cards = model_.cards();
    for (std::size_t i = 0; i < cards.size(); ++i) if (cards[i].id == command.id) { model_.Select(static_cast<int>(i)); return true; }
    return false;
}

void CapsuleService::DropSession(std::string_view reason) {
    FCITX_UNUSED(reason);
    pending_unfocus_token_.clear();
    CancelFocusGraceTimer();
    model_.Disarm(reason);
    Publish();
}

void CapsuleService::OnPasswordField(InputContext* ic, bool password) {
    if (ic && !ic->hasFocus()) return;
    field_protected_ = password;
    if (password || session_protected_) {
        model_.Hide();
        model_.set_password_field(true);
        Publish();
        return;
    }
    if (model_.password_field()) {
        model_.set_password_field(false);
        Publish();
    }
}

void CapsuleService::OnSessionProtection(bool protected_session) {
    if (session_protected_ == protected_session) return;
    session_protected_ = protected_session;
    pending_unfocus_token_.clear(); CancelFocusGraceTimer();
    if (protected_session) model_.Hide();
    model_.set_password_field(session_protected_ || field_protected_);
    Publish();
}

void CapsuleService::Toggle(InputContext* ic) {
    if (!model_.visible()) {
        Show(ic);
        return;
    }
    // Visible but disarmed (field switch): one hotkey re-arms this IC.
    // A second press, while armed here, closes.
    if (ic != nullptr && !ArmedFor(ic)) {
        Show(ic);
        return;
    }
    Close();
}

void CapsuleService::Show(InputContext* ic) {
    model_.set_managing(false);
    if (!enabled_ || ic == nullptr) {
        return;
    }
    const bool password = ProtectedInput(ic->capabilityFlags());
    OnPasswordField(ic, password);
    if (password || model_.password_field()) {
        return;
    }
    ReloadNotes();
    model_.set_visible(true);
    model_.set_armed(true);
    model_.set_token(TokenFor(ic));
    pending_unfocus_token_.clear();
    CancelFocusGraceTimer();
    EnsureUi();
    Publish();
}

void CapsuleService::Close() {
    model_.Hide();
    pending_unfocus_token_.clear();
    CancelFocusGraceTimer();
    Publish();
}

void CapsuleService::ShowDetached() {
    model_.set_managing(false);
    if (!Enabled() || model_.password_field()) return;
    model_.Disarm("detached-open");
    pending_unfocus_token_.clear(); CancelFocusGraceTimer();
    ReloadNotes(); model_.set_visible(true); EnsureUi(); Publish();
}

void CapsuleService::SetEnabled(bool enabled) {
    if (enabled_ == enabled) return;
    enabled_ = enabled;
    if (!enabled_) Close();
}

bool CapsuleService::DeliverNote(const rimes::capsule::Card& card) {
    if (!AllowsModule() || model_.managing()) return false;
    InputContext* ic = LiveTarget();
    if (ic == nullptr || card.payload.empty() || card.kind != rimes::capsule::Kind::Note) {
        return false;
    }
    if (ProtectedInput(ic->capabilityFlags()) || model_.password_field()) {
        return false;
    }
    if (!model_.arms(TokenFor(ic))) {
        return false;
    }
    ic->commitString(card.payload);
    return true;
}

bool CapsuleService::Activate() {
    if (!AllowsModule() || model_.managing()) { Publish(); return false; }
    const auto* card = model_.Selected();
    if (card == nullptr) {
        return false;
    }
    rimes::capsule::Record record;
    std::string error;
    if (store_.Get(card->id, &record, &error) != rimes::capsule::StoreStatus::Ok) {
        return false;
    }
    if (record.revision != card->revision) { ReloadNotes(); return false; }
    rimes::capsule::Card fresh = *card;
    fresh.payload = record.content;
    fresh.kind = record.kind;
    if (!DeliverNote(fresh)) {
        return false;
    }
    Close();
    return true;
}

bool CapsuleService::CopySelected() {
    if (!AllowsModule()) { Publish(); return false; }
    const auto* card = model_.Selected();
    if (card == nullptr || card->kind != rimes::capsule::Kind::Note) {
        return false;
    }
    rimes::capsule::Record record;
    std::string error;
    if (store_.Get(card->id, &record, &error) != rimes::capsule::StoreStatus::Ok) {
        return false;
    }
    if (record.revision != card->revision || !AllowsModule()) { ReloadNotes(); return false; }
    model_.set_last_copied(record.content);
    Publish();
    return true;
}

bool CapsuleService::HandleEarlyKey(KeyEvent& event) {
    if (!Enabled() || model_.managing()) return false;
    InputContext* ic = event.inputContext();
    if (ic == nullptr) {
        return false;
    }
    OnPasswordField(ic, ProtectedInput(ic->capabilityFlags()));
    if (!managed_hotkey_ && IsToggleHotkey(event)) {
        Toggle(ic);
        event.filterAndAccept();
        return true;
    }
    if (!ArmedFor(ic) || event.isRelease()) {
        return false;
    }
    const auto& key = event.rawKey();
    if (key.check(FcitxKey_Escape)) {
        Close();
        event.filterAndAccept();
        return true;
    }
    if (IsReturnKey(key)) {
        Activate();
        event.filterAndAccept();
        return true;
    }
    if (key.check(FcitxKey_Tab)) {
        const int offset = key.states().test(KeyState::Shift) ? -1 : 1;
        model_.CycleModule(offset);
        ReloadNotes();
        Publish();
        event.filterAndAccept();
        return true;
    }
    if (key.check(FcitxKey_Left) || key.check(FcitxKey_KP_Left)) {
        model_.Move(-1);
        Publish();
        event.filterAndAccept();
        return true;
    }
    if (key.check(FcitxKey_Right) || key.check(FcitxKey_KP_Right)) {
        model_.Move(1);
        Publish();
        event.filterAndAccept();
        return true;
    }
    if (key.check(FcitxKey_BackSpace)) {
        model_.backspace_query();
        Publish();
        event.filterAndAccept();
        return true;
    }
    if (key.states().test(KeyState::Ctrl) && !key.states().test(KeyState::Alt) &&
        !key.states().test(KeyState::Super)) {
        const auto sym = key.sym();
        if (sym == FcitxKey_c || sym == FcitxKey_C) {
            CopySelected();
            event.filterAndAccept();
            return true;
        }
        int digit = -1;
        if (sym >= FcitxKey_1 && sym <= FcitxKey_9) {
            digit = static_cast<int>(sym - FcitxKey_1);
        } else if (sym >= FcitxKey_KP_1 && sym <= FcitxKey_KP_9) {
            digit = static_cast<int>(sym - FcitxKey_KP_1);
        }
        if (digit >= 0) {
            model_.Select(digit);
            Activate();
            event.filterAndAccept();
            return true;
        }
    }
    char printable = 0;
    if (IsPrintableAscii(event, &printable)) {
        model_.append_query(printable);
        Publish();
        event.filterAndAccept();
        return true;
    }
    return false;
}

void CapsuleService::OnActivate(InputContext* ic) {
    if (ic == nullptr) {
        return;
    }
    OnPasswordField(ic, ProtectedInput(ic->capabilityFlags()));
    const auto token = TokenFor(ic);
    if (!model_.visible()) {
        return;
    }
    if (!pending_unfocus_token_.empty() && pending_unfocus_token_ == token) {
        pending_unfocus_token_.clear();
        CancelFocusGraceTimer();
        // Same-IC reactivation is a field switch. Do not keep the session.
        DropSession("same-ic");
        return;
    }
    if (model_.armed() && model_.token() != token) {
        DropSession("other-ic");
        return;
    }
    if (model_.armed() && model_.token() == token) {
        return;
    }
}

void CapsuleService::OnDeactivate(InputContext* ic, bool switching_im) {
    // Fcitx disables the IM on CapabilityFlag::Password (switch-IM
    // deactivate). Mark the field before Close() so the snapshot stays
    // honest even though later keys never reach HandleEarlyKey.
    if (ic != nullptr) {
        OnPasswordField(ic, ProtectedInput(ic->capabilityFlags()));
    }
    if (switching_im && !model_.managing()) {
        Close();
        return;
    }
    if (ic == nullptr || !model_.visible()) {
        return;
    }
    if (model_.arms(TokenFor(ic))) {
        pending_unfocus_token_ = TokenFor(ic);
        ArmFocusGraceTimer();
    }
}

void CapsuleService::OnInputContextDestroyed(InputContext* ic) {
    if (ic == nullptr) {
        return;
    }
    if (model_.arms(TokenFor(ic)) || pending_unfocus_token_ == TokenFor(ic)) {
        DropSession("destroyed");
    }
}

void CapsuleService::ArmFocusGraceTimer() {
    if (instance_ == nullptr) {
        return;
    }
    focus_grace_timer_ = instance_->eventLoop().addTimeEvent(
        CLOCK_MONOTONIC, now(CLOCK_MONOTONIC) + focus_grace_ms_ * 1000, 0,
        [this](EventSourceTime*, uint64_t) {
            if (!pending_unfocus_token_.empty()) {
                DropSession("focus-grace");
            }
            return true;
        });
}

void CapsuleService::CancelFocusGraceTimer() {
    focus_grace_timer_.reset();
}

void CapsuleService::HandleCommand(const rimes::capsule::Command& command) {
    if (model_.password_field() && command.op != rimes::capsule::CommandOp::Hello &&
        command.op != rimes::capsule::CommandOp::Status && command.op != rimes::capsule::CommandOp::Close) {
        Publish(); return;
    }
    InputContext* ic = LiveTarget();
    if (ic == nullptr && instance_) {
        instance_->inputContextManager().foreachFocused([&](InputContext* focused) {
            ic = focused;
            return false;
        });
    }
    switch (command.op) {
        case rimes::capsule::CommandOp::Hello:
            break;
        case rimes::capsule::CommandOp::Status:
        case rimes::capsule::CommandOp::Refresh:
            ReloadNotes(command.id);
            break;
        case rimes::capsule::CommandOp::Toggle:
            Toggle(ic);
            break;
        case rimes::capsule::CommandOp::Show:
            Show(ic);
            break;
        case rimes::capsule::CommandOp::Close:
            Close();
            break;
        case rimes::capsule::CommandOp::Next:
            model_.Move(1);
            break;
        case rimes::capsule::CommandOp::Prev:
            model_.Move(-1);
            break;
        case rimes::capsule::CommandOp::Select:
            SelectIdentity(command);
            break;
        case rimes::capsule::CommandOp::Tab:
            model_.set_tab(rimes::capsule::TabFromRaw(command.text));
            ReloadNotes();
            break;
        case rimes::capsule::CommandOp::Activate:
            if (SelectIdentity(command)) Activate();
            break;
        case rimes::capsule::CommandOp::Copy:
            if (SelectIdentity(command)) CopySelected();
            break;
        case rimes::capsule::CommandOp::Search:
            model_.set_query(command.text);
            break;
        case rimes::capsule::CommandOp::Module:
            if (const auto module = rimes::capsule::ModuleFromRaw(command.text)) model_.set_module(*module);
            ReloadNotes();
            break;
        case rimes::capsule::CommandOp::Filter:
            model_.set_filter(command.text);
            break;
        case rimes::capsule::CommandOp::Manage:
            Manage();
            break;
        case rimes::capsule::CommandOp::Rail:
            ReturnToRail();
            break;
        case rimes::capsule::CommandOp::Unknown:
            break;
    }
    Publish();
}

void CapsuleService::EnsureUi() {
    if (headless_ || !model_.visible()) {
        return;
    }
    ReapUi();
    if (ui_pid_ > 0) {
        return;
    }
    const auto binary = FindUiBinary();
    if (binary.empty()) {
        FCITX_LOGC(rimes_capsule_log, Info) << "rimes-capsule UI is not installed";
        return;
    }
    const pid_t pid = fork();
    if (pid < 0) {
        return;
    }
    if (pid == 0) {
        execl(binary.c_str(), "rimes-capsule", "--socket", socket_path_.c_str(),
              static_cast<char*>(nullptr));
        _exit(127);
    }
    ui_pid_ = pid;
}

void CapsuleService::ReapUi() {
    if (ui_pid_ <= 0) {
        return;
    }
    if (rimes::buffer::UiProcessGone(ui_pid_)) {
        ui_pid_ = 0;
    }
}

void CapsuleService::ReplaceDroppedUi() {
    if (!rimes::buffer::ShouldForceUiRespawn(ui_pid_, dropped_ui_pid_)) {
        return;
    }
    rimes::buffer::DiscardUiProcess(ui_pid_);
    ui_pid_ = 0;
}

int CapsuleService::UiClientCount() {
    std::lock_guard<std::recursive_mutex> lock(clients_mu_);
    return static_cast<int>(clients_.size());
}

void CapsuleService::StartSocket() {
    unlink(socket_path_.c_str());
    listen_fd_ = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (listen_fd_ < 0) {
        FCITX_LOGC(rimes_capsule_log, Error) << "capsule socket() failed";
        return;
    }
    SetCloexec(listen_fd_);
    sockaddr_un address{};
    address.sun_family = AF_UNIX;
    if (socket_path_.size() >= sizeof(address.sun_path)) {
        close(listen_fd_);
        listen_fd_ = -1;
        return;
    }
    std::strncpy(address.sun_path, socket_path_.c_str(), sizeof(address.sun_path) - 1);
    if (bind(listen_fd_, reinterpret_cast<sockaddr*>(&address), sizeof(address)) != 0 ||
        listen(listen_fd_, 8) != 0) {
        FCITX_LOGC(rimes_capsule_log, Error) << "capsule bind/listen failed: " << socket_path_;
        close(listen_fd_);
        listen_fd_ = -1;
        return;
    }
    chmod(socket_path_.c_str(), 0600);
    running_.store(true);
    socket_thread_ = std::thread([this] { SocketLoop(); });
}

void CapsuleService::StopSocket() {
    running_.store(false);
    if (listen_fd_ >= 0) {
        shutdown(listen_fd_, SHUT_RDWR);
    }
    {
        std::lock_guard<std::recursive_mutex> lock(clients_mu_);
        for (auto& client : clients_) {
            if (client.fd >= 0) {
                shutdown(client.fd, SHUT_RDWR);
            }
        }
    }
    if (socket_thread_.joinable()) {
        socket_thread_.join();
    }
    {
        std::lock_guard<std::recursive_mutex> lock(clients_mu_);
        for (auto& client : clients_) {
            if (client.fd >= 0) {
                close(client.fd);
            }
        }
        clients_.clear();
    }
    if (listen_fd_ >= 0) {
        close(listen_fd_);
        listen_fd_ = -1;
    }
    unlink(socket_path_.c_str());
}

void CapsuleService::SocketLoop() {
    while (running_.load()) {
        std::vector<pollfd> fds;
        {
            std::lock_guard<std::recursive_mutex> lock(clients_mu_);
            if (listen_fd_ >= 0) {
                fds.push_back(pollfd{listen_fd_, POLLIN, 0});
            }
            for (const auto& client : clients_) {
                fds.push_back(pollfd{client.fd, POLLIN, 0});
            }
        }
        if (fds.empty()) {
            break;
        }
        const int ready = poll(fds.data(), fds.size(), 250);
        if (ready < 0) {
            if (errno == EINTR) {
                continue;
            }
            break;
        }
        if (ready == 0) {
            continue;
        }
        if (fds[0].fd == listen_fd_ && (fds[0].revents & POLLIN) != 0) {
            AcceptClient();
        }
        std::vector<int> readable;
        {
            std::lock_guard<std::recursive_mutex> lock(clients_mu_);
            for (const auto& item : fds) {
                if (item.fd == listen_fd_) {
                    continue;
                }
                if ((item.revents & (POLLIN | POLLHUP | POLLERR)) != 0) {
                    readable.push_back(item.fd);
                }
            }
        }
        for (int fd : readable) {
            std::lock_guard<std::recursive_mutex> lock(clients_mu_);
            for (auto& client : clients_) {
                if (client.fd == fd) {
                    ReadClient(&client);
                    break;
                }
            }
        }
    }
}

void CapsuleService::AcceptClient() {
    const int fd = accept(listen_fd_, nullptr, nullptr);
    if (fd < 0) {
        return;
    }
    SetCloexec(fd);
    {
        std::lock_guard<std::recursive_mutex> lock(clients_mu_);
        clients_.push_back(Client{fd, {}});
    }
    post_([this, alive = alive_] { if (alive->load()) Publish(); });
}

void CapsuleService::ReadClient(Client* client) {
    char chunk[4096];
    const auto got = read(client->fd, chunk, sizeof(chunk));
    if (got <= 0) {
        CloseClient(client->fd);
        return;
    }
    client->incoming.append(chunk, static_cast<std::size_t>(got));
    while (client->incoming.size() >= 4) {
        std::uint32_t length = 0;
        if (!rimes::buffer::DecodeFrameHeader(client->incoming.data(), &length)) {
            CloseClient(client->fd);
            return;
        }
        if (client->incoming.size() < 4 + length) {
            return;
        }
        const std::string payload = client->incoming.substr(4, length);
        client->incoming.erase(0, 4 + length);
        rimes::capsule::Command command;
        std::string error;
        if (!rimes::capsule::ParseCommand(payload, &command, &error)) {
            WriteAll(rimes::buffer::EncodeError("bad_command", error));
            continue;
        }
        post_([this, alive = alive_, command] { if (alive->load()) HandleCommand(command); });
    }
}

void CapsuleService::CloseClient(int fd) {
    bool clients_empty = false;
    {
        std::lock_guard<std::recursive_mutex> lock(clients_mu_);
        for (auto iterator = clients_.begin(); iterator != clients_.end(); ++iterator) {
            if (iterator->fd == fd) {
                close(fd);
                clients_.erase(iterator);
                clients_empty = clients_.empty();
                break;
            }
        }
    }
    if (clients_empty && !headless_) {
        post_([this, alive = alive_] { if (alive->load()) ScheduleUiRespawn(); });
    }
}

bool CapsuleService::HasUiClients() {
    std::lock_guard<std::recursive_mutex> lock(clients_mu_);
    return !clients_.empty();
}

void CapsuleService::ScheduleUiRespawn() {
    if (headless_ || !model_.visible()) {
        return;
    }
    dropped_ui_pid_ = ui_pid_;
    ui_respawn_attempt_ = 0;
    ArmUiRespawnTimer(50000);
}

void CapsuleService::ArmUiRespawnTimer(int delay_us) {
    if (instance_ == nullptr) {
        return;
    }
    ui_respawn_timer_ = instance_->eventLoop().addTimeEvent(
        CLOCK_MONOTONIC, now(CLOCK_MONOTONIC) + delay_us, 0,
        [this](EventSourceTime*, uint64_t) {
            ReapUi();
            ReplaceDroppedUi();
            ++ui_respawn_attempt_;
            if (model_.visible()) {
                EnsureUi();
            }
            if (model_.visible() && !HasUiClients() && ui_respawn_attempt_ < 5) {
                const int delays[] = {2000000, 2000000, 2000000, 2000000};
                const int index = std::min(ui_respawn_attempt_ - 1, 3);
                ArmUiRespawnTimer(delays[index]);
            }
            return true;
        });
}

void CapsuleService::WriteAll(const std::string& payload) {
    std::string frame;
    if (!rimes::buffer::EncodeFrame(payload, &frame)) {
        return;
    }
    std::lock_guard<std::recursive_mutex> lock(clients_mu_);
    for (auto iterator = clients_.begin(); iterator != clients_.end();) {
        const auto written = send(iterator->fd, frame.data(), frame.size(), MSG_NOSIGNAL);
        if (written != static_cast<ssize_t>(frame.size())) {
            close(iterator->fd);
            iterator = clients_.erase(iterator);
            continue;
        }
        ++iterator;
    }
}

void CapsuleService::Publish() {
    if (model_.visible()) {
        EnsureUi();
    }
    auto snapshot = rimes::capsule::MakeSnapshot(model_);
    snapshot.theme = theme_;
    snapshot.ui_clients = UiClientCount();
    const auto json = rimes::capsule::EncodeSnapshot(snapshot);
    WriteAll(json);
    if (dump_path_.empty()) {
        return;
    }
    const auto tmp = dump_path_ + ".tmp";
    FILE* file = std::fopen(tmp.c_str(), "w");
    if (file == nullptr) {
        return;
    }
    std::fwrite(json.data(), 1, json.size(), file);
    std::fputc('\n', file);
    std::fclose(file);
    std::rename(tmp.c_str(), dump_path_.c_str());
}

}  // namespace fcitx
