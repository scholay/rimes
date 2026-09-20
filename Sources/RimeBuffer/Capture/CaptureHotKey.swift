import AppKit
import Carbon.HIToolbox

/// Optional capture shortcut. It has no default registration, and never
/// participates in the IMK text-delivery shortcut state machine.
final class CaptureHotKey {
    static let shared = CaptureHotKey()
    private var handler: EventHandlerRef?
    private var hotKeys: [EventHotKeyRef] = []
    /// Which of the two screenshot shortcuts macOS refused to hand over.
    private(set) var blockedBySystem: Set<RimeShortcutAction> = []
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
            let action = id.id
            DispatchQueue.main.async {
                if action == 2 {
                    CaptureCoordinator.shared.begin("area")
                } else {
                    CaptureCoordinator.shared.showLauncher()
                }
            }
            return noErr
        }, 1, &type, nil, &handler)
        observer = NotificationCenter.default.addObserver(forName: .rimeShortcutPreferencesDidChange, object: nil, queue: .main) { [weak self] _ in self?.reload() }
        reload()
    }
    private func reload() {
        hotKeys.forEach { UnregisterEventHotKey($0) }
        hotKeys.removeAll()
        blockedBySystem.removeAll()
        for (action, identifier) in [
            (RimeShortcutAction.captureScreen, UInt32(1)),
            (RimeShortcutAction.captureArea, UInt32(2)),
        ] {
            let shortcut = RimeShortcutPreferences.shortcut(for: action)
            guard shortcut.keyCode != UInt16.max else { continue }
            var reference: EventHotKeyRef?
            let status = RegisterEventHotKey(
                UInt32(shortcut.keyCode),
                shortcut.carbonModifiers,
                EventHotKeyID(signature: 0x43415054, id: identifier),
                GetApplicationEventTarget(),
                OptionBits(kEventHotKeyExclusive),
                &reference
            )
            if let reference, status == noErr {
                hotKeys.append(reference)
            } else {
                // macOS still owns this combination. Record it so the
                // settings row can say so instead of the shortcut simply
                // doing nothing.
                blockedBySystem.insert(action)
                IMELog.write("capture shortcut \(action.rawValue) registration "
                    + "failed status=\(status); system screenshot shortcut "
                    + "is probably still enabled")
            }
        }
    }
}
