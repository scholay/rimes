import AppKit
import Foundation

/// Production dashboard controls and rendering against explicitly synthetic,
/// isolated telemetry fixtures. No live preferences, IMK or input source.
func runStatisticsDashboardSmokeTest(outputURL: URL? = nil) -> Bool {
    func fail(_ message: String) -> Bool {
        print("statistics-dashboard-smoke: FAIL \(message)")
        return false
    }
    guard Thread.isMainThread else { return fail("AppKit requires the main thread") }
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    app.finishLaunching()
    let suiteName = "RIMES.StatisticsDashboardSmoke.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else { return fail("isolated preferences") }
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let preferences = DailyMetricsPreferences(defaults: defaults)
    preferences.setKeyFrequencyEnabled(true)
    preferences.setTypingActivityEnabled(true)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "rimebuffer-statistics-dashboard-\(UUID().uuidString.lowercased())", isDirectory: true)
    do {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let keys = KeyFrequencyStore(storageRoot: root, autosaveDelay: 60)
        let activity = TypingSpeedStore(storageRoot: root, autosaveDelay: 60)
        let calendar = Calendar(identifier: .gregorian)
        let today = calendar.startOfDay(for: Date()).addingTimeInterval(3_600)
        let keyIDs = ["KeyA", "KeyS", "KeyD", "KeyF", "KeyJ", "KeyK", "KeyL", "Space", "Backspace"]
        // Fifteen real store days; one deliberately has no activity collector,
        // another has a single key with no measurable elapsed time.
        for offset in (0..<15).reversed() {
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else { return fail("fixture dates") }
            let count = 48 + (offset * 17 % 62)
            for index in 0..<count {
                let stamp = date.addingTimeInterval(Double(index) * (0.5 + Double(offset % 4) / 8))
                let keyID = keyIDs[(index * 7 + offset) % keyIDs.count]
                keys.record(keyID: keyID, at: stamp)
                guard offset != 4, offset != 2 || index == 0 else { continue }
                activity.consume(.key(.init(keyID: keyID, timestamp: stamp.timeIntervalSince1970,
                                            isRepeat: false, modifierFlags: 0, schemaID: "statistics-fixture")))
                if index % 4 == 3 {
                    activity.consume(.commit(.init(characterCount: 2 + offset % 3,
                                                   timestamp: stamp.timeIntervalSince1970 + 0.1,
                                                   source: .direct, schemaID: "statistics-fixture")))
                }
                if index % 7 == 6 {
                    activity.consume(.chord(.init(rimeKeyCodes: [113, 107, 109],
                                                  timestamp: stamp.timeIntervalSince1970 + 0.15,
                                                  duration: 0.08, handledReleaseCount: 3,
                                                  schemaID: "statistics-fixture")))
                }
            }
        }
        keys.saveNow(); activity.saveNow()
        guard keys.storageState == .ready, activity.storageIssue == nil,
              keys.historySnapshot().days.count == 15,
              activity.historySnapshot().days.count == 14 else { return fail("seeded isolated stores") }
        let keyBytes = try Data(contentsOf: root.appendingPathComponent("stats/key_frequency.json"))
        let activityBytes = try Data(contentsOf: root.appendingPathComponent("stats/typing_speed.json"))
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func selectDate(_ date: Date, in view: NSView) -> Bool {
            guard let picker = descendants(view).compactMap({ $0 as? NSDatePicker }).first else { return false }
            picker.dateValue = date
            return picker.sendAction(picker.action, to: picker.target)
        }
        func card(_ title: String, in view: NSView) -> MetricsValueCard? {
            descendants(view).compactMap { $0 as? MetricsValueCard }.first { $0.accessibilityLabel() == title }
        }
        func cardsMatch(_ date: Date, in view: NSView) -> Bool {
            let snapshot = activity.snapshot(for: date)
            let expected = NumberFormatter.localizedString(from: NSNumber(value: snapshot.committedCharacterCount), number: .decimal)
            return (card("成文字数", in: view)?.accessibilityValue() as? String) == "\(expected) 字符"
                && (card("输入按键", in: view)?.accessibilityValue() as? String) == "\(snapshot.keyCount) 键"
        }

        let daily = StatisticsSettingsViewController(subpageID: "daily", store: keys, speedStore: activity, preferences: preferences)
        let history = StatisticsSettingsViewController(subpageID: "history", store: keys, speedStore: activity, preferences: preferences)
        let dailyView = daily.view
        let historyView = history.view
        guard selectDate(today, in: dailyView), selectDate(today, in: historyView),
              cardsMatch(today, in: dailyView), cardsMatch(today, in: historyView) else { return fail("initial card values") }
        guard let dailyChart = descendants(dailyView).compactMap({ $0 as? MetricsLineChartView }).first,
              let historyChart = descendants(historyView).compactMap({ $0 as? MetricsLineChartView }).first,
              dailyChart.samples.count == 7, historyChart.samples.count == 30,
              dailyChart.unit == "字符", historyChart.unit == "字符" else { return fail("graph units and date ranges") }
        let missingDate = calendar.date(byAdding: .day, value: -4, to: today)!
        let missingKey = keys.dayKey(for: missingDate)
        guard dailyChart.samples.first(where: { $0.id == missingKey })?.value == nil,
              dailyChart.samples.last?.value == Double(activity.snapshot(for: today).committedCharacterCount) else {
            return fail("missing collector must be nil, not fabricated zero")
        }
        let pickerControls = descendants(dailyView).compactMap { $0 as? NSSegmentedControl }
        guard let range = pickerControls.first(where: { $0.label(forSegment: 0) == "7 天" }),
              let metric = pickerControls.first(where: { $0.label(forSegment: 0) == "成文字数" }) else {
            return fail("filter controls")
        }
        range.selectedSegment = 1
        guard range.sendAction(range.action, to: range.target), dailyChart.samples.count == 30 else { return fail("30-day filter action") }
        metric.selectedSegment = 1
        guard metric.sendAction(metric.action, to: metric.target), dailyChart.unit == "字符/分" else { return fail("speed metric action") }
        let zeroDurationKey = keys.dayKey(for: calendar.date(byAdding: .day, value: -2, to: today)!)
        guard dailyChart.samples.first(where: { $0.id == zeroDurationKey })?.value == nil,
              abs((dailyChart.samples.last?.value ?? -1) - activity.snapshot(for: today).charactersPerMinute) < 0.0001 else {
            return fail("speed denominator and zero-duration omission")
        }
        let chosenDate = calendar.date(byAdding: .day, value: -6, to: today)!
        let chosenKey = keys.dayKey(for: chosenDate)
        dailyChart.onSelectSample?(chosenKey)
        historyChart.onSelectSample?(chosenKey)
        guard cardsMatch(chosenDate, in: dailyView), cardsMatch(chosenDate, in: historyView),
              dailyChart.selectedSampleID == chosenKey, historyChart.selectedSampleID == chosenKey else {
            return fail("chart-date-card linkage")
        }
        guard let dailyPicker = descendants(dailyView).compactMap({ $0 as? NSDatePicker }).first,
              keys.dayKey(for: dailyPicker.dateValue) == keys.dayKey(for: today),
              dailyChart.samples.last?.id == keys.dayKey(for: today) else {
            return fail("point selection must not move the date-range anchor")
        }
        let olderDate = calendar.date(byAdding: .day, value: -12, to: today)!
        dailyChart.onSelectSample?(keys.dayKey(for: olderDate))
        guard cardsMatch(olderDate, in: dailyView) else { return fail("old point detail") }
        range.selectedSegment = 0
        guard range.sendAction(range.action, to: range.target), dailyChart.samples.count == 7,
              cardsMatch(today, in: dailyView) else { return fail("shortened range must retire invisible selection") }
        let futureDate = calendar.date(byAdding: .day, value: 20, to: today)!
        guard selectDate(futureDate, in: dailyView), dailyChart.samples.count == 7,
              dailyChart.samples.last?.id == keys.dayKey(for: today),
              cardsMatch(today, in: dailyView) else { return fail("future range is bounded at today") }
        guard let heatmap = descendants(historyView).compactMap({ $0 as? YearHistoryHeatmapView }).first else {
            return fail("calendar heatmap")
        }
        heatmap.onSelectDay?(keys.dayKey(for: today))
        guard cardsMatch(today, in: historyView), historyChart.samples.last?.id == keys.dayKey(for: today) else {
            return fail("calendar-date-trend linkage")
        }
        let buttons = descendants(dailyView).compactMap { $0 as? NSButton }
        guard let recording = buttons.first(where: { $0.title == "输入趋势" }),
              let keysRecording = buttons.first(where: { $0.title == "按键分布" }),
              recording.state == .on, keysRecording.state == .on else { return fail("recording controls") }
        recording.performClick(nil)
        guard !preferences.recordsTypingActivity, preferences.recordsKeyFrequency else { return fail("independent collection consent") }
        keysRecording.performClick(nil)
        guard !preferences.recordsKeyFrequency else { return fail("key collection action") }
        recording.performClick(nil); keysRecording.performClick(nil)
        guard try Data(contentsOf: root.appendingPathComponent("stats/key_frequency.json")) == keyBytes,
              try Data(contentsOf: root.appendingPathComponent("stats/typing_speed.json")) == activityBytes else {
            return fail("dashboard and consent changes must not rewrite historical records")
        }

        let emptyRoot = root.appendingPathComponent("empty", isDirectory: true)
        let empty = StatisticsSettingsViewController(subpageID: "daily",
                                                     store: KeyFrequencyStore(storageRoot: emptyRoot, autosaveDelay: 60),
                                                     speedStore: TypingSpeedStore(storageRoot: emptyRoot, autosaveDelay: 60),
                                                     preferences: preferences)
        guard let emptyChart = descendants(empty.view).compactMap({ $0 as? MetricsLineChartView }).first,
              emptyChart.samples.count == 7, emptyChart.samples.allSatisfy({ $0.value == nil }),
              (card("日常速度", in: empty.view)?.accessibilityValue() as? String)?.hasPrefix("—") == true,
              (card("成文字数", in: empty.view)?.accessibilityValue() as? String)?.hasPrefix("—") == true else {
            return fail("honest graphical empty state")
        }
        let olderRoot = root.appendingPathComponent("older-history", isDirectory: true)
        let olderKeys = KeyFrequencyStore(storageRoot: olderRoot, autosaveDelay: 60)
        let olderActivity = TypingSpeedStore(storageRoot: olderRoot, autosaveDelay: 60)
        let lastRecordedDate = calendar.date(byAdding: .day, value: -120, to: today)!
        olderKeys.record(keyID: "KeyA", at: lastRecordedDate)
        olderActivity.consume(.key(.init(keyID: "KeyA", timestamp: lastRecordedDate.timeIntervalSince1970,
                                         isRepeat: false, modifierFlags: 0, schemaID: "statistics-fixture")))
        olderActivity.consume(.commit(.init(characterCount: 2, timestamp: lastRecordedDate.timeIntervalSince1970 + 2,
                                            source: .direct, schemaID: "statistics-fixture")))
        olderKeys.saveNow(); olderActivity.saveNow()
        let olderHistory = StatisticsSettingsViewController(subpageID: "history", store: olderKeys,
                                                            speedStore: olderActivity, preferences: preferences)
        guard let olderChart = descendants(olderHistory.view).compactMap({ $0 as? MetricsLineChartView }).first,
              olderChart.samples.count == 30,
              olderChart.samples.last?.id == olderKeys.dayKey(for: lastRecordedDate),
              olderChart.samples.last?.value == 2 else {
            return fail("initial history range ends at the last real record, not months of future blanks")
        }
        guard MetricsLineChartView.axisMaximum(73) == 100,
              MetricsLineChartView.axisMaximum(0) == 1,
              MetricsChartSample(id: "invalid", label: "", value: .nan).value == nil else {
            return fail("chart value and axis safety")
        }
        guard KeyboardHeatmapLabelRules.displayLabel("Control") == "⌃",
              KeyboardHeatmapLabelRules.displayLabel("Option") == "⌥",
              KeyboardHeatmapLabelRules.displayLabel("Command") == "⌘",
              KeyboardHeatmapLabelRules.displayLabel("Home") == "Home",
              KeyboardHeatmapLabelRules.fontSize(for: "Home", availableWidth: 22, preferredSize: 11) < 11 else {
            return fail("compact modifier labels and narrow-key font fitting")
        }
        // Restore overview choices before optional image export.
        range.selectedSegment = 0; metric.selectedSegment = 0
        guard selectDate(today, in: dailyView) else { return fail("restore daily render") }
        func render(_ pane: NSView, to destination: URL?) -> Bool {
            pane.wantsLayer = true
            pane.layer?.backgroundColor = RimeUI.surface.cgColor
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 698, height: 800),
                                  styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = RimeUI.appKitAppearance
            window.backgroundColor = RimeUI.surface
            window.contentView = pane
            defer { window.close() }
            pane.layoutSubtreeIfNeeded()
            let height = ceil(pane.fittingSize.height)
            guard height.isFinite, (400...1_800).contains(height) else { return fail("dashboard fitting height \(height)") }
            window.setContentSize(NSSize(width: 698, height: height))
            pane.layoutSubtreeIfNeeded()
            let graphs = descendants(pane).compactMap { $0 as? MetricsLineChartView }
            guard graphs.allSatisfy({ $0.frame.width >= 600 && $0.frame.height >= 160 }),
                  descendants(pane).compactMap({ $0 as? MetricsValueCard }).allSatisfy({ $0.frame.width >= 140 && $0.frame.height >= 92 }) else {
                return fail("collapsed chart or metric card")
            }
            pane.displayIfNeeded()
            guard let bitmap = pane.bitmapImageRepForCachingDisplay(in: pane.bounds) else { return fail("bitmap surface") }
            pane.cacheDisplay(in: pane.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]), !png.isEmpty else { return fail("PNG output") }
            if let destination {
                do { try png.write(to: destination, options: .atomic) }
                catch { return fail(error.localizedDescription) }
                print("statistics-dashboard-smoke: rendered \(destination.path)")
            }
            return true
        }
        let historyURL = outputURL.map { $0.deletingPathExtension().appendingPathExtension("history.png") }
        guard render(dailyView, to: outputURL), render(historyView, to: historyURL) else { return false }
        print("statistics-dashboard-smoke: PASS 15-day fixtures, filters, linked cards/calendar, consent, preserved files, missing-value gaps and native renders")
        return true
    } catch { return fail(error.localizedDescription) }
}
