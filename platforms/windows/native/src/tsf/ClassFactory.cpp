#include "ClassFactory.h"

#include <new>

#include "ModuleState.h"
#include "TextService.h"

namespace rimes::windows::tsf {

ClassFactory::ClassFactory() noexcept {
  module::AddObject();
}

ClassFactory::~ClassFactory() {
  module::ReleaseObject();
}

HRESULT STDMETHODCALLTYPE ClassFactory::QueryInterface(REFIID interface_id,
                                                       void** object) {
  if (object == nullptr) {
    return E_POINTER;
  }
  *object = nullptr;

  if (!InlineIsEqualGUID(interface_id, IID_IUnknown) &&
      !InlineIsEqualGUID(interface_id, IID_IClassFactory)) {
    return E_NOINTERFACE;
  }

  *object = static_cast<IClassFactory*>(this);
  AddRef();
  return S_OK;
}

ULONG STDMETHODCALLTYPE ClassFactory::AddRef() {
  return reference_count_.fetch_add(1, std::memory_order_relaxed) + 1;
}

ULONG STDMETHODCALLTYPE ClassFactory::Release() {
  const ULONG remaining =
      reference_count_.fetch_sub(1, std::memory_order_acq_rel) - 1;
  if (remaining == 0) {
    delete this;
  }
  return remaining;
}

HRESULT STDMETHODCALLTYPE ClassFactory::CreateInstance(IUnknown* outer,
                                                       REFIID interface_id,
                                                       void** object) {
  if (object == nullptr) {
    return E_POINTER;
  }
  *object = nullptr;

  if (outer != nullptr) {
    return CLASS_E_NOAGGREGATION;
  }

  TextService* service = new (std::nothrow) TextService();
  if (service == nullptr) {
    return E_OUTOFMEMORY;
  }

  const HRESULT result = service->QueryInterface(interface_id, object);
  service->Release();
  return result;
}

HRESULT STDMETHODCALLTYPE ClassFactory::LockServer(BOOL lock) {
  if (lock != FALSE) {
    module::AddServerLock();
  } else {
    module::ReleaseServerLock();
  }
  return S_OK;
}

}  // namespace rimes::windows::tsf
