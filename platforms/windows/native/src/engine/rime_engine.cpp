#include "rime_engine.hpp"

#ifndef _WIN32
#error "RimeEngine is a Windows broker component"
#endif

#include <windows.h>

#include <algorithm>
#include <atomic>
#include <cstring>
#include <cwctype>
#include <limits>
#include <mutex>
#include <string_view>
#include <unordered_set>
#include <utility>
#include <vector>

#include "rime_abi.hpp"

namespace rimes::windows::engine {
namespace {

inline constexpr std::size_t kMaximumWindowsPath = 32767;
inline constexpr std::size_t kMaximumSelectKeysBytes =
    core::kMaxCandidateCount * 4;
inline constexpr std::size_t kMaximumApiBytes = 64U * 1024U;

std::atomic<void*> g_runtime_owner = nullptr;

void SetError(std::string* error, std::string_view message) noexcept {
  if (error == nullptr) {
    return;
  }
  try {
    error->assign(message);
  } catch (...) {
    // Diagnostics are best effort at this boundary.
  }
}

std::string Win32ErrorMessage(DWORD code) noexcept {
  try {
    wchar_t* system_message = nullptr;
    const DWORD count = FormatMessageW(
        FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_SYSTEM |
            FORMAT_MESSAGE_IGNORE_INSERTS,
        nullptr, code, 0, reinterpret_cast<wchar_t*>(&system_message), 0,
        nullptr);
    if (count == 0 || system_message == nullptr) {
      return "Win32 error " + std::to_string(code);
    }
    struct LocalMemoryGuard {
      HLOCAL memory;
      ~LocalMemoryGuard() { LocalFree(memory); }
    };
    [[maybe_unused]] LocalMemoryGuard message_guard{system_message};

    std::wstring_view wide(system_message, count);
    while (!wide.empty() &&
           (wide.back() == L'\r' || wide.back() == L'\n' ||
            wide.back() == L' ')) {
      wide.remove_suffix(1);
    }
    const int required = WideCharToMultiByte(
        CP_UTF8, WC_ERR_INVALID_CHARS, wide.data(),
        static_cast<int>(wide.size()), nullptr, 0, nullptr, nullptr);
    std::string result;
    if (required > 0) {
      result.resize(static_cast<std::size_t>(required));
      WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, wide.data(),
                          static_cast<int>(wide.size()), result.data(), required,
                          nullptr, nullptr);
    } else {
      result = "Win32 error " + std::to_string(code);
    }
    return result;
  } catch (...) {
    return "Win32 operation failed";
  }
}

bool WideToUtf8(std::wstring_view wide,
                std::string* output,
                std::string* error) noexcept {
  try {
    if (wide.empty()) {
      output->clear();
      return true;
    }
    if (wide.size() > static_cast<std::size_t>(std::numeric_limits<int>::max())) {
      SetError(error, "path is too long to encode as UTF-8");
      return false;
    }
    const int required = WideCharToMultiByte(
        CP_UTF8, WC_ERR_INVALID_CHARS, wide.data(),
        static_cast<int>(wide.size()), nullptr, 0, nullptr, nullptr);
    if (required <= 0) {
      SetError(error, "path contains invalid Unicode");
      return false;
    }
    std::string encoded(static_cast<std::size_t>(required), '\0');
    if (WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, wide.data(),
                            static_cast<int>(wide.size()), encoded.data(),
                            required, nullptr, nullptr) != required) {
      SetError(error, "failed to encode path as UTF-8");
      return false;
    }
    *output = std::move(encoded);
    return true;
  } catch (...) {
    SetError(error, "exception while encoding a path");
    return false;
  }
}

bool NormalizeDllPath(const std::filesystem::path& path,
                      std::wstring* output,
                      std::string* error) noexcept {
  try {
    if (path.empty() || !path.is_absolute()) {
      SetError(error, "rime.dll path must be absolute");
      return false;
    }
    const std::wstring input = path.native();
    if (input.size() > kMaximumWindowsPath) {
      SetError(error, "rime.dll path exceeds the Windows path limit");
      return false;
    }

    const DWORD required = GetFullPathNameW(input.c_str(), 0, nullptr, nullptr);
    if (required == 0 || required > kMaximumWindowsPath) {
      SetError(error, "failed to normalize the rime.dll path");
      return false;
    }
    std::wstring normalized(required, L'\0');
    const DWORD written = GetFullPathNameW(input.c_str(), required,
                                           normalized.data(), nullptr);
    if (written == 0 || written >= required) {
      SetError(error, "failed to normalize the rime.dll path");
      return false;
    }
    normalized.resize(written);

    // Do not load executable code from UNC shares or device namespaces. The
    // broker accepts an ordinary absolute path on a local fixed drive only.
    if (normalized.size() < 3 ||
        !std::iswalpha(static_cast<wint_t>(normalized[0])) ||
        normalized[1] != L':' ||
        (normalized[2] != L'\\' && normalized[2] != L'/')) {
      SetError(error, "rime.dll must reside on a local drive");
      return false;
    }
    wchar_t root[] = {normalized[0], L':', L'\\', L'\0'};
    if (GetDriveTypeW(root) != DRIVE_FIXED) {
      SetError(error, "rime.dll must reside on a fixed local drive");
      return false;
    }

    const std::filesystem::path normalized_path(normalized);
    if (CompareStringOrdinal(normalized_path.filename().c_str(), -1,
                             L"rime.dll", -1, TRUE) != CSTR_EQUAL) {
      SetError(error, "engine DLL filename must be rime.dll");
      return false;
    }
    const DWORD attributes = GetFileAttributesW(normalized.c_str());
    if (attributes == INVALID_FILE_ATTRIBUTES ||
        (attributes & FILE_ATTRIBUTE_DIRECTORY) != 0) {
      SetError(error, "rime.dll path does not identify a file");
      return false;
    }

    *output = std::move(normalized);
    return true;
  } catch (...) {
    SetError(error, "exception while validating the rime.dll path");
    return false;
  }
}

bool CopyBoundedCString(const char* value,
                        std::size_t maximum_bytes,
                        std::string* output,
                        std::string* error) noexcept {
  try {
    if (value == nullptr) {
      output->clear();
      return true;
    }
    const void* terminator = std::memchr(value, 0, maximum_bytes + 1);
    if (terminator == nullptr) {
      SetError(error, "librime returned an unterminated or oversized string");
      return false;
    }
    const auto length = static_cast<std::size_t>(
        static_cast<const char*>(terminator) - value);
    output->assign(value, length);
    if (!detail::IsValidUtf8(*output)) {
      SetError(error, "librime returned invalid UTF-8");
      return false;
    }
    return true;
  } catch (...) {
    SetError(error, "exception while copying librime text");
    return false;
  }
}

std::vector<std::string_view> SplitUtf8Scalars(std::string_view text) {
  std::vector<std::string_view> scalars;
  scalars.reserve(core::kMaxCandidateCount);
  std::size_t index = 0;
  while (index < text.size() && scalars.size() < core::kMaxCandidateCount) {
    const auto first = static_cast<unsigned char>(text[index]);
    std::size_t width = 1;
    if (first >= 0xc2U && first <= 0xdfU) {
      width = 2;
    } else if (first >= 0xe0U && first <= 0xefU) {
      width = 3;
    } else if (first >= 0xf0U && first <= 0xf4U) {
      width = 4;
    }
    scalars.push_back(text.substr(index, width));
    index += width;
  }
  return scalars;
}

bool HasRequiredApi(const abi::ApiPrefix* api) noexcept {
  if (api == nullptr || api->data_size < 0) {
    return false;
  }
  const std::size_t available = sizeof(api->data_size) +
                                static_cast<std::size_t>(api->data_size);
  if (available < sizeof(abi::ApiPrefix) || available > kMaximumApiBytes) {
    return false;
  }
  return api->setup != nullptr && api->initialize != nullptr &&
         api->finalize != nullptr && api->start_maintenance != nullptr &&
         api->is_maintenance_mode != nullptr &&
         api->join_maintenance_thread != nullptr &&
         api->create_session != nullptr && api->destroy_session != nullptr &&
         api->process_key != nullptr && api->get_commit != nullptr &&
         api->free_commit != nullptr && api->get_context != nullptr &&
         api->free_context != nullptr;
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

      void* expected = nullptr;
      if (!g_runtime_owner.compare_exchange_strong(expected, this)) {
        SetError(error, "another RimeEngine owns the process-wide librime runtime");
        return false;
      }
      owns_runtime_ = true;

      std::wstring dll_path;
      if (!NormalizeDllPath(options.dll_path, &dll_path, error) ||
          !StoreDataPaths(options, error)) {
        StopLocked();
        return false;
      }

      module_ = LoadLibraryExW(
          dll_path.c_str(), nullptr,
          LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_SYSTEM32);
      if (module_ == nullptr) {
        const std::string win32_error = Win32ErrorMessage(GetLastError());
        SetError(error, "secure LoadLibraryExW failed: " + win32_error);
        StopLocked();
        return false;
      }

      const FARPROC get_api_symbol = GetProcAddress(module_, "rime_get_api");
      if (get_api_symbol == nullptr) {
        SetError(error, "rime.dll does not export rime_get_api");
        StopLocked();
        return false;
      }
      static_assert(sizeof(get_api_symbol) == sizeof(abi::GetApiFunction));
      abi::GetApiFunction get_api = nullptr;
      std::memcpy(&get_api, &get_api_symbol, sizeof(get_api));
      api_ = get_api();
      if (!HasRequiredApi(api_)) {
        SetError(error, "rime.dll exposes an incompatible RimeApi prefix");
        StopLocked();
        return false;
      }

      abi::Traits traits;
      abi::InitializeVersionedStruct(&traits);
      traits.shared_data_dir = shared_data_dir_.c_str();
      traits.user_data_dir = user_data_dir_.c_str();
      traits.distribution_name = "RIMES";
      traits.distribution_code_name = "rimes";
      traits.distribution_version = "0.1.0";
      traits.app_name = "rime.rimes.windows";
      traits.modules = nullptr;
      traits.min_log_level = 1;
      traits.log_dir = log_dir_.empty() ? nullptr : log_dir_.c_str();
      traits.prebuilt_data_dir = nullptr;
      traits.staging_dir = nullptr;

      api_->setup(&traits);
      api_->initialize(&traits);
      initialized_ = true;

      if (!RunMaintenanceLocked(options.full_maintenance_check, error)) {
        StopLocked();
        return false;
      }

      const abi::SessionId smoke = api_->create_session();
      if (smoke == 0) {
        SetError(error, "librime smoke session creation failed");
        StopLocked();
        return false;
      }
      if (api_->destroy_session(smoke) == 0) {
        SetError(error, "librime smoke session destruction failed");
        StopLocked();
        return false;
      }
      healthy_ = true;
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
      std::lock_guard<std::mutex> lock(mutex_);
      StopLocked();
    } catch (...) {
      // Destruction cannot surface an exception across the broker boundary.
    }
  }

  bool IsHealthy() const noexcept {
    try {
      std::lock_guard<std::mutex> lock(mutex_);
      return healthy_ && api_ != nullptr && module_ != nullptr;
    } catch (...) {
      return false;
    }
  }

  bool RunMaintenance(bool full_check, std::string* error) noexcept {
    try {
      std::lock_guard<std::mutex> lock(mutex_);
      if (!healthy_) {
        SetError(error, "librime is not initialized");
        return false;
      }
      if (!sessions_.empty()) {
        SetError(error,
                 "librime maintenance requires all input sessions to close");
        return false;
      }
      return RunMaintenanceLocked(full_check, error);
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
      const abi::SessionId session = api_->create_session();
      if (session == 0) {
        SetError(error, "librime session creation failed");
        return 0;
      }
      try {
        sessions_.insert(session);
      } catch (...) {
        api_->destroy_session(session);
        throw;
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
      if (api_->destroy_session(session) == 0) {
        SetError(error, "librime rejected session destruction");
        return false;
      }
      return true;
    } catch (...) {
      SetError(error, "exception while destroying a librime session");
      return false;
    }
  }

  bool ProcessKey(SessionId session,
                  std::int32_t keycode,
                  std::int32_t modifiers,
                  EngineSnapshot* output,
                  std::string* error) noexcept {
    if (output != nullptr) {
      *output = EngineSnapshot{};
    }
    if (output == nullptr) {
      SetError(error, "engine snapshot output is null");
      return false;
    }

    try {
      std::lock_guard<std::mutex> lock(mutex_);
      if (!healthy_ || api_ == nullptr || session == 0 ||
          !sessions_.contains(session)) {
        SetError(error, "unknown or inactive librime session");
        return false;
      }

      const bool handled = api_->process_key(session, keycode, modifiers) != 0;
      if (!handled) {
        RawSnapshotView raw;
        raw.handled = false;
        return BuildEngineSnapshot(raw, output, error);
      }
      return CollectSnapshotLocked(session, output, error);
    } catch (...) {
      *output = EngineSnapshot{};
      SetError(error, "exception while processing a librime key event");
      return false;
    }
  }

 private:
  struct OwnedCandidate {
    std::string text;
    std::string comment;
    std::string label;
  };

  bool StoreDataPaths(const RimeEngineOptions& options,
                      std::string* error) noexcept {
    try {
      if (options.shared_data_dir.empty() ||
          !options.shared_data_dir.is_absolute() ||
          options.shared_data_dir.native().size() > kMaximumWindowsPath) {
        SetError(error, "shared data directory must be absolute");
        return false;
      }
      if (options.user_data_dir.empty() ||
          !options.user_data_dir.is_absolute() ||
          options.user_data_dir.native().size() > kMaximumWindowsPath) {
        SetError(error, "user data directory must be absolute");
        return false;
      }
      if (!options.log_dir.empty() &&
          (!options.log_dir.is_absolute() ||
           options.log_dir.native().size() > kMaximumWindowsPath)) {
        SetError(error, "log directory must be absolute");
        return false;
      }
      return WideToUtf8(options.shared_data_dir.native(), &shared_data_dir_,
                        error) &&
             WideToUtf8(options.user_data_dir.native(), &user_data_dir_,
                        error) &&
             WideToUtf8(options.log_dir.native(), &log_dir_, error);
    } catch (...) {
      SetError(error, "exception while validating librime data paths");
      return false;
    }
  }

  bool RunMaintenanceLocked(bool full_check, std::string* error) noexcept {
    if (api_ == nullptr || api_->start_maintenance == nullptr ||
        api_->is_maintenance_mode == nullptr ||
        api_->join_maintenance_thread == nullptr) {
      SetError(error, "librime maintenance API is unavailable");
      return false;
    }
    const bool started = api_->start_maintenance(full_check ? 1 : 0) != 0;
    if (started || api_->is_maintenance_mode() != 0) {
      api_->join_maintenance_thread();
    }
    return true;
  }

  bool CollectSnapshotLocked(SessionId session,
                             EngineSnapshot* output,
                             std::string* error) noexcept {
    std::string commit_text;
    abi::Commit commit;
    abi::InitializeVersionedStruct(&commit);
    if (api_->get_commit(session, &commit) != 0) {
      const bool copied = CopyBoundedCString(
          commit.text, core::kMaxCommitTextBytes, &commit_text, error);
      api_->free_commit(&commit);
      if (!copied) {
        return false;
      }
    }

    abi::Context context;
    abi::InitializeVersionedStruct(&context);
    const bool has_context = api_->get_context(session, &context) != 0;

    std::string composition;
    std::string select_keys;
    std::vector<OwnedCandidate> candidates;
    std::size_t caret_utf8 = 0;
    std::size_t selection_start_utf8 = 0;
    std::size_t selection_end_utf8 = 0;
    std::uint32_t page_number = 0;
    std::uint32_t page_size = 0;
    int highlighted_candidate = -1;
    bool copied = true;

    if (has_context) {
      struct ContextGuard {
        abi::ApiPrefix* api;
        abi::Context* context;
        ~ContextGuard() { api->free_context(context); }
      } context_guard{api_, &context};

      if (context.composition.length < 0 ||
          context.composition.cursor_pos < 0 ||
          context.composition.sel_start < 0 ||
          context.composition.sel_end < 0 || context.menu.page_size < 0 ||
          context.menu.page_no < 0 || context.menu.num_candidates < 0 ||
          context.menu.num_candidates >
              static_cast<int>(core::kMaxCandidateCount)) {
        SetError(error, "librime returned negative or oversized context data");
        copied = false;
      }

      if (copied) {
        copied = CopyBoundedCString(context.composition.preedit,
                                    core::kMaxCompositionBytes, &composition,
                                    error);
      }
      if (copied &&
          static_cast<std::size_t>(context.composition.length) >
              composition.size()) {
        SetError(error, "librime composition length exceeds its preedit text");
        copied = false;
      }
      if (copied) {
        caret_utf8 = static_cast<std::size_t>(context.composition.cursor_pos);
        selection_start_utf8 =
            static_cast<std::size_t>(context.composition.sel_start);
        selection_end_utf8 =
            static_cast<std::size_t>(context.composition.sel_end);
      }

      const int count = copied ? context.menu.num_candidates : 0;
      if (copied && count > 0) {
        if (context.menu.candidates == nullptr || context.menu.page_size <= 0 ||
            context.menu.page_size >
                static_cast<int>(core::kMaxCandidateCount) ||
            count > context.menu.page_size) {
          SetError(error, "librime returned inconsistent candidate metadata");
          copied = false;
        } else {
          page_number = static_cast<std::uint32_t>(context.menu.page_no);
          page_size = static_cast<std::uint32_t>(context.menu.page_size);
          highlighted_candidate = context.menu.highlighted_candidate_index;
          candidates.resize(static_cast<std::size_t>(count));
        }
      }

      if (copied && count > 0 && context.menu.select_keys != nullptr) {
        copied = CopyBoundedCString(context.menu.select_keys,
                                    kMaximumSelectKeysBytes, &select_keys,
                                    error);
      }
      const std::vector<std::string_view> scalar_labels =
          copied ? SplitUtf8Scalars(select_keys)
                 : std::vector<std::string_view>{};

      for (int index = 0; copied && index < count; ++index) {
        OwnedCandidate& candidate = candidates[static_cast<std::size_t>(index)];
        copied = CopyBoundedCString(
                     context.menu.candidates[index].text,
                     core::kMaxCandidateTextBytes, &candidate.text, error) &&
                 CopyBoundedCString(
                     context.menu.candidates[index].comment,
                     core::kMaxCandidateCommentBytes, &candidate.comment,
                     error);
        if (!copied) {
          break;
        }

        if (context.select_labels != nullptr &&
            context.select_labels[index] != nullptr) {
          copied = CopyBoundedCString(context.select_labels[index],
                                      core::kMaxCandidateLabelBytes,
                                      &candidate.label, error);
        } else if (static_cast<std::size_t>(index) < scalar_labels.size()) {
          candidate.label.assign(scalar_labels[static_cast<std::size_t>(index)]);
        } else {
          candidate.label = std::to_string(index + 1);
        }
      }
      if (!copied) {
        return false;
      }
    }

    std::vector<RawCandidateView> candidate_views;
    candidate_views.reserve(candidates.size());
    for (const OwnedCandidate& candidate : candidates) {
      candidate_views.push_back(
          {candidate.text, candidate.comment, candidate.label});
    }

    RawSnapshotView raw;
    raw.handled = true;
    raw.has_context = has_context;
    raw.composition = composition;
    raw.commit_text = commit_text;
    raw.caret_utf8 = caret_utf8;
    raw.selection_start_utf8 = selection_start_utf8;
    raw.selection_end_utf8 = selection_end_utf8;
    raw.page_number = page_number;
    raw.page_size = page_size;
    raw.highlighted_candidate = highlighted_candidate;
    raw.candidates = candidate_views;
    return BuildEngineSnapshot(raw, output, error);
  }

  void StopLocked() noexcept {
    healthy_ = false;
    if (api_ != nullptr) {
      for (const SessionId session : sessions_) {
        api_->destroy_session(session);
      }
      sessions_.clear();
      if (initialized_) {
        api_->finalize();
      }
    }
    initialized_ = false;
    api_ = nullptr;
    if (module_ != nullptr) {
      FreeLibrary(module_);
      module_ = nullptr;
    }
    shared_data_dir_.clear();
    user_data_dir_.clear();
    log_dir_.clear();
    if (owns_runtime_) {
      void* expected = this;
      g_runtime_owner.compare_exchange_strong(expected, nullptr);
      owns_runtime_ = false;
    }
  }

  mutable std::mutex mutex_;
  HMODULE module_ = nullptr;
  abi::ApiPrefix* api_ = nullptr;
  bool initialized_ = false;
  bool healthy_ = false;
  bool owns_runtime_ = false;
  std::string shared_data_dir_;
  std::string user_data_dir_;
  std::string log_dir_;
  std::unordered_set<SessionId> sessions_;
};

RimeEngine::RimeEngine() : impl_(std::make_unique<Impl>()) {}

RimeEngine::~RimeEngine() { Stop(); }

bool RimeEngine::Start(const RimeEngineOptions& options,
                       std::string* error) noexcept {
  return impl_->Start(options, error);
}

void RimeEngine::Stop() noexcept { impl_->Stop(); }

bool RimeEngine::IsHealthy() const noexcept { return impl_->IsHealthy(); }

bool RimeEngine::RunMaintenance(bool full_check,
                                std::string* error) noexcept {
  return impl_->RunMaintenance(full_check, error);
}

RimeEngine::SessionId RimeEngine::CreateSession(std::string* error) noexcept {
  return impl_->CreateSession(error);
}

bool RimeEngine::DestroySession(SessionId session,
                                std::string* error) noexcept {
  return impl_->DestroySession(session, error);
}

bool RimeEngine::ProcessKey(SessionId session,
                            std::int32_t keycode,
                            std::int32_t modifiers,
                            EngineSnapshot* output,
                            std::string* error) noexcept {
  return impl_->ProcessKey(session, keycode, modifiers, output, error);
}

}  // namespace rimes::windows::engine
