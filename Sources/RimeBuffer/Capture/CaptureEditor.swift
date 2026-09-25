import AppKit
import Vision
import UniformTypeIdentifiers

final class CaptureCanvas: NSView {
    /// The editor panel has no title bar, so it is movable by its background.
    /// That made every drag on the canvas move the window instead of drawing:
    /// AppKit runs its own event loop for a background drag and the view
    /// never sees mouseDragged, so an annotation kept its start point and was
    /// committed zero-sized — the tools looked dead while the log showed a
    /// clean mouseDown/mouseUp pair. Chrome still drags the window; the
    /// drawing surface does not.
    override var mouseDownCanMoveWindow: Bool { false }
    var image: CGImage? { didSet { needsDisplay = true } }
    var documentSize = CGSize(width: 1, height: 1)
    var displayPixelSize: CGSize?
    var tool: CaptureTool = .select
    var color = "FFE338"
    var zoom: CGFloat? { didSet { pan = .zero; needsDisplay = true } }
    private var pan = CGPoint.zero
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
        let scale = zoom.map { $0 * (displayPixelSize ?? documentSize).width / CGFloat(image.width) } ?? min((bounds.width-72)/CGFloat(image.width), (bounds.height-72)/CGFloat(image.height))
        let size = CGSize(width: CGFloat(image.width)*scale, height: CGFloat(image.height)*scale)
        return CGRect(x: (bounds.width-size.width)/2 + pan.x, y: (bounds.height-size.height)/2 + pan.y, width: size.width, height: size.height)
    }
    override func scrollWheel(with event: NSEvent) {
        guard zoom != nil else { return }
        let rect = imageRect
        pan.x = min(max(0, (rect.width - bounds.width) / 2 + 24), max(-max(0, (rect.width - bounds.width) / 2 + 24), pan.x + event.scrollingDeltaX))
        pan.y = min(max(0, (rect.height - bounds.height) / 2 + 24), max(-max(0, (rect.height - bounds.height) / 2 + 24), pan.y + event.scrollingDeltaY))
        needsDisplay = true
    }
    private func point(_ event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil), rect = imageRect
        return CGPoint(x: min(documentSize.width, max(0,(point.x-rect.minX)/max(1,rect.width)*documentSize.width)),
                       y: min(documentSize.height, max(0,(point.y-rect.minY)/max(1,rect.height)*documentSize.height)))
    }
    override func mouseDown(with event: NSEvent) {
        // DIAGNOSTIC: drawing reported dead. This says whether the canvas is
        // reached at all, which tool it thinks is active, and whether preview
        // mode is swallowing the press.
        IMELog.write("capture canvas mouseDown tool=\(tool.rawValue) "
            + "previewOnly=\(previewOnly) size=\(documentSize)")
        guard !previewOnly, imageRect.contains(convert(event.locationInWindow, from: nil)) else { return }
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
        IMELog.write("capture canvas mouseUp tool=\(tool.rawValue) "
            + "rect=\(node.rect) color=\(node.color) width=\(node.width) "
            + "hasSink=\(complete != nil)")
        complete?(node); needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        CaptureChrome.canvas.setFill(); bounds.fill()
        guard let image, let cg = NSGraphicsContext.current?.cgContext else { return }
        NSImage(cgImage: image, size: .zero).draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        if let draft {
            cg.saveGState(); cg.translateBy(x: imageRect.minX, y: imageRect.minY)
            cg.scaleBy(x: imageRect.width/documentSize.width, y: imageRect.height/documentSize.height)
            if draft.tool == .crop { cg.setStrokeColor(CaptureChrome.blue.cgColor); cg.setLineWidth(3); cg.stroke(draft.rect) }
            else { CaptureRenderer.draw(draft, context: cg, canvas: documentSize) }
            cg.restoreGState()
        }
        if let rect = selectedRect, !previewOnly {
            let r = CGRect(x: imageRect.minX + rect.minX/documentSize.width*imageRect.width, y: imageRect.minY + rect.minY/documentSize.height*imageRect.height, width: rect.width/documentSize.width*imageRect.width, height: rect.height/documentSize.height*imageRect.height)
            CaptureChrome.blue.setStroke(); NSBezierPath(rect: r.insetBy(dx: -3, dy: -3)).stroke()
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
    private(set) var document: CaptureDocument?
    private var undo: [CaptureDocument] = []
    private var redo: [CaptureDocument] = []
    private var selectionDragRecorded = false
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
    private var toolButtons: [CaptureToolButton] = []
    private var controlActions: [CaptureControlAction] = []
    private var menuActions: [CaptureControlAction] = []
    private var popover: NSPopover?
    private weak var colorButton: CaptureChromeButton?
    private weak var previewButton: CaptureChromeButton?

    init(record: CaptureRecord, store: CaptureStore) throws {
        self.record = record; self.store = store
        panel = CapturePanel(size: NSSize(width: 1200, height: 780))
        panel.captureChrome = true
        panel.minSize = NSSize(width: 1040, height: 700); panel.escapeCloses = false
        panel.shouldClose = { [weak self] in self?.requestClose(); return false }
        guard store.acquire(record.id) else { throw CaptureError.message("资产正在清理，请刷新捕获历史") }
        build()
        panel.closed = { [weak self] in
            guard let self else { return }; self.closed = true; self.store.release(self.record.id)
            self.popover?.close(); self.popover = nil
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
            } catch { DispatchQueue.main.async { self.status.stringValue = error.localizedDescription; self.status.isHidden = false } }
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
        let previous = document
        body(&document)
        guard document != previous else { return }
        recordUndo(previous); self.document = document; render()
    }
    private func recordUndo(_ document: CaptureDocument) {
        undo.append(document); if undo.count > 60 { undo.removeFirst() }; redo.removeAll()
    }
    private func render() {
        guard var snapshot = document else { return }
        canvas.documentSize = snapshot.size; canvas.previewOnly = preview
        previewButton?.active = preview
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
                case .success(let image):
                    let annotationCount = value.annotations.count
                    IMELog.write("capture render ok \(image.width)x\(image.height) "
                        + "annotations=\(annotationCount)")
                    self.canvas.image = image
                    self.canvas.displayPixelSize = CaptureRenderer.outputPixelSize(value)
                    self.status.isHidden = true
                case .failure(let error):
                    IMELog.write("capture render FAILED \(error.localizedDescription)")
                    self.status.stringValue = error.localizedDescription
                    self.status.isHidden = false
                }
            }
        }
        renderQueue.addOperation(operation)
    }
    /// The rail shows which tool is active, so every change has to reach it.
    private func syncToolSelection() {
        for button in toolButtons {
            button.isActiveTool = button.accessibilityLabel() == canvas.tool.title
        }
    }

    private func build() {
        let drag = CaptureCurrentDragView()
        drag.snapshot = { [weak self] in guard let self, let document = self.document else { return nil }; return (document, self.store.directory(self.record.id), self.store, self.record.id) }
        let root = panel.contentView!
        let top = CaptureChromeSurface()
        let footer = CaptureChromeSurface()
        let traffic = NSView(); traffic.widthAnchor.constraint(equalToConstant: 68).isActive = true
        let crop = CaptureChromeButton(symbol: "crop", help: "裁剪") { [weak self] in self?.selectTool(.crop) }
        let add = CaptureChromeButton(symbol: "photo.badge.plus", help: "添加图片") { [weak self] in self?.chooseImages() }
        let background = CaptureChromeButton(symbol: "photo.on.rectangle", help: "背景与画布")
        background.onClick = { [weak self, weak background] in
            guard let self, let background else { return }; self.showPopover(self.makeBackgroundControls(), from: background)
        }
        let visibleTools: [CaptureTool] = [.select, .rectangle, .filledRectangle, .ellipse, .line, .arrow, .text, .pixelate, .spotlight, .counter, .pen, .highlight]
        let tools = visibleTools.map { tool in
            let button = CaptureToolButton(tool: tool) { [weak self] in self?.selectTool($0) }
            toolButtons.append(button); return button
        }
        let group = CaptureChrome.group(tools, spacing: 0, inset: 0)
        let color = CaptureChromeButton(help: "标注颜色", size: NSSize(width: 48, height: 32)); color.dropdown = true
        color.swatch = CaptureColorValue.parse(canvas.color); colorButton = color
        color.onClick = { [weak self, weak color] in
            guard let self, let color else { return }
            let picker = CaptureColorPicker(hex: self.canvas.color)
            // One color-popover session is one undo step, even while dragging.
            var registeredUndo = false
            picker.onChange = { [weak self, weak color] value in
                guard let self else { return }
                self.canvas.color = value; color?.swatch = CaptureColorValue.parse(value)
                if let selected = self.selected, let index = self.document?.annotations.firstIndex(where: { $0.id == selected }) {
                    guard self.document?.annotations[index].color != value else { return }
                    if !registeredUndo, let document = self.document { self.recordUndo(document); registeredUndo = true }
                    self.document?.annotations[index].color = value; self.render()
                }
            }
            self.showPopover(picker, from: color)
        }
        let stroke = CaptureChromeButton(symbol: "line.diagonal", help: "线条粗细", size: NSSize(width: 48, height: 32)); stroke.dropdown = true
        stroke.onClick = { [weak self, weak stroke] in
            guard let self, let stroke else { return }
            self.showMenu([1, 3, 5, 8, 12, 20].map { "\($0) px" }, from: stroke) { index in
                self.canvas.stroke = CGFloat([1, 3, 5, 8, 12, 20][index])
                if let selected = self.selected { self.mutate { doc in if let i = doc.annotations.firstIndex(where: { $0.id == selected }) { doc.annotations[i].width = self.canvas.stroke } } }
            }
        }
        let saveAs = CaptureChromeButton(symbol: "square.and.arrow.down", help: "另存为…") { [weak self] in self?.exportImage() }
        let done = CaptureChromeButton(symbol: "checkmark", help: "完成") { [weak self] in self?.save { [weak self] _ in self?.panel.close() } }; done.active = true
        let topRow = CaptureUI.row([traffic, crop, add, background, group, color, stroke, CaptureChrome.spacer(), saveAs, done], spacing: 6)
        CaptureUI.fill(topRow, in: top, inset: 12)
        let zoom = CaptureChromeButton(symbol: "plus.magnifyingglass", help: "画布缩放", size: NSSize(width: 48, height: 32)); zoom.dropdown = true
        zoom.onClick = { [weak self, weak zoom] in
            guard let self, let zoom else { return }
            self.showMenu(["适合", "50%", "100%", "200%"], from: zoom) { index in
                self.canvas.zoom = [nil, 0.5, 1, 2][index]; zoom.title = ["适合", "50%", "100%", "200%"][index]
            }
        }
        let undo = CaptureChromeButton(symbol: "arrow.uturn.backward", help: "撤销 ⌘Z", size: NSSize(width: 32, height: 32)) { [weak self] in self?.undoEdit() }; undo.bare = true
        let redo = CaptureChromeButton(symbol: "arrow.uturn.forward", help: "重做 ⇧⌘Z", size: NSSize(width: 32, height: 32)) { [weak self] in self?.redoEdit() }; redo.bare = true
        let preview = CaptureChromeButton(symbol: "eye", help: "切换效果预览")
        preview.onClick = { [weak self, weak preview] in guard let self else { return }; self.preview.toggle(); preview?.active = self.preview; self.render() }
        previewButton = preview
        let pin = CaptureChromeButton(symbol: "pin.fill", help: "贴图") { [weak self] in self?.save { CaptureCoordinator.shared.pin($0) } }
        let copy = CaptureChromeButton(symbol: "doc.on.doc", help: "复制图片") { [weak self] in self?.save { CaptureCoordinator.shared.copy($0) } }
        let left = CaptureUI.row([zoom, undo, redo], spacing: 4)
        let right = CaptureUI.row([preview, pin, copy], spacing: 6)
        for view in [left, drag, right] { view.translatesAutoresizingMaskIntoConstraints = false; footer.addSubview(view) }
        for view in [top, canvas, footer] { view.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(view) }
        NSLayoutConstraint.activate([
            top.leadingAnchor.constraint(equalTo: root.leadingAnchor), top.trailingAnchor.constraint(equalTo: root.trailingAnchor), top.topAnchor.constraint(equalTo: root.topAnchor), top.heightAnchor.constraint(equalToConstant: 56),
            canvas.leadingAnchor.constraint(equalTo: root.leadingAnchor), canvas.trailingAnchor.constraint(equalTo: root.trailingAnchor), canvas.topAnchor.constraint(equalTo: top.bottomAnchor), canvas.bottomAnchor.constraint(equalTo: footer.topAnchor),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor), footer.trailingAnchor.constraint(equalTo: root.trailingAnchor), footer.bottomAnchor.constraint(equalTo: root.bottomAnchor), footer.heightAnchor.constraint(equalToConstant: 54),
            left.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 14), left.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            drag.centerXAnchor.constraint(equalTo: footer.centerXAnchor), drag.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            right.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -14), right.centerYAnchor.constraint(equalTo: footer.centerYAnchor)
        ])
        status.textColor = CaptureChrome.muted; status.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(status)
        NSLayoutConstraint.activate([status.centerXAnchor.constraint(equalTo: canvas.centerXAnchor), status.centerYAnchor.constraint(equalTo: canvas.centerYAnchor)])
        // Real traffic lights retain standard close/minimize/zoom semantics.
        panel.styleMask.insert([.closable, .miniaturizable])
        for (index, type) in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].enumerated() {
            if let button = panel.standardWindowButton(type) {
                button.isHidden = false; button.removeFromSuperview(); traffic.addSubview(button)
                button.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([button.leadingAnchor.constraint(equalTo: traffic.leadingAnchor, constant: CGFloat(index * 22)), button.centerYAnchor.constraint(equalTo: traffic.centerYAnchor), button.widthAnchor.constraint(equalToConstant: 14), button.heightAnchor.constraint(equalToConstant: 14)])
            }
        }
        traffic.heightAnchor.constraint(equalToConstant: 32).isActive = true
        syncToolSelection()
        canvas.complete = { [weak self] in self?.add($0) }
        canvas.pick = { [weak self] point in
            guard let self else { return }
            self.selectionDragRecorded = false
            let node = self.document?.annotations.reversed().first { $0.rect.insetBy(dx: -15, dy: -15).contains(point) }
            self.selected = node?.id
            if let node { self.canvas.color = node.color; self.canvas.stroke = node.width; self.colorButton?.swatch = CaptureColorValue.parse(node.color) }
            self.selectedLayer = node == nil ? self.document?.layers.indices.reversed().first { self.document!.layers[$0].frame.contains(point) } : nil
            self.canvas.selectedRect = node?.rect ?? self.selectedLayer.flatMap { self.document?.layers[$0].frame }; self.canvas.needsDisplay = true
        }
        canvas.moveSelection = { [weak self] delta in
            guard let self, !self.closed, delta != .zero, delta.x.isFinite, delta.y.isFinite,
                  var document = self.document else { return }
            let previous = document
            if let selected = self.selected, let index = document.annotations.firstIndex(where: { $0.id == selected }) {
                document.annotations[index].points = document.annotations[index].points.map { CGPoint(x: $0.x+delta.x, y: $0.y+delta.y) }
                self.canvas.selectedRect = document.annotations[index].rect
            } else if let index = self.selectedLayer, document.layers.indices.contains(index) {
                document.layers[index].frame = document.layers[index].frame.offsetBy(dx: delta.x, dy: delta.y)
                self.canvas.selectedRect = document.layers[index].frame
            }
            guard document != previous else { return }
            if !self.selectionDragRecorded { self.recordUndo(previous); self.selectionDragRecorded = true }
            self.document = document
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

    /// Binds a control to a closure so it applies as it changes.
    private func bind(_ control: NSControl, _ perform: @escaping () -> Void) {
        let action = CaptureControlAction(perform)
        controlActions.append(action)
        control.target = action
        control.action = #selector(CaptureControlAction.fire)
    }

    private func selectTool(_ tool: CaptureTool) {
        canvas.tool = tool; canvas.selectedRect = nil; selected = nil; selectedLayer = nil
        preview = false; syncToolSelection(); render()
    }
    private func showPopover(_ view: NSView, from button: NSView) {
        popover?.close()
        let controller = NSViewController(); controller.view = view
        let popover = NSPopover(); popover.behavior = .transient; popover.appearance = NSAppearance(named: .darkAqua)
        popover.contentViewController = controller
        popover.contentSize = view.frame.size == .zero ? view.fittingSize : view.frame.size
        self.popover = popover; popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
    }
    private func showMenu(_ titles: [String], from view: NSView, picked: @escaping (Int) -> Void) {
        menuActions.removeAll(); let menu = NSMenu()
        defer { menuActions.removeAll() }
        for (index, title) in titles.enumerated() {
            let target = CaptureControlAction { picked(index) }; menuActions.append(target)
            let item = NSMenuItem(title: title, action: #selector(CaptureControlAction.fire), keyEquivalent: ""); item.target = target; menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: .zero, in: view)
    }
    private func makeBackgroundControls() -> NSView {
        controlActions.removeAll()
        let current = document?.background ?? CaptureBackground()
        let enabled = NSButton(checkboxWithTitle: "启用背景", target: nil, action: nil); enabled.state = current.enabled ? .on : .off
        let padding = NSTextField(string: String(Int(current.padding)))
        let corner = NSTextField(string: String(Int(current.corner)))
        let shadow = NSTextField(string: String(Int(current.shadow)))
        let color = NSColorWell(); color.color = CaptureColorValue.parse(current.color) ?? .white
        let change = { [weak self] in
            guard let self else { return }
            self.mutate { doc in
                doc.background.enabled = enabled.state == .on
                doc.background.padding = min(2000, max(0, padding.doubleValue))
                doc.background.corner = min(1000, max(0, corner.doubleValue))
                doc.background.shadow = min(200, max(0, shadow.doubleValue))
                doc.background.color = CaptureColorValue.hex(color.color); doc.background.secondColor = nil
            }
            self.preview = true; self.render()
        }
        for control in [enabled, padding, corner, shadow, color] { bind(control, change) }
        let stack = CaptureUI.column([
            enabled, CaptureUI.field("颜色", color), CaptureUI.field("留白", padding),
            CaptureUI.field("圆角", corner), CaptureUI.field("阴影", shadow),
            CaptureUI.row([
                CaptureChromeButton(symbol: "rotate.right", help: "旋转") { [weak self] in self?.mutate { $0.turns += 1 }; self?.preview = true; self?.render() },
                CaptureChromeButton(symbol: "arrow.left.and.right.righttriangle.left.righttriangle.right", help: "翻转") { [weak self] in self?.mutate { $0.flip.toggle() }; self?.preview = true; self?.render() }
            ])
        ], spacing: 10)
        let body = CaptureChromeSurface(); body.frame = CGRect(x: 0, y: 0, width: 228, height: 248)
        CaptureUI.fill(stack, in: body, inset: 16); return body
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
        IMELog.write("capture annotation stored count=\(document?.annotations.count ?? -1)")
    }
    private func undoEdit() { guard let previous = undo.popLast(), let document else { return }; redo.append(document); self.document = previous; selected = nil; selectedLayer = nil; canvas.selectedRect = nil; render() }
    private func redoEdit() { guard let next = redo.popLast(), let document else { return }; undo.append(document); self.document = next; selected = nil; selectedLayer = nil; canvas.selectedRect = nil; render() }
    private func requestClose() {
        guard !saving else { status.stringValue = "正在保存，请稍候"; status.isHidden = false; return }
        guard document != saved else { panel.close(); return }
        let alert = NSAlert(); alert.messageText = "保存本次编辑？"; alert.addButton(withTitle: "保存"); alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "放弃修改")
        alert.beginSheetModal(for: panel) { response in
            if response == .alertFirstButtonReturn { self.save { _ in self.panel.close() } }
            else if response == .alertThirdButtonReturn { self.panel.close() }
        }
    }
    private func save(completion: ((CaptureRecord) -> Void)? = nil) {
        guard let snapshot = document, !saving else { return }
        saving = true; status.stringValue = "正在保存工程…"; status.isHidden = false
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
                DispatchQueue.main.async { self.record = result; self.saved = snapshot; self.saving = false; self.status.stringValue = "工程已保存"; self.status.isHidden = true; completion?(result) }
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
