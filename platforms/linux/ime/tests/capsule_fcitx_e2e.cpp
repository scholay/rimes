#include "official_catalog.hpp"
#include "capsule_store.hpp"
#include <chrono>
#include <cstdlib>
#include <cstring>
#include <exception>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <memory>
#include <stdexcept>
#include <string>
#include <unistd.h>

#include <fcitx-utils/capabilityflags.h>
#include <fcitx-utils/event.h>
#include <fcitx-utils/eventdispatcher.h>
#include <fcitx-utils/key.h>
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
std::unique_ptr<fcitx::EventSourceTime> resume_timer;

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
                      ("rimes-capsule-e2e-" + std::to_string(getpid()));
    std::error_code error;
    std::filesystem::remove_all(root, error);
    std::filesystem::create_directories(root / "user" / "log", error);
    if (error) {
        Die("could not create isolated dirs: " + error.message());
    }
    static std::string user_env;
    static std::string log_env;
    static std::string buffer_socket;
    static std::string buffer_dump;
    static std::string capsule_socket;
    static std::string capsule_dump;
    user_env = (root / "user").string();
    log_env = (root / "user" / "log").string();
    buffer_socket = (root / "rimes-buffer.sock").string();
    buffer_dump = (root / "buffer-snapshot.json").string();
    capsule_socket = (root / "rimes-capsule.sock").string();
    capsule_dump = (root / "capsule-snapshot.json").string();
    setenv("RIMES_USER_DIR", user_env.c_str(), 1);
    setenv("RIMES_LOG_DIR", log_env.c_str(), 1);
    setenv("RIMES_BUFFER_SOCKET", buffer_socket.c_str(), 1);
    setenv("RIMES_BUFFER_DUMP", buffer_dump.c_str(), 1);
    setenv("RIMES_BUFFER_HEADLESS", "1", 1);
    setenv("RIMES_BUFFER_AUTO_CAPTURE", "0", 1);
    setenv("RIMES_CAPSULE_SOCKET", capsule_socket.c_str(), 1);
    setenv("RIMES_CAPSULE_DUMP", capsule_dump.c_str(), 1);
    setenv("RIMES_CAPSULE_HEADLESS", "1", 1);
    setenv("RIMES_CAPSULE_FOCUS_GRACE_MS", "200", 1);
    return capsule_dump;
}

std::string ReadDump(const std::string& path) {
    std::ifstream in(path);
    if (!in) {
        Die("capsule dump is missing at " + path);
    }
    std::string json((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
    if (json.empty()) {
        Die("capsule dump is empty");
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

void RunCapsuleSuite(fcitx::Instance& instance, fcitx::AddonInstance* frontend,
                     const fcitx::ICUUID& uuid, fcitx::InputContext* ic,
                     const std::string& dump_path) {
    ic->setCapabilityFlags(fcitx::CapabilityFlags{fcitx::CapabilityFlag::Preedit} |
                           fcitx::CapabilityFlag::ClientUnfocusCommit);

    SendKey(frontend, uuid, "Control+Shift+V");
    for (int i=0;i<5 && ReadDump(dump_path).find("\"module\":\"notes\"")==std::string::npos;++i) SendKey(frontend,uuid,"Tab");
    auto snapshot = ReadDump(dump_path);
    ExpectContains(snapshot, "\"visible\":true", "Ctrl+Shift+V did not show the rail");
    ExpectContains(snapshot, "\"armed\":true", "Ctrl+Shift+V did not arm the session");
    ExpectContains(snapshot, "RIMES 默认词条", "seed note is missing");
    ExpectMissing(snapshot, "\\u200b", "snapshot must not advertise a ZWSP");
    ExpectNoZwsp(ic, "open rail");
    std::cout << "ok: Ctrl+Shift+V showed an armed rail with the seed note\n";

    SendKey(frontend, uuid, "Control+Shift+V");
    snapshot = ReadDump(dump_path);
    ExpectContains(snapshot, "\"visible\":false", "hotkey did not hide");
    ExpectContains(snapshot, "\"armed\":false", "hotkey did not disarm");
    std::cout << "ok: Ctrl+Shift+V hid the rail\n";

    SendKey(frontend, uuid, "Control+Shift+V");
    frontend->call<fcitx::ITestFrontend::pushCommitExpectation>("RIMES");
    SendKey(frontend, uuid, "Return");
    snapshot = ReadDump(dump_path);
    ExpectContains(snapshot, "\"visible\":false", "activate must close the rail");
    std::cout << "ok: Return inserted the seed note and closed the rail\n";

    SendKey(frontend, uuid, "Control+Shift+V");
    Type(frontend, uuid, "nihao");
    ExpectNoZwsp(ic, "search while armed");
    SendKey(frontend, uuid, "space");
    snapshot = ReadDump(dump_path);
    ExpectContains(snapshot, "\"query\":\"nihao ", "armed typing must edit the search query");
    ExpectMissing(snapshot, "你好", "armed typing must not leak into cards");
    std::cout << "ok: armed printable keys search and do not leak 你好\n";

    SendKey(frontend, uuid, "Escape");
    snapshot = ReadDump(dump_path);
    ExpectContains(snapshot, "\"visible\":false", "Escape did not hide");
    frontend->call<fcitx::ITestFrontend::pushCommitExpectation>("你好");
    Type(frontend, uuid, "nihao");
    SendKey(frontend, uuid, "space");
    std::cout << "ok: after close, Rime commits go to the host\n";

    SendKey(frontend, uuid, "Control+Shift+V");
    ic->focusOut();
    ic->focusIn();
    snapshot = ReadDump(dump_path);
    ExpectContains(snapshot, "\"armed\":false", "same-IC reactivate must disarm");
    ExpectContains(snapshot, "\"visible\":true", "field switch keeps the rail");
    std::cout << "ok: field switch disarms; later Return is not consumed by Capsule\n";

    SendKey(frontend, uuid, "Control+Shift+V");
    snapshot = ReadDump(dump_path);
    ExpectContains(snapshot, "\"armed\":true", "hotkey on a visible disarmed rail re-arms");
    ExpectContains(snapshot, "\"visible\":true", "re-arm keeps the rail up");
    ExpectContains(snapshot, "RIMES 默认词条", "re-arm shows the seed after hide cleared search");
    SendKey(frontend, uuid, "Control+Shift+V");
    snapshot = ReadDump(dump_path);
    ExpectContains(snapshot, "\"visible\":false", "second hotkey while armed closes");
    SendKey(frontend, uuid, "Control+Shift+V");
    snapshot = ReadDump(dump_path);
    ExpectContains(snapshot, "\"armed\":true", "open again after the close");
    const auto uuid2 =
        frontend->call<fcitx::ITestFrontend::createInputContext>("rimes-capsule-other");
    auto* ic2 = instance.inputContextManager().findByUUID(uuid2);
    if (ic2 == nullptr) {
        Die("second test input context was not created");
    }
    instance.setCurrentInputMethod(ic2, "rimes", true);
    ic2->focusIn();
    snapshot = ReadDump(dump_path);
    ExpectContains(snapshot, "\"armed\":false", "focusing another IC must disarm");
    ExpectContains(snapshot, "\"visible\":true", "focus change must keep the rail");
    const bool other_handled =
        frontend->call<fcitx::ITestFrontend::sendKeyEvent>(uuid2, fcitx::Key("Escape"), false);
    frontend->call<fcitx::ITestFrontend::keyEvent>(uuid2, fcitx::Key("Escape"), true);
    if (other_handled) {
        Die("Escape on a disarmed IC was swallowed");
    }
    snapshot = ReadDump(dump_path);
    ExpectContains(snapshot, "\"visible\":true", "Escape on another IC must not close Capsule");
    std::cout << "ok: Escape is scoped to the armed input context\n";
    frontend->call<fcitx::ITestFrontend::destroyInputContext>(uuid2);

    ic->focusIn();
    SendKey(frontend, uuid, "Escape");
    ic->setCapabilityFlags(fcitx::CapabilityFlags{fcitx::CapabilityFlag::Preedit} |
                           fcitx::CapabilityFlag::ClientUnfocusCommit |
                           fcitx::CapabilityFlag::Password);
    snapshot = ReadDump(dump_path);
    ExpectContains(snapshot, "\"visible\":false", "password capability must hide the rail");
    ExpectContains(snapshot, "\"password_field\":true", "password flag missing");
    SendKey(frontend, uuid, "Control+Shift+V");
    snapshot = ReadDump(dump_path);
    ExpectContains(snapshot, "\"visible\":false", "password field must refuse the rail");
    ExpectContains(snapshot, "\"password_field\":true", "password flag must survive a toggle");
    std::cout << "ok: password field refuses Capsule\n";

    ic->setCapabilityFlags(fcitx::CapabilityFlags{fcitx::CapabilityFlag::Preedit} |
                           fcitx::CapabilityFlag::ClientUnfocusCommit);
    instance.setCurrentInputMethod(ic, "rimes", true);
    ic->focusIn();
    SendKey(frontend, uuid, "Control+Shift+V");
    snapshot = ReadDump(dump_path);
    ExpectContains(snapshot, "\"armed\":true", "normal field can re-arm after password");
    SendKey(frontend, uuid, "Control+c");
    snapshot = ReadDump(dump_path);
    ExpectContains(snapshot, "\"last_copied\":\"RIMES\"", "Ctrl+C did not copy the seed body");
    ExpectContains(snapshot, "\"copy_seq\":1", "first Ctrl+C must bump copy_seq");
    Type(frontend, uuid, "z");
    snapshot = ReadDump(dump_path);
    ExpectContains(snapshot, "\"copy_seq\":1", "search must not bump copy_seq");
    ExpectContains(snapshot, "\"last_copied\":\"RIMES\"", "search must not clear last_copied");
    SendKey(frontend, uuid, "Control+Shift+V");
    snapshot = ReadDump(dump_path);
    ExpectContains(snapshot, "\"visible\":false", "armed hotkey closes");
    ExpectContains(snapshot, "\"last_copied\":\"\"", "Hide must clear last_copied");
    ExpectContains(snapshot, "\"copy_seq\":1", "Hide must not bump copy_seq");
    SendKey(frontend, uuid, "Control+Shift+V");
    snapshot = ReadDump(dump_path);
    ExpectContains(snapshot, "\"copy_seq\":1", "reopen must not look like a new copy");
    ExpectContains(snapshot, "\"last_copied\":\"\"", "reopen must not restore last_copied");
    SendKey(frontend, uuid, "Control+c");
    snapshot = ReadDump(dump_path);
    ExpectContains(snapshot, "\"copy_seq\":2", "second Ctrl+C on the same card must bump copy_seq");
    ExpectContains(snapshot, "\"last_copied\":\"RIMES\"", "second Ctrl+C must copy again");
    std::cout << "ok: Ctrl+C is edge-triggered and can copy the same card twice\n";

    auto* engine = instance.inputMethodEngine(ic);
    if (!engine || !engine->getConfig()) Die("missing plugin host configuration");
    rimes::plugins::PackageStore packages(rimes::runtime::UserRoot()/"plugins",rimes::plugins::OfficialCatalog(),
        rimes::plugins::BundledPackages(),rimes::plugins::CompiledAdapters(),RIMES_PRODUCT_VERSION);
    const auto notes=packages.Inspect("builtin.capsule.notes");
    packages.Enable(notes.id,false,notes.grant); engine->reloadConfig();
    snapshot=ReadDump(dump_path);
    ExpectContains(snapshot,"\"armed\":false","plugin disable must revoke insertion");
    ExpectContains(snapshot,"\"last_copied\":\"\"","plugin disable must clear clipboard intent");
    ExpectMissing(snapshot,"RIMES 默认词条","disabled notes still exposed");
    frontend->call<fcitx::ITestFrontend::pushCommitExpectation>("你好");
    Type(frontend,uuid,"nihao"); SendKey(frontend,uuid,"space");
    rimes::capsule::ContentStore content(rimes::capsule::ContentStore::DefaultRoot());
    rimes::capsule::Record saved; std::string error;
    if(content.Get(rimes::capsule::kDefaultEntryId,&saved,&error)!=rimes::capsule::StoreStatus::Ok) Die("disabled plugin lost its data");
    const auto disabled=packages.Inspect(notes.id);
    packages.Enable(notes.id,true,disabled.grant); engine->reloadConfig();
    const auto until=std::chrono::steady_clock::now()+std::chrono::seconds(8);
    resume_timer=instance.eventLoop().addTimeEvent(CLOCK_MONOTONIC,fcitx::now(CLOCK_MONOTONIC)+50000,50000,
        [&,frontend,uuid,ic,dump_path,until](fcitx::EventSourceTime* timer,uint64_t) {
            try {
                if(ReadDump(dump_path).find("\"loading\":true")!=std::string::npos) {
                    if(std::chrono::steady_clock::now()>until) Die("Capsule reload timed out");
                    timer->setTime(fcitx::now(CLOCK_MONOTONIC)+50000);timer->setOneShot();return true;
                }
                SendKey(frontend,uuid,"Control+Shift+V");
                for(int i=0;i<5 && ReadDump(dump_path).find("\"module\":\"notes\"")==std::string::npos;++i) SendKey(frontend,uuid,"Tab");
                const auto restored=ReadDump(dump_path);
                ExpectContains(restored,"\"armed\":true","re-enabled plugin needs explicit target capture");
                ExpectContains(restored,"RIMES 默认词条","re-enabled module failed to reload data");
                std::cout<<"ok: package disable revokes capture, preserves data and ordinary typing; re-enable reloads notes\n";
                SendKey(frontend,uuid,"Control+Shift+B");SendKey(frontend,uuid,"Return");
                ExpectContains(ReadDump(dump_path),"\"visible\":true","Buffer Return must not close Capsule");
                std::cout<<"ok: Buffer capturing keeps Capsule from consuming Return\n";
            } catch(const TestFailed&) {}
            instance.exit();return true;
        });
}

}  // namespace

int main(int argc, char** argv) {
    if (argc < 4) {
        std::cerr << "Usage: rimes-capsule-fcitx-e2e <build-dir> <addon-rel-dir> <data-rel-dir>\n";
        return EXIT_FAILURE;
    }

    try {
        const auto dump_path = IsolateDirs();
        fcitx::setupTestingEnvironment(argv[1], {argv[2]}, {argv[3]});
        // setupTestingEnvironment deliberately disables config writes. This
        // suite verifies a real saved plugin preference in its isolated root.
        const auto config = std::filesystem::path(dump_path).parent_path() / "config";
        std::filesystem::create_directories(config / "conf");
        unsetenv("SKIP_FCITX_USER_PATH");
        setenv("FCITX_CONFIG_HOME", config.c_str(), 1);
        setenv("FCITX_DATA_HOME", (config / "data").c_str(), 1);
        setenv("XDG_CACHE_HOME", (config / "cache").c_str(), 1);

        char arg0[] = "rimes-capsule-fcitx-e2e";
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
            uuid = frontend->call<fcitx::ITestFrontend::createInputContext>("rimes-capsule-e2e");
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
                    if (ReadDump(dump_path).find("\"loading\":true")!=std::string::npos) {
                        source->setTime(fcitx::now(CLOCK_MONOTONIC)+50000);source->setOneShot();return true;
                    }
                    if (suite_started) {
                        return true;
                    }
                    suite_started = true;
                    std::cout << "ok: capsule testfrontend left Deploying\n";
                    try {
                        RunCapsuleSuite(instance, frontend, uuid, ic, dump_path);
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
