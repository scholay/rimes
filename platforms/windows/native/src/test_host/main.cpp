#include <Windows.h>

#include <algorithm>
#include <string_view>

namespace {

constexpr std::wstring_view kWindowClass = L"RimesTsfTestHostWindow";
constexpr std::wstring_view kWindowTitle = L"RIMES TSF Test Host";
constexpr int kEditorId = 1001;

LRESULT CALLBACK WindowProcedure(HWND window,
                                 UINT message,
                                 WPARAM wparam,
                                 LPARAM lparam) {
  switch (message) {
    case WM_CREATE: {
      const HWND editor = CreateWindowExW(
          WS_EX_CLIENTEDGE, L"EDIT", L"",
          WS_CHILD | WS_VISIBLE | WS_TABSTOP | ES_LEFT | ES_MULTILINE |
              ES_AUTOVSCROLL | ES_WANTRETURN | WS_VSCROLL,
          0, 0, 0, 0, window,
          reinterpret_cast<HMENU>(static_cast<INT_PTR>(kEditorId)),
          GetModuleHandleW(nullptr), nullptr);
      if (editor == nullptr) {
        return -1;
      }
      SendMessageW(editor, WM_SETFONT,
                   reinterpret_cast<WPARAM>(GetStockObject(DEFAULT_GUI_FONT)),
                   TRUE);
      SetFocus(editor);
      return 0;
    }

    case WM_SIZE: {
      const HWND editor = GetDlgItem(window, kEditorId);
      if (editor != nullptr) {
        MoveWindow(editor, 12, 12, (std::max)(0, LOWORD(lparam) - 24),
                   (std::max)(0, HIWORD(lparam) - 24), TRUE);
      }
      return 0;
    }

    case WM_SETFOCUS: {
      const HWND editor = GetDlgItem(window, kEditorId);
      if (editor != nullptr) {
        SetFocus(editor);
      }
      return 0;
    }

    case WM_DESTROY:
      PostQuitMessage(0);
      return 0;

    default:
      return DefWindowProcW(window, message, wparam, lparam);
  }
}

}  // namespace

int WINAPI wWinMain(HINSTANCE instance, HINSTANCE, PWSTR, int show_command) {
  WNDCLASSEXW window_class{};
  window_class.cbSize = sizeof(window_class);
  window_class.hInstance = instance;
  window_class.lpfnWndProc = WindowProcedure;
  window_class.lpszClassName = kWindowClass.data();
  window_class.hCursor = LoadCursorW(nullptr, IDC_IBEAM);
  window_class.hbrBackground =
      reinterpret_cast<HBRUSH>(COLOR_WINDOW + 1);
  if (RegisterClassExW(&window_class) == 0) {
    return 1;
  }

  const HWND window = CreateWindowExW(
      0, kWindowClass.data(), kWindowTitle.data(), WS_OVERLAPPEDWINDOW,
      CW_USEDEFAULT, CW_USEDEFAULT, 720, 420, nullptr, nullptr, instance,
      nullptr);
  if (window == nullptr) {
    return 2;
  }

  ShowWindow(window, show_command);
  UpdateWindow(window);

  MSG message{};
  while (GetMessageW(&message, nullptr, 0, 0) > 0) {
    TranslateMessage(&message);
    DispatchMessageW(&message);
  }
  return static_cast<int>(message.wParam);
}
