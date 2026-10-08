#pragma once

#include <msctf.h>

#include <atomic>

#include "Guids.h"

namespace rimes::windows::tsf {

class DisplayAttributeInfo final : public ITfDisplayAttributeInfo {
 public:
  DisplayAttributeInfo() noexcept;

  DisplayAttributeInfo(const DisplayAttributeInfo&) = delete;
  DisplayAttributeInfo& operator=(const DisplayAttributeInfo&) = delete;

  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID interface_id,
                                           void** object) override;
  ULONG STDMETHODCALLTYPE AddRef() override;
  ULONG STDMETHODCALLTYPE Release() override;

  HRESULT STDMETHODCALLTYPE GetGUID(GUID* guid) override;
  HRESULT STDMETHODCALLTYPE GetDescription(BSTR* description) override;
  HRESULT STDMETHODCALLTYPE GetAttributeInfo(TF_DISPLAYATTRIBUTE* info) override;
  HRESULT STDMETHODCALLTYPE SetAttributeInfo(
      const TF_DISPLAYATTRIBUTE* info) override;
  HRESULT STDMETHODCALLTYPE Reset() override;

  static void FillDefault(TF_DISPLAYATTRIBUTE* info) noexcept;

 private:
  ~DisplayAttributeInfo() = default;

  std::atomic_ulong reference_count_{1};
};

class EnumDisplayAttributeInfo final : public IEnumTfDisplayAttributeInfo {
 public:
  EnumDisplayAttributeInfo() noexcept;

  EnumDisplayAttributeInfo(const EnumDisplayAttributeInfo&) = delete;
  EnumDisplayAttributeInfo& operator=(const EnumDisplayAttributeInfo&) =
      delete;

  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID interface_id,
                                           void** object) override;
  ULONG STDMETHODCALLTYPE AddRef() override;
  ULONG STDMETHODCALLTYPE Release() override;
  HRESULT STDMETHODCALLTYPE Clone(IEnumTfDisplayAttributeInfo** clone) override;
  HRESULT STDMETHODCALLTYPE Next(ULONG count,
                                 ITfDisplayAttributeInfo** items,
                                 ULONG* fetched) override;
  HRESULT STDMETHODCALLTYPE Reset() override;
  HRESULT STDMETHODCALLTYPE Skip(ULONG count) override;

 private:
  ~EnumDisplayAttributeInfo() = default;

  std::atomic_ulong reference_count_{1};
  ULONG index_ = 0;
};

HRESULT CreateDisplayAttributeInfo(ITfDisplayAttributeInfo** info) noexcept;
HRESULT CreateEnumDisplayAttributeInfo(
    IEnumTfDisplayAttributeInfo** enumerator) noexcept;
HRESULT ApplyCompositionDisplayAttribute(TfEditCookie edit_cookie,
                                         ITfContext* context,
                                         ITfRange* range) noexcept;

}  // namespace rimes::windows::tsf
