import AppKit

/// Retain each callback with its menu item (NSMenuItem.target is weak).
enum CapsuleCardMenu {
    static func make(_ actions: [(String, String, Bool, () -> Void)]) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for (title, symbol, enabled, action) in actions {
            let handler = Handler(action)
            let item = NSMenuItem(title: title, action: #selector(Handler.invoke), keyEquivalent: "")
            item.target = handler
            item.representedObject = handler
            item.isEnabled = enabled
            item.image = RimeUI.symbol(symbol, pointSize: 13, weight: .regular)
            item.image?.isTemplate = true
            menu.addItem(item)
        }
        return menu
    }

    private final class Handler: NSObject {
        private let action: () -> Void
        init(_ action: @escaping () -> Void) { self.action = action }
        @objc func invoke() { action() }
    }
}
