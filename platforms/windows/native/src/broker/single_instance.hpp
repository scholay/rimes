#pragma once

#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>

#include <string>

namespace rimes::windows::broker {

class SingleInstance {
 public:
  SingleInstance() = default;
  ~SingleInstance();

  SingleInstance(const SingleInstance&) = delete;
  SingleInstance& operator=(const SingleInstance&) = delete;

  bool Acquire(const std::wstring& mutex_name,
               SECURITY_ATTRIBUTES* security,
               std::wstring* error);

  [[nodiscard]] bool acquired() const { return acquired_; }
  [[nodiscard]] bool already_running() const { return already_running_; }

 private:
  HANDLE mutex_ = nullptr;
  bool acquired_ = false;
  bool already_running_ = false;
};

}  // namespace rimes::windows::broker
