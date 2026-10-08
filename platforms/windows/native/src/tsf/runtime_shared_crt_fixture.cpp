#include <mutex>

// Never packaged or installed. Its /MD imports are a negative control for the
// TSF runtime guard, including the mutex operation behind the QQ regression.
extern "C" __declspec(dllexport) void RimesSharedCrtFixture() {
  std::mutex mutex;
  const std::lock_guard lock(mutex);
}
