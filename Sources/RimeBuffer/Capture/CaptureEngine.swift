import AppKit
import AVFoundation
import ScreenCaptureKit
import Vision

struct CaptureTarget {
    let display: SCDisplay
    let window: SCWindow?
    /// Top-left pixel-independent display coordinates; nil means full display.
    let rect: CGRect?
}

enum CaptureEngine {
    static func nativeScale(_ target: CaptureTarget) -> CGFloat { max(1, CGFloat(target.display.width) / max(1, target.display.frame.width)) }
    static func content() async throws -> SCShareableContent {
        try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    }
    static func filter(_ target: CaptureTarget, content: SCShareableContent) -> SCContentFilter {
        if let window = target.window { return SCContentFilter(desktopIndependentWindow: window) }
        return SCContentFilter(display: target.display,
            excludingApplications: content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier },
            exceptingWindows: [])
    }
    static func configuration(_ target: CaptureTarget, scale: CGFloat = 2) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        let rect = target.window?.frame ?? target.rect ?? CGRect(origin: .zero, size: target.display.frame.size)
        config.width = max(2, Int(rect.width * scale))
        config.height = max(2, Int(rect.height * scale))
        config.showsCursor = false
        if let crop = target.rect, target.window == nil { config.sourceRect = crop }
        config.queueDepth = 3
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        if #available(macOS 14.0, *) { config.ignoreShadowsSingleWindow = true; config.shouldBeOpaque = false }
        return config
    }
    static func image(_ target: CaptureTarget, content: SCShareableContent, scale: CGFloat? = nil) async throws -> CGImage {
        let filter = filter(target, content: content)
        let config = configuration(target, scale: scale ?? nativeScale(target))
        if #available(macOS 14.0, *) {
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        }
        return try await CaptureSingleFrame.capture(filter: filter, config: config)
    }
    static func recognize(_ image: CGImage) throws -> String {
        let text = VNRecognizeTextRequest()
        text.recognitionLevel = .accurate; text.usesLanguageCorrection = true
        text.automaticallyDetectsLanguage = true
        let codes = VNDetectBarcodesRequest()
        try VNImageRequestHandler(cgImage: image).perform([text, codes])
        let lines = (text.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        let qr = (codes.results ?? []).compactMap(\.payloadStringValue)
        return (lines + qr.filter { !lines.contains($0) }).joined(separator: "\n")
    }
}

private final class CaptureSingleFrame: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<CGImage, Error>?
    private var stream: SCStream?
    private var keepAlive: CaptureSingleFrame?
    static func capture(filter: SCContentFilter, config: SCStreamConfiguration) async throws -> CGImage {
        let receiver = CaptureSingleFrame()
        receiver.keepAlive = receiver
        return try await withCheckedThrowingContinuation { continuation in
            receiver.continuation = continuation
            let stream = SCStream(filter: filter, configuration: config, delegate: receiver)
            receiver.stream = stream
            do {
                try stream.addStreamOutput(receiver, type: .screen, sampleHandlerQueue: DispatchQueue(label: "RIMES.Capture.frame"))
                stream.startCapture { error in if let error { receiver.finish(.failure(error)) } }
                DispatchQueue.global().asyncAfter(deadline: .now() + 8) { receiver.finish(.failure(CaptureError.message("屏幕捕获超时"))) }
            } catch { receiver.finish(.failure(error)) }
        }
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) { finish(.failure(error)) }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let status = attachments.first?[.status] as? Int, status != SCFrameStatus.complete.rawValue { return }
        guard type == .screen, sampleBuffer.isValid,
              let pixelBuffer = sampleBuffer.imageBuffer,
              let image = CIContext().createCGImage(CIImage(cvPixelBuffer: pixelBuffer), from: CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))) else { return }
        finish(.success(image))
    }
    private func finish(_ result: Result<CGImage, Error>) {
        lock.lock(); let pending = continuation; continuation = nil; lock.unlock()
        guard let pending else { return }
        if let stream {
            self.stream = nil
            stream.stopCapture { _ in try? stream.removeStreamOutput(self, type: .screen); self.keepAlive = nil }
        } else { keepAlive = nil }
        pending.resume(with: result)
    }
}
