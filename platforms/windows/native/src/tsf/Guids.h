#pragma once

#include <Windows.h>

namespace rimes::windows::tsf {

// These identifiers are part of the installed product identity. Do not change
// them after a build has been distributed: registration, upgrades, and user
// language-profile preferences all depend on their stability.
inline constexpr CLSID kTextServiceClsid = {
    0x0b2c570b,
    0x9811,
    0x45df,
    {0x98, 0x9b, 0xea, 0x30, 0x62, 0x81, 0xf6, 0xb4},
};

inline constexpr GUID kLanguageProfileGuid = {
    0xcd791b35,
    0x640f,
    0x4f1c,
    {0xa3, 0xd3, 0x62, 0x40, 0x99, 0xe1, 0x5a, 0xcb},
};

inline constexpr LANGID kLanguageId = 0x0804;  // Chinese (Simplified, China)

inline constexpr wchar_t kTextServiceClsidString[] =
    L"{0B2C570B-9811-45DF-989B-EA306281F6B4}";
inline constexpr wchar_t kLanguageProfileGuidString[] =
    L"{CD791B35-640F-4F1C-A3D3-624099E15ACB}";
inline constexpr wchar_t kDisplayName[] = L"RIMES";
inline constexpr wchar_t kDllFileName[] = L"RimesTsf.dll";

}  // namespace rimes::windows::tsf
