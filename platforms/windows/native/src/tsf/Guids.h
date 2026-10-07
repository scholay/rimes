#pragma once

#include <Windows.h>

namespace rimes::windows::tsf {

// These identifiers are part of the installed product identity. Do not change
// them after a build has been distributed: registration, upgrades, and user
// language-profile preferences all depend on their stability.
#ifdef RIMES_RECOVERY_TEST_IDENTITY
// Isolated registrar lifecycle targets must never touch the installed product.
inline constexpr CLSID kTextServiceClsid = {0x726f9b64, 0x3421, 0x4b62, {0x8a,0xe9,0x30,0x69,0x59,0x13,0x61,0x01}};
inline constexpr GUID kLanguageProfileGuid = {0x726f9b64, 0x3421, 0x4b62, {0x8a,0xe9,0x30,0x69,0x59,0x13,0x61,0x02}};
#else
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

#endif

inline constexpr LANGID kLanguageId = 0x0804;  // Chinese (Simplified, China)

// Display attribute used to underline the inline preedit. Stable product
// identity; do not regenerate after a build has been distributed.
inline constexpr GUID kInputDisplayAttributeGuid = {
    0x8f2a1c3e,
    0x7b94,
    0x4d21,
    {0x9e, 0x5a, 0x1c, 0x8d, 0x3f, 0x6a, 0x2b, 0x40},
};

#ifdef RIMES_RECOVERY_TEST_IDENTITY
inline constexpr wchar_t kTextServiceClsidString[] = L"{726F9B64-3421-4B62-8AE9-306959136101}";
inline constexpr wchar_t kLanguageProfileGuidString[] = L"{726F9B64-3421-4B62-8AE9-306959136102}";
inline constexpr wchar_t kDisplayName[] = L"RIMES Recovery Test";
#else
inline constexpr wchar_t kTextServiceClsidString[] =
    L"{0B2C570B-9811-45DF-989B-EA306281F6B4}";
inline constexpr wchar_t kLanguageProfileGuidString[] =
    L"{CD791B35-640F-4F1C-A3D3-624099E15ACB}";
inline constexpr wchar_t kDisplayName[] = L"RIMES";
#endif
inline constexpr wchar_t kDllFileName[] = L"RimesTsf.dll";
inline constexpr wchar_t kCandidateWindowClass[] = L"Rimes.CandidateWindow";

}  // namespace rimes::windows::tsf
