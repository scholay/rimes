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

/// One overlay per display, with each crop expressed in that display's point
/// coordinates. Conversion to pixels happens once, at the capture boundary.
final class CaptureSelectionView: NSView {
    var selected: ((CGRect) -> Void)?
    var cancelled: (() -> Void)?
    let snapshot: CGImage
    var fixedSize: CGSize?
    var ratio: CGFloat?
    private var start: CGPoint?
    private var end = CGPoint.zero
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    init(image: CGImage) { snapshot = image; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { cancelled?() }
    }
    private var selection: CGRect {
        guard let start else { return .zero }
        var w = abs(end.x - start.x), h = abs(end.y - start.y)
        if let fixedSize { w = fixedSize.width; h = fixedSize.height }
        else if let ratio { h = w / ratio }
        return CGRect(x: end.x < start.x ? start.x - w : start.x,
                      y: end.y < start.y ? start.y - h : start.y, width: w, height: h).intersection(bounds)
    }
    override func mouseDown(with event: NSEvent) { start = convert(event.locationInWindow, from: nil); end = start!; needsDisplay = true }
    override func mouseDragged(with event: NSEvent) { end = convert(event.locationInWindow, from: nil); needsDisplay = true }
    override func mouseUp(with event: NSEvent) {
        end = convert(event.locationInWindow, from: nil)
        if selection.width >= 4, selection.height >= 4 { selected?(selection) }
    }
    override func draw(_ dirtyRect: NSRect) {
        let image = NSImage(cgImage: snapshot, size: bounds.size)
        image.draw(in: bounds, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
        NSColor.black.withAlphaComponent(0.45).setFill(); bounds.fill()
        guard start != nil else {
            ("拖动选择区域 · Esc 取消" as NSString).draw(at: CGPoint(x: 30, y: 30), withAttributes: [.foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: 18)])
            return
        }
        let rect = selection
        NSGraphicsContext.saveGraphicsState(); NSBezierPath(rect: rect).addClip()
        image.draw(in: bounds, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
        RimeUI.accentGreen.setStroke(); let border = NSBezierPath(rect: rect); border.lineWidth = 1.5; border.stroke()
        let factor = CGFloat(snapshot.width) / bounds.width
        let size = "\(Int(rect.width*factor)) × \(Int(rect.height*factor)) px · \(Int(rect.width)) × \(Int(rect.height)) pt"
        (size as NSString).draw(at: CGPoint(x: rect.minX, y: min(bounds.height - 24, rect.maxY + 5)), withAttributes: [.foregroundColor: NSColor.white, .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)])
        let scale = CGFloat(snapshot.width) / bounds.width
        let sample = CGRect(x: end.x * scale - 10, y: end.y * scale - 10, width: 20, height: 20).intersection(CGRect(x: 0, y: 0, width: snapshot.width, height: snapshot.height))
        if let crop = snapshot.cropping(to: sample) {
            let magnifier = CGRect(x: min(bounds.width - 90, end.x + 24), y: min(bounds.height - 90, end.y + 24), width: 80, height: 80)
            NSGraphicsContext.current?.imageInterpolation = .none
            NSImage(cgImage: crop, size: magnifier.size).draw(in: magnifier, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
            let cross = NSBezierPath(); cross.move(to: CGPoint(x: magnifier.midX, y: magnifier.minY)); cross.line(to: CGPoint(x: magnifier.midX, y: magnifier.maxY)); cross.move(to: CGPoint(x: magnifier.minX, y: magnifier.midY)); cross.line(to: CGPoint(x: magnifier.maxX, y: magnifier.midY)); cross.stroke()
        }
    }
}
