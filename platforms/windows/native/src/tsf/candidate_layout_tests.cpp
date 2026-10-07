#include "../ui/buffer_layout.hpp"
#include "../ui/candidate_strip.hpp"
#include "../ui/theme.hpp"
#include "candidate_layout.hpp"

#include <cstdlib>
#include <iostream>
#include <string>
#include <vector>

namespace rimes::windows::tsf::tests {
namespace {

using rimes::windows::ui::BufferPaintState;
using rimes::windows::ui::HitTestCandidateStrip;
using rimes::windows::ui::LayoutBuffer;
using rimes::windows::ui::LayoutCandidateStripMeasured;
using rimes::windows::ui::Palette;
using rimes::windows::ui::ParseThemeId;
using rimes::windows::ui::ScaleDip;
using rimes::windows::ui::ThemeId;
using rimes::windows::ui::ThemeIdOrDefault;
using rimes::windows::ui::CandidateStripItem;
using rimes::windows::ui::CandidateStripMetrics;
using rimes::windows::tsf::HasVisibleCaret;
using rimes::windows::tsf::ResolveCandidateCaret;

int g_failures = 0;

void Check(bool condition, const char* message) {
  if (!condition) {
    std::cerr << "FAIL: " << message << '\n';
    ++g_failures;
  }
}

void TestPrefersBelowCaret() {
  const ScreenRect caret{100, 200, 140, 224};
  const ScreenRect work{0, 0, 1920, 1080};
  const ScreenPoint origin = PlaceCandidateWindow(caret, 320, 180, work);
  Check(origin.x == 100, "window should align with the caret left edge");
  Check(origin.y == 230, "window should sit just below the caret");
}

void TestFlipsAboveWhenNeeded() {
  const ScreenRect caret{100, 1000, 140, 1024};
  const ScreenRect work{0, 0, 1920, 1080};
  const ScreenPoint origin = PlaceCandidateWindow(caret, 320, 180, work);
  Check(origin.y == 814, "window should flip above the caret near the bottom");
}

void TestClampsToWorkArea() {
  const ScreenRect caret{1800, 100, 1900, 124};
  const ScreenRect work{0, 0, 1920, 1080};
  const ScreenPoint origin = PlaceCandidateWindow(caret, 400, 180, work);
  Check(origin.x == 1520, "window should stay inside the right work-area edge");
}

void TestDpiScale() {
  Check(ScaleForDpi(16, 96) == 16, "96 DPI should be identity");
  Check(ScaleForDpi(16, 144) == 24, "150% DPI should scale by 1.5");
  Check(ScaleForDpi(16, 192) == 32, "200% DPI should scale by 2");
  Check(ScaleDip(34, 96) == 34, "strip height DIP identity");
  Check(ScaleDip(34, 144) == 51, "strip height at 150%");
  Check(ScaleDip(34, 192) == 68, "strip height at 200%");
}

void TestCollapsedCaretAndSelectionLabels() {
  const auto origin = PlaceCandidateWindow({120, 180, 120, 204}, 320, 180,
                                           {0, 0, 1920, 1080});
  Check(origin.x == 120 && origin.y == 210,
        "zero-width TSF caret must remain anchored at the input field");
  Check(CandidateSelectionKey(L"", 2) == L'3',
        "unlabelled candidate must use the displayed numeric key");
  Check(CandidateSelectionKey(L"2", 0) == L'2',
        "explicit numeric label must take precedence");
  Check(CandidateSelectionKey(L"", 9) == 0 &&
            CandidateSelectionKey(L"x", 0) == 0,
        "unsupported labels must not synthesize another candidate key");
}

void TestUnknownCaretReusesPreviousPlacement() {
  // A host mid-composition can refuse every caret source, yielding an
  // all-zero rectangle. Passing that to PlaceCandidateWindow would anchor the
  // popup to the work-area origin, which is the visible jump to the screen
  // corner. The previous placement must win instead.
  ScreenRect resolved{};
  Check(ResolveCandidateCaret({420, 300, 460, 324}, {0, 0, 0, 0}, &resolved),
        "a successful query always wins");
  Check(resolved.left == 420 && resolved.bottom == 324,
        "the queried caret is used verbatim");

  Check(ResolveCandidateCaret({0, 0, 0, 0}, {420, 300, 460, 324}, &resolved),
        "an unknown caret falls back to the previous placement");
  Check(resolved.left == 420 && resolved.top == 300,
        "the popup stays next to the input field instead of jumping to (0, 0)");
  const auto origin =
      PlaceCandidateWindow(resolved, 320, 180, {0, 0, 1920, 1080});
  Check(origin.x == 420 && origin.y == 330,
        "the reused placement renders at the previous caret, not the corner");

  Check(!ResolveCandidateCaret({0, 0, 0, 0}, {0, 0, 0, 0}, &resolved),
        "no caret has ever been observed, so the popup must stay suppressed");

  Check(HasVisibleCaret({120, 180, 120, 204}),
        "a collapsed zero-width caret still identifies a visible position");
  Check(!HasVisibleCaret({0, 0, 0, 0}),
        "an all-zero rectangle is unknown geometry, not a caret");
  Check(!HasVisibleCaret({100, 200, 140, 200}),
        "a rectangle with no height carries no caret information");
  Check(!ResolveCandidateCaret({0, 0, 0, 0}, {100, 200, 100, 200}, &resolved),
        "a flat previous caret cannot stand in for a real one");
  Check(!ResolveCandidateCaret({420, 300, 460, 324}, {100, 200, 140, 224},
                               nullptr),
        "a null output is rejected rather than written");
}

void TestThemeDefaults() {
  Check(ThemeIdOrDefault("night") == ThemeId::kNight, "night parses");
  Check(ThemeIdOrDefault("day") == ThemeId::kDay, "day parses");
  Check(ThemeIdOrDefault("quiet") == ThemeId::kQuiet, "quiet parses");
  Check(ThemeIdOrDefault("rasta") == ThemeId::kRasta, "rasta parses");
  Check(ThemeIdOrDefault("unknown") == ThemeId::kNight,
        "unknown theme falls back to night");
  Check(!ParseThemeId("neon").has_value(), "unknown theme fails validation");
  Check(Palette(ThemeId::kNight).settings_background == 0x323232,
        "night settings background");
  Check(Palette(ThemeId::kDay).settings_background == 0xECECEC,
        "day settings background");
  Check(Palette(ThemeId::kNight).selection == 0x15803D, "night selection");
  Check(Palette(ThemeId::kDay).selection == 0x0F6A3F, "day selection");
}

void TestHorizontalWrapAndHits() {
  CandidateStripMetrics metrics;
  std::vector<CandidateStripItem> items;
  for (int i = 0; i < 9; ++i) {
    CandidateStripItem item;
    item.label = std::to_wstring(i + 1);
    item.text = L"候选项内容偏长";
    item.content_width_dip = 90;
    items.push_back(item);
  }
  const auto layout =
      LayoutCandidateStripMeasured(items, 80.0f, true, metrics, 320.0f);
  Check(layout.row_count >= 2, "narrow monitor must wrap into extra rows");
  Check(layout.pills.size() == 9, "wrapping must keep every selectable entry");
  Check(layout.show_preedit, "preedit pill is present");
  Check(layout.width_dip <= 320.0f + 0.01f, "width clamps to available");
  for (std::size_t i = 0; i < layout.pills.size(); ++i) {
    const auto& pill = layout.pills[i];
    const float cx = (pill.left + pill.right) * 0.5f;
    const float cy = (pill.top + pill.bottom) * 0.5f;
    Check(HitTestCandidateStrip(layout, cx, cy) == static_cast<int>(i),
          "painted pill must map to the same logical index");
  }
  Check(HitTestCandidateStrip(layout, -1, -1) < 0, "miss outside returns -1");
}

void TestLongTextDoesNotDropIndex() {
  CandidateStripMetrics metrics;
  std::vector<CandidateStripItem> items(3);
  items[0].content_width_dip = 40;
  items[1].content_width_dip = 800;
  items[2].content_width_dip = 40;
  const auto layout =
      LayoutCandidateStripMeasured(items, 0, false, metrics, 460.0f);
  Check(layout.pills.size() == 3, "long text still yields three hit targets");
  Check(layout.row_count >= 2, "oversized pill forces a new row");
  for (const auto& pill : layout.pills)
    Check(pill.left >= 0 && pill.right <= layout.width_dip,
          "long candidates stay inside their actual clickable viewport");
  Check(HitTestCandidateStrip(
            layout, (layout.pills[1].left + layout.pills[1].right) * 0.5f,
            (layout.pills[1].top + layout.pills[1].bottom) * 0.5f) == 1,
        "page index 1 remains hittable after clip");
}

void TestNarrowViewportAndLargeFont() {
  for (const float width : {16.f, 100.f, 240.f, 460.f}) {
    const auto metrics = ui::MakeCandidateMetrics(40);
    std::vector<CandidateStripItem> items(3);
    items[0].content_width_dip = 800;
    items[1].content_width_dip = 32;
    items[2].content_width_dip = 48;
    const auto layout = LayoutCandidateStripMeasured(items, 200, true, metrics, width);
    Check(layout.width_dip <= width, "small work area bounds the popup");
    Check(metrics.pill_height_dip >= metrics.candidate_font_dip + 4,
          "large text fits inside the pill");
    for (std::size_t i = 0; i < layout.pills.size(); ++i) {
      const auto& r = layout.pills[i];
      Check(r.left >= 0 && r.right <= layout.width_dip &&
                r.top >= 0 && r.bottom <= layout.height_dip,
            "every hit rectangle is visible inside the popup");
      for (const unsigned dpi : {96U, 144U, 192U}) {
        const float scale = static_cast<float>(dpi) / 96.f;
        const float x = (r.left + r.right) * .5f * scale;
        const float y = (r.top + r.bottom) * .5f * scale;
        Check(HitTestCandidateStrip(layout, x / scale, y / scale) == static_cast<int>(i),
              "DPI conversion preserves logical candidate identity");
      }
    }
    Check(HitTestCandidateStrip(layout, layout.width_dip + 1, layout.pills[0].top + 1) < 0,
          "invisible candidate text cannot receive a click");
  }
  const auto preedit = LayoutCandidateStripMeasured({}, 200, true, {}, 100);
  Check(preedit.row_count == 0 && preedit.height_dip == preedit.preedit.bottom,
        "preedit without candidates does not draw an empty strip");
  const auto origin = PlaceCandidateWindow({100, 100, 100, 124}, 200, 100,
                                          {0, 0, 1920, 1080}, ScaleDip(6, 144));
  Check(origin.y == 133, "caret gap scales to nine pixels at 150 percent");
}

void TestBufferLayoutBounds() {
  BufferPaintState state;
  state.source_blocks = {{L"a", false}};
  auto layout = LayoutBuffer(state, 400);
  Check(layout.width_dip == 520, "buffer width floors at 520");
  layout = LayoutBuffer(state, 2000);
  Check(layout.width_dip == 1100, "buffer width caps at 1100");
  layout = LayoutBuffer(state, 760);
  Check(layout.height_dip == 73, "ordinary expanded height");
  state.translate = true;
  state.result_blocks = {{L"b", false}};
  layout = LayoutBuffer(state, 760);
  Check(layout.height_dip == 105, "translation expanded height");
  BufferPaintState empty;
  layout = LayoutBuffer(empty, 760);
  Check(layout.height_dip == 73, "empty expanded Buffer keeps its source rail");
  empty.folded = true;
  layout = LayoutBuffer(empty, 760);
  Check(layout.height_dip == 35, "toolbar-only height");
}

}  // namespace

int RunCandidateLayoutTests() {
  TestPrefersBelowCaret();
  TestFlipsAboveWhenNeeded();
  TestClampsToWorkArea();
  TestDpiScale();
  TestCollapsedCaretAndSelectionLabels();
  TestUnknownCaretReusesPreviousPlacement();
  TestThemeDefaults();
  TestHorizontalWrapAndHits();
  TestLongTextDoesNotDropIndex();
  TestNarrowViewportAndLargeFont();
  TestBufferLayoutBounds();
  return g_failures == 0 ? EXIT_SUCCESS : EXIT_FAILURE;
}

}  // namespace rimes::windows::tsf::tests

int main() {
  return rimes::windows::tsf::tests::RunCandidateLayoutTests();
}
