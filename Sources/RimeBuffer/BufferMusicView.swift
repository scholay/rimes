import Cocoa

/// Compact Buffer rows. Only the toolbar contains transport actions; keys and
/// harmonic context belong to row one, the drummer's controls to row two.
final class BufferMusicView: NSView, NSTextFieldDelegate {
    static func bodyHeight(tracks: Int) -> CGFloat { 124 + CGFloat(min(2, max(0, tracks))) * 34 }
    static var recommendedHeight: CGFloat { bodyHeight(tracks: 0) }
    let toolbarView: NSView
    var onRequestKeyboardFocus: (() -> Void)?
    var onKeyEvent: ((NSEvent) -> Bool)?
    var onTrackCountChanged: ((Int) -> Void)?
    private let toolbar = MusicTransportToolbar()
    private let keyboard = MusicKeyboardRow()
    private let chord = NSTextField(labelWithString: "—")
    private let root = NSTextField(labelWithString: "C")
    private let mode = FirstMousePopUpButton(frame: .zero, pullsDown: false)
    private let beats = MusicBeatRow()
    private let bpmLabel = NSTextField(labelWithString: "BPM")
    private let bpm = NSTextField(string: "110")
    private let stepper = NSStepper()
    private let meter = FirstMousePopUpButton(frame: .zero, pullsDown: false)
    private let groove = FirstMousePopUpButton(frame: .zero, pullsDown: false)
    private let drums = FirstMouseButton(frame: .zero)
    private var trackViews: [MusicLoopRow] = []
    private var snapshot = BufferMusicSnapshot()
    private var observers: [NSObjectProtocol] = []
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: Self.bodyHeight(tracks: snapshot.loops.count)) }

    override init(frame frameRect: NSRect) {
        toolbarView = toolbar
        super.init(frame: frameRect)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        [keyboard, chord, root, mode, beats, bpmLabel, bpm, stepper, meter, groove, drums].forEach { addSubview($0) }
        root.font = .monospacedSystemFont(ofSize: 10, weight: .semibold)
        chord.font = .systemFont(ofSize: 11, weight: .semibold)
        bpmLabel.font = .systemFont(ofSize: 8)
        for label in [root, chord, bpmLabel] {
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
        }
        for (popup, titles, action) in [
            (mode, BufferMusicMode.allCases.map(\.rawValue), #selector(selectMusicMode)),
            (meter, BufferMusicMeter.allCases.map(\.rawValue), #selector(changeMeter)),
            (groove, BufferMusicGroove.allCases.map(\.rawValue), #selector(changeGroove))
        ] {
            popup.addItems(withTitles: titles)
            popup.controlSize = .mini
            popup.font = .systemFont(ofSize: 9)
            popup.target = self; popup.action = action
        }
        mode.setAccessibilityLabel("当前调式")
        meter.setAccessibilityLabel("拍型")
        groove.setAccessibilityLabel("节奏型")
        bpm.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        bpm.alignment = .center
        bpm.focusRingType = .none
        bpm.delegate = self
        bpm.setAccessibilityLabel("BPM（四分音符每分钟）")
        stepper.minValue = 40; stepper.maxValue = 240; stepper.increment = 1
        stepper.controlSize = .mini; stepper.target = self; stepper.action = #selector(stepBPM)
        configure(drums, symbol: "metronome", title: "", action: #selector(toggleDrums))
        drums.toolTip = "Enter 开关架子鼓 · AVL Black Pearl 五层力度采样"
        configure(toolbar.record, symbol: "record.circle", title: "+ Loop  Tab", action: #selector(toggleLoop))
        configure(toolbar.stop, symbol: "stop.fill", title: "", action: #selector(stopMusic))
        toolbar.record.toolTip = "Tab 添加一轨，再按完成；第二轨对齐第一轨，最多两轨"
        toolbar.stop.toolTip = "停止全部声音并清除两轨 Loop（Esc）"
        for (control, title, action) in [
            (toolbar.transposeStepper, "移调，每步一个半音", #selector(stepTranspose)),
            (toolbar.octaveStepper, "升降八度，每步一个八度", #selector(stepOctave))
        ] {
            control.controlSize = .mini; control.increment = 1
            control.valueWraps = false; control.target = self; control.action = action
            control.toolTip = title + "；未分配快捷键"
            control.setAccessibilityLabel(title)
        }
        observers.append(NotificationCenter.default.addObserver(forName: .bufferMusicDidChange, object: nil, queue: .main) { [weak self] _ in self?.refresh() })
        observers.append(NotificationCenter.default.addObserver(forName: .rimeAppearanceDidChange, object: nil, queue: .main) { [weak self] _ in self?.applyAppearance() })
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onRequestKeyboardFocus?() }
    override func keyDown(with event: NSEvent) { if onKeyEvent?(event) != true { super.keyDown(with: event) } }
    override func keyUp(with event: NSEvent) { if onKeyEvent?(event) != true { super.keyUp(with: event) } }
    func refresh() { render(BufferMusicSession.shared.snapshot) }

    /// Same projection for live notifications and render QA; no audio side effects.
    func render(_ state: BufferMusicSnapshot) {
        let oldCount = snapshot.loops.count
        snapshot = state
        keyboard.snapshot = state; keyboard.needsDisplay = true
        root.stringValue = state.rootName
        mode.selectItem(withTitle: state.mode.rawValue)
        toolbar.transposeLabel.stringValue = String(format: "移调 %+d", state.transpose)
        toolbar.octaveLabel.stringValue = String(format: "八度 %+d", state.octaveShift)
        toolbar.transposeStepper.minValue = Double(-28 - state.octaveShift * 12)
        toolbar.transposeStepper.maxValue = Double(127 - 52 - state.octaveShift * 12)
        toolbar.octaveStepper.minValue = ceil(Double(-28 - state.transpose) / 12)
        toolbar.octaveStepper.maxValue = floor(Double(127 - 52 - state.transpose) / 12)
        toolbar.transposeStepper.integerValue = state.transpose
        toolbar.octaveStepper.integerValue = state.octaveShift
        chord.stringValue = state.chordName
        chord.setAccessibilityLabel("当前和弦：\(state.chordName)")
        beats.snapshot = state; beats.needsDisplay = true
        if bpm.currentEditor() == nil { bpm.integerValue = state.bpm }
        stepper.integerValue = state.bpm
        bpm.isEnabled = state.canChangeTiming; stepper.isEnabled = state.canChangeTiming
        meter.isEnabled = state.canChangeTiming
        bpm.toolTip = state.canChangeTiming ? "40–240 BPM，四分音符计速" : "停止 Loop 后可调整速度与拍型"
        meter.selectItem(withTitle: state.meter.rawValue)
        groove.selectItem(withTitle: state.groove.rawValue)
        drums.usesPrimarySurface = state.isDrumsEnabled
        drums.setAccessibilityLabel(state.isDrumsEnabled ? "关闭架子鼓" : "开启架子鼓")
        toolbar.record.title = state.isRecording ? "完成 Tab" : "录制 Tab"
        toolbar.record.isEnabled = (!state.isActive || state.isReady) && state.canAddLoop
        toolbar.record.usesPrimarySurface = state.isRecording
        toolbar.status.stringValue = state.errorMessage ?? (!state.fillTitle.isEmpty ? state.fillTitle : (state.isRecording ? (state.loops.last?.queued == true ? "等待小节 · 待录" : "录制中") : "Loop \(state.loops.count)/2"))
        toolbar.status.toolTip = state.errorMessage ?? "空格轮换加花；长按进入过渡，松开于小节末收尾"
        while trackViews.count > state.loops.count { trackViews.removeLast().removeFromSuperview() }
        while trackViews.count < state.loops.count {
            let view = MusicLoopRow()
            view.onMute = { [weak self, weak view] in
                guard let id = view?.state?.id else { return }
                self?.onRequestKeyboardFocus?(); BufferMusicSession.shared.toggleTrackMute(id)
            }
            view.onDelete = { [weak self, weak view] in
                guard let id = view?.state?.id else { return }
                self?.onRequestKeyboardFocus?(); BufferMusicSession.shared.removeTrack(id)
            }
            trackViews.append(view); addSubview(view)
        }
        for (index, view) in trackViews.enumerated() {
            view.state = state.loops[index]
            view.number = index + 1
            view.canDelete = !state.isRecording
            view.needsDisplay = true
        }
        applyAppearance(); needsLayout = true
        if oldCount != state.loops.count {
            invalidateIntrinsicContentSize()
            onTrackCountChanged?(state.loops.count)
        }
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        let detailWidth: CGFloat = min(136, w * 0.32)
        let dx = w - detailWidth - 6
        keyboard.frame = NSRect(x: 6, y: 4, width: max(0, dx - 16), height: 82)
        root.frame = NSRect(x: dx, y: 25, width: 25, height: 16)
        mode.frame = NSRect(x: dx + 25, y: 23, width: 62, height: 20)
        chord.frame = NSRect(x: dx, y: 49, width: detailWidth, height: 17)
        let y: CGFloat = 95
        var right = w - 6
        func place(_ view: NSView, width: CGFloat) {
            right -= width; view.frame = NSRect(x: right, y: y, width: width, height: 22); right -= 5
        }
        place(drums, width: 24); place(groove, width: 78); place(meter, width: 47)
        place(stepper, width: 15); place(bpm, width: 36); place(bpmLabel, width: 24)
        bpmLabel.frame.origin.y += 6
        beats.frame = NSRect(x: 6, y: 93, width: max(0, right - 10), height: 26)
        for (index, view) in trackViews.enumerated() {
            view.frame = NSRect(x: 6, y: 125 + CGFloat(index) * 34, width: w - 12, height: 28)
            view.needsLayout = true
        }
        toolbar.needsLayout = true
    }
    override func draw(_ dirtyRect: NSRect) {
        RimeUI.bufferBg.setFill(); bounds.fill()
        RimeUI.border.setStroke()
        let line = NSBezierPath(); line.move(to: NSPoint(x: 6, y: 89)); line.line(to: NSPoint(x: bounds.width - 6, y: 89)); line.stroke()
    }
    private func configure(_ button: FirstMouseButton, symbol: String, title: String, action: Selector) {
        button.title = title; button.image = RimeUI.symbol(symbol, pointSize: 10, weight: .medium)
        button.imagePosition = title.isEmpty ? .imageOnly : .imageLeading
        button.font = .systemFont(ofSize: 9, weight: .medium)
        button.isBordered = false; button.showsPersistentInteractionSurface = true
        button.target = self; button.action = action
    }
    private func applyAppearance() {
        appearance = RimeUI.appKitAppearance
        for label in [root, chord] { label.textColor = RimeUI.textPrimary }
        for label in [toolbar.transposeLabel, toolbar.octaveLabel, bpmLabel, toolbar.status] { label.textColor = RimeUI.textMuted }
        for button in [drums, toolbar.record, toolbar.stop] {
            button.contentTintColor = button.usesPrimarySurface ? RimeUI.accentForegroundColor : RimeUI.textPrimary
            button.refreshInteractionAppearance()
        }
        needsDisplay = true
    }
    @objc private func toggleLoop() { onRequestKeyboardFocus?(); BufferMusicSession.shared.toggleLoopRecording() }
    @objc private func stopMusic() { onRequestKeyboardFocus?(); BufferMusicSession.shared.stop() }
    @objc private func toggleDrums() { onRequestKeyboardFocus?(); BufferMusicSession.shared.toggleDrums() }
    @objc private func selectMusicMode() { if let s = mode.titleOfSelectedItem, let m = BufferMusicMode(rawValue: s) { BufferMusicSession.shared.setMode(m) }; onRequestKeyboardFocus?() }
    @objc private func changeMeter() { if let s = meter.titleOfSelectedItem, let m = BufferMusicMeter(rawValue: s) { BufferMusicSession.shared.setMeter(m) }; onRequestKeyboardFocus?() }
    @objc private func changeGroove() { if let s = groove.titleOfSelectedItem, let g = BufferMusicGroove(rawValue: s) { BufferMusicSession.shared.setGroove(g) }; onRequestKeyboardFocus?() }
    @objc private func stepTranspose() { BufferMusicSession.shared.setTranspose(toolbar.transposeStepper.integerValue); onRequestKeyboardFocus?() }
    @objc private func stepOctave() { BufferMusicSession.shared.setOctaveShift(toolbar.octaveStepper.integerValue); onRequestKeyboardFocus?() }
    @objc private func stepBPM() { BufferMusicSession.shared.setBPM(stepper.integerValue); onRequestKeyboardFocus?() }
    private func commitBPM() { BufferMusicSession.shared.setBPM(min(240, max(40, bpm.integerValue))) }
    func controlTextDidEndEditing(_ obj: Notification) { commitBPM() }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard control === bpm else { return false }
        if selector == #selector(NSResponder.insertNewline(_:)) { commitBPM(); onRequestKeyboardFocus?(); return true }
        if selector == #selector(NSResponder.cancelOperation(_:)) { bpm.integerValue = snapshot.bpm; onRequestKeyboardFocus?(); return true }
        return false
    }

    func exercisePitchSteppersForSmoke() -> Bool {
        let session = BufferMusicSession.shared
        let before = session.snapshot
        defer { session.setTranspose(before.transpose); session.setOctaveShift(before.octaveShift); session.waitUntilIdleForTesting(); refresh() }
        refresh()
        toolbar.transposeStepper.integerValue = before.transpose + 1
        stepTranspose()
        session.waitUntilIdleForTesting()
        toolbar.octaveStepper.integerValue = before.octaveShift + 1
        stepOctave()
        session.waitUntilIdleForTesting()
        refresh()
        return session.snapshot.transpose == before.transpose + 1
            && session.snapshot.octaveShift == before.octaveShift + 1
            && toolbar.transposeLabel.stringValue.contains("+1")
            && toolbar.octaveLabel.stringValue.contains("+1")
    }

    var layoutDiagnostics: String {
        "body \(bounds) " + subviews.map { "\(type(of: $0))=\($0.frame),hidden=\($0.isHidden)" }.joined(separator: "; ")
    }
    var layoutIsContained: Bool {
        let area = bounds.insetBy(dx: -1, dy: -1)
        let visible = subviews.filter { !$0.isHidden }
        return visible.allSatisfy { area.contains($0.frame) && $0.frame.width > 0 }
            && !keyboard.frame.intersects(chord.frame)
            && !beats.frame.intersects(bpmLabel.frame)
            && trackViews.count == snapshot.loops.count
    }
}

private final class MusicTransportToolbar: NSView {
    let record = FirstMouseButton(frame: .zero)
    let stop = FirstMouseButton(frame: .zero)
    let status = NSTextField(labelWithString: "Loop 0/2")
    let transposeLabel = NSTextField(labelWithString: "移调 +0")
    let octaveLabel = NSTextField(labelWithString: "八度 +0")
    let transposeStepper = NSStepper()
    let octaveStepper = NSStepper()
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 340, height: 24) }
    override init(frame: NSRect) {
        super.init(frame: frame)
        [record, stop, status, transposeLabel, octaveLabel, transposeStepper, octaveStepper].forEach { addSubview($0) }
        for label in [transposeLabel, octaveLabel] {
            label.font = .monospacedDigitSystemFont(ofSize: 9, weight: .medium)
            label.lineBreakMode = .byTruncatingTail
        }
        status.font = .systemFont(ofSize: 9)
        status.lineBreakMode = .byTruncatingTail
        status.maximumNumberOfLines = 1
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        record.frame = NSRect(x: 0, y: 1, width: 66, height: 22)
        stop.frame = NSRect(x: 70, y: 1, width: 24, height: 22)
        transposeLabel.frame = NSRect(x: 102, y: 6, width: 49, height: 15)
        transposeStepper.frame = NSRect(x: 153, y: 1, width: 15, height: 22)
        octaveLabel.frame = NSRect(x: 174, y: 6, width: 49, height: 15)
        octaveStepper.frame = NSRect(x: 225, y: 1, width: 15, height: 22)
        status.frame = NSRect(x: 246, y: 6, width: max(0, bounds.width - 250), height: 15)
    }
}

private final class MusicKeyboardRow: NSView {
    var snapshot = BufferMusicSnapshot()
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        let gap: CGFloat = 2
        let labelWidth: CGFloat = 22
        let width = (bounds.width - labelWidth - gap * 9) / 10
        let tonic = 60 + snapshot.transpose + snapshot.octaveShift * 12
        for (index, code) in BufferMusicSession.noteKeys.enumerated() {
            let row = index / 10
            if index % 10 == 0 {
                let note = BufferMusicSession.openStringNotes[row] + snapshot.transpose + snapshot.octaveShift * 12
                musicDrawText("\(row + 1) \(BufferMusicTheory.noteName(note))", rect: NSRect(x: 0, y: CGFloat(row) * 21 + 3, width: labelWidth - 2, height: 14), size: 7, color: RimeUI.textMuted)
            }
            let rect = NSRect(x: labelWidth + CGFloat(index % 10) * (width + gap), y: CGFloat(row) * 21, width: width, height: 18)
            let note = snapshot.pressedKeys[code]
            let key = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
            (note == nil ? RimeUI.textMuted.withAlphaComponent(0.10) : RimeUI.accentBlue).setFill(); key.fill()
            RimeUI.textMuted.withAlphaComponent(0.22).setStroke(); key.lineWidth = 0.5; key.stroke()
            if let note {
                let label = BufferMusicTheory.solfege(note: note, tonic: tonic, mode: snapshot.mode)
                musicDrawText(label, rect: rect.insetBy(dx: 0, dy: 3), size: 8, color: RimeUI.accentForegroundColor, centered: true)
            }
        }
        setAccessibilityLabel("四弦贝斯排列，每排 10 键，共 40 键，当前按下 \(snapshot.pressedKeys.count) 键")
    }
}

private final class MusicBeatRow: NSView {
    var snapshot = BufferMusicSnapshot()
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        let count = snapshot.meter.beatsPerBar
        let start: CGFloat = 22
        musicDrawText(snapshot.grooveSection == 0 ? "A" : "B", rect: NSRect(x: 0, y: 7, width: 16, height: 15), size: 9, color: RimeUI.textMuted)
        let width = min(32, (bounds.width - start - CGFloat(count - 1) * 4) / CGFloat(count))
        for i in 0..<count {
            let rect = NSRect(x: start + CGFloat(i) * (width + 4), y: 3, width: width, height: 21)
            let active = snapshot.beat == i + 1 && (snapshot.isDrumsEnabled || snapshot.isLooping || snapshot.isRecording || !snapshot.fillTitle.isEmpty)
            (active ? RimeUI.accentBlue : RimeUI.textMuted.withAlphaComponent(0.13)).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()
            musicDrawText("\(i + 1)", rect: rect.insetBy(dx: 0, dy: 4), size: 9, color: active ? RimeUI.accentForegroundColor : RimeUI.textMuted, centered: true)
        }
    }
}

private final class MusicLoopRow: NSView {
    var state: BufferMusicLoopSnapshot?
    var number = 1
    var canDelete = true
    var onMute: (() -> Void)?
    var onDelete: (() -> Void)?
    private let mute = FirstMouseButton(frame: .zero)
    private let remove = FirstMouseButton(frame: .zero)
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        for (button, icon, action) in [(mute, "speaker.slash", #selector(muteTapped)), (remove, "trash", #selector(removeTapped))] {
            button.image = RimeUI.symbol(icon, pointSize: 9, weight: .medium)
            button.isBordered = false; button.showsPersistentInteractionSurface = true
            button.target = self; button.action = action; addSubview(button)
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        mute.frame = NSRect(x: bounds.width - 50, y: 3, width: 22, height: 22)
        remove.frame = NSRect(x: bounds.width - 24, y: 3, width: 22, height: 22)
        mute.isEnabled = state?.recording == false
        remove.isEnabled = canDelete && state?.recording == false
        mute.usesPrimarySurface = state?.muted == true
        mute.setAccessibilityLabel(state?.muted == true ? "恢复 Loop \(number)" : "静音 Loop \(number)")
        remove.setAccessibilityLabel("删除 Loop \(number)")
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let state else { return }
        RimeUI.textMuted.withAlphaComponent(0.07).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
        let status = state.queued ? "待录/待播" : (state.recording ? "录制" : (state.muted ? "静音" : "\(state.bars) 小节"))
        musicDrawText("L\(number) · \(status)", rect: NSRect(x: 6, y: 8, width: 95, height: 15), size: 9, color: state.recording ? RimeUI.accentBlue : RimeUI.textMuted)
        let timeline = NSRect(x: 104, y: 5, width: max(0, bounds.width - 166), height: 18)
        let binWidth = timeline.width / 32
        for (i, value) in state.activity.prefix(32).enumerated() {
            let h = value == 0 ? 2 : min(18, 4 + CGFloat(value) * 3)
            (state.muted ? RimeUI.textMuted : RimeUI.accentBlue.withAlphaComponent(0.6)).setFill()
            NSRect(x: timeline.minX + CGFloat(i) * binWidth, y: timeline.midY - h / 2, width: max(1, binWidth - 2), height: h).fill()
        }
        if !state.queued {
            RimeUI.textPrimary.setFill()
            NSRect(x: timeline.minX + timeline.width * state.progress, y: timeline.minY, width: 1, height: timeline.height).fill()
        }
    }
    @objc private func muteTapped() { onMute?() }
    @objc private func removeTapped() { onDelete?() }
}

private func musicDrawText(_ text: String, rect: NSRect, size: CGFloat, color: NSColor, centered: Bool = false) {
    let paragraph = NSMutableParagraphStyle(); paragraph.alignment = centered ? .center : .left
    paragraph.lineBreakMode = .byTruncatingTail
    (text as NSString).draw(in: rect, withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: .medium), .foregroundColor: color, .paragraphStyle: paragraph])
}

func runBufferMusicViewSmokeTest(outputURL: URL? = nil) -> Bool {
    _ = NSApplication.shared
    let view = BufferMusicView(frame: .zero)
    var focusRequests = 0
    view.onRequestKeyboardFocus = { focusRequests += 1 }
    view.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification))
    guard focusRequests == 0, view.exercisePitchSteppersForSmoke() else { return false }
    for width: CGFloat in [520, 760, 1040] {
        for count in 0...2 {
            var state = BufferMusicSnapshot()
            state.isActive = true; state.isReady = true; state.isDrumsEnabled = true
            state.pressedKeys = [18:43,14:40,3:36,6:28]
            state.beat = 3
            state.loops = (0..<count).map { .init(id: $0 + 1, bars: 1, recording: $0 == 1, queued: false, muted: false, progress: 0.42, activity: (0..<32).map { ($0 * 7) % 5 }) }
            let height = BufferMusicView.bodyHeight(tracks: count)
            view.frame = NSRect(x: 0, y: 0, width: width, height: height)
            view.render(state); view.layoutSubtreeIfNeeded()
            guard view.layoutIsContained else { print("FAILED: music rows overflow \(width), tracks=\(count)"); return false }
            if let outputURL {
                let canvas = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height + 35))
                canvas.wantsLayer = true; canvas.layer?.backgroundColor = RimeUI.bufferBg.cgColor
                canvas.addSubview(view); view.frame.origin = .zero
                canvas.addSubview(view.toolbarView)
                view.toolbarView.frame = NSRect(x: 8, y: height + 5, width: 300, height: 24)
                view.toolbarView.layoutSubtreeIfNeeded()
                guard let rep = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds) else { return false }
                canvas.cacheDisplay(in: canvas.bounds, to: rep)
                guard let data = rep.representation(using: .png, properties: [:]) else { return false }
                let path = outputURL.deletingPathExtension().path + "-\(Int(width))-\(count).png"
                do { try data.write(to: URL(fileURLWithPath: path)) } catch { return false }
                view.removeFromSuperview(); view.toolbarView.removeFromSuperview()
            }
        }
    }
    print("Music rows smoke: OK (4 × 10 bass keys, harmony, beat controls, 0/1/2 tracks; 520/760/1040)")
    return true
}
