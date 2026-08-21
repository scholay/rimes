import Cocoa
import Carbon.HIToolbox

extension Notification.Name {
    static let rimeShortcutPreferencesDidChange = Notification.Name(
        "RimeShortcutPreferencesDidChange"
    )
}

/// A physical macOS shortcut. Key codes are layout independent, matching the
/// Carbon global-hot-key API and the NSEvent path used by the input method.
struct RimeKeyboardShortcut: Codable, Equatable {
    let keyCode: UInt16
    let modifierRawValue: UInt

    init(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        self.keyCode = keyCode
        modifierRawValue = modifiers
            .intersection(Self.supportedModifiers)
            .rawValue
    }

    var modifiers: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifierRawValue)
            .intersection(Self.supportedModifiers)
    }

    var carbonModifiers: UInt32 {
        var value: UInt32 = 0
        if modifiers.contains(.command) { value |= UInt32(cmdKey) }
        if modifiers.contains(.shift) { value |= UInt32(shiftKey) }
        if modifiers.contains(.option) { value |= UInt32(optionKey) }
        if modifiers.contains(.control) { value |= UInt32(controlKey) }
        return value
    }

    var displayTitle: String {
        var title = ""
        if modifiers.contains(.control) { title += "⌃" }
        if modifiers.contains(.option) { title += "⌥" }
        if modifiers.contains(.shift) { title += "⇧" }
        if modifiers.contains(.command) { title += "⌘" }
        return title + Self.keyTitle(for: keyCode)
    }

    var hasCommandLikeModifier: Bool {
        !modifiers.intersection([.command, .control, .option]).isEmpty
    }

    /// These exact chords already implement workbench editing and must not be
    /// rebound to another RIMES action. Extra modifiers remain distinct.
    var isReservedBufferEditingShortcut: Bool {
        guard modifiers == [.command] || modifiers == [.control] else {
            return false
        }
        return keyCode == UInt16(kVK_ANSI_A)
            || keyCode == UInt16(kVK_ANSI_V)
    }

    func matches(keyCode otherKeyCode: UInt16,
                 modifiers otherModifiers: NSEvent.ModifierFlags) -> Bool {
        keyCode == otherKeyCode
            && modifiers == otherModifiers.intersection(Self.supportedModifiers)
    }

    static let supportedModifiers: NSEvent.ModifierFlags = [
        .command, .control, .option, .shift,
    ]

    private static func keyTitle(for keyCode: UInt16) -> String {
        switch keyCode {
        case UInt16(kVK_Return): return "↩"
        case UInt16(kVK_ANSI_KeypadEnter): return "Num ↩"
        case UInt16(kVK_Tab): return "⇥"
        case UInt16(kVK_Space): return "Space"
        case UInt16(kVK_Delete): return "⌫"
        case UInt16(kVK_Escape): return "Esc"
        case UInt16(kVK_LeftArrow): return "←"
        case UInt16(kVK_RightArrow): return "→"
        case UInt16(kVK_UpArrow): return "↑"
        case UInt16(kVK_DownArrow): return "↓"
        case UInt16(kVK_Home): return "Home"
        case UInt16(kVK_End): return "End"
        case UInt16(kVK_PageUp): return "Page Up"
        case UInt16(kVK_PageDown): return "Page Down"
        case UInt16(kVK_F1): return "F1"
        case UInt16(kVK_F2): return "F2"
        case UInt16(kVK_F3): return "F3"
        case UInt16(kVK_F4): return "F4"
        case UInt16(kVK_F5): return "F5"
        case UInt16(kVK_F6): return "F6"
        case UInt16(kVK_F7): return "F7"
        case UInt16(kVK_F8): return "F8"
        case UInt16(kVK_F9): return "F9"
        case UInt16(kVK_F10): return "F10"
        case UInt16(kVK_F11): return "F11"
        case UInt16(kVK_F12): return "F12"
        case UInt16(kVK_ANSI_A): return "A"
        case UInt16(kVK_ANSI_B): return "B"
        case UInt16(kVK_ANSI_C): return "C"
        case UInt16(kVK_ANSI_D): return "D"
        case UInt16(kVK_ANSI_E): return "E"
        case UInt16(kVK_ANSI_F): return "F"
        case UInt16(kVK_ANSI_G): return "G"
        case UInt16(kVK_ANSI_H): return "H"
        case UInt16(kVK_ANSI_I): return "I"
        case UInt16(kVK_ANSI_J): return "J"
        case UInt16(kVK_ANSI_K): return "K"
        case UInt16(kVK_ANSI_L): return "L"
        case UInt16(kVK_ANSI_M): return "M"
        case UInt16(kVK_ANSI_N): return "N"
        case UInt16(kVK_ANSI_O): return "O"
        case UInt16(kVK_ANSI_P): return "P"
        case UInt16(kVK_ANSI_Q): return "Q"
        case UInt16(kVK_ANSI_R): return "R"
        case UInt16(kVK_ANSI_S): return "S"
        case UInt16(kVK_ANSI_T): return "T"
        case UInt16(kVK_ANSI_U): return "U"
        case UInt16(kVK_ANSI_V): return "V"
        case UInt16(kVK_ANSI_W): return "W"
        case UInt16(kVK_ANSI_X): return "X"
        case UInt16(kVK_ANSI_Y): return "Y"
        case UInt16(kVK_ANSI_Z): return "Z"
        case UInt16(kVK_ANSI_0): return "0"
        case UInt16(kVK_ANSI_1): return "1"
        case UInt16(kVK_ANSI_2): return "2"
        case UInt16(kVK_ANSI_3): return "3"
        case UInt16(kVK_ANSI_4): return "4"
        case UInt16(kVK_ANSI_5): return "5"
        case UInt16(kVK_ANSI_6): return "6"
        case UInt16(kVK_ANSI_7): return "7"
        case UInt16(kVK_ANSI_8): return "8"
        case UInt16(kVK_ANSI_9): return "9"
        default: return "Key \(keyCode)"
        }
    }
}

enum RimeShortcutAction: String, CaseIterable {
    case deliverBuffer
    case toggleWorkbench
    case toggleClipboardHistory
    case openSettings
    case previousPlugin
    case nextPlugin

    var title: String {
        switch self {
        case .deliverBuffer: return "投递缓冲内容"
        case .toggleWorkbench: return "显示或隐藏工作台"
        case .toggleClipboardHistory: return "显示或隐藏剪贴板历史"
        case .openSettings: return "打开设置"
        case .previousPlugin: return "上一个缓冲插件"
        case .nextPlugin: return "下一个缓冲插件"
        }
    }

    var detail: String {
        switch self {
        case .deliverBuffer:
            return "轻按发送下一块；按住约 1.2 秒发送全部"
        case .toggleWorkbench:
            return "在任何应用中呼出或收起缓冲工作台"
        case .toggleClipboardHistory:
            return "在共享工作台中单独呼出或收起剪贴板历史"
        case .openSettings:
            return "在任何应用中打开 RIMES 设置"
        case .previousPlugin:
            return "工作台可用时切换到上一个插件"
        case .nextPlugin:
            return "工作台可用时切换到下一个插件"
        }
    }

    var defaultShortcut: RimeKeyboardShortcut {
        switch self {
        case .deliverBuffer:
            return RimeKeyboardShortcut(
                keyCode: UInt16(kVK_Return),
                modifiers: []
            )
        case .toggleWorkbench:
            return RimeKeyboardShortcut(
                keyCode: UInt16(kVK_ANSI_B),
                modifiers: [.command, .shift]
            )
        case .toggleClipboardHistory:
            return RimeKeyboardShortcut(
                keyCode: UInt16(kVK_ANSI_P),
                modifiers: [.command, .shift]
            )
        case .openSettings:
            return RimeKeyboardShortcut(
                keyCode: UInt16(kVK_ANSI_S),
                modifiers: [.command, .shift]
            )
        case .previousPlugin:
            return RimeKeyboardShortcut(
                keyCode: UInt16(kVK_UpArrow),
                modifiers: [.command, .shift]
            )
        case .nextPlugin:
            return RimeKeyboardShortcut(
                keyCode: UInt16(kVK_DownArrow),
                modifiers: [.command, .shift]
            )
        }
    }

    func accepts(_ shortcut: RimeKeyboardShortcut) -> Bool {
        guard !shortcut.isReservedBufferEditingShortcut else { return false }
        if shortcut.hasCommandLikeModifier { return true }
        guard self == .deliverBuffer, shortcut.modifiers.isEmpty else {
            return false
        }
        return [
            UInt16(kVK_Return),
            UInt16(kVK_ANSI_KeypadEnter),
            UInt16(kVK_F6), UInt16(kVK_F7), UInt16(kVK_F8),
            UInt16(kVK_F9), UInt16(kVK_F10), UInt16(kVK_F11),
            UInt16(kVK_F12),
        ].contains(shortcut.keyCode)
    }
}

enum RimeShortcutPreferenceError: Error, Equatable {
    case modifierRequired
    case unsafeBareKey
    case reservedBufferEditingShortcut
    case conflict(RimeShortcutAction)
}

enum RimeShortcutPreferences {
    private static let keyPrefix = "keyboardShortcut.v1."

    /// These actions may already have an explicit user binding from a version
    /// that did not expose the Clipboard rail shortcut. Upgrade must preserve
    /// those choices even if one already owns the new Command-Shift-P default.
    private static let actionsPredatingClipboardHistory: [RimeShortcutAction] = [
        .deliverBuffer,
        .toggleWorkbench,
        .openSettings,
        .previousPlugin,
        .nextPlugin,
    ]

    /// A missing Clipboard binding normally resolves to Command-Shift-P. If a
    /// pre-existing action already owns it, persist the first free fallback so
    /// Carbon never receives duplicate registrations from this process.
    private static let clipboardHistoryFallbackKeyCodes: [UInt16] = [
        UInt16(kVK_ANSI_C), UInt16(kVK_ANSI_D), UInt16(kVK_ANSI_E),
        UInt16(kVK_ANSI_F), UInt16(kVK_ANSI_G), UInt16(kVK_ANSI_H),
        UInt16(kVK_ANSI_I), UInt16(kVK_ANSI_J), UInt16(kVK_ANSI_K),
        UInt16(kVK_ANSI_L), UInt16(kVK_ANSI_M), UInt16(kVK_ANSI_N),
        UInt16(kVK_ANSI_O), UInt16(kVK_ANSI_Q), UInt16(kVK_ANSI_R),
        UInt16(kVK_ANSI_T), UInt16(kVK_ANSI_U), UInt16(kVK_ANSI_V),
        UInt16(kVK_ANSI_W), UInt16(kVK_ANSI_X), UInt16(kVK_ANSI_Y),
        UInt16(kVK_ANSI_Z), UInt16(kVK_ANSI_A), UInt16(kVK_ANSI_B),
        UInt16(kVK_ANSI_S),
    ]

    static func shortcut(for action: RimeShortcutAction,
                         defaults: UserDefaults = .standard) -> RimeKeyboardShortcut {
        if action == .toggleClipboardHistory {
            migrateClipboardHistoryShortcutIfNeeded(defaults: defaults)
        }
        return storedShortcut(for: action, defaults: defaults)
            ?? action.defaultShortcut
    }

    /// This accessor is also used during global-hot-key installation, so the
    /// migration writes silently and never posts a notification that could
    /// re-enter Carbon registration.
    private static func migrateClipboardHistoryShortcutIfNeeded(
        defaults: UserDefaults
    ) {
        let clipboardAction = RimeShortcutAction.toggleClipboardHistory
        let clipboardKey = preferenceKey(for: clipboardAction)
        if let data = defaults.data(forKey: clipboardKey),
           let shortcut = try? JSONDecoder().decode(
                RimeKeyboardShortcut.self,
                from: data
           ),
           clipboardAction.accepts(shortcut) {
            return
        }

        let occupied = actionsPredatingClipboardHistory.map { action in
            (action, storedShortcut(for: action, defaults: defaults)
                ?? action.defaultShortcut)
        }
        let desired = clipboardAction.defaultShortcut
        guard let conflict = occupied.first(where: { $0.1 == desired }) else {
            return
        }

        let fallback = clipboardHistoryFallbackKeyCodes.lazy
            .map {
                RimeKeyboardShortcut(
                    keyCode: $0,
                    modifiers: [.command, .shift]
                )
            }
            .first { candidate in
                clipboardAction.accepts(candidate)
                    && !occupied.contains(where: { $0.1 == candidate })
            }
        guard let fallback,
              let data = try? JSONEncoder().encode(fallback) else {
            IMELog.write(
                "clipboard shortcut migration failed; no encodable fallback"
            )
            return
        }

        defaults.set(data, forKey: clipboardKey)
        IMELog.write(
            "clipboard shortcut migrated; preserved=\(conflict.0.rawValue) "
                + "clipboard=\(fallback.displayTitle)"
        )
    }

    private static func preferenceKey(for action: RimeShortcutAction) -> String {
        keyPrefix + action.rawValue
    }

    private static func storedShortcut(
        for action: RimeShortcutAction,
        defaults: UserDefaults
    ) -> RimeKeyboardShortcut? {
        guard let data = defaults.data(forKey: preferenceKey(for: action)),
              let shortcut = try? JSONDecoder().decode(
                  RimeKeyboardShortcut.self,
                  from: data
              ),
              action.accepts(shortcut) else {
            return nil
        }
        return shortcut
    }

    static func set(_ shortcut: RimeKeyboardShortcut,
                    for action: RimeShortcutAction,
                    defaults: UserDefaults = .standard)
        throws {
        if shortcut.isReservedBufferEditingShortcut {
            throw RimeShortcutPreferenceError.reservedBufferEditingShortcut
        }
        guard action.accepts(shortcut) else {
            if action == .deliverBuffer {
                throw RimeShortcutPreferenceError.unsafeBareKey
            }
            throw RimeShortcutPreferenceError.modifierRequired
        }
        if let conflict = RimeShortcutAction.allCases.first(where: {
            $0 != action && self.shortcut(for: $0, defaults: defaults) == shortcut
        }) {
            throw RimeShortcutPreferenceError.conflict(conflict)
        }
        guard let data = try? JSONEncoder().encode(shortcut) else { return }
        defaults.set(data, forKey: preferenceKey(for: action))
        NotificationCenter.default.post(
            name: .rimeShortcutPreferencesDidChange,
            object: nil,
            userInfo: ["action": action.rawValue]
        )
    }

    static func reset(_ action: RimeShortcutAction,
                      defaults: UserDefaults = .standard) throws {
        let defaultShortcut = action.defaultShortcut
        if let conflict = RimeShortcutAction.allCases.first(where: {
            $0 != action
                && self.shortcut(for: $0, defaults: defaults) == defaultShortcut
        }) {
            throw RimeShortcutPreferenceError.conflict(conflict)
        }
        defaults.removeObject(forKey: preferenceKey(for: action))
        NotificationCenter.default.post(
            name: .rimeShortcutPreferencesDidChange,
            object: nil,
            userInfo: ["action": action.rawValue]
        )
    }

    static func resetAll(defaults: UserDefaults = .standard) {
        for action in RimeShortcutAction.allCases {
            defaults.removeObject(forKey: preferenceKey(for: action))
        }
        NotificationCenter.default.post(
            name: .rimeShortcutPreferencesDidChange,
            object: nil
        )
    }
}

/// Native, keyboard-first shortcut capture. Escape cancels; Delete restores
/// the default. A local monitor is used because settings-window key equivalents
/// otherwise consume Command shortcuts before an NSButton receives keyDown.
final class RimeShortcutRecorderButton: NSButton {
    private let shortcutAction: RimeShortcutAction
    private var monitor: Any?
    private var isRecording = false
    var onFeedback: ((String?) -> Void)?

    init(action: RimeShortcutAction) {
        shortcutAction = action
        super.init(frame: .zero)
        title = RimeShortcutPreferences.shortcut(for: action).displayTitle
        bezelStyle = .rounded
        font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        target = self
        self.action = #selector(toggleRecording)
        toolTip = "点击后按下新的快捷键；Delete 恢复默认，Esc 取消"
        setAccessibilityLabel("\(action.title)快捷键")
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(greaterThanOrEqualToConstant: 108).isActive = true
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        stopRecording(refreshTitle: false)
    }

    @objc private func toggleRecording() {
        isRecording ? stopRecording() : startRecording()
    }

    private func startRecording() {
        stopRecording(refreshTitle: false)
        isRecording = true
        title = "请按快捷键…"
        onFeedback?(
            shortcutAction == .deliverBuffer
                ? "按下新的投递键；Esc 取消，Delete 恢复默认。"
                : "按下包含 ⌘、⌃ 或 ⌥ 的组合；Esc 取消，Delete 恢复默认。"
        )
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            guard let self, self.isRecording else { return event }
            self.capture(event)
            return nil
        }
    }

    private func capture(_ event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) {
            stopRecording()
            onFeedback?(nil)
            return
        }
        if [UInt16(kVK_Delete), UInt16(kVK_ForwardDelete)].contains(event.keyCode),
           event.modifierFlags.intersection(RimeKeyboardShortcut.supportedModifiers).isEmpty {
            do {
                try RimeShortcutPreferences.reset(shortcutAction)
                stopRecording()
                onFeedback?("已恢复“\(shortcutAction.title)”的默认快捷键。")
            } catch let RimeShortcutPreferenceError.conflict(action) {
                NSSound.beep()
                title = "快捷键冲突"
                onFeedback?(
                    "默认组合已用于“\(action.title)”，请先修改冲突项。"
                )
            } catch {
                NSSound.beep()
                stopRecording()
                onFeedback?("默认快捷键未恢复，请重试。")
            }
            return
        }

        let shortcut = RimeKeyboardShortcut(
            keyCode: event.keyCode,
            modifiers: event.modifierFlags
        )
        do {
            try RimeShortcutPreferences.set(shortcut, for: shortcutAction)
            stopRecording()
            onFeedback?("“\(shortcutAction.title)”已改为 \(shortcut.displayTitle)。")
        } catch RimeShortcutPreferenceError.modifierRequired {
            NSSound.beep()
            title = "需要修饰键"
            onFeedback?("请至少加入 ⌘、⌃ 或 ⌥，避免拦截普通输入。")
        } catch RimeShortcutPreferenceError.unsafeBareKey {
            NSSound.beep()
            title = "按键不安全"
            onFeedback?("无修饰键时仅可使用 Return、数字键盘 Enter 或 F6–F12。")
        } catch RimeShortcutPreferenceError.reservedBufferEditingShortcut {
            NSSound.beep()
            title = "系统编辑快捷键"
            onFeedback?("⌘/⌃A 与 ⌘/⌃V 保留给全选和粘贴，请换一个组合。")
        } catch let RimeShortcutPreferenceError.conflict(action) {
            NSSound.beep()
            title = "快捷键冲突"
            onFeedback?("该组合已用于“\(action.title)”，请换一个组合。")
        } catch {
            NSSound.beep()
            stopRecording()
            onFeedback?("快捷键未保存，请重试。")
        }
    }

    private func stopRecording(refreshTitle: Bool = true) {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        isRecording = false
        if refreshTitle {
            title = RimeShortcutPreferences
                .shortcut(for: shortcutAction)
                .displayTitle
        }
    }
}
