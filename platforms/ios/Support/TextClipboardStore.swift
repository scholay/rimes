import Foundation

/// Only explicitly collected text is saved. The keyboard's private sandbox owns it.
final class TextClipboardStore {
    struct Entry: Codable, Equatable, Identifiable { let id: UUID; let text: String }
    private struct Archive: Codable { let version: Int; let entries: [Entry] }
    enum Failure: Error { case invalidText, unsafeStorage }
    static let maximumEntries = 40, maximumEntryBytes = 16 * 1024, maximumBytes = 128 * 1024
    private let root: URL
    private var file: URL { root.appendingPathComponent("history-v1.json") }
    init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TextClipboard", isDirectory: true)
    }
    func load() -> [Entry] {
        guard safe(root), safe(file), let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= 1024 * 1024, let data = try? Data(contentsOf: file, options: .mappedIfSafe), data.count <= 1024 * 1024,
              let archive = try? JSONDecoder().decode(Archive.self, from: data), archive.version == 1,
              archive.entries.count <= Self.maximumEntries,
              Set(archive.entries.map(\.id)).count == archive.entries.count,
              Set(archive.entries.map { Data($0.text.utf8) }).count == archive.entries.count,
              archive.entries.allSatisfy({ Self.valid($0.text) }),
              archive.entries.reduce(0, { $0 + $1.text.utf8.count }) <= Self.maximumBytes else { return [] }
        return archive.entries
    }
    @discardableResult func collect(_ text: String) throws -> [Entry] {
        guard Self.valid(text) else { throw Failure.invalidText }
        var entries = load()
        let bytes = Data(text.utf8)
        let entry = entries.first(where: { Data($0.text.utf8) == bytes }) ?? Entry(id: UUID(), text: text)
        entries.removeAll { Data($0.text.utf8) == bytes }; entries.insert(entry, at: 0)
        while entries.count > Self.maximumEntries || entries.reduce(0, { $0 + $1.text.utf8.count }) > Self.maximumBytes { entries.removeLast() }
        try write(entries); return entries
    }
    @discardableResult func remove(_ id: UUID) throws -> [Entry] {
        let entries = load().filter { $0.id != id }; try write(entries); return entries
    }
    func clear() throws { try write([]) }
    private static func valid(_ text: String) -> Bool { !text.isEmpty && text.utf8.count <= maximumEntryBytes }
    private func safe(_ url: URL) -> Bool { (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true }
    private func write(_ entries: [Entry]) throws {
        guard safe(root), safe(file) else { throw Failure.unsafeStorage }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var directory = root; var values = URLResourceValues(); values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        try JSONEncoder().encode(Archive(version: 1, entries: entries)).write(to: file,
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
