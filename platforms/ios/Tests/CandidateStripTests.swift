import XCTest
import UIKit
@testable import RIMES

@MainActor final class CandidateStripTests: XCTestCase {
    private func strip(width: CGFloat = 320, expanded: Bool = false, controls: Bool = false) -> CandidateStrip {
        let strip = CandidateStrip()
        strip.expanded = expanded; strip.landscape = width > 600
        strip.controlInsets = .init(top: 0, left: controls ? 36 : 0, bottom: 0, right: controls ? 36 : 0)
        strip.update(Array(repeating: "候选", count: 60))
        strip.frame = CGRect(x: 0, y: 0, width: width, height: max(32, strip.fittingHeight(width: width)))
        strip.layoutIfNeeded()
        return strip
    }
    private func frame(_ button: CandidateButton, in strip: CandidateStrip) -> CGRect {
        button.convert(button.bounds, to: strip)
    }
    private func center(_ button: CandidateButton, in strip: CandidateStrip) -> CGPoint {
        let rect = frame(button, in: strip)
        return CGPoint(x: rect.midX, y: rect.midY)
    }
    private func visibleIndex(at point: CGPoint, in strip: CandidateStrip) -> Int? {
        strip.buttons.indices.first { frame(strip.buttons[$0], in: strip).contains(point) }
    }

    func testCodeHintsAreSmallerMeasuredAndNeverChangeTheSelectedText() throws {
        let strip = CandidateStrip()
        strip.update(["你", "你好"], comments: ["(wq wqi wqiy)", "(wqvb)"])
        strip.frame = CGRect(x: 0, y: 0, width: 320, height: 32); strip.layoutIfNeeded()
        let plain = CandidateLayout.measure(["你", "你好"], width: 320, expanded: false, landscape: false)
        let button = try XCTUnwrap(strip.buttons.first)
        button.layoutIfNeeded()
        XCTAssertEqual(button.currentTitle, "你")
        XCTAssertEqual(button.accessibilityValue, "(wq wqi wqiy)")
        XCTAssertLessThan(button.commentLabel.font.pointSize, try XCTUnwrap(button.titleLabel?.font.pointSize))
        XCTAssertGreaterThan(button.bounds.width, plain.frames[0].width)
        XCTAssertLessThanOrEqual(button.commentLabel.frame.maxX, button.bounds.width)
        var selected: [Int] = []; strip.onSelect = { selected.append($0) }
        button.sendActions(for: .touchUpInside); XCTAssertEqual(selected, [0])
        strip.update(["你", "你好"], comments: ["(wq)", "(wqvb)"])
        XCTAssertEqual(strip.buttons[0].comment, "(wq)")
        strip.update(["你", "你好"])
        XCTAssertTrue(strip.buttons[0].commentLabel.isHidden)
        XCTAssertNil(strip.buttons[0].accessibilityValue)
    }

    func testMatrixFramesStayFixedThroughoutScrollingAndRelayout() {
        for width: CGFloat in [320, 393, 852] {
            for controls in [false, true] {
                let strip = strip(width: width, expanded: true, controls: controls)
                strip.update((0..<60).map { $0 % 7 == 0 ? "这是一个比较长的候选词" : "词\($0)" })
                strip.layoutIfNeeded()
                let original = strip.buttons.map(\.frame)
                let contentSize = strip.scroll.contentSize
                XCTAssertEqual(strip.scroll.frame.minX, controls ? 36 : 0)
                XCTAssertEqual(strip.scroll.frame.maxX, width - (controls ? 72 : 36))
                let limit = max(0, contentSize.height - strip.scroll.bounds.height)
                for proposed: CGFloat in [1, 15, 29, 30, 33, 34, 49, 68, 102, 201, 10_000, 68, 0] {
                    let offset = min(proposed, limit)
                    strip.scroll.contentOffset.y = offset
                    strip.setNeedsLayout(); strip.layoutIfNeeded()
                    XCTAssertEqual(strip.scroll.contentOffset.y, offset, accuracy: 0.01)
                    XCTAssertEqual(strip.scroll.contentSize, contentSize)
                    XCTAssertEqual(strip.buttons.map(\.frame), original)
                    for button in strip.buttons {
                        let rect = frame(button, in: strip)
                        XCTAssertGreaterThanOrEqual(rect.minX, strip.scroll.frame.minX)
                        XCTAssertLessThanOrEqual(rect.maxX, strip.scroll.frame.maxX)
                        XCTAssertFalse(rect.intersects(strip.expandButton.frame))
                    }
                }
            }
        }
    }

    func testAppendingCandidatesPreservesExistingFramesAndScrollPosition() {
        let strip = strip(expanded: true, controls: true)
        let values = (0..<60).map { "候选\($0)" }
        strip.update(Array(values.prefix(30)), context: "shi")
        strip.layoutIfNeeded()
        strip.scroll.contentOffset.y = 34
        let frames = strip.buttons.map(\.frame)
        strip.update(values, context: "shi")
        strip.layoutIfNeeded()
        XCTAssertEqual(Array(strip.buttons.prefix(30)).map(\.frame), frames)
        XCTAssertEqual(strip.scroll.contentOffset.y, 34)
        strip.update(["新候选"], context: "xin")
        strip.layoutIfNeeded()
        XCTAssertEqual(strip.scroll.contentOffset, .zero)
    }

    func testStableMatrixKeepsEveryWordReachableWhileScrollingForwardAndBackward() {
        let strip = strip(width: 320, expanded: true, controls: true)
        strip.update((0..<60).map { $0 % 7 == 0 ? "这是一个比较长的候选词" : "词\($0)" })
        strip.layoutIfNeeded()
        var seen = Set<Int>()
        let limit = strip.scroll.contentSize.height
        for offset in stride(from: CGFloat(0), through: limit, by: 8) {
            strip.scroll.contentOffset.y = offset
            for index in strip.buttons.indices {
                let rect = frame(strip.buttons[index], in: strip)
                if strip.bounds.contains(rect) { seen.insert(index) }
            }
        }
        XCTAssertEqual(seen, Set(strip.buttons.indices))
        strip.scroll.contentOffset = .zero
        XCTAssertEqual(frame(strip.buttons[0], in: strip).minY, 0)
    }

    func testHoldMagnifiesAndReleaseCommitsTheDraggedTargetExactlyOnce() {
        let strip = strip()
        var selected: [Int] = []; strip.onSelect = { selected.append($0) }
        strip.developmentBeginSelection(at: center(strip.buttons[0], in: strip))
        XCTAssertEqual(strip.selectedIndex, 0)
        strip.buttons[0].layoutIfNeeded()
        XCTAssertGreaterThan(strip.buttons[0].titleLabel!.transform.a, 1)
        // UIKit cancelling the original button's tracking must not erase the drag highlight.
        strip.buttons[0].isHighlighted = false
        XCTAssertNotEqual(strip.buttons[0].backgroundColor, .clear)
        let target = center(strip.buttons[2], in: strip)
        strip.developmentMoveSelection(to: target)
        XCTAssertEqual(strip.selectedIndex, 2); XCTAssertFalse(strip.buttons[0].isDragTarget)
        XCTAssertTrue(selected.isEmpty)
        strip.developmentFinishSelection(at: target)
        strip.developmentFinishSelection(at: target)
        XCTAssertEqual(selected, [2]); XCTAssertNil(strip.selectedIndex)
        strip.buttons[2].layoutIfNeeded()
        XCTAssertEqual(strip.buttons[2].titleLabel!.transform, .identity)
        XCTAssertEqual(strip.buttons[2].backgroundColor, .clear)
        // Ordinary taps and VoiceOver activation continue through the same selection action.
        strip.buttons[1].sendActions(for: .touchUpInside)
        XCTAssertEqual(selected, [2, 1])
    }

    func testHorizontalEdgeScrollRetargetsWithoutLiftingFinger() throws {
        let strip = strip()
        var selected: [Int] = []; strip.onSelect = { selected.append($0) }
        strip.developmentBeginSelection(at: center(strip.buttons[0], in: strip))
        let edge = CGPoint(x: strip.scroll.frame.maxX - 5, y: 15)
        strip.developmentMoveSelection(to: edge)
        for _ in 0..<60 { strip.developmentAdvanceSelection(by: 1.0 / 60) }
        XCTAssertGreaterThan(strip.scroll.contentOffset.x, 150)
        let expected = try XCTUnwrap(visibleIndex(at: edge, in: strip))
        XCTAssertGreaterThan(expected, 5); XCTAssertEqual(strip.selectedIndex, expected)
        strip.developmentFinishSelection(at: edge)
        XCTAssertEqual(selected, [expected])
    }

    func testExpandedEdgeScrollAndPageJumpKeepTargetUnderStationaryFinger() throws {
        let strip = strip(expanded: true)
        var selected: [Int] = []; strip.onSelect = { selected.append($0) }
        strip.developmentBeginSelection(at: center(strip.buttons[0], in: strip))
        let edge = CGPoint(x: 20, y: strip.scroll.frame.maxY - 8)
        strip.developmentMoveSelection(to: edge)
        let before = try XCTUnwrap(strip.selectedIndex)
        for _ in 0..<60 { strip.developmentAdvanceSelection(by: 1.0 / 60) }
        XCTAssertGreaterThan(strip.scroll.contentOffset.y, 100)
        // Scrolling by a page, including from accessibility, re-hits the current point.
        strip.scroll.contentOffset.y = 5 * 34
        let expected = try XCTUnwrap(visibleIndex(at: edge, in: strip))
        XCTAssertGreaterThan(expected, before); XCTAssertEqual(strip.selectedIndex, expected)
        strip.developmentFinishSelection(at: edge)
        XCTAssertEqual(selected, [expected])
        let offset = strip.scroll.contentOffset
        strip.developmentAdvanceSelection(by: 1)
        XCTAssertEqual(strip.scroll.contentOffset, offset)
    }

    func testDragCanReturnAcrossRowsAndScrollBackToTheStart() throws {
        let strip = strip(expanded: true)
        strip.scroll.contentOffset.y = 170
        let firstBody = CGPoint(x: 20, y: strip.scroll.frame.minY + 5)
        strip.developmentBeginSelection(at: firstBody)
        XCTAssertNotNil(strip.selectedIndex)
        for _ in 0..<120 { strip.developmentAdvanceSelection(by: 1.0 / 60) }
        XCTAssertEqual(strip.scroll.contentOffset.y, 0)
        let first = center(strip.buttons[0], in: strip)
        strip.developmentMoveSelection(to: first)
        XCTAssertEqual(strip.selectedIndex, 0)
        strip.cancelSelection()
    }

    func testOutsideReleaseControlsAndCancelledOrReplacedListsNeverCommit() {
        for reason in 0..<6 {
            let strip = strip(expanded: true, controls: true)
            var selected: [Int] = []; strip.onSelect = { selected.append($0) }
            let first = center(strip.buttons[0], in: strip)
            strip.developmentBeginSelection(at: first)
            switch reason {
            case 0: strip.developmentFinishSelection(at: CGPoint(x: 10, y: strip.bounds.maxY + 20))
            case 1: strip.cancelSelection()
            case 2: strip.update(["新的候选"])
            case 3: strip.update(Array(repeating: "候选", count: 60), context: "different composition")
            case 4: strip.expanded = false
            default: strip.removeFromSuperview(); strip.didMoveToWindow()
            }
            strip.developmentFinishSelection(at: first)
            XCTAssertTrue(selected.isEmpty, "Cancellation \(reason)")
            XCTAssertNil(strip.selectedIndex)
            XCTAssertFalse(strip.buttons.contains { $0.isDragTarget })
        }
        let strip = strip(expanded: true, controls: true)
        for point in [CGPoint(x: 10, y: 15), CGPoint(x: strip.bounds.maxX - 10, y: 15), center(strip.expandButton, in: strip)] {
            strip.developmentBeginSelection(at: point)
            XCTAssertNil(strip.selectedIndex)
        }
    }

    func testHeldCandidateSurvivesUnchangedRenderButNotRotation() {
        let strip = strip()
        let first = center(strip.buttons[0], in: strip)
        strip.developmentBeginSelection(at: first)
        strip.update(Array(repeating: "候选", count: 60))
        strip.setNeedsLayout(); strip.layoutIfNeeded()
        XCTAssertEqual(strip.selectedIndex, 0)
        strip.frame.size.width = 852; strip.layoutIfNeeded()
        XCTAssertNil(strip.selectedIndex)
    }

    func testReuseUpdatesWordsAndAccessibilityButRetiresTouchedAndRemovedCandidates() {
        let strip = strip()
        let reused = strip.buttons[0], touched = strip.buttons[1], removed = strip.buttons[59]
        var selected = [Int](); strip.onSelect = { selected.append($0) }
        touched.isHighlighted = true
        strip.update(["新的首选", "第二词", "长一点的候选词"], context: "next composition")
        strip.layoutIfNeeded()
        XCTAssertTrue(strip.buttons[0] === reused)
        XCTAssertFalse(strip.buttons[1] === touched)
        XCTAssertEqual(reused.currentTitle, "新的首选")
        XCTAssertEqual(reused.accessibilityLabel, "新的首选")
        XCTAssertEqual(strip.buttons.count, 3)
        touched.sendActions(for: .touchUpInside)
        removed.sendActions(for: .touchUpInside)
        XCTAssertTrue(selected.isEmpty)
        reused.sendActions(for: .touchUpInside)
        XCTAssertEqual(selected, [0])
        strip.update([]); reused.sendActions(for: .touchUpInside)
        XCTAssertEqual(selected, [0])
        XCTAssertEqual(strip.fittingHeight(width: 320), 0)
    }

    func testSelectionFeedbackChangesWithTargetAndScrollButDoesNotRepeatWhileStill() throws {
        let strip = strip(expanded: true)
        var changes = 0; strip.onSelectionChanged = { changes += 1 }
        let first = center(strip.buttons[0], in: strip)
        strip.developmentBeginSelection(at: first)
        XCTAssertEqual(changes, 1)
        for _ in 0..<5 { strip.developmentMoveSelection(to: first); strip.developmentAdvanceSelection(by: 0.01) }
        XCTAssertEqual(changes, 1)
        let next = center(strip.buttons[1], in: strip)
        strip.developmentMoveSelection(to: next); XCTAssertEqual(changes, 2)
        strip.developmentMoveSelection(to: CGPoint(x: -20, y: 15))
        strip.developmentMoveSelection(to: next); XCTAssertEqual(changes, 2) // leaving/re-entering the same word
        strip.scroll.contentOffset.y = 3 * 34
        XCTAssertNotEqual(strip.selectedIndex, 1); XCTAssertEqual(changes, 3)
        strip.developmentMoveSelection(to: next); XCTAssertEqual(changes, 3)
        strip.cancelSelection(); XCTAssertEqual(changes, 3)
        strip.developmentBeginSelection(at: next); XCTAssertEqual(changes, 4) // new hold, even on the same word
        strip.cancelSelection()
    }
}
