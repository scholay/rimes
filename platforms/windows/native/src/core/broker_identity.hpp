#pragma once

namespace rimes::windows::core {

// This identity is selected at compile time, never by a user-controlled
// environment variable. Only the isolated E2E targets use the test endpoint;
// production TSF and Broker retain their established names and access checks.
#if defined(RIMES_E2E_TEST_IDENTITY)
inline constexpr wchar_t kBrokerObjectName[] = L"RIMES.E2E.Broker";
inline constexpr wchar_t kBrokerExecutable[] = L"RimesE2EBroker.exe";
inline constexpr bool kAllowBrokerAutoLaunch = false;
#else
inline constexpr wchar_t kBrokerObjectName[] = L"RIMES.Broker";
inline constexpr wchar_t kBrokerExecutable[] = L"RimesBroker.exe";
inline constexpr bool kAllowBrokerAutoLaunch = true;
#endif

}  // namespace rimes::windows::core
