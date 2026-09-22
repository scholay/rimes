import UIKit
import RimesCore

@MainActor final class ProxyTextDelivery: TextDelivery {
    private weak var controller: UIInputViewController?
    private let active: () -> Bool
    private var markedTarget: UUID?
    private var markedText = ""
    private var markedProxy: (any UITextDocumentProxy)?
    private var writeDepth = 0
    var isWriting: Bool { writeDepth > 0 }
    var hasMarkedText: Bool { markedTarget != nil }
    init(controller: UIInputViewController, active: @escaping () -> Bool) {
        self.controller = controller; self.active = active
    }
    private func proxy(for target: UUID) -> UITextDocumentProxy? {
        guard active(), let controller, controller.isViewLoaded, controller.view.window != nil,
              DocumentIdentity.read(controller.textDocumentProxy) == target else { return nil }
        return controller.textDocumentProxy
    }
    func insert(_ text: String, target: UUID) -> Bool {
        writeDepth += 1; defer { writeDepth -= 1 }
        guard !text.isEmpty, let proxy = proxy(for: target) else { return false }
        if markedTarget == target {
            // Replace the entire composition explicitly; insertText can replace
            // only the selected portion of marked text in some input views.
            proxy.setMarkedText(text, selectedRange: NSRange(location: text.utf16.count, length: 0))
            proxy.unmarkText(); forgetMarkedText()
        } else { proxy.insertText(text) }
        return true
    }
    @discardableResult func updateMarkedText(_ text: String, target: UUID) -> Bool {
        writeDepth += 1; defer { writeDepth -= 1 }
        guard let proxy = proxy(for: target) else { return false }
        if markedTarget != nil && markedTarget != target { forgetMarkedText() }
        if text.isEmpty { discardMarkedText(); return true }
        guard markedTarget != target || markedText != text else { return true }
        markedTarget = target; markedText = text; markedProxy = proxy
        proxy.setMarkedText(text, selectedRange: NSRange(location: text.utf16.count, length: 0))
        return true
    }
    func discardMarkedText() {
        writeDepth += 1; defer { writeDepth -= 1 }
        guard let target = markedTarget else { return }
        guard let ownedProxy = proxy(for: target) else { abandonMarkedText(); return }
        forgetMarkedText()
        ownedProxy.setMarkedText("", selectedRange: NSRange(location: 0, length: 0))
        ownedProxy.unmarkText()
    }
    /// Once the host changes selection/document, ownership is gone. Never erase
    /// text at the new caret by trying to clean up an old marked range there.
    func abandonMarkedText() {
        writeDepth += 1; defer { writeDepth -= 1 }
        let target = markedTarget
        let previous = target.flatMap { proxy(for: $0) } ?? markedProxy
        forgetMarkedText()
        // Some hosts retain the old field's marked range after focus moves.
        // End that range through its original proxy only if its identity still
        // matches. Unmarking preserves content and cannot erase a new selection.
        guard active(), let previous, let target, DocumentIdentity.read(previous) == target else { return }
        previous.unmarkText()
    }
    func finishDocumentResetIfNeeded() {
        guard !isWriting else { return }
        writeDepth += 1; defer { writeDepth -= 1 }
        guard active(), let controller, controller.isViewLoaded, controller.view.window != nil,
              DocumentIdentity.read(controller.textDocumentProxy) == nil else { return }
        // UIKit may withhold the new document ID while a refocused field still
        // has a mark from its previous session. Unmarking preserves all text and
        // selections; insertion/deletion still require a verified document ID.
        controller.textDocumentProxy.unmarkText()
    }
    func forgetMarkedText() { markedTarget = nil; markedText = ""; markedProxy = nil }
    func deleteBackward(target: UUID) -> Bool {
        writeDepth += 1; defer { writeDepth -= 1 }
        guard let proxy = proxy(for: target) else { return false }
        proxy.deleteBackward(); return true
    }
}
