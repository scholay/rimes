import Foundation
import CRimeBridge
import Darwin

enum RimeFileBackedCacheMissReason: String, Equatable {
    case cold
    case scopeChanged = "scope-change"
    case filesChanged = "file-change"
    case explicitInvalidation = "explicit-invalidation"
}

struct RimeFileBackedCacheDiagnostics: Equatable {
    fileprivate(set) var hits = 0
    fileprivate(set) var misses = 0
    fileprivate(set) var loads = 0
    fileprivate(set) var invalidations = 0
}

enum RimeFileBackedCacheLookup<Value> {
    case hit(Value)
    case miss(RimeFileBackedCacheMissReason)
}

/// Small process-local cache primitive for deployed/config metadata. A hit
/// performs only `stat(2)` calls; file contents are parsed only after an
/// identity/size/nanosecond-timestamp change. `stat` deliberately follows a
/// symlink so replacing either the link target or a regular file invalidates
/// the cached value.
struct RimeFileBackedValueCache<Value> {
    struct FileStamp: Equatable {
        let result: Int32
        let device: UInt64
        let inode: UInt64
        let mode: UInt32
        let size: Int64
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
        let changedSeconds: Int64
        let changedNanoseconds: Int64

        static func capture(_ url: URL) -> FileStamp {
            var metadata = stat()
            let result = url.path.withCString { stat($0, &metadata) }
            guard result == 0 else {
                return FileStamp(
                    result: Int32(errno),
                    device: 0,
                    inode: 0,
                    mode: 0,
                    size: 0,
                    modifiedSeconds: 0,
                    modifiedNanoseconds: 0,
                    changedSeconds: 0,
                    changedNanoseconds: 0
                )
            }
            return FileStamp(
                result: 0,
                device: UInt64(metadata.st_dev),
                inode: UInt64(metadata.st_ino),
                mode: UInt32(metadata.st_mode),
                size: Int64(metadata.st_size),
                modifiedSeconds: Int64(metadata.st_mtimespec.tv_sec),
                modifiedNanoseconds: Int64(metadata.st_mtimespec.tv_nsec),
                changedSeconds: Int64(metadata.st_ctimespec.tv_sec),
                changedNanoseconds: Int64(metadata.st_ctimespec.tv_nsec)
            )
        }
    }

    private struct Entry {
        let scope: [String]
        let watchedURLs: [URL]
        let stamps: [FileStamp]
        let value: Value
    }

    private var entry: Entry?
    private var pendingMissReason: RimeFileBackedCacheMissReason?
    private(set) var diagnostics = RimeFileBackedCacheDiagnostics()

    mutating func lookup(scope: [String]) -> RimeFileBackedCacheLookup<Value> {
        guard let entry else {
            diagnostics.misses += 1
            let reason = pendingMissReason ?? .cold
            pendingMissReason = nil
            return .miss(reason)
        }
        guard entry.scope == scope else {
            self.entry = nil
            diagnostics.misses += 1
            diagnostics.invalidations += 1
            return .miss(.scopeChanged)
        }
        let current = entry.watchedURLs.map(FileStamp.capture)
        guard current == entry.stamps else {
            self.entry = nil
            diagnostics.misses += 1
            diagnostics.invalidations += 1
            return .miss(.filesChanged)
        }
        diagnostics.hits += 1
        return .hit(entry.value)
    }

    mutating func store(_ value: Value, scope: [String], watching urls: [URL]) {
        store(
            value,
            scope: scope,
            watching: urls,
            expectedStamps: urls.map(FileStamp.capture)
        )
    }

    func captureStamps(for urls: [URL]) -> [FileStamp] {
        urls.map(FileStamp.capture)
    }

    /// Cache only when the exact snapshot observed before a load still exists
    /// afterwards. This closes the read→store window where an atomic deploy or
    /// a newly-created higher-priority config could otherwise bind a stale value
    /// to fresh file metadata and hit indefinitely.
    @discardableResult
    mutating func store(_ value: Value,
                        scope: [String],
                        watching urls: [URL],
                        expectedStamps: [FileStamp]) -> Bool {
        let currentStamps = urls.map(FileStamp.capture)
        guard expectedStamps == currentStamps,
              expectedStamps.count == urls.count else {
            entry = nil
            pendingMissReason = .filesChanged
            diagnostics.invalidations += 1
            return false
        }
        entry = Entry(
            scope: scope,
            watchedURLs: urls,
            stamps: currentStamps,
            value: value
        )
        pendingMissReason = nil
        diagnostics.loads += 1
        return true
    }

    @discardableResult
    mutating func invalidate() -> Bool {
        let hadEntry = entry != nil
        entry = nil
        pendingMissReason = .explicitInvalidation
        if hadEntry {
            diagnostics.invalidations += 1
        }
        return hadEntry
    }
}

enum RimeKeyboardLayoutCacheStatus: String, Equatable {
    case hit
    case coldLoad = "miss-cold"
    case scopeChange = "miss-scope-change"
    case fileChange = "miss-file-change"
    case explicitInvalidation = "miss-explicit-invalidation"
    case uncachedReadFailure = "uncached-read-failure"
    case uncachedChangedDuringLoad = "uncached-file-change"
}

struct RimeKeyboardLayoutOverrideResolution: Equatable {
    let layout: String?
    let source: String
    let cacheStatus: RimeKeyboardLayoutCacheStatus
}

/// Caches the parsed `keyboard_layout` value while retaining Squirrel's
/// precedence rules. Only the prefix through the winning file is watched: a
/// newly-created higher-priority file or a change/removal of the current source
/// invalidates the result, while lower-priority files cannot affect it.
final class RimeKeyboardLayoutOverrideCache {
    private enum ConfigRead {
        case missing
        case noSetting
        case configured(String)
        case unreadable
    }

    private struct StoredResolution {
        let layout: String?
        let source: String
    }

    private let lock = NSLock()
    private var cache = RimeFileBackedValueCache<StoredResolution>()

    func resolve(candidates: [URL]) -> RimeKeyboardLayoutOverrideResolution {
        lock.lock()
        defer { lock.unlock() }

        let scope = candidates.map { $0.standardizedFileURL.path }
        let missReason: RimeFileBackedCacheMissReason
        switch cache.lookup(scope: scope) {
        case let .hit(stored):
            return RimeKeyboardLayoutOverrideResolution(
                layout: stored.layout,
                source: stored.source,
                cacheStatus: .hit
            )
        case let .miss(reason):
            missReason = reason
        }

        // Capture the complete precedence chain before reading any file. Even
        // files below the eventual winner are cheap to stat; their stamps are
        // sliced away at store, while a new higher-priority file cannot slip
        // between a "missing" read and the post-load snapshot.
        let initialStamps = cache.captureStamps(for: candidates)
        var watched: [URL] = []
        var cacheable = true
        for url in candidates {
            watched.append(url)
            switch Self.readConfig(at: url) {
            case .missing, .noSetting:
                continue
            case .unreadable:
                // Do not turn a transient read/permission race into a durable
                // fallback. Retry parsing on the next activation.
                cacheable = false
                continue
            case let .configured(configured):
                let stored: StoredResolution
                switch configured {
                case "", "last":
                    stored = StoredResolution(layout: nil, source: url.path)
                case "default":
                    stored = StoredResolution(
                        layout: "com.apple.keylayout.ABC",
                        source: url.path
                    )
                default:
                    stored = StoredResolution(layout: configured, source: url.path)
                }
                let cacheableBeforeStore = cacheable
                if cacheable {
                    cacheable = cache.store(
                        stored,
                        scope: scope,
                        watching: watched,
                        expectedStamps: Array(initialStamps.prefix(watched.count))
                    )
                }
                return RimeKeyboardLayoutOverrideResolution(
                    layout: stored.layout,
                    source: stored.source,
                    cacheStatus: cacheable
                        ? Self.status(for: missReason)
                        : (cacheableBeforeStore
                            ? .uncachedChangedDuringLoad
                            : .uncachedReadFailure)
                )
            }
        }

        let fallback = StoredResolution(layout: nil, source: "fallback:last")
        let cacheableBeforeStore = cacheable
        if cacheable {
            cacheable = cache.store(
                fallback,
                scope: scope,
                watching: watched,
                expectedStamps: initialStamps
            )
        }
        return RimeKeyboardLayoutOverrideResolution(
            layout: nil,
            source: fallback.source,
            cacheStatus: cacheable
                ? Self.status(for: missReason)
                : (cacheableBeforeStore
                    ? .uncachedChangedDuringLoad
                    : .uncachedReadFailure)
        )
    }

    var diagnostics: RimeFileBackedCacheDiagnostics {
        lock.lock()
        defer { lock.unlock() }
        return cache.diagnostics
    }

    private static func status(
        for reason: RimeFileBackedCacheMissReason
    ) -> RimeKeyboardLayoutCacheStatus {
        switch reason {
        case .cold: return .coldLoad
        case .scopeChanged: return .scopeChange
        case .filesChanged: return .fileChange
        case .explicitInvalidation: return .explicitInvalidation
        }
    }

    private static func readConfig(at url: URL) -> ConfigRead {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .missing
        }
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
            return .unreadable
        }
        for rawLine in contents.components(separatedBy: .newlines) {
            let uncommented = rawLine.split(
                separator: "#",
                maxSplits: 1,
                omittingEmptySubsequences: false
            ).first ?? ""
            let parts = uncommented.split(
                separator: ":",
                maxSplits: 1,
                omittingEmptySubsequences: false
            )
            guard parts.count == 2,
                  parts[0].trimmingCharacters(in: .whitespaces) == "keyboard_layout" else {
                continue
            }
            var value = parts[1].trimmingCharacters(in: .whitespaces)
            if value.count >= 2,
               (value.hasPrefix("\"") && value.hasSuffix("\"")
                || value.hasPrefix("'") && value.hasSuffix("'")) {
                value.removeFirst()
                value.removeLast()
            }
            return .configured(value)
        }
        return .noSetting
    }
}

extension Notification.Name {
    /// Sent synchronously on the main thread before librime closes every
    /// session for a user-dictionary export/import. Controllers must settle
    /// marked text, destroy their session, and set the cached id to zero.
    static let rimeUserDictionaryMaintenanceWillBegin = Notification.Name(
        "RimeBuffer.RimeUserDictionaryMaintenance.willBegin"
    )

    /// Sent synchronously after the operation. Controllers recreate sessions
    /// lazily through their ordinary ensureSessionReady path.
    static let rimeUserDictionaryMaintenanceDidEnd = Notification.Name(
        "RimeBuffer.RimeUserDictionaryMaintenance.didEnd"
    )
}

/// Thin, INSTANTIABLE wrapper over the C bridge. Deliberately NOT a singleton
/// and holds NO shared session — each IMK controller owns its own session so
/// composition never bleeds across fields. (The prototype's `.shared` +
/// `sharedSession` cache are gone.)
final class RimeEngine {
    private var started = false
    private let schemaListCacheLock = NSLock()
    private var schemaListCache = RimeFileBackedValueCache<[(id: String, name: String)]>()
    private var lastLoggedSchemaCacheHit = 0

    private static let squirrelShared = "/Library/Input Methods/Squirrel.app/Contents/SharedSupport"
    private static let squirrelFrameworks = "/Library/Input Methods/Squirrel.app/Contents/Frameworks"

    // Prefer the app's OWN bundled data + librime (self-contained install, no
    // Squirrel needed); fall back to a system Squirrel install for dev builds
    // run outside the .app. RIMEBUFFER_SHARED_DIR/RIMEBUFFER_FRAMEWORKS_DIR let
    // the CLI smoke harness point at a staged bundle without a full .app.
    private let sharedDataDir: String = {
        if let override = ProcessInfo.processInfo.environment["RIMEBUFFER_SHARED_DIR"],
           !override.isEmpty {
            return override
        }
        if let ss = Bundle.main.sharedSupportPath,
           FileManager.default.fileExists(atPath: ss + "/default.yaml") {
            return ss
        }
        return RimeEngine.squirrelShared
    }()
    private let frameworksDir: String = {
        if let override = ProcessInfo.processInfo.environment["RIMEBUFFER_FRAMEWORKS_DIR"],
           !override.isEmpty {
            return override
        }
        if let fw = Bundle.main.privateFrameworksPath,
           FileManager.default.fileExists(atPath: fw + "/librime.1.dylib") {
            return fw
        }
        return RimeEngine.squirrelFrameworks
    }()

    // Its OWN user dir (~/Library/RimeBuffer). Separate from Squirrel's so the
    // two never fight over the same userdb LevelDB lock — that lock conflict
    // silently kills candidates. First run deploys into it from sharedDataDir.
    // RIMEBUFFER_USER_DIR overrides it (used by the CLI smoke harness).
    private static let defaultUserDir = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/RimeBuffer").path
    private let userDataDir = ProcessInfo.processInfo.environment["RIMEBUFFER_USER_DIR"]
        ?? RimeEngine.defaultUserDir
    private let logDir = ProcessInfo.processInfo.environment["RIMEBUFFER_USER_DIR"]
        ?? RimeEngine.defaultUserDir

    /// dlopen + setup + initialize + smoke session. Retries on a later call if
    /// it failed (started stays false), so a transient failure isn't permanent.
    @discardableResult
    func start() -> Bool {
        if started { return true }
        // Ensure the user dir exists so the first-run deploy has a build target.
        try? FileManager.default.createDirectory(atPath: userDataDir, withIntermediateDirectories: true)
        started = BBRimeStart(sharedDataDir, userDataDir, logDir, frameworksDir)
        if started {
            IMELog.write("rime start OK shared=\(sharedDataDir) fw=\(frameworksDir) user=\(userDataDir)")
        } else {
            IMELog.write("rime start FAILED: \(lastError())")
        }
        return started
    }

    var isHealthy: Bool { BBRimeIsHealthy() }

    func createSession() -> UInt64 { BBRimeCreateSession() }
    func destroySession(_ session: UInt64) {
        guard session != 0 else { return }
        BBRimeDestroySession(session)
    }
    func sessionExists(_ session: UInt64) -> Bool {
        session != 0 && BBRimeSessionExists(session)
    }

    func processKey(_ keycode: Int32, mask: Int32 = 0, session: UInt64) -> Bool {
        BBRimeProcessKey(session, keycode, mask)
    }
    func commitComposition(session: UInt64) -> Bool { BBRimeCommitComposition(session) }
    func clearComposition(session: UInt64) { BBRimeClearComposition(session) }
    func selectCandidate(onPage index: Int, session: UInt64) -> Bool {
        BBRimeSelectCandidateOnCurrentPage(session, UInt64(index))
    }

    func getOption(_ name: String, session: UInt64) -> Bool {
        name.withCString { BBRimeGetOption(session, $0) }
    }
    func setOption(_ name: String, _ value: Bool, session: UInt64) {
        name.withCString { BBRimeSetOption(session, $0, value) }
    }
    func selectSchema(_ id: String, session: UInt64) -> Bool {
        id.withCString { BBRimeSelectSchema(session, $0) }
    }

    func takeCommit(session: UInt64) -> String? { takeString(BBRimeCopyCommit(session)) }
    func currentSchema(session: UInt64) -> String? { takeString(BBRimeCopySchema(session)) }
    func lastError() -> String { takeString(BBRimeCopyLastError()) ?? "" }

    /// Read a double from a deployed config, e.g. ("squirrel", "chord_duration").
    func configDouble(_ configId: String, _ key: String) -> Double? {
        var value = 0.0
        let ok = configId.withCString { c in
            key.withCString { k in BBRimeConfigGetDouble(c, k, &value) }
        }
        return ok ? value : nil
    }

    /// Schemas Rime has actually deployed (id + display name). Empty if the
    /// engine isn't up. librime's `get_schema_list` reloads every listed schema
    /// config, so keep its copied strings until the deployed build changes.
    /// This cache is process metadata only; Rime sessions remain per controller.
    func schemaList() -> [(id: String, name: String)] {
        schemaListCacheLock.lock()
        defer { schemaListCacheLock.unlock() }

        let scope = [URL(fileURLWithPath: userDataDir, isDirectory: true)
            .standardizedFileURL.path]
        let missReason: RimeFileBackedCacheMissReason
        switch schemaListCache.lookup(scope: scope) {
        case let .hit(schemas):
            let hits = schemaListCache.diagnostics.hits
            // Give diagnostics a cheap proof that activation is on the cache
            // path without adding one extra log write for every app switch.
            if hits == 1 || hits - lastLoggedSchemaCacheHit >= 128 {
                lastLoggedSchemaCacheHit = hits
                IMELog.write("rime schema cache hit count=\(hits) entries=\(schemas.count)")
            }
            return schemas
        case let .miss(reason):
            missReason = reason
        }

        // Enumerate every deployed schema before librime reads. The build
        // directory stamp protects membership changes; individual schema
        // stamps protect in-place edits that do not change the directory. We
        // intentionally watch the small full set rather than discover schema
        // files after the load and reopen a read→stamp race.
        let watched = schemaListSnapshotWatchURLs()
        let initialStamps = schemaListCache.captureStamps(for: watched)
        let schemas = loadSchemaList()
        // A transient bridge failure must remain retryable. A healthy deployed
        // list is cached against the build directory, effective default config,
        // and each schema config whose display metadata librime just loaded.
        var cached = false
        if !schemas.isEmpty {
            let watchedPaths = Set(watched.map { $0.standardizedFileURL.path })
            let returnedSchemaURLs = schemaListWatchURLs(for: schemas)
                .dropFirst(2)
            // A schema created after the enumeration is covered by the build
            // directory stamp, but is not yet individually watched. Skip this
            // cache generation and let the next activation enumerate it.
            let includesEveryReturnedSchema = returnedSchemaURLs.allSatisfy {
                watchedPaths.contains($0.standardizedFileURL.path)
            }
            cached = includesEveryReturnedSchema && schemaListCache.store(
                schemas,
                scope: scope,
                watching: watched,
                expectedStamps: initialStamps
            )
        }
        IMELog.write(
            "rime schema cache reload reason=\(missReason.rawValue) entries=\(schemas.count) cached=\(cached)"
        )
        return schemas
    }

    /// Explicit seam for any future in-process deploy path. Current menu and
    /// settings deployments exit after success, while the file fingerprint also
    /// catches external deploys and manual changes to the effective build.
    func invalidateSchemaListCacheAfterDeployment() {
        schemaListCacheLock.lock()
        let invalidated = schemaListCache.invalidate()
        schemaListCacheLock.unlock()
        if invalidated {
            IMELog.write("rime schema cache invalidated reason=deployment")
        }
    }

    var schemaListCacheDiagnostics: RimeFileBackedCacheDiagnostics {
        schemaListCacheLock.lock()
        defer { schemaListCacheLock.unlock() }
        return schemaListCache.diagnostics
    }

    private func loadSchemaList() -> [(id: String, name: String)] {
        var buf = [BBRimeSchema](repeating: BBRimeSchema(), count: 64)
        let count = Int(BBRimeGetSchemaList(&buf, 64))
        guard count > 0 else { return [] }
        return (0..<count).compactMap { i in
            guard let idPtr = buf[i].id else { return nil }
            let id = String(cString: idPtr)
            guard !id.isEmpty else { return nil }
            let name = buf[i].name.map { String(cString: $0) } ?? id
            return (id, name.isEmpty ? id : name)
        }
    }

    private func schemaListWatchURLs(
        for schemas: [(id: String, name: String)]
    ) -> [URL] {
        let build = URL(fileURLWithPath: userDataDir, isDirectory: true)
            .appendingPathComponent("build", isDirectory: true)
        var urls = [build, build.appendingPathComponent("default.yaml")]
        var seen = Set(urls.map { $0.standardizedFileURL.path })
        for schema in schemas {
            let url = build.appendingPathComponent("\(schema.id).schema.yaml")
            if seen.insert(url.standardizedFileURL.path).inserted {
                urls.append(url)
            }
        }
        return urls
    }

    private func schemaListSnapshotWatchURLs() -> [URL] {
        let build = URL(fileURLWithPath: userDataDir, isDirectory: true)
            .appendingPathComponent("build", isDirectory: true)
        let schemaURLs = (try? FileManager.default.contentsOfDirectory(
            at: build,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ))?.filter {
            $0.lastPathComponent.hasSuffix(".schema.yaml")
        }.sorted {
            $0.lastPathComponent < $1.lastPathComponent
        } ?? []
        return [build, build.appendingPathComponent("default.yaml")] + schemaURLs
    }

    // MARK: User dictionary maintenance

    /// True when librime currently has a LevelDB for this `user_dict` name.
    /// Listing does not open or mutate the database and is safe while typing.
    func hasUserDictionary(named name: String) -> Bool {
        guard started, !name.isEmpty else { return false }
        return name.withCString { BBRimeHasUserDictionary($0) }
    }

    /// Export learned entries in librime's portable TSV format. This operation
    /// necessarily closes every Rime session so the LevelDB can be opened by
    /// the official levers manager. Call only on main: notification observers
    /// must first settle IMK marked text and invalidate their cached sessions.
    func exportUserDictionary(named name: String, to fileURL: URL) -> Int {
        performUserDictionaryMaintenance {
            name.withCString { dict in
                fileURL.path.withCString { path in
                    Int(BBRimeExportUserDictionary(dict, path))
                }
            }
        }
    }

    /// Merge portable TSV entries into the selected librime user dictionary.
    /// Existing frequencies are preserved/raised according to librime's own
    /// UserDbImporter rules; the LevelDB is never copied or replaced.
    func importUserDictionary(named name: String, from fileURL: URL) -> Int {
        performUserDictionaryMaintenance {
            name.withCString { dict in
                fileURL.path.withCString { path in
                    Int(BBRimeImportUserDictionary(dict, path))
                }
            }
        }
    }

    /// Merge a lossless `*.userdb.txt` snapshot. The snapshot itself declares
    /// its database name; UserLexiconService validates it before this call.
    func restoreUserDictionarySnapshot(from fileURL: URL) -> Bool {
        performUserDictionaryMaintenance {
            fileURL.path.withCString { path in
                BBRimeRestoreUserDictionarySnapshot(path) ? 0 : -1
            }
        } >= 0
    }

    private func performUserDictionaryMaintenance(_ operation: () -> Int) -> Int {
        guard Thread.isMainThread, started else { return -1 }
        NotificationCenter.default.post(name: .rimeUserDictionaryMaintenanceWillBegin,
                                        object: self)
        let result = operation()
        NotificationCenter.default.post(name: .rimeUserDictionaryMaintenanceDidEnd,
                                        object: self,
                                        userInfo: ["succeeded": result >= 0])
        return result
    }

    // MARK: Context / status

    func getContext(session: UInt64) -> RimeContextModel {
        var ctx = BBRimeContext()
        guard BBRimeGetContext(session, &ctx) else { return RimeContextModel() }

        var model = RimeContextModel()
        model.active = ctx.active
        model.preedit = ctx.preedit.map { String(cString: $0) } ?? ""
        model.input = ctx.input.map { String(cString: $0) } ?? ""
        model.cursorPos = Int(ctx.cursorPos)
        model.selStart = Int(ctx.selStart)
        model.selEnd = Int(ctx.selEnd)
        model.pageSize = Int(ctx.pageSize)
        model.pageNo = Int(ctx.pageNo)
        model.isLastPage = ctx.isLastPage
        model.highlightedIndex = Int(ctx.highlightedIndex)

        let count = Int(ctx.numCandidates)
        if count > 0 {
            let cap = Int(BB_MAX_CANDIDATES)
            withUnsafePointer(to: &ctx.candidates) { tuplePtr in
                tuplePtr.withMemoryRebound(to: BBRimeCandidate.self, capacity: cap) { arr in
                    for i in 0..<min(count, cap) {
                        let c = arr[i]
                        model.candidates.append(RimeCandidateModel(
                            text: c.text.map { String(cString: $0) } ?? "",
                            comment: c.comment.map { String(cString: $0) } ?? "",
                            label: c.label.map { String(cString: $0) } ?? ""))
                    }
                }
            }
        }
        return model
    }

    func getStatus(session: UInt64) -> RimeStatusModel {
        var st = BBRimeStatus()
        guard BBRimeGetStatus(session, &st) else { return RimeStatusModel() }
        var m = RimeStatusModel()
        m.schemaId = st.schemaId.map { String(cString: $0) } ?? ""
        m.schemaName = st.schemaName.map { String(cString: $0) } ?? ""
        m.asciiMode = st.asciiMode
        m.fullShape = st.fullShape
        m.simplified = st.simplified
        m.traditional = st.traditional
        m.asciiPunct = st.asciiPunct
        m.composing = st.composing
        m.disabled = st.disabled
        return m
    }

    private func takeString(_ pointer: UnsafeMutablePointer<CChar>?) -> String? {
        guard let pointer else { return nil }
        let value = String(cString: pointer)
        BBRimeFreeString(pointer)
        return value.isEmpty ? nil : value
    }
}
