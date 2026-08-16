#pragma once

#include <cstddef>
#include <cstdint>
#include <type_traits>

namespace rimes::windows::engine::abi {

using Bool = int;
using SessionId = std::uintptr_t;

// Prefix-compatible declarations calibrated against librime's public 1.x
// rime_api.h and the existing Sources/CRimeBridge adapter. Only the prefix
// through free_context is used by the Windows broker. Never append a function
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
};

using GetApiFunction = ApiPrefix* (*)();

template <typename Type>
void InitializeVersionedStruct(Type* value) noexcept {
  *value = Type{};
  value->data_size =
      static_cast<int>(sizeof(Type) - sizeof(value->data_size));
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
