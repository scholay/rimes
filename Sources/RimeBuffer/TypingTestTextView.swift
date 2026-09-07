import AppKit

/// A local NSTextInputClient; only committed text leaves this editor for scoring.
final class TypingTestTextView: NSTextView {
    var onPhysicalKey: ((NSEvent) -> Void)?
    var onCommittedText: ((String, Range<Int>?) -> Void)?
    var onCompositionStarted: (() -> Void)?
    var onWillResignFocus: (() -> Void)?
    var onFocusLost: (() -> Void)?
    var onAssistedInput: (() -> Void)?
    var acceptsTestInput = false
    private var publishingSuppressed = false
    private var lastPublishedText = ""
    private var mutationDepth = 0
    private var settingMarkedText = false
    private var pendingInsertionRange: Range<Int>?
    private var ownedTextStorage: NSTextStorage?

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        // NSTextView's designated initializer with nil does not create a text
        // system. Build and retain one so IME marked/insert callbacks are real.
        let effectiveContainer: NSTextContainer
        if let container { effectiveContainer = container }
        else {
            let storage = NSTextStorage()
            let layout = NSLayoutManager()
            effectiveContainer = NSTextContainer(size: NSSize(width: max(1, frameRect.width), height: CGFloat.greatestFiniteMagnitude))
            storage.addLayoutManager(layout)
            layout.addTextContainer(effectiveContainer)
            ownedTextStorage = storage
        }
        super.init(frame: frameRect, textContainer: effectiveContainer)
        isRichText = false
        importsGraphics = false
        allowsUndo = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isAutomaticTextCompletionEnabled = false
        isContinuousSpellCheckingEnabled = false
        isGrammarCheckingEnabled = false
        isAutomaticLinkDetectionEnabled = false
        isAutomaticDataDetectionEnabled = false
        usesFindPanel = false
        font = .systemFont(ofSize: 18)
        textContainerInset = NSSize(width: 14, height: 12)
        backgroundColor = RimeUI.surface
        textColor = RimeUI.textPrimary
        insertionPointColor = RimeUI.accentGreen
        setAccessibilityLabel("文章跟打输入区")
        setAccessibilityHelp("逐字输入上方文章。组字中的编码不判错；不支持粘贴或拖入文字。")
    }
    required init?(coder: NSCoder) { nil }

    func resetForTest() {
        publishingSuppressed = true
        inputContext?.discardMarkedText()
        string = ""
        lastPublishedText = ""
        pendingInsertionRange = nil
        super.setSelectedRange(NSRange(location: 0, length: 0))
        publishingSuppressed = false
    }
    override func keyDown(with event: NSEvent) {
        guard acceptsTestInput else { return }
        onPhysicalKey?(event)
        super.keyDown(with: event)
    }
    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        guard acceptsTestInput || publishingSuppressed else { return }
        if !hasMarkedText(), !publishingSuppressed { onCompositionStarted?() }
        mutationDepth += 1
        settingMarkedText = true
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        settingMarkedText = false
        mutationDepth -= 1
        publishIfCommitted()
    }
    override func insertText(_ string: Any, replacementRange: NSRange) {
        guard acceptsTestInput || publishingSuppressed else { return }
        let inserted = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        let replacement = replacementRange.location != NSNotFound ? replacementRange
            : (hasMarkedText() ? markedRange() : selectedRange())
        let before = self.string as NSString
        guard replacement.location <= before.length,
              replacement.length <= before.length - replacement.location else { return }
        let candidate = before.replacingCharacters(in: replacement, with: inserted)
        guard Self.isAllowedCommittedText(candidate) else { rejectAssistance(); return }
        let capturesInsertion = !settingMarkedText && mutationDepth == 0
        mutationDepth += 1
        super.insertText(string, replacementRange: replacementRange)
        if capturesInsertion, TypingTestSession.normalized(self.string) == TypingTestSession.normalized(candidate) {
            pendingInsertionRange = Self.insertionCharacterRange(
                in: self.string,
                utf16Range: NSRange(location: replacement.location, length: (inserted as NSString).length)
            )
        }
        mutationDepth -= 1
        publishIfCommitted()
    }
    override func unmarkText() {
        mutationDepth += 1
        super.unmarkText()
        mutationDepth -= 1
        publishIfCommitted()
    }
    override func didChangeText() { super.didChangeText(); publishIfCommitted() }
    override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
        guard acceptsTestInput || publishingSuppressed else { return false }
        let count = (string as NSString).length
        let added = ((replacementString ?? "") as NSString).length
        guard affectedCharRange.location <= count,
              affectedCharRange.length <= count - affectedCharRange.location,
              count - affectedCharRange.length + added <= 16_384 else { NSSound.beep(); return false }
        let candidate = (string as NSString).replacingCharacters(in: affectedCharRange,
                                                                with: replacementString ?? "")
        if !Self.isAllowedCommittedText(candidate) { return false }
        return super.shouldChangeText(in: affectedCharRange, replacementString: replacementString)
    }
    override func resignFirstResponder() -> Bool {
        // AppKit may synchronously commit composition inside super. Mark the
        // session before that callback can auto-finish as a formal result.
        if acceptsTestInput, !publishingSuppressed { onWillResignFocus?() }
        let resigned = super.resignFirstResponder()
        if resigned, acceptsTestInput, !publishingSuppressed { onFocusLost?() }
        return resigned
    }
    override func paste(_ sender: Any?) { rejectAssistance() }
    override func pasteAsPlainText(_ sender: Any?) { rejectAssistance() }
    override func pasteAsRichText(_ sender: Any?) { rejectAssistance() }
    override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        rejectAssistance(); return false
    }
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { [] }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        rejectAssistance(); return false
    }
    override func complete(_ sender: Any?) { rejectAssistance() }
    private func rejectAssistance() {
        guard acceptsTestInput else { return }
        onAssistedInput?(); NSSound.beep()
    }
    private func publishIfCommitted() {
        guard acceptsTestInput, !publishingSuppressed, mutationDepth == 0, !hasMarkedText(),
              string != lastPublishedText || pendingInsertionRange != nil else { return }
        let insertion = pendingInsertionRange
        pendingInsertionRange = nil
        guard Self.isAllowedCommittedText(string) else { onAssistedInput?(); return }
        lastPublishedText = string
        onCommittedText?(string, insertion)
    }
    static func isAllowedCommittedText(_ text: String) -> Bool {
        !text.contains("\0") && text.utf8.count <= TypingTestSession.maximumTextBytes
            && TypingTestSession.normalized(text).count <= TypingTestSession.maximumCharacters
    }
    static func insertionCharacterRange(in text: String, utf16Range: NSRange) -> Range<Int>? {
        let native = text as NSString
        guard utf16Range.location <= native.length,
              utf16Range.length <= native.length - utf16Range.location else { return nil }
        // A separately committed combining mark or ZWJ can merge with an
        // existing grapheme. Expand in the resulting string, not the old text.
        let affected = native.rangeOfComposedCharacterSequences(for: utf16Range)
        let lower = TypingTestSession.normalized(native.substring(to: affected.location)).count
        let length = TypingTestSession.normalized(native.substring(with: affected)).count
        return lower..<(lower + length)
    }
}
