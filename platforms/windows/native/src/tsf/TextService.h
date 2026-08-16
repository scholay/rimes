#pragma once

#include <Windows.h>

#include <atomic>
#include <memory>
#include <string>

#include "BrokerClient.h"
#include "TsfInterfaces.h"

namespace rimes::windows::tsf {

class TextService final : public ITfTextInputProcessorEx,
                          public ITfKeyEventSink {
 public:
  TextService() noexcept;

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
                                          WPARAM virtual_key,
                                          LPARAM key_data,
                                          BOOL* eaten) override;
  HRESULT STDMETHODCALLTYPE OnKeyDown(ITfContext* context,
                                      WPARAM virtual_key,
                                      LPARAM key_data,
                                      BOOL* eaten) override;
  HRESULT STDMETHODCALLTYPE OnTestKeyUp(ITfContext* context,
                                        WPARAM virtual_key,
                                        LPARAM key_data,
                                        BOOL* eaten) override;
  HRESULT STDMETHODCALLTYPE OnKeyUp(ITfContext* context,
                                    WPARAM virtual_key,
                                    LPARAM key_data,
                                    BOOL* eaten) override;
  HRESULT STDMETHODCALLTYPE OnPreservedKey(ITfContext* context,
                                           REFGUID key,
                                           BOOL* eaten) override;

 private:
  ~TextService();

  HRESULT HandleKey(BrokerKeyPhase phase,
                    ITfContext* context,
                    WPARAM virtual_key,
                    LPARAM key_data,
                    BOOL* eaten) noexcept;

  HRESULT CommitText(ITfContext* context,
                     const std::wstring& text) noexcept;

  std::atomic_ulong reference_count_{1};
  ITfThreadMgr* thread_manager_ = nullptr;
  ITfKeystrokeMgr* keystroke_manager_ = nullptr;
  TfClientId client_id_ = kNullClientId;
  DWORD activation_flags_ = 0;
  bool key_event_sink_advised_ = false;
  std::unique_ptr<BrokerClient> broker_client_;
};

}  // namespace rimes::windows::tsf
