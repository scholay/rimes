import Cocoa

func runCandidatePaginationSmokeTest() -> Bool {
    _ = NSApplication.shared
    var ok = true
    var checkCount = 0
    func check(_ condition: Bool, _ message: String) {
        checkCount += 1
        if !condition { print("FAILED: \(message)"); ok = false }
    }
    let defaults = UserDefaults.standard
    let saved = CandidateWindowMetric.allCases.map { ($0.userDefaultsKey, defaults.object(forKey: $0.userDefaultsKey)) }
    let savedArrangement = defaults.object(forKey: CandidateArrangement.defaultsKey)
    defaults.removeObject(forKey: CandidateArrangement.defaultsKey)
    defer {
        if let savedArrangement { defaults.set(savedArrangement, forKey: CandidateArrangement.defaultsKey) }
        else { defaults.removeObject(forKey: CandidateArrangement.defaultsKey) }
        for (key, value) in saved {
            if let value { defaults.set(value, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }
    }
    func configure(width: Double, count: Int, font: Double = 16) {
        let values = CandidateWindowMetrics.resolvedValues([
            .baseWidth: width, .candidatesPerPage: Double(count),
            .compactCandidateHeight: 32, .compactStripHeight: 40,
            .candidateFontSize: font,
        ])
        // No notifications: these temporary fixtures must not re-open panels.
        for (metric, value) in values { defaults.set(value, forKey: metric.userDefaultsKey) }
    }
    func context(_ texts: [String], last: Bool = true) -> RimeContextModel {
        var result = RimeContextModel()
        result.pageSize = 9
        result.isLastPage = last
        result.candidates = texts.enumerated().map {
            RimeCandidateModel(text: $0.element, comment: "", label: String($0.offset + 1))
        }
        return result
    }
    // The reported case: seven visible candidates and two in the overflow.
    let sevenPlusTwo = CandidatePagination(widths: Array(repeating: 50, count: 9),
        availableWidth: 480, limit: 9, hasEngineNeighbours: false)
    check(sevenPlusTwo.pages == [Array(0..<7), [7, 8]] && sevenPlusTwo.showsControls,
          "seven-plus-two preserves every candidate and exposes paging")
    check(CandidatePagination(widths: Array(repeating: 20, count: 9),
        availableWidth: 800, limit: 5, hasEngineNeighbours: false).pages == [Array(0..<5), Array(5..<9)],
          "configured count caps a page even when all nine would fit")
    for count in [-1, 1, 5, 9, 99] {
        let resolved = CandidateWindowMetrics.resolvedValues([.candidatesPerPage: Double(count)])
        check(resolved[.candidatesPerPage] == Double(min(9, max(1, count))), "candidate count bounds \(count)")
    }
    for key in [RimeKey.pageUp, RimeKey.pageDown, 0x2D, 0x3D, 0x31, 0x39] {
        check(CandidateKeyboardRoutingRules.ownsLocally(keycode: key, isExpanded: false, usesNumericLabels: true),
              "compact visual page owns key \(key)")
    }
    check(!CandidateKeyboardRoutingRules.ownsLocally(keycode: 0x30, isExpanded: false, usesNumericLabels: true),
          "zero keeps its schema binding")
    check(!CandidateKeyboardRoutingRules.ownsLocally(keycode: 0x31, isExpanded: false, usesNumericLabels: false),
          "custom selection-key schemas keep their digit bindings")

    check(CandidateKeyboardRoutingRules.ownsLocally(keycode: RimeKey.escape, isExpanded: true), "expanded Escape belongs to matrix")
    check(!CandidateKeyboardRoutingRules.ownsLocally(keycode: RimeKey.escape, isExpanded: false), "collapsed Escape keeps schema cancellation")
    defaults.set("vertical", forKey: CandidateArrangement.defaultsKey)
    configure(width: 360, count: 5, font: 24)
    let verticalContext = context(["中华人民共和国", "你好", "长候选测试", "测试", "五", "六", "七", "八", "九"])
    for page in 0..<2 {
        let vertical = CandidateWindow.paginationSnapshotForSmoke(context: verticalContext, page: page)
        check(vertical.pages == [Array(0..<5), Array(5..<9)], "vertical pages follow count instead of summed width")
        check(vertical.contentFits, "vertical native buttons fit in panel")
        check(vertical.numberSelections == vertical.visibleIndices, "vertical numeric selection matches visible rows")
    }
    defaults.removeObject(forKey: CandidateArrangement.defaultsKey)

    let output = CommandLine.arguments.first { $0.hasPrefix("--output=") }
        .map { URL(fileURLWithPath: String($0.dropFirst("--output=".count)), isDirectory: true) }
    if let output { try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true) }
    let samples = [
        (1...9).map { "候选\($0)" },
        ["中华人民共和国", "中文", "输入法候选", "你好", "计算宽度", "显示", "下一页", "第八个", "第九个"],
        [String(repeating: "长候选", count: 50), "末尾"],
    ]
    var visualPages = 0
    for width in [360.0, 622, 900] {
        for count in [1, 5, 9] {
            for font in [12.0, 24] {
                configure(width: width, count: count, font: font)
                for texts in samples {
                    let ctx = context(texts)
                    let first = CandidateWindow.paginationSnapshotForSmoke(context: ctx, page: 0)
                    check(first.pages.flatMap { $0 } == Array(texts.indices), "ordered coverage at \(width)/\(count)/\(font)")
                    for page in first.pages.indices {
                        let snapshot = CandidateWindow.paginationSnapshotForSmoke(context: ctx, page: page)
                        visualPages += 1
                        check(snapshot.contentFits, "AppKit buttons and pager fit at \(width)/\(count)/\(font) page \(page)")
                        check(snapshot.visibleIndices == first.pages[page] && snapshot.visibleIndices.count <= count,
                              "render matches partition, within configured limit")
                        check(snapshot.numberSelections == snapshot.visibleIndices && snapshot.rejectsInvisibleNumber,
                              "digits select only the visible candidates")
                        check(snapshot.visibleLabels.enumerated().allSatisfy { $0.element.hasPrefix("\($0.offset + 1) ") },
                              "visible labels restart at one")
                        check(snapshot.canGoBack == (page > 0) && snapshot.canGoForward == (page + 1 < first.pages.count),
                              "first and last visual pages expose correct boundaries")
                    }
                }
            }
        }
    }

    configure(width: 622, count: 5)
    let fixture = context((1...9).map { "候选\($0)" })
    for (message, condition) in CandidateWindow.paginationNavigationChecksForSmoke(context: fixture) {
        check(condition, message)
    }
    for page in 0..<2 {
        _ = CandidateWindow.paginationSnapshotForSmoke(context: fixture, page: page,
            imageURL: output?.appendingPathComponent("candidates-page-\(page + 1).png"))
    }

    var decorated = fixture
    decorated.candidates = fixture.candidates.enumerated().map {
        RimeCandidateModel(text: $0.element.text, comment: "注释", label: ["⒈", "⒉", "⒊", "⒋", "⒌", "⒍", "⒎", "⒏", "⒐"][$0.offset])
    }
    let decoratedTail = CandidateWindow.paginationSnapshotForSmoke(context: decorated, page: 1)
    check(decoratedTail.contentFits && decoratedTail.visibleLabels[0].hasPrefix("1 ")
          && decoratedTail.numberSelections.first == 5, "decorative labels cannot change the numeric selection mapping")
    decorated.usesNumericSelectionKeys = false
    let customKeys = CandidateWindow.paginationSnapshotForSmoke(context: decorated, page: 0)
    check(customKeys.visibleLabels[0].hasPrefix("⒈ "), "custom selection-key labels are preserved")

    // Exercise real librime pages and the exact on-page indices used by the
    // controller. main.swift isolates this command from the live user database.
    let engine = RimeEngine()
    guard engine.start() else { print("FAILED: isolated librime startup"); return false }
    let session = engine.createSession()
    guard session != 0 else { print("FAILED: isolated librime session"); return false }
    defer { engine.destroySession(session) }
    guard engine.selectSchema("rime_ice", session: session) else {
        print("FAILED: isolated rime_ice selection"); return false
    }
    engine.setOption("ascii_mode", false, session: session)
    func typeInput() {
        engine.clearComposition(session: session)
        _ = engine.takeCommit(session: session)
        for scalar in "shi".unicodeScalars { _ = engine.processKey(Int32(scalar.value), session: session) }
    }
    typeInput()
    let original = engine.getContext(session: session)
    print("engine fixture: pageSize=\(original.pageSize) count=\(original.candidates.count) page=\(original.pageNo)")
    check(original.candidates.count == 9 && !original.isLastPage && original.usesNumericSelectionKeys,
          "real engine provides nine numeric candidates and more pages")
    let first = CandidateWindow.paginationSnapshotForSmoke(context: original, page: 0)
    let tail = CandidateWindow.paginationSnapshotForSmoke(context: original, page: first.pages.count - 1)
    check(first.visibleIndices.count == 5 && tail.visibleIndices == [5, 6, 7, 8], "real engine page partitions 5+4")
    check(tail.canGoForward, "engine continuation remains available after visual overflow")
    _ = engine.processKey(RimeKey.pageDown, session: session)
    let next = engine.getContext(session: session)
    check(next.pageNo == original.pageNo + 1, "engine advances only after visual tail")
    _ = engine.processKey(RimeKey.pageUp, session: session)
    let previous = engine.getContext(session: session)
    let previousTail = CandidateWindow.paginationSnapshotForSmoke(context: previous, page: first.pages.count - 1)
    check(previousTail.visibleIndices == tail.visibleIndices && previous.candidates.map(\.text) == original.candidates.map(\.text),
          "reverse engine navigation preserves the previous overflow")
    if let index = tail.numberSelections.first {
        let expected = previous.candidates[index].text
        check(engine.selectCandidate(onPage: index, session: session), "overflow number maps to an accepted engine index")
        check(engine.takeCommit(session: session) == expected, "overflow selection commits exactly the visible word")
    } else { check(false, "missing overflow number mapping") }
    print("candidate-pagination-smoke: \(ok ? "OK" : "FAILED") (\(checkCount) checks, \(visualPages) AppKit pages, isolated librime paging/commit)")
    return ok
}
