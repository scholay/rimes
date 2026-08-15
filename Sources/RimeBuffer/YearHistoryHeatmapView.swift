import AppKit
import Foundation

/// A horizontally growing, seven-row calendar heatmap. The view deliberately
/// owns no scroll view: its intrinsic width represents the entire history so a
/// settings page can place it inside one horizontal NSScrollView.
final class YearHistoryHeatmapView: NSView {
    enum IntensityNormalization: Equatable {
        case squareRoot
        case logarithmic
    }

    struct DayCell: Equatable {
        let dayKey: String
        let total: Int
        let weekIndex: Int
        /// Monday = 0, Sunday = 6.
        let weekdayIndex: Int
    }

    struct Layout: Equatable {
        let cells: [DayCell]
        let weekCount: Int
        let firstDayKey: String?
        let lastDayKey: String?
        let maxDayTotal: Int

        static let empty = Layout(cells: [],
                                  weekCount: 0,
                                  firstDayKey: nil,
                                  lastDayKey: nil,
                                  maxDayTotal: 0)
    }

    struct MonthMarker: Equatable {
        let monthKey: String
        let title: String
        let weekIndex: Int
    }

    var snapshot: KeyFrequencyHistorySnapshot = .empty {
        didSet { rebuildLayout() }
    }

    var normalization: IntensityNormalization = .squareRoot {
        didSet {
            guard normalization != oldValue else { return }
            needsDisplay = true
        }
    }

    /// Called only for a real calendar cell between the first and last recorded
    /// day. Missing days inside that interval are selectable with a total of 0.
    var onSelectDay: ((String) -> Void)?

    private enum Metrics {
        static let cellSize: CGFloat = 12
        static let spacing: CGFloat = 3
        static let leading: CGFloat = 32
        static let trailing: CGFloat = 12
        static let top: CGFloat = 28
        static let bottom: CGFloat = 30
        static let minimumWidth: CGFloat = 360
    }

    private static let weekdayTitles = ["一", "二", "三", "四", "五", "六", "日"]
    private var calendarLayout: Layout = .empty
    private var cellsByPosition: [Int: DayCell] = [:]
    private var trackingAreaReference: NSTrackingArea?
    private var hoveredDayKey: String?
    private var hoveredDayTotal: Int?
    private var lastMousePoint: NSPoint?

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        guard calendarLayout.weekCount > 0 else {
            return NSSize(width: Metrics.minimumWidth,
                          height: Metrics.top + gridHeight + Metrics.bottom)
        }
        let gridWidth = Self.gridSize(weekCount: calendarLayout.weekCount,
                                      cellSize: Metrics.cellSize,
                                      spacing: Metrics.spacing).width
        return NSSize(width: max(Metrics.minimumWidth,
                                 Metrics.leading + gridWidth + Metrics.trailing),
                      height: Metrics.top + gridHeight + Metrics.bottom)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureView()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaReference { removeTrackingArea(trackingAreaReference) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaReference = area
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        updateHover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        lastMousePoint = nil
        setHoveredCell(nil)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        updateHover(at: point)
        guard let cell = cell(at: point) else { return }
        onSelectDay?(cell.dayKey)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.clear.setFill()
        dirtyRect.fill()

        guard !calendarLayout.cells.isEmpty else {
            drawEmptyState()
            return
        }

        drawMonthLabels()
        drawWeekdayLabels()
        for cell in calendarLayout.cells {
            let rect = Self.cellFrame(weekIndex: cell.weekIndex,
                                      weekdayIndex: cell.weekdayIndex,
                                      origin: gridOrigin,
                                      cellSize: Metrics.cellSize,
                                      spacing: Metrics.spacing)
            if rect.intersects(dirtyRect) { draw(cell, in: rect) }
        }
        drawLegend()
    }

    /// Builds a complete daily sequence from the first valid recorded date to
    /// the last one, while retaining partial first/last week columns.
    static func makeLayout(snapshot: KeyFrequencyHistorySnapshot) -> Layout {
        guard snapshot.days.count <= LocalMetricsValidation.maximumHistoryDays else {
            return .empty
        }
        let calendar = historyCalendar
        var values: [String: (date: Date, total: Int)] = [:]
        for item in snapshot.days {
            guard let date = parseDayKey(item.dayKey, calendar: calendar) else { continue }
            let normalizedKey = dayKey(for: date, calendar: calendar)
            let addition = max(0, item.total)
            if let old = values[normalizedKey] {
                let combined = addition >= Int.max - old.total
                    ? Int.max
                    : old.total + addition
                values[normalizedKey] = (date, combined)
            } else {
                values[normalizedKey] = (date, addition)
            }
        }

        let ordered = values.values.sorted { $0.date < $1.date }
        guard let first = ordered.first?.date,
              let last = ordered.last?.date else { return .empty }
        guard let recordedSpan = calendar.dateComponents([.day],
                                                         from: first,
                                                         to: last).day,
              recordedSpan >= 0,
              recordedSpan < LocalMetricsValidation.maximumHistoryDays else {
            return .empty
        }

        let weekday = calendar.component(.weekday, from: first)
        let daysFromMonday = (weekday - calendar.firstWeekday + 7) % 7
        guard let firstWeekStart = calendar.date(byAdding: .day,
                                                 value: -daysFromMonday,
                                                 to: first),
              let span = calendar.dateComponents([.day],
                                                 from: firstWeekStart,
                                                 to: last).day else {
            return .empty
        }

        var cells: [DayCell] = []
        var cursor = first
        while cursor <= last {
            let key = dayKey(for: cursor, calendar: calendar)
            let offset = calendar.dateComponents([.day],
                                                 from: firstWeekStart,
                                                 to: cursor).day ?? 0
            cells.append(DayCell(dayKey: key,
                                 total: values[key]?.total ?? 0,
                                 weekIndex: max(0, offset / 7),
                                 weekdayIndex: max(0, offset % 7)))
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor),
                  next > cursor else { break }
            cursor = next
        }

        return Layout(cells: cells,
                      weekCount: max(1, span / 7 + 1),
                      firstDayKey: cells.first?.dayKey,
                      lastDayKey: cells.last?.dayKey,
                      maxDayTotal: cells.map(\.total).max() ?? 0)
    }

    /// Five levels, 0...4. Level 0 is an empty day; every positive value is at
    /// least level 1 and the maximum is level 4.
    static func intensityLevel(total: Int,
                               maxTotal: Int,
                               normalization: IntensityNormalization = .squareRoot) -> Int {
        guard total > 0 else { return 0 }
        let denominator = max(total, maxTotal)
        guard denominator > 0 else { return 0 }
        let fraction = min(1, max(0, Double(total) / Double(denominator)))
        let normalized: Double
        switch normalization {
        case .squareRoot:
            normalized = sqrt(fraction)
        case .logarithmic:
            normalized = log1p(Double(total)) / log1p(Double(denominator))
        }
        if normalized <= 0.25 { return 1 }
        if normalized <= 0.50 { return 2 }
        if normalized <= 0.75 { return 3 }
        return 4
    }

    static func gridSize(weekCount: Int,
                         cellSize: CGFloat,
                         spacing: CGFloat) -> CGSize {
        guard weekCount > 0 else { return .zero }
        let safeCellSize = max(0, cellSize)
        let safeSpacing = max(0, spacing)
        return CGSize(width: CGFloat(weekCount) * safeCellSize
                        + CGFloat(max(0, weekCount - 1)) * safeSpacing,
                      height: 7 * safeCellSize + 6 * safeSpacing)
    }

    static func cellFrame(weekIndex: Int,
                          weekdayIndex: Int,
                          origin: CGPoint,
                          cellSize: CGFloat,
                          spacing: CGFloat) -> CGRect {
        let pitch = max(0, cellSize) + max(0, spacing)
        return CGRect(x: origin.x + CGFloat(max(0, weekIndex)) * pitch,
                      y: origin.y + CGFloat(min(6, max(0, weekdayIndex))) * pitch,
                      width: max(0, cellSize),
                      height: max(0, cellSize))
    }

    static func monthMarkers(layout: Layout) -> [MonthMarker] {
        var markers: [MonthMarker] = []
        var previousMonth: String?
        for cell in layout.cells {
            let monthKey = String(cell.dayKey.prefix(7))
            guard monthKey != previousMonth else { continue }
            let parts = monthKey.split(separator: "-")
            guard parts.count == 2, let month = Int(parts[1]) else { continue }
            let includeYear = previousMonth == nil || month == 1
            let title = includeYear
                ? "\(parts[0])年\(month)月"
                : "\(month)月"
            markers.append(MonthMarker(monthKey: monthKey,
                                       title: title,
                                       weekIndex: cell.weekIndex))
            previousMonth = monthKey
        }
        return markers
    }

    private var gridOrigin: CGPoint {
        CGPoint(x: Metrics.leading, y: Metrics.top)
    }

    private var gridHeight: CGFloat {
        Self.gridSize(weekCount: max(1, calendarLayout.weekCount),
                      cellSize: Metrics.cellSize,
                      spacing: Metrics.spacing).height
    }

    private func configureView() {
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .vertical)
        rebuildLayout()
    }

    private func rebuildLayout() {
        calendarLayout = Self.makeLayout(snapshot: snapshot)
        cellsByPosition = Dictionary(uniqueKeysWithValues: calendarLayout.cells.map {
            ($0.weekIndex * 7 + $0.weekdayIndex, $0)
        })
        invalidateIntrinsicContentSize()
        needsDisplay = true
        if let lastMousePoint {
            updateHover(at: lastMousePoint)
        } else {
            setHoveredCell(nil)
        }
    }

    private func cell(at point: CGPoint) -> DayCell? {
        guard calendarLayout.weekCount > 0 else { return nil }
        let pitch = Metrics.cellSize + Metrics.spacing
        let localX = point.x - gridOrigin.x
        let localY = point.y - gridOrigin.y
        guard localX >= 0, localY >= 0 else { return nil }
        let week = Int(floor(localX / pitch))
        let weekday = Int(floor(localY / pitch))
        guard week >= 0, week < calendarLayout.weekCount,
              weekday >= 0, weekday < 7,
              localX - CGFloat(week) * pitch <= Metrics.cellSize,
              localY - CGFloat(weekday) * pitch <= Metrics.cellSize else {
            return nil
        }
        return cellsByPosition[week * 7 + weekday]
    }

    private func updateHover(at point: CGPoint) {
        lastMousePoint = point
        setHoveredCell(cell(at: point))
    }

    private func setHoveredCell(_ cell: DayCell?) {
        let nextKey = cell?.dayKey
        let nextTotal = cell?.total
        guard nextKey != hoveredDayKey
                || nextTotal != hoveredDayTotal
                || (cell == nil && toolTip != nil) else { return }
        hoveredDayKey = nextKey
        hoveredDayTotal = nextTotal
        if let cell {
            let count = NumberFormatter.localizedString(
                from: NSNumber(value: cell.total),
                number: .decimal
            )
            toolTip = "\(cell.dayKey) · \(count) 次"
        } else {
            toolTip = nil
        }
        needsDisplay = true
    }

    private func draw(_ cell: DayCell, in rect: CGRect) {
        let level = Self.intensityLevel(total: cell.total,
                                        maxTotal: calendarLayout.maxDayTotal,
                                        normalization: normalization)
        let path = NSBezierPath(roundedRect: rect, xRadius: 2.5, yRadius: 2.5)
        color(for: level).setFill()
        path.fill()

        if hoveredDayKey == cell.dayKey {
            RimeUI.accentGreen.setStroke()
            path.lineWidth = 1.5
            path.stroke()
        } else if level == 0 {
            RimeUI.border.setStroke()
            path.lineWidth = 0.5
            path.stroke()
        }
    }

    private func drawMonthLabels() {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium),
            .foregroundColor: RimeUI.textSecondary,
        ]
        var lastMaxX: CGFloat = -CGFloat.greatestFiniteMagnitude
        let pitch = Metrics.cellSize + Metrics.spacing
        for marker in Self.monthMarkers(layout: calendarLayout) {
            let text = marker.title as NSString
            let size = text.size(withAttributes: attributes)
            let x = gridOrigin.x + CGFloat(marker.weekIndex) * pitch
            guard x >= lastMaxX + 5 else { continue }
            text.draw(in: CGRect(x: x, y: 5, width: size.width, height: size.height),
                      withAttributes: attributes)
            lastMaxX = x + size.width
        }
    }

    private func drawWeekdayLabels() {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9, weight: .regular),
            .foregroundColor: RimeUI.textMuted,
        ]
        let pitch = Metrics.cellSize + Metrics.spacing
        for (row, title) in Self.weekdayTitles.enumerated() {
            let text = title as NSString
            let size = text.size(withAttributes: attributes)
            let rect = CGRect(x: gridOrigin.x - 18,
                              y: gridOrigin.y + CGFloat(row) * pitch
                                + (Metrics.cellSize - size.height) / 2,
                              width: 12,
                              height: size.height)
            text.draw(in: rect, withAttributes: attributes)
        }
    }

    private func drawLegend() {
        let labelAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9),
            .foregroundColor: RimeUI.textMuted,
        ]
        let less = "少" as NSString
        let more = "多" as NSString
        let lessSize = less.size(withAttributes: labelAttributes)
        let moreSize = more.size(withAttributes: labelAttributes)
        let box: CGFloat = 9
        let gap: CGFloat = 3
        let boxesWidth = box * 5 + gap * 4
        let totalWidth = lessSize.width + 5 + boxesWidth + 5 + moreSize.width
        var x = max(gridOrigin.x, intrinsicContentSize.width - Metrics.trailing - totalWidth)
        let y = gridOrigin.y + gridHeight + 10
        less.draw(in: CGRect(x: x, y: y, width: lessSize.width, height: lessSize.height),
                  withAttributes: labelAttributes)
        x += lessSize.width + 5
        for level in 0...4 {
            let rect = CGRect(x: x, y: y, width: box, height: box)
            color(for: level).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()
            x += box + gap
        }
        x += 2
        more.draw(in: CGRect(x: x, y: y, width: moreSize.width, height: moreSize.height),
                  withAttributes: labelAttributes)
    }

    private func drawEmptyState() {
        let text = "暂无历史统计" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: RimeUI.textMuted,
        ]
        let size = text.size(withAttributes: attributes)
        text.draw(in: CGRect(x: bounds.midX - size.width / 2,
                             y: bounds.midY - size.height / 2,
                             width: size.width,
                             height: size.height),
                  withAttributes: attributes)
    }

    private func color(for level: Int) -> NSColor {
        guard level > 0 else {
            return RimeUI.surface2
        }
        let alpha: [CGFloat] = [0, 0.24, 0.43, 0.67, 0.92]
        return RimeUI.accentGreen.withAlphaComponent(alpha[min(4, max(0, level))])
    }

    private static let historyCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        return calendar
    }()

    private static func parseDayKey(_ value: String, calendar: Calendar) -> Date? {
        let pieces = value.split(separator: "-", omittingEmptySubsequences: false)
        guard pieces.count == 3,
              pieces[0].count == 4,
              pieces[1].count == 2,
              pieces[2].count == 2,
              let year = Int(pieces[0]),
              let month = Int(pieces[1]),
              let day = Int(pieces[2]) else { return nil }
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        components.year = year
        components.month = month
        components.day = day
        guard let date = calendar.date(from: components) else { return nil }
        let roundTrip = calendar.dateComponents([.year, .month, .day], from: date)
        guard roundTrip.year == year,
              roundTrip.month == month,
              roundTrip.day == day else { return nil }
        return date
    }

    private static func dayKey(for date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d",
                      components.year ?? 0,
                      components.month ?? 0,
                      components.day ?? 0)
    }
}

/// Pure layout and intensity coverage. It intentionally creates no NSView or
/// NSApplication, so it can be called from the executable smoke harness later.
func runHistoryHeatmapSmokeTest() -> Bool {
    func fail(_ message: String) -> Bool {
        print("FAILED: history heatmap \(message)")
        return false
    }

    let snapshot = KeyFrequencyHistorySnapshot(
        days: [
            KeyFrequencyDayTotal(dayKey: "2024-03-04", total: 25),
            KeyFrequencyDayTotal(dayKey: "2024-02-28", total: 1),
            KeyFrequencyDayTotal(dayKey: "2024-02-29", total: 9),
            KeyFrequencyDayTotal(dayKey: "2024-03-01", total: 100),
            KeyFrequencyDayTotal(dayKey: "not-a-date", total: 999),
        ],
        total: 1_134,
        maxDayTotal: 999,
        firstDayKey: "2024-02-28",
        lastDayKey: "not-a-date"
    )
    let layout = YearHistoryHeatmapView.makeLayout(snapshot: snapshot)
    let byDay = Dictionary(uniqueKeysWithValues: layout.cells.map { ($0.dayKey, $0) })
    guard layout.weekCount == 2,
          layout.cells.count == 6,
          layout.firstDayKey == "2024-02-28",
          layout.lastDayKey == "2024-03-04",
          layout.maxDayTotal == 100,
          byDay["2024-02-28"]?.weekdayIndex == 2,
          byDay["2024-02-29"]?.weekdayIndex == 3,
          byDay["2024-03-01"]?.weekdayIndex == 4,
          byDay["2024-03-02"]?.total == 0,
          byDay["2024-03-04"]?.weekIndex == 1 else {
        return fail("calendar layout, leap day, or missing-day fill")
    }

    let squareRootLevels = [0, 1, 9, 36, 100].map {
        YearHistoryHeatmapView.intensityLevel(total: $0,
                                              maxTotal: 100,
                                              normalization: .squareRoot)
    }
    guard squareRootLevels == [0, 1, 2, 3, 4] else {
        return fail("square-root levels: \(squareRootLevels)")
    }

    let logarithmicLevels = [0, 1, 5, 25, 100].map {
        YearHistoryHeatmapView.intensityLevel(total: $0,
                                              maxTotal: 100,
                                              normalization: .logarithmic)
    }
    guard logarithmicLevels.first == 0,
          logarithmicLevels.last == 4,
          zip(logarithmicLevels, logarithmicLevels.dropFirst())
            .allSatisfy({ $0 <= $1 }),
          logarithmicLevels.allSatisfy((0...4).contains) else {
        return fail("logarithmic levels: \(logarithmicLevels)")
    }

    let frame = YearHistoryHeatmapView.cellFrame(
        weekIndex: 1,
        weekdayIndex: 4,
        origin: CGPoint(x: 10, y: 20),
        cellSize: 12,
        spacing: 3
    )
    guard frame == CGRect(x: 25, y: 80, width: 12, height: 12),
          YearHistoryHeatmapView.gridSize(weekCount: 2,
                                          cellSize: 12,
                                          spacing: 3)
            == CGSize(width: 27, height: 102),
          YearHistoryHeatmapView.monthMarkers(layout: layout).map(\.monthKey)
            == ["2024-02", "2024-03"],
          YearHistoryHeatmapView.makeLayout(snapshot: .empty) == .empty else {
        return fail("pure geometry, month markers, or empty state")
    }
    let excessiveSpan = KeyFrequencyHistorySnapshot(
        days: [
            KeyFrequencyDayTotal(dayKey: "1900-01-01", total: 1),
            KeyFrequencyDayTotal(dayKey: "2201-01-01", total: 1),
        ],
        total: 2,
        maxDayTotal: 1,
        firstDayKey: "1900-01-01",
        lastDayKey: "2201-01-01"
    )
    guard YearHistoryHeatmapView.makeLayout(snapshot: excessiveSpan) == .empty else {
        return fail("excessive calendar span was expanded")
    }

    // The history view depends on the store preserving every day and failing
    // closed on unreadable data. Pin that boundary here so a future migration
    // cannot silently replace the user's statistics with an empty file.
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(
        "rimebuffer-history-store-\(UUID().uuidString)", isDirectory: true
    )
    defer { try? fileManager.removeItem(at: root) }
    let firstDate = Date(timeIntervalSince1970: 1_709_251_200) // 2024-03-01 UTC
    let secondDate = firstDate.addingTimeInterval(2 * 86_400)
    let store = KeyFrequencyStore(storageRoot: root, autosaveDelay: 60)
    store.record(keyID: "KeyA", at: firstDate)
    store.record(keyID: "KeyA", at: firstDate)
    store.record(keyID: "KeyB", at: secondDate)
    store.saveNow()
    let storedHistory = store.historySnapshot()
    guard storedHistory.days.map(\.total) == [2, 1],
          storedHistory.total == 3,
          storedHistory.maxDayTotal == 2,
          storedHistory.firstDayKey == store.dayKey(for: firstDate),
          storedHistory.lastDayKey == store.dayKey(for: secondDate) else {
        return fail("history-store aggregation")
    }

    let storageURL = root.appendingPathComponent("stats/key_frequency.json")
    do {
        let directoryPermissions = (try fileManager.attributesOfItem(
            atPath: storageURL.deletingLastPathComponent().path
        )[.posixPermissions] as? NSNumber)?.intValue ?? -1
        let filePermissions = (try fileManager.attributesOfItem(
            atPath: storageURL.path
        )[.posixPermissions] as? NSNumber)?.intValue ?? -1
        guard directoryPermissions & 0o777 == 0o700,
              filePermissions & 0o777 == 0o600 else {
            return fail("statistics storage permissions")
        }
    } catch {
        return fail("statistics permission fixture: \(error.localizedDescription)")
    }

    let invalidRoot = root.appendingPathComponent("invalid", isDirectory: true)
    let invalidURL = invalidRoot.appendingPathComponent("stats/key_frequency.json")
    do {
        try fileManager.createDirectory(at: invalidURL.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
        let invalidJSON = #"{"version":1,"days":{"2024-03-01":{"keys":{"KeyA":-1}}},"updatedAt":1}"#
        try Data(invalidJSON.utf8).write(to: invalidURL, options: .atomic)
        let invalidStore = KeyFrequencyStore(storageRoot: invalidRoot,
                                             autosaveDelay: 60)
        guard case .readOnly = invalidStore.storageState else {
            return fail("negative counter was accepted")
        }
    } catch {
        return fail("invalid-counter fixture: \(error.localizedDescription)")
    }

    let oversizedRoot = root.appendingPathComponent("oversized", isDirectory: true)
    let oversizedURL = oversizedRoot.appendingPathComponent("stats/key_frequency.json")
    do {
        try fileManager.createDirectory(at: oversizedURL.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
        try Data(repeating: 0x61,
                 count: KeyFrequencyStore.maximumFileBytes + 1)
            .write(to: oversizedURL, options: .atomic)
        let oversizedStore = KeyFrequencyStore(storageRoot: oversizedRoot,
                                               autosaveDelay: 60)
        guard case .readOnly = oversizedStore.storageState else {
            return fail("oversized file was accepted")
        }
    } catch {
        return fail("oversized-file fixture: \(error.localizedDescription)")
    }

    let symlinkRoot = root.appendingPathComponent("symlink", isDirectory: true)
    let symlinkURL = symlinkRoot.appendingPathComponent("stats/key_frequency.json")
    let symlinkTarget = root.appendingPathComponent("symlink-target.json")
    do {
        try fileManager.createDirectory(at: symlinkURL.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: symlinkTarget, options: .atomic)
        try fileManager.createSymbolicLink(at: symlinkURL,
                                           withDestinationURL: symlinkTarget)
        let symlinkStore = KeyFrequencyStore(storageRoot: symlinkRoot,
                                            autosaveDelay: 60)
        guard case .readOnly = symlinkStore.storageState else {
            return fail("symlink statistics file was accepted")
        }
    } catch {
        return fail("symlink fixture: \(error.localizedDescription)")
    }

    let corruptData = Data("not-json-and-must-survive".utf8)
    do {
        try corruptData.write(to: storageURL, options: .atomic)
    } catch {
        return fail("corrupt-store fixture: \(error.localizedDescription)")
    }
    let readOnlyStore = KeyFrequencyStore(storageRoot: root, autosaveDelay: 60)
    guard case .readOnly = readOnlyStore.storageState else {
        return fail("corrupt store did not fail closed")
    }
    readOnlyStore.record(keyID: "KeyC", at: secondDate)
    readOnlyStore.saveNow()
    guard (try? Data(contentsOf: storageURL)) == corruptData else {
        return fail("read-only store overwrote corrupt source")
    }
    guard readOnlyStore.repairReadOnlyStore(),
          readOnlyStore.storageState == .ready,
          readOnlyStore.historySnapshot() == .empty,
          (try? fileManager.contentsOfDirectory(
            at: storageURL.deletingLastPathComponent(),
            includingPropertiesForKeys: nil
          ).contains(where: { $0.lastPathComponent.contains("corrupt-") })) == true else {
        return fail("explicit corrupt-store repair")
    }

    print("history heatmap smoke OK")
    return true
}
