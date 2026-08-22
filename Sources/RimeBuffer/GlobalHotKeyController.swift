import Carbon.HIToolbox
import Foundation

enum GlobalHotKeyRoute: Equatable {
    case toggleWorkbench
    case toggleClipboardHistory
    case openSettings
    case ignore
}

enum GlobalHotKeyAction: UInt32, CaseIterable, Hashable {
    case toggleWorkbench = 1
    case openSettings = 2
    case toggleClipboardHistory = 3

    var shortcutAction: RimeShortcutAction {
        switch self {
        case .toggleWorkbench: return .toggleWorkbench
        case .toggleClipboardHistory: return .toggleClipboardHistory
        case .openSettings: return .openSettings
        }
    }
}

struct GlobalHotKeyDefinition {
    let action: GlobalHotKeyAction
    let keyCode: UInt32
    let modifiers: UInt32

    /// Clipboard visibility is a deliberate global command. Register it
    /// exclusively so another Carbon listener cannot observe the same chord;
    /// ordinary AppKit editing events remain outside this handler.
    var registrationOptions: OptionBits {
        action == .toggleClipboardHistory
            ? OptionBits(kEventHotKeyExclusive)
            : OptionBits(kEventHotKeyNoOptions)
    }

    var logDescription: String {
        "action=\(action) keyCode=\(keyCode) modifiers=\(modifiers) "
            + "exclusive=\(registrationOptions == OptionBits(kEventHotKeyExclusive))"
    }

    var identifier: EventHotKeyID {
        EventHotKeyID(signature: GlobalHotKeyRouting.signature,
                      id: action.rawValue)
    }
}

/// Pure definitions and matching for the process-wide shortcuts. Keeping this
/// separate from registration lets smoke tests validate the contract without
/// temporarily claiming real global shortcuts from the user's Mac.
enum GlobalHotKeyRouting {
    /// FourCC `ETBW`; the original workbench namespace now owns all RIMES
    /// process-global shortcuts while preserving its stable Carbon signature.
    static let signature: OSType = 0x4554_4257

    static func definitions(defaults: UserDefaults = .standard)
        -> [GlobalHotKeyDefinition] {
        GlobalHotKeyAction.allCases.map { action in
            let shortcut = RimeShortcutPreferences.shortcut(
                for: action.shortcutAction,
                defaults: defaults
            )
            return GlobalHotKeyDefinition(action: action,
                                          keyCode: UInt32(shortcut.keyCode),
                                          modifiers: shortcut.carbonModifiers)
        }
    }

    static func definition(
        for action: GlobalHotKeyAction,
        defaults: UserDefaults = .standard
    ) -> GlobalHotKeyDefinition {
        let shortcut = RimeShortcutPreferences.shortcut(
            for: action.shortcutAction,
            defaults: defaults
        )
        return GlobalHotKeyDefinition(action: action,
                                      keyCode: UInt32(shortcut.keyCode),
                                      modifiers: shortcut.carbonModifiers)
    }

    static func route(eventClass: OSType,
                      eventKind: UInt32,
                      identifier: EventHotKeyID) -> GlobalHotKeyRoute {
        guard eventClass == OSType(kEventClassKeyboard),
              eventKind == UInt32(kEventHotKeyPressed),
              identifier.signature == signature,
              let action = GlobalHotKeyAction(rawValue: identifier.id) else {
            return .ignore
        }
        switch action {
        case .toggleWorkbench: return .toggleWorkbench
        case .toggleClipboardHistory: return .toggleClipboardHistory
        case .openSettings: return .openSettings
        }
    }
}

/// Carbon remains the least invasive way for an accessory input-method process
/// to own a true global shortcut: unlike an NSEvent global monitor it needs no
/// Accessibility permission, and a handled hot-key event is not delivered as a
/// character or application key equivalent. Normal Command-key IMK routing is
/// deliberately untouched.
final class GlobalHotKeyController {
    static let shared = GlobalHotKeyController()

    private var eventHandlerRef: EventHandlerRef?
    private var hotKeyRefs: [GlobalHotKeyAction: EventHotKeyRef] = [:]
    private var registeredDefinitions: [GlobalHotKeyAction: GlobalHotKeyDefinition] = [:]
    private var shortcutPreferencesObserver: NSObjectProtocol?

    private init() {
        shortcutPreferencesObserver = NotificationCenter.default.addObserver(
            forName: .rimeShortcutPreferencesDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            if let rawAction = notification.userInfo?["action"] as? String,
               let action = RimeShortcutAction(rawValue: rawAction),
               action != .toggleWorkbench,
               action != .toggleClipboardHistory,
               action != .openSettings {
                return
            }
            if self?.reloadFromPreferences() == false {
                IMELog.write(
                    "global hotkey reload incomplete; one or more shortcuts unavailable"
                )
            }
        }
    }

    @discardableResult
    func install(defaults: UserDefaults = .standard) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))

        if eventHandlerRef == nil {
            var eventType = EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed)
            )
            var installedHandler: EventHandlerRef?
            let handlerStatus = InstallEventHandler(
                GetApplicationEventTarget(),
                Self.eventHandler,
                1,
                &eventType,
                Unmanaged.passUnretained(self).toOpaque(),
                &installedHandler
            )
            guard handlerStatus == noErr, let installedHandler else {
                IMELog.write("global hotkey handler install failed status=\(handlerStatus)")
                return false
            }
            eventHandlerRef = installedHandler
        }

        let definitions = GlobalHotKeyRouting.definitions(defaults: defaults)
        for definition in definitions
        where hotKeyRefs[definition.action] == nil {
            var registeredHotKey: EventHotKeyRef?
            let registrationStatus = RegisterEventHotKey(
                definition.keyCode,
                definition.modifiers,
                definition.identifier,
                GetApplicationEventTarget(),
                definition.registrationOptions,
                &registeredHotKey
            )
            guard registrationStatus == noErr, let registeredHotKey else {
                let reason = registrationStatus == OSStatus(eventHotKeyExistsErr)
                    ? "already registered by this or another process"
                    : "Carbon registration error"
                IMELog.write(
                    "global hotkey registration failed "
                        + "\(definition.logDescription) status=\(registrationStatus) "
                        + "reason=\(reason)"
                )
                continue
            }

            hotKeyRefs[definition.action] = registeredHotKey
            registeredDefinitions[definition.action] = definition
            IMELog.write("global hotkey installed \(definition.logDescription)")
        }

        return hotKeyRefs.count == definitions.count
    }

    /// Settings can persist new bindings, then call this method to apply them
    /// without restarting the input method process.
    @discardableResult
    func reloadFromPreferences() -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        for hotKeyRef in hotKeyRefs.values {
            _ = UnregisterEventHotKey(hotKeyRef)
        }
        hotKeyRefs.removeAll()
        registeredDefinitions.removeAll()
        return install()
    }

    deinit {
        if let shortcutPreferencesObserver {
            NotificationCenter.default.removeObserver(shortcutPreferencesObserver)
        }
        for hotKeyRef in hotKeyRefs.values {
            _ = UnregisterEventHotKey(hotKeyRef)
        }
        if let eventHandlerRef {
            _ = RemoveEventHandler(eventHandlerRef)
        }
    }

    private static let eventHandler: EventHandlerUPP = { _, event, userData in
        guard let event, let userData else { return OSStatus(eventNotHandledErr) }
        let controller = Unmanaged<GlobalHotKeyController>
            .fromOpaque(userData)
            .takeUnretainedValue()
        return controller.handle(event)
    }

    private func handle(_ event: EventRef) -> OSStatus {
        var identifier = EventHotKeyID()
        let parameterStatus = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &identifier
        )
        guard parameterStatus == noErr else {
            return OSStatus(eventNotHandledErr)
        }
        let route = GlobalHotKeyRouting.route(
            eventClass: GetEventClass(event),
            eventKind: GetEventKind(event),
            identifier: identifier
        )
        guard route != .ignore else {
            return OSStatus(eventNotHandledErr)
        }

        // The application event target normally invokes us on the main loop;
        // retain the same behavior defensively if Carbon ever calls elsewhere.
        let performRoute = {
            // Carbon owns the shortcut's Command/key events, so the active IMK
            // controller may only see Shift down/up. Record a process-wide
            // tombstone before changing the workbench: the eventual release
            // can be delivered after host re-entry or to another controller,
            // so mutating only the current controller's gesture is not enough.
            let carbonTimestamp = TimeInterval(GetEventTime(event))
            let eventTimestamp = carbonTimestamp.isFinite && carbonTimestamp > 0
                ? carbonTimestamp
                : TimeInterval(GetCurrentEventTime())
            // Consult the definition that actually owns this Carbon
            // registration. Preferences can change immediately before a
            // reload; re-reading them here could describe a different chord
            // from the event currently being dispatched.
            let shortcutUsesShift = GlobalHotKeyAction(rawValue: identifier.id)
                .flatMap { self.registeredDefinitions[$0] }
                .map { $0.modifiers & UInt32(shiftKey) != 0 }
                ?? false
            RimeBufferController.globalHotKeyWillPerform(
                route,
                eventTimestamp: eventTimestamp,
                shortcutUsesShift: shortcutUsesShift
            )
            switch route {
            case .toggleWorkbench:
                BufferWindowController.shared.toggleVisibility()
                IMELog.write("global hotkey toggled buffer workbench")
            case .toggleClipboardHistory:
                BufferWindowController.shared.toggleClipboardHistory()
                IMELog.write("global hotkey toggled clipboard history")
            case .openSettings:
                SettingsWindowController.shared.show()
                IMELog.write("global hotkey opened settings")
            case .ignore:
                break
            }
        }
        if Thread.isMainThread {
            performRoute()
        } else {
            // Suppression must be ordered before the physical Shift-up
            // callback. Carbon normally invokes us on the main loop; this
            // synchronous fallback keeps the exceptional path deterministic.
            DispatchQueue.main.sync(execute: performRoute)
        }

        // This exact registered hot key is ours. Mark it handled so its key
        // cannot continue into the focused host application.
        return noErr
    }
}
