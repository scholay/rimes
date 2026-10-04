import UIKit
#if KEYBOARD_LAYOUT_TESTS
@testable import RIMES
#endif
import RimesCore
import UniformTypeIdentifiers
import Translation

final class KeyboardViewController: UIInputViewController {
    #if KEYBOARD_LAYOUT_TESTS
    var layoutProxy = LayoutTestDocumentProxy()
    var layoutNeedsInputModeSwitchKey: Bool?
    private var developmentPreferencesAreIsolated = false
    private var developmentPluginRoot: URL?
    deinit { if let root = developmentPluginRoot { try? FileManager.default.removeItem(at: root) } }
    override var needsInputModeSwitchKey: Bool { layoutNeedsInputModeSwitchKey ?? super.needsInputModeSwitchKey }
    override var textDocumentProxy: any UITextDocumentProxy { layoutProxy }
    #endif
    private let initializationStart = ProcessInfo.processInfo.systemUptime
    private let metrics = KeyboardMetrics()
    private let engine = MobileEngine()
    private lazy var delivery = ProxyTextDelivery(controller: self) { [weak self] in self?.onscreen ?? false }
    private let store = ConfigurationStore(), secrets = KeychainStore()
    private var resultPluginAuthorization: String?
    private var officialPlugins = try? MobileOfficialPlugins.makeStore()
    private var config = AppConfiguration()
    private var scheme: InputScheme = .pinyin
    private var importedSchemeStore = RimeSchemeStore()
    private var importedSchemeEnglish = false
    private var importedSchemeSelection: RimeSchemeSelection?
    private var importedSchemeLibrary = RimeSchemeLibrary()
    private var snapshot = EngineSnapshot()
    private var buffer = BufferSession()
    private var bufferEnabled = false
    private var liveTyping = BufferLiveTypingMetrics()
    private var autoClock = DefaultBufferClock()
    private var autoTimer: Timer?
    private var autoTarget: UUID?
    private var autoSuspended = false
    private var defaultDelay = UserDefaults.standard.double(forKey: "defaultBuffer.autoDelay")
    private let typingStats = UILabel()
    private var typingCardPreview: TypingCardPreview?
    private var typingCardPNG: Data?
    private var typingCardStore = TypingCardStore()
    private var typingCardSavingPhoto = false
    #if KEYBOARD_LAYOUT_TESTS
    var developmentCardFullAccess: Bool?
    #endif
    private var canExportTypingCard: Bool {
        #if KEYBOARD_LAYOUT_TESTS
        if let developmentCardFullAccess { return developmentCardFullAccess }
        #endif
        return hasFullAccess
    }
    /// Whole-session totals behind the typing signature.
    private var session = TypingSessionTotals()
    /// Keeps the typing readout moving after typing stops.
    private var statsTimer: Timer?
    private var isDefaultBuffer: Bool { bufferEnabled && selectedPlugin == nil }
    var defaultClockNow: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    private var uptime: TimeInterval { defaultClockNow() }
    private let preferencesStore = KeyboardPreferenceStore()
    private var preferences = KeyboardPreferences()
    private let runner = BufferPluginRunner()
    private let appleTranslation = AppleTranslationPlugin()
    private let speaker = BlockSpeaker()
    private var selectedPlugin: KeyboardPlugin?
    private var languages: [Locale.Language] = []
    private let insertButton = InsertKeycapButton(), stopButton = KeycapButton()
    /// AI plugins never run on their own: Run is the only trigger.
    private let runButton = KeycapButton()
    /// Clipboard text that arrived while iOS's paste alert had focus; added once we are back.
    private var pendingPaste: String?
    /// Left of the input line: opens the Buffer/plugin settings panel.
    private let settingsButton = KeycapButton()
    /// Left of the output line: display-only light for the output's state.
    private let statusLight = StatusLight()
    private var lastRunFailed = false
    /// Translate settings rows, kept across renders so the rollers keep their position.
    private let languageRow = LanguagePairRow(), speakRow = PanelSwitchRow()
    private let shortcuts = PluginShortcutBar()
    /// Buffer and plugin settings, drawn over the keys.
    private let panel = KeyboardPanel()
    private var panelOpen = false
    private var needsPluginResult: Bool { selectedPlugin != nil }
    private var realtime: Bool { selectedPlugin == .translate }

    private var currentDocument: UUID?
    private var onscreen = false
    private var expanded = false
    private let bottom = UIStackView(), candidateStrip = CandidateStrip()
    private let handPreview = ChordHandPreviewView()
    private var bottomKeyWidths: [NSLayoutConstraint] = []
    private var spaceMinimumWidth: NSLayoutConstraint?
    private var customLayoutSnapshot: CustomKeyboardLayout?
    private var syncingCustomLayout = false
    private let customGlobeSpacer = UIView()
    private let customEmojiKey = KeycapButton(), customBufferKey = KeycapButton()
    private let symbolsKey = KeycapButton(), separatorKey = KeycapButton(), spellingKey = KeycapButton(), punctuationKey = KeycapButton()
    private let spellingStrip = NineKeySpellingStrip()
    private var spellingChoicesOpen = false
    private var symbolPage = false
    private lazy var nineKeySpelling: NineKeyPinyin = {
        let url = Bundle.main.url(forResource: "EngineData", withExtension: nil)?.appendingPathComponent("nine-key-syllables.json")
        let syllables = url.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
        return NineKeyPinyin(syllables: syllables)
    }()
    private var customFunctions: [CustomKeyAction: UIView] {
        [.space: spaceKey, .backspace: deleteButton, .enter: returnKey, .shift: shiftButton,
         .numbers: numbers, .language: bottomLanguage, .emoji: customEmojiKey, .buffer: customBufferKey]
    }
    private var standardFunctions: [StandardKeyControl: UIView] {
        var values = Dictionary(uniqueKeysWithValues: customFunctions.compactMap { key, value in
            StandardKeyControl(rawValue: key.rawValue).map { ($0, value) }
        })
        values[.symbols] = symbolsKey; values[.separator] = separatorKey
        values[.spelling] = spellingKey; values[.punctuation] = punctuationKey
        return values
    }
    private var usesNineKeyEngine: Bool { preferences.ordinaryLayout == .nineKey && customLayoutSnapshot == nil && scheme == .pinyin && importedSchemeSelection == nil }
    private var usesNineKey: Bool { usesNineKeyEngine && !directEnglish && !surface.shifted && !surface.numeric && !surface.emojiMode }
    private var compactTypingKeys: Bool { surface.chordMode && !surface.numeric && !surface.emojiMode }
    private let status = UILabel(), source = SingleLineTextView(), result = SingleLineTextView(), surface = KeySurface()
    private let bufferPanel = UIView(), insertionSlot = UIView(), candidatePanel = UIView()
    private let bufferButton = KeycapButton(), aiButton = KeycapButton(), moreButton = KeycapButton()
    private let deleteButton = RepeatKeycapButton()
    /// Chord mode swaps Delete into the right-hand 中/EN cell and 中/EN into Delete's slot.
    private let chordDelete = RepeatKeycapButton(), bottomLanguage = KeycapButton()
    private var deletionTarget: UUID?
    /// A held Delete that started on Buffer text stops when the Buffer empties, never
    /// running on into the app's text.
    private var deletingBuffer = false
    private let returnKey = KeycapButton()
    private enum ReturnAction: Equatable { case confirm, insertBuffer, waiting, host }
    private struct ReturnPressContext: Equatable {
        var action: ReturnAction
        var insertion: InsertionContext
        var rawInput: String
        var buffered: Bool
    }
    private var pressedReturn: ReturnPressContext?
    /// The same state drives the label and action in every layout and theme.
    private var returnAction: ReturnAction {
        if hasComposition || !engine.rawInput.isEmpty { return .confirm }
        if bufferEnabled && !bufferIsEmpty {
            if buffer.generating { return .waiting }
            return (needsPluginResult ? buffer.pluginPending : buffer.pending).isEmpty ? .waiting : .insertBuffer
        }
        return .host
    }
    private var returnPressContext: ReturnPressContext {
        .init(action: returnAction, insertion: insertionContext, rawInput: engine.rawInput, buffered: bufferEnabled)
    }
    /// With the Buffer on but empty, Delete and Return act on the app's field directly.
    private var bufferIsEmpty: Bool {
        buffer.source.isEmpty && !hasComposition && !buffer.generating && engine.rawInput.isEmpty
            && (needsPluginResult ? buffer.pluginPending : buffer.pending).isEmpty
    }
    private var editsHost: Bool { !bufferEnabled || bufferIsEmpty }
    /// App text before the caret when it was last known to be ours; nil until read.
    private var hostSnapshot: String?
    /// App text after the caret at that time; dictation never changes it, a caret move does.
    private var hostAfter: String?
    private var captureTimer: Timer?
    private var lastHostTextChange: TimeInterval = -.infinity
    private var directEnglish: Bool { importedSchemeSelection != nil ? importedSchemeEnglish : (scheme == .english || preferences.englishInput) }
    private let globe = KeycapButton(), numbers = KeycapButton(), shiftButton = KeycapButton(), spaceKey = SpaceCursorButton()
    private var caretSteps = 0
    /// Set while a left-half Space hold is extending a Buffer selection.
    private var selectingText = false
    /// Associated words offered after a Chinese commit, shown while nothing is composed.
    private var associations: [String] = []
    /// Last Chinese commit, so the next consecutive one can be learned as its successor.
    private var lastCommitted: String?
    private lazy var associationIndex: AssociationIndex? = Bundle.main.url(forResource: "EngineData", withExtension: nil)
        .flatMap { AssociationIndex(contentsOf: $0.appendingPathComponent("associations.tsv")) }
    private var associationHistory = AssociationHistory()
    private var associationStore = AssociationHistoryStore()
    private var associationHistoryRevision: UUID?
    private var associationHistoryLoaded = false, associationHistoryChanges = 0
    private var showingAssociations: Bool { snapshot.candidates.isEmpty && !associations.isEmpty }
    private var height: NSLayoutConstraint!
    private var hostWidth: NSLayoutConstraint?
    private var chordPreview = ""
    private var hasComposition: Bool { !snapshot.preedit.isEmpty || surface.isChordActive }
    private var compositionText: String {
        var preedit = snapshot.preedit
        if usesNineKey, !preedit.isEmpty, let reading = engine.candidateReadings.first,
           !reading.isEmpty, reading.utf8.allSatisfy({ (97...122).contains($0) || $0 == 32 || $0 == 39 }),
           NineKeyPinyin.digits(for: reading).filter({ $0.isNumber }) == NineKeyPinyin.digits(for: engine.rawInput).filter({ $0.isNumber }) {
            preedit = reading.replacingOccurrences(of: " ", with: "'")
        }
        return [preedit, chordPreview].filter { !$0.isEmpty }.joined(separator: " ")
    }
    private var consentThisSession = Set<String>()
    private struct InsertionContext: Equatable {
        var target: UUID?, revision: UUID, plugin: KeyboardPlugin?, authorization: String?, blocks: [String]
    }
    private var pressedInsertion: InsertionContext?
    /// Smooths streamed output: text arrives in bursts, the line shows it at an even pace.
    private lazy var reveal = StreamReveal(line: result) { [weak self] in self?.render() }
    private var revealGeneration: UUID?
    /// Thinking is shown as readable captions, not a racing ticker.
    private lazy var caption = ThinkingCaption(line: result)
    private var insertionContext: InsertionContext {
        InsertionContext(target: currentDocument, revision: buffer.sourceRevision, plugin: selectedPlugin,
                         authorization: selectedPlugin.flatMap { pluginAuthorization($0.rawValue) }, blocks: needsPluginResult ? buffer.pluginPending : buffer.pending)
    }
    override func viewDidLoad() {
        super.viewDidLoad()
        preferences = preferencesStore.load(); surface.feedback.enabled = preferences.haptics; surface.feedback.strength = preferences.hapticStrength
        surface.feedback.soundEnabled = preferences.keySounds
        view.backgroundColor = .systemGroupedBackground
        // A provisional host frame must not become a competing height constraint.
        view.translatesAutoresizingMaskIntoConstraints = false
        inputView?.allowsSelfSizing = true
        height = view.heightAnchor.constraint(equalToConstant: 240)
        height.identifier = "RIMES.keyboard.contentHeight"
        height.isActive = true
        for item in [bufferPanel, candidatePanel, spellingStrip, surface, bottom, status, panel] { view.addSubview(item) }
        spellingStrip.isHidden = true
        spellingStrip.onSelect = { [weak self] spelling in self?.selectNineKeySpelling(spelling) }
        panel.isHidden = true
        panel.onPress = { [weak self] in self?.surface.feedback.send(.press) }
        panel.onClose = { [weak self] in self?.closePanel() }
        candidatePanel.addSubview(bufferButton); candidatePanel.addSubview(candidateStrip); candidatePanel.addSubview(moreButton); candidatePanel.addSubview(handPreview); candidatePanel.addSubview(shortcuts)
        typingStats.font = .monospacedDigitSystemFont(ofSize: 16, weight: .medium)
        typingStats.textAlignment = .center
        typingStats.textColor = .secondaryLabel; typingStats.adjustsFontSizeToFitWidth = true; typingStats.minimumScaleFactor = 0.8
        typingStats.accessibilityIdentifier = "keyboard.buffer.metrics"
        typingStats.isUserInteractionEnabled = false
        bufferPanel.addSubview(aiButton); bufferPanel.addSubview(insertionSlot); bufferPanel.addSubview(runButton); bufferPanel.addSubview(settingsButton); bufferPanel.addSubview(statusLight)
        statusLight.accessibilityIdentifier = "keyboard.buffer.status"
        // A tap moves to the next look among those chosen in settings.
        statusLight.onCycleSkin = { [weak self] in
            guard let self else { return }
            let skins = StatusSkin.rotation(self.preferences.statusSkinRotation)
            let next = skins.firstIndex(of: self.statusLight.skin.canonical).map { skins[($0 + 1) % skins.count] } ?? skins[0]
            self.surface.feedback.send(.press); self.selectKeyboardTheme(next)
        }
        configureLanguageRows()
        configure(settingsButton, "") { [weak self] in guard let self else { return }; self.panelOpen ? self.closePanel() : self.openSettings(for: self.selectedPlugin) }
        settingsButton.symbol("slider.horizontal.3", label: L("插件与 Buffer 设置", "Plugin and Buffer settings"))
        settingsButton.accessibilityHint = L("打开插件与 Buffer 设置", "Open plugin and Buffer settings")
        configure(runButton, "") { [weak self] in self?.runSelectedPlugin() }
        // Quick Q&A: tapping the empty input line pastes the clipboard as the question.
        source.onTapBackground = { [weak self] in self?.pasteQuestion() }
        runButton.symbol("play.fill", label: L("执行插件", "Run plugin"))
        shortcuts.onPress = { [weak self] in self?.surface.feedback.send(.press) }
        shortcuts.onSelect = { [weak self] plugin in self?.openPlugin(plugin) }
        shortcuts.onSettings = { [weak self] plugin in self?.openSettings(for: plugin) }
        configure(bufferButton, "") { [weak self] in self?.toggleBuffer() }
        bufferButton.symbol("square.stack.3d.up", label: L("Buffer 开关", "Toggle Buffer"))
        bufferButton.accessibilityHint = L("按住打开 Buffer 设置", "Hold for Buffer settings")
        let bufferHold = UILongPressGestureRecognizer(target: self, action: #selector(bufferHeld(_:))); bufferHold.minimumPressDuration = 0.45
        bufferButton.addGestureRecognizer(bufferHold)
        configure(aiButton, "") {}; aiButton.showsMenuAsPrimaryAction = true
        configure(moreButton, "") {}; moreButton.symbol("gearshape", label: L("键盘设置", "Keyboard settings")); moreButton.showsMenuAsPrimaryAction = true
        moreButton.addAction(UIAction { [weak self] _ in self?.surface.cancel(); self?.insertButton.cancelPress(); self?.cancelDeletes() }, for: .touchDown)
        insertButton.symbol("paperplane", label: L("插入下一块", "Insert next block"))
        insertButton.accessibilityHint = L("单击逐块上屏，长按一秒插入全部", "Tap for the next block; hold one second to insert all")
        insertButton.addAction(UIAction { [weak self] _ in self?.surface.feedback.send(.press) }, for: .touchDown)
        insertButton.onPressBegan = { [weak self] in self?.pressedInsertion = self?.insertionContext }
        insertButton.onInsert = { [weak self] action in
            guard let self, self.pressedInsertion == self.insertionContext else { return }
            self.deliver(all: action == .all)
        }
        configure(stopButton, "") { [weak self] in
            guard let self else { return }
            self.cancelRequest(); self.status.text = self.realtime ? L("已停止；继续编辑后重新翻译", "Stopped; edit to translate again") : L("已停止；点 ▶ 重新执行", "Stopped; tap ▶ to run again"); self.render()
        }
        stopButton.symbol("stop.fill", label: L("停止处理", "Stop processing"))
        insertionSlot.addSubview(insertButton); insertionSlot.addSubview(stopButton)
        candidateStrip.onSelect = { [weak self] index in
            guard let self else { return }; self.collapseCandidates(); self.surface.cancel()
            if self.showingAssociations { self.chooseAssociation(index) } else { self.receive(self.engine.candidate(index)) }
        }
        candidateStrip.onPress = { [weak self] in self?.surface.feedback.send(.press) }
        candidateStrip.onExpand = { [weak self] in self?.expanded.toggle(); self?.resize() }
        for (line, name) in [(source, "source"), (result, "result")] {
            line.accessibilityIdentifier = "keyboard.buffer.\(name)"
            bufferPanel.addSubview(line)
        }
        source.role = .input; result.role = .output
        // Tapping an output block reads it aloud without sending it; tap again to hear it again.
        result.onTapBlock = { [weak self] index in self?.readOutputBlock(index) }
        result.onTapBackground = { [weak self] in if self?.isDefaultBuffer == true { self?.showTypingCard() } }
        result.addSubview(typingStats)
        refreshPluginMenu()
        if #available(iOS 26, *) {
            Task { [weak self] in
                let languages = await LanguageAvailability().supportedLanguages
                guard let self else { return }; self.languages = languages.sorted { $0.minimalIdentifier < $1.minimalIdentifier }; self.render()
            }
        }
        surface.onTypingPress = { [weak self] in self?.noteTypingKey() }
        surface.onKey = { [weak self] in self?.type($0) }
        surface.onEmoji = { [weak self] text in
            guard let self, self.onscreen else { return }
            self.surface.cancel(); self.settle(); self.breakAssociationChain(); self.insert(text); self.render()
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
            self.symbolPage = false
            self.numbers.setTitle(self.surface.numeric ? "ABC" : "123", for: .normal); self.render()
        }
        configure(shiftButton, "") { [weak self] in
            self?.toggleShift()
        }
        shiftButton.symbol("shift", label: L("大写切换", "Shift"))
        configure(spaceKey, "") { [weak self] in guard let self, self.spaceKey.consumeTap() else { return }; self.noteTypingKey(); self.space() }
        spaceKey.symbol("space", label: L("空格", "Space"))
        spaceKey.onCursorBegan = { [weak self] half in self?.beginCaretDrag(selecting: half == .left) ?? false }
        spaceKey.onCursorMove = { [weak self] steps in self?.moveCaret(steps) }
        for delete in [deleteButton, chordDelete] {
            delete.symbol("delete.left", label: L("删除", "Delete"))
            delete.onPressBegan = { [weak self, weak delete] in
                guard let self, self.onscreen, let target = self.currentDocument,
                      target == DocumentIdentity.read(self.textDocumentProxy) else { return false }
                self.noteTypingKey(backspace: true)
                self.deletionTarget = target; self.deletingBuffer = !self.editsHost
                self.surface.cancel(); self.insertButton.cancelPress()
                if delete !== self.deleteButton { self.deleteButton.cancelPress() } else { self.chordDelete.cancelPress() }
                return true
            }
            delete.onDelete = { [weak self] in
                guard let self, self.onscreen, self.deletionTarget == self.currentDocument,
                      self.currentDocument == DocumentIdentity.read(self.textDocumentProxy) else { return false }
                if self.deletingBuffer && self.editsHost { return false }
                self.backspace(); self.surface.feedback.send(.press); return self.onscreen
            }
        }
        chordDelete.compactCap = true; chordDelete.titleHorizontalInset = 2
        surface.languageCellView = chordDelete
        configure(bottomLanguage, "中") { [weak self] in self?.toggleLanguage() }
        bottomLanguage.titleLabel?.font = .systemFont(ofSize: 18, weight: .medium)
        let enter = returnKey; configure(enter, "") { [weak self] in
            guard let self else { return }
            defer { self.pressedReturn = nil }
            // A pending block can be auto-inserted while a finger is down. That
            // same release must not turn into the host's Send action.
            if let pressed = self.pressedReturn, pressed != self.returnPressContext { return }
            self.noteTypingKey(); self.enter()
        }
        enter.addAction(UIAction { [weak self] _ in self?.pressedReturn = self?.returnPressContext }, for: .touchDown)
        enter.addAction(UIAction { [weak self] _ in self?.pressedReturn = nil }, for: [.touchCancel, .touchUpOutside])
        enter.titleLabel?.adjustsFontSizeToFitWidth = true; enter.titleLabel?.minimumScaleFactor = 0.7
        for item in [globe, numbers, shiftButton, spaceKey, deleteButton, bottomLanguage, enter] { bottom.addArrangedSubview(item) }
        // The functional widths never depend on the optional globe; its removal widens Space.
        for item in [globe, numbers, shiftButton, deleteButton, bottomLanguage, enter] {
            let width = item.widthAnchor.constraint(equalTo: bottom.widthAnchor, multiplier: 1 / 7.5, constant: -20 / 7.5)
            width.priority = .defaultHigh; width.isActive = true; bottomKeyWidths.append(width)
        }
        spaceMinimumWidth = spaceKey.widthAnchor.constraint(greaterThanOrEqualTo: numbers.widthAnchor, multiplier: 2.5)
        spaceMinimumWidth?.isActive = true
        configure(customEmojiKey, "") { [weak self] in self?.surface.showEmoji() }
        customEmojiKey.symbol("face.smiling", label: L("表情", "Emoji"))
        customEmojiKey.accessibilityIdentifier = "keyboard.custom.emoji"
        configure(customBufferKey, "") { [weak self] in self?.toggleBuffer() }
        customBufferKey.symbol("square.stack.3d.up", label: L("Buffer 开关", "Toggle Buffer"))
        customBufferKey.accessibilityIdentifier = "keyboard.custom.buffer"
        configure(symbolsKey, "#+=") { [weak self] in
            guard let self else { return }; self.settle(); self.surface.numeric = true; self.symbolPage.toggle(); self.render()
        }
        configure(separatorKey, "分隔") { [weak self] in
            guard let self, self.usesNineKey, !self.engine.rawInput.isEmpty, !self.engine.rawInput.hasSuffix("'") else { return }
            self.type("'")
        }
        configure(spellingKey, "选拼音") { [weak self] in
            guard let self else { return }; self.spellingChoicesOpen.toggle(); self.render()
        }
        configure(punctuationKey, "，。?!") {}
        punctuationKey.menu = UIMenu(children: ["，", "。", "？", "！", "、", "：", "；"].map { mark in
            UIAction(title: mark) { [weak self] _ in self?.settle(); self?.insert(mark); self?.render() }
        })
        punctuationKey.showsMenuAsPrimaryAction = true
        for (id, button) in [("symbols", symbolsKey), ("separator", separatorKey), ("spelling", spellingKey), ("punctuation", punctuationKey)] {
            button.accessibilityIdentifier = "keyboard.nineKey.\(id)"
        }
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabel; status.numberOfLines = 2
        for (item, id) in [(bufferButton, "buffer"), (aiButton, "plugin"), (runButton, "plugin.run"), (settingsButton, "buffer.settings"), (insertButton, "insert"), (stopButton, "stop"), (moreButton, "more"), (globe, "globe"), (spaceKey, "space"), (shiftButton, "shift"), (deleteButton, "delete"), (chordDelete, "delete.chord"), (bottomLanguage, "mode.bottom"), (enter, "enter")] {
            item.accessibilityIdentifier = "keyboard.\(id)"
        }
        NotificationCenter.default.addObserver(self, selector: #selector(hostResigned), name: .NSExtensionHostWillResignActive, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(resume), name: .NSExtensionHostDidBecomeActive, object: nil)
        render()
    }
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated); onscreen = true; reloadPreferences()
        if currentDocument != DocumentIdentity.read(textDocumentProxy) { delivery.abandonMarkedText(); cancelRequest(); buffer = .init() }; currentDocument = DocumentIdentity.read(textDocumentProxy); choose(preferences.scheme); render()
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Reinstall our own constraint after the remote host has attached us.
        // An unchanged constant alone does not renegotiate a stale host height.
        height.isActive = false
        updateHeight()
        height.isActive = true
        view.invalidateIntrinsicContentSize()
        view.setNeedsLayout()
        view.superview?.setNeedsLayout()
        releaseEdgeTouchDelay(); metrics.presented(since: initializationStart)
    }
    /// iOS edge-swipe recognizers above the keyboard hold back touches that start
    /// near the screen edges until a swipe is ruled out, so quick taps on the outer
    /// keys feel dead and long presses land late. Keys own their touches: let them
    /// begin immediately. The system gestures themselves stay enabled.
    private func releaseEdgeTouchDelay() {
        var node: UIView? = view
        while let current = node {
            for recognizer in current.gestureRecognizers ?? [] where recognizer.delaysTouchesBegan { recognizer.delaysTouchesBegan = false }
            node = current.superview
        }
    }
    override func viewWillDisappear(_ animated: Bool) { protect(); super.viewWillDisappear(animated) }
    @objc private func resume() {
        guard isViewLoaded, view.window != nil else { return }
        onscreen = true; currentDocument = DocumentIdentity.read(textDocumentProxy)
        reloadPreferences(); choose(preferences.scheme); render()
        applyPendingPaste()
    }
    /// The app lost focus for a moment (a system alert, Notification Center): text is still
    /// cleared, but the Buffer and the open plugin stay, so you carry on where you were.
    @objc private func hostResigned() {
        let mode = (bufferEnabled, selectedPlugin)
        protect()
        bufferEnabled = mode.0; selectedPlugin = mode.1; refreshPluginMenu(); render()
    }
    @objc private func protect() {
        dismissTypingCard(resume: false)
        breakAssociationChain(); saveAssociationHistory()
        stopDefaultAutoSend(); liveTyping.reset()
        returnKey.cancelTracking(with: nil); pressedReturn = nil
        cancelDeletes(); surface.shifted = false; shiftButton.isSelected = false
        metrics.sampleMemory(); metrics.save()
        delivery.discardMarkedText()
        onscreen = false; consentThisSession.removeAll(); speaker.stop(); session.reset(); statsTimer?.invalidate(); statsTimer = nil; surface.retire(); cancelRequest(); engine.clear(); snapshot = .init(); buffer = .init(); bufferEnabled = false; selectedPlugin = nil; panelOpen = false; status.text = ""; refreshPluginMenu(); render()
    }
    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) { cancelDeletes(); insertButton.cancelPress(); surface.retire(); super.viewWillTransition(to: size, with: coordinator); coordinator.animate(alongsideTransition: { _ in self.resize() }) }
    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        delivery.finishDocumentResetIfNeeded()
        hostTextChanged()
        if currentDocument != DocumentIdentity.read(textDocumentProxy) {
            // A field change within this visible session stops work for the old
            // target, but keeps unsubmitted blocks for another explicit insertion.
            // Hiding/resigning the keyboard ends the session and clears the draft.
            cancelDeletes(); delivery.abandonMarkedText(); cancelRequest(); engine.clear(); snapshot = .init(); chordPreview = ""; surface.retire()
            dismissTypingCard(resume: false)
            stopDefaultAutoSend(); autoSuspended = true; liveTyping.reset(); breakAssociationChain()
            currentDocument = DocumentIdentity.read(textDocumentProxy); render()
        }
        if !hasFullAccess && selectedPlugin?.isAI == true { cancelRequest(); render() }
    }
    override func selectionDidChange(_ textInput: UITextInput?) {
        super.selectionDidChange(textInput)
        // A caret move without new text starts over from the new position; dictation
        // moves the caret along with its text, so that case keeps tracking.
        if !delivery.isWriting, ProcessInfo.processInfo.systemUptime - lastHostTextChange > 0.3 {
            captureTimer?.invalidate(); captureTimer = nil; hostSnapshot = nil
        }
    }
    override func selectionWillChange(_ textInput: UITextInput?) {
        if !delivery.isWriting {
            autoClock.pause()
            cancelDeletes(); abandonHostComposition()
        }
        super.selectionWillChange(textInput)
    }
    override func textWillChange(_ textInput: UITextInput?) {
        abandonHostComposition()
        super.textWillChange(textInput)
    }
    // MARK: Dictation into the Buffer
    /// With the Buffer on, text the system writes straight into the app (the dictation
    /// microphone, mainly) is moved into the Buffer once it pauses for a second.
    private func hostTextChanged() {
        captureTimer?.invalidate(); captureTimer = nil
        lastHostTextChange = ProcessInfo.processInfo.systemUptime
        guard bufferEnabled, onscreen, currentDocument != nil else { hostSnapshot = nil; return }
        let ours = delivery.isWriting || ProcessInfo.processInfo.systemUptime - delivery.lastWriteTime < 0.6
        guard !ours, hostSnapshot != nil else { snapshotHost(); return }
        let timer = Timer(timeInterval: 1.0, repeats: false) { [weak self] _ in self?.captureHostText() }
        captureTimer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    private func captureHostText() {
        captureTimer = nil
        guard bufferEnabled, onscreen, let old = hostSnapshot, let target = currentDocument,
              target == DocumentIdentity.read(textDocumentProxy),
              ProcessInfo.processInfo.systemUptime - delivery.lastWriteTime >= 0.6 else { return }
        let now = textDocumentProxy.documentContextBeforeInput ?? ""
        guard (textDocumentProxy.documentContextAfterInput ?? "") == (hostAfter ?? ""),
              let added = Self.appendedText(before: old, after: now), !added.isEmpty, added.count <= 4000 else { snapshotHost(); return }
        for _ in 0..<added.count { guard delivery.deleteBackward(target: target) else { break } }
        hostSnapshot = nil
        surface.cancel(); settle(); insert(added); render()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            guard let self, self.bufferEnabled, self.onscreen, self.hostSnapshot == nil else { return }
            self.snapshotHost()
        }
    }
    private func snapshotHost() {
        hostSnapshot = textDocumentProxy.documentContextBeforeInput ?? ""; hostAfter = textDocumentProxy.documentContextAfterInput ?? ""
    }
    /// Text added at the caret between two readings of the context before it. The proxy
    /// only exposes a window of that context, so an unchanged tail anchors the match.
    static func appendedText(before old: String, after new: String) -> String? {
        if old.isEmpty { return new }
        if new.hasPrefix(old) { return String(new.dropFirst(old.count)) }
        // Longest tail of the earlier text that still appears; the window may have cut its start.
        for length in [16, 12, 8, 6, 4] where length <= old.count {
            if let range = new.range(of: String(old.suffix(length)), options: .backwards) { return String(new[range.upperBound...]) }
        }
        return nil
    }
    private func abandonHostComposition() {
        guard !delivery.isWriting, !bufferEnabled, delivery.hasMarkedText else { return }
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
    private func choose(_ requested: InputScheme) {
        let value: InputScheme = requested == .chord && officialPlugins?.isEnabled(legacyID: "chord") != true ? .pinyin : requested
        cancelDeletes()
        spellingChoicesOpen = false; symbolPage = false
        engine.clear(); snapshot = .init(); chordPreview = ""; surface.cancel()
        var selectedImported = false
        if let selection = importedSchemeSelection {
            selectedImported = engine.selectImported(selection, store: importedSchemeStore)
            if !selectedImported {
                importedSchemeSelection = nil; saveImportedSchemeChoice()
                status.text = L("导入方案无法加载，已恢复原输入方式；可在 App 中检查方案。", "Imported scheme could not load. Restored the previous input mode; check the scheme in the app.")
            }
        }
        scheme = selectedImported ? .pinyin : value
        surface.profile = config.keyboardChord; surface.chordMode = scheme == .chord; surface.numeric = false; surface.shifted = false
        surface.chordLayout = preferences.chordLayout; surface.englishInput = directEnglish
        if !selectedImported && value != .english {
            let schema = usesNineKeyEngine ? "rimes_pinyin9"
                : value == .chord && surface.profile.outputEncoding == .ziranma ? "rimes_ziranma" : value.schemaID
            if !engine.select(schema: schema) { status.text = L("输入引擎不可用，请切换英文或其他键盘", "Engine unavailable. Switch to English or another keyboard.") }
        }
        shiftButton.isSelected = false; numbers.setTitle("123", for: .normal)
        refreshMoreMenu()
    }
    private func receive(_ state: EngineSnapshot) {
        snapshot = state
        if !state.preedit.isEmpty && realtime { cancelRequest() }
        if !state.preedit.isEmpty { associations = [] }
        if !state.commit.isEmpty { insert(state.commit); committed(state.commit, composing: !state.preedit.isEmpty) }
        render()
    }
    // MARK: Associations
    /// Learns `previous → text` for consecutive Chinese commits and, once nothing is
    /// left in composition, offers what usually follows `text`.
    private func committed(_ text: String, composing: Bool) {
        guard onscreen, !directEnglish, Associations.isChinese(text) else { breakAssociationChain(); return }
        if let previous = lastCommitted { learnAssociation(previous: previous, next: text) }
        lastCommitted = text
        associations = composing ? [] : Associations.suggestions(after: text, index: associationIndex, history: loadedAssociationHistory())
    }
    private func chooseAssociation(_ index: Int) {
        guard onscreen, associations.indices.contains(index) else { return }
        let word = associations[index]
        insert(word); committed(word, composing: false); render()
    }
    /// Any key other than a candidate hides associations; edits that are not a
    /// continuation (delete, space, return, cursor, field change) also end learning.
    private func breakAssociationChain() { lastCommitted = nil; associations = [] }
    private func loadedAssociationHistory() -> AssociationHistory {
        if !associationHistoryLoaded || associationHistoryRevision != associationStore.resetRevision {
            associationHistory = associationStore.load(); associationHistoryRevision = associationStore.resetRevision
            associationHistoryLoaded = true
            associationHistoryChanges = 0
        }
        return associationHistory
    }
    private func learnAssociation(previous: String, next: String) {
        _ = loadedAssociationHistory()
        associationHistory.record(previous: previous, next: next); associationHistoryChanges += 1
        if associationHistoryChanges >= 10 { saveAssociationHistory() }
    }
    /// Keyboard-private: never in the App Group, never synced, excluded from backup.
    private func saveAssociationHistory() {
        guard associationHistoryLoaded, associationHistoryChanges > 0 else { return }
        do {
            let saved = try associationStore.save(associationHistory, revision: associationHistoryRevision)
            associationHistoryChanges = 0
            if !saved { associationHistoryLoaded = false; breakAssociationChain() }
        } catch { /* Keep unsaved changes for the next normal save. */ }
    }
    private func applyAssociationReset(_ revision: UUID?) {
        do {
            let cleared = try associationStore.applyReset(revision)
            if cleared || (associationHistoryLoaded && associationHistoryRevision != associationStore.resetRevision) {
                associationHistoryLoaded = false; associationHistoryChanges = 0
                _ = loadedAssociationHistory(); breakAssociationChain()
            }
        } catch { status.text = L("联想记录暂时无法清除，下次打开键盘时会重试", "Could not clear learned associations; will retry when the keyboard reopens") }
    }
    private func commitRawInput() {
        guard !engine.rawInput.isEmpty else { return }
        let text = engine.literalInput
        engine.clear(); snapshot = .init(); chordPreview = ""
        if !text.isEmpty { insert(text) }
        render()
    }
    private func toggleShift() {
        cancelDeletes(); surface.cancel()
        if !surface.shifted { commitRawInput() }
        surface.shifted.toggle(); shiftButton.isSelected = surface.shifted; render()
    }
    private func toggleLanguage() {
        guard onscreen else { return }
        cancelDeletes(); surface.cancel(); commitRawInput()
        if importedSchemeSelection != nil {
            importedSchemeEnglish.toggle(); saveImportedSchemeChoice()
        } else {
            preferences.toggleLanguage(); preferencesStore.save(preferences)
            if scheme != preferences.scheme { choose(preferences.scheme) }
        }
        surface.shifted = false; shiftButton.isSelected = false
        surface.englishInput = directEnglish; render()
    }
    private func changeLayout(_ layout: ChordLayout) {
        cancelDeletes(); insertButton.cancelPress(); surface.retire()
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
        if bufferEnabled { if isDefaultBuffer { liveTyping.noteCommit(characterCount: text.count, at: uptime); session.noteCommit(characterCount: text.count, at: uptime, burst: liveTyping) }; cancelRequest(); buffer.insert(text); sourceChanged() } else if let target = currentDocument { _ = delivery.insert(text,target:target) }
    }
    private func type(_ text: String, chord: Bool = false) {
        let start = ProcessInfo.processInfo.systemUptime; defer { metrics.processed(since: start) }
        guard onscreen else { return }; status.text = ""
        if usesNineKeyEngine && surface.numeric { breakAssociationChain(); insert(text); render(); return }
        if directEnglish || surface.shifted { breakAssociationChain(); insert(surface.shifted ? text.uppercased() : text); render(); return }
        guard engine.available else { return }
        for scalar in text.unicodeScalars {
            let (state, handled) = engine.handledKey(Int32(scalar.value), generatedSeparator: chord && scalar.value == 39); receive(state)
            if importedSchemeSelection != nil && !engine.lastError.isEmpty {
                status.text = L("方案扩展处理失败，可在 App 的“测试候选”中查看原因。", "Scheme extension failed. Check details with Test candidates in the app.")
            }
            if !handled { insert(String(scalar)) }
        }
        render()
    }
    private func settle() {
        guard !snapshot.preedit.isEmpty else { return }
        if !snapshot.candidates.isEmpty { receive(engine.candidate(0)) }
        else { receive(engine.process(key: 0xff0d)) }
    }
    private func space() {
        surface.cancel()
        // Imported schemes own their space semantics, including sentence buffers and top-up.
        if importedSchemeSelection != nil && !directEnglish && !surface.shifted { type(" "); return }
        if !snapshot.preedit.isEmpty { settle() } else { breakAssociationChain(); insert(" "); render() }
    }
    private func enter() {
        guard onscreen, currentDocument == DocumentIdentity.read(textDocumentProxy) else { return }
        let action = returnAction
        surface.cancel(); breakAssociationChain()
        switch action {
        case .confirm:
            // Preserve each engine's existing Return semantics. Confirmation and
            // Buffer delivery always require separate taps.
            if usesNineKey && !engine.rawInput.isEmpty { settle() }
            else if importedSchemeSelection != nil && !directEnglish && !engine.rawInput.isEmpty {
                let (state, handled) = engine.handledKey(0xff0d); receive(state)
                if !handled { commitRawInput() }
            } else { commitRawInput(); render() }
        case .insertBuffer:
            _ = deliver(all: false)
        case .waiting:
            break
        case .host:
            // UIKit interprets Return according to the host field (Send, Search,
            // or an actual newline). It is never appended to an occupied Buffer.
            if let target = currentDocument { _ = delivery.insert("\n", target: target) }
            render()
        }
    }
    private var hostReturnTitle: String? {
        let type = onscreen ? textDocumentProxy.returnKeyType : nil
        return switch type {
        case .send?: L("发送", "Send")
        case .go?, .google?, .yahoo?, .route?: L("前往", "Go")
        case .search?: L("搜索", "Search")
        case .done?: L("完成", "Done")
        case .next?: L("下一项", "Next")
        case .join?: L("加入", "Join")
        case .continue?: L("继续", "Continue")
        case .emergencyCall?: L("紧急", "SOS")
        default: nil
        }
    }
    private func refreshReturnKey() {
        let title: String, hint: String?
        let selected: Bool, enabled: Bool
        switch returnAction {
        case .confirm:
            title = L("确认", "Confirm")
            hint = bufferEnabled ? L("先确认当前组字，再点上屏", "Confirm composition first, then tap Insert") : L("确认当前输入", "Confirm current input")
            selected = false; enabled = true
        case .insertBuffer:
            title = L("上屏", "Insert")
            hint = L("将下一块内容放入输入框", "Insert the next block into the app")
            selected = true; enabled = true
        case .waiting:
            title = buffer.generating ? L("生成中", "Working") : L("上屏", "Insert")
            hint = L("结果就绪后可上屏", "Insert when the result is ready")
            selected = false; enabled = false
        case .host:
            title = hostReturnTitle ?? L("换行", "return")
            hint = L("使用当前输入框的回车操作", "Use the current field's Return action")
            selected = bufferEnabled || hostReturnTitle != nil; enabled = true
        }
        returnKey.setImage(nil, for: .normal); returnKey.setTitle(title, for: .normal)
        returnKey.accessibilityLabel = title; returnKey.accessibilityHint = hint
        returnKey.isSelected = selected; returnKey.isEnabled = enabled
        insertButton.isSelected = bufferEnabled && insertButton.isEnabled
    }
    private func backspace() {
        guard onscreen, currentDocument == DocumentIdentity.read(textDocumentProxy) else { cancelDeletes(); return }
        surface.cancel(); if usesNineKey && !engine.rawInput.isEmpty { replaceNineKeyInput(NineKeyPinyin.backspacing(engine.rawInput)) }
        else if !engine.rawInput.isEmpty { receive(engine.process(key: 0xff08)) }
        // Default shows its blocks, so Delete removes a whole block; plugin input
        // shows none and keeps character deletion.
        else if bufferEnabled && !bufferIsEmpty { cancelRequest(); if isDefaultBuffer { buffer.deleteBlockBackward() } else { buffer.backspace() }; sourceChanged(); render() }
        else if let target = currentDocument { _ = delivery.deleteBackward(target:target) }
    }
    private func toggleBuffer() { breakAssociationChain(); stopDefaultAutoSend(); autoSuspended = false; liveTyping.reset(); cancelDeletes(); surface.cancel(); settle(); bufferEnabled.toggle(); if !bufferEnabled { cancelRequest(); selectedPlugin = nil; panelOpen = false; refreshPluginMenu() }; bufferButton.isSelected = bufferEnabled; render() }
    private func render() {
        syncCustomLayout()
        var spellings = usesNineKey ? nineKeySpelling.choices(for: engine.rawInput) : []
        if let best = engine.candidateReadings.first?.split(separator: " ").first.map(String.init),
           let index = spellings.firstIndex(of: best) { spellings.remove(at: index); spellings.insert(best, at: 0) }
        spellingStrip.update(spellings)
        spellingStrip.isHidden = !usesNineKey || !spellingChoicesOpen || spellings.isEmpty
        spellingKey.isEnabled = usesNineKey && !spellings.isEmpty
        spellingKey.isSelected = !spellingStrip.isHidden
        if onscreen {
            if bufferEnabled { delivery.discardMarkedText() }
            else if let target = currentDocument { delivery.updateMarkedText(compositionText, target: target) }
        }
        candidateStrip.update(showingAssociations ? associations : snapshot.candidates); renderHandPreview(); renderShortcuts(); refreshLanguageSwap(); refreshKeyboardSkin(); renderBuffer(); resize()
    }
    private func syncCustomLayout() {
        guard !syncingCustomLayout else { return }
        let desired = scheme != .chord && !usesNineKey && !surface.numeric && !surface.emojiMode ? customLayoutSnapshot : nil
        let standard: StandardKeyboardMode? = scheme == .chord || surface.emojiMode || desired != nil ? nil
            : surface.numeric ? (symbolPage ? .symbols : .numeric) : usesNineKey ? .nineKey : .qwerty
        guard desired != surface.customLayout || standard != surface.standardMode else { return }
        syncingCustomLayout = true
        defer { syncingCustomLayout = false }
        cancelDeletes(); spaceKey.cancelTracking(with: nil)
        NSLayoutConstraint.deactivate(bottomKeyWidths); spaceMinimumWidth?.isActive = false
        if desired != nil || standard != nil {
            for button in standardFunctions.values {
                bottom.removeArrangedSubview(button); button.removeFromSuperview()
                button.translatesAutoresizingMaskIntoConstraints = true
                surface.addSubview(button)
                (button as? KeycapButton)?.compactCap = false
            }
            if customGlobeSpacer.superview == nil { bottom.addArrangedSubview(customGlobeSpacer) }
            bottomKeyWidths.first?.isActive = true
            surface.customFunctionViews = customFunctions
            surface.customLayout = desired
            surface.standardFunctionViews = standardFunctions
            surface.standardMode = standard
        } else {
            surface.customLayout = nil; surface.customFunctionViews = [:]; surface.standardMode = nil; surface.standardFunctionViews = [:]
            bottom.removeArrangedSubview(customGlobeSpacer); customGlobeSpacer.removeFromSuperview()
            for button in standardFunctions.values { button.removeFromSuperview(); button.isHidden = false }
            for button in [numbers, shiftButton, spaceKey, deleteButton, bottomLanguage, returnKey] {
                button.translatesAutoresizingMaskIntoConstraints = false
                bottom.addArrangedSubview(button)
            }
            NSLayoutConstraint.activate(bottomKeyWidths); spaceMinimumWidth?.isActive = true
        }
        surface.setNeedsLayout()
    }
    private func selectNineKeySpelling(_ spelling: String) {
        guard usesNineKey, let raw = nineKeySpelling.selecting(spelling, in: engine.rawInput) else { return }
        replaceNineKeyInput(raw)
    }
    private func replaceNineKeyInput(_ raw: String) {
        engine.clear(); snapshot = .init()
        for scalar in raw.unicodeScalars { snapshot = engine.handledKey(Int32(scalar.value)).0 }
        render()
    }
    private func selectKeyboardTheme(_ theme: StatusSkin) {
        preferences.statusSkin = theme.canonical.rawValue
        preferences.keyboardSkin = theme.keyboardStyle
        preferences.keyboardThemeMigrationVersion = 1
        persistKeyboardTheme()
        preferencesStore.save(preferences)
        render()
    }
    private func persistKeyboardTheme() {
        #if KEYBOARD_LAYOUT_TESTS
        if developmentPreferencesAreIsolated { return }
        #endif
        // Without shared-container writes, the extension still keeps its local choice.
        if let saved = try? KeyboardThemeStore().save(preferences.resolvedTheme) {
            preferences.appliedKeyboardThemeRevision = saved.revision
        }
    }
    private func refreshKeyboardSkin() {
        let theme = preferences.resolvedTheme, skin = theme.keyboardStyle
        surface.theme = theme
        view.backgroundColor = theme.palette.background; view.tintColor = theme.palette.accent
        panel.backgroundColor = theme.palette.background
        handPreview.theme = theme
        for (action, view) in standardFunctions {
            guard let button = view as? KeycapButton else { continue }
            button.theme = theme; button.functionalCap = !usesNineKey && action != .space
            button.accentCap = action == .enter
            button.titleLabel?.font = .systemFont(ofSize: scheme != .chord && (action == .language || skin == .system) ? 18 : 14, weight: scheme != .chord && skin == .system ? .regular : .medium)
            button.setPreferredSymbolConfiguration(.init(pointSize: scheme != .chord && skin == .system ? 21 : 17, weight: .medium), forImageIn: .normal)
            button.titleHorizontalInset = scheme == .chord ? 6 : 2
            button.titleLabel?.adjustsFontSizeToFitWidth = scheme != .chord || action == .enter
            button.titleLabel?.minimumScaleFactor = 0.7
        }
        for button in [moreButton, bufferButton, aiButton, settingsButton, insertButton, stopButton, runButton, globe, chordDelete] { button.theme = theme }
        bufferButton.accentCap = true; insertButton.accentCap = true
        symbolsKey.setTitle(symbolPage ? "123" : "#+=", for: .normal)
        numbers.setTitle(surface.numeric ? (usesNineKeyEngine && !directEnglish ? "拼音" : "ABC") : "123", for: .normal)
        if surface.usesStandardLayout && skin == .system {
            spaceKey.setImage(nil, for: .normal)
            spaceKey.setTitle(usesNineKey && !snapshot.candidates.isEmpty ? "选定" : directEnglish ? "space" : "空格", for: .normal)
            spaceKey.titleLabel?.font = .systemFont(ofSize: 18)
        } else if spaceKey.image(for: .normal) == nil && !spaceKey.split {
            spaceKey.symbol("space", label: L("空格", "Space"))
        }
    }
    private func renderHandPreview() {
        let preview = surface.handPreview
        handPreview.update(preview)
        handPreview.isHidden = preview == nil; candidateStrip.isHidden = preview != nil
    }
    /// An empty candidate row offers the plugins instead.
    private func renderShortcuts() {
        let empty = snapshot.preedit.isEmpty && snapshot.candidates.isEmpty && !showingAssociations && !surface.isChordActive && handPreview.isHidden
        // The empty strip stays in place underneath, so the row keeps its reserved slot.
        shortcuts.isHidden = !empty
        shortcuts.selected = bufferEnabled ? selectedPlugin : nil
        for (plugin, button) in shortcuts.buttons { button.isEnabled = pluginAuthorization(plugin.rawValue) != nil }
    }
    private func renderBuffer() {
        bufferPanel.isHidden = !bufferEnabled; bufferButton.isSelected = bufferEnabled
        if !bufferEnabled { hostSnapshot = nil; captureTimer?.invalidate(); captureTimer = nil }
        else if hostSnapshot == nil, captureTimer == nil, onscreen, !delivery.isWriting,
                ProcessInfo.processInfo.systemUptime - delivery.lastWriteTime >= 0.6 { snapshotHost() }
        // Default shows its delivery blocks in the input line (caret block outlined);
        // plugins send their result, so their output line shows those blocks instead.
        let display = BufferComposition(source: buffer.source, cursor: buffer.cursor, preedit: compositionText,
                                        font: .systemFont(ofSize: view.bounds.width > 600 ? 14 : 15), selection: buffer.selection,
                                        blocks: isDefaultBuffer ? buffer.blocks : nil, accent: preferences.resolvedTheme.palette.accentText)
        source.setBlocks(display.blockRanges, active: display.activeBlock)
        source.attributedText = display.text; source.caretLocation = display.caretRange.location
        source.scrollRangeToVisible(display.caretRange)
        // Every Buffer mode uses the same two lines: a display-only output line
        // above an input line. Default shows its live typing stats as output.
        // Blocks still deliver their line breaks; the one-line display drops the trailing ones
        // so each poem line reads as its own block, side by side.
        // Thinking arrives tagged; it streams dimmed with no label, then gives way to the answer.
        let thinking = buffer.generating && buffer.preview.hasPrefix(ThinkingText.marker)
        let incoming = (thinking ? String(buffer.preview.dropFirst()) : buffer.preview).split(whereSeparator: \.isNewline).joined(separator: " ")
        if thinking != result.thinking {
            result.thinking = thinking
            // The answer never waits for the thinking: drop the caption and start the answer at once.
            if !thinking { caption.stop(); if buffer.generating { reveal.clear(); reveal.start() } }
        }
        // Still streaming, or the reveal has not yet caught up with what arrived.
        let streaming = !isDefaultBuffer && (buffer.generating || reveal.isActive || (revealGeneration != nil && reveal.isBehind(incoming)))
        let outputBlocks = (isDefaultBuffer || streaming ? [] : (needsPluginResult ? buffer.pluginPending : buffer.pending))
            .map { block in var shown = block; while shown.last?.isNewline == true { shown.removeLast() }; return shown }
        result.setBlocks(BufferBlockStyle.ranges(of: outputBlocks), active: outputBlocks.isEmpty ? nil : 0)
        if streaming {
            // No "working…" words: the status light shows waiting and thinking. The answer is fed
            // through our own buffer and revealed at an even pace (see `StreamReveal`).
            if buffer.generating, buffer.generation != revealGeneration {
                revealGeneration = buffer.generation; reveal.start(); reveal.readable = !realtime
                // AI answers start from an empty line; live translation keeps what still matches.
                if !realtime { reveal.clear() }
            }
            if thinking { reveal.stop(); caption.update(incoming) }
            else if !incoming.isEmpty || !buffer.generating { reveal.feed(incoming, finished: !buffer.generating) }
            // Nothing readable yet (no answer, no thinking sentence): pulsing dots, no words.
            result.waiting = buffer.generating && (incoming.isEmpty || (thinking && caption.current.isEmpty))
        } else {
            result.waiting = false
            let text = isDefaultBuffer ? "" : outputBlocks.joined()
            if result.text != text {
                let arriving = revealGeneration != nil
                result.text = text
                // A finished stream glides back to its first block, the one Send inserts,
                // unless the reader has taken over the line.
                if arriving { revealGeneration = nil; if reveal.following { result.setContentOffset(.zero, animated: true) } } else { result.scrollToStart() }
            }
        }
        aiButton.isHidden = !bufferEnabled
        insertionSlot.isHidden = !bufferEnabled
        settingsButton.isHidden = !bufferEnabled
        settingsButton.isSelected = panelOpen
        statusLight.isHidden = !bufferEnabled
        statusLight.skin = preferences.resolvedTheme
        statusLight.set(outputState)
        runButton.isHidden = !bufferEnabled || selectedPlugin?.isAI != true
        runButton.isEnabled = !buffer.generating && !buffer.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        stopButton.isHidden = !buffer.generating; insertButton.isHidden = buffer.generating
        // Quick Q&A invites a paste only when the clipboard has text (checked without reading it).
        source.placeholder = selectedPlugin == .ask && hasFullAccess && UIPasteboard.general.hasStrings
            ? L("轻点这里粘贴剪贴板，或直接输入问题", "Tap here to paste, or type a question") : selectedPlugin?.placeholder ?? ""
        let hasOutput = needsPluginResult ? !buffer.pluginPending.isEmpty : !buffer.pending.isEmpty
        insertButton.isEnabled = hasOutput && !buffer.generating && !hasComposition
        if pressedInsertion != insertionContext { insertButton.cancelPress() }
        refreshMoreMenu(); refreshDefaultBuffer(); renderPanel(); refreshReturnKey()
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
        status.isHidden = status.text?.isEmpty != false
        globe.isHidden = !onscreen || !needsInputModeSwitchKey
        bottom.isHidden = surface.usesManagedLayout && globe.isHidden
        let bufferHeight: CGFloat = landscape ? 60 : 76
        let customHeight = surface.usesCustomLayout ? surface.customLayout.map { CGFloat($0.geometry(width: Double(max(1, width - 10)), landscape: landscape).height) } : nil
        let standardHeight = surface.usesStandardLayout ? StandardKeyboardGeometry.height(landscape: landscape) : nil
        return [(status, 28), (bufferPanel, bufferHeight),
                (candidatePanel, max(32, candidateStrip.fittingHeight(width: width - 82))),
                (spellingStrip, 34),
                (surface, customHeight ?? standardHeight ?? KeyboardGeometry.height(layout: surface.chordLayout, chord: surface.chordMode, numeric: surface.numeric, emoji: surface.emojiMode, landscape: landscape, width: max(1, width - 10), profile: surface.profile)), (bottom, landscape ? 34 : 40)].filter { !$0.0.isHidden }
    }
    private func resize() {
        updateHeight()
        view.setNeedsLayout()
    }
    private func contentHeight(width: CGFloat) -> CGFloat {
        let rows = layoutRows(width: width)
        return rows.reduce(CGFloat(10)) { $0 + $1.1 } + CGFloat(max(0, rows.count - 1)) * 4 - (compactTypingKeys ? 3 : 0)
    }
    private func updateHeight() {
        guard height != nil else { return }
        // First presentation can be measured before the input view has bounds.
        // Use the attached host (or screen before attachment) instead of leaving
        // the initial 240-point constraint in UIKit's first sizing response.
        let width = [view.bounds.width, view.superview?.bounds.width ?? 0,
                     view.window?.windowScene?.screen.bounds.width ?? UIScreen.main.bounds.width]
            .first { $0.isFinite && $0 > 0 } ?? 320
        let desired = contentHeight(width: width)
        if height.constant != desired {
            height.constant = desired
            view.invalidateIntrinsicContentSize()
        }
        let size = CGSize(width: width, height: desired)
        if preferredContentSize != size { preferredContentSize = size }
    }
    override func updateViewConstraints() {
        updateHeight()
        super.updateViewConstraints()
    }
    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        // Keep UIKit's original input view and host-sizing behavior. Only the width
        // follows the host; inheriting its provisional height recreates the blank area.
        if let parent = view.superview {
            if hostWidth?.secondItem as? UIView !== parent {
                hostWidth?.isActive = false
                hostWidth = view.widthAnchor.constraint(equalTo: parent.widthAnchor)
                hostWidth?.priority = .defaultHigh
            }
            hostWidth?.isActive = true
        } else {
            hostWidth?.isActive = false; hostWidth = nil
        }
        // Resolve the current width before UIKit lays out the input view, including
        // first attachment, rotation and presentations that only change the height.
        updateHeight()
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let rows = layoutRows(width: view.bounds.width)
        var y = view.bounds.height - 5
        for (item, rowHeight) in rows.reversed() {
            y -= rowHeight; item.frame = CGRect(x: 5, y: y, width: max(0, view.bounds.width - 10), height: rowHeight); y -= item === bottom && compactTypingKeys ? 1 : 4
        }
        let landscape = view.bounds.width > 600
        let bufferRowHeight: CGFloat = landscape ? 28 : 36
        let topLine = CGRect(x: 36, y: 0, width: max(0, bufferPanel.bounds.width - 72), height: bufferRowHeight)
        typingStats.font = .monospacedDigitSystemFont(ofSize: landscape ? 14 : 16, weight: .medium)
        insertionSlot.frame = CGRect(x: bufferPanel.bounds.width - 32, y: 0, width: 32, height: bufferRowHeight)
        // Right column: Send, plugin and the Buffer switch line up above each other;
        // settings sits alone on the left of the candidate row.
        aiButton.frame = CGRect(x: bufferPanel.bounds.width - 32, y: bufferRowHeight + 4, width: 32, height: bufferRowHeight)
        // Input row: [settings] [input line] [Run] [plugin]. Run appears only for AI plugins.
        // Left column: status light above the settings key, both 1U like the right column.
        let settingsWidth: CGFloat = settingsButton.isHidden ? 0 : 36, runWidth: CGFloat = runButton.isHidden ? 0 : 36
        statusLight.frame = CGRect(x: 0, y: 0, width: 32, height: bufferRowHeight)
        settingsButton.frame = CGRect(x: 0, y: bufferRowHeight + 4, width: 32, height: bufferRowHeight)
        runButton.frame = CGRect(x: bufferPanel.bounds.width - 68, y: bufferRowHeight + 4, width: 32, height: bufferRowHeight)
        let bottomLine = CGRect(x: settingsWidth, y: bufferRowHeight + 4, width: max(0, bufferPanel.bounds.width - 36 - runWidth - settingsWidth), height: bufferRowHeight)
        // Default sends what you type, so the input line sits beside Send and the typing
        // readout drops below it. Plugins send their output, which stays on top.
        if isDefaultBuffer { source.frame = topLine; result.frame = bottomLine } else { result.frame = topLine; source.frame = bottomLine }
        typingStats.frame = CGRect(x: 8, y: 0, width: max(0, result.bounds.width - 16), height: bufferRowHeight)
        bufferButton.frame = CGRect(x: candidatePanel.bounds.width - 32, y: 0, width: 32, height: 32)
        candidateStrip.frame = CGRect(x: 36, y: 0, width: max(0, candidatePanel.bounds.width - 72), height: candidatePanel.bounds.height)
        moreButton.frame = CGRect(x: 0, y: 0, width: 32, height: 32)
        handPreview.frame = CGRect(x: 36, y: 0, width: max(0, candidatePanel.bounds.width - 72), height: 32)
        shortcuts.frame = handPreview.frame
        handPreview.landscape = landscape
        result.font = .systemFont(ofSize: landscape ? 14 : 15)
        bottom.layoutIfNeeded()
        insertButton.frame = insertionSlot.bounds; stopButton.frame = insertionSlot.bounds
        // Settings cover the keys only, so the Buffer lines stay visible while choosing.
        panel.frame = (bottom.isHidden ? surface.frame : surface.frame.union(bottom.frame)).insetBy(dx: -5, dy: 0)
        metrics.laidOut(width: view.bounds.width, height: view.bounds.height, requestedHeight: height.constant,
            containerHeight: Double(view.superview?.bounds.height ?? 0), topInset: Double(rows.first?.0.frame.minY ?? 0))
    }
    private func cancelDeletes() { deleteButton.cancelPress(); chordDelete.cancelPress() }
    private func refreshLanguageSwap() {
        let swapped = compactTypingKeys
        if deleteButton.isHidden != swapped { deleteButton.isHidden = swapped }
        if bottomLanguage.isHidden == swapped { bottomLanguage.isHidden = !swapped }
        if swapped { deleteButton.cancelPress() } else { chordDelete.cancelPress() }
        bottomLanguage.setTitle(surface.englishInput ? "EN" : "中", for: .normal)
        bottomLanguage.isSelected = surface.englishInput
        bottomLanguage.accessibilityLabel = surface.englishInput ? L("英文，切换中文", "English; switch to Chinese") : L("中文，切换英文", "Chinese; switch to English")
        // Chord mode splits Space: hold the left half to select, the right half to move.
        spaceKey.split = swapped
        spaceKey.accessibilityHint = swapped
            ? L("左半按住拖动可在 Buffer 中选择文字，右半按住拖动可移动光标", "Hold the left half and drag to select text in the Buffer; hold the right half and drag to move the cursor")
            : L("按住并左右拖动可移动光标", "Hold and drag left or right to move the cursor")
        if surface.usesCustomLayout {
            let actions = Set(surface.customLayout?.rows.flatMap { $0 }.map(\.action) ?? [])
            for (action, button) in customFunctions { button.isHidden = !actions.contains(action) }
            customBufferKey.isSelected = bufferEnabled
        } else if surface.usesStandardLayout, let mode = surface.standardMode {
            let actions = Set(StandardKeyboardGeometry.make(width: max(1, surface.bounds.width), mode: mode, landscape: view.bounds.width > 600).controls.keys)
            for (action, button) in standardFunctions { button.isHidden = !actions.contains(action) }
            bottomLanguage.setTitle(usesNineKey ? "ABC" : (directEnglish ? "中" : "英"), for: .normal)
        }
    }
    /// Space hold starts caret movement only when nothing is being composed.
    /// Selecting works only in the Buffer: iOS gives keyboards no way to select
    /// host text, so there the left half moves the caret like the right half.
    private func beginCaretDrag(selecting: Bool = false) -> Bool {
        guard onscreen, !hasComposition, engine.rawInput.isEmpty else { return false }
        if !bufferEnabled { guard let target = currentDocument, target == DocumentIdentity.read(textDocumentProxy) else { return false } }
        cancelDeletes(); insertButton.cancelPress(); surface.cancel(); breakAssociationChain()
        selectingText = selecting && bufferEnabled
        if selectingText { buffer.beginSelection() } else if bufferEnabled { buffer.clearSelection() }
        if selecting && !bufferEnabled { showHostSelectionNoteOnce() }
        surface.feedback.send(.press); render(); return true
    }
    private static let hostSelectionNoteKey = "rimes.keyboard.hostSelectionNoteShown"
    private func showHostSelectionNoteOnce() {
        guard !UserDefaults.standard.bool(forKey: Self.hostSelectionNoteKey) else { return }
        UserDefaults.standard.set(true, forKey: Self.hostSelectionNoteKey)
        status.text = L("iOS 不允许键盘在应用中选择文字；打开 Buffer 即可选择", "iOS doesn't let keyboards select text in apps; turn on Buffer to select")
    }
    private func moveCaret(_ steps: Int) {
        guard onscreen, steps != 0 else { return }
        if bufferEnabled {
            let before = buffer.cursor
            if selectingText { buffer.extendSelection(steps) } else { buffer.moveCursor(steps) }
            guard buffer.cursor != before else { return }
            render()
        } else {
            guard let target = currentDocument, delivery.moveCaret(by: steps, target: target) else { return }
        }
        caretSteps += 1; surface.feedback.send(.selection, combination: String(caretSteps))
    }
    /// Expanded candidates are a one-shot view: choosing or typing returns to one row.
    private func collapseCandidates() {
        guard expanded else { return }
        expanded = false; candidateStrip.setNeedsLayout(); resize()
    }
    private func noteTypingKey(backspace: Bool = false) {
        // A key press hides associations; Delete also ends the learning chain.
        if backspace { breakAssociationChain() } else { associations = [] }
        if !backspace {
            collapseCandidates()
            // Only Delete acts on a selection; any other key just clears it.
            if buffer.selectionAnchor != nil { buffer.clearSelection(); renderBuffer() }
        }
        guard isDefaultBuffer else { return }
        liveTyping.noteKey(at: uptime, isRepeat: false, isBackspace: backspace); session.noteKey(at: uptime)
    }
    private func stopDefaultAutoSend() {
        autoTimer?.invalidate(); autoTimer = nil; autoClock.reset(); autoTarget = nil
    }
    private func setDefaultDelay(_ delay: Double) {
        stopDefaultAutoSend(); defaultDelay = delay; autoSuspended = false
        UserDefaults.standard.set(delay, forKey: "defaultBuffer.autoDelay")
    }
    /// The Default readout: live speed (still falling while you pause), keys per character,
    /// keys per second, and how long you have paused. Tap it to sign the app's text.
    private func updateTypingStats() {
        let now = uptime
        var parts: [String] = []
        if let cpm = liveTyping.charactersPerMinute(at: now) { parts.append("\(Int(cpm.rounded())) " + L("字/分", "cpm")) }
        if let code = liveTyping.codeLength { parts.append(String(format: "%.2f ", code) + L("触/字", "keys/char")) }
        if let keys = liveTyping.keysPerSecond { parts.append(String(format: "%.1f ", keys) + L("触/秒", "keys/s")) }
        if parts.isEmpty { parts = [L("— 字/分", "— cpm"), L("— 触/字", "— keys/char"), L("— 触/秒", "— keys/s")] }
        if !liveTyping.isEmpty, let idle = liveTyping.idleSeconds(at: now), idle >= 1 { parts.append(L("停 ", "idle ") + "\(Int(idle))s") }
        let enabled = [1.0, 2, 3, 5].contains(defaultDelay) && !autoSuspended
        typingStats.text = parts.joined(separator: " · ") + (enabled ? String(format: " · %.1fs", max(0, defaultDelay - autoClock.headAge)) : "")
    }
    private func refreshDefaultBuffer() {
        typingStats.isHidden = !isDefaultBuffer
        guard isDefaultBuffer, onscreen else { statsTimer?.invalidate(); statsTimer = nil; stopDefaultAutoSend(); return }
        updateTypingStats()
        if statsTimer == nil {
            let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
                guard let self, self.isDefaultBuffer, self.onscreen else { self?.statsTimer?.invalidate(); self?.statsTimer = nil; return }
                self.updateTypingStats()
            }
            statsTimer = timer; RunLoop.main.add(timer, forMode: .common)
        }
        let enabled = [1.0, 2, 3, 5].contains(defaultDelay) && !autoSuspended
        guard typingCardPreview == nil, enabled, !buffer.pending.isEmpty, buffer.retainedResults.isEmpty, buffer.result == nil, let target = currentDocument,
              target == DocumentIdentity.read(textDocumentProxy) else { stopDefaultAutoSend(); return }
        if autoTarget != target { stopDefaultAutoSend(); autoTarget = target }
        autoClock.synchronize(buffer.pending)
        if hasComposition || buffer.generating { autoClock.pause() }
        guard autoTimer == nil else { return }
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.tickDefaultBuffer() }
        autoTimer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    private func tickDefaultBuffer() {
        guard typingCardPreview == nil, onscreen, isDefaultBuffer, !autoSuspended, let target = autoTarget,
              target == currentDocument, target == DocumentIdentity.read(textDocumentProxy) else { stopDefaultAutoSend(); return }
        autoClock.synchronize(buffer.pending)
        if autoClock.tick(at: uptime, lifetime: defaultDelay, canAge: !hasComposition && !buffer.generating && !insertButton.isHighlighted) {
            if !deliver(all: false) { stopDefaultAutoSend(); autoSuspended = true }
        }
        refreshDefaultBuffer()
    }
    private func refreshMoreMenu() {
        let levels: [(String, HapticStrength?)] = [(L("关闭", "Off"), nil), (L("轻", "Light"), .light), (L("强", "Strong"), .strong), (L("更强", "Stronger"), .strongest)]
        let haptics = UIMenu(title: L("按键震动", "Key haptics"), image: UIImage(systemName: "iphone.radiowaves.left.and.right"), children: levels.map { title, strength in
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
        var schemeActions: [UIMenuElement] = InputScheme.allCases.map { value in
            UIAction(title: value.title, state: importedSchemeSelection == nil && value == scheme ? .on : .off) { [weak self] _ in
                guard let self else { return }
                self.settle(); self.importedSchemeSelection = nil; self.saveImportedSchemeChoice()
                self.preferences.select(value); self.preferencesStore.save(self.preferences)
                self.choose(value); self.render()
            }
        }
        for package in importedSchemeLibrary.packages {
            for imported in package.schemas {
                let selection = RimeSchemeSelection(packageID: package.id, schemaID: imported.id)
                schemeActions.append(UIAction(title: imported.name, state: selection == importedSchemeSelection ? .on : .off) { [weak self] _ in
                    guard let self else { return }
                    self.settle(); self.importedSchemeSelection = selection; self.saveImportedSchemeChoice()
                    self.importedSchemeEnglish = false; self.saveImportedSchemeChoice()
                    self.choose(self.preferences.scheme); self.render()
                })
            }
        }
        let schemes = UIMenu(title: L("输入方案", "Input scheme"), image: UIImage(systemName: "keyboard"), children: schemeActions)
        let keySounds = UIAction(title: L("按键音效", "Key sounds"), image: UIImage(systemName: "speaker.wave.2"), state: preferences.keySounds ? .on : .off) { [weak self] _ in
            guard let self else { return }
            self.preferences.keySounds.toggle(); self.preferencesStore.save(self.preferences)
            self.surface.feedback.soundEnabled = self.preferences.keySounds
            self.refreshMoreMenu()
        }
        var items: [UIMenuElement] = [schemes, keySounds, UIAction(title: L("繁体输出", "Traditional Chinese output"), image: UIImage(systemName: "character.book.closed"), state: preferences.traditional ? .on : .off) { [weak self] _ in self?.toggleScript() }]
        items.insert(UIMenu(title: L("宠物与配色", "Pet & colors"), image: UIImage(systemName: "paintpalette"), children: StatusSkin.themes.map { theme in
            UIAction(title: theme.title, image: theme.usesDot ? UIImage(systemName: "circle.fill") : nil,
                     state: preferences.resolvedTheme == theme ? .on : .off) { [weak self] _ in self?.selectKeyboardTheme(theme) }
        }), at: 2)
        if scheme != .chord {
            items.append(UIMenu(title: L("键位布局", "Key layout"), children: OrdinaryKeyboardLayout.allCases.map { layout in
                UIAction(title: layout == .qwerty ? "26 键 · QWERTY" : "9 键 · 全拼",
                         attributes: layout == .nineKey && (scheme != .pinyin || importedSchemeSelection != nil) ? .disabled : [],
                         state: preferences.ordinaryLayout == layout && customLayoutSnapshot == nil ? .on : .off) { [weak self] _ in
                    guard let self else { return }; self.settle(); self.customLayoutSnapshot = nil
                    self.preferences.overriddenCustomLayoutRevision = CustomLayoutStore().load().revision
                    self.preferences.ordinaryLayout = layout; self.preferencesStore.save(self.preferences)
                    self.choose(self.preferences.scheme); self.render()
                }
            }))

        }
        if !surface.hasUtilityCells {
            items.append(UIAction(title: directEnglish ? L("切换中文", "Switch to Chinese") : L("切换英文", "Switch to English"), image: UIImage(systemName: "globe")) { [weak self] _ in self?.toggleLanguage() })
            items.append(UIAction(title: L("表情", "Emoji"), image: UIImage(systemName: "face.smiling")) { [weak self] _ in self?.surface.showEmoji() })
        }
        items.append(haptics)
        moreButton.menu = UIMenu(children: items)
    }
    @discardableResult private func deliver(all: Bool) -> Bool {
        if let selectedPlugin, pluginAuthorization(selectedPlugin.rawValue) == nil || pluginAuthorization(selectedPlugin.rawValue) != resultPluginAuthorization {
            cancelRequest(); buffer.invalidateResult(); return false
        }
        surface.cancel(); if !snapshot.preedit.isEmpty { settle(); return false }
        guard onscreen, !buffer.generating, currentDocument == DocumentIdentity.read(textDocumentProxy) else { return false }
        let blocks = needsPluginResult ? buffer.pluginPending : buffer.pending
        let text = all ? blocks.joined() : blocks.first ?? ""
        guard !text.isEmpty, let target = currentDocument, delivery.insert(text, target: target) else { return false }
        // Read aloud exactly what was sent: one block per tap, everything on a hold.
        if realtime && preferences.speakTranslation { speaker.speak(text, language: preferences.targetLanguage) }
        return finishDelivery(all: all)
    }
    /// The status row opens all export formats without inserting anything yet.
    private func showTypingCard() {
        guard typingCardPreview == nil, onscreen, isDefaultBuffer,
              currentDocument == DocumentIdentity.read(textDocumentProxy) else { return }
        guard let snapshot = TypingCardSnapshot(session: session) else {
            status.text = L("先打几个字，再点这里分享统计", "Type a little, then tap here to share stats"); render(); return
        }
        do {
            let png = try TypingStatsCard.render(snapshot)
            let preview = TypingCardPreview(png: png, fullAccess: canExportTypingCard,
                                            blockText: TypingStatsText.matrix(snapshot), plainText: typingSignature() ?? "")
            cancelDeletes(); surface.cancel(); stopDefaultAutoSend()
            typingCardPNG = png; typingCardPreview = preview
            preview.onClose = { [weak self] in self?.dismissTypingCard() }
            preview.onCopy = { [weak self] in self?.copyTypingCard() }
            preview.onSave = { [weak self] in self?.saveTypingCard() }
            preview.onPhotos = { [weak self] in self?.saveTypingCardToPhotos() }
            preview.onText = { [weak self] text in self?.dismissTypingCard(resume: false); self?.appendTypingSignature(text: text) }
            preview.onCopyText = { [weak self] text in self?.copyTypingStatsText(text) }
            preview.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(preview)
            NSLayoutConstraint.activate([
                preview.leadingAnchor.constraint(equalTo: view.leadingAnchor), preview.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                preview.topAnchor.constraint(equalTo: view.topAnchor), preview.bottomAnchor.constraint(equalTo: view.bottomAnchor)
            ])
            UIAccessibility.post(notification: .screenChanged, argument: preview)
        } catch { status.text = error.localizedDescription; render() }
    }
    private func dismissTypingCard(resume: Bool = true) {
        typingCardPreview?.removeFromSuperview(); typingCardPreview = nil; typingCardPNG = nil
        if resume { refreshDefaultBuffer() }
    }
    private func copyTypingCard() {
        guard canExportTypingCard else { typingCardPreview?.showMessage(L("复制图片需要完全访问。", "Copying images needs Full Access.")); return }
        guard let png = typingCardPNG else { return }
        do { try TypingStatsCard.copy(png); typingCardPreview?.showMessage(L("图片已复制；若聊天不支持粘贴图片，请使用保存到相册。", "Copied. If your chat cannot paste images, use Save to Photos.")) }
        catch { typingCardPreview?.showMessage(error.localizedDescription) }
    }
    private func saveTypingCard() {
        guard canExportTypingCard else { typingCardPreview?.showMessage(L("保存到 App 需要完全访问。", "Saving to the app needs Full Access.")); return }
        guard let png = typingCardPNG else { return }
        do { try typingCardStore.save(png); typingCardPreview?.showMessage(L("已保存到 RIMES → 打字统计卡片，可从那里保存到相册。", "Saved to RIMES → Typing stats card, where you can save to Photos.")) }
        catch { typingCardPreview?.showMessage(error.localizedDescription) }
    }
    private func saveTypingCardToPhotos() {
        guard canExportTypingCard else { typingCardPreview?.showMessage(L("键盘保存图片需要完全访问。", "Saving from the keyboard needs Full Access.")); return }
        guard !typingCardSavingPhoto, let png = typingCardPNG, let preview = typingCardPreview else { return }
        // Keep the explicitly exported PNG available if the system permission prompt dismisses the keyboard.
        do { try typingCardStore.save(png) } catch { preview.showMessage(error.localizedDescription); return }
        typingCardSavingPhoto = true; preview.setSaving(true)
        preview.showMessage(L("请允许添加照片，正在保存…", "Allow adding photos to save the image…"))
        Task { [weak self, weak preview] in
            let message: String
            do { try await TypingCardPhotos().save(png); message = L("已保存到相册，可在聊天中选择这张照片。", "Saved to Photos. Select this image in your chat.") }
            catch { message = error.localizedDescription }
            self?.typingCardSavingPhoto = false
            preview?.setSaving(false); preview?.showMessage(message)
        }
    }
    private func copyTypingStatsText(_ text: String) {
        guard canExportTypingCard else { typingCardPreview?.showMessage(L("复制文字需要完全访问，也可直接追加到输入框。", "Copying needs Full Access. You can insert the text instead.")); return }
        UIPasteboard.general.setItems([[UTType.utf8PlainText.identifier: text]], options: [.localOnly: true])
        typingCardPreview?.showMessage(L("文字已复制。", "Text copied."))
    }
    /// Appends only the explicitly selected text through the normal delivery path.
    private func appendTypingSignature(text: String? = nil) {
        guard onscreen, let target = currentDocument, target == DocumentIdentity.read(textDocumentProxy) else { return }
        guard let line = text ?? typingSignature() else { status.text = L("先打几个字，再点这里附上打字数据", "Type a little first, then tap here to add your typing stats"); render(); return }
        surface.cancel(); settle()
        // The proxy only sees a window of text after the caret: walk it to the end.
        for _ in 0..<64 {
            guard let after = textDocumentProxy.documentContextAfterInput, !after.isEmpty,
                  delivery.moveCaret(by: after.count, target: target) else { break }
        }
        let before = textDocumentProxy.documentContextBeforeInput ?? ""
        let gap = before.isEmpty ? "" : before.hasSuffix("\n\n") ? "" : before.hasSuffix("\n") ? "\n" : "\n\n"
        guard delivery.insert(gap + line, target: target) else { return }
        // Signed and sent: the next signature starts from zero, and the readout clears now.
        session.reset(); liveTyping.reset(); updateTypingStats()
        surface.feedback.send(.commit); status.text = L("已在末尾附上打字数据", "Typing stats added at the end"); render()
    }
    func typingSignature() -> String? {
        guard !session.isEmpty else { return nil }
        var figures = [L("共 \(session.characters) 字", "\(session.characters) characters")]
        if let cpm = session.charactersPerMinute { figures.append(L("平均 \(Int(cpm.rounded())) 字/分", "avg \(Int(cpm.rounded())) cpm")) }
        if session.peakCharactersPerMinute > 0 { figures.append(L("最快 \(Int(session.peakCharactersPerMinute.rounded())) 字/分", "peak \(Int(session.peakCharactersPerMinute.rounded())) cpm")) }
        if let code = session.codeLength { figures.append(String(format: L("码长 %.2f 触/字", "%.2f keys/char"), code)) }
        if let keys = session.keysPerSecond { figures.append(String(format: L("击键 %.1f 触/秒", "%.1f keys/s"), keys)) }
        return "—\n" + figures.joined(separator: " · ") + "\n" + L("来自 RIMES 免费开源输入法", "Sent from RIMES, the free open-source input method")
    }
    private func pasteQuestion() {
        guard bufferEnabled, selectedPlugin == .ask, buffer.source.isEmpty, !hasComposition else { return }
        guard hasFullAccess else { status.text = L("读取剪贴板需要为 RIMES 开启“完全访问”", "Pasting needs Full Access for RIMES"); render(); return }
        // iOS may ask "Allow Paste?" here. The read waits for the answer, and the alert takes
        // focus meanwhile, so keep the text and add it once the keyboard is back if needed.
        let text = String((UIPasteboard.general.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(4000))
        guard !text.isEmpty else { status.text = L("剪贴板里没有文字", "Nothing to paste"); render(); return }
        pendingPaste = text
        if onscreen { applyPendingPaste() }
    }
    private func applyPendingPaste() {
        guard let text = pendingPaste else { return }
        pendingPaste = nil
        guard onscreen, bufferEnabled, selectedPlugin == .ask, buffer.source.isEmpty else { return }
        surface.cancel(); surface.feedback.send(.commit)
        insert(text); status.text = L("已粘贴，点 ▶ 提问", "Pasted; tap ▶ to ask"); render()
    }
    private func readOutputBlock(_ index: Int) {
        guard onscreen, needsPluginResult, selectedPlugin != .art, !buffer.generating, buffer.pluginPending.indices.contains(index) else { return }
        surface.feedback.send(.press)
        speaker.replay(buffer.pluginPending[index], language: realtime ? preferences.targetLanguage : nil)
    }
    private func finishDelivery(all: Bool) -> Bool {
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
    private func cancelRequest() { insertButton.cancelPress(); pressedInsertion = nil; lastRunFailed = false; runner.cancel(); buffer.cancel(); reveal.stop(); caption.stop(); revealGeneration = nil }
    private var outputState: StatusLight.State {
        if buffer.generating { return buffer.preview.isEmpty ? .waiting : .streaming }
        if lastRunFailed { return .failed }
        return (needsPluginResult ? buffer.pluginPending : buffer.pending).isEmpty ? .idle : .ready
    }
    private func reloadPreferences() {
        #if KEYBOARD_LAYOUT_TESTS
        // Keep explicit test fixtures across appearance callbacks without reading
        // or rewriting the app's installed schemes and active custom layout.
        if developmentPreferencesAreIsolated { return }
        #endif
        config = store.load(); preferences = preferencesStore.load()
        if let plugin = selectedPlugin, pluginAuthorization(plugin.rawValue) == nil {
            cancelRequest(); buffer.invalidateResult(); selectedPlugin = nil
        }
        applyAssociationReset(config.associationResetRevision)
        let appearance = KeyboardAppearanceStore().load()
        if let revision = appearance.revision, revision != preferences.appliedKeyboardAppearanceRevision {
            preferences.ordinaryLayout = appearance.layout
            if preferences.keyboardThemeMigrationVersion == 0 { preferences.keyboardSkin = appearance.skin }
            preferences.appliedKeyboardAppearanceRevision = revision; preferencesStore.save(preferences)
        }
        let savedTheme = KeyboardThemeStore().load()
        let explicitAppTheme = savedTheme.revision != nil && savedTheme.revision != preferences.appliedKeyboardThemeRevision
        preferences.reconcileTheme(savedTheme)
        // Load once at presentation, never in response to an in-progress key gesture.
        let customLibrary = CustomLayoutStore().load()
        customLayoutSnapshot = preferences.overriddenCustomLayoutRevision == customLibrary.revision ? nil : customLibrary.active
        importedSchemeLibrary = importedSchemeStore.load()
        if let data = UserDefaults.standard.data(forKey: "imported-rime-choice-v1"),
           let choice = try? JSONDecoder().decode(KeyboardRimeSchemeChoice.self, from: data),
           choice.appRevision == importedSchemeLibrary.revision {
            importedSchemeSelection = choice.selection; importedSchemeEnglish = choice.englishInput
        } else {
            importedSchemeSelection = importedSchemeLibrary.active
            importedSchemeEnglish = false
            saveImportedSchemeChoice()
        }
        preferences.reconcile(scheme: config.scheme, revision: config.schemeSelectionRevision)
        // A rotation picked in the RIMES app applies once, then the keyboard's own edits stand.
        if let revision = config.statusSkinsRevision, revision != preferences.appliedSkinRevision {
            preferences.statusSkinRotation = config.statusSkins ?? []; preferences.appliedSkinRevision = revision
            let rotation = StatusSkin.rotation(preferences.statusSkinRotation)
            if !explicitAppTheme && !rotation.contains(preferences.resolvedTheme) { preferences.statusSkin = rotation[0].rawValue }
        }
        preferences.keyboardSkin = preferences.resolvedTheme.keyboardStyle
        if savedTheme.revision == nil || savedTheme.selection != preferences.resolvedTheme { persistKeyboardTheme() }
        preferencesStore.save(preferences); surface.feedback.enabled = preferences.haptics; surface.feedback.strength = preferences.hapticStrength
        surface.feedback.soundEnabled = preferences.keySounds
        engine.traditional = preferences.traditional
        refreshPluginMenu(); render()
    }
    private func saveImportedSchemeChoice() {
        let choice = KeyboardRimeSchemeChoice(appRevision: importedSchemeLibrary.revision, selection: importedSchemeSelection, englishInput: importedSchemeEnglish)
        if let data = try? JSONEncoder().encode(choice) { UserDefaults.standard.set(data, forKey: "imported-rime-choice-v1") }
    }
    private func refreshPluginMenu() {
        let original = UIAction(title: "Buffer", image: UIImage(systemName: "square.stack.3d.up"), state: selectedPlugin == nil ? .on : .off) { [weak self] _ in self?.selectPlugin(nil) }
        // Each plugin stands alone; choosing one only opens it.
        let plugins = KeyboardPlugin.allCases.map { plugin in
            UIAction(title: plugin.title, image: UIImage(systemName: plugin.symbol), attributes: pluginAuthorization(plugin.rawValue) == nil ? [.disabled] : [], state: selectedPlugin == plugin ? .on : .off) { [weak self] _ in
                guard let self else { return }; self.surface.cancel(); self.settle(); self.selectPlugin(plugin)
            }
        }
        aiButton.menu = UIMenu(children: [original] + plugins)
        aiButton.symbol(selectedPlugin?.symbol ?? "square.stack.3d.up", label: selectedPlugin?.title ?? "Buffer")
        aiButton.accessibilityHint = L("选择插件", "Choose plugin")
        aiButton.isSelected = selectedPlugin != nil
        refreshMoreMenu()
    }
    /// Opens a plugin from the candidate-row shortcuts, turning the Buffer on. Tapping
    /// the open plugin again returns to Buffer.
    private func openPlugin(_ plugin: KeyboardPlugin) {
        guard onscreen else { return }
        surface.cancel(); settle(); breakAssociationChain(); collapseCandidates()
        if bufferEnabled && selectedPlugin == plugin { selectPlugin(nil); return }
        if !bufferEnabled { stopDefaultAutoSend(); autoSuspended = false; liveTyping.reset(); cancelDeletes(); bufferEnabled = true }
        selectPlugin(plugin)
    }
    private func selectPlugin(_ plugin: KeyboardPlugin?) {
        if let plugin, pluginAuthorization(plugin.rawValue) == nil {
            status.text = L("请在 RIMES App 的“官方插件”中安装并启用", "Install and enable this plugin in RIMES → Official plugins")
            return
        }
        cancelRequest(); buffer.invalidateResult(); selectedPlugin = plugin
        if plugin != .translate { speaker.stop() }
        status.text = plugin?.isAI == true ? aiReadinessHint() ?? "" : ""
        refreshPluginMenu(); sourceChanged(); render()
    }
    private func aiReadinessHint() -> String? {
        if !hasFullAccess { return L("AI 插件需要在系统设置中为 RIMES 开启“完全访问”", "AI plugins need Full Access for RIMES in Settings") }
        if config.provider == nil { return L("请先在 RIMES App 中配置 AI 服务", "Configure an AI service in the RIMES app first") }
        return nil
    }
    // MARK: Settings panel
    @objc private func bufferHeld(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began else { return }
        surface.feedback.send(.press); openSettings(for: selectedPlugin)
    }
    /// Opens the panel for a plugin (nil for Buffer), turning the Buffer on first.
    private func openSettings(for plugin: KeyboardPlugin?) {
        guard onscreen else { return }
        surface.cancel(); settle(); cancelDeletes(); insertButton.cancelPress(); collapseCandidates()
        if !bufferEnabled { stopDefaultAutoSend(); autoSuspended = false; liveTyping.reset(); bufferEnabled = true }
        if plugin != selectedPlugin { selectPlugin(plugin) }
        panelOpen = true; render()
    }
    private func closePanel() { panelOpen = false; render() }
    private func renderPanel() {
        panel.isHidden = !panelOpen
        guard panelOpen else { return }
        view.bringSubviewToFront(panel)
        panel.show(title: L("Buffer 设置", "Buffer settings"), sections: panelSections())
    }
    private func panelSections() -> [PanelSection] {
        var sections: [PanelSection] = []
        let plugins = [PanelItem(id: "default", title: "Buffer", symbol: "square.stack.3d.up", selected: selectedPlugin == nil)]
            + KeyboardPlugin.allCases.map { PanelItem(id: $0.rawValue, title: $0.title, symbol: $0.symbol, selected: selectedPlugin == $0) }
        sections.append(PanelSection(title: L("插件", "Plugin"), items: plugins) { [weak self] id in self?.selectPlugin(KeyboardPlugin(rawValue: id)) })
        switch selectedPlugin {
        case nil:
            let delays = [0.0, 1, 2, 3, 5].map { PanelItem(id: "\($0)", title: $0 == 0 ? L("关闭", "Off") : "\(Int($0)) s", selected: defaultDelay == $0) }
            sections.append(PanelSection(title: L("自动上屏", "Automatic insertion"), note: L("停止输入达到所选时长后，自动插入最前面的一块。", "Inserts the first block after you pause for the chosen time."), items: delays) { [weak self] id in
                self?.setDefaultDelay(Double(id) ?? 0); self?.render()
            })
        case .translate?:
            refreshLanguageRows()
            sections.append(PanelSection(title: L("语言", "Languages"), custom: languageRow, customHeight: 102,
                                         customKey: "\(preferences.sourceLanguage)>\(preferences.targetLanguage)|\(languages.count)"))
            speakRow.toggle.setOn(preferences.speakTranslation, animated: false)
            sections.append(PanelSection(title: L("朗读", "Read aloud"), note: L("开启后，发送时朗读发出的块。不开启也可以点按输出块来听。", "When on, blocks are read as you send them. Tap an output block to hear it any time."),
                                         custom: speakRow, customHeight: 36, customKey: "\(preferences.speakTranslation)"))
        case .art?:
            let art = preferences.art
            func change(_ edit: @escaping (inout TextArtOptions, String) -> Void) -> (String) -> Void {
                { [weak self] id in guard let self else { return }; edit(&self.preferences.art, id); self.preferencesStore.save(self.preferences); self.render() }
            }
            sections.append(PanelSection(title: L("画法", "Style"), note: L("每行固定同样多的字符，逐行发送不散架。彩色方块在任何应用里都等宽；任意字符可用汉字、符号、emoji，全角字符对得最齐。", "Every row has the same number of characters, so rows sent one by one keep the frame. Colour blocks are equal width everywhere; any characters allows Chinese, symbols and emoji, and full-width ones line up best."),
                                         items: TextArtStyle.allCases.map { PanelItem(id: $0.rawValue, title: $0.title, selected: art.style == $0) }, action: change { value, id in value.style = TextArtStyle(rawValue: id) ?? .blocks }))
            sections.append(PanelSection(title: L("画框（宽 × 高）", "Frame (width × height)"), items: TextArtOptions.sizes.map { PanelItem(id: "\($0)", title: "\($0) × \($0)", selected: art.width == $0 && art.height == $0) },
                                         action: change { value, id in let size = Int(id) ?? 10; value.width = size; value.height = size }))
        case .polish?, .ask?:
            sections.append(PanelSection(title: L("AI 服务", "AI service"), note: config.provider.map { "\($0.name) · \($0.model)" } ?? L("未配置。请在 RIMES App 的“AI 服务”中添加。", "Not set up. Add one under AI services in the RIMES app."), items: []) { _ in })
        case .poem?:
            let options = preferences.poem, library = config.poemLibrary
            func change(_ edit: @escaping (inout PoemOptions, String) -> Void) -> (String) -> Void {
                { [weak self] id in guard let self else { return }; edit(&self.preferences.poem, id); self.preferencesStore.save(self.preferences); self.render() }
            }
            sections.append(PanelSection(title: L("模式", "Mode"), items: PoemMode.allCases.map { PanelItem(id: $0.rawValue, title: $0.title, selected: options.mode == $0) }, action: change { value, id in value.mode = PoemMode(rawValue: id) ?? .improvise }))
            sections.append(PanelSection(title: L("每句字数", "Characters per line"), items: PoemLineLength.allCases.map { PanelItem(id: "\($0.rawValue)", title: $0.title, selected: options.lineLength == $0) }, action: change { value, id in value.lineLength = Int(id).flatMap(PoemLineLength.init(rawValue:)) ?? .free }))
            sections.append(PanelSection(title: L("句式", "Pattern"), items: library.allPatterns.map { PanelItem(id: $0.id, title: $0.name, selected: options.patternID == $0.id) }, action: change { value, id in value.patternID = id }))
            sections.append(PanelSection(title: L("词卡", "Word cards"), note: library.cards.isEmpty ? L("在 RIMES App 的“AI 作诗”中添加词卡。", "Add word cards under AI Poem in the RIMES app.") : nil,
                                         items: library.cards.map { PanelItem(id: $0.id.uuidString, title: $0.name, selected: options.cardIDs.contains($0.id)) }, action: change { value, id in
                guard let card = UUID(uuidString: id) else { return }
                if value.cardIDs.contains(card) { value.cardIDs.removeAll { $0 == card } } else { value.cardIDs.append(card) }
            }))
        }
        if selectedPlugin?.isAI == true {
            sections.append(PanelSection(title: L("思考深度", "Thinking depth"),
                                         note: L("越低越快。模型仍然想得太久时选“关闭”；服务不支持的写法会自动跳过。", "Lower is faster. If the model still thinks too long, choose Off; settings a service doesn't support are skipped automatically."),
                                         items: AIThinking.allCases.map { PanelItem(id: $0.rawValue, title: $0.title, selected: preferences.thinking == $0) }) { [weak self] id in
                guard let self, let level = AIThinking(rawValue: id) else { return }
                self.preferences.thinking = level; self.preferencesStore.save(self.preferences); self.render()
            })
        }
        let skin = preferences.resolvedTheme
        let rotation = StatusSkin.rotation(preferences.statusSkinRotation)
        sections.append(PanelSection(title: L("宠物与配色", "Pet & colors"),
                                     note: L("轻点宠物，在选中的主题间轮换，键盘配色同步改变（当前：\(skin.title)）。动画宠物来自 Google Noto Animated Emoji（CC BY 4.0）。",
                                             "Tap the pet to rotate through themes and keyboard colors (now: \(skin.title)). Animated pets: Google Noto Animated Emoji (CC BY 4.0)."),
                                     items: StatusSkin.themes.map { PanelItem(id: $0.rawValue, title: $0.title, selected: rotation.contains($0)) }) { [weak self] id in
            guard let self, let chosen = StatusSkin(rawValue: id) else { return }
            var next = StatusSkin.rotation(self.preferences.statusSkinRotation)
            if next.contains(chosen) { if next.count > 1 { next.removeAll { $0 == chosen } } } else { next.append(chosen) }
            self.preferences.statusSkinRotation = StatusSkin.themes.filter(next.contains).map(\.rawValue)
            // Removing the current theme selects the first remaining one; adding a pet selects it.
            if !next.contains(self.preferences.resolvedTheme) || !rotation.contains(chosen) {
                self.selectKeyboardTheme(next.contains(chosen) ? chosen : next[0])
            } else { self.preferencesStore.save(self.preferences); self.render() }
        })
        sections.append(PanelSection(title: L("Buffer", "Buffer"), items: [
            PanelItem(id: "source", title: L("插入原文", "Insert source"), role: .action, enabled: !buffer.source.isEmpty && !buffer.generating),
            PanelItem(id: "clear", title: L("清空 Buffer", "Clear Buffer"), role: .destructive, enabled: !buffer.source.isEmpty || !buffer.pluginPending.isEmpty),
        ]) { [weak self] id in
            guard let self else { return }
            if id == "source" { self.deliverSource() }
            else { self.surface.cancel(); self.cancelRequest(); self.engine.clear(); self.snapshot = .init(); self.buffer = .init(); self.status.text = ""; self.render() }
        })
        return sections
    }
    private var languageChoices: [Locale.Language] {
        languages.isEmpty ? [Locale.Language(identifier: "zh-Hans"), Locale.Language(identifier: "en")] : languages
    }
    private func configureLanguageRows() {
        speakRow.label.text = L("发送时朗读", "Read when sending")
        speakRow.toggle.accessibilityIdentifier = "keyboard.panel.speak"
        speakRow.toggle.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.surface.feedback.send(.press)
            self.preferences.speakTranslation = self.speakRow.toggle.isOn; self.preferencesStore.save(self.preferences)
            if !self.preferences.speakTranslation { self.speaker.stop() }
            self.render()
        }, for: .valueChanged)
        for (drum, isSource) in [(languageRow.source, true), (languageRow.target, false)] {
            drum.onTick = { [weak self] in self?.surface.feedback.send(.selection, combination: UUID().uuidString) }
            drum.onChange = { [weak self] index in
                guard let self, self.languageChoices.indices.contains(index) else { return }
                let id = self.languageChoices[index].minimalIdentifier
                if isSource { self.preferences.sourceLanguage = id } else { self.preferences.targetLanguage = id }
                self.languageChanged()
            }
        }
        languageRow.swap.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.surface.feedback.send(.press)
            let old = self.preferences.sourceLanguage
            self.preferences.sourceLanguage = self.preferences.targetLanguage; self.preferences.targetLanguage = old; self.languageChanged()
        }, for: .touchUpInside)
    }
    private func refreshLanguageRows() {
        let values = languageChoices
        let names = values.map { Locale.current.localizedString(forIdentifier: $0.minimalIdentifier) ?? $0.minimalIdentifier }
        func index(_ id: String) -> Int { values.firstIndex { $0.minimalIdentifier == id } ?? 0 }
        languageRow.source.set(items: names, selected: index(preferences.sourceLanguage))
        languageRow.target.set(items: names, selected: index(preferences.targetLanguage))
    }
    private func languageChanged() {
        preferencesStore.save(preferences); cancelRequest(); buffer.invalidateResult(); sourceChanged(); render()
    }
    private func sourceChanged() {
        guard realtime, bufferEnabled, onscreen, snapshot.preedit.isEmpty, !buffer.source.isEmpty else { return }
        run(appleTranslation, delay: 400_000_000)
    }
    private func pluginAuthorization(_ legacyID: String) -> String? {
        guard let store = officialPlugins, store.isEnabled(legacyID: legacyID),
              let entry = store.entry(legacyID: legacyID) else { return nil }
        return store.state(entry.id)?.installationID
    }
    private func run(_ plugin: any BufferPlugin, delay: UInt64) {
        guard let authorization = pluginAuthorization(plugin.descriptor.id) else { return }
        cancelRequest(); resultPluginAuthorization = authorization; status.text = ""
        let revision = buffer.sourceRevision, id = buffer.begin()
        let networkPlugin = plugin.descriptor.id.hasPrefix("ai.")
        var options = ["source": preferences.sourceLanguage, "target": preferences.targetLanguage]
        // Translation works clause by clause so its output comes back as matching blocks.
        if plugin === appleTranslation { options["blocks"] = DefaultBlockSegmenter.segments(from: buffer.source).joined(separator: AppleTranslationPlugin.blockSeparator) }
        let request = BufferPluginRequest(source: buffer.source, revision: revision, options: options)
        runner.submit(plugin: plugin, request: request, delayNanoseconds: delay, preview: { [weak self] text in
            guard let self, self.onscreen else { return }
            guard self.pluginAuthorization(plugin.descriptor.id) == authorization else { self.cancelRequest(); self.render(); return }
            if networkPlugin && !self.hasFullAccess { self.cancelRequest(); self.render(); return }; self.buffer.receive(text, id: id); self.renderBuffer(); self.resize()
        }, completion: { [weak self] result in
            guard let self, self.onscreen, self.buffer.sourceRevision == revision, self.buffer.generation == id else { return }
            guard self.pluginAuthorization(plugin.descriptor.id) == authorization else { self.cancelRequest(); self.render(); return }
            if networkPlugin && !self.hasFullAccess { self.cancelRequest(); self.render(); return }
            switch result {
            case .success(let output):
                guard output.revision == revision else { return }; self.buffer.finish(output.text, id: id, blocks: output.blocks)
            case .failure(let error):
                self.buffer.cancel(); self.reveal.stop(); self.caption.stop(); self.revealGeneration = nil; self.lastRunFailed = true; self.status.text = (error as? LocalizedError)?.errorDescription ?? L("请求未完成，原文已保留", "Request failed; source preserved")
            }
            self.metrics.sampleMemory(); self.metrics.save(); self.render()
        })
        render()
    }
    private func runSelectedPlugin() {
        guard let plugin = selectedPlugin else { return }
        if plugin == .translate { settle(); if !buffer.source.isEmpty { run(appleTranslation, delay: 0) }; render(); return }
        generate(plugin)
    }
    private func generate(_ plugin: KeyboardPlugin) {
        defer { render() }
        surface.cancel(); settle()
        guard onscreen, bufferEnabled, selectedPlugin == plugin, plugin.isAI else { return }
        if let hint = aiReadinessHint() { status.text = hint; return }
        guard !buffer.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let provider = config.provider else {
            status.text = L("先在输入行写下内容", "Write something in the input line first"); return
        }
        let instruction: String
        do {
            guard let store = officialPlugins, let entry = store.entry(legacyID: plugin.rawValue) else { throw OfficialPluginStateError.unavailable }
            let content = try store.package(entry.id).instruction()
            switch plugin {
            case .poem: instruction = content + "\n" + (try PoemPrompt.instruction(source: buffer.source, options: preferences.poem, library: config.poemLibrary))
            case .art: instruction = content + "\n" + TextArt.instruction(options: preferences.art)
            default: instruction = content
            }
        } catch let error as PoemError { status.text = error.message; return }
        catch { status.text = error.localizedDescription; return }
        let identity = provider.consentIdentity
        guard config.consents.contains(identity) || consentThisSession.contains(identity) else {
            let alert = UIAlertController(title: L("发送到 AI 服务", "Send to AI service"), message: "\(provider.name)\n\(identity)\n\n" + L("仅发送当前 Buffer 原文，不读取宿主全文。接收方的数据政策适用。", "Only the current Buffer text will be sent. Host documents are not read. The recipient's data policy applies."), preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: L("取消", "Cancel"), style: .cancel))
            alert.addAction(UIAlertAction(title: L("同意并发送", "Agree and send"), style: .default) { [weak self] _ in self?.consentThisSession.insert(identity); self?.generate(plugin) }); present(alert, animated: true); return
        }
        do {
            let key = try secrets.read(provider.id)
            guard !key.isEmpty else { status.text = L("请在 App 中保存 API Key", "Save your API Key in the app"); return }
            cancelRequest(); buffer.invalidateResult(); status.text = ""
            // Text art is forced onto its grid, one row per block, so rows sent one by one keep the frame.
            let art = preferences.art
            let shape: ((String) -> [String])? = plugin == .art ? { reply in
                let rows = TextArt.normalize(reply, options: art)
                return rows.enumerated().map { $0.offset == rows.count - 1 ? $0.element : $0.element + "\n" }
            } : nil
            run(AITextPlugin(id: plugin.rawValue, title: plugin.title, provider: provider, key: key, consent: identity, instruction: instruction,
                             thinking: preferences.thinking, shape: shape), delay: 0)
        } catch { status.text = (error as? CoreError)?.localizedDescription ?? L("无法读取 AI 配置", "Unable to read AI configuration") }
    }
    #if KEYBOARD_LAYOUT_TESTS
    var layoutViews: (buffer: UIView, candidates: CandidateStrip, keys: KeySurface, settings: KeycapButton, bottom: UIStackView, source: SingleLineTextView, insert: InsertKeycapButton, globe: KeycapButton, result: SingleLineTextView, stop: KeycapButton) {
        (bufferPanel, candidateStrip, surface, moreButton, bottom, source, insertButton, globe, result, stopButton)
    }
    func developmentType(_ text: String) { type(text) }
    func developmentResetPreferences() {
        developmentPreferencesAreIsolated = true
        if developmentPluginRoot == nil {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("Keyboard-Plugins-\(UUID())")
            developmentPluginRoot = root
            if let catalog = try? OfficialPluginCatalog.bundled() {
                officialPlugins = OfficialPluginStore(root: root, platform: "ios", hostVersion: "1.1.0", catalog: catalog, legacyProfile: true)
                try? officialPlugins?.bootstrap()
            }
        }
        config = .init(); preferences = .init(); engine.traditional = false
        importedSchemeSelection = nil; importedSchemeEnglish = false; importedSchemeLibrary = .init(); customLayoutSnapshot = nil
        choose(.pinyin); render()
    }
    func developmentChoose(_ value: InputScheme) { importedSchemeSelection = nil; preferences.select(value); choose(value); render() }
    func developmentChooseImported(_ selection: RimeSchemeSelection, store: RimeSchemeStore? = nil) { if let store { importedSchemeStore = store }; importedSchemeSelection = selection; choose(preferences.scheme); render() }
    var developmentImportedSelection: RimeSchemeSelection? { importedSchemeSelection }
    func developmentSetCustomLayout(_ layout: CustomKeyboardLayout?) {
        customLayoutSnapshot = layout.flatMap { try? $0.validated() }; render(); view.setNeedsLayout(); view.layoutIfNeeded()
    }
    func developmentOrdinaryAppearance(layout: OrdinaryKeyboardLayout, skin: KeyboardSkin = .system) {
        preferences.ordinaryLayout = layout; preferences.keyboardSkin = skin
        preferences.statusSkin = (skin == .system ? StatusSkin.apple : .rhino).rawValue
        choose(preferences.scheme); render(); view.layoutIfNeeded()
    }
    func developmentSelectNineKeySpelling(_ value: String) { selectNineKeySpelling(value) }
    var developmentStandardFunctions: [StandardKeyControl: UIView] { standardFunctions }
    func developmentChord(_ text: String) { type(text, chord: true) }
    var developmentHandPreview: ChordHandPreviewView { handPreview }
    var developmentShortcuts: PluginShortcutBar { shortcuts }
    var developmentSelectedPlugin: KeyboardPlugin? { selectedPlugin }
    var developmentPluginControls: (run: KeycapButton, plugin: KeycapButton, settings: KeycapButton) { (runButton, aiButton, settingsButton) }
    func developmentHostResigned() { hostResigned() }
    func developmentPreview(_ text: String) { if let id = buffer.generation { buffer.receive(text, id: id); render() } }
    /// Opens a plugin with sample text, optionally a finished output or a running request.
    func developmentPlugin(_ plugin: KeyboardPlugin?, source: String, output: String? = nil, blocks: [String]? = nil, generating: Bool = false) {
        resultPluginAuthorization = plugin.flatMap { pluginAuthorization($0.rawValue) }
        cancelRequest(); buffer = .init(); bufferEnabled = true; selectedPlugin = plugin; panelOpen = false; breakAssociationChain()
        buffer.edit(source)
        if let output { let id = buffer.begin(); buffer.finish(output, id: id, blocks: blocks) }
        if generating { _ = buffer.begin() }
        status.text = ""; refreshPluginMenu(); render()
    }
    func developmentSkin(_ skin: StatusSkin) { preferences.statusSkin = skin.canonical.rawValue; render() }
    func developmentOpenSettings() { openSettings(for: selectedPlugin) }
    func developmentClosePanel() { closePanel() }
    func developmentClearAssociations() { breakAssociationChain(); render() }
    func developmentFinish(_ output: String) { if let id = buffer.generation { buffer.finish(output, id: id); render() } }
    var developmentPanel: KeyboardPanel? { panelOpen ? panel : nil }
    var developmentSpaceKey: SpaceCursorButton { spaceKey }
    var developmentBufferSelection: Range<Int>? { buffer.selection }
    var developmentAssociations: [String] { showingAssociations ? associations : [] }
    func developmentClearAssociationHistory() { applyAssociationReset(UUID()); render() }
    func developmentApplyAssociationReset(_ revision: UUID?) { applyAssociationReset(revision); render() }
    func developmentAssociationStore(_ store: AssociationHistoryStore) {
        associationStore = store; associationHistoryLoaded = false; associationHistoryChanges = 0; breakAssociationChain()
    }
    func developmentSaveAssociationHistory() { associationHistoryChanges = max(1, associationHistoryChanges); saveAssociationHistory() }
    var developmentStatus: String { status.text ?? "" }
    func developmentReleaseEdgeTouchDelay() { releaseEdgeTouchDelay() }
    func developmentNumeric() { numbers.sendActions(for: .touchUpInside) }
    var developmentBufferCursor: Int { buffer.cursor }
    func developmentShift() { toggleShift() }
    func developmentLanguage() { toggleLanguage() }
    func developmentEnter() { enter() }
    func developmentSpace() { space() }
    func developmentBackspace() { backspace() }
    func developmentHostTextChanged() { hostTextChanged() }
    func developmentCaptureHostText() { captureHostText() }
    var developmentCapturePending: Bool { captureTimer != nil }
    func developmentAutoDelay(_ delay: Double) { setDefaultDelay(delay); render() }
    func developmentAutoTick() { tickDefaultBuffer() }
    var developmentTypingMetrics: BufferLiveTypingMetrics { liveTyping }
    var developmentTypingSession: TypingSessionTotals { session }
    func developmentRefreshTypingStats() { updateTypingStats() }
    func developmentAppendSignature() { appendTypingSignature() }
    func developmentShowTypingCard() { showTypingCard() }
    func developmentCloseTypingCard() { dismissTypingCard() }
    func developmentSaveTypingCard(store: TypingCardStore) { typingCardStore = store; saveTypingCard() }
    var developmentTypingCardPNG: Data? { typingCardPNG }
    var developmentDelete: RepeatKeycapButton { deleteButton }
    var developmentRaw: String { engine.rawInput }
    func developmentSetLayout(_ value: ChordLayout) { changeLayout(value) }
    func developmentBufferCursor(_ cursor: Int) { buffer.moveCursor(cursor - buffer.cursor); render() }
    var developmentBufferSource: (text: String, revision: UUID) { (buffer.source, buffer.sourceRevision) }
    func developmentContent(preedit: String = "", candidates: [String] = []) {
        snapshot = .init(preedit: preedit, candidates: candidates); render()
    }
    func developmentRevokePlugin(_ plugin: KeyboardPlugin) throws {
        guard let store = officialPlugins, let entry = store.entry(legacyID: plugin.rawValue) else { throw OfficialPluginStateError.unavailable }
        try store.setEnabled(false, id: entry.id)
        try store.setEnabled(true, id: entry.id)
    }
    func developmentBuffer(_ text: String?, plugin: Bool = false, output: String? = nil, generating: Bool = false) {
        resultPluginAuthorization = plugin ? pluginAuthorization(KeyboardPlugin.translate.rawValue) : nil
        buffer = .init(); bufferEnabled = text != nil; selectedPlugin = plugin ? .translate : nil
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
            selectedPlugin = .translate; buffer.edit(bufferText); let id = buffer.begin(); buffer.finish("Hello, this is the translation preview.", id: id); refreshPluginMenu()
        }
        snapshot = .init(preedit: "nihao", candidates: ["你好", "您好", "你们好", "你好世界", "拟好", "倪皓"])
        render(); return (bufferPanel, candidateStrip, surface)
    }
    #endif

}

/// Our own buffer between a stream and the output line. Tokens come in bursts; the line reveals
/// them at an even pace that speeds up with the backlog (so it never lags far behind) and
/// follows the newest text smoothly, until the reader drags the line themselves.
@MainActor final class StreamReveal: NSObject {
    private weak var line: SingleLineTextView?
    private let settled: () -> Void
    private var target: [Character] = []
    private var shown: Double = 0
    private var finished = false
    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0
    private(set) var following = true
    /// Readable pace for answers; quick catch-up otherwise.
    var readable = true
    /// True while characters are still being revealed.
    var isActive: Bool { link != nil }
    init(line: SingleLineTextView, settled: @escaping () -> Void) { self.line = line; self.settled = settled }
    /// A new stream: follow it. What is already shown stays, so a revised text continues from
    /// the part that still matches.
    func start() { link?.invalidate(); link = nil; following = true; finished = false; line?.scrollToStart() }
    func isBehind(_ text: String) -> Bool { Int(shown) < text.count }
    /// Empty line, nothing pending.
    func clear() { stop(); line?.text = "" }
    func stop() { link?.invalidate(); link = nil; target = []; shown = 0; finished = false }
    func feed(_ text: String, finished done: Bool) {
        let next = Array(text)
        if !next.starts(with: target) { shown = min(shown, Double(zip(next, target).prefix { $0 == $1 }.count)) }
        target = next; finished = done
        guard link == nil else { return }
        guard Int(shown) < target.count else { if done { settled() }; return }
        last = CACurrentMediaTime()
        let link = CADisplayLink(target: self, selector: #selector(tick(_:))); link.add(to: .main, forMode: .common)
        self.link = link
    }
    @objc private func tick(_ link: CADisplayLink) {
        guard let line else { stop(); return }
        let now = link.timestamp, dt = min(0.1, max(0, now - last)); last = now
        let backlog = Double(target.count) - shown
        // Answers stream at a readable 25–90 characters a second, even when they arrive in one
        // burst; live translation still clears any backlog in ~0.45 s.
        let rate = readable ? min(90, max(25, backlog / 1.2)) : max(28, backlog / 0.45)
        shown = min(Double(target.count), shown + rate * dt)
        let text = String(target.prefix(Int(shown)))
        if line.text != text { line.text = text }
        if line.isTracking || line.isDragging { following = false }
        if following {
            line.layoutIfNeeded()
            // Ease towards the end of the text rather than jumping to it.
            let end = max(0, line.contentSize.width - line.bounds.width), gap = end - line.contentOffset.x
            if gap > 0.5 { line.contentOffset.x += max(0.5, gap * 0.2) }
        }
        guard Int(shown) >= target.count else { return }
        // Caught up: rest until more arrives, or hand over to the finished blocks.
        self.link?.invalidate(); self.link = nil
        if finished { settled() }
    }
}

/// The model's thinking as subtitles: the newest complete sentence, faded in and held long
/// enough to read. If thinking outpaces reading, older sentences are skipped — the caption is
/// never behind, and never delays the answer.
@MainActor final class ThinkingCaption {
    static let dwell: CFTimeInterval = 1.1
    private weak var line: SingleLineTextView?
    private var latest = "", shown = ""
    private var lastChange: CFTimeInterval = 0
    private var timer: Timer?
    init(line: SingleLineTextView) { self.line = line }
    var current: String { shown }
    func update(_ reasoning: String) {
        latest = Self.caption(reasoning)
        guard !latest.isEmpty else { return }
        if shown.isEmpty || CACurrentMediaTime() - lastChange >= Self.dwell { show() }
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.latest != self.shown, CACurrentMediaTime() - self.lastChange >= Self.dwell else { return }
                self.show()
            }
        }
        RunLoop.main.add(timer, forMode: .common); self.timer = timer
    }
    func stop() { timer?.invalidate(); timer = nil; latest = ""; shown = "" }
    private func show() {
        guard let line, latest != shown else { return }
        shown = latest; lastChange = CACurrentMediaTime()
        let fade = CATransition(); fade.type = .fade; fade.duration = 0.25
        line.layer.add(fade, forKey: "caption")
        line.text = shown; line.layoutIfNeeded()
        // A sentence wider than the line shows its newest words.
        line.contentOffset.x = max(0, line.contentSize.width - line.bounds.width)
    }
    /// The last finished sentence; before the first one finishes, a long enough unfinished tail.
    static func caption(_ text: String) -> String {
        let enders: Set<Character> = ["。", "！", "？", ".", "!", "?", "；", ";", "…"]
        var sentences: [String] = [], current = ""
        for c in text {
            current.append(c)
            if enders.contains(c) {
                let s = current.trimmingCharacters(in: .whitespaces); if s.count > 1 { sentences.append(s) }; current = ""
            }
        }
        let tail = current.trimmingCharacters(in: .whitespaces)
        if let last = sentences.last, tail.count < 24 { return String(last.suffix(80)) }
        return tail.count >= 10 ? String(tail.suffix(80)) : ""
    }
}
