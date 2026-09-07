import AppKit
import Carbon
import CryptoKit
import Foundation

/// Owns one local article editor. Persisted results contain metrics, not text.
final class TypingSpeedSettingsViewController: NSViewController, TypingPracticeTelemetrySink {
    private let isHistory: Bool
    private let historyStore: TypingTestHistoryStore
    private let contextProvider: (() -> TypingTestContext)?
    private let clockProvider: () -> TimeInterval
    private let telemetryEnabled: Bool
    private var observers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var sourceObserver: NSObjectProtocol?
    private var timer: Timer?
    private var session: TypingTestSession?
    private var latestSnapshot: TypingTestSnapshot?
    private var isArmed = false
    private var isStopping = false
    private var selectedArticle = TypingTestArticles.defaultArticle
    private var frozenSourceID: String?
    private let articlePicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let contextPicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let startButton = RimePointingHandButton(title: "开始跟打", target: nil, action: nil)
    private let finishButton = RimePointingHandButton(title: "结束", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")
    private let articleDetail = NSTextField(labelWithString: "")
    private let progressLabel = NSTextField(labelWithString: "0%")
    private let timeLabel = NSTextField(labelWithString: "00:00")
    private let progress = NSProgressIndicator()
    private let targetText = NSTextView(frame: .zero)
    private let editor = TypingTestTextView(frame: .zero, textContainer: nil)
    private let speedCard = MetricsValueCard(title: "有效速度", symbolName: "speedometer")
    private let keysCard = MetricsValueCard(title: "击键", symbolName: "keyboard")
    private let backspaceCard = MetricsValueCard(title: "回退", symbolName: "delete.left")
    private let accuracyCard = MetricsValueCard(title: "过程正确率", symbolName: "scope")
    private let speedChart = MetricsLineChartView()
    private let resultStack = NSStackView()
    private let historyRows = NSStackView()
    private let historySummary = NSTextField(labelWithString: "")
    private let resultDetail = NSTextField(wrappingLabelWithString: "")
    private let storageWarning = NSTextField(wrappingLabelWithString: "")
    private let clearButton = RimePointingHandButton(title: "清空成绩…", target: nil, action: nil)
    private let repairButton = RimePointingHandButton(title: "备份并重建…", target: nil, action: nil)
    private var renderedTargetStates: [TypingTestCharacterState]?

    init(subpageID: String, historyStore: TypingTestHistoryStore = .shared,
         contextProvider: (() -> TypingTestContext)? = nil,
         clockProvider: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         telemetryEnabled: Bool = true) {
        isHistory = subpageID == "history"
        self.historyStore = historyStore
        self.contextProvider = contextProvider
        self.clockProvider = clockProvider
        self.telemetryEnabled = telemetryEnabled
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { nil }
    deinit {
        timer?.invalidate()
        if telemetryEnabled { TypingPracticeTelemetry.shared.deactivate(textView: editor) }
        observers.forEach(NotificationCenter.default.removeObserver)
        workspaceObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        if let sourceObserver { DistributedNotificationCenter.default().removeObserver(sourceObserver) }
    }

    override func loadView() {
        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 14
        content.edgeInsets = NSEdgeInsets(top: 24, left: 26, bottom: 28, right: 26)
        content.translatesAutoresizingMaskIntoConstraints = false
        content.addArrangedSubview(label(isHistory ? "测速成绩" : "文章跟打", size: 25, weight: .semibold))
        let subtitle = label(isHistory ? "同一篇文章、同一输入方案，看见每一次进步" : "8 篇中英文短文 · 原生组字 · 一次专注输入", size: 12)
        subtitle.textColor = RimeUI.textSecondary
        content.addArrangedSubview(subtitle)
        configureControls()
        if isHistory { buildHistory(in: content) } else { buildPractice(in: content) }
        storageWarning.font = .systemFont(ofSize: 11)
        storageWarning.textColor = RimeUI.warningTextColor
        storageWarning.isHidden = true
        content.addArrangedSubview(storageWarning)
        content.arrangedSubviews.forEach {
            $0.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -52).isActive = true
        }
        let document = TypingTestDocumentView()
        document.onDetach = { [weak self] in self?.interrupt(reason: .interrupted, message: "已离开跟打页 · 本次记为练习") }
        document.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            content.topAnchor.constraint(equalTo: document.topAnchor),
            content.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])
        // The settings shell supplies the outer scrolling viewport. Keeping a
        // plain document preserves its intrinsic height and avoids nested clips.
        view = document
        view.identifier = NSUserInterfaceItemIdentifier(isHistory ? "typing-test-history" : "typing-test-practice")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        observe(.typingTestHistoryDidChange) { [weak self] _ in
            guard let self, self.isHistory else { return }
            self.refreshHistory(rebuildContexts: true)
        }
        for name in [Notification.Name.inputConfigurationDidChange, .chordExtensionDidChange,
                     .chordKeymapDidChange, .chordDurationDidChange] {
            observe(name) { [weak self] _ in self?.interrupt(reason: .configurationChanged, message: "方案已改变 · 本次记为练习") }
        }
        for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
            observe(name) { [weak self] notification in
                guard let self, let window = notification.object as? NSWindow,
                      window === self.view.window else { return }
                self.interrupt(reason: .focusLost, message: "窗口已失焦 · 本次记为练习")
            }
        }
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in self?.interrupt(reason: .interrupted, message: "会话已暂停 · 本次记为练习") })
        }
        sourceObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, self.isArmed,
                  RimeInputSourceAuthority.currentInputSourceID() != self.frozenSourceID else { return }
            self.interrupt(reason: .inputSourceChanged, message: "输入源已改变 · 本次记为练习")
        }
        if isHistory { refreshHistory(rebuildContexts: true) } else { resetArticle() }
    }

    override func viewWillDisappear() {
        interrupt(reason: .interrupted, message: "已离开跟打页 · 本次记为练习")
        super.viewWillDisappear()
    }
    private func observe(_ name: Notification.Name, action: @escaping (Notification) -> Void) {
        observers.append(NotificationCenter.default.addObserver(forName: name, object: nil,
                                                                 queue: .main, using: action))
    }

    private func configureControls() {
        for article in TypingTestArticles.all {
            articlePicker.addItem(withTitle: "\(article.title)  ·  \(article.displayLength)")
            articlePicker.lastItem?.representedObject = article.id
        }
        articlePicker.target = self
        articlePicker.action = #selector(articleChanged)
        articlePicker.setAccessibilityLabel("选择测速文章")
        articlePicker.selectItem(at: TypingTestArticles.all.firstIndex { $0.id == selectedArticle.id } ?? 0)
        contextPicker.target = self
        contextPicker.action = #selector(contextChanged)
        contextPicker.setAccessibilityLabel("筛选输入方案与文章版本")
        startButton.target = self
        startButton.action = #selector(startTapped)
        startButton.bezelStyle = .rounded
        finishButton.target = self
        finishButton.action = #selector(finishTapped)
        finishButton.bezelStyle = .rounded
        finishButton.refusesFirstResponder = true
        startButton.refusesFirstResponder = true
        finishButton.isEnabled = false
        clearButton.target = self
        clearButton.action = #selector(clearHistoryTapped)
        clearButton.bezelStyle = .rounded
        repairButton.target = self
        repairButton.action = #selector(repairHistoryTapped)
        repairButton.bezelStyle = .rounded
        repairButton.isHidden = true
        articleDetail.font = .systemFont(ofSize: 11)
        articleDetail.textColor = RimeUI.textSecondary
        statusLabel.font = .systemFont(ofSize: 11, weight: .medium)
        statusLabel.textColor = RimeUI.textSecondary
        statusLabel.lineBreakMode = .byTruncatingTail
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 15, weight: .medium)
        progressLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 1
        progress.style = .bar
        progress.controlSize = .small
        targetText.isEditable = false
        targetText.isSelectable = true
        targetText.drawsBackground = false
        targetText.textContainerInset = NSSize(width: 14, height: 12)
        targetText.setAccessibilityLabel("跟打原文，绿色为正确，红色为待改，灰色为未输入")
        editor.isEditable = false
        editor.onPhysicalKey = { [weak self] event in
            guard let self else { return }
            TypingPracticeTelemetry.shared.noteLocalKey(event, textView: self.editor)
        }
        editor.onCompositionStarted = { [weak self] in
            guard let self, self.isArmed else { return }
            self.session?.start(at: self.now)
        }
        editor.onCommittedText = { [weak self] text, insertion in self?.committedTextChanged(text, insertion: insertion) }
        editor.onWillResignFocus = { [weak self] in self?.session?.markPractice(reason: .focusLost) }
        editor.onFocusLost = { [weak self] in
            self?.interrupt(reason: .focusLost, message: "输入区已失焦 · 本次记为练习")
        }
        editor.onAssistedInput = { [weak self] in
            self?.session?.markPractice(reason: .assistedInput)
            self?.statusLabel.stringValue = "已阻止粘贴或辅助输入 · 本次记为练习"
        }
        [resultStack, historyRows].forEach {
            $0.orientation = .vertical
            $0.alignment = .leading
            $0.spacing = 10
        }
        resultDetail.font = .systemFont(ofSize: 11)
        resultDetail.textColor = RimeUI.textSecondary
        resultDetail.maximumNumberOfLines = 4
        speedChart.emptyMessage = "开始输入后，速度曲线会在这里生长"
        speedChart.xAxisLabel = isHistory ? "测次" : "用时"
        speedChart.translatesAutoresizingMaskIntoConstraints = false
        speedChart.heightAnchor.constraint(equalToConstant: 165).isActive = true
    }

    private func buildPractice(in content: NSStackView) {
        let random = iconButton("shuffle", help: "随机选择另一篇文章", action: #selector(randomTapped))
        articlePicker.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        content.addArrangedSubview(row([articlePicker, random, flexible(), startButton, finishButton]))
        content.addArrangedSubview(articleDetail)
        content.addArrangedSubview(metricRow([speedCard, keysCard, backspaceCard, accuracyCard]))
        content.addArrangedSubview(row([statusLabel, flexible(), timeLabel]))
        content.addArrangedSubview(row([progress, progressLabel]))
        progress.setContentHuggingPriority(.defaultLow, for: .horizontal)
        content.addArrangedSubview(textPanel(title: "原文", detail: "正确  /  待改  /  未输入", textView: targetText, height: 202))
        content.addArrangedSubview(textPanel(title: "输入", detail: "首键计时 · 组字不判错", textView: editor, height: 152))
        content.addArrangedSubview(resultStack)
        resultStack.isHidden = true
        content.addArrangedSubview(label("速度轨迹", size: 12, weight: .semibold))
        content.addArrangedSubview(speedChart)
        let rules = label("计时含思考与纠错 · 标点逐字对照 · 仅保存成绩，不保存输入正文", size: 10)
        rules.textColor = RimeUI.textMuted
        rules.toolTip = "中文有效速度 = 正确字符 ÷ 总分钟；英文 WPM = 正确字符 ÷ 5 ÷ 总分钟。过程正确率保留改正前的错误，最终字准单独展示。"
        content.addArrangedSubview(rules)
    }
    private func buildHistory(in content: NSStackView) {
        content.addArrangedSubview(row([articlePicker, flexible(), repairButton, clearButton]))
        content.addArrangedSubview(contextPicker)
        content.addArrangedSubview(articleDetail)
        content.addArrangedSubview(metricRow([speedCard, keysCard, backspaceCard, accuracyCard]))
        historySummary.font = .systemFont(ofSize: 12, weight: .medium)
        content.addArrangedSubview(historySummary)
        speedChart.emptyMessage = "这篇文章还没有成绩，去完成第一次跟打吧"
        speedChart.onSelectSample = { [weak self] id in self?.selectHistoryResult(id: id) }
        content.addArrangedSubview(speedChart)
        content.addArrangedSubview(resultStack)
        resultStack.isHidden = true
        content.addArrangedSubview(historyRows)
        let privacy = label("只比较同篇、同版、同方案；非正式练习不连入成绩曲线。正文不进入历史。", size: 10)
        privacy.textColor = RimeUI.textMuted
        content.addArrangedSubview(privacy)
    }
    private var now: TimeInterval { clockProvider() }

    @objc private func articleChanged() {
        guard let id = articlePicker.selectedItem?.representedObject as? String,
              let article = TypingTestArticles.article(id: id) else { return }
        interrupt(reason: .interrupted, message: "已切换文章")
        selectedArticle = article
        if isHistory { refreshHistory(rebuildContexts: true) } else { resetArticle() }
    }
    @objc private func randomTapped() {
        guard let article = TypingTestArticles.all.filter({ $0.id != selectedArticle.id }).randomElement(),
              let index = TypingTestArticles.all.firstIndex(where: { $0.id == article.id }) else { return }
        articlePicker.selectItem(at: index)
        articleChanged()
    }
    @objc private func contextChanged() { refreshHistory(rebuildContexts: false) }

    private func resetArticle() {
        timer?.invalidate(); timer = nil
        session = nil; latestSnapshot = nil; isArmed = false
        editor.acceptsTestInput = false
        editor.isEditable = false
        editor.resetForTest()
        articleDetail.stringValue = "\(selectedArticle.theme)  ·  \(selectedArticle.difficulty)  ·  \(selectedArticle.displayLength)"
        statusLabel.stringValue = "准备好后开始，第一枚按键触发计时"
        startButton.title = "开始跟打"
        finishButton.isEnabled = false
        resultStack.isHidden = true
        speedChart.samples = []
        speedChart.unit = selectedArticle.language == .english ? "WPM" : "字/分"
        timeLabel.stringValue = "00:00"
        progress.doubleValue = 0
        progressLabel.stringValue = "0%"
        updateMetricCards(nil)
        renderedTargetStates = nil
        renderTarget(states: [])
        refreshStorageWarning()
    }

    @objc private func startTapped() {
        if isArmed { interrupt(reason: .interrupted, message: "已重新开始") }
        resetArticle()
        let context = contextProvider?() ?? currentContext()
        frozenSourceID = context.inputSourceID
        session = TypingTestSession(article: selectedArticle, context: context)
        isArmed = true
        editor.isEditable = true
        editor.acceptsTestInput = true
        view.window?.makeFirstResponder(editor)
        if telemetryEnabled { TypingPracticeTelemetry.shared.activate(textView: editor, sink: self) }
        startButton.title = "重新开始"
        finishButton.isEnabled = true
        statusLabel.stringValue = context.mode == .practice ? "重练 · 从第一个字开始" : "首次挑战 · 从第一个字开始"
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.refreshLive() }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func currentContext() -> TypingTestContext {
        let sourceID = RimeInputSourceAuthority.currentInputSourceID()
        let own = sourceID.map { RimeInputSourceAuthority.isOwnInputSourceID($0) } ?? false
        let schema = own ? InputConfigurationStore.shared.selectedSchemaID : (sourceID ?? "unknown")
        let isChord = own && ChordExtensionStore.isChordSchema(schema)
        let keymap = isChord ? ChordKeymapStore.shared.activeProfile : nil
        let revision = keymap.flatMap { profile -> String? in
            guard let data = try? ChordKeymapStore.shared.exportData(profile) else { return nil }
            return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                + String(format: ":%.3f", ChordSettings.duration)
        }
        let prior = historyStore.results.contains {
            $0.articleID == selectedArticle.id && $0.articleVersion == selectedArticle.version
                && $0.context.schemaID == schema && $0.context.keymapRevision == revision
                && $0.context.inputSourceID == sourceID
        }
        return TypingTestContext(schemaID: schema, keymapID: keymap?.id,
                                       mode: prior ? .practice : .firstAttempt,
                                       chordCountingAvailable: isChord, inputSourceID: sourceID,
                                       keymapRevision: revision)
    }

    func practiceKey(_ event: NSEvent, isComposing: Bool) {
        guard isArmed, let session else { return }
        session.recordKey(at: now, isRepeat: event.isARepeat,
                          isBackspace: event.keyCode == 51,
                          isComposing: isComposing)
        refreshLive()
    }
    func practiceChord(schemaID: String) {
        guard isArmed, schemaID == session?.context.schemaID else { return }
        session?.recordChord(at: now)
        refreshLive()
    }
    func practiceBackspaceBecameComposition() {
        guard isArmed else { return }
        session?.reclassifyBackspaceAsComposition()
        refreshLive()
    }
    private func committedTextChanged(_ text: String, insertion: Range<Int>?) {
        guard isArmed, let session else { return }
        guard session.reconcileCommittedText(text, at: now, explicitInsertionRange: insertion) else {
            interrupt(reason: .assistedInput, message: "输入超出测速范围 · 本次记为练习")
            return
        }
        refreshLive()
        if latestSnapshot?.canComplete == true { completeSession() }
    }
    private func refreshLive() {
        guard isArmed, let session else { return }
        let snapshot = session.snapshot(at: now)
        latestSnapshot = snapshot
        render(snapshot)
    }
    private func render(_ snapshot: TypingTestSnapshot) {
        let metrics = snapshot.metrics
        updateMetricCards(metrics)
        timeLabel.stringValue = Self.duration(metrics.elapsedSeconds)
        progress.doubleValue = metrics.progress
        progressLabel.stringValue = String(format: "%.0f%%", metrics.progress * 100)
        renderTarget(states: snapshot.targetStates)
        speedChart.samples = metrics.speedSamples.enumerated().map { index, sample in
            MetricsChartSample(id: String(index), label: Self.duration(sample.elapsedSeconds),
                               value: selectedArticle.language == .english ? sample.effectiveCPM / 5 : sample.effectiveCPM,
                               position: sample.elapsedSeconds)
        }
    }
    @objc private func finishTapped() {
        if editor.hasMarkedText() {
            statusLabel.stringValue = "请先确认或取消当前组字，再结束"
            view.window?.makeFirstResponder(editor)
            return
        }
        completeSession()
    }
    private func completeSession() {
        guard isArmed, let session else { return }
        finish(session: session, message: nil)
    }
    private func interrupt(reason: TypingTestPracticeReason, message: String) {
        guard isArmed, !isStopping, let session else { return }
        session.markPractice(reason: reason)
        finish(session: session, message: message)
    }
    private func finish(session: TypingTestSession, message: String?) {
        guard !isStopping else { return }
        if contextProvider == nil, RimeInputSourceAuthority.currentInputSourceID() != frozenSourceID {
            session.markPractice(reason: .inputSourceChanged)
        }
        isStopping = true; isArmed = false
        if telemetryEnabled { TypingPracticeTelemetry.shared.deactivate(textView: editor) }
        timer?.invalidate(); timer = nil
        editor.acceptsTestInput = false
        editor.isEditable = false
        finishButton.isEnabled = false
        startButton.title = "同篇重练"
        if let result = session.finish(at: now) {
            latestSnapshot = session.snapshot(at: now)
            if let snapshot = latestSnapshot { render(snapshot) }
            let saved = historyStore.add(result)
            renderResult(result)
            statusLabel.stringValue = message ?? (saved ? (result.isComplete ? "本次完成 · 成绩已保存" : "提前结束 · 已保存为练习") : "本次结束 · 成绩未能保存")
        } else {
            session.cancel()
            statusLabel.stringValue = message ?? "尚未输入，不产生空成绩"
        }
        refreshStorageWarning()
        isStopping = false
    }

    private func updateMetricCards(_ metrics: TypingTestMetrics?) {
        let english = selectedArticle.language == .english
        speedCard.update(value: metrics.map { Self.number(english ? $0.wordsPerMinute : $0.effectiveCPM) } ?? "—",
                         unit: english ? "WPM" : "字/分", detail: "正确成文字符 ÷ 总分钟；英文每 5 字符折算一词。")
        keysCard.update(value: metrics.map { String($0.physicalKeyCount) } ?? "—",
                        unit: metrics.map { "键 · \(Self.number($0.keysPerSecond))/秒" } ?? "键",
                        detail: metrics.map { "\(Self.number($0.keysPerSecond)) 键/秒；自动重复 \($0.repeatKeyCount) 次" } ?? "物理按键与并击拍数分开计算")
        backspaceCard.update(value: metrics.map { String($0.backspaceCount) } ?? "—", unit: "次",
                             detail: metrics.map { "组字退格 \($0.compositionBackspaceCount) · 上屏退格 \($0.committedBackspaceCount) · 删除 \($0.deletedCharacterCount) 字符" } ?? "组字退格与上屏回改分开记录")
        accuracyCard.update(value: metrics?.processAccuracy.map { Self.number($0 * 100) } ?? "—", unit: "%",
                            detail: "正确提交尝试 ÷ 全部提交尝试；改正不会抹去先前错误，未上屏组字不判错。")
    }
    private func renderResult(_ result: TypingTestResult) {
        clear(resultStack)
        resultStack.isHidden = false
        let metrics = result.metrics
        let final = MetricsValueCard(title: "最终字准", symbolName: "checkmark.circle")
        final.update(value: metrics.finalAccuracy.map { Self.number($0 * 100) } ?? "—", unit: "%")
        let correction = MetricsValueCard(title: "回改", symbolName: "arrow.uturn.backward")
        correction.update(value: String(metrics.correctionCount), unit: "次", detail: "实际删除 \(metrics.deletedCharacterCount) 字符")
        let chord = MetricsValueCard(title: "并击拍数", symbolName: "waveform.path")
        chord.update(value: metrics.chordCount.map(String.init) ?? "—", unit: "拍", detail: "仅记录可信 RIMES 并击事件；缺少数据不当作零。")
        let cards = metricRow([final, correction, chord])
        resultStack.addArrangedSubview(cards)
        cards.widthAnchor.constraint(equalTo: resultStack.widthAnchor).isActive = true
        resultDetail.stringValue = "错 \(metrics.substitutionCount) · 漏 \(metrics.omissionCount) · 多 \(metrics.extraCharacterCount)　｜　\(result.context.schemaID)　｜　\(result.context.mode == .firstAttempt ? "首次" : "重练")\(result.practiceReasons.isEmpty ? "" : " · 非正式练习")"
        resultDetail.toolTip = "文章版本 \(result.articleVersion)；组字退格 \(metrics.compositionBackspaceCount)，上屏退格 \(metrics.committedBackspaceCount)；码长 \(metrics.codeLength.map(Self.number) ?? "—") 键/字。"
        resultStack.addArrangedSubview(resultDetail)
        resultDetail.widthAnchor.constraint(equalTo: resultStack.widthAnchor).isActive = true
    }

    private func renderTarget(states: [TypingTestCharacterState]) {
        guard renderedTargetStates != states else { return }
        renderedTargetStates = states
        let attributed = NSMutableAttributedString(string: "")
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 6
        paragraph.paragraphSpacing = 10
        for (index, character) in selectedArticle.text.enumerated() {
            let state = index < states.count ? states[index] : .pending
            var color = RimeUI.textMuted
            var background = NSColor.clear
            switch state {
            case .correct: color = RimeUI.accentTextColor
            case .incorrect, .omitted:
                color = RimeUI.dangerTextColor
                background = RimeUI.dangerFillColor.withAlphaComponent(0.13)
            case .pending: break
            }
            attributed.append(NSAttributedString(string: String(character), attributes: [
                .font: NSFont.systemFont(ofSize: 18), .foregroundColor: color,
                .backgroundColor: background, .paragraphStyle: paragraph,
            ]))
        }
        targetText.textStorage?.setAttributedString(attributed)
        if let index = states.firstIndex(of: .pending), index > 0 {
            let prefix = String(selectedArticle.text.prefix(index))
            targetText.scrollRangeToVisible(NSRange(location: (prefix as NSString).length, length: 0))
        }
    }

    private func refreshHistory(rebuildContexts: Bool) {
        let articleResults = historyStore.results.filter { $0.articleID == selectedArticle.id }
            .sorted { $0.completedAt > $1.completedAt }
        if rebuildContexts {
            let selected = contextPicker.selectedItem?.representedObject as? String
            contextPicker.removeAllItems()
            var seen = Set<String>()
            for result in articleResults where seen.insert(Self.comparisonKey(result)).inserted {
                let revision = result.context.keymapRevision.map { " · \($0.prefix(6))" } ?? ""
                contextPicker.addItem(withTitle: "\(result.context.schemaID) · 文章 v\(result.articleVersion)\(revision)")
                contextPicker.lastItem?.representedObject = Self.comparisonKey(result)
                contextPicker.lastItem?.toolTip = "\(result.context.inputSourceID ?? "未知输入源") · \(result.context.keymapID ?? "普通键位") · \(result.context.keymapRevision ?? "")"
            }
            if contextPicker.numberOfItems == 0 { contextPicker.addItem(withTitle: "暂无输入方案记录") }
            if let selected, let item = contextPicker.itemArray.first(where: { $0.representedObject as? String == selected }) {
                contextPicker.select(item)
            }
        }
        let key = contextPicker.selectedItem?.representedObject as? String
        let results = articleResults.filter { Self.comparisonKey($0) == key }
        articleDetail.stringValue = "\(selectedArticle.theme) · \(selectedArticle.displayLength) · \(results.count) 次记录"
        updateMetricCards(results.first?.metrics)
        resultStack.isHidden = true
        historySummary.stringValue = results.isEmpty ? "等待你的第一次成绩" : "最近成绩 · \(results.filter(\.isComplete).count) 次完成"
        let visible = Array(results.prefix(30))
        speedChart.unit = selectedArticle.language == .english ? "WPM" : "字/分"
        speedChart.samples = visible.reversed().map { result in
            MetricsChartSample(id: result.id.uuidString, label: Self.shortDate(result.completedAt),
                               value: result.isComparable ? result.displaySpeed : nil,
                               detail: "\(result.context.mode == .firstAttempt ? "首次" : "重练")\(result.practiceReasons.isEmpty ? "" : " · 练习")")
        }
        clear(historyRows)
        for result in visible {
            let icon = NSImageView()
            icon.image = NSImage(systemSymbolName: result.isComparable ? "checkmark.circle.fill" : "pause.circle", accessibilityDescription: nil)
            icon.contentTintColor = result.isComparable ? RimeUI.accentGreen : RimeUI.warningTextColor
            let speed = label(Self.number(result.displaySpeed), size: 22, weight: .semibold)
            speed.font = .monospacedDigitSystemFont(ofSize: 22, weight: .semibold)
            let caption = label("\(Self.shortDate(result.completedAt))  ·  \(result.context.mode == .firstAttempt ? "首次" : "重练")\(result.practiceReasons.isEmpty ? "" : " · 练习")", size: 11)
            caption.textColor = RimeUI.textSecondary
            let accuracy = label("\(result.metrics.processAccuracy.map { Self.number($0 * 100) } ?? "—")%", size: 13, weight: .medium)
            accuracy.toolTip = "过程正确率；最终字准 \(result.metrics.finalAccuracy.map { Self.number($0 * 100) } ?? "—")%"
            let detail = row([icon, speed, label(speedChart.unit, size: 10), flexible(), caption, accuracy])
            detail.edgeInsets = NSEdgeInsets(top: 9, left: 12, bottom: 9, right: 12)
            let box = roundedBox(detail)
            box.identifier = NSUserInterfaceItemIdentifier(result.id.uuidString)
            box.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(historyRowClicked(_:))))
            box.toolTip = "查看这次成绩的最终字准、回改与并击数据"
            historyRows.addArrangedSubview(box)
            box.widthAnchor.constraint(equalTo: historyRows.widthAnchor).isActive = true
        }
        if results.isEmpty {
            let empty = label("在「文章跟打」完成练习后，这里会显示速度趋势与成绩。", size: 12)
            empty.textColor = RimeUI.textSecondary
            historyRows.addArrangedSubview(empty)
        }
        refreshStorageWarning()
    }
    @objc private func historyRowClicked(_ gesture: NSClickGestureRecognizer) {
        guard let id = gesture.view?.identifier?.rawValue else { return }
        selectHistoryResult(id: id)
    }
    private func selectHistoryResult(id: String) {
        guard let result = historyStore.results.first(where: { $0.id.uuidString == id }),
              result.articleID == selectedArticle.id else { return }
        speedChart.selectedSampleID = id
        updateMetricCards(result.metrics)
        historySummary.stringValue = "\(Self.shortDate(result.completedAt)) · \(result.context.mode == .firstAttempt ? "首次挑战" : "同篇重练")"
        renderResult(result)
    }
    private static func comparisonKey(_ result: TypingTestResult) -> String {
        "\(result.articleVersion)|\(result.language.rawValue)|\(result.context.schemaID)|\(result.context.keymapID ?? "")|\(result.context.keymapVersion.map(String.init) ?? "")|\(result.context.keymapRevision ?? "")|\(result.context.inputSourceID ?? "")"
    }
    private func refreshStorageWarning() {
        if let issue = historyStore.storageIssue {
            storageWarning.stringValue = "成绩存储暂不可用，原文件不会被覆盖。\(issue)"
            storageWarning.isHidden = false
            repairButton.isHidden = false
            clearButton.isEnabled = false
        } else {
            storageWarning.isHidden = true
            repairButton.isHidden = true
            clearButton.isEnabled = !historyStore.results.isEmpty
        }
    }

    @objc private func clearHistoryTapped() {
        confirm(title: "清空文章跟打成绩？", detail: "只删除本机文章跟打的成绩记录，无法撤销。日常统计与原来的输入速度历史不会改变。", button: "清空成绩") { [weak self] in
            guard let self else { return }
            _ = self.historyStore.clearAll()
            self.refreshHistory(rebuildContexts: true)
        }
    }
    @objc private func repairHistoryTapped() {
        confirm(title: "备份并重建跟打成绩库？", detail: "无法读取的原路径条目会原样移到同目录的备份，再创建空成绩库；不会读取符号链接目标，也不影响日常统计。", button: "备份并重建") { [weak self] in
            guard let self else { return }
            _ = self.historyStore.repairReadOnlyStore()
            self.refreshHistory(rebuildContexts: true)
        }
    }
    private func confirm(title: String, detail: String, button: String, action: @escaping () -> Void) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "取消")
        if let window = view.window {
            alert.beginSheetModal(for: window) { if $0 == .alertFirstButtonReturn { action() } }
        } else {
            alert.window.appearance = RimeUI.appKitAppearance
            if alert.runModal() == .alertFirstButtonReturn { action() }
        }
    }

    private func textPanel(title: String, detail: String, textView: NSTextView, height: CGFloat) -> NSView {
        let explanation = label(detail, size: 10)
        explanation.textColor = RimeUI.textMuted
        let header = row([label(title, size: 11, weight: .semibold), flexible(), explanation])
        header.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 0, right: 14)
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = textView
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: height - 32).isActive = true
        let stack = NSStackView(views: [header, scroll])
        stack.orientation = .vertical
        stack.spacing = 5
        stack.alignment = .leading
        header.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        scroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return roundedBox(stack)
    }
    private func roundedBox(_ content: NSView) -> NSView {
        let box = TypingTestSurfaceView()
        box.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            content.topAnchor.constraint(equalTo: box.topAnchor),
            content.bottomAnchor.constraint(equalTo: box.bottomAnchor),
        ])
        return box
    }
    private func row(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10
        return stack
    }
    private func metricRow(_ views: [NSView]) -> NSStackView {
        let stack = row(views)
        stack.distribution = .fillEqually
        return stack
    }
    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = RimeUI.textPrimary
        field.lineBreakMode = .byTruncatingTail
        return field
    }
    private func flexible() -> NSView {
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return spacer
    }
    private func iconButton(_ symbol: String, help: String, action: Selector) -> NSButton {
        let button = RimePointingHandButton(title: "", target: self, action: action)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: help)
        button.bezelStyle = .rounded
        button.toolTip = help
        return button
    }
    private func clear(_ stack: NSStackView) {
        stack.arrangedSubviews.forEach { stack.removeArrangedSubview($0); $0.removeFromSuperview() }
    }
    private static func number(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        return String(format: value >= 100 ? "%.0f" : "%.1f", value)
    }
    private static func duration(_ seconds: TimeInterval) -> String {
        let value = max(0, Int(seconds.isFinite ? seconds : 0))
        return String(format: "%02d:%02d", value / 60, value % 60)
    }
    private static func shortDate(_ time: TimeInterval) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM.dd HH:mm"
        return formatter.string(from: Date(timeIntervalSince1970: time))
    }
    /// Isolated rendering hooks: no user window, keyboard event, or live store mutation.
    func prepareForSmoke(articleID: String, committedText: String = "") {
        _ = view
        guard let article = TypingTestArticles.article(id: articleID) else { return }
        selectedArticle = article
        articlePicker.selectItem(at: TypingTestArticles.all.firstIndex { $0.id == articleID } ?? 0)
        if isHistory { refreshHistory(rebuildContexts: true); return }
        resetArticle()
        if !committedText.isEmpty {
            let smoke = TypingTestSession(article: article, context: TypingTestContext(schemaID: "smoke"))
            smoke.start(at: 10)
            for index in 0..<committedText.count { smoke.recordKey(at: 10 + Double(index) * 0.08) }
            _ = smoke.reconcileCommittedText(committedText, at: 20)
            editor.string = committedText
            render(smoke.snapshot(at: 20))
        }
    }
    var smokeArticleCount: Int { articlePicker.numberOfItems }
    var smokeTargetString: String { targetText.string }
    var smokeEditor: TypingTestTextView { editor }
    var smokeChart: MetricsLineChartView { speedChart }
    var smokeIsArmed: Bool { isArmed }
    var smokeHasTimer: Bool { timer?.isValid == true }
    var smokeSessionSnapshot: TypingTestSnapshot? { session?.snapshot(at: now) }
    func smokeStartByButton() { startButton.performClick(nil) }
    func smokeFinishByButton() { finishButton.performClick(nil) }
}

private final class TypingTestDocumentView: NSView {
    var onDetach: (() -> Void)?
    private var wasAttached = false
    override var isFlipped: Bool { true }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { wasAttached = true }
        else if wasAttached { onDetach?() }
    }
}

private final class TypingTestSurfaceView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
        RimeUI.surface.setFill(); path.fill()
        RimeUI.border.setStroke(); path.lineWidth = 1; path.stroke()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
