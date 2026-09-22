import UIKit
import RimesCore

final class KeyboardViewController: UIInputViewController {
    private let engine = MobileEngine()
    private lazy var delivery = ProxyTextDelivery(controller: self) { [weak self] in self?.onscreen ?? false }
    private let store = ConfigurationStore(), secrets = KeychainStore()
    private var config = AppConfiguration()
    private var scheme: InputScheme = .pinyin
    private var snapshot = EngineSnapshot()
    private var buffer = BufferSession()
    private var bufferEnabled = false
    private var requestTask: Task<Void, Never>?
    private var currentDocument: UUID?
    private var onscreen = false
    private var expanded = false
    private let stack = UIStackView(), toolbar = UIStackView(), candidates = UIStackView(), candidateScroll = UIScrollView()
    private let preedit = UILabel(), status = UILabel(), source = UITextView(), result = UITextView(), surface = KeySurface()
    private let bufferPanel = UIStackView(), actions = UIStackView()
    private let schemeButton = UIButton(type: .system), bufferButton = UIButton(type: .system), aiButton = UIButton(type: .system)
    private var height: NSLayoutConstraint!, candidatesHeight: NSLayoutConstraint!
    private var rowHeights: [NSLayoutConstraint] = [], textHeights: [NSLayoutConstraint] = []
    private var preeditHeight: NSLayoutConstraint!, statusHeight: NSLayoutConstraint!
    private let expandButton = UIButton(type: .system)
    private var consentThisSession = Set<String>()
    private var translationLanguage = "English"
    private var aiAction: AIAction = .polish
    override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = .systemGroupedBackground
        stack.axis = .vertical; stack.spacing = 5; stack.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 5), stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -5), stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 5), stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -5)])
        height = view.heightAnchor.constraint(equalToConstant: 292); height.priority = .required; height.isActive = true
        toolbar.spacing = 5; toolbar.distribution = .fillEqually; stack.addArrangedSubview(toolbar)
        schemeButton.addAction(UIAction { [weak self] _ in self?.surface.cancel() }, for: .touchDown)
        toolbar.addArrangedSubview(schemeButton)
        configure(bufferButton, "Buffer") { [weak self] in self?.toggleBuffer() }; toolbar.addArrangedSubview(bufferButton)
        configure(expandButton, "↕") { [weak self] in self?.expanded.toggle(); self?.renderCandidates(); self?.resize() }; toolbar.addArrangedSubview(expandButton)
        preedit.font = .monospacedSystemFont(ofSize: 14, weight: .medium); preedit.textColor = .secondaryLabel; preeditHeight = preedit.heightAnchor.constraint(equalToConstant: 20); preeditHeight.isActive = true; stack.addArrangedSubview(preedit)
        candidates.axis = .horizontal; candidates.spacing = 8; candidates.translatesAutoresizingMaskIntoConstraints = false
        candidateScroll.addSubview(candidates); candidateScroll.showsHorizontalScrollIndicator = false; stack.addArrangedSubview(candidateScroll)
        candidatesHeight = candidateScroll.heightAnchor.constraint(equalToConstant: 34); candidatesHeight.isActive = true
        NSLayoutConstraint.activate([candidates.leadingAnchor.constraint(equalTo: candidateScroll.contentLayoutGuide.leadingAnchor), candidates.trailingAnchor.constraint(equalTo: candidateScroll.contentLayoutGuide.trailingAnchor), candidates.topAnchor.constraint(equalTo: candidateScroll.contentLayoutGuide.topAnchor), candidates.bottomAnchor.constraint(equalTo: candidateScroll.contentLayoutGuide.bottomAnchor)])
        bufferPanel.axis = .vertical; bufferPanel.spacing = 4
        for textView in [source,result] { textView.isEditable = false; textView.isSelectable = false; textView.font = .systemFont(ofSize: 16); textView.layer.cornerRadius = 7; let h = textView.heightAnchor.constraint(equalToConstant: 52); h.isActive = true; textHeights.append(h); bufferPanel.addArrangedSubview(textView) }
        let editRow = UIStackView(); editRow.distribution = .fillEqually; editRow.spacing = 4
        editRow.addArrangedSubview(button("←") { [weak self] in self?.settle(); self?.buffer.moveCursor(-1); self?.renderBuffer() })
        editRow.addArrangedSubview(button("→") { [weak self] in self?.settle(); self?.buffer.moveCursor(1); self?.renderBuffer() })
        editRow.addArrangedSubview(button(L("清空", "Clear")) { [weak self] in self?.cancelRequest(); self?.engine.clear(); self?.snapshot = .init(); self?.buffer.edit(""); self?.render() })
        editRow.addArrangedSubview(button(L("插入一块", "Insert next")) { [weak self] in self?.deliver(all: false) })
        editRow.addArrangedSubview(button(L("全部插入", "Insert all")) { [weak self] in self?.deliver(all: true) }); bufferPanel.addArrangedSubview(editRow)
        actions.distribution = .fillEqually; actions.spacing = 4
        configure(aiButton, "AI") { }; aiButton.showsMenuAsPrimaryAction = true
        aiButton.menu = UIMenu(children: AIAction.allCases.map { action in UIAction(title: action.title) { [weak self] _ in self?.aiAction = action; self?.generate() } })
        actions.addArrangedSubview(aiButton)
        let language = button(L("译文语言", "Translate to")) {}; language.showsMenuAsPrimaryAction = true
        language.menu = UIMenu(children: ["English","简体中文","繁體中文","日本語","한국어","Français","Deutsch","Español"].map { value in UIAction(title: value) { [weak self] _ in self?.translationLanguage = value; language.setTitle(value, for: .normal) } })
        actions.addArrangedSubview(language); actions.addArrangedSubview(button(L("取消生成", "Cancel AI")) { [weak self] in self?.cancelRequest(); self?.renderBuffer() }); bufferPanel.addArrangedSubview(actions)
        bufferPanel.isHidden = true; stack.addArrangedSubview(bufferPanel)
        stack.addArrangedSubview(surface); surface.heightAnchor.constraint(greaterThanOrEqualToConstant: 65).isActive = true
        surface.onKey = { [weak self] in self?.type($0) }
        surface.onPreview = { [weak self] in self?.preedit.text = $0.isEmpty ? self?.snapshot.preedit : $0 }
        surface.onChord = { [weak self] resolution in
            guard let self else { return }; guard let resolution else { self.status.text = L("无有效组合，未输入", "No valid combination"); return }
            self.type(resolution.input)
        }
        let bottom = UIStackView(); bottom.distribution = .fillEqually; bottom.spacing = 4
        let globe = button("") {}; globe.setImage(UIImage(systemName: "globe"), for: .normal); globe.accessibilityLabel = L("下一键盘", "Next keyboard"); globe.addTarget(self, action: #selector(handleInputModeList(from:with:)), for: .allTouchEvents); bottom.addArrangedSubview(globe)
        bottom.addArrangedSubview(button("123 / ABC") { [weak self] in self?.settle(); self?.surface.numeric.toggle() })
        bottom.addArrangedSubview(button("⇧") { [weak self] in self?.surface.shifted.toggle() })
        bottom.addArrangedSubview(button(L("空格", "Space")) { [weak self] in self?.space() })
        bottom.addArrangedSubview(button("⌫") { [weak self] in self?.backspace() })
        bottom.addArrangedSubview(button("↵") { [weak self] in self?.enter() }); stack.addArrangedSubview(bottom)
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabel; status.numberOfLines = 2; statusHeight = status.heightAnchor.constraint(equalToConstant: 28); statusHeight.isActive = true; stack.addArrangedSubview(status)
        for row in [toolbar,bottom,editRow,actions] { let h = row.heightAnchor.constraint(equalToConstant: 32); h.isActive = true; rowHeights.append(h) }
        NotificationCenter.default.addObserver(self, selector: #selector(protect), name: .NSExtensionHostWillResignActive, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(resume), name: .NSExtensionHostDidBecomeActive, object: nil)
    }
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated); onscreen = true; config = store.load(); translationLanguage = config.translationLanguage
        if currentDocument != textDocumentProxy.documentIdentifier { cancelRequest(); buffer = .init() }; currentDocument = textDocumentProxy.documentIdentifier; choose(config.scheme); render()
    }
    override func viewWillDisappear(_ animated: Bool) { super.viewWillDisappear(animated); protect() }
    @objc private func resume() {
        guard isViewLoaded, view.window != nil else { return }
        onscreen = true; currentDocument = textDocumentProxy.documentIdentifier
        config = store.load(); choose(config.scheme); render()
    }
    @objc private func protect() {
        onscreen = false; consentThisSession.removeAll(); surface.retire(); cancelRequest(); engine.clear(); snapshot = .init(); buffer = .init(); bufferEnabled = false; render()
    }
    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) { surface.retire(); super.viewWillTransition(to: size, with: coordinator); coordinator.animate(alongsideTransition: { _ in self.resize() }) }
    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        if currentDocument != textDocumentProxy.documentIdentifier {
            // A field change within this visible session stops work for the old
            // target, but keeps unsubmitted blocks for another explicit insertion.
            // Hiding/resigning the keyboard ends the session and clears the draft.
            cancelRequest(); surface.cancel(); engine.clear(); snapshot = .init()
            currentDocument = textDocumentProxy.documentIdentifier; render()
        }
        if !hasFullAccess { cancelRequest() }
    }
    private func configure(_ button: UIButton, _ title: String, action: @escaping () -> Void) {
        button.setTitle(title, for: .normal); button.titleLabel?.font = .systemFont(ofSize: 13, weight: .medium)
        button.backgroundColor = .secondarySystemGroupedBackground; button.layer.cornerRadius = 6
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
    }
    private func button(_ title: String, action: @escaping () -> Void) -> UIButton { let b = UIButton(type: .system); configure(b,title,action:action); return b }
    private func choose(_ value: InputScheme) {
        surface.cancel(); engine.clear(); snapshot = .init(); scheme = value
        surface.profile = config.chord; surface.chordMode = value == .chord; surface.numeric = false; surface.shifted = false
        if value != .english {
            let schema = value == .chord && config.chord.outputEncoding == .ziranma ? "rimes_ziranma" : value.schemaID
            if !engine.select(schema: schema) { status.text = L("输入引擎不可用，请切换英文或其他键盘", "Engine unavailable. Switch to English or another keyboard.") }
        }
        schemeButton.setTitle(value.title, for: .normal); schemeButton.showsMenuAsPrimaryAction = true
        schemeButton.menu = UIMenu(children: InputScheme.allCases.map { value in UIAction(title: value.title, state: value == scheme ? .on : .off) { [weak self] _ in self?.settle(); self?.choose(value); self?.render() } })
    }
    private func receive(_ state: EngineSnapshot) { snapshot = state; if !state.commit.isEmpty { insert(state.commit) }; render() }
    private func insert(_ text: String) {
        guard onscreen else { return }
        if bufferEnabled { cancelRequest(); buffer.insert(text) } else if let target = currentDocument { _ = delivery.insert(text,target:target) }
    }
    private func type(_ text: String) {
        guard onscreen else { return }; status.text = ""
        if scheme == .english { insert(text); render(); return }
        guard engine.available else { return }
        for scalar in text.unicodeScalars {
            let (state, handled) = engine.handledKey(Int32(scalar.value)); receive(state)
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
    private func enter() { surface.cancel(); if !snapshot.preedit.isEmpty { settle() } else { insert("\n"); render() } }
    private func backspace() {
        surface.cancel(); if !snapshot.preedit.isEmpty { receive(engine.process(key: 0xff08)) }
        else if bufferEnabled { cancelRequest(); buffer.backspace(); renderBuffer() }
        else if let target = currentDocument { _ = delivery.deleteBackward(target:target) }
    }
    private func toggleBuffer() { surface.cancel(); settle(); bufferEnabled.toggle(); if bufferEnabled { expanded = false }; bufferButton.tintColor = bufferEnabled ? .systemOrange : .systemTeal; render() }
    private func render() { preedit.text = snapshot.preedit; renderCandidates(); renderBuffer(); resize() }
    private func renderCandidates() {
        candidates.arrangedSubviews.forEach { $0.removeFromSuperview() }
        candidates.axis = expanded ? .vertical : .horizontal; candidatesHeight.constant = expanded ? 110 : 34
        for (i,text) in snapshot.candidates.enumerated() {
            let b = button(text) { [weak self] in guard let self else { return }; self.surface.cancel(); self.receive(self.engine.candidate(i)) }
            b.contentEdgeInsets = .init(top: 4,left: 9,bottom: 4,right: 9); b.heightAnchor.constraint(equalToConstant: 30).isActive = true; candidates.addArrangedSubview(b)
        }
    }
    private func renderBuffer() {
        bufferPanel.isHidden = !bufferEnabled; expandButton.isEnabled = !bufferEnabled
        var shown = buffer.source; shown.insert("▏", at: shown.index(shown.startIndex, offsetBy: buffer.cursor)); source.text = shown
        result.text = buffer.generating ? buffer.preview : buffer.result?.joined() ?? L("生成结果会在这里预览", "Generated text appears here")
        aiButton.isEnabled = hasFullAccess && !buffer.source.isEmpty && !buffer.generating
        if bufferEnabled && !hasFullAccess { status.text = L("AI 需要完全访问；离线输入仍可用", "AI needs Full Access; offline typing still works") }
    }
    private func resize() {
        let landscape = view.bounds.width > 600
        rowHeights.forEach { $0.constant = landscape ? 28 : 32 }
        textHeights.forEach { $0.constant = landscape ? 28 : 52 }
        preeditHeight.constant = landscape ? 16 : 20
        statusHeight.constant = landscape ? 16 : 28
        candidatesHeight.constant = expanded ? (landscape ? 80 : 110) : (landscape ? 28 : 34)
        height.constant = (landscape ? 238 : 292) + (bufferEnabled ? (landscape ? 128 : 180) : 0) + (expanded ? (landscape ? 52 : 76) : 0)
    }
    private func deliver(all: Bool) {
        surface.cancel(); if !snapshot.preedit.isEmpty { settle(); return }
        guard onscreen, !buffer.generating, currentDocument == textDocumentProxy.documentIdentifier else { return }
        let text = all ? buffer.pending.joined() : buffer.pending.first ?? ""
        guard !text.isEmpty else { return }
        guard let target = currentDocument, delivery.insert(text,target:target) else { return }; buffer.consumed(all: all); renderBuffer()
    }
    private func cancelRequest() { requestTask?.cancel(); requestTask = nil; buffer.cancel() }
    private func generate() {
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
            let request = try AIRequest.make(provider: provider, key: key, source: buffer.source, action: aiAction, language: translationLanguage, consent: identity)
            cancelRequest(); let id = buffer.begin(); renderBuffer()
            requestTask = Task { [weak self] in
                do {
                    let text = try await AIClient().generate(request) { [weak self] partial in
                        await MainActor.run { guard let self, self.onscreen, self.hasFullAccess else { return }; self.buffer.receive(partial,id:id); self.renderBuffer() }
                    }
                    guard let self, !Task.isCancelled, self.onscreen, self.hasFullAccess else { return }
                    self.buffer.finish(text,id:id); self.renderBuffer()
                } catch {
                    guard let self, self.buffer.generation == id else { return }; self.buffer.cancel(); self.status.text = (error as? CoreError)?.localizedDescription ?? L("请求失败或取消，原文已保留", "Request failed or cancelled. Source preserved."); self.renderBuffer()
                }
            }
        } catch { status.text = (error as? CoreError)?.localizedDescription ?? L("无法读取 AI 配置", "Unable to read AI configuration") }
    }
}
