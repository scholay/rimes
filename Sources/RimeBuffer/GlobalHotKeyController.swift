import AppKit
import Carbon.HIToolbox
import Foundation

enum GlobalHotKeyRoute: Equatable {
    case toggleWorkbench
    case toggleClipboardHistory
    case openMailbox
    case openSettings
    case ignore
}

enum GlobalHotKeyAction: UInt32, CaseIterable, Hashable {
    case toggleWorkbench = 1
    case openSettings = 2
    case toggleClipboardHistory = 3
    case openMailbox = 4

    var shortcutAction: RimeShortcutAction {
        switch self {
        case .toggleWorkbench: return .toggleWorkbench
        case .toggleClipboardHistory: return .toggleClipboardHistory
        case .openMailbox: return .openMailbox
        case .openSettings: return .openSettings
        }
    }

    /// Utility surfaces keep working while another input method is selected.
    /// Settings still belongs to the live RIMES session because several of its
    /// actions deploy or mutate the active input method.
    var requiresRimeInputSource: Bool {
        self == .openSettings
    }
}

struct GlobalHotKeyDefinition {
    let action: GlobalHotKeyAction
    let keyCode: UInt32
    let modifiers: UInt32

    /// Content-window visibility is a deliberate global command. Register
    /// Capsule and Mailbox exclusively so another Carbon listener cannot
    /// observe the same chord; ordinary AppKit editing remains outside here.
    var registrationOptions: OptionBits {
        action == .toggleClipboardHistory
            || action == .openMailbox
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

struct GlobalHotKeyPrimaryKeyMatch: Equatable {
    let action: GlobalHotKeyAction
    let route: GlobalHotKeyRoute
    let keyCode: UInt16
}

/// Pure definitions and matching for the process-wide shortcuts. Keeping this
/// separate from registration lets smoke tests validate the contract without
/// temporarily claiming real global shortcuts from the user's Mac.
enum GlobalHotKeyRouting {
    /// FourCC `ETBW`; the original workbench namespace now owns all RIMES
    /// process-global shortcuts while preserving its stable Carbon signature.
    static let signature: OSType = 0x4554_4257

    static func registeredActions(currentSourceIsOwn: Bool)
        -> Set<GlobalHotKeyAction> {
        Set(GlobalHotKeyAction.allCases.filter {
            currentSourceIsOwn || !$0.requiresRimeInputSource
        })
    }

    static func definitions(defaults: UserDefaults = .standard)
        -> [GlobalHotKeyDefinition] {
        RimeShortcutPreferences.migrateGlobalHotKeyShortcutsIfNeeded(
            defaults: defaults
        )
        return GlobalHotKeyAction.allCases.map { action in
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
        RimeShortcutPreferences.migrateGlobalHotKeyShortcutsIfNeeded(
            defaults: defaults
        )
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
        return route(for: action)
    }

    static func route(for action: GlobalHotKeyAction) -> GlobalHotKeyRoute {
        switch action {
        case .toggleWorkbench: return .toggleWorkbench
        case .toggleClipboardHistory: return .toggleClipboardHistory
        case .openMailbox: return .openMailbox
        case .openSettings: return .openSettings
        }
    }

    /// IMK and Carbon may report the same physical press in either order. Match
    /// only definitions whose Carbon registration actually succeeded, and only
    /// the exact supported modifier set, so an ordinary later press of the same
    /// primary key can never be mistaken for the global shortcut.
    static func primaryKeyMatch(
        definitions: [GlobalHotKeyDefinition],
        eventType: NSEvent.EventType,
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags
    ) -> GlobalHotKeyPrimaryKeyMatch? {
        guard eventType == .keyDown else { return nil }
        let carbonModifiers = RimeKeyboardShortcut(
            keyCode: keyCode,
            modifiers: modifierFlags
        ).carbonModifiers
        guard let definition = definitions.first(where: {
            $0.keyCode == UInt32(keyCode)
                && $0.modifiers == carbonModifiers
        }) else { return nil }
        let route = route(for: definition.action)
        guard route != .ignore else { return nil }
        return GlobalHotKeyPrimaryKeyMatch(
            action: definition.action,
            route: route,
            keyCode: keyCode
        )
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
    private var rimeInputSourceIsActive = false
    private var lastReconciledInputSourceState: Bool?

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
               action != .openMailbox,
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

        return install(
            definitions: GlobalHotKeyRouting.definitions(defaults: defaults)
        )
    }

    @discardableResult
    private func install(definitions: [GlobalHotKeyDefinition]) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))

        if eventHandlerRef == nil {
            let eventTypes = [
                EventTypeSpec(
                    eventClass: OSType(kEventClassKeyboard),
                    eventKind: UInt32(kEventHotKeyPressed)
                ),
                EventTypeSpec(
                    eventClass: OSType(kEventClassKeyboard),
                    eventKind: UInt32(kEventHotKeyReleased)
                ),
            ]
            var installedHandler: EventHandlerRef?
            let handlerStatus = eventTypes.withUnsafeBufferPointer { buffer in
                InstallEventHandler(
                    GetApplicationEventTarget(),
                    Self.eventHandler,
                    buffer.count,
                    buffer.baseAddress,
                    Unmanaged.passUnretained(self).toOpaque(),
                    &installedHandler
                )
            }
            guard handlerStatus == noErr, let installedHandler else {
                IMELog.write("global hotkey handler install failed status=\(handlerStatus)")
                return false
            }
            eventHandlerRef = installedHandler
        }

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
        unregisterAllHotKeys()
        return reconcileRegistrations(
            currentSourceIsOwn: rimeInputSourceIsActive
        )
    }

    /// Four utility shortcuts remain process-global across input-source changes.
    /// Only RIMES-owned actions are added or removed with IMK authority.
    @discardableResult
    func setRuntimeEnabledForInputSource(_ enabled: Bool) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        // Every ordinary IMK callback reconfirms source authority. Once the
        // source state has been reconciled, that hot path must not reread
        // preferences, retry a permanently conflicting shortcut, or append a
        // failure log per key. Preferences explicitly call reload; a real
        // source transition performs the next retry.
        if lastReconciledInputSourceState == enabled {
            let desiredActions = GlobalHotKeyRouting.registeredActions(
                currentSourceIsOwn: enabled
            )
            return eventHandlerRef != nil
                && Set(hotKeyRefs.keys) == desiredActions
                && Set(registeredDefinitions.keys) == desiredActions
        }
        return reconcileRegistrations(currentSourceIsOwn: enabled)
    }

    @discardableResult
    private func reconcileRegistrations(
        currentSourceIsOwn: Bool,
        defaults: UserDefaults = .standard
    ) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        rimeInputSourceIsActive = currentSourceIsOwn
        lastReconciledInputSourceState = currentSourceIsOwn
        let desiredActions = GlobalHotKeyRouting.registeredActions(
            currentSourceIsOwn: currentSourceIsOwn
        )
        for action in Array(hotKeyRefs.keys)
        where !desiredActions.contains(action) {
            if let hotKeyRef = hotKeyRefs.removeValue(forKey: action) {
                _ = UnregisterEventHotKey(hotKeyRef)
            }
            registeredDefinitions.removeValue(forKey: action)
        }
        let desiredDefinitions = GlobalHotKeyRouting.definitions(defaults: defaults)
            .filter { desiredActions.contains($0.action) }
        let complete = install(definitions: desiredDefinitions)
            && Set(hotKeyRefs.keys) == desiredActions
        let sourceLabel = currentSourceIsOwn ? "RIMES" : "external"
        IMELog.write(
            "global hotkeys reconciled source=\(sourceLabel) "
                + "actions=\(desiredActions.count) complete=\(complete)"
        )
        return complete
    }

    private func unregisterAllHotKeys() {
        for hotKeyRef in hotKeyRefs.values {
            _ = UnregisterEventHotKey(hotKeyRef)
        }
        hotKeyRefs.removeAll()
        registeredDefinitions.removeAll()
    }

    /// Called from the IMK key path before its event can reach Rime. Using the
    /// live registration table avoids claiming a preference whose Carbon
    /// registration failed, while letting an IMK-first callback be consumed
    /// before Carbon opens the corresponding utility surface.
    func registeredPrimaryKeyMatch(
        eventType: NSEvent.EventType,
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags
    ) -> GlobalHotKeyPrimaryKeyMatch? {
        dispatchPrecondition(condition: .onQueue(.main))
        guard rimeInputSourceIsActive else { return nil }
        return GlobalHotKeyRouting.primaryKeyMatch(
            definitions: Array(registeredDefinitions.values),
            eventType: eventType,
            keyCode: keyCode,
            modifierFlags: modifierFlags
        )
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
        let eventClass = GetEventClass(event)
        let eventKind = GetEventKind(event)
        guard eventClass == OSType(kEventClassKeyboard),
              identifier.signature == GlobalHotKeyRouting.signature,
              let action = GlobalHotKeyAction(rawValue: identifier.id),
              eventKind == UInt32(kEventHotKeyPressed)
                || eventKind == UInt32(kEventHotKeyReleased) else {
            return OSStatus(eventNotHandledErr)
        }
        let hadAuthorityBeforeMainHop = RimeInputSourceAuthority
            .currentSourceIsOwn()

        // The application event target normally invokes us on the main loop;
        // retain the same behavior defensively if Carbon ever calls elsewhere.
        let performEvent = { () -> Bool in
            let carbonTimestamp = TimeInterval(GetEventTime(event))
            let routingTimestamp = carbonTimestamp.isFinite && carbonTimestamp > 0
                ? carbonTimestamp
                : TimeInterval(GetCurrentEventTime())
            guard let registeredDefinition = self.registeredDefinitions[action],
                  let primaryKeyCode = UInt16(
                    exactly: registeredDefinition.keyCode
                  ) else {
                IMELog.write("global hotkey ignored without registered definition")
                return false
            }
            let hasAuthorityAtMainBoundary = RimeInputSourceAuthority
                .currentSourceIsOwn()
            // A distributed TIS notification may be delayed or omitted. Any
            // Carbon event is still a live boundary: reconcile the cached
            // registration scope before routing, including when the pressed
            // action is one of the four source-independent utilities.
            if self.rimeInputSourceIsActive != hasAuthorityAtMainBoundary {
                _ = self.setRuntimeEnabledForInputSource(
                    hasAuthorityAtMainBoundary
                )
            }
            let primaryKeyEventIdentity = Self.primaryKeyEventIdentity(
                event,
                eventKind: eventKind,
                keyCode: primaryKeyCode
            )
            if eventKind == UInt32(kEventHotKeyReleased) {
                if hadAuthorityBeforeMainHop,
                   hasAuthorityAtMainBoundary {
                    _ = RIMESController.globalHotKeyDidRelease(
                        action,
                        eventTimestamp: carbonTimestamp,
                        primaryKeyEventIdentity: primaryKeyEventIdentity
                    )
                }
                // A release belongs to a Carbon registration that already
                // consumed its press. Never leak that half-event into the newly
                // selected input method during a source transition.
                return true
            }

            let route = GlobalHotKeyRouting.route(
                eventClass: eventClass,
                eventKind: eventKind,
                identifier: identifier
            )
            guard route != .ignore else { return false }
            if action.requiresRimeInputSource
                && (!hadAuthorityBeforeMainHop || !hasAuthorityAtMainBoundary) {
                _ = self.setRuntimeEnabledForInputSource(false)
                IMELog.write("RIMES-only global hotkey ignored for external source")
                return true
            }
            // Consult the definition that actually owns this Carbon
            // registration. Preferences can change immediately before a
            // reload; re-reading them here could describe a different chord
            // from the event currently being dispatched.
            let shortcutUsesShift = registeredDefinition.modifiers
                & UInt32(shiftKey) != 0
            if hadAuthorityBeforeMainHop, hasAuthorityAtMainBoundary {
                RIMESController.globalHotKeyWillPerform(
                    action,
                    route,
                    eventTimestamp: routingTimestamp,
                    primaryKeyEventTimestamp: carbonTimestamp,
                    primaryKeyCode: primaryKeyCode,
                    primaryKeyEventIdentity: primaryKeyEventIdentity,
                    shortcutUsesShift: shortcutUsesShift
                )
            }
            switch route {
            case .toggleWorkbench:
                BufferWindowController.shared.toggleVisibility()
                IMELog.write("global hotkey toggled buffer workbench")
            case .toggleClipboardHistory:
                ClipboardHistoryWindowController.shared.toggleVisibility()
                IMELog.write("global hotkey toggled Capsule rail")
            case .openMailbox:
                let action = MailboxWindowController.shared.toggleVisibility()
                IMELog.write("global hotkey toggled Mailbox action=\(action)")
            case .openSettings:
                SettingsWindowController.shared.show()
                IMELog.write("global hotkey opened settings")
            case .ignore:
                break
            }
            return true
        }
        let handled: Bool
        if Thread.isMainThread {
            handled = performEvent()
        } else {
            // Suppression must be ordered before the physical Shift-up
            // callback. Carbon normally invokes us on the main loop; this
            // synchronous fallback keeps the exceptional path deterministic.
            handled = DispatchQueue.main.sync(execute: performEvent)
        }

        // This exact registered hot key is ours. Mark it handled so its key
        // cannot continue into the focused host application.
        return handled ? noErr : OSStatus(eventNotHandledErr)
    }

    private static func primaryKeyEventIdentity(
        _ event: EventRef,
        eventKind: UInt32,
        keyCode: UInt16
    ) -> GlobalHotKeyPrimaryKeyEventIdentity? {
        let phase: GlobalHotKeyPrimaryKeyEventIdentity.Phase
        switch eventKind {
        case UInt32(kEventHotKeyPressed): phase = .keyDown
        case UInt32(kEventHotKeyReleased): phase = .keyUp
        default: return nil
        }
        guard let copiedCGEvent = CopyEventCGEvent(event) else { return nil }
        let cgEvent = copiedCGEvent.takeRetainedValue()
        return GlobalHotKeyPrimaryKeyEventIdentity(
            keyCode: keyCode,
            phase: phase,
            cgTimestamp: cgEvent.timestamp
        )
    }
}
