#include "ModuleState.h"

#include <atomic>

namespace rimes::windows::tsf::module {
namespace {

std::atomic_ulong g_object_count{0};
std::atomic_ulong g_server_lock_count{0};

void DecrementWithoutUnderflow(std::atomic_ulong* counter) noexcept {
  unsigned long current = counter->load(std::memory_order_acquire);
  while (current != 0 &&
         !counter->compare_exchange_weak(current, current - 1,
                                         std::memory_order_acq_rel,
                                         std::memory_order_acquire)) {
  }
}

}  // namespace

void AddObject() noexcept {
  g_object_count.fetch_add(1, std::memory_order_relaxed);
}

void ReleaseObject() noexcept {
  DecrementWithoutUnderflow(&g_object_count);
}

void AddServerLock() noexcept {
  g_server_lock_count.fetch_add(1, std::memory_order_relaxed);
}

void ReleaseServerLock() noexcept {
  DecrementWithoutUnderflow(&g_server_lock_count);
}

HRESULT CanUnloadNow() noexcept {
  const bool has_objects =
      g_object_count.load(std::memory_order_acquire) != 0;
  const bool has_server_locks =
      g_server_lock_count.load(std::memory_order_acquire) != 0;
  return (!has_objects && !has_server_locks) ? S_OK : S_FALSE;
}

}  // namespace rimes::windows::tsf::module
