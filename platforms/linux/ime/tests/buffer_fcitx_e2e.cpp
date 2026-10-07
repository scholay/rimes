#include <chrono>
#include <cstdlib>
#include <cstring>
#include <exception>
#include <filesystem>
#include <fstream>
#include <functional>
#include <iostream>
#include <memory>
#include <stdexcept>
#include <string>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#include <vector>

#include "buffer_protocol.hpp"

#include <fcitx-utils/capabilityflags.h>
#include <fcitx-utils/event.h>
#include <fcitx-utils/eventdispatcher.h>
#include <fcitx-utils/key.h>
#include <fcitx-utils/keysym.h>
#include <fcitx-utils/rect.h>
#include <fcitx-utils/testing.h>
#include <fcitx/addonmanager.h>
#include <fcitx/inputcontextmanager.h>
#include <fcitx/inputmethodengine.h>
#include <fcitx/inputmethodgroup.h>
#include <fcitx/inputmethodmanager.h>
#include <fcitx/inputpanel.h>
#include <fcitx/instance.h>
#include <testfrontend_public.h>

namespace {

int g_exit_status = EXIT_SUCCESS;

struct TestFailed : std::runtime_error {
    explicit TestFailed(const std::string& message) : std::runtime_error(message) {}
};

void Die(const std::string& message) {
    std::cerr << "FAIL: " << message << '\n';
    g_exit_status = EXIT_FAILURE;
    throw TestFailed(message);
}

void Type(fcitx::AddonInstance* frontend, const fcitx::ICUUID& uuid, const char* keys) {
    for (const char* cursor = keys; *cursor != '\0'; ++cursor) {
        const char name[] = {*cursor, '\0'};
        frontend->call<fcitx::ITestFrontend::keyEvent>(uuid, fcitx::Key(name), false);
        frontend->call<fcitx::ITestFrontend::keyEvent>(uuid, fcitx::Key(name), true);
    }
}

void SendKey(fcitx::AddonInstance* frontend, const fcitx::ICUUID& uuid, const char* name) {
    frontend->call<fcitx::ITestFrontend::keyEvent>(uuid, fcitx::Key(name), false);
    frontend->call<fcitx::ITestFrontend::keyEvent>(uuid, fcitx::Key(name), true);
}

std::string IsolateDirs() {
    const auto root = std::filesystem::temp_directory_path() /
                      ("rimes-buffer-e2e-" + std::to_string(getpid()));
    std::error_code error;
    std::filesystem::remove_all(root, error);
    std::filesystem::create_directories(root / "user" / "log", error);
    if (error) {
        Die("could not create isolated dirs: " + error.message());
    }
    static std::string user_env;
    static std::string log_env;
    static std::string socket_env;
    static std::string dump_env;
    user_env = (root / "user").string();
    log_env = (root / "user" / "log").string();
    socket_env = (root / "rimes-buffer.sock").string();
    dump_env = (root / "buffer-snapshot.json").string();
    setenv("RIMES_USER_DIR", user_env.c_str(), 1);
    setenv("RIMES_LOG_DIR", log_env.c_str(), 1);
    setenv("RIMES_BUFFER_SOCKET", socket_env.c_str(), 1);
    setenv("RIMES_BUFFER_DUMP", dump_env.c_str(), 1);
    setenv("RIMES_BUFFER_HEADLESS", "1", 1);
    // Enable via the user hotkey. AUTO_CAPTURE plus a synthetic key that also
    // activates the IC would Toggle the workbench closed in the same event.
    setenv("RIMES_BUFFER_AUTO_CAPTURE", "0", 1);
    setenv("RIMES_BUFFER_CLOSE_AFTER_LAST", "1", 1);
    setenv("RIMES_BUFFER_FOCUS_GRACE_MS", "200", 1);
    return dump_env;
}

std::string ReadDump(const std::string& path) {
    std::ifstream in(path);
    if (!in) {
        Die("buffer dump is missing at " + path);
    }
    std::string json((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
    if (json.empty()) {
        Die("buffer dump is empty");
    }
    return json;
}

bool HasNeedle(const std::string& haystack, const char* needle) {
    return haystack.find(needle) != std::string::npos;
}

void ExpectContains(const std::string& haystack, const char* needle, const char* message) {
    if (!HasNeedle(haystack, needle)) {
        std::cerr << haystack << '\n';
        Die(message);
    }
}

void ExpectMissing(const std::string& haystack, const char* needle, const char* message) {
    if (HasNeedle(haystack, needle)) {
        std::cerr << haystack << '\n';
        Die(message);
    }
}

void ExpectNoZwsp(fcitx::InputContext* ic, const char* where) {
    const auto client = ic->inputPanel().clientPreedit().toString();
    const auto popup = ic->inputPanel().preedit().toString();
    constexpr const char* kZwsp = "\xe2\x80\x8b";
    if (client.find(kZwsp) != std::string::npos || popup.find(kZwsp) != std::string::npos) {
        Die(std::string("U+200B leaked into host preedit at ") + where);
    }
}

void EnsureCapturing(fcitx::AddonInstance* frontend, const fcitx::ICUUID& uuid,
                     const std::string& dump_path) {
    auto snapshot = ReadDump(dump_path);
    if (HasNeedle(snapshot, "\"capturing\":true")) {
        return;
    }
    SendKey(frontend, uuid, "Control+Shift+B");
    snapshot = ReadDump(dump_path);
    ExpectContains(snapshot, "\"capturing\":true", "could not resume Buffer capture");
}

using ExtraTimers = std::vector<std::unique_ptr<fcitx::EventSourceTime>>;

struct SuiteCtx {
    fcitx::Instance* instance = nullptr;
    ExtraTimers* timers = nullptr;
    fcitx::AddonInstance* frontend = nullptr;
    fcitx::ICUUID uuid{};
    fcitx::InputContext* ic = nullptr;
    std::string dump_path;
    std::unique_ptr<fcitx::EventSourceTime>* grace_timer = nullptr;
    std::unique_ptr<fcitx::EventSourceTime>* hold_timer = nullptr;
};

void AfterUs(SuiteCtx ctx, int delay_us, std::function<void(SuiteCtx)> fn) {
    ctx.timers->emplace_back(ctx.instance->eventLoop().addTimeEvent(
        CLOCK_MONOTONIC, fcitx::now(CLOCK_MONOTONIC) + delay_us, 0,
        [ctx, fn = std::move(fn)](fcitx::EventSourceTime*, uint64_t) {
            try {
                fn(ctx);
            } catch (const TestFailed&) {
                ctx.instance->exit();
            }
            return true;
        }));
}

void SendBufferOp(const char* op) {
    const char* path = std::getenv("RIMES_BUFFER_SOCKET");
    if (path == nullptr || path[0] == '\0') {
        Die("RIMES_BUFFER_SOCKET is missing");
    }
    const int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (fd < 0) {
        Die("could not open the Buffer socket");
    }
    sockaddr_un address{};
    address.sun_family = AF_UNIX;
    std::strncpy(address.sun_path, path, sizeof(address.sun_path) - 1);
    if (connect(fd, reinterpret_cast<sockaddr*>(&address), sizeof(address)) != 0) {
        close(fd);
        Die("could not connect to the Buffer socket");
    }
    const std::string json = std::string("{\"v\":1,\"op\":\"") + op + "\"}";
    std::string frame;
    if (!rimes::buffer::EncodeFrame(json, &frame) ||
        send(fd, frame.data(), frame.size(), MSG_NOSIGNAL) != static_cast<ssize_t>(frame.size())) {
        close(fd);
        Die(std::string("could not send Buffer op ") + op);
    }
    close(fd);
}

void DrainStaged(fcitx::AddonInstance* frontend, const fcitx::ICUUID& uuid,
                 const std::string& dump_path) {
    EnsureCapturing(frontend, uuid, dump_path);
    for (int attempt = 0; attempt < 12; ++attempt) {
        const auto snapshot = ReadDump(dump_path);
        if (HasNeedle(snapshot, "\"empty\":true")) {
            return;
        }
        SendKey(frontend, uuid, "BackSpace");
    }
    const auto leftover = ReadDump(dump_path);
    if (!HasNeedle(leftover, "\"empty\":true")) {
        Die("could not drain leftover Buffer chips");
    }
}

void RunBufferSuite(fcitx::Instance& instance,
                    fcitx::AddonInstance* frontend,
                    const fcitx::ICUUID& uuid,
                    fcitx::InputContext* ic,
                    const std::string& dump_path,
                    std::unique_ptr<fcitx::EventSourceTime>* grace_timer,
                    std::unique_ptr<fcitx::EventSourceTime>* hold_timer,
                    ExtraTimers* extra_timers) {
    ic->setCapabilityFlags(fcitx::CapabilityFlags{fcitx::CapabilityFlag::Preedit} |
                           fcitx::CapabilityFlag::ClientUnfocusCommit);

    SendKey(frontend, uuid, "Control+Shift+B");
    auto snapshot = ReadDump(dump_path);
    ExpectContains(snapshot, "\"capturing\":true", "Ctrl+Shift+B did not enable capture");
    ExpectContains(snapshot, "\"visible\":true", "Ctrl+Shift+B did not show the workbench");
    std::cout << "ok: Ctrl+Shift+B enabled capture\n";

    SendKey(frontend, uuid, "Control+Shift+B");
    snapshot = ReadDump(dump_path);
    ExpectContains(snapshot, "\"capturing\":false", "hotkey did not pause capture");
    ExpectContains(snapshot, "\"visible\":false", "hotkey did not hide the workbench");
    std::cout << "ok: Ctrl+Shift+B paused an open workbench\n";

    SendKey(frontend, uuid, "Control+Shift+B");
    snapshot = ReadDump(dump_path);
    ExpectContains(snapshot, "\"capturing\":true", "hotkey did not resume capture");
    ExpectContains(snapshot, "\"visible\":true", "hotkey did not show the workbench");
    std::cout << "ok: Ctrl+Shift+B resumed capture\n";

    Type(frontend, uuid, "nihao");
    SendKey(frontend, uuid, "space");
    snapshot = ReadDump(dump_path);
    ExpectContains(snapshot, "你好", "Rime commit was not staged into Buffer");
    ExpectContains(snapshot, "\"capturing\":true", "capture lost after commit");
    std::cout << "ok: buffer staged nihao + Space\n";

    Type(frontend, uuid, "shijie");
    SendKey(frontend, uuid, "space");
    snapshot = ReadDump(dump_path);
    ExpectContains(snapshot, "世界", "second commit was not staged");
    std::cout << "ok: buffer kept a second block\n";

    frontend->call<fcitx::ITestFrontend::pushCommitExpectation>("你好");
    SendKey(frontend, uuid, "Return");
    snapshot = ReadDump(dump_path);
    ExpectMissing(snapshot, "你好", "Return tap left the delivered block");
    ExpectContains(snapshot, "世界", "Return tap consumed more than one block");
    std::cout << "ok: buffer Return tap sendNext delivered 你好\n";

    frontend->call<fcitx::ITestFrontend::pushCommitExpectation>("世界");
    SendKey(frontend, uuid, "Return");
    snapshot = ReadDump(dump_path);
    ExpectMissing(snapshot, "世界", "second Return tap did not send the remaining block");
    std::cout << "ok: buffer second Return tap sendNext\n";

    EnsureCapturing(frontend, uuid, dump_path);
    Type(frontend, uuid, "nihao");
    SendKey(frontend, uuid, "space");
    SendKey(frontend, uuid, "BackSpace");
    snapshot = ReadDump(dump_path);
    ExpectMissing(snapshot, "你好", "Backspace did not drop the staged block");
    std::cout << "ok: buffer Backspace remove_last\n";

    Type(frontend, uuid, "nihao");
    SendKey(frontend, uuid, "Return");
    snapshot = ReadDump(dump_path);
    // rime_ice maps Return to commit_raw_input, so the settled chip is the
    // spelling, not the highlighted candidate.
    ExpectContains(snapshot, "nihao", "composing Return must settle into a block");
    ExpectContains(snapshot, "\"capturing\":true", "settle must not send or pause");
    frontend->call<fcitx::ITestFrontend::pushCommitExpectation>("nihao");
    SendKey(frontend, uuid, "Return");
    snapshot = ReadDump(dump_path);
    ExpectMissing(snapshot, "nihao", "ready Return did not send the settled block");
    std::cout << "ok: buffer composing Return settles, next Return sends\n";

    EnsureCapturing(frontend, uuid, dump_path);
    Type(frontend, uuid, "nihao");
    ExpectNoZwsp(ic, "composing while capturing");
    snapshot = ReadDump(dump_path);
    ExpectMissing(snapshot, "\\u200b", "snapshot must not advertise a ZWSP preedit");
    ExpectMissing(snapshot, "\xe2\x80\x8b", "snapshot must not contain U+200B");
    ic->focusOut();
    ExpectNoZwsp(ic, "focus-out while capturing");
    ic->focusIn();
    ExpectNoZwsp(ic, "focus-in after capturing focus-out");
    snapshot = ReadDump(dump_path);
    ExpectContains(snapshot, "\"capturing\":false",
                   "same-IC reactivation without a drag must pause capture");
    ExpectContains(snapshot, "nihao", "open composition is staged on same-IC reactivate");
    std::cout << "ok: capturing never installs a client-preedit ZWSP\n";
    std::cout << "ok: same-IC reactivate without a fresh caret pauses capture\n";

    frontend->call<fcitx::ITestFrontend::pushCommitExpectation>("你好");
    Type(frontend, uuid, "nihao");
    SendKey(frontend, uuid, "space");
    snapshot = ReadDump(dump_path);
    ExpectContains(snapshot, "\"capturing\":false",
                   "next key after a stale same-IC reactivate must stay direct");
    ExpectMissing(snapshot, "你好", "next key after same-IC reactivate must not stage");
    std::cout << "ok: next key after same-IC reactivate is not captured\n";

    EnsureCapturing(frontend, uuid, dump_path);
    DrainStaged(frontend, uuid, dump_path);
    ic->focusOut();
    ic->focusIn();
    ic->setCursorRect(fcitx::Rect(80, 200, 88, 220));
    snapshot = ReadDump(dump_path);
    ExpectContains(snapshot, "\"capturing\":false",
                   "caret update after activate must not restore capture");
    frontend->call<fcitx::ITestFrontend::pushCommitExpectation>("你好");
    Type(frontend, uuid, "nihao");
    SendKey(frontend, uuid, "space");
    snapshot = ReadDump(dump_path);
    ExpectMissing(snapshot, "你好", "late caret update must not recapture the next key");
    std::cout << "ok: caret update after activate does not recapture\n";

    EnsureCapturing(frontend, uuid, dump_path);
    SendKey(frontend, uuid, "Escape");
    snapshot = ReadDump(dump_path);
    ExpectContains(snapshot, "\"visible\":false", "Escape did not hide");
    ExpectContains(snapshot, "\"capturing\":false", "Escape did not pause capture");

    frontend->call<fcitx::ITestFrontend::pushCommitExpectation>("你好");
    Type(frontend, uuid, "nihao");
    SendKey(frontend, uuid, "space");
    std::cout << "ok: buffer paused; later commits go to the host\n";

    SendKey(frontend, uuid, "Control+Shift+B");
    snapshot = ReadDump(dump_path);
    ExpectContains(snapshot, "\"capturing\":true", "could not reopen for Escape-scope");
    const auto uuid2 = frontend->call<fcitx::ITestFrontend::createInputContext>("rimes-buffer-other");
    auto* ic2 = instance.inputContextManager().findByUUID(uuid2);
    if (ic2 == nullptr) {
        Die("second test input context was not created");
    }
    instance.setCurrentInputMethod(ic2, "rimes", true);
    ic2->focusIn();
    snapshot = ReadDump(dump_path);
    ExpectContains(snapshot, "\"capturing\":false", "focusing another IC must drop capture");
    ExpectContains(snapshot, "\"visible\":true", "focus change must keep the workbench");
    const bool other_handled =
        frontend->call<fcitx::ITestFrontend::sendKeyEvent>(uuid2, fcitx::Key("Escape"), false);
    frontend->call<fcitx::ITestFrontend::keyEvent>(uuid2, fcitx::Key("Escape"), true);
    if (other_handled) {
        Die("Escape on an uncaptured IC was swallowed");
    }
    snapshot = ReadDump(dump_path);
    ExpectContains(snapshot, "\"visible\":true", "Escape on another IC must not close Buffer");
    std::cout << "ok: Escape is scoped to the captured input context\n";

    frontend->call<fcitx::ITestFrontend::destroyInputContext>(uuid2);
    ic->focusIn();
    EnsureCapturing(frontend, uuid, dump_path);

    const auto uuid_dying =
        frontend->call<fcitx::ITestFrontend::createInputContext>("rimes-buffer-dying");
    auto* ic_dying = instance.inputContextManager().findByUUID(uuid_dying);
    if (ic_dying == nullptr) {
        Die("dying test input context was not created");
    }
    instance.setCurrentInputMethod(ic_dying, "rimes", true);
    ic_dying->focusIn();
    SendKey(frontend, uuid_dying, "Control+Shift+B");
    snapshot = ReadDump(dump_path);
    ExpectContains(snapshot, "\"capturing\":true", "dying IC did not capture");
    frontend->call<fcitx::ITestFrontend::destroyInputContext>(uuid_dying);
    snapshot = ReadDump(dump_path);
    ExpectContains(snapshot, "\"capturing\":false", "destroyed IC must drop capture");
    std::cout << "ok: destroying the captured IC pauses capture and clears the route\n";

    ic->focusIn();
    EnsureCapturing(frontend, uuid, dump_path);
    const SuiteCtx ctx{&instance, extra_timers, frontend, uuid, ic, dump_path, grace_timer,
                       hold_timer};
    SendBufferOp("drag_begin");
    AfterUs(ctx, 50000, [](SuiteCtx ctx) {
        AfterUs(ctx, 2000000, [](SuiteCtx ctx) {
            ctx.ic->focusOut();
            ctx.ic->focusIn();
            auto snapshot = ReadDump(ctx.dump_path);
            ExpectContains(snapshot, "\"capturing\":true",
                           "same-IC reactivate 2s after drag_begin without drag_end must keep");
            std::cout << "ok: drag_begin without drag_end keeps capture for 2s\n";

            SendBufferOp("drag_begin");
            AfterUs(ctx, 50000, [](SuiteCtx ctx) {
                AfterUs(ctx, 300000, [](SuiteCtx ctx) {
                    SendBufferOp("drag_end");
                    // IME command-order coverage for #44: the next same-IC
                    // activation after the socket command is dispatched is
                    // a field switch. This headless test does not exercise
                    // physical button release or GTK's 50ms release poll.
                    AfterUs(ctx, 10000, [](SuiteCtx ctx) {
                        ctx.ic->focusOut();
                        ctx.ic->focusIn();
                        auto snapshot = ReadDump(ctx.dump_path);
                        ExpectContains(
                            snapshot, "\"capturing\":false",
                            "same-IC reactivate within 10ms after drag_end must pause");
                        std::cout << "ok: immediate field switch after drag_end pauses capture\n";

                        ctx.ic->focusOut();
                        ctx.ic->focusIn();
                        snapshot = ReadDump(ctx.dump_path);
                        ExpectContains(snapshot, "\"capturing\":false",
                                       "second same-IC after a consumed drag must pause");
                        std::cout << "ok: field switch after a completed drag pauses capture\n";

                        EnsureCapturing(ctx.frontend, ctx.uuid, ctx.dump_path);
                        SendBufferOp("drag_begin");
                        AfterUs(ctx, 50000, [](SuiteCtx ctx) {
                            SendBufferOp("drag_end");
                            AfterUs(ctx, 1200000, [](SuiteCtx ctx) {
                                ctx.ic->focusOut();
                                ctx.ic->focusIn();
                                auto snapshot = ReadDump(ctx.dump_path);
                                ExpectContains(snapshot, "\"capturing\":false",
                                               "same-IC reactivate after drag_end must pause");
                                std::cout
                                    << "ok: same-IC reactivate 1.2s after drag_end pauses\n";

                                ctx.ic->focusIn();
                                EnsureCapturing(ctx.frontend, ctx.uuid, ctx.dump_path);
                                DrainStaged(ctx.frontend, ctx.uuid, ctx.dump_path);
                                Type(ctx.frontend, ctx.uuid, "zhongguoren");
                                const auto uuid_switch =
                                    ctx.frontend->call<fcitx::ITestFrontend::createInputContext>(
                                        "rimes-buffer-switch");
                                auto* ic_switch =
                                    ctx.instance->inputContextManager().findByUUID(uuid_switch);
                                if (ic_switch == nullptr) {
                                    Die("switch test input context was not created");
                                }
                                ctx.instance->setCurrentInputMethod(ic_switch, "rimes", true);
                                ic_switch->focusIn();
                                snapshot = ReadDump(ctx.dump_path);
                                ExpectContains(snapshot, "zhongguoren",
                                               "app switch must stage raw input, not "
                                               "syllable-spaced preedit");
                                ExpectMissing(snapshot, "zhong guo",
                                              "staged composition must not keep syllable spaces");
                                ExpectContains(snapshot, "\"capturing\":false",
                                               "app switch must pause capture");
                                std::cout << "ok: switching apps stages raw input zhongguoren\n";
                                ctx.frontend->call<fcitx::ITestFrontend::destroyInputContext>(
                                    uuid_switch);

                                ctx.ic->focusIn();
                                DrainStaged(ctx.frontend, ctx.uuid, ctx.dump_path);
                                Type(ctx.frontend, ctx.uuid, "shi");
                                ctx.ic->focusOut();
                                *ctx.grace_timer = ctx.instance->eventLoop().addTimeEvent(
                                    CLOCK_MONOTONIC, fcitx::now(CLOCK_MONOTONIC) + 400000, 0,
                                    [ctx](fcitx::EventSourceTime*, uint64_t) {
                                        try {
                                            auto snapshot = ReadDump(ctx.dump_path);
                                            ExpectContains(snapshot, "\"capturing\":false",
                                                           "focus-out grace must drop capture");
                                            ExpectContains(
                                                snapshot, "shi",
                                                "open composition must stage into Buffer");
                                            std::cout << "ok: leaving a field stages the open "
                                                         "preedit and drops capture\n";

                                            ctx.ic->focusIn();
                                            DrainStaged(ctx.frontend, ctx.uuid, ctx.dump_path);
                                            Type(ctx.frontend, ctx.uuid, "nihao");
                                            SendKey(ctx.frontend, ctx.uuid, "space");
                                            Type(ctx.frontend, ctx.uuid, "shijie");
                                            SendKey(ctx.frontend, ctx.uuid, "space");
                                            snapshot = ReadDump(ctx.dump_path);
                                            ExpectContains(snapshot, "你好",
                                                           "hold-Return fixture missing first chip");
                                            ExpectContains(
                                                snapshot, "世界",
                                                "hold-Return fixture missing second chip");
                                            ctx.frontend
                                                ->call<fcitx::ITestFrontend::pushCommitExpectation>(
                                                    "你好");
                                            ctx.frontend
                                                ->call<fcitx::ITestFrontend::pushCommitExpectation>(
                                                    "世界");
                                            ctx.frontend->call<fcitx::ITestFrontend::keyEvent>(
                                                ctx.uuid, fcitx::Key("Return"), false);

                                            *ctx.hold_timer =
                                                ctx.instance->eventLoop().addTimeEvent(
                                                    CLOCK_MONOTONIC,
                                                    fcitx::now(CLOCK_MONOTONIC) + 1400000, 0,
                                                    [ctx](fcitx::EventSourceTime*, uint64_t) {
                                                        try {
                                                            const fcitx::Key repeat_return(
                                                                FcitxKey_Return,
                                                                fcitx::KeyStates{
                                                                    fcitx::KeyState::Repeat});
                                                            for (int index = 0; index < 8;
                                                                 ++index) {
                                                                ctx.frontend->call<
                                                                    fcitx::ITestFrontend::keyEvent>(
                                                                    ctx.uuid, repeat_return, false);
                                                            }
                                                            ctx.frontend->call<
                                                                fcitx::ITestFrontend::keyEvent>(
                                                                ctx.uuid, fcitx::Key("Return"),
                                                                true);
                                                            const auto after =
                                                                ReadDump(ctx.dump_path);
                                                            ExpectMissing(
                                                                after, "你好",
                                                                "hold-Return left the first chip");
                                                            ExpectMissing(
                                                                after, "世界",
                                                                "hold-Return left the second chip");
                                                            ExpectContains(
                                                                after, "\"capturing\":false",
                                                                "send-all + close-after-last must "
                                                                "pause");
                                                            ExpectNoZwsp(
                                                                ctx.ic,
                                                                "after held-Return send-all");
                                                            std::cout << "ok: held-Return send-all "
                                                                         "ate leftover repeats\n";
                                                            ctx.frontend->call<
                                                                fcitx::ITestFrontend::
                                                                    destroyInputContext>(ctx.uuid);
                                                            ctx.instance->exit();
                                                        } catch (const TestFailed&) {
                                                            ctx.instance->exit();
                                                        }
                                                        return true;
                                                    });
                                        } catch (const TestFailed&) {
                                            ctx.instance->exit();
                                        }
                                        return true;
                                    });
                            });
                        });
                    });
                });
            });
        });
    });
}

}  // namespace

int main(int argc, char** argv) {
    if (argc < 4) {
        std::cerr << "Usage: rimes-buffer-fcitx-e2e <build-dir> <addon-rel-dir> <data-rel-dir>\n";
        return EXIT_FAILURE;
    }

    try {
        const auto dump_path = IsolateDirs();
        fcitx::setupTestingEnvironment(argv[1], {argv[2]}, {argv[3]});

        char arg0[] = "rimes-buffer-fcitx-e2e";
        char arg1[] = "--disable=all";
        char arg2[] = "--enable=testfrontend,testui,rimes";
        char* args[] = {arg0, arg1, arg2};
        fcitx::Instance instance(3, args);
        instance.addonManager().registerDefaultLoader(nullptr);

        fcitx::EventDispatcher dispatcher;
        dispatcher.attach(&instance.eventLoop());

        fcitx::AddonInstance* frontend = nullptr;
        fcitx::ICUUID uuid{};
        fcitx::InputContext* ic = nullptr;
        std::unique_ptr<fcitx::EventSourceTime> wait_timer;
        std::unique_ptr<fcitx::EventSourceTime> grace_timer;
        std::unique_ptr<fcitx::EventSourceTime> hold_timer;
        ExtraTimers extra_timers;
        const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(180);
        bool suite_started = false;

        dispatcher.schedule([&]() {
            auto& manager = instance.inputMethodManager();
            if (manager.entry("rimes") == nullptr) {
                Die("input method 'rimes' was not registered");
            }
            if (manager.groupCount() == 0) {
                manager.addEmptyGroup("Default");
                manager.setGroupOrder({"Default"});
            }
            fcitx::InputMethodGroup group("Default");
            group.setDefaultLayout("us");
            group.inputMethodList().emplace_back(fcitx::InputMethodGroupItem("rimes"));
            group.setDefaultInputMethod("rimes");
            manager.setGroup(group);
            manager.setCurrentGroup("Default");

            frontend = instance.addonManager().addon("testfrontend", true);
            if (frontend == nullptr) {
                Die("testfrontend addon did not load");
            }
            uuid = frontend->call<fcitx::ITestFrontend::createInputContext>("rimes-buffer-e2e");
            ic = instance.inputContextManager().findByUUID(uuid);
            if (ic == nullptr) {
                Die("test input context was not created");
            }
            instance.setCurrentInputMethod(ic, "rimes", true);
            if (instance.inputMethod(ic) != "rimes") {
                Die("could not switch the test context to rimes");
            }

            wait_timer = instance.eventLoop().addTimeEvent(
                CLOCK_MONOTONIC, fcitx::now(CLOCK_MONOTONIC) + 50000, 50000,
                [&](fcitx::EventSourceTime* source, uint64_t) {
                    if (std::chrono::steady_clock::now() > deadline) {
                        Die("addon stayed in Deploying; deploy-ready notify never ran");
                    }
                    auto* ime = instance.inputMethodEngine(ic);
                    const auto* entry = instance.inputMethodEntry(ic);
                    if (ime != nullptr && entry != nullptr &&
                        ime->subMode(*entry, *ic) == "Deploying") {
                        source->setTime(fcitx::now(CLOCK_MONOTONIC) + 200000);
                        source->setOneShot();
                        return true;
                    }
                    if (suite_started) {
                        return true;
                    }
                    suite_started = true;
                    std::cout << "ok: buffer testfrontend left Deploying\n";
                    try {
                        RunBufferSuite(instance, frontend, uuid, ic, dump_path, &grace_timer,
                                       &hold_timer, &extra_timers);
                    } catch (const TestFailed&) {
                        instance.exit();
                    }
                    return true;
                });
        });

        try {
            const int rc = instance.exec();
            return g_exit_status != EXIT_SUCCESS ? g_exit_status : rc;
        } catch (const fcitx::InstanceQuietQuit&) {
            return g_exit_status;
        }
    } catch (const TestFailed&) {
        return EXIT_FAILURE;
    } catch (const std::exception& exception) {
        std::cerr << "FAIL: " << exception.what() << '\n';
        return EXIT_FAILURE;
    }
}
