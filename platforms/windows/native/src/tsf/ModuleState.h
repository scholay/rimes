#pragma once

#include <Windows.h>

namespace rimes::windows::tsf::module {

void AddObject() noexcept;
void ReleaseObject() noexcept;
void AddServerLock() noexcept;
void ReleaseServerLock() noexcept;
HRESULT CanUnloadNow() noexcept;

}  // namespace rimes::windows::tsf::module
