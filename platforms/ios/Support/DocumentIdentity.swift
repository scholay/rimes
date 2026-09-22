import UIKit

/// UIKit can return nil while resetting a remote document, despite declaring the
/// UUID property nonnull. Read that public Objective-C getter before Swift's
/// unconditional UUID bridge; an absent target must reject delivery, not trap.
enum DocumentIdentity {
    static func read(_ proxy: any UITextDocumentProxy) -> UUID? { readObject(proxy as? NSObject) }
    static func readObject(_ object: NSObject?) -> UUID? {
        let selector = #selector(getter: UITextDocumentProxy.documentIdentifier)
        guard let object, object.responds(to: selector) else { return nil }
        return object.perform(selector)?.takeUnretainedValue() as? UUID
    }
}
