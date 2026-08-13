import AppKit
import Foundation

/// Page-owned UI for the built-in typing-speed extension. It observes only the
/// sanitized aggregate store and has no dependency on SettingsWindow, input
/// routing, focus leases or committed text.
final class TypingSpeedSettingsViewController: NSViewController {
    private static let maximumVisibleDayRows = 90
    private enum Page {
        case overview
        case history
    }

    private let subpageID: String
    private let store: TypingSpeedStore
    private let page: Page

    private var storeObserver: NSObjectProtocol?
    private var scheduledRefresh: DispatchWorkItem?

    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(wrappingLabelWithString: "")
    private let storageIssueLabel = NSTextField(wrappingLabelWithString: "")
    private let storageIssueBox = NSBox()
    private let repairStorageButton = NSButton(title: "备份损坏文件并重建…",
                                                target: nil,
                                                action: nil)

    private let todaySectionLabel = NSTextField(labelWithString: "")
    private let todayKeyCount = NSTextField(labelWithString: "0")
    private let todayCharacterCount = NSTextField(labelWithString: "0")
    private let todayActiveTime = NSTextField(labelWithString: "0 秒")
    private let todayKPM = NSTextField(labelWithString: "0")
    private let todayCPM = NSTextField(labelWithString: "0")
    private let todaySessionCount = NSTextField(labelWithString: "0")
    private let latestSessionSummary = NSTextField(wrappingLabelWithString: "")

    private let bestSpeedLabel = NSTextField(labelWithString: "")
    private let dayRangeLabel = NSTextField(labelWithString: "")
    private let dayRows = NSStackView()
    private let sessionRows = NSStackView()
    private let clearAllButton = NSButton(title: "清空全部记录",
                                          target: nil,
                                          action: nil)

    init(subpageID: String, store: TypingSpeedStore = .shared) {
        self.subpageID = subpageID
        self.store = store
        page = subpageID == "history" ? .history : .overview
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        scheduledRefresh?.cancel()
        if let storeObserver {
            NotificationCenter.default.removeObserver(storeObserver)
        }
    }

    override func loadView() {
        configureCommonControls()

        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 14
        content.edgeInsets = NSEdgeInsets(top: 26, left: 28, bottom: 30, right: 28)
        content.translatesAutoresizingMaskIntoConstraints = false
        content.addArrangedSubview(titleLabel)
        content.addArrangedSubview(subtitleLabel)
        content.addArrangedSubview(storageIssueBox)
        content.addArrangedSubview(spacer(height: 2))

        switch page {
        case .overview:
            buildOverview(in: content)
        case .history:
            buildHistory(in: content)
        }
        for arrangedView in content.arrangedSubviews {
            arrangedView.widthAnchor.constraint(
                equalTo: content.widthAnchor,
                constant: -(content.edgeInsets.left + content.edgeInsets.right)
            ).isActive = true
        }

        let document = TypingSpeedSettingsDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(content)

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.documentView = document

        NSLayoutConstraint.activate([
            document.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            document.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            content.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            content.topAnchor.constraint(equalTo: document.topAnchor),
            content.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            content.widthAnchor.constraint(greaterThanOrEqualToConstant: 560),
        ])
        view = scrollView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        storeObserver = NotificationCenter.default.addObserver(
            forName: .typingSpeedDidChange,
            object: store,
            queue: .main
        ) { [weak self] _ in
            self?.scheduleRefresh()
        }
        refresh()
    }

    private func configureCommonControls() {
        titleLabel.font = .systemFont(ofSize: 24, weight: .semibold)
        titleLabel.alignment = .left
        titleLabel.stringValue = page == .history ? "打字测速 · 历史" : "打字测速 · 概览"

        subtitleLabel.font = .systemFont(ofSize: 12)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.alignment = .left
        subtitleLabel.maximumNumberOfLines = 3
        subtitleLabel.stringValue = page == .history
            ? "按日期与会话回看本机测速聚合；速度按实际活跃输入时长计算。"
            : "统计按键、成文字符与活跃输入时长，并计算 KPM / CPM。成文字符按 Rime commit 计数，直输与进入缓冲均计入。"

        storageIssueLabel.font = .systemFont(ofSize: 11, weight: .medium)
        storageIssueLabel.textColor = .labelColor
        storageIssueLabel.maximumNumberOfLines = 4
        storageIssueLabel.setContentCompressionResistancePriority(.defaultLow,
                                                                  for: .horizontal)
        repairStorageButton.target = self
        repairStorageButton.action = #selector(confirmRepairStorage(_:))
        repairStorageButton.bezelStyle = .rounded
        repairStorageButton.setContentCompressionResistancePriority(.required,
                                                                    for: .horizontal)
        let warningIcon = NSImageView()
        warningIcon.image = NSImage(
            systemSymbolName: "exclamationmark.triangle.fill",
            accessibilityDescription: "测速存储警告"
        )
        warningIcon.contentTintColor = .systemOrange
        warningIcon.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: 15, weight: .semibold
        )
        warningIcon.setContentHuggingPriority(.required, for: .horizontal)
        let storageIssueRow = NSStackView(views: [
            warningIcon, storageIssueLabel, repairStorageButton,
        ])
        storageIssueRow.orientation = .horizontal
        storageIssueRow.alignment = .centerY
        storageIssueRow.spacing = 10
        storageIssueBox.boxType = .custom
        storageIssueBox.titlePosition = .noTitle
        storageIssueBox.cornerRadius = 8
        storageIssueBox.borderWidth = 1
        storageIssueBox.borderColor = NSColor.systemOrange.withAlphaComponent(0.55)
        storageIssueBox.fillColor = NSColor.systemOrange.withAlphaComponent(0.09)
        storageIssueBox.contentViewMargins = NSSize(width: 12, height: 10)
        storageIssueBox.contentView = storageIssueRow
        storageIssueBox.isHidden = true
        dayRangeLabel.font = .systemFont(ofSize: 11)
        dayRangeLabel.textColor = .tertiaryLabelColor

        [todayKeyCount, todayCharacterCount, todayActiveTime,
         todayKPM, todayCPM, todaySessionCount].forEach { field in
            field.font = .monospacedDigitSystemFont(ofSize: 22, weight: .semibold)
            field.alignment = .left
            field.lineBreakMode = .byTruncatingTail
        }

        latestSessionSummary.font = .monospacedDigitSystemFont(ofSize: 12,
                                                                weight: .regular)
        latestSessionSummary.textColor = .secondaryLabelColor
        latestSessionSummary.maximumNumberOfLines = 3

        bestSpeedLabel.font = .monospacedDigitSystemFont(ofSize: 17, weight: .semibold)
        bestSpeedLabel.textColor = .labelColor

        [dayRows, sessionRows].forEach { stack in
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 0
        }

        clearAllButton.target = self
        clearAllButton.action = #selector(clearAllTapped)
        clearAllButton.bezelStyle = .rounded
        clearAllButton.controlSize = .regular
        clearAllButton.setContentHuggingPriority(.required, for: .horizontal)
    }

    private func buildOverview(in content: NSStackView) {
        todaySectionLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        content.addArrangedSubview(todaySectionLabel)

        let firstRow = metricRow([
            metricCard(title: "按键数", value: todayKeyCount),
            metricCard(title: "成文字符", value: todayCharacterCount),
            metricCard(title: "活跃时长", value: todayActiveTime),
        ])
        let secondRow = metricRow([
            metricCard(title: "KPM", value: todayKPM),
            metricCard(title: "CPM", value: todayCPM),
            metricCard(title: "会话数", value: todaySessionCount),
        ])
        let metricRows = NSStackView(views: [firstRow, secondRow])
        metricRows.orientation = .vertical
        metricRows.alignment = .leading
        metricRows.spacing = 10
        firstRow.widthAnchor.constraint(equalTo: metricRows.widthAnchor).isActive = true
        secondRow.widthAnchor.constraint(equalTo: metricRows.widthAnchor).isActive = true
        content.addArrangedSubview(metricRows)

        content.addArrangedSubview(spacer(height: 4))
        content.addArrangedSubview(sectionLabel("最近会话"))
        let latestBox = NSBox()
        latestBox.boxType = .custom
        latestBox.cornerRadius = 8
        latestBox.borderWidth = 1
        latestBox.borderColor = .separatorColor
        latestBox.fillColor = .controlBackgroundColor
        latestBox.contentViewMargins = NSSize(width: 12, height: 10)
        latestBox.contentView = latestSessionSummary
        content.addArrangedSubview(latestBox)

        content.addArrangedSubview(spacer(height: 6))
        let privacy = NSTextField(wrappingLabelWithString:
            "隐私：成文字符按 Rime commit 计数，直输与进入缓冲均计入；只在本机保存字符数量、按键数、并击数、活跃时长与会话时间，不保存输入正文、候选内容、应用身份或焦点对象。")
        privacy.font = .systemFont(ofSize: 11)
        privacy.textColor = .tertiaryLabelColor
        privacy.maximumNumberOfLines = 4
        content.addArrangedSubview(privacy)
    }

    private func buildHistory(in content: NSStackView) {
        let bestTitle = sectionLabel("最佳速度（最近 100 次会话）")
        let bestRow = NSStackView(views: [bestTitle, flexibleSpacer(), clearAllButton])
        bestRow.orientation = .horizontal
        bestRow.alignment = .centerY
        bestRow.spacing = 10
        content.addArrangedSubview(bestRow)
        content.addArrangedSubview(bestSpeedLabel)

        content.addArrangedSubview(spacer(height: 6))
        content.addArrangedSubview(sectionLabel("每日历史"))
        content.addArrangedSubview(dayRangeLabel)
        content.addArrangedSubview(dayRows)

        content.addArrangedSubview(spacer(height: 8))
        content.addArrangedSubview(sectionLabel("最近会话"))
        content.addArrangedSubview(sessionRows)

        content.addArrangedSubview(spacer(height: 4))
        let privacy = NSTextField(wrappingLabelWithString:
            "历史记录仅包含本机聚合计数与时间戳，不含输入正文、文本框、应用或焦点信息。")
        privacy.font = .systemFont(ofSize: 11)
        privacy.textColor = .tertiaryLabelColor
        content.addArrangedSubview(privacy)
    }

    private func scheduleRefresh() {
        guard isViewLoaded,
              view.window?.isVisible == true,
              scheduledRefresh == nil else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.scheduledRefresh = nil
            self.refresh()
        }
        scheduledRefresh = item
        let delay: TimeInterval = page == .history ? 1.0 : 0.3
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func refresh() {
        dispatchPrecondition(condition: .onQueue(.main))
        if let issue = store.storageIssue {
            storageIssueLabel.stringValue = "测速文件无法安全读取，当前为只读模式。原路径条目不会被覆盖。\n原因：\(issue)"
            storageIssueBox.isHidden = false
            repairStorageButton.isEnabled = true
            clearAllButton.isEnabled = false
        } else {
            storageIssueLabel.stringValue = ""
            storageIssueBox.isHidden = true
            repairStorageButton.isEnabled = false
            clearAllButton.isEnabled = true
        }

        switch page {
        case .overview:
            refreshOverview()
        case .history:
            refreshHistory()
        }
    }

    private func refreshOverview(now: Date = Date()) {
        let today = store.snapshot(for: now)
        let history = store.historySnapshot()
        todaySectionLabel.stringValue = "今天 · \(Self.displayDate(today.dayKey))"
        todayKeyCount.stringValue = Self.integer(today.keyCount)
        todayCharacterCount.stringValue = Self.integer(today.committedCharacterCount)
        todayActiveTime.stringValue = Self.duration(today.activeSeconds)
        todayKPM.stringValue = Self.speed(today.keysPerMinute)
        todayCPM.stringValue = Self.speed(today.charactersPerMinute)
        todaySessionCount.stringValue = Self.integer(today.sessionCount)

        guard let session = history.recentSessions.first else {
            latestSessionSummary.stringValue = "尚无测速会话。开始输入后，这里会显示最近一次会话的聚合结果。"
            return
        }
        let kpm = session.activeSeconds > 0
            ? Double(session.keyCount) * 60 / max(1, session.activeSeconds)
            : 0
        latestSessionSummary.stringValue = [
            "\(Self.sessionTimeRange(session)) · \(Self.duration(session.activeSeconds))",
            "按键 \(Self.integer(session.keyCount))  ·  成文字符 \(Self.integer(session.committedCharacterCount))  ·  并击 \(Self.integer(session.chordCount))",
            "KPM \(Self.speed(kpm))  ·  CPM \(Self.speed(session.charactersPerMinute))",
        ].joined(separator: "\n")
    }

    private func refreshHistory() {
        let history = store.historySnapshot()
        bestSpeedLabel.stringValue = history.recentSessions.isEmpty
            ? "暂无有效会话"
            : "\(Self.speed(history.bestCharactersPerMinute)) CPM"

        let allDays = Array(history.days.reversed())
        let visibleDays = Array(allDays.prefix(Self.maximumVisibleDayRows))
        dayRangeLabel.stringValue = allDays.count > visibleDays.count
            ? "共 \(allDays.count) 个活跃日，显示最近 \(visibleDays.count) 天；完整聚合仍保存在本机。"
            : "共 \(allDays.count) 个活跃日"
        replaceRows(in: dayRows,
                    values: visibleDays,
                    emptyMessage: "暂无每日记录") { day in
            self.historyRow(
                title: Self.displayDate(day.dayKey),
                detail: "按键 \(Self.integer(day.keyCount)) · 成文字符 \(Self.integer(day.committedCharacterCount)) · 活跃 \(Self.duration(day.activeSeconds)) · KPM \(Self.speed(day.keysPerMinute)) · CPM \(Self.speed(day.charactersPerMinute))"
            )
        }
        replaceRows(in: sessionRows,
                    values: history.recentSessions,
                    emptyMessage: "暂无会话记录") { session in
            let kpm = session.activeSeconds > 0
                ? Double(session.keyCount) * 60 / max(1, session.activeSeconds)
                : 0
            return self.historyRow(
                title: Self.sessionTimeRange(session),
                detail: "按键 \(Self.integer(session.keyCount)) · 成文字符 \(Self.integer(session.committedCharacterCount)) · 并击 \(Self.integer(session.chordCount)) · \(Self.duration(session.activeSeconds)) · KPM \(Self.speed(kpm)) · CPM \(Self.speed(session.charactersPerMinute))"
            )
        }
    }

    private func replaceRows<T>(in stack: NSStackView,
                                values: [T],
                                emptyMessage: String,
                                makeRow: (T) -> NSView) {
        stack.arrangedSubviews.forEach { view in
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        guard !values.isEmpty else {
            let empty = NSTextField(labelWithString: emptyMessage)
            empty.font = .systemFont(ofSize: 12)
            empty.textColor = .secondaryLabelColor
            empty.alignment = .center
            empty.translatesAutoresizingMaskIntoConstraints = false
            empty.heightAnchor.constraint(greaterThanOrEqualToConstant: 52).isActive = true
            stack.addArrangedSubview(empty)
            empty.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            return
        }
        for (index, value) in values.enumerated() {
            let row = makeRow(value)
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            if index < values.count - 1 {
                let separator = NSBox()
                separator.boxType = .separator
                stack.addArrangedSubview(separator)
                separator.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            }
        }
    }

    private func metricCard(title: String, value: NSTextField) -> NSView {
        let caption = NSTextField(labelWithString: title)
        caption.font = .systemFont(ofSize: 11, weight: .medium)
        caption.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [caption, value])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 5
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)

        let box = NSBox()
        box.boxType = .custom
        box.cornerRadius = 8
        box.borderWidth = 1
        box.borderColor = .separatorColor
        box.fillColor = .controlBackgroundColor
        box.contentViewMargins = .zero
        box.contentView = stack
        box.translatesAutoresizingMaskIntoConstraints = false
        box.heightAnchor.constraint(greaterThanOrEqualToConstant: 72).isActive = true
        return box
    }

    private func metricRow(_ cards: [NSView]) -> NSStackView {
        let row = NSStackView(views: cards)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fillEqually
        row.spacing = 10
        return row
    }

    private func historyRow(title: String, detail: String) -> NSView {
        let titleField = NSTextField(labelWithString: title)
        titleField.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        titleField.setContentHuggingPriority(.required, for: .horizontal)
        titleField.setContentCompressionResistancePriority(.required, for: .horizontal)

        let detailField = NSTextField(labelWithString: detail)
        detailField.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        detailField.textColor = .secondaryLabelColor
        detailField.lineBreakMode = .byTruncatingTail
        detailField.toolTip = detail
        detailField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [titleField, detailField])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 14
        row.edgeInsets = NSEdgeInsets(top: 9, left: 4, bottom: 9, right: 4)
        row.translatesAutoresizingMaskIntoConstraints = false
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: 38).isActive = true
        return row
    }

    private func sectionLabel(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.alignment = .left
        return label
    }

    private func spacer(height: CGFloat) -> NSView {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.heightAnchor.constraint(equalToConstant: height).isActive = true
        return view
    }

    private func flexibleSpacer() -> NSView {
        let view = NSView()
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return view
    }

    @objc private func clearAllTapped() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "清空全部打字测速记录？"
        alert.informativeText = "每日统计和最近会话都会从本机删除，此操作无法撤销。"
        alert.addButton(withTitle: "清空全部")
        alert.addButton(withTitle: "取消")
        alert.window.appearance = RimeUI.appKitAppearance
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        store.clearAll()
        scheduledRefresh?.cancel()
        scheduledRefresh = nil
        refresh()
    }

    @objc private func confirmRepairStorage(_ sender: NSButton) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "重建打字测速存储？"
        alert.informativeText = "当前无法读取的路径条目会先原样移动到同目录，以 corrupt-<时间>-<唯一标识>.json 命名；随后创建新的空测速库。符号链接只移动链接本身，不会读取链接目标。"
        alert.addButton(withTitle: "备份并重建")
        alert.addButton(withTitle: "取消")
        presentConfirmation(alert) { [weak self] confirmed in
            guard confirmed, let self else { return }
            let repaired = self.store.repairReadOnlyStore()
            self.scheduledRefresh?.cancel()
            self.scheduledRefresh = nil
            self.refresh()
            self.showRepairResult(succeeded: repaired)
        }
    }

    private func presentConfirmation(_ alert: NSAlert,
                                     completion: @escaping (Bool) -> Void) {
        if let window = view.window {
            alert.beginSheetModal(for: window) { response in
                completion(response == .alertFirstButtonReturn)
            }
        } else {
            alert.window.appearance = RimeUI.appKitAppearance
            completion(alert.runModal() == .alertFirstButtonReturn)
        }
    }

    private func showRepairResult(succeeded: Bool) {
        let alert = NSAlert()
        if succeeded {
            alert.alertStyle = .informational
            alert.messageText = "测速存储已重建"
            alert.informativeText = "旧路径条目（如有）已备份在原目录，新的空测速库可以继续采集。"
        } else {
            alert.alertStyle = .critical
            alert.messageText = "测速存储重建失败"
            alert.informativeText = "测速仍处于只读模式，现有路径不会被新统计覆盖。\n\(store.storageIssue ?? "未知错误")"
        }
        alert.addButton(withTitle: "好")
        if let window = view.window {
            alert.beginSheetModal(for: window)
        } else {
            alert.window.appearance = RimeUI.appKitAppearance
            alert.runModal()
        }
    }

    private static func integer(_ value: Int) -> String {
        NumberFormatter.localizedString(from: NSNumber(value: value), number: .decimal)
    }

    private static func speed(_ value: Double) -> String {
        guard value.isFinite, value > 0 else { return "0" }
        return value >= 100 ? String(format: "%.0f", value) : String(format: "%.1f", value)
    }

    private static func duration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0 秒" }
        let rounded = Int(seconds.rounded())
        let hours = rounded / 3_600
        let minutes = (rounded % 3_600) / 60
        let remainder = rounded % 60
        if hours > 0 { return "\(hours) 小时 \(minutes) 分" }
        if minutes > 0 { return "\(minutes) 分 \(remainder) 秒" }
        return "\(remainder) 秒"
    }

    private static func displayDate(_ dayKey: String) -> String {
        guard dayKey.count == 10 else { return dayKey }
        return dayKey.replacingOccurrences(of: "-", with: ".")
    }

    private static func sessionTimeRange(_ session: TypingSpeedSessionSnapshot) -> String {
        let start = Date(timeIntervalSince1970: session.startedAt)
        let end = Date(timeIntervalSince1970: session.endedAt)
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateFormat = "MM.dd HH:mm:ss"
        if abs(session.endedAt - session.startedAt) < 0.5 {
            return formatter.string(from: start)
        }
        let endFormatter = DateFormatter()
        endFormatter.locale = .current
        endFormatter.dateFormat = Calendar.current.isDate(start, inSameDayAs: end)
            ? "HH:mm:ss"
            : "MM.dd HH:mm:ss"
        return "\(formatter.string(from: start))–\(endFormatter.string(from: end))"
    }
}

private final class TypingSpeedSettingsDocumentView: NSView {
    override var isFlipped: Bool { true }
}
