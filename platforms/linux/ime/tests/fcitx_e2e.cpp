#include <chrono>
#include <cstdlib>
#include <exception>
#include <filesystem>
#include <iostream>
#include <memory>
#include <string>
#include <unistd.h>

#include <fcitx-utils/capabilityflags.h>
#include <fcitx-utils/event.h>
#include <fcitx-utils/eventdispatcher.h>
#include <fcitx-utils/key.h>
#include <fcitx-utils/testing.h>
#include <fcitx-config/rawconfig.h>
#include <fcitx/addonmanager.h>
#include <fcitx/candidatelist.h>
#include <fcitx/inputcontextmanager.h>
#include <fcitx/inputmethodengine.h>
#include <fcitx/inputmethodgroup.h>
#include <fcitx/inputmethodmanager.h>
#include <fcitx/inputpanel.h>
#include <fcitx/instance.h>
#include <testfrontend_public.h>

namespace {

void Die(const std::string& message) {
    std::cerr << "FAIL: " << message << '\n';
    std::exit(EXIT_FAILURE);
}

void Type(fcitx::AddonInstance* frontend, const fcitx::ICUUID& uuid, const char* keys) {
    for (const char* cursor = keys; *cursor != '\0'; ++cursor) {
        const char name[] = {*cursor, '\0'};
        frontend->call<fcitx::ITestFrontend::keyEvent>(uuid, fcitx::Key(name), false);
        frontend->call<fcitx::ITestFrontend::keyEvent>(uuid, fcitx::Key(name), true);
    }
}

void IsolateEmptyUserDir() {
    const auto user = std::filesystem::temp_directory_path() /
                      ("rimes-fcitx-e2e-user-" + std::to_string(getpid()));
    std::error_code error;
    std::filesystem::remove_all(user, error);
    std::filesystem::create_directories(user / "log", error);
    if (error) {
        Die("could not create isolated user dir: " + error.message());
    }
    setenv("RIMES_USER_DIR", user.string().c_str(), 1);
    setenv("RIMES_LOG_DIR", (user / "log").string().c_str(), 1);
}

void RunTypingSuite(fcitx::Instance& instance,
                    fcitx::AddonInstance* frontend,
                    const fcitx::ICUUID& uuid,
                    fcitx::InputContext* ic) {
    ic->setCapabilityFlags(fcitx::CapabilityFlags{fcitx::CapabilityFlag::Preedit} |
                           fcitx::CapabilityFlag::ClientUnfocusCommit);

    frontend->call<fcitx::ITestFrontend::pushCommitExpectation>("你好");
    Type(frontend, uuid, "nihao");
    if (ic->inputPanel().clientPreedit().empty()) {
        Die("nihao produced no inline preedit");
    }
    if (!ic->inputPanel().preedit().empty()) {
        Die("inline-capable client also showed preedit in the popup");
    }
    auto candidates = ic->inputPanel().candidateList();
    if (!candidates || candidates->size() < 1) {
        Die("nihao produced no candidate list");
    }
    bool saw_nihao = false;
    for (int index = 0; index < candidates->size(); ++index) {
        if (candidates->candidate(index).text().toStringForCommit() == "你好") {
            saw_nihao = true;
        }
    }
    if (!saw_nihao) {
        Die("candidate page after nihao did not include 你好");
    }
    frontend->call<fcitx::ITestFrontend::keyEvent>(uuid, fcitx::Key("space"), false);
    frontend->call<fcitx::ITestFrontend::keyEvent>(uuid, fcitx::Key("space"), true);
    std::cout << "ok: testfrontend nihao + Space\n";

    Type(frontend, uuid, "ni");
    candidates = ic->inputPanel().candidateList();
    if (!candidates || candidates->size() < 2) {
        Die("expected at least two candidates after typing ni");
    }
    const std::string second = candidates->candidate(1).text().toStringForCommit();
    frontend->call<fcitx::ITestFrontend::pushCommitExpectation>(second);
    frontend->call<fcitx::ITestFrontend::keyEvent>(uuid, fcitx::Key("2"), false);
    frontend->call<fcitx::ITestFrontend::keyEvent>(uuid, fcitx::Key("2"), true);
    std::cout << "ok: testfrontend number selection\n";

    Type(frontend, uuid, "a");
    candidates = ic->inputPanel().candidateList();
    if (!candidates || candidates->empty()) {
        Die("expected candidates before paging");
    }
    const std::string first_page = candidates->candidate(0).text().toStringForCommit();
    frontend->call<fcitx::ITestFrontend::keyEvent>(uuid, fcitx::Key("Page_Down"), false);
    frontend->call<fcitx::ITestFrontend::keyEvent>(uuid, fcitx::Key("Page_Down"), true);
    candidates = ic->inputPanel().candidateList();
    if (!candidates || candidates->empty()) {
        Die("page down cleared the candidate list");
    }
    const std::string paged = candidates->candidate(0).text().toStringForCommit();
    auto* pageable = candidates->toPageable();
    if (paged == first_page &&
        (pageable == nullptr || (!pageable->hasNext() && !pageable->hasPrev()))) {
        Die("page down left a single unpageable list");
    }
    frontend->call<fcitx::ITestFrontend::keyEvent>(uuid, fcitx::Key("Escape"), false);
    frontend->call<fcitx::ITestFrontend::keyEvent>(uuid, fcitx::Key("Escape"), true);
    std::cout << "ok: testfrontend paging\n";

    Type(frontend, uuid, "nihao");
    frontend->call<fcitx::ITestFrontend::keyEvent>(uuid, fcitx::Key("Escape"), false);
    frontend->call<fcitx::ITestFrontend::keyEvent>(uuid, fcitx::Key("Escape"), true);
    std::cout << "ok: testfrontend Escape\n";

    auto key = [&](const char* name) {
        frontend->call<fcitx::ITestFrontend::keyEvent>(uuid, fcitx::Key(name), false);
        frontend->call<fcitx::ITestFrontend::keyEvent>(uuid, fcitx::Key(name), true);
    };
    Type(frontend, uuid, "shi");
    const auto original = ic->inputPanel().candidateList()->candidate(0).text().toStringForCommit();
    key("Page_Down");
    const auto later = ic->inputPanel().candidateList()->candidate(0).text().toStringForCommit();
    key("Page_Up");
    key("Down");
    if (std::getenv("RIMES_REQUIRE_MATRIX_WINDOW") && !ic->inputPanel().customInputPanelCallback())
        Die("native matrix popup did not replace the compact Fcitx panel");
    key("Down"); key("Escape");
    if (ic->inputPanel().customInputPanelCallback())
        Die("matrix Escape left the native panel active");
    if (ic->inputPanel().clientPreedit().empty() || ic->inputPanel().candidateList()->candidate(0).text().toStringForCommit() != original)
        Die("matrix Escape failed to restore opening page and composition");
    key("Down"); key("Down");
    frontend->call<fcitx::ITestFrontend::pushCommitExpectation>(later);
    key("space");
    Type(frontend, uuid, "ni");
    fcitx::RawConfig config;
    auto* engine = instance.inputMethodEngine(ic);
    config.setValueByPath("VerticalCandidates", "False"); engine->setConfig(config);
    if (ic->inputPanel().candidateList()->layoutHint() != fcitx::CandidateLayoutHint::Horizontal)
        Die("horizontal setting was not applied to the candidate list");
    config.setValueByPath("VerticalCandidates", "True"); engine->setConfig(config);
    if (ic->inputPanel().candidateList()->layoutHint() != fcitx::CandidateLayoutHint::Vertical)
        Die("vertical setting was not applied to the candidate list");
    key("Escape");
    std::cout << "ok: matrix navigation, Escape, exact later-page commit and orientation settings\n";

    Type(frontend, uuid, "nihao");
    if (ic->inputPanel().clientPreedit().empty()) {
        Die("expected inline preedit before focus-out");
    }
    ic->focusOut();
    ic->focusIn();
    if (!ic->inputPanel().clientPreedit().empty() ||
        !ic->inputPanel().preedit().empty()) {
        Die("focus-out left a leftover preedit");
    }
    std::cout << "ok: testfrontend focus-out did not commit\n";

    frontend->call<fcitx::ITestFrontend::destroyInputContext>(uuid);
    instance.exit();
}

}  // namespace

int main(int argc, char** argv) {
    if (argc < 4) {
        std::cerr << "Usage: rimes-fcitx-e2e <build-dir> <addon-rel-dir> <data-rel-dir>\n";
        return EXIT_FAILURE;
    }

    // Empty user dir so the addon takes the async first-run deploy path.
    IsolateEmptyUserDir();

    fcitx::setupTestingEnvironment(argv[1], {argv[2]}, {argv[3]});

    char arg0[] = "rimes-fcitx-e2e";
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
        uuid = frontend->call<fcitx::ITestFrontend::createInputContext>("rimes-e2e");
        ic = instance.inputContextManager().findByUUID(uuid);
        if (ic == nullptr) {
            Die("test input context was not created");
        }
        instance.setCurrentInputMethod(ic, "rimes", true);
        if (instance.inputMethod(ic) != "rimes") {
            Die("could not switch the test context to rimes");
        }

        // Yield back to the event loop so the addon's EventDispatcher can
        // receive the maintenance-thread notify. A one-shot timer that only
        // called setTime() would miss that — re-arm with setOneShot().
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
                std::cout << "ok: testfrontend left Deploying after background deploy\n";
                RunTypingSuite(instance, frontend, uuid, ic);
                return true;
            });
    });

    try {
        return instance.exec();
    } catch (const fcitx::InstanceQuietQuit&) {
        return EXIT_SUCCESS;
    } catch (const std::exception& exception) {
        Die(exception.what());
    }
}
