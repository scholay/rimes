#pragma once
#include <wincodec.h>
#include <wrl/client.h>
#include <filesystem>
#include <stdexcept>

// Offscreen fixture rendering using the production painters and child controls.
// No desktop capture, input synthesis, user preferences, or IME registration.
namespace parity_render {
using Microsoft::WRL::ComPtr;
inline void Require(HRESULT result) { if (FAILED(result)) throw std::runtime_error("render failed"); }
struct Canvas {
  HDC dc = CreateCompatibleDC(nullptr);
  HBITMAP bitmap = nullptr;
  HGDIOBJ previous = nullptr;
  RECT rect{};
  Canvas(int width, int height) : rect{0, 0, width, height} {
    BITMAPINFO info{}; info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    info.bmiHeader.biWidth = width; info.bmiHeader.biHeight = -height;
    info.bmiHeader.biPlanes = 1; info.bmiHeader.biBitCount = 32;
    info.bmiHeader.biCompression = BI_RGB;
    void* pixels = nullptr;
    bitmap = CreateDIBSection(dc, &info, DIB_RGB_COLORS, &pixels, nullptr, 0);
    if (!bitmap || !dc) throw std::runtime_error("canvas unavailable");
    previous = SelectObject(dc, bitmap);
  }
  ~Canvas() { SelectObject(dc, previous); DeleteObject(bitmap); DeleteDC(dc); }
  void Save(const std::filesystem::path& path, IWICImagingFactory* factory) {
    ComPtr<IWICBitmap> source; ComPtr<IWICStream> stream;
    ComPtr<IWICBitmapEncoder> encoder; ComPtr<IWICBitmapFrameEncode> frame;
    Require(factory->CreateBitmapFromHBITMAP(bitmap, nullptr, WICBitmapIgnoreAlpha, &source));
    Require(factory->CreateStream(&stream)); Require(stream->InitializeFromFilename(path.c_str(), GENERIC_WRITE));
    Require(factory->CreateEncoder(GUID_ContainerFormatPng, nullptr, &encoder));
    Require(encoder->Initialize(stream.Get(), WICBitmapEncoderNoCache));
    Require(encoder->CreateNewFrame(&frame, nullptr)); Require(frame->Initialize(nullptr));
    Require(frame->SetSize(rect.right, rect.bottom));
    auto format = GUID_WICPixelFormat24bppBGR; Require(frame->SetPixelFormat(&format));
    Require(frame->WriteSource(source.Get(), nullptr)); Require(frame->Commit()); Require(encoder->Commit());
  }
};
inline int Export(const std::filesystem::path& directory) {
  using namespace rimes::windows;
  try {
    CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    ComPtr<IWICImagingFactory> imaging;
    Require(CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&imaging)));
    ComPtr<ID2D1Factory> factory; ComPtr<IDWriteFactory> write;
    Require(D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED, factory.GetAddressOf()));
    Require(DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED, __uuidof(IDWriteFactory), reinterpret_cast<IUnknown**>(write.GetAddressOf())));
    ComPtr<IDWriteTextFormat> body, label;
    Require(write->CreateTextFormat(L"Microsoft YaHei UI", nullptr, DWRITE_FONT_WEIGHT_NORMAL, DWRITE_FONT_STYLE_NORMAL, DWRITE_FONT_STRETCH_NORMAL, 12, L"zh-CN", &body));
    Require(write->CreateTextFormat(L"Segoe UI", nullptr, DWRITE_FONT_WEIGHT_SEMI_BOLD, DWRITE_FONT_STYLE_NORMAL, DWRITE_FONT_STRETCH_NORMAL, 10, L"zh-CN", &label));
    body->SetWordWrapping(DWRITE_WORD_WRAPPING_NO_WRAP); label->SetWordWrapping(DWRITE_WORD_WRAPPING_NO_WRAP);
    std::filesystem::create_directories(directory);
    for (int theme = 0; theme < 4; ++theme) {
      for (const int dpi : {96, 144, 192}) {
        Canvas canvas(MulDiv(760, dpi, 96), MulDiv(438, dpi, 96));
        ComPtr<ID2D1DCRenderTarget> target; ComPtr<ID2D1SolidColorBrush> brush;
        const auto properties = D2D1::RenderTargetProperties(D2D1_RENDER_TARGET_TYPE_SOFTWARE,
            D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_IGNORE), static_cast<float>(dpi), static_cast<float>(dpi));
        Require(factory->CreateDCRenderTarget(&properties, &target));
        Require(target->BindDC(canvas.dc, &canvas.rect)); Require(target->CreateSolidColorBrush(D2D1::ColorF(0), &brush));
        target->BeginDraw(); target->Clear(ui::ColorF(ui::Palette(static_cast<ui::ThemeId>(theme)).settings_background));
        float top = 8;
        for (int scenario = 0; scenario < 4; ++scenario) {
          ui::BufferPaintState state; state.theme = static_cast<ui::ThemeId>(theme);
          state.visible = true; state.bound = true; state.capturing = true;
          state.source_blocks = {{L"现在可以在块之间插入", false}, {L"新的内容。", false}};
          state.insertion = 1; state.status = L"已关联输入框";
          if (scenario == 0) { state.preedit = L"nihao"; state.preedit_caret = 5; }
          if (scenario == 1 || scenario == 2) {
            state.mode = ui::BufferMode::kGenerate; state.busy = scenario == 1;
            if (state.busy) { state.preview = L"正在整理你的想法…"; state.status = L"生成中…"; }
            else { state.result_blocks = {{L"这是生成的结果。", false}, {L"按快捷键逐块发送。", false}}; state.status = L"结果就绪"; }
          }
          if (scenario == 3) { state.mode = ui::BufferMode::kTranslate; state.translate = true;
            state.result_blocks = {{L"You can now insert text between blocks.", false}};
            state.status = L"2 秒后上屏"; state.auto_send_seconds = 2; state.close_after_send = true; }
          const auto layout = ui::LayoutBuffer(state, 760);
          target->SetTransform(D2D1::Matrix3x2F::Translation(0, top));
          ui::DrawBufferWorkbench({target.Get(), write.Get(), body.Get(), label.Get(), brush.Get(), static_cast<float>(dpi)}, state, layout);
          top += layout.height_dip + 14;
        }
        Require(target->EndDraw());
        canvas.Save(directory / (L"buffer-" + std::to_wstring(theme) + L"-" + std::to_wstring(dpi) + L".png"), imaging.Get());
      }
      workbench::SettingsUiCallbacks callbacks;
      callbacks.load = [theme] { workbench::Settings s; s.theme = ui::ThemeIdString(static_cast<ui::ThemeId>(theme)); s.auto_send_seconds = 2; s.close_after_send = true; return s; };
      workbench::SettingsUiHost settings(callbacks);
      for (const auto page : {ui::SettingsPage::kInput, ui::SettingsPage::kAppearance, ui::SettingsPage::kBuffer, ui::SettingsPage::kApi, ui::SettingsPage::kChord}) {
        for (int subpage=0;subpage<2;++subpage) {
        settings.OpenPage(nullptr, page, subpage, false);
        RECT rect{}; GetClientRect(settings.hwnd(), &rect); Canvas canvas(rect.right, rect.bottom);
        SendMessageW(settings.hwnd(), WM_PRINTCLIENT, reinterpret_cast<WPARAM>(canvas.dc), PRF_CLIENT);
        for (HWND child = GetWindow(settings.hwnd(), GW_CHILD); child; child = GetWindow(child, GW_HWNDNEXT)) {
          if (!(GetWindowLongPtrW(child, GWL_STYLE) & WS_VISIBLE)) continue;
          RECT child_rect{}; GetWindowRect(child, &child_rect);
          MapWindowPoints(nullptr, settings.hwnd(), reinterpret_cast<POINT*>(&child_rect), 2);
          const int saved = SaveDC(canvas.dc); SetViewportOrgEx(canvas.dc, child_rect.left, child_rect.top, nullptr);
          const int before_print = SaveDC(canvas.dc);
          SendMessageW(child, WM_PRINT, reinterpret_cast<WPARAM>(canvas.dc), PRF_CLIENT | PRF_NONCLIENT);
          RestoreDC(canvas.dc, before_print);
          // Native EDIT skips glyph painting under a hidden top-level window.
          // Render its actual text/font into its own client area in this fixture.
          wchar_t kind[32]{}; GetClassNameW(child, kind, 32);
          if (_wcsicmp(kind, L"EDIT") == 0) {
            std::wstring text(GetWindowTextLengthW(child) + 1, L'\0');
            GetWindowTextW(child, text.data(), static_cast<int>(text.size())); text.resize(wcslen(text.c_str()));
            if (GetWindowLongPtrW(child, GWL_STYLE) & ES_PASSWORD) text.assign(text.size(), L'•');
            RECT edit{}; GetClientRect(child, &edit);
            const auto font = reinterpret_cast<HFONT>(SendMessageW(child, WM_GETFONT, 0, 0));
            if (font) SelectObject(canvas.dc, font);
            SetBkMode(canvas.dc, TRANSPARENT); SetTextColor(canvas.dc, ui::ToColorRef(ui::Palette(static_cast<ui::ThemeId>(theme)).text_primary));
            DrawTextW(canvas.dc, text.c_str(), -1, &edit, DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS);
          }
          RestoreDC(canvas.dc, saved);
        }
        canvas.Save(directory / (L"settings-" + std::to_wstring(theme) + L"-" + std::to_wstring(static_cast<int>(page)) + L"-" + std::to_wstring(subpage) + L".png"), imaging.Get());
        }
      }
    }
    return 0;
  } catch (...) { return 1; }
}
}
