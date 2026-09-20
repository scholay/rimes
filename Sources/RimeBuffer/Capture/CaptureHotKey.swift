import AppKit
import Carbon.HIToolbox

/// Optional capture shortcut. It has no default registration, and never
/// participates in the IMK text-delivery shortcut state machine.
final class CaptureHotKey {
    static let shared = CaptureHotKey()
    private var handler: EventHandlerRef?
    private var hotKey: EventHotKeyRef?
    private var observer: NSObjectProtocol?
    private init() {}
    func start() {
        guard handler == nil else { return }
        DispatchQueue.main.async { _ = CaptureCoordinator.shared }
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            guard let event else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr,
                  id.signature == 0x43415054 else { return OSStatus(eventNotHandledErr) }
            DispatchQueue.main.async { CaptureCoordinator.shared.showLauncher() }
            return noErr
        }, 1, &type, nil, &handler)
        observer = NotificationCenter.default.addObserver(forName: .rimeShortcutPreferencesDidChange, object: nil, queue: .main) { [weak self] _ in self?.reload() }
        reload()
    }
    private func reload() {
        if let hotKey { UnregisterEventHotKey(hotKey); self.hotKey = nil }
        let shortcut = RimeShortcutPreferences.shortcut(for: .captureScreen)
        guard shortcut.keyCode != UInt16.max else { return }
        let status = RegisterEventHotKey(UInt32(shortcut.keyCode), shortcut.carbonModifiers, EventHotKeyID(signature: 0x43415054, id: 1), GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &hotKey)
        if status != noErr { IMELog.write("capture shortcut registration failed status=\(status)") }
    }
}
