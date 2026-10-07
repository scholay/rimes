#include <Windows.h>

#include "ModuleState.h"

BOOL WINAPI DllMain(HINSTANCE instance, DWORD reason, LPVOID) {
  if (reason == DLL_PROCESS_ATTACH) {
    rimes::windows::tsf::module::SetInstance(instance);
#if !defined(_MSC_VER) || defined(_DLL)
    // MSVC's static CRT needs thread attach/detach notifications for its own
    // per-thread state. Keep the optimization only for the original shared
    // CRT / non-MSVC builds.
    DisableThreadLibraryCalls(instance);
#endif
  }
  return TRUE;
}
