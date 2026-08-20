import AppKit
import Foundation

/// Page-owned UI for the built-in key-frequency statistics extension.
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

    private let storageWarningBox = NSBox()
    private let storageWarningLabel = NSTextField(wrappingLabelWithString: "")
    private let repairStorageButton = NSButton()

    private let dailyDatePicker = NSDatePicker()
    private let dailySummaryLabel = NSTextField(labelWithString: "")
    private let dailyTopKeyLabel = NSTextField(labelWithString: "")
    private let dailyHeatmap = KeyboardHeatmapView()
    private let clearDailyButton = NSButton()

    private let historySummaryLabel = NSTextField(wrappingLabelWithString: "")
    private let historyHeatmap = YearHistoryHeatmapView()
    private let historyScrollView = NSScrollView()
    private let historyDocumentView = StatisticsHistoryDocumentView()
    private let clearHistoryButton = NSButton()
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

    init(subpageID: String, store: KeyFrequencyStore = .shared) {
        self.subpage = Subpage(id: subpageID)
        self.store = store
        super.init(nibName: nil, bundle: nil)
        observeStore()
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        if let storeObserver {
            NotificationCenter.default.removeObserver(storeObserver)
        }
        pendingRefresh?.cancel()
    }

    override func loadView() {
        configureStorageWarning()

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

    // MARK: Page construction

    private func makeDailyPage() -> NSView {
        let title = titleLabel("统计 · 每日")
        let privacy = secondaryLabel("仅记录按键标识和次数，不记录输入内容。")

        dailyDatePicker.datePickerStyle = .textFieldAndStepper
        dailyDatePicker.datePickerMode = .single
        dailyDatePicker.datePickerElements = [.yearMonthDay]
        dailyDatePicker.dateValue = Date()
        dailyDatePicker.target = self
        dailyDatePicker.action = #selector(dailyDateChanged(_:))

        clearDailyButton.title = "清空当天…"
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
            sectionLabel("选择日期"),
            dateRow,
            dailySummaryLabel,
            dailyTopKeyLabel,
            dailyHeatmap,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(20, after: privacy)
        stack.setCustomSpacing(22, after: storageWarningBox)
        stack.setCustomSpacing(14, after: dateRow)
        stack.setCustomSpacing(6, after: dailySummaryLabel)
        stack.setCustomSpacing(14, after: dailyTopKeyLabel)
        pinArrangedSubviewsToWidth(of: stack)
        return stack
    }

    private func makeHistoryPage() -> NSView {
        let title = titleLabel("统计 · 历史")
        let privacy = secondaryLabel("按日期聚合按键次数；点击日期方块可查看当天的键盘分布。")

        clearHistoryButton.title = "清空全部…"
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
        historyDetailStack.addArrangedSubview(historyDaySummaryLabel)
        historyDetailStack.addArrangedSubview(historyDayTopKeyLabel)
        historyDetailStack.addArrangedSubview(historyDayHeatmap)
        historyDetailStack.setCustomSpacing(13, after: historyDayTopKeyLabel)
        pinArrangedSubviewsToWidth(of: historyDetailStack)
        historyDetailStack.isHidden = true

        let stack = NSStackView(views: [
            title,
            privacy,
            storageWarningBox,
            sectionLabel("全部历史"),
            summaryRow,
            historyScrollView,
            separator(),
            historyDetailStack,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(20, after: privacy)
        stack.setCustomSpacing(22, after: storageWarningBox)
        stack.setCustomSpacing(14, after: summaryRow)
        stack.setCustomSpacing(24, after: historyScrollView)
        stack.setCustomSpacing(24, after: stack.arrangedSubviews[6])
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
            guard let self else { return }
            self.selectedHistoryDayKey = dayKey
            self.refreshSelectedHistoryDay()
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
        switch subpage {
        case .daily:
            refreshDaily()
        case .history:
            refreshHistory()
        }
    }

    private func refreshStorageState() {
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
        let snapshot = store.snapshot(for: dailyDatePicker.dateValue)
        dailyHeatmap.snapshot = snapshot
        apply(snapshot: snapshot,
              summaryLabel: dailySummaryLabel,
              topKeyLabel: dailyTopKeyLabel)
        clearDailyButton.isEnabled = store.storageState == .ready && snapshot.total > 0
    }

    private func refreshHistory() {
        let snapshot = store.historySnapshot()
        let hadSelection = selectedHistoryDayKey != nil
        historyHeatmap.snapshot = snapshot

        if snapshot.days.isEmpty {
            historySummaryLabel.stringValue = "暂无历史统计"
            selectedHistoryDayKey = nil
            historyDetailStack.isHidden = true
        } else {
            historySummaryLabel.stringValue = historySummary(snapshot)
            if !isSelectedHistoryDayInside(snapshot) {
                selectedHistoryDayKey = snapshot.lastDayKey
            }
            historyDetailStack.isHidden = false
            refreshSelectedHistoryDay()
            if !hadSelection {
                DispatchQueue.main.async { [weak self] in self?.scrollHistoryToLatest() }
            }
        }
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
        summaryLabel.stringValue = "\(snapshot.dayKey) · 总按键 \(formatted(snapshot.total)) 次 · 覆盖 \(formatted(coverage)) 个键"
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
        return "\(first) — \(last) · \(formatted(snapshot.days.count)) 天有记录 · 总按键 \(formatted(snapshot.total)) 次 · 单日最高 \(formatted(snapshot.maxDayTotal)) 次"
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
        refreshImmediately()
    }

    @objc private func confirmClearDaily(_ sender: NSButton) {
        let date = dailyDatePicker.dateValue
        let dayKey = store.dayKey(for: date)
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
