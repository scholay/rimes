#pragma once

#include <cstdint>

namespace rimes::windows::tsf {

// Privacy-preserving TSF diagnostics.  The implementation accepts only these
// fixed stage identifiers, so callers cannot accidentally write key data,
// text, SIDs, paths, HRESULTs, or other process data to the diagnostic file.
// When RIMES_TSF_DIAGNOSTICS is disabled (the default), both functions are
// no-ops and no file is created.
enum class DiagnosticStage : std::uint8_t {
  // ActivateEx and Deactivate.
  kActivateEntered,                 // A000
  kActivateFlagsNone,               // A001
  kActivateFlagSecureMode,          // A002
  kActivateFlagComless,             // A003
  kActivateFlagWow16,               // A004
  kActivateFlagConsole,             // A005
  kActivateFlagsUnknown,            // A006
  kActivateInvalidArgument,         // A010
  kActivateAlreadyActive,           // A011
  kActivateKeystrokeQueryFailed,    // A012
  kActivateAdviseSinkFailed,        // A013
  kActivateAdviseSinkSucceeded,     // A014
  kActivateConnectRequested,        // A020
  kActivateConnectSuppressedSecure, // A021
  kActivateBrokerClientUnavailable, // A022
  kActivateSucceeded,               // A0FF
  kDeactivateEntered,               // D000

  // BeginConnect and its background worker.
  kConnectBeginCalled,              // C000
  kConnectStopEventUnavailable,     // C001
  kConnectWorkerThreadStarted,      // C002
  kConnectWorkerThreadStartFailed,  // C003
  kConnectWorkerEntered,            // C100
  kConnectEndpointBuildFailed,      // C101
  kConnectCancelledAfterEndpoint,   // C102
  kConnectPipeDeadlineExpired,      // C110
  kConnectPipeAccessDenied,         // C111
  kConnectPipeOpenFailed,           // C112
  kConnectCancelledWhileOpening,    // C113
  kConnectServerPidQueryFailed,     // C120
  kConnectServerSessionQueryFailed, // C121
  kConnectServerSessionMismatch,    // C122
  kConnectServerProcessOpenFailed,  // C123
  kConnectServerTokenReadFailed,    // C124
  kConnectServerSidMismatch,        // C125
  kConnectCancelledAfterIdentity,   // C126
  kConnectHelloEncodeFailed,        // C130
  kConnectHelloWriteTimedOut,       // C131
  kConnectHelloReadTimedOut,        // C132
  kConnectHelloExchangeFailed,      // C133
  kConnectHelloEnvelopeInvalid,     // C134
  kConnectHelloDecodeFailed,        // C135
  kConnectHelloIdentityMismatch,    // C136
  kConnectOpenEncodeFailed,         // C140
  kConnectOpenWriteTimedOut,        // C141
  kConnectOpenReadTimedOut,         // C142
  kConnectOpenExchangeFailed,       // C143
  kConnectOpenEnvelopeInvalid,      // C144
  kConnectOpenDecodeFailed,         // C145
  kConnectCancelledBeforePublish,   // C150
  kConnectPublishConflict,          // C151
  kConnectSucceeded,                // C1FE
  kConnectWorkerException,          // C1FF

  // Real key events only.  No code identifies the key or its content.
  kKeyRequestEncodeFailed,                // K100
  kKeyRequestWriteTimedOut,               // K101
  kKeyRequestReadTimedOut,                // K102
  kKeyRequestExchangeFailed,              // K103
  kKeyResponseEnvelopeInvalid,            // K104
  kKeyResponseDecodeFailed,               // K105
  kKeyResponseUnhandled,                  // K110
  kKeyResponseHandledCommitEmpty,         // K111
  kKeyResponseHandledCommitOneUtf16,      // K112
  kKeyResponseHandledCommitMultipleUtf16, // K113
  kKeyResponseHandledCommitNonempty,      // K114

  // TSF edit-session and insertion outcomes.  HRESULTs are deliberately
  // reduced to fixed outcome classes rather than written as raw values.
  kCommitDispatchStarted,             // E000
  kCommitDispatchSucceeded,           // E001
  kCommitDispatchFailed,              // E002
  kCommitInvalidArgument,             // E100
  kCommitAllocationFailed,            // E101
  kCommitSyncRequestFailed,           // E110
  kCommitSyncEditSucceeded,           // E111
  kCommitSyncEditLocked,              // E112
  kCommitSyncEditSynchronousDenied,   // E113
  kCommitSyncEditFailed,              // E114
  kCommitAsyncRequestFailed,          // E120
  kCommitAsyncRequestAccepted,        // E121
  kEditSessionEntered,                // E200
  kEditSessionTextEmpty,              // E201
  kEditSessionTextTooLong,            // E202
  kEditSessionInsertQueryFailed,      // E210
  kEditSessionInsertQuerySucceeded,   // E211
  kEditSessionInsertFailed,           // E220
  kEditSessionInsertSucceeded,        // E221
  kEditSessionInsertNoLock,           // E222
  kEditSessionInsertDisconnected,     // E223
  kEditSessionInsertNoSelection,      // E224
  kEditSessionInsertReadOnly,         // E225
  kEditSessionInsertOtherFailure,     // E226
  kEditSessionInsertInvalidArgument,  // E227
  kEditSessionInsertNotImplemented,   // E228
  kEditSessionInsertGenericFailure,   // E229
  kEditSessionInsertUnexpected,       // E22A
  kEditSessionInsertAccessDenied,     // E22B
  kEditSessionInsertRangeMissing,     // E230
  kEditSessionCaretCollapseSucceeded, // E231
  kEditSessionCaretCollapseFailed,    // E232
  kEditSessionSelectionSucceeded,     // E233
  kEditSessionSelectionFailed,        // E234
};

#if defined(RIMES_TSF_DIAGNOSTICS)
void LogDiagnosticStage(DiagnosticStage stage) noexcept;
void LogActivationFlags(std::uint32_t flags) noexcept;
#else
inline void LogDiagnosticStage(DiagnosticStage) noexcept {}
inline void LogActivationFlags(std::uint32_t) noexcept {}
#endif

} // namespace rimes::windows::tsf
