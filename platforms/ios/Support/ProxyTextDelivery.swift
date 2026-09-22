import UIKit
import RimesCore

@MainActor final class ProxyTextDelivery: TextDelivery {
    private weak var controller: UIInputViewController?
    private let active: () -> Bool
    init(controller: UIInputViewController, active: @escaping () -> Bool) {
        self.controller = controller; self.active = active
    }
    private func proxy(for target: UUID) -> UITextDocumentProxy? {
        guard active(), let controller, controller.isViewLoaded, controller.view.window != nil,
              controller.textDocumentProxy.documentIdentifier == target else { return nil }
        return controller.textDocumentProxy
    }
    func insert(_ text: String, target: UUID) -> Bool {
        guard !text.isEmpty, let proxy = proxy(for: target) else { return false }
        proxy.insertText(text); return true
    }
    func deleteBackward(target: UUID) -> Bool {
        guard let proxy = proxy(for: target) else { return false }
        proxy.deleteBackward(); return true
    }
}
