import AppKit
import Vision
import UniformTypeIdentifiers

final class CaptureCanvas: NSView {
    var image: CGImage? { didSet { needsDisplay = true } }
    var documentSize = CGSize(width: 1, height: 1)
    var tool: CaptureTool = .select
    var color = "22c55e"
    var stroke: CGFloat = 5
    var previewOnly = false
    var draft: CaptureAnnotation?
    var selectedRect: CGRect?
    var textBoxes: [CGRect] = []
    var complete: ((CaptureAnnotation) -> Void)?
    var pick: ((CGPoint) -> Void)?
    var moveSelection: ((CGPoint) -> Void)?
    var editSelection: (() -> Void)?
    private var previousPoint: CGPoint?
    var importURLs: (([URL]) -> Void)?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override init(frame frameRect: NSRect) { super.init(frame: frameRect); registerForDraggedTypes([.fileURL]) }
    required init?(coder: NSCoder) { fatalError() }
    var imageRect: CGRect {
        guard let image else { return .zero }
        let scale = min((bounds.width-24)/CGFloat(image.width), (bounds.height-24)/CGFloat(image.height))
        let size = CGSize(width: CGFloat(image.width)*scale, height: CGFloat(image.height)*scale)
        return CGRect(x: (bounds.width-size.width)/2, y: (bounds.height-size.height)/2, width: size.width, height: size.height)
    }
    private func point(_ event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil), rect = imageRect
        return CGPoint(x: min(documentSize.width, max(0,(point.x-rect.minX)/max(1,rect.width)*documentSize.width)),
                       y: min(documentSize.height, max(0,(point.y-rect.minY)/max(1,rect.height)*documentSize.height)))
    }
    override func mouseDown(with event: NSEvent) {
        guard !previewOnly else { return }
        let p = point(event)
        if tool == .select { previousPoint = p; pick?(p); if event.clickCount == 2 { editSelection?() }; return }
        draft = CaptureAnnotation(tool: tool, points: [p,p], color: color, width: stroke)
    }
    override func mouseDragged(with event: NSEvent) {
        if tool == .select, let previousPoint {
            let next = point(event); self.previousPoint = next
            moveSelection?(CGPoint(x: next.x-previousPoint.x, y: next.y-previousPoint.y))
            return
        }
        guard draft != nil else { return }
        if tool == .pen { draft?.points.append(point(event)) } else { draft?.points[1] = point(event) }
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        previousPoint = nil
        guard var node = draft else { return }; draft = nil
        if tool != .pen { node.points[1] = point(event) }
        if tool == .highlight {
            let matches = textBoxes.filter { $0.intersects(node.rect.insetBy(dx: -3, dy: -3)) }
            if let first = matches.first { let rect = matches.dropFirst().reduce(first) { $0.union($1) }; node.points = [rect.origin, CGPoint(x: rect.maxX, y: rect.maxY)] }
        }
        complete?(node); needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        RimeUI.surface2.setFill(); bounds.fill()
        guard let image, let cg = NSGraphicsContext.current?.cgContext else { return }
        NSImage(cgImage: image, size: .zero).draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        if let draft {
            cg.saveGState(); cg.translateBy(x: imageRect.minX, y: imageRect.minY)
            cg.scaleBy(x: imageRect.width/documentSize.width, y: imageRect.height/documentSize.height)
            if draft.tool == .crop { cg.setStrokeColor(RimeUI.accentGreen.cgColor); cg.setLineWidth(3); cg.stroke(draft.rect) }
            else { CaptureRenderer.draw(draft, context: cg, canvas: documentSize) }
            cg.restoreGState()
        }
        if let rect = selectedRect, !previewOnly {
            let r = CGRect(x: imageRect.minX + rect.minX/documentSize.width*imageRect.width, y: imageRect.minY + rect.minY/documentSize.height*imageRect.height, width: rect.width/documentSize.width*imageRect.width, height: rect.height/documentSize.height*imageRect.height)
            RimeUI.accentGreen.setStroke(); NSBezierPath(rect: r.insetBy(dx: -3, dy: -3)).stroke()
        }
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] ?? []
        importURLs?(urls); return !urls.isEmpty
    }
}

@MainActor
final class CaptureEditor {
    let panel: CapturePanel
    var onClose: (() -> Void)?
    nonisolated private let store: CaptureStore
    private var record: CaptureRecord
    private var document: CaptureDocument?
    private var undo: [CaptureDocument] = []
    private var redo: [CaptureDocument] = []
    private var saved: CaptureDocument?
    private let canvas = CaptureCanvas()
    private let status = CaptureUI.label("正在读取图片…")
    private let work = DispatchQueue(label: "RIMES.Capture.editor", qos: .userInitiated)
    private let renderQueue: OperationQueue = { let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1; queue.qualityOfService = .userInitiated; return queue }()
    private var renderGeneration = UUID()
    private var selected: UUID?
    private var selectedLayer: Int?
    private var ocrSelection = false
    private var saving = false
    private var closed = false
    private var monitor: Any?
    private var preview = false

    init(record: CaptureRecord, store: CaptureStore) throws {
        self.record = record; self.store = store
        panel = CapturePanel(size: NSSize(width: 1120, height: 780))
        panel.minSize = NSSize(width: 1040, height: 700); panel.escapeCloses = false
        panel.shouldClose = { [weak self] in self?.requestClose(); return false }
        guard store.acquire(record.id) else { throw CaptureError.message("资产正在清理，请刷新捕获历史") }
        build()
        panel.closed = { [weak self] in
            guard let self else { return }; self.closed = true; self.store.release(self.record.id)
            self.renderGeneration = UUID()
            self.renderQueue.cancelAllOperations()
            if let monitor = self.monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            self.onClose?()
            self.canvas.complete = nil; self.canvas.pick = nil; self.canvas.importURLs = nil; self.canvas.moveSelection = nil; self.canvas.editSelection = nil
            self.panel.contentView = nil
        }
        performAssetWork { [weak self] in
            guard let self else { return }
            do {
                let original = try CaptureImageIO.read(store.url(record, original: true))
                var value = CaptureDocument(image: original, file: record.original)
                if let path = record.project {
                    value = try JSONDecoder().decode(CaptureDocument.self, from: Data(contentsOf: store.directory(record.id).appendingPathComponent(path)))
                    try value.validate()
                }
                let request = VNRecognizeTextRequest(); request.recognitionLevel = .fast
                try? VNImageRequestHandler(cgImage: original).perform([request])
                let boxes = (request.results ?? []).map { result in
                    let r = result.boundingBox
                    return CGRect(x: r.minX*CGFloat(original.width), y: (1-r.maxY)*CGFloat(original.height), width: r.width*CGFloat(original.width), height: r.height*CGFloat(original.height))
                }
                let loaded = value
                DispatchQueue.main.async { guard !self.closed else { return }; self.document = loaded; self.saved = loaded; self.canvas.textBoxes = boxes; self.render() }
            } catch { DispatchQueue.main.async { self.status.stringValue = error.localizedDescription } }
        }
    }
    func show() {
        let frame = NSScreen.main?.visibleFrame ?? panel.frame
        let available = NSSize(width: max(960, frame.width-32), height: max(640, frame.height-32))
        panel.minSize = NSSize(width: min(1040, available.width), height: min(700, available.height))
        panel.setContentSize(NSSize(width: min(panel.frame.width, available.width), height: min(panel.frame.height, available.height)))
        panel.setFrameOrigin(CGPoint(x: frame.midX-panel.frame.width/2, y: frame.minY+16))
        panel.present(center: false)
    }
    /// Background operations retain their own lease so closing the window
    /// cannot let history cleanup remove files during export or OCR.
    private func performAssetWork(_ body: @escaping () -> Void) {
        let store = store, id = record.id
        guard store.acquire(id) else { status.stringValue = "资产正在清理，请刷新捕获历史"; return }
        work.async { defer { store.release(id) }; body() }
    }
    private func mutate(_ body: (inout CaptureDocument) -> Void) {
        guard !closed else { return }
        guard var document else { return }
        undo.append(document); if undo.count > 60 { undo.removeFirst() }; redo.removeAll()
        body(&document); self.document = document; render()
    }
    private func render() {
        guard var snapshot = document else { return }
        canvas.documentSize = snapshot.size; canvas.previewOnly = preview
        if !preview { snapshot.background.enabled = false; snapshot.crop = nil; snapshot.turns = 0; snapshot.flip = false; snapshot.outputWidth = nil }
        let token = UUID(); renderGeneration = token
        status.stringValue = preview ? "效果预览 · 切回标注后编辑" : "标注原始画布 · 拖入图片可组合"
        let id = record.id, directory = store.directory(record.id), value = snapshot
        renderQueue.cancelAllOperations()
        let operation = BlockOperation()
        operation.addExecutionBlock { [weak operation] in
            guard operation?.isCancelled == false, self.store.acquire(id) else { return }
            defer { self.store.release(id) }
            let result = Result { try CaptureRenderer.render(value, directory: directory, preview: true) }
            guard operation?.isCancelled == false else { return }
            DispatchQueue.main.async {
                guard token == self.renderGeneration else { return }
                switch result {
                case .success(let image): self.canvas.image = image
                case .failure(let error): self.status.stringValue = error.localizedDescription
                }
            }
        }
        renderQueue.addOperation(operation)
    }
    private func build() {
        let drag = CaptureCurrentDragView()
        drag.snapshot = { [weak self] in guard let self, let document = self.document else { return nil }; return (document, self.store.directory(self.record.id), self.store, self.record.id) }
        let toolbar = CaptureUI.row([
            CaptureUI.label("Capsule", size: 16),
            CaptureButton("标注") { self.preview = false; self.render() },
            CaptureButton("效果预览") { self.preview = true; self.render() },
            CaptureButton("撤销") { self.undoEdit() }, CaptureButton("重做") { self.redoEdit() },
            CaptureButton("复制") { self.save { CaptureCoordinator.shared.copy($0) } },
            drag,
            CaptureButton("导出") { self.exportImage() },
            CaptureButton("收入 Capsule") { self.save { CaptureCoordinator.shared.collect($0) } },
            CaptureButton("保存") { self.save() },
            CaptureButton("关闭", symbol: "xmark") { self.requestClose() }
        ], spacing: 5)
        let tools = CaptureUI.column(CaptureTool.allCases.map { tool in CaptureButton(tool.title) { self.canvas.tool = tool; self.preview = false; self.render() } }, spacing: 4)
        tools.widthAnchor.constraint(equalToConstant: 85).isActive = true
        let toolsScroll = CaptureInspectorScroll(tools)
        toolsScroll.widthAnchor.constraint(equalToConstant: 105).isActive = true
        let inspector = CaptureInspectorScroll(makeInspector()); inspector.widthAnchor.constraint(equalToConstant: 210).isActive = true
        let middle = CaptureUI.row([toolsScroll, canvas, inspector], spacing: 14); middle.alignment = .top
        canvas.widthAnchor.constraint(greaterThanOrEqualToConstant: 540).isActive = true
        canvas.heightAnchor.constraint(equalTo: middle.heightAnchor).isActive = true
        inspector.heightAnchor.constraint(equalTo: middle.heightAnchor).isActive = true
        toolsScroll.heightAnchor.constraint(equalTo: middle.heightAnchor).isActive = true
        middle.heightAnchor.constraint(greaterThanOrEqualToConstant: 410).isActive = true
        let strip = CaptureLibraryStrip(store: store)
        strip.heightAnchor.constraint(equalToConstant: 126).isActive = true
        let stack = CaptureUI.column([toolbar, middle, status, strip], spacing: 10)
        CaptureUI.fill(stack, in: panel.contentView!)
        for child in [toolbar, middle, strip] { child.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        canvas.complete = { [weak self] in self?.add($0) }
        canvas.pick = { [weak self] point in
            guard let self else { return }
            if let document = self.document { self.undo.append(document); self.redo.removeAll() }
            let node = self.document?.annotations.reversed().first { $0.rect.insetBy(dx: -15, dy: -15).contains(point) }
            self.selected = node?.id
            self.selectedLayer = node == nil ? self.document?.layers.indices.reversed().first { self.document!.layers[$0].frame.contains(point) } : nil
            self.canvas.selectedRect = node?.rect ?? self.selectedLayer.flatMap { self.document?.layers[$0].frame }; self.canvas.needsDisplay = true
        }
        canvas.moveSelection = { [weak self] delta in
            guard let self else { return }
            if let selected = self.selected, let index = self.document?.annotations.firstIndex(where: { $0.id == selected }) {
                let moved = self.document!.annotations[index].points.map { CGPoint(x: $0.x+delta.x, y: $0.y+delta.y) }
                self.document?.annotations[index].points = moved
                self.canvas.selectedRect = self.document?.annotations[index].rect
            } else if let index = self.selectedLayer, let frame = self.document?.layers[index].frame {
                self.document?.layers[index].frame = frame.offsetBy(dx: delta.x, dy: delta.y)
                self.canvas.selectedRect = self.document?.layers[index].frame
            }
            self.render()
        }
        canvas.editSelection = { [weak self] in self?.editSelectedText() }
        canvas.importURLs = { [weak self] in self?.importImages($0) }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.panel,
                  !(self.panel.firstResponder is NSTextView) else { return event }
            if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == [.command, .shift], event.charactersIgnoringModifiers?.lowercased() == "z" { self.redoEdit(); return nil }
            if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command {
                switch event.charactersIgnoringModifiers {
                case "s": self.save(); return nil
                case "z": self.undoEdit(); return nil
                default: break
                }
            }
            if event.keyCode == 53 { self.requestClose(); return nil }
            if event.keyCode == 51, let selected = self.selected {
                self.mutate { $0.annotations.removeAll { $0.id == selected } }; self.selected = nil; self.canvas.selectedRect = nil; return nil
            }
            if event.keyCode == 51, let layer = self.selectedLayer, self.document!.layers.count > 1 {
                self.mutate { $0.layers.remove(at: layer) }; self.selectedLayer = nil; self.canvas.selectedRect = nil; return nil
            }
            return event
        }
    }

    private func makeInspector() -> NSView {
        let color = NSPopUpButton(); color.addItems(withTitles: ["绿色", "红色", "黄色", "蓝色", "白色", "黑色"])
        let colors = ["22c55e","e34b3f","f2c94c","388bfd","ffffff","000000"]
        let width = NSTextField(string: "5")
        let textStyle = CaptureButton("应用样式") {
            self.canvas.color = colors[color.indexOfSelectedItem]; self.canvas.stroke = min(64,max(1,width.doubleValue))
            if let selected = self.selected { self.mutate { doc in if let i = doc.annotations.firstIndex(where: { $0.id == selected }) { doc.annotations[i].color = self.canvas.color; doc.annotations[i].width = self.canvas.stroke } } }
        }
        let padding = NSTextField(string: "48"), corner = NSTextField(string: "16"), shadow = NSTextField(string: "24")
        let bg = NSPopUpButton(); bg.addItems(withTitles: ["透明", "鼠尾草", "石墨", "米白", "海蓝渐变", "紫色渐变"])
        let aspect = NSPopUpButton(); aspect.addItems(withTitles: ["自适应", "1:1", "16:9", "9:16", "4:3"])
        let align = NSPopUpButton(); align.addItems(withTitles: ["居中", "靠上", "靠下"])
        let apply = CaptureButton("应用背景") {
            self.mutate { doc in
                doc.background.enabled = bg.indexOfSelectedItem != 0
                doc.background.color = ["ffffff","dbe7df","242933","f6f1e8","d5ecff","e1d7ff"][bg.indexOfSelectedItem]
                doc.background.secondColor = bg.indexOfSelectedItem >= 4 ? "748ba8" : nil
                doc.background.padding = min(2000,max(0,padding.doubleValue)); doc.background.corner = min(1000,max(0,corner.doubleValue)); doc.background.shadow = min(200,max(0,shadow.doubleValue))
                let ratios: [CGFloat?] = [nil,1,16/9,9/16,4/3]; doc.background.aspect = ratios[aspect.indexOfSelectedItem]
                doc.background.alignment = align.indexOfSelectedItem
            }; self.preview = true; self.render()
        }
        let size = NSTextField(string: "1440")
        let presets = CaptureUI.row([CaptureButton("存预设") { if let background = self.document?.background, let data = try? JSONEncoder().encode(background) { UserDefaults.standard.set(data, forKey: "capture.background.preset") } }, CaptureButton("用预设") { if let data = UserDefaults.standard.data(forKey: "capture.background.preset"), let background = try? JSONDecoder().decode(CaptureBackground.self, from: data) { self.mutate { $0.background = background }; self.preview = true; self.render() } }])
        return CaptureUI.column([
            CaptureUI.label("工具样式", size: 14), color, CaptureUI.row([CaptureUI.label("线宽"),width]), textStyle,
            CaptureUI.label("背景", size: 14), bg,
            CaptureUI.row([CaptureUI.label("留白"),padding]), CaptureUI.row([CaptureUI.label("圆角"),corner]), CaptureUI.row([CaptureUI.label("阴影"),shadow]), aspect, align, apply, presets,
            CaptureButton("自动平衡") { self.autoBalance() },
            CaptureUI.row([CaptureButton("旋转") { self.mutate { $0.turns += 1 }; self.preview = true; self.render() }, CaptureButton("翻转") { self.mutate { $0.flip.toggle() }; self.preview = true; self.render() }]),
            CaptureUI.row([size, CaptureButton("设宽度") { self.mutate { $0.outputWidth = min(16384,max(16,size.integerValue)) }; self.preview = true; self.render() }]),
            CaptureButton("添加图片 / 背景") { self.chooseImages() },
            CaptureUI.row([CaptureButton("缩小图层") { self.scaleLayer(0.9) }, CaptureButton("放大图层") { self.scaleLayer(1.1) }]),
            CaptureButton("识别局部文字") { self.ocrSelection = true; self.canvas.tool = .crop; self.preview = false; self.render(); self.status.stringValue = "框选需要识别的区域" },
            CaptureButton("导出可编辑工程") { self.exportProject() }
        ], spacing: 7)
    }
    private func add(_ value: CaptureAnnotation) {
        var node = value
        if node.tool == .crop {
            if ocrSelection { ocrSelection = false; recognizeSelection(node.rect); return }
            if node.rect.width > 2, node.rect.height > 2 { mutate { $0.crop = node.rect }; preview = true; render() }; return
        }
        if node.tool == .text {
            let alert = NSAlert(); alert.messageText = "添加文字"
            let field = NSTextField(frame: NSRect(x: 0,y: 0,width: 320,height: 26)); alert.accessoryView = field
            alert.addButton(withTitle: "添加"); alert.addButton(withTitle: "取消")
            alert.beginSheetModal(for: panel) { response in
                guard response == .alertFirstButtonReturn, !field.stringValue.isEmpty else { return }
                node.text = field.stringValue; self.mutate { $0.annotations.append(node) }
            }; return
        }
        if node.tool == .counter { node.text = String((document?.annotations.filter { $0.tool == .counter }.count ?? 0)+1) }
        mutate { $0.annotations.append(node) }
    }
    private func undoEdit() { guard let previous = undo.popLast(), let document else { return }; redo.append(document); self.document = previous; selected = nil; selectedLayer = nil; canvas.selectedRect = nil; render() }
    private func redoEdit() { guard let next = redo.popLast(), let document else { return }; undo.append(document); self.document = next; selected = nil; selectedLayer = nil; canvas.selectedRect = nil; render() }
    private func requestClose() {
        guard !saving else { status.stringValue = "正在保存，请稍候"; return }
        guard document != saved else { panel.close(); return }
        let alert = NSAlert(); alert.messageText = "保存本次编辑？"; alert.addButton(withTitle: "保存"); alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "放弃修改")
        alert.beginSheetModal(for: panel) { response in
            if response == .alertFirstButtonReturn { self.save { _ in self.panel.close() } }
            else if response == .alertThirdButtonReturn { self.panel.close() }
        }
    }
    private func save(completion: ((CaptureRecord) -> Void)? = nil) {
        guard let snapshot = document, !saving else { return }
        saving = true; status.stringValue = "正在保存工程…"
        let record = self.record, directory = store.directory(record.id)
        performAssetWork {
            do {
                let image = try CaptureRenderer.render(snapshot, directory: directory)
                let revision = UUID().uuidString
                let output = "render-\(revision).png", project = "project-\(revision).json"
                try CaptureImageIO.write(image, to: directory.appendingPathComponent(output))
                try JSONEncoder().encode(snapshot).write(to: directory.appendingPathComponent(project), options: [.atomic])
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: directory.appendingPathComponent(project).path)
                try CaptureProjectPackage.write(document: snapshot, directory: directory, output: directory.appendingPathComponent(output + ".rimesproject"))
                var updated = try self.store.record(record.id)
                updated.output = output; updated.project = project; updated.width = image.width; updated.height = image.height
                updated.thumbnail = try CaptureStore.makeThumbnail(source: directory.appendingPathComponent(output), kind: .image, directory: directory)
                try self.store.update(updated)
                if updated.collectionID != nil { updated = try self.store.collect(record.id) }
                let result = updated
                DispatchQueue.main.async { self.record = result; self.saved = snapshot; self.saving = false; self.status.stringValue = "工程已保存"; completion?(result) }
            } catch { DispatchQueue.main.async { self.saving = false; self.status.stringValue = error.localizedDescription; CaptureUI.error(error, window: self.panel) } }
        }
    }
    private func exportImage() {
        let dialog = NSSavePanel(); dialog.allowedContentTypes = [.png, .jpeg]; dialog.allowsOtherFileTypes = false
        dialog.nameFieldStringValue = record.title + ".png"
        dialog.beginSheetModal(for: panel) { response in
            guard response == .OK, let url = dialog.url, let document = self.document else { return }
            let directory = self.store.directory(self.record.id)
            self.performAssetWork { do { try CaptureImageIO.write(CaptureRenderer.render(document, directory: directory), to: url, jpeg: ["jpg","jpeg"].contains(url.pathExtension.lowercased())) } catch { DispatchQueue.main.async { CaptureUI.error(error, window: self.panel) } } }
        }
    }
    private func exportProject() {
        let alert = NSAlert(); alert.messageText = "工程包含原始素材"; alert.informativeText = "工程可继续编辑，包含遮盖前的原图。发送普通图片请使用“导出”。"
        alert.addButton(withTitle: "导出工程"); alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: panel) { response in
            guard response == .alertFirstButtonReturn else { return }
            self.save { record in
                let dialog = NSSavePanel(); dialog.nameFieldStringValue = record.title + ".rimesproject"
                dialog.beginSheetModal(for: self.panel) { response in
                    guard response == .OK, let url = dialog.url else { return }
                    let source = self.store.url(record).appendingPathExtension("rimesproject")
                    self.performAssetWork { do { let data = try Data(contentsOf: source); try data.write(to: url, options: .atomic) } catch { DispatchQueue.main.async { CaptureUI.error(error) } } }
                }
            }
        }
    }
    private func chooseImages() {
        let dialog = NSOpenPanel(); dialog.allowedContentTypes = [.image]; dialog.allowsMultipleSelection = true
        let background = NSButton(checkboxWithTitle: "用作自定义背景", target: nil, action: nil); dialog.accessoryView = background
        dialog.beginSheetModal(for: panel) { if $0 == .OK { self.importImages(dialog.urls, background: background.state == .on) } }
    }
    private func importImages(_ urls: [URL], background: Bool = false) {
        let directory = store.directory(record.id)
        performAssetWork {
            do {
                var layers: [CaptureImageLayer] = []
                for url in urls.prefix(16) {
                    let image = try CaptureImageIO.read(url)
                    let file = "image-\(UUID().uuidString).png"; try CaptureImageIO.write(image, to: directory.appendingPathComponent(file))
                    layers.append(CaptureImageLayer(file: file, frame: CGRect(x: 0,y: 0,width: image.width,height: image.height)))
                }
                let loaded = layers
                DispatchQueue.main.async {
                    self.mutate { doc in
                        if background { doc.background.imageFile = loaded.first?.file; doc.background.enabled = true }
                        else { for var layer in loaded { layer.frame.origin.y = doc.size.height; doc.size.height += layer.frame.height; doc.size.width = max(doc.size.width,layer.frame.width); doc.layers.append(layer) } }
                    }
                    if background { self.preview = true; self.render() }
                }
            } catch { DispatchQueue.main.async { CaptureUI.error(error, window: self.panel) } }
        }
    }
    private func autoBalance() {
        // Balance the image bounds, including non-text content and annotations.
        // OCR-only cropping can silently cut off charts or controls.
        guard let document, !document.layers.isEmpty else { return }
        let bounds = document.layers.map(\.frame) + document.annotations.map(\.rect)
        let union = bounds.reduce(CGRect.null) { $0.union($1) }.intersection(CGRect(origin: .zero, size: document.size))
        mutate { $0.crop = union; $0.background.enabled = true; $0.background.alignment = 0; $0.background.padding = max(24, min(96, min(union.width, union.height) * 0.08)) }
        preview = true; render()
    }
    private func scaleLayer(_ factor: CGFloat) {
        guard let i = selectedLayer, let document, document.layers.indices.contains(i) else { status.stringValue = "先用选择工具选中一张图片"; return }
        mutate { doc in var frame = doc.layers[i].frame; let center = CGPoint(x: frame.midX, y: frame.midY); frame.size = CGSize(width: frame.width*factor, height: frame.height*factor); frame.origin = CGPoint(x: center.x-frame.width/2, y: center.y-frame.height/2); doc.layers[i].frame = frame }
        canvas.selectedRect = self.document?.layers[i].frame
    }
    private func editSelectedText() {
        guard let selected, let node = document?.annotations.first(where: { $0.id == selected }), node.tool == .text || node.tool == .counter else { return }
        let alert = NSAlert(); alert.messageText = "编辑文字"; alert.addButton(withTitle: "保存"); alert.addButton(withTitle: "取消")
        let field = NSTextField(frame: CGRect(x: 0, y: 0, width: 320, height: 26)); field.stringValue = node.text; alert.accessoryView = field
        alert.beginSheetModal(for: panel) { response in if response == .alertFirstButtonReturn { self.mutate { doc in if let i = doc.annotations.firstIndex(where: { $0.id == selected }) { doc.annotations[i].text = field.stringValue } } } }
    }
    private func recognizeSelection(_ region: CGRect) {
        guard var snapshot = document else { return }
        snapshot.crop = region; snapshot.background.enabled = false; snapshot.turns = 0; snapshot.flip = false; snapshot.outputWidth = nil
        let directory = store.directory(record.id)
        let value = snapshot
        performAssetWork {
            do { let image = try CaptureRenderer.render(value, directory: directory); let text = try CaptureEngine.recognize(image); DispatchQueue.main.async { CaptureCoordinator.shared.showText(text) } }
            catch { DispatchQueue.main.async { CaptureUI.error(error) } }
        }
    }
}

enum CaptureProjectPackage {
    /// A bounded JSON archive. Embedded PNGs make a project self-contained;
    /// the cloud keeps the existing 256 MB per-asset ceiling.
    struct Archive: Codable { let version: Int; let document: CaptureDocument; let files: [String: Data] }
    static func validate(_ data: Data) throws {
        guard data.count <= 256 * 1024 * 1024 else { throw CaptureError.message("工程文件过大") }
        let archive = try JSONDecoder().decode(Archive.self, from: data)
        guard archive.version == 1 else { throw CaptureError.message("工程版本不支持") }
        try archive.document.validate()
        guard Set(archive.document.layers.map(\.file) + [archive.document.background.imageFile].compactMap({ $0 })).isSubset(of: Set(archive.files.keys)) else { throw CaptureError.message("工程素材缺失") }
    }
    static func write(document: CaptureDocument, directory: URL, output: URL) throws {
        try document.validate()
        var files: [String: Data] = [:]; var total = 0
        for file in Set(document.layers.map(\.file) + [document.background.imageFile].compactMap({ $0 })) {
            let data = try Data(contentsOf: directory.appendingPathComponent(file), options: .mappedIfSafe)
            total += data.count
            guard total <= 180 * 1024 * 1024 else { throw CaptureError.message("可编辑工程超过 180 MB，请减少组合图片") }
            files[file] = data
        }
        let data = try JSONEncoder().encode(Archive(version: 1, document: document, files: files))
        try data.write(to: output, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
    }
    static func restore(_ input: URL, directory: URL) throws -> CaptureDocument {
        let values = try input.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey])
        guard values.isSymbolicLink != true, (values.fileSize ?? Int.max) <= 256 * 1024 * 1024 else { throw CaptureError.message("工程文件过大或不是普通文件") }
        let archive = try JSONDecoder().decode(Archive.self, from: Data(contentsOf: input))
        guard archive.version == 1 else { throw CaptureError.message("工程版本不支持") }
        try archive.document.validate()
        for name in Set(archive.document.layers.map(\.file) + [archive.document.background.imageFile].compactMap({ $0 })) {
            guard let data = archive.files[name] else { throw CaptureError.message("工程素材缺失") }
            let url = directory.appendingPathComponent(name)
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        return archive.document
    }
}
