#include "TextService.h"

#include <initguid.h>
#include <inputscope.h>
#include <textstor.h>

#include <algorithm>
#include <cstdint>
#include <functional>
#include <limits>
#include <new>
#include <string>
#include <utility>

#include "Diagnostics.h"
#include "DisplayAttribute.h"
#include "Guids.h"
#include "ModuleState.h"
#include "candidate_layout.hpp"
#include "../ui/theme.hpp"

namespace rimes::windows::tsf {
namespace {

constexpr UINT kRefreshFocusedContext = WM_APP + 74;

// Called with a granted edit cookie; never inspect or forward protected text.
bool AllowedContext(ITfContext* context,
                    TfEditCookie cookie = TF_INVALID_EDIT_COOKIE) {
  TF_STATUS status{};
  if (SUCCEEDED(context->GetStatus(&status)) &&
      (status.dwStaticFlags & TS_SD_READONLY))
    return false;
  ITfCompartmentMgr* compartments = nullptr;
  if (SUCCEEDED(context->QueryInterface(
          IID_ITfCompartmentMgr, reinterpret_cast<void**>(&compartments)))) {
    bool disabled = false;
    for (const auto& guid :
         {GUID_COMPARTMENT_KEYBOARD_DISABLED, GUID_COMPARTMENT_EMPTYCONTEXT}) {
      ITfCompartment* compartment = nullptr;
      if (SUCCEEDED(compartments->GetCompartment(guid, &compartment)) &&
          compartment) {
        VARIANT value{};
        VariantInit(&value);
        if (SUCCEEDED(compartment->GetValue(&value)) && value.vt == VT_I4 &&
            value.lVal)
          disabled = true;
        VariantClear(&value);
        compartment->Release();
      }
    }
    compartments->Release();
    if (disabled) return false;
  }
  ITfContextView* view = nullptr;
  if (SUCCEEDED(context->GetActiveView(&view)) && view) {
    HWND window = nullptr;
    view->GetWnd(&window);
    view->Release();
    if (window) {
      wchar_t name[32]{};
      GetClassNameW(window, name, 32);
      if ((_wcsicmp(name, L"Edit") == 0 ||
           _wcsnicmp(name, L"RichEdit", 8) == 0) &&
          (GetWindowLongPtrW(window, GWL_STYLE) & ES_PASSWORD))
        return false;
    }
  }
  if (cookie == TF_INVALID_EDIT_COOKIE) return true;
  TF_SELECTION selection{};
  ULONG fetched = 0;
  if (FAILED(context->GetSelection(cookie, TF_DEFAULT_SELECTION, 1, &selection,
                                   &fetched)) ||
      !selection.range)
    return false;
  ITfReadOnlyProperty* property = nullptr;
  bool allowed = true;
  if (SUCCEEDED(context->GetAppProperty(GUID_PROP_INPUTSCOPE, &property)) &&
      property) {
    VARIANT value{};
    VariantInit(&value);
    if (SUCCEEDED(property->GetValue(cookie, selection.range, &value)) &&
        value.vt == VT_UNKNOWN && value.punkVal) {
      ITfInputScope* scope = nullptr;
      if (SUCCEEDED(value.punkVal->QueryInterface(
              IID_ITfInputScope, reinterpret_cast<void**>(&scope)))) {
        InputScope* values = nullptr;
        UINT count = 0;
        if (SUCCEEDED(scope->GetInputScopes(&values, &count))) {
          for (UINT i = 0; i < count; ++i)
            if (values[i] == IS_PASSWORD || values[i] == IS_PRIVATE ||
                (static_cast<int>(values[i]) >= 63 &&
                 static_cast<int>(values[i]) <= 66))
              allowed = false;
          CoTaskMemFree(values);
        }
        scope->Release();
      }
    }
    VariantClear(&value);
    property->Release();
  }
  selection.range->Release();
  return allowed;
}

class ScopeRead final : public ITfEditSession {
 public:
  explicit ScopeRead(ITfContext* context) : context_(context) {
    context_->AddRef();
    module::AddObject();
  }
  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID id, void** out) override {
    if (!out) return E_POINTER;
    *out = nullptr;
    if (id != IID_IUnknown && id != IID_ITfEditSession) return E_NOINTERFACE;
    *out = static_cast<ITfEditSession*>(this);
    AddRef();
    return S_OK;
  }
  ULONG STDMETHODCALLTYPE AddRef() override { return ++refs_; }
  ULONG STDMETHODCALLTYPE Release() override {
    const auto n = --refs_;
    if (!n) delete this;
    return n;
  }
  HRESULT STDMETHODCALLTYPE DoEditSession(TfEditCookie cookie) override {
    allowed = AllowedContext(context_, cookie);
    TF_SELECTION selection{};
    ULONG count = 0;
    ITfContextView* view = nullptr;
    if (SUCCEEDED(context_->GetSelection(cookie, TF_DEFAULT_SELECTION, 1,
                                         &selection, &count)) &&
        selection.range) {
      if (SUCCEEDED(context_->GetActiveView(&view)) && view) {
        BOOL clipped = FALSE;
        RECT text_caret{};
        if (SUCCEEDED(view->GetTextExt(cookie, selection.range, &text_caret,
                                       &clipped))) {
          caret = text_caret;
        }
        view->Release();
      }
      selection.range->Release();
    }
    return S_OK;
  }
  bool allowed = false;
  RECT caret{};

 private:
  ~ScopeRead() {
    context_->Release();
    module::ReleaseObject();
  }
  std::atomic_ulong refs_{1};
  ITfContext* context_;
};

class CommitEditSession final : public ITfEditSession {
 public:
  CommitEditSession(ITfContext* context, std::wstring text,
                    std::shared_ptr<std::atomic_bool> valid,
                    std::function<void(bool)> completion = {},
                    IUnknown* owner = nullptr,
                    std::function<bool(TfEditCookie)> validate = {})
      : context_(context),
        text_(std::move(text)),
        valid_(std::move(valid)),
        completion_(std::move(completion)),
        owner_(owner),
        validate_(std::move(validate)) {
    if (owner_) owner_->AddRef();
    context_->AddRef();
    module::AddObject();
  }

  CommitEditSession(const CommitEditSession&) = delete;
  CommitEditSession& operator=(const CommitEditSession&) = delete;

  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID interface_id,
                                           void** object) override {
    if (object == nullptr) {
      return E_POINTER;
    }
    *object = nullptr;
    if (!InlineIsEqualGUID(interface_id, IID_IUnknown) &&
        !InlineIsEqualGUID(interface_id, IID_ITfEditSession)) {
      return E_NOINTERFACE;
    }
    *object = static_cast<ITfEditSession*>(this);
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
    struct Completion {
      CommitEditSession* self;
      ~Completion() { self->Notify(); }
    } completion{this};
    if (!valid_ || !valid_->load() || !AllowedContext(context_, edit_cookie) ||
        (validate_ && !validate_(edit_cookie)))
      return TF_E_DISCONNECTED;
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

    ITfInsertAtSelection* insert_at_selection = nullptr;
    HRESULT result = context_->QueryInterface(
        IID_ITfInsertAtSelection,
        reinterpret_cast<void**>(&insert_at_selection));
    if (FAILED(result)) {
      LogDiagnosticStage(DiagnosticStage::kEditSessionInsertQueryFailed);
      return result;
    }
    LogDiagnosticStage(DiagnosticStage::kEditSessionInsertQuerySucceeded);

    ITfRange* inserted_range = nullptr;
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

    accepted_ = true;
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
  void Notify() {
    if (completion_) {
      auto callback = std::move(completion_);
      callback(accepted_);
    }
  }
  ~CommitEditSession() {
    Notify();
    if (owner_) owner_->Release();
    context_->Release();
    module::ReleaseObject();
  }

  std::atomic_ulong reference_count_{1};
  ITfContext* context_;
  std::wstring text_;
  std::shared_ptr<std::atomic_bool> valid_;
  std::function<void(bool)> completion_;
  IUnknown* owner_ = nullptr;
  bool accepted_ = false;
  std::function<bool(TfEditCookie)> validate_;
};

class CompositionEditSession final : public ITfEditSession {
 public:
  enum class Action {
    kUpdate,
    kEnd,
    kApply,
  };

  CompositionEditSession(ITfContext* context, ITfCompositionSink* sink,
                         ITfComposition** composition_slot, Action action,
                         std::wstring text, std::uint32_t caret_utf16,
                         std::shared_ptr<std::atomic_bool> valid,
                         std::wstring committed = {})
      : context_(context),
        sink_(sink),
        composition_slot_(composition_slot),
        action_(action),
        text_(std::move(text)),
        caret_utf16_(caret_utf16),
        valid_(std::move(valid)),
        committed_(std::move(committed)) {
    context_->AddRef();
    sink_->AddRef();
    module::AddObject();
  }

  CompositionEditSession(const CompositionEditSession&) = delete;
  CompositionEditSession& operator=(const CompositionEditSession&) = delete;

  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID interface_id,
                                           void** object) override {
    if (object == nullptr) {
      return E_POINTER;
    }
    *object = nullptr;
    if (!InlineIsEqualGUID(interface_id, IID_IUnknown) &&
        !InlineIsEqualGUID(interface_id, IID_ITfEditSession)) {
      return E_NOINTERFACE;
    }
    *object = static_cast<ITfEditSession*>(this);
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
    if (!valid_ || !valid_->load()) return TF_E_DISCONNECTED;
    if (!AllowedContext(context_, edit_cookie)) return TS_E_READONLY;
    if (action_ == Action::kEnd) return EndLocked(edit_cookie);
    if (action_ == Action::kApply) {
      if (!committed_.empty()) {
        HRESULT hr = S_OK;
        if (*composition_slot_) {
          const auto preedit = std::move(text_);
          const auto caret = caret_utf16_;
          text_ = committed_;
          caret_utf16_ = static_cast<std::uint32_t>(text_.size());
          hr = UpdateLocked(edit_cookie);
          text_ = preedit;
          caret_utf16_ = caret;
          if (SUCCEEDED(hr)) hr = EndLocked(edit_cookie);
        } else {
          auto* insert = new (std::nothrow)
              CommitEditSession(context_, committed_, valid_);
          if (!insert) return E_OUTOFMEMORY;
          hr = insert->DoEditSession(edit_cookie);
          insert->Release();
        }
        if (FAILED(hr)) return hr;
      }
      if (text_.empty()) {
        if (*composition_slot_) {
          auto hr = UpdateLocked(edit_cookie);
          if (FAILED(hr)) return hr;
        }
        return EndLocked(edit_cookie);
      }
    }
    return UpdateLocked(edit_cookie);
  }

 private:
  ~CompositionEditSession() {
    context_->Release();
    sink_->Release();
    module::ReleaseObject();
  }

  HRESULT StartLocked(TfEditCookie edit_cookie) {
    if (composition_slot_ == nullptr || *composition_slot_ != nullptr) {
      return S_OK;
    }
    ITfInsertAtSelection* insert = nullptr;
    HRESULT result = context_->QueryInterface(
        IID_ITfInsertAtSelection, reinterpret_cast<void**>(&insert));
    if (FAILED(result) || insert == nullptr) {
      return result;
    }
    ITfRange* range = nullptr;
    result = insert->InsertTextAtSelection(edit_cookie, TF_IAS_QUERYONLY,
                                           nullptr, 0, &range);
    insert->Release();
    if (FAILED(result) || range == nullptr) {
      if (range != nullptr) {
        range->Release();
      }
      return result;
    }

    ITfContextComposition* context_composition = nullptr;
    result = context_->QueryInterface(
        IID_ITfContextComposition,
        reinterpret_cast<void**>(&context_composition));
    if (FAILED(result) || context_composition == nullptr) {
      range->Release();
      return result;
    }
    result = context_composition->StartComposition(edit_cookie, range, sink_,
                                                   composition_slot_);
    context_composition->Release();
    range->Release();
    return result;
  }

  HRESULT UpdateLocked(TfEditCookie edit_cookie) {
    HRESULT result = S_OK;
    if (composition_slot_ == nullptr) {
      return E_INVALIDARG;
    }
    if (*composition_slot_ == nullptr) {
      result = StartLocked(edit_cookie);
      if (FAILED(result) || *composition_slot_ == nullptr) {
        return result;
      }
    }

    ITfRange* range = nullptr;
    result = (*composition_slot_)->GetRange(&range);
    if (FAILED(result) || range == nullptr) {
      if (range != nullptr) {
        range->Release();
      }
      return result;
    }
    if (text_.size() >
        static_cast<std::size_t>(std::numeric_limits<LONG>::max())) {
      range->Release();
      return E_INVALIDARG;
    }
    result = range->SetText(edit_cookie, 0, text_.c_str(),
                            static_cast<LONG>(text_.size()));
    if (SUCCEEDED(result)) {
      ApplyCompositionDisplayAttribute(edit_cookie, context_, range);
      ITfRange* caret_range = nullptr;
      if (SUCCEEDED(range->Clone(&caret_range)) && caret_range != nullptr) {
        ITfRangeACP* acp = nullptr;
        if (SUCCEEDED(caret_range->QueryInterface(
                IID_ITfRangeACP, reinterpret_cast<void**>(&acp))) &&
            acp != nullptr) {
          LONG start = 0;
          LONG ignored = 0;
          if (SUCCEEDED(acp->GetExtent(&start, &ignored))) {
            const LONG caret =
                start + static_cast<LONG>(
                            (std::min)(caret_utf16_, static_cast<std::uint32_t>(
                                                         text_.size())));
            acp->SetExtent(caret, 0);
          }
          acp->Release();
        } else {
          caret_range->Collapse(edit_cookie, TF_ANCHOR_END);
        }
        TF_SELECTION selection{};
        selection.range = caret_range;
        selection.style.ase = TF_AE_NONE;
        selection.style.fInterimChar = FALSE;
        context_->SetSelection(edit_cookie, 1, &selection);
        caret_range->Release();
      }
    }
    range->Release();
    return result;
  }

  HRESULT EndLocked(TfEditCookie edit_cookie) {
    if (composition_slot_ == nullptr || *composition_slot_ == nullptr) {
      return S_OK;
    }
    ITfComposition* composition = *composition_slot_;
    *composition_slot_ = nullptr;
    const HRESULT result = composition->EndComposition(edit_cookie);
    composition->Release();
    return result;
  }

  std::atomic_ulong reference_count_{1};
  ITfContext* context_;
  ITfCompositionSink* sink_;
  ITfComposition** composition_slot_;
  Action action_;
  std::wstring text_;
  std::uint32_t caret_utf16_ = 0;
  std::shared_ptr<std::atomic_bool> valid_;
  std::wstring committed_;
};

class CancelCompositionEdit final : public ITfEditSession {
 public:
  explicit CancelCompositionEdit(ITfComposition* composition)
      : composition_(composition) {
    composition_->AddRef();
    module::AddObject();
  }
  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID id, void** out) override {
    if (!out) return E_POINTER;
    *out = nullptr;
    if (id != IID_IUnknown && id != IID_ITfEditSession) return E_NOINTERFACE;
    *out = static_cast<ITfEditSession*>(this);
    AddRef();
    return S_OK;
  }
  ULONG STDMETHODCALLTYPE AddRef() override { return ++references_; }
  ULONG STDMETHODCALLTYPE Release() override {
    auto n = --references_;
    if (!n) delete this;
    return n;
  }
  HRESULT STDMETHODCALLTYPE DoEditSession(TfEditCookie cookie) override {
    ITfRange* range = nullptr;
    if (SUCCEEDED(composition_->GetRange(&range)) && range) {
      range->SetText(cookie, 0, L"", 0);
      range->Release();
    }
    return composition_->EndComposition(cookie);
  }

 private:
  ~CancelCompositionEdit() {
    composition_->Release();
    module::ReleaseObject();
  }
  std::atomic_ulong references_{1};
  ITfComposition* composition_;
};

// Mouse callbacks are outside TSF's keystroke path: hosts may refuse a
// synchronous lock. Keep the service/context alive until the requested edit
// actually runs, and validate the captured candidate inside that edit.
class CandidateSelectionEdit final : public ITfEditSession {
 public:
  CandidateSelectionEdit(ITfContext* context, IUnknown* owner,
                          std::function<HRESULT(TfEditCookie)> callback)
      : context_(context), owner_(owner), callback_(std::move(callback)) {
    context_->AddRef();
    owner_->AddRef();
    module::AddObject();
  }
  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID id, void** out) override {
    if (!out) return E_POINTER;
    *out = nullptr;
    if (id != IID_IUnknown && id != IID_ITfEditSession) return E_NOINTERFACE;
    *out = static_cast<ITfEditSession*>(this);
    AddRef();
    return S_OK;
  }
  ULONG STDMETHODCALLTYPE AddRef() override { return ++references_; }
  ULONG STDMETHODCALLTYPE Release() override {
    const auto n = --references_;
    if (!n) delete this;
    return n;
  }
  HRESULT STDMETHODCALLTYPE DoEditSession(TfEditCookie cookie) override {
    // A host must not execute the same click twice.
    auto callback = std::move(callback_);
    if (!callback) return S_OK;
    try { return callback(cookie); } catch (...) { return E_FAIL; }
  }

 private:
  ~CandidateSelectionEdit() {
    context_->Release();
    owner_->Release();
    module::ReleaseObject();
  }
  std::atomic_ulong references_{1};
  ITfContext* context_;
  IUnknown* owner_;
  std::function<HRESULT(TfEditCookie)> callback_;
};

HRESULT RequestEdit(ITfContext* context, TfClientId client_id,
                    ITfEditSession* session) {
  if (context == nullptr || session == nullptr || client_id == kNullClientId) {
    return E_INVALIDARG;
  }
  HRESULT edit_result = E_FAIL;
  HRESULT request_result = context->RequestEditSession(
      client_id, session, TF_ES_SYNC | TF_ES_READWRITE, &edit_result);
  if (FAILED(request_result) || edit_result == TF_E_SYNCHRONOUS ||
      edit_result == TF_E_LOCKED) {
    request_result = context->RequestEditSession(
        client_id, session, TF_ES_ASYNC | TF_ES_READWRITE, &edit_result);
  }
  return FAILED(request_result) ? request_result : edit_result;
}

}  // namespace

TextService::TextService() noexcept : TextService(CreateBrokerClient()) {}
TextService::TextService(std::unique_ptr<BrokerClient> broker_client) noexcept
    : broker_client_(std::move(broker_client)) {
  module::AddObject();
  candidate_window_.SetSelect([this](std::size_t index) { SelectCandidate(index); });
}

void TextService::SelectCandidate(std::size_t index) noexcept {
  if (!active_context_ || !broker_client_) return;
  const auto selection = candidate_navigation_.AtVisibleIndex(index);
  if (!selection) return;
  auto* context = active_context_;
  const auto valid = edit_valid_;
  const auto revision = last_state_.revision;
  const auto epoch = candidate_epoch_;
  try {
    auto* edit = new (std::nothrow) CandidateSelectionEdit(
        context, static_cast<ITfTextInputProcessorEx*>(this),
        [this, context, valid, revision, epoch, selection](TfEditCookie cookie) {
          RefreshBrokerConnection();
          if (!valid || !valid->load() || context != active_context_ ||
              last_state_.revision != revision ||
              candidate_epoch_ != epoch ||
              !IsFocusedContext() || !AllowedContext(context, cookie))
            return TF_E_DISCONNECTED;
          const auto applied = CommitCandidate(context, *selection, cookie);
          if (FAILED(applied)) {
            candidate_navigation_.Reset(last_state_);
            ++candidate_epoch_;
            UpdateCandidateWindow(context, last_state_, cookie);
          }
          return applied;
        });
    if (!edit) return;
    RequestEdit(context, client_id_, edit);
    edit->Release();
  } catch (...) {}
}

std::optional<BrokerInputState> TextService::StepCandidatePage(int delta) noexcept {
  try {
    if (!broker_client_->Control({{"op", "candidate_guard"},
          {"revision", last_state_.revision}, {"index", 0}})) return std::nullopt;
    const WPARAM key = delta < 0 ? VK_PRIOR : VK_NEXT;
    BrokerInputState state, released;
    const auto result = broker_client_->HandleKey(
        {BrokerKeyPhase::kKeyDown, key, 1}, &state);
    const auto release = broker_client_->HandleKey(
        {BrokerKeyPhase::kKeyUp, key, static_cast<LPARAM>(1ULL << 31)}, &released);
    if (result == BrokerKeyResult::kUnavailable || release == BrokerKeyResult::kUnavailable)
      return std::nullopt;
    if (released.has_snapshot) state = std::move(released);
    if (!state.has_snapshot) return last_state_;
    if (!state.commit_text.empty() || state.composition != last_state_.composition ||
        state.candidates.empty() || !state.candidates_visible) {
      // A custom schema can bind PageUp/Down to a non-navigation action. Apply
      // its authoritative result and retire the preview instead of replaying it.
      ApplyDocumentState(active_context_, state);
      return std::nullopt;
    }
    last_state_ = state;
    return state;
  } catch (...) { return std::nullopt; }
}

HRESULT TextService::CommitCandidate(ITfContext* context,
    CandidateNavigation::Selection selection, TfEditCookie cookie) noexcept {
  try {
    // A clicked matrix row is at most two pages from the active row.
    for (int i = 0; i < 3 && CandidateNavigation::PageId(last_state_) != selection.page_id; ++i) {
      const auto before = CandidateNavigation::PageId(last_state_);
      const auto state = StepCandidatePage(selection.page_id < before ? -1 : 1);
      if (!state || CandidateNavigation::PageId(*state) == before) return E_FAIL;
    }
    if (CandidateNavigation::PageId(last_state_) != selection.page_id ||
        selection.index >= last_state_.candidates.size()) return E_FAIL;
    const auto key = CandidateSelectionKey(
        last_state_.candidates[selection.index].label, selection.index);
    if (!key || !broker_client_->Control({{"op", "candidate_guard"},
        {"revision", last_state_.revision}, {"index", selection.index}}))
      return TF_E_DISCONNECTED;
    BrokerInputState state, released;
    const auto result = broker_client_->HandleKey(
        {BrokerKeyPhase::kKeyDown, static_cast<WPARAM>(key), 1}, &state);
    const auto release = broker_client_->HandleKey(
        {BrokerKeyPhase::kKeyUp, static_cast<WPARAM>(key),
         static_cast<LPARAM>(1ULL << 31)}, &released);
    if (result != BrokerKeyResult::kConsumed) return E_FAIL;
    auto applied = state.has_snapshot ? ApplyDocumentState(context, state, cookie) : S_OK;
    if (SUCCEEDED(applied) && release == BrokerKeyResult::kConsumed && released.has_snapshot)
      applied = ApplyDocumentState(context, released, cookie);
    return applied;
  } catch (...) { return E_FAIL; }
}

bool TextService::HandleCandidateKey(BrokerKeyPhase phase, ITfContext* context,
                                     WPARAM key) noexcept {
  if (phase != BrokerKeyPhase::kTestKeyDown && phase != BrokerKeyPhase::kKeyDown)
    return false;
  if (candidate_navigation_.empty() ||
      (!candidate_ui_ && !candidate_window_.snapshot().visible))
    return false;
  for (int modifier : {VK_SHIFT, VK_CONTROL, VK_MENU, VK_LWIN, VK_RWIN})
    if (GetKeyState(modifier) & 0x8000) return false;
  const bool arrow = key == VK_LEFT || key == VK_RIGHT || key == VK_UP || key == VK_DOWN;
  const bool digit = candidate_navigation_.expanded() && key >= '1' && key <= '9';
  const bool collapse = candidate_navigation_.expanded() && key == VK_ESCAPE;
  const bool page = candidate_navigation_.expanded() && (key == VK_PRIOR || key == VK_NEXT || key == VK_OEM_MINUS || key == VK_OEM_PLUS);
  if (!arrow && !digit && !collapse && !page && key != VK_SPACE) return false;
  if (phase == BrokerKeyPhase::kTestKeyDown) return true;
  candidate_owned_keys_.set(static_cast<std::size_t>(key));
  ++candidate_epoch_;
  try {
    if (key == VK_LEFT || key == VK_RIGHT) {
      candidate_navigation_.MoveColumn(key == VK_LEFT ? -1 : 1);
    } else if (key == VK_UP || key == VK_DOWN || page) {
      if (!candidate_navigation_.MoveRow(key == VK_UP || key == VK_PRIOR || key == VK_OEM_MINUS ? -1 : 1,
          [this](int delta) { return StepCandidatePage(delta); }))
        candidate_navigation_.Reset(last_state_);
    } else if (collapse) {
      if (!candidate_navigation_.CollapseToAnchor([this](int delta) { return StepCandidatePage(delta); }))
        candidate_navigation_.Reset(last_state_);
    } else {
      auto selection = candidate_navigation_.Selected(
          digit ? std::optional<std::size_t>(key - '1') : std::nullopt);
      if (digit && candidate_window_.IsVisible()) {
        const auto index = candidate_window_.MatrixDigitIndex(key - '1');
        selection = index ? candidate_navigation_.AtVisibleIndex(*index) : std::nullopt;
      }
      if (selection && FAILED(CommitCandidate(context, *selection)))
        candidate_navigation_.Reset(last_state_);
    }
    UpdateCandidateWindow(context, last_state_);
  } catch (...) {
    candidate_navigation_.Reset({});
    EndCandidateUI();
  }
  return true;
}

TextService::~TextService() {
  Deactivate();
  module::ReleaseObject();
}

HRESULT STDMETHODCALLTYPE TextService::QueryInterface(REFIID interface_id,
                                                      void** object) {
  if (object == nullptr) {
    return E_POINTER;
  }
  *object = nullptr;

  if (InlineIsEqualGUID(interface_id, IID_IUnknown) ||
      InlineIsEqualGUID(interface_id, kTextInputProcessorExIid)) {
    *object = static_cast<ITfTextInputProcessorEx*>(this);
  } else if (InlineIsEqualGUID(interface_id, IID_ITfTextInputProcessor)) {
    *object = static_cast<ITfTextInputProcessor*>(this);
  } else if (InlineIsEqualGUID(interface_id, IID_ITfKeyEventSink)) {
    *object = static_cast<ITfKeyEventSink*>(this);
  } else if (InlineIsEqualGUID(interface_id, IID_ITfCompositionSink)) {
    *object = static_cast<ITfCompositionSink*>(this);
  } else if (InlineIsEqualGUID(interface_id, IID_ITfDisplayAttributeProvider)) {
    *object = static_cast<ITfDisplayAttributeProvider*>(this);
  } else if (InlineIsEqualGUID(interface_id, IID_ITfThreadMgrEventSink)) {
    *object = static_cast<ITfThreadMgrEventSink*>(this);
  } else if (InlineIsEqualGUID(interface_id, IID_ITfTextEditSink)) {
    *object = static_cast<ITfTextEditSink*>(this);
  } else if (InlineIsEqualGUID(interface_id, IID_ITfTextLayoutSink)) {
    *object = static_cast<ITfTextLayoutSink*>(this);
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

HRESULT STDMETHODCALLTYPE TextService::Activate(ITfThreadMgr* thread_manager,
                                                TfClientId client_id) {
  return ActivateEx(thread_manager, client_id, 0);
}

HRESULT STDMETHODCALLTYPE TextService::ActivateEx(ITfThreadMgr* thread_manager,
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

  ITfKeystrokeMgr* keystroke_manager = nullptr;
  HRESULT result = thread_manager->QueryInterface(
      IID_ITfKeystrokeMgr, reinterpret_cast<void**>(&keystroke_manager));
  if (FAILED(result)) {
    LogDiagnosticStage(DiagnosticStage::kActivateKeystrokeQueryFailed);
    return result;
  }

  result = keystroke_manager->AdviseKeyEventSink(
      client_id, static_cast<ITfKeyEventSink*>(this), TRUE);
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
  thread_manager_->QueryInterface(IID_ITfUIElementMgr,
                                  reinterpret_cast<void**>(&ui_manager_));
  key_event_sink_advised_ = true;
  ITfSource* source = nullptr;
  if (SUCCEEDED(thread_manager_->QueryInterface(
          IID_ITfSource, reinterpret_cast<void**>(&source)))) {
    source->AdviseSink(IID_ITfThreadMgrEventSink,
                       static_cast<ITfThreadMgrEventSink*>(this),
                       &thread_sink_cookie_);
    source->Release();
  }

  WNDCLASSW notification_class{};
  notification_class.lpfnWndProc = NotificationProcedure;
  notification_class.hInstance = module::Instance();
  notification_class.lpszClassName = L"Rimes.Tsf.Notification";
  RegisterClassW(&notification_class);
  notification_window_ = CreateWindowExW(
      0, notification_class.lpszClassName, L"", 0, 0, 0, 0, 0, HWND_MESSAGE,
      nullptr, notification_class.hInstance, this);
  if (broker_client_)
    broker_client_->SetNotificationWindow(notification_window_);

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
  RevokeContext();
  if (ui_manager_) std::exchange(ui_manager_, nullptr)->Release();
  if (thread_manager_ && thread_sink_cookie_ != TF_INVALID_COOKIE) {
    ITfSource* source = nullptr;
    if (SUCCEEDED(thread_manager_->QueryInterface(
            IID_ITfSource, reinterpret_cast<void**>(&source)))) {
      source->UnadviseSink(thread_sink_cookie_);
      source->Release();
    }
    thread_sink_cookie_ = TF_INVALID_COOKIE;
  }
  candidate_window_.Hide();
  if (composition_ != nullptr) {
    ending_composition_ = true;
    composition_->Release();
    composition_ = nullptr;
    ending_composition_ = false;
  }
  if (broker_client_ != nullptr) {
    broker_client_->SetNotificationWindow(nullptr);
    broker_client_->Disconnect();
  }
  if (notification_window_) {
    DestroyWindow(notification_window_);
    notification_window_ = nullptr;
  }

  ITfKeystrokeMgr* keystroke_manager =
      std::exchange(keystroke_manager_, nullptr);
  ITfThreadMgr* thread_manager = std::exchange(thread_manager_, nullptr);
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

HRESULT STDMETHODCALLTYPE TextService::OnSetFocus(BOOL foreground) {
  if (foreground == FALSE)
    RevokeContext();
  else
    OnPushContext(nullptr);
  return S_OK;
}

HRESULT STDMETHODCALLTYPE TextService::OnCompositionTerminated(
    TfEditCookie cookie, ITfComposition* composition) {
  if (composition && composition_ == composition) {
    // The host can terminate a composition before its focus notification.
    // Use the granted write cookie while the old range is still editable;
    // releasing the composition alone would leave raw preedit in the field.
    auto* terminated = std::exchange(composition_, nullptr);
    ITfRange* range = nullptr;
    if (SUCCEEDED(terminated->GetRange(&range)) && range) {
      range->SetText(cookie, 0, L"", 0);
      range->Release();
    }
    terminated->Release();
    RevokeContext();
  }
  if (!ending_composition_) {
    EndCandidateUI();
  }
  return S_OK;
}

HRESULT STDMETHODCALLTYPE TextService::EnumDisplayAttributeInfo(
    IEnumTfDisplayAttributeInfo** enumerator) {
  return CreateEnumDisplayAttributeInfo(enumerator);
}

HRESULT STDMETHODCALLTYPE TextService::GetDisplayAttributeInfo(
    REFGUID guid, ITfDisplayAttributeInfo** info) {
  if (!InlineIsEqualGUID(guid, kInputDisplayAttributeGuid)) {
    if (info != nullptr) {
      *info = nullptr;
    }
    return E_INVALIDARG;
  }
  return CreateDisplayAttributeInfo(info);
}

bool TextService::IsBrokerConnected() const noexcept {
  return broker_client_ != nullptr && broker_client_->IsConnected();
}

HRESULT STDMETHODCALLTYPE TextService::OnTestKeyDown(ITfContext* context,
                                                     WPARAM virtual_key,
                                                     LPARAM key_data,
                                                     BOOL* eaten) {
  return HandleKey(BrokerKeyPhase::kTestKeyDown, context, virtual_key, key_data,
                   eaten);
}

HRESULT STDMETHODCALLTYPE TextService::OnKeyDown(ITfContext* context,
                                                 WPARAM virtual_key,
                                                 LPARAM key_data, BOOL* eaten) {
  return HandleKey(BrokerKeyPhase::kKeyDown, context, virtual_key, key_data,
                   eaten);
}

HRESULT STDMETHODCALLTYPE TextService::OnTestKeyUp(ITfContext* context,
                                                   WPARAM virtual_key,
                                                   LPARAM key_data,
                                                   BOOL* eaten) {
  return HandleKey(BrokerKeyPhase::kTestKeyUp, context, virtual_key, key_data,
                   eaten);
}

HRESULT STDMETHODCALLTYPE TextService::OnKeyUp(ITfContext* context,
                                               WPARAM virtual_key,
                                               LPARAM key_data, BOOL* eaten) {
  return HandleKey(BrokerKeyPhase::kKeyUp, context, virtual_key, key_data,
                   eaten);
}

HRESULT STDMETHODCALLTYPE TextService::OnPreservedKey(ITfContext*, REFGUID,
                                                      BOOL* eaten) {
  return HandleKey(BrokerKeyPhase::kPreservedKey, nullptr, 0, 0, eaten);
}

HRESULT TextService::HandleKey(BrokerKeyPhase phase, ITfContext* context,
                               WPARAM virtual_key, LPARAM key_data,
                               BOOL* eaten) noexcept {
  if (eaten == nullptr) {
    return E_POINTER;
  }

  *eaten = FALSE;
  if (broker_client_ == nullptr ||
      (activation_flags_ & TF_TMAE_SECUREMODE) != 0) {
    return S_OK;
  }

  const bool test_up = phase == BrokerKeyPhase::kTestKeyUp;
  const bool up = phase == BrokerKeyPhase::kKeyUp;
  if (virtual_key < candidate_owned_keys_.size() && (test_up || up) &&
      candidate_owned_keys_.test(static_cast<std::size_t>(virtual_key))) {
    *eaten = TRUE;
    if (up) candidate_owned_keys_.reset(static_cast<std::size_t>(virtual_key));
    return S_OK;
  }
  const bool repeat =
      (static_cast<std::uint64_t>(key_data) & (1ULL << 30)) != 0;
  if (virtual_key != 0 && virtual_key == buffer_owned_key_ && (test_up || up || repeat)) {
    *eaten = TRUE;
    if (up) {
      buffer_owned_key_ = 0;
      if (context == active_context_) {
        BrokerInputState ignored;
        broker_client_->HandleKey({phase, virtual_key, key_data}, &ignored);
      }
    }
    return S_OK;
  }
  RefreshBrokerConnection();
  if (!context || !BindContext(context)) return S_OK;
  // Read-only locks never enqueue keystrokes or expose sensitive text to IPC.
  auto* scope = new (std::nothrow) ScopeRead(context);
  if (!scope) return S_OK;
  HRESULT scope_result = E_FAIL;
  const auto read = context->RequestEditSession(
      client_id_, scope, TF_ES_SYNC | TF_ES_READ, &scope_result);
  const bool allowed =
      SUCCEEDED(read) && SUCCEEDED(scope_result) && scope->allowed;
  scope->Release();
  if (!allowed) {
    RevokeContext();
    return S_OK;
  }
  if (!broker_client_->SetContext(context_generation_)) return S_OK;
  if (HandleCandidateKey(phase, context, virtual_key)) {
    *eaten = TRUE;
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
    if ((virtual_key == VK_RETURN || broker_client_->IsBufferSendKey(virtual_key)) &&
        phase == BrokerKeyPhase::kKeyDown &&
        broker_client_->Capturing())
      buffer_owned_key_ = virtual_key;
  }
  // A Shift modifier can commit existing code while remaining a host key.
  // Snapshot application and keyboard ownership are independent.
  if (result != BrokerKeyResult::kUnavailable && context != nullptr &&
      is_real_event && state.has_snapshot)
    ApplyDocumentState(context, state);
  return S_OK;
}

HRESULT TextService::ApplyDocumentState(
    ITfContext* context, const BrokerInputState& state, TfEditCookie cookie) noexcept {
  if (context == nullptr) {
    return E_INVALIDARG;
  }
  SetCapture(state.buffer_capture);
  candidate_navigation_.Reset(state);
  ++candidate_epoch_;
  if (state.buffer_capture) {
    last_state_ = state;
    UpdateCandidateWindow(context, state, cookie);
    return S_OK;
  }
  // A modifier-only snapshot (for example an idle Shift ASCII toggle) changes
  // engine state, not document text. Requesting a write lock here can fail in
  // a dialog host and revoke the context, resetting the just-toggled session.
  // Existing compositions and actual commits must still use an edit session.
  if (!composition_ && !state.composing && state.commit_text.empty()) {
    last_state_ = state;
    UpdateCandidateWindow(context, state, cookie);
    return S_OK;
  }
  auto* session = new (std::nothrow) CompositionEditSession(
      context, this, &composition_, CompositionEditSession::Action::kApply,
      state.composing ? state.composition : std::wstring(), state.caret_utf16,
      edit_valid_, state.commit_text);
  if (!session) return E_OUTOFMEMORY;
  const auto result = cookie == TF_INVALID_EDIT_COOKIE
                          ? RequestEdit(context, client_id_, session)
                          : session->DoEditSession(cookie);
  session->Release();
  if (FAILED(result)) {
    RevokeContext();
    return result;
  }

  last_state_ = state;
  UpdateCandidateWindow(context, state, cookie);
  return S_OK;
}

HRESULT TextService::UpdateComposition(ITfContext* context,
                                       const BrokerInputState& state) noexcept {
  CompositionEditSession* session = new (std::nothrow) CompositionEditSession(
      context, this, &composition_,
      state.commit_text.empty() ? CompositionEditSession::Action::kUpdate
                                : CompositionEditSession::Action::kUpdate,
      state.commit_text.empty() ? state.composition : state.commit_text,
      state.commit_text.empty()
          ? state.caret_utf16
          : static_cast<std::uint32_t>(state.commit_text.size()),
      edit_valid_);
  if (session == nullptr) {
    return E_OUTOFMEMORY;
  }
  const HRESULT result = RequestEdit(context, client_id_, session);
  session->Release();
  if (!state.commit_text.empty() && !state.composing) {
    EndComposition(context);
  } else if (!state.commit_text.empty() && state.composing &&
             !state.composition.empty()) {
    CompositionEditSession* next = new (std::nothrow) CompositionEditSession(
        context, this, &composition_, CompositionEditSession::Action::kUpdate,
        state.composition, state.caret_utf16, edit_valid_);
    if (next != nullptr) {
      RequestEdit(context, client_id_, next);
      next->Release();
    }
  }
  return result;
}

HRESULT TextService::EndComposition(ITfContext* context) noexcept {
  ending_composition_ = true;
  CompositionEditSession* session = new (std::nothrow) CompositionEditSession(
      context, this, &composition_, CompositionEditSession::Action::kEnd,
      std::wstring(), 0, edit_valid_);
  HRESULT result = S_OK;
  if (session != nullptr) {
    result = RequestEdit(context, client_id_, session);
    session->Release();
  } else if (composition_ != nullptr) {
    composition_->Release();
    composition_ = nullptr;
    result = E_OUTOFMEMORY;
  }
  ending_composition_ = false;
  return result;
}

void TextService::EndCandidateUI() noexcept {
  auto* element = std::exchange(candidate_ui_, nullptr);
  const auto id = std::exchange(candidate_ui_id_, TF_INVALID_UIELEMENTID);
  if (element) {
    auto* manager = ui_manager_;
    if (manager) manager->AddRef();
    element->Detach();
    if (manager && id != TF_INVALID_UIELEMENTID) manager->EndUIElement(id);
    if (manager) manager->Release();
    element->Release();
  }
  candidate_window_.Hide();
}

bool TextService::IsFocusedContext() const noexcept {
  BOOL focused = FALSE;
  if (!thread_manager_ || FAILED(thread_manager_->IsThreadFocus(&focused)) || !focused)
    return false;
  ITfDocumentMgr* document = nullptr;
  ITfContext* context = nullptr;
  IUnknown* identity = nullptr;
  if (SUCCEEDED(thread_manager_->GetFocus(&document)) && document &&
      SUCCEEDED(document->GetTop(&context)) && context)
    context->QueryInterface(IID_IUnknown, reinterpret_cast<void**>(&identity));
  const bool same = identity && identity == context_identity_;
  if (identity) identity->Release();
  if (context) context->Release();
  if (document) document->Release();
  return same;
}

HRESULT TextService::CandidateUIAction(CandidateUIElement::Action action, UINT index) {
  if (!active_context_ || !candidate_ui_ || !edit_valid_ || !edit_valid_->load())
    return TF_E_DISCONNECTED;
  if (!IsFocusedContext()) return TF_E_DISCONNECTED;
  if (action == CandidateUIElement::Action::kAbort) {
    RevokeContext();
    return S_OK;
  }
  if (action == CandidateUIElement::Action::kFinalize) {
    SelectCandidate(index);
    return S_OK;
  }
  // The UI-less list exposes the same flattened rows as our own panel.
  // Moving across preview rows also advances the authoritative engine page.
  if (!candidate_navigation_.AtVisibleIndex(index)) return E_INVALIDARG;
  if (!candidate_navigation_.SelectVisibleIndex(index,
          [this](int delta) { return StepCandidatePage(delta); })) {
    candidate_navigation_.Reset(last_state_);
    ++candidate_epoch_;
    if (active_context_) UpdateCandidateWindow(active_context_, last_state_);
    return E_FAIL;
  }
  ++candidate_epoch_;
  UpdateCandidateWindow(active_context_, last_state_);
  return S_OK;
}

void TextService::PublishCandidateUI(ITfContext* context,
                                     const CandidateSnapshot& snapshot) {
  if (!ui_manager_) {
    // Never draw an unnegotiated panel in a host that requested UI-less mode.
    if ((activation_flags_ & TF_TMAE_UIELEMENTENABLEDONLY) == 0)
      candidate_window_.Update(snapshot);
    return;
  }
  if (candidate_ui_) {
    auto* element = candidate_ui_;
    auto* manager = ui_manager_;
    const auto id = candidate_ui_id_;
    element->AddRef();
    manager->AddRef();
    try {
      element->Update(snapshot);
      if (candidate_ui_ == element && id != TF_INVALID_UIELEMENTID)
        manager->UpdateUIElement(id);
    } catch (...) {
      if (candidate_ui_ == element) EndCandidateUI();
    }
    manager->Release();
    element->Release();
    return;
  }
  ITfDocumentMgr* document = nullptr;
  if (FAILED(context->GetDocumentMgr(&document)) || !document) return;
  CandidateUIElement* element = nullptr;
  try {
    element = new CandidateUIElement(document, &candidate_window_,
        [this](CandidateUIElement::Action action, UINT index) {
          return CandidateUIAction(action, index);
        });
  } catch (...) { document->Release(); throw; }
  document->Release();
  candidate_ui_ = element;
  element->AddRef(); // Begin/Update may synchronously revoke the context.
  auto* manager = ui_manager_;
  manager->AddRef();
  try {
    element->Update(snapshot);
    element->InitialFlags();
    BOOL show = TRUE;
    DWORD id = TF_INVALID_UIELEMENTID;
    const auto result = manager->BeginUIElement(element, &show, &id);
    if (SUCCEEDED(result) && id != TF_INVALID_UIELEMENTID) {
      if (candidate_ui_ == element) {
        candidate_ui_id_ = id;
        element->Show(show);
        if (candidate_ui_ == element) manager->UpdateUIElement(id);
      } else manager->EndUIElement(id);
    } else if (candidate_ui_ == element) EndCandidateUI();
  } catch (...) {
    if (candidate_ui_ == element) EndCandidateUI();
  }
  manager->Release();
  element->Release();
}

void TextService::UpdateCandidateWindow(
    ITfContext* context, const BrokerInputState& state, TfEditCookie cookie) noexcept {
  if (!state.candidates_visible || state.candidates.empty() ||
      (activation_flags_ & TF_TMAE_SECUREMODE) != 0) {
    EndCandidateUI();
    return;
  }
  try {
    CandidateSnapshot snapshot;
    snapshot.visible = true;
    snapshot.highlighted = state.highlighted_candidate;
    snapshot.page_start = state.page_start;
    snapshot.page_size = state.page_size;
    snapshot.composition = state.composition;
    const RECT queried = capture_active_ ? buffer_caret_ : QueryCaretRect(context, cookie);
    // A host mid-composition can refuse every caret source, which yields an
    // all-zero rectangle. That is unknown geometry, not a caret at the screen
    // origin: reusing the previous placement keeps the popup next to the input
    // field, and suppressing it beats showing it at the work-area corner.
    const RECT previous = capture_active_ ? RECT{} : candidate_ui_
        ? candidate_ui_->Snapshot().caret_rect : candidate_window_.snapshot().caret_rect;
    ScreenRect resolved{};
    const bool has_caret = ResolveCandidateCaret({queried.left, queried.top, queried.right,
                                queried.bottom},
                               {previous.left, previous.top, previous.right,
                                previous.bottom},
                               &resolved);
    if (has_caret) snapshot.caret_rect = {resolved.left, resolved.top, resolved.right,
                                         resolved.bottom};
    auto append = [&](const BrokerInputState& page) {
      for (std::size_t index = 0; index < page.candidates.size(); ++index) {
        const auto& candidate = page.candidates[index];
        snapshot.items.push_back({candidate.label.empty() ? std::to_wstring(index + 1)
                                                         : candidate.label,
                                  candidate.text, candidate.comment});
      }
    };
    if (candidate_navigation_.empty()) {
      append(state);
    } else {
      for (auto row = candidate_navigation_.base(); row < candidate_navigation_.end(); ++row) {
        const auto& page = candidate_navigation_.page(row);
        if (row == candidate_navigation_.row())
          snapshot.highlighted = static_cast<std::uint16_t>(
              snapshot.items.size() + candidate_navigation_.column());
        if (candidate_navigation_.expanded())
          snapshot.matrix_rows.push_back(page.candidates.size());
        append(page);
      }
    }
    HWND owner = nullptr;
    ITfContextView* view = nullptr;
    if (SUCCEEDED(context->GetActiveView(&view)) && view) {
      if (FAILED(view->GetWnd(&owner))) owner = nullptr;
      view->Release();
    }
    if (!owner) owner = GetFocus();
    candidate_window_.SetOwner(owner);
    // The host's own UI does not require a Win32 caret rectangle.
    if (ui_manager_) PublishCandidateUI(context, snapshot);
    else if (has_caret) PublishCandidateUI(context, snapshot);
    else candidate_window_.Hide();
  } catch (...) {
    EndCandidateUI();
  }
}

RECT TextService::QueryCaretRect(ITfContext* context, TfEditCookie cookie) noexcept {
  RECT caret{};
  if (context == nullptr) {
    return caret;
  }
  auto* read = new (std::nothrow) ScopeRead(context);
  if (read) {
    HRESULT edit = E_FAIL;
    const auto hr = cookie == TF_INVALID_EDIT_COOKIE
                        ? context->RequestEditSession(
                              client_id_, read, TF_ES_SYNC | TF_ES_READ, &edit)
                        : (edit = read->DoEditSession(cookie));
    if (SUCCEEDED(hr) && SUCCEEDED(edit)) caret = read->caret;
    read->Release();
    if (caret.bottom > caret.top) return caret;
  }
  // A native caret can be a dummy caret, or belong to a different child
  // window than GetWnd. Keep missing TSF geometry unknown so the caller
  // can retain the last verified caret for this context.
  return caret;
}

void TextService::ClearCompositionPointer() noexcept {
  if (composition_ != nullptr) {
    composition_->Release();
    composition_ = nullptr;
  }
}

HRESULT TextService::CommitText(ITfContext* context,
                                const std::wstring& text) noexcept {
  if (context == nullptr || text.empty() || client_id_ == kNullClientId) {
    LogDiagnosticStage(DiagnosticStage::kCommitInvalidArgument);
    return E_INVALIDARG;
  }

  CommitEditSession* edit_session = nullptr;
  try {
    edit_session =
        new (std::nothrow) CommitEditSession(context, text, edit_valid_);
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

bool TextService::BindContext(ITfContext* context) noexcept {
  if ((activation_flags_ & TF_TMAE_SECUREMODE) != 0 ||
      !context || !AllowedContext(context)) {
    RevokeContext();
    return false;
  }
  IUnknown* identity = nullptr;
  if (FAILED(context->QueryInterface(IID_IUnknown,
                                     reinterpret_cast<void**>(&identity))))
    return false;
  if (context_identity_ == identity) {
    identity->Release();
    return true;
  }
  RevokeContext();
  try {
    edit_valid_ = std::make_shared<std::atomic_bool>(true);
  } catch (...) {
    identity->Release();
    return false;
  }
  context_identity_ = identity;
  active_context_ = context;
  context->AddRef();
  ++context_generation_;
  ITfSource* source = nullptr;
  if (SUCCEEDED(context->QueryInterface(IID_ITfSource,
                                        reinterpret_cast<void**>(&source)))) {
    source->AdviseSink(IID_ITfTextLayoutSink,
                       static_cast<ITfTextLayoutSink*>(this),
                       &layout_sink_cookie_);
    source->AdviseSink(IID_ITfTextEditSink, static_cast<ITfTextEditSink*>(this),
                       &edit_sink_cookie_);
    source->Release();
  }
  if (broker_client_) broker_client_->SetContext(context_generation_);
  return true;
}

void TextService::RevokeContext() noexcept {
  if (edit_valid_) edit_valid_->store(false);
  capture_active_ = false;
  EndCandidateUI();
  last_state_ = {};
  candidate_navigation_.Reset({});
  candidate_owned_keys_.reset();
  ++candidate_epoch_;
  if (active_context_ && composition_) {
    auto* cleanup = new (std::nothrow) CancelCompositionEdit(composition_);
    auto* old = composition_;
    composition_ = nullptr;
    if (cleanup) {
      RequestEdit(active_context_, client_id_, cleanup);
      cleanup->Release();
    }
    old->Release();
  }
  if (active_context_ && layout_sink_cookie_ != TF_INVALID_COOKIE) {
    ITfSource* source = nullptr;
    if (SUCCEEDED(active_context_->QueryInterface(
            IID_ITfSource, reinterpret_cast<void**>(&source)))) {
      source->UnadviseSink(layout_sink_cookie_);
      if (edit_sink_cookie_ != TF_INVALID_COOKIE)
        source->UnadviseSink(edit_sink_cookie_);
      source->Release();
    }
  }
  layout_sink_cookie_ = TF_INVALID_COOKIE;
  edit_sink_cookie_ = TF_INVALID_COOKIE;
  own_buffer_edit_ = false;
  if (active_context_) {
    active_context_->Release();
    active_context_ = nullptr;
  }
  if (context_identity_) {
    context_identity_->Release();
    context_identity_ = nullptr;
  }
  if (broker_client_) broker_client_->SetContext(0);
}
HRESULT STDMETHODCALLTYPE TextService::OnInitDocumentMgr(ITfDocumentMgr*) {
  return S_OK;
}
HRESULT STDMETHODCALLTYPE TextService::OnUninitDocumentMgr(ITfDocumentMgr*) {
  return S_OK;
}
HRESULT STDMETHODCALLTYPE TextService::OnSetFocus(ITfDocumentMgr* focused,
                                                  ITfDocumentMgr*) {
  RefreshBrokerConnection();
  if (!focused) {
    RevokeContext();
    return S_OK;
  }
  ITfContext* context = nullptr;
  if (SUCCEEDED(focused->GetTop(&context)) && context) {
    if (BindContext(context) && broker_client_)
      broker_client_->SetContext(context_generation_);
    context->Release();
  } else
    RevokeContext();
  return S_OK;
}
HRESULT STDMETHODCALLTYPE TextService::OnPushContext(ITfContext*) {
  ITfDocumentMgr* focused = nullptr;
  if (thread_manager_ && SUCCEEDED(thread_manager_->GetFocus(&focused)) &&
      focused) {
    OnSetFocus(focused, nullptr);
    focused->Release();
  } else
    RevokeContext();
  return S_OK;
}
HRESULT STDMETHODCALLTYPE TextService::OnPopContext(ITfContext* context) {
  if (context == active_context_) RevokeContext();
  return S_OK;
}
HRESULT STDMETHODCALLTYPE TextService::OnLayoutChange(ITfContext* context,
                                                      TfLayoutCode code,
                                                      ITfContextView*) {
  if (context == active_context_) {
    if (code == TF_LC_DESTROY)
      RevokeContext();
    else
      UpdateCandidateWindow(context, last_state_);
  }
  return S_OK;
}

HRESULT STDMETHODCALLTYPE TextService::OnEndEdit(ITfContext* context,
                                                 TfEditCookie,
                                                 ITfEditRecord* record) {
  if (context != active_context_ || !record) return S_OK;
  // A host may accept an insertion without moving selection. Consume the
  // origin marker on that edit too, so a later user click is never mistaken
  // for our own insertion and allowed to retarget a Buffer delivery.
  const bool own_edit = std::exchange(own_buffer_edit_, false);
  BOOL changed = FALSE;
  if (SUCCEEDED(record->GetSelectionStatus(&changed)) && changed &&
      broker_client_->Capturing() && !own_edit) {
    RevokeContext();
    // Chromium can move between fields using the same TSF context and only
    // report a selection change. Retire the capture immediately, then publish
    // the current target after the edit callback so an explicit rebind works
    // without sending a first key into the host. This never resumes capture.
    if (notification_window_)
      PostMessageW(notification_window_, kRefreshFocusedContext, 0, 0);
  }
  return S_OK;
}

LRESULT CALLBACK TextService::NotificationProcedure(HWND window, UINT message,
                                                    WPARAM wparam,
                                                    LPARAM lparam) {
  auto* self =
      reinterpret_cast<TextService*>(GetWindowLongPtrW(window, GWLP_USERDATA));
  if (message == WM_NCCREATE) {
    self = static_cast<TextService*>(
        reinterpret_cast<CREATESTRUCTW*>(lparam)->lpCreateParams);
    SetWindowLongPtrW(window, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(self));
  }
  if (message == kBrokerNotification && self) {
    try {
      self->OnBrokerNotification();
    } catch (...) {
      self->RevokeContext();
    }
    return 0;
  }
  if (message == kBrokerConnected && self && self->IsBrokerConnected()) {
    DWORD foreground_process = 0;
    GetWindowThreadProcessId(GetForegroundWindow(), &foreground_process);
    // A background application's late connection must not replace live focus.
    if (foreground_process == GetCurrentProcessId())
      self->OnSetFocus(TRUE);
    return 0;
  }
  if (message == kRefreshFocusedContext && self) {
    BOOL focused = FALSE;
    if (self->thread_manager_ &&
        SUCCEEDED(self->thread_manager_->IsThreadFocus(&focused)) && focused)
      self->OnPushContext(nullptr);
    return 0;
  }
  return DefWindowProcW(window, message, wparam, lparam);
}
void TextService::SetCapture(bool enabled) {
  if (enabled == capture_active_) return;
  capture_active_ = enabled;
  buffer_caret_ = {};
  if (edit_valid_) edit_valid_->store(false);
  edit_valid_ = std::make_shared<std::atomic_bool>(true);
  if (active_context_ && composition_) {
    auto* cleanup = new (std::nothrow) CancelCompositionEdit(composition_);
    auto* old = composition_;
    composition_ = nullptr;
    if (cleanup) {
      own_buffer_edit_ = true;
      RequestEdit(active_context_, client_id_, cleanup);
      cleanup->Release();
    }
    old->Release();
  }
  EndCandidateUI();
  last_state_ = {};
  candidate_navigation_.Reset({});
  ++candidate_epoch_;
}
void TextService::RefreshBrokerConnection() noexcept {
  const auto generation = broker_client_->ConnectionGeneration();
  if (generation == broker_generation_) return;
  broker_generation_ = generation;
  last_delivery_ = 0;
  RevokeContext();
}
void TextService::OnBrokerNotification() {
  RefreshBrokerConnection();
  while (auto message = broker_client_->TakeNotification()) {
    if (message->value("connectionGeneration", 0ULL) != broker_generation_)
      continue;
    const auto kind = message->value("kind", "");
    if (message->value("context", 0ULL) != context_generation_) continue;
    if (kind == "buffer_caret") {
      const auto rect = message->find("rect");
      if (capture_active_ && broker_client_->Capturing() && active_context_ &&
          message->value("openingRevision", 0ULL) == buffer_opening_ &&
          rect != message->end() && rect->is_array() && rect->size() == 4 &&
          std::all_of(rect->begin(), rect->end(), [](const core::Json& n) { return n.is_number_integer(); })) {
        RECT caret{(*rect)[0].get<LONG>(), (*rect)[1].get<LONG>(),
                   (*rect)[2].get<LONG>(), (*rect)[3].get<LONG>()};
        if (caret.bottom > caret.top && caret.bottom - caret.top < 600 &&
            caret.right >= caret.left && caret.right - caret.left < 100) {
          buffer_caret_ = caret;
          UpdateCandidateWindow(active_context_, last_state_);
        }
      }
      continue;
    }
    if (kind == "capture") {
      candidate_window_.SetFont(
          (std::clamp)(message->value("font", 16U), 10U, 40U));
      candidate_window_.SetVertical(message->value("verticalCandidates", false));
      candidate_window_.SetTheme(ui::ThemeIdOrDefault(
          message->value("theme", std::string("night"))));
      const bool enabled = message->value("enabled", false);
      const auto opening = message->value("openingRevision", 0ULL);
      if (opening != buffer_opening_) buffer_caret_ = {};
      buffer_opening_ = opening;
      const auto opening_context = context_generation_;
      const auto opening_valid = edit_valid_;
      auto same_focus = [this, opening_context, opening_valid] {
        if (!opening_valid || !opening_valid->load() ||
            opening_context != context_generation_ || !thread_manager_) return false;
        ITfDocumentMgr* manager = nullptr;
        ITfContext* focused = nullptr;
        IUnknown* identity = nullptr;
        if (SUCCEEDED(thread_manager_->GetFocus(&manager)) && manager &&
            SUCCEEDED(manager->GetTop(&focused)) && focused)
          focused->QueryInterface(IID_IUnknown, reinterpret_cast<void**>(&identity));
        const bool matches = identity && identity == context_identity_;
        if (identity) identity->Release();
        if (focused) focused->Release();
        if (manager) manager->Release();
        return matches;
      };
      // Query TSF's real caret while the host still owns its composition.
      // This also works in Chromium controls with no Win32 caret/TextPattern2.
      // Never use a saved rectangle as a new opening's focus authority.
      if (enabled && active_context_ && same_focus()) {
        DWORD process = 0;
        GetWindowThreadProcessId(GetForegroundWindow(), &process);
        if (process == GetCurrentProcessId()) {
          auto* scope = new (std::nothrow) ScopeRead(active_context_);
          if (scope) {
            HRESULT result = E_FAIL;
            const auto hr = active_context_->RequestEditSession(
                client_id_, scope, TF_ES_SYNC | TF_ES_READ, &result);
            if (SUCCEEDED(hr) && SUCCEEDED(result) && scope->allowed &&
                scope->caret.bottom > scope->caret.top && same_focus()) {
              const auto caret = scope->caret;
              broker_client_->Control({{"op", "geometry"},
                  {"context", context_generation_},
                  {"openingRevision", message->value("openingRevision", 0ULL)},
                  {"caret", {caret.left, caret.top, caret.right - caret.left,
                             caret.bottom - caret.top}}});
            }
            scope->Release();
          }
        }
      }
      if (opening_context != context_generation_) continue;
      SetCapture(enabled);
      continue;
    }
    if (kind != "deliver") continue;
    const auto request = message->value("request", 0ULL);
    bool valid = request > last_delivery_ && active_context_ && edit_valid_ &&
                 edit_valid_->load() &&
                 message->value("context", 0ULL) == context_generation_ &&
                 broker_client_->Capturing();
    DWORD foreground_process = 0;
    GetWindowThreadProcessId(GetForegroundWindow(), &foreground_process);
    valid = valid && foreground_process == GetCurrentProcessId();
    ITfDocumentMgr* manager = nullptr;
    ITfContext* focused = nullptr;
    IUnknown* identity = nullptr;
    if (valid && SUCCEEDED(thread_manager_->GetFocus(&manager)) && manager) {
      if (SUCCEEDED(manager->GetTop(&focused)) && focused)
        focused->QueryInterface(IID_IUnknown,
                                reinterpret_cast<void**>(&identity));
    }
    valid = valid && identity && identity == context_identity_;
    if (identity) identity->Release();
    if (focused) focused->Release();
    if (manager) manager->Release();
    if (!valid) {
      broker_client_->Control(
          {{"op", "ack"}, {"request", request}, {"accepted", false}});
      continue;
    }
    last_delivery_ = request;
    const auto text = message->value("text", std::string());
    std::wstring wide;
    if (!text.empty()) {
      int count =
          MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text.data(),
                              static_cast<int>(text.size()), nullptr, 0);
      if (count > 0) {
        wide.resize(static_cast<std::size_t>(count));
        MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text.data(),
                            static_cast<int>(text.size()), wide.data(), count);
      }
    }
    if (wide.empty()) {
      broker_client_->Control(
          {{"op", "ack"}, {"request", request}, {"accepted", false}});
      continue;
    }
    auto* session = new (std::nothrow) CommitEditSession(
        active_context_, std::move(wide), edit_valid_,
        [this, request, generation = broker_generation_,
         context = context_generation_](bool accepted) {
          if (generation != broker_client_->ConnectionGeneration() ||
              context != context_generation_) return;
          own_buffer_edit_ = accepted;
          broker_client_->Control(
              {{"op", "ack"}, {"request", request}, {"accepted", accepted}});
        },
        static_cast<ITfTextInputProcessorEx*>(this),
        [this, generation = broker_generation_](TfEditCookie) {
          if (generation != broker_client_->ConnectionGeneration())
            return false;
          DWORD process = 0;
          GetWindowThreadProcessId(GetForegroundWindow(), &process);
          if (process != GetCurrentProcessId() || !broker_client_->Capturing())
            return false;
          ITfDocumentMgr* manager = nullptr;
          ITfContext* context = nullptr;
          IUnknown* identity = nullptr;
          if (SUCCEEDED(thread_manager_->GetFocus(&manager)) && manager) {
            if (SUCCEEDED(manager->GetTop(&context)) && context)
              context->QueryInterface(IID_IUnknown,
                                      reinterpret_cast<void**>(&identity));
          }
          const bool matches = identity && identity == context_identity_;
          if (identity) identity->Release();
          if (context) context->Release();
          if (manager) manager->Release();
          return matches;
        });
    if (!session) {
      broker_client_->Control(
          {{"op", "ack"}, {"request", request}, {"accepted", false}});
      continue;
    }
    RequestEdit(active_context_, client_id_, session);
    session->Release();
  }
}

}  // namespace rimes::windows::tsf
