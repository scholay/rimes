import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// What saving one Recent card into Capsule would create.
enum CapsuleRailSavePlan: Equatable {
    case note(title: String, text: String)
    /// A file the user already keeps on disk: an Image or PDF entry that
    /// points at it.
    case file(kind: CapsuleEntryKind, title: String, path: String)
    /// Image data with no file behind it. It is written into Capsule's
    /// content-addressed assets first, then saved as an Image entry.
    case imageData(title: String, data: Data, fileExtension: String)
    case unsupported(UnsupportedReason)

    enum UnsupportedReason: Equatable {
        /// Colors and unrecognised pasteboard types have no Capsule kind.
        case kind
        /// A file that is neither an image nor a PDF.
        case fileType
        case tooLarge
        case noContent
    }
}

enum CapsuleRailSaveOutcome: Equatable {
    case saved(CapsuleEntryKind, UUID)
    /// An entry with the same text, or pointing at the same file, already
    /// exists, so nothing new was written.
    case alreadySaved(CapsuleEntryKind, UUID)
    case unsupported(CapsuleRailSavePlan.UnsupportedReason)
    case failed
}

enum CapsuleRailSaveRules {
    static let maximumTitleCharacters = 60
    static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "heic", "webp", "tif", "tiff", "gif", "bmp",
    ]

    /// Kinds that can become a Capsule entry: text and links as notes,
    /// images and image or PDF files as media.
    static func isSaveable(_ kind: ClipboardItemKind) -> Bool {
        switch kind {
        case .text, .link, .image, .files: return true
        case .color, .unknown: return false
        }
    }

    /// The first non-empty line with its whitespace collapsed, bounded so a
    /// pasted paragraph does not become the title.
    static func title(fromText text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline)
            .map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            .first { !$0.isEmpty } ?? ""
        guard line.count > maximumTitleCharacters else { return line }
        return String(line.prefix(maximumTitleCharacters)) + "…"
    }

    static func imageTitle(capturedAt: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return "图片 " + formatter.string(from: capturedAt)
    }

    /// One plan per thing the card holds; a card of several files yields one
    /// plan per file. Decoding may re-encode an image, so call this off the
    /// main thread.
    static func plans(kind: ClipboardItemKind,
                      completeText: String?,
                      capturedAt: Date,
                      archive: ClipboardPasteboardArchive) -> [CapsuleRailSavePlan] {
        switch kind {
        case .text, .link:
            guard let text = completeText ?? plainText(in: archive),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return [.unsupported(.noContent)]
            }
            guard text.count <= CapsuleContentStore.maximumContentCharacters else {
                return [.unsupported(.tooLarge)]
            }
            return [.note(title: title(fromText: text), text: text)]
        case .image:
            guard let (data, fileExtension) = imageData(in: archive) else {
                return [.unsupported(.noContent)]
            }
            guard data.count <= CapsuleMediaPreviewLoader.maximumImageBytes else {
                return [.unsupported(.tooLarge)]
            }
            return [.imageData(
                title: imageTitle(capturedAt: capturedAt),
                data: data,
                fileExtension: fileExtension
            )]
        case .files:
            let urls = fileURLs(in: archive)
            guard !urls.isEmpty else { return [.unsupported(.noContent)] }
            return urls.map { url in
                let ext = url.pathExtension.lowercased()
                if ext == "pdf" {
                    return .file(kind: .pdf, title: url.lastPathComponent, path: url.path)
                }
                if imageExtensions.contains(ext) {
                    return .file(kind: .image, title: url.lastPathComponent, path: url.path)
                }
                return .unsupported(.fileType)
            }
        case .color, .unknown:
            return [.unsupported(.kind)]
        }
    }

    static func plainText(in archive: ClipboardPasteboardArchive) -> String? {
        for item in archive.items {
            for type in ["public.utf8-plain-text", "public.plain-text", "public.url"] {
                if let data = item.dataByType[type],
                   let text = String(data: data, encoding: .utf8) {
                    return text
                }
            }
            if let data = item.dataByType["public.utf16-plain-text"],
               let text = String(data: data, encoding: .utf16) {
                return text
            }
        }
        return nil
    }

    private static let storedImageTypes: [(type: String, fileExtension: String)] = [
        ("public.png", "png"),
        ("public.jpeg", "jpg"),
        ("public.heic", "heic"),
        ("public.tiff", "tiff"),
        ("com.compuserve.gif", "gif"),
        ("org.webmproject.webp", "webp"),
        ("public.webp", "webp"),
        ("com.microsoft.bmp", "bmp"),
    ]

    /// The image as stored, when its format is one Capsule accepts, otherwise
    /// re-encoded as PNG.
    static func imageData(in archive: ClipboardPasteboardArchive) -> (Data, String)? {
        for (type, fileExtension) in storedImageTypes {
            for item in archive.items {
                if let data = item.dataByType[type], !data.isEmpty {
                    return (data, fileExtension)
                }
            }
        }
        for item in archive.items {
            for type in item.types
                where ClipboardPasteboardArchive.isImageRepresentationType(type) {
                guard let data = item.dataByType[type],
                      let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
                else { continue }
                let output = NSMutableData()
                guard let destination = CGImageDestinationCreateWithData(
                    output,
                    UTType.png.identifier as CFString,
                    1,
                    nil
                ) else { continue }
                CGImageDestinationAddImage(destination, image, nil)
                if CGImageDestinationFinalize(destination) {
                    return (output as Data, "png")
                }
            }
        }
        return nil
    }

    static func fileURLs(in archive: ClipboardPasteboardArchive) -> [URL] {
        archive.items.compactMap { item in
            guard let data = item.dataByType["public.file-url"],
                  let string = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(
                        in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0"))
                    ),
                  let url = URL(string: string),
                  url.isFileURL else { return nil }
            return url.standardizedFileURL
        }
    }

    static func toast(for outcomes: [CapsuleRailSaveOutcome]) -> String {
        var saved: [CapsuleEntryKind] = []
        var alreadySaved = 0
        var failed = 0
        for outcome in outcomes {
            switch outcome {
            case let .saved(kind, _): saved.append(kind)
            case .alreadySaved: alreadySaved += 1
            case .failed: failed += 1
            case .unsupported: break
            }
        }
        if saved.count == 1, saved.count == outcomes.count {
            return "已收入 Capsule · \(saved[0].tabLabel)"
        }
        if !saved.isEmpty { return "已收入 Capsule · \(saved.count) 条" }
        if alreadySaved > 0 { return "已在 Capsule 中" }
        if failed > 0 { return "收入 Capsule 失败" }
        return "此类型暂不能收入 Capsule"
    }
}

/// Writes rail saves into the Capsule stores. Runs off the main thread; the
/// repository publishes the store change, which also wakes iCloud sync.
struct CapsuleRailSaver {
    let contentStore: CapsuleContentStore
    let repository: CapsuleWindowRepository
    let assetsURL: URL

    static func live() -> CapsuleRailSaver {
        CapsuleRailSaver(
            contentStore: .shared,
            repository: CapsuleWindowRepository(),
            assetsURL: CapsulePasswordStore.defaultRootURL()
                .appendingPathComponent("assets", isDirectory: true)
        )
    }

    /// Each plan is checked against the store first, so saving the same card
    /// twice finds the entry it already made instead of duplicating it.
    func save(_ plans: [CapsuleRailSavePlan]) -> [CapsuleRailSaveOutcome] {
        var records: [CapsuleContentRecord]?
        var outcomes: [CapsuleRailSaveOutcome] = []
        for plan in plans {
            do {
                if records == nil { records = try contentStore.listRecords() }
                let existing = records ?? []
                let outcome: CapsuleRailSaveOutcome
                switch plan {
                case let .unsupported(reason):
                    outcome = .unsupported(reason)
                case let .note(title, text):
                    if let match = existing.first(where: {
                        $0.summary.type == .note && $0.content == text
                    }) {
                        outcome = .alreadySaved(.note, match.summary.id)
                    } else {
                        let row = try repository.save(CapsuleWindowDraft(
                            kind: .note,
                            title: title,
                            content: text
                        ))
                        outcome = .saved(.note, row.id)
                    }
                case let .file(kind, title, path):
                    outcome = try saveFile(kind: kind, title: title, path: path, existing: existing)
                case let .imageData(title, data, fileExtension):
                    let path = try writeAsset(data, fileExtension: fileExtension)
                    outcome = try saveFile(kind: .image, title: title, path: path, existing: existing)
                }
                if case .saved = outcome { records = nil }
                outcomes.append(outcome)
            } catch {
                IMELog.write("capsule rail save failed: \(error.localizedDescription)")
                outcomes.append(.failed)
            }
        }
        return outcomes
    }

    private func saveFile(kind: CapsuleEntryKind,
                          title: String,
                          path: String,
                          existing: [CapsuleContentRecord]) throws -> CapsuleRailSaveOutcome {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        if let match = existing.first(where: {
            $0.summary.type == kind
                && URL(fileURLWithPath: $0.content).standardizedFileURL.path == standardized
        }) {
            return .alreadySaved(kind, match.summary.id)
        }
        let row = try repository.save(CapsuleWindowDraft(
            kind: kind,
            title: title,
            content: standardized
        ))
        return .saved(kind, row.id)
    }

    /// Stores image data under its SHA-256, the same naming Capsule's iCloud
    /// mirror uses for media, so the same image is only ever written once.
    func writeAsset(_ data: Data, fileExtension: String) throws -> String {
        let name = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined() + "." + fileExtension
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: assetsURL.path) {
            try fileManager.createDirectory(
                at: assetsURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        let url = assetsURL.appendingPathComponent(name)
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        if values?.isSymbolicLink == true {
            throw CapsuleFilePasteboardError.unavailableFile
        }
        if values?.isRegularFile != true {
            try data.write(to: url, options: [.atomic])
            _ = chmod(url.path, mode_t(0o600))
        }
        return url.path
    }
}

/// Remembers which Recent cards were saved into which entries, so the rail
/// can mark them. Only ids are kept, never content.
final class CapsuleRailSavedIndex {
    private static let defaultsKey = "capsuleRail.savedHistoryEntries.v1"
    private static let limit = 2_000

    private let defaults: UserDefaults?
    /// Oldest first, so the limit drops the oldest saves.
    private var pairs: [(history: UUID, entry: UUID)]

    init(defaults: UserDefaults?) {
        self.defaults = defaults
        let stored = defaults?.array(forKey: Self.defaultsKey) as? [[String]] ?? []
        pairs = stored.compactMap { pair in
            guard pair.count == 2,
                  let history = UUID(uuidString: pair[0]),
                  let entry = UUID(uuidString: pair[1]) else { return nil }
            return (history, entry)
        }
    }

    func entryID(forHistoryItem id: UUID) -> UUID? {
        pairs.last { $0.history == id }?.entry
    }

    func record(historyItem: UUID, entry: UUID) {
        pairs.removeAll { $0.history == historyItem }
        pairs.append((historyItem, entry))
        if pairs.count > Self.limit {
            pairs.removeFirst(pairs.count - Self.limit)
        }
        persist()
    }

    /// Forgets saves whose entry no longer exists.
    func prune(keeping entryIDs: Set<UUID>) {
        let before = pairs.count
        pairs.removeAll { !entryIDs.contains($0.entry) }
        if pairs.count != before { persist() }
    }

    private func persist() {
        defaults?.set(
            pairs.map { [$0.history.uuidString, $0.entry.uuidString] },
            forKey: Self.defaultsKey
        )
    }
}
