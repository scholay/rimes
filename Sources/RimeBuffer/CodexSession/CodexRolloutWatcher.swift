import Foundation

/// Follows the rollout a spawned codex session is writing.
///
/// The left pane is the real CLI in a real terminal, so nothing can be learned
/// from it but pixels: codex draws a full-screen TUI that repaints, and a
/// screen is not a transcript. The rollout is the same run in semantic form,
/// which is what makes a second pane possible at all.
final class CodexRolloutWatcher {
    struct Location: Equatable {
        let url: URL
        let header: CodexSessionHeader
    }

    static let sessionsRoot = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(".codex/sessions", isDirectory: true)

    private let fileManager: FileManager
    private let root: URL
    private var handle: FileHandle?
    private var pending = Data()
    private var timer: Timer?
    private(set) var location: Location?

    var onEvents: (([CodexRolloutEvent]) -> Void)?
    var onLocated: ((Location) -> Void)?

    init(root: URL = CodexRolloutWatcher.sessionsRoot,
         fileManager: FileManager = .default) {
        self.root = root
        self.fileManager = fileManager
    }

    deinit { stop() }

    /// A spawned session cannot be named in advance: codex chooses the file.
    /// Identify it by its own header — the newest rollout whose recorded `cwd`
    /// is the workspace we launched into and which appeared after we launched.
    /// Matching on the filename's timestamp alone would attach to a session
    /// started by hand in another window a second earlier.
    static func locateSession(workspace: URL,
                              launchedAfter: Date,
                              root: URL = CodexRolloutWatcher.sessionsRoot,
                              fileManager: FileManager = .default) -> Location? {
        let wanted = workspace.standardizedFileURL.path
        guard let walker = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey]
        ) else { return nil }
        var best: (Location, Date)?
        for case let url as URL in walker where url.pathExtension == "jsonl" {
            guard let values = try? url.resourceValues(
                forKeys: [.contentModificationDateKey, .isRegularFileKey]
            ), values.isRegularFile == true,
               let modified = values.contentModificationDate,
               modified >= launchedAfter.addingTimeInterval(-2) else { continue }
            guard let header = firstHeader(at: url, fileManager: fileManager),
                  let cwd = header.cwd,
                  URL(fileURLWithPath: cwd).standardizedFileURL.path == wanted
            else { continue }
            if best == nil || modified > best!.1 {
                best = (Location(url: url, header: header), modified)
            }
        }
        return best?.0
    }

    private static func firstHeader(at url: URL,
                                    fileManager: FileManager) -> CodexSessionHeader? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        // The header is the first record; reading a bounded prefix keeps this
        // cheap even when the directory holds hundreds of long sessions.
        guard let chunk = try? handle.read(upToCount: 64 * 1024),
              let newline = chunk.firstIndex(of: 0x0a) else { return nil }
        return CodexRolloutParser.header(from: chunk[chunk.startIndex..<newline])
    }

    /// Polls rather than using FSEvents: a rollout is append-only and a
    /// quarter-second cadence is imperceptible next to model latency, while
    /// FSEvents coalescing would need the same tail-read anyway.
    func start(workspace: URL, launchedAfter: Date, interval: TimeInterval = 0.25) {
        stop()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.poll(workspace: workspace, launchedAfter: launchedAfter)
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        try? handle?.close()
        handle = nil
        pending.removeAll()
    }

    private func poll(workspace: URL, launchedAfter: Date) {
        if location == nil {
            guard let found = Self.locateSession(workspace: workspace,
                                                 launchedAfter: launchedAfter,
                                                 root: root,
                                                 fileManager: fileManager)
            else { return }
            location = found
            handle = try? FileHandle(forReadingFrom: found.url)
            onLocated?(found)
        }
        guard let handle else { return }
        guard let chunk = try? handle.readToEnd(), !chunk.isEmpty else { return }
        pending.append(chunk)
        let events = Self.drain(&pending)
        if !events.isEmpty { onEvents?(events) }
    }

    /// Splits complete lines out of the buffer, leaving a partial trailing
    /// line for the next read. A rollout is appended to while it is read, so
    /// a chunk boundary lands mid-record routinely.
    static func drain(_ buffer: inout Data) -> [CodexRolloutEvent] {
        var events: [CodexRolloutEvent] = []
        while let newline = buffer.firstIndex(of: 0x0a) {
            let line = buffer[buffer.startIndex..<newline]
            buffer = buffer[buffer.index(after: newline)...]
            guard !line.isEmpty else { continue }
            if let event = CodexRolloutParser.event(from: Data(line)) {
                events.append(event)
            }
        }
        buffer = Data(buffer)
        return events
    }
}

/// Where a session should run. Codex is workspace-bound — its sandbox, its
/// file edits and its rollout `cwd` all follow the launch directory — so this
/// must be a real project root, never a transient one.
enum CodexSessionWorkspaceRules {
    static let lastWorkspaceKey = "codexSession.lastWorkspace.v1"

    static func preferredWorkspace(
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) -> URL {
        if let stored = defaults.string(forKey: lastWorkspaceKey),
           !stored.isEmpty {
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: stored, isDirectory: &isDirectory),
               isDirectory.boolValue {
                return URL(fileURLWithPath: stored, isDirectory: true)
            }
        }
        return fileManager.homeDirectoryForCurrentUser
    }

    static func remember(_ workspace: URL,
                         defaults: UserDefaults = .standard) {
        defaults.set(workspace.standardizedFileURL.path,
                     forKey: lastWorkspaceKey)
    }
}
