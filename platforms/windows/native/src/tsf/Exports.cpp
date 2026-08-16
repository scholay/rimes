#include <Windows.h>

#include <new>

#include "ClassFactory.h"
#include "Guids.h"
#include "ModuleState.h"

STDAPI DllGetClassObject(REFCLSID class_id,
                         REFIID interface_id,
                         void** object) {
  if (object == nullptr) {
    return E_POINTER;
  }
  *object = nullptr;

  if (!InlineIsEqualGUID(class_id,
                         rimes::windows::tsf::kTextServiceClsid)) {
    return CLASS_E_CLASSNOTAVAILABLE;
  }

  auto* factory =
      new (std::nothrow) rimes::windows::tsf::ClassFactory();
  if (factory == nullptr) {
    return E_OUTOFMEMORY;
  }

  const HRESULT result = factory->QueryInterface(interface_id, object);
  factory->Release();
  return result;
}

STDAPI DllCanUnloadNow() {
  return rimes::windows::tsf::module::CanUnloadNow();
}
