#include "DisplayAttribute.h"

#include <oleauto.h>

#include <new>

#include "ModuleState.h"

namespace rimes::windows::tsf {
namespace {

void FillDefaultAttribute(TF_DISPLAYATTRIBUTE* info) noexcept {
  if (info == nullptr) {
    return;
  }
  *info = {};
  info->crText.type = TF_CT_NONE;
  info->crBk.type = TF_CT_NONE;
  info->lsStyle = TF_LS_DOT;
  info->fBoldLine = FALSE;
  info->crLine.type = TF_CT_NONE;
  info->bAttr = TF_ATTR_INPUT;
}

}  // namespace

void DisplayAttributeInfo::FillDefault(TF_DISPLAYATTRIBUTE* info) noexcept {
  FillDefaultAttribute(info);
}

DisplayAttributeInfo::DisplayAttributeInfo() noexcept {
  module::AddObject();
}

HRESULT STDMETHODCALLTYPE DisplayAttributeInfo::QueryInterface(
    REFIID interface_id, void** object) {
  if (object == nullptr) {
    return E_POINTER;
  }
  *object = nullptr;
  if (!InlineIsEqualGUID(interface_id, IID_IUnknown) &&
      !InlineIsEqualGUID(interface_id, IID_ITfDisplayAttributeInfo)) {
    return E_NOINTERFACE;
  }
  *object = static_cast<ITfDisplayAttributeInfo*>(this);
  AddRef();
  return S_OK;
}

ULONG STDMETHODCALLTYPE DisplayAttributeInfo::AddRef() {
  return reference_count_.fetch_add(1, std::memory_order_relaxed) + 1;
}

ULONG STDMETHODCALLTYPE DisplayAttributeInfo::Release() {
  const ULONG remaining =
      reference_count_.fetch_sub(1, std::memory_order_acq_rel) - 1;
  if (remaining == 0) {
    module::ReleaseObject();
    delete this;
  }
  return remaining;
}

HRESULT STDMETHODCALLTYPE DisplayAttributeInfo::GetGUID(GUID* guid) {
  if (guid == nullptr) {
    return E_POINTER;
  }
  *guid = kInputDisplayAttributeGuid;
  return S_OK;
}

HRESULT STDMETHODCALLTYPE DisplayAttributeInfo::GetDescription(BSTR* description) {
  if (description == nullptr) {
    return E_POINTER;
  }
  *description = SysAllocString(L"RIMES composition");
  return *description != nullptr ? S_OK : E_OUTOFMEMORY;
}

HRESULT STDMETHODCALLTYPE DisplayAttributeInfo::GetAttributeInfo(
    TF_DISPLAYATTRIBUTE* info) {
  if (info == nullptr) {
    return E_POINTER;
  }
  FillDefaultAttribute(info);
  return S_OK;
}

HRESULT STDMETHODCALLTYPE DisplayAttributeInfo::SetAttributeInfo(
    const TF_DISPLAYATTRIBUTE*) {
  return E_NOTIMPL;
}

HRESULT STDMETHODCALLTYPE DisplayAttributeInfo::Reset() {
  return S_OK;
}

EnumDisplayAttributeInfo::EnumDisplayAttributeInfo() noexcept {
  module::AddObject();
}

HRESULT STDMETHODCALLTYPE EnumDisplayAttributeInfo::QueryInterface(
    REFIID interface_id, void** object) {
  if (object == nullptr) {
    return E_POINTER;
  }
  *object = nullptr;
  if (!InlineIsEqualGUID(interface_id, IID_IUnknown) &&
      !InlineIsEqualGUID(interface_id, IID_IEnumTfDisplayAttributeInfo)) {
    return E_NOINTERFACE;
  }
  *object = static_cast<IEnumTfDisplayAttributeInfo*>(this);
  AddRef();
  return S_OK;
}

ULONG STDMETHODCALLTYPE EnumDisplayAttributeInfo::AddRef() {
  return reference_count_.fetch_add(1, std::memory_order_relaxed) + 1;
}

ULONG STDMETHODCALLTYPE EnumDisplayAttributeInfo::Release() {
  const ULONG remaining =
      reference_count_.fetch_sub(1, std::memory_order_acq_rel) - 1;
  if (remaining == 0) {
    module::ReleaseObject();
    delete this;
  }
  return remaining;
}

HRESULT STDMETHODCALLTYPE EnumDisplayAttributeInfo::Clone(
    IEnumTfDisplayAttributeInfo** clone) {
  if (clone == nullptr) {
    return E_POINTER;
  }
  *clone = nullptr;
  auto* copy = new (std::nothrow) EnumDisplayAttributeInfo();
  if (copy == nullptr) {
    return E_OUTOFMEMORY;
  }
  copy->index_ = index_;
  *clone = copy;
  return S_OK;
}

HRESULT STDMETHODCALLTYPE EnumDisplayAttributeInfo::Next(
    ULONG count, ITfDisplayAttributeInfo** items, ULONG* fetched) {
  if (items == nullptr) {
    return E_POINTER;
  }
  ULONG produced = 0;
  if (count > 0 && index_ == 0) {
    const HRESULT result = CreateDisplayAttributeInfo(&items[0]);
    if (FAILED(result)) {
      return result;
    }
    index_ = 1;
    produced = 1;
  }
  if (fetched != nullptr) {
    *fetched = produced;
  }
  return produced == count ? S_OK : S_FALSE;
}

HRESULT STDMETHODCALLTYPE EnumDisplayAttributeInfo::Reset() {
  index_ = 0;
  return S_OK;
}

HRESULT STDMETHODCALLTYPE EnumDisplayAttributeInfo::Skip(ULONG count) {
  if (count > 0 && index_ == 0) {
    index_ = 1;
    return count == 1 ? S_OK : S_FALSE;
  }
  return count == 0 ? S_OK : S_FALSE;
}

HRESULT CreateDisplayAttributeInfo(ITfDisplayAttributeInfo** info) noexcept {
  if (info == nullptr) {
    return E_POINTER;
  }
  *info = nullptr;
  auto* created = new (std::nothrow) DisplayAttributeInfo();
  if (created == nullptr) {
    return E_OUTOFMEMORY;
  }
  *info = created;
  return S_OK;
}

HRESULT CreateEnumDisplayAttributeInfo(
    IEnumTfDisplayAttributeInfo** enumerator) noexcept {
  if (enumerator == nullptr) {
    return E_POINTER;
  }
  *enumerator = nullptr;
  auto* created = new (std::nothrow) EnumDisplayAttributeInfo();
  if (created == nullptr) {
    return E_OUTOFMEMORY;
  }
  *enumerator = created;
  return S_OK;
}

HRESULT ApplyCompositionDisplayAttribute(TfEditCookie edit_cookie,
                                         ITfContext* context,
                                         ITfRange* range) noexcept {
  if (context == nullptr || range == nullptr) {
    return E_INVALIDARG;
  }

  ITfCategoryMgr* categories = nullptr;
  HRESULT result =
      CoCreateInstance(CLSID_TF_CategoryMgr, nullptr, CLSCTX_INPROC_SERVER,
                       IID_ITfCategoryMgr, reinterpret_cast<void**>(&categories));
  if (FAILED(result) || categories == nullptr) {
    return result;
  }

  TfGuidAtom atom = TF_INVALID_GUIDATOM;
  result = categories->RegisterGUID(kInputDisplayAttributeGuid, &atom);
  categories->Release();
  if (FAILED(result) || atom == TF_INVALID_GUIDATOM) {
    return result;
  }

  ITfProperty* property = nullptr;
  result = context->GetProperty(GUID_PROP_ATTRIBUTE, &property);
  if (FAILED(result) || property == nullptr) {
    return result;
  }

  VARIANT value;
  VariantInit(&value);
  value.vt = VT_I4;
  value.lVal = static_cast<LONG>(atom);
  result = property->SetValue(edit_cookie, range, &value);
  property->Release();
  return result;
}

}  // namespace rimes::windows::tsf
