import Cocoa
import Carbon
import Darwin
import Foundation

/// TIS source references are process-local snapshots.  Keep every mutating
/// step in a short-lived process, then verify it from another process so an
/// install never makes the child mode race its parent or reuses a stale ref.
enum InputSourceInstallPhase: String, CaseIterable {
    case validateBundle = "--rimes-tis-validate-bundle"
    case register = "--rimes-tis-register"
    case verifyInstalled = "--rimes-tis-verify-installed"
    case enableParent = "--rimes-tis-enable-parent"
    case verifyParent = "--rimes-tis-verify-parent"
    case enableMode = "--rimes-tis-enable-mode"
    case verifyMode = "--rimes-tis-verify-mode"
    case selectMode = "--rimes-tis-select-mode"
    case verifySelected = "--rimes-tis-verify-selected"
}

struct InputSourceInstallMetadata: Equatable {
    let sourceID: String
    let bundleID: String
    let sourceType: String?
    let category: String?
    let enabled: Bool?
    let enableCapable: Bool?
    let selectCapable: Bool?
    let asciiCapable: Bool?
}

enum InputSourceInstallRules {
    /// Roughly eleven seconds per convergence boundary. There is deliberately
    /// no claim that Apple completes TIS propagation within this interval: a
    /// timeout means "defer to login/session refresh", not "bundle install
    /// failed".
    static let retryDelays: [TimeInterval] = [
        0, 0.10, 0.25, 0.50, 1.0, 2.0, 3.0, 4.0,
    ]
    static let subprocessTimeout: TimeInterval = 3
    static let totalInstallBudget: TimeInterval = 90

    static func isParent(_ metadata: InputSourceInstallMetadata,
                         parentID: String) -> Bool {
        guard metadata.sourceID == parentID,
              metadata.bundleID == parentID,
              metadata.sourceType == nil
                || metadata.sourceType == kTISTypeKeyboardInputMethodModeEnabled as String,
              metadata.category == nil
                || metadata.category == kTISCategoryKeyboardInputSource as String,
              metadata.enableCapable != false,
              metadata.selectCapable != true else {
            return false
        }
        return true
    }

    static func isMode(_ metadata: InputSourceInstallMetadata,
                       bundleID: String,
                       modeID: String) -> Bool {
        guard metadata.sourceID == modeID,
              metadata.bundleID == bundleID,
              metadata.sourceType == nil
                || metadata.sourceType == kTISTypeKeyboardInputMode as String,
              metadata.category == nil
                || metadata.category == kTISCategoryKeyboardInputSource as String,
              metadata.enableCapable != false,
              metadata.selectCapable != false else {
            return false
        }
        return true
    }

    /// Never use an all-installed object's possibly stale IsEnabled property as
    /// the fence before enabling the child. The public dependency is satisfied
    /// only after a fresh enabled-only process sees the unique parent.
    static func parentDependencySatisfied(parentInEnabledRoster: Bool) -> Bool {
        parentInEnabledRoster
    }

    /// ASCII capability is intentionally not part of this predicate. It is a
    /// product metadata diagnostic, not an enable/select precondition, and the
    /// public TIS contract permits properties to be absent for some sources.
    static func modeReachedEnabledRoster(_ modeCount: Int) -> Bool {
        modeCount == 1
    }
}

private enum InputSourceInstallExit {
    static let success: Int32 = 0
    static let failed: Int32 = 1
    static let retryable: Int32 = 75 // EX_TEMPFAIL
}

private struct InputSourceInstallIdentity {
    let bundleID: String
    let modeID: String

    static func load() -> InputSourceInstallIdentity? {
        guard let info = Bundle.main.infoDictionary,
              let bundleID = Bundle.main.bundleIdentifier,
              info["TISInputSourceID"] as? String == bundleID,
              let component = info["ComponentInputModeDict"]
                as? [String: Any],
              let visibleModes = component["tsVisibleInputModeOrderedArrayKey"]
                as? [String],
              visibleModes.count == 1,
              let modeID = visibleModes.first,
              let modeList = component["tsInputModeListKey"]
                as? [String: Any],
              let modeEntry = modeList[modeID] as? [String: Any],
              modeEntry["TISInputSourceID"] as? String == modeID,
              modeID.hasPrefix(bundleID + ".") else {
            print("install: invalid bundle/input-mode metadata")
            return nil
        }
        return InputSourceInstallIdentity(bundleID: bundleID, modeID: modeID)
    }
}

private struct InputSourceInstallMatch {
    let source: TISInputSource
    let metadata: InputSourceInstallMetadata
    let iconURL: String?
}

private struct InputSourceInstallRoster {
    let parent: [InputSourceInstallMatch]
    let mode: [InputSourceInstallMatch]
    let unexpected: [InputSourceInstallMatch]
}

private func installerTISStringProperty(_ source: TISInputSource,
                                        _ key: CFString) -> String? {
    guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
    return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
}

private func installerTISBoolProperty(_ source: TISInputSource,
                                      _ key: CFString) -> Bool? {
    guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
    return Unmanaged<NSNumber>.fromOpaque(pointer).takeUnretainedValue().boolValue
}

private func installerTISURLProperty(_ source: TISInputSource,
                                     _ key: CFString) -> String? {
    guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
    let url = Unmanaged<CFURL>.fromOpaque(pointer).takeUnretainedValue() as URL
    return url.path
}

private func inputSourceMetadata(_ source: TISInputSource)
    -> InputSourceInstallMetadata? {
    guard let sourceID = installerTISStringProperty(
            source,
            kTISPropertyInputSourceID
          ),
          let bundleID = installerTISStringProperty(
            source,
            kTISPropertyBundleID
          ) else {
        return nil
    }
    return InputSourceInstallMetadata(
        sourceID: sourceID,
        bundleID: bundleID,
        sourceType: installerTISStringProperty(
            source,
            kTISPropertyInputSourceType
        ),
        category: installerTISStringProperty(
            source,
            kTISPropertyInputSourceCategory
        ),
        enabled: installerTISBoolProperty(
            source,
            kTISPropertyInputSourceIsEnabled
        ),
        enableCapable: installerTISBoolProperty(
            source,
            kTISPropertyInputSourceIsEnableCapable
        ),
        selectCapable: installerTISBoolProperty(
            source,
            kTISPropertyInputSourceIsSelectCapable
        ),
        asciiCapable: installerTISBoolProperty(
            source,
            kTISPropertyInputSourceIsASCIICapable
        )
    )
}

private func inputSourceRoster(identity: InputSourceInstallIdentity,
                               includeAllInstalled: Bool)
    -> InputSourceInstallRoster? {
    let filter = [kTISPropertyBundleID as String: identity.bundleID] as CFDictionary
    guard let cf = TISCreateInputSourceList(filter, includeAllInstalled)?
            .takeRetainedValue(),
          let sources = cf as? [TISInputSource] else {
        print("install: TIS roster unavailable all=\(includeAllInstalled)")
        return nil
    }

    var parent: [InputSourceInstallMatch] = []
    var mode: [InputSourceInstallMatch] = []
    var unexpected: [InputSourceInstallMatch] = []
    for source in sources {
        guard let metadata = inputSourceMetadata(source) else { continue }
        let match = InputSourceInstallMatch(
            source: source,
            metadata: metadata,
            iconURL: installerTISURLProperty(source, kTISPropertyIconImageURL)
        )
        switch metadata.sourceID {
        case identity.bundleID:
            parent.append(match)
        case identity.modeID:
            mode.append(match)
        default:
            unexpected.append(match)
        }
    }
    return InputSourceInstallRoster(
        parent: parent,
        mode: mode,
        unexpected: unexpected
    )
}

private func describe(_ value: Bool?) -> String {
    value.map(String.init) ?? "nil"
}

private func logRoster(_ roster: InputSourceInstallRoster,
                       label: String,
                       identity: InputSourceInstallIdentity) {
    func log(_ role: String, _ matches: [InputSourceInstallMatch]) {
        if matches.isEmpty {
            print("install: \(label) \(role)=missing")
            return
        }
        for (index, match) in matches.enumerated() {
            let metadata = match.metadata
            let sourceType = metadata.sourceType ?? "nil"
            let category = metadata.category ?? "nil"
            let iconURL = match.iconURL ?? "nil"
            print(
                "install: \(label) \(role)[\(index)]"
                    + " id=\(metadata.sourceID)"
                    + " type=\(sourceType)"
                    + " category=\(category)"
                    + " enabled=\(describe(metadata.enabled))"
                    + " enableCapable=\(describe(metadata.enableCapable))"
                    + " selectCapable=\(describe(metadata.selectCapable))"
                    + " ascii=\(describe(metadata.asciiCapable))"
                    + " icon=\(iconURL)"
            )
        }
    }
    log("parent", roster.parent)
    log("mode", roster.mode)
    if !roster.unexpected.isEmpty {
        let ids = roster.unexpected.map(\.metadata.sourceID).joined(separator: ",")
        print("install: \(label) unexpected bundle sources=\(ids)")
    }
    if roster.parent.count > 1 || roster.mode.count > 1 {
        print(
            "install: \(label) ambiguous registrations"
                + " parent=\(roster.parent.count) mode=\(roster.mode.count)"
                + " expected=\(identity.bundleID),\(identity.modeID)"
        )
    }
}

private func uniqueParent(in roster: InputSourceInstallRoster,
                          identity: InputSourceInstallIdentity)
    -> InputSourceInstallMatch? {
    guard roster.parent.count == 1,
          let parent = roster.parent.first,
          InputSourceInstallRules.isParent(
            parent.metadata,
            parentID: identity.bundleID
          ) else {
        return nil
    }
    return parent
}

private func uniqueMode(in roster: InputSourceInstallRoster,
                        identity: InputSourceInstallIdentity)
    -> InputSourceInstallMatch? {
    guard roster.mode.count == 1,
          let mode = roster.mode.first,
          InputSourceInstallRules.isMode(
            mode.metadata,
            bundleID: identity.bundleID,
            modeID: identity.modeID
          ) else {
        return nil
    }
    return mode
}

private func runInputSourceInstallPhase(_ phase: InputSourceInstallPhase) -> Int32 {
    guard let identity = InputSourceInstallIdentity.load() else {
        return InputSourceInstallExit.failed
    }

    switch phase {
    case .validateBundle:
        print(
            "install: bundle metadata valid"
                + " parent=\(identity.bundleID) mode=\(identity.modeID)"
        )
        return InputSourceInstallExit.success

    case .register:
        let status = TISRegisterInputSource(Bundle.main.bundleURL as CFURL)
        print("install: register \(Bundle.main.bundleURL.path) -> \(status)")
        return status == noErr
            ? InputSourceInstallExit.success
            : InputSourceInstallExit.retryable

    case .verifyInstalled:
        guard let roster = inputSourceRoster(
                identity: identity,
                includeAllInstalled: true
              ) else {
            return InputSourceInstallExit.retryable
        }
        logRoster(roster, label: "installed", identity: identity)
        return uniqueParent(in: roster, identity: identity) != nil
            && uniqueMode(in: roster, identity: identity) != nil
            ? InputSourceInstallExit.success
            : InputSourceInstallExit.retryable

    case .enableParent:
        guard let roster = inputSourceRoster(
                identity: identity,
                includeAllInstalled: true
              ),
              let parent = uniqueParent(in: roster, identity: identity) else {
            print("install: cannot resolve a unique parent to enable")
            return InputSourceInstallExit.retryable
        }
        let status = TISEnableInputSource(parent.source)
        print(
            "install: enable parent=\(status)"
                + " reportedBefore=\(describe(parent.metadata.enabled))"
                + " \(identity.bundleID)"
        )
        return status == noErr
            ? InputSourceInstallExit.success
            : InputSourceInstallExit.retryable

    case .verifyParent:
        guard let installed = inputSourceRoster(
                identity: identity,
                includeAllInstalled: true
              ),
              let enabled = inputSourceRoster(
                identity: identity,
                includeAllInstalled: false
              ) else {
            return InputSourceInstallExit.retryable
        }
        logRoster(enabled, label: "enabled-parent", identity: identity)
        let installedParent = uniqueParent(in: installed, identity: identity)
        let enabledParent = uniqueParent(in: enabled, identity: identity)
        let ready = InputSourceInstallRules.parentDependencySatisfied(
            parentInEnabledRoster: enabledParent != nil
        )
        print(
            "install: parent dependency ready=\(ready)"
                + " installedReported=\(describe(installedParent?.metadata.enabled))"
        )
        return ready
            ? InputSourceInstallExit.success
            : InputSourceInstallExit.retryable

    case .enableMode:
        guard let installed = inputSourceRoster(
                identity: identity,
                includeAllInstalled: true
              ),
              let enabled = inputSourceRoster(
                identity: identity,
                includeAllInstalled: false
              ),
              uniqueParent(in: installed, identity: identity) != nil,
              InputSourceInstallRules.parentDependencySatisfied(
                parentInEnabledRoster: uniqueParent(
                    in: enabled,
                    identity: identity
                ) != nil
              ),
              let mode = uniqueMode(in: installed, identity: identity) else {
            print("install: parent not ready or child mode is ambiguous")
            return InputSourceInstallExit.retryable
        }
        let status = TISEnableInputSource(mode.source)
        print(
            "install: enable mode=\(status)"
                + " reportedBefore=\(describe(mode.metadata.enabled))"
                + " \(identity.modeID)"
        )
        return status == noErr
            ? InputSourceInstallExit.success
            : InputSourceInstallExit.retryable

    case .verifyMode:
        guard let roster = inputSourceRoster(
                identity: identity,
                includeAllInstalled: false
              ) else {
            return InputSourceInstallExit.retryable
        }
        logRoster(roster, label: "enabled-mode", identity: identity)
        let parent = uniqueParent(in: roster, identity: identity)
        let mode = uniqueMode(in: roster, identity: identity)
        let ready = parent != nil && mode != nil
            && InputSourceInstallRules.modeReachedEnabledRoster(
                roster.mode.count
            )
        print(
            "install: child enabled roster ready=\(ready)"
                + " parentPresent=\(parent != nil)"
        )
        return ready
            ? InputSourceInstallExit.success
            : InputSourceInstallExit.retryable

    case .selectMode:
        guard let roster = inputSourceRoster(
                identity: identity,
                includeAllInstalled: false
              ),
              uniqueParent(in: roster, identity: identity) != nil,
              let mode = uniqueMode(in: roster, identity: identity) else {
            print("install: no fresh enabled parent/child pair to select")
            return InputSourceInstallExit.retryable
        }
        let status = TISSelectInputSource(mode.source)
        print("install: select=\(status) \(identity.modeID)")
        // Some recent macOS builds return paramErr while applying the change
        // asynchronously. A separate verifier is the authority.
        return status == noErr
            ? InputSourceInstallExit.success
            : InputSourceInstallExit.retryable

    case .verifySelected:
        guard let current = TISCopyCurrentKeyboardInputSource()?
                .takeRetainedValue() else {
            print("install: selected source unavailable")
            return InputSourceInstallExit.retryable
        }
        let currentID = installerTISStringProperty(
            current,
            kTISPropertyInputSourceID
        ) ?? "(unknown)"
        let selected = currentID == identity.modeID
        print("install: selected mode ready=\(selected) current=\(currentID)")
        return selected
            ? InputSourceInstallExit.success
            : InputSourceInstallExit.retryable
    }
}

/// Handles private phase arguments before AppKit/IMK/librime startup. A nil
/// return means the executable should continue with its ordinary command path.
func inputSourceInstallPhaseExitStatus(arguments: [String]) -> Int32? {
    let phases = InputSourceInstallPhase.allCases.filter {
        arguments.dropFirst().contains($0.rawValue)
    }
    guard !phases.isEmpty else { return nil }
    guard phases.count == 1, arguments.count == 2, let phase = phases.first else {
        print("install: invalid internal TIS phase arguments")
        return InputSourceInstallExit.failed
    }
    return runInputSourceInstallPhase(phase)
}

private func runInputSourceInstallSubprocess(
    _ phase: InputSourceInstallPhase,
    timeout: TimeInterval
) -> Int32 {
    guard let executableURL = Bundle.main.executableURL else {
        print("install: cannot locate installer executable")
        return InputSourceInstallExit.failed
    }
    let process = Process()
    let completed = DispatchSemaphore(value: 0)
    process.executableURL = executableURL
    process.arguments = [phase.rawValue]
    process.terminationHandler = { _ in completed.signal() }
    do {
        try process.run()
    } catch {
        print("install: cannot launch phase \(phase): \(error.localizedDescription)")
        return InputSourceInstallExit.failed
    }
    let boundedTimeout = max(0.05, timeout)
    let timeoutNanoseconds = Int(boundedTimeout * 1_000_000_000)
    if completed.wait(
        timeout: .now() + .nanoseconds(timeoutNanoseconds)
    ) == .timedOut {
        print("install: phase \(phase) exceeded \(boundedTimeout)s; terminating")
        if process.isRunning {
            process.terminate()
        }
        if completed.wait(timeout: .now() + .milliseconds(500)) == .timedOut,
           process.isRunning {
            Darwin.kill(process.processIdentifier, SIGKILL)
            _ = completed.wait(timeout: .now() + .seconds(1))
        }
        return InputSourceInstallExit.retryable
    }
    guard process.terminationReason == .exit else {
        print("install: phase \(phase) terminated by signal")
        return InputSourceInstallExit.failed
    }
    return process.terminationStatus
}

private func convergeInputSourceInstallBoundary(
    _ label: String,
    action: InputSourceInstallPhase,
    verify: InputSourceInstallPhase,
    deadlineUptime: TimeInterval
) -> Bool {
    for (index, delay) in InputSourceInstallRules.retryDelays.enumerated() {
        var remaining = deadlineUptime - ProcessInfo.processInfo.systemUptime
        guard remaining > 0 else {
            print("install: total activation budget expired at \(label)")
            return false
        }
        let actionStatus = runInputSourceInstallSubprocess(
            action,
            timeout: min(InputSourceInstallRules.subprocessTimeout, remaining)
        )
        if delay > 0 {
            remaining = deadlineUptime - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else {
                print("install: total activation budget expired at \(label)")
                return false
            }
            Thread.sleep(forTimeInterval: min(delay, remaining))
        }
        remaining = deadlineUptime - ProcessInfo.processInfo.systemUptime
        guard remaining > 0 else {
            print("install: total activation budget expired at \(label)")
            return false
        }
        let verifyStatus = runInputSourceInstallSubprocess(
            verify,
            timeout: min(InputSourceInstallRules.subprocessTimeout, remaining)
        )
        print(
            "install: boundary=\(label) attempt=\(index + 1)"
                + " action=\(actionStatus) verify=\(verifyStatus)"
        )
        if verifyStatus == InputSourceInstallExit.success {
            return true
        }
    }
    print("install: boundary=\(label) pending system/session refresh")
    return false
}

/// Register, enable, and (when safe) select the shipped child input mode.
/// `false` means activation should be retried after a session refresh; package
/// installation must not reinterpret it as a corrupt payload.
func installInputSource() -> Bool {
    guard InputSourceInstallIdentity.load() != nil else { return false }
    let deadlineUptime = ProcessInfo.processInfo.systemUptime
        + InputSourceInstallRules.totalInstallBudget

    guard convergeInputSourceInstallBoundary(
            "registered",
            action: .register,
            verify: .verifyInstalled,
            deadlineUptime: deadlineUptime
          ),
          convergeInputSourceInstallBoundary(
            "parent-enabled",
            action: .enableParent,
            verify: .verifyParent,
            deadlineUptime: deadlineUptime
          ),
          convergeInputSourceInstallBoundary(
            "mode-enabled",
            action: .enableMode,
            verify: .verifyMode,
            deadlineUptime: deadlineUptime
          ) else {
        return false
    }

    // The historical WeChat crash is in Apple's input-source HUD before our
    // controller runs. Enabling is complete; defer automatic selection.
    if NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        == "com.tencent.xinWeChat" {
        print("install: WeChat is frontmost; selection deferred")
        return true
    }

    let selected = convergeInputSourceInstallBoundary(
        "mode-selected",
        action: .selectMode,
        verify: .verifySelected,
        deadlineUptime: deadlineUptime
    )
    if !selected {
        print("install: mode is enabled; automatic selection remains best-effort")
    }
    return true
}

func runInputSourceInstallSmokeTest() -> Bool {
    print("== RIMES input-source installer smoke test ==")
    let bundleID = "com.isaac.inputmethod.RimeBuffer"
    let modeID = bundleID + ".Hans"
    let parent = InputSourceInstallMetadata(
        sourceID: bundleID,
        bundleID: bundleID,
        sourceType: kTISTypeKeyboardInputMethodModeEnabled as String,
        category: kTISCategoryKeyboardInputSource as String,
        enabled: true,
        enableCapable: true,
        selectCapable: false,
        asciiCapable: nil
    )
    let mode = InputSourceInstallMetadata(
        sourceID: modeID,
        bundleID: bundleID,
        sourceType: kTISTypeKeyboardInputMode as String,
        category: kTISCategoryKeyboardInputSource as String,
        enabled: nil,
        enableCapable: true,
        selectCapable: true,
        asciiCapable: nil
    )
    let wrongMode = InputSourceInstallMetadata(
        sourceID: mode.sourceID,
        bundleID: mode.bundleID,
        sourceType: kTISTypeKeyboardInputMethodModeEnabled as String,
        category: mode.category,
        enabled: mode.enabled,
        enableCapable: mode.enableCapable,
        selectCapable: mode.selectCapable,
        asciiCapable: mode.asciiCapable
    )
    let incapableMode = InputSourceInstallMetadata(
        sourceID: mode.sourceID,
        bundleID: mode.bundleID,
        sourceType: mode.sourceType,
        category: mode.category,
        enabled: mode.enabled,
        enableCapable: false,
        selectCapable: true,
        asciiCapable: mode.asciiCapable
    )
    let unselectableMode = InputSourceInstallMetadata(
        sourceID: mode.sourceID,
        bundleID: mode.bundleID,
        sourceType: mode.sourceType,
        category: mode.category,
        enabled: mode.enabled,
        enableCapable: true,
        selectCapable: false,
        asciiCapable: mode.asciiCapable
    )
    let selectableParent = InputSourceInstallMetadata(
        sourceID: parent.sourceID,
        bundleID: parent.bundleID,
        sourceType: parent.sourceType,
        category: parent.category,
        enabled: parent.enabled,
        enableCapable: true,
        selectCapable: true,
        asciiCapable: parent.asciiCapable
    )
    let legacyActivationMarker = PendingActivationMarkerPayload(
        kind: .activation,
        generationToken: nil
    )
    let versionedDuplicateMarker = PendingActivationMarkerPayload(
        kind: .duplicateConflict,
        generationToken: "A1_b-2"
    )

    guard InputSourceInstallRules.isParent(parent, parentID: bundleID),
          InputSourceInstallRules.isMode(
            mode,
            bundleID: bundleID,
            modeID: modeID
          ),
          !InputSourceInstallRules.isMode(
            wrongMode,
            bundleID: bundleID,
            modeID: modeID
          ),
          !InputSourceInstallRules.isMode(
            incapableMode,
            bundleID: bundleID,
            modeID: modeID
          ),
          !InputSourceInstallRules.isMode(
            unselectableMode,
            bundleID: bundleID,
            modeID: modeID
          ),
          !InputSourceInstallRules.isParent(
            selectableParent,
            parentID: bundleID
          ),
          InputSourceInstallRules.parentDependencySatisfied(
            parentInEnabledRoster: true
          ),
          !InputSourceInstallRules.parentDependencySatisfied(
            parentInEnabledRoster: false
          ),
          InputSourceInstallRules.modeReachedEnabledRoster(1),
          !InputSourceInstallRules.modeReachedEnabledRoster(0),
          !InputSourceInstallRules.modeReachedEnabledRoster(2),
          InputSourceInstallRules.retryDelays.first == 0,
          InputSourceInstallRules.retryDelays.reduce(0, +) < 15,
          InputSourceInstallRules.subprocessTimeout <= 3,
          InputSourceInstallRules.totalInstallBudget <= 90,
          parsePendingActivationMarkerValue("") == legacyActivationMarker,
          parsePendingActivationMarkerValue("activation")
            == legacyActivationMarker,
          parsePendingActivationMarkerValue("duplicate-conflict")
            == PendingActivationMarkerPayload(
                kind: .duplicateConflict,
                generationToken: nil
            ),
          parsePendingActivationMarkerValue(
            "v1:duplicate-conflict:A1_b-2"
          ) == versionedDuplicateMarker,
          parsePendingActivationMarkerValue("v1:activation:") == nil,
          parsePendingActivationMarkerValue("v1:unknown:A1_b-2") == nil,
          parsePendingActivationMarkerValue("v1:activation:bad:token") == nil,
          runPendingActivationMarkerGenerationSmokeTest(),
          Set(InputSourceInstallPhase.allCases.map(\.rawValue)).count
            == InputSourceInstallPhase.allCases.count else {
        print("FAILED: input-source installer rules")
        return false
    }
    print("input-source installer smoke OK")
    return true
}

/// A package install can finish while macOS is still refreshing the current
/// login session. Retry the user-scoped reconciliation once when the IMK app is
/// next launched; leave the marker in place on failure so a later login/launch
/// gets another bounded attempt.
private var pendingInputSourceActivationRetryProcess: Process?

private func pendingInputSourceActivationURLs()
    -> (marker: URL, agent: URL, lock: URL) {
    let home = FileManager.default.homeDirectoryForCurrentUser
    return (
        home
            .appendingPathComponent(
                "Library/Application Support/RIMES",
                isDirectory: true
            )
            .appendingPathComponent("input-source-activation-pending"),
        home
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent(
                "com.scholay.rimes.activation-repair.plist"
            ),
        home
            .appendingPathComponent(
                "Library/Application Support/RIMES",
                isDirectory: true
            )
            .appendingPathComponent("input-source-activation-repair.lock")
    )
}

private func pendingActivationPathIsConfirmedAbsent(_ url: URL) -> Bool {
    var metadata = stat()
    let status = url.path.withCString { path in
        Darwin.lstat(path, &metadata)
    }
    guard status != 0 else { return false }
    return errno == ENOENT
}

/// Must be called while holding the publication lock. The marker is removed
/// and proven absent before the agent is touched, so a failed clear can leave a
/// harmless marker-less stale agent but never a live marker without a consumer.
private func clearPendingInputSourceActivation(
    marker: URL,
    agent: URL
) -> Bool {
    _ = marker.path.withCString { path in
        Darwin.unlink(path)
    }
    guard pendingActivationPathIsConfirmedAbsent(marker) else {
        print("install: could not confirm pending marker removal")
        return false
    }

    _ = agent.path.withCString { path in
        Darwin.unlink(path)
    }
    guard pendingActivationPathIsConfirmedAbsent(agent) else {
        print("install: could not confirm pending LaunchAgent removal")
        return false
    }
    return true
}

private enum PendingActivationKind: Equatable {
    case activation
    case duplicateConflict
}

private struct PendingActivationMarkerPayload: Equatable {
    let kind: PendingActivationKind
    let generationToken: String?
}

/// Every package-side publication uses an atomic rename of a newly-created
/// marker. Keeping the old marker descriptor open while reconciliation runs
/// makes its `(device, inode)` pair non-reusable, while the remaining metadata
/// also detects an unsupported in-place rewrite. This gives legacy marker
/// contents a generation identity without changing their on-disk format.
private struct PendingActivationMarkerGeneration: Equatable {
    /// Present for the v1 on-disk format. Legacy markers derive their identity
    /// solely from the still-open file and its immutable publication metadata.
    let token: String?
    let device: UInt64
    let inode: UInt64
    let size: Int64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let changedSeconds: Int64
    let changedNanoseconds: Int64

    init(metadata: stat, token: String? = nil) {
        self.token = token
        device = UInt64(metadata.st_dev)
        inode = UInt64(metadata.st_ino)
        size = Int64(metadata.st_size)
        modifiedSeconds = Int64(metadata.st_mtimespec.tv_sec)
        modifiedNanoseconds = Int64(metadata.st_mtimespec.tv_nsec)
        changedSeconds = Int64(metadata.st_ctimespec.tv_sec)
        changedNanoseconds = Int64(metadata.st_ctimespec.tv_nsec)
    }
}

private struct PendingActivationMarkerSnapshot {
    let kind: PendingActivationKind
    let generation: PendingActivationMarkerGeneration
    /// Owned by the snapshot. The caller must close it; O_CLOEXEC prevents TIS
    /// subprocesses from retaining an old generation.
    let descriptor: Int32
}

private enum PendingActivationMarkerState {
    case committed(PendingActivationMarkerSnapshot)
    case absent
    case invalid
    case unavailable(String)
}

private func validPendingActivationGenerationToken(_ token: Substring) -> Bool {
    let bytes = token.utf8
    guard !bytes.isEmpty, bytes.count <= 40 else { return false }
    return bytes.allSatisfy { byte in
        switch byte {
        case 48...57, 65...90, 97...122, 45, 95:
            return true
        default:
            return false
        }
    }
}

private func parsePendingActivationMarkerValue(_ value: String)
    -> PendingActivationMarkerPayload? {
    switch value {
    case "", "activation":
        // Empty is the marker format shipped before marker kinds existed.
        return PendingActivationMarkerPayload(
            kind: .activation,
            generationToken: nil
        )
    case "duplicate-conflict":
        return PendingActivationMarkerPayload(
            kind: .duplicateConflict,
            generationToken: nil
        )
    default:
        let fields = value.split(separator: ":", omittingEmptySubsequences: false)
        guard fields.count == 3,
              fields[0] == "v1",
              validPendingActivationGenerationToken(fields[2]) else {
            return nil
        }
        let kind: PendingActivationKind
        switch fields[1] {
        case "activation":
            kind = .activation
        case "duplicate-conflict":
            kind = .duplicateConflict
        default:
            return nil
        }
        return PendingActivationMarkerPayload(
            kind: kind,
            generationToken: String(fields[2])
        )
    }
}

/// Opens and parses one committed marker generation. A committed result owns an
/// open descriptor so a replacement marker cannot recycle the snapshotted inode
/// before compare-before-clear completes.
private func pendingActivationMarkerState(_ url: URL)
    -> PendingActivationMarkerState {
    let descriptor = Darwin.open(
        url.path,
        O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
    )
    guard descriptor >= 0 else {
        let code = errno
        if code == ENOENT { return .absent }
        if code == ELOOP { return .invalid }
        return .unavailable("open errno=\(code)")
    }

    var before = stat()
    guard Darwin.fstat(descriptor, &before) == 0 else {
        let code = errno
        _ = Darwin.close(descriptor)
        return .unavailable("fstat errno=\(code)")
    }
    guard (before.st_mode & S_IFMT) == S_IFREG,
          before.st_size >= 0,
          before.st_size <= 64 else {
        _ = Darwin.close(descriptor)
        return .invalid
    }

    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 65)
    while data.count <= 64 {
        let capacity = min(buffer.count, 65 - data.count)
        let count = buffer.withUnsafeMutableBytes { bytes in
            Darwin.read(descriptor, bytes.baseAddress, capacity)
        }
        if count < 0 {
            if errno == EINTR { continue }
            let code = errno
            _ = Darwin.close(descriptor)
            return .unavailable("read errno=\(code)")
        }
        if count == 0 { break }
        data.append(contentsOf: buffer.prefix(count))
    }
    guard data.count <= 64,
          let value = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) else {
        _ = Darwin.close(descriptor)
        return .invalid
    }

    guard let payload = parsePendingActivationMarkerValue(value) else {
        _ = Darwin.close(descriptor)
        return .invalid
    }

    var after = stat()
    guard Darwin.fstat(descriptor, &after) == 0 else {
        let code = errno
        _ = Darwin.close(descriptor)
        return .unavailable("second fstat errno=\(code)")
    }
    let beforeGeneration = PendingActivationMarkerGeneration(metadata: before)
    let afterGeneration = PendingActivationMarkerGeneration(metadata: after)
    guard beforeGeneration == afterGeneration else {
        _ = Darwin.close(descriptor)
        return .unavailable("marker changed while being read")
    }
    return .committed(PendingActivationMarkerSnapshot(
        kind: payload.kind,
        generation: PendingActivationMarkerGeneration(
            metadata: after,
            token: payload.generationToken
        ),
        descriptor: descriptor
    ))
}

private func runPendingActivationMarkerGenerationSmokeTest() -> Bool {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(
        "rimes-marker-generation-\(UUID().uuidString)",
        isDirectory: true
    )
    let marker = root.appendingPathComponent("pending")
    let agent = root.appendingPathComponent("agent.plist")
    let lock = root.appendingPathComponent("repair.lock")
    do {
        try fileManager.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? fileManager.removeItem(at: root) }

        try Data("v1:activation:OldA1\n".utf8).write(
            to: marker,
            options: .atomic
        )
        guard case let .committed(original) =
            pendingActivationMarkerState(marker) else {
            return false
        }
        defer { _ = Darwin.close(original.descriptor) }

        // Atomic replacement must create a distinguishable generation even
        // while the original descriptor remains open.
        try Data("v1:duplicate-conflict:NewB2\n".utf8).write(
            to: marker,
            options: .atomic
        )
        guard case let .committed(replacement) =
            pendingActivationMarkerState(marker) else {
            return false
        }
        defer { _ = Darwin.close(replacement.descriptor) }
        guard original.kind == .activation,
              original.generation.token == "OldA1",
              replacement.kind == .duplicateConflict,
              replacement.generation.token == "NewB2",
              original.generation != replacement.generation else {
            return false
        }

        try Data("agent".utf8).write(to: agent, options: .atomic)
        // An old repair must not erase a marker/agent pair published while its
        // slow TIS work was in flight.
        guard !commitPendingInputSourceActivationClear(
            marker: marker,
            agent: agent,
            lock: lock,
            expected: original
        ),
        fileManager.fileExists(atPath: marker.path),
        fileManager.fileExists(atPath: agent.path) else {
            return false
        }

        // The exact replacement generation may commit marker-first cleanup.
        guard commitPendingInputSourceActivationClear(
            marker: marker,
            agent: agent,
            lock: lock,
            expected: replacement
        ),
        !fileManager.fileExists(atPath: marker.path),
        !fileManager.fileExists(atPath: agent.path) else {
            return false
        }

        // Legacy writers had no token. Holding the first descriptor open must
        // still distinguish an atomic same-content replacement by file identity.
        try Data("activation\n".utf8).write(to: marker, options: .atomic)
        guard case let .committed(legacyOriginal) =
            pendingActivationMarkerState(marker) else {
            return false
        }
        defer { _ = Darwin.close(legacyOriginal.descriptor) }
        try Data("activation\n".utf8).write(to: marker, options: .atomic)
        guard case let .committed(legacyReplacement) =
            pendingActivationMarkerState(marker) else {
            return false
        }
        defer { _ = Darwin.close(legacyReplacement.descriptor) }
        try Data("agent".utf8).write(to: agent, options: .atomic)
        guard legacyOriginal.generation != legacyReplacement.generation,
              !commitPendingInputSourceActivationClear(
                marker: marker,
                agent: agent,
                lock: lock,
                expected: legacyOriginal
              ),
              fileManager.fileExists(atPath: marker.path),
              fileManager.fileExists(atPath: agent.path) else {
            return false
        }
        return commitPendingInputSourceActivationClear(
            marker: marker,
            agent: agent,
            lock: lock,
            expected: legacyReplacement
        )
    } catch {
        print("FAILED: marker generation smoke: \(error.localizedDescription)")
        return false
    }
}

private enum PhysicalDuplicateScanResult {
    case clear
    case conflicts([String])
    case unavailable(String)
}

/// A duplicate marker is intentionally stronger than a transient TIS marker:
/// ordinary roster reconciliation must not erase it while a second physical
/// bundle with one of our frozen identifiers remains. Once the user removes
/// the logged path, a later login can automatically continue activation.
private func scanForPhysicalInputSourceDuplicates()
    -> PhysicalDuplicateScanResult {
    let fileManager = FileManager.default
    let canonicalPath = "/Library/Input Methods/ETInput.app"
    let managedIdentifiers: Set<String> = [
        "com.isaac.inputmethod.RimeBuffer",
        "com.isaac.inputmethod.ETInput",
    ]
    let roots = [
        URL(fileURLWithPath: "/Library/Input Methods", isDirectory: true),
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Input Methods", isDirectory: true),
    ]
    var conflicts: [String] = []

    for root in roots {
        var rootMetadata = stat()
        let rootStatus = root.path.withCString { path in
            Darwin.lstat(path, &rootMetadata)
        }
        if rootStatus != 0 {
            if errno == ENOENT { continue }
            return .unavailable("cannot inspect \(root.path): errno=\(errno)")
        }
        guard (rootMetadata.st_mode & S_IFMT) == S_IFDIR else {
            return .unavailable("input-method root is not a directory: \(root.path)")
        }

        let candidates: [URL]
        do {
            candidates = try fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: nil,
                options: [.skipsSubdirectoryDescendants]
            )
        } catch {
            return .unavailable(
                "cannot enumerate \(root.path): \(error.localizedDescription)"
            )
        }
        guard candidates.count <= 128 else {
            return .unavailable("too many bundles under \(root.path)")
        }

        for candidate in candidates where
            candidate.pathExtension.caseInsensitiveCompare("app")
                == .orderedSame {
            guard candidate.standardizedFileURL.path != canonicalPath else {
                continue
            }
            let infoURL = candidate
                .appendingPathComponent("Contents", isDirectory: true)
                .appendingPathComponent("Info.plist")
            let data: Data
            do {
                data = try Data(contentsOf: infoURL, options: .mappedIfSafe)
            } catch {
                // An unreadable immediate .app could be the exact conflict the
                // root installer recorded. Preserve the marker instead of
                // incorrectly declaring the physical namespace clean.
                return .unavailable(
                    "cannot inspect \(infoURL.path): \(error.localizedDescription)"
                )
            }
            guard data.count <= 1_048_576,
                  let object = try? PropertyListSerialization.propertyList(
                    from: data,
                    options: [],
                    format: nil
                  ),
                  let dictionary = object as? [String: Any],
                  let identifier = dictionary["CFBundleIdentifier"] as? String
            else {
                continue
            }
            if managedIdentifiers.contains(identifier) {
                conflicts.append(candidate.path)
            }
        }
    }
    return conflicts.isEmpty ? .clear : .conflicts(conflicts)
}

private func acquirePendingActivationLock(_ url: URL) -> Int32 {
    let descriptor = Darwin.open(
        url.path,
        O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_EXLOCK | O_NONBLOCK,
        S_IRUSR | S_IWUSR
    )
    guard descriptor >= 0 else { return -1 }
    var metadata = stat()
    guard Darwin.fstat(descriptor, &metadata) == 0,
          (metadata.st_mode & S_IFMT) == S_IFREG,
          metadata.st_uid == Darwin.geteuid(),
          (metadata.st_mode & (S_IRWXG | S_IRWXO)) == 0 else {
        _ = Darwin.close(descriptor)
        return -1
    }
    return descriptor
}

/// Commits successful reconciliation only if the marker path still names the
/// exact generation that was snapshotted before the slow work began. A newer
/// marker (especially the stronger duplicate-conflict kind) and an unreadable
/// marker are both preserved for a later repair.
private func commitPendingInputSourceActivationClear(
    marker: URL,
    agent: URL,
    lock: URL,
    expected: PendingActivationMarkerSnapshot
) -> Bool {
    let clearLock = acquirePendingActivationLock(lock)
    guard clearLock >= 0 else {
        print("install: activation ready, but marker compare lock is busy")
        return false
    }
    defer {
        _ = Darwin.close(clearLock)
    }

    switch pendingActivationMarkerState(marker) {
    case let .committed(current):
        defer {
            _ = Darwin.close(current.descriptor)
        }
        guard current.kind == expected.kind,
              current.generation == expected.generation else {
            print("install: preserving a newer pending activation generation")
            return false
        }
        return clearPendingInputSourceActivation(
            marker: marker,
            agent: agent
        )
    case .absent:
        // A concurrent successful installer already removed the marker. Finish
        // stale-agent cleanup with the same marker-first verification contract.
        return clearPendingInputSourceActivation(
            marker: marker,
            agent: agent
        )
    case .invalid:
        print("install: pending marker changed to an invalid newer generation")
        return false
    case let .unavailable(reason):
        print("install: cannot compare pending marker generation: \(reason)")
        return false
    }
}

/// Entry point for the one-shot per-user LaunchAgent written by postinstall.
/// Its only durable condition is registration+enablement; selecting RIMES is
/// best-effort and never competes indefinitely with a user's later choice.
func repairPendingInputSourceActivation() -> Bool {
    let urls = pendingInputSourceActivationURLs()
    let snapshotLock = acquirePendingActivationLock(urls.lock)
    guard snapshotLock >= 0 else { return false }

    let markerSnapshot: PendingActivationMarkerSnapshot
    switch pendingActivationMarkerState(urls.marker) {
    case let .committed(snapshot):
        markerSnapshot = snapshot
        _ = Darwin.close(snapshotLock)
    case .absent:
        // The agent is published before the marker commit point. If an
        // installer was interrupted between those atomic renames, this is a
        // safe stale-agent cleanup while holding the shared advisory lock.
        let cleared = clearPendingInputSourceActivation(
            marker: urls.marker,
            agent: urls.agent
        )
        _ = Darwin.close(snapshotLock)
        return cleared
    case .invalid:
        // Unknown/corrupt content may belong to a newer package format. Without
        // a generation snapshot we cannot prove ownership, so fail closed.
        print("install: pending marker is invalid; preserving it for diagnosis")
        _ = Darwin.close(snapshotLock)
        return false
    case let .unavailable(reason):
        print("install: pending marker is temporarily unavailable: \(reason)")
        _ = Darwin.close(snapshotLock)
        return false
    }
    defer {
        _ = Darwin.close(markerSnapshot.descriptor)
    }

    // Never hold the publication lock across a physical scan or the bounded
    // 90-second TIS convergence. PackageKit can now publish a stronger/newer
    // generation while this repair is running.
    if markerSnapshot.kind == .duplicateConflict {
        switch scanForPhysicalInputSourceDuplicates() {
        case .clear:
            print("install: recorded duplicate paths are now clear; retrying activation")
        case let .conflicts(paths):
            print("install: activation remains blocked by duplicate paths:")
            paths.forEach { print("install: duplicate=\($0)") }
            return false
        case let .unavailable(reason):
            print("install: duplicate-path check unavailable: \(reason)")
            return false
        }
    }

    guard installInputSource() else { return false }
    return commitPendingInputSourceActivationClear(
        marker: urls.marker,
        agent: urls.agent,
        lock: urls.lock,
        expected: markerSnapshot
    )
}

func retryPendingInputSourceActivationIfNeeded() {
    guard pendingInputSourceActivationRetryProcess == nil else { return }
    let marker = pendingInputSourceActivationURLs().marker
    guard let values = try? marker.resourceValues(forKeys: [
        .isRegularFileKey,
        .isSymbolicLinkKey,
    ]),
    values.isRegularFile == true,
    values.isSymbolicLink != true,
    let executableURL = Bundle.main.executableURL else {
        return
    }

    let process = Process()
    process.executableURL = executableURL
    process.arguments = ["--repair-pending-install"]
    // The child owns the cross-process advisory lock and is solely responsible
    // for clearing its marker generation. A parent-side second clear can race
    // a newer package install and erase that newer generation.
    process.terminationHandler = { _ in }
    do {
        pendingInputSourceActivationRetryProcess = process
        try process.run()
        print("install: retrying pending input-source activation")
    } catch {
        pendingInputSourceActivationRetryProcess = nil
        print(
            "install: cannot retry pending activation:"
                + " \(error.localizedDescription)"
        )
    }
}
