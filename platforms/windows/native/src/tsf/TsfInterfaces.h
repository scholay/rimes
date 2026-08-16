#pragma once

#include <msctf.h>

// Current Windows SDKs declare ITfTextInputProcessorEx. MinGW-w64's msctf.h
// can lag behind the Windows SDK, so keep this exact SDK-compatible fallback
// declaration to make cross-compilation and static analysis possible. It is
// excluded automatically when the platform header already provides it.
#if !defined(__ITfTextInputProcessorEx_INTERFACE_DEFINED__)
#define __ITfTextInputProcessorEx_INTERFACE_DEFINED__
MIDL_INTERFACE("6e4e2102-f9cd-433d-b496-303ce03a6507")
ITfTextInputProcessorEx : public ITfTextInputProcessor {
 public:
  virtual HRESULT STDMETHODCALLTYPE ActivateEx(ITfThreadMgr* thread_manager,
                                                TfClientId client_id,
                                                DWORD flags) = 0;
};
#endif

namespace rimes::windows::tsf {

// Kept local rather than relying on an import-library IID so the fallback
// interface above has identical QueryInterface behavior on every toolchain.
inline constexpr GUID kTextInputProcessorExIid = {
    0x6e4e2102,
    0xf9cd,
    0x433d,
    {0xb4, 0x96, 0x30, 0x3c, 0xe0, 0x3a, 0x65, 0x07},
};

inline constexpr TfClientId kNullClientId = 0;

}  // namespace rimes::windows::tsf
