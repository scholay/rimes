import UIKit
#if KEYBOARD_LAYOUT_TESTS
@testable import RIMES
#endif

/// Local text controls embedded in the existing keyboard settings panel.
final class TextClipboardPanel: UIView, UITableViewDataSource, UITableViewDelegate {
    let collect = BufferPasteButton()
    var onSelect: ((UUID) -> Void)?, onDelete: ((UUID) -> Void)?, onClear: (() -> Void)?
    private let caption = UILabel(), clear = UIButton(type: .system), table = UITableView(frame: .zero, style: .plain)
    private var entries: [TextClipboardStore.Entry] = []
    private var enabled = false
    override init(frame: CGRect) {
        super.init(frame: frame)
        collect.accessibilityIdentifier = "keyboard.clipboard.collect"
        collect.setPurpose(label: L("收录当前剪贴板文字", "Collect current clipboard text"), hint: L("只保存于本机，不上屏", "Save on this device without inserting"))
        caption.font = .systemFont(ofSize: 13); caption.textColor = .secondaryLabel
        caption.text = L("收录当前文字", "Collect current text")
        clear.setTitle(L("清空历史", "Clear history"), for: .normal); clear.titleLabel?.font = .systemFont(ofSize: 13)
        clear.accessibilityIdentifier = "keyboard.clipboard.clear"
        clear.addAction(UIAction { [weak self] _ in self?.onClear?() }, for: .touchUpInside)
        table.dataSource = self; table.delegate = self; table.rowHeight = 68
        table.backgroundColor = .clear; table.register(UITableViewCell.self, forCellReuseIdentifier: "entry")
        table.accessibilityIdentifier = "keyboard.clipboard.entries"
        for item in [collect, caption, clear, table] { addSubview(item) }
    }
    required init?(coder: NSCoder) { fatalError() }
    func update(_ entries: [TextClipboardStore.Entry], fullAccess: Bool, enabled: Bool) {
        self.entries = entries; self.enabled = enabled
        collect.fullAccess = fullAccess; collect.isEnabled = enabled
        clear.isEnabled = enabled && !entries.isEmpty; table.reloadData()
    }
    func redact() { entries = []; enabled = false; collect.isEnabled = false; table.reloadData() }
    override func layoutSubviews() {
        super.layoutSubviews()
        collect.frame = CGRect(x: 0, y: 0, width: 44, height: 36)
        clear.frame = CGRect(x: max(44, bounds.width - 86), y: 0, width: min(86, bounds.width), height: 36)
        caption.frame = CGRect(x: 48, y: 0, width: max(0, clear.frame.minX - 52), height: 36)
        table.frame = CGRect(x: 0, y: 40, width: bounds.width, height: max(0, bounds.height - 40))
    }
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { entries.count }
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let entry = entries[indexPath.row], cell = tableView.dequeueReusableCell(withIdentifier: "entry", for: indexPath)
        cell.backgroundColor = .secondarySystemGroupedBackground
        var content = cell.defaultContentConfiguration(); content.text = String(entry.text.prefix(140))
        content.textProperties.numberOfLines = 3; content.textProperties.font = .systemFont(ofSize: 13); cell.contentConfiguration = content
        cell.accessibilityIdentifier = "keyboard.clipboard.entry.\(entry.id)"
        cell.accessibilityHint = L("点按加入 Buffer", "Tap to add to Buffer")
        let remove = UIButton(type: .system); remove.frame.size = CGSize(width: 36, height: 40)
        remove.setImage(UIImage(systemName: "trash"), for: .normal)
        remove.accessibilityLabel = L("删除剪贴板条目", "Delete clipboard entry")
        remove.accessibilityIdentifier = "keyboard.clipboard.delete.\(entry.id)"
        remove.isEnabled = enabled
        let deleteAction = onDelete
        remove.addAction(UIAction { _ in deleteAction?(entry.id) }, for: .touchUpInside)
        cell.accessoryView = remove; return cell
    }
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard enabled, entries.indices.contains(indexPath.row) else { return }
        onSelect?(entries[indexPath.row].id)
    }
}
