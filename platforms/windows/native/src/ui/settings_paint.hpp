#pragma once

#include <Windows.h>

#include <string>

#include "icons.hpp"
#include "settings_layout.hpp"
#include "theme.hpp"

namespace rimes::windows::ui {

struct SettingsFonts {
  HFONT sidebar = nullptr;
  HFONT title = nullptr;
  HFONT heading = nullptr;
  HFONT body = nullptr;
  HFONT family = nullptr;
  HFONT control = nullptr;
  unsigned dpi = 96;

  void Release() noexcept {
    if (sidebar) DeleteObject(sidebar);
    if (title) DeleteObject(title);
    if (heading) DeleteObject(heading);
    if (body) DeleteObject(body);
    if (family) DeleteObject(family);
    if (control) DeleteObject(control);
    sidebar = title = heading = body = family = control = nullptr;
  }

  void Ensure(unsigned new_dpi) {
    if (sidebar && dpi == new_dpi) return;
    Release();
    dpi = new_dpi ? new_dpi : 96;
    auto make = [&](int dip, int weight) {
      return CreateFontW(-MulDiv(dip, static_cast<int>(dpi), 96), 0, 0, 0, weight,
                         FALSE, FALSE, FALSE, DEFAULT_CHARSET,
                         OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
                         CLEARTYPE_QUALITY, DEFAULT_PITCH | FF_DONTCARE,
                         L"Segoe UI");
    };
    sidebar = make(12, FW_MEDIUM);
    title = make(11, FW_SEMIBOLD);
    heading = make(20, FW_BOLD);
    body = make(11, FW_NORMAL);
    family = make(9, FW_NORMAL);
    control = make(11, FW_NORMAL);
  }
};

inline void PaintSettingsShell(HDC dc, const SettingsLayout& layout,
                               const SettingsDraft& draft,
                               const SettingsFonts& fonts,
                               unsigned dpi) {
  const ThemeId theme = draft.preview_theme;
  const ThemePalette& p = Palette(theme);
  RECT client{0, 0,
              static_cast<LONG>(layout.width_dip * static_cast<float>(dpi) / 96.0f +
                                0.5f),
              static_cast<LONG>(layout.height_dip * static_cast<float>(dpi) /
                                    96.0f +
                                0.5f)};
  auto px = [&](const DipRect& r) {
    RECT out{};
    out.left = static_cast<LONG>(r.left * dpi / 96.0f + 0.5f);
    out.top = static_cast<LONG>(r.top * dpi / 96.0f + 0.5f);
    out.right = static_cast<LONG>(r.right * dpi / 96.0f + 0.5f);
    out.bottom = static_cast<LONG>(r.bottom * dpi / 96.0f + 0.5f);
    return out;
  };

  FillRectColor(dc, client, ToColorRef(p.settings_background));

  FillRectColor(dc, px(layout.sidebar), ToColorRef(p.settings_background));
  RECT side_divider = px(layout.divider);
  side_divider.right = side_divider.left + 1;
  FillRectColor(dc, side_divider, ToColorRef(p.settings_separator));

  SetBkMode(dc, TRANSPARENT);
  HGDIOBJ old = SelectObject(dc, fonts.sidebar ? fonts.sidebar : GetStockObject(DEFAULT_GUI_FONT));
  SetTextColor(dc, ToColorRef(p.text_muted));
  RECT header = px({12, 14, 148, 34});
  DrawTextW(dc, L"设置", -1, &header, DT_LEFT | DT_VCENTER | DT_SINGLELINE);

  for (int i = 0; i < kSettingsPageCount; ++i) {
    const auto row = px(layout.nav[static_cast<std::size_t>(i)]);
    const bool selected = static_cast<int>(draft.page) == i;
    if (selected) {
      FillRoundRect(dc, row, MulDiv(8, static_cast<int>(dpi), 96),
                    ToColorRef(Blend(p.settings_background, p.accent, 0.16f)));
    } else if (draft.hover == i) {
      FillRoundRect(dc, row, MulDiv(8, static_cast<int>(dpi), 96),
                    ToColorRef(p.surface_tertiary));
    }
    if (draft.keyboard_focus && draft.focus == i) {
      HPEN focus_pen =
          CreatePen(PS_SOLID, (std::max)(1, MulDiv(1, static_cast<int>(dpi), 96)),
                    ToColorRef(p.accent));
      HGDIOBJ old_pen = SelectObject(dc, focus_pen);
      HGDIOBJ old_br = SelectObject(dc, GetStockObject(NULL_BRUSH));
      RoundRect(dc, row.left, row.top, row.right, row.bottom,
                MulDiv(8, static_cast<int>(dpi), 96),
                MulDiv(8, static_cast<int>(dpi), 96));
      SelectObject(dc, old_br);
      SelectObject(dc, old_pen);
      DeleteObject(focus_pen);
    }
    RECT icon = row;
    icon.left += MulDiv(6, static_cast<int>(dpi), 96);
    icon.right = icon.left + MulDiv(18, static_cast<int>(dpi), 96);
    icon.top += (row.bottom - row.top - MulDiv(18, static_cast<int>(dpi), 96)) / 2;
    icon.bottom = icon.top + MulDiv(18, static_cast<int>(dpi), 96);
    DrawIconGlyph(dc, kSettingsPageIcons[i], icon,
                  ToColorRef(selected ? p.text_primary : p.text_secondary));
    SelectObject(dc, fonts.sidebar);
    SetTextColor(dc, ToColorRef(selected ? p.text_primary : p.text_secondary));
    RECT text = row;
    text.left = icon.right + MulDiv(8, static_cast<int>(dpi), 96);
    DrawTextW(dc, kSettingsPageTitles[i], -1, &text,
              DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX);
  }

  // Subpage bar + divider
  FillRectColor(dc, px(layout.subpage_bar), ToColorRef(p.settings_background));
  RECT sub_div = px({layout.content.left, layout.subpage_bar.bottom - 1.0f,
                     layout.content.right, layout.subpage_bar.bottom});
  sub_div.top = sub_div.bottom - 1;
  FillRectColor(dc, sub_div, ToColorRef(p.settings_separator));
  const DipRect segments = {layout.subpage_tabs[0].left,
                            layout.subpage_tabs[0].top,
                            layout.subpage_tabs[1].right,
                            layout.subpage_tabs[1].bottom};
  FillRoundRect(dc, px(segments), MulDiv(5, static_cast<int>(dpi), 96),
                ToColorRef(Blend(p.settings_background, p.text_muted, 0.30f)));
  for (int i = 0; i < 2; ++i) {
    const bool on = draft.subpage == i;
    RECT tab = px(layout.subpage_tabs[static_cast<std::size_t>(i)]);
    if (on) {
      FillRoundRect(dc, tab, MulDiv(5, static_cast<int>(dpi), 96),
                    ToColorRef(Blend(p.settings_background, p.text_primary, 0.35f)));
      SetTextColor(dc, ToColorRef(p.text_primary));
    } else {
      SetTextColor(dc, ToColorRef(p.text_muted));
    }
    SelectObject(dc, fonts.sidebar);
    DrawTextW(dc, kSettingsSubpageLabels[static_cast<int>(draft.page)][i], -1,
              &tab, DT_CENTER | DT_VCENTER | DT_SINGLELINE);
  }

  // Mac heading aligns to the body's leading edge, vertically centered.
  SelectObject(dc, fonts.heading);
  SetTextColor(dc, ToColorRef(p.text_primary));
  RECT heading = px(layout.heading);
  heading.left += MulDiv(24, static_cast<int>(dpi), 96);
  DrawTextW(dc, kSettingsPageTitles[static_cast<int>(draft.page)], -1, &heading,
            DT_LEFT | DT_VCENTER | DT_SINGLELINE);

  if (draft.page == SettingsPage::kInput) {
    for (std::size_t i = 0; i < layout.scheme_cards.size(); ++i) {
      RECT card = px(layout.scheme_cards[i]);
      const bool selected = draft.schema_index == static_cast<int>(i);
      FillRoundRect(dc, card, MulDiv(8, static_cast<int>(dpi), 96),
                    ToColorRef(selected ? Blend(p.surface_secondary, p.accent, 0.10f)
                                        : p.surface_secondary));
      StrokeRoundRect(dc, card, MulDiv(8, static_cast<int>(dpi), 96),
                      ToColorRef(selected ? p.selection :
                          draft.hover == 100 + static_cast<int>(i)
                              ? p.border_strong : p.border),
                      selected ? 2 : 1);
      RECT icon = card;
      icon.left += MulDiv(10, static_cast<int>(dpi), 96);
      icon.right = icon.left + MulDiv(24, static_cast<int>(dpi), 96);
      icon.top += (card.bottom - card.top - MulDiv(24, static_cast<int>(dpi), 96)) / 2;
      icon.bottom = icon.top + MulDiv(24, static_cast<int>(dpi), 96);
      DrawIconGlyph(dc, kSettingsSchemeIcons[i], icon, ToColorRef(p.text_secondary));
      SelectObject(dc, fonts.title);
      SetTextColor(dc, ToColorRef(p.text_primary));
      RECT title = card;
      title.left = icon.right + MulDiv(9, static_cast<int>(dpi), 96);
      title.right -= MulDiv(36, static_cast<int>(dpi), 96);
      DrawTextW(dc, kSettingsSchemeTitles[i], -1, &title,
                DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS);
      RECT radio = card;
      radio.right -= MulDiv(12, static_cast<int>(dpi), 96);
      radio.left = radio.right - MulDiv(16, static_cast<int>(dpi), 96);
      radio.top += (card.bottom - card.top - MulDiv(16, static_cast<int>(dpi), 96)) / 2;
      radio.bottom = radio.top + MulDiv(16, static_cast<int>(dpi), 96);
      DrawIconGlyph(dc, selected ? IconId::kRadioOn : IconId::kRadioOff, radio,
                    ToColorRef(selected ? p.accent : p.border_strong));
      if (draft.keyboard_focus && draft.focus == 100 + static_cast<int>(i)) {
        HPEN focus_pen = CreatePen(
            PS_SOLID, (std::max)(1, MulDiv(1, static_cast<int>(dpi), 96)),
            ToColorRef(p.accent));
        HGDIOBJ old_pen = SelectObject(dc, focus_pen);
        HGDIOBJ old_br = SelectObject(dc, GetStockObject(NULL_BRUSH));
        RoundRect(dc, card.left, card.top, card.right, card.bottom,
                  MulDiv(8, static_cast<int>(dpi), 96),
                  MulDiv(8, static_cast<int>(dpi), 96));
        SelectObject(dc, old_br);
        SelectObject(dc, old_pen);
        DeleteObject(focus_pen);
      }
    }
  } else if (draft.page == SettingsPage::kAppearance && draft.subpage == 0) {
    SelectObject(dc, fonts.title);
    SetTextColor(dc, ToColorRef(p.text_secondary));
    RECT section = px({layout.body.left, layout.body.top, layout.body.right,
                       layout.body.top + 18});
    DrawTextW(dc, L"选择主题", -1, &section,
              DT_LEFT | DT_VCENTER | DT_SINGLELINE);
    for (std::size_t i = 0; i < layout.theme_cards.size(); ++i) {
      const ThemeId card_theme = static_cast<ThemeId>(i);
      const ThemePalette& tp = Palette(card_theme);
      RECT card = px(layout.theme_cards[i]);
      const bool selected = draft.theme_index == static_cast<int>(i);
      FillRoundRect(dc, card, MulDiv(8, static_cast<int>(dpi), 96),
                    ToColorRef(tp.surface_secondary));
      StrokeRoundRect(dc, card, MulDiv(8, static_cast<int>(dpi), 96),
                      ToColorRef(selected ? tp.selection :
                          draft.hover == 200 + static_cast<int>(i)
                              ? tp.border_strong : tp.border),
                      selected ? 2 : 1);
      RECT preview = card;
      preview.left += MulDiv(10, static_cast<int>(dpi), 96);
      preview.right -= MulDiv(10, static_cast<int>(dpi), 96);
      preview.top += MulDiv(10, static_cast<int>(dpi), 96);
      preview.bottom = preview.top + MulDiv(68, static_cast<int>(dpi), 96);
      FillRoundRect(dc, preview, MulDiv(6, static_cast<int>(dpi), 96),
                    ToColorRef(tp.surface));
      StrokeRoundRect(dc, preview, MulDiv(6, static_cast<int>(dpi), 96),
                      ToColorRef(tp.border), 1);
      const std::uint32_t colors[3] = {
          card_theme == ThemeId::kRasta ? tp.brand_red : tp.surface_secondary,
          card_theme == ThemeId::kRasta ? tp.brand_yellow : tp.selection,
          card_theme == ThemeId::kRasta ? tp.brand_green : tp.accent};
      int sx = preview.left + MulDiv(12, static_cast<int>(dpi), 96);
      const int sy =
          (preview.top + preview.bottom) / 2 - MulDiv(15, static_cast<int>(dpi), 96);
      const int sw = (preview.right - preview.left - MulDiv(36, static_cast<int>(dpi), 96)) / 3;
      for (int s = 0; s < 3; ++s) {
        RECT swatch{sx, sy, sx + sw,
                    sy + MulDiv(30, static_cast<int>(dpi), 96)};
        FillRoundRect(dc, swatch, MulDiv(4, static_cast<int>(dpi), 96),
                      ToColorRef(colors[s]));
        sx += sw + MulDiv(6, static_cast<int>(dpi), 96);
      }
      if (selected) {
        RECT mark{preview.right - MulDiv(24, static_cast<int>(dpi), 96),
                  preview.top + MulDiv(7, static_cast<int>(dpi), 96),
                  preview.right - MulDiv(7, static_cast<int>(dpi), 96),
                  preview.top + MulDiv(24, static_cast<int>(dpi), 96)};
        InflateRect(&mark, -MulDiv(2, static_cast<int>(dpi), 96),
                    -MulDiv(2, static_cast<int>(dpi), 96));
        HBRUSH mark_brush = CreateSolidBrush(ToColorRef(tp.accent));
        const auto old_mark = SelectObject(dc, mark_brush);
        const auto old_pen = SelectObject(dc, GetStockObject(NULL_PEN));
        Ellipse(dc, mark.left, mark.top, mark.right, mark.bottom);
        SelectObject(dc, old_pen);
        SelectObject(dc, old_mark);
        DeleteObject(mark_brush);
        DrawIconGlyph(dc, IconId::kCheck, mark, ToColorRef(tp.accent_foreground));
      }
      SelectObject(dc, fonts.title);
      SetTextColor(dc, ToColorRef(tp.text_primary));
      RECT name = card;
      name.left += MulDiv(12, static_cast<int>(dpi), 96);
      name.top = preview.bottom + MulDiv(8, static_cast<int>(dpi), 96);
      name.bottom = card.bottom - MulDiv(10, static_cast<int>(dpi), 96);
      DrawTextW(dc, kThemeTitles[i], -1, &name,
                DT_LEFT | DT_VCENTER | DT_SINGLELINE);
      SIZE size{};
      GetTextExtentPoint32W(dc, kThemeTitles[i],
                            static_cast<int>(wcslen(kThemeTitles[i])), &size);
      SelectObject(dc, fonts.family);
      SetTextColor(dc, ToColorRef(tp.text_muted));
      RECT family = name;
      family.top += MulDiv(2, static_cast<int>(dpi), 96);
      family.left = name.left + size.cx + MulDiv(8, static_cast<int>(dpi), 96);
      DrawTextW(dc, kThemeFamilies[i], -1, &family,
                DT_LEFT | DT_VCENTER | DT_SINGLELINE);
      RECT info = px(layout.theme_details[i]);
      if (draft.hover == 400 + static_cast<int>(i))
        FillRoundRect(dc, info, MulDiv(5, static_cast<int>(dpi), 96),
                      ToColorRef(tp.surface_tertiary));
      RECT glyph = info;
      InflateRect(&glyph, -MulDiv(4, static_cast<int>(dpi), 96),
                  -MulDiv(4, static_cast<int>(dpi), 96));
      DrawIconGlyph(dc, IconId::kInfo, glyph, ToColorRef(tp.text_secondary));
      if (draft.keyboard_focus && draft.focus == 400 + static_cast<int>(i))
        StrokeRoundRect(dc, info, MulDiv(5, static_cast<int>(dpi), 96),
                        ToColorRef(tp.accent));
      if (draft.keyboard_focus && draft.focus == 200 + static_cast<int>(i)) {
        HPEN focus_pen = CreatePen(
            PS_SOLID, (std::max)(1, MulDiv(1, static_cast<int>(dpi), 96)),
            ToColorRef(tp.accent));
        HGDIOBJ old_pen = SelectObject(dc, focus_pen);
        HGDIOBJ old_br = SelectObject(dc, GetStockObject(NULL_BRUSH));
        RoundRect(dc, card.left, card.top, card.right, card.bottom,
                  MulDiv(8, static_cast<int>(dpi), 96),
                  MulDiv(8, static_cast<int>(dpi), 96));
        SelectObject(dc, old_br);
        SelectObject(dc, old_pen);
        DeleteObject(focus_pen);
      }
    }
  } else if (draft.page == SettingsPage::kAppearance) {
    SelectObject(dc, fonts.body);
    SetTextColor(dc, ToColorRef(p.text_secondary));
    RECT fl = px({layout.body.left, layout.font_edit.top,
                  layout.font_edit.left - 8.0f, layout.font_edit.bottom});
    DrawTextW(dc, L"候选字号（10–40）", -1, &fl,
              DT_LEFT | DT_VCENTER | DT_SINGLELINE);
    RECT count_label = px({layout.body.left, layout.candidate_count_edit.top,
      layout.candidate_count_edit.left - 8.f, layout.candidate_count_edit.bottom});
    DrawTextW(dc, L"每页候选数（1–9）", -1, &count_label, DT_LEFT | DT_VCENTER | DT_SINGLELINE);
  } else if (draft.page == SettingsPage::kBuffer && draft.subpage == 0) {
    SelectObject(dc, fonts.body);
    SetTextColor(dc, ToColorRef(p.text_secondary));
    RECT help = px(layout.body);
    help.bottom = help.top + MulDiv(48, static_cast<int>(dpi), 96);
    DrawTextW(dc, L"使用 Ctrl+Alt+字母 打开或绑定 Buffer。", -1, &help,
              DT_LEFT | DT_WORDBREAK);
    RECT fl = px({layout.body.left, layout.hotkey_edit.top,
                  layout.hotkey_edit.left - 8.0f, layout.hotkey_edit.bottom});
    DrawTextW(dc, L"Ctrl+Alt+", -1, &fl, DT_LEFT | DT_VCENTER | DT_SINGLELINE);
  } else if (draft.page == SettingsPage::kBuffer) {
    SelectObject(dc, fonts.body);
    SetTextColor(dc, ToColorRef(p.text_secondary));
    RECT help = px(layout.body);
    DrawTextW(dc, L"输入先进入缓冲区，再由你发送到已绑定的输入框。\n\n"
                 L"Return 轻按发送下一块，长按 1.2 秒发送全部。\n"
                 L"切换输入框后暂停输入和发送。先点宿主输入框，再点 Buffer 原文区重新绑定；也可按快捷键。\n"
                 L"关闭窗口保留本次内容，退出后不恢复正文。", -1, &help,
              DT_LEFT | DT_WORDBREAK);
  } else if (draft.page == SettingsPage::kApi) {
    SelectObject(dc, fonts.body);
    SetTextColor(dc, ToColorRef(p.text_secondary));
    const wchar_t* labels[] = {L"API 地址", L"模型", L"API 密钥（留空保留）",
                               L"翻译目标语言"};
    const DipRect* edits[] = {&layout.base_edit, &layout.model_edit,
                              &layout.key_edit, &layout.lang_edit};
    for (int i = 0; i < 4; ++i) {
      if (edits[i]->width() <= 0) continue;
      RECT fl = px({layout.body.left, edits[i]->top, edits[i]->left - 8.0f,
                    edits[i]->bottom});
      DrawTextW(dc, labels[i], -1, &fl, DT_LEFT | DT_VCENTER | DT_SINGLELINE);
    }
    const float note_y = draft.subpage == 0 ? layout.lang_edit.bottom
                                            : layout.key_edit.bottom;
    RECT note = px({layout.body.left, note_y + 12.0f,
                    layout.body.right, note_y + 60.0f});
    SelectObject(dc, fonts.family);
    SetTextColor(dc, ToColorRef(p.text_muted));
    DrawTextW(dc, L"密钥保存在 Windows 凭据管理器。正文只在生成或翻译时发送。",
              -1, &note, DT_LEFT | DT_WORDBREAK);
  } else if (draft.page == SettingsPage::kPlugins) {
    SelectObject(dc, fonts.body); SetTextColor(dc, ToColorRef(p.text_secondary));
    if (draft.subpage == 1) {
      RECT note = px(layout.body);
      DrawTextW(dc, L"下载安装后默认停用，启用后即可使用。\n\n卸载保留配置、密钥和词库。停用并击后恢复普通全拼，重新启用可继续使用原方案选择。\n\n你可以在这里查看、安装和管理 RIMES 官方插件。", -1, &note, DT_LEFT | DT_WORDBREAK);
    }
  } else {
    SelectObject(dc, fonts.body);
    SetTextColor(dc, ToColorRef(p.text_secondary));
    RECT about = px(layout.body);
    auto text = draft.about_text;
    const auto version_end = text.find(L'\n', text.find(L'\n') + 1);
    if (version_end != std::wstring::npos)
      text = draft.subpage == 0 ? text.substr(0, version_end)
                               : text.substr(version_end + 1);
    DrawTextW(dc, text.c_str(), -1, &about, DT_LEFT | DT_WORDBREAK);
  }

  const DipRect* fields[] = {&layout.font_edit, &layout.candidate_count_edit, &layout.hotkey_edit,
      &layout.base_edit, &layout.model_edit, &layout.key_edit, &layout.lang_edit};
  for (const auto* field : fields) {
    if (field->width() <= 0) continue;
    RECT box = px(*field);
    FillRoundRect(dc, box, MulDiv(8, static_cast<int>(dpi), 96),
                  ToColorRef(p.surface));
    StrokeRoundRect(dc, box, MulDiv(8, static_cast<int>(dpi), 96),
                    ToColorRef(p.border), 1);
  }

  // Save / Close chrome
  auto paint_button = [&](const DipRect& r, const wchar_t* text, bool primary,
                          int focus) {
    RECT box = px(r);
    FillRoundRect(dc, box, MulDiv(8, static_cast<int>(dpi), 96),
                  ToColorRef(primary ? p.accent : p.surface_secondary));
    StrokeRoundRect(dc, box, MulDiv(8, static_cast<int>(dpi), 96),
                    ToColorRef(primary ? p.accent : p.border), 1);
    SelectObject(dc, fonts.body);
    SetTextColor(dc, ToColorRef(primary ? p.accent_foreground : p.text_primary));
    DrawTextW(dc, text, -1, &box, DT_CENTER | DT_VCENTER | DT_SINGLELINE);
    if (draft.keyboard_focus && draft.focus == focus) {
      InflateRect(&box, -3, -3);
      StrokeRoundRect(dc, box, MulDiv(5, static_cast<int>(dpi), 96),
                      ToColorRef(p.text_primary), 1);
    }
  };
  paint_button(layout.save, L"保存", true, 300);
  paint_button(layout.close, L"关闭", false, 301);
  FillRectColor(dc, px(layout.status_bar), ToColorRef(p.surface_secondary));
  SelectObject(dc, fonts.family);
  SetTextColor(dc, ToColorRef(p.text_muted));
  RECT status = px(layout.status_bar);
  status.left += MulDiv(12, static_cast<int>(dpi), 96);
  DrawTextW(dc, L"选择与修改将在保存后生效", -1, &status,
            DT_LEFT | DT_VCENTER | DT_SINGLELINE);

  if (layout.theme_popover.width() > 0 && draft.theme_detail >= 0 &&
      draft.theme_detail < 4) {
    RECT panel = px(layout.theme_popover);
    RECT shadow = panel;
    OffsetRect(&shadow, 0, MulDiv(3, static_cast<int>(dpi), 96));
    FillRoundRect(dc, shadow, MulDiv(8, static_cast<int>(dpi), 96),
                  ToColorRef(Blend(p.settings_background, 0x000000, 0.28f)));
    FillRoundRect(dc, panel, MulDiv(8, static_cast<int>(dpi), 96),
                  ToColorRef(p.surface_secondary));
    StrokeRoundRect(dc, panel, MulDiv(8, static_cast<int>(dpi), 96),
                    ToColorRef(p.border_strong));
    RECT text = panel;
    text.left += MulDiv(14, static_cast<int>(dpi), 96);
    text.right -= MulDiv(14, static_cast<int>(dpi), 96);
    text.top += MulDiv(12, static_cast<int>(dpi), 96);
    text.bottom = text.top + MulDiv(20, static_cast<int>(dpi), 96);
    SelectObject(dc, fonts.sidebar);
    SetTextColor(dc, ToColorRef(p.text_primary));
    DrawTextW(dc, kThemeTitles[draft.theme_detail], -1, &text, DT_LEFT | DT_SINGLELINE);
    OffsetRect(&text, 0, MulDiv(24, static_cast<int>(dpi), 96));
    SelectObject(dc, fonts.family);
    SetTextColor(dc, ToColorRef(p.text_muted));
    DrawTextW(dc, draft.theme_detail == 3 ? L"独立主题" : L"经典配色", -1, &text,
              DT_LEFT | DT_SINGLELINE);
    OffsetRect(&text, 0, MulDiv(20, static_cast<int>(dpi), 96));
    text.bottom = panel.bottom - MulDiv(14, static_cast<int>(dpi), 96);
    SelectObject(dc, fonts.body);
    SetTextColor(dc, ToColorRef(p.text_secondary));
    DrawTextW(dc, kThemeDetails[draft.theme_detail], -1, &text,
              DT_LEFT | DT_WORDBREAK | DT_NOPREFIX);
  }
  SelectObject(dc, old);
}

}  // namespace rimes::windows::ui
