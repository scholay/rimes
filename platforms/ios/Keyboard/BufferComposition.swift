import UIKit

/// Presentation only: unconfirmed text never enters BufferSession or plugin input.
struct BufferComposition {
    let text: NSAttributedString
    let markedRange: NSRange
    let caretRange: NSRange
    init(source: String, cursor: Int, preedit: String, font: UIFont) {
        let offset = min(max(0, cursor), source.count)
        let position = source.index(source.startIndex, offsetBy: offset)
        let prefix = String(source[..<position]), suffix = String(source[position...])
        markedRange = NSRange(location: prefix.utf16.count, length: preedit.utf16.count)
        caretRange = NSRange(location: prefix.utf16.count + preedit.utf16.count, length: 1)
        let value = NSMutableAttributedString(string: prefix + preedit + "▏" + suffix,
                                             attributes: [.font: font, .foregroundColor: UIColor.label])
        if markedRange.length > 0 {
            value.addAttributes([.foregroundColor: UIColor.systemTeal, .backgroundColor: UIColor.systemTeal.withAlphaComponent(0.1),
                                 .underlineStyle: NSUnderlineStyle.single.rawValue], range: markedRange)
        }
        value.addAttribute(.foregroundColor, value: UIColor.systemTeal, range: caretRange)
        text = value
    }
}
