#pragma once
#include <functional>
#include <mutex>

#include "runtime.hpp"
namespace rimes::windows::workbench {
// Broker-owned dispatcher. IPC workers only post commands; all settings UI
// work remains on the window thread. Detaching retires the destination before
// its HWND can be reused.
class UiCommands {
 public:
  void Attach(HWND window);
  bool RequestSettings();
  bool RequestExit();
 private:
  std::mutex mutex_;
  HWND window_ = nullptr;
};
void RunWindow(Runtime& runtime, const std::function<void()>& stop,
               const std::function<void()>& deploy,
               UiCommands* commands = nullptr, bool open_settings = false);
}
