import AppKit
import CryptoKit
import Foundation

struct CapsuleRevealChord: Codable, Equatable, Hashable, Sendable {
    static let keyboardOrder = Array("qwertyuiopasdfghjklzxcvbnm")
    static let maximumKeys = 8

    let keys: String

    init?(_ raw: String) {
        let lowered = raw.lowercased()
        let characters = Set(lowered)
        guard !characters.isEmpty,
              characters.count <= Self.maximumKeys,
              lowered.allSatisfy({ Self.keyboardOrder.contains($0) }) else {
            return nil
        }
        keys = String(Self.keyboardOrder.filter(characters.contains))
    }

    var displayValue: String { keys.uppercased() }

    /// Match the physical ANSI letter key carried by the native event. This
    /// deliberately does not consult `charactersIgnoringModifiers`: the
    /// passcode remains the same while another input source or keyboard layout
    /// is active, and no composed text participates in authentication.
    static func character(forPhysicalKeyCode keyCode: UInt16) -> Character? {
        guard let key = RimeKey.fromVirtualKeyCode(keyCode),
              key >= 0x61,
              key <= 0x7a,
              let scalar = UnicodeScalar(UInt32(key)) else { return nil }
        return Character(String(scalar))
    }
}

struct CapsuleRevealPasscode: Equatable, Sendable {
    static let slotCount = 4
    static let defaultValue = CapsuleRevealPasscode(chords: [
        CapsuleRevealChord("rh")!,
        CapsuleRevealChord("wo")!,
        CapsuleRevealChord("cvn")!,
        CapsuleRevealChord("qu")!,
    ])!

    let chords: [CapsuleRevealChord]

    init?(chords: [CapsuleRevealChord]) {
        guard chords.count == Self.slotCount else { return nil }
        self.chords = chords
    }

    fileprivate var canonicalData: Data {
        Data(chords.map(\.keys).joined(separator: "\u{1f}").utf8)
    }
}

/// Stores only a salted digest for custom reveal codes. The default event
/// sequence is compiled into the product; no raw custom chord sequence enters
/// UserDefaults, logs, Capsule Markdown, the pasteboard, or iCloud sync.
final class CapsuleRevealPasscodeStore {
    static let shared = CapsuleRevealPasscodeStore()

    private enum Key {
        static let credential = "capsule.passwordRevealPasscode.credential.v1"
        // Remove the two-key development format if it was ever exercised by a
        // local build. It was never a release format.
        static let legacySalt = "capsule.passwordRevealPasscode.salt.v1"
        static let legacyDigest = "capsule.passwordRevealPasscode.digest.v1"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var isCustomized: Bool {
        hasAnyStoredCredential
    }

    func matches(_ passcode: CapsuleRevealPasscode) -> Bool {
        if defaults.object(forKey: Key.credential) != nil {
            guard let stored = validStoredCredential() else {
                // A damaged custom credential must never silently reactivate
                // the public default passcode.
                return false
            }
            return Self.constantTimeEqual(
                Self.digest(passcode.canonicalData, salt: stored.salt),
                stored.digest
            )
        }
        // Legacy development keys prove that a non-default credential existed,
        // but they cannot be authenticated as the single current-format blob.
        // Keep the store locked instead of silently re-enabling the public
        // default. Only explicit local recovery can clear an invalid legacy
        // residue because no candidate can authenticate it.
        guard !hasLegacyCredential else { return false }
        return passcode == .defaultValue
    }

    func set(_ passcode: CapsuleRevealPasscode) {
        var bytes = [UInt8](repeating: 0, count: 24)
        for index in bytes.indices {
            bytes[index] = UInt8.random(in: .min ... .max)
        }
        let salt = Data(bytes)
        let digest = Self.digest(passcode.canonicalData, salt: salt)
        var credential = Data([1])
        credential.append(salt)
        credential.append(digest)
        defaults.set(
            credential.base64EncodedString(),
            forKey: Key.credential
        )
        defaults.removeObject(forKey: Key.legacySalt)
        defaults.removeObject(forKey: Key.legacyDigest)
        NotificationCenter.default.post(
            name: .capsuleRevealPasscodeDidChange,
            object: self
        )
    }

    func resetToDefault() {
        defaults.removeObject(forKey: Key.credential)
        defaults.removeObject(forKey: Key.legacySalt)
        defaults.removeObject(forKey: Key.legacyDigest)
        NotificationCenter.default.post(
            name: .capsuleRevealPasscodeDidChange,
            object: self
        )
    }

    private func validStoredCredential() -> (salt: Data, digest: Data)? {
        guard let encoded = defaults.string(forKey: Key.credential),
              let credential = Data(base64Encoded: encoded),
              credential.count == 1 + 24 + SHA256.Digest.byteCount,
              credential.first == 1 else { return nil }
        let salt = credential.subdata(in: 1..<25)
        let digest = credential.subdata(in: 25..<credential.count)
        return (salt, digest)
    }

    private var hasLegacyCredential: Bool {
        defaults.object(forKey: Key.legacySalt) != nil
            || defaults.object(forKey: Key.legacyDigest) != nil
    }

    private var hasAnyStoredCredential: Bool {
        defaults.object(forKey: Key.credential) != nil
            || hasLegacyCredential
    }

    private static func digest(_ canonical: Data, salt: Data) -> Data {
        var payload = Data("RIMES.CapsuleRevealPasscode.v1\0".utf8)
        payload.append(salt)
        payload.append(canonical)
        return Data(SHA256.hash(data: payload))
    }

    private static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for (left, right) in zip(lhs, rhs) {
            difference |= left ^ right
        }
        return difference == 0
    }
}

extension Notification.Name {
    static let capsuleRevealPasscodeDidChange = Notification.Name(
        "com.isaac.inputmethod.RimeBuffer.capsuleRevealPasscodeDidChange"
    )
}

struct CapsuleRevealPasscodeAttempt {
    private(set) var chords: [CapsuleRevealChord] = []

    var isComplete: Bool {
        chords.count == CapsuleRevealPasscode.slotCount
    }

    mutating func append(_ chord: CapsuleRevealChord) -> CapsuleRevealPasscode? {
        guard !isComplete else { return nil }
        chords.append(chord)
        return CapsuleRevealPasscode(chords: chords)
    }

    mutating func reset() {
        chords.removeAll(keepingCapacity: true)
    }
}

private final class CapsuleRevealChordCaptureView: NSView {
    var onChord: ((CapsuleRevealChord) -> Void)?
    var onProgress: ((CapsuleRevealChord?) -> Void)?
    var onCancel: (() -> Void)?

    private var keysDown: [UInt16: Character] = [:]
    private var allKeysDown = Set<UInt16>()
    private var chordKeys = Set<Character>()
    private var rejectedCurrentChord = false
    private var blockedByModifier = false

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 54).isActive = true
        setAccessibilityLabel("并击口令输入区")
        setAccessibilityHelp("同时按下每组字母并全部松开，完成一个槽位")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            reset()
            onCancel?()
            return
        }
        guard !event.isARepeat else { return }
        allKeysDown.insert(event.keyCode)
        guard event.modifierFlags
                .intersection([.command, .control, .option, .function])
                .isEmpty,
              let character = CapsuleRevealChord.character(
                forPhysicalKeyCode: event.keyCode
              ) else {
            rejectCurrentChord()
            return
        }
        keysDown[event.keyCode] = character
        chordKeys.insert(character)
        onProgress?(
            rejectedCurrentChord
                ? nil
                : CapsuleRevealChord(String(chordKeys))
        )
        needsDisplay = true
    }

    override func keyUp(with event: NSEvent) {
        if event.keyCode == 53 { return }
        allKeysDown.remove(event.keyCode)
        keysDown.removeValue(forKey: event.keyCode)
        guard allKeysDown.isEmpty, !blockedByModifier else { return }
        defer { reset() }
        guard !rejectedCurrentChord else { return }
        guard let chord = CapsuleRevealChord(String(chordKeys)) else {
            NSSound.beep()
            return
        }
        onChord?(chord)
    }

    override func flagsChanged(with event: NSEvent) {
        let blocked = !event.modifierFlags
            .intersection([.command, .control, .option, .function])
            .isEmpty
        if blocked {
            blockedByModifier = true
            rejectCurrentChord()
        } else if blockedByModifier {
            blockedByModifier = false
            if allKeysDown.isEmpty { reset() }
        }
    }

    override func resignFirstResponder() -> Bool {
        reset()
        return super.resignFirstResponder()
    }

    func reset() {
        keysDown.removeAll(keepingCapacity: true)
        allKeysDown.removeAll(keepingCapacity: true)
        chordKeys.removeAll(keepingCapacity: true)
        rejectedCurrentChord = false
        blockedByModifier = false
        onProgress?(nil)
        needsDisplay = true
    }

    private func rejectCurrentChord() {
        if !rejectedCurrentChord { NSSound.beep() }
        rejectedCurrentChord = true
        chordKeys.removeAll(keepingCapacity: true)
        onProgress?(nil)
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let rect = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7)
        RimeUI.surface3.setFill()
        path.fill()
        RimeUI.accentGreen.withAlphaComponent(0.8).setStroke()
        path.lineWidth = window?.firstResponder === self ? 1.5 : 1
        path.stroke()
        let label = chordKeys.isEmpty
            ? "点击此处，然后逐组并击"
            : String(CapsuleRevealChord.keyboardOrder.filter(chordKeys.contains))
                .uppercased()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(
                ofSize: chordKeys.isEmpty ? 12 : 20,
                weight: .semibold
            ),
            .foregroundColor: chordKeys.isEmpty
                ? RimeUI.textSecondary
                : RimeUI.textPrimary,
        ]
        let size = (label as NSString).size(withAttributes: attributes)
        (label as NSString).draw(
            at: NSPoint(
                x: bounds.midX - size.width / 2,
                y: bounds.midY - size.height / 2
            ),
            withAttributes: attributes
        )
    }
}

private final class CapsuleRevealPasscodeSlotsView: NSStackView {
    private let labels: [NSTextField]

    override init(frame frameRect: NSRect) {
        labels = (0..<CapsuleRevealPasscode.slotCount).map { index in
            let label = NSTextField(labelWithString: "\(index + 1)")
            label.alignment = .center
            label.font = NSFont.monospacedSystemFont(ofSize: 15, weight: .semibold)
            label.wantsLayer = true
            label.layer?.cornerRadius = 7
            label.layer?.borderWidth = 1
            label.translatesAutoresizingMaskIntoConstraints = false
            label.widthAnchor.constraint(greaterThanOrEqualToConstant: 62).isActive = true
            label.heightAnchor.constraint(equalToConstant: 42).isActive = true
            return label
        }
        super.init(frame: frameRect)
        orientation = .horizontal
        alignment = .centerY
        distribution = .fillEqually
        spacing = 8
        translatesAutoresizingMaskIntoConstraints = false
        labels.forEach(addArrangedSubview)
        update(completed: 0, active: nil, revealCompletedValues: false)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(
        completed: Int,
        active: CapsuleRevealChord?,
        revealCompletedValues: Bool,
        values: [CapsuleRevealChord] = []
    ) {
        for (index, label) in labels.enumerated() {
            label.layer?.borderColor = (index == min(completed, labels.count - 1)
                ? RimeUI.accentGreen
                : RimeUI.border).cgColor
            label.backgroundColor = RimeUI.surface3
            label.textColor = RimeUI.textPrimary
            if index < completed {
                label.stringValue = revealCompletedValues && values.indices.contains(index)
                    ? values[index].displayValue
                    : "●"
                label.setAccessibilityLabel("口令槽位 \(index + 1)，已输入")
            } else if index == completed, let active {
                label.stringValue = active.displayValue
                label.setAccessibilityLabel("口令槽位 \(index + 1)，输入中")
            } else {
                label.stringValue = "\(index + 1)"
                label.setAccessibilityLabel("口令槽位 \(index + 1)，未输入")
            }
        }
    }
}

final class CapsuleRevealPasscodeChallengeController: NSObject, NSWindowDelegate {
    enum Purpose {
        case verify
        case configure
    }

    private let purpose: Purpose
    private let store: CapsuleRevealPasscodeStore
    private let panel: NSPanel
    private let slots = CapsuleRevealPasscodeSlotsView()
    private let capture = CapsuleRevealChordCaptureView()
    private let status = NSTextField(labelWithString: "")
    private var attempt = CapsuleRevealPasscodeAttempt()
    private var firstConfiguration: CapsuleRevealPasscode?
    private var completion: ((Bool) -> Void)?
    private var didFinish = false

    init(
        purpose: Purpose,
        store: CapsuleRevealPasscodeStore = .shared
    ) {
        self.purpose = purpose
        self.store = store
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 430, height: 245),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        super.init()
        configurePanel()
    }

    func beginSheet(for parent: NSWindow, completion: @escaping (Bool) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        self.completion = completion
        panel.title = purpose == .verify ? "验证查看口令" : "设置查看口令"
        status.stringValue = purpose == .verify
            ? "输入四组并击后验证"
            : "输入新的四组并击口令"
        slots.update(completed: 0, active: nil, revealCompletedValues: false)
        parent.beginSheet(panel)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.panel.makeFirstResponder(self.capture)
        }
    }

    func cancel() {
        finish(false)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        finish(false)
        return false
    }

    func windowDidResignKey(_ notification: Notification) {
        // A sheet becoming non-key means authentication no longer has the
        // user's uninterrupted attention. Cancel it without preserving a
        // partial chord sequence.
        finish(false)
    }

    private func configurePanel() {
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.backgroundColor = RimeUI.surface

        let heading = NSTextField(
            labelWithString: purpose == .verify
                ? "查看密码明文"
                : "密码查看口令"
        )
        heading.font = NSFont.systemFont(ofSize: 17, weight: .semibold)
        let explanation = NSTextField(
            wrappingLabelWithString: "每个槽位是一组并击：同时按下该组字母，全部松开后进入下一槽。按 Esc 取消。"
        )
        explanation.textColor = RimeUI.textSecondary
        explanation.font = NSFont.systemFont(ofSize: 11)
        status.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        status.textColor = RimeUI.textSecondary

        let cancelButton = RimePointingHandButton(
            title: "取消",
            target: self,
            action: #selector(cancelPressed)
        )
        cancelButton.bezelStyle = .rounded
        let actions = NSStackView(views: [NSView(), cancelButton])
        actions.orientation = .horizontal

        let column = NSStackView(views: [
            heading,
            explanation,
            slots,
            capture,
            status,
            actions,
        ])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 10
        column.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 16, right: 20)
        column.translatesAutoresizingMaskIntoConstraints = false
        let root = NSView()
        root.wantsLayer = true
        root.addSubview(column)
        panel.contentView = root
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            column.topAnchor.constraint(equalTo: root.topAnchor),
            column.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            slots.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -40),
            capture.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -40),
            actions.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -40),
        ])

        capture.onProgress = { [weak self] active in
            guard let self else { return }
            self.slots.update(
                completed: self.attempt.chords.count,
                active: active,
                revealCompletedValues: false
            )
        }
        capture.onChord = { [weak self] chord in
            self?.accept(chord)
        }
        capture.onCancel = { [weak self] in self?.finish(false) }
    }

    private func accept(_ chord: CapsuleRevealChord) {
        guard !didFinish else { return }
        let completed = attempt.chords.count + 1
        let passcode = attempt.append(chord)
        slots.update(
            completed: completed,
            active: nil,
            revealCompletedValues: purpose == .configure,
            values: attempt.chords
        )
        guard let passcode else { return }

        switch purpose {
        case .verify:
            if store.matches(passcode) {
                finish(true)
            } else {
                status.stringValue = "口令不匹配，请重新输入"
                status.textColor = .systemRed
                attempt.reset()
                slots.update(
                    completed: 0,
                    active: nil,
                    revealCompletedValues: false
                )
            }
        case .configure:
            if let firstConfiguration {
                guard firstConfiguration == passcode else {
                    status.stringValue = "两次口令不一致，请从头设置"
                    status.textColor = .systemRed
                    self.firstConfiguration = nil
                    attempt.reset()
                    slots.update(
                        completed: 0,
                        active: nil,
                        revealCompletedValues: true
                    )
                    return
                }
                store.set(passcode)
                finish(true)
            } else {
                firstConfiguration = passcode
                attempt.reset()
                status.stringValue = "再次输入四组并击进行确认"
                status.textColor = RimeUI.textSecondary
                slots.update(
                    completed: 0,
                    active: nil,
                    revealCompletedValues: true
                )
            }
        }
    }

    @objc private func cancelPressed() {
        finish(false)
    }

    private func finish(_ success: Bool) {
        guard !didFinish else { return }
        didFinish = true
        capture.reset()
        attempt.reset()
        firstConfiguration = nil
        if let parent = panel.sheetParent {
            parent.endSheet(panel)
        } else {
            panel.orderOut(nil)
        }
        let completion = self.completion
        self.completion = nil
        completion?(success)
    }
}

/// Reusable Settings row. It exposes only configuration and status; password
/// entries remain exclusively in the standalone Capsule manager.
final class CapsuleRevealPasscodeSettingsView: NSView {
    private let store: CapsuleRevealPasscodeStore
    private let statusLabel = NSTextField(labelWithString: "")
    private var observer: NSObjectProtocol?
    private var challenge: CapsuleRevealPasscodeChallengeController?

    init(store: CapsuleRevealPasscodeStore = .shared) {
        self.store = store
        super.init(frame: .zero)
        build()
        renderStatus()
        observer = NotificationCenter.default.addObserver(
            forName: .capsuleRevealPasscodeDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in self?.renderStatus() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        challenge?.cancel()
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    private func build() {
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "密码查看口令")
        title.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        let detail = NSTextField(
            wrappingLabelWithString: "查看 Capsule 密码明文前，必须完成四组原生按键并击。自定义口令只保存加盐摘要。"
        )
        detail.font = NSFont.systemFont(ofSize: 11)
        detail.textColor = RimeUI.textSecondary
        statusLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)

        let setButton = RimePointingHandButton(
            title: "设置口令…",
            target: self,
            action: #selector(setPasscode)
        )
        setButton.bezelStyle = .rounded
        let resetButton = RimePointingHandButton(
            title: "恢复默认",
            target: self,
            action: #selector(resetPasscode)
        )
        resetButton.bezelStyle = .inline
        let actions = NSStackView(views: [setButton, resetButton, NSView()])
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = 8

        let column = NSStackView(views: [title, detail, statusLabel, actions])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 7
        column.edgeInsets = NSEdgeInsets(top: 13, left: 14, bottom: 13, right: 14)
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.topAnchor.constraint(equalTo: topAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
            detail.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -28),
            actions.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -28),
        ])
        applyAppearance()
    }

    private func renderStatus() {
        statusLabel.stringValue = store.isCustomized
            ? "已启用 · 4 槽 · 自定义并击口令"
            : "已启用 · 4 槽 · 默认 RH / WO / CVN / QU"
    }

    @objc private func setPasscode() {
        guard let window else { return }
        beginVerification(for: window) { [weak self, weak window] in
            guard let self, let window else { return }
            let configure = CapsuleRevealPasscodeChallengeController(
                purpose: .configure,
                store: self.store
            )
            self.challenge = configure
            configure.beginSheet(for: window) { [weak self] _ in
                self?.challenge = nil
                self?.renderStatus()
            }
        }
    }

    @objc private func resetPasscode() {
        guard let window else { return }
        beginVerification(for: window) { [weak self] in
            self?.store.resetToDefault()
            self?.renderStatus()
        }
    }

    private func beginVerification(
        for window: NSWindow,
        onVerified: @escaping () -> Void
    ) {
        let verify = CapsuleRevealPasscodeChallengeController(
            purpose: .verify,
            store: store
        )
        challenge?.cancel()
        challenge = verify
        verify.beginSheet(for: window) { [weak self, weak window] success in
            guard let self else { return }
            if self.challenge === verify {
                self.challenge = nil
            }
            guard success, window != nil else {
                self.renderStatus()
                return
            }
            // Let AppKit finish detaching the verification sheet before a
            // configuration sheet is attached to the same Settings window.
            DispatchQueue.main.async(execute: onVerified)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearance()
    }

    private func applyAppearance() {
        layer?.backgroundColor = RimeUI.surface2.cgColor
        layer?.borderColor = RimeUI.border.cgColor
    }
}
