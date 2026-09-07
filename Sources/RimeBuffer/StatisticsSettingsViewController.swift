import AppKit
import Foundation

/// Graph-first everyday input statistics. Existing key-frequency and passive
/// speed files remain independent, preserving both historical data and consent.
///
/// The settings shell is responsible only for routing. Date selection,
/// history drill-down, destructive confirmations and store observation all
/// live here so the same controller can be hosted outside SettingsWindow.
final class StatisticsSettingsViewController: NSViewController {
    private enum Subpage {
        case daily
        case history

        init(id: String) {
            self = id == "history" ? .history : .daily
        }
    }

    private let subpage: Subpage
    private let store: KeyFrequencyStore
    private let speedStore: TypingSpeedStore
    private let preferences: DailyMetricsPreferences
    private var speedObserver: NSObjectProtocol?
    private var preferencesObserver: NSObjectProtocol?
    private let charactersCard = MetricsValueCard(title: "成文字数", symbolName: "textformat")
    private let keysCard = MetricsValueCard(title: "输入按键", symbolName: "keyboard")
    private let durationCard = MetricsValueCard(title: "活跃时长", symbolName: "clock")
    private let speedCard = MetricsValueCard(title: "日常速度", symbolName: "speedometer")
    private let trendChart = MetricsLineChartView()
    private let sessionChart = MetricsLineChartView()
    private let sessionBestLabel = NSTextField(labelWithString: "")
    private let rangeControl = NSSegmentedControl(labels: ["7 天", "30 天"], trackingMode: .selectOne, target: nil, action: nil)
    private let metricControl = NSSegmentedControl(labels: ["成文字数", "日常速度"], trackingMode: .selectOne, target: nil, action: nil)
    private let recordKeysButton = NSButton(checkboxWithTitle: "按键分布", target: nil, action: nil)
    private let recordSpeedButton = NSButton(checkboxWithTitle: "输入趋势", target: nil, action: nil)
    private let clearSpeedButton = RimePointingHandButton(title: "清空输入趋势…", target: nil, action: nil)
    private let speedWarningBox = NSBox()
    private let speedWarningLabel = NSTextField(wrappingLabelWithString: "")
    private let repairSpeedButton = RimePointingHandButton(title: "备份并重建…", target: nil, action: nil)
    private var trendEndDate = Date()
    private var selectedDailyDayKey: String?

    private let storageWarningBox = NSBox()
    private let storageWarningLabel = NSTextField(wrappingLabelWithString: "")
    private let repairStorageButton = RimePointingHandButton()

    private let dailyDatePicker = NSDatePicker()
    private let dailySummaryLabel = NSTextField(labelWithString: "")
    private let dailyTopKeyLabel = NSTextField(labelWithString: "")
    private let dailyHeatmap = KeyboardHeatmapView()
    private let clearDailyButton = RimePointingHandButton()

    private let historySummaryLabel = NSTextField(wrappingLabelWithString: "")
    private let historyHeatmap = YearHistoryHeatmapView()
    private let historyScrollView = NSScrollView()
    private let historyDocumentView = StatisticsHistoryDocumentView()
    private let clearHistoryButton = RimePointingHandButton()
    private let historyDetailStack = NSStackView()
    private let historyDetailTitleLabel = NSTextField(labelWithString: "")
    private let historyDaySummaryLabel = NSTextField(labelWithString: "")
    private let historyDayTopKeyLabel = NSTextField(labelWithString: "")
    private let historyDayHeatmap = KeyboardHeatmapView()

    private var selectedHistoryDayKey: String?
    private var storeObserver: NSObjectProtocol?
    private var pendingRefresh: DispatchWorkItem?
    private var refreshToken = 0
    private var lastRefreshUptime: TimeInterval = 0
    private let refreshInterval: TimeInterval = 0.18

    init(subpageID: String, store: KeyFrequencyStore = .shared,
         speedStore: TypingSpeedStore = .shared,
         preferences: DailyMetricsPreferences = .shared) {
        self.subpage = Subpage(id: subpageID)
        self.store = store
        self.speedStore = speedStore
        self.preferences = preferences
        super.init(nibName: nil, bundle: nil)
        observeStore()
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        if let storeObserver {
            NotificationCenter.default.removeObserver(storeObserver)
        }
        if let speedObserver { NotificationCenter.default.removeObserver(speedObserver) }
        if let preferencesObserver { NotificationCenter.default.removeObserver(preferencesObserver) }
        pendingRefresh?.cancel()
    }

    override func loadView() {
        configureStorageWarning()
        configureActivityControls()

        let pageContent: NSView
        switch subpage {
        case .daily:
            pageContent = makeDailyPage()
        case .history:
            pageContent = makeHistoryPage()
        }

        let root = NSStackView(views: [pageContent])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 0
        root.edgeInsets = NSEdgeInsets(top: 0, left: 24, bottom: 22, right: 24)
        pageContent.translatesAutoresizingMaskIntoConstraints = false
        pageContent.widthAnchor.constraint(equalToConstant: 650).isActive = true
        view = root
        refreshImmediately()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        dailyDatePicker.maxDate = Date()
        refreshImmediately()
    }

    // MARK: Page construction

    private func makeDailyPage() -> NSView {
        let title = titleLabel("统计 · 每日")
        let privacy = secondaryLabel("日常输入 · 仅保存本机计数，不保存正文")

        dailyDatePicker.datePickerStyle = .textFieldAndStepper
        dailyDatePicker.datePickerMode = .single
        dailyDatePicker.datePickerElements = [.yearMonthDay]
        dailyDatePicker.dateValue = trendEndDate
        dailyDatePicker.target = self
        dailyDatePicker.action = #selector(dailyDateChanged(_:))

        clearDailyButton.title = "清空当天键频…"
        clearDailyButton.bezelStyle = .rounded
        clearDailyButton.target = self
        clearDailyButton.action = #selector(confirmClearDaily(_:))

        let dateRow = NSStackView(views: [dailyDatePicker, flexibleSpacer(), clearDailyButton])
        dateRow.orientation = .horizontal
        dateRow.alignment = .centerY
        dateRow.spacing = 10

        dailySummaryLabel.font = .systemFont(ofSize: 11, weight: .medium)
        dailySummaryLabel.textColor = RimeUI.textPrimary
        dailySummaryLabel.alignment = .left
        dailyTopKeyLabel.font = .systemFont(ofSize: 10)
        dailyTopKeyLabel.textColor = RimeUI.textSecondary
        dailyTopKeyLabel.alignment = .left

        dailyHeatmap.translatesAutoresizingMaskIntoConstraints = false
        dailyHeatmap.setContentHuggingPriority(.defaultLow, for: .horizontal)
        dailyHeatmap.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        dailyHeatmap.heightAnchor.constraint(equalToConstant: 260).isActive = true

        let stack = NSStackView(views: [
            title,
            privacy,
            storageWarningBox,
            speedWarningBox,
            dateRow,
            dailySummaryLabel,
            makeMetricCards(),
            makeTrendControls(),
            trendChart,
            sectionLabel("键盘分布"),
            dailyHeatmap,
            makeRecordingControls(),
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(20, after: privacy)
        stack.setCustomSpacing(22, after: storageWarningBox)
        stack.setCustomSpacing(14, after: dateRow)
        stack.setCustomSpacing(6, after: dailySummaryLabel)
        pinArrangedSubviewsToWidth(of: stack)
        return stack
    }

    private func makeHistoryPage() -> NSView {
        let title = titleLabel("统计 · 历史")
        let privacy = secondaryLabel("日常输入趋势与按键日历 · 点击数据点查看当天")

        clearHistoryButton.title = "清空键频历史…"
        clearHistoryButton.bezelStyle = .rounded
        clearHistoryButton.target = self
        clearHistoryButton.action = #selector(confirmClearHistory(_:))

        historySummaryLabel.font = .systemFont(ofSize: 11, weight: .medium)
        historySummaryLabel.textColor = RimeUI.textPrimary
        historySummaryLabel.alignment = .left
        historySummaryLabel.maximumNumberOfLines = 0
        let summaryRow = NSStackView(views: [historySummaryLabel, flexibleSpacer(), clearHistoryButton])
        summaryRow.orientation = .horizontal
        summaryRow.alignment = .centerY
        summaryRow.spacing = 12

        configureHistoryScrollView()

        historyDetailTitleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        historyDetailTitleLabel.textColor = RimeUI.textPrimary
        historyDetailTitleLabel.alignment = .left
        historyDaySummaryLabel.font = .systemFont(ofSize: 11, weight: .medium)
        historyDaySummaryLabel.textColor = RimeUI.textPrimary
        historyDaySummaryLabel.alignment = .left
        historyDayTopKeyLabel.font = .systemFont(ofSize: 10)
        historyDayTopKeyLabel.textColor = RimeUI.textSecondary
        historyDayTopKeyLabel.alignment = .left
        historyDayHeatmap.translatesAutoresizingMaskIntoConstraints = false
        historyDayHeatmap.setContentHuggingPriority(.defaultLow, for: .horizontal)
        historyDayHeatmap.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        historyDayHeatmap.heightAnchor.constraint(equalToConstant: 260).isActive = true

        historyDetailStack.orientation = .vertical
        historyDetailStack.alignment = .leading
        historyDetailStack.spacing = 8
        historyDetailStack.addArrangedSubview(historyDetailTitleLabel)
        historyDetailStack.addArrangedSubview(makeMetricCards())
        historyDetailStack.addArrangedSubview(historyDaySummaryLabel)
        historyDetailStack.addArrangedSubview(historyDayHeatmap)
        pinArrangedSubviewsToWidth(of: historyDetailStack)
        historyDetailStack.isHidden = true

        let stack = NSStackView(views: [
            title,
            privacy,
            storageWarningBox,
            speedWarningBox,
            makeTrendControls(),
            trendChart,
            sectionLabel("按键日历 · 全部历史"),
            summaryRow,
            historyScrollView,
            separator(),
            historyDetailStack,
            makeSessionHeading(),
            sessionChart,
            makeRecordingControls(),
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(20, after: privacy)
        stack.setCustomSpacing(22, after: storageWarningBox)
        stack.setCustomSpacing(14, after: summaryRow)
        stack.setCustomSpacing(24, after: historyScrollView)
        pinArrangedSubviewsToWidth(of: stack)
        return stack
    }

    private func pinArrangedSubviewsToWidth(of stack: NSStackView) {
        for arrangedView in stack.arrangedSubviews {
            arrangedView.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }

    private func configureStorageWarning() {
        storageWarningLabel.font = .systemFont(ofSize: 10)
        storageWarningLabel.textColor = RimeUI.textPrimary
        storageWarningLabel.maximumNumberOfLines = 0
        storageWarningLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        repairStorageButton.title = "修复统计存储…"
        repairStorageButton.bezelStyle = .rounded
        repairStorageButton.target = self
        repairStorageButton.action = #selector(confirmRepairStorage(_:))
        repairStorageButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        let warningIcon = NSImageView()
        warningIcon.image = NSImage(
            systemSymbolName: "exclamationmark.triangle.fill",
            accessibilityDescription: "统计存储警告"
        )
        warningIcon.contentTintColor = .systemOrange
        warningIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        warningIcon.setContentHuggingPriority(.required, for: .horizontal)

        let row = NSStackView(views: [warningIcon, storageWarningLabel, repairStorageButton])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10

        storageWarningBox.boxType = .custom
        storageWarningBox.titlePosition = .noTitle
        storageWarningBox.cornerRadius = 8
        storageWarningBox.borderWidth = 1
        storageWarningBox.borderColor = NSColor.systemOrange.withAlphaComponent(0.55)
        storageWarningBox.fillColor = NSColor.systemOrange.withAlphaComponent(0.09)
        storageWarningBox.contentViewMargins = NSSize(width: 12, height: 10)
        storageWarningBox.contentView = row
        storageWarningBox.isHidden = true
    }

    private func configureHistoryScrollView() {
        historyScrollView.drawsBackground = false
        historyScrollView.borderType = .noBorder
        historyScrollView.hasHorizontalScroller = true
        historyScrollView.hasVerticalScroller = false
        historyScrollView.autohidesScrollers = false
        historyScrollView.horizontalScrollElasticity = .automatic
        historyScrollView.verticalScrollElasticity = .none
        historyScrollView.translatesAutoresizingMaskIntoConstraints = false
        historyScrollView.heightAnchor.constraint(equalToConstant: 164).isActive = true

        historyDocumentView.translatesAutoresizingMaskIntoConstraints = false
        historyHeatmap.translatesAutoresizingMaskIntoConstraints = false
        historyDocumentView.addSubview(historyHeatmap)
        historyScrollView.documentView = historyDocumentView

        NSLayoutConstraint.activate([
            historyDocumentView.leadingAnchor.constraint(equalTo: historyScrollView.contentView.leadingAnchor),
            historyDocumentView.topAnchor.constraint(equalTo: historyScrollView.contentView.topAnchor),
            historyDocumentView.heightAnchor.constraint(equalTo: historyScrollView.contentView.heightAnchor),
            historyDocumentView.widthAnchor.constraint(greaterThanOrEqualTo: historyScrollView.contentView.widthAnchor),
            historyHeatmap.leadingAnchor.constraint(equalTo: historyDocumentView.leadingAnchor),
            historyHeatmap.trailingAnchor.constraint(equalTo: historyDocumentView.trailingAnchor),
            historyHeatmap.topAnchor.constraint(equalTo: historyDocumentView.topAnchor),
            historyHeatmap.bottomAnchor.constraint(equalTo: historyDocumentView.bottomAnchor),
        ])

        historyHeatmap.onSelectDay = { [weak self] dayKey in
            guard let self, let date = self.localDate(for: dayKey), date <= Date() else { return }
            self.selectedHistoryDayKey = dayKey
            self.trendEndDate = date
            self.dailyDatePicker.dateValue = date
            self.refreshActivityGraph()
            self.refreshSelectedHistoryDay()
        }
    }

    // MARK: Everyday activity graphs (formerly the passive typing-speed page)

    private func configureActivityControls() {
        dailyDatePicker.datePickerStyle = .textFieldAndStepper
        dailyDatePicker.datePickerMode = .single
        dailyDatePicker.datePickerElements = [.yearMonthDay]
        dailyDatePicker.maxDate = Date()
        dailyDatePicker.dateValue = trendEndDate
        dailyDatePicker.target = self
        dailyDatePicker.action = #selector(dailyDateChanged(_:))
        dailyDatePicker.setAccessibilityLabel("趋势结束日期")
        dailyDatePicker.toolTip = "设置 7 / 30 天趋势的结束日期；点击图中数据点只切换当天详情，不移动趋势范围。"
        [rangeControl, metricControl].forEach {
            $0.controlSize = .small; $0.target = self; $0.action = #selector(activityFilterChanged)
        }
        rangeControl.selectedSegment = subpage == .history ? 1 : 0
        metricControl.selectedSegment = 0
        rangeControl.setAccessibilityLabel("趋势天数")
        metricControl.setAccessibilityLabel("趋势指标")
        trendChart.translatesAutoresizingMaskIntoConstraints = false
        trendChart.heightAnchor.constraint(equalToConstant: 190).isActive = true
        trendChart.xAxisLabel = "日期"
        trendChart.onSelectSample = { [weak self] key in
            guard let self else { return }
            if self.subpage == .daily {
                self.selectedDailyDayKey = key
                self.refreshDaily()
            } else {
                self.selectedHistoryDayKey = key
                self.refreshSelectedHistoryDay()
            }
        }
        sessionChart.translatesAutoresizingMaskIntoConstraints = false
        sessionChart.heightAnchor.constraint(equalToConstant: 165).isActive = true
        sessionChart.unit = "字符/分"
        sessionChart.xAxisLabel = "会话顺序 · 最近 20 次"
        sessionChart.emptyMessage = "开始日常输入，积累会话记录"
        recordKeysButton.target = self; recordKeysButton.action = #selector(recordKeysChanged)
        recordSpeedButton.target = self; recordSpeedButton.action = #selector(recordSpeedChanged)
        recordKeysButton.controlSize = .small; recordSpeedButton.controlSize = .small
        recordKeysButton.toolTip = "只记录 RIMES 输入路径的按键标识与次数；不追踪其他输入法的全局键盘。"
        recordSpeedButton.toolTip = "本机成文字数、按键数、并击数和活跃时长；关闭不删除历史，也不影响文章测速。"
        clearSpeedButton.bezelStyle = .rounded; clearSpeedButton.controlSize = .small
        clearSpeedButton.target = self; clearSpeedButton.action = #selector(confirmClearSpeed)
        repairSpeedButton.bezelStyle = .rounded; repairSpeedButton.controlSize = .small
        repairSpeedButton.target = self; repairSpeedButton.action = #selector(confirmRepairSpeed)
        speedWarningLabel.font = .systemFont(ofSize: 11)
        speedWarningLabel.textColor = RimeUI.warningTextColor
        speedWarningLabel.maximumNumberOfLines = 0
        speedWarningLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [speedWarningLabel, repairSpeedButton])
        row.orientation = .horizontal; row.spacing = 10; row.alignment = .centerY
        speedWarningBox.boxType = .custom; speedWarningBox.titlePosition = .noTitle
        speedWarningBox.cornerRadius = 8; speedWarningBox.borderWidth = 1
        speedWarningBox.fillColor = RimeUI.warningSurfaceColor
        speedWarningBox.borderColor = RimeUI.warningBorderColor
        speedWarningBox.contentViewMargins = NSSize(width: 12, height: 10)
        speedWarningBox.contentView = row; speedWarningBox.isHidden = true
    }

    private func makeMetricCards() -> NSView {
        let row = NSStackView(views: [charactersCard, keysCard, durationCard, speedCard])
        row.orientation = .horizontal; row.spacing = 10; row.distribution = .fillEqually
        row.alignment = .centerY
        return row
    }

    private func makeTrendControls() -> NSView {
        let views: [NSView] = subpage == .history
            ? [metricControl, flexibleSpacer(), dailyDatePicker, rangeControl]
            : [metricControl, flexibleSpacer(), rangeControl]
        let row = NSStackView(views: views)
        row.orientation = .horizontal; row.spacing = 10; row.alignment = .centerY
        return row
    }

    private func makeRecordingControls() -> NSView {
        let divider = separator()
        let row = NSStackView(views: [sectionLabel("本机记录"), recordKeysButton, recordSpeedButton, flexibleSpacer(), clearSpeedButton])
        row.orientation = .horizontal; row.spacing = 10; row.alignment = .centerY
        let stack = NSStackView(views: [divider, row])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 16
        pinArrangedSubviewsToWidth(of: stack)
        return stack
    }

    private func makeSessionHeading() -> NSView {
        sessionBestLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        sessionBestLabel.textColor = RimeUI.textMuted
        let row = NSStackView(views: [sectionLabel("最近输入会话"), flexibleSpacer(), sessionBestLabel])
        row.orientation = .horizontal; row.spacing = 10; row.alignment = .centerY
        return row
    }

    private func refreshActivityGraph() {
        let history = speedStore.historySnapshot()
        let byDay = Dictionary(uniqueKeysWithValues: history.days.map { ($0.dayKey, $0) })
        let days = rangeControl.selectedSegment == 0 ? 7 : 30
        let calendar = Calendar(identifier: .gregorian)
        let isSpeed = metricControl.selectedSegment == 1
        trendChart.unit = isSpeed ? "字符/分" : "字符"
        trendChart.emptyMessage = isSpeed ? "尚无可计算速度的输入记录" : "尚无成文记录 · 开始日常输入"
        trendChart.samples = (0..<days).reversed().compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: trendEndDate) else { return nil }
            let key = store.dayKey(for: date)
            let day = byDay[key]
            let value: Double? = isSpeed
                ? day.flatMap { $0.activeSeconds > 0 ? $0.charactersPerMinute : nil }
                : day.map { Double($0.committedCharacterCount) }
            return MetricsChartSample(id: key, label: String(key.suffix(5)).replacingOccurrences(of: "-", with: "."), value: value,
                                      detail: day.map { "\(key) · 活跃 \(Self.duration($0.activeSeconds)) · 日常输入，非文章测试" } ?? "\(key) · 未记录，不视为零速度")
        }
        // A shorter range must not leave the cards on an invisible old point.
        // This never shifts the range itself, so chart clicks cannot recurse.
        let selection = subpage == .daily ? selectedDailyDayKey : selectedHistoryDayKey
        if let selection, !trendChart.samples.contains(where: { $0.id == selection }) {
            if subpage == .daily { selectedDailyDayKey = trendChart.samples.last?.id }
            else { selectedHistoryDayKey = trendChart.samples.last?.id }
        }
        let timeFormatter = DateFormatter(); timeFormatter.dateFormat = "MM.dd HH:mm"
        let validSessions = history.recentSessions.filter { $0.activeSeconds > 0 }
        sessionBestLabel.stringValue = validSessions.map(\.charactersPerMinute).max().map {
            "近期最佳 \(String(format: "%.1f", $0)) 字符/分"
        } ?? "暂无有效速度"
        sessionBestLabel.toolTip = "最近 100 次日常输入会话的最高 CPM；按活跃时长计算，不与文章测速混排。曲线展示最近 20 次，会话间距按顺序排列。"
        sessionChart.samples = Array(history.recentSessions.prefix(20).reversed()).enumerated().map { index, session in
            MetricsChartSample(id: "session-\(index)", label: timeFormatter.string(from: Date(timeIntervalSince1970: session.startedAt)),
                               value: session.activeSeconds > 0 ? session.charactersPerMinute : nil,
                               detail: "成文 \(session.committedCharacterCount) 字符 · 按键 \(session.keyCount) 次 · 并击 \(session.chordCount) 拍 · 活跃 \(Self.duration(session.activeSeconds))")
        }
    }

    private func updateMetricCards(for dayKey: String) {
        // Presence is established from stored days, not an all-zero fallback
        // snapshot. Disabled or unavailable collection must remain unknown.
        let day = speedStore.historySnapshot().days.first { $0.dayKey == dayKey }
        charactersCard.update(value: day.map { formatted($0.committedCharacterCount) } ?? "—", unit: "字符",
                              detail: "Rime 上屏或进入缓冲时的成文字符数量，不保存正文。— 表示该日没有输入趋势记录。")
        keysCard.update(value: day.map { formatted($0.keyCount) } ?? "—", unit: "键",
                        detail: "日常输入中的物理按键次数，排除按住重复、快捷键与纯导航键。键盘分布保留完整键频口径，两者不混算。")
        durationCard.update(value: day.map { Self.duration($0.activeSeconds) } ?? "—",
                            detail: "连续日常输入的活跃时长；间隔超过 10 秒开始新会话，长停顿不计。保留原统计口径。")
        speedCard.update(value: day.flatMap { $0.activeSeconds > 0 ? String(format: "%.1f", $0.charactersPerMinute) : nil } ?? "—", unit: "字符/分",
                         detail: "成文字符 × 60 ÷ max(1 秒, 活跃时长)。日常速度不等于文章测速；没有有效时长时不计算，不显示为 0。")
    }

    private func localDate(for dayKey: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: dayKey)
    }

    private static func duration(_ seconds: TimeInterval) -> String {
        let rounded = Int(max(0, seconds).rounded())
        if rounded >= 3_600 { return "\(rounded / 3_600)时\(rounded % 3_600 / 60)分" }
        if rounded >= 60 { return "\(rounded / 60)分\(rounded % 60)秒" }
        return "\(rounded)秒"
    }

    @objc private func activityFilterChanged() { refreshImmediately() }
    @objc private func recordKeysChanged() { preferences.setKeyFrequencyEnabled(recordKeysButton.state == .on) }
    @objc private func recordSpeedChanged() { preferences.setTypingActivityEnabled(recordSpeedButton.state == .on) }

    @objc private func confirmClearSpeed() {
        let alert = NSAlert(); alert.alertStyle = .warning
        alert.messageText = "清空全部日常输入趋势？"
        alert.informativeText = "永久删除原打字测速积累的每日成文字数、活跃时长和最近会话，无法撤销。键盘分布和文章测速成绩不受影响。"
        alert.addButton(withTitle: "清空输入趋势"); alert.addButton(withTitle: "取消")
        presentConfirmation(alert) { [weak self] confirmed in
            guard confirmed, let self else { return }
            self.speedStore.clearAll(); self.refreshImmediately()
        }
    }

    @objc private func confirmRepairSpeed() {
        let alert = NSAlert(); alert.alertStyle = .critical
        alert.messageText = "重建日常输入趋势存储？"
        alert.informativeText = "先把无法读取的路径条目原样移动为同目录的 corrupt-<时间>-<唯一标识>.json，再创建空库。符号链接只移动链接本身，不读取目标。"
        alert.addButton(withTitle: "备份并重建"); alert.addButton(withTitle: "取消")
        presentConfirmation(alert) { [weak self] confirmed in
            guard confirmed, let self else { return }
            let repaired = self.speedStore.repairReadOnlyStore()
            self.refreshImmediately()
            if !repaired {
                let failure = NSAlert(); failure.alertStyle = .critical
                failure.messageText = "输入趋势存储重建失败"
                failure.informativeText = "仍为只读，不会覆盖现有路径。\n\(self.speedStore.storageIssue ?? "未知错误")"
                failure.addButton(withTitle: "好"); failure.window.appearance = RimeUI.appKitAppearance
                if let window = self.view.window { failure.beginSheetModal(for: window) } else { failure.runModal() }
            }
        }
    }

    // MARK: Refresh

    private func observeStore() {
        storeObserver = NotificationCenter.default.addObserver(
            forName: .keyFrequencyDidChange,
            object: store,
            queue: nil
        ) { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                self?.scheduleThrottledRefresh()
            }
        }
        speedObserver = NotificationCenter.default.addObserver(forName: .typingSpeedDidChange, object: speedStore, queue: .main) { [weak self] _ in
            self?.scheduleThrottledRefresh()
        }
        preferencesObserver = NotificationCenter.default.addObserver(forName: .dailyMetricsPreferencesDidChange, object: preferences, queue: .main) { [weak self] _ in
            self?.scheduleThrottledRefresh()
        }
    }

    /// Coalesces the per-key notification stream while guaranteeing that UI
    /// reads and mutations happen on the main thread.
    private func scheduleThrottledRefresh() {
        precondition(Thread.isMainThread)
        guard isViewLoaded,
              view.window?.isVisible == true,
              pendingRefresh == nil else { return }

        let elapsed = ProcessInfo.processInfo.systemUptime - lastRefreshUptime
        let delay = max(0, refreshInterval - elapsed)
        refreshToken += 1
        let token = refreshToken
        let work = DispatchWorkItem { [weak self] in
            guard let self, token == self.refreshToken else { return }
            self.pendingRefresh = nil
            self.lastRefreshUptime = ProcessInfo.processInfo.systemUptime
            self.refreshUI()
        }
        pendingRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func refreshImmediately() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.refreshImmediately() }
            return
        }
        guard isViewLoaded else { return }
        refreshToken += 1
        pendingRefresh?.cancel()
        pendingRefresh = nil
        lastRefreshUptime = ProcessInfo.processInfo.systemUptime
        refreshUI()
    }

    private func refreshUI() {
        refreshStorageState()
        refreshActivityGraph()
        switch subpage {
        case .daily:
            refreshDaily()
        case .history:
            refreshHistory()
        }
    }

    private func refreshStorageState() {
        recordKeysButton.state = preferences.recordsKeyFrequency ? .on : .off
        recordSpeedButton.state = preferences.recordsTypingActivity ? .on : .off
        if let reason = speedStore.storageIssue {
            speedWarningLabel.stringValue = "输入趋势存储只读，原路径不会被覆盖。\n\(reason)"
            speedWarningBox.isHidden = false
        } else { speedWarningBox.isHidden = true }
        clearSpeedButton.isEnabled = speedStore.storageIssue == nil && !speedStore.historySnapshot().days.isEmpty
        switch store.storageState {
        case .ready:
            storageWarningBox.isHidden = true
            repairStorageButton.isEnabled = false
        case let .readOnly(reason):
            storageWarningLabel.stringValue = "统计文件无法安全读取，当前为只读模式。原文件不会被覆盖。\n原因：\(reason)"
            storageWarningBox.isHidden = false
            repairStorageButton.isEnabled = true
        }
    }

    private func refreshDaily() {
        let dayKey = selectedDailyDayKey ?? store.dayKey(for: trendEndDate)
        let snapshot = store.snapshot(dayKey: dayKey)
        dailyHeatmap.snapshot = snapshot
        apply(snapshot: snapshot,
              summaryLabel: dailySummaryLabel,
              topKeyLabel: dailyTopKeyLabel)
        updateMetricCards(for: snapshot.dayKey)
        dailySummaryLabel.stringValue = "\(snapshot.dayKey) · 日常输入"
        trendChart.selectedSampleID = snapshot.dayKey
        clearDailyButton.isEnabled = store.storageState == .ready && snapshot.total > 0
    }

    private func refreshHistory() {
        let snapshot = store.historySnapshot()
        let hadSelection = selectedHistoryDayKey != nil
        historyHeatmap.snapshot = snapshot

        let speedDays = speedStore.historySnapshot().days
        let latestDay = ([snapshot.lastDayKey, speedDays.last?.dayKey].compactMap { $0 }).max()
        if snapshot.days.isEmpty {
            historySummaryLabel.stringValue = "暂无历史统计"
        } else {
            historySummaryLabel.stringValue = historySummary(snapshot)
            if !hadSelection {
                DispatchQueue.main.async { [weak self] in self?.scrollHistoryToLatest() }
            }
        }
        if selectedHistoryDayKey == nil {
            let todayKey = store.dayKey(for: Date())
            let initialDay = min(latestDay ?? todayKey, todayKey)
            selectedHistoryDayKey = initialDay
            if let date = localDate(for: initialDay) {
                trendEndDate = date
                dailyDatePicker.dateValue = date
                refreshActivityGraph()
            }
        }
        historyDetailStack.isHidden = false
        refreshSelectedHistoryDay()
        historyHeatmap.setAccessibilityElement(true)
        historyHeatmap.setAccessibilityRole(.image)
        historyHeatmap.setAccessibilityLabel("每日按键热力日历")
        historyHeatmap.setAccessibilityValue("\(snapshot.days.count) 个记录日，共 \(snapshot.total) 次；通过趋势图或日期选择器也可查看当天。")
        clearHistoryButton.isEnabled = store.storageState == .ready && snapshot.total > 0
    }

    private func refreshSelectedHistoryDay() {
        guard isViewLoaded, let dayKey = selectedHistoryDayKey else {
            historyDetailStack.isHidden = true
            return
        }
        let snapshot = store.snapshot(dayKey: dayKey)
        historyDetailTitleLabel.stringValue = "日期详情 · \(dayKey)"
        historyDayHeatmap.snapshot = snapshot
        updateMetricCards(for: dayKey)
        trendChart.selectedSampleID = dayKey
        apply(snapshot: snapshot,
              summaryLabel: historyDaySummaryLabel,
              topKeyLabel: historyDayTopKeyLabel)
        historyDetailStack.isHidden = false
    }

    private func apply(
        snapshot: KeyFrequencySnapshot,
        summaryLabel: NSTextField,
        topKeyLabel: NSTextField
    ) {
        let coverage = snapshot.counts.values.filter { $0 > 0 }.count
        summaryLabel.stringValue = "键盘分布 · \(formatted(snapshot.total)) 次 · \(formatted(coverage)) 个键"
        let keyboard = subpage == .daily ? dailyHeatmap : historyDayHeatmap
        keyboard.setAccessibilityElement(true)
        keyboard.setAccessibilityRole(.image)
        keyboard.setAccessibilityLabel("\(snapshot.dayKey) 键盘热力分布")
        keyboard.setAccessibilityValue(snapshot.counts.sorted { $0.key < $1.key }.map {
            "\(KeyboardLayout.displayName(for: $0.key)) \($0.value) 次"
        }.joined(separator: "，"))
        guard let topKeyID = snapshot.topKeyId else {
            topKeyLabel.stringValue = "最高频：暂无"
            return
        }
        let count = snapshot.counts[topKeyID] ?? 0
        let ratio = snapshot.total > 0 ? Double(count) / Double(snapshot.total) * 100 : 0
        topKeyLabel.stringValue = "最高频：\(KeyboardLayout.displayName(for: topKeyID)) · \(formatted(count)) 次 · \(String(format: "%.1f", ratio))%"
    }

    private func historySummary(_ snapshot: KeyFrequencyHistorySnapshot) -> String {
        guard let first = snapshot.firstDayKey, let last = snapshot.lastDayKey else {
            return "暂无历史统计"
        }
        historySummaryLabel.toolTip = "\(first) — \(last) · 共 \(formatted(snapshot.total)) 次 · 单日最高 \(formatted(snapshot.maxDayTotal)) 次"
        return "\(formatted(snapshot.days.count)) 个记录日"
    }

    private func isSelectedHistoryDayInside(_ snapshot: KeyFrequencyHistorySnapshot) -> Bool {
        guard let selectedHistoryDayKey,
              let first = snapshot.firstDayKey,
              let last = snapshot.lastDayKey else { return false }
        return selectedHistoryDayKey >= first && selectedHistoryDayKey <= last
    }

    private func scrollHistoryToLatest() {
        historyDocumentView.layoutSubtreeIfNeeded()
        let clipView = historyScrollView.contentView
        let maximumX = max(0, historyDocumentView.bounds.width - clipView.bounds.width)
        clipView.scroll(to: NSPoint(x: maximumX, y: 0))
        historyScrollView.reflectScrolledClipView(clipView)
    }

    // MARK: Actions

    @objc private func dailyDateChanged(_ sender: NSDatePicker) {
        trendEndDate = min(sender.dateValue, Date())
        sender.dateValue = trendEndDate
        let dayKey = store.dayKey(for: trendEndDate)
        if subpage == .history { selectedHistoryDayKey = dayKey }
        else { selectedDailyDayKey = dayKey }
        refreshImmediately()
    }

    @objc private func confirmClearDaily(_ sender: NSButton) {
        let dayKey = selectedDailyDayKey ?? store.dayKey(for: trendEndDate)
        guard let date = localDate(for: dayKey) else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "清空 \(dayKey) 的按键统计？"
        alert.informativeText = "这会永久删除当天的按键次数，无法撤销。"
        alert.addButton(withTitle: "清空当天")
        alert.addButton(withTitle: "取消")
        presentConfirmation(alert) { [weak self] confirmed in
            guard confirmed, let self else { return }
            self.store.clear(day: date)
            self.refreshImmediately()
        }
    }

    @objc private func confirmClearHistory(_ sender: NSButton) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "清空全部按键统计？"
        alert.informativeText = "所有日期的按键次数都会被永久删除，无法撤销。"
        alert.addButton(withTitle: "清空全部")
        alert.addButton(withTitle: "取消")
        presentConfirmation(alert) { [weak self] confirmed in
            guard confirmed, let self else { return }
            self.store.clear(day: nil)
            self.selectedHistoryDayKey = nil
            self.refreshImmediately()
        }
    }

    @objc private func confirmRepairStorage(_ sender: NSButton) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "修复统计存储？"
        alert.informativeText = "当前无法读取的文件会先保留为 corrupt-<时间>.json，再创建一个新的空统计库。旧文件中的历史次数不会继续显示。"
        alert.addButton(withTitle: "备份并修复")
        alert.addButton(withTitle: "取消")
        presentConfirmation(alert) { [weak self] confirmed in
            guard confirmed, let self else { return }
            if self.store.repairReadOnlyStore() {
                self.refreshImmediately()
            } else {
                self.showRepairFailure()
            }
        }
    }

    private func presentConfirmation(_ alert: NSAlert, completion: @escaping (Bool) -> Void) {
        if let window = view.window {
            alert.beginSheetModal(for: window) { response in
                completion(response == .alertFirstButtonReturn)
            }
        } else {
            alert.window.appearance = RimeUI.appKitAppearance
            completion(alert.runModal() == .alertFirstButtonReturn)
        }
    }

    private func showRepairFailure() {
        let reason: String
        if case let .readOnly(message) = store.storageState {
            reason = message
        } else {
            reason = "未知错误"
        }
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "统计存储修复失败"
        alert.informativeText = "原文件仍保持不变。\n\(reason)"
        alert.addButton(withTitle: "好")
        if let window = view.window {
            alert.beginSheetModal(for: window)
        } else {
            alert.window.appearance = RimeUI.appKitAppearance
            alert.runModal()
        }
        refreshImmediately()
    }

    // MARK: Small UI helpers

    private func titleLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = RimeUI.textSecondary
        label.alignment = .left
        return label
    }

    private func sectionLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = RimeUI.textSecondary
        label.alignment = .left
        return label
    }

    private func secondaryLabel(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 10)
        label.textColor = RimeUI.textMuted
        label.alignment = .left
        return label
    }

    private func flexibleSpacer() -> NSView {
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return spacer
    }

    private func separator() -> NSView {
        let line = NSBox()
        line.boxType = .separator
        return line
    }

    private func formatted(_ value: Int) -> String {
        NumberFormatter.localizedString(from: NSNumber(value: value), number: .decimal)
    }
}

private final class StatisticsHistoryDocumentView: NSView {
    override var isFlipped: Bool { true }
}
