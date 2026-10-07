#pragma once

#include <cstddef>
#include <cstdint>
#include <type_traits>

namespace rimes::windows::engine::abi {

using Bool = int;
using SessionId = std::uintptr_t;

// Prefix-compatible declarations calibrated against librime's public 1.x
// rime_api.h and the existing Sources/CRimeBridge adapter. Only the prefix
// through config_set_int is used by the Windows broker. Never append a function
// here without checking both its exact order and RimeApi::data_size first.
struct Traits {
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

struct Composition {
  int length;
  int cursor_pos;
  int sel_start;
  int sel_end;
  char* preedit;
};

struct Candidate {
  char* text;
  char* comment;
  void* reserved;
};

struct Menu {
  int page_size;
  int page_no;
  Bool is_last_page;
  int highlighted_candidate_index;
  int num_candidates;
  Candidate* candidates;
  char* select_keys;
};

struct Commit {
  int data_size;
  char* text;
};

struct Context {
  int data_size;
  Composition composition;
  Menu menu;
  char* commit_text_preview;
  char** select_labels;
};

using NotificationHandler = void (*)(void*, SessionId, const char*,
                                     const char*);

struct Config { void* ptr; };

struct ApiPrefix {
  int data_size;
  void (*setup)(Traits*);
  void (*set_notification_handler)(NotificationHandler, void*);
  void (*initialize)(Traits*);
  void (*finalize)();
  Bool (*start_maintenance)(Bool);
  Bool (*is_maintenance_mode)();
  void (*join_maintenance_thread)();
  void (*deployer_initialize)(Traits*);
  Bool (*prebuild)();
  Bool (*deploy)();
  Bool (*deploy_schema)(const char*);
  Bool (*deploy_config_file)(const char*, const char*);
  Bool (*sync_user_data)();
  SessionId (*create_session)();
  Bool (*find_session)(SessionId);
  Bool (*destroy_session)(SessionId);
  void (*cleanup_stale_sessions)();
  void (*cleanup_all_sessions)();
  Bool (*process_key)(SessionId, int, int);
  Bool (*commit_composition)(SessionId);
  void (*clear_composition)(SessionId);
  Bool (*get_commit)(SessionId, Commit*);
  Bool (*free_commit)(Commit*);
  Bool (*get_context)(SessionId, Context*);
  Bool (*free_context)(Context*);
  Bool (*get_status)(SessionId, void*);
  Bool (*free_status)(void*);
  void (*set_option)(SessionId, const char*, Bool);
  Bool (*get_option)(SessionId, const char*);
  void (*set_property)(SessionId, const char*, const char*);
  Bool (*get_property)(SessionId, const char*, char*, std::size_t);
  Bool (*get_schema_list)(void*);
  void (*free_schema_list)(void*);
  Bool (*get_current_schema)(SessionId, char*, std::size_t);
  Bool (*select_schema)(SessionId, const char*);
  // Calibrated to librime 1.17.0 rime_api.h. Unused slots are never called;
  // retaining their order is necessary to reach config_set_int safely.
  Bool (*schema_open)(const char*, Config*);
  Bool (*config_open)(const char*, Config*);
  Bool (*config_close)(Config*);
  void (*unused_config_get_bool)();
  void (*unused_config_get_int)();
  void (*unused_config_get_double)();
  void (*unused_config_get_string)();
  void (*unused_config_get_cstring)();
  void (*unused_config_update_signature)();
  void (*unused_config_begin_map)();
  void (*unused_config_next)();
  void (*unused_config_end)();
  void (*unused_simulate_key_sequence)();
  void (*unused_register_module)();
  void (*unused_find_module)();
  void (*unused_run_task)();
  void (*unused_get_shared_data_dir)();
  void (*unused_get_user_data_dir)();
  void (*unused_get_sync_dir)();
  void (*unused_get_user_id)();
  void (*unused_get_user_data_sync_dir)();
  void (*unused_config_init)();
  void (*unused_config_load_string)();
  void (*unused_config_set_bool)();
  Bool (*config_set_int)(Config*, const char*, int);
};

using GetApiFunction = ApiPrefix* (*)();

template <typename Type>
void InitializeVersionedStruct(Type* value) noexcept {
  *value = Type{};
  value->data_size = static_cast<int>(sizeof(Type) - sizeof(value->data_size));
}

static_assert(std::is_standard_layout_v<Traits>);
static_assert(std::is_standard_layout_v<Commit>);
static_assert(std::is_standard_layout_v<Context>);
static_assert(std::is_standard_layout_v<ApiPrefix>);
static_assert(offsetof(Traits, data_size) == 0);
static_assert(offsetof(Commit, data_size) == 0);
static_assert(offsetof(Context, data_size) == 0);
static_assert(offsetof(ApiPrefix, data_size) == 0);

}  // namespace rimes::windows::engine::abi
