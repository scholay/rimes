import AppKit

/// Capture history has its own metadata source, while sharing Capsule's
/// bottom rail, search composition, geometry and keyboard ownership.
final class CaptureHistoryView: NSView {
    private let scroll = NSScrollView()
    private let stack = NSStackView()
    private let empty = CaptureUI.label("还没有捕获内容，点击相机开始")
    private let queue = DispatchQueue(label:"RIMES.Capture.history",qos:.userInitiated)
    private var records: [CaptureRecord] = []
    private var selected: UUID?
    private var observer: NSObjectProtocol?
    private var viewportObserver: NSObjectProtocol?
    private var generation = UUID()
    var enabled = false
    var storeProvider: () throws -> CaptureStore = { try CaptureStore.shared.get() }
    var mediaFilter = 0 { didSet { render() } }
    var query = "" { didSet { if query != oldValue { render() } } }
    var protected = false { didSet { if protected != oldValue { render() } } }
    override init(frame frameRect: NSRect) {
        super.init(frame:frameRect)
        stack.orientation = .horizontal; stack.alignment = .top; stack.spacing = 8
        scroll.documentView = stack; scroll.drawsBackground = false; scroll.hasHorizontalScroller = true
        CaptureUI.fill(scroll,in:self,inset:0)
        addSubview(empty); empty.frame = CGRect(x:12,y:40,width:480,height:28)
        observer = NotificationCenter.default.addObserver(forName:.capsuleCapturesDidChange,object:nil,queue:.main) { [weak self] _ in self?.reload() }
        scroll.contentView.postsBoundsChangedNotifications = true
        viewportObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self] _ in self?.loadVisiblePreviews() }
    }
    required init?(coder:NSCoder) { fatalError() }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) }; if let viewportObserver { NotificationCenter.default.removeObserver(viewportObserver) } }
    override func layout() { super.layout(); loadVisiblePreviews() }
    override func scrollWheel(with event: NSEvent) {
        let delta = ClipboardHistoryScrollRules.horizontalDelta(deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY, precise: event.hasPreciseScrollingDeltas, shiftHeld: event.modifierFlags.contains(.shift))
        let x = min(max(0, stack.frame.width-scroll.contentSize.width), max(0, scroll.contentView.bounds.minX+delta))
        scroll.contentView.scroll(to: CGPoint(x: x, y: 0)); scroll.reflectScrolledClipView(scroll.contentView)
    }
    private func loadVisiblePreviews() {
        let visible = scroll.contentView.bounds.insetBy(dx: -214, dy: 0)
        for case let card as CaptureHistoryCard in stack.arrangedSubviews { card.showPreview(card.frame.intersects(visible)) }
    }
    func reload() {
        guard enabled else { return }
        let token = UUID(); generation = token
        let provider = storeProvider
        queue.async {
            let result = Result { try provider().records() }
            DispatchQueue.main.async {
                guard self.generation == token else { return }
                switch result {
                case .success(let records): self.records = records; self.render()
                case .failure(let error): self.empty.stringValue = error.localizedDescription; self.empty.isHidden = false
                }
            }
        }
    }
    private var filtered: [CaptureRecord] {
        guard !protected else { return [] }
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        return Array(records.filter { r in (mediaFilter == 0 || (mediaFilter == 1 ? r.kind != .video : r.kind == .video)) && terms.allSatisfy { (r.title+" "+r.kind.label+" "+r.source+" "+r.text).localizedCaseInsensitiveContains($0) } }.prefix(200))
    }
    private func render() {
        stack.arrangedSubviews.forEach { stack.removeArrangedSubview($0); $0.removeFromSuperview() }
        let values = filtered
        if !values.contains(where: { $0.id == selected }) { selected = values.first?.id }
        empty.isHidden = !values.isEmpty; empty.stringValue = protected ? "受保护内容" : "没有匹配的捕获内容"
        guard enabled, let store = try? storeProvider() else { return }
        for record in values {
            let card = CaptureHistoryCard(record:record, file:store.url(record), previewFile:store.previewURL(record))
            card.selected = record.id == selected
            card.choose = { [weak self] in self?.selected = record.id; self?.updateSelection() }
            card.open = { CaptureCoordinator.shared.edit(record) }
            card.widthAnchor.constraint(equalToConstant:206).isActive = true
            card.heightAnchor.constraint(equalToConstant:126).isActive = true
            stack.addArrangedSubview(card)
        }
        stack.frame = CGRect(x:0,y:0,width:CGFloat(values.count)*214,height:126)
        stack.layoutSubtreeIfNeeded(); loadVisiblePreviews()
    }
    private func updateSelection() {
        for case let card as CaptureHistoryCard in stack.arrangedSubviews { card.selected = card.record.id == selected }
    }
    private var current: CaptureRecord? { filtered.first { $0.id == selected } ?? filtered.first }
    @discardableResult func activate() -> Bool { guard let current else { return false }; CaptureCoordinator.shared.edit(current); return true }
    @discardableResult func copy() -> Bool { guard let current else { return false }; CaptureCoordinator.shared.copy(current); return true }
    @discardableResult func collect() -> Bool { guard let current else { return false }; CaptureCoordinator.shared.collect(current); return true }
    @discardableResult func remove() -> Bool {
        guard let current else { return false }
        queue.async { do { try CaptureStore.shared.get().remove(current.id) } catch { DispatchQueue.main.async { CaptureUI.error(error) } } }; return true
    }
    func move(_ delta:Int) {
        let values = filtered; guard !values.isEmpty else { return }
        let index = values.firstIndex { $0.id == selected } ?? 0
        selected = values[max(0,min(values.count-1,index+delta))].id; updateSelection()
        if let view = stack.arrangedSubviews.first(where: { ($0 as? CaptureHistoryCard)?.record.id == selected }) { view.scrollToVisible(view.bounds) }
    }
}

/// The editor reuses the same capture cards, search metadata, thumbnail loader
/// and actions as Capsule's capture tab.
final class CaptureLibraryStrip: NSView, NSSearchFieldDelegate {
    private let history = CaptureHistoryView()
    private let filter = NSPopUpButton()
    private let search = NSSearchField()
    init(store: CaptureStore) {
        super.init(frame: .zero)
        history.storeProvider = { store }; history.enabled = true
        filter.addItems(withTitles: ["捕获", "图片", "视频"]); filter.target = self; filter.action = #selector(changeFilter)
        search.placeholderString = "搜索捕获内容…"; search.delegate = self
        let controls = CaptureUI.column([filter, search], spacing: 10); controls.widthAnchor.constraint(equalToConstant: 180).isActive = true
        let row = CaptureUI.row([controls, history], spacing: 14)
        history.heightAnchor.constraint(equalToConstant: 126).isActive = true
        history.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        CaptureUI.fill(row, in: self, inset: 0)
        history.reload()
    }
    required init?(coder: NSCoder) { fatalError() }
    func controlTextDidChange(_ notification: Notification) { history.query = search.stringValue }
    @objc private func changeFilter() { history.mediaFilter = filter.indexOfSelectedItem }
}

private final class CaptureHistoryCard: NSView {
    let record: CaptureRecord
    var choose:(()->Void)?
    var open:(()->Void)?
    var selected = false { didSet { layer?.borderColor = selected ? RimeUI.accentGreen.cgColor : RimeUI.border.cgColor } }
    private let image = CaptureDragImageView()
    private var operation: Operation?
    private let file: URL
    private let previewFile: URL
    init(record:CaptureRecord,file:URL,previewFile:URL) {
        self.record = record; self.file = file; self.previewFile = previewFile; super.init(frame:.zero)
        wantsLayer = true; layer?.cornerRadius = 11; layer?.borderWidth = 1; layer?.backgroundColor = RimeUI.surface3.cgColor
        image.clicked = { [weak self] event in if event.clickCount >= 2 { self?.open?() } else { self?.choose?() } }
        image.file = file; image.imageScaling = .scaleProportionallyUpOrDown
        image.widthAnchor.constraint(equalToConstant:186).isActive = true; image.heightAnchor.constraint(equalToConstant:72).isActive = true
        let title = CaptureUI.label(String(record.title.prefix(25)),size:11)
        let duration = record.kind == .video ? String(format: " · %02d:%02d", Int(record.duration)/60, Int(record.duration)%60) : ""
        let detail = CaptureUI.label(record.kind.label + duration + (record.collectionID == nil ? "" : " · 已收藏") + (record.incomplete ? " · 未完成" : ""),size:10)
        CaptureUI.fill(CaptureUI.column([image,title,detail],spacing:3),in:self,inset:8)
        setAccessibilityElement(true); setAccessibilityLabel(record.title)
    }
    func showPreview(_ visible: Bool) {
        if !visible { operation?.cancel(); operation = nil; image.image = nil; return }
        guard operation == nil else { return }
        operation = CapsuleMediaPreviewLoader.shared.load(kind:record.thumbnail == nil ? record.kind.capsuleKind : .image,path:previewFile.path,maximumPixelSize:512) { [weak self] result in
            if case let .image(image) = result { self?.image.image = NSImage(cgImage:image,size:.zero) }
        }
    }
    required init?(coder:NSCoder) { fatalError() }
    deinit { operation?.cancel() }
    override func acceptsFirstMouse(for event:NSEvent?)->Bool { true }
    override func mouseDown(with event:NSEvent) { if event.clickCount >= 2 { open?() } else { choose?() } }
    override func menu(for event:NSEvent)->NSMenu? {
        let menu = NSMenu()
        for (title,tag) in [("打开",0),("复制",1),("收入 Capsule",2),("贴图",3),("识别文字",4),("保存文件",5)] {
            let item = NSMenuItem(title:title,action:#selector(action(_:)),keyEquivalent:""); item.target = self; item.tag = tag; menu.addItem(item)
        }
        return menu
    }
    @objc private func action(_ sender:NSMenuItem) {
        switch sender.tag {
        case 0: CaptureCoordinator.shared.edit(record)
        case 1: CaptureCoordinator.shared.copy(record)
        case 2: CaptureCoordinator.shared.collect(record)
        case 3: CaptureCoordinator.shared.pin(record)
        case 4: CaptureCoordinator.shared.ocr(record)
        case 5: CaptureCoordinator.shared.export(record)
        default: break
        }
    }
}
