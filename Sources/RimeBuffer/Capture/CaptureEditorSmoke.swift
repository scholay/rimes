import AppKit

@MainActor
enum CaptureEditorSmoke {
    static func run(record: CaptureRecord, store: CaptureStore) throws {
        func require(_ condition: Bool, _ message: String) throws {
            if !condition { throw CaptureError.message("editor history: " + message) }
        }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let editor = try CaptureEditor(record: record, store: store)
        defer { editor.panel.close() }
        let deadline = Date().addingTimeInterval(8)
        while editor.document == nil, Date() < deadline {
            _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        guard let initial = editor.document, let root = editor.panel.contentView,
              let canvas = descendants(root).compactMap({ $0 as? CaptureCanvas }).first else {
            throw CaptureError.message("editor history: fixture did not load")
        }
        let buttons = descendants(root).compactMap { $0 as? CaptureChromeButton }
        func action(_ title: String) throws {
            guard let button = buttons.first(where: { $0.accessibilityLabel() == title }) else {
                throw CaptureError.message("editor history: missing action")
            }
            button.performClick(nil)
        }
        let node = CaptureAnnotation(tool: .rectangle, points: [CGPoint(x: 30, y: 30), CGPoint(x: 130, y: 130)])
        canvas.complete?(node)
        let annotated = editor.document
        canvas.pick?(CGPoint(x: 70, y: 70))
        canvas.moveSelection?(.zero)
        try action("撤销 ⌘Z")
        try require(editor.document == initial, "selection/no-op drag creates no undo entry")
        canvas.pick?(CGPoint(x: -100, y: -100))
        canvas.moveSelection?(CGPoint(x: 5, y: 0))
        try action("重做 ⇧⌘Z")
        try require(editor.document == annotated, "selection and unselected drag preserve redo")

        canvas.pick?(CGPoint(x: 70, y: 70))
        canvas.moveSelection?(CGPoint(x: 5, y: 4))
        canvas.moveSelection?(CGPoint(x: 7, y: 3))
        let moved = editor.document
        try require(moved?.annotations.last?.points.first == CGPoint(x: 42, y: 37), "drag moves selected annotation")
        try action("撤销 ⌘Z")
        try require(editor.document == annotated, "one undo restores entire multi-event drag")
        try action("重做 ⇧⌘Z")
        try require(editor.document == moved, "redo restores exact drag result")
        try action("撤销 ⌘Z")
        canvas.pick?(CGPoint(x: 70, y: 70))
        canvas.moveSelection?(CGPoint(x: 1, y: 1))
        let replacement = editor.document
        try action("重做 ⇧⌘Z")
        try require(editor.document == replacement && replacement != moved, "new real edit retires redo")

        canvas.pick?(CGPoint(x: 300, y: 300))
        canvas.moveSelection?(CGPoint(x: 9, y: 11))
        try require(editor.document?.layers.first?.frame.origin == CGPoint(x: 9, y: 11), "layer dragging uses same history policy")
        try action("撤销 ⌘Z")
        try require(editor.document == replacement, "layer drag undo restores exact document")
        print("capture-editor-smoke: OK (selection, no-op, redo preservation, coalesced annotation/layer drag)")
    }
}
