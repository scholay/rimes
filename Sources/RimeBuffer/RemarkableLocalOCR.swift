import AppKit
import CoreGraphics
import Foundation
import PDFKit
import Vision

enum RemarkableOCRLanguageMode: String, CaseIterable, Hashable {
    static let defaultsKey = "plugins.remarkable.ocrLanguage.v1"
    static let defaultMode: Self = .simplifiedChinese

    case simplifiedChinese
    case traditionalChinese
    case english
    case automatic

    var displayName: String {
        switch self {
        case .automatic:
            return "自动识别（繁简混排）"
        case .english:
            return "英文"
        case .simplifiedChinese:
            return "简体中文（推荐）"
        case .traditionalChinese:
            return "繁体中文"
        }
    }

    var workbenchDisplayName: String {
        switch self {
        case .automatic:
            return "自动（繁简混排）"
        case .english:
            return "英文"
        case .simplifiedChinese:
            return "简中（推荐）"
        case .traditionalChinese:
            return "繁中"
        }
    }

    static func configured(in defaults: UserDefaults) -> Self {
        guard let rawValue = defaults.string(forKey: defaultsKey),
              let mode = Self(rawValue: rawValue) else {
            return defaultMode
        }
        return mode
    }
}

enum RemarkableLocalOCRError: Error, Equatable, LocalizedError {
    case pdfTooLarge
    case invalidPDF
    case pageCountMismatch
    case pageOutOfRange
    case invalidPage
    case renderTooLarge
    case renderingFailed
    case recognitionFailed
    case outputTooLarge
    case invalidText
    case cancelled

    var errorDescription: String? {
        switch self {
        case .pdfTooLarge:
            return "reMarkable 返回的 PDF 过大，已停止识别"
        case .invalidPDF:
            return "reMarkable 返回的 PDF 无效或不完整，请重试"
        case .pageCountMismatch:
            return "PDF 页数与 reMarkable 页面目录不一致，请重试"
        case .pageOutOfRange:
            return "当前页在导出的 PDF 中不存在，请重试"
        case .invalidPage:
            return "PDF 当前页无效，无法识别"
        case .renderTooLarge:
            return "PDF 页面尺寸异常，无法安全渲染"
        case .renderingFailed:
            return "无法渲染 reMarkable 当前页"
        case .recognitionFailed:
            return "Mac 本地文字识别失败，请重试"
        case .outputTooLarge:
            return "识别出的文字过多，已停止导入"
        case .invalidText:
            return "没有识别到可用文字，或识别结果包含无效内容"
        case .cancelled:
            return "文字识别已取消"
        }
    }

    var logCode: String {
        switch self {
        case .pdfTooLarge: return "pdf-too-large"
        case .invalidPDF: return "invalid-pdf"
        case .pageCountMismatch: return "page-count-mismatch"
        case .pageOutOfRange: return "page-out-of-range"
        case .invalidPage: return "invalid-page"
        case .renderTooLarge: return "render-too-large"
        case .renderingFailed: return "rendering-failed"
        case .recognitionFailed: return "recognition-failed"
        case .outputTooLarge: return "output-too-large"
        case .invalidText: return "invalid-text"
        case .cancelled: return "cancelled"
        }
    }
}

struct RemarkableOCRResult {
    let text: String
    let observationCount: Int
    let meanConfidence: Float?
}

protocol RemarkablePDFTextRecognizing: AnyObject {
    @discardableResult
    func recognizeText(
        in pdfData: Data,
        pageIndex: Int,
        expectedPageCount: Int,
        language: RemarkableOCRLanguageMode,
        completion: @escaping (
            Result<RemarkableOCRResult, RemarkableLocalOCRError>
        ) -> Void
    ) -> any AITextCancellable
}

struct RemarkableVisionLanguageConfiguration: Equatable {
    let recognitionLanguages: [String]
    let automaticallyDetectsLanguage: Bool
}

/// Vision's supported-language set is fixed for our revision/recognition-level
/// pair during one process lifetime. Cache only successful probes: a transient
/// framework failure remains retryable on the next explicit OCR action.
final class RemarkableVisionLanguageResolver {
    typealias SupportedLanguagesProvider = () throws -> [String]

    private let lock = NSLock()
    private let provider: SupportedLanguagesProvider
    private var cachedSupportedLanguages: Set<String>?

    init(provider: @escaping SupportedLanguagesProvider) {
        self.provider = provider
    }

    func resolve(
        _ mode: RemarkableOCRLanguageMode
    ) throws -> RemarkableVisionLanguageConfiguration {
        let supported: Set<String>
        lock.lock()
        do {
            if let cachedSupportedLanguages {
                supported = cachedSupportedLanguages
            } else {
                let queried = Set(try provider())
                cachedSupportedLanguages = queried
                supported = queried
            }
            lock.unlock()
        } catch {
            lock.unlock()
            throw error
        }

        let preferred: [String]
        let automaticallyDetectsLanguage: Bool
        switch mode {
        case .automatic:
            preferred = ["zh-Hans", "zh-Hant", "en-US"]
            automaticallyDetectsLanguage = true
        case .english:
            preferred = ["en-US"]
            automaticallyDetectsLanguage = false
        case .simplifiedChinese:
            preferred = ["zh-Hans", "en-US"]
            automaticallyDetectsLanguage = false
        case .traditionalChinese:
            preferred = ["zh-Hant", "en-US"]
            automaticallyDetectsLanguage = false
        }

        let available = preferred.filter(supported.contains)
        guard !available.isEmpty else {
            throw RemarkableLocalOCRError.recognitionFailed
        }
        return RemarkableVisionLanguageConfiguration(
            recognitionLanguages: available,
            automaticallyDetectsLanguage: automaticallyDetectsLanguage
        )
    }
}

enum RemarkablePDFKitDocumentValidator {
    static let maximumPDFBytes = 32 * 1_024 * 1_024

    static func isValid(
        data: Data,
        pageIndex: Int,
        expectedPageCount: Int
    ) -> Bool {
        (try? validatedPage(
            data: data,
            pageIndex: pageIndex,
            expectedPageCount: expectedPageCount
        )) != nil
    }

    fileprivate struct ValidatedPage {
        // Keep the document alive for the lifetime of the page and pageRef.
        let document: PDFDocument
        let page: PDFPage
        let pageRef: CGPDFPage
        let bounds: CGRect
    }

    fileprivate static func validatedPage(
        data: Data,
        pageIndex: Int,
        expectedPageCount: Int
    ) throws -> ValidatedPage {
        guard data.count <= maximumPDFBytes else {
            throw RemarkableLocalOCRError.pdfTooLarge
        }
        guard hasCompletePDFEnvelope(data),
              let document = PDFDocument(data: data),
              !document.isLocked else {
            throw RemarkableLocalOCRError.invalidPDF
        }
        guard expectedPageCount > 0,
              document.pageCount == expectedPageCount else {
            throw RemarkableLocalOCRError.pageCountMismatch
        }
        guard pageIndex >= 0, pageIndex < document.pageCount else {
            throw RemarkableLocalOCRError.pageOutOfRange
        }
        guard let page = document.page(at: pageIndex),
              let pageRef = page.pageRef else {
            throw RemarkableLocalOCRError.invalidPage
        }

        let bounds = page.bounds(for: .mediaBox)
        guard bounds.origin.x.isFinite,
              bounds.origin.y.isFinite,
              bounds.width.isFinite,
              bounds.height.isFinite,
              bounds.width > 0,
              bounds.height > 0 else {
            throw RemarkableLocalOCRError.invalidPage
        }
        return ValidatedPage(
            document: document,
            page: page,
            pageRef: pageRef,
            bounds: bounds
        )
    }

    private static func hasCompletePDFEnvelope(_ data: Data) -> Bool {
        let header: [UInt8] = [0x25, 0x50, 0x44, 0x46] // %PDF
        let trailer: [UInt8] = [0x25, 0x25, 0x45, 0x4F, 0x46] // %%EOF
        guard data.count >= header.count + trailer.count,
              data.prefix(header.count).elementsEqual(header) else {
            return false
        }

        var end = data.endIndex
        while end > data.startIndex {
            let previous = data.index(before: end)
            switch data[previous] {
            case 0x09, 0x0A, 0x0C, 0x0D, 0x20:
                end = previous
            default:
                let remaining = data.distance(from: data.startIndex, to: end)
                guard remaining >= trailer.count else { return false }
                let start = data.index(end, offsetBy: -trailer.count)
                return data[start..<end].elementsEqual(trailer)
            }
        }
        return false
    }
}

final class RemarkableAppleVisionOCR: RemarkablePDFTextRecognizing {
    static let renderDPI: CGFloat = 300
    static let maximumRenderedEdge = 4_096
    static let maximumRenderedPixels = 12_000_000
    static let maximumOutputBytes = 1 * 1_024 * 1_024

    private static let queue = DispatchQueue(
        label: "RimeBuffer.RemarkableAppleVisionOCR",
        qos: .userInitiated
    )
    private static let languageResolver = RemarkableVisionLanguageResolver {
        let request = VNRecognizeTextRequest()
        request.revision = VNRecognizeTextRequestRevision3
        request.recognitionLevel = .accurate
        return try request.supportedRecognitionLanguages()
    }

    init() {
        // Move the small, stable Vision capability probe off the first button
        // press. This does not load page data or start recognition.
        Self.queue.async {
            _ = try? Self.languageResolver.resolve(
                RemarkableOCRLanguageMode.defaultMode
            )
        }
    }

    @discardableResult
    func recognizeText(
        in pdfData: Data,
        pageIndex: Int,
        expectedPageCount: Int,
        language: RemarkableOCRLanguageMode,
        completion: @escaping (
            Result<RemarkableOCRResult, RemarkableLocalOCRError>
        ) -> Void
    ) -> any AITextCancellable {
        let task = RemarkableVisionOCRTask(completion: completion)
        Self.queue.async {
            guard !task.isFinished else { return }
            let result: Result<
                RemarkableOCRResult,
                RemarkableLocalOCRError
            > = autoreleasepool {
                Self.recognizeSynchronously(
                    pdfData: pdfData,
                    pageIndex: pageIndex,
                    expectedPageCount: expectedPageCount,
                    language: language,
                    task: task
                )
            }
            task.finish(result)
        }
        return task
    }

    private static func recognizeSynchronously(
        pdfData: Data,
        pageIndex: Int,
        expectedPageCount: Int,
        language: RemarkableOCRLanguageMode,
        task: RemarkableVisionOCRTask
    ) -> Result<RemarkableOCRResult, RemarkableLocalOCRError> {
        guard !task.isCancelled else { return .failure(.cancelled) }

        let validatedPage: RemarkablePDFKitDocumentValidator.ValidatedPage
        do {
            validatedPage = try RemarkablePDFKitDocumentValidator.validatedPage(
                data: pdfData,
                pageIndex: pageIndex,
                expectedPageCount: expectedPageCount
            )
        } catch let error as RemarkableLocalOCRError {
            return .failure(error)
        } catch {
            return .failure(.invalidPDF)
        }

        guard !task.isCancelled else { return .failure(.cancelled) }
        let image: CGImage
        do {
            image = try render(validatedPage)
        } catch let error as RemarkableLocalOCRError {
            return .failure(error)
        } catch {
            return .failure(.renderingFailed)
        }

        guard !task.isCancelled else { return .failure(.cancelled) }
        let request = VNRecognizeTextRequest()
        request.revision = VNRecognizeTextRequestRevision3
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        do {
            try configureLanguages(request, mode: language)
        } catch {
            return .failure(.recognitionFailed)
        }
        guard task.install(request) else {
            return .failure(.cancelled)
        }

        do {
            let handler = VNImageRequestHandler(
                cgImage: image,
                orientation: .up,
                options: [:]
            )
            try handler.perform([request])
        } catch {
            return task.isCancelled
                ? .failure(.cancelled)
                : .failure(.recognitionFailed)
        }
        guard !task.isCancelled else { return .failure(.cancelled) }
        return makeResult(from: request.results ?? [])
    }

    private static func configureLanguages(
        _ request: VNRecognizeTextRequest,
        mode: RemarkableOCRLanguageMode
    ) throws {
        let configuration = try languageResolver.resolve(mode)
        request.recognitionLanguages = configuration.recognitionLanguages
        request.automaticallyDetectsLanguage =
            configuration.automaticallyDetectsLanguage
    }

    private static func render(
        _ validatedPage: RemarkablePDFKitDocumentValidator.ValidatedPage
    ) throws -> CGImage {
        let bounds = validatedPage.bounds
        let pointsPerInch: CGFloat = 72
        let dpiScale = renderDPI / pointsPerInch
        let edgeScale = CGFloat(maximumRenderedEdge)
            / max(bounds.width, bounds.height)
        let pixelScale = sqrt(
            CGFloat(maximumRenderedPixels)
                / (bounds.width * bounds.height)
        )
        let scale = min(dpiScale, edgeScale, pixelScale)
        guard scale.isFinite, scale > 0 else {
            throw RemarkableLocalOCRError.renderTooLarge
        }

        let width = max(1, Int(floor(bounds.width * scale)))
        let height = max(1, Int(floor(bounds.height * scale)))
        guard width <= maximumRenderedEdge,
              height <= maximumRenderedEdge,
              Int64(width) * Int64(height)
                <= Int64(maximumRenderedPixels) else {
            throw RemarkableLocalOCRError.renderTooLarge
        }

        // PDFPage.thumbnail uses PDFKit's own antialiasing and page rendering
        // path. On real reMarkable exports it preserves thin pen-stroke joins
        // more accurately than drawing the underlying CGPDFPage ourselves.
        let thumbnail = validatedPage.page.thumbnail(
            of: CGSize(width: CGFloat(width), height: CGFloat(height)),
            for: .mediaBox
        )
        var proposedRect = CGRect(origin: .zero, size: thumbnail.size)
        guard let image = thumbnail.cgImage(
            forProposedRect: &proposedRect,
            context: nil,
            hints: nil
        ) else {
            throw RemarkableLocalOCRError.renderingFailed
        }
        guard image.width > 0,
              image.height > 0 else {
            throw RemarkableLocalOCRError.renderingFailed
        }
        guard image.width <= maximumRenderedEdge,
              image.height <= maximumRenderedEdge,
              Int64(image.width) * Int64(image.height)
                <= Int64(maximumRenderedPixels) else {
            throw RemarkableLocalOCRError.renderTooLarge
        }
        // Keep both PDFKit objects and the validated pageRef alive until
        // PDFKit has produced the backing CGImage.
        _ = validatedPage.document
        _ = validatedPage.pageRef
        return image
    }

    private static func makeResult(
        from observations: [VNRecognizedTextObservation]
    ) -> Result<RemarkableOCRResult, RemarkableLocalOCRError> {
        let ordered = observations.sorted {
            if $0.boundingBox.maxY != $1.boundingBox.maxY {
                return $0.boundingBox.maxY > $1.boundingBox.maxY
            }
            return $0.boundingBox.minX < $1.boundingBox.minX
        }
        let recognized = ordered.compactMap { observation
            -> (String, Float)? in
            guard let candidate = observation.topCandidates(1).first else {
                return nil
            }
            let text = candidate.string.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !text.isEmpty else { return nil }
            return (text, candidate.confidence)
        }
        guard !recognized.isEmpty else {
            return .failure(.invalidText)
        }

        var lines: [String] = []
        lines.reserveCapacity(recognized.count)
        var outputBytes = 0
        var confidenceTotal: Float = 0
        for (text, confidence) in recognized {
            guard !text.unicodeScalars.contains(where: { $0.value == 0 }) else {
                return .failure(.invalidText)
            }
            let separatorBytes = lines.isEmpty ? 0 : 1
            let nextBytes = text.utf8.count
            guard nextBytes <= maximumOutputBytes - outputBytes - separatorBytes
            else {
                return .failure(.outputTooLarge)
            }
            outputBytes += separatorBytes + nextBytes
            lines.append(text)
            confidenceTotal += confidence
        }

        let meanConfidence = recognized.isEmpty
            ? nil
            : confidenceTotal / Float(recognized.count)
        return .success(RemarkableOCRResult(
            text: lines.joined(separator: "\n"),
            observationCount: recognized.count,
            meanConfidence: meanConfidence
        ))
    }
}

private final class RemarkableVisionOCRTask: AITextCancellable {
    private let lock = NSLock()
    private var request: VNRequest?
    private var completion: ((
        Result<RemarkableOCRResult, RemarkableLocalOCRError>
    ) -> Void)?
    private var cancelled = false
    private var finished = false

    init(
        completion: @escaping (
            Result<RemarkableOCRResult, RemarkableLocalOCRError>
        ) -> Void
    ) {
        self.completion = completion
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }

    func install(_ request: VNRequest) -> Bool {
        lock.lock()
        if cancelled || finished {
            lock.unlock()
            request.cancel()
            return false
        }
        self.request = request
        lock.unlock()
        return true
    }

    func cancel() {
        let request: VNRequest?
        let completion: ((
            Result<RemarkableOCRResult, RemarkableLocalOCRError>
        ) -> Void)?
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        cancelled = true
        finished = true
        request = self.request
        self.request = nil
        completion = self.completion
        self.completion = nil
        lock.unlock()

        request?.cancel()
        completion?(.failure(.cancelled))
    }

    func finish(
        _ result: Result<RemarkableOCRResult, RemarkableLocalOCRError>
    ) {
        let completion: ((
            Result<RemarkableOCRResult, RemarkableLocalOCRError>
        ) -> Void)?
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        request = nil
        completion = self.completion
        self.completion = nil
        lock.unlock()
        completion?(result)
    }
}
