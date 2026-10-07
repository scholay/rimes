#pragma once

#include <algorithm>
#include <array>
#include <string>
#include <vector>

#include "candidate_strip.hpp"
#include "icons.hpp"
#include "theme.hpp"

namespace rimes::windows::ui {

enum class SettingsPage {
  kInput = 0,
  kAppearance = 1,
  kBuffer = 2,
  kApi = 3,
  kPlugins = 4,
  kAbout = 5,
};

inline constexpr int kSettingsPageCount = 6;
inline constexpr const wchar_t* kSettingsPageTitles[] = {
    L"输入法", L"外观", L"Buffer", L"连接器", L"官方插件", L"关于"};
inline constexpr IconId kSettingsPageIcons[] = {
    IconId::kKeyboard, IconId::kPalette, IconId::kGrid, IconId::kLink,
    IconId::kGrid, IconId::kSettings};
inline constexpr const wchar_t* kSettingsSchemeTitles[] = {
    L"雾凇全拼", L"自然码双拼", L"小鹤双拼", L"五笔 86", L"英文", L"isaac2026"};
inline constexpr IconId kSettingsSchemeIcons[] = {
    IconId::kAlphabet, IconId::kKeyboard, IconId::kBird, IconId::kGrid,
    IconId::kEnglish, IconId::kKeyboard};
inline constexpr const wchar_t* kSettingsSubpageLabels[][2] = {
    {L"输入方案", L"选项"},
    {L"主题", L"尺寸"},
    {L"快捷键", L"行为"},
    {L"模型", L"密钥"},
    {L"管理", L"说明"},
    {L"版本", L"诊断"},
};

struct SettingsMetrics {
  int client_width_dip = 980;
  int client_height_dip = 680;
  int min_client_width_dip = 860;
  int min_client_height_dip = 600;
  int sidebar_width_dip = 160;
  int sidebar_pad_x_dip = 12;
  int sidebar_header_y_dip = 16;
  int sidebar_row_y_dip = 36;
  int sidebar_row_height_dip = 32;
  int sidebar_row_gap_dip = 4;
  int sidebar_icon_dip = 18;
  int sidebar_font_dip = 12;
  int subpage_bar_height_dip = 46;
  int heading_band_height_dip = 84;
  int body_origin_x_dip = 184;
  int body_origin_y_dip = 130;
  int body_max_width_dip = 650;
  int choice_card_height_dip = 68;
  int choice_gap_dip = 8;
  int theme_card_height_dip = 116;
  int theme_preview_height_dip = 68;
  int theme_swatch_height_dip = 30;
  int control_radius_dip = 8;
  int card_radius_dip = 11;
};

struct SettingsDraft {
  ThemeId theme = ThemeId::kNight;
  ThemeId preview_theme = ThemeId::kNight;
  SettingsPage page = SettingsPage::kInput;
  int subpage = 0;
  int schema_index = 0;
  int theme_index = 0;
  int theme_detail = -1;
  // Keyboard focus: -1 none, 0..4 sidebar, 100+ scheme, 200+ theme.
  int focus = -1;
  bool keyboard_focus = false;
  int hover = -1;
  bool ascii = false;
  bool traditional = false;
  bool ascii_punctuation = false;
  unsigned font_size = 16;
  unsigned candidate_count = 9;
  bool vertical_candidates = false;
  unsigned hotkey_modifiers = MOD_CONTROL | MOD_SHIFT;
  wchar_t hotkey = L'B';
  std::wstring base_url;
  std::wstring model;
  std::wstring target_language = L"English";
  std::wstring api_key;  // fixture / draft only; never loaded from secrets
  std::wstring about_text;
};

struct SettingsLayout {
  float width_dip = 980;
  float height_dip = 680;
  DipRect sidebar{};
  DipRect divider{};
  DipRect content{};
  DipRect subpage_bar{};
  DipRect heading{};
  DipRect body{};
  DipRect status_bar{};
  DipRect save{};
  DipRect close{};
  std::array<DipRect, kSettingsPageCount> nav{};
  std::vector<DipRect> scheme_cards;
  std::vector<DipRect> theme_cards;
  std::vector<DipRect> theme_details;
  DipRect theme_popover{};
  std::array<DipRect, 2> subpage_tabs{};
  DipRect font_edit{};
  DipRect candidate_count_edit{};
  DipRect check_vertical{};
  DipRect hotkey_modifiers{};
  DipRect hotkey_edit{};
  DipRect base_edit{};
  DipRect model_edit{};
  DipRect key_edit{};
  DipRect lang_edit{};
  DipRect check_ascii{};
  DipRect check_trad{};
  DipRect check_punct{};
};

[[nodiscard]] inline float SettingsBodyWidth(float client_width_dip,
                                             const SettingsMetrics& m = {}) {
  const float available =
      client_width_dip - static_cast<float>(m.body_origin_x_dip) - 24.0f;
  return (std::clamp)(available, 320.0f,
                      static_cast<float>(m.body_max_width_dip));
}

[[nodiscard]] inline SettingsLayout LayoutSettings(
    float width_dip, float height_dip, const SettingsDraft& draft,
    const SettingsMetrics& m = {}) {
  SettingsLayout layout;
  width_dip = (std::max)(width_dip, static_cast<float>(m.min_client_width_dip));
  height_dip =
      (std::max)(height_dip, static_cast<float>(m.min_client_height_dip));
  layout.width_dip = width_dip;
  layout.height_dip = height_dip;

  const float side_w = static_cast<float>(m.sidebar_width_dip);
  layout.sidebar = {0, 0, side_w, height_dip};
  layout.divider = {side_w, 0, side_w + 1.0f, height_dip};
  layout.content = {side_w + 1.0f, 0, width_dip, height_dip};
  layout.subpage_bar = {layout.content.left, 0, layout.content.right,
                        static_cast<float>(m.subpage_bar_height_dip)};
  layout.heading = {layout.content.left, layout.subpage_bar.bottom,
                    layout.content.right,
                    layout.subpage_bar.bottom +
                        static_cast<float>(m.heading_band_height_dip)};
  const float body_w = SettingsBodyWidth(width_dip, m);
  layout.body = {static_cast<float>(m.body_origin_x_dip),
                 static_cast<float>(m.body_origin_y_dip),
                 static_cast<float>(m.body_origin_x_dip) + body_w,
                 height_dip - 64.0f};

  const float pad = static_cast<float>(m.sidebar_pad_x_dip);
  float ny = static_cast<float>(m.sidebar_row_y_dip);
  for (int i = 0; i < kSettingsPageCount; ++i) {
    layout.nav[static_cast<std::size_t>(i)] = {
        pad, ny, side_w - pad,
        ny + static_cast<float>(m.sidebar_row_height_dip)};
    ny += static_cast<float>(m.sidebar_row_height_dip + m.sidebar_row_gap_dip);
  }

  float tab_x = layout.content.left + 24.0f;
  for (int i = 0; i < 2; ++i) {
    const float tab_width = 16.0f + 12.0f * static_cast<float>(
        std::char_traits<wchar_t>::length(
            kSettingsSubpageLabels[static_cast<int>(draft.page)][i]));
    layout.subpage_tabs[static_cast<std::size_t>(i)] = {
        tab_x, 13, tab_x + tab_width, 33};
    tab_x += tab_width;
  }
  layout.status_bar = {layout.content.left, height_dip - 30,
                       layout.content.right, height_dip};

  layout.save = {width_dip - 220.0f, height_dip - 66.0f, width_dip - 116.0f,
                 height_dip - 38.0f};
  layout.close = {width_dip - 108.0f, height_dip - 66.0f, width_dip - 24.0f,
                  height_dip - 38.0f};

  const float gap = static_cast<float>(m.choice_gap_dip);
  if (draft.page == SettingsPage::kInput && draft.subpage == 0) {
    const int columns = 3;
    const float card_h = static_cast<float>(m.choice_card_height_dip);
    const float card_w = (body_w - gap * (columns - 1)) / columns;
    layout.scheme_cards.resize(6);
    for (int i = 0; i < 6; ++i) {
      const int row = i / columns;
      const int col = i % columns;
      const float x = layout.body.left + static_cast<float>(col) * (card_w + gap);
      const float y = layout.body.top + static_cast<float>(row) * (card_h + gap);
      layout.scheme_cards[static_cast<std::size_t>(i)] = {x, y, x + card_w,
                                                          y + card_h};
    }
  } else if (draft.page == SettingsPage::kInput) {
    float cy = layout.body.top;
    layout.check_ascii = {layout.body.left, cy, layout.body.left + 220.0f,
                          cy + 24.0f};
    cy += 28.0f;
    layout.check_trad = {layout.body.left, cy, layout.body.left + 220.0f,
                         cy + 24.0f};
    cy += 28.0f;
    layout.check_punct = {layout.body.left, cy, layout.body.left + 220.0f,
                          cy + 24.0f};
  } else if (draft.page == SettingsPage::kAppearance && draft.subpage == 0) {
    const int columns = 2;
    const float card_h = static_cast<float>(m.theme_card_height_dip);
    const float card_w = (body_w - gap) / 2.0f;
    layout.theme_cards.resize(4);
    layout.theme_details.resize(4);
    for (int i = 0; i < 4; ++i) {
      const int row = i / columns;
      const int col = i % columns;
      const float x = layout.body.left + static_cast<float>(col) * (card_w + gap);
      const float y = layout.body.top + 24.0f +
                      static_cast<float>(row) * (card_h + gap);
      layout.theme_cards[static_cast<std::size_t>(i)] = {x, y, x + card_w,
                                                         y + card_h};
      layout.theme_details[static_cast<std::size_t>(i)] = {
          x + card_w - 31, y + card_h - 30, x + card_w - 9, y + card_h - 8};
    }
  } else if (draft.page == SettingsPage::kAppearance) {
    const float fy = layout.body.top;
    layout.font_edit = {layout.body.left + 170.0f, fy, layout.body.left + 250.0f,
                        fy + 26.0f};
    layout.candidate_count_edit = {layout.font_edit.left, fy + 44.f, layout.font_edit.right, fy + 70.f};
    layout.check_vertical = {layout.body.left, fy + 88.f, layout.body.right, fy + 118.f};
  } else if (draft.page == SettingsPage::kBuffer) {
    layout.hotkey_modifiers = {layout.body.left, layout.body.top + 48.0f,
                              layout.body.left + 130.0f, layout.body.top + 74.0f};
    layout.hotkey_edit = {layout.body.left + 142.0f, layout.body.top + 48.0f,
                          layout.body.left + 190.0f, layout.body.top + 74.0f};
  } else if (draft.page == SettingsPage::kApi) {
    float y = layout.body.top;
    auto place = [&](DipRect& edit) {
      edit = {layout.body.left + 200.0f, y, layout.body.right, y + 26.0f};
      y += 40.0f;
    };
    if (draft.subpage == 0) {
      place(layout.base_edit);
      place(layout.model_edit);
      place(layout.lang_edit);
    } else {
      place(layout.key_edit);
    }
  }
  if (draft.page == SettingsPage::kAppearance && draft.subpage == 0 &&
      draft.theme_detail >= 0 && draft.theme_detail < 4) {
    const auto& anchor = layout.theme_details[static_cast<std::size_t>(draft.theme_detail)];
    const float left = (std::clamp)(anchor.right - 260.0f,
                                    layout.content.left + 12.0f, width_dip - 272.0f);
    const float top = (std::min)(anchor.bottom + 8.0f, layout.save.top - 148.0f);
    layout.theme_popover = {left, top, left + 260.0f, top + 136.0f};
  }
  return layout;
}

// The details button owns its region before its parent theme card. This also
// supplies one stable mouse-down/up identity to the production settings host.
[[nodiscard]] inline int HitTestSettings(const SettingsLayout& layout,
                                          float x, float y) noexcept {
  const auto hit = [&](const DipRect& r) {
    return r.width() > 0 && r.height() > 0 && r.contains(x, y);
  };
  if (hit(layout.theme_popover)) return 600;
  for (std::size_t i = 0; i < layout.theme_details.size(); ++i)
    if (hit(layout.theme_details[i])) return 400 + static_cast<int>(i);
  for (std::size_t i = 0; i < layout.nav.size(); ++i)
    if (hit(layout.nav[i])) return static_cast<int>(i);
  for (std::size_t i = 0; i < layout.subpage_tabs.size(); ++i)
    if (hit(layout.subpage_tabs[i])) return 500 + static_cast<int>(i);
  for (std::size_t i = 0; i < layout.scheme_cards.size(); ++i)
    if (hit(layout.scheme_cards[i])) return 100 + static_cast<int>(i);
  for (std::size_t i = 0; i < layout.theme_cards.size(); ++i)
    if (hit(layout.theme_cards[i])) return 200 + static_cast<int>(i);
  if (hit(layout.save)) return 300;
  if (hit(layout.close)) return 301;
  return -1;
}

}  // namespace rimes::windows::ui
