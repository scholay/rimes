import AppKit
import Foundation

enum FlyChordSettingsThemeRules {
    static func successTextHex(for appearance: RimeAppearanceMode) -> UInt32 {
        appearance.palette.accentText
    }
}

final class FlyChordLearningSettingsViewController: NSViewController {
    private let subpageID: String
    private let schemaResult: Result<FlyChordSchema, Error>
    private let progressStoreResult: Result<FlyChordProgressStore, Error>

    init(subpageID: String) {
        self.subpageID = subpageID
        do {
            schemaResult = .success(try FlyChordSchemaParser.loadDefault())
        } catch {
            schemaResult = .failure(error)
        }
        do {
            progressStoreResult = .success(try FlyChordProgressStore())
        } catch {
            progressStoreResult = .failure(error)
        }
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        if subpageID == "settings" {
            view = FlyChordConfigurationPageView()
            return
        }
        guard case let .success(schema) = schemaResult,
              case let .success(store) = progressStoreResult else {
            view = errorView()
            return
        }
        let curriculum = FlyChordCurriculum(schema: schema)
        switch subpageID {
        case "practice":
            view = FlyChordPracticePageView(curriculum: curriculum, progressStore: store)
        case "progress":
            view = FlyChordProgressPageView(curriculum: curriculum, progressStore: store)
        default:
            view = FlyChordLessonsPageView(curriculum: curriculum, progressStore: store)
        }
    }

    private func errorView() -> NSView {
        let message: String
        switch (schemaResult, progressStoreResult) {
        case let (.failure(error), _): message = error.localizedDescription
        case let (_, .failure(error)): message = error.localizedDescription
        default: message = "并击学习数据暂不可用"
        }
        return FlyChordPageStyle.column([
            FlyChordPageStyle.title("并击"),
            FlyChordPageStyle.caption(message, color: .systemRed),
            FlyChordPageStyle.caption("为保护已有进度，损坏的数据文件不会被自动覆盖。"),
        ])
    }
}

private enum FlyChordPageStyle {
    static func column(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 24, bottom: 22, right: 24)
        return stack
    }

    static func title(_ value: String) -> NSTextField {
        let label = NSTextField(labelWithString: value)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = RimeUI.textSecondary
        return label
    }

    static func section(_ value: String) -> NSTextField {
        let label = NSTextField(labelWithString: value)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = RimeUI.textPrimary
        return label
    }

    static func caption(_ value: String,
                        color: NSColor = RimeUI.textSecondary) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: value)
        label.font = .systemFont(ofSize: 10)
        label.textColor = color
        return label
    }

    static func card(_ views: [NSView]) -> NSStackView {
        let stack = FlyChordCardStackView(arrangedViews: views)
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.widthAnchor.constraint(equalToConstant: 650).isActive = true
        return stack
    }
}

/// Layer-backed card colors are refreshed when the settings window switches
/// between 墨竹 and 翡翠. This avoids freezing an AppKit dynamic color's
/// one-time `cgColor` resolution into a layer.
private final class FlyChordCardStackView: NSStackView {
    init(arrangedViews: [NSView]) {
        super.init(frame: .zero)
        arrangedViews.forEach(addArrangedSubview)
        wantsLayer = true
        layer?.borderWidth = 0.5
        layer?.cornerRadius = 8
        updateThemeColors()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer?.borderWidth = 0.5
        layer?.cornerRadius = 8
        updateThemeColors()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateThemeColors()
    }

    private func updateThemeColors() {
        layer?.backgroundColor = RimeUI.surface2.cgColor
        layer?.borderColor = RimeUI.border.cgColor
    }
}

private final class FlyChordModeCardView: NSView {
    private let choice: RimeFixedAccentChoiceButton

    init(choice: RimeFixedAccentChoiceButton,
         title: String,
         detail: String,
         symbolName: String) {
        self.choice = choice
        super.init(frame: .zero)
        choice.showsTitle = false
        choice.removeFromSuperview()

        let icon = NSImageView()
        icon.image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: title
        )?.withSymbolConfiguration(.init(pointSize: 18, weight: .medium))
        icon.imageScaling = .scaleProportionallyDown
        icon.contentTintColor = RimeUI.textSecondary
        icon.setAccessibilityElement(false)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 24).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 24).isActive = true

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        titleLabel.textColor = RimeUI.textPrimary
        let detailLabel = NSTextField(labelWithString: detail)
        detailLabel.font = .systemFont(ofSize: 9)
        detailLabel.textColor = RimeUI.textMuted
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.toolTip = detail
        let copy = NSStackView(views: [titleLabel, detailLabel])
        copy.orientation = .vertical
        copy.alignment = .leading
        copy.spacing = 3
        copy.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [icon, copy, flexibleSpacer(), choice])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 9
        row.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 68).isActive = true
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        choice.onVisualStateChange = { [weak self] in self?.needsDisplay = true }
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }

    override func mouseDown(with event: NSEvent) {
        guard choice.isEnabled else { return }
        choice.performClick(self)
        needsDisplay = true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, alphaValue > 0, frame.contains(point) else { return nil }
        let localPoint = convert(point, from: superview)
        let choiceRect = convert(choice.bounds, from: choice)
        return choiceRect.contains(localPoint) ? super.hitTest(point) : self
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let path = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
            xRadius: 8,
            yRadius: 8
        )
        (choice.state == .on
            ? RimeUI.surface2.blended(withFraction: 0.10, of: RimeUI.accentGreen)
                ?? RimeUI.surface2
            : RimeUI.surface2).setFill()
        path.fill()
        (choice.state == .on
            ? RimeUI.accentTextColor.withAlphaComponent(0.60)
            : RimeUI.border).setStroke()
        path.lineWidth = choice.state == .on ? 1.2 : 1
        path.stroke()
    }
}

private final class FlyChordConfigurationPageView: NSView, NSTextFieldDelegate {
    private var modeButtons: [ChordExtensionMode: RimeFixedAccentChoiceButton] = [:]
    private let availabilityLabel = NSTextField(labelWithString: "")
    private let availabilityDetail = NSTextField(wrappingLabelWithString: "")
    private let makeCurrentButton = NSButton(title: "设为当前输入方案", target: nil, action: nil)
    private let durationField = NSTextField(string: "")
    private let durationStepper = NSStepper()
    private var extensionObserver: NSObjectProtocol?
    private var inputConfigurationObserver: NSObjectProtocol?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
        observeChanges()
        refresh()
    }

    convenience init() {
        self.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        if let extensionObserver {
            NotificationCenter.default.removeObserver(extensionObserver)
        }
        if let inputConfigurationObserver {
            NotificationCenter.default.removeObserver(inputConfigurationObserver)
        }
    }

    private func build() {
        let cards = ChordExtensionMode.allCases.enumerated().map { index, mode -> NSView in
            let button = RimeFixedAccentChoiceButton.radio(
                title: mode.title,
                target: self,
                action: #selector(modeSelected(_:))
            )
            button.tag = index
            button.translatesAutoresizingMaskIntoConstraints = false
            modeButtons[mode] = button
            let detail: String
            let symbol: String
            switch mode {
            case .chord:
                detail = "只结算同一时间窗内的按键"
                symbol = "rectangle.3.group"
            case .mutual:
                detail = "允许左右手相邻击跨批配对"
                symbol = "arrow.left.arrow.right"
            }
            return FlyChordModeCardView(
                choice: button,
                title: mode.implementationName,
                detail: detail,
                symbolName: symbol
            )
        }
        let modeGrid = NSStackView(views: cards)
        modeGrid.orientation = .horizontal
        modeGrid.alignment = .centerY
        modeGrid.distribution = .fillEqually
        modeGrid.spacing = 8
        modeGrid.translatesAutoresizingMaskIntoConstraints = false
        modeGrid.widthAnchor.constraint(equalToConstant: 650).isActive = true

        availabilityLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        availabilityLabel.textColor = RimeUI.textPrimary
        availabilityLabel.setContentHuggingPriority(.required, for: .horizontal)
        availabilityDetail.font = .systemFont(ofSize: 10)
        availabilityDetail.textColor = RimeUI.textSecondary
        makeCurrentButton.target = self
        makeCurrentButton.action = #selector(makeCurrent)
        makeCurrentButton.controlSize = .small
        makeCurrentButton.setContentHuggingPriority(.required, for: .horizontal)
        let availabilityCopy = NSStackView(
            views: [availabilityLabel, availabilityDetail]
        )
        availabilityCopy.orientation = .vertical
        availabilityCopy.alignment = .leading
        availabilityCopy.spacing = 4
        availabilityCopy.setContentCompressionResistancePriority(
            .defaultLow,
            for: .horizontal
        )
        let availabilityRow = NSStackView(
            views: [availabilityCopy, flexibleSpacer(), makeCurrentButton]
        )
        availabilityRow.orientation = .horizontal
        availabilityRow.alignment = .centerY
        availabilityRow.spacing = 8
        let availabilityCard = FlyChordPageStyle.card([availabilityRow])

        let formatter = NumberFormatter()
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        formatter.allowsFloats = true
        formatter.minimum = NSNumber(value: ChordSettings.range.lowerBound)
        formatter.maximum = NSNumber(value: ChordSettings.range.upperBound)
        durationField.formatter = formatter
        durationField.alignment = .right
        durationField.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        durationField.target = self
        durationField.action = #selector(durationFieldChanged)
        durationField.delegate = self
        durationField.translatesAutoresizingMaskIntoConstraints = false
        durationField.widthAnchor.constraint(equalToConstant: 64).isActive = true
        durationStepper.minValue = ChordSettings.range.lowerBound
        durationStepper.maxValue = ChordSettings.range.upperBound
        durationStepper.increment = 0.01
        durationStepper.valueWraps = false
        durationStepper.target = self
        durationStepper.action = #selector(durationStepperChanged)
        let unit = NSTextField(labelWithString: "秒")
        unit.font = .systemFont(ofSize: 10)
        unit.textColor = RimeUI.textMuted
        let reset = NSButton(title: "恢复默认", target: self, action: #selector(resetDuration))
        reset.controlSize = .small
        let durationRow = NSStackView(
            views: [durationField, durationStepper, unit, reset, flexibleSpacer()]
        )
        durationRow.orientation = .horizontal
        durationRow.alignment = .centerY
        durationRow.spacing = 8

        let column = FlyChordPageStyle.column([
            FlyChordPageStyle.title("并击设置"),
            FlyChordPageStyle.caption(
                "扩展启用后提供飞耀输入方案；启用本身不会打断当前输入方案。"
            ),
            availabilityCard,
            FlyChordPageStyle.section("飞耀模式"),
            modeGrid,
            FlyChordPageStyle.section("组键间隔"),
            durationRow,
            FlyChordPageStyle.caption(
                "并击只结算当前时间窗；互击还允许相邻的左手声母与右手韵母跨击配对。修改后立即作用于普通输入与意识流输入。"
            ),
        ])
        addPinned(column)
    }

    private func observeChanges() {
        extensionObserver = NotificationCenter.default.addObserver(
            forName: .chordExtensionDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refresh()
        }
        inputConfigurationObserver = NotificationCenter.default.addObserver(
            forName: .inputConfigurationDidChange,
            object: InputConfigurationStore.shared,
            queue: .main
        ) { [weak self] _ in
            self?.refresh()
        }
    }

    private func refresh() {
        let store = ChordExtensionStore.shared
        let current = InputConfigurationStore.shared.selectedSchemaID
            == ChordExtensionStore.schemaID
        for mode in ChordExtensionMode.allCases {
            modeButtons[mode]?.state = store.mode == mode ? .on : .off
            modeButtons[mode]?.isEnabled = store.isEnabled
        }
        durationField.stringValue = String(format: "%.2f", store.duration)
        durationField.isEnabled = store.isEnabled
        durationStepper.doubleValue = store.duration
        durationStepper.isEnabled = store.isEnabled

        if current {
            availabilityLabel.stringValue = "正在使用"
            availabilityLabel.textColor = RimeUI.accentTextColor
            availabilityDetail.stringValue = "飞耀方案正作为当前输入方案；普通输入与意识流输入共享此模式。"
            makeCurrentButton.title = "当前输入方案"
            makeCurrentButton.isEnabled = false
        } else if store.isEnabled {
            availabilityLabel.stringValue = "可用"
            availabilityLabel.textColor = RimeUI.accentTextColor
            availabilityDetail.stringValue = "扩展已启用，但不会自动替换你当前使用的输入方案。"
            makeCurrentButton.title = "设为当前输入方案"
            makeCurrentButton.isEnabled = true
        } else {
            availabilityLabel.stringValue = "已停用"
            availabilityLabel.textColor = RimeUI.textMuted
            availabilityDetail.stringValue = "请先在“插件 · 内置扩展”中启用并击。"
            makeCurrentButton.title = "设为当前输入方案"
            makeCurrentButton.isEnabled = false
        }
    }

    @objc private func modeSelected(_ sender: RimeFixedAccentChoiceButton) {
        guard ChordExtensionMode.allCases.indices.contains(sender.tag),
              ChordExtensionStore.shared.isEnabled else { return }
        ChordExtensionStore.shared.setMode(ChordExtensionMode.allCases[sender.tag])
        refresh()
    }

    @objc private func makeCurrent() {
        guard ChordExtensionStore.shared.isEnabled,
              InputConfigurationStore.shared.select(
                schemaID: ChordExtensionStore.schemaID
              ) else {
            NSSound.beep()
            refresh()
            return
        }
        RimeBufferController.applyStoredInputConfiguration()
        refresh()
    }

    @objc private func durationFieldChanged() {
        applyDuration(durationField.doubleValue)
    }

    @objc private func durationStepperChanged() {
        applyDuration(durationStepper.doubleValue)
    }

    @objc private func resetDuration() {
        window?.makeFirstResponder(nil)
        ChordExtensionStore.shared.resetDuration()
        refresh()
    }

    private func applyDuration(_ value: Double) {
        ChordExtensionStore.shared.duration = value
        refresh()
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard obj.object as? NSTextField === durationField else { return }
        applyDuration(durationField.doubleValue)
    }
}

private final class FlyChordLessonsPageView: NSView {
    init(curriculum: FlyChordCurriculum, progressStore: FlyChordProgressStore) {
        super.init(frame: .zero)
        let snapshot = progressStore.snapshot
        var rows: [NSView] = [
            FlyChordPageStyle.title("课程"),
            FlyChordPageStyle.caption(
                "课程从当前飞耀方案的精确映射自动生成；方案更新后无需维护第二份键位表。"
            ),
        ]
        for course in curriculum.courses {
            let progress = snapshot.progress(for: course)
            let name = NSTextField(labelWithString: course.title)
            name.font = .systemFont(ofSize: 11, weight: .semibold)
            name.textColor = RimeUI.textPrimary
            let count = NSTextField(labelWithString: "\(course.mappings.count) 项")
            count.font = .monospacedDigitSystemFont(ofSize: 9, weight: .medium)
            count.textColor = RimeUI.textMuted
            let header = NSStackView(views: [name, flexibleSpacer(), count])
            header.orientation = .horizontal
            let detail = FlyChordPageStyle.caption(
                "已练 \(progress.attemptedItems)/\(progress.totalItems) · 已掌握 \(progress.masteredItems) · 连续正确 3 次即掌握"
            )
            rows.append(FlyChordPageStyle.card([header, detail]))
        }
        rows.append(FlyChordPageStyle.caption(
            "练习进度只保存映射的匿名 ID、正确次数和时间戳，不保存按键文本或输入内容。"
        ))
        let column = FlyChordPageStyle.column(rows)
        addPinned(column)
    }

    required init?(coder: NSCoder) { nil }
}

private final class FlyChordProgressPageView: NSView {
    private let curriculum: FlyChordCurriculum
    private let progressStore: FlyChordProgressStore
    private let rows = NSStackView()

    init(curriculum: FlyChordCurriculum, progressStore: FlyChordProgressStore) {
        self.curriculum = curriculum
        self.progressStore = progressStore
        super.init(frame: .zero)
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 8
        rows.edgeInsets = NSEdgeInsets(top: 0, left: 24, bottom: 22, right: 24)
        addPinned(rows)
        refresh()
    }

    required init?(coder: NSCoder) { nil }

    private func refresh() {
        rows.arrangedSubviews.forEach {
            rows.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        let snapshot = progressStore.snapshot
        let all = curriculum.courses.map { snapshot.progress(for: $0) }
        let total = all.reduce(0) { $0 + $1.totalItems }
        let attempted = all.reduce(0) { $0 + $1.attemptedItems }
        let mastered = all.reduce(0) { $0 + $1.masteredItems }
        rows.addArrangedSubview(FlyChordPageStyle.title("学习进度"))
        rows.addArrangedSubview(FlyChordPageStyle.caption(
            "全部 \(total) 项 · 已练 \(attempted) · 已掌握 \(mastered)"
        ))
        for (course, progress) in zip(curriculum.courses, all) {
            let accuracy = progress.attempts > 0
                ? Double(progress.correctAttempts) / Double(progress.attempts) * 100
                : 0
            let name = NSTextField(labelWithString: course.title)
            name.font = .systemFont(ofSize: 11, weight: .semibold)
            name.textColor = RimeUI.textPrimary
            let detail = FlyChordPageStyle.caption(
                "掌握 \(progress.masteredItems)/\(progress.totalItems) · 尝试 \(progress.attempts) 次 · 正确率 \(String(format: "%.0f", accuracy))%"
            )
            rows.addArrangedSubview(FlyChordPageStyle.card([name, detail]))
        }
        let clear = NSButton(title: "清空学习进度…", target: self, action: #selector(clearProgress))
        rows.addArrangedSubview(clear)
    }

    @objc private func clearProgress() {
        let alert = NSAlert()
        alert.messageText = "清空并击学习进度？"
        alert.informativeText = "课程与键位不会删除，但所有练习次数、正确率和掌握状态会被清空。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "清空")
        alert.addButton(withTitle: "取消")
        alert.window.appearance = RimeUI.appKitAppearance
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            _ = try progressStore.clear()
            refresh()
        } catch {
            showErrorAlert(error)
        }
    }
}

private final class FlyChordPracticePageView: NSView {
    private let curriculum: FlyChordCurriculum
    private let progressStore: FlyChordProgressStore
    private let coursePopUp = RimeFixedAccentPopUpButton()
    private let targetLabel = NSTextField(labelWithString: "")
    private let chordHint = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let progressLabel = NSTextField(labelWithString: "")
    private let captureView: FlyChordPracticeCaptureView
    private let captureButton = NSButton(title: "开始练习", target: nil, action: nil)
    private let nextButton = NSButton(title: "换一题", target: nil, action: nil)
    private var exercises: [FlyChordExercise] = []
    private var exerciseIndex = 0
    private var streak = 0
    private var isAdvancingAfterCorrectAnswer = false
    private var feedbackGeneration = 0

    init(curriculum: FlyChordCurriculum, progressStore: FlyChordProgressStore) {
        self.curriculum = curriculum
        self.progressStore = progressStore
        captureView = FlyChordPracticeCaptureView(alphabet: curriculum.alphabet)
        super.init(frame: .zero)
        build()
        loadCourses()
    }

    required init?(coder: NSCoder) { nil }

    private func build() {
        targetLabel.font = .systemFont(ofSize: 34, weight: .semibold)
        targetLabel.alignment = .center
        targetLabel.textColor = RimeUI.textPrimary
        targetLabel.translatesAutoresizingMaskIntoConstraints = false
        targetLabel.widthAnchor.constraint(equalToConstant: 620).isActive = true
        chordHint.font = .monospacedSystemFont(ofSize: 14, weight: .medium)
        chordHint.textColor = RimeUI.textSecondary
        statusLabel.font = .systemFont(ofSize: 12, weight: .medium)
        progressLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        progressLabel.textColor = RimeUI.textMuted

        coursePopUp.target = self
        coursePopUp.action = #selector(courseChanged)
        captureButton.target = self
        captureButton.action = #selector(toggleCapture)
        nextButton.target = self
        nextButton.action = #selector(nextExercise)
        let controls = NSStackView(views: [coursePopUp, captureButton, nextButton, flexibleSpacer(), progressLabel])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 8
        controls.translatesAutoresizingMaskIntoConstraints = false
        controls.widthAnchor.constraint(equalToConstant: 650).isActive = true

        captureView.onChord = { [weak self] chord in self?.submit(chord) }
        captureView.onActivationChanged = { [weak self] active in
            self?.captureButton.title = active ? "停止练习" : "开始练习"
        }

        let targetCard = FlyChordPageStyle.card([
            targetLabel,
            chordHint,
            captureView,
            statusLabel,
        ])
        let column = FlyChordPageStyle.column([
            FlyChordPageStyle.title("专项练习"),
            FlyChordPageStyle.caption("选择课程后点击“开始练习”。只有下方练习区域获得焦点时才会捕获按键；离开页面即停止。"),
            controls,
            targetCard,
            FlyChordPageStyle.caption("目标显示为方案输出音节。按错后才显示正确键位，连续正确 3 次会标记为已掌握。"),
        ])
        addPinned(column)
    }

    private func loadCourses() {
        coursePopUp.removeAllItems()
        for course in curriculum.courses {
            coursePopUp.addItem(withTitle: "\(course.title)（\(course.mappings.count)）")
            coursePopUp.lastItem?.representedObject = course.id
        }
        if let preferred = curriculum.courses.firstIndex(where: { $0.keyCount == 2 }) {
            coursePopUp.selectItem(at: preferred)
        }
        reloadExercises()
    }

    private var selectedCourse: FlyChordCourse? {
        guard let id = coursePopUp.selectedItem?.representedObject as? String else { return nil }
        return curriculum.course(id: id)
    }

    @objc private func courseChanged() {
        captureView.deactivate()
        reloadExercises()
    }

    private func reloadExercises() {
        feedbackGeneration &+= 1
        isAdvancingAfterCorrectAnswer = false
        guard let course = selectedCourse else {
            exercises = []
            refreshExercise()
            return
        }
        exercises = FlyChordExerciseSampler.sample(
            from: course,
            limit: min(30, course.mappings.count),
            progress: progressStore.snapshot,
            seed: UInt64(Date().timeIntervalSince1970 / 86_400)
        )
        exerciseIndex = 0
        streak = 0
        refreshExercise()
    }

    private func refreshExercise() {
        guard exercises.indices.contains(exerciseIndex) else {
            targetLabel.stringValue = "本轮完成"
            chordHint.stringValue = "换一个课程，或重新选择当前课程再练一轮。"
            statusLabel.stringValue = ""
            progressLabel.stringValue = ""
            captureView.deactivate()
            return
        }
        let exercise = exercises[exerciseIndex]
        targetLabel.stringValue = exercise.expectedOutput
        chordHint.stringValue = "按下对应并击"
        statusLabel.stringValue = "等待输入"
        statusLabel.textColor = RimeUI.textSecondary
        progressLabel.stringValue = "\(exerciseIndex + 1)/\(exercises.count) · 连对 \(streak)"
    }

    @objc private func toggleCapture() {
        captureView.isCapturing ? captureView.deactivate() : captureView.activate()
    }

    @objc private func nextExercise() {
        guard !exercises.isEmpty else { return }
        feedbackGeneration &+= 1
        isAdvancingAfterCorrectAnswer = false
        exerciseIndex = (exerciseIndex + 1) % exercises.count
        streak = 0
        refreshExercise()
        if captureView.isCapturing { window?.makeFirstResponder(captureView) }
    }

    private func submit(_ chord: String) {
        // Keep the visible question and the scored question identical. During
        // the short success feedback interval the capture view may receive a
        // very fast next chord; ignore it until the next prompt is on screen.
        guard !isAdvancingAfterCorrectAnswer,
              exercises.indices.contains(exerciseIndex) else { return }
        let exercise = exercises[exerciseIndex]
        let correct = FlyChordAnswerMatcher.matches(captured: chord,
                                                    expected: exercise.chord)
        do {
            _ = try progressStore.recordAttempt(mappingID: exercise.mappingID,
                                                correct: correct)
        } catch {
            statusLabel.stringValue = error.localizedDescription
            statusLabel.textColor = .systemRed
            return
        }
        if correct {
            isAdvancingAfterCorrectAnswer = true
            feedbackGeneration &+= 1
            let scheduledGeneration = feedbackGeneration
            streak += 1
            statusLabel.stringValue = "正确 · \(exercise.chord.uppercased())"
            statusLabel.textColor = RimeUI.color(
                FlyChordSettingsThemeRules.successTextHex(for: RimeUI.appearance)
            )
            chordHint.stringValue = "键位 \(exercise.chord.uppercased())"
            exerciseIndex += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
                guard let self,
                      self.feedbackGeneration == scheduledGeneration else { return }
                self.isAdvancingAfterCorrectAnswer = false
                self.refreshExercise()
                if self.captureView.isCapturing {
                    self.window?.makeFirstResponder(self.captureView)
                }
            }
        } else {
            streak = 0
            statusLabel.stringValue = "这次是 \(chord.uppercased())，再试一次"
            statusLabel.textColor = .systemOrange
            chordHint.stringValue = "提示：\(exercise.chord.uppercased())"
            progressLabel.stringValue = "\(exerciseIndex + 1)/\(exercises.count) · 连对 0"
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            feedbackGeneration &+= 1
            isAdvancingAfterCorrectAnswer = false
            captureView.deactivate()
        }
    }
}

private final class FlyChordPracticeCaptureView: NSView {
    var onChord: ((String) -> Void)?
    var onActivationChanged: ((Bool) -> Void)?
    private let alphabetOrder: [Character]
    private var keysDown: Set<Character> = []
    private var chordKeys: Set<Character> = []
    private(set) var isCapturing = false {
        didSet {
            needsDisplay = true
            onActivationChanged?(isCapturing)
        }
    }

    init(alphabet: String) {
        var seen = Set<Character>()
        alphabetOrder = alphabet.filter { seen.insert($0).inserted }
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 76).isActive = true
    }

    required init?(coder: NSCoder) { nil }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func activate() {
        isCapturing = true
        window?.makeFirstResponder(self)
    }

    func deactivate() {
        keysDown.removeAll()
        chordKeys.removeAll()
        isCapturing = false
        if window?.firstResponder === self { window?.makeFirstResponder(nil) }
    }

    override func mouseDown(with event: NSEvent) {
        guard isCapturing else { return }
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        guard isCapturing else {
            super.keyDown(with: event)
            return
        }
        if event.modifierFlags.intersection([.command, .control, .option]).isEmpty == false {
            super.keyDown(with: event)
            return
        }
        guard !event.isARepeat,
              let character = event.charactersIgnoringModifiers?.lowercased().first,
              alphabetOrder.contains(character) else {
            NSSound.beep()
            return
        }
        keysDown.insert(character)
        chordKeys.insert(character)
        needsDisplay = true
    }

    override func keyUp(with event: NSEvent) {
        guard isCapturing,
              let character = event.charactersIgnoringModifiers?.lowercased().first,
              alphabetOrder.contains(character) else {
            super.keyUp(with: event)
            return
        }
        keysDown.remove(character)
        guard keysDown.isEmpty, !chordKeys.isEmpty else {
            needsDisplay = true
            return
        }
        let chord = String(alphabetOrder.filter(chordKeys.contains))
        chordKeys.removeAll()
        needsDisplay = true
        onChord?(chord)
    }

    override func resignFirstResponder() -> Bool {
        keysDown.removeAll()
        chordKeys.removeAll()
        needsDisplay = true
        return super.resignFirstResponder()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let rect = bounds.insetBy(dx: 2, dy: 4)
        let path = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
        let fill = isCapturing
            ? RimeUI.accentGreen.withAlphaComponent(0.11)
            : RimeUI.surface3
        fill.setFill()
        path.fill()
        (isCapturing ? RimeUI.accentGreen : RimeUI.border).setStroke()
        path.lineWidth = isCapturing ? 1.5 : 1
        path.stroke()

        let value: String
        if !chordKeys.isEmpty {
            value = String(alphabetOrder.filter(chordKeys.contains)).uppercased()
        } else {
            value = isCapturing ? "练习已激活 · 请并击" : "点击“开始练习”后捕获按键"
        }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: chordKeys.isEmpty ? 13 : 24,
                                     weight: chordKeys.isEmpty ? .medium : .semibold),
            .foregroundColor: chordKeys.isEmpty ? RimeUI.textSecondary : RimeUI.textPrimary,
        ]
        let size = (value as NSString).size(withAttributes: attrs)
        (value as NSString).draw(at: CGPoint(x: bounds.midX - size.width / 2,
                                             y: bounds.midY - size.height / 2),
                                 withAttributes: attrs)
    }
}

private func flexibleSpacer() -> NSView {
    let view = NSView()
    view.setContentHuggingPriority(.defaultLow, for: .horizontal)
    return view
}

private extension NSView {
    func addPinned(_ child: NSView) {
        child.translatesAutoresizingMaskIntoConstraints = false
        addSubview(child)
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: leadingAnchor),
            child.trailingAnchor.constraint(equalTo: trailingAnchor),
            child.topAnchor.constraint(equalTo: topAnchor),
            child.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    func showErrorAlert(_ error: Error) {
        let alert = NSAlert(error: error)
        if let window { alert.beginSheetModal(for: window) }
        else {
            alert.window.appearance = RimeUI.appKitAppearance
            alert.runModal()
        }
    }
}
