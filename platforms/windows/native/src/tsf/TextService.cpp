#include "TextService.h"

#include <limits>
#include <new>
#include <string>
#include <utility>

#include <textstor.h>

#include "Diagnostics.h"
#include "ModuleState.h"

namespace rimes::windows::tsf {
namespace {

class CommitEditSession final : public ITfEditSession {
public:
  CommitEditSession(ITfContext *context, std::wstring text)
      : context_(context), text_(std::move(text)) {
    context_->AddRef();
    module::AddObject();
  }

  CommitEditSession(const CommitEditSession &) = delete;
  CommitEditSession &operator=(const CommitEditSession &) = delete;

  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID interface_id,
                                           void **object) override {
    if (object == nullptr) {
      return E_POINTER;
    }
    *object = nullptr;
    if (!InlineIsEqualGUID(interface_id, IID_IUnknown) &&
        !InlineIsEqualGUID(interface_id, IID_ITfEditSession)) {
      return E_NOINTERFACE;
    }
    *object = static_cast<ITfEditSession *>(this);
    AddRef();
    return S_OK;
  }

  ULONG STDMETHODCALLTYPE AddRef() override {
    return reference_count_.fetch_add(1, std::memory_order_relaxed) + 1;
  }

  ULONG STDMETHODCALLTYPE Release() override {
    const ULONG remaining =
        reference_count_.fetch_sub(1, std::memory_order_acq_rel) - 1;
    if (remaining == 0) {
      delete this;
    }
    return remaining;
  }

  HRESULT STDMETHODCALLTYPE DoEditSession(TfEditCookie edit_cookie) override {
    LogDiagnosticStage(DiagnosticStage::kEditSessionEntered);
    if (text_.empty()) {
      LogDiagnosticStage(DiagnosticStage::kEditSessionTextEmpty);
      return S_OK;
    }
    if (text_.size() >
        static_cast<std::size_t>(std::numeric_limits<LONG>::max())) {
      LogDiagnosticStage(DiagnosticStage::kEditSessionTextTooLong);
      return E_INVALIDARG;
    }

    ITfInsertAtSelection *insert_at_selection = nullptr;
    HRESULT result = context_->QueryInterface(
        IID_ITfInsertAtSelection,
        reinterpret_cast<void **>(&insert_at_selection));
    if (FAILED(result)) {
      LogDiagnosticStage(DiagnosticStage::kEditSessionInsertQueryFailed);
      return result;
    }
    LogDiagnosticStage(DiagnosticStage::kEditSessionInsertQuerySucceeded);

    ITfRange *inserted_range = nullptr;
    result = insert_at_selection->InsertTextAtSelection(
        edit_cookie, 0, text_.data(), static_cast<LONG>(text_.size()),
        &inserted_range);
    insert_at_selection->Release();
    if (FAILED(result)) {
      if (inserted_range != nullptr) {
        inserted_range->Release();
      }
      LogDiagnosticStage(DiagnosticStage::kEditSessionInsertFailed);
      if (result == TF_E_NOLOCK) {
        LogDiagnosticStage(DiagnosticStage::kEditSessionInsertNoLock);
      } else if (result == TF_E_DISCONNECTED) {
        LogDiagnosticStage(DiagnosticStage::kEditSessionInsertDisconnected);
      } else if (result == TS_E_NOSELECTION) {
        LogDiagnosticStage(DiagnosticStage::kEditSessionInsertNoSelection);
      } else if (result == TS_E_READONLY) {
        LogDiagnosticStage(DiagnosticStage::kEditSessionInsertReadOnly);
      } else if (result == E_INVALIDARG) {
        LogDiagnosticStage(DiagnosticStage::kEditSessionInsertInvalidArgument);
      } else if (result == E_NOTIMPL) {
        LogDiagnosticStage(DiagnosticStage::kEditSessionInsertNotImplemented);
      } else if (result == E_FAIL) {
        LogDiagnosticStage(DiagnosticStage::kEditSessionInsertGenericFailure);
      } else if (result == E_UNEXPECTED) {
        LogDiagnosticStage(DiagnosticStage::kEditSessionInsertUnexpected);
      } else if (result == E_ACCESSDENIED) {
        LogDiagnosticStage(DiagnosticStage::kEditSessionInsertAccessDenied);
      } else {
        LogDiagnosticStage(DiagnosticStage::kEditSessionInsertOtherFailure);
      }
      return result;
    }

    LogDiagnosticStage(DiagnosticStage::kEditSessionInsertSucceeded);
    if (inserted_range == nullptr) {
      // The host has already accepted the text.  Treat a missing optional
      // range as a caret-positioning limitation instead of retrying the
      // insertion and duplicating the committed text.
      LogDiagnosticStage(DiagnosticStage::kEditSessionInsertRangeMissing);
      return S_OK;
    }

    const HRESULT collapse_result =
        inserted_range->Collapse(edit_cookie, TF_ANCHOR_END);
    LogDiagnosticStage(SUCCEEDED(collapse_result)
                           ? DiagnosticStage::kEditSessionCaretCollapseSucceeded
                           : DiagnosticStage::kEditSessionCaretCollapseFailed);
    if (SUCCEEDED(collapse_result)) {
      TF_SELECTION selection{};
      selection.range = inserted_range;
      selection.style.ase = TF_AE_NONE;
      selection.style.fInterimChar = FALSE;
      const HRESULT selection_result =
          context_->SetSelection(edit_cookie, 1, &selection);
      LogDiagnosticStage(SUCCEEDED(selection_result)
                             ? DiagnosticStage::kEditSessionSelectionSucceeded
                             : DiagnosticStage::kEditSessionSelectionFailed);
    }
    inserted_range->Release();

    // Insertion succeeded even if this host refuses the best-effort caret
    // update.  Returning a failure here could schedule a duplicate commit.
    return S_OK;
  }

private:
  ~CommitEditSession() {
    context_->Release();
    module::ReleaseObject();
  }

  std::atomic_ulong reference_count_{1};
  ITfContext *context_;
  std::wstring text_;
};

} // namespace

TextService::TextService() noexcept : broker_client_(CreateBrokerClient()) {
  module::AddObject();
}

TextService::~TextService() {
  Deactivate();
  module::ReleaseObject();
}

HRESULT STDMETHODCALLTYPE TextService::QueryInterface(REFIID interface_id,
                                                      void **object) {
  if (object == nullptr) {
    return E_POINTER;
  }
  *object = nullptr;

  if (InlineIsEqualGUID(interface_id, IID_IUnknown) ||
      InlineIsEqualGUID(interface_id, kTextInputProcessorExIid)) {
    *object = static_cast<ITfTextInputProcessorEx *>(this);
  } else if (InlineIsEqualGUID(interface_id, IID_ITfTextInputProcessor)) {
    *object = static_cast<ITfTextInputProcessor *>(this);
  } else if (InlineIsEqualGUID(interface_id, IID_ITfKeyEventSink)) {
    *object = static_cast<ITfKeyEventSink *>(this);
  } else {
    return E_NOINTERFACE;
  }

  AddRef();
  return S_OK;
}

ULONG STDMETHODCALLTYPE TextService::AddRef() {
  return reference_count_.fetch_add(1, std::memory_order_relaxed) + 1;
}

ULONG STDMETHODCALLTYPE TextService::Release() {
  const ULONG remaining =
      reference_count_.fetch_sub(1, std::memory_order_acq_rel) - 1;
  if (remaining == 0) {
    delete this;
  }
  return remaining;
}

HRESULT STDMETHODCALLTYPE TextService::Activate(ITfThreadMgr *thread_manager,
                                                TfClientId client_id) {
  return ActivateEx(thread_manager, client_id, 0);
}

HRESULT STDMETHODCALLTYPE TextService::ActivateEx(ITfThreadMgr *thread_manager,
                                                  TfClientId client_id,
                                                  DWORD flags) {
  LogActivationFlags(flags);
  if (thread_manager == nullptr || client_id == kNullClientId) {
    LogDiagnosticStage(DiagnosticStage::kActivateInvalidArgument);
    return E_INVALIDARG;
  }
  if (thread_manager_ != nullptr || keystroke_manager_ != nullptr) {
    LogDiagnosticStage(DiagnosticStage::kActivateAlreadyActive);
    return TF_E_ALREADY_EXISTS;
  }

  ITfKeystrokeMgr *keystroke_manager = nullptr;
  HRESULT result = thread_manager->QueryInterface(
      IID_ITfKeystrokeMgr, reinterpret_cast<void **>(&keystroke_manager));
  if (FAILED(result)) {
    LogDiagnosticStage(DiagnosticStage::kActivateKeystrokeQueryFailed);
    return result;
  }

  result = keystroke_manager->AdviseKeyEventSink(
      client_id, static_cast<ITfKeyEventSink *>(this), TRUE);
  if (FAILED(result)) {
    LogDiagnosticStage(DiagnosticStage::kActivateAdviseSinkFailed);
    keystroke_manager->Release();
    return result;
  }
  LogDiagnosticStage(DiagnosticStage::kActivateAdviseSinkSucceeded);

  thread_manager->AddRef();
  thread_manager_ = thread_manager;
  keystroke_manager_ = keystroke_manager;
  client_id_ = client_id;
  activation_flags_ = flags;
  key_event_sink_advised_ = true;

  // Pipe discovery, server authentication, ClientHello, and session opening
  // all happen on the client's bounded worker and never delay app activation.
  // Secure-mode TSF hosts must never forward their keystrokes out of process.
  if (broker_client_ != nullptr && (flags & TF_TMAE_SECUREMODE) == 0) {
    LogDiagnosticStage(DiagnosticStage::kActivateConnectRequested);
    broker_client_->BeginConnect();
  } else if ((flags & TF_TMAE_SECUREMODE) != 0) {
    LogDiagnosticStage(DiagnosticStage::kActivateConnectSuppressedSecure);
  } else {
    LogDiagnosticStage(DiagnosticStage::kActivateBrokerClientUnavailable);
  }

  LogDiagnosticStage(DiagnosticStage::kActivateSucceeded);
  return S_OK;
}

HRESULT STDMETHODCALLTYPE TextService::Deactivate() {
  LogDiagnosticStage(DiagnosticStage::kDeactivateEntered);
  if (broker_client_ != nullptr) {
    broker_client_->Disconnect();
  }

  ITfKeystrokeMgr *keystroke_manager =
      std::exchange(keystroke_manager_, nullptr);
  ITfThreadMgr *thread_manager = std::exchange(thread_manager_, nullptr);
  const TfClientId client_id = std::exchange(client_id_, kNullClientId);
  const bool was_advised = std::exchange(key_event_sink_advised_, false);
  activation_flags_ = 0;

  HRESULT result = S_OK;
  if (keystroke_manager != nullptr) {
    if (was_advised) {
      result = keystroke_manager->UnadviseKeyEventSink(client_id);
    }
    keystroke_manager->Release();
  }
  if (thread_manager != nullptr) {
    thread_manager->Release();
  }
  return result;
}

HRESULT STDMETHODCALLTYPE TextService::OnSetFocus(BOOL) { return S_OK; }

HRESULT STDMETHODCALLTYPE TextService::OnTestKeyDown(ITfContext *context,
                                                     WPARAM virtual_key,
                                                     LPARAM key_data,
                                                     BOOL *eaten) {
  return HandleKey(BrokerKeyPhase::kTestKeyDown, context, virtual_key, key_data,
                   eaten);
}

HRESULT STDMETHODCALLTYPE TextService::OnKeyDown(ITfContext *context,
                                                 WPARAM virtual_key,
                                                 LPARAM key_data, BOOL *eaten) {
  return HandleKey(BrokerKeyPhase::kKeyDown, context, virtual_key, key_data,
                   eaten);
}

HRESULT STDMETHODCALLTYPE TextService::OnTestKeyUp(ITfContext *context,
                                                   WPARAM virtual_key,
                                                   LPARAM key_data,
                                                   BOOL *eaten) {
  return HandleKey(BrokerKeyPhase::kTestKeyUp, context, virtual_key, key_data,
                   eaten);
}

HRESULT STDMETHODCALLTYPE TextService::OnKeyUp(ITfContext *context,
                                               WPARAM virtual_key,
                                               LPARAM key_data, BOOL *eaten) {
  return HandleKey(BrokerKeyPhase::kKeyUp, context, virtual_key, key_data,
                   eaten);
}

HRESULT STDMETHODCALLTYPE TextService::OnPreservedKey(ITfContext *, REFGUID,
                                                      BOOL *eaten) {
  return HandleKey(BrokerKeyPhase::kPreservedKey, nullptr, 0, 0, eaten);
}

HRESULT TextService::HandleKey(BrokerKeyPhase phase, ITfContext *context,
                               WPARAM virtual_key, LPARAM key_data,
                               BOOL *eaten) noexcept {
  if (eaten == nullptr) {
    return E_POINTER;
  }

  *eaten = FALSE;
  if (broker_client_ == nullptr ||
      (activation_flags_ & TF_TMAE_SECUREMODE) != 0) {
    return S_OK;
  }

  BrokerInputState state;
  const bool is_real_event =
      phase == BrokerKeyPhase::kKeyDown || phase == BrokerKeyPhase::kKeyUp;
  const BrokerKeyResult result = broker_client_->HandleKey(
      {phase, virtual_key, key_data}, is_real_event ? &state : nullptr);
  if (result == BrokerKeyResult::kConsumed) {
    // The Broker has already advanced the authoritative librime session.  Eat
    // the key even if the host refuses an edit lock; passing it through would
    // duplicate raw input while leaving the engine one event ahead.
    *eaten = TRUE;
    if (context != nullptr && !state.commit_text.empty()) {
      LogDiagnosticStage(DiagnosticStage::kCommitDispatchStarted);
      const HRESULT commit_result = CommitText(context, state.commit_text);
      LogDiagnosticStage(SUCCEEDED(commit_result)
                             ? DiagnosticStage::kCommitDispatchSucceeded
                             : DiagnosticStage::kCommitDispatchFailed);
    }
  }
  return S_OK;
}

HRESULT TextService::CommitText(ITfContext *context,
                                const std::wstring &text) noexcept {
  if (context == nullptr || text.empty() || client_id_ == kNullClientId) {
    LogDiagnosticStage(DiagnosticStage::kCommitInvalidArgument);
    return E_INVALIDARG;
  }

  CommitEditSession *edit_session = nullptr;
  try {
    edit_session = new (std::nothrow) CommitEditSession(context, text);
  } catch (...) {
    LogDiagnosticStage(DiagnosticStage::kCommitAllocationFailed);
    return E_OUTOFMEMORY;
  }
  if (edit_session == nullptr) {
    LogDiagnosticStage(DiagnosticStage::kCommitAllocationFailed);
    return E_OUTOFMEMORY;
  }

  HRESULT edit_result = E_FAIL;
  HRESULT request_result = context->RequestEditSession(
      client_id_, edit_session, TF_ES_SYNC | TF_ES_READWRITE, &edit_result);
  if (FAILED(request_result)) {
    LogDiagnosticStage(DiagnosticStage::kCommitSyncRequestFailed);
  } else if (SUCCEEDED(edit_result)) {
    LogDiagnosticStage(DiagnosticStage::kCommitSyncEditSucceeded);
  } else if (edit_result == TF_E_LOCKED) {
    LogDiagnosticStage(DiagnosticStage::kCommitSyncEditLocked);
  } else if (edit_result == TF_E_SYNCHRONOUS) {
    LogDiagnosticStage(DiagnosticStage::kCommitSyncEditSynchronousDenied);
  } else {
    LogDiagnosticStage(DiagnosticStage::kCommitSyncEditFailed);
  }
  if (FAILED(request_result) || edit_result == TF_E_SYNCHRONOUS ||
      edit_result == TF_E_LOCKED) {
    // Some hosts do not grant a synchronous lock from their keystroke path.
    // An asynchronous retry keeps the COM object and context alive until TSF
    // invokes DoEditSession.
    request_result = context->RequestEditSession(
        client_id_, edit_session, TF_ES_ASYNC | TF_ES_READWRITE, &edit_result);
    LogDiagnosticStage(FAILED(request_result)
                           ? DiagnosticStage::kCommitAsyncRequestFailed
                           : DiagnosticStage::kCommitAsyncRequestAccepted);
  }
  edit_session->Release();
  return FAILED(request_result) ? request_result : edit_result;
}

} // namespace rimes::windows::tsf
