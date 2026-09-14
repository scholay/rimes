#include "CRimeBridge.h"

#include <dlfcn.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

#include <mutex>
#include <sstream>
#include <string>
#include <vector>

typedef int Bool;
typedef uintptr_t RimeSessionId;

struct RimeTraits {
    int data_size;
    const char* shared_data_dir;
    const char* user_data_dir;
    const char* distribution_name;
    const char* distribution_code_name;
    const char* distribution_version;
    const char* app_name;
    const char** modules;
    int min_log_level;
    const char* log_dir;
    const char* prebuilt_data_dir;
    const char* staging_dir;
};

struct RimeComposition {
    int length;
    int cursor_pos;
    int sel_start;
    int sel_end;
    char* preedit;
};

struct RimeCandidate {
    char* text;
    char* comment;
    void* reserved;
};

struct RimeMenu {
    int page_size;
    int page_no;
    Bool is_last_page;
    int highlighted_candidate_index;
    int num_candidates;
    RimeCandidate* candidates;
    char* select_keys;
};

struct RimeCommit {
    int data_size;
    char* text;
};

struct RimeContext {
    int data_size;
    RimeComposition composition;
    RimeMenu menu;
    char* commit_text_preview;
    char** select_labels;
};

struct RimeStatus {
    int data_size;
    char* schema_id;
    char* schema_name;
    Bool is_disabled;
    Bool is_composing;
    Bool is_ascii_mode;
    Bool is_full_shape;
    Bool is_simplified;
    Bool is_traditional;
    Bool is_ascii_punct;
};

struct RimeSchemaListItem {
    char* schema_id;
    char* name;
    void* reserved;
};

struct RimeSchemaList {
    size_t size;
    RimeSchemaListItem* list;
};

struct RimeStringSlice {
    const char* str;
    size_t length;
};

struct RimeCandidateListIterator {
    void* ptr;
    int index;
    RimeCandidate candidate;
};

struct RimeConfig {
    void* ptr;
};

struct RimeConfigIterator {
    void* list;
    void* map;
    int index;
    const char* key;
    const char* path;
};

typedef void (*RimeNotificationHandler)(void* context_object,
                                        RimeSessionId session_id,
                                        const char* message_type,
                                        const char* message_value);

struct RimeModule {
    int data_size;
    const char* module_name;
    void (*initialize)(void);
    void (*finalize)(void);
    void* (*get_api)(void);
};

// Prefix-compatible copy of librime 1.x's custom `levers` API. This is a
// separate, versioned custom API returned by find_module("levers"); it is NOT
// part of the load-bearing RimeApi vtable below. Keep field order identical to
// rime_levers_api.h and check data_size before calling optional members.
struct RimeUserDictIterator {
    void* ptr;
    size_t i;
};

struct RimeLeversApi {
    int data_size;
    void* (*custom_settings_init)(const char*, const char*);
    void (*custom_settings_destroy)(void*);
    Bool (*load_settings)(void*);
    Bool (*save_settings)(void*);
    Bool (*customize_bool)(void*, const char*, Bool);
    Bool (*customize_int)(void*, const char*, int);
    Bool (*customize_double)(void*, const char*, double);
    Bool (*customize_string)(void*, const char*, const char*);
    Bool (*is_first_run)(void*);
    Bool (*settings_is_modified)(void*);
    Bool (*settings_get_config)(void*, RimeConfig*);
    void* (*switcher_settings_init)(void);
    Bool (*get_available_schema_list)(void*, RimeSchemaList*);
    Bool (*get_selected_schema_list)(void*, RimeSchemaList*);
    void (*schema_list_destroy)(RimeSchemaList*);
    const char* (*get_schema_id)(void*);
    const char* (*get_schema_name)(void*);
    const char* (*get_schema_version)(void*);
    const char* (*get_schema_author)(void*);
    const char* (*get_schema_description)(void*);
    const char* (*get_schema_file_path)(void*);
    Bool (*select_schemas)(void*, const char*[], int);
    const char* (*get_hotkeys)(void*);
    Bool (*set_hotkeys)(void*, const char*);
    Bool (*user_dict_iterator_init)(RimeUserDictIterator*);
    void (*user_dict_iterator_destroy)(RimeUserDictIterator*);
    const char* (*next_user_dict)(RimeUserDictIterator*);
    Bool (*backup_user_dict)(const char*);
    Bool (*restore_user_dict)(const char*);
    int (*export_user_dict)(const char*, const char*);
    int (*import_user_dict)(const char*, const char*);
    Bool (*customize_item)(void*, const char*, RimeConfig*);
};

struct RimeApi {
    int data_size;
    void (*setup)(RimeTraits*);
    void (*set_notification_handler)(RimeNotificationHandler, void*);
    void (*initialize)(RimeTraits*);
    void (*finalize)(void);
    Bool (*start_maintenance)(Bool);
    Bool (*is_maintenance_mode)(void);
    void (*join_maintenance_thread)(void);
    void (*deployer_initialize)(RimeTraits*);
    Bool (*prebuild)(void);
    Bool (*deploy)(void);
    Bool (*deploy_schema)(const char*);
    Bool (*deploy_config_file)(const char*, const char*);
    Bool (*sync_user_data)(void);
    RimeSessionId (*create_session)(void);
    Bool (*find_session)(RimeSessionId);
    Bool (*destroy_session)(RimeSessionId);
    void (*cleanup_stale_sessions)(void);
    void (*cleanup_all_sessions)(void);
    Bool (*process_key)(RimeSessionId, int, int);
    Bool (*commit_composition)(RimeSessionId);
    void (*clear_composition)(RimeSessionId);
    Bool (*get_commit)(RimeSessionId, RimeCommit*);
    Bool (*free_commit)(RimeCommit*);
    Bool (*get_context)(RimeSessionId, RimeContext*);
    Bool (*free_context)(RimeContext*);
    Bool (*get_status)(RimeSessionId, RimeStatus*);
    Bool (*free_status)(RimeStatus*);
    void (*set_option)(RimeSessionId, const char*, Bool);
    Bool (*get_option)(RimeSessionId, const char*);
    void (*set_property)(RimeSessionId, const char*, const char*);
    Bool (*get_property)(RimeSessionId, const char*, char*, size_t);
    Bool (*get_schema_list)(RimeSchemaList*);
    void (*free_schema_list)(RimeSchemaList*);
    Bool (*get_current_schema)(RimeSessionId, char*, size_t);
    Bool (*select_schema)(RimeSessionId, const char*);
    Bool (*schema_open)(const char*, RimeConfig*);
    Bool (*config_open)(const char*, RimeConfig*);
    Bool (*config_close)(RimeConfig*);
    Bool (*config_get_bool)(RimeConfig*, const char*, Bool*);
    Bool (*config_get_int)(RimeConfig*, const char*, int*);
    Bool (*config_get_double)(RimeConfig*, const char*, double*);
    Bool (*config_get_string)(RimeConfig*, const char*, char*, size_t);
    const char* (*config_get_cstring)(RimeConfig*, const char*);
    Bool (*config_update_signature)(RimeConfig*, const char*);
    Bool (*config_begin_map)(RimeConfigIterator*, RimeConfig*, const char*);
    Bool (*config_next)(RimeConfigIterator*);
    void (*config_end)(RimeConfigIterator*);
    Bool (*simulate_key_sequence)(RimeSessionId, const char*);
    Bool (*register_module)(RimeModule*);
    RimeModule* (*find_module)(const char*);
    Bool (*run_task)(const char*);
    const char* (*get_shared_data_dir)(void);
    const char* (*get_user_data_dir)(void);
    const char* (*get_sync_dir)(void);
    const char* (*get_user_id)(void);
    void (*get_user_data_sync_dir)(char*, size_t);
    Bool (*config_init)(RimeConfig*);
    Bool (*config_load_string)(RimeConfig*, const char*);
    Bool (*config_set_bool)(RimeConfig*, const char*, Bool);
    Bool (*config_set_int)(RimeConfig*, const char*, int);
    Bool (*config_set_double)(RimeConfig*, const char*, double);
    Bool (*config_set_string)(RimeConfig*, const char*, const char*);
    Bool (*config_get_item)(RimeConfig*, const char*, RimeConfig*);
    Bool (*config_set_item)(RimeConfig*, const char*, RimeConfig*);
    Bool (*config_clear)(RimeConfig*, const char*);
    Bool (*config_create_list)(RimeConfig*, const char*);
    Bool (*config_create_map)(RimeConfig*, const char*);
    size_t (*config_list_size)(RimeConfig*, const char*);
    Bool (*config_begin_list)(RimeConfigIterator*, RimeConfig*, const char*);
    const char* (*get_input)(RimeSessionId);
    size_t (*get_caret_pos)(RimeSessionId);
    Bool (*select_candidate)(RimeSessionId, size_t);
    const char* (*get_version)(void);
    void (*set_caret_pos)(RimeSessionId, size_t);
    Bool (*select_candidate_on_current_page)(RimeSessionId, size_t);
    Bool (*candidate_list_begin)(RimeSessionId, RimeCandidateListIterator*);
    Bool (*candidate_list_next)(RimeCandidateListIterator*);
    void (*candidate_list_end)(RimeCandidateListIterator*);
    Bool (*user_config_open)(const char*, RimeConfig*);
    Bool (*candidate_list_from_index)(RimeSessionId,
                                      RimeCandidateListIterator*,
                                      int);
    const char* (*get_prebuilt_data_dir)(void);
    const char* (*get_staging_dir)(void);
    void (*commit_proto)(RimeSessionId, void*);
    void (*context_proto)(RimeSessionId, void*);
    void (*status_proto)(RimeSessionId, void*);
    const char* (*get_state_label)(RimeSessionId, const char*, Bool);
    Bool (*delete_candidate)(RimeSessionId, size_t);
    Bool (*delete_candidate_on_current_page)(RimeSessionId, size_t);
    RimeStringSlice (*get_state_label_abbreviated)(RimeSessionId,
                                                    const char*,
                                                    Bool,
                                                    Bool);
    Bool (*set_input)(RimeSessionId, const char*);
    void (*get_shared_data_dir_s)(char*, size_t);
    void (*get_user_data_dir_s)(char*, size_t);
    void (*get_prebuilt_data_dir_s)(char*, size_t);
    void (*get_staging_dir_s)(char*, size_t);
    void (*get_sync_dir_s)(char*, size_t);
    Bool (*highlight_candidate)(RimeSessionId, size_t);
    Bool (*highlight_candidate_on_current_page)(RimeSessionId, size_t);
    Bool (*change_page)(RimeSessionId, Bool);
};

typedef RimeApi* (*RimeGetApiFunc)(void);

static std::mutex gMutex;
static RimeApi* gApi = nullptr;
static bool gStarted = false;
static bool gOctagramAvailable = false;
static std::string gLastError;
static std::string gSharedDataDir;
static std::string gUserDataDir;
static std::string gLogDir;

// Fallback location when the app isn't self-contained: a system Squirrel install.
static const char* kSquirrelFrameworks =
    "/Library/Input Methods/Squirrel.app/Contents/Frameworks";

static bool fileExists(const std::string& path) {
    struct stat st;
    return stat(path.c_str(), &st) == 0;
}

// Prefer the app's own bundled Frameworks dir; fall back to Squirrel's. `leaf`
// is relative to a Frameworks dir, e.g. "librime.1.dylib" or
// "rime-plugins/librime-lua.dylib".
static std::string resolveDylib(const std::string& frameworksDir, const char* leaf) {
    if (!frameworksDir.empty()) {
        std::string bundled = frameworksDir + "/" + leaf;
        if (fileExists(bundled)) return bundled;
    }
    return std::string(kSquirrelFrameworks) + "/" + leaf;
}

#define RIME_STRUCT_INIT(Type, var) \
    ((var).data_size = (int)(sizeof(Type) - sizeof((var).data_size)))

static char* copyString(const std::string& value) {
    char* result = static_cast<char*>(malloc(value.size() + 1));
    if (!result) return nullptr;
    memcpy(result, value.c_str(), value.size() + 1);
    return result;
}

// Backing storage for the pointers handed out by BBRimeGetContext /
// BBRimeGetStatus. Valid until the next call; guarded by gMutex; the Swift side
// copies immediately. Fixed-size so element addresses never move.
static std::string gCtxPreedit;
static std::string gCtxInput;
static std::vector<std::string> gCandText(BB_MAX_CANDIDATES);
static std::vector<std::string> gCandComment(BB_MAX_CANDIDATES);
static std::vector<std::string> gCandLabel(BB_MAX_CANDIDATES);
static std::string gStatusSchemaId;
static std::string gStatusSchemaName;

template <typename Struct, typename Member>
static bool apiHasMember(const Struct* api, Member Struct::*member) {
    if (!api) return false;
    const size_t offset = reinterpret_cast<const char*>(&(api->*member))
        - reinterpret_cast<const char*>(api);
    const size_t available = sizeof(api->data_size) + static_cast<size_t>(api->data_size);
    return available >= offset + sizeof(api->*member);
}

static RimeLeversApi* leversApi() {
    if (!gApi || !gApi->find_module) return nullptr;
    RimeModule* module = gApi->find_module("levers");
    if (!module || !module->get_api) return nullptr;
    return reinterpret_cast<RimeLeversApi*>(module->get_api());
}

static bool loadDylib(const char* path, bool required) {
    void* handle = dlopen(path, RTLD_NOW | RTLD_GLOBAL);
    if (handle) return true;

    const char* err = dlerror();
    gLastError = std::string("dlopen failed: ") + path;
    if (err) {
        gLastError += " ";
        gLastError += err;
    }
    return !required;
}

bool BBRimeStart(const char* sharedDataDir,
                 const char* userDataDir,
                 const char* logDir,
                 const char* frameworksDir) {
    std::lock_guard<std::mutex> lock(gMutex);
    if (gStarted) return true;

    gSharedDataDir = sharedDataDir ? sharedDataDir : "";
    gUserDataDir = userDataDir ? userDataDir : "";
    gLogDir = logDir ? logDir : "";
    std::string fw = frameworksDir ? frameworksDir : "";

    // librime is dlopen'd (not linked). Load it FIRST with RTLD_GLOBAL so that
    // when the plugins below ask for their `@rpath/librime.1.dylib` dependency,
    // dyld satisfies it from this already-loaded image by install-name match —
    // no LC_RPATH needed on the plugins or on us.
    if (!loadDylib(resolveDylib(fw, "librime.1.dylib").c_str(), true)) return false;
    loadDylib(resolveDylib(fw, "rime-plugins/librime-lua.dylib").c_str(), false);
    loadDylib(resolveDylib(fw, "rime-plugins/librime-octagram.dylib").c_str(), false);
    loadDylib(resolveDylib(fw, "rime-plugins/librime-predict.dylib").c_str(), false);

    auto getApi = reinterpret_cast<RimeGetApiFunc>(dlsym(RTLD_DEFAULT, "rime_get_api"));
    if (!getApi) {
        const char* err = dlerror();
        gLastError = std::string("dlsym rime_get_api failed");
        if (err) {
            gLastError += ": ";
            gLastError += err;
        }
        return false;
    }

    gApi = getApi();
    if (!gApi) {
        gLastError = "rime_get_api returned null";
        return false;
    }

    static const char* modules[] = {"default", "lua", "octagram", "predict", nullptr};
    RimeTraits traits = {0};
    RIME_STRUCT_INIT(RimeTraits, traits);
    traits.shared_data_dir = gSharedDataDir.c_str();
    traits.user_data_dir = gUserDataDir.c_str();
    traits.distribution_name = "RimeBuffer";
    traits.distribution_code_name = "rimebuffer";
    traits.distribution_version = "0.1";
    traits.app_name = "rime.rimebuffer";
    traits.modules = modules;
    traits.min_log_level = 0;
    traits.log_dir = gLogDir.c_str();
    traits.prebuilt_data_dir = nullptr;
    traits.staging_dir = nullptr;

    gApi->setup(&traits);
    gApi->initialize(&traits);
    gOctagramAvailable = gApi->find_module
        && gApi->find_module("octagram") != nullptr;

    // First-run / stale deploy: build the schemas from shared_data_dir into
    // user_data_dir/build. This is what makes a self-contained app work with no
    // prior Squirrel/~/Library/Rime — otherwise create_session below fails
    // because there's no compiled data. full_check only on the first build (no
    // build dir yet) so subsequent launches stay fast.
    if (gApi->start_maintenance) {
        bool needFullCheck = !fileExists(gUserDataDir + "/build");
        bool maintenanceStarted = gApi->start_maintenance(needFullCheck ? 1 : 0) != 0;
        // squirrel.yaml is a frontend config, so librime's ordinary schema
        // maintenance does not build it by itself. Deploy it explicitly (the
        // same step Squirrel performs) so squirrel.custom.yaml is merged and
        // chord_duration can be read from the authoritative deployed config.
        // Calling this on every start is intentional and idempotent: existing
        // RimeBuffer user dirs may predate this frontend-config deployment.
        if (gApi->deploy_config_file) {
            gApi->deploy_config_file("squirrel.yaml", "config_version");
        }
        if (maintenanceStarted && gApi->join_maintenance_thread) {
            gApi->join_maintenance_thread();
        }
    }

    // This inference-only schema is intentionally absent from the F4 list, so
    // ordinary maintenance may not compile it. Failure stays non-fatal: the
    // stream engine can fall back without taking ordinary Rime input down.
    if (gApi->deploy_schema
        && fileExists(gSharedDataDir + "/stream_input_local.schema.yaml")) {
        const std::string streamSchema =
            gSharedDataDir + "/stream_input_local.schema.yaml";
        gApi->deploy_schema(streamSchema.c_str());
    }

    // Health gate: only report started if a smoke session actually spins up.
    if (!gApi->create_session) {
        gLastError = "librime missing create_session";
        return false;
    }
    RimeSessionId smoke = gApi->create_session();
    if (!smoke) {
        gLastError = "smoke create_session failed (deploy did not produce usable data)";
        return false;
    }
    if (gApi->destroy_session) gApi->destroy_session(smoke);

    gStarted = true;
    gLastError.clear();
    return true;
}

bool BBRimeIsHealthy(void) {
    std::lock_guard<std::mutex> lock(gMutex);
    return gStarted && gApi != nullptr;
}

bool BBRimeHasOctagram(void) {
    std::lock_guard<std::mutex> lock(gMutex);
    return gStarted && gOctagramAvailable;
}

uint64_t BBRimeCreateSession(void) {
    std::lock_guard<std::mutex> lock(gMutex);
    if (!gStarted || !gApi || !gApi->create_session) return 0;
    return static_cast<uint64_t>(gApi->create_session());
}

void BBRimeDestroySession(uint64_t session) {
    std::lock_guard<std::mutex> lock(gMutex);
    if (!gStarted || !gApi || !gApi->destroy_session || session == 0) return;
    gApi->destroy_session(static_cast<RimeSessionId>(session));
}

bool BBRimeProcessKey(uint64_t session, int32_t keycode, int32_t mask) {
    std::lock_guard<std::mutex> lock(gMutex);
    if (!gStarted || !gApi || !gApi->process_key || session == 0) return false;
    return gApi->process_key(static_cast<RimeSessionId>(session), keycode, mask);
}

bool BBRimeCommitComposition(uint64_t session) {
    std::lock_guard<std::mutex> lock(gMutex);
    if (!gStarted || !gApi || !gApi->commit_composition || session == 0) return false;
    return gApi->commit_composition(static_cast<RimeSessionId>(session));
}

void BBRimeClearComposition(uint64_t session) {
    std::lock_guard<std::mutex> lock(gMutex);
    if (!gStarted || !gApi || !gApi->clear_composition || session == 0) return;
    gApi->clear_composition(static_cast<RimeSessionId>(session));
}

bool BBRimeSelectCandidateOnCurrentPage(uint64_t session, uint64_t index) {
    std::lock_guard<std::mutex> lock(gMutex);
    if (!gStarted || !gApi || !gApi->select_candidate_on_current_page || session == 0) {
        return false;
    }
    return gApi->select_candidate_on_current_page(
        static_cast<RimeSessionId>(session),
        static_cast<size_t>(index));
}

bool BBRimeGetOption(uint64_t session, const char* option) {
    std::lock_guard<std::mutex> lock(gMutex);
    if (!gStarted || !gApi || !gApi->get_option || session == 0 || !option) {
        return false;
    }
    return gApi->get_option(static_cast<RimeSessionId>(session), option);
}

char* BBRimeCopyCommit(uint64_t session) {
    std::lock_guard<std::mutex> lock(gMutex);
    if (!gStarted || !gApi || !gApi->get_commit || !gApi->free_commit || session == 0) {
        return nullptr;
    }

    RimeCommit commit = {0};
    RIME_STRUCT_INIT(RimeCommit, commit);
    if (!gApi->get_commit(static_cast<RimeSessionId>(session), &commit)) {
        return nullptr;
    }

    std::string text = commit.text ? commit.text : "";
    gApi->free_commit(&commit);
    if (text.empty()) return nullptr;
    return copyString(text);
}

char* BBRimeCopySchema(uint64_t session) {
    std::lock_guard<std::mutex> lock(gMutex);
    if (!gStarted || !gApi || !gApi->get_current_schema || session == 0) return nullptr;

    char schema[128] = {0};
    if (!gApi->get_current_schema(static_cast<RimeSessionId>(session), schema, sizeof(schema))) {
        return nullptr;
    }
    return copyString(schema);
}

bool BBRimeGetContext(uint64_t session, BBRimeContext* out) {
    std::lock_guard<std::mutex> lock(gMutex);
    if (!out) return false;
    memset(out, 0, sizeof(*out));
    if (!gStarted || !gApi || !gApi->get_context || !gApi->free_context || session == 0) {
        return false;
    }

    RimeContext context = {0};
    RIME_STRUCT_INIT(RimeContext, context);
    if (!gApi->get_context(static_cast<RimeSessionId>(session), &context)) {
        return false;
    }

    const char* rawInput = gApi->get_input
        ? gApi->get_input(static_cast<RimeSessionId>(session))
        : nullptr;
    gCtxPreedit = context.composition.preedit ? context.composition.preedit : "";
    gCtxInput = rawInput ? rawInput : "";

    out->preedit = gCtxPreedit.c_str();
    out->input = gCtxInput.c_str();
    out->cursorPos = context.composition.cursor_pos;
    out->inputCaretPos = gApi->get_caret_pos
        ? static_cast<int>(gApi->get_caret_pos(static_cast<RimeSessionId>(session)))
        : -1;
    out->selStart = context.composition.sel_start;
    out->selEnd = context.composition.sel_end;
    out->pageSize = context.menu.page_size;
    out->pageNo = context.menu.page_no;
    out->isLastPage = context.menu.is_last_page != 0;
    out->highlightedIndex = context.menu.highlighted_candidate_index;

    int count = context.menu.num_candidates;
    if (count > BB_MAX_CANDIDATES) count = BB_MAX_CANDIDATES;
    out->numCandidates = count;
    for (int i = 0; i < count; ++i) {
        std::string label;
        if (context.select_labels && context.select_labels[i]) {
            label = context.select_labels[i];
        } else if (context.menu.select_keys && context.menu.select_keys[i]) {
            label.assign(1, context.menu.select_keys[i]);
        } else {
            label = std::to_string(i + 1);
        }
        gCandLabel[i] = label;
        gCandText[i] = context.menu.candidates[i].text ? context.menu.candidates[i].text : "";
        gCandComment[i] = context.menu.candidates[i].comment ? context.menu.candidates[i].comment : "";
        out->candidates[i].label = gCandLabel[i].c_str();
        out->candidates[i].text = gCandText[i].c_str();
        out->candidates[i].comment = gCandComment[i].c_str();
    }

    out->active = !gCtxInput.empty() || !gCtxPreedit.empty() || count > 0;
    gApi->free_context(&context);
    return true;
}

bool BBRimeGetStatus(uint64_t session, BBRimeStatus* out) {
    std::lock_guard<std::mutex> lock(gMutex);
    if (!out) return false;
    memset(out, 0, sizeof(*out));
    if (!gStarted || !gApi || !gApi->get_status || !gApi->free_status || session == 0) {
        return false;
    }

    RimeStatus status = {0};
    RIME_STRUCT_INIT(RimeStatus, status);
    if (!gApi->get_status(static_cast<RimeSessionId>(session), &status)) {
        return false;
    }

    gStatusSchemaId = status.schema_id ? status.schema_id : "";
    gStatusSchemaName = status.schema_name ? status.schema_name : "";
    out->schemaId = gStatusSchemaId.c_str();
    out->schemaName = gStatusSchemaName.c_str();
    out->disabled = status.is_disabled != 0;
    out->composing = status.is_composing != 0;
    out->asciiMode = status.is_ascii_mode != 0;
    out->fullShape = status.is_full_shape != 0;
    out->simplified = status.is_simplified != 0;
    out->traditional = status.is_traditional != 0;
    out->asciiPunct = status.is_ascii_punct != 0;

    gApi->free_status(&status);
    return true;
}

void BBRimeSetOption(uint64_t session, const char* option, bool value) {
    std::lock_guard<std::mutex> lock(gMutex);
    if (!gStarted || !gApi || !gApi->set_option || session == 0 || !option) return;
    gApi->set_option(static_cast<RimeSessionId>(session), option, value ? 1 : 0);
}

bool BBRimeSelectSchema(uint64_t session, const char* schemaId) {
    std::lock_guard<std::mutex> lock(gMutex);
    if (!gStarted || !gApi || !gApi->select_schema || session == 0 || !schemaId) return false;
    return gApi->select_schema(static_cast<RimeSessionId>(session), schemaId);
}

int BBRimeDecodeCandidateTexts(uint64_t session,
                               const char* input,
                               char* textBuffer,
                               uint64_t candidateStride,
                               int maxCount) {
    std::lock_guard<std::mutex> lock(gMutex);
    if (!gStarted || !gApi || session == 0 || !input || !textBuffer
        || candidateStride < 2 || candidateStride > 65536
        || maxCount <= 0 || maxCount > BB_MAX_CANDIDATES
        || !gApi->get_context || !gApi->free_context
        || !gApi->clear_composition
        || !apiHasMember(gApi, &RimeApi::set_input)
        || !gApi->set_input
        || !apiHasMember(gApi, &RimeApi::highlight_candidate_on_current_page)
        || !gApi->highlight_candidate_on_current_page) {
        return -1;
    }

    const size_t stride = static_cast<size_t>(candidateStride);
    memset(textBuffer, 0, stride * static_cast<size_t>(maxCount));
    const RimeSessionId id = static_cast<RimeSessionId>(session);
    gApi->clear_composition(id);
    if (!gApi->set_input(id, input)) {
        gApi->clear_composition(id);
        return -1;
    }

    RimeContext context = {0};
    RIME_STRUCT_INIT(RimeContext, context);
    if (!gApi->get_context(id, &context)) {
        gApi->clear_composition(id);
        return -1;
    }

    int count = context.menu.candidates ? context.menu.num_candidates : 0;
    if (count > maxCount) count = maxCount;
    gApi->free_context(&context);

    // candidate.text may cover only the translated prefix. Highlight each
    // choice and copy commit_text_preview instead so an unselected tail can
    // never be silently dropped (for example, `nihaox` -> `你好像`, not `你好`).
    for (int i = 0; i < count; ++i) {
        // librime returns false when highlighting is a no-op (normally item 0
        // is already highlighted), so validate the resulting context instead
        // of treating that Bool as an error code.
        gApi->highlight_candidate_on_current_page(id, static_cast<size_t>(i));
        RimeContext preview = {0};
        RIME_STRUCT_INIT(RimeContext, preview);
        if (!gApi->get_context(id, &preview)) {
            gApi->clear_composition(id);
            return -1;
        }
        if (preview.menu.highlighted_candidate_index != i) {
            gApi->free_context(&preview);
            gApi->clear_composition(id);
            return -1;
        }
        const char* text = preview.commit_text_preview;
        const size_t length = text ? strnlen(text, stride) : 0;
        if (!text || length == 0 || length >= stride) {
            gApi->free_context(&preview);
            gApi->clear_composition(id);
            return -1;
        }
        memcpy(textBuffer + stride * static_cast<size_t>(i), text, length);
        gApi->free_context(&preview);
    }
    gApi->clear_composition(id);
    return count;
}

bool BBRimeDeploy(void) {
    std::lock_guard<std::mutex> lock(gMutex);
    if (!gStarted || !gApi || !gApi->deploy) return false;
    return gApi->deploy();
}

bool BBRimeConfigGetDouble(const char* configId, const char* key, double* out) {
    std::lock_guard<std::mutex> lock(gMutex);
    if (!gStarted || !gApi || !gApi->config_open || !gApi->config_get_double ||
        !gApi->config_close || !configId || !key || !out) {
        return false;
    }
    RimeConfig config = {nullptr};
    if (!gApi->config_open(configId, &config)) return false;
    Bool ok = gApi->config_get_double(&config, key, out);
    gApi->config_close(&config);
    return ok != 0;
}

static std::vector<std::string> gSchemaIds(64);
static std::vector<std::string> gSchemaNames(64);

int BBRimeGetSchemaList(BBRimeSchema* out, int maxCount) {
    std::lock_guard<std::mutex> lock(gMutex);
    if (!out || maxCount <= 0) return 0;
    if (!gStarted || !gApi || !gApi->get_schema_list || !gApi->free_schema_list) return 0;

    RimeSchemaList list;
    memset(&list, 0, sizeof(list));
    if (!gApi->get_schema_list(&list)) return 0;

    int count = (int)list.size;
    if (count > maxCount) count = maxCount;
    if (count > 64) count = 64;
    for (int i = 0; i < count; ++i) {
        gSchemaIds[i] = list.list[i].schema_id ? list.list[i].schema_id : "";
        gSchemaNames[i] = list.list[i].name ? list.list[i].name : "";
        out[i].id = gSchemaIds[i].c_str();
        out[i].name = gSchemaNames[i].c_str();
    }
    gApi->free_schema_list(&list);
    return count;
}

char* BBRimeCopyLastError(void) {
    std::lock_guard<std::mutex> lock(gMutex);
    return copyString(gLastError);
}

void BBRimeFreeString(char* value) {
    free(value);
}

bool BBRimeSessionExists(uint64_t session) {
    std::lock_guard<std::mutex> lock(gMutex);
    if (!gStarted || !gApi || !gApi->find_session || session == 0) return false;
    return gApi->find_session(static_cast<RimeSessionId>(session)) != 0;
}

bool BBRimeHasUserDictionary(const char* dictName) {
    std::lock_guard<std::mutex> lock(gMutex);
    if (!gStarted || !dictName || !*dictName) return false;
    RimeLeversApi* api = leversApi();
    if (!api
        || !apiHasMember(api, &RimeLeversApi::user_dict_iterator_init)
        || !apiHasMember(api, &RimeLeversApi::user_dict_iterator_destroy)
        || !apiHasMember(api, &RimeLeversApi::next_user_dict)
        || !api->user_dict_iterator_init
        || !api->user_dict_iterator_destroy
        || !api->next_user_dict) {
        return false;
    }

    RimeUserDictIterator iterator = {nullptr, 0};
    if (!api->user_dict_iterator_init(&iterator)) return false;
    bool found = false;
    while (const char* name = api->next_user_dict(&iterator)) {
        if (strcmp(name, dictName) == 0) {
            found = true;
            break;
        }
    }
    api->user_dict_iterator_destroy(&iterator);
    return found;
}

int BBRimeExportUserDictionary(const char* dictName, const char* textFile) {
    std::lock_guard<std::mutex> lock(gMutex);
    if (!gStarted || !gApi || !dictName || !*dictName || !textFile || !*textFile) {
        return -1;
    }
    RimeLeversApi* api = leversApi();
    if (!api
        || !apiHasMember(api, &RimeLeversApi::export_user_dict)
        || !api->export_user_dict
        || !gApi->cleanup_all_sessions) {
        return -1;
    }

    // UserDictManager's upstream contract requires the LevelDB to be closed.
    // Every Swift controller has already received the maintenance notification
    // and settled its composition before entering this bridge call.
    gApi->cleanup_all_sessions();
    return api->export_user_dict(dictName, textFile);
}

int BBRimeImportUserDictionary(const char* dictName, const char* textFile) {
    std::lock_guard<std::mutex> lock(gMutex);
    if (!gStarted || !gApi || !dictName || !*dictName || !textFile || !*textFile) {
        return -1;
    }
    RimeLeversApi* api = leversApi();
    if (!api
        || !apiHasMember(api, &RimeLeversApi::import_user_dict)
        || !api->import_user_dict
        || !gApi->cleanup_all_sessions) {
        return -1;
    }

    gApi->cleanup_all_sessions();
    return api->import_user_dict(dictName, textFile);
}

bool BBRimeRestoreUserDictionarySnapshot(const char* snapshotFile) {
    std::lock_guard<std::mutex> lock(gMutex);
    if (!gStarted || !gApi || !snapshotFile || !*snapshotFile) return false;
    RimeLeversApi* api = leversApi();
    if (!api
        || !apiHasMember(api, &RimeLeversApi::restore_user_dict)
        || !api->restore_user_dict
        || !gApi->cleanup_all_sessions) {
        return false;
    }

    gApi->cleanup_all_sessions();
    return api->restore_user_dict(snapshotFile) != 0;
}
