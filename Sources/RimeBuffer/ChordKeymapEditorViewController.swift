import AppKit
import UniformTypeIdentifiers

/// A local draft editor. Applying a draft is the only operation that reaches
/// the deployment coordinator; recording and trying keys never touch an IMK
/// client, a Rime session, or the system input-source selection.
final class ChordKeymapEditorViewController: NSViewController,
    NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    typealias Apply = (ChordKeymapProfile, @escaping (Result<Void, Error>) -> Void) -> Void

    private let store: ChordKeymapStore
    private let applyProfile: Apply
    private var profiles: [ChordKeymapProfile] = []
    private var draft: ChordKeymapProfile
    private var savedDraft: ChordKeymapProfile
    private var visibleEntries: [ChordKeymapEntry] = []
    private var editingKeys: String?
    private var rowBaseline = EntryFields()
    private var loading = false
    private var applying = false
    private var hasUnsavedProfile = false

    private let profilePicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let nameField = NSTextField()
    private let boundaryPicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let leftField = NSTextField()
    private let rightField = NSTextField()
    private let searchField = NSSearchField()
    private let keysField = NSTextField()
    private let outputField = NSTextField()
    private let kindPicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let keyboardMode = NSSegmentedControl(labels: ["选择和弦", "设为左区", "设为右区", "移出键区"],
                                                 trackingMode: .selectOne,
                                                 target: nil, action: nil)
    private var keyButtons: [Character: NSButton] = [:]
    private let table = NSTableView()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let profileStatus = NSTextField(wrappingLabelWithString: "")
    private let previewLabel = NSTextField(wrappingLabelWithString: "选择键位，然后点击“试译和弦”。")
    private let recorder = ChordKeymapRecorderView()
    private let addButton = RimePointingHandButton(title: "添加映射", target: nil, action: nil)
    private let removeEntryButton = RimePointingHandButton(title: "删除映射", target: nil, action: nil)
    private let saveButton = RimePointingHandButton(title: "保存草稿", target: nil, action: nil)
    private let applyButton = RimePointingHandButton(title: "应用键位方案", target: nil, action: nil)
    private let deleteProfileButton = RimePointingHandButton(title: "删除方案…", target: nil, action: nil)
    private var operationButtons: [NSButton] = []

    private struct EntryFields: Equatable {
        var keys = ""
        var output = ""
        var syllable = true
    }

    private struct RetainedDraft {
        let draft: ChordKeymapProfile
        let savedDraft: ChordKeymapProfile
        let isNew: Bool
        let entry: EntryFields
        let rowBaseline: EntryFields
        let editingKeys: String?
    }

    // Settings may reconstruct its page tree when appearance changes. Retain
    // only this editor's in-memory state, not an implicit on-disk save/apply.
    private static var retainedDrafts: [ObjectIdentifier: RetainedDraft] = [:]

    init(store: ChordKeymapStore = .shared, apply: Apply? = nil) {
        self.store = store
        self.applyProfile = apply ?? { profile, completion in
            ChordKeymapActivationCoordinator.shared.apply(profile: profile,
                                                        completion: completion)
        }
        draft = store.activeProfile
        savedDraft = store.activeProfile
        super.init(nibName: nil, bundle: nil)
        if let retained = Self.retainedDrafts[ObjectIdentifier(store)] {
            draft = retained.draft
            savedDraft = retained.savedDraft
            hasUnsavedProfile = retained.isNew
        }
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 10
        root.edgeInsets = NSEdgeInsets(top: 0, left: 24, bottom: 24, right: 24)
        view = root

        root.addArrangedSubview(card([
            row([profilePicker, button("复制方案", #selector(duplicateProfile)),
                 button("新建", #selector(newProfile)), button("导入…", #selector(importProfile)),
                 button("导出…", #selector(exportProfile)), spacer()]),
            profileStatus,
            row([label("名称"), nameField, deleteProfileButton]),
            row([label("音节边界"), boundaryPicker, spacer()]),
        ]))
        profilePicker.target = self
        profilePicker.action = #selector(selectProfile)
        profilePicker.setAccessibilityIdentifier("chord-keymap.profile")
        profilePicker.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        profilePicker.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
        nameField.placeholderString = "给方案起个名字"
        configureField(nameField, id: "name")
        configure(deleteProfileButton, #selector(deleteProfile))
        boundaryPicker.addItems(withTitles: ["每个多键批次（兼容飞耀）", "按映射类型（完整音节 / 片段）"])
        boundaryPicker.controlSize = .small
        boundaryPicker.target = self
        boundaryPicker.action = #selector(boundaryChanged)
        boundaryPicker.setAccessibilityIdentifier("chord-keymap.boundary-policy")
        boundaryPicker.toolTip = "复制飞耀时默认保留原来的分隔行为；新建方案可由每条映射的类型决定音节边界。"

        leftField.placeholderString = "左区字母键"
        rightField.placeholderString = "右区字母键"
        configureField(leftField, id: "left-keys")
        configureField(rightField, id: "right-keys")
        keyboardMode.selectedSegment = 0
        keyboardMode.target = self
        keyboardMode.action = #selector(changeKeyboardMode)
        keyboardMode.controlSize = .small
        let keyboard = NSStackView()
        keyboard.orientation = .vertical
        keyboard.alignment = .leading
        keyboard.spacing = 4
        for (index, letters) in ["qwertyuiop", "asdfghjkl", "zxcvbnm,."].enumerated() {
            var cells: [NSView] = []
            let indent = NSView()
            indent.widthAnchor.constraint(equalToConstant: CGFloat(index * 12)).isActive = true
            cells.append(indent)
            for key in letters {
                let keyButton = RimePointingHandButton(title: String(key).uppercased(), target: self,
                                                     action: #selector(clickKey(_:)))
                keyButton.bezelStyle = .rounded
                keyButton.setButtonType(.pushOnPushOff)
                keyButton.identifier = NSUserInterfaceItemIdentifier(String(key))
                keyButton.widthAnchor.constraint(equalToConstant: 43).isActive = true
                keyButton.heightAnchor.constraint(equalToConstant: 28).isActive = true
                keyButtons[key] = keyButton
                cells.append(keyButton)
            }
            keyboard.addArrangedSubview(row(cells, spacing: 4))
        }
        let keyZoneSectionLabel = label("键区与和弦", size: 11, weight: .semibold)
        keyZoneSectionLabel.toolTip =
            "键帽上的 L / R 表示所属键区。选择和弦可点选多个键；重新分区也可直接编辑上方字母。"
        root.addArrangedSubview(card([
            keyZoneSectionLabel,
            row([label("左区"), leftField, label("右区"), rightField]),
            keyboardMode, keyboard,
        ]))
        leftField.widthAnchor.constraint(equalTo: rightField.widthAnchor).isActive = true
        leftField.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true

        searchField.placeholderString = "搜索键位或输出拼音"
        configureField(searchField, id: "search")
        searchField.widthAnchor.constraint(equalToConstant: 330).isActive = true
        for (id, title, width) in [("keys", "和弦键", 160.0), ("output", "输出拼音", 255.0),
                                   ("kind", "类型", 140.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            table.addTableColumn(column)
        }
        table.delegate = self
        table.dataSource = self
        table.rowHeight = 25
        table.style = .plain
        // A fixed native label row keeps the column titles readable while
        // scrolling, without the translucent system header blending old rows.
        table.headerView = nil
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.backgroundColor = RimeUI.surface3
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = false
        table.setAccessibilityIdentifier("chord-keymap.mappings")
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = RimeUI.surface3
        scroll.borderType = .bezelBorder
        scroll.heightAnchor.constraint(equalToConstant: 195).isActive = true
        keysField.placeholderString = "例如 dvkm"
        outputField.placeholderString = "例如 nong"
        configureField(keysField, id: "chord-keys")
        configureField(outputField, id: "output")
        keysField.widthAnchor.constraint(equalToConstant: 130).isActive = true
        outputField.widthAnchor.constraint(equalToConstant: 160).isActive = true
        kindPicker.addItems(withTitles: ["完整音节", "拼音片段"])
        kindPicker.target = self
        kindPicker.action = #selector(entryChanged)
        kindPicker.controlSize = .small
        configure(addButton, #selector(addOrUpdateEntry))
        configure(removeEntryButton, #selector(removeEntry))
        let headerKeys = label("和弦键", weight: .semibold)
        let headerOutput = label("输出拼音", weight: .semibold)
        let headerKind = label("类型", weight: .semibold)
        headerKeys.widthAnchor.constraint(equalToConstant: 160).isActive = true
        headerOutput.widthAnchor.constraint(equalToConstant: 255).isActive = true
        let columnHeader = row([headerKeys, headerOutput, headerKind, spacer()], spacing: 3)
        columnHeader.edgeInsets = NSEdgeInsets(top: 2, left: 5, bottom: 2, right: 5)
        let mappingTableSectionLabel = label("映射表", size: 11, weight: .semibold)
        mappingTableSectionLabel.toolTip =
            "按映射类型时，完整音节保留边界，片段可继续补全。相同键集合只能对应一条映射，按键顺序不影响结果。"
        root.addArrangedSubview(card([
            row([mappingTableSectionLabel, spacer(), searchField]),
            columnHeader, scroll,
            row([label("和弦"), keysField, label("输出"), outputField, kindPicker, spacer()]),
            row([addButton, button("清空编辑", #selector(clearEntry)), removeEntryButton, spacer(),
                 button("试译和弦", #selector(trySelectedKeys))]),
        ]))
        recorder.onChord = { [weak self] keys in
            guard let self, !self.applying else { return }
            self.showPreview(keys: keys)
        }
        let localTrySectionLabel = label("本地试打", size: 11, weight: .semibold)
        localTrySectionLabel.toolTip =
            "试打只在此处显示当前草稿的映射结果；按住一组键后全部松开即结算，Esc 退出。"
        root.addArrangedSubview(card([
            row([localTrySectionLabel, spacer(),
                 button("开始试打", #selector(startRecording)), button("停止", #selector(stopRecording))]),
            recorder, previewLabel,
        ]))
        configure(saveButton, #selector(saveDraftAction))
        configure(applyButton, #selector(applyDraft))
        root.addArrangedSubview(card([row([saveButton, applyButton, spacer()]), statusLabel]))
        for field in [statusLabel, profileStatus, previewLabel] {
            field.font = .systemFont(ofSize: 10)
            field.textColor = RimeUI.textSecondary
            field.alignment = .left
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        statusLabel.setAccessibilityIdentifier("chord-keymap.status")
        previewLabel.setAccessibilityIdentifier("chord-keymap.preview")
        do {
            profiles = try store.allProfiles()
            renderProfile()
            if let retained = Self.retainedDrafts[ObjectIdentifier(store)] {
                editingKeys = retained.editingKeys
                rowBaseline = retained.rowBaseline
                setEntryFields(retained.entry)
                refreshKeyboard()
                setStatus("已恢复此窗口中尚未保存的编辑。")
            } else if let error = store.loadError {
                setStatus("已回退到内置方案：\(error.localizedDescription)", error: true)
            }
        } catch {
            renderProfile()
            setStatus(error.localizedDescription, error: true)
        }
    }

    override func viewWillDisappear() {
        retainUnsavedDraft()
        recorder.deactivate()
        super.viewWillDisappear()
    }

    /// Called by settings navigation and its close delegate before removing
    /// this page. A failed validation/save keeps the user's editor open.
    func confirmCanLeave() -> Bool {
        guard !applying else { setStatus("方案正在应用，请稍候。", error: true); return false }
        captureProfileFields()
        guard isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = "保存键位方案的更改？"
        alert.informativeText = "保存为本地草稿不会应用到输入法。"
        alert.addButton(withTitle: "保存草稿")
        alert.addButton(withTitle: "放弃更改")
        alert.addButton(withTitle: "继续编辑")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return saveDraft()
        case .alertSecondButtonReturn:
            draft = savedDraft
            hasUnsavedProfile = false
            renderProfile()
            Self.retainedDrafts.removeValue(forKey: ObjectIdentifier(store))
            return true
        default: return false
        }
    }

    private var entryFields: EntryFields {
        EntryFields(keys: keysField.stringValue, output: outputField.stringValue,
                    syllable: kindPicker.indexOfSelectedItem == 0)
    }

    private var entryDirty: Bool {
        entryFields != rowBaseline && (!outputField.stringValue.isEmpty || editingKeys != nil)
    }

    private var isDirty: Bool {
        !draft.isBuiltIn && (hasUnsavedProfile || draft != savedDraft || entryDirty)
    }

    private func retainUnsavedDraft() {
        guard isViewLoaded else { return }
        captureProfileFields()
        guard isDirty else {
            Self.retainedDrafts.removeValue(forKey: ObjectIdentifier(store))
            return
        }
        Self.retainedDrafts[ObjectIdentifier(store)] = RetainedDraft(
            draft: draft, savedDraft: savedDraft, isNew: hasUnsavedProfile,
            entry: entryFields, rowBaseline: rowBaseline, editingKeys: editingKeys
        )
    }

    private func captureProfileFields() {
        guard isViewLoaded, !loading, !draft.isBuiltIn else { return }
        draft.name = nameField.stringValue
        draft.boundaryPolicy = boundaryPicker.indexOfSelectedItem == 0 ? .legacyBatches : .explicitSyllables
        draft.leftKeys = leftField.stringValue.lowercased()
        draft.rightKeys = rightField.stringValue.lowercased()
    }

    private func renderProfile() {
        loading = true
        defer { loading = false }
        profilePicker.removeAllItems()
        var listed = profiles
        if !listed.contains(where: { $0.id == draft.id }) { listed.append(draft) }
        for profile in listed {
            profilePicker.addItem(withTitle: profile.name + (profile.id == store.activeProfile.id ? " · 当前" : ""))
            profilePicker.lastItem?.representedObject = profile.id
        }
        if let index = listed.firstIndex(where: { $0.id == draft.id }) { profilePicker.selectItem(at: index) }
        nameField.stringValue = draft.name
        boundaryPicker.selectItem(at: draft.boundaryPolicy == .legacyBatches ? 0 : 1)
        leftField.stringValue = draft.leftKeys
        rightField.stringValue = draft.rightKeys
        clearEntryFields()
        reloadTable()
        refreshControls()
        refreshKeyboard()
    }

    private func refreshControls() {
        let editable = !draft.isBuiltIn && !applying
        [nameField, leftField, rightField, outputField].forEach { $0.isEnabled = editable }
        keysField.isEnabled = !applying
        profilePicker.isEnabled = !applying
        kindPicker.isEnabled = editable
        boundaryPicker.isEnabled = editable
        for button in operationButtons { button.isEnabled = !applying }
        saveButton.isEnabled = editable
        applyButton.isEnabled = !applying
        addButton.isEnabled = editable
        removeEntryButton.isEnabled = editable && editingKeys != nil
        deleteProfileButton.isEnabled = editable && draft.id != store.activeProfile.id && !hasUnsavedProfile
        keyboardMode.isEnabled = !applying
        if draft.isBuiltIn { keyboardMode.selectedSegment = 0 }
        addButton.title = editingKeys == nil ? "添加映射" : "更新映射"
        let identity = draft.isBuiltIn ? "内置模板 · 只读，复制后即可编辑" : "自定义方案 · \(draft.mappings.count) 条映射"
        profileStatus.stringValue = identity + (draft.id == store.activeProfile.id ? " · 当前已启用" : "")
        recorder.alphabet = draft.alphabet
    }

    private func refreshKeyboard() {
        let selected = Set(keysField.stringValue.lowercased())
        for (key, button) in keyButtons {
            let half = draft.leftKeys.contains(key) ? "L" : draft.rightKeys.contains(key) ? "R" : "—"
            button.title = "\(String(key).uppercased()) \(half)"
            button.state = selected.contains(key) ? .on : .off
            button.isEnabled = !applying
            button.setAccessibilityLabel("\(key)，\(half == "L" ? "左区" : half == "R" ? "右区" : "未分区")")
            button.toolTip = "\(key)：\(selected.contains(key) ? "已选" : "未选")"
        }
    }

    private func reloadTable() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        visibleEntries = draft.mappings.filter {
            query.isEmpty || $0.keys.lowercased().contains(query) || $0.output.lowercased().contains(query)
        }
        table.reloadData()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { visibleEntries.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard visibleEntries.indices.contains(row) else { return nil }
        let entry = visibleEntries[row]
        let value: String
        switch tableColumn?.identifier.rawValue {
        case "keys": value = entry.keys.uppercased().map(String.init).joined(separator: " + ")
        case "kind": value = entry.kind == .syllable ? "完整音节" : "拼音片段"
        default: value = entry.output
        }
        let cell = NSTextField(labelWithString: value)
        cell.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        cell.lineBreakMode = .byTruncatingTail
        cell.toolTip = value
        cell.textColor = RimeUI.textPrimary
        return cell
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        !applying && confirmEntryReplacement()
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !loading, visibleEntries.indices.contains(table.selectedRow) else { return }
        let entry = visibleEntries[table.selectedRow]
        editingKeys = entry.keys
        rowBaseline = EntryFields(keys: entry.keys, output: entry.output, syllable: entry.kind == .syllable)
        setEntryFields(rowBaseline)
        refreshControls()
        refreshKeyboard()
    }

    func controlTextDidChange(_ obj: Notification) {
        guard !loading else { return }
        if obj.object as AnyObject? === searchField {
            loading = true
            reloadTable()
            loading = false
            return
        }
        captureProfileFields()
        refreshKeyboard()
        refreshControls()
        setStatus(isDirty ? "有未保存的更改。保存草稿后，再应用键位方案。" : "")
        retainUnsavedDraft()
    }

    @objc private func selectProfile() {
        guard let id = profilePicker.selectedItem?.representedObject as? String, id != draft.id else { return }
        guard confirmCanLeave() else { renderPickerSelection(); return }
        do {
            let selected = try store.profile(id: id)
            draft = selected
            savedDraft = selected
            hasUnsavedProfile = false
            renderProfile()
            setStatus("")
        } catch { renderPickerSelection(); setStatus(error.localizedDescription, error: true) }
    }

    private func renderPickerSelection() {
        if let index = profilePicker.itemArray.firstIndex(where: { ($0.representedObject as? String) == draft.id }) {
            profilePicker.selectItem(at: index)
        }
    }

    @objc private func newProfile() {
        guard confirmCanLeave() else { return }
        openUnsaved(.newProfile(name: "我的并击方案"))
    }

    @objc private func duplicateProfile() {
        guard confirmCanLeave() else { return }
        openUnsaved(draft.duplicated())
    }

    private func openUnsaved(_ profile: ChordKeymapProfile) {
        draft = profile
        savedDraft = profile
        hasUnsavedProfile = true
        renderProfile()
        setStatus("新方案尚未保存。可编辑键位后保存草稿，再应用键位方案。")
        retainUnsavedDraft()
    }

    @objc private func deleteProfile() {
        guard !draft.isBuiltIn, draft.id != store.activeProfile.id, !hasUnsavedProfile,
              confirmCanLeave() else { return }
        let alert = NSAlert()
        alert.messageText = "删除“\(draft.name)”？"
        alert.informativeText = "这会删除此自定义方案。你可以先导出文件作为备份。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "删除方案")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try store.remove(id: draft.id)
            profiles = try store.allProfiles()
            draft = store.activeProfile
            savedDraft = draft
            renderProfile()
            setStatus("自定义方案已删除。")
        } catch { setStatus(error.localizedDescription, error: true) }
    }

    @objc private func changeKeyboardMode() {
        if draft.isBuiltIn && keyboardMode.selectedSegment != 0 {
            keyboardMode.selectedSegment = 0
            setStatus("内置飞耀模板只读。点击“复制方案”后可以调整键区。")
        }
    }

    @objc private func clickKey(_ sender: NSButton) {
        guard let key = sender.identifier?.rawValue.first, !applying else { return }
        captureProfileFields()
        if keyboardMode.selectedSegment == 0 {
            var selected = Set(keysField.stringValue.lowercased())
            if selected.contains(key) { selected.remove(key) } else { selected.insert(key) }
            keysField.stringValue = draft.canonicalKeys(String(selected))
        } else if !draft.isBuiltIn {
            draft.leftKeys.removeAll(where: { $0 == key })
            draft.rightKeys.removeAll(where: { $0 == key })
            if keyboardMode.selectedSegment == 1 { draft.leftKeys.append(key) }
            if keyboardMode.selectedSegment == 2 { draft.rightKeys.append(key) }
            leftField.stringValue = draft.leftKeys
            rightField.stringValue = draft.rightKeys
            setStatus("键区已修改；保存时会检查已有映射是否仍有效。")
        }
        refreshKeyboard()
        refreshControls()
        retainUnsavedDraft()
    }

    @objc private func entryChanged() { retainUnsavedDraft() }

    @objc private func boundaryChanged() {
        captureProfileFields()
        setStatus("音节边界规则已修改，尚未保存或应用。")
        retainUnsavedDraft()
    }

    private func confirmEntryReplacement() -> Bool {
        guard entryDirty, !draft.isBuiltIn else { return true }
        let alert = NSAlert()
        alert.messageText = "当前映射尚未加入方案"
        alert.informativeText = "先保存这条映射，或放弃该条目的修改。"
        alert.addButton(withTitle: "保存映射")
        alert.addButton(withTitle: "放弃修改")
        alert.addButton(withTitle: "继续编辑")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return upsertEntry()
        case .alertSecondButtonReturn: clearEntryFields(); return true
        default: return false
        }
    }

    @objc private func addOrUpdateEntry() { _ = upsertEntry() }

    @discardableResult private func upsertEntry() -> Bool {
        guard !draft.isBuiltIn else { setStatus("请先复制内置方案再编辑。", error: true); return false }
        captureProfileFields()
        var candidate = draft
        let rawKeys = keysField.stringValue.lowercased()
        let keys = candidate.canonicalKeys(rawKeys)
        // Never let Set normalization silently turn a repeated key into a
        // different valid chord, or silently overwrite an existing mapping.
        guard rawKeys.count == Set(rawKeys).count else {
            setStatus("一条和弦中不能重复同一个键。", error: true); return false
        }
        if candidate.mappings.contains(where: { Set($0.keys) == Set(rawKeys) && $0.keys != editingKeys }) {
            setStatus("这些键已存在映射。请在列表中选择该映射后编辑。", error: true); return false
        }
        let entry = ChordKeymapEntry(keys: keys, output: outputField.stringValue.lowercased(),
                                    kind: kindPicker.indexOfSelectedItem == 0 ? .syllable : .fragment)
        if let editingKeys, let index = candidate.mappings.firstIndex(where: { $0.keys == editingKeys }) {
            candidate.mappings[index] = entry
        } else { candidate.mappings.append(entry) }
        do {
            draft = try candidate.validated(requireMappings: false)
            self.editingKeys = entry.keys
            rowBaseline = EntryFields(keys: entry.keys, output: entry.output, syllable: entry.kind == .syllable)
            setEntryFields(rowBaseline)
            loading = true
            reloadTable()
            loading = false
            refreshControls()
            refreshKeyboard()
            setStatus("映射已加入草稿。点击“保存草稿”保留修改。")
            retainUnsavedDraft()
            return true
        } catch { setStatus(error.localizedDescription, error: true); return false }
    }

    @objc private func removeEntry() {
        guard !draft.isBuiltIn, let key = editingKeys else { return }
        draft.mappings.removeAll(where: { $0.keys == key })
        clearEntryFields()
        loading = true
        reloadTable()
        loading = false
        refreshControls()
        refreshKeyboard()
        setStatus("映射已从草稿移除，尚未保存。")
        retainUnsavedDraft()
    }

    @objc private func clearEntry() {
        guard confirmEntryReplacement() else { return }
        clearEntryFields()
        table.deselectAll(nil)
        refreshControls()
        refreshKeyboard()
    }

    private func clearEntryFields() {
        editingKeys = nil
        rowBaseline = EntryFields()
        setEntryFields(rowBaseline)
    }

    private func setEntryFields(_ fields: EntryFields) {
        keysField.stringValue = fields.keys
        outputField.stringValue = fields.output
        kindPicker.selectItem(at: fields.syllable ? 0 : 1)
    }

    @objc private func saveDraftAction() { _ = saveDraft() }

    @discardableResult private func saveDraft() -> Bool {
        guard !draft.isBuiltIn else { return true }
        if entryDirty && !upsertEntry() { return false }
        captureProfileFields()
        do {
            let validated = try draft.validated(requireMappings: false)
            try store.save(validated)
            draft = validated
            savedDraft = validated
            hasUnsavedProfile = false
            profiles = try store.allProfiles()
            renderProfile()
            Self.retainedDrafts.removeValue(forKey: ObjectIdentifier(store))
            setStatus("草稿已保存。点击“应用键位方案”才会生效。")
            return true
        } catch { setStatus(error.localizedDescription, error: true); return false }
    }

    @objc private func applyDraft() {
        guard !applying else { return }
        if !draft.isBuiltIn && !saveDraft() { return }
        do {
            let profile = try draft.validated()
            applying = true
            recorder.deactivate()
            refreshControls()
            refreshKeyboard()
            setStatus("正在应用方案，请稍候…")
            applyProfile(profile) { [weak self] result in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.applying = false
                    self.refreshControls()
                    self.refreshKeyboard()
                    switch result {
                    case .success:
                        self.profiles = (try? self.store.allProfiles()) ?? self.profiles
                        self.renderProfile()
                        self.setStatus("“\(profile.name)”已应用。普通输入若尚未使用并击，请在“设置”页设为当前输入方案。")
                    case let .failure(error): self.setStatus(error.localizedDescription, error: true)
                    }
                }
            }
        } catch { setStatus(error.localizedDescription, error: true) }
    }

    @objc private func importProfile() {
        guard confirmCanLeave() else { return }
        let panel = NSOpenPanel()
        panel.title = "导入并击键位方案"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.json, UTType(filenameExtension: "rimes-keymap") ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true, (values.fileSize ?? Int.max) <= 2 * 1_024 * 1_024 else {
                throw editorError("请选择不超过 2 MB 的键位方案文件。")
            }
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            openUnsaved(try store.importData(data))
            setStatus("已导入为独立的新方案。确认后保存草稿，再应用键位方案。")
        } catch { setStatus(error.localizedDescription, error: true) }
    }

    @objc private func exportProfile() {
        if entryDirty && !upsertEntry() { return }
        captureProfileFields()
        do {
            let data = try store.exportData(draft)
            let panel = NSSavePanel()
            panel.title = "导出并击键位方案"
            panel.allowedContentTypes = [.json]
            panel.nameFieldStringValue = draft.name.replacingOccurrences(of: "/", with: "-") + ".json"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try data.write(to: url, options: .atomic)
            setStatus("方案已导出，可在另一台电脑导入。")
        } catch { setStatus(error.localizedDescription, error: true) }
    }

    @objc private func trySelectedKeys() {
        captureProfileFields()
        showPreview(keys: keysField.stringValue)
    }

    private func showPreview(keys: String) {
        do {
            let profile = try draft.validated(requireMappings: false)
            previewLabel.stringValue = try Self.preview(profile: profile, keys: keys)
            previewLabel.textColor = RimeUI.textPrimary
        } catch {
            previewLabel.stringValue = error.localizedDescription
            previewLabel.textColor = .systemRed
        }
    }

    /// Deterministic pure hook used by UI smoke checks, without deployment.
    static func preview(profile: ChordKeymapProfile, keys: String) throws -> String {
        let lower = keys.lowercased()
        guard !lower.isEmpty, Set(lower).count == lower.count,
              Set(lower).isSubset(of: Set(profile.alphabet)) else {
            throw editorError("请至少选择一个属于当前键区的键，且不要重复。")
        }
        let canonical = profile.canonicalKeys(lower)
        let codes = Set(lower.unicodeScalars.map { Int32($0.value) })
        if let entry = profile.entry(for: codes) {
            return "\(canonical.uppercased()) → \(entry.output)  ·  \(entry.kind == .syllable ? "完整音节" : "拼音片段")"
        }
        if lower.count == 1 {
            if lower == "," || lower == "." {
                return "\(canonical)  ·  普通输入交给标点处理；意识流忽略此单键"
            }
            return "\(canonical.uppercased()) → \(lower)  ·  单键原样输入"
        }
        let fallback = canonical.filter { "abcdefghijklmnopqrstuvwxyz".contains($0) }
        if fallback.isEmpty {
            return "\(canonical.uppercased()) →（无文本输出）  ·  未定义映射中的标点键不进入原码"
        }
        return "\(canonical.uppercased()) → \(fallback)  ·  未定义映射，保留字母原码"
    }

    /// The caller supplies a temporary store. Exercises actual editor actions
    /// and draft persistence, with deployment replaced by an inert closure.
    static func smokeCheck(store: ChordKeymapStore) throws {
        let activeBefore = store.activeProfile
        let controller = ChordKeymapEditorViewController(store: store, apply: { _, _ in })
        _ = controller.view
        guard !controller.nameField.isEnabled, !controller.addButton.isEnabled else {
            throw editorError("内置键位模板必须只读")
        }
        controller.openUnsaved(.newProfile(name: "编辑器 smoke"))
        controller.keysField.stringValue = "dv"
        controller.outputField.stringValue = "n"
        controller.kindPicker.selectItem(at: 1)
        guard controller.upsertEntry(), controller.draft.mappings.count == 1 else {
            throw editorError("编辑器不能添加有效映射")
        }
        controller.clearEntryFields()
        controller.keysField.stringValue = "vd"
        controller.outputField.stringValue = "m"
        guard !controller.upsertEntry(), controller.draft.mappings.first?.output == "n" else {
            throw editorError("编辑器未拒绝顺序无关的重复键位")
        }
        controller.clearEntryFields()
        controller.keysField.stringValue = "km"
        controller.outputField.stringValue = "ong"
        controller.kindPicker.selectItem(at: 1)
        guard controller.upsertEntry(), controller.draft.mappings.count == 2 else {
            throw editorError("编辑器不能保留多条映射")
        }
        let preview = try Self.preview(profile: controller.draft, keys: "vd")
        guard preview.contains("→ n"),
              try Self.preview(profile: controller.draft, keys: ".vd,").contains("→ dv"),
              try Self.preview(profile: controller.draft, keys: ".,").contains("无文本输出"),
              try Self.preview(profile: controller.draft, keys: ",").contains("意识流忽略"),
              controller.saveDraft(),
              store.activeProfile == activeBefore,
              try store.profile(id: controller.draft.id).mappings.count == 2 else {
            throw editorError("草稿保存或隔离试译失败")
        }
        let exported = try store.exportData(controller.draft)
        let imported = try store.importData(exported)
        guard imported.id != controller.draft.id,
              imported.mappings == controller.draft.mappings else {
            throw editorError("导入应保留映射并产生独立方案")
        }
        controller.searchField.stringValue = "ong"
        controller.reloadTable()
        guard controller.visibleEntries.count == 1 else {
            throw editorError("映射搜索未按输出过滤")
        }
    }

    @objc private func startRecording() {
        captureProfileFields()
        recorder.alphabet = draft.alphabet
        recorder.activate()
    }

    @objc private func stopRecording() { recorder.deactivate() }

    private func setStatus(_ text: String, error: Bool = false) {
        statusLabel.stringValue = text
        statusLabel.textColor = error ? .systemRed : RimeUI.textSecondary
    }

    private func configureField(_ field: NSTextField, id: String) {
        field.delegate = self
        field.font = .systemFont(ofSize: 11)
        field.controlSize = .small
        field.setAccessibilityIdentifier("chord-keymap.\(id)")
        let labels = ["name": "键位方案名称", "left-keys": "左侧键区", "right-keys": "右侧键区",
                      "search": "搜索键位或输出拼音", "chord-keys": "映射的和弦键", "output": "映射输出拼音"]
        field.setAccessibilityLabel(labels[id] ?? id)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    private func configure(_ button: NSButton, _ action: Selector) {
        button.target = self
        button.action = action
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = .systemFont(ofSize: 11)
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let button = RimePointingHandButton(title: title, target: self, action: action)
        configure(button, action)
        operationButtons.append(button)
        return button
    }

    private func label(_ text: String, size: CGFloat = 11,
                       weight: NSFont.Weight = .regular) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = RimeUI.textSecondary
        label.alignment = .left
        return label
    }

    private func row(_ views: [NSView], spacing: CGFloat = 7) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.distribution = .fill
        stack.alignment = .centerY
        stack.spacing = spacing
        return stack
    }

    private func spacer() -> NSView {
        let spacer = NSView()
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        return spacer
    }

    private func card(_ views: [NSView]) -> NSStackView {
        let stack = ChordKeymapCardView(views: views)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.widthAnchor.constraint(equalToConstant: 650).isActive = true
        return stack
    }
}

private func editorError(_ message: String) -> NSError {
    NSError(domain: "RIMES.ChordKeymapEditor", code: 1,
            userInfo: [NSLocalizedDescriptionKey: message])
}

private final class ChordKeymapCardView: NSStackView {
    init(views: [NSView]) {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 8
        edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        views.forEach(addArrangedSubview)
        for child in views {
            child.translatesAutoresizingMaskIntoConstraints = false
            if let label = child as? NSTextField {
                label.preferredMaxLayoutWidth = 626
                label.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -24).isActive = true
            } else if child is NSSegmentedControl {
                child.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -24).isActive = true
            } else {
                child.widthAnchor.constraint(equalTo: widthAnchor, constant: -24).isActive = true
            }
        }
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 0.5
        updateColors()
    }

    required init?(coder: NSCoder) { nil }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }
    private func updateColors() {
        layer?.backgroundColor = RimeUI.surface2.cgColor
        layer?.borderColor = RimeUI.border.cgColor
    }
}

/// Only receives native events while explicitly focused inside settings. It
/// neither installs a global monitor nor forwards any key to Rime/IMK.
private final class ChordKeymapRecorderView: NSView {
    var alphabet = ""
    var onChord: ((String) -> Void)?
    private var held: [UInt16: Character] = [:]
    private var keys = Set<Character>()
    private var recording = false
    private var windowObserver: NSObjectProtocol?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        heightAnchor.constraint(equalToConstant: 48).isActive = true
        setAccessibilityLabel("本地并击试打区域")
    }
    required init?(coder: NSCoder) { nil }
    override var acceptsFirstResponder: Bool { true }

    deinit {
        if let windowObserver { NotificationCenter.default.removeObserver(windowObserver) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let windowObserver { NotificationCenter.default.removeObserver(windowObserver) }
        windowObserver = nil
        held.removeAll()
        keys.removeAll()
        recording = false
        if let window {
            windowObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification, object: window, queue: .main
            ) { [weak self] _ in self?.deactivate() }
        }
        needsDisplay = true
    }

    func activate() {
        recording = true
        window?.makeFirstResponder(self)
        needsDisplay = true
    }
    func deactivate() {
        recording = false
        held.removeAll()
        keys.removeAll()
        if window?.firstResponder === self { window?.makeFirstResponder(nil) }
        needsDisplay = true
    }
    override func resignFirstResponder() -> Bool {
        recording = false
        held.removeAll()
        keys.removeAll()
        needsDisplay = true
        return super.resignFirstResponder()
    }
    override func keyDown(with event: NSEvent) {
        guard recording else { super.keyDown(with: event); return }
        if event.keyCode == 53 { deactivate(); return }
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else {
            held.removeAll()
            keys.removeAll()
            super.keyDown(with: event)
            return
        }
        guard !event.isARepeat,
              let character = event.charactersIgnoringModifiers?.lowercased().first,
              alphabet.contains(character) else { return }
        held[event.keyCode] = character
        keys.insert(character)
        needsDisplay = true
    }
    override func keyUp(with event: NSEvent) {
        guard recording, held.removeValue(forKey: event.keyCode) != nil else { return }
        if held.isEmpty, !keys.isEmpty {
            let captured = String(alphabet.filter(keys.contains))
            keys.removeAll()
            onChord?(captured)
        }
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 7, yRadius: 7)
        RimeUI.surface3.setFill()
        path.fill()
        (recording ? RimeUI.accentGreen : RimeUI.border).setStroke()
        path.stroke()
        let text = !keys.isEmpty ? String(alphabet.filter(keys.contains)).uppercased()
            : recording ? "请并击，全部松开后查看结果 · Esc 退出" : "点击“开始试打”后在这里接收按键"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: RimeUI.textSecondary,
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(at: NSPoint(x: max(8, (bounds.width - size.width) / 2),
                                          y: (bounds.height - size.height) / 2),
                               withAttributes: attributes)
    }
}
