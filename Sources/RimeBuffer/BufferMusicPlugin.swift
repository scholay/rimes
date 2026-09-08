import AppKit

/// Compiled, opt-in performance surface. Enabling the catalog entry does not
/// open an audio device; only a focused music workbench starts the engine.
final class BufferMusicInternalPlugin: InternalPlugin {
    static let key = PluginKey(domain: .builtIn, rawID: BuiltInPluginID.music)
    private static let catalog = PresetBufferPluginCatalog.entry(id: BuiltInPluginID.music)!
    let descriptor = PluginDescriptor(
        key: key, wireID: nil, name: catalog.nameZH,
        symbolName: "waveform", version: catalog.version,
        summary: catalog.summaryZH, source: .builtIn,
        capabilities: [.bufferAction], settings: nil, canUninstall: false
    )

    func start() {}
    func stop() { BufferMusicSession.shared.setActive(false) }
    func makeSettingsViewController(subpageID: String) -> NSViewController? { nil }
}

/// Only used by the focused native music panel. Modified shortcuts are left
/// with AppKit; an owned key-up still releases its note if modifiers changed.
struct BufferMusicKeyboardRouting {
    private var ownedKeys = Set<UInt16>()

    mutating func shouldConsume(code: UInt16, isDown: Bool,
                                modifiers: NSEvent.ModifierFlags,
                                editingText: Bool) -> Bool {
        if !isDown { return ownedKeys.remove(code) != nil }
        guard !editingText else { return false }
        guard modifiers.intersection([.command, .control, .option]).isEmpty else { return false }
        ownedKeys.insert(code)
        return true
    }

    mutating func reset() { ownedKeys.removeAll() }
}

func runBufferMusicKeyboardSmokeTest() -> Bool {
    var routing = BufferMusicKeyboardRouting()
    let note = routing.shouldConsume(code: 18, isDown: true, modifiers: [], editingText: false)
    let release = routing.shouldConsume(code: 18, isDown: false,
                                        modifiers: [.command], editingText: true)
    let shortcut = routing.shouldConsume(code: 45, isDown: true,
                                         modifiers: [.command, .shift], editingText: false)
    let shortcutUp = routing.shouldConsume(code: 45, isDown: false,
                                           modifiers: [], editingText: false)
    let editor = routing.shouldConsume(code: 18, isDown: true, modifiers: [], editingText: true)
    _ = routing.shouldConsume(code: 19, isDown: true, modifiers: [], editingText: false)
    routing.reset()
    let staleRelease = routing.shouldConsume(code: 19, isDown: false,
                                             modifiers: [], editingText: false)
    let modifiedArrow = routing.shouldConsume(code: 124, isDown: true, modifiers: [.command, .shift], editingText: false)
    let modifiedArrowUp = routing.shouldConsume(code: 124, isDown: false, modifiers: [], editingText: false)
    let otherArrow = routing.shouldConsume(code: 124, isDown: true, modifiers: [.command], editingText: false)
    let editingArrow = routing.shouldConsume(code: 126, isDown: true, modifiers: [.command, .shift], editingText: true)
    let passed = !modifiedArrow && !modifiedArrowUp && !otherArrow && !editingArrow && note && release && !shortcut && !shortcutUp && !editor && !staleRelease
    print("music keyboard ownership smoke: \(passed ? "OK" : "FAIL")")
    return passed
}
