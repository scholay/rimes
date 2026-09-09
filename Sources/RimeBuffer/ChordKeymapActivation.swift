import Foundation
import CRimeBridge

extension Notification.Name {
    static let chordKeymapWillChange = Notification.Name("RimeBuffer.ChordKeymap.willChange")
}

enum ChordKeymapActivationError: LocalizedError {
    case message(String)
    case restorationFailed(String)
    var errorDescription: String? {
        switch self {
        case let .message(text), let .restorationFailed(text): return text
        }
    }
}

/// Generated schemas are disposable deployment artifacts. The versioned
/// profile snapshot in chord-keymaps is authoritative and survives reseeding.
struct ChordKeymapRuntimeFiles {
    let root: URL

    static var userRoot: URL {
        ProcessInfo.processInfo.environment["RIMEBUFFER_USER_DIR"]
            .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Library/\(RimesPaths.directoryName)", isDirectory: true)
    }

    struct Snapshot {
        let schemaURL: URL?
        let schemaData: Data?
        let listURL: URL
        let listData: Data?
    }

    private func checkedData(at url: URL) throws -> Data? {
        let manager = FileManager.default
        // resourceValues also detects dangling symlinks, unlike fileExists.
        if let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]),
           values.isSymbolicLink == true {
            throw ChordKeymapActivationError.message("方案路径不能是符号链接。")
        }
        guard manager.fileExists(atPath: url.path) else { return nil }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, (values.fileSize ?? Int.max) <= 4 * 1024 * 1024 else {
            throw ChordKeymapActivationError.message("方案文件类型或大小不受支持。")
        }
        return try Data(contentsOf: url)
    }

    private func prepareRoot() throws {
        if let values = try? root.resourceValues(forKeys: [.isSymbolicLinkKey]),
           values.isSymbolicLink == true {
            throw ChordKeymapActivationError.message("Rime 数据目录不能是符号链接。")
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func writeSchema(for profile: ChordKeymapProfile) throws {
        guard !profile.isBuiltIn else { return }
        let yaml = try ChordKeymapCompiler.schemaYAML(for: profile)
        try prepareRoot()
        let url = root.appendingPathComponent(profile.schemaID + ".schema.yaml")
        let data = Data(yaml.utf8)
        guard try checkedData(at: url) != data else { return }
        try data.write(to: url, options: .atomic)
    }

    func prepare(_ profile: ChordKeymapProfile) throws -> Snapshot {
        try prepareRoot()
        let schemaURL = profile.isBuiltIn ? nil
            : root.appendingPathComponent(profile.schemaID + ".schema.yaml")
        let listURL = root.appendingPathComponent("default.custom.yaml")
        let snapshot = Snapshot(schemaURL: schemaURL,
                                schemaData: try schemaURL.flatMap { try checkedData(at: $0) },
                                listURL: listURL,
                                listData: try checkedData(at: listURL))
        do {
            try writeSchema(for: profile)
            let stored = SchemaListStore.enabledIDs(at: listURL)
                .filter { !ChordExtensionStore.isChordSchema($0) }
            let ordinary = stored.isEmpty ? InputSchemaCatalog.defaultEnabledIDs : stored
            try SchemaListStore.writeEnabledIDs(ordinary + [profile.schemaID],
                                                to: listURL,
                                                chordSchemaID: profile.schemaID)
        } catch {
            let preparationError = error
            do { try restore(snapshot) }
            catch {
                throw ChordKeymapActivationError.restorationFailed(
                    "准备键位方案后无法恢复原文件：\(error.localizedDescription)"
                )
            }
            throw preparationError
        }
        return snapshot
    }

    func restore(_ snapshot: Snapshot) throws {
        func restoreFile(_ url: URL, _ bytes: Data?) throws {
            _ = try checkedData(at: url)
            if let bytes {
                try bytes.write(to: url, options: .atomic)
            } else if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
        if let url = snapshot.schemaURL { try restoreFile(url, snapshot.schemaData) }
        try restoreFile(snapshot.listURL, snapshot.listData)
    }
}

/// Retire per-client sessions, deploy and verify the exact candidate profile,
/// then publish its immutable snapshot. Failed deployments restore raw files
/// and redeploy before allowing controllers to recreate their old sessions.
final class ChordKeymapActivationCoordinator {
    enum LifecycleEvent: Equatable {
        case willChange
        case maintenanceWillBegin
        case didChange
        case maintenanceDidEnd
    }

    /// The transaction owns sequencing; these effects provide its production
    /// filesystem/engine boundaries and deterministic smoke-test substitutes.
    struct Runtime {
        var isEnabled: () -> Bool
        var startEngine: () -> Bool
        var activeProfile: () -> ChordKeymapProfile
        var selectedSchemaID: () -> String
        var prepare: (ChordKeymapProfile) throws -> ChordKeymapRuntimeFiles.Snapshot
        var restore: (ChordKeymapRuntimeFiles.Snapshot) throws -> Void
        var activate: (ChordKeymapProfile) throws -> Void
        var selectSchema: (String) -> Void
        /// Completion must return to the main queue; no activation or session
        /// resume can happen while this asynchronous verification is pending.
        var deployAndVerify: (ChordKeymapProfile, @escaping (Bool) -> Void) -> Void
        var publish: (LifecycleEvent) -> Void
        var invalidateSchemaCache: () -> Void
        var recoveryMessage: () -> String?
        var setRecoveryMessage: (String?) -> Void
        var disableChord: () -> Void

        static var live: Runtime {
            let files = ChordKeymapRuntimeFiles(root: ChordKeymapRuntimeFiles.userRoot)
            return Runtime(
                isEnabled: { ChordExtensionStore.shared.isEnabled },
                startEngine: { rimeEngine.start() },
                activeProfile: { ChordKeymapStore.shared.activeProfile },
                selectedSchemaID: { InputConfigurationStore.shared.selectedSchemaID },
                prepare: { try files.prepare($0) },
                restore: { try files.restore($0) },
                activate: { try ChordKeymapStore.shared.activate($0) },
                selectSchema: { _ = InputConfigurationStore.shared.select(schemaID: $0) },
                deployAndVerify: { profile, completion in
                    DispatchQueue.global(qos: .userInitiated).async {
                        let verified = BBRimeDeploy()
                            && ChordKeymapActivationCoordinator.verify(profile, engine: rimeEngine)
                        DispatchQueue.main.async { completion(verified) }
                    }
                },
                publish: { event in
                    let name: Notification.Name
                    let object: AnyObject
                    switch event {
                    case .willChange:
                        name = .chordKeymapWillChange
                        object = ChordKeymapActivationCoordinator.shared
                    case .maintenanceWillBegin:
                        name = .rimeUserDictionaryMaintenanceWillBegin
                        object = rimeEngine
                    case .didChange:
                        name = .chordKeymapDidChange
                        object = ChordKeymapStore.shared
                    case .maintenanceDidEnd:
                        name = .rimeUserDictionaryMaintenanceDidEnd
                        object = rimeEngine
                    }
                    NotificationCenter.default.post(name: name, object: object)
                },
                invalidateSchemaCache: { rimeEngine.invalidateSchemaListCacheAfterDeployment() },
                recoveryMessage: { UserDefaults.standard.string(forKey: ChordKeymapActivationCoordinator.recoveryKey) },
                setRecoveryMessage: { message in
                    if let message { UserDefaults.standard.set(message, forKey: ChordKeymapActivationCoordinator.recoveryKey) }
                    else { UserDefaults.standard.removeObject(forKey: ChordKeymapActivationCoordinator.recoveryKey) }
                },
                disableChord: { _ = ChordExtensionStore.shared.setEnabled(false, source: .rollback) }
            )
        }
    }

    static let shared = ChordKeymapActivationCoordinator()
    private let runtime: Runtime
    private(set) var isApplying = false
    var extensionDeploymentInProgress = false
    private static let recoveryKey = "chord.keymap.recovery-message.v1"
    var recoveryMessage: String? { runtime.recoveryMessage() }

    init(runtime: Runtime = .live) {
        self.runtime = runtime
    }

    func suspendChordAfterFailure(_ message: String) {
        runtime.setRecoveryMessage(message)
        runtime.disableChord()
    }

    func clearRecoveryMessage() { runtime.setRecoveryMessage(nil) }

    func apply(profile: ChordKeymapProfile,
               completion: @escaping (Result<Void, Error>) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !isApplying, !extensionDeploymentInProgress else {
            completion(.failure(ChordKeymapActivationError.message("正在应用另一个键位方案。")))
            return
        }
        guard runtime.isEnabled() else {
            completion(.failure(ChordKeymapActivationError.message("请先启用并击扩展。")))
            return
        }
        let candidate: ChordKeymapProfile
        do { candidate = try profile.validated() }
        catch { completion(.failure(error)); return }
        guard runtime.startEngine() else {
            completion(.failure(ChordKeymapActivationError.message("Rime 引擎未就绪，当前方案未改变。")))
            return
        }
        let previous = runtime.activeProfile()
        let previousSchemaID = runtime.selectedSchemaID()
        isApplying = true
        runtime.publish(.willChange)
        runtime.publish(.maintenanceWillBegin)
        let snapshot: ChordKeymapRuntimeFiles.Snapshot
        do { snapshot = try runtime.prepare(candidate) }
        catch {
            if case .restorationFailed? = error as? ChordKeymapActivationError {
                suspendChordAfterFailure("准备键位方案失败且原文件未能恢复，已暂停并击，请重新启用扩展重试。")
            }
            finish(.failure(error), completion: completion)
            return
        }

        runtime.deployAndVerify(candidate) { verified in
            dispatchPrecondition(condition: .onQueue(.main))
            if verified {
                do {
                    try self.runtime.activate(candidate)
                    self.clearRecoveryMessage()
                    if ChordExtensionStore.isChordSchema(previousSchemaID) {
                        self.runtime.selectSchema(candidate.schemaID)
                    }
                    self.finish(.success(()), completion: completion)
                    return
                } catch {
                    self.rollback(snapshot: snapshot, previous: previous,
                                  previousSchemaID: previousSchemaID, error: error,
                                  completion: completion)
                    return
                }
            }
            self.rollback(snapshot: snapshot, previous: previous,
                          previousSchemaID: previousSchemaID,
                          error: ChordKeymapActivationError.message("部署或映射验证失败，未启用新方案。"),
                          completion: completion)
        }
    }

    private func rollback(snapshot: ChordKeymapRuntimeFiles.Snapshot,
                          previous: ChordKeymapProfile, previousSchemaID: String,
                          error: Error, completion: @escaping (Result<Void, Error>) -> Void) {
        do {
            try runtime.restore(snapshot)
            if runtime.activeProfile() != previous {
                try runtime.activate(previous)
            }
            runtime.selectSchema(previousSchemaID)
        } catch {
            suspendChordAfterFailure("键位方案恢复失败，已暂停并击并退回普通输入，请重新启用扩展重试。")
            finish(.failure(ChordKeymapActivationError.message(
                "方案恢复失败，已暂停并击并退回普通输入；请重新部署：\(error.localizedDescription)"
            )), completion: completion)
            return
        }
        runtime.deployAndVerify(previous) { recovered in
            dispatchPrecondition(condition: .onQueue(.main))
            if !recovered {
                self.suspendChordAfterFailure("旧键位方案部署验证失败，已暂停并击，请重新启用扩展重试。")
            }
            let resultError = recovered ? error : ChordKeymapActivationError.message(
                "已恢复原方案文件，但部署验证失败；已暂停并击并退回普通输入，请重新启用扩展重试。"
            )
            self.finish(.failure(resultError), completion: completion)
        }
    }

    private func finish(_ result: Result<Void, Error>,
                        completion: @escaping (Result<Void, Error>) -> Void) {
        runtime.invalidateSchemaCache()
        isApplying = false
        runtime.publish(.didChange)
        runtime.publish(.maintenanceDidEnd)
        completion(result)
    }

    /// A successful maintenance return alone does not prove that a generated
    /// schema compiled. Verify selection and every explicit mapping in a new
    /// private session without commits, learning or external text delivery.
    static func verify(_ profile: ChordKeymapProfile, engine: RimeEngine) -> Bool {
        let session = engine.createSession()
        guard session != 0 else { return false }
        defer { engine.destroySession(session) }
        guard engine.selectSchema(profile.schemaID, session: session),
              engine.getStatus(session: session).schemaId == profile.schemaID else { return false }
        engine.setOption("ascii_mode", false, session: session)
        for entry in profile.mappings {
            engine.clearComposition(session: session)
            let keys = entry.keys.unicodeScalars.map { Int32($0.value) }
            for key in keys { _ = engine.processKey(key, session: session) }
            for key in keys { _ = engine.processKey(key, mask: RimeKey.releaseMask, session: session) }
            guard engine.getContext(session: session).input == entry.output else { return false }
        }
        return true
    }
}
