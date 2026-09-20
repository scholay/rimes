import AppKit
import CryptoKit
import Foundation
import GRDB
import ImageIO
import UniformTypeIdentifiers
import AVFoundation

extension Notification.Name {
    static let capsuleCapturesDidChange = Notification.Name("RIMES.CapsuleCapturesDidChange")
}

enum CaptureKind: String, Codable, CaseIterable {
    case image, scrolling, video, gif
    var label: String {
        switch self { case .image: return "截图"; case .scrolling: return "长截图"
        case .video: return "录屏"; case .gif: return "GIF" }
    }
    var capsuleKind: CapsuleEntryKind { self == .video || self == .gif ? .video : .image }
}

struct CaptureRecord: Codable, Equatable, Identifiable {
    var id: UUID
    var title: String
    var kind: CaptureKind
    var createdAt: Date
    var source: String
    var original: String
    var output: String
    var project: String?
    var text: String
    var width: Int
    var height: Int
    var duration: Double
    var collectionID: UUID?
    var incomplete: Bool
    var thumbnail: String? = nil
}

enum CaptureError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(s) = self { return s }; return nil }
}

/// The database contains metadata only. File transactions are serialized;
/// the independent lease lock lets the UI retain assets without waiting on I/O.
final class CaptureStore: @unchecked Sendable {
    static let shared: Result<CaptureStore, Error> = Result { try CaptureStore() }
    static let retention: TimeInterval = 30 * 24 * 3600
    static let capacity: Int64 = 10 * 1024 * 1024 * 1024
    let root: URL
    private let db: DatabaseQueue
    private let queue = DispatchQueue(label: "RIMES.Capture.store", qos: .utility)
    private var leases: [UUID: Int] = [:]
    private let leaseLock = NSLock()
    private var retiring = Set<UUID>()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(root: URL = CapsulePasswordStore.defaultRootURL().appendingPathComponent("captures")) throws {
        self.root = root
        try Self.ensureDirectory(root)
        let database = root.appendingPathComponent("captures.sqlite")
        db = try DatabaseQueue(path: database.path)
        try db.write { db in
            try db.execute(sql: "CREATE TABLE IF NOT EXISTS captures (id TEXT PRIMARY KEY, created REAL NOT NULL, record BLOB NOT NULL)")
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: database.path)
    }

    func directory(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
    func url(_ record: CaptureRecord, original: Bool = false) -> URL {
        directory(record.id).appendingPathComponent(original ? record.original : record.output)
    }
    func previewURL(_ record: CaptureRecord) -> URL { record.thumbnail.map { directory(record.id).appendingPathComponent($0) } ?? url(record) }
    @discardableResult func acquire(_ id: UUID) -> Bool {
        leaseLock.withLock { guard !retiring.contains(id) else { return false }; leases[id, default: 0] += 1; return true }
    }
    func release(_ id: UUID) { leaseLock.withLock { leases[id] = max(0, (leases[id] ?? 0) - 1) } }
    private func isLeased(_ id: UUID) -> Bool { leaseLock.withLock { (leases[id] ?? 0) > 0 } }

    func records() throws -> [CaptureRecord] { try queue.sync { try load() } }
    private func load() throws -> [CaptureRecord] {
        try db.read { db in try Data.fetchAll(db, sql: "SELECT record FROM captures ORDER BY created DESC") }
            .map(decodeRecord)
    }
    private func decodeRecord(_ data: Data) throws -> CaptureRecord {
        let r = try decoder.decode(CaptureRecord.self, from: data)
        for name in [r.original, r.output] + [r.project, r.thumbnail].compactMap({ $0 }) {
            guard !name.isEmpty, name == URL(fileURLWithPath: name).lastPathComponent, !name.contains("..") else { throw CaptureError.message("捕获索引包含无效路径") }
        }
        return r
    }
    func record(_ id: UUID) throws -> CaptureRecord {
        try queue.sync {
            guard let data = try db.read({ try Data.fetchOne($0, sql: "SELECT record FROM captures WHERE id=?", arguments: [id.uuidString]) }) else { throw CaptureError.message("捕获记录已移除") }
            return try decodeRecord(data)
        }
    }

    private func write(_ r: CaptureRecord) throws {
        let data = try encoder.encode(r)
        // The per-asset manifest is the recovery journal. All media already
        // exists before this atomic manifest and the index become visible.
        try data.write(to: directory(r.id).appendingPathComponent("record.json"), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: directory(r.id).appendingPathComponent("record.json").path)
        try db.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO captures(id,created,record) VALUES(?,?,?)",
                           arguments: [r.id.uuidString, r.createdAt.timeIntervalSince1970, data])
        }
    }

    func importProject(_ file: URL, title: String? = nil, collectionID: UUID? = nil) throws -> CaptureRecord {
        let id = UUID()
        // Use the asset identity for the transaction directory as well.
        let destination = directory(id)
        try Self.ensureDirectory(destination)
        do {
            let document = try CaptureProjectPackage.restore(file, directory: destination)
            guard let first = document.layers.first else { throw CaptureError.message("工程没有图片") }
            let output = "render-\(UUID().uuidString).png", project = "project-\(UUID().uuidString).json"
            let image = try CaptureRenderer.render(document, directory: destination)
            try CaptureImageIO.write(image, to: destination.appendingPathComponent(output))
            try JSONEncoder().encode(document).write(to: destination.appendingPathComponent(project), options: .atomic)
            try CaptureProjectPackage.write(document: document, directory: destination, output: destination.appendingPathComponent(output + ".rimesproject"))
            var record = CaptureRecord(id: id, title: title ?? file.deletingPathExtension().lastPathComponent, kind: .image, createdAt: Date(), source: "工程导入", original: first.file, output: output, project: project, text: "", width: image.width, height: image.height, duration: 0, collectionID: collectionID, incomplete: false)
            record.thumbnail = try Self.makeThumbnail(source: url(record), kind: .image, directory: destination)
            try queue.sync { try write(record) }; changed(); return record
        } catch { try? FileManager.default.removeItem(at: destination); throw error }
    }
    private func changed() {
        DispatchQueue.main.async { NotificationCenter.default.post(name: .capsuleCapturesDidChange, object: nil) }
    }
    func update(_ r: CaptureRecord) throws {
        try queue.sync { try write(r) }
        changed()
    }

    @discardableResult
    func importFile(_ file: URL, kind: CaptureKind, title: String? = nil, source: String = "",
                    width: Int = 0, height: Int = 0, duration: Double = 0, incomplete: Bool = false, moveSource: Bool = false) throws -> CaptureRecord {
        let id = UUID()
        let folder = directory(id)
        try Self.ensureDirectory(folder)
        let name = "original." + file.pathExtension.lowercased()
        let destination = folder.appendingPathComponent(name)
        do {
            if moveSource { try FileManager.default.moveItem(at: file, to: destination) }
            else { try FileManager.default.copyItem(at: file, to: destination) }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            var record = CaptureRecord(id: id, title: title ?? "\(kind.label) \(Date().formatted(date: .numeric, time: .shortened))",
                kind: kind, createdAt: Date(), source: source, original: name, output: name, project: nil, text: "",
                width: width, height: height, duration: duration, collectionID: nil, incomplete: incomplete)
            record.thumbnail = try? Self.makeThumbnail(source: destination, kind: kind, directory: folder)
            try queue.sync { try write(record) }
            changed()
            return record
        } catch {
            if moveSource, FileManager.default.fileExists(atPath: destination.path) { try? FileManager.default.moveItem(at: destination, to: file) }
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    static func makeThumbnail(source: URL, kind: CaptureKind, directory: URL) throws -> String {
        let image: CGImage
        if kind == .video {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: source)); generator.appliesPreferredTrackTransform = true; generator.maximumSize = CGSize(width: 512, height: 512)
            image = try generator.copyCGImage(at: .zero, actualTime: nil)
        } else { image = try CaptureImageIO.read(source, maximum: 512) }
        let name = "thumbnail-\(UUID().uuidString).png"
        try CaptureImageIO.write(image, to: directory.appendingPathComponent(name)); return name
    }

    func importImage(_ image: CGImage, kind: CaptureKind = .image, source: String = "", incomplete: Bool = false) throws -> CaptureRecord {
        let temporary = root.appendingPathComponent(UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try CaptureImageIO.write(image, to: temporary)
        return try importFile(temporary, kind: kind, source: source, width: image.width, height: image.height, incomplete: incomplete)
    }

    /// Promotion is idempotent and keeps the capture's identity. Editing a
    /// saved record updates its existing entry rather than making duplicates.
    func collect(_ id: UUID) throws -> CaptureRecord {
        try queue.sync {
            guard var r = try load().first(where: { $0.id == id }) else { throw CaptureError.message("未找到捕获") }
            let libraryRoot = root.deletingLastPathComponent()
            let content = CapsuleContentStore(rootURL: libraryRoot)
            let repo = CapsuleWindowRepository(contentStore: content, passwordStore: CapsulePasswordStore(rootURL: libraryRoot))
            if r.collectionID == nil {
                r.collectionID = try content.listRecords().first { $0.summary.type == r.kind.capsuleKind && URL(fileURLWithPath: $0.content).deletingLastPathComponent().standardizedFileURL == directory(id).standardizedFileURL }?.summary.id
            }
            var draft = CapsuleWindowDraft(kind: r.kind.capsuleKind, title: r.title, content: url(r).path)
            if let savedID = r.collectionID,
               let row = try repo.list(kind: r.kind.capsuleKind).first(where: { $0.id == savedID }) {
                draft = try repo.draft(for: row)
                draft.content = url(r).path
                r.title = draft.title
            }
            let row = try repo.save(draft)
            r.collectionID = row.id
            try write(r)
            changed()
            return r
        }
    }

    func remove(_ id: UUID) throws {
        try queue.sync {
            guard !isLeased(id) else { throw CaptureError.message("此内容正在使用，请关闭编辑器或贴图后重试") }
            guard let r = try load().first(where: { $0.id == id }) else { return }
            guard r.collectionID == nil else { throw CaptureError.message("已收藏内容请在 Capsule 管理中处理") }
            try retire(id)
            changed()
        }
    }

    @discardableResult
    func prune(now: Date = Date(), retention: TimeInterval = CaptureStore.retention,
               capacity: Int64 = CaptureStore.capacity) throws -> Int {
        try queue.sync {
            let library = try CapsuleContentStore(rootURL: root.deletingLastPathComponent()).listRecords()
            let liveIDs = Set(library.map { $0.summary.id })
            let referencedDirectories = Set(library.filter { $0.summary.type.storesLocalPath }.map { URL(fileURLWithPath: $0.content).deletingLastPathComponent().path })
            var current = try load()
            for i in current.indices {
                if let id = current[i].collectionID, !liveIDs.contains(id) { current[i].collectionID = nil; try write(current[i]) }
            }
            let records = current.reversed()
            var sizes: [UUID: Int64] = [:]
            for r in records { sizes[r.id] = Self.bytes(in: directory(r.id)) }
            // The cap applies to temporary history, not permanent collections.
            var total = records.filter { $0.collectionID == nil }.reduce(Int64(0)) { $0 + (sizes[$1.id] ?? 0) }
            var removed = 0
            for r in records where r.collectionID == nil && !isLeased(r.id) && !referencedDirectories.contains(directory(r.id).path) {
                guard now.timeIntervalSince(r.createdAt) > retention || total > capacity else { continue }
                try retire(r.id)
                total -= sizes[r.id] ?? 0
                removed += 1
            }
            if removed > 0 { changed() }
            return removed
        }
    }

    private func retire(_ id: UUID) throws {
        try leaseLock.withLock {
            guard (leases[id] ?? 0) == 0 else { throw CaptureError.message("资产正在使用，稍后再清理") }
            retiring.insert(id)
        }
        defer { _ = leaseLock.withLock { retiring.remove(id) } }
        let original = directory(id), removed = root.appendingPathComponent(".removed-" + id.uuidString)
        let exists = FileManager.default.fileExists(atPath: original.path)
        if exists { try FileManager.default.moveItem(at: original, to: removed) }
        do { try db.write { try $0.execute(sql: "DELETE FROM captures WHERE id=?", arguments: [id.uuidString]) } }
        catch { if exists { try? FileManager.default.moveItem(at: removed, to: original) }; throw error }
        if exists { try? FileManager.default.removeItem(at: removed) }
    }

    /// Called once at application startup, before any new recording starts.
    /// Valid unfinished recordings become visible recovery cards. Unplayable
    /// files remain on disk for manual recovery, never silently discarded.
    func recoverInterruptedRecordings() throws -> Int {
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isRegularFileKey])
        var recovered = 0
        // Reconcile a crash between manifest replacement and SQLite commit.
        try queue.sync {
            for folder in files {
                if folder.lastPathComponent.hasPrefix(".removed-"), let id = UUID(uuidString: String(folder.lastPathComponent.dropFirst(9))) {
                    try db.write { try $0.execute(sql: "DELETE FROM captures WHERE id=?", arguments: [id.uuidString]) }
                    try? FileManager.default.removeItem(at: folder)
                    continue
                }
                guard let id = UUID(uuidString: folder.lastPathComponent),
                      let data = try? Data(contentsOf: folder.appendingPathComponent("record.json")),
                      let record = try? decoder.decode(CaptureRecord.self, from: data), record.id == id,
                      [record.original, record.output].allSatisfy({ $0 == URL(fileURLWithPath: $0).lastPathComponent && !$0.contains("..") }),
                      FileManager.default.fileExists(atPath: url(record).path) else { continue }
                try db.write { try $0.execute(sql: "INSERT OR REPLACE INTO captures(id,created,record) VALUES(?,?,?)", arguments: [id.uuidString, record.createdAt.timeIntervalSince1970, data]) }
            }
        }
        for file in files where file.lastPathComponent.hasPrefix("recording-") && file.pathExtension == "mp4" {
            guard (try file.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else { continue }
            let asset = AVURLAsset(url: file)
            guard !asset.tracks(withMediaType: .video).isEmpty else { continue }
            _ = try importFile(file, kind: .video, title: "恢复的录屏", duration: max(0, CMTimeGetSeconds(asset.duration)), incomplete: true)
            try FileManager.default.removeItem(at: file)
            recovered += 1
        }
        return recovered
    }

    static func ensureDirectory(_ url: URL) throws {
        var info = stat()
        if lstat(url.path, &info) == 0 {
            guard (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == getuid() else {
                throw CaptureError.message("捕获目录必须是当前用户的普通目录")
            }
        } else {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    static func bytes(in url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey], options: [.skipsHiddenFiles]) else { return 0 }
        return enumerator.compactMap { $0 as? URL }.reduce(0) {
            let v = try? $1.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            return $0 + (v?.isRegularFile == true ? Int64(v?.fileSize ?? 0) : 0)
        }
    }
}

enum CaptureImageIO {
    static func read(_ url: URL, maximum: Int = 32768) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, Int64(width) * Int64(height) <= 128_000_000,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maximum,
              ] as CFDictionary) else { throw CaptureError.message("无法读取图片，或图片超过 1.28 亿像素") }
        return image
    }
    static func write(_ image: CGImage, to url: URL, jpeg: Bool = false) throws {
        let temp = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temp) }
        guard let destination = CGImageDestinationCreateWithURL(temp as CFURL, (jpeg ? UTType.jpeg.identifier : UTType.png.identifier) as CFString, 1, nil) else { throw CaptureError.message("无法创建图片") }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CaptureError.message("图片写入失败") }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temp.path)
        if FileManager.default.fileExists(atPath: url.path) { _ = try FileManager.default.replaceItemAt(url, withItemAt: temp) }
        else { try FileManager.default.moveItem(at: temp, to: url) }
    }
}
