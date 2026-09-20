import AppKit
import AVFoundation
import CoreGraphics
import CryptoKit
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

extension Notification.Name {
    static let capsuleStoreDidChange = Notification.Name(
        "CapsuleStoreDidChange"
    )
}

enum CapsuleWindowToggleAction: Equatable {
    case show
    case close
}

enum CapsuleWindowVisibilityRules {
    static func action(isVisible: Bool) -> CapsuleWindowToggleAction {
        isVisible ? .close : .show
    }

    /// Keep the shortcut/menu toggle on the same AppKit close route as the
    /// title-bar close button. `NSWindow.close()` skips `windowShouldClose(_:)`
    /// and would therefore discard a Capsule draft without confirmation.
    static func perform(
        _ action: CapsuleWindowToggleAction,
        show: () -> Void,
        performClose: () -> Void
    ) {
        switch action {
        case .show:
            show()
        case .close:
            performClose()
        }
    }
}

enum CapsuleWindowSelectionRules {
    /// A password row is never decrypted just because its type became visible.
    /// Only a user-selected row, or a refresh of that already-selected ID, may
    /// enter the password editor.
    static func allowsAutomaticFirstSelection(
        kind: CapsuleEntryKind
    ) -> Bool {
        kind != .password
    }
}

enum CapsuleWindowGeometry {
    static let defaultContentSize = NSSize(width: 940, height: 660)
    static let minimumContentSize = NSSize(width: 620, height: 430)
    static let screenInset: CGFloat = 12

    /// AppKit resets the root view's autoresizing mask when assigning a view
    /// controller. Keep this in one production helper so async-preview tests
    /// exercise the same resize isolation used by the shipped window.
    static func install(
        contentController: NSViewController,
        in window: NSWindow
    ) {
        window.contentViewController = contentController
        window.contentView?.autoresizingMask = []
    }

    static func constrainedFrame(
        _ proposedFrame: NSRect,
        visibleFrames: [NSRect],
        fallbackVisibleFrame: NSRect? = nil
    ) -> NSRect {
        let candidates = visibleFrames.filter { !$0.isEmpty }
        let intersectingFrame = candidates.max(by: {
            $0.intersection(proposedFrame).area
                < $1.intersection(proposedFrame).area
        }).flatMap {
            $0.intersection(proposedFrame).area > 0 ? $0 : nil
        }
        guard let visibleFrame = intersectingFrame
                ?? fallbackVisibleFrame
                ?? candidates.first,
              !visibleFrame.isEmpty else {
            return proposedFrame
        }

        let safeFrame = visibleFrame.insetBy(
            dx: min(screenInset, visibleFrame.width / 4),
            dy: min(screenInset, visibleFrame.height / 4)
        )
        guard !safeFrame.isEmpty else { return visibleFrame }

        var result = proposedFrame
        result.size.width = min(max(1, result.width), safeFrame.width)
        result.size.height = min(max(1, result.height), safeFrame.height)
        result.origin.x = min(
            max(result.minX, safeFrame.minX),
            safeFrame.maxX - result.width
        )
        result.origin.y = min(
            max(result.minY, safeFrame.minY),
            safeFrame.maxY - result.height
        )
        return result
    }
}

private extension NSRect {
    var area: CGFloat {
        guard !isNull, !isInfinite else { return 0 }
        return max(0, width) * max(0, height)
    }
}

struct CapsulePaneLayoutSnapshot {
    let rootFrame: NSRect
    let headerToToolbarGap: CGFloat
    let formTopGap: CGFloat
    let toolbarTop: CGFloat
    let editorTop: CGFloat
    let tabStripFrame: NSRect
    let listFrame: NSRect
    let editorFrame: NSRect
    let actionsFrame: NSRect
    let previewFrame: NSRect?
    let imagePreviewFrame: NSRect?
    let copyButtonFrame: NSRect?
    let titleRowHeight: CGFloat?
    let firstDetailRowHeight: CGFloat?
    let titleToFirstDetailGap: CGFloat?
    let bottomSpacerHeight: CGFloat?
    let horizontalContentFits: Bool
    let actionsAreVisible: Bool
    let previewFitsEditorWidth: Bool
    let imagePreviewFitsContainer: Bool
    let imagePreviewUsesAspectFit: Bool
    let formMatchesClipWidth: Bool
    let copyButtonIsVisible: Bool
    let hasAmbiguousLayout: Bool
}

enum CapsuleMediaPreviewResult {
    case image(CGImage)
    case pdf(image: CGImage, pageCount: Int)
    case unavailable
}

enum CapsuleFilePasteboardError: LocalizedError, Equatable {
    case unsupportedKind
    case invalidPath
    case unavailableFile
    case fileTooLarge
    case undecodableImage
    case pasteboardChanged
    case pasteboardWriteFailed

    var errorDescription: String? {
        switch self {
        case .unsupportedKind:
            return "该条目没有可复制的本机文件"
        case .invalidPath:
            return "请先选择有效的绝对路径"
        case .unavailableFile:
            return "文件或文件夹不存在、不受支持或使用了符号链接"
        case .fileTooLarge:
            return "图片过大，无法安全复制"
        case .undecodableImage:
            return "无法解码图片"
        case .pasteboardChanged:
            return "准备期间剪贴板已有新内容，未覆盖"
        case .pasteboardWriteFailed:
            return "无法写入系统剪贴板"
        }
    }
}

/// A prepared payload contains no live file handle and can be constructed away
/// from the main thread. The final AppKit pasteboard mutation remains explicit
/// and never synthesizes Command-V, Paste, a context menu, or an AX event.
struct CapsuleFilePasteboardPayload {
    let kind: CapsuleEntryKind
    let fileURL: URL
    let imagePNG: Data?
    let imageTIFF: Data?
    let originalImageType: NSPasteboard.PasteboardType?
    let originalImageData: Data?
}

enum CapsuleFilePasteboardWriter {
    static let maximumSourcePixelCount: UInt64 = 128_000_000
    static let maximumSourceDimension: UInt64 = 32_768
    static let maximumFallbackRepresentationDimension = 4_096

    static func prepare(
        kind: CapsuleEntryKind,
        path: String
    ) throws -> CapsuleFilePasteboardPayload {
        guard NSString(string: path).isAbsolutePath else {
            throw CapsuleFilePasteboardError.invalidPath
        }
        let url = URL(fileURLWithPath: path).standardizedFileURL

        switch kind {
        case .skill:
            var info = stat()
            guard lstat(url.path, &info) == 0,
                  (info.st_mode & S_IFMT) == S_IFDIR
                    || (info.st_mode & S_IFMT) == S_IFREG else {
                throw CapsuleFilePasteboardError.unavailableFile
            }
            return CapsuleFilePasteboardPayload(
                kind: kind,
                fileURL: url,
                imagePNG: nil,
                imageTIFF: nil,
                originalImageType: nil,
                originalImageData: nil
            )
        case .pdf, .video:
            try validateOrdinaryFile(url)
            return CapsuleFilePasteboardPayload(
                kind: kind,
                fileURL: url,
                imagePNG: nil,
                imageTIFF: nil,
                originalImageType: nil,
                originalImageData: nil
            )
        case .image:
            let data = try readImageData(url)
            guard let source = CGImageSourceCreateWithData(
                data as CFData,
                nil
            ) else {
                throw CapsuleFilePasteboardError.undecodableImage
            }
            guard sourceDimensionsAreSafe(source) else {
                throw CapsuleFilePasteboardError.fileTooLarge
            }
            guard let image = CGImageSourceCreateThumbnailAtIndex(
                source,
                0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceThumbnailMaxPixelSize:
                        maximumFallbackRepresentationDimension,
                ] as CFDictionary
            ) else {
                throw CapsuleFilePasteboardError.undecodableImage
            }
            let sourceType = CGImageSourceGetType(source) as String?
            let png = sourceType == UTType.png.identifier
                ? data
                : encode(image, as: UTType.png.identifier)
            let tiff = sourceType == UTType.tiff.identifier
                ? data
                : encode(image, as: UTType.tiff.identifier)
            guard let png, let tiff else {
                throw CapsuleFilePasteboardError.undecodableImage
            }
            return CapsuleFilePasteboardPayload(
                kind: kind,
                fileURL: url,
                imagePNG: png,
                imageTIFF: tiff,
                originalImageType: sourceType.map {
                    NSPasteboard.PasteboardType($0)
                },
                originalImageData: data
            )
        case .password, .note:
            throw CapsuleFilePasteboardError.unsupportedKind
        }
    }

    /// Build the complete pasteboard item before clearing the destination. A
    /// validation or decode failure therefore leaves the user's clipboard
    /// untouched. Image representations and the file URL live on one item so
    /// image-aware and file-aware targets can each choose their native format.
    @discardableResult
    static func write(
        _ payload: CapsuleFilePasteboardPayload,
        to pasteboard: NSPasteboard = .general,
        expectedChangeCount: Int? = nil
    ) throws -> Int {
        let item = NSPasteboardItem()
        if payload.kind == .image {
            guard let png = payload.imagePNG,
                  let tiff = payload.imageTIFF,
                  item.setData(png, forType: .png),
                  item.setData(tiff, forType: .tiff) else {
                throw CapsuleFilePasteboardError.pasteboardWriteFailed
            }
            if let originalType = payload.originalImageType,
               originalType != .png,
               originalType != .tiff,
               let originalData = payload.originalImageData {
                guard item.setData(originalData, forType: originalType) else {
                    throw CapsuleFilePasteboardError.pasteboardWriteFailed
                }
            }
        }
        guard item.setString(
            payload.fileURL.absoluteString,
            forType: .fileURL
        ) else {
            throw CapsuleFilePasteboardError.pasteboardWriteFailed
        }
        if let expectedChangeCount,
           pasteboard.changeCount != expectedChangeCount {
            throw CapsuleFilePasteboardError.pasteboardChanged
        }
        pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else {
            throw CapsuleFilePasteboardError.pasteboardWriteFailed
        }
        return pasteboard.changeCount
    }

    @discardableResult
    static func copy(
        kind: CapsuleEntryKind,
        path: String,
        to pasteboard: NSPasteboard = .general
    ) throws -> Int {
        try write(prepare(kind: kind, path: path), to: pasteboard)
    }

    private static func validateOrdinaryFile(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw CapsuleFilePasteboardError.unavailableFile
        }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size > 0 else {
            throw CapsuleFilePasteboardError.unavailableFile
        }
    }

    private static func readImageData(_ url: URL) throws -> Data {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw CapsuleFilePasteboardError.unavailableFile
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size > 0 else {
            throw CapsuleFilePasteboardError.unavailableFile
        }
        guard info.st_size <= off_t(CapsuleMediaPreviewLoader.maximumImageBytes)
        else {
            throw CapsuleFilePasteboardError.fileTooLarge
        }
        guard let data = try handle.readToEnd(),
              !data.isEmpty,
              data.count == Int(info.st_size) else {
            throw CapsuleFilePasteboardError.unavailableFile
        }
        return data
    }

    private static func sourceDimensionsAreSafe(
        _ source: CGImageSource
    ) -> Bool {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(
            source,
            0,
            nil
        ) as? [CFString: Any],
        let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?
            .uint64Value,
        let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?
            .uint64Value,
        width > 0,
        height > 0,
        width <= maximumSourceDimension,
        height <= maximumSourceDimension,
        width <= maximumSourcePixelCount / height else {
            return false
        }
        return true
    }

    private static func encode(_ image: CGImage, as type: String) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            type as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}

/// Media files are user-managed and can be large. Validate and decode them off
/// the main thread, then let the selected editor install only the latest result.
/// This prevents a 100+ MB PDF or a stale image selection from freezing or
/// repainting the next Capsule row.
final class CapsuleMediaPreviewLoader {
    static let shared = CapsuleMediaPreviewLoader()

    static let maximumImageBytes = 128 * 1_024 * 1_024
    static let maximumPDFBytes = 256 * 1_024 * 1_024
    static let maximumThumbnailPixels = 1_600

    private let queue: OperationQueue

    init(queue: OperationQueue = OperationQueue()) {
        queue.name = "RIMES.CapsuleMediaPreview"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 1
        self.queue = queue
    }

    @discardableResult
    func load(
        kind: CapsuleEntryKind,
        path: String,
        maximumPixelSize: Int = 1600,
        completion: @escaping (CapsuleMediaPreviewResult) -> Void
    ) -> Operation {
        // The queue is process-global and serial. Cancellation belongs to the
        // requesting pane, so a Settings preview cannot starve the standalone
        // Capsule window (or vice versa).
        let operation = BlockOperation()
        operation.addExecutionBlock { [weak operation] in
            guard operation?.isCancelled == false else { return }
            let result = Self.loadSynchronously(kind: kind, path: path, maximumPixelSize: maximumPixelSize)
            guard operation?.isCancelled == false else { return }
            OperationQueue.main.addOperation { [weak operation] in
                guard operation?.isCancelled == false else { return }
                completion(result)
            }
        }
        queue.addOperation(operation)
        return operation
    }

    static func loadSynchronously(
        kind: CapsuleEntryKind,
        path: String,
        maximumPixelSize: Int = 1600
    ) -> CapsuleMediaPreviewResult {
        guard kind == .image || kind == .pdf || kind == .video,
              NSString(string: path).isAbsolutePath else {
            return .unavailable
        }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        if kind == .pdf, url.pathExtension.lowercased() != "pdf" {
            return .unavailable
        }
        let descriptor = open(
            url.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else { return .unavailable }
        defer { close(descriptor) }
        var fileStatus = stat()
        guard fstat(descriptor, &fileStatus) == 0,
              (fileStatus.st_mode & S_IFMT) == S_IFREG,
              fileStatus.st_size > 0 else {
            return .unavailable
        }
        let size = UInt64(fileStatus.st_size)
        // ImageIO/Core Graphics read through the already-validated descriptor,
        // so replacing the original path cannot swap in a symlink or a larger
        // file between the safety check and the decoder open.
        let descriptorURL = URL(fileURLWithPath: "/dev/fd/\(descriptor)")

        switch kind {
        case .image:
            guard size <= UInt64(maximumImageBytes),
                  let source = CGImageSourceCreateWithURL(
                    descriptorURL as CFURL,
                    nil
                  ) else {
                return .unavailable
            }
            let options = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
            ] as CFDictionary
            guard let image = CGImageSourceCreateThumbnailAtIndex(
                source,
                0,
                options
            ) else {
                return .unavailable
            }
            return .image(image)
        case .video:
            if url.pathExtension.lowercased() == "gif", let image = try? CaptureImageIO.read(url, maximum: maximumPixelSize) { return .image(image) }
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: maximumPixelSize, height: maximumPixelSize)
            guard let image = try? generator.copyCGImage(at: .zero, actualTime: nil) else { return .unavailable }
            return .image(image)
        case .pdf:
            guard size <= UInt64(maximumPDFBytes),
                  let provider = CGDataProvider(url: descriptorURL as CFURL),
                  let document = CGPDFDocument(provider),
                  document.numberOfPages > 0,
                  let page = document.page(at: 1) else {
                return .unavailable
            }
            var previewBox: CGPDFBox = .cropBox
            var pageBox = page.getBoxRect(previewBox)
            if pageBox.isEmpty {
                previewBox = .mediaBox
                pageBox = page.getBoxRect(previewBox)
            }
            guard pageBox.width > 0, pageBox.height > 0 else {
                return .unavailable
            }
            let scale = min(
                CGFloat(maximumPixelSize) / pageBox.width,
                CGFloat(maximumPixelSize) / pageBox.height,
                1
            )
            let width = max(1, Int(ceil(pageBox.width * scale)))
            let height = max(1, Int(ceil(pageBox.height * scale)))
            guard let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                return .unavailable
            }
            let target = CGRect(x: 0, y: 0, width: width, height: height)
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(target)
            context.concatenate(page.getDrawingTransform(
                previewBox,
                rect: target,
                rotate: 0,
                preserveAspectRatio: true
            ))
            context.drawPDFPage(page)
            guard let image = context.makeImage() else {
                return .unavailable
            }
            return .pdf(image: image, pageCount: document.numberOfPages)
        case .password, .skill, .note:
            return .unavailable
        }
    }
}

struct CapsulePasswordEditorSnapshot: Equatable {
    let revealButtonTitle: String
    let revealRequiresChordAuthentication: Bool
    /// The body has no editable view at all while concealed, so there is no
    /// masked control to read, select, or expose to accessibility.
    let secretIsConcealed: Bool
    let plaintextAllowsSelection: Bool
    let plaintextIsAccessibilityElement: Bool
    let hasUnsavedChanges: Bool
}

/// Password details remain outside list/search projections. A row is safe to
/// render, log in a smoke failure, or expose as an accessibility label.
struct CapsuleWindowEntryRow: Equatable, Identifiable {
    let id: UUID
    let kind: CapsuleEntryKind
    let title: String
    let preview: String
    let updatedAt: Date
    let revision: String
    let fileURL: URL

    var accessibilitySummary: String {
        if kind == .password {
            return "Password · \(title) · 已脱敏"
        }
        return "\(kind.displayName) · \(title) · \(preview)"
    }
}

enum CapsulePasswordEditorField: CaseIterable {
    case title
    case secret
}

enum CapsulePasswordEditorSecurityPolicy {
    static let revealDuration: TimeInterval = 15

    static func mayReveal(_ field: CapsulePasswordEditorField) -> Bool {
        field == .secret
    }

    static func usesSecureControl(
        _ field: CapsulePasswordEditorField,
        plaintextVisible: Bool = false
    ) -> Bool {
        switch field {
        case .title:
            return false
        case .secret:
            return !plaintextVisible
        }
    }
}

struct CapsulePasswordRevealState: Equatable {
    private(set) var concealAt: Date?

    var isPlaintextVisible: Bool { concealAt != nil }

    func remainingDuration(now: Date) -> TimeInterval? {
        concealAt.map { max(0, $0.timeIntervalSince(now)) }
    }

    mutating func reveal(now: Date) {
        concealAt = now.addingTimeInterval(
            CapsulePasswordEditorSecurityPolicy.revealDuration
        )
    }

    mutating func conceal() {
        concealAt = nil
    }

    @discardableResult
    mutating func concealIfExpired(now: Date) -> Bool {
        guard let concealAt, now >= concealAt else { return false }
        self.concealAt = nil
        return true
    }
}

enum CapsuleWindowDraftError: LocalizedError, Equatable {
    case missingTitle
    case missingContent
    case missingPassword
    case relativeSkillPath
    case invalidURL
    case relativeAssetPath(String)
    case unsupportedAssetType(String)
    case unavailableAsset(String)

    var errorDescription: String? {
        switch self {
        case .missingTitle:
            return "请填写标题"
        case .missingContent:
            return "请填写内容"
        case .missingPassword:
            return "请填写密码"
        case .relativeSkillPath:
            return "Skill 必须使用电脑中的绝对路径"
        case .invalidURL:
            return "URL 必须是包含协议的完整网址"
        case let .relativeAssetPath(kind):
            return "\(kind) 必须使用电脑中的绝对路径"
        case let .unsupportedAssetType(kind):
            return "所选文件不是受支持的 \(kind)"
        case let .unavailableAsset(kind):
            return "\(kind) 文件不存在、不是普通文件或使用了符号链接"
        }
    }
}

enum CapsuleWindowRepositoryError: LocalizedError, Equatable {
    case staleRecord

    var errorDescription: String? {
        switch self {
        case .staleRecord:
            return "该条目已在另一窗口或 Obsidian 中更新；请重新载入后再编辑"
        }
    }
}

struct CapsuleWindowDraft: Equatable {
    var id: UUID?
    var kind: CapsuleEntryKind
    var title: String
    /// Every kind — passwords included — carries its payload here. A password
    /// entry holds free-form Markdown that happens to be encrypted at rest.
    var content: String
    var loadedRevision: String?

    init(id: UUID? = nil,
         kind: CapsuleEntryKind,
         title: String,
         content: String,
         loadedRevision: String? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
        self.content = content
        self.loadedRevision = loadedRevision
    }

    static func empty(kind: CapsuleEntryKind) -> CapsuleWindowDraft {
        CapsuleWindowDraft(
            id: nil,
            kind: kind,
            title: "",
            content: "",
            loadedRevision: nil
        )
    }

    func validated() throws -> CapsuleWindowDraft {
        var normalized = self
        normalized.title = title.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !normalized.title.isEmpty else {
            throw CapsuleWindowDraftError.missingTitle
        }
        switch kind {
        case .note:
            guard !content.isEmpty else {
                throw CapsuleWindowDraftError.missingContent
            }
        case .skill:
            guard !content.isEmpty else {
                throw CapsuleWindowDraftError.missingContent
            }
            guard NSString(string: content).isAbsolutePath else {
                throw CapsuleWindowDraftError.relativeSkillPath
            }
        case .image, .pdf, .video:
            guard !content.isEmpty else {
                throw CapsuleWindowDraftError.missingContent
            }
            guard NSString(string: content).isAbsolutePath else {
                throw CapsuleWindowDraftError.relativeAssetPath(
                    kind.displayName
                )
            }
            let ext = URL(fileURLWithPath: content).pathExtension.lowercased()
            let accepted: Set<String> = kind == .pdf
                ? ["pdf"]
                : kind == .video ? ["mp4", "mov", "m4v", "gif"] : [
                    "png", "jpg", "jpeg", "heic", "webp", "tif",
                    "tiff", "gif", "bmp",
                ]
            guard accepted.contains(ext) else {
                throw CapsuleWindowDraftError.unsupportedAssetType(
                    kind.displayName
                )
            }
            let assetURL = URL(fileURLWithPath: content).standardizedFileURL
            let values = try? assetURL.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ])
            guard values?.isRegularFile == true,
                  values?.isSymbolicLink != true else {
                throw CapsuleWindowDraftError.unavailableAsset(
                    kind.displayName
                )
            }
        case .password:
            guard !content.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty else {
                throw CapsuleWindowDraftError.missingPassword
            }
        }
        return normalized
    }
}

/// Synchronous local repository used only by the explicit management window.
/// It deliberately has no dependency on BufferModel or Delivery.
final class CapsuleWindowRepository {
    private let contentStore: CapsuleContentStore
    private let passwordStore: CapsulePasswordStore

    init(contentStore: CapsuleContentStore = .shared,
         passwordStore: CapsulePasswordStore = .shared) {
        self.contentStore = contentStore
        self.passwordStore = passwordStore
    }

    func list(kind: CapsuleEntryKind, query: String = "") throws
        -> [CapsuleWindowEntryRow] {
        let terms = Self.searchTerms(query)
        switch kind {
        case .password:
            return try passwordStore.listSummaries().filter { summary in
                Self.matches(terms: terms, text: summary.title)
            }.map { summary in
                CapsuleWindowEntryRow(
                    id: summary.id,
                    kind: .password,
                    title: summary.title,
                    preview: summary.maskedPassword,
                    updatedAt: summary.updatedAt,
                    revision: try Self.fileRevision(summary.fileURL),
                    fileURL: summary.fileURL
                )
            }
        case .skill, .note, .image, .pdf, .video:
            return try contentStore.listRecords().filter { record in
                record.summary.type == kind
                    && Self.matches(
                        terms: terms,
                        text: record.summary.title + "\n" + record.content
                    )
            }.map { record in
                CapsuleWindowEntryRow(
                    id: record.summary.id,
                    kind: record.summary.type,
                    title: record.summary.title,
                    preview: record.snippet,
                    updatedAt: record.summary.updatedAt,
                    revision: try Self.fileRevision(record.summary.fileURL),
                    fileURL: record.summary.fileURL
                )
            }
        }
    }

    func draft(for row: CapsuleWindowEntryRow) throws -> CapsuleWindowDraft {
        switch row.kind {
        case .password:
            let before = try Self.fileRevision(row.fileURL)
            let record = try passwordStore.record(id: row.id)
            let after = try Self.fileRevision(record.summary.fileURL)
            guard before == after else {
                throw CapsuleWindowRepositoryError.staleRecord
            }
            return CapsuleWindowDraft(
                id: record.summary.id,
                kind: .password,
                title: record.summary.title,
                content: record.secret.body,
                loadedRevision: after
            )
        case .skill, .note, .image, .pdf, .video:
            let before = try Self.fileRevision(row.fileURL)
            let record = try contentStore.record(id: row.id)
            let after = try Self.fileRevision(record.summary.fileURL)
            guard record.summary.type == row.kind else {
                throw CapsuleContentStoreError.recordNotFound
            }
            guard before == after else {
                throw CapsuleWindowRepositoryError.staleRecord
            }
            return CapsuleWindowDraft(
                id: record.summary.id,
                kind: record.summary.type,
                title: record.summary.title,
                content: record.content,
                loadedRevision: after
            )
        }
    }

    @discardableResult
    func save(_ draft: CapsuleWindowDraft) throws -> CapsuleWindowEntryRow {
        let draft = try draft.validated()
        if draft.id != nil, draft.loadedRevision == nil {
            throw CapsuleWindowRepositoryError.staleRecord
        }
        let row: CapsuleWindowEntryRow
        switch draft.kind {
        case .password:
            let summary: CapsulePasswordSummary
            do {
                summary = try passwordStore.put(
                    CapsulePasswordWriteRequest(
                        id: draft.id,
                        title: draft.title,
                        body: draft.content
                    ),
                    expectedRevision: draft.loadedRevision
                )
            } catch CapsulePasswordStoreError.revisionConflict {
                throw CapsuleWindowRepositoryError.staleRecord
            }
            row = CapsuleWindowEntryRow(
                id: summary.id,
                kind: .password,
                title: summary.title,
                preview: summary.maskedPassword,
                updatedAt: summary.updatedAt,
                revision: try Self.fileRevision(summary.fileURL),
                fileURL: summary.fileURL
            )
        case .skill, .note, .image, .pdf, .video:
            let summary: CapsuleContentSummary
            do {
                summary = try contentStore.put(
                    CapsuleContentWriteRequest(
                        id: draft.id,
                        type: draft.kind,
                        title: draft.title,
                        content: draft.content
                    ),
                    expectedRevision: draft.loadedRevision
                )
            } catch CapsuleContentStoreError.revisionConflict {
                throw CapsuleWindowRepositoryError.staleRecord
            }
            let record = try contentStore.record(id: summary.id)
            row = CapsuleWindowEntryRow(
                id: summary.id,
                kind: summary.type,
                title: summary.title,
                preview: record.snippet,
                updatedAt: summary.updatedAt,
                revision: try Self.fileRevision(summary.fileURL),
                fileURL: summary.fileURL
            )
        }
        publishChange()
        return row
    }

    func remove(_ row: CapsuleWindowEntryRow,
                expectedRevision: String?) throws {
        guard let expectedRevision else {
            throw CapsuleWindowRepositoryError.staleRecord
        }
        do {
            switch row.kind {
            case .password:
                try passwordStore.remove(
                    id: row.id,
                    expectedRevision: expectedRevision
                )
            case .skill, .note, .image, .pdf, .video:
                try contentStore.remove(
                    id: row.id,
                    expectedRevision: expectedRevision
                )
            }
        } catch CapsulePasswordStoreError.revisionConflict {
            throw CapsuleWindowRepositoryError.staleRecord
        } catch CapsuleContentStoreError.revisionConflict {
            throw CapsuleWindowRepositoryError.staleRecord
        }
        publishChange()
    }

    private static func fileRevision(_ fileURL: URL) throws -> String {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
        } catch {
            throw CapsuleWindowRepositoryError.staleRecord
        }
        return SHA256.hash(data: data).map {
            String(format: "%02x", $0)
        }.joined()
    }

    private func publishChange() {
        let publish = { [self] in
            NotificationCenter.default.post(
                name: .capsuleStoreDidChange,
                object: self
            )
        }
        if Thread.isMainThread {
            publish()
        } else {
            DispatchQueue.main.async(execute: publish)
        }
    }

    private static func searchTerms(_ query: String) -> [String] {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split(whereSeparator: \Character.isWhitespace)
            .map(String.init)
    }

    private static func matches(terms: [String], text: String) -> Bool {
        guard !terms.isEmpty else { return true }
        let text = text.lowercased()
        return terms.allSatisfy(text.contains)
    }
}

/// Standalone, key-capable Capsule manager. This window owns CRUD only; it is
/// never an implicit Buffer destination and never performs paste/AX delivery.
final class CapsuleWindowController: NSObject, NSWindowDelegate {
    static let shared = CapsuleWindowController()

    private var window: NSWindow?
    private var contentController: CapsulePaneViewController?
    private var appearanceObserver: NSObjectProtocol?
    private var screenParametersObserver: NSObjectProtocol?

    deinit {
        if let appearanceObserver {
            NotificationCenter.default.removeObserver(appearanceObserver)
        }
        if let screenParametersObserver {
            NotificationCenter.default.removeObserver(screenParametersObserver)
        }
    }

    static var isVisible: Bool { shared.window?.isVisible == true }

    /// Input/focus routing may use this to reject the management window as a
    /// host delivery target while still letting AppKit fields become key.
    static var isKeyAndVisible: Bool {
        shared.window?.isVisible == true && shared.window?.isKeyWindow == true
    }

    @discardableResult
    func toggleVisibility() -> CapsuleWindowToggleAction {
        let action = CapsuleWindowVisibilityRules.action(
            isVisible: window?.isVisible == true
        )
        CapsuleWindowVisibilityRules.perform(
            action,
            show: { [weak self] in self?.show() },
            performClose: { [weak self] in self?.window?.performClose(nil) }
        )
        return action
    }

    func show() {
        // Capsule is a standalone AppKit manager. It has no IMK client or
        // delivery authority, so the selected input source must not gate it.
        if window == nil { build() }
        if window?.isVisible == true {
            clampWindowToVisibleScreens(display: false)
        } else {
            placeAtRail()
        }
        applyAppearance()
        contentController?.reloadFromStore()
        if let window {
            StandaloneWindowFocusCoordinator.shared.windowWillPresent(window)
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { [weak self] in
            self?.contentController?.windowBecameKey()
        }
    }

    /// Opens the manager from the rail's gear, on the kind the rail was showing.
    func show(kind: CapsuleEntryKind?) {
        show()
        if let kind { contentController?.selectKind(kind) }
    }

    /// The gear, Esc or the Recent tab: closes the manager, confirming an
    /// unsaved draft, and brings the rail back on `tab` once focus has
    /// returned to the application the user came from.
    func returnToRail(tab: CapsuleRailTab) {
        guard let window, window.isVisible else { return }
        window.performClose(nil)
        guard !window.isVisible else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            ClipboardHistoryWindowController.shared.show(tab: tab)
        }
    }

    /// Opens the manager on a new, unsaved entry prefilled from the rail.
    func show(draftKind kind: CapsuleEntryKind, title: String, content: String) {
        show()
        contentController?.beginDraft(kind: kind, title: title, content: content)
    }

    /// Opens the manager on one entry, as the rail's edit brush asks.
    func show(revealing kind: CapsuleEntryKind, id: UUID) {
        show()
        contentController?.reveal(kind: kind, id: id)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        contentController?.windowBecameKey()
    }

    func windowDidResignKey(_ notification: Notification) {
        if contentController?.isPresentingPasswordChallengeSheet == true {
            return
        }
        contentController?.concealPasswordPlaintext()
    }

    func windowWillClose(_ notification: Notification) {
        contentController?.discardEditorForClose()
        guard let closingWindow = notification.object as? NSWindow,
              closingWindow === window else { return }
        StandaloneWindowFocusCoordinator.shared.windowWillClose(closingWindow)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        contentController?.concealPasswordPlaintext()
        return contentController?.confirmDiscardChangesIfNeeded() ?? true
    }

    private func build() {
        // The manager is the rail grown upward: a key window with the rail's
        // chrome and header, so it has no visible title bar of its own.
        let window = NSWindow(
            contentRect: NSRect(
                origin: .zero,
                size: CapsuleWindowGeometry.defaultContentSize
            ),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "RIMES Capsule"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.isHidden = true
        }
        window.isReleasedWhenClosed = false
        window.contentMinSize = CapsuleWindowGeometry.minimumContentSize
        window.appearance = RimeUI.appKitAppearance
        window.backgroundColor = RimeUI.workbenchChrome
        window.animationBehavior = .documentWindow
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.delegate = self

        let contentController = CapsulePaneViewController()
        contentController.onReturnToRail = { [weak self] tab in
            self?.returnToRail(tab: tab)
        }
        // Keep content constraint invalidation from being interpreted as a
        // window resize. NSWindow still resizes this view for explicit user or
        // programmatic frame changes.
        CapsuleWindowGeometry.install(
            contentController: contentController,
            in: window
        )

        self.window = window
        self.contentController = contentController
        appearanceObserver = NotificationCenter.default.addObserver(
            forName: .rimeAppearanceDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.applyAppearance()
        }
        screenParametersObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.clampWindowToVisibleScreens(display: true)
        }
    }

    /// Same centre and bottom edge as the rail, on the pointer's screen.
    private func placeAtRail() {
        guard let window else { return }
        let screen = NSScreen.screens.first {
            $0.frame.contains(NSEvent.mouseLocation)
        } ?? NSScreen.main
        let visible = screen?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1_440, height: 900)
        let minimum = CapsuleWindowGeometry.minimumContentSize
        let preferred = CapsuleWindowGeometry.defaultContentSize
        let width = min(preferred.width, max(minimum.width, visible.width - 32))
        let height = min(preferred.height, max(minimum.height, visible.height - 48))
        let content = NSRect(
            x: visible.midX - width / 2,
            y: visible.minY + min(24, max(0, visible.height - height)),
            width: width,
            height: height
        )
        window.setFrame(window.frameRect(forContentRect: content), display: false)
    }

    private func clampWindowToVisibleScreens(display: Bool) {
        guard let window else { return }
        let constrained = CapsuleWindowGeometry.constrainedFrame(
            window.frame,
            visibleFrames: NSScreen.screens.map(\.visibleFrame),
            fallbackVisibleFrame: NSScreen.main?.visibleFrame
        )
        if constrained != window.frame {
            window.setFrame(constrained, display: display)
        }
    }

    private func applyAppearance() {
        window?.appearance = RimeUI.appKitAppearance
        window?.backgroundColor = RimeUI.workbenchChrome
        contentController?.applyAppearance()
    }
}

/// Capsule's reusable management surface belongs only to the standalone
/// window. Settings exposes configuration and launch controls without
/// embedding this operational pane.
final class CapsulePaneViewController: NSViewController,
                                       NSTableViewDataSource,
                                       NSTableViewDelegate,
                                       NSTextFieldDelegate,
                                       NSTextViewDelegate {
    private static let searchDebounce: TimeInterval = 0.150
    private static let maximumPreviewWidth: CGFloat = 640

    private let repository: CapsuleWindowRepository
    private let cloudSyncController: CapsuleCloudSyncController?
    private let mediaPreviewLoader = CapsuleMediaPreviewLoader.shared
    private let fileCopyQueue = DispatchQueue(
        label: "RIMES.CapsuleWindow.file-copy",
        qos: .userInitiated
    )
    private let reloadQueue = DispatchQueue(
        label: "RIMES.CapsuleWindow.reload",
        qos: .userInitiated
    )

    /// Asked to close the manager and show the rail on the given tab.
    var onReturnToRail: ((CapsuleRailTab) -> Void)?

    private let titleLabel = NSTextField(labelWithString: "Capsule")
    private let countLabel = NSTextField(labelWithString: "")
    private let tabStrip = CapsuleRailTabStrip()
    private let railButton = RimePointingHandButton(title: "", target: nil, action: nil)
    private let closeButton = RimePointingHandButton(title: "", target: nil, action: nil)
    private let hintLabel = NSTextField(labelWithString: "⌘S SAVE   ESC BACK TO RAIL")
    private weak var headerStack: NSStackView?
    private weak var toolbarStack: NSStackView?
    private let syncStatusLabel = NSTextField(labelWithString: "iCloud 未设置")
    private let syncNowButton = RimePointingHandButton(
        title: "立即同步",
        target: nil,
        action: nil
    )
    private let syncManageButton = RimePointingHandButton(
        title: "iCloud…",
        target: nil,
        action: nil
    )
    private let searchField = NSSearchField()
    private let newButton = RimePointingHandButton(
        title: "＋ 新建",
        target: nil,
        action: nil
    )
    private let tableView = NSTableView()
    private let listScrollView = NSScrollView()
    private let listContainer = NSView()
    private let editorContainer = NSView()
    private let editorScrollView = NSScrollView()
    private let formStack = NSStackView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let saveButton = RimePointingHandButton(
        title: "保存",
        target: nil,
        action: nil
    )
    private let deleteButton = RimePointingHandButton(
        title: "删除",
        target: nil,
        action: nil
    )

    private var rows: [CapsuleWindowEntryRow] = []
    private var selectedKind: CapsuleEntryKind = .note
    private var draft = CapsuleWindowDraft.empty(kind: .note)
    private var titleField: NSTextField?
    private var contentTextView: NSTextView?
    private var skillPathField: NSTextField?
    private var urlContentField: NSTextField?
    private var assetPathField: NSTextField?
    private weak var assetPreviewContainer: NSView?
    private var imagePreviewView: NSImageView?
    private weak var titleFormRow: NSView?
    private weak var firstDetailFormRow: NSView?
    private weak var formBottomSpacer: NSView?
    private weak var fileCopyButton: NSButton?
    private weak var editorActions: NSStackView?
    private var passwordSecretTextView: NSTextView?
    private var previousPasswordFields: [NSTextField] = []
    private var passwordRevealButton: NSButton?
    private var passwordRevealState = CapsulePasswordRevealState()
    private var passwordRevealTimer: Timer?
    private var passwordChallengeGeneration: UInt64 = 0
    private var passwordChallengeController:
        CapsuleRevealPasscodeChallengeController?
    private var searchReloadTimer: Timer?
    private var reloadGeneration: UInt64 = 0
    private var mediaPreviewGeneration: UInt64 = 0
    private var mediaPreviewOperation: Operation?
    private var fileCopyGeneration: UInt64 = 0
    private var applyingSelection = false
    private var editorDirty = false
    private var storeObserver: NSObjectProtocol?
    private var cloudSyncObserver: NSObjectProtocol?
    private var revealPasscodeObserver: NSObjectProtocol?
    private var applicationPrivacyObservers: [NSObjectProtocol] = []
    private var workspacePrivacyObservers: [NSObjectProtocol] = []
    private var distributedPrivacyObservers: [NSObjectProtocol] = []

    init(
        repository: CapsuleWindowRepository = CapsuleWindowRepository(),
        cloudSyncController: CapsuleCloudSyncController? = .shared
    ) {
        self.repository = repository
        self.cloudSyncController = cloudSyncController
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        passwordChallengeController?.cancel()
        searchReloadTimer?.invalidate()
        passwordRevealTimer?.invalidate()
        if let storeObserver {
            NotificationCenter.default.removeObserver(storeObserver)
        }
        if let cloudSyncObserver {
            NotificationCenter.default.removeObserver(cloudSyncObserver)
        }
        if let revealPasscodeObserver {
            NotificationCenter.default.removeObserver(revealPasscodeObserver)
        }
        let center = NotificationCenter.default
        applicationPrivacyObservers.forEach(center.removeObserver)
        let workspace = NSWorkspace.shared.notificationCenter
        workspacePrivacyObservers.forEach(workspace.removeObserver)
        let distributed = DistributedNotificationCenter.default()
        distributedPrivacyObservers.forEach(distributed.removeObserver)
    }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true

        titleLabel.font = .monospacedSystemFont(ofSize: 15, weight: .bold)
        titleLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        countLabel.font = .monospacedSystemFont(ofSize: 10, weight: .medium)
        countLabel.lineBreakMode = .byTruncatingTail
        countLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        tabStrip.onSelect = { [weak self] tab in self?.tabSelected(tab) }

        syncStatusLabel.font = MailboxTerminalTypography.font(ofSize: 9)
        syncStatusLabel.lineBreakMode = .byTruncatingTail
        syncStatusLabel.maximumNumberOfLines = 1
        syncStatusLabel.setContentCompressionResistancePriority(
            .defaultLow,
            for: .horizontal
        )
        syncStatusLabel.setAccessibilityLabel("Capsule iCloud 同步状态")

        for button in [syncNowButton, syncManageButton] {
            button.bezelStyle = .inline
            button.font = MailboxTerminalTypography.font(
                ofSize: 9,
                weight: .semibold
            )
            button.setContentHuggingPriority(.required, for: .horizontal)
        }
        syncNowButton.target = self
        syncNowButton.action = #selector(syncNow)
        syncNowButton.setAccessibilityLabel("立即同步 Capsule")
        syncManageButton.target = self
        syncManageButton.action = #selector(manageCloudSync)
        syncManageButton.setAccessibilityLabel("管理 Capsule iCloud 同步")

        // The manager is the rail grown upward: the rail's header, with the
        // gear lit to show this is the manage view.
        railButton.image = RimeUI.symbol("gearshape", pointSize: 12, weight: .semibold)
        railButton.image?.isTemplate = true
        railButton.imagePosition = .imageOnly
        railButton.isBordered = false
        railButton.wantsLayer = true
        railButton.layer?.cornerRadius = 6
        railButton.target = self
        railButton.action = #selector(returnToRailPressed)
        railButton.toolTip = "返回 Capsule 底栏"
        railButton.setAccessibilityLabel("返回 Capsule 底栏")
        closeButton.image = RimeUI.symbol("xmark", pointSize: 11, weight: .bold)
        closeButton.image?.isTemplate = true
        closeButton.imagePosition = .imageOnly
        closeButton.isBordered = false
        closeButton.target = self
        closeButton.action = #selector(closePressed)
        closeButton.setAccessibilityLabel("关闭 Capsule")
        NSLayoutConstraint.activate([
            railButton.widthAnchor.constraint(equalToConstant: 22),
            railButton.heightAnchor.constraint(equalToConstant: 22),
            closeButton.widthAnchor.constraint(equalToConstant: 16),
            closeButton.heightAnchor.constraint(equalToConstant: 16),
        ])
        let header = NSStackView(views: [
            titleLabel, countLabel, tabStrip, NSView(),
            syncStatusLabel, syncNowButton, syncManageButton,
            railButton, closeButton,
        ])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 9
        headerStack = header
        tabStrip.select(.saved(selectedKind))

        searchField.placeholderString = "搜索标题或内容"
        searchField.sendsSearchStringImmediately = true
        searchField.sendsWholeSearchString = false
        searchField.target = self
        searchField.action = #selector(searchChanged)
        searchField.font = MailboxTerminalTypography.font(ofSize: 11)
        searchField.setAccessibilityLabel("搜索 Capsule")

        newButton.target = self
        newButton.action = #selector(createNew)
        newButton.bezelStyle = .rounded
        newButton.font = MailboxTerminalTypography.font(
            ofSize: 10,
            weight: .semibold
        )
        newButton.setContentHuggingPriority(.required, for: .horizontal)

        let toolbar = NSStackView(views: [searchField, newButton])
        toolbar.orientation = .horizontal
        toolbar.alignment = .centerY
        toolbar.spacing = 8
        toolbarStack = toolbar

        hintLabel.font = .monospacedSystemFont(ofSize: 9, weight: .medium)
        hintLabel.lineBreakMode = .byTruncatingTail

        let column = NSTableColumn(
            identifier: NSUserInterfaceItemIdentifier("capsule-entry")
        )
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 56
        tableView.intercellSpacing = NSSize(width: 0, height: 1)
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .none
        tableView.dataSource = self
        tableView.delegate = self
        tableView.focusRingType = .none
        tableView.setAccessibilityLabel("Capsule 条目列表")

        listScrollView.documentView = tableView
        listScrollView.drawsBackground = false
        listScrollView.hasVerticalScroller = true
        listScrollView.autohidesScrollers = true
        listScrollView.translatesAutoresizingMaskIntoConstraints = false
        listContainer.wantsLayer = true
        listContainer.layer?.cornerRadius = 6
        listContainer.layer?.borderWidth = 1
        listContainer.translatesAutoresizingMaskIntoConstraints = false
        listContainer.addSubview(listScrollView)
        NSLayoutConstraint.activate([
            listScrollView.leadingAnchor.constraint(equalTo: listContainer.leadingAnchor),
            listScrollView.trailingAnchor.constraint(equalTo: listContainer.trailingAnchor),
            listScrollView.topAnchor.constraint(equalTo: listContainer.topAnchor),
            listScrollView.bottomAnchor.constraint(equalTo: listContainer.bottomAnchor),
        ])

        configureEditor()

        let divider = NSView()
        divider.wantsLayer = true
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.identifier = NSUserInterfaceItemIdentifier("capsule-divider")

        header.translatesAutoresizingMaskIntoConstraints = false
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        editorContainer.translatesAutoresizingMaskIntoConstraints = false
        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(header)
        root.addSubview(toolbar)
        root.addSubview(listContainer)
        root.addSubview(divider)
        root.addSubview(editorContainer)
        root.addSubview(hintLabel)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            header.heightAnchor.constraint(equalToConstant: 30),

            toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            toolbar.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 14),
            toolbar.widthAnchor.constraint(equalTo: listContainer.widthAnchor),

            listContainer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            listContainer.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 12),
            listContainer.bottomAnchor.constraint(equalTo: hintLabel.topAnchor, constant: -8),
            listContainer.widthAnchor.constraint(greaterThanOrEqualToConstant: 200),
            listContainer.widthAnchor.constraint(lessThanOrEqualToConstant: 286),

            divider.leadingAnchor.constraint(equalTo: listContainer.trailingAnchor, constant: 12),
            divider.topAnchor.constraint(equalTo: toolbar.topAnchor),
            divider.bottomAnchor.constraint(equalTo: listContainer.bottomAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),

            editorContainer.leadingAnchor.constraint(equalTo: divider.trailingAnchor, constant: 14),
            editorContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            editorContainer.topAnchor.constraint(equalTo: toolbar.topAnchor),
            editorContainer.bottomAnchor.constraint(equalTo: listContainer.bottomAnchor),
            editorContainer.widthAnchor.constraint(greaterThanOrEqualToConstant: 280),

            hintLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            hintLabel.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -14),
            hintLabel.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),
        ])
        let preferredListWidth = listContainer.widthAnchor.constraint(
            equalTo: root.widthAnchor,
            multiplier: 0.31
        )
        preferredListWidth.priority = .defaultHigh
        preferredListWidth.isActive = true

        view = root
        renderCloudSyncStatus()
        renderEditor()
        applyAppearance()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        storeObserver = NotificationCenter.default.addObserver(
            forName: .capsuleStoreDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  (notification.object as AnyObject?) !== self.repository else {
                return
            }
            self.reloadFromStore()
        }
        if let cloudSyncController {
            cloudSyncObserver = NotificationCenter.default.addObserver(
                forName: .capsuleCloudSyncStatusDidChange,
                object: cloudSyncController,
                queue: .main
            ) { [weak self] _ in
                self?.renderCloudSyncStatus()
            }
            cloudSyncController.start()
        }
        revealPasscodeObserver = NotificationCenter.default.addObserver(
            forName: .capsuleRevealPasscodeDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Changing or resetting the credential revokes any visible
            // plaintext lease and any in-progress verification immediately.
            self?.concealPasswordPlaintext()
        }
        installPrivacyObservers()
        reloadFromStore()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        reloadFromStore()
        cloudSyncController?.requestSync(after: 0)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // Keep the two explicit iCloud actions reachable on compact surfaces.
        // The status remains available as their tooltip and returns as soon as
        // enough width is available.
        let hidesInlineSyncStatus = view.bounds.width < 760
        let shouldHideSyncStatus = cloudSyncController == nil
            || hidesInlineSyncStatus
        if syncStatusLabel.isHidden != shouldHideSyncStatus {
            syncStatusLabel.isHidden = shouldHideSyncStatus
        }
    }

    override func viewWillDisappear() {
        concealPasswordPlaintext()
        super.viewWillDisappear()
    }

    func reloadFromStore() {
        guard isViewLoaded else { return }
        concealPasswordPlaintext()
        scheduleReload(after: 0)
    }

    /// Starts a new entry of `kind` filled in from the rail. It stays unsaved
    /// until the user saves it; closing asks, as for any unsaved draft.
    func beginDraft(kind: CapsuleEntryKind, title: String, content: String) {
        guard isViewLoaded else { return }
        concealPasswordPlaintext()
        guard confirmDiscardChangesIfNeeded() else { return }
        selectedKind = kind
        tabStrip.select(.saved(kind))
        searchField.placeholderString = kind == .password
            ? "仅搜索密码标题"
            : "搜索标题或内容"
        searchField.stringValue = ""
        cancelPendingReload()
        draft = CapsuleWindowDraft(kind: kind, title: title, content: content)
        editorDirty = true
        renderEditor()
        reloadFromStore()
    }

    /// Switches to `kind` and selects entry `id` once the list reloads. An
    /// unsaved draft is confirmed first, as for any other switch.
    func reveal(kind: CapsuleEntryKind, id: UUID) {
        guard isViewLoaded else { return }
        concealPasswordPlaintext()
        guard draft.id != id || draft.kind != kind else { return }
        guard confirmDiscardChangesIfNeeded() else { return }
        selectedKind = kind
        tabStrip.select(.saved(kind))
        searchField.placeholderString = kind == .password
            ? "仅搜索密码标题"
            : "搜索标题或内容"
        searchField.stringValue = ""
        cancelPendingReload()
        // The reload prefers the draft's id and then loads the full record.
        draft = CapsuleWindowDraft(id: id, kind: kind, title: "", content: "")
        editorDirty = false
        reloadFromStore()
    }

    func windowBecameKey() {
        view.window?.makeFirstResponder(searchField)
    }

    var hasUnsavedChanges: Bool { editorDirty }

    var isPresentingPasswordChallengeSheet: Bool {
        passwordChallengeController != nil && view.window?.attachedSheet != nil
    }

    /// Reveal is deliberately ephemeral. Rebuilding the editor preserves an
    /// unsaved password draft but never extends the original 15-second lease.
    func concealPasswordPlaintext() {
        passwordChallengeGeneration &+= 1
        passwordChallengeController?.cancel()
        passwordChallengeController = nil
        passwordRevealTimer?.invalidate()
        passwordRevealTimer = nil
        guard passwordRevealState.isPlaintextVisible else { return }
        captureDraftFromFields()
        passwordRevealState.conceal()
        renderEditor()
    }

    /// Remove decrypted credential values when a reusable pane leaves its
    /// surface. Password always fails closed.
    func scrubSensitiveEditor() {
        guard draft.kind == .password else { return }
        cancelPendingReload()
        concealPasswordPlaintext()
        draft = .empty(kind: .password)
        editorDirty = false
        renderEditor()
    }

    /// A retained standalone NSWindow must never reopen with a discarded draft
    /// still present in its controls, even when the next store reload fails.
    func discardEditorForClose() {
        guard isViewLoaded else { return }
        cancelPendingReload()
        concealPasswordPlaintext()
        applyingSelection = true
        tableView.deselectAll(nil)
        applyingSelection = false
        draft = .empty(kind: selectedKind)
        editorDirty = false
        renderEditor()
    }

    /// Any navigation that replaces the editor must be explicit about an
    /// unsaved draft. This is synchronous because AppKit selection and window
    /// close delegate callbacks need an immediate allow/deny answer.
    func confirmDiscardChangesIfNeeded() -> Bool {
        captureDraftFromFields()
        guard editorDirty else { return true }
        let alert = NSAlert()
        alert.messageText = "放弃未保存的更改？"
        alert.informativeText = "当前 Capsule 条目尚未保存。放弃后无法恢复这些修改。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "放弃更改")
        alert.addButton(withTitle: "继续编辑")
        guard alert.runModal() == .alertFirstButtonReturn else {
            setStatus("当前更改尚未保存")
            return false
        }
        editorDirty = false
        return true
    }

    func applyAppearance() {
        guard isViewLoaded else { return }
        view.layer?.backgroundColor = RimeUI.workbenchChrome.cgColor
        titleLabel.textColor = RimeUI.textPrimary
        countLabel.textColor = RimeUI.textMuted
        hintLabel.textColor = RimeUI.textMuted
        tabStrip.applyAppearance()
        railButton.contentTintColor = RimeUI.textPrimary
        railButton.layer?.backgroundColor = RimeUI.clipboardSelectedBackground.cgColor
        closeButton.contentTintColor = RimeUI.textSecondary
        syncStatusLabel.textColor = RimeUI.textSecondary
        statusLabel.textColor = RimeUI.textSecondary
        listContainer.layer?.backgroundColor = RimeUI.surface2.cgColor
        listContainer.layer?.borderColor = RimeUI.border.cgColor
        editorContainer.layer?.backgroundColor = RimeUI.surface2.cgColor
        editorContainer.layer?.borderColor = RimeUI.border.cgColor
        view.subviews.first(where: {
            $0.identifier?.rawValue == "capsule-divider"
        })?.layer?.backgroundColor = RimeUI.border.cgColor
        tableView.reloadData()
    }

    private func renderCloudSyncStatus() {
        guard isViewLoaded else { return }
        guard let cloudSyncController else {
            syncStatusLabel.isHidden = true
            syncNowButton.isHidden = true
            syncManageButton.isHidden = true
            return
        }
        let status = cloudSyncController.status
        syncStatusLabel.isHidden = view.bounds.width < 760
        syncNowButton.isHidden = false
        syncManageButton.isHidden = false
        switch status.phase {
        case .unconfigured:
            syncStatusLabel.stringValue = "iCloud 未设置"
        case .unavailable:
            syncStatusLabel.stringValue = "iCloud Drive 不可用"
        case .idle:
            syncStatusLabel.stringValue = "iCloud 等待同步"
        case .syncing:
            syncStatusLabel.stringValue = "iCloud 正在同步"
        case .synced:
            if status.deferredCount > 0 {
                syncStatusLabel.stringValue =
                    "iCloud · \(status.deferredCount) 个媒体待本机文件"
            } else if status.conflictCount > 0 {
                syncStatusLabel.stringValue = "iCloud · \(status.conflictCount) 个冲突"
            } else if let date = status.lastSyncedAt {
                let time = DateFormatter.localizedString(
                    from: date,
                    dateStyle: .none,
                    timeStyle: .short
                )
                syncStatusLabel.stringValue = "iCloud 已同步 \(time)"
            } else {
                syncStatusLabel.stringValue = "iCloud 已同步"
            }
        case .failed:
            syncStatusLabel.stringValue = "iCloud 同步失败"
        }
        let statusDetail = [status.folderName, status.message]
            .compactMap { $0 }
            .joined(separator: " · ")
        syncStatusLabel.toolTip = statusDetail
        let visibleStatus = [syncStatusLabel.stringValue, statusDetail]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
        for button in [syncNowButton, syncManageButton] {
            button.toolTip = visibleStatus
            button.setAccessibilityHelp(visibleStatus)
        }
        syncNowButton.isEnabled = status.isConfigured
            && status.phase != .unavailable
            && !status.isBusy
        syncManageButton.isEnabled = !status.isBusy
    }

    @objc private func syncNow() {
        cloudSyncController?.requestSync(after: 0)
    }

    @objc private func manageCloudSync() {
        guard let cloudSyncController else { return }
        guard cloudSyncController.status.isConfigured else {
            chooseCloudSyncFolder()
            return
        }
        let alert = NSAlert()
        alert.messageText = "管理 Capsule iCloud 同步"
        alert.informativeText = "关闭只会停止自动同步，不会删除本机或 iCloud Drive 中的内容。Password、Skill 路径与主密钥始终保留在本机。"
        alert.addButton(withTitle: "更换文件夹…")
        alert.addButton(withTitle: "关闭同步")
        alert.addButton(withTitle: "取消")
        let handle: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self else { return }
            switch response {
            case .alertFirstButtonReturn:
                self.chooseCloudSyncFolder()
            case .alertSecondButtonReturn:
                cloudSyncController.disable { [weak self] result in
                    if case let .failure(error) = result {
                        self?.presentCloudSyncError(error)
                    }
                }
            default:
                break
            }
        }
        if let window = view.window {
            alert.beginSheetModal(for: window, completionHandler: handle)
        } else {
            handle(alert.runModal())
        }
    }

    private func chooseCloudSyncFolder() {
        guard let cloudSyncController else { return }
        let panel = NSOpenPanel()
        panel.title = "选择 Capsule iCloud Drive 文件夹"
        panel.message = "请在 iCloud Drive 中新建或选择一个空文件夹。Prompt、Memory、Note、URL、Image 与 PDF 会同步；Password、Skill 路径与主密钥不会上传。"
        panel.prompt = "使用此文件夹"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.resolvesAliases = false
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent(
                "Library/Mobile Documents/com~apple~CloudDocs",
                isDirectory: true
            ),
            home.appendingPathComponent(
                "Library/CloudStorage",
                isDirectory: true
            ),
        ]
        panel.directoryURL = candidates.first {
            FileManager.default.fileExists(atPath: $0.path)
        }
        let handle: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            cloudSyncController.configure(folderURL: url) { [weak self] result in
                if case let .failure(error) = result {
                    self?.presentCloudSyncError(error)
                }
            }
        }
        if let window = view.window {
            panel.beginSheetModal(for: window, completionHandler: handle)
        } else {
            handle(panel.runModal())
        }
    }

    private func presentCloudSyncError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "无法启用 iCloud 同步"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "好")
        if let window = view.window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    /// Native smoke hook: render the real AppKit pane at a deterministic size
    /// and expose only geometry, never draft contents or password controls.
    func layoutSnapshotForSmoke(
        kind: CapsuleEntryKind,
        size: NSSize
    ) -> CapsulePaneLayoutSnapshot {
        _ = view
        cancelPendingReload()
        passwordRevealTimer?.invalidate()
        passwordRevealTimer = nil
        passwordRevealState.conceal()
        selectedKind = kind
        tabStrip.select(.saved(kind))
        draft = .empty(kind: kind)
        editorDirty = false
        renderEditor()

        view.frame = NSRect(origin: .zero, size: size)
        view.bounds = NSRect(origin: .zero, size: size)
        view.needsUpdateConstraints = true
        view.updateConstraintsForSubtreeIfNeeded()
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        editorScrollView.layoutSubtreeIfNeeded()
        formStack.layoutSubtreeIfNeeded()
        scrollEditorToTop()

        return currentLayoutSnapshotForSmoke(kind: kind)
    }

    /// Exercise the production async preview path without exposing file data in
    /// smoke output. Callers can compare their NSWindow geometry before and
    /// after `mediaPreviewIsReadyForSmoke` becomes true.
    func beginMediaPreviewForSmoke(kind: CapsuleEntryKind, path: String) {
        precondition(kind == .image || kind == .pdf || kind == .video)
        _ = view
        cancelPendingReload()
        passwordRevealTimer?.invalidate()
        passwordRevealTimer = nil
        passwordRevealState.conceal()
        selectedKind = kind
        tabStrip.select(.saved(kind))
        draft = .empty(kind: kind)
        draft.title = "Media layout smoke"
        draft.content = path
        editorDirty = false
        renderEditor()
        layoutCurrentViewForSmoke()
    }

    var mediaPreviewIsReadyForSmoke: Bool {
        imagePreviewView != nil
    }

    func currentLayoutSnapshotForSmoke(
        kind: CapsuleEntryKind
    ) -> CapsulePaneLayoutSnapshot {
        layoutCurrentViewForSmoke()

        let headerFrame = headerStack.map { $0.convert($0.bounds, to: view) } ?? .zero
        let toolbarFrame = toolbarStack.map { $0.convert($0.bounds, to: view) } ?? .zero
        let tabStripFrame = tabStrip.convert(tabStrip.bounds, to: view)
        let listFrame = listContainer.convert(listContainer.bounds, to: view)
        let editorFrame = editorContainer.convert(editorContainer.bounds, to: view)
        let actionsFrame = editorActions.map {
            $0.convert($0.bounds, to: view)
        } ?? .zero
        let previewFrame = assetPreviewContainer.map {
            $0.convert($0.bounds, to: view)
        }
        let imagePreviewFrame = imagePreviewView.map {
            $0.convert($0.bounds, to: view)
        }
        let copyButtonFrame = fileCopyButton.map {
            $0.convert($0.bounds, to: view)
        }
        let headerToToolbarGap: CGFloat
        let toolbarTop: CGFloat
        let editorTop: CGFloat
        if view.isFlipped {
            headerToToolbarGap = toolbarFrame.minY - headerFrame.maxY
            toolbarTop = toolbarFrame.minY
            editorTop = editorFrame.minY
        } else {
            headerToToolbarGap = headerFrame.minY - toolbarFrame.maxY
            toolbarTop = toolbarFrame.maxY
            editorTop = editorFrame.maxY
        }

        let clip = editorScrollView.contentView
        let clipFrame = clip.convert(clip.bounds, to: view)
        let formFrame = formStack.convert(formStack.bounds, to: view)
        let formTopGap: CGFloat
        if let firstRow = formStack.arrangedSubviews.first {
            let firstFrame = firstRow.convert(firstRow.bounds, to: clip)
            formTopGap = clip.isFlipped
                ? firstFrame.minY - clip.bounds.minY
                : clip.bounds.maxY - firstFrame.maxY
        } else {
            formTopGap = .infinity
        }
        let titleRowFrame = titleFormRow.map {
            $0.convert($0.bounds, to: formStack)
        }
        let firstDetailRowFrame = firstDetailFormRow.map {
            $0.convert($0.bounds, to: formStack)
        }
        let titleToFirstDetailGap: CGFloat?
        if let titleRowFrame, let firstDetailRowFrame {
            titleToFirstDetailGap = formStack.isFlipped
                ? firstDetailRowFrame.minY - titleRowFrame.maxY
                : titleRowFrame.minY - firstDetailRowFrame.maxY
        } else {
            titleToFirstDetailGap = nil
        }

        let bounds = view.bounds
        let horizontallyContained: (NSRect, NSRect) -> Bool = { outer, inner in
            inner.minX >= outer.minX - 0.5
                && inner.maxX <= outer.maxX + 0.5
                && inner.width > 0
        }
        let fullyContained: (NSRect, NSRect) -> Bool = { outer, inner in
            horizontallyContained(outer, inner)
                && inner.minY >= outer.minY - 0.5
                && inner.maxY <= outer.maxY + 0.5
                && inner.height > 0
        }
        let fileKind = kind == .image || kind == .pdf || kind == .video || kind == .skill

        return CapsulePaneLayoutSnapshot(
            rootFrame: view.frame,
            headerToToolbarGap: headerToToolbarGap,
            formTopGap: formTopGap,
            toolbarTop: toolbarTop,
            editorTop: editorTop,
            tabStripFrame: tabStripFrame,
            listFrame: listFrame,
            editorFrame: editorFrame,
            actionsFrame: actionsFrame,
            previewFrame: previewFrame,
            imagePreviewFrame: imagePreviewFrame,
            copyButtonFrame: copyButtonFrame,
            titleRowHeight: titleRowFrame?.height,
            firstDetailRowHeight: firstDetailRowFrame?.height,
            titleToFirstDetailGap: titleToFirstDetailGap,
            bottomSpacerHeight: formBottomSpacer?.frame.height,
            horizontalContentFits: horizontallyContained(bounds, listFrame)
                && horizontallyContained(bounds, editorFrame)
                && listFrame.maxX < editorFrame.minX,
            actionsAreVisible: fullyContained(editorFrame, actionsFrame),
            previewFitsEditorWidth: previewFrame.map {
                horizontallyContained(editorFrame, $0)
                    && $0.width <= Self.maximumPreviewWidth + 0.5
                    && (159...361).contains($0.height)
            } ?? true,
            imagePreviewFitsContainer: {
                guard let previewFrame, let imagePreviewFrame else { return true }
                return fullyContained(previewFrame, imagePreviewFrame)
            }(),
            imagePreviewUsesAspectFit: imagePreviewView.map {
                $0.imageScaling == .scaleProportionallyUpOrDown
            } ?? true,
            formMatchesClipWidth: abs(formFrame.width - clipFrame.width) <= 0.5,
            copyButtonIsVisible: !fileKind || copyButtonFrame.map {
                fullyContained(editorFrame, $0)
            } == true,
            hasAmbiguousLayout: view.hasAmbiguousLayout
                || editorContainer.hasAmbiguousLayout
                || listContainer.hasAmbiguousLayout
        )
    }

    private func layoutCurrentViewForSmoke() {
        view.needsUpdateConstraints = true
        view.updateConstraintsForSubtreeIfNeeded()
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        editorScrollView.layoutSubtreeIfNeeded()
        formStack.layoutSubtreeIfNeeded()
    }

    /// Native smoke hook that inspects control classes and labels only. It
    /// intentionally uses empty values so no credential can enter failure text.
    func passwordEditorSnapshotForSmoke(
        plaintextVisible: Bool
    ) -> CapsulePasswordEditorSnapshot {
        _ = view
        passwordRevealTimer?.invalidate()
        passwordRevealTimer = nil
        selectedKind = .password
        tabStrip.select(.saved(.password))
        draft = .empty(kind: .password)
        draft.content = "- 示例：值"
        editorDirty = false
        passwordRevealState.conceal()
        if plaintextVisible {
            passwordRevealState.reveal(now: Date())
        }
        renderEditor()
        let snapshot = CapsulePasswordEditorSnapshot(
            revealButtonTitle: passwordRevealButton?.title ?? "",
            revealRequiresChordAuthentication: true,
            // The body exists as an editable view only while revealed, so
            // concealment is the absence of the control rather than a mask.
            secretIsConcealed: passwordSecretTextView == nil,
            plaintextAllowsSelection: passwordSecretTextView?.isSelectable
                ?? false,
            plaintextIsAccessibilityElement: passwordSecretTextView?
                .isAccessibilityElement() ?? false,
            hasUnsavedChanges: editorDirty
        )
        passwordRevealState.conceal()
        renderEditor()
        return snapshot
    }

    func validatesEntryRowPointerForSmoke() -> Bool {
        let cell = CapsuleWindowEntryCell()
        let enabled = cell.pointingHandCursorKindForSmoke
        cell.isPointingHandEnabled = false
        return enabled == .pointingHand
            && cell.pointingHandCursorKindForSmoke == .arrow
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView,
                   viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("capsule-entry-cell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self)
            as? CapsuleWindowEntryCell ?? CapsuleWindowEntryCell()
        cell.identifier = identifier
        cell.configure(row: rows[row], selected: tableView.selectedRow == row)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !applyingSelection else { return }
        let requestedRow = tableView.selectedRow
        guard confirmDiscardChangesIfNeeded() else {
            restoreTableSelectionForDraft()
            return
        }
        cancelPendingReload()
        selectRow(at: requestedRow)
        tableView.reloadData()
    }

    func controlTextDidChange(_ notification: Notification) {
        editorDirty = true
        guard let field = notification.object as? NSTextField else { return }
        if field === assetPathField || field === skillPathField {
            fileCopyButton?.isEnabled = !field.stringValue.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty
        }
        guard field === assetPathField,
              draft.kind == .image || draft.kind == .pdf || draft.kind == .video,
              let preview = assetPreviewContainer else { return }
        // Keep the preview guard in sync with the visible field immediately.
        // Otherwise a late decode for the old path can repaint this editor.
        draft.content = field.stringValue
        imagePreviewView = nil
        loadAssetPreview(kind: draft.kind, path: draft.content, in: preview)
    }

    func textDidChange(_ notification: Notification) {
        editorDirty = true
    }

    private func scheduleReload(after delay: TimeInterval) {
        searchReloadTimer?.invalidate()
        searchReloadTimer = nil
        reloadGeneration &+= 1
        let generation = reloadGeneration
        let kind = selectedKind
        let query = searchField.stringValue
        let preferredID = draft.id
        let begin = { [weak self] in
            self?.performReload(
                generation: generation,
                kind: kind,
                query: query,
                preferredID: preferredID
            )
        }
        if delay > 0 {
            searchReloadTimer = Timer.scheduledTimer(
                withTimeInterval: delay,
                repeats: false
            ) { _ in begin() }
        } else {
            begin()
        }
    }

    private func performReload(
        generation: UInt64,
        kind: CapsuleEntryKind,
        query: String,
        preferredID: UUID?
    ) {
        setStatus(query.isEmpty ? "正在读取本地 Capsule" : "正在本地搜索")
        let repository = self.repository
        reloadQueue.async { [weak self] in
            let result = Result {
                try repository.list(kind: kind, query: query)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.reloadGeneration == generation else { return }
                self.applyReloadResult(
                    result,
                    kind: kind,
                    preferredID: preferredID
                )
            }
        }
    }

    private func applyReloadResult(
        _ result: Result<[CapsuleWindowEntryRow], Error>,
        kind: CapsuleEntryKind,
        preferredID: UUID?
    ) {
        switch result {
        case let .success(rows):
            self.rows = rows
            countLabel.stringValue = CapsuleRailCountText.items(rows.count)
            tableView.reloadData()
            if editorDirty, draft.kind == kind {
                if let id = draft.id,
                   let index = rows.firstIndex(where: { $0.id == id }) {
                    selectTableRow(index)
                } else {
                    applyingSelection = true
                    tableView.deselectAll(nil)
                    applyingSelection = false
                }
                setStatus(draft.id == nil ? "新条目尚未保存" : "本地列表已变化；当前编辑尚未保存")
                return
            }
            if let preferredID,
               let index = rows.firstIndex(where: { $0.id == preferredID }) {
                selectTableRow(index)
                // Refresh the exact record, not only the list projection. Two
                // visible panes must never overwrite a newer external edit
                // with a stale draft.
                guard selectRow(at: index) else { return }
            } else if CapsuleWindowSelectionRules
                .allowsAutomaticFirstSelection(kind: kind), !rows.isEmpty {
                selectTableRow(0)
                guard selectRow(at: 0) else { return }
            } else {
                applyingSelection = true
                tableView.deselectAll(nil)
                applyingSelection = false
                draft = .empty(kind: kind)
                editorDirty = false
                renderEditor()
            }
            setStatus(
                rows.isEmpty
                    ? "暂无 \(kind.displayName) 条目"
                    : "\(rows.count) 条本地记录"
            )
        case let .failure(error):
            rows = []
            countLabel.stringValue = ""
            tableView.reloadData()
            setStatus(error.localizedDescription, isError: true)
        }
    }

    private func selectTableRow(_ index: Int) {
        applyingSelection = true
        tableView.selectRowIndexes(
            IndexSet(integer: index),
            byExtendingSelection: false
        )
        applyingSelection = false
        tableView.scrollRowToVisible(index)
        tableView.reloadData()
    }

    private func restoreTableSelectionForDraft() {
        applyingSelection = true
        if let id = draft.id,
           let index = rows.firstIndex(where: { $0.id == id }) {
            tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        } else {
            tableView.deselectAll(nil)
        }
        applyingSelection = false
        tableView.reloadData()
    }

    private func cancelPendingReload() {
        searchReloadTimer?.invalidate()
        searchReloadTimer = nil
        reloadGeneration &+= 1
    }

    private func configureEditor() {
        editorContainer.wantsLayer = true
        editorContainer.layer?.cornerRadius = 6
        editorContainer.layer?.borderWidth = 1

        formStack.orientation = .vertical
        formStack.alignment = .leading
        formStack.spacing = 10
        formStack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        formStack.translatesAutoresizingMaskIntoConstraints = false

        // NSStackView can be the scroll document directly. Binding both width
        // and minimum height to the clip view keeps the form top-aligned while
        // still allowing Password fields to grow and scroll.
        editorScrollView.documentView = formStack
        NSLayoutConstraint.activate([
            formStack.widthAnchor.constraint(equalTo: editorScrollView.contentView.widthAnchor),
            formStack.heightAnchor.constraint(
                greaterThanOrEqualTo: editorScrollView.contentView.heightAnchor
            ),
        ])
        editorScrollView.drawsBackground = false
        editorScrollView.hasVerticalScroller = true
        editorScrollView.autohidesScrollers = true
        editorScrollView.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = MailboxTerminalTypography.font(ofSize: 9)
        statusLabel.lineBreakMode = .byTruncatingMiddle
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        statusLabel.setContentCompressionResistancePriority(
            .defaultLow,
            for: .horizontal
        )
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        deleteButton.target = self
        deleteButton.action = #selector(deleteCurrent)
        deleteButton.bezelStyle = .inline
        deleteButton.font = MailboxTerminalTypography.font(ofSize: 10)
        saveButton.target = self
        saveButton.action = #selector(saveCurrent)
        saveButton.keyEquivalent = "s"
        saveButton.keyEquivalentModifierMask = [.command]
        saveButton.bezelStyle = .rounded
        saveButton.font = MailboxTerminalTypography.font(
            ofSize: 10,
            weight: .semibold
        )
        let actions = NSStackView(views: [statusLabel, deleteButton, saveButton])
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = 8
        actions.translatesAutoresizingMaskIntoConstraints = false
        editorActions = actions

        editorContainer.addSubview(editorScrollView)
        editorContainer.addSubview(actions)
        NSLayoutConstraint.activate([
            editorScrollView.leadingAnchor.constraint(equalTo: editorContainer.leadingAnchor),
            editorScrollView.trailingAnchor.constraint(equalTo: editorContainer.trailingAnchor),
            editorScrollView.topAnchor.constraint(equalTo: editorContainer.topAnchor),
            editorScrollView.bottomAnchor.constraint(equalTo: actions.topAnchor, constant: -8),

            actions.leadingAnchor.constraint(equalTo: editorContainer.leadingAnchor, constant: 16),
            actions.trailingAnchor.constraint(equalTo: editorContainer.trailingAnchor, constant: -16),
            actions.bottomAnchor.constraint(equalTo: editorContainer.bottomAnchor, constant: -12),
        ])
    }

    private func renderEditor(scrollToTop: Bool = true) {
        guard isViewLoaded else { return }
        mediaPreviewOperation?.cancel()
        mediaPreviewOperation = nil
        mediaPreviewGeneration &+= 1
        fileCopyGeneration &+= 1
        for view in formStack.arrangedSubviews {
            formStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        titleField = nil
        contentTextView = nil
        skillPathField = nil
        urlContentField = nil
        assetPathField = nil
        assetPreviewContainer = nil
        imagePreviewView = nil
        titleFormRow = nil
        firstDetailFormRow = nil
        formBottomSpacer = nil
        fileCopyButton = nil
        passwordSecretTextView = nil
        previousPasswordFields = []
        passwordRevealButton = nil

        let mode = draft.id == nil ? "NEW" : "EDIT"
        let heading = NSTextField(
            labelWithString: "// \(mode) \(draft.kind.displayName.uppercased())"
        )
        heading.font = MailboxTerminalTypography.font(
            ofSize: 10,
            weight: .semibold
        )
        heading.textColor = RimeUI.accentTextColor
        if draft.kind == .password {
            let revealButton = RimePointingHandButton(
                title: passwordRevealState.isPlaintextVisible
                    ? "隐藏明文"
                    : "查看明文",
                target: self,
                action: #selector(togglePasswordPlaintext)
            )
            revealButton.bezelStyle = .inline
            revealButton.font = MailboxTerminalTypography.font(
                ofSize: 9,
                weight: .semibold
            )
            revealButton.setAccessibilityLabel(
                passwordRevealState.isPlaintextVisible
                    ? "隐藏密码明文"
                    : "查看密码明文"
            )
            revealButton.setContentHuggingPriority(.required, for: .horizontal)
            passwordRevealButton = revealButton

            let headingRow = NSStackView(views: [
                heading,
                NSView(),
                revealButton,
            ])
            headingRow.orientation = .horizontal
            headingRow.alignment = .centerY
            headingRow.spacing = 8
            addFormRow(headingRow)
        } else {
            addFormRow(heading)
        }

        let title = NSTextField(string: draft.title)
        title.placeholderString = "标题"
        title.font = MailboxTerminalTypography.font(ofSize: 12)
        title.setAccessibilityLabel("标题")
        title.delegate = self
        titleField = title
        titleFormRow = addField(label: "TITLE", field: title)

        switch draft.kind {
        case .note:
            let textView = makeContentTextView(text: draft.content)
            contentTextView = textView
            firstDetailFormRow = addTextArea(
                label: "NOTE · MARKDOWN",
                textView: textView
            )
        case .skill:
            let pathField = NSTextField(string: draft.content)
            pathField.placeholderString = "/Users/name/path/to/skill"
            pathField.font = MailboxTerminalTypography.font(ofSize: 11)
            pathField.setAccessibilityLabel("Skill 绝对路径")
            pathField.delegate = self
            pathField.setContentCompressionResistancePriority(
                .defaultLow,
                for: .horizontal
            )
            skillPathField = pathField
            let chooseButton = RimePointingHandButton(
                title: "选择…",
                target: self,
                action: #selector(chooseSkillFolder)
            )
            chooseButton.bezelStyle = .rounded
            chooseButton.font = MailboxTerminalTypography.font(ofSize: 10)
            chooseButton.setContentHuggingPriority(.required, for: .horizontal)
            let copyButton = makeFileCopyButton(
                title: "复制文件/文件夹",
                accessibilityLabel: "复制 Skill 文件或文件夹"
            )
            let row = NSStackView(views: [
                pathField,
                chooseButton,
                copyButton,
            ])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 8
            firstDetailFormRow = addField(label: "ABSOLUTE PATH", field: row)
        case .image, .pdf, .video:
            addAssetFields(kind: draft.kind)
        case .password:
            addPasswordFields()
        }

        if draft.kind != .note {
            addFixedFormBottomSpacer()
        }

        deleteButton.isEnabled = draft.id != nil
        saveButton.title = draft.id == nil ? "创建" : "保存"
        if scrollToTop {
            let generation = mediaPreviewGeneration
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      generation == self.mediaPreviewGeneration,
                      self.isViewLoaded else { return }
                self.scrollEditorToTop()
            }
        }
    }

    private func scrollEditorToTop() {
        editorScrollView.layoutSubtreeIfNeeded()
        formStack.layoutSubtreeIfNeeded()
        let clip = editorScrollView.contentView
        let y = formStack.isFlipped
            ? formStack.bounds.minY
            : max(
                formStack.bounds.minY,
                formStack.bounds.maxY - clip.bounds.height
            )
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: y))
        editorScrollView.reflectScrolledClipView(clip)
    }

    /// Title plus one encrypted Markdown body. Entries hold different shapes
    /// of secret — API keys, credential pairs, recovery phrases — so the body
    /// is free-form, and it is only rendered or editable once the passcode has
    /// been entered.
    private func addPasswordFields() {
        guard passwordRevealState.isPlaintextVisible else {
            passwordSecretTextView = nil
            firstDetailFormRow = addField(
                label: "SECRET · SECURE",
                field: makeConcealedSecretPlaceholder()
            )
            return
        }
        let textView = makeContentTextView(text: draft.content)
        passwordSecretTextView = textView
        firstDetailFormRow = addTextArea(
            label: "SECRET · MARKDOWN · SECURE",
            textView: textView
        )
    }

    /// Stands in for the body while it is concealed. It shows that a secret
    /// exists without hinting at its length or shape.
    private func makeConcealedSecretPlaceholder() -> NSView {
        let label = NSTextField(labelWithString: "已加密 · 输入口令后查看与编辑")
        label.font = MailboxTerminalTypography.font(ofSize: 11)
        label.textColor = RimeUI.textMuted
        label.setAccessibilityLabel("敏感信息已加密，需要口令才能查看")
        let box = NSView()
        box.wantsLayer = true
        box.layer?.cornerRadius = 6
        box.layer?.borderWidth = 1
        box.layer?.borderColor = RimeUI.border.cgColor
        box.layer?.backgroundColor = RimeUI.surface2.cgColor
        label.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(label)
        NSLayoutConstraint.activate([
            // Stays within the compact first-row height the other fixed-form
            // kinds use, so a locked entry keeps the pane's usual shape.
            box.heightAnchor.constraint(equalToConstant: 32),
            label.leadingAnchor.constraint(equalTo: box.leadingAnchor,
                                           constant: 10),
            label.centerYAnchor.constraint(equalTo: box.centerYAnchor),
        ])
        return box
    }

    @discardableResult
    private func addField(
        label: String,
        field: NSView,
        expandsVertically: Bool = false
    ) -> NSView {
        let stack = NSStackView(views: [fieldLabel(label), field])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 5
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        addFormRow(stack, expandsVertically: expandsVertically)
        return stack
    }

    private func addFormRow(
        _ row: NSView,
        expandsVertically: Bool = false
    ) {
        row.translatesAutoresizingMaskIntoConstraints = false
        row.setContentHuggingPriority(
            expandsVertically ? .defaultLow : .required,
            for: .vertical
        )
        row.setContentCompressionResistancePriority(.required, for: .vertical)
        formStack.addArrangedSubview(row)
        row.widthAnchor.constraint(
            equalTo: formStack.widthAnchor,
            constant: -(formStack.edgeInsets.left + formStack.edgeInsets.right)
        ).isActive = true
    }

    @discardableResult
    private func addTextArea(label: String, textView: NSTextView) -> NSView {
        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.drawsBackground = true
        scroll.backgroundColor = RimeUI.surface3
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        return addField(label: label, field: scroll, expandsVertically: true)
    }

    private func addFixedFormBottomSpacer() {
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(
            NSLayoutConstraint.Priority(rawValue: 1),
            for: .vertical
        )
        spacer.setContentCompressionResistancePriority(
            NSLayoutConstraint.Priority(rawValue: 1),
            for: .vertical
        )
        formStack.addArrangedSubview(spacer)
        NSLayoutConstraint.activate([
            spacer.widthAnchor.constraint(
                equalTo: formStack.widthAnchor,
                constant: -(formStack.edgeInsets.left + formStack.edgeInsets.right)
            ),
            spacer.heightAnchor.constraint(greaterThanOrEqualToConstant: 0),
        ])
        formBottomSpacer = spacer
    }

    private func addAssetFields(kind: CapsuleEntryKind) {
        precondition(kind == .image || kind == .pdf || kind == .video)
        let pathField = NSTextField(string: draft.content)
        pathField.placeholderString = kind == .image
            ? "/Users/name/Pictures/example.png"
            : kind == .video ? "/Users/name/Movies/example.mp4" : "/Users/name/Documents/example.pdf"
        pathField.font = MailboxTerminalTypography.font(ofSize: 11)
        pathField.setAccessibilityLabel("\(kind.displayName) 绝对路径")
        pathField.delegate = self
        pathField.setContentCompressionResistancePriority(
            .defaultLow,
            for: .horizontal
        )
        assetPathField = pathField

        let chooseButton = RimePointingHandButton(
            title: kind == .image ? "选择图片…" : kind == .video ? "选择视频…" : "选择 PDF…",
            target: self,
            action: #selector(chooseAssetFile)
        )
        chooseButton.bezelStyle = .rounded
        chooseButton.font = MailboxTerminalTypography.font(ofSize: 10)
        chooseButton.setContentHuggingPriority(.required, for: .horizontal)
        let copyButton = makeFileCopyButton(
            title: kind == .image ? "复制图片" : "复制文件",
            accessibilityLabel: kind == .image
                ? "复制 Capsule 图片"
                : kind == .video ? "复制 Capsule 视频文件" : "复制 Capsule PDF 文件"
        )
        let pathRow = NSStackView(views: [pathField, chooseButton, copyButton])
        pathRow.orientation = .horizontal
        pathRow.alignment = .centerY
        pathRow.spacing = 8
        firstDetailFormRow = addField(label: "ABSOLUTE PATH", field: pathRow)

        let preview = NSView()
        preview.wantsLayer = true
        preview.layer?.backgroundColor = RimeUI.surface3.cgColor
        preview.layer?.borderColor = RimeUI.border.cgColor
        preview.layer?.borderWidth = 1
        preview.layer?.cornerRadius = 5
        preview.layer?.masksToBounds = true
        let adaptiveHeight = preview.heightAnchor.constraint(
            equalTo: preview.widthAnchor,
            multiplier: 9.0 / 16.0
        )
        adaptiveHeight.priority = .defaultHigh
        NSLayoutConstraint.activate([
            preview.heightAnchor.constraint(greaterThanOrEqualToConstant: 160),
            preview.heightAnchor.constraint(lessThanOrEqualToConstant: 360),
            adaptiveHeight,
        ])
        assetPreviewContainer = preview

        loadAssetPreview(kind: kind, path: draft.content, in: preview)
        addBoundedPreviewField(preview)
    }

    private func addBoundedPreviewField(_ preview: NSView) {
        let host = NSView()
        host.translatesAutoresizingMaskIntoConstraints = false
        preview.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(preview)
        let fillAvailableWidth = preview.widthAnchor.constraint(
            equalTo: host.widthAnchor
        )
        fillAvailableWidth.priority = NSLayoutConstraint.Priority(rawValue: 999)
        NSLayoutConstraint.activate([
            preview.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            preview.leadingAnchor.constraint(
                greaterThanOrEqualTo: host.leadingAnchor
            ),
            preview.trailingAnchor.constraint(
                lessThanOrEqualTo: host.trailingAnchor
            ),
            preview.topAnchor.constraint(equalTo: host.topAnchor),
            preview.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            preview.widthAnchor.constraint(
                lessThanOrEqualToConstant: Self.maximumPreviewWidth
            ),
            fillAvailableWidth,
        ])
        addField(label: "PREVIEW", field: host)
    }

    private func makeFileCopyButton(
        title: String,
        accessibilityLabel: String
    ) -> NSButton {
        let button = RimePointingHandButton(
            title: title,
            target: self,
            action: #selector(copyCurrentFile)
        )
        button.bezelStyle = .rounded
        button.font = MailboxTerminalTypography.font(ofSize: 10)
        button.setAccessibilityLabel(accessibilityLabel)
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.isEnabled = !draft.content.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty
        fileCopyButton = button
        return button
    }

    private func loadAssetPreview(
        kind: CapsuleEntryKind,
        path: String,
        in container: NSView
    ) {
        mediaPreviewOperation?.cancel()
        mediaPreviewOperation = nil
        mediaPreviewGeneration &+= 1
        let generation = mediaPreviewGeneration
        guard !path.isEmpty else {
            installAssetPreviewMessage(
                kind == .image
                    ? "选择图片后在这里预览"
                    : "选择 PDF 后在这里预览",
                in: container
            )
            return
        }
        installAssetPreviewMessage("正在读取本机文件…", in: container)
        mediaPreviewOperation = mediaPreviewLoader.load(
            kind: kind,
            path: path
        ) { [weak self, weak container] result in
            guard let self,
                  let container,
                  generation == self.mediaPreviewGeneration,
                  self.draft.kind == kind,
                  self.draft.content == path,
                  container.superview != nil else { return }
            container.subviews.forEach { $0.removeFromSuperview() }
            switch result {
            case let .image(image):
                let imageView = self.makeAssetPreviewImageView(
                    image: image,
                    accessibilityLabel: "图片预览"
                )
                container.addSubview(imageView)
                NSLayoutConstraint.activate([
                    imageView.leadingAnchor.constraint(
                        equalTo: container.leadingAnchor,
                        constant: 8
                    ),
                    imageView.trailingAnchor.constraint(
                        equalTo: container.trailingAnchor,
                        constant: -8
                    ),
                    imageView.topAnchor.constraint(
                        equalTo: container.topAnchor,
                        constant: 8
                    ),
                    imageView.bottomAnchor.constraint(
                        equalTo: container.bottomAnchor,
                        constant: -8
                    ),
                ])
                self.imagePreviewView = imageView
            case let .pdf(image, pageCount):
                let imageView = self.makeAssetPreviewImageView(
                    image: image,
                    accessibilityLabel: "PDF 第 1 页预览，共 \(pageCount) 页"
                )
                let pageLabel = NSTextField(
                    labelWithString: "第 1 页预览 · 共 \(pageCount) 页"
                )
                pageLabel.font = MailboxTerminalTypography.font(ofSize: 9)
                pageLabel.textColor = RimeUI.textSecondary
                pageLabel.alignment = .center
                pageLabel.translatesAutoresizingMaskIntoConstraints = false
                container.addSubview(imageView)
                container.addSubview(pageLabel)
                NSLayoutConstraint.activate([
                    imageView.leadingAnchor.constraint(
                        equalTo: container.leadingAnchor
                    ),
                    imageView.trailingAnchor.constraint(
                        equalTo: container.trailingAnchor
                    ),
                    imageView.topAnchor.constraint(equalTo: container.topAnchor),
                    imageView.bottomAnchor.constraint(
                        equalTo: pageLabel.topAnchor,
                        constant: -4
                    ),
                    pageLabel.leadingAnchor.constraint(
                        equalTo: container.leadingAnchor,
                        constant: 8
                    ),
                    pageLabel.trailingAnchor.constraint(
                        equalTo: container.trailingAnchor,
                        constant: -8
                    ),
                    pageLabel.bottomAnchor.constraint(
                        equalTo: container.bottomAnchor,
                        constant: -8
                    ),
                ])
                self.imagePreviewView = imageView
            case .unavailable:
                self.installAssetPreviewMessage(
                    "无法读取文件；请检查路径、格式或文件大小",
                    in: container
                )
            }
        }
    }

    private func makeAssetPreviewImageView(
        image: CGImage,
        accessibilityLabel: String
    ) -> NSImageView {
        let imageView = NSImageView()
        imageView.image = NSImage(
            cgImage: image,
            size: NSSize(width: image.width, height: image.height)
        )
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        imageView.setAccessibilityLabel(accessibilityLabel)
        // Scaling affects drawing only. Without these priorities, AppKit uses
        // the thumbnail's pixel dimensions as an intrinsic point size and can
        // enlarge the scroll document and its owning window after async load.
        imageView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        imageView.setContentHuggingPriority(.defaultLow, for: .vertical)
        imageView.setContentCompressionResistancePriority(
            .defaultLow,
            for: .horizontal
        )
        imageView.setContentCompressionResistancePriority(
            .defaultLow,
            for: .vertical
        )
        imageView.translatesAutoresizingMaskIntoConstraints = false
        return imageView
    }

    private func installAssetPreviewMessage(
        _ message: String,
        in container: NSView
    ) {
        container.subviews.forEach { $0.removeFromSuperview() }
        let label = NSTextField(labelWithString: message)
        label.font = MailboxTerminalTypography.font(ofSize: 10)
        label.textColor = RimeUI.textSecondary
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            label.leadingAnchor.constraint(
                greaterThanOrEqualTo: container.leadingAnchor,
                constant: 16
            ),
            label.trailingAnchor.constraint(
                lessThanOrEqualTo: container.trailingAnchor,
                constant: -16
            ),
        ])
    }

    private func fieldLabel(_ value: String) -> NSTextField {
        let label = NSTextField(labelWithString: value)
        label.font = MailboxTerminalTypography.font(
            ofSize: 9,
            weight: .semibold
        )
        label.textColor = RimeUI.textSecondary
        label.alignment = .left
        return label
    }

    private func makeSecureField(
        value: String,
        label: String,
        policyField: CapsulePasswordEditorField
    ) -> NSSecureTextField {
        precondition(
            CapsulePasswordEditorSecurityPolicy.usesSecureControl(policyField)
        )
        let field = NSSecureTextField(string: value)
        field.placeholderString = label
        field.font = MailboxTerminalTypography.font(ofSize: 11)
        field.setAccessibilityLabel(label + "，安全输入")
        field.delegate = self
        return field
    }

    private func makePasswordEditorField(
        value: String,
        label: String,
        policyField: CapsulePasswordEditorField
    ) -> NSTextField {
        precondition(CapsulePasswordEditorSecurityPolicy.mayReveal(policyField))
        if CapsulePasswordEditorSecurityPolicy.usesSecureControl(
            policyField,
            plaintextVisible: passwordRevealState.isPlaintextVisible
        ) {
            return makeSecureField(
                value: value,
                label: label,
                policyField: policyField
            )
        }

        // Plaintext reveal is view-only. Keeping this field non-selectable
        // prevents an accidental copy/cut from placing the credential on the
        // general pasteboard. Hiding it restores the editable secure control.
        let field = NSTextField(string: value)
        field.placeholderString = label
        field.font = MailboxTerminalTypography.font(ofSize: 11)
        field.isEditable = false
        field.isSelectable = false
        field.setAccessibilityElement(false)
        return field
    }

    private func makeContentTextView(text: String) -> NSTextView {
        let textView = NSTextView(frame: .zero)
        textView.string = text
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.font = MailboxTerminalTypography.font(ofSize: 12)
        textView.textColor = RimeUI.textPrimary
        textView.backgroundColor = RimeUI.surface3
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.setAccessibilityLabel("Capsule 内容")
        textView.delegate = self
        return textView
    }

    private func captureDraftFromFields() {
        draft.title = titleField?.stringValue ?? draft.title
        switch draft.kind {
        case .note:
            draft.content = contentTextView?.string ?? draft.content
        case .skill:
            draft.content = skillPathField?.stringValue ?? draft.content
        case .image, .pdf, .video:
            draft.content = assetPathField?.stringValue ?? draft.content
        case .password:
            // Only read back a body the user could actually see; a concealed
            // editor has no text view and must not blank the stored secret.
            if let passwordSecretTextView {
                draft.content = passwordSecretTextView.string
            }
        }
    }

    private func schedulePasswordAutoConceal() {
        passwordRevealTimer?.invalidate()
        passwordRevealTimer = nil
        guard let delay = passwordRevealState.remainingDuration(now: Date()) else {
            return
        }
        passwordRevealTimer = Timer.scheduledTimer(
            withTimeInterval: max(0.001, delay),
            repeats: false
        ) { [weak self] _ in
            guard let self else { return }
            self.passwordRevealTimer = nil
            guard self.passwordRevealState.concealIfExpired(now: Date()) else {
                self.schedulePasswordAutoConceal()
                return
            }
            self.captureDraftFromFields()
            self.renderEditor(scrollToTop: false)
        }
    }

    @discardableResult
    private func selectRow(at index: Int) -> Bool {
        guard rows.indices.contains(index) else { return false }
        concealPasswordPlaintext()
        do {
            let loadedDraft = try repository.draft(for: rows[index])
            draft = loadedDraft
            editorDirty = false
            renderEditor()
            setStatus("已加载本地条目")
            return true
        } catch {
            if draft.kind == .password,
               !rows.contains(where: { $0.id == draft.id }) {
                draft = .empty(kind: .password)
                editorDirty = false
                renderEditor()
            }
            restoreTableSelectionForDraft()
            setStatus(error.localizedDescription, isError: true)
            return false
        }
    }

    private func setStatus(_ value: String, isError: Bool = false) {
        statusLabel.stringValue = value
        statusLabel.textColor = isError ? .systemRed : RimeUI.textSecondary
    }

    /// Switches the list and editor to `kind`, confirming an unsaved draft
    /// first. The tab row always ends up showing the kind actually selected.
    func selectKind(_ requestedKind: CapsuleEntryKind) {
        guard isViewLoaded else { return }
        guard requestedKind != selectedKind else {
            tabStrip.select(.saved(selectedKind))
            return
        }
        concealPasswordPlaintext()
        guard confirmDiscardChangesIfNeeded() else {
            tabStrip.select(.saved(selectedKind))
            return
        }
        selectedKind = requestedKind
        tabStrip.select(.saved(selectedKind))
        searchField.placeholderString = selectedKind == .password
            ? "仅搜索密码标题"
            : "搜索标题或内容"
        cancelPendingReload()
        draft = .empty(kind: selectedKind)
        editorDirty = false
        renderEditor()
        reloadFromStore()
    }

    private func tabSelected(_ tab: CapsuleRailTab) {
        guard let kind = tab.savedKind else {
            tabStrip.select(.saved(selectedKind))
            onReturnToRail?(.recent)
            return
        }
        selectKind(kind)
    }

    @objc private func returnToRailPressed() {
        onReturnToRail?(.saved(selectedKind))
    }

    @objc private func closePressed() {
        view.window?.performClose(nil)
    }

    /// Esc returns to the rail. An input method's marked text never gets
    /// here: the input method consumes that Esc first.
    override func cancelOperation(_ sender: Any?) {
        onReturnToRail?(.saved(selectedKind))
    }

    @objc private func searchChanged() {
        concealPasswordPlaintext()
        scheduleReload(after: Self.searchDebounce)
    }

    @objc private func createNew() {
        concealPasswordPlaintext()
        guard confirmDiscardChangesIfNeeded() else { return }
        cancelPendingReload()
        tableView.deselectAll(nil)
        draft = .empty(kind: selectedKind)
        editorDirty = false
        renderEditor()
        setStatus("新建 \(selectedKind.displayName) 条目")
        view.window?.makeFirstResponder(titleField)
    }

    @objc private func saveCurrent() {
        concealPasswordPlaintext()
        captureDraftFromFields()
        do {
            let saved = try repository.save(draft)
            draft.id = saved.id
            draft.loadedRevision = saved.revision
            editorDirty = false
            if let index = rows.firstIndex(where: { $0.id == saved.id }) {
                rows[index] = saved
                tableView.reloadData()
                selectTableRow(index)
            }
            reloadFromStore()
            setStatus("已保存到本地 Capsule")
        } catch {
            setStatus(error.localizedDescription, isError: true)
        }
    }

    @objc private func deleteCurrent() {
        concealPasswordPlaintext()
        guard let id = draft.id,
              let expectedRevision = draft.loadedRevision,
              let row = rows.first(where: { $0.id == id }),
              let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = "删除「\(row.title)」？"
        alert.informativeText = "该操作会删除本地 Capsule 文件。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            do {
                try self.repository.remove(
                    row,
                    expectedRevision: expectedRevision
                )
                self.cancelPendingReload()
                self.rows.removeAll(where: { $0.id == row.id })
                self.applyingSelection = true
                self.tableView.deselectAll(nil)
                self.applyingSelection = false
                self.tableView.reloadData()
                self.draft = .empty(kind: self.selectedKind)
                self.editorDirty = false
                self.renderEditor()
                self.reloadFromStore()
                self.setStatus("已删除本地条目")
            } catch {
                self.setStatus(error.localizedDescription, isError: true)
            }
        }
    }

    @objc private func chooseSkillFolder() {
        guard let window = view.window else { return }
        let panel = NSOpenPanel()
        panel.title = "选择 Skill 文件或文件夹"
        panel.message = "Capsule 会保存所选项目在当前电脑中的绝对路径。"
        panel.prompt = "选择"
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let path = panel.url?.path else { return }
            self?.skillPathField?.stringValue = path
            self?.fileCopyButton?.isEnabled = true
            self?.editorDirty = true
            self?.setStatus("Skill 路径尚未保存")
        }
    }

    @objc private func chooseAssetFile() {
        guard draft.kind == .image || draft.kind == .pdf || draft.kind == .video,
              let window = view.window else { return }
        captureDraftFromFields()
        let kind = draft.kind
        let panel = NSOpenPanel()
        panel.title = kind == .image ? "选择 Capsule 图片" : "选择 Capsule PDF"
        panel.message = "Capsule 只保存该文件在当前电脑中的绝对路径。"
        panel.prompt = "选择"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = false
        panel.allowedContentTypes = kind == .image ? [.image] : kind == .video ? [.movie, .gif] : [.pdf]
        if !draft.content.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: draft.content)
                .deletingLastPathComponent()
        }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self,
                  response == .OK,
                  let selectedURL = panel.url else { return }
            self.draft.content = selectedURL.standardizedFileURL.path
            self.editorDirty = true
            self.renderEditor()
            self.setStatus("\(kind.displayName) 路径尚未保存")
        }
    }

    @objc private func copyCurrentFile() {
        captureDraftFromFields()
        let kind = draft.kind
        guard kind == .image || kind == .pdf || kind == .video || kind == .skill else {
            setStatus(
                CapsuleFilePasteboardError.unsupportedKind.localizedDescription,
                isError: true
            )
            return
        }
        let path = draft.content
        fileCopyGeneration &+= 1
        let generation = fileCopyGeneration
        let expectedPasteboardChangeCount = NSPasteboard.general.changeCount
        fileCopyButton?.isEnabled = false
        setStatus("正在准备复制…")

        fileCopyQueue.async { [weak self] in
            let result = Result {
                try CapsuleFilePasteboardWriter.prepare(kind: kind, path: path)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, generation == self.fileCopyGeneration else {
                    return
                }
                self.fileCopyButton?.isEnabled = !path.isEmpty
                switch result {
                case let .success(payload):
                    do {
                        try CapsuleFilePasteboardWriter.write(
                            payload,
                            expectedChangeCount: expectedPasteboardChangeCount
                        )
                        switch kind {
                        case .image:
                            self.setStatus("已复制图片")
                        case .video:
                            self.setStatus("已复制视频文件")
                        case .pdf:
                            self.setStatus("已复制 PDF 文件")
                        case .skill:
                            self.setStatus("已复制 Skill 文件或文件夹")
                        case .password, .note:
                            break
                        }
                    } catch {
                        self.setStatus(error.localizedDescription, isError: true)
                    }
                case let .failure(error):
                    self.setStatus(error.localizedDescription, isError: true)
                }
            }
        }
    }

    @objc private func togglePasswordPlaintext() {
        guard draft.kind == .password else { return }
        captureDraftFromFields()
        if passwordRevealState.isPlaintextVisible {
            concealPasswordPlaintext()
            return
        }
        guard let window = view.window else { return }

        passwordChallengeGeneration &+= 1
        let generation = passwordChallengeGeneration
        let expectedID = draft.id
        let challenge = CapsuleRevealPasscodeChallengeController(
            purpose: .verify
        )
        passwordChallengeController?.cancel()
        passwordChallengeController = challenge
        challenge.beginSheet(for: window) { [weak self, weak challenge] success in
            guard let self else { return }
            if self.passwordChallengeController === challenge {
                self.passwordChallengeController = nil
            }
            guard success,
                  self.passwordChallengeGeneration == generation,
                  self.draft.kind == .password,
                  self.draft.id == expectedID,
                  self.view.window === window else { return }
            self.captureDraftFromFields()
            self.passwordRevealState.reveal(now: Date())
            self.schedulePasswordAutoConceal()
            self.renderEditor(scrollToTop: false)
        }
    }

    private func installPrivacyObservers() {
        guard applicationPrivacyObservers.isEmpty,
              workspacePrivacyObservers.isEmpty,
              distributedPrivacyObservers.isEmpty else { return }

        let center = NotificationCenter.default
        for name in [
            NSApplication.didResignActiveNotification,
            NSWindow.didResignKeyNotification,
        ] {
            applicationPrivacyObservers.append(center.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let self else { return }
                if name == NSWindow.didResignKeyNotification,
                   (notification.object as? NSWindow) !== self.view.window {
                    return
                }
                if name == NSWindow.didResignKeyNotification,
                   self.isPresentingPasswordChallengeSheet {
                    // Beginning the authentication sheet makes the parent
                    // Capsule window resign key. Keep the challenge alive;
                    // app deactivation, screen lock, or any later focus loss
                    // still fails closed through the other observers.
                    return
                }
                self.concealPasswordPlaintext()
            })
        }

        let workspace = NSWorkspace.shared.notificationCenter
        for name in [
            NSWorkspace.sessionDidResignActiveNotification,
            NSWorkspace.willSleepNotification,
        ] {
            workspacePrivacyObservers.append(workspace.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.concealPasswordPlaintext()
            })
        }

        let distributed = DistributedNotificationCenter.default()
        distributedPrivacyObservers.append(distributed.addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.concealPasswordPlaintext()
        })
    }
}

private final class CapsuleWindowEntryCell: NSTableCellView {
    private var pointerTrackingArea: NSTrackingArea?
    private var pointerInside = false
    private let kindLabel = NSTextField(labelWithString: "")
    private let titleLabel = NSTextField(labelWithString: "")
    private let previewLabel = NSTextField(labelWithString: "")

    var isPointingHandEnabled = true {
        didSet {
            RimePointingHandCursorRules.enabledDidChange(
                for: self,
                pointerInside: pointerInside,
                enabled: isPointingHandEnabled
            )
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        RimePointingHandCursorRules.updateTrackingArea(
            &pointerTrackingArea,
            for: self
        )
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        RimePointingHandCursorRules.resetCursorRect(
            for: self,
            enabled: isPointingHandEnabled
        )
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        pointerInside = true
        RimePointingHandCursorRules.mouseEntered(
            enabled: isPointingHandEnabled
        )
    }

    override func mouseExited(with event: NSEvent) {
        pointerInside = false
        RimePointingHandCursorRules.mouseExited()
        super.mouseExited(with: event)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        kindLabel.font = MailboxTerminalTypography.font(
            ofSize: 8,
            weight: .semibold
        )
        kindLabel.setContentHuggingPriority(.required, for: .horizontal)
        titleLabel.font = MailboxTerminalTypography.font(
            ofSize: 11,
            weight: .semibold
        )
        titleLabel.lineBreakMode = .byTruncatingTail
        previewLabel.font = MailboxTerminalTypography.font(ofSize: 9)
        previewLabel.lineBreakMode = .byTruncatingTail

        let heading = NSStackView(views: [kindLabel, titleLabel])
        heading.orientation = .horizontal
        heading.alignment = .centerY
        heading.spacing = 7
        let stack = NSStackView(views: [heading, previewLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 11),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            heading.widthAnchor.constraint(equalTo: stack.widthAnchor),
            previewLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    fileprivate var pointingHandCursorKindForSmoke: RimePointingHandCursorKind {
        RimePointingHandCursorRules.kind(enabled: isPointingHandEnabled)
    }

    func configure(row: CapsuleWindowEntryRow, selected: Bool) {
        kindLabel.stringValue = row.kind.displayName.uppercased()
        titleLabel.stringValue = row.title
        previewLabel.stringValue = row.preview
        kindLabel.textColor = selected
            ? RimeUI.accentTextColor
            : RimeUI.textSecondary
        titleLabel.textColor = selected
            ? RimeUI.accentTextColor
            : RimeUI.textPrimary
        previewLabel.textColor = RimeUI.textSecondary
        layer?.backgroundColor = selected
            ? RimeUI.accentGreen.withAlphaComponent(0.10).cgColor
            : NSColor.clear.cgColor
        setAccessibilityLabel(row.accessibilitySummary)
    }
}
