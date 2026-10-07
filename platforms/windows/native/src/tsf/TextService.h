#pragma once

#include <Windows.h>
#include <msctf.h>

#include <atomic>
#include <memory>
#include <string>

#include "BrokerClient.h"
#include "CandidateWindow.h"
#include "TsfInterfaces.h"

namespace rimes::windows::tsf {

class TextService final : public ITfTextInputProcessorEx,
                          public ITfKeyEventSink,
                          public ITfCompositionSink,
                          public ITfDisplayAttributeProvider,
                          public ITfThreadMgrEventSink,
                          public ITfTextLayoutSink,
                          public ITfTextEditSink {
 public:
  TextService() noexcept;
  explicit TextService(std::unique_ptr<BrokerClient> broker_client) noexcept;

  TextService(const TextService&) = delete;
  TextService& operator=(const TextService&) = delete;

  // IUnknown
  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID interface_id,
                                           void** object) override;
  ULONG STDMETHODCALLTYPE AddRef() override;
  ULONG STDMETHODCALLTYPE Release() override;

  // ITfTextInputProcessor / ITfTextInputProcessorEx
  HRESULT STDMETHODCALLTYPE Activate(ITfThreadMgr* thread_manager,
                                     TfClientId client_id) override;
  HRESULT STDMETHODCALLTYPE ActivateEx(ITfThreadMgr* thread_manager,
                                       TfClientId client_id,
                                       DWORD flags) override;
  HRESULT STDMETHODCALLTYPE Deactivate() override;

  // ITfKeyEventSink
  HRESULT STDMETHODCALLTYPE OnSetFocus(BOOL foreground) override;
  HRESULT STDMETHODCALLTYPE OnTestKeyDown(ITfContext* context,
                                          WPARAM virtual_key, LPARAM key_data,
                                          BOOL* eaten) override;
  HRESULT STDMETHODCALLTYPE OnKeyDown(ITfContext* context, WPARAM virtual_key,
                                      LPARAM key_data, BOOL* eaten) override;
  HRESULT STDMETHODCALLTYPE OnTestKeyUp(ITfContext* context, WPARAM virtual_key,
                                        LPARAM key_data, BOOL* eaten) override;
  HRESULT STDMETHODCALLTYPE OnKeyUp(ITfContext* context, WPARAM virtual_key,
                                    LPARAM key_data, BOOL* eaten) override;
  HRESULT STDMETHODCALLTYPE OnPreservedKey(ITfContext* context, REFGUID key,
                                           BOOL* eaten) override;

  // ITfCompositionSink
  HRESULT STDMETHODCALLTYPE OnCompositionTerminated(
      TfEditCookie write_cookie, ITfComposition* composition) override;

  // ITfDisplayAttributeProvider
  HRESULT STDMETHODCALLTYPE
  EnumDisplayAttributeInfo(IEnumTfDisplayAttributeInfo** enumerator) override;
  HRESULT STDMETHODCALLTYPE GetDisplayAttributeInfo(
      REFGUID guid, ITfDisplayAttributeInfo** info) override;

  HRESULT STDMETHODCALLTYPE OnInitDocumentMgr(ITfDocumentMgr*) override;
  HRESULT STDMETHODCALLTYPE OnUninitDocumentMgr(ITfDocumentMgr*) override;
  HRESULT STDMETHODCALLTYPE OnSetFocus(ITfDocumentMgr*,
                                       ITfDocumentMgr*) override;
  HRESULT STDMETHODCALLTYPE OnPushContext(ITfContext*) override;
  HRESULT STDMETHODCALLTYPE OnPopContext(ITfContext*) override;
  HRESULT STDMETHODCALLTYPE OnLayoutChange(ITfContext*, TfLayoutCode,
                                           ITfContextView*) override;

  HRESULT STDMETHODCALLTYPE OnEndEdit(ITfContext*, TfEditCookie,
                                      ITfEditRecord*) override;

  [[nodiscard]] bool IsBrokerConnected() const noexcept;

 private:
  friend struct CaretRegressionProbe;
  ~TextService();

  HRESULT HandleKey(BrokerKeyPhase phase, ITfContext* context,
                    WPARAM virtual_key, LPARAM key_data, BOOL* eaten) noexcept;

  HRESULT ApplyDocumentState(ITfContext* context,
                             const BrokerInputState& state,
                             TfEditCookie cookie = TF_INVALID_EDIT_COOKIE) noexcept;
  void SelectCandidate(std::size_t index) noexcept;
  HRESULT CommitText(ITfContext* context, const std::wstring& text) noexcept;
  HRESULT UpdateComposition(ITfContext* context,
                            const BrokerInputState& state) noexcept;
  HRESULT EndComposition(ITfContext* context) noexcept;
  void UpdateCandidateWindow(ITfContext* context,
                             const BrokerInputState& state,
                             TfEditCookie cookie = TF_INVALID_EDIT_COOKIE) noexcept;
  RECT QueryCaretRect(ITfContext* context,
                      TfEditCookie cookie = TF_INVALID_EDIT_COOKIE) noexcept;
  void ClearCompositionPointer() noexcept;
  bool BindContext(ITfContext*) noexcept;
  void SetCapture(bool enabled);
  bool capture_active_ = false;
  void OnBrokerNotification();
  void RefreshBrokerConnection() noexcept;
  static LRESULT CALLBACK NotificationProcedure(HWND, UINT, WPARAM, LPARAM);
  HWND notification_window_ = nullptr;
  std::uint64_t last_delivery_ = 0;
  std::uint64_t broker_generation_ = 0;
  bool return_owned_ = false;
  void RevokeContext() noexcept;
  ITfContext* active_context_ = nullptr;
  IUnknown* context_identity_ = nullptr;
  std::uint64_t context_generation_ = 0;
  std::shared_ptr<std::atomic_bool> edit_valid_;
  DWORD thread_sink_cookie_ = TF_INVALID_COOKIE;
  DWORD edit_sink_cookie_ = TF_INVALID_COOKIE;
  bool own_buffer_edit_ = false;
  DWORD layout_sink_cookie_ = TF_INVALID_COOKIE;
  BrokerInputState last_state_;

  std::atomic_ulong reference_count_{1};
  ITfThreadMgr* thread_manager_ = nullptr;
  ITfKeystrokeMgr* keystroke_manager_ = nullptr;
  ITfComposition* composition_ = nullptr;
  TfClientId client_id_ = kNullClientId;
  DWORD activation_flags_ = 0;
  bool key_event_sink_advised_ = false;
  bool ending_composition_ = false;
  std::unique_ptr<BrokerClient> broker_client_;
  CandidateWindow candidate_window_;
};

}  // namespace rimes::windows::tsf
