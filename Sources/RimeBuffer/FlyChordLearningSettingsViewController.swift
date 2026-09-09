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
    private var keymapEditor: ChordKeymapEditorViewController?

    func confirmCanLeave() -> Bool { keymapEditor?.confirmCanLeave() ?? true }

    init(subpageID: String) {
        self.subpageID = subpageID
        do {
            schemaResult = .success(try FlyChordSchemaParser.loadActive())
        } catch {
            schemaResult = .failure(error)
        }
        do {
            progressStoreResult = .success(try FlyChordProgressStore(
                schemaID: ChordKeymapStore.shared.activeProfile.schemaID
            ))
        } catch {
            progressStoreResult = .failure(error)
        }
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        if subpageID == "keymap" {
            let editor = ChordKeymapEditorViewController()
            keymapEditor = editor
            addChild(editor)
            view = editor.view
            return
        }
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

struct FlyChordConfigurationState {
    let isEnabled: Bool
    let implementationName: String
    let isCurrent: Bool
    let duration: TimeInterval
}

/// A single product behavior with injectable state/actions for isolated UI QA.
/// This page has no selector for historical same-batch-only behavior.
final class FlyChordConfigurationPageView: NSView, NSTextFieldDelegate {
    private let stateProvider: () -> FlyChordConfigurationState
    private let onDuration: (Double) -> Void
    private let onReset: () -> Void
    private let onMakeCurrent: () -> Bool
    private let implementationLabel = NSTextField(labelWithString: "")
    private let availabilityLabel = NSTextField(labelWithString: "")
    private let availabilityDetail = NSTextField(wrappingLabelWithString: "")
    private let makeCurrentButton = RimePointingHandButton(
        title: "设为当前输入方案", target: nil, action: nil
    )
    private let durationField = NSTextField(string: "")
    private let durationStepper = NSStepper()
    private var observations: [NSObjectProtocol] = []

    convenience init() {
        self.init(
            stateProvider: {
                let store = ChordExtensionStore.shared
                return FlyChordConfigurationState(
                    isEnabled: store.isEnabled,
                    implementationName: store.implementationName,
                    isCurrent: InputConfigurationStore.shared.selectedSchemaID
                        == ChordExtensionStore.schemaID,
                    duration: store.duration
                )
            },
            onDuration: { ChordExtensionStore.shared.duration = $0 },
            onReset: { ChordExtensionStore.shared.resetDuration() },
            onMakeCurrent: {
                guard ChordExtensionStore.shared.isEnabled,
                      InputConfigurationStore.shared.select(schemaID: ChordExtensionStore.schemaID)
                else { return false }
                RIMESController.applyStoredInputConfiguration()
                return true
            }
        )
    }

    init(stateProvider: @escaping () -> FlyChordConfigurationState,
         onDuration: @escaping (Double) -> Void,
         onReset: @escaping () -> Void,
         onMakeCurrent: @escaping () -> Bool,
         observesChanges: Bool = true) {
        self.stateProvider = stateProvider
        self.onDuration = onDuration
        self.onReset = onReset
        self.onMakeCurrent = onMakeCurrent
        super.init(frame: .zero)
        build()
        if observesChanges { observeChanges() }
        refresh()
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        observations.forEach { NotificationCenter.default.removeObserver($0) }
    }

    private func build() {
        availabilityLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        availabilityLabel.textColor = RimeUI.textPrimary
        availabilityLabel.setContentHuggingPriority(.required, for: .horizontal)
        availabilityDetail.font = .systemFont(ofSize: 10)
        availabilityDetail.textColor = RimeUI.textSecondary
        availabilityDetail.preferredMaxLayoutWidth = 425
        makeCurrentButton.target = self
        makeCurrentButton.action = #selector(makeCurrent)
        makeCurrentButton.controlSize = .small
        makeCurrentButton.setAccessibilityIdentifier("chord-settings.make-current")
        makeCurrentButton.setContentHuggingPriority(.required, for: .horizontal)
        let availabilityCopy = NSStackView(views: [availabilityLabel, availabilityDetail])
        availabilityCopy.orientation = .vertical
        availabilityCopy.alignment = .leading
        availabilityCopy.spacing = 4
        availabilityCopy.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let availabilityRow = NSStackView(
            views: [availabilityCopy, flexibleSpacer(), makeCurrentButton]
        )
        availabilityRow.orientation = .horizontal
        availabilityRow.distribution = .fill
        availabilityRow.alignment = .centerY
        availabilityRow.spacing = 8

        implementationLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        implementationLabel.textColor = RimeUI.textPrimary
        implementationLabel.setAccessibilityIdentifier("chord-settings.implementation")
        let behavior = FlyChordPageStyle.caption(
            "同一批按键可一起结算，也支持先左后右分开敲。至少一侧为多键时，优先按合并后的整组键位映射为音节。"
        )
        behavior.setAccessibilityIdentifier("chord-settings.behavior")
        let guards = FlyChordPageStyle.caption(
            "单独字母保留原字符，两次单键不会跨批合并。“按映射类型”方案的合并项须为完整音节。停顿本身不会取消左右配对；分隔符、编辑、焦点或方案变化会结束配对。"
        )

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
        durationField.setAccessibilityLabel("并击组键间隔，秒")
        durationField.setAccessibilityIdentifier("chord-settings.duration")
        durationField.translatesAutoresizingMaskIntoConstraints = false
        durationField.widthAnchor.constraint(equalToConstant: 64).isActive = true
        durationStepper.minValue = ChordSettings.range.lowerBound
        durationStepper.maxValue = ChordSettings.range.upperBound
        durationStepper.increment = 0.01
        durationStepper.valueWraps = false
        durationStepper.target = self
        durationStepper.action = #selector(durationStepperChanged)
        durationStepper.setAccessibilityLabel("调整并击组键间隔")
        let unit = NSTextField(labelWithString: "秒")
        unit.font = .systemFont(ofSize: 10)
        unit.textColor = RimeUI.textMuted
        let reset = RimePointingHandButton(title: "恢复默认", target: self,
                                          action: #selector(resetDuration))
        reset.controlSize = .small
        reset.setAccessibilityIdentifier("chord-settings.reset-duration")
        let durationRow = NSStackView(
            views: [durationField, durationStepper, unit, reset, flexibleSpacer()]
        )
        durationRow.orientation = .horizontal
        durationRow.distribution = .fill
        durationRow.alignment = .centerY
        durationRow.spacing = 8

        let introduction = FlyChordPageStyle.caption(
            "在“键位方案”页复制、新建或导入方案。启用扩展不会自动替换当前普通输入方案。"
        )
        introduction.preferredMaxLayoutWidth = 650
        introduction.widthAnchor.constraint(lessThanOrEqualToConstant: 650).isActive = true
        let column = FlyChordPageStyle.column([
            FlyChordPageStyle.title("并击设置"),
            introduction,
            configurationCard([availabilityRow]),
            configurationCard([implementationLabel, behavior, guards]),
            configurationCard([
                FlyChordPageStyle.section("组键间隔"),
                durationRow,
                FlyChordPageStyle.caption(
                    "此间隔决定哪些按键属于同一批，不是左右配对的超时。修改后立即作用于普通输入与意识流输入。"
                ),
            ]),
        ])
        addPinned(column)
    }

    private func configurationCard(_ views: [NSView]) -> NSStackView {
        let card = FlyChordPageStyle.card(views)
        card.alignment = .leading
        for view in views {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: card.widthAnchor, constant: -24).isActive = true
            if let label = view as? NSTextField {
                label.alignment = .left
                label.preferredMaxLayoutWidth = 626
            }
        }
        return card
    }

    private func observeChanges() {
        for name in [Notification.Name.chordExtensionDidChange, .inputConfigurationDidChange,
                     .chordKeymapDidChange, .chordDurationDidChange] {
            observations.append(NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in self?.refresh() })
        }
    }

    private func refresh() {
        let state = stateProvider()
        implementationLabel.stringValue = "当前键位方案：\(state.implementationName)"
        durationField.stringValue = String(format: "%.2f", state.duration)
        durationField.isEnabled = state.isEnabled
        durationStepper.doubleValue = state.duration
        durationStepper.isEnabled = state.isEnabled
        if state.isCurrent && state.isEnabled {
            availabilityLabel.stringValue = "正在使用"
            availabilityLabel.textColor = RimeUI.accentTextColor
            availabilityDetail.stringValue = "普通输入与意识流输入使用同一套并击规则和已应用的键位方案。"
            makeCurrentButton.title = "当前输入方案"
            makeCurrentButton.isEnabled = false
        } else if state.isEnabled {
            availabilityLabel.stringValue = "可用"
            availabilityLabel.textColor = RimeUI.accentTextColor
            availabilityDetail.stringValue = "扩展已启用。需要在普通输入中使用时，可设为当前输入方案。"
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

    @objc private func makeCurrent() {
        guard stateProvider().isEnabled, onMakeCurrent() else {
            NSSound.beep()
            refresh()
            return
        }
        refresh()
    }

    @objc private func durationFieldChanged() { applyDuration(durationField.doubleValue) }
    @objc private func durationStepperChanged() { applyDuration(durationStepper.doubleValue) }
    @objc private func resetDuration() {
        window?.makeFirstResponder(nil)
        onReset()
        refresh()
    }

    private func applyDuration(_ value: Double) {
        onDuration(value)
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
                "课程从当前键位方案的精确映射自动生成，进度按方案分别保存。"
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
        let clear = RimePointingHandButton(
            title: "清空学习进度…",
            target: self,
            action: #selector(clearProgress)
        )
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
    private let captureButton = RimePointingHandButton(
        title: "开始练习",
        target: nil,
        action: nil
    )
    private let nextButton = RimePointingHandButton(
        title: "换一题",
        target: nil,
        action: nil
    )
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
    private var pointerTrackingArea: NSTrackingArea?
    private var pointerInside = false
    private(set) var isCapturing = false {
        didSet {
            needsDisplay = true
            RimePointingHandCursorRules.enabledDidChange(
                for: self,
                pointerInside: pointerInside,
                enabled: isCapturing
            )
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

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        RimePointingHandCursorRules.updateTrackingArea(
            &pointerTrackingArea,
            for: self
        )
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        RimePointingHandCursorRules.resetCursorRect(
            for: self,
            enabled: isCapturing
        )
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        pointerInside = true
        RimePointingHandCursorRules.mouseEntered(enabled: isCapturing)
    }

    override func mouseExited(with event: NSEvent) {
        pointerInside = false
        RimePointingHandCursorRules.mouseExited()
        super.mouseExited(with: event)
    }

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
