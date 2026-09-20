import AppKit
import CoreImage
import Foundation

enum CaptureTool: String, Codable, CaseIterable {
    case select, crop, arrow, curve, line, rectangle, filledRectangle, ellipse, text, counter, pen, highlight, spotlight, blur, pixelate, redact
    var title: String {
        switch self {
        case .select: return "选择"; case .crop: return "裁剪"; case .arrow: return "箭头"; case .curve: return "弯箭头"
        case .line: return "直线"; case .rectangle: return "矩形"; case .filledRectangle: return "实心矩形"; case .ellipse: return "椭圆"
        case .text: return "文字"; case .counter: return "编号"; case .pen: return "画笔"; case .highlight: return "高亮"
        case .spotlight: return "聚光灯"; case .blur: return "模糊"; case .pixelate: return "像素化"; case .redact: return "遮盖"
        }
    }

    /// Icons, because sixteen Chinese labels of four different widths read as
    /// a list of words rather than a tool rail. The name survives as the
    /// tooltip and the accessibility label.
    var symbolName: String {
        switch self {
        case .select: return "cursorarrow"
        case .crop: return "crop"
        case .arrow: return "arrow.up.right"
        case .curve: return "arrow.turn.up.right"
        case .line: return "line.diagonal"
        case .rectangle: return "rectangle"
        case .filledRectangle: return "rectangle.fill"
        case .ellipse: return "circle"
        case .text: return "textformat"
        case .counter: return "1.circle"
        case .pen: return "pencil.tip"
        case .highlight: return "highlighter"
        case .spotlight: return "flashlight.on.fill"
        case .blur: return "drop.fill"
        case .pixelate: return "square.grid.3x3.fill"
        case .redact: return "rectangle.slash.fill"
        }
    }

    /// Rail groups: pointer, shapes, marks, redaction. Separators between
    /// them make sixteen icons scannable.
    var group: Int {
        switch self {
        case .select, .crop: return 0
        case .arrow, .curve, .line, .rectangle, .filledRectangle, .ellipse: return 1
        case .text, .counter, .pen, .highlight, .spotlight: return 2
        case .blur, .pixelate, .redact: return 3
        }
    }
}

struct CaptureAnnotation: Codable, Equatable, Identifiable {
    var id = UUID()
    var tool: CaptureTool
    var points: [CGPoint]
    var color: String = "22c55e"
    var width: CGFloat = 5
    var text: String = ""
    var rect: CGRect {
        guard let a = points.first, let b = points.last else { return .zero }
        if tool == .text { return CGRect(x: a.x, y: a.y, width: max(10, CGFloat(text.count) * max(18, width*4) * 0.7), height: max(18, width*4)*1.3) }
        if tool == .counter { return CGRect(x: a.x-18, y: a.y-18, width: 36, height: 36) }
        if tool == .pen { return points.reduce(CGRect(x: a.x, y: a.y, width: 0, height: 0)) { $0.union(CGRect(x: $1.x, y: $1.y, width: 1, height: 1)) } }
        return CGRect(x: min(a.x,b.x), y: min(a.y,b.y), width: abs(b.x-a.x), height: abs(b.y-a.y))
    }
}

struct CaptureImageLayer: Codable, Equatable {
    var file: String
    var frame: CGRect
}

struct CaptureBackground: Codable, Equatable {
    var enabled = false
    var color = "dbe7df"
    var secondColor: String? = nil
    var imageFile: String? = nil
    var padding: CGFloat = 48
    var corner: CGFloat = 16
    var shadow: CGFloat = 24
    var aspect: CGFloat? = nil
    var alignment: Int = 0
}

struct CaptureDocument: Codable, Equatable {
    var version = 1
    var size: CGSize
    var layers: [CaptureImageLayer]
    var annotations: [CaptureAnnotation] = []
    var background = CaptureBackground()
    var crop: CGRect? = nil
    var turns = 0
    var flip = false
    var outputWidth: Int? = nil

    init(image: CGImage, file: String) {
        size = CGSize(width: image.width, height: image.height)
        layers = [CaptureImageLayer(file: file, frame: CGRect(origin: .zero, size: size))]
    }
    func validate() throws {
        guard version == 1, size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0, size.width <= 32768, size.height <= 32768,
              size.width * size.height <= 128_000_000, !layers.isEmpty, layers.count <= 32, annotations.count <= 5000,
              background.padding.isFinite, (0...2000).contains(background.padding),
              background.corner.isFinite, (0...1000).contains(background.corner),
              background.shadow.isFinite, (0...200).contains(background.shadow) else { throw CaptureError.message("图像工程尺寸或内容超出限制") }
        for file in layers.map(\.file) + [background.imageFile].compactMap({ $0 }) {
            guard !file.isEmpty, file == URL(fileURLWithPath: file).lastPathComponent, !file.contains("..") else { throw CaptureError.message("工程包含无效素材路径") }
        }
        guard layers.allSatisfy({ [$0.frame.minX, $0.frame.minY, $0.frame.width, $0.frame.height].allSatisfy(\.isFinite) }),
              annotations.allSatisfy({ $0.width.isFinite && (0...512).contains($0.width) && $0.points.count <= 100_000 && $0.points.allSatisfy { $0.x.isFinite && $0.y.isFinite } }) else { throw CaptureError.message("工程坐标无效") }
    }
}

enum CaptureRenderer {
    private static let ci = CIContext(options: [.cacheIntermediates: false])
    static func color(_ hex: String, alpha: CGFloat = 1) -> CGColor {
        let value = UInt32(hex.replacingOccurrences(of: "#", with: ""), radix: 16) ?? 0x22c55e
        return CGColor(red: CGFloat((value >> 16) & 255)/255, green: CGFloat((value >> 8) & 255)/255, blue: CGFloat(value & 255)/255, alpha: alpha)
    }
    static func context(_ size: CGSize) throws -> CGContext {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
              size.width <= 32768, size.height <= 32768, size.width * size.height <= 128_000_000,
              let ctx = CGContext(data: nil, width: Int(ceil(size.width)), height: Int(ceil(size.height)), bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw CaptureError.message("图像过大，无法渲染") }
        ctx.translateBy(x: 0, y: CGFloat(ctx.height)); ctx.scaleBy(x: 1, y: -1)
        return ctx
    }
    static func drawImage(_ image: CGImage, in rect: CGRect, context: CGContext) {
        context.saveGState(); context.translateBy(x: rect.minX, y: rect.maxY); context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: rect.size)); context.restoreGState()
    }
    static func render(_ document: CaptureDocument, directory: URL, preview: Bool = false) throws -> CGImage {
        try document.validate()
        // Scale the document before allocating a preview canvas. In particular,
        // a tall scrolling capture must not allocate its export-sized bitmap on
        // every mouse movement.
        var document = document
        var extent = document.size
        if document.background.enabled {
            extent.width += document.background.padding*2; extent.height += document.background.padding*2
            if let ratio = document.background.aspect, ratio.isFinite, ratio > 0.1, ratio < 10 {
                if extent.width/extent.height > ratio { extent.height = extent.width/ratio } else { extent.width = extent.height*ratio }
            }
        }
        let factor = preview ? min(1, 1600 / max(extent.width, extent.height)) : 1
        if factor < 1 {
            let transform = CGAffineTransform(scaleX: factor, y: factor)
            document.size = CGSize(width: document.size.width * factor, height: document.size.height * factor)
            document.layers = document.layers.map { var layer = $0; layer.frame = layer.frame.applying(transform); return layer }
            document.annotations = document.annotations.map { var node = $0; node.points = node.points.map { $0.applying(transform) }; node.width *= factor; return node }
            document.crop = document.crop?.applying(transform)
            document.background.padding *= factor; document.background.corner *= factor; document.background.shadow *= factor
        }
        let ctx = try context(document.size)
        for layer in document.layers { drawImage(try CaptureImageIO.read(directory.appendingPathComponent(layer.file), maximum: preview ? 1600 : 32768), in: layer.frame, context: ctx) }
        for node in document.annotations { draw(node, context: ctx, canvas: document.size, scale: factor) }
        guard var image = ctx.makeImage() else { throw CaptureError.message("图像渲染失败") }
        if let crop = document.crop {
            let valid = crop.intersection(CGRect(origin: .zero, size: document.size)).integral
            guard valid.width > 1, valid.height > 1, let result = image.cropping(to: valid) else { throw CaptureError.message("裁剪区域无效") }
            image = result
        }
        if document.flip {
            let flipped = try context(CGSize(width: image.width, height: image.height))
            flipped.translateBy(x: CGFloat(image.width), y: 0); flipped.scaleBy(x: -1, y: 1)
            drawImage(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height), context: flipped)
            image = flipped.makeImage()!
        }
        for _ in 0..<((document.turns % 4 + 4) % 4) {
            let rotated = try context(CGSize(width: image.height, height: image.width))
            rotated.translateBy(x: CGFloat(image.height), y: 0); rotated.rotate(by: .pi / 2)
            drawImage(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height), context: rotated)
            image = rotated.makeImage()!
        }
        if document.background.enabled { image = try addBackground(image, document.background, directory: directory, preview: preview) }
        let maximum = preview ? min(image.width, Int(CGFloat(image.width) * min(1, 1600 / CGFloat(max(image.width, image.height))))) : (document.outputWidth ?? image.width)
        if maximum > 0, maximum != image.width {
            let target = CGSize(width: maximum, height: max(1, Int(CGFloat(image.height) * CGFloat(maximum) / CGFloat(image.width))))
            let resized = try context(target); resized.interpolationQuality = .high
            drawImage(image, in: CGRect(origin: .zero, size: target), context: resized)
            image = resized.makeImage()!
        }
        return image
    }
    private static func addBackground(_ image: CGImage, _ background: CaptureBackground, directory: URL, preview: Bool) throws -> CGImage {
        var size = CGSize(width: CGFloat(image.width) + 2 * background.padding, height: CGFloat(image.height) + 2 * background.padding)
        if let ratio = background.aspect, ratio.isFinite, ratio > 0.1, ratio < 10 {
            if size.width / size.height > ratio { size.height = size.width / ratio } else { size.width = size.height * ratio }
        }
        let ctx = try context(size); let bounds = CGRect(origin: .zero, size: size)
        ctx.setFillColor(color(background.color)); ctx.fill(bounds)
        if let second = background.secondColor, let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [color(background.color), color(second)] as CFArray, locations: [0,1]) {
            ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
        }
        if let file = background.imageFile { drawImage(try CaptureImageIO.read(directory.appendingPathComponent(file), maximum: preview ? 1600 : 32768), in: bounds, context: ctx) }
        let y = background.alignment == 1 ? background.padding : background.alignment == 2 ? size.height - CGFloat(image.height) - background.padding : (size.height - CGFloat(image.height))/2
        let rect = CGRect(x: (size.width-CGFloat(image.width))/2, y: y, width: CGFloat(image.width), height: CGFloat(image.height))
        let path = CGPath(roundedRect: rect, cornerWidth: background.corner, cornerHeight: background.corner, transform: nil)
        ctx.saveGState(); ctx.setShadow(offset: CGSize(width: 0, height: background.shadow/3), blur: background.shadow, color: CGColor(gray: 0, alpha: 0.35))
        ctx.addPath(path); ctx.setFillColor(CGColor(gray: 0.5, alpha: 1)); ctx.fillPath(); ctx.restoreGState()
        ctx.addPath(path); ctx.clip(); drawImage(image, in: rect, context: ctx)
        return ctx.makeImage()!
    }
    static func draw(_ node: CaptureAnnotation, context ctx: CGContext, canvas: CGSize, scale: CGFloat = 1) {
        guard let a = node.points.first, let b = node.points.last else { return }
        ctx.saveGState(); defer { ctx.restoreGState() }
        ctx.setStrokeColor(color(node.color)); ctx.setFillColor(color(node.color)); ctx.setLineWidth(node.width)
        ctx.setLineCap(.round); ctx.setLineJoin(.round)
        let rect = node.rect
        switch node.tool {
        case .select, .crop: break
        case .rectangle: ctx.stroke(rect)
        case .filledRectangle, .redact: ctx.fill(rect)
        case .ellipse: ctx.strokeEllipse(in: rect)
        case .highlight: ctx.setBlendMode(.multiply); ctx.setFillColor(color(node.color, alpha: 0.35)); ctx.fill(rect)
        case .spotlight:
            ctx.addRect(CGRect(origin: .zero, size: canvas)); ctx.addEllipse(in: rect); ctx.clip(using: .evenOdd)
            ctx.setFillColor(CGColor(gray: 0, alpha: 0.6)); ctx.fill(CGRect(origin: .zero, size: canvas))
        case .line, .arrow, .curve:
            ctx.move(to: a)
            var direction = CGPoint(x: b.x-a.x, y: b.y-a.y)
            if node.tool == .curve {
                let control = CGPoint(x: (a.x+b.x)/2 - (b.y-a.y)*0.25, y: (a.y+b.y)/2 + (b.x-a.x)*0.25)
                ctx.addQuadCurve(to: b, control: control); direction = CGPoint(x: b.x-control.x, y: b.y-control.y)
            } else { ctx.addLine(to: b) }
            ctx.strokePath()
            if node.tool != .line {
                let angle = atan2(direction.y, direction.x), length = max(16*scale, node.width*4)
                ctx.move(to: CGPoint(x: b.x-length*cos(angle-0.5), y: b.y-length*sin(angle-0.5)))
                ctx.addLine(to: b); ctx.addLine(to: CGPoint(x: b.x-length*cos(angle+0.5), y: b.y-length*sin(angle+0.5))); ctx.strokePath()
            }
        case .pen:
            ctx.move(to: a)
            if node.points.count > 2 {
                for i in 1..<(node.points.count-1) {
                    let current = node.points[i], next = node.points[i+1]
                    ctx.addQuadCurve(to: CGPoint(x: (current.x+next.x)/2, y: (current.y+next.y)/2), control: current)
                }
            }
            ctx.addLine(to: b); ctx.strokePath()
        case .text, .counter:
            var origin = a
            let fontSize = max(16*scale, node.width*5)
            if node.tool == .counter {
                let radius = max(18*scale, fontSize)
                ctx.fillEllipse(in: CGRect(x: a.x-radius, y: a.y-radius, width: radius*2, height: radius*2))
                origin = CGPoint(x: a.x-fontSize*0.28, y: a.y-fontSize*0.6)
            }
            let value = NSAttributedString(string: node.text, attributes: [.font: NSFont.systemFont(ofSize: fontSize, weight: .semibold), .foregroundColor: NSColor(cgColor: node.tool == .counter ? CGColor(gray: 1, alpha: 1) : color(node.color))!])
            let line = CTLineCreateWithAttributedString(value)
            ctx.translateBy(x: origin.x, y: origin.y + fontSize); ctx.scaleBy(x: 1, y: -1)
            ctx.textPosition = .zero; CTLineDraw(line, ctx)
        case .blur, .pixelate:
            guard let snapshot = ctx.makeImage(),
                  let region = snapshot.cropping(to: rect.intersection(CGRect(origin: .zero, size: canvas)).integral) else { return }
            let input = CIImage(cgImage: region)
            let processed = node.tool == .blur
                ? input.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: max(12*scale, node.width*3)]).cropped(to: input.extent)
                : input.applyingFilter("CIPixellate", parameters: [kCIInputScaleKey: max(12*scale,node.width*4)]).cropped(to: input.extent)
            if let image = ci.createCGImage(processed, from: input.extent) { drawImage(image, in: rect, context: ctx) }
        }
    }
}
