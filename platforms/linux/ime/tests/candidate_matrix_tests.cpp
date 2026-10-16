#include "fcitx/candidate_navigation.hpp"
#include <cstdlib>
#include <iostream>

int main() {
    using Page = rimes::linuxime::EngineSnapshot;
    std::vector<Page> pages(6);
    for (int row = 0; row < 6; ++row) {
        auto& page = pages[row]; page.page_no = row; page.page_size = 9; page.highlighted = 0; page.raw_input = "shi"; page.is_last_page = row == 5;
        for (int col = 0; col < (row == 5 ? 2 : 9); ++col) page.candidates.push_back({std::to_string(row * 9 + col), "", std::to_string(col + 1)});
    }
    auto check = [](bool valid, const char* name) { if (!valid) { std::cerr << name << '\n'; std::exit(1); } };
    int engine = 0;
    auto step = [&](int delta) -> std::optional<Page> { engine = std::clamp(engine + delta, 0, 5); return pages[engine]; };
    fcitx::CandidateNavigation nav; nav.Reset(pages[0]); nav.MoveColumn(2);
    check(nav.MoveRow(1, step) && nav.expanded() && nav.end() == 3 && engine == 0, "preview must restore engine");
    for (int row = 1; row < 6; ++row) {
        check(nav.MoveRow(1, step) && static_cast<int>(nav.row()) == row && engine == row, "navigate past viewport");
        check(nav.end() - nav.base() <= 3, "three visible rows");
    }
    check(nav.column() == 1 && !nav.Selected(8), "short tail clamps selection and rejects hidden numbers");
    check(nav.MoveRow(1, step) && engine == 5 && nav.row() == 5, "tail must not duplicate");
    check(nav.CollapseToAnchor(step) && engine == 0 && !nav.expanded(), "Escape restores anchor");
    check(nav.MoveRow(1, step) && nav.SelectVisibleIndex(19, step) && engine == 2 && nav.Selected()->index == 1, "mouse maps page and local index");
    nav.Reset({}); check(nav.empty() && !nav.Selected(), "focus retirement drops stale selection");
    nav.Reset(pages[0]);
    int calls = 0;
    auto retired = [&](int) -> std::optional<Page> {
        if (++calls == 1) return pages[1];
        nav.Reset({}); return std::nullopt;
    };
    check(!nav.MoveRow(1, retired) && calls == 2 && nav.empty(), "retirement must not send a restoring key");
    nav.Reset(pages[0]); calls = 0;
    auto failed = [&](int) -> std::optional<Page> {
        if (++calls == 1) return pages[1];
        return std::nullopt;
    };
    check(!nav.MoveRow(1, failed) && calls == 2, "transport failure stops preview immediately");
    engine = 0; nav.Reset(pages[0]); nav.MoveRow(1, step); nav.MoveRow(1, step);
    auto replaced = [&](int) -> std::optional<Page> { nav.Reset(pages[0]); return pages[0]; };
    check(!nav.CollapseToAnchor(replaced) && !nav.expanded(), "collapse cannot reuse a replaced context");
    engine = 0; nav.MoveRow(1, step);
    check(!nav.SelectVisibleIndex(19, replaced) && nav.row() == 0, "selection cannot reuse a replaced context");
    std::cout << "candidate matrix navigation OK\n";
}
