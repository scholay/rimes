#pragma once

#include <Windows.h>
#include <Unknwn.h>

#include <atomic>

namespace rimes::windows::tsf {

class ClassFactory final : public IClassFactory {
 public:
  ClassFactory() noexcept;

  ClassFactory(const ClassFactory&) = delete;
  ClassFactory& operator=(const ClassFactory&) = delete;

  // IUnknown
  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID interface_id,
                                           void** object) override;
  ULONG STDMETHODCALLTYPE AddRef() override;
  ULONG STDMETHODCALLTYPE Release() override;

  // IClassFactory
  HRESULT STDMETHODCALLTYPE CreateInstance(IUnknown* outer,
                                           REFIID interface_id,
                                           void** object) override;
  HRESULT STDMETHODCALLTYPE LockServer(BOOL lock) override;

 private:
  ~ClassFactory();

  std::atomic_ulong reference_count_{1};
};

}  // namespace rimes::windows::tsf
