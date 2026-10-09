#include "buffer_anchor.hpp"

#include <objbase.h>
#include <oleauto.h>
#include <UIAutomation.h>
#include <wrl/client.h>

#include <cwchar>

namespace rimes::windows::workbench {
namespace {
using Microsoft::WRL::ComPtr;

DWORD WindowProcess(HWND window) {
  DWORD process = 0;
  if (window) GetWindowThreadProcessId(window, &process);
  return process;
}
BufferRect FromRect(const RECT& r) {
  return {static_cast<double>(r.left), static_cast<double>(r.top),
          static_cast<double>(r.right) - r.left,
          static_cast<double>(r.bottom) - r.top};
}
bool NativeTextField(HWND window) {
  wchar_t name[64]{};
  GetClassNameW(window, name, 64);
  return _wcsicmp(name, L"Edit") == 0 || _wcsnicmp(name, L"RichEdit", 8) == 0;
}
BufferInputAnchor NativeAnchor(HWND foreground, DWORD process) {
  BufferInputAnchor anchor;
  GUITHREADINFO info{sizeof(info)};
  const auto thread = GetWindowThreadProcessId(foreground, nullptr);
  if (!thread || !GetGUIThreadInfo(thread, &info) ||
      !info.hwndFocus || info.hwndFocus != info.hwndCaret ||
      WindowProcess(info.hwndFocus) != process || !NativeTextField(info.hwndFocus) ||
      (GetWindowLongPtrW(info.hwndFocus, GWL_STYLE) & ES_PASSWORD)) return anchor;
  POINT points[2]{{info.rcCaret.left, info.rcCaret.top},
                  {info.rcCaret.right, info.rcCaret.bottom}};
  if (!ClientToScreen(info.hwndCaret, &points[0]) ||
      !ClientToScreen(info.hwndCaret, &points[1])) return anchor;
  anchor.caret = BufferRect{static_cast<double>(points[0].x),
      static_cast<double>(points[0].y), static_cast<double>(points[1].x - points[0].x),
      static_cast<double>(points[1].y - points[0].y)};
  RECT box{};
  if (GetWindowRect(info.hwndFocus, &box)) anchor.box = FromRect(box);
  return anchor;
}
std::optional<BufferRect> RangeBounds(IUIAutomationTextRange* range) {
  SAFEARRAY* bounds = nullptr;
  if (FAILED(range->GetBoundingRectangles(&bounds)) || !bounds) return {};
  struct ArrayLifetime {
    SAFEARRAY* value;
    ~ArrayLifetime() { SafeArrayDestroy(value); }
  } lifetime{bounds};
  LONG lower = 0, upper = -1;
  VARTYPE type = VT_EMPTY;
  if (SafeArrayGetDim(bounds) != 1 ||
      FAILED(SafeArrayGetVartype(bounds, &type)) || type != VT_R8 ||
      FAILED(SafeArrayGetLBound(bounds, 1, &lower)) ||
      FAILED(SafeArrayGetUBound(bounds, 1, &upper)) ||
      upper - lower < 3 || upper - lower > 255) return {};
  double coordinates[4]{};
  for (LONG i = 0; i < 4; ++i) {
    LONG index = lower + i;
    if (FAILED(SafeArrayGetElement(bounds, &index, &coordinates[i]))) return {};
  }
  BufferRect rect{coordinates[0], coordinates[1], coordinates[2], coordinates[3]};
  if (!FiniteBufferRect(rect) || rect.width < 0 || rect.height <= 2) return {};
  return rect;
}
BufferInputAnchor AutomationAnchor(DWORD process) {
  BufferInputAnchor anchor;
  ComPtr<IUIAutomation2> automation;
  if (FAILED(CoCreateInstance(CLSID_CUIAutomation8, nullptr, CLSCTX_INPROC_SERVER,
      IID_PPV_ARGS(automation.GetAddressOf())))) return anchor;
  // Optional read-only geometry probing lives on the Broker UI thread, never
  // in the synchronous TSF key/IPC path. Slow/inaccessible providers fall back.
  if (FAILED(automation->put_AutoSetFocus(FALSE)) ||
      FAILED(automation->put_ConnectionTimeout(100)) ||
      FAILED(automation->put_TransactionTimeout(100))) return anchor;
  ComPtr<IUIAutomationElement> element;
  if (FAILED(automation->GetFocusedElement(element.GetAddressOf())) || !element)
    return anchor;
  int owner = 0;
  BOOL password = TRUE, focused = FALSE, offscreen = TRUE;
  CONTROLTYPEID control = 0;
  if (FAILED(element->get_CurrentProcessId(&owner)) ||
      static_cast<DWORD>(owner) != process ||
      FAILED(element->get_CurrentIsPassword(&password)) || password ||
      FAILED(element->get_CurrentHasKeyboardFocus(&focused)) || !focused ||
      FAILED(element->get_CurrentIsOffscreen(&offscreen)) || offscreen ||
      FAILED(element->get_CurrentControlType(&control)) ||
      (control != UIA_EditControlTypeId && control != UIA_DocumentControlTypeId))
    return anchor;
  ComPtr<IUIAutomationTextPattern2> pattern;
  if (FAILED(element->GetCurrentPatternAs(UIA_TextPattern2Id,
      IID_PPV_ARGS(pattern.GetAddressOf()))) || !pattern) return anchor;
  ComPtr<IUIAutomationTextRange> range;
  BOOL active = FALSE;
  if (FAILED(pattern->GetCaretRange(&active, range.GetAddressOf())) ||
      !active || !range) return anchor;
  anchor.caret = RangeBounds(range.Get());
  if (!anchor.caret && SUCCEEDED(range->ExpandToEnclosingUnit(TextUnit_Character))) {
    // A degenerate range may have no rectangle. Expand only this private
    // range to recover the current line; never select text or fetch its value.
    anchor.caret = RangeBounds(range.Get());
  }
  if (!anchor.caret) return anchor;
  RECT box{};
  if (SUCCEEDED(element->get_CurrentBoundingRectangle(&box))) anchor.box = FromRect(box);
  return anchor;
}
}  // namespace

BufferInputAnchor ProbeBufferInputAnchor(DWORD expected_process) {
  if (!expected_process || expected_process == GetCurrentProcessId()) return {};
  const HWND foreground = GetForegroundWindow();
  if (!foreground || WindowProcess(foreground) != expected_process) return {};
  auto anchor = NativeAnchor(foreground, expected_process);
  if (!anchor.caret) anchor = AutomationAnchor(expected_process);
  // Do not align to a former field/app if focus changed during a provider call.
  if (foreground != GetForegroundWindow() ||
      WindowProcess(GetForegroundWindow()) != expected_process) return {};
  return anchor;
}
}  // namespace rimes::windows::workbench
