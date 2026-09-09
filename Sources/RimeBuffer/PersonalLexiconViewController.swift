import AppKit

/// Page-owned editor. Loading is explicit; searching/sorting only uses the
/// in-memory snapshot. It never polls userdb or calls an AI/network provider.
final class PersonalLexiconViewController: NSViewController, NSTableViewDataSource,
                                            NSTableViewDelegate, NSSearchFieldDelegate {
    private let service: UserLexiconService
    private let permitsInteraction: () -> Bool
    private let loadsOnOpen: Bool
    private(set) var kind: UserLexiconKind
    private var entries: [PersonalLexiconEntry] = []
    private var visibleEntries: [PersonalLexiconEntry] = []
    private var isLoaded = false

    var onImport: ((UserLexiconKind) -> Void)?
    var onExport: ((UserLexiconKind) -> Void)?

    private let dictionaryPicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let search = NSSearchField()
    private let sortPicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let table = NSTableView()
    private let emptyLabel = NSTextField(wrappingLabelWithString: "")
    private let feedback = NSTextField(wrappingLabelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")
    private let scopeLabel = NSTextField(wrappingLabelWithString: "")
    private let addButton = RimePointingHandButton(title: "新增", target: nil, action: nil)
    private let editButton = RimePointingHandButton(title: "编辑", target: nil, action: nil)
    private let deleteButton = RimePointingHandButton(title: "删除…", target: nil, action: nil)
    private let undoButton = RimePointingHandButton(title: "撤销上次修改", target: nil, action: nil)
    private let refreshButton = RimePointingHandButton(title: "刷新", target: nil, action: nil)
    private let importButton = RimePointingHandButton(title: "导入…", target: nil, action: nil)
    private let exportButton = RimePointingHandButton(title: "导出…", target: nil, action: nil)

    init(kind: UserLexiconKind = .chinese, service: UserLexiconService = .shared,
         loadsOnOpen: Bool = true,
         permitsInteraction: @escaping () -> Bool = { RimeInputSourceAuthority.currentSourceIsOwn() }) {
        self.kind = kind
        self.service = service
        self.loadsOnOpen = loadsOnOpen
        self.permitsInteraction = permitsInteraction
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = RimeUI.color(RimeUI.appearance == .day ? 0xECECEC : 0x323232).cgColor
        root.identifier = NSUserInterfaceItemIdentifier("settings.personal-lexicon-pane")
        let heading = NSTextField(labelWithString: "个人词库")
        heading.font = .systemFont(ofSize: 22, weight: .semibold)
        heading.textColor = RimeUI.textPrimary
        let subtitle = label("这里显示你选词、造词以及手动添加或导入的个人记录，不包含雾凇等内置词库的全部词条。")

        dictionaryPicker.addItems(withTitles: UserLexiconKind.allCases.map(\.personalRecordsTitle))
        dictionaryPicker.selectItem(at: UserLexiconKind.allCases.firstIndex(of: kind) ?? 0)
        dictionaryPicker.target = self
        dictionaryPicker.action = #selector(dictionaryChanged)
        dictionaryPicker.setAccessibilityLabel("个人学习记录分类")
        dictionaryPicker.widthAnchor.constraint(equalToConstant: 165).isActive = true

        search.placeholderString = "搜索词条、拼音或编码"
        search.setAccessibilityLabel("搜索个人词条")
        search.delegate = self
        search.sendsSearchStringImmediately = true
        search.setContentHuggingPriority(.defaultLow, for: .horizontal)
        search.widthAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
        sortPicker.addItems(withTitles: PersonalLexiconSort.allCases.map(\.title))
        sortPicker.target = self
        sortPicker.action = #selector(sortChanged)
        sortPicker.setAccessibilityLabel("词条排序")

        let selectors = row([dictionaryPicker, search, sortPicker, refreshButton])
        scopeLabel.font = .systemFont(ofSize: 11)
        scopeLabel.textColor = RimeUI.textSecondary
        scopeLabel.stringValue = kind.personalRecordsDescription
        let actions = row([addButton, editButton, deleteButton, undoButton, spacer(), importButton, exportButton])
        configure(addButton, #selector(addEntry))
        configure(editButton, #selector(editEntry))
        configure(deleteButton, #selector(deleteEntries))
        configure(undoButton, #selector(undoChange))
        configure(refreshButton, #selector(refresh))
        configure(importButton, #selector(importEntries))
        configure(exportButton, #selector(exportEntries))

        table.dataSource = self
        table.delegate = self
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.usesAlternatingRowBackgroundColors = true
        table.style = .inset
        table.rowHeight = 32
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.target = self
        table.doubleAction = #selector(editEntry)
        table.setAccessibilityLabel("个人词条列表")
        for (id, title, width) in [("text", "词条", 220.0), ("code", "拼音 / 编码", 230.0),
                                    ("weight", "学习权重", 90.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            column.minWidth = id == "weight" ? 80 : 120
            table.addTableColumn(column)
        }
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        scroll.documentView = table
        let tableHost = NSView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.alignment = .center
        emptyLabel.textColor = RimeUI.textSecondary
        tableHost.addSubview(scroll)
        tableHost.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: tableHost.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: tableHost.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: tableHost.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: tableHost.bottomAnchor),
            tableHost.heightAnchor.constraint(greaterThanOrEqualToConstant: 180),
            emptyLabel.centerXAnchor.constraint(equalTo: tableHost.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: tableHost.centerYAnchor),
            emptyLabel.widthAnchor.constraint(lessThanOrEqualTo: tableHost.widthAnchor, constant: -40),
        ])
        countLabel.font = .systemFont(ofSize: 11)
        countLabel.textColor = RimeUI.textSecondary
        let backupButton = RimePointingHandButton(title: "查看备份", target: self,
                                                  action: #selector(openBackup))
        backupButton.bezelStyle = .rounded
        backupButton.controlSize = .small
        let footer = row([countLabel, spacer(), backupButton])
        let explanation = label("修改前自动备份，可撤销上次修改。学习权重不等同于候选排名；删除个人记录后，内置词库中的同名词仍可能出现。")
        feedback.font = .systemFont(ofSize: 11)
        feedback.maximumNumberOfLines = 3

        let content = NSStackView(views: [heading, subtitle, selectors, scopeLabel, actions, tableHost,
                                        footer, explanation, feedback])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 12
        content.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            content.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20),
        ])
        for child in content.arrangedSubviews {
            child.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        }
        tableHost.setContentHuggingPriority(.defaultLow, for: .vertical)
        view = root
        showEntries([])
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        if loadsOnOpen {
            DispatchQueue.main.async { [weak self] in self?.reload() }
        }
    }

    func reload() {
        do {
            let result = try service.personalEntries(kind)
            isLoaded = true
            showEntries(result)
            message("已读取本机的\(kind.personalRecordsTitle)。")
        } catch {
            isLoaded = false
            showEntries([])
            message(error.localizedDescription, error: true)
        }
    }

    private func showEntries(_ result: [PersonalLexiconEntry]) {
        entries = result
        filterEntries()
    }

    private func filterEntries() {
        let selectedIDs = Set(selectedEntries.map(\.id))
        let sort = PersonalLexiconSort(rawValue: sortPicker.indexOfSelectedItem) ?? .weight
        visibleEntries = sort.apply(to: entries, query: search.stringValue)
        table.reloadData()
        table.selectRowIndexes(IndexSet(visibleEntries.indices.filter {
            selectedIDs.contains(visibleEntries[$0].id)
        }), byExtendingSelection: false)
        countLabel.stringValue = "\(visibleEntries.count) / \(entries.count) 条"
        emptyLabel.stringValue = !isLoaded ? "点击刷新以读取个人词库"
            : (entries.isEmpty ? "还没有学习记录\n可以新增词条，或在输入时选字让输入法学习。" : "没有匹配的词条")
        emptyLabel.isHidden = !visibleEntries.isEmpty
        updateActions()
    }

    private var selectedEntries: [PersonalLexiconEntry] {
        table.selectedRowIndexes.compactMap { visibleEntries.indices.contains($0) ? visibleEntries[$0] : nil }
    }

    private func updateActions() {
        addButton.isEnabled = isLoaded
        editButton.isEnabled = isLoaded && selectedEntries.count == 1
        deleteButton.isEnabled = isLoaded && !selectedEntries.isEmpty
        undoButton.isEnabled = service.lastPersonalChange?.kind == kind
        exportButton.isEnabled = isLoaded && !entries.isEmpty
    }

    func numberOfRows(in tableView: NSTableView) -> Int { visibleEntries.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard visibleEntries.indices.contains(row), let column = tableColumn else { return nil }
        let entry = visibleEntries[row]
        let value: String
        switch column.identifier.rawValue {
        case "code": value = entry.code
        case "weight": value = String(entry.weight)
        default: value = entry.text
        }
        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: column.identifier, owner: self) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = column.identifier
            let field = NSTextField(labelWithString: "")
            field.font = .systemFont(ofSize: 13)
            field.lineBreakMode = .byTruncatingTail
            field.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(field)
            cell.textField = field
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
                field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }
        cell.textField?.stringValue = value
        cell.toolTip = value
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateActions() }
    func controlTextDidChange(_ obj: Notification) { filterEntries() }

    @objc private func dictionaryChanged() {
        guard UserLexiconKind.allCases.indices.contains(dictionaryPicker.indexOfSelectedItem) else { return }
        kind = UserLexiconKind.allCases[dictionaryPicker.indexOfSelectedItem]
        scopeLabel.stringValue = kind.personalRecordsDescription
        search.stringValue = ""
        table.deselectAll(nil)
        reload()
    }

    @objc private func sortChanged() { filterEntries() }
    @objc private func refresh() { reload() }
    @objc private func addEntry() { presentEditor(original: nil) }
    @objc private func editEntry() {
        guard selectedEntries.count == 1 else { return }
        presentEditor(original: selectedEntries[0])
    }

    private func presentEditor(original: PersonalLexiconEntry?) {
        guard permitsInteraction(), isLoaded else { return }
        let selectedKind = kind
        let textField = NSTextField(string: original?.text ?? "")
        textField.placeholderString = "例如：雾凇词库"
        textField.setAccessibilityLabel("词条文字")
        let codeField = NSTextField(string: original?.code ?? "")
        codeField.placeholderString = selectedKind == .chinese ? "wu song ci ku" : "输入编码"
        codeField.setAccessibilityLabel("词条拼音或编码")
        let alert = NSAlert()
        alert.messageText = original == nil ? "新增个人词条" : "编辑个人词条"
        alert.informativeText = selectedKind == .chinese
            ? "填写完整拼音，用空格分隔音节；ü 用 v 表示。多音字请按实际读音填写。"
            : "填写词条及对应的\(selectedKind == .english ? "英文" : "五笔")编码。"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        let form = NSStackView(views: [label("词条"), textField, label("拼音 / 编码"), codeField])
        form.orientation = .vertical
        form.alignment = .leading
        form.spacing = 8
        form.frame = NSRect(x: 0, y: 0, width: 380, height: 112)
        for child in form.arrangedSubviews { child.widthAnchor.constraint(equalToConstant: 380).isActive = true }
        alert.accessoryView = form
        alert.window.initialFirstResponder = textField
        alert.window.appearance = RimeUI.appKitAppearance
        while permitsInteraction() {
            guard StandaloneWindowFocusCoordinator.shared.runModalAlertIfRIMESActive(alert) == .alertFirstButtonReturn,
                  permitsInteraction(), kind == selectedKind else { return }
            do {
                let draft = try PersonalLexiconEntry.draft(text: textField.stringValue, code: codeField.stringValue)
                showEntries(try service.savePersonalEntry(draft, replacing: original, kind: selectedKind))
                message("词条已保存，可重新输入拼音或编码检查候选。")
                return
            } catch UserLexiconServiceError.invalidEntry {
                alert.informativeText = UserLexiconServiceError.invalidEntry.localizedDescription
            } catch {
                message(error.localizedDescription, error: true)
                updateActions()
                return
            }
        }
    }

    @objc private func deleteEntries() {
        guard permitsInteraction(), !selectedEntries.isEmpty else { return }
        let selected = selectedEntries
        let selectedKind = kind
        let alert = NSAlert()
        alert.messageText = "删除选中的 \(selected.count) 条个人记录？"
        alert.informativeText = "会移除这些词条的个人学习记录，基础词库不受影响。删除后可以撤销。"
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        alert.window.appearance = RimeUI.appKitAppearance
        guard StandaloneWindowFocusCoordinator.shared.runModalAlertIfRIMESActive(alert) == .alertFirstButtonReturn,
              permitsInteraction(), kind == selectedKind else { return }
        do {
            showEntries(try service.deletePersonalEntries(selected, kind: selectedKind))
            message("已删除 \(selected.count) 条个人记录。")
        } catch { message(error.localizedDescription, error: true) }
        updateActions()
    }

    @objc private func undoChange() {
        guard permitsInteraction(), service.lastPersonalChange?.kind == kind else { return }
        do {
            showEntries(try service.undoPersonalChange())
            message("已恢复词条；学习权重由输入法合并。")
        } catch { message(error.localizedDescription, error: true) }
        updateActions()
    }

    @objc private func importEntries() {
        guard permitsInteraction() else { return }
        onImport?(kind)
        reload()
    }

    @objc private func exportEntries() {
        guard permitsInteraction() else { return }
        onExport?(kind)
    }

    @objc private func openBackup() {
        guard permitsInteraction() else { return }
        let directory = service.personalBackupDirectory
        if FileManager.default.fileExists(atPath: directory.path) {
            NSWorkspace.shared.open(directory)
        } else { message("首次修改词条后，会在本机生成备份。") }
    }

    private func message(_ text: String, error: Bool = false) {
        feedback.stringValue = text
        feedback.textColor = error ? .systemRed : RimeUI.textSecondary
    }

    private func configure(_ button: NSButton, _ action: Selector) {
        button.target = self
        button.action = action
        button.bezelStyle = .rounded
        button.controlSize = .small
    }

    private func label(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = RimeUI.textSecondary
        return label
    }

    private func row(_ views: [NSView]) -> NSStackView {
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        return row
    }

    private func spacer() -> NSView {
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return spacer
    }

    // In-memory fixtures for visual smoke tests, never real personal data.
    func loadPreviewEntries(_ entries: [PersonalLexiconEntry]) {
        _ = view
        isLoaded = true
        showEntries(entries)
        message("预览数据 · 仅保存在内存中")
    }

    func searchForSmoke(_ query: String) -> Int {
        search.stringValue = query
        filterEntries()
        return visibleEntries.count
    }
}
