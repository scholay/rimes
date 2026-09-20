import AppKit
import ScreenCaptureKit
import ApplicationServices

enum CaptureScrollAxis: String { case vertical, horizontal }
enum CaptureScrollMatch: Equatable { case stationary, advance(Int), uncertain }

enum CaptureScrollMatcher {
    static func stickyTail(_ previous: CGImage, _ current: CGImage, axis: CaptureScrollAxis) -> Int {
        let vertical = axis == .vertical
        guard previous.width == current.width, previous.height == current.height else { return 0 }
        let length = vertical ? previous.height : previous.width
        let scale = min(1, 512 / CGFloat(length))
        let width = max(1, Int(CGFloat(previous.width)*scale)), height = max(1, Int(CGFloat(previous.height)*scale))
        guard let a = grayscale(previous, width: width, height: height), let b = grayscale(current, width: width, height: height) else { return 0 }
        let along = vertical ? height : width, across = vertical ? width : height
        var stable = 0
        for y in stride(from: along-1, through: max(0, along*3/4), by: -1) {
            var changed = 0, count = 0
            for x in stride(from: across/10, to: across*9/10, by: max(1, across/96)) {
                let index = vertical ? y*width+x : x*width+y
                if abs(Int(a[index])-Int(b[index])) > 5 { changed += 1 }; count += 1
            }
            if changed > max(1, count/20) { return stable >= 3 ? Int(CGFloat(stable)/scale) : 0 }
            stable += 1
        }
        return 0 // A blank/repeated tail without a boundary is ambiguous.
    }
    /// Compare normalized luminance away from sticky headers/sidebars. A
    /// repeated/blank overlap is rejected rather than silently losing lines.
    static func match(_ previous: CGImage, _ current: CGImage, axis: CaptureScrollAxis) -> CaptureScrollMatch {
        guard previous.width == current.width, previous.height == current.height else { return .uncertain }
        let vertical = axis == .vertical
        let scale = min(1, 256 / CGFloat(vertical ? previous.height : previous.width))
        let w = max(16,Int(CGFloat(previous.width)*scale)), h = max(16,Int(CGFloat(previous.height)*scale))
        guard let a = grayscale(previous,width:w,height:h), let b = grayscale(current,width:w,height:h) else { return .uncertain }
        let length = vertical ? h : w, breadth = vertical ? w : h
        let border = max(4,length/10)
        func value(_ data: [UInt8], _ along: Int, _ across: Int) -> Double {
            Double(data[vertical ? along*w+across : across*w+along])/255
        }
        func error(_ shift: Int) -> (Double, Double) {
            var sum = 0.0, mean = 0.0, squares = 0.0, count = 0.0
            let step = max(1,breadth/96)
            guard length-shift-border > border else { return (1,0) }
            for y in stride(from: border, to: length-shift-border, by: 2) {
                for x in stride(from: max(1,breadth/12), to: breadth-breadth/12, by: step) {
                    let lhs = value(a,y+shift,x), rhs = value(b,y,x)
                    sum += abs(lhs-rhs); mean += lhs; squares += lhs*lhs; count += 1
                }
            }
            return (sum/max(1,count), squares/max(1,count)-pow(mean/max(1,count),2))
        }
        if error(0).0 < 0.004 { return .stationary }
        let candidates = (3..<max(4,length-border*3)).map { ($0,error($0)) }.sorted { $0.1.0 < $1.1.0 }
        guard let best = candidates.first, best.1.0 < 0.07, best.1.1 > 0.002,
              let next = candidates.first(where: { abs($0.0-best.0) > 4 }), next.1.0 > best.1.0*1.12+0.001 else { return .uncertain }
        let estimate = Int((CGFloat(best.0)/scale).rounded())
        // Refine at the source's exact axis resolution to avoid accumulating
        // a few missing/duplicated pixels at every join on Retina displays.
        let rw = vertical ? min(96, previous.width) : previous.width
        let rh = vertical ? previous.height : min(96, previous.height)
        if let exactA = grayscale(previous, width: rw, height: rh), let exactB = grayscale(current, width: rw, height: rh) {
            let fullLength = vertical ? rh : rw, fullBreadth = vertical ? rw : rh
            let radius = Int(ceil(1/scale))+1
            let lower = max(1, estimate-radius), upper = min(fullLength*7/10, estimate+radius)
            guard lower <= upper, fullBreadth >= 8 else { return .uncertain }
            var refined = estimate, minimum = Double.infinity
            for shift in lower...upper {
                var error = 0.0, count = 0
                for y in stride(from: fullLength/10, to: fullLength-shift-fullLength/10, by: 2) {
                    for x in 3..<max(4,fullBreadth-3) {
                        let ia = vertical ? (y+shift)*rw+x : x*rw+y+shift
                        let ib = vertical ? y*rw+x : x*rw+y
                        error += Double(abs(Int(exactA[ia])-Int(exactB[ib]))); count += 1
                    }
                }
                error /= Double(max(1,count))
                if error < minimum { minimum = error; refined = shift }
            }
            return .advance(refined)
        }
        return .advance(estimate)
    }
    private static func grayscale(_ image: CGImage,width:Int,height:Int) -> [UInt8]? {
        guard let ctx = CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width,space:CGColorSpaceCreateDeviceGray(),bitmapInfo:0) else { return nil }
        ctx.draw(image,in:CGRect(x:0,y:0,width:width,height:height))
        guard let bytes = ctx.data else { return nil }
        return Array(UnsafeBufferPointer(start:bytes.assumingMemoryBound(to:UInt8.self),count:width*height))
    }
}

@MainActor
final class CaptureScrollSession {
    private let target: CaptureTarget
    private let content: SCShareableContent
    private let completed: (CGImage,Bool) -> Void
    private let panel = CapturePanel(size: NSSize(width: 330,height: 300))
    private let axis = NSPopUpButton()
    private let auto = NSButton(checkboxWithTitle:"自动滚动（需要辅助功能权限）",target:nil,action:nil)
    private let status = CaptureUI.label("选择方向后开始；保持页面稳定")
    private let preview = NSImageView()
    private var task: Task<Void,Never>?
    private var tiles: [(URL,Int)] = []
    private var previous: CGImage?
    private var previewTiles: [(CGImage, Int)] = []
    private var folder: URL?
    private var total = 0
    private var trailingInset = 0
    private var running = false
    private var incomplete = false
    private var selectedAxis: CaptureScrollAxis = .vertical
    private var stationaryCount = 0
    private var sourceApplication: NSRunningApplication?
    private let queue = DispatchQueue(label:"RIMES.Capture.stitch",qos:.userInitiated)

    init(target:CaptureTarget, content:SCShareableContent, sourceApplication: NSRunningApplication?, completed:@escaping(CGImage,Bool)->Void) {
        self.target = target; self.content = content; self.completed = completed
        self.sourceApplication = sourceApplication
        axis.addItems(withTitles:["纵向","横向"])
        preview.imageScaling = .scaleProportionallyUpOrDown
        preview.heightAnchor.constraint(equalToConstant:150).isActive = true
        preview.widthAnchor.constraint(equalToConstant:300).isActive = true
        status.lineBreakMode = .byWordWrapping; status.maximumNumberOfLines = 3
        CaptureUI.fill(CaptureUI.column([CaptureUI.row([CaptureUI.label("滚动截图",size:15),axis]),auto,preview,status,CaptureUI.row([
            CaptureButton("开始") { self.start() }, CaptureButton("完成") { self.finish() }, CaptureButton("取消") { self.cancel() }
        ])],spacing:8),in:panel.contentView!)
        panel.closed = { [weak self] in self?.task?.cancel(); self?.running = false; self?.panel.contentView = nil }
    }
    func show() { panel.present() }
    func start() {
        guard !running, tiles.isEmpty else { return }
        if auto.state == .on, !AXIsProcessTrusted() {
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            _ = AXIsProcessTrustedWithOptions([key:true] as CFDictionary)
            status.stringValue = "请授权辅助功能后重试，或取消自动滚动"; return
        }
        selectedAxis = axis.indexOfSelectedItem == 0 ? .vertical : .horizontal
        running = true; axis.isEnabled = false; auto.isEnabled = false
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rimes-scroll-\(UUID().uuidString)")
        do { try CaptureStore.ensureDirectory(dir); folder = dir } catch { CaptureUI.error(error); return }
        // Return focus to the content while this passive control stays visible.
        sourceApplication?.activate(options: [.activateIgnoringOtherApps])
        task = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled, self.running {
                do {
                    let image = try await CaptureEngine.image(self.target,content:self.content)
                    let prior = self.previous, selectedAxis = self.selectedAxis, count = self.tiles.count
                    let result: CaptureScrollMatch = await withCheckedContinuation { continuation in
                        self.queue.async { continuation.resume(returning:prior.map { CaptureScrollMatcher.match($0,image,axis:selectedAxis) } ?? .advance(selectedAxis == .vertical ? image.height : image.width)) }
                    }
                    guard !Task.isCancelled, self.running else { return }
                    switch result {
                    case .stationary:
                        self.stationaryCount += 1
                        if self.auto.state == .on, self.stationaryCount >= 4 { self.running = false; self.status.stringValue = "已到末尾，点击完成保存" }
                    case .uncertain:
                        self.incomplete = true; self.running = false
                        self.status.stringValue = "无法可靠拼接，已暂停。可保存现有部分，或重新捕获。"
                    case .advance(let pixels):
                        self.stationaryCount = 0
                        let dimension = selectedAxis == .vertical ? image.height : image.width
                        let added = min(pixels,dimension)
                        let cross = selectedAxis == .vertical ? image.width : image.height
                        if count == 1, let prior {
                            self.trailingInset = CaptureScrollMatcher.stickyTail(prior, image, axis: selectedAxis)
                            if self.trailingInset > 0, let first = self.tiles.first {
                                let kept = dimension-self.trailingInset
                                let rect = selectedAxis == .vertical ? CGRect(x: 0, y: 0, width: image.width, height: kept) : CGRect(x: 0, y: 0, width: kept, height: image.height)
                                if let trimmed = prior.cropping(to: rect) {
                                    try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in self.queue.async { do { try CaptureImageIO.write(trimmed, to: first.0); c.resume() } catch { c.resume(throwing: error) } } }
                                    self.tiles[0].1 = kept; self.total = kept
                                    self.previewTiles.removeAll()
                                    let ctx = try CaptureRenderer.context(CGSize(width: max(1, CGFloat(trimmed.width)*min(1, 240/CGFloat(max(trimmed.width, trimmed.height)))), height: max(1, CGFloat(trimmed.height)*min(1, 240/CGFloat(max(trimmed.width, trimmed.height))))))
                                    CaptureRenderer.drawImage(trimmed, in: CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height), context: ctx)
                                    if let thumb = ctx.makeImage() { self.previewTiles.append((thumb, kept)) }
                                }
                            }
                        }
                        let outputLength = self.total+added+self.trailingInset
                        guard outputLength <= 32768, outputLength*cross <= 64_000_000 else { self.incomplete = true; self.running = false; self.status.stringValue = "达到长图尺寸上限，请保存后继续分段捕获"; break }
                        let rect = selectedAxis == .vertical ? CGRect(x:0,y:image.height-added-self.trailingInset,width:image.width,height:added) : CGRect(x:image.width-added-self.trailingInset,y:0,width:added,height:image.height)
                        guard let tile = image.cropping(to:rect) else { throw CaptureError.message("长图切片失败") }
                        let path = dir.appendingPathComponent("\(count).png")
                        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void,Error>) in self.queue.async { do { try CaptureImageIO.write(tile,to:path); continuation.resume() } catch { continuation.resume(throwing:error) } } }
                        self.tiles.append((path,added)); self.total += added; self.previous = image
                        // Cumulative preview from small tiles, never loading a
                        // growing full-resolution image on the event queue.
                        let thumbContext = try CaptureRenderer.context(CGSize(width: max(1, CGFloat(tile.width)*min(1, 240/CGFloat(max(tile.width, tile.height)))), height: max(1, CGFloat(tile.height)*min(1, 240/CGFloat(max(tile.width, tile.height))))))
                        CaptureRenderer.drawImage(tile, in: CGRect(x: 0, y: 0, width: thumbContext.width, height: thumbContext.height), context: thumbContext)
                        if let thumb = thumbContext.makeImage() { self.previewTiles.append((thumb, added)) }
                        self.updatePreview(cross: cross)
                        self.status.stringValue = "已拼接 \(self.tiles.count) 段 · \(self.total) px"
                    }
                    if self.auto.state == .on, self.running { self.scroll() }
                    try await Task.sleep(nanoseconds:700_000_000)
                } catch {
                    if !Task.isCancelled { self.status.stringValue = error.localizedDescription; self.incomplete = true }
                    self.running = false
                }
            }
        }
    }
    private func updatePreview(cross: Int) {
        let ratio = selectedAxis == .vertical ? CGSize(width: cross, height: total) : CGSize(width: total, height: cross)
        let factor = min(600 / ratio.width, 300 / ratio.height)
        guard let ctx = try? CaptureRenderer.context(CGSize(width: max(1, ratio.width*factor), height: max(1, ratio.height*factor))) else { return }
        var offset: CGFloat = 0
        for (image, length) in previewTiles {
            let rect = selectedAxis == .vertical ? CGRect(x: 0, y: offset, width: CGFloat(cross)*factor, height: CGFloat(length)*factor) : CGRect(x: offset, y: 0, width: CGFloat(length)*factor, height: CGFloat(cross)*factor)
            CaptureRenderer.drawImage(image, in: rect, context: ctx); offset += CGFloat(length)*factor
        }
        if let image = ctx.makeImage() { preview.image = NSImage(cgImage: image, size: .zero) }
    }
    private func scroll() {
        guard let rect = target.rect else { return }
        let position = CGPoint(x:target.display.frame.minX+rect.midX,y:target.display.frame.minY+rect.midY)
        let mouse = CGEvent(mouseEventSource:nil,mouseType:.mouseMoved,mouseCursorPosition:position,mouseButton:.left)
        mouse?.post(tap:.cghidEventTap)
        let distance = Int32(max(30,(selectedAxis == .vertical ? rect.height : rect.width)*0.3))
        CGEvent(scrollWheelEvent2Source:nil,units:.pixel,wheelCount:2,wheel1:selectedAxis == .vertical ? -distance : 0,wheel2:selectedAxis == .horizontal ? -distance : 0,wheel3:0)?.post(tap:.cghidEventTap)
    }
    func finish() {
        running = false; task?.cancel()
        guard let previous, !tiles.isEmpty else { cancel(); return }
        let tiles = self.tiles, total = self.total + trailingInset, inset = trailingInset, axis = selectedAxis, incomplete = self.incomplete, folder = folder
        status.stringValue = "正在合成长图…"
        queue.async {
            do {
                let size = axis == .vertical ? CGSize(width:previous.width,height:total) : CGSize(width:total,height:previous.height)
                let context = try CaptureRenderer.context(size); var offset = 0
                for (url,length) in tiles {
                    let image = try CaptureImageIO.read(url)
                    let rect = axis == .vertical ? CGRect(x:0,y:offset,width:image.width,height:length) : CGRect(x:offset,y:0,width:length,height:image.height)
                    CaptureRenderer.drawImage(image,in:rect,context:context); offset += length
                }
                if inset > 0 {
                    let rect = axis == .vertical ? CGRect(x: 0, y: previous.height-inset, width: previous.width, height: inset) : CGRect(x: previous.width-inset, y: 0, width: inset, height: previous.height)
                    if let tail = previous.cropping(to: rect) {
                        CaptureRenderer.drawImage(tail, in: axis == .vertical ? CGRect(x: 0, y: offset, width: previous.width, height: inset) : CGRect(x: offset, y: 0, width: inset, height: previous.height), context: context)
                    }
                }
                guard let image = context.makeImage() else { throw CaptureError.message("长图输出失败") }
                if let folder { try? FileManager.default.removeItem(at:folder) }
                DispatchQueue.main.async { self.panel.close(); self.completed(image,incomplete) }
            } catch { DispatchQueue.main.async { CaptureUI.error(error,window:self.panel) } }
        }
    }
    func cancel() { running = false; task?.cancel(); panel.close(); let folder = folder; queue.async { if let folder { try? FileManager.default.removeItem(at:folder) } } }
}
