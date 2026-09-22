import UIKit
#if KEYBOARD_LAYOUT_TESTS
@testable import RIMES
#endif
import RimesCore
import Translation

final class KeyboardViewController: UIInputViewController {
    #if KEYBOARD_LAYOUT_TESTS
    var layoutProxy = LayoutTestDocumentProxy()
    var layoutNeedsInputModeSwitchKey: Bool?
    override var needsInputModeSwitchKey: Bool { layoutNeedsInputModeSwitchKey ?? super.needsInputModeSwitchKey }
    override var textDocumentProxy: any UITextDocumentProxy { layoutProxy }
    #endif
    private let initializationStart = ProcessInfo.processInfo.systemUptime
    private let metrics = KeyboardMetrics()
    private let engine = MobileEngine()
    private lazy var delivery = ProxyTextDelivery(controller: self) { [weak self] in self?.onscreen ?? false }
    private let store = ConfigurationStore(), secrets = KeychainStore()
    private var config = AppConfiguration()
    private var scheme: InputScheme = .pinyin
    private var snapshot = EngineSnapshot()
    private var buffer = BufferSession()
    private var bufferEnabled = false
    private var liveTyping = BufferLiveTypingMetrics()
    private var autoClock = DefaultBufferClock()
    private var autoTimer: Timer?
    private var autoTarget: UUID?
    private var autoSuspended = false
    private var defaultDelay = UserDefaults.standard.double(forKey: "defaultBuffer.autoDelay")
    private let typingStats = UILabel(), sourceBlocks = BufferBlockStrip()
    private var isDefaultBuffer: Bool { bufferEnabled && selectedPlugin == nil }
    var defaultClockNow: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    private var uptime: TimeInterval { defaultClockNow() }
    private let preferencesStore = KeyboardPreferenceStore()
    private var preferences = KeyboardPreferences()
    private let runner = BufferPluginRunner()
    private let appleTranslation = AppleTranslationPlugin()
    private var selectedPlugin: String?
    private var languages: [Locale.Language] = []
    private var translationLanguageMenu: UIMenu?
    private let insertButton = InsertKeycapButton(), stopButton = KeycapButton()
    private var needsPluginResult: Bool { selectedPlugin != nil }
    private var realtime: Bool { selectedPlugin == appleTranslation.descriptor.id }

    private var currentDocument: UUID?
    private var onscreen = false
    private var expanded = false
    private let bottom = UIStackView(), candidateStrip = CandidateStrip()
    private var bottomKeyWidths: [NSLayoutConstraint] = []
    private var compactTypingKeys: Bool { surface.chordMode && !surface.numeric && !surface.emojiMode }
    private let status = UILabel(), source = UITextView(), result = UITextView(), surface = KeySurface()
    private let bufferPanel = UIView(), insertionSlot = UIView(), candidatePanel = UIView()
    private let bufferButton = KeycapButton(), aiButton = KeycapButton(), moreButton = KeycapButton()
    private let deleteButton = RepeatKeycapButton()
    private var deletionTarget: UUID?
    private var directEnglish: Bool { scheme == .english || preferences.englishInput }
    private let globe = KeycapButton(), numbers = KeycapButton(), shiftButton = KeycapButton(), spaceKey = KeycapButton()
    private var height: NSLayoutConstraint!
    private var previousWidth: CGFloat = 0
    private var chordPreview = ""
    private var hasComposition: Bool { !snapshot.preedit.isEmpty || surface.isChordActive }
    private var compositionText: String { [snapshot.preedit, chordPreview].filter { !$0.isEmpty }.joined(separator: " ") }
    private var consentThisSession = Set<String>()
    private var aiAction: AIAction = .polish
    private struct InsertionContext: Equatable {
        var target: UUID?, revision: UUID, plugin: String?, blocks: [String]
    }
    private var pressedInsertion: InsertionContext?
    private var insertionContext: InsertionContext {
        InsertionContext(target: currentDocument, revision: buffer.sourceRevision, plugin: selectedPlugin,
                         blocks: needsPluginResult ? buffer.pluginPending : buffer.pending)
    }
    override func viewDidLoad() {
        super.viewDidLoad()
        preferences = preferencesStore.load(); surface.feedback.enabled = preferences.haptics; surface.feedback.strength = preferences.hapticStrength
        view.backgroundColor = .systemGroupedBackground
        height = view.heightAnchor.constraint(equalToConstant: 240); height.isActive = true
        for item in [bufferPanel, candidatePanel, surface, bottom, status] { view.addSubview(item) }
        candidatePanel.addSubview(bufferButton); candidatePanel.addSubview(candidateStrip); candidatePanel.addSubview(moreButton)
        typingStats.font = .monospacedDigitSystemFont(ofSize: 16, weight: .medium)
        typingStats.textAlignment = .center
        typingStats.textColor = .secondaryLabel; typingStats.adjustsFontSizeToFitWidth = true; typingStats.minimumScaleFactor = 0.8
        typingStats.accessibilityIdentifier = "keyboard.buffer.metrics"
        bufferPanel.addSubview(typingStats); bufferPanel.addSubview(sourceBlocks)
        bufferPanel.addSubview(aiButton); bufferPanel.addSubview(insertionSlot)
        configure(bufferButton, "") { [weak self] in self?.toggleBuffer() }
        bufferButton.symbol("square.stack.3d.up", label: L("Buffer 开关", "Toggle Buffer"))
        configure(aiButton, "") {}; aiButton.showsMenuAsPrimaryAction = true
        configure(moreButton, "") {}; moreButton.symbol("gearshape", label: L("键盘设置", "Keyboard settings")); moreButton.showsMenuAsPrimaryAction = true
        moreButton.addAction(UIAction { [weak self] _ in self?.surface.cancel(); self?.insertButton.cancelPress(); self?.deleteButton.cancelPress() }, for: .touchDown)
        insertButton.symbol("paperplane", label: L("插入下一块", "Insert next block"))
        insertButton.accessibilityHint = L("单击逐块上屏，长按一秒插入全部", "Tap for the next block; hold one second to insert all")
        insertButton.addAction(UIAction { [weak self] _ in self?.surface.feedback.send(.press) }, for: .touchDown)
        insertButton.onPressBegan = { [weak self] in self?.pressedInsertion = self?.insertionContext }
        insertButton.onInsert = { [weak self] action in
            guard let self, self.pressedInsertion == self.insertionContext else { return }
            self.deliver(all: action == .all)
        }
        configure(stopButton, "") { [weak self] in
            self?.cancelRequest(); self?.status.text = L("已停止；继续编辑后重新翻译", "Stopped; edit to translate again"); self?.render()
        }
        stopButton.symbol("stop.fill", label: L("停止处理", "Stop processing"))
        insertionSlot.addSubview(insertButton); insertionSlot.addSubview(stopButton)
        candidateStrip.onSelect = { [weak self] index in
            guard let self else { return }; self.surface.cancel(); self.receive(self.engine.candidate(index))
        }
        candidateStrip.onPress = { [weak self] in self?.surface.feedback.send(.press) }
        candidateStrip.onExpand = { [weak self] in self?.expanded.toggle(); self?.resize() }
        for (textView, name) in [(source, "source"), (result, "result")] {
            textView.isEditable = false; textView.isSelectable = false
            textView.textContainerInset = .init(top: 3, left: 4, bottom: 3, right: 4)
            textView.layer.cornerRadius = 7; textView.accessibilityIdentifier = "keyboard.buffer.\(name)"
            bufferPanel.addSubview(textView)
        }
        refreshPluginMenu(); refreshLanguageMenu()
        if #available(iOS 26, *) {
            Task { [weak self] in
                let languages = await LanguageAvailability().supportedLanguages
                guard let self else { return }; self.languages = languages.sorted { $0.minimalIdentifier < $1.minimalIdentifier }; self.refreshLanguageMenu()
            }
        }
        surface.onTypingPress = { [weak self] in self?.noteTypingKey() }
        surface.onKey = { [weak self] in self?.type($0) }
        surface.onEmoji = { [weak self] text in
            guard let self, self.onscreen else { return }
            self.surface.cancel(); self.settle(); self.insert(text); self.render()
        }
        surface.onLanguageToggle = { [weak self] in self?.toggleLanguage() }
        surface.onModeChanged = { [weak self] in self?.render() }
        surface.onPreview = { [weak self] value in
            guard let self else { return }; self.chordPreview = value; self.render()
        }
        surface.onChord = { [weak self] resolution in
            guard let self else { return }; self.chordPreview = ""
            guard let resolution else { self.render(); return }
            self.type(resolution.input, chord: true)
        }
        bottom.distribution = .fill; bottom.spacing = 4
        configure(globe, "") {}; globe.symbol("globe", label: L("下一键盘", "Next keyboard"))
        globe.addTarget(self, action: #selector(handleInputModeList(from:with:)), for: .allTouchEvents)
        configure(numbers, "123") { [weak self] in
            guard let self else { return }; self.surface.cancel(); self.settle(); self.surface.numeric.toggle()
            self.numbers.setTitle(self.surface.numeric ? "ABC" : "123", for: .normal); self.render()
        }
        configure(shiftButton, "") { [weak self] in
            self?.toggleShift()
        }
        shiftButton.symbol("shift", label: L("大写切换", "Shift"))
        configure(spaceKey, "") { [weak self] in self?.noteTypingKey(); self?.space() }; spaceKey.symbol("space", label: L("空格", "Space"))
        deleteButton.symbol("delete.left", label: L("删除", "Delete"))
        deleteButton.onPressBegan = { [weak self] in
            guard let self, self.onscreen, let target = self.currentDocument,
                  target == DocumentIdentity.read(self.textDocumentProxy) else { return false }
            self.noteTypingKey(backspace: true)
            self.deletionTarget = target
            self.surface.cancel(); self.insertButton.cancelPress()
            return true
        }
        deleteButton.onDelete = { [weak self] in
            guard let self, self.onscreen, self.deletionTarget == self.currentDocument,
                  self.currentDocument == DocumentIdentity.read(self.textDocumentProxy) else { return false }
            self.backspace(); self.surface.feedback.send(.press); return self.onscreen
        }
        let enter = button("") { [weak self] in self?.noteTypingKey(); self?.enter() }; enter.symbol("return", label: L("回车", "Return"))
        for item in [globe, numbers, shiftButton, spaceKey, deleteButton, enter] { bottom.addArrangedSubview(item) }
        // The functional widths never depend on the optional globe; its removal widens Space.
        for item in [globe, numbers, shiftButton, deleteButton, enter] {
            let width = item.widthAnchor.constraint(equalTo: bottom.widthAnchor, multiplier: 1 / 7.5, constant: -20 / 7.5)
            width.priority = .defaultHigh; width.isActive = true; bottomKeyWidths.append(width)
        }
        spaceKey.widthAnchor.constraint(greaterThanOrEqualTo: numbers.widthAnchor, multiplier: 2.5).isActive = true
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabel; status.numberOfLines = 2
        for (item, id) in [(bufferButton, "buffer"), (aiButton, "plugin"), (insertButton, "insert"), (stopButton, "stop"), (moreButton, "more"), (globe, "globe"), (spaceKey, "space"), (shiftButton, "shift"), (deleteButton, "delete"), (enter, "enter")] {
            item.accessibilityIdentifier = "keyboard.\(id)"
        }
        NotificationCenter.default.addObserver(self, selector: #selector(protect), name: .NSExtensionHostWillResignActive, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(resume), name: .NSExtensionHostDidBecomeActive, object: nil)
        render()
    }
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated); onscreen = true; reloadPreferences()
        if currentDocument != DocumentIdentity.read(textDocumentProxy) { delivery.abandonMarkedText(); cancelRequest(); buffer = .init() }; currentDocument = DocumentIdentity.read(textDocumentProxy); choose(preferences.scheme); render()
    }
    override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); metrics.presented(since: initializationStart) }
    override func viewWillDisappear(_ animated: Bool) { protect(); super.viewWillDisappear(animated) }
    @objc private func resume() {
        guard isViewLoaded, view.window != nil else { return }
        onscreen = true; currentDocument = DocumentIdentity.read(textDocumentProxy)
        reloadPreferences(); choose(preferences.scheme); render()
    }
    @objc private func protect() {
        stopDefaultAutoSend(); liveTyping.reset()
        deleteButton.cancelPress(); surface.shifted = false; shiftButton.isSelected = false
        metrics.sampleMemory(); metrics.save()
        delivery.discardMarkedText()
        onscreen = false; consentThisSession.removeAll(); surface.retire(); cancelRequest(); engine.clear(); snapshot = .init(); buffer = .init(); bufferEnabled = false; selectedPlugin = nil; status.text = ""; refreshPluginMenu(); render()
    }
    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) { deleteButton.cancelPress(); insertButton.cancelPress(); surface.retire(); super.viewWillTransition(to: size, with: coordinator); coordinator.animate(alongsideTransition: { _ in self.resize() }) }
    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        delivery.finishDocumentResetIfNeeded()
        if currentDocument != DocumentIdentity.read(textDocumentProxy) {
            // A field change within this visible session stops work for the old
            // target, but keeps unsubmitted blocks for another explicit insertion.
            // Hiding/resigning the keyboard ends the session and clears the draft.
            deleteButton.cancelPress(); delivery.abandonMarkedText(); cancelRequest(); engine.clear(); snapshot = .init(); chordPreview = ""; surface.retire()
            stopDefaultAutoSend(); autoSuspended = true; liveTyping.reset()
            currentDocument = DocumentIdentity.read(textDocumentProxy); render()
        }
        if !hasFullAccess && selectedPlugin?.hasPrefix("ai.") == true { cancelRequest(); render() }
    }
    override func selectionWillChange(_ textInput: UITextInput?) {
        stopDefaultAutoSend(); autoSuspended = true
        deleteButton.cancelPress(); abandonHostComposition()
        super.selectionWillChange(textInput)
    }
    override func textWillChange(_ textInput: UITextInput?) {
        abandonHostComposition()
        super.textWillChange(textInput)
    }
    private func abandonHostComposition() {
        guard !bufferEnabled, delivery.hasMarkedText else { return }
        delivery.abandonMarkedText(); engine.clear(); snapshot = .init(); chordPreview = ""
        cancelRequest(); surface.retire(); render()
    }
    private func configure(_ button: KeycapButton, _ title: String, action: @escaping () -> Void) {
        button.setTitle(title, for: .normal)
        button.addAction(UIAction { [weak self] _ in self?.surface.feedback.send(.press) }, for: .touchDown)
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
    }
    private func button(_ title: String, action: @escaping () -> Void) -> KeycapButton {
        let button = KeycapButton(); configure(button, title, action: action); return button
    }
    private func choose(_ value: InputScheme) {
        deleteButton.cancelPress()
        engine.clear(); snapshot = .init(); chordPreview = ""; surface.cancel(); scheme = value
        surface.profile = config.keyboardChord; surface.chordMode = value == .chord; surface.numeric = false; surface.shifted = false
        surface.chordLayout = preferences.chordLayout; surface.englishInput = directEnglish
        if value != .english {
            let schema = value == .chord && surface.profile.outputEncoding == .ziranma ? "rimes_ziranma" : value.schemaID
            if !engine.select(schema: schema) { status.text = L("输入引擎不可用，请切换英文或其他键盘", "Engine unavailable. Switch to English or another keyboard.") }
        }
        shiftButton.isSelected = false; numbers.setTitle("123", for: .normal)
        refreshMoreMenu()
    }
    private func receive(_ state: EngineSnapshot) {
        snapshot = state
        if !state.preedit.isEmpty && realtime { cancelRequest() }
        if !state.commit.isEmpty { insert(state.commit) }
        render()
    }
    private func commitRawInput() {
        guard !engine.rawInput.isEmpty else { return }
        let text = engine.literalInput
        engine.clear(); snapshot = .init(); chordPreview = ""
        if !text.isEmpty { insert(text) }
        render()
    }
    private func toggleShift() {
        deleteButton.cancelPress(); surface.cancel()
        if !surface.shifted { commitRawInput() }
        surface.shifted.toggle(); shiftButton.isSelected = surface.shifted; render()
    }
    private func toggleLanguage() {
        guard onscreen else { return }
        deleteButton.cancelPress(); surface.cancel(); commitRawInput()
        preferences.toggleLanguage(); preferencesStore.save(preferences)
        if scheme != preferences.scheme { choose(preferences.scheme) }
        surface.shifted = false; shiftButton.isSelected = false
        surface.englishInput = directEnglish; render()
    }
    private func changeLayout(_ layout: ChordLayout) {
        deleteButton.cancelPress(); insertButton.cancelPress(); surface.retire()
        preferences.chordLayout = layout
        preferencesStore.save(preferences)
        surface.chordLayout = layout; render()
    }
    private func toggleScript() {
        guard onscreen else { return }
        surface.cancel(); insertButton.cancelPress()
        preferences.traditional.toggle(); preferencesStore.save(preferences)
        engine.traditional = preferences.traditional
        snapshot = engine.currentSnapshot
        render()
    }
    private func insert(_ text: String) {
        guard onscreen else { return }
        if bufferEnabled { if isDefaultBuffer { liveTyping.noteCommit(characterCount: text.count, at: uptime) }; cancelRequest(); buffer.insert(text); sourceChanged() } else if let target = currentDocument { _ = delivery.insert(text,target:target) }
    }
    private func type(_ text: String, chord: Bool = false) {
        let start = ProcessInfo.processInfo.systemUptime; defer { metrics.processed(since: start) }
        guard onscreen else { return }; status.text = ""
        if directEnglish || surface.shifted { insert(surface.shifted ? text.uppercased() : text); render(); return }
        guard engine.available else { return }
        for scalar in text.unicodeScalars {
            let (state, handled) = engine.handledKey(Int32(scalar.value), generatedSeparator: chord && scalar.value == 39); receive(state)
            if !handled { insert(String(scalar)) }
        }
        render()
    }
    private func settle() {
        guard !snapshot.preedit.isEmpty else { return }
        if !snapshot.candidates.isEmpty { receive(engine.candidate(0)) }
        else { receive(engine.process(key: 0xff0d)) }
    }
    private func space() { surface.cancel(); if !snapshot.preedit.isEmpty { settle() } else { insert(" "); render() } }
    private func enter() { surface.cancel(); if !engine.rawInput.isEmpty { commitRawInput() } else { insert("\n"); render() } }
    private func backspace() {
        guard onscreen, currentDocument == DocumentIdentity.read(textDocumentProxy) else { deleteButton.cancelPress(); return }
        surface.cancel(); if !engine.rawInput.isEmpty { receive(engine.process(key: 0xff08)) }
        else if bufferEnabled { cancelRequest(); buffer.backspace(); sourceChanged(); render() }
        else if let target = currentDocument { _ = delivery.deleteBackward(target:target) }
    }
    private func toggleBuffer() { stopDefaultAutoSend(); autoSuspended = false; liveTyping.reset(); deleteButton.cancelPress(); surface.cancel(); settle(); bufferEnabled.toggle(); if !bufferEnabled { cancelRequest(); selectedPlugin = nil; refreshPluginMenu() }; bufferButton.isSelected = bufferEnabled; render() }
    private func render() {
        if onscreen {
            if bufferEnabled { delivery.discardMarkedText() }
            else if let target = currentDocument { delivery.updateMarkedText(compositionText, target: target) }
        }
        candidateStrip.update(snapshot.candidates); renderBuffer(); resize()
    }
    private func renderBuffer() {
        bufferPanel.isHidden = !bufferEnabled; bufferButton.isSelected = bufferEnabled
        let display = BufferComposition(source: buffer.source, cursor: buffer.cursor, preedit: compositionText,
                                        font: .systemFont(ofSize: view.bounds.width > 600 ? 14 : 15))
        source.attributedText = display.text; source.scrollRangeToVisible(display.caretRange)
        source.isHidden = isDefaultBuffer
        sourceBlocks.isHidden = !isDefaultBuffer
        if isDefaultBuffer {
            sourceBlocks.update(source: buffer.source, cursor: buffer.cursor, preedit: compositionText,
                                font: .systemFont(ofSize: view.bounds.width > 600 ? 16 : 18))
        }
        result.isHidden = isDefaultBuffer
        result.text = isDefaultBuffer ? "" : buffer.generating ? L("处理中… ", "Working… ") + buffer.preview : (needsPluginResult ? buffer.pluginPending.joined() : buffer.pending.joined())
        aiButton.isHidden = !bufferEnabled
        insertionSlot.isHidden = !bufferEnabled
        stopButton.isHidden = !buffer.generating; insertButton.isHidden = buffer.generating
        let hasOutput = needsPluginResult ? !buffer.pluginPending.isEmpty : !buffer.pending.isEmpty
        insertButton.isEnabled = hasOutput && !buffer.generating && !hasComposition
        if pressedInsertion != insertionContext { insertButton.cancelPress() }
        refreshMoreMenu(); refreshDefaultBuffer()
    }
    /// Only the auxiliaries change height. The typing block stays at a fixed offset
    /// from the system's bottom edge, including while a chord is being held.
    private func layoutRows(width: CGFloat) -> [(UIView, CGFloat)] {
        let landscape = width > 600
        bottom.spacing = compactTypingKeys ? 2 : 4
        for case let button as KeycapButton in bottom.arrangedSubviews where button.compactCap != compactTypingKeys {
            button.compactCap = compactTypingKeys
        }
        for constraint in bottomKeyWidths { constraint.constant = -5 * bottom.spacing / 7.5 }
        candidateStrip.expanded = expanded; candidateStrip.landscape = landscape
        candidateStrip.isHidden = false
        status.isHidden = status.text?.isEmpty != false
        globe.isHidden = !onscreen || !needsInputModeSwitchKey
        let bufferHeight: CGFloat = landscape ? 60 : 76
        return [(status, 28), (bufferPanel, bufferHeight),
                (candidatePanel, max(32, candidateStrip.fittingHeight(width: width - 82))),
                (surface, KeyboardGeometry.height(layout: surface.chordLayout, chord: surface.chordMode, numeric: surface.numeric, emoji: surface.emojiMode, landscape: landscape, width: max(1, width - 10), profile: surface.profile)), (bottom, landscape ? 34 : 40)].filter { !$0.0.isHidden }
    }
    private func resize() {
        guard height != nil else { return }
        let rows = layoutRows(width: view.bounds.width)
        height.constant = rows.reduce(CGFloat(10)) { $0 + $1.1 } + CGFloat(max(0, rows.count - 1)) * 4 - (compactTypingKeys ? 3 : 0)
        view.setNeedsLayout()
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if previousWidth != view.bounds.width { previousWidth = view.bounds.width; resize() }
        let rows = layoutRows(width: view.bounds.width)
        var y = view.bounds.height - 5
        for (item, rowHeight) in rows.reversed() {
            y -= rowHeight; item.frame = CGRect(x: 5, y: y, width: max(0, view.bounds.width - 10), height: rowHeight); y -= item === bottom && compactTypingKeys ? 1 : 4
        }
        let landscape = view.bounds.width > 600
        let bufferRowHeight: CGFloat = landscape ? 28 : 36
        result.frame = CGRect(x: 0, y: 0, width: max(0, bufferPanel.bounds.width - 36), height: bufferRowHeight)
        typingStats.frame = CGRect(x: 36, y: 0, width: max(0, bufferPanel.bounds.width - 72), height: bufferRowHeight)
        typingStats.font = .monospacedDigitSystemFont(ofSize: landscape ? 14 : 16, weight: .medium)
        insertionSlot.frame = CGRect(x: bufferPanel.bounds.width - 32, y: 0, width: 32, height: bufferRowHeight)
        aiButton.frame = CGRect(x: 0, y: bufferRowHeight + 4, width: 32, height: bufferRowHeight)
        source.frame = CGRect(x: 36, y: bufferRowHeight + 4, width: max(0, bufferPanel.bounds.width - 36), height: bufferRowHeight)
        sourceBlocks.frame = source.frame
        bufferButton.frame = CGRect(x: 0, y: 0, width: 32, height: 32)
        candidateStrip.frame = CGRect(x: 36, y: 0, width: max(0, candidatePanel.bounds.width - 72), height: candidatePanel.bounds.height)
        moreButton.frame = CGRect(x: candidatePanel.bounds.width - 32, y: 0, width: 32, height: 32)
        result.font = .systemFont(ofSize: landscape ? 14 : 15)
        bottom.layoutIfNeeded()
        insertButton.frame = insertionSlot.bounds; stopButton.frame = insertionSlot.bounds
    }
    private func noteTypingKey(backspace: Bool = false) {
        guard isDefaultBuffer else { return }
        liveTyping.noteKey(at: uptime, isRepeat: false, isBackspace: backspace)
    }
    private func stopDefaultAutoSend() {
        autoTimer?.invalidate(); autoTimer = nil; autoClock.reset(); autoTarget = nil
    }
    private func setDefaultDelay(_ delay: Double) {
        stopDefaultAutoSend(); defaultDelay = delay; autoSuspended = false
        UserDefaults.standard.set(delay, forKey: "defaultBuffer.autoDelay")
    }
    private func refreshDefaultBuffer() {
        typingStats.isHidden = !isDefaultBuffer
        guard isDefaultBuffer, onscreen else { stopDefaultAutoSend(); return }
        let stats = (BufferLiveTypingMetricsFormatter.line(for: liveTyping) ?? BufferLiveTypingMetricsFormatter.idleLine)
            .replacingOccurrences(of: "码长", with: "触/字").replacingOccurrences(of: "击键", with: "触")
        let enabled = [1.0, 2, 3, 5].contains(defaultDelay) && !autoSuspended
        typingStats.text = stats + (enabled ? String(format: " · %.1fs", max(0, defaultDelay - autoClock.headAge)) : "")
        guard enabled, !buffer.pending.isEmpty, buffer.retainedResults.isEmpty, buffer.result == nil, let target = currentDocument,
              target == DocumentIdentity.read(textDocumentProxy) else { stopDefaultAutoSend(); return }
        if autoTarget != target { stopDefaultAutoSend(); autoTarget = target }
        autoClock.synchronize(buffer.pending)
        if hasComposition || buffer.generating { autoClock.pause() }
        guard autoTimer == nil else { return }
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.tickDefaultBuffer() }
        autoTimer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    private func tickDefaultBuffer() {
        guard onscreen, isDefaultBuffer, !autoSuspended, let target = autoTarget,
              target == currentDocument, target == DocumentIdentity.read(textDocumentProxy) else { stopDefaultAutoSend(); return }
        autoClock.synchronize(buffer.pending)
        if autoClock.tick(at: uptime, lifetime: defaultDelay, canAge: !hasComposition && !buffer.generating && !insertButton.isHighlighted) {
            if !deliver(all: false) { stopDefaultAutoSend(); autoSuspended = true }
        }
        refreshDefaultBuffer()
    }
    private func refreshMoreMenu() {
        let levels: [(String, HapticStrength?)] = [(L("关闭", "Off"), nil), (L("轻", "Light"), .light), (L("强", "Strong"), .strong), (L("更强", "Stronger"), .strongest)]
        let haptics = UIMenu(title: L("按键触感", "Key haptics"), children: levels.map { title, strength in
            UIAction(title: title, state: (strength == nil ? !preferences.haptics : preferences.haptics && preferences.hapticStrength == strength) ? .on : .off) { [weak self] _ in
                guard let self else { return }
                self.preferences.haptics = strength != nil
                if let strength { self.preferences.hapticStrength = strength }
                self.preferencesStore.save(self.preferences)
                self.surface.feedback.enabled = self.preferences.haptics
                self.surface.feedback.strength = self.preferences.hapticStrength
                self.surface.feedback.send(.commit); self.refreshMoreMenu()
            }
        })
        let schemes = UIMenu(title: L("输入方案", "Input scheme"), image: UIImage(systemName: "keyboard"), children: InputScheme.allCases.map { value in
            UIAction(title: value.title, state: value == scheme ? .on : .off) { [weak self] _ in
                guard let self else { return }
                self.settle(); self.preferences.select(value); self.preferencesStore.save(self.preferences)
                self.choose(value); self.render()
            }
        })
        var items: [UIMenuElement] = [schemes, UIAction(title: L("繁体输出", "Traditional Chinese output"), state: preferences.traditional ? .on : .off) { [weak self] _ in self?.toggleScript() }]
        if scheme == .chord {
            let labels: [ChordLayout: String] = [.orthogonal: L("无中缝正交", "Orthogonal"), .splitOrthogonal: L("有中缝正交", "Split orthogonal")]
            let layouts: [UIMenuElement] = ChordLayout.allCases.map { layout in
                UIAction(title: labels[layout]!, state: preferences.chordLayout == layout ? .on : .off) { [weak self] _ in self?.changeLayout(layout) }
            }
            items.append(UIMenu(title: L("并击布局", "Chord layout"), children: layouts))
        }
        if !surface.hasUtilityCells {
            items.append(UIAction(title: directEnglish ? L("切换中文", "Switch to Chinese") : L("切换英文", "Switch to English"), image: UIImage(systemName: "globe")) { [weak self] _ in self?.toggleLanguage() })
            items.append(UIAction(title: L("表情", "Emoji"), image: UIImage(systemName: "face.smiling")) { [weak self] _ in self?.surface.showEmoji() })
        }
        if bufferEnabled {
            if isDefaultBuffer {
                items.append(UIMenu(title: L("Default 延迟上屏", "Default automatic insertion"), children: [0.0, 1, 2, 3, 5].map { delay in
                    UIAction(title: delay == 0 ? L("关闭", "Off") : "\(Int(delay)) s", state: defaultDelay == delay && !autoSuspended ? .on : .off) { [weak self] _ in
                        guard let self else { return }
                        self.setDefaultDelay(delay); self.render()
                    }
                }))
            }
            if realtime, let translationLanguageMenu { items.append(translationLanguageMenu) }
            let source = UIAction(title: L("插入原文", "Insert source"), image: UIImage(systemName: "text.insert"), attributes: buffer.source.isEmpty || buffer.generating ? [.disabled] : []) { [weak self] _ in self?.deliverSource() }
            let left = UIAction(title: L("光标左移", "Move cursor left"), image: UIImage(systemName: "arrow.left")) { [weak self] _ in self?.settle(); self?.buffer.moveCursor(-1); self?.render() }
            let right = UIAction(title: L("光标右移", "Move cursor right"), image: UIImage(systemName: "arrow.right")) { [weak self] _ in self?.settle(); self?.buffer.moveCursor(1); self?.render() }
            let clear = UIAction(title: L("清空 Buffer", "Clear Buffer"), image: UIImage(systemName: "trash"), attributes: [.destructive]) { [weak self] _ in
                guard let self else { return }; self.surface.cancel(); self.cancelRequest(); self.engine.clear(); self.snapshot = .init(); self.buffer = .init(); self.status.text = ""; self.render()
            }
            items += [source, UIMenu(title: L("光标", "Cursor"), children: [left, right]), clear]
        }
        items.append(haptics); moreButton.menu = UIMenu(children: items)
    }
    @discardableResult private func deliver(all: Bool) -> Bool {
        surface.cancel(); if !snapshot.preedit.isEmpty { settle(); return false }
        guard onscreen, !buffer.generating, currentDocument == DocumentIdentity.read(textDocumentProxy) else { return false }
        let blocks = needsPluginResult ? buffer.pluginPending : buffer.pending
        let text = all ? blocks.joined() : blocks.first ?? ""
        guard !text.isEmpty, let target = currentDocument, delivery.insert(text, target: target) else { return false }
        if needsPluginResult { buffer.consumePlugin(all: all) } else { autoClock.consumed(all: all); buffer.consumed(all: all) }
        // Delivery is not a source edit: never schedule a translation of a remainder.
        surface.feedback.send(.commit); render(); return true
    }
    private func deliverSource() {
        surface.cancel(); if !snapshot.preedit.isEmpty { settle(); return }
        guard onscreen, !buffer.generating, !buffer.source.isEmpty,
              let target = currentDocument, delivery.insert(buffer.source, target: target) else { return }
        cancelRequest(); buffer.consumeSource(); surface.feedback.send(.commit); render()
    }
    private func cancelRequest() { insertButton.cancelPress(); pressedInsertion = nil; runner.cancel(); buffer.cancel() }
    private func reloadPreferences() {
        config = store.load(); preferences = preferencesStore.load()
        preferences.reconcile(scheme: config.scheme, revision: config.schemeSelectionRevision)
        preferencesStore.save(preferences); surface.feedback.enabled = preferences.haptics; surface.feedback.strength = preferences.hapticStrength
        engine.traditional = preferences.traditional
        refreshPluginMenu(); refreshLanguageMenu()
    }
    private func refreshPluginMenu() {
        let original = UIAction(title: L("Default · 原文", "Default · Original"), state: selectedPlugin == nil ? .on : .off) { [weak self] _ in
            guard let self else { return }; self.cancelRequest(); self.buffer.invalidateResult(); self.selectedPlugin = nil; self.status.text = ""; self.refreshPluginMenu(); self.render()
        }
        let translate = UIAction(title: appleTranslation.descriptor.title, state: realtime ? .on : .off) { [weak self] _ in
            guard let self else { return }; self.settle(); self.cancelRequest(); self.buffer.invalidateResult(); self.selectedPlugin = self.appleTranslation.descriptor.id; self.refreshPluginMenu(); self.sourceChanged(); self.render()
        }
        let ai = UIMenu(title: L("AI 服务", "AI service"), children: AIAction.allCases.map { action in
            UIAction(title: action.title) { [weak self] _ in self?.aiAction = action; self?.generate() }
        })
        aiButton.menu = UIMenu(children: [original, translate, ai])
        aiButton.symbol(realtime ? "translate" : selectedPlugin == nil ? "puzzlepiece.extension" : "sparkles", label: realtime ? L("苹果翻译", "Apple Translation") : selectedPlugin == nil ? L("选择插件", "Choose plugin") : L("AI 服务", "AI service"))
        aiButton.isSelected = selectedPlugin != nil
        bufferButton.menu = nil
        refreshMoreMenu()
    }
    private func refreshLanguageMenu() {
        let values = languages.isEmpty ? [Locale.Language(identifier: "zh-Hans"), Locale.Language(identifier: "en")] : languages
        func name(_ id: String) -> String { Locale.current.localizedString(forIdentifier: id) ?? id }
        func choices(source: Bool) -> UIMenu {
            UIMenu(title: source ? L("原文语言", "Source language") : L("译文语言", "Target language"), children: values.map { value in
                let id = value.minimalIdentifier
                return UIAction(title: name(id), state: id == (source ? preferences.sourceLanguage : preferences.targetLanguage) ? .on : .off) { [weak self] _ in
                    guard let self else { return }
                    if source { self.preferences.sourceLanguage = id } else { self.preferences.targetLanguage = id }
                    self.languageChanged()
                }
            })
        }
        translationLanguageMenu = UIMenu(title: "\(name(preferences.sourceLanguage)) → \(name(preferences.targetLanguage))", image: UIImage(systemName: "translate"), children: [choices(source: true), choices(source: false), UIAction(title: L("交换方向", "Swap direction")) { [weak self] _ in
            guard let self else { return }; let old = self.preferences.sourceLanguage; self.preferences.sourceLanguage = self.preferences.targetLanguage; self.preferences.targetLanguage = old; self.languageChanged()
        }])
        refreshMoreMenu()
    }
    private func languageChanged() {
        preferencesStore.save(preferences); cancelRequest(); buffer.invalidateResult(); refreshLanguageMenu(); sourceChanged(); render()
    }
    private func sourceChanged() {
        guard realtime, bufferEnabled, onscreen, snapshot.preedit.isEmpty, !buffer.source.isEmpty else { return }
        run(appleTranslation, delay: 400_000_000)
    }
    private func run(_ plugin: any BufferPlugin, delay: UInt64) {
        cancelRequest(); status.text = ""
        let revision = buffer.sourceRevision, id = buffer.begin()
        let networkPlugin = plugin.descriptor.id.hasPrefix("ai.")
        let request = BufferPluginRequest(source: buffer.source, revision: revision, options: ["source": preferences.sourceLanguage, "target": preferences.targetLanguage])
        runner.submit(plugin: plugin, request: request, delayNanoseconds: delay, preview: { [weak self] text in
            guard let self, self.onscreen else { return }; if networkPlugin && !self.hasFullAccess { self.cancelRequest(); self.render(); return }; self.buffer.receive(text, id: id); self.renderBuffer(); self.resize()
        }, completion: { [weak self] result in
            guard let self, self.onscreen, self.buffer.sourceRevision == revision, self.buffer.generation == id else { return }
            if networkPlugin && !self.hasFullAccess { self.cancelRequest(); self.render(); return }
            switch result {
            case .success(let output):
                guard output.revision == revision else { return }; self.buffer.finish(output.text, id: id)
            case .failure(let error):
                self.buffer.cancel(); self.status.text = (error as? LocalizedError)?.errorDescription ?? L("请求未完成，原文已保留", "Request failed; source preserved")
            }
            self.metrics.sampleMemory(); self.metrics.save(); self.render()
        })
        render()
    }
    private func generate() {
        defer { render() }
        surface.cancel(); settle()
        guard onscreen, hasFullAccess, !buffer.source.isEmpty, let provider = config.provider else { status.text = L("请在 RIMES App 中配置 AI 服务", "Configure an AI service in RIMES"); return }
        let identity = provider.consentIdentity
        guard config.consents.contains(identity) || consentThisSession.contains(identity) else {
            let alert = UIAlertController(title: L("发送到 AI 服务", "Send to AI service"), message: "\(provider.name)\n\(identity)\n\n" + L("仅发送当前 Buffer 原文，不读取宿主全文。接收方的数据政策适用。", "Only the current Buffer text will be sent. Host documents are not read. The recipient's data policy applies."), preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: L("取消", "Cancel"), style: .cancel))
            alert.addAction(UIAlertAction(title: L("同意并发送", "Agree and send"), style: .default) { [weak self] _ in self?.consentThisSession.insert(identity); self?.generate() }); present(alert, animated: true); return
        }
        do {
            let key = try secrets.read(provider.id)
            guard !key.isEmpty else { status.text = L("请在 App 中保存 API Key", "Save your API Key in the app"); return }
            cancelRequest(); buffer.invalidateResult(); selectedPlugin = "ai.\(aiAction.rawValue)"; refreshPluginMenu()
            run(AITextPlugin(provider: provider, key: key, consent: identity, action: aiAction), delay: 0)
        } catch { status.text = (error as? CoreError)?.localizedDescription ?? L("无法读取 AI 配置", "Unable to read AI configuration"); render() }
    }
    #if KEYBOARD_LAYOUT_TESTS
    var layoutViews: (buffer: UIView, candidates: CandidateStrip, keys: KeySurface, settings: KeycapButton, bottom: UIStackView, source: UITextView, insert: InsertKeycapButton, globe: KeycapButton, result: UITextView, stop: KeycapButton) {
        (bufferPanel, candidateStrip, surface, moreButton, bottom, source, insertButton, globe, result, stopButton)
    }
    func developmentType(_ text: String) { type(text) }
    func developmentResetPreferences() { preferences = .init(); choose(.pinyin); render() }
    func developmentChoose(_ value: InputScheme) { preferences.select(value); choose(value); render() }
    func developmentChord(_ text: String) { type(text, chord: true) }
    func developmentShift() { toggleShift() }
    func developmentLanguage() { toggleLanguage() }
    func developmentEnter() { enter() }
    func developmentSpace() { space() }
    func developmentBackspace() { backspace() }
    func developmentAutoDelay(_ delay: Double) { setDefaultDelay(delay); render() }
    func developmentAutoTick() { tickDefaultBuffer() }
    var developmentTypingMetrics: BufferLiveTypingMetrics { liveTyping }
    var developmentDelete: RepeatKeycapButton { deleteButton }
    var developmentRaw: String { engine.rawInput }
    func developmentSetLayout(_ value: ChordLayout) { changeLayout(value) }
    func developmentBufferCursor(_ cursor: Int) { buffer.moveCursor(cursor - buffer.cursor); render() }
    var developmentBufferSource: (text: String, revision: UUID) { (buffer.source, buffer.sourceRevision) }
    func developmentContent(preedit: String = "", candidates: [String] = []) {
        snapshot = .init(preedit: preedit, candidates: candidates); render()
    }
    func developmentBuffer(_ text: String?, plugin: Bool = false, output: String? = nil, generating: Bool = false) {
        buffer = .init(); bufferEnabled = text != nil; selectedPlugin = plugin ? appleTranslation.descriptor.id : nil
        if let text { buffer.edit(text) }
        if let output { let id = buffer.begin(); buffer.finish(output, id: id) }
        if generating { _ = buffer.begin() }
        refreshPluginMenu(); render()
    }
    #endif
    #if DEBUG
    /// Hosted rendering test only; never called by an installed keyboard session.
    func developmentLayout(bufferText: String?, expanded: Bool, chord: Bool) -> (UIView, UIView, KeySurface) {
        loadViewIfNeeded(); preferences = .init(); choose(chord ? .chord : .pinyin)
        self.expanded = expanded; bufferEnabled = bufferText != nil
        if let bufferText {
            selectedPlugin = appleTranslation.descriptor.id; buffer.edit(bufferText); let id = buffer.begin(); buffer.finish("Hello, this is the translation preview.", id: id); refreshPluginMenu()
        }
        snapshot = .init(preedit: "nihao", candidates: ["你好", "您好", "你们好", "你好世界", "拟好", "倪皓"])
        render(); return (bufferPanel, candidateStrip, surface)
    }
    #endif

}
