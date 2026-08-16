#include "Diagnostics.h"

#include <Windows.h>

#include <algorithm>
#include <array>
#include <cstddef>
#include <iterator>
#include <string_view>

#include <msctf.h>

namespace rimes::windows::tsf {
namespace {

#if defined(RIMES_TSF_DIAGNOSTICS)

std::string_view StageCode(DiagnosticStage stage) noexcept {
  using enum DiagnosticStage;
  switch (stage) {
  case kActivateEntered:
    return "A000\n";
  case kActivateFlagsNone:
    return "A001\n";
  case kActivateFlagSecureMode:
    return "A002\n";
  case kActivateFlagComless:
    return "A003\n";
  case kActivateFlagWow16:
    return "A004\n";
  case kActivateFlagConsole:
    return "A005\n";
  case kActivateFlagsUnknown:
    return "A006\n";
  case kActivateInvalidArgument:
    return "A010\n";
  case kActivateAlreadyActive:
    return "A011\n";
  case kActivateKeystrokeQueryFailed:
    return "A012\n";
  case kActivateAdviseSinkFailed:
    return "A013\n";
  case kActivateAdviseSinkSucceeded:
    return "A014\n";
  case kActivateConnectRequested:
    return "A020\n";
  case kActivateConnectSuppressedSecure:
    return "A021\n";
  case kActivateBrokerClientUnavailable:
    return "A022\n";
  case kActivateSucceeded:
    return "A0FF\n";
  case kDeactivateEntered:
    return "D000\n";
  case kConnectBeginCalled:
    return "C000\n";
  case kConnectStopEventUnavailable:
    return "C001\n";
  case kConnectWorkerThreadStarted:
    return "C002\n";
  case kConnectWorkerThreadStartFailed:
    return "C003\n";
  case kConnectWorkerEntered:
    return "C100\n";
  case kConnectEndpointBuildFailed:
    return "C101\n";
  case kConnectCancelledAfterEndpoint:
    return "C102\n";
  case kConnectPipeDeadlineExpired:
    return "C110\n";
  case kConnectPipeAccessDenied:
    return "C111\n";
  case kConnectPipeOpenFailed:
    return "C112\n";
  case kConnectCancelledWhileOpening:
    return "C113\n";
  case kConnectServerPidQueryFailed:
    return "C120\n";
  case kConnectServerSessionQueryFailed:
    return "C121\n";
  case kConnectServerSessionMismatch:
    return "C122\n";
  case kConnectServerProcessOpenFailed:
    return "C123\n";
  case kConnectServerTokenReadFailed:
    return "C124\n";
  case kConnectServerSidMismatch:
    return "C125\n";
  case kConnectCancelledAfterIdentity:
    return "C126\n";
  case kConnectHelloEncodeFailed:
    return "C130\n";
  case kConnectHelloWriteTimedOut:
    return "C131\n";
  case kConnectHelloReadTimedOut:
    return "C132\n";
  case kConnectHelloExchangeFailed:
    return "C133\n";
  case kConnectHelloEnvelopeInvalid:
    return "C134\n";
  case kConnectHelloDecodeFailed:
    return "C135\n";
  case kConnectHelloIdentityMismatch:
    return "C136\n";
  case kConnectOpenEncodeFailed:
    return "C140\n";
  case kConnectOpenWriteTimedOut:
    return "C141\n";
  case kConnectOpenReadTimedOut:
    return "C142\n";
  case kConnectOpenExchangeFailed:
    return "C143\n";
  case kConnectOpenEnvelopeInvalid:
    return "C144\n";
  case kConnectOpenDecodeFailed:
    return "C145\n";
  case kConnectCancelledBeforePublish:
    return "C150\n";
  case kConnectPublishConflict:
    return "C151\n";
  case kConnectSucceeded:
    return "C1FE\n";
  case kConnectWorkerException:
    return "C1FF\n";
  case kKeyRequestEncodeFailed:
    return "K100\n";
  case kKeyRequestWriteTimedOut:
    return "K101\n";
  case kKeyRequestReadTimedOut:
    return "K102\n";
  case kKeyRequestExchangeFailed:
    return "K103\n";
  case kKeyResponseEnvelopeInvalid:
    return "K104\n";
  case kKeyResponseDecodeFailed:
    return "K105\n";
  case kKeyResponseUnhandled:
    return "K110\n";
  case kKeyResponseHandledCommitEmpty:
    return "K111\n";
  case kKeyResponseHandledCommitOneUtf16:
    return "K112\n";
  case kKeyResponseHandledCommitMultipleUtf16:
    return "K113\n";
  case kKeyResponseHandledCommitNonempty:
    return "K114\n";
  case kCommitDispatchStarted:
    return "E000\n";
  case kCommitDispatchSucceeded:
    return "E001\n";
  case kCommitDispatchFailed:
    return "E002\n";
  case kCommitInvalidArgument:
    return "E100\n";
  case kCommitAllocationFailed:
    return "E101\n";
  case kCommitSyncRequestFailed:
    return "E110\n";
  case kCommitSyncEditSucceeded:
    return "E111\n";
  case kCommitSyncEditLocked:
    return "E112\n";
  case kCommitSyncEditSynchronousDenied:
    return "E113\n";
  case kCommitSyncEditFailed:
    return "E114\n";
  case kCommitAsyncRequestFailed:
    return "E120\n";
  case kCommitAsyncRequestAccepted:
    return "E121\n";
  case kEditSessionEntered:
    return "E200\n";
  case kEditSessionTextEmpty:
    return "E201\n";
  case kEditSessionTextTooLong:
    return "E202\n";
  case kEditSessionInsertQueryFailed:
    return "E210\n";
  case kEditSessionInsertQuerySucceeded:
    return "E211\n";
  case kEditSessionInsertFailed:
    return "E220\n";
  case kEditSessionInsertSucceeded:
    return "E221\n";
  case kEditSessionInsertNoLock:
    return "E222\n";
  case kEditSessionInsertDisconnected:
    return "E223\n";
  case kEditSessionInsertNoSelection:
    return "E224\n";
  case kEditSessionInsertReadOnly:
    return "E225\n";
  case kEditSessionInsertOtherFailure:
    return "E226\n";
  case kEditSessionInsertInvalidArgument:
    return "E227\n";
  case kEditSessionInsertNotImplemented:
    return "E228\n";
  case kEditSessionInsertGenericFailure:
    return "E229\n";
  case kEditSessionInsertUnexpected:
    return "E22A\n";
  case kEditSessionInsertAccessDenied:
    return "E22B\n";
  case kEditSessionInsertRangeMissing:
    return "E230\n";
  case kEditSessionCaretCollapseSucceeded:
    return "E231\n";
  case kEditSessionCaretCollapseFailed:
    return "E232\n";
  case kEditSessionSelectionSucceeded:
    return "E233\n";
  case kEditSessionSelectionFailed:
    return "E234\n";
  }
  return {};
}

void AppendStageCode(std::string_view code) noexcept {
  if (code.empty()) {
    return;
  }

  std::array<wchar_t, MAX_PATH + 1U> path{};
  const DWORD temp_length =
      GetTempPathW(static_cast<DWORD>(path.size()), path.data());
  constexpr wchar_t kFileName[] = L"RimesTsfDiagnostics.log";
  if (temp_length == 0 || temp_length >= path.size() ||
      static_cast<std::size_t>(temp_length) + std::size(kFileName) >
          path.size()) {
    return;
  }
  std::copy(std::begin(kFileName), std::end(kFileName),
            path.begin() + static_cast<std::ptrdiff_t>(temp_length));

  const HANDLE file =
      CreateFileW(path.data(), FILE_APPEND_DATA,
                  FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                  nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_TEMPORARY, nullptr);
  if (file == INVALID_HANDLE_VALUE) {
    return;
  }
  DWORD written = 0;
  WriteFile(file, code.data(), static_cast<DWORD>(code.size()), &written,
            nullptr);
  CloseHandle(file);
}

#endif // defined(RIMES_TSF_DIAGNOSTICS)

} // namespace

void LogDiagnosticStage(DiagnosticStage stage) noexcept {
#if defined(RIMES_TSF_DIAGNOSTICS)
  AppendStageCode(StageCode(stage));
#else
  static_cast<void>(stage);
#endif
}

void LogActivationFlags(std::uint32_t flags) noexcept {
#if defined(RIMES_TSF_DIAGNOSTICS)
  LogDiagnosticStage(DiagnosticStage::kActivateEntered);
  if (flags == 0) {
    LogDiagnosticStage(DiagnosticStage::kActivateFlagsNone);
    return;
  }

  constexpr std::uint32_t kSecureMode =
      static_cast<std::uint32_t>(TF_TMAE_SECUREMODE);
  constexpr std::uint32_t kComless =
      static_cast<std::uint32_t>(TF_TMAE_COMLESS);
  constexpr std::uint32_t kWow16 = static_cast<std::uint32_t>(TF_TMAE_WOW16);
  constexpr std::uint32_t kConsole =
      static_cast<std::uint32_t>(TF_TMAE_CONSOLE);
  constexpr std::uint32_t kKnownFlags =
      kSecureMode | kComless | kWow16 | kConsole;
  if ((flags & kSecureMode) != 0) {
    LogDiagnosticStage(DiagnosticStage::kActivateFlagSecureMode);
  }
  if ((flags & kComless) != 0) {
    LogDiagnosticStage(DiagnosticStage::kActivateFlagComless);
  }
  if ((flags & kWow16) != 0) {
    LogDiagnosticStage(DiagnosticStage::kActivateFlagWow16);
  }
  if ((flags & kConsole) != 0) {
    LogDiagnosticStage(DiagnosticStage::kActivateFlagConsole);
  }
  if ((flags & ~kKnownFlags) != 0) {
    LogDiagnosticStage(DiagnosticStage::kActivateFlagsUnknown);
  }
#else
  static_cast<void>(flags);
#endif
}

} // namespace rimes::windows::tsf
