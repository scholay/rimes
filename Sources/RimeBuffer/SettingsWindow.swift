import Cocoa
import CRimeBridge
import UniformTypeIdentifiers

private enum SettingsPluginSwitchMode {
    case enablement
    case bufferEnablement
}

private final class SettingsPluginSwitch: NSSwitch {
    var pluginKey = PluginKey(domain: .builtIn, rawID: "")
    var mode: SettingsPluginSwitchMode = .enablement
}

private final class SettingsPluginConfigurationButton: NSButton {
    var pluginKey = PluginKey(domain: .builtIn, rawID: "")
}

private final class SettingsLexiconButton: NSButton {
    var lexiconKind: UserLexiconKind = .chinese
}

private final class SettingsRouteButton: NSButton {
    var routeID = SettingsCoreRoute.inputMethod.id
}

private final class SettingsPageDocumentView: NSView {
    override var isFlipped: Bool { true }
}

private final class SettingsBackgroundView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
    }
}

/// Central settings surface for input schemas, candidate UI, buffer mode,
/// remote typing, and local diagnostics.
final class SettingsWindowController: NSObject, NSTextFieldDelegate, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private var window: NSWindow?
    private let sidebar = NSStackView()
    private let contentHost = NSView()
    private var routeCatalog = try! SettingsRouteCatalog()
    private lazy var navigation = SettingsNavigationState(catalog: routeCatalog)
    private var navButtons: [SettingsRouteID: NSButton] = [:]
    private var activePluginSettingsController: NSViewController?
    private var statsObserver: NSObjectProtocol?
    private var pluginObserver: NSObjectProtocol?
    private var registryObserver: NSObjectProtocol?
    private var activeBufferPluginObserver: NSObjectProtocol?
    private var inputConfigurationObserver: NSObjectProtocol?
    private var aiConnectorObserver: NSObjectProtocol?
    private var aiConnectorAvailabilityObserver: NSObjectProtocol?

    private var encodingRadios: [InputEncoding: NSButton] = [:]
    private var keyingModeRadios: [KeyingMode: NSButton] = [:]
    private let appearancePopUp = NSPopUpButton()
    private let bufferCheck = NSButton(checkboxWithTitle: "启用缓冲模式（提交先暂存，手动确认上屏）", target: nil, action: nil)
    private let bufferWindowVisibleCheck = NSButton(checkboxWithTitle: "显示独立缓冲工作台", target: nil, action: nil)
    private let bufferPinnedCheck = NSButton(checkboxWithTitle: "常显于所有桌面与全屏空间", target: nil, action: nil)
    private let candidatePlacementPopUp = NSPopUpButton()
    private let moveBufferWindowButton = NSButton(title: "移到当前屏幕", target: nil, action: nil)
    private let resetOnAppSwitchCheck = NSButton(checkboxWithTitle: "切换到其他应用时清空本地缓冲内容", target: nil, action: nil)
    private let gatewayEnableCheck = NSButton(checkboxWithTitle: "启用本地网关（127.0.0.1，仅回环，Token 鉴权）", target: nil, action: nil)
    private let gatewayConfigField = NSTextField(string: "")
    private let gatewayCopyConfigButton = NSButton(title: "复制配置 (JSON)", target: nil, action: nil)
    private let gatewayCommandField = NSTextField(string: "")
    private let gatewayCopyButton = NSButton(title: "复制 Claude Code 命令", target: nil, action: nil)
    private let aiBaseURLField = NSTextField(string: "")
    private let aiModelField = NSTextField(string: "")
    private let aiAPIKeyField = NSSecureTextField(string: "")
    private let aiConfigurationStatus = NSTextField(labelWithString: "")
    private var aiConnectorRadios: [AITextProviderKind: NSButton] = [:]
    private let codexLoginButton = NSButton(title: "登录 Codex", target: nil, action: nil)
    private let codexCopyLoginLinkButton = NSButton(title: "复制登录链接", target: nil, action: nil)
    private let codexLoginSpinner = NSProgressIndicator()
    private let codexLoginStatusLabel = NSTextField(wrappingLabelWithString: "")
    private var codexLoginOperation: AITextCodexLoginOperation?
    private var codexLoginSessionID: UUID?
    private var codexLoginCancelling = false
    private var codexAuthorizationURL: URL?
    private var codexLoginFeedback: String?
    private var codexLoginFeedbackIsError = false
    private let claudeLoginButton = NSButton(title: "登录 Claude", target: nil, action: nil)
    private let claudeLoginSpinner = NSProgressIndicator()
    private let claudeLoginStatusLabel = NSTextField(wrappingLabelWithString: "")
    private var claudeLoginOperation: AITextClaudeLoginOperation?
    private var claudeLoginSessionID: UUID?
    private var claudeLoginCancelling = false
    private var claudeLoginFeedback: String?
    private var claudeLoginFeedbackIsError = false
    private var candidateMetricFields: [CandidateWindowMetric: NSTextField] = [:]
    private var candidateMetricSliders: [CandidateWindowMetric: NSSlider] = [:]
    private var candidateMetricHints: [CandidateWindowMetric: NSTextField] = [:]
    private var candidatePreview: CandidatePreviewView?
    private let chordDurationField = NSTextField(string: "")
    private let chordDurationStepper = NSStepper()
    private let statsDatePicker = NSDatePicker()
    private let statsSummary = NSTextField(labelWithString: "")
    private let statsTopKey = NSTextField(labelWithString: "")
    private let installStatus = NSTextField(labelWithString: "")
    private let heatmapView = KeyboardHeatmapView()
    private let remoteCheck = NSButton(checkboxWithTitle: "启用隔空传字", target: nil, action: nil)
    private let remoteNameField = NSTextField(string: "")
    private let remoteStatusLabel = NSTextField(labelWithString: "")
    private let remoteDevicesStack = NSStackView()
    private var remoteDiscoveredIDs: [String] = []
    private var remoteTrustedKeys: [String] = []
    private let pluginRowsStack = NSStackView()
    private let pluginStatusLabel = NSTextField(labelWithString: "")
    private var pluginDownloadInProgress = false
    private var pluginRefreshScheduled = false
    private var pluginConfigurationSheet: NSPanel?

    private var userDir: URL {
        if let override = ProcessInfo.processInfo.environment["RIMEBUFFER_USER_DIR"],
           !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/RimeBuffer", isDirectory: true)
    }

    private var installLogURL: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("rimebuffer-install.log")
    }

    func show() {
        if window == nil { build() }
        rebuildRouteCatalog()
        reload()
        showCurrentRoute()
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    /// Dev-only: render one settings page to a PNG by drawing the window's own
    /// view hierarchy (no screen-recording permission needed). Used to preview
    /// the UI without a live input session.
    func renderForPreview(pageIndex: Int, to path: String) {
        if window == nil { build() }
        rebuildRouteCatalog()
        reload()
        let targets = previewTargets()
        let target = targets.indices.contains(pageIndex)
            ? targets[pageIndex]
            : (SettingsCoreRoute.buffer.id, SettingsSubpageID(rawValue: "general"), "buffer")
        selectPreviewTarget(routeID: target.0, subpageID: target.1)
        renderCurrentView(to: path)
    }

    /// Renders every route/subpage from the live catalog and writes a manifest
    /// so visual checks never depend on enum ordinals or a hard-coded page
    /// count. Preview user-data isolation is established by main.swift.
    @discardableResult
    func renderAllForPreview(to directory: String) -> Bool {
        if window == nil { build() }
        rebuildRouteCatalog()
        reload()
        let root = URL(fileURLWithPath: directory, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: root,
                                                    withIntermediateDirectories: true)
        } catch {
            print("settings render directory failed: \(error.localizedDescription)")
            return false
        }

        var manifest: [[String: String]] = []
        var allRendered = true
        for target in previewTargets() {
            selectPreviewTarget(routeID: target.0, subpageID: target.1)
            let fileName = target.2 + ".png"
            let path = root.appendingPathComponent(fileName).path
            allRendered = renderCurrentView(to: path) && allRendered
            manifest.append([
                "routeID": target.0.rawValue,
                "subpageID": target.1.rawValue,
                "file": fileName,
            ])
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: manifest,
                                                  options: [.prettyPrinted, .sortedKeys])
            try data.write(to: root.appendingPathComponent("manifest.json"),
                           options: .atomic)
        } catch {
            print("settings render manifest failed: \(error.localizedDescription)")
            allRendered = false
        }
        return allRendered
    }

    private func previewTargets() -> [(SettingsRouteID, SettingsSubpageID, String)] {
        routeCatalog.orderedRoutes.flatMap { route in
            route.subpages.map { subpage in
                let routeSlug = route.id.rawValue
                    .replacingOccurrences(of: ".", with: "-")
                let subpageSlug = subpage.id.rawValue
                    .replacingOccurrences(of: ".", with: "-")
                return (route.id, subpage.id, "\(routeSlug)--\(subpageSlug)")
            }
        }
    }

    private func selectPreviewTarget(routeID: SettingsRouteID,
                                     subpageID: SettingsSubpageID) {
        _ = navigation.selectRoute(routeID, catalog: routeCatalog)
        _ = navigation.selectSubpage(subpageID, catalog: routeCatalog)
        showCurrentRoute()
    }

    @discardableResult
    private func renderCurrentView(to path: String) -> Bool {
        guard let content = window?.contentView else { return false }
        content.layoutSubtreeIfNeeded()
        content.display()
        guard let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return false }
        content.cacheDisplay(in: content.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        do {
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            return true
        } catch {
            print("settings render failed \(path): \(error.localizedDescription)")
            return false
        }
    }

    // MARK: UI construction

    private func build() {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 680),
                           styleMask: [.titled, .closable, .resizable],
                           backing: .buffered, defer: false)
        win.title = "\(ProductIdentity.displayName) 设置"
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.minSize = NSSize(width: 860, height: 600)
        win.backgroundColor = .windowBackgroundColor

        configureControls()

        sidebar.orientation = .vertical
        sidebar.alignment = .leading
        sidebar.spacing = 6
        sidebar.edgeInsets = NSEdgeInsets(top: 16, left: 12, bottom: 16, right: 12)
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        rebuildSidebar()

        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false

        contentHost.translatesAutoresizingMaskIntoConstraints = false

        let background = SettingsBackgroundView()
        win.contentView = background
        background.addSubview(sidebar)
        background.addSubview(divider)
        background.addSubview(contentHost)
        contentHost.setContentHuggingPriority(.defaultLow, for: .horizontal)
        contentHost.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: background.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 160),
            divider.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            divider.topAnchor.constraint(equalTo: background.topAnchor),
            divider.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),
            contentHost.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            contentHost.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            contentHost.topAnchor.constraint(equalTo: background.topAnchor),
            contentHost.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])

        statsObserver = NotificationCenter.default.addObserver(
            forName: .keyFrequencyDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard self?.window?.isVisible == true,
                  self?.selectedBuiltInPluginID == BuiltInPluginID.statistics else { return }
            self?.refreshStats()
        }

        pluginObserver = NotificationCenter.default.addObserver(
            forName: ActionPluginManager.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  notification.userInfo?[ActionPluginManager.rootPathUserInfoKey] as? String
                    == ActionPluginManager.shared.rootURL.path,
                  self.window?.isVisible == true,
                  self.selectedCoreRoute == .plugins else { return }
            self.schedulePluginListRefresh()
        }

        registryObserver = NotificationCenter.default.addObserver(
            forName: .pluginRegistryDidChange,
            object: PluginRegistry.shared,
            queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window?.isVisible == true else { return }
                self.rebuildRouteCatalog()
                self.showCurrentRoute()
            }
        }

        activeBufferPluginObserver = NotificationCenter.default.addObserver(
            forName: .activeBufferPluginDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self,
                  self.window?.isVisible == true,
                  self.selectedCoreRoute == .plugins else { return }
            self.schedulePluginListRefresh()
        }

        inputConfigurationObserver = NotificationCenter.default.addObserver(
            forName: .inputConfigurationDidChange,
            object: InputConfigurationStore.shared,
            queue: .main
        ) { [weak self] _ in
            self?.refreshInputConfigurationSelection()
        }

        aiConnectorObserver = NotificationCenter.default.addObserver(
            forName: .aiTextConnectorDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshAIConnectorSelection()
        }
        aiConnectorAvailabilityObserver = NotificationCenter.default.addObserver(
            forName: .aiTextConnectorAvailabilityDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let rawKind = notification.userInfo?["kind"] as? String,
                  let kind = AITextProviderKind(rawValue: rawKind) else { return }
            if kind == .claudeCodeCLI, self.claudeLoginOperation == nil {
                self.claudeLoginFeedback = nil
                self.claudeLoginFeedbackIsError = false
            }
            if kind == .codexCLI, self.codexLoginOperation == nil {
                self.codexLoginFeedback = nil
                self.codexLoginFeedbackIsError = false
            }
            guard self.window?.isVisible == true,
                  self.selectedCoreRoute == .connectors,
                  self.navigation.selectedSubpage()?.rawValue == "ai-model" else { return }
            DispatchQueue.main.async { [weak self] in
                self?.showCurrentRoute()
            }
        }

        window = win
    }

    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === window else { return }
        if let sheet = pluginConfigurationSheet {
            window?.endSheet(sheet)
            sheet.orderOut(nil)
            pluginConfigurationSheet = nil
        }
        if let operation = codexLoginOperation {
            codexLoginCancelling = true
            codexAuthorizationURL = nil
            codexLoginFeedback = "正在取消 Codex 登录…"
            codexLoginFeedbackIsError = false
            operation.cancel()
        }
        if let operation = claudeLoginOperation {
            claudeLoginCancelling = true
            claudeLoginFeedback = "正在取消 Claude 登录…"
            claudeLoginFeedbackIsError = false
            operation.cancel()
        }
        // The controller is a process-lifetime singleton, but dynamic plugin
        // pages must not be: they observe high-frequency metric stores. Drop
        // the hosted view/controller so a closed Settings window does no
        // hidden AppKit work on the IME main thread.
        contentHost.subviews.forEach { $0.removeFromSuperview() }
        activePluginSettingsController = nil
        candidatePreview = nil
    }

    private func configureControls() {
        for (index, encoding) in InputEncoding.allCases.enumerated() {
            let button = NSButton(radioButtonWithTitle: encoding.title,
                                  target: self,
                                  action: #selector(inputEncodingSelected(_:)))
            button.tag = index
            button.font = .systemFont(ofSize: 13, weight: .medium)
            button.translatesAutoresizingMaskIntoConstraints = false
            button.widthAnchor.constraint(equalToConstant: 150).isActive = true
            encodingRadios[encoding] = button
        }
        for (index, mode) in KeyingMode.allCases.enumerated() {
            let button = NSButton(radioButtonWithTitle: mode.title,
                                  target: self,
                                  action: #selector(keyingModeSelected(_:)))
            button.tag = index
            button.font = .systemFont(ofSize: 13, weight: .medium)
            button.translatesAutoresizingMaskIntoConstraints = false
            button.widthAnchor.constraint(equalToConstant: 150).isActive = true
            keyingModeRadios[mode] = button
        }
        for (index, kind) in AITextProviderKind.allCases.enumerated() {
            let button = NSButton(radioButtonWithTitle: kind.displayName,
                                  target: self,
                                  action: #selector(aiConnectorSelected(_:)))
            button.tag = index
            button.font = .systemFont(ofSize: 13, weight: .medium)
            button.translatesAutoresizingMaskIntoConstraints = false
            button.widthAnchor.constraint(equalToConstant: 220).isActive = true
            aiConnectorRadios[kind] = button
        }
        codexLoginButton.target = self
        codexLoginButton.action = #selector(codexLoginButtonPressed)
        codexCopyLoginLinkButton.target = self
        codexCopyLoginLinkButton.action = #selector(copyCodexLoginLink)
        codexCopyLoginLinkButton.isHidden = true
        codexLoginSpinner.style = .spinning
        codexLoginSpinner.controlSize = .small
        codexLoginSpinner.isDisplayedWhenStopped = false
        codexLoginSpinner.translatesAutoresizingMaskIntoConstraints = false
        codexLoginSpinner.widthAnchor.constraint(equalToConstant: 16).isActive = true
        codexLoginSpinner.heightAnchor.constraint(equalToConstant: 16).isActive = true
        codexLoginStatusLabel.font = .systemFont(ofSize: 11)
        codexLoginStatusLabel.textColor = .tertiaryLabelColor
        claudeLoginButton.target = self
        claudeLoginButton.action = #selector(claudeLoginButtonPressed)
        claudeLoginSpinner.style = .spinning
        claudeLoginSpinner.controlSize = .small
        claudeLoginSpinner.isDisplayedWhenStopped = false
        claudeLoginSpinner.translatesAutoresizingMaskIntoConstraints = false
        claudeLoginSpinner.widthAnchor.constraint(equalToConstant: 16).isActive = true
        claudeLoginSpinner.heightAnchor.constraint(equalToConstant: 16).isActive = true
        claudeLoginStatusLabel.font = .systemFont(ofSize: 11)
        claudeLoginStatusLabel.textColor = .tertiaryLabelColor
        bufferCheck.target = self
        bufferCheck.action = #selector(bufferToggled)
        bufferWindowVisibleCheck.target = self
        bufferWindowVisibleCheck.action = #selector(bufferWindowVisibilityToggled)
        bufferPinnedCheck.target = self
        bufferPinnedCheck.action = #selector(bufferPinnedToggled)
        candidatePlacementPopUp.removeAllItems()
        for placement in BufferCandidatePlacement.allCases {
            candidatePlacementPopUp.addItem(withTitle: placement.title)
            candidatePlacementPopUp.lastItem?.representedObject = placement.rawValue
        }
        candidatePlacementPopUp.target = self
        candidatePlacementPopUp.action = #selector(bufferCandidatePlacementChanged)
        moveBufferWindowButton.target = self
        moveBufferWindowButton.action = #selector(moveBufferWindow)
        resetOnAppSwitchCheck.target = self
        resetOnAppSwitchCheck.action = #selector(resetOnAppSwitchToggled)
        gatewayEnableCheck.target = self
        gatewayEnableCheck.action = #selector(gatewayToggled)
        gatewayConfigField.isEditable = false
        gatewayConfigField.isSelectable = true
        gatewayConfigField.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        gatewayConfigField.lineBreakMode = .byCharWrapping
        gatewayConfigField.maximumNumberOfLines = 12
        gatewayConfigField.translatesAutoresizingMaskIntoConstraints = false
        gatewayConfigField.widthAnchor.constraint(equalToConstant: 560).isActive = true
        gatewayCopyConfigButton.target = self
        gatewayCopyConfigButton.action = #selector(copyGatewayConfig)
        gatewayCommandField.isEditable = false
        gatewayCommandField.isSelectable = true
        gatewayCommandField.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        gatewayCommandField.lineBreakMode = .byCharWrapping
        gatewayCommandField.maximumNumberOfLines = 4
        gatewayCommandField.translatesAutoresizingMaskIntoConstraints = false
        gatewayCommandField.widthAnchor.constraint(equalToConstant: 560).isActive = true
        gatewayCopyButton.target = self
        gatewayCopyButton.action = #selector(copyGatewayCommand)

        aiBaseURLField.placeholderString = "https://api.openai.com/v1"
        aiBaseURLField.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        aiModelField.placeholderString = "模型名称"
        aiModelField.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        aiAPIKeyField.placeholderString = "API Key（可留空）"
        aiAPIKeyField.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        for field in [aiBaseURLField, aiModelField, aiAPIKeyField] {
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalToConstant: 420).isActive = true
        }
        aiConfigurationStatus.font = .systemFont(ofSize: 11)
        aiConfigurationStatus.textColor = .tertiaryLabelColor
        aiConfigurationStatus.lineBreakMode = .byTruncatingTail

        appearancePopUp.removeAllItems()
        for mode in RimeAppearanceMode.allCases {
            appearancePopUp.addItem(withTitle: mode.title)
            appearancePopUp.lastItem?.representedObject = mode.rawValue
        }
        appearancePopUp.target = self
        appearancePopUp.action = #selector(appearanceChosen)
        configureCandidateMetricControls()
        configureChordControl()

        statsDatePicker.datePickerElements = [.yearMonthDay]
        statsDatePicker.datePickerStyle = .textFieldAndStepper
        statsDatePicker.dateValue = Date()
        statsDatePicker.target = self
        statsDatePicker.action = #selector(statsDateChanged)

        statsSummary.font = .systemFont(ofSize: 13, weight: .semibold)
        statsTopKey.font = .systemFont(ofSize: 12)
        statsTopKey.textColor = .secondaryLabelColor
        installStatus.font = .systemFont(ofSize: 11)
        installStatus.textColor = .tertiaryLabelColor
        heatmapView.translatesAutoresizingMaskIntoConstraints = false
        heatmapView.heightAnchor.constraint(greaterThanOrEqualToConstant: 330).isActive = true

        remoteCheck.target = self
        remoteCheck.action = #selector(remoteToggled)
        remoteNameField.placeholderString = Host.current().localizedName ?? "Mac"
        remoteNameField.translatesAutoresizingMaskIntoConstraints = false
        remoteNameField.widthAnchor.constraint(equalToConstant: 220).isActive = true
        remoteStatusLabel.font = .systemFont(ofSize: 12)
        remoteStatusLabel.textColor = .secondaryLabelColor
        remoteDevicesStack.orientation = .vertical
        remoteDevicesStack.alignment = .leading
        remoteDevicesStack.spacing = 6

        pluginStatusLabel.font = .systemFont(ofSize: 11)
        pluginStatusLabel.textColor = .secondaryLabelColor
        pluginStatusLabel.lineBreakMode = .byTruncatingTail

        pluginRowsStack.orientation = .vertical
        pluginRowsStack.alignment = .width
        pluginRowsStack.distribution = .fill
        pluginRowsStack.spacing = 6
        pluginRowsStack.translatesAutoresizingMaskIntoConstraints = false
        pluginRowsStack.setContentHuggingPriority(.required, for: .vertical)
        pluginRowsStack.setContentCompressionResistancePriority(.required, for: .vertical)
        pluginRowsStack.widthAnchor.constraint(equalToConstant: 650).isActive = true
    }

    private func configureCandidateMetricControls() {
        for metric in CandidateWindowMetric.allCases {
            let formatter = NumberFormatter()
            formatter.minimumFractionDigits = 0
            formatter.maximumFractionDigits = 0
            formatter.allowsFloats = false
            formatter.minimum = NSNumber(value: metric.range.lowerBound)
            formatter.maximum = NSNumber(value: metric.range.upperBound)

            let field = NSTextField(string: "")
            field.formatter = formatter
            field.alignment = .right
            field.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            field.target = self
            field.action = #selector(candidateMetricFieldChanged(_:))
            field.delegate = self
            field.tag = metric.tag
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalToConstant: 52).isActive = true

            let slider = NSSlider(value: metric.defaultValue,
                                  minValue: metric.range.lowerBound,
                                  maxValue: metric.range.upperBound,
                                  target: self,
                                  action: #selector(candidateMetricSliderChanged(_:)))
            slider.isContinuous = true
            slider.tag = metric.tag
            slider.translatesAutoresizingMaskIntoConstraints = false
            slider.widthAnchor.constraint(equalToConstant: 190).isActive = true

            let hint = NSTextField(labelWithString: "")
            hint.font = .systemFont(ofSize: 10)
            hint.textColor = .tertiaryLabelColor
            hint.isHidden = true

            candidateMetricFields[metric] = field
            candidateMetricSliders[metric] = slider
            candidateMetricHints[metric] = hint
        }
    }

    private func configureChordControl() {
        let formatter = NumberFormatter()
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        formatter.allowsFloats = true
        formatter.minimum = NSNumber(value: ChordSettings.range.lowerBound)
        formatter.maximum = NSNumber(value: ChordSettings.range.upperBound)

        chordDurationField.formatter = formatter
        chordDurationField.alignment = .right
        chordDurationField.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        chordDurationField.target = self
        chordDurationField.action = #selector(chordDurationFieldChanged)
        chordDurationField.delegate = self
        chordDurationField.translatesAutoresizingMaskIntoConstraints = false
        chordDurationField.widthAnchor.constraint(equalToConstant: 64).isActive = true

        chordDurationStepper.minValue = ChordSettings.range.lowerBound
        chordDurationStepper.maxValue = ChordSettings.range.upperBound
        chordDurationStepper.increment = 0.01
        chordDurationStepper.valueWraps = false
        chordDurationStepper.target = self
        chordDurationStepper.action = #selector(chordDurationStepperChanged)
    }

    private var selectedRoute: SettingsRouteDescriptor? {
        routeCatalog.route(for: navigation.currentRouteID)
    }

    private var selectedCoreRoute: SettingsCoreRoute? {
        guard case let .core(route)? = selectedRoute?.source else { return nil }
        return route
    }

    private var selectedBuiltInPluginID: String? {
        guard case let .builtInPlugin(key)? = selectedRoute?.source else { return nil }
        return key.rawID
    }

    private func rebuildRouteCatalog() {
        do {
            let next = try SettingsRouteCatalog(
                pluginContributions: PluginRegistry.shared.enabledSettingsContributions()
            )
            routeCatalog = next
            navigation.reconcile(with: next)
            if window != nil { rebuildSidebar() }
        } catch {
            IMELog.write("settings route catalog rejected: \(error)")
        }
    }

    private func rebuildSidebar() {
        sidebar.arrangedSubviews.forEach {
            sidebar.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        navButtons.removeAll()
        for (sectionIndex, section) in routeCatalog.sections.enumerated() {
            sidebar.addArrangedSubview(
                sidebarGroupHeader(section.title, first: sectionIndex == 0)
            )
            for route in section.routes {
                let button = SettingsRouteButton(
                    title: route.title,
                    target: self,
                    action: #selector(routeChosen(_:))
                )
                button.routeID = route.id
                button.bezelStyle = .regularSquare
                button.isBordered = false
                button.alignment = .left
                button.font = .systemFont(ofSize: 13, weight: .medium)
                button.image = NSImage(systemSymbolName: route.symbolName,
                                       accessibilityDescription: route.title)
                button.imagePosition = .imageLeading
                button.imageHugsTitle = true
                button.wantsLayer = true
                button.layer?.cornerRadius = 7
                button.translatesAutoresizingMaskIntoConstraints = false
                button.widthAnchor.constraint(equalToConstant: 136).isActive = true
                button.heightAnchor.constraint(equalToConstant: 32).isActive = true
                sidebar.addArrangedSubview(button)
                navButtons[route.id] = button
            }
        }
        sidebar.addArrangedSubview(flexSpacer())
        refreshSidebarSelection()
    }

    private func refreshSidebarSelection() {
        for (routeID, button) in navButtons {
            let selected = routeID == navigation.currentRouteID
            button.state = selected ? .on : .off
            button.contentTintColor = selected ? .labelColor : .secondaryLabelColor
            button.layer?.backgroundColor = selected
                ? NSColor.controlAccentColor.withAlphaComponent(0.13).cgColor
                : NSColor.clear.cgColor
        }
    }

    private func showCurrentRoute() {
        guard let route = selectedRoute else { return }
        refreshSidebarSelection()
        activePluginSettingsController = nil
        contentHost.subviews.forEach { $0.removeFromSuperview() }

        let subpageID = navigation.selectedSubpage()?.rawValue
        let body: NSView
        switch route.source {
        case let .core(core):
            body = makeCorePage(core, subpageID: subpageID)
        case let .builtInPlugin(pluginKey):
            if let subpageID,
               let controller = PluginRegistry.shared.makeSettingsViewController(
                    pluginKey: pluginKey,
                    subpageID: subpageID
               ) {
                activePluginSettingsController = controller
                body = controller.view
            } else {
                body = contentColumn([
                    title(route.title),
                    caption("扩展页面当前不可用，可在“插件”中重新启用。"),
                ])
            }
        }

        let pageView = pageShell(route: route, body: body)
        pageView.translatesAutoresizingMaskIntoConstraints = false
        contentHost.addSubview(pageView)
        NSLayoutConstraint.activate([
            pageView.leadingAnchor.constraint(equalTo: contentHost.leadingAnchor),
            pageView.trailingAnchor.constraint(equalTo: contentHost.trailingAnchor),
            pageView.topAnchor.constraint(equalTo: contentHost.topAnchor),
            pageView.bottomAnchor.constraint(equalTo: contentHost.bottomAnchor),
        ])

        switch route.source {
        case .core(.appearance): refreshCandidateMetricControls()
        case .core(.connectors): refreshRemoteStatus()
        case .core(.plugins): refreshPluginList()
        case .builtInPlugin(let key) where key.rawID == BuiltInPluginID.statistics:
            refreshStats()
        default: break
        }
    }

    private func makeCorePage(_ route: SettingsCoreRoute,
                              subpageID: String?) -> NSView {
        switch route {
        case .inputMethod: return inputPage(subpageID: subpageID ?? "encoding")
        case .appearance: return appearancePage(subpageID: subpageID ?? "candidate-window")
        case .buffer: return bufferPage(subpageID: subpageID ?? "general")
        case .connectors: return connectionsPage(subpageID: subpageID ?? "remote-typing")
        case .plugins: return pluginsPage(subpageID: subpageID ?? "all")
        case .maintenance: return maintenancePage(subpageID: subpageID ?? "update-restart")
        }
    }

    private func pageShell(route: SettingsRouteDescriptor, body: NSView) -> NSView {
        let tabs = NSSegmentedControl(
            labels: route.subpages.map(\.title),
            trackingMode: .selectOne,
            target: self,
            action: #selector(subpageChosen(_:))
        )
        tabs.segmentStyle = .automatic
        if let selected = navigation.selectedSubpage(),
           let index = route.subpages.firstIndex(where: { $0.id == selected }) {
            tabs.selectedSegment = index
        }

        let tabsRow = NSStackView(views: [tabs, flexSpacer()])
        tabsRow.orientation = .horizontal
        tabsRow.alignment = .centerY
        tabsRow.edgeInsets = NSEdgeInsets(top: 12, left: 24, bottom: 10, right: 24)

        let bodyHost: NSView
        if body is NSScrollView {
            // Page-owned controllers may preserve their own scroll positions;
            // do not nest them in another scroll view with zero intrinsic height.
            bodyHost = body
        } else {
            let scroll = NSScrollView()
            scroll.drawsBackground = false
            scroll.hasVerticalScroller = true
            scroll.autohidesScrollers = true
            let document = SettingsPageDocumentView()
            scroll.documentView = document
            document.translatesAutoresizingMaskIntoConstraints = false
            body.translatesAutoresizingMaskIntoConstraints = false
            document.addSubview(body)
            NSLayoutConstraint.activate([
                document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
                document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
                document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
                document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
                body.leadingAnchor.constraint(equalTo: document.leadingAnchor),
                body.trailingAnchor.constraint(equalTo: document.trailingAnchor),
                body.topAnchor.constraint(equalTo: document.topAnchor),
                body.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            ])
            bodyHost = scroll
        }

        let root = NSStackView(views: [tabsRow, bodyHost])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 0
        tabsRow.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        bodyHost.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        bodyHost.setContentHuggingPriority(.defaultLow, for: .vertical)
        bodyHost.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return root
    }

    private func sidebarGroupHeader(_ title: String, first: Bool) -> NSView {
        let label = NSTextField(labelWithString: title.uppercased())
        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.textColor = .tertiaryLabelColor
        let wrap = NSStackView(views: [label])
        wrap.orientation = .horizontal
        wrap.edgeInsets = NSEdgeInsets(top: first ? 2 : 12, left: 6, bottom: 4, right: 6)
        return wrap
    }

    private func inputPage(subpageID: String) -> NSView {
        let openDirBtn = NSButton(title: "打开配置目录", target: self, action: #selector(openDir))
        let note = NSTextField(wrappingLabelWithString:
            "配置目录是 ~/Library/RimeBuffer。未显示的方案文件仅作为词典或反查依赖保留，不会出现在 F4。")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .tertiaryLabelColor

        let chordNote = NSTextField(wrappingLabelWithString:
            "飞耀方案使用此间隔划分每一击；并击只组合当前时间窗内的按键，单侧击也会正常结算；互击还允许相邻的左侧声母与右侧韵母跨击配对。默认 0.10 秒，修改后立即生效。")
        chordNote.font = .systemFont(ofSize: 11)
        chordNote.textColor = .tertiaryLabelColor

        switch subpageID {
        case "typing-mode":
            return contentColumn([
                title("键入模式"),
                spacer(8),
                keyingModeSelectionView(),
                spacer(16),
                sectionLabel("飞耀组键间隔"),
                chordDurationRow(),
                chordNote,
            ])
        case "dictionaries":
            let learning = NSTextField(wrappingLabelWithString:
                "Rime 会在独立的 ~/Library/RimeBuffer 中学习词频。这里导入、导出的只是可移植学习记录，不会复制或替换正在使用的 LevelDB。")
            learning.font = .systemFont(ofSize: 11)
            learning.textColor = .tertiaryLabelColor
            return contentColumn([
                title("词库"),
                caption("词库负责候选内容；输入编码与键入模式只决定如何检索它。"),
                spacer(8),
                sectionLabel("已安装词库"),
                lexiconCard(kind: .chinese,
                            title: "雾凇拼音",
                            detail: "中文主词库 · 全拼、自然码双拼、飞耀互击共享"),
                lexiconCard(kind: .english,
                            title: "Easy English",
                            detail: "英文候选、补全、生词兜底与独立学习"),
                spacer(16),
                sectionLabel("用户学习"),
                learning,
                openDirBtn,
                note,
            ])
        default:
            return contentColumn([
                title("输入编码"),
                caption("单独轻点 Shift 切换中英；Shift 与字母/标点组合或持续按住 500 ms 后，会保持按下前的输入模式。"),
                spacer(8),
                inputEncodingSelectionView(),
            ])
        }
    }

    private func inputModeCard(title: String,
                               detail: String,
                               active: Bool,
                               inactiveLabel: String = "规划中") -> NSView {
        let name = NSTextField(labelWithString: title)
        name.font = .systemFont(ofSize: 13, weight: .semibold)
        let status = NSTextField(labelWithString: active ? "可用" : inactiveLabel)
        status.font = .systemFont(ofSize: 10, weight: .medium)
        status.textColor = active ? .systemGreen : .tertiaryLabelColor
        let detailLabel = NSTextField(wrappingLabelWithString: detail)
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        let header = NSStackView(views: [name, flexSpacer(), status])
        header.orientation = .horizontal
        let card = NSStackView(views: [header, detailLabel])
        card.orientation = .vertical
        card.alignment = .leading
        card.spacing = 5
        card.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.65).cgColor
        card.layer?.cornerRadius = 8
        card.translatesAutoresizingMaskIntoConstraints = false
        card.widthAnchor.constraint(equalToConstant: 600).isActive = true
        header.widthAnchor.constraint(equalTo: card.widthAnchor, constant: -24).isActive = true
        detailLabel.widthAnchor.constraint(equalTo: card.widthAnchor, constant: -24).isActive = true
        card.alphaValue = active ? 1 : 0.68
        return card
    }

    private func dictionaryCard(title: String, detail: String) -> NSView {
        inputModeCard(title: title, detail: detail, active: true)
    }

    private func lexiconCard(kind: UserLexiconKind,
                             title: String,
                             detail: String) -> NSView {
        let status = UserLexiconService.shared.status(for: kind)
        let name = NSTextField(labelWithString: title)
        name.font = .systemFont(ofSize: 13, weight: .semibold)

        let statusLabel = NSTextField(labelWithString:
            status.hasLearningDatabase ? "学习库已建立" : "尚未建立学习库")
        statusLabel.font = .systemFont(ofSize: 10, weight: .medium)
        statusLabel.textColor = status.hasLearningDatabase ? .systemGreen : .tertiaryLabelColor

        let detailLabel = NSTextField(wrappingLabelWithString: detail)
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor

        let importButton = SettingsLexiconButton(title: "导入学习…",
                                                  target: self,
                                                  action: #selector(importUserLexicon(_:)))
        importButton.lexiconKind = kind
        importButton.controlSize = .small

        let exportButton = SettingsLexiconButton(title: "导出学习…",
                                                  target: self,
                                                  action: #selector(exportUserLexicon(_:)))
        exportButton.lexiconKind = kind
        exportButton.controlSize = .small
        exportButton.isEnabled = status.hasLearningDatabase

        let header = NSStackView(views: [name, flexSpacer(), statusLabel])
        header.orientation = .horizontal
        header.alignment = .centerY
        let actions = NSStackView(views: [importButton, exportButton, flexSpacer()])
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = 7

        let card = NSStackView(views: [header, detailLabel, actions])
        card.orientation = .vertical
        card.alignment = .leading
        card.spacing = 7
        card.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.65).cgColor
        card.layer?.cornerRadius = 8
        card.translatesAutoresizingMaskIntoConstraints = false
        card.widthAnchor.constraint(equalToConstant: 600).isActive = true
        for arrangedView in card.arrangedSubviews {
            arrangedView.widthAnchor.constraint(equalTo: card.widthAnchor,
                                                 constant: -24).isActive = true
        }
        return card
    }

    private func chordDurationRow() -> NSView {
        let label = NSTextField(labelWithString: "组键间隔")
        label.alignment = .right
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: 96).isActive = true

        let unit = NSTextField(labelWithString: "秒")
        unit.font = .systemFont(ofSize: 11)
        unit.textColor = .tertiaryLabelColor
        unit.translatesAutoresizingMaskIntoConstraints = false
        unit.widthAnchor.constraint(equalToConstant: 24).isActive = true

        let resetBtn = NSButton(title: "恢复默认", target: self, action: #selector(resetChordDuration))
        resetBtn.bezelStyle = .rounded

        chordDurationField.removeFromSuperview()
        chordDurationStepper.removeFromSuperview()
        let row = NSStackView(views: [label, chordDurationField, chordDurationStepper, unit, resetBtn])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        return row
    }

    private func inputEncodingSelectionView() -> NSView {
        radioSelectionView(InputEncoding.allCases.compactMap { encoding in
            guard let button = encodingRadios[encoding] else { return nil }
            return button
        })
    }

    private func keyingModeSelectionView() -> NSView {
        radioSelectionView(KeyingMode.allCases.compactMap { mode in
            guard let button = keyingModeRadios[mode] else { return nil }
            return button
        })
    }

    private func radioSelectionView(_ buttons: [NSButton]) -> NSView {
        buttons.forEach { $0.removeFromSuperview() }
        let stack = NSStackView(views: buttons)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        return stack
    }

    private func appearancePage(subpageID: String) -> NSView {
        if subpageID == "theme" {
            appearancePopUp.removeFromSuperview()
            return contentColumn([
                title("主题"),
                caption("主题同时作用于候选窗、缓冲工作台和设置页中的输入法预览。"),
                spacer(8),
                sectionLabel("显示模式"),
                appearancePopUp,
                spacer(12),
                inputModeCard(title: "明亮", detail: "浅色表面、深色正文和高对比度边界。", active: true),
                inputModeCard(title: "暗色", detail: "深色表面、浅色正文；菜单和状态文字使用独立层级色。", active: true),
            ])
        }
        let preview = CandidatePreviewView(maxWidth: 620)
        candidatePreview = preview
        return contentColumn([
            title("候选窗"),
            caption("拖动滑块即时预览效果；滑块灰色区间表示当前不支持（受关联项限制），无法调整。"),
            spacer(8),
            sectionLabel("实时预览"),
            preview,
            spacer(16),
            sectionLabel("尺寸与文字"),
            candidateMetricsView(),
        ])
    }

    private func bufferPage(subpageID: String) -> NSView {
        let note = NSTextField(wrappingLabelWithString:
            "缓冲区开启后，Rime 提交内容会进入单行缓冲条；轻按 Enter 或点击右侧纸飞机发送下一块，按住 Enter 约 1.2 秒发送全部。AI 生成插件会复用右侧主按钮和 Enter 请求 AI，结果就绪后再变回逐块发送。成功发送的块会立即消失；失败或未发送的块不会丢失，也不会保存发送历史。")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .tertiaryLabelColor

        let resetNote = NSTextField(wrappingLabelWithString:
            "默认跨应用保留。开启后，仅当整个缓冲都来自本地输入时，切到其他应用会不可撤销地清空内容；只要混有外部来源块就整体保留。")
        resetNote.font = .systemFont(ofSize: 11)
        resetNote.textColor = .tertiaryLabelColor

        let secureNote = NSTextField(wrappingLabelWithString:
            "安全：当系统安全输入生效时，工作台会隐藏正文，并禁用发送与插件操作。此保护始终开启。")
        secureNote.font = .systemFont(ofSize: 11)
        secureNote.textColor = .tertiaryLabelColor

        if subpageID == "workbench" {
            return contentColumn([
                title("缓冲工作台"),
                caption("独立、可拖动、可常显的缓冲区窗口；关闭只暂停捕获，不删除已有块。"),
                spacer(8),
                sectionLabel("窗口"),
                bufferWindowVisibleCheck,
                bufferPinnedCheck,
                secondaryLabel("候选显示位置"),
                candidatePlacementPopUp,
                moveBufferWindowButton,
                caption("顶部功能栏始终展开；可拖动其空白区域移动工作台，按钮和下拉框仍保持正常点击。"),
            ])
        }
        return contentColumn([
            title("缓冲区"),
            caption("把提交内容先暂存，再由你确认发送到当前输入框。"),
            spacer(8),
            sectionLabel("模式"),
            bufferCheck,
            note,
            spacer(16),
            sectionLabel("安全与清理"),
            resetOnAppSwitchCheck,
            resetNote,
            spacer(8),
            secureNote,
        ])
    }

    private func connectionsPage(subpageID: String) -> NSView {
        if subpageID == "ai-model" {
            return aiModelConnectionsPage()
        }
        let applyNameBtn = NSButton(title: "应用名称", target: self, action: #selector(applyRemoteName))
        let nameRow = NSStackView(views: [remoteNameField, applyNameBtn])
        nameRow.orientation = .horizontal
        nameRow.alignment = .centerY
        nameRow.spacing = 8

        let sourcesNote = NSTextField(wrappingLabelWithString:
            "标准 MCP（Streamable HTTP，2025-06-18）端点，任何 MCP 客户端／智能体都能接入——"
            + "把文字送进缓冲区收件箱，需你逐条确认后才成为可发送的块。")
        sourcesNote.font = .systemFont(ofSize: 11)
        sourcesNote.textColor = .tertiaryLabelColor

        let cliNote = NSTextField(wrappingLabelWithString:
            "或用 Claude Code 命令行一键注册（等价于上面的配置）：")
        cliNote.font = .systemFont(ofSize: 11)
        cliNote.textColor = .tertiaryLabelColor

        let laterSources = NSStackView(views: [
            comingSoonRow("SSE 订阅", "订阅外部事件流，流式进缓冲区", "M6"),
            comingSoonRow("SSH", "远程主机命令输出流式进缓冲区", "M6"),
        ])
        laterSources.orientation = .vertical
        laterSources.alignment = .leading
        laterSources.spacing = 8

        if subpageID == "local-gateway" {
            return contentColumn([
                title("本地网关"),
                caption("让本机智能体和工具把内容送入缓冲区收件箱；所有内容仍需手动确认。"),
                spacer(8),
                sectionLabel("MCP / HTTP 接入"),
                gatewayEnableCheck,
                sourcesNote,
                spacer(6),
                secondaryLabel("接入配置（标准 MCP，任意客户端通用）"),
                gatewayConfigField,
                gatewayCopyConfigButton,
                spacer(10),
                cliNote,
                gatewayCommandField,
                gatewayCopyButton,
                spacer(16),
                sectionLabel("更多来源"),
                laterSources,
            ])
        }
        return contentColumn([
            title("隔空传字"),
            caption("在受信任的 Mac 之间发送文字；配对关系和设备名称在这里维护。"),
            spacer(8),
            remoteCheck,
            remoteStatusLabel,
            spacer(8),
            secondaryLabel("本机名称"),
            nameRow,
            spacer(6),
            secondaryLabel("设备"),
            remoteDevicesStack,
        ])
    }

    private func aiModelConnectionsPage() -> NSView {
        let connectors = AITextConnectorRegistry.shared
        let codexAvailability = connectors.availability(for: .codexCLI)
        let claudeAvailability = connectors.availability(for: .claudeCodeCLI)
        let codexReady = codexAvailability == .ready
        let claudeReady = claudeAvailability == .ready
        let codexDetail: String
        switch codexAvailability {
        case .ready:
            codexDetail = "使用 \(ProductIdentity.displayName) 专用的 ChatGPT 登录；不会读取 ~/.codex 中的 MCP、工具、Hook 或技能。"
        case let .unavailable(message):
            codexDetail = message
        }
        let claudeDetail: String
        switch claudeAvailability {
        case .ready:
            claudeDetail = "使用本机已登录的 claude 命令行；工具调用与会话持久化被关闭。"
        case let .unavailable(message):
            claudeDetail = message
        }
        refreshCodexLoginControls(
            hasCredential: connectors.codexHasStoredChatGPTCredential
        )
        refreshClaudeLoginControls(
            authenticationStatus: connectors.claudeAuthenticationStatus
        )
        codexLoginButton.removeFromSuperview()
        codexCopyLoginLinkButton.removeFromSuperview()
        codexLoginSpinner.removeFromSuperview()
        codexLoginStatusLabel.removeFromSuperview()
        let codexLoginActions = NSStackView(views: [
            codexLoginButton,
            codexCopyLoginLinkButton,
            codexLoginSpinner,
            flexSpacer(),
        ])
        codexLoginActions.orientation = .horizontal
        codexLoginActions.alignment = .centerY
        codexLoginActions.spacing = 8
        claudeLoginButton.removeFromSuperview()
        claudeLoginSpinner.removeFromSuperview()
        claudeLoginStatusLabel.removeFromSuperview()
        let claudeLoginActions = NSStackView(views: [
            claudeLoginButton,
            claudeLoginSpinner,
            flexSpacer(),
        ])
        claudeLoginActions.orientation = .horizontal
        claudeLoginActions.alignment = .centerY
        claudeLoginActions.spacing = 8
        let save = NSButton(title: "保存配置",
                            target: self,
                            action: #selector(saveAIModelConfiguration))
        let clearKey = NSButton(title: "清除密钥",
                                target: self,
                                action: #selector(clearAIModelAPIKey))
        let actions = NSStackView(views: [save, clearKey])
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = 8

        let privacy = NSTextField(wrappingLabelWithString:
            "Codex CLI 与 Claude Code CLI 在本机启动，但并不代表本地推理：点击生成后，缓冲区全文会通过所选 CLI 的授权状态发送。\(ProductIdentity.displayName) 不会把环境中的 API Key 透传给这两个 CLI。通用 Open API（OpenAI 兼容）连接器只会在你点击生成时把全文发送到这里配置的端点。")
        privacy.font = .systemFont(ofSize: 11)
        privacy.textColor = .tertiaryLabelColor

        let keyNote = NSTextField(wrappingLabelWithString:
            "Base URL 应包含 API 前缀（例如 /v1），程序会追加 /chat/completions。远程地址必须使用 HTTPS；HTTP 仅允许 localhost、127.0.0.1 或 ::1。密钥保存在权限为 0600 的本地配置文件，不写入偏好设置或日志。")
        keyNote.font = .systemFont(ofSize: 11)
        keyNote.textColor = .tertiaryLabelColor

        return contentColumn([
            title("AI 模型"),
            caption("“AI 生成”是一个统一缓冲插件；在这里切换它使用的模型连接器。生成结果进入独立下层缓冲区，由你确认后发送。"),
            spacer(8),
            sectionLabel("当前连接器"),
            aiConnectorSelectionView(),
            spacer(12),
            sectionLabel("本地 CLI"),
            inputModeCard(title: "Codex CLI",
                          detail: codexDetail,
                          active: codexReady,
                          inactiveLabel: "不可用"),
            codexLoginActions,
            codexLoginStatusLabel,
            inputModeCard(title: "Claude Code CLI",
                          detail: claudeDetail,
                          active: claudeReady,
                          inactiveLabel: "不可用"),
            claudeLoginActions,
            claudeLoginStatusLabel,
            privacy,
            spacer(16),
            sectionLabel("通用 Open API（OpenAI 兼容 Chat Completions）"),
            labeledSettingsRow("Base URL", control: aiBaseURLField),
            labeledSettingsRow("模型", control: aiModelField),
            labeledSettingsRow("API Key", control: aiAPIKeyField),
            actions,
            aiConfigurationStatus,
            keyNote,
        ])
    }

    private func aiConnectorSelectionView() -> NSView {
        refreshAIConnectorSelection()
        return radioSelectionView(AITextProviderKind.allCases.compactMap { kind in
            aiConnectorRadios[kind]
        })
    }

    private func labeledSettingsRow(_ labelText: String, control: NSView) -> NSView {
        control.removeFromSuperview()
        let label = NSTextField(labelWithString: labelText)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.alignment = .right
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: 76).isActive = true
        let row = NSStackView(views: [label, control])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        return row
    }

    /// Client-agnostic MCP server config — the `mcpServers` shape Claude Desktop,
    /// Cursor, Cline, VS Code and most agents read. Any client that speaks
    /// Streamable HTTP can drop this in.
    private func gatewayConfigJSON() -> String {
        """
        {
          "mcpServers": {
            "etinput": {
              "type": "http",
              "url": "http://127.0.0.1:\(LocalGateway.shared.port)/mcp",
              "headers": {
                "Authorization": "Bearer \(GatewayToken.current())"
              }
            }
          }
        }
        """
    }

    private func gatewayCommand() -> String {
        "claude mcp add --transport http etinput http://127.0.0.1:\(LocalGateway.shared.port)/mcp "
            + "--header \"Authorization: Bearer \(GatewayToken.current())\""
    }

    @objc private func gatewayToggled() {
        LocalGateway.shared.enabled = gatewayEnableCheck.state == .on
    }

    @objc private func copyGatewayConfig() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(gatewayConfigJSON(), forType: .string)
    }

    @objc private func copyGatewayCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(gatewayCommand(), forType: .string)
    }

    @objc private func saveAIModelConfiguration() {
        window?.makeFirstResponder(nil)
        do {
            let previous = try OpenAICompatibleConfigurationStore.shared.load()
            let enteredKey = aiAPIKeyField.stringValue
            let configuration = OpenAICompatibleConfiguration(
                baseURL: aiBaseURLField.stringValue,
                model: aiModelField.stringValue,
                apiKey: enteredKey.isEmpty ? (previous?.apiKey ?? "") : enteredKey
            )
            try OpenAICompatibleConfigurationStore.shared.save(configuration)
            refreshAIModelConfiguration(statusMessage: "通用 Open API 配置已保存")
        } catch let error as AITextProviderError {
            refreshAIModelConfiguration(statusMessage: error.userFacingMessage,
                                        isError: true)
        } catch {
            refreshAIModelConfiguration(statusMessage: "保存失败，请检查本地目录权限",
                                        isError: true)
        }
    }

    @objc private func clearAIModelAPIKey() {
        window?.makeFirstResponder(nil)
        do {
            guard var configuration = try OpenAICompatibleConfigurationStore.shared.load() else {
                refreshAIModelConfiguration(statusMessage: "当前没有已保存的密钥")
                return
            }
            configuration.apiKey = ""
            try OpenAICompatibleConfigurationStore.shared.save(configuration)
            refreshAIModelConfiguration(statusMessage: "已清除本地 API Key")
        } catch {
            refreshAIModelConfiguration(statusMessage: "清除失败，请检查本地目录权限",
                                        isError: true)
        }
    }

    private func pluginsPage(subpageID: String) -> NSView {
        let installButton = NSButton(title: "安装…",
                                     target: self,
                                     action: #selector(showPluginInstallDialog))
        let uninstallButton = NSButton(title: "卸载…",
                                       target: self,
                                       action: #selector(showPluginUninstallDialog))
        let manageButton = NSButton(title: "管理…",
                                    target: self,
                                    action: #selector(showPluginManagementDialog))
        for button in [installButton, uninstallButton, manageButton] {
            button.controlSize = .small
        }
        let actions = NSStackView(views: [installButton, uninstallButton, manageButton])
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = 6

        let heading = NSStackView(views: [title("插件"), flexSpacer(), actions])
        heading.orientation = .horizontal
        heading.alignment = .centerY
        heading.spacing = 12
        heading.translatesAutoresizingMaskIntoConstraints = false
        heading.widthAnchor.constraint(equalToConstant: 650).isActive = true

        pluginRowsStack.removeFromSuperview()
        let note = NSTextField(wrappingLabelWithString:
            "可以同时开启多个缓冲插件；只有已开启的插件会出现在缓冲工作台，当前使用项仍在工作台中切换。")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .tertiaryLabelColor

        let showExternal = subpageID == "all" || subpageID == "buffer-plugins"
        let showBuiltIns = subpageID == "all" || subpageID == "built-in-extensions"
        var views: [NSView] = [
            heading,
            caption("在这里管理工作台可用的缓冲插件，或管理随应用提供的内部扩展。"),
            spacer(8),
        ]
        if showBuiltIns {
            let rows = NSStackView()
            rows.orientation = .vertical
            rows.alignment = .width
            rows.spacing = 6
            let builtIns = PluginRegistry.shared.plugins(source: .builtIn).filter {
                !$0.descriptor.capabilities.contains(.bufferAction)
            }
            for plugin in builtIns {
                rows.addArrangedSubview(pluginRow(plugin, mode: .enablement))
            }
            views.append(sectionLabel("内置扩展"))
            views.append(rows)
            if showExternal { views.append(spacer(16)) }
        }
        if showExternal {
            views.append(sectionLabel("缓冲插件"))
            views.append(note)
            views.append(pluginRowsStack)
            views.append(pluginStatusLabel)
        }
        return pluginContentColumn(views)
    }

    private func pluginRow(_ plugin: RegisteredPlugin,
                           mode: SettingsPluginSwitchMode) -> NSView {
        let icon = NSImageView()
        icon.image = PluginVisualIdentity.image(
            symbolName: plugin.descriptor.symbolName,
            accessibilityDescription: plugin.descriptor.name,
            pointSize: 15,
            weight: .semibold
        )
        icon.imageScaling = .scaleProportionallyDown
        icon.contentTintColor = .secondaryLabelColor
        icon.toolTip = plugin.descriptor.name
        // The adjacent name is the semantic label; keep this decorative image
        // out of the VoiceOver traversal so the row is not announced twice.
        icon.setAccessibilityElement(false)
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 22),
            icon.heightAnchor.constraint(equalToConstant: 22),
        ])
        icon.setContentHuggingPriority(.required, for: .horizontal)
        icon.setContentCompressionResistancePriority(.required, for: .horizontal)

        let name = NSTextField(labelWithString: plugin.descriptor.name)
        name.font = .systemFont(ofSize: 13, weight: .semibold)
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let version = NSTextField(labelWithString: "v\(plugin.descriptor.version)")
        version.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        version.textColor = .tertiaryLabelColor
        version.setContentHuggingPriority(.required, for: .horizontal)

        let titleRow = NSStackView(views: [name, version])
        titleRow.orientation = .horizontal
        titleRow.alignment = .firstBaseline
        titleRow.spacing = 6

        let detail = NSTextField(labelWithString: plugin.descriptor.summary)
        detail.font = .systemFont(ofSize: 10)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        detail.toolTip = plugin.descriptor.summary
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let labels = NSStackView(views: [titleRow, detail])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 2
        labels.setContentHuggingPriority(.defaultLow, for: .horizontal)
        labels.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let toggle = SettingsPluginSwitch(frame: .zero)
        toggle.pluginKey = plugin.descriptor.key
        toggle.mode = mode
        toggle.state = plugin.isEnabled ? .on : .off
        toggle.controlSize = .small
        toggle.target = self
        toggle.action = #selector(pluginSwitchToggled(_:))
        toggle.toolTip = mode == .bufferEnablement
            ? (toggle.state == .on
                ? "停用插件并从工作台移除"
                : "启用插件并加入工作台")
            : (toggle.state == .on ? "停用扩展" : "启用扩展")
        toggle.setContentHuggingPriority(.required, for: .horizontal)

        var rowViews: [NSView] = [icon, labels, flexSpacer()]
        if PluginRegistry.shared.hasConfiguration(
            for: plugin.descriptor.key
        ) {
            let configure = SettingsPluginConfigurationButton(
                title: "设置…",
                target: self,
                action: #selector(configureBufferPlugin(_:))
            )
            configure.pluginKey = plugin.descriptor.key
            configure.controlSize = .small
            configure.toolTip = "配置 \(plugin.descriptor.name)"
            configure.setContentHuggingPriority(.required, for: .horizontal)
            rowViews.append(configure)
        }
        rowViews.append(toggle)

        let row = NSStackView(views: rowViews)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.edgeInsets = NSEdgeInsets(top: 8, left: 11, bottom: 8, right: 10)
        row.wantsLayer = true
        row.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.72).cgColor
        row.layer?.borderColor = NSColor.separatorColor.cgColor
        row.layer?.borderWidth = 1 / max(window?.backingScaleFactor ?? 2, 1)
        row.layer?.cornerRadius = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: 650).isActive = true
        row.heightAnchor.constraint(equalToConstant: 58).isActive = true
        return row
    }

    private func pluginContentColumn(_ views: [NSView]) -> NSView {
        let column = NSStackView(views: views)
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 8
        column.edgeInsets = NSEdgeInsets(top: 22, left: 24, bottom: 22, right: 24)
        return column
    }

    /// A disabled preview row for a not-yet-built connection/processor, with a
    /// milestone tag so the settings window shows where the workbench is going
    /// without pretending the control works yet.
    private func comingSoonRow(_ name: String, _ detail: String, _ milestone: String) -> NSView {
        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor.tertiaryLabelColor.cgColor
        dot.layer?.cornerRadius = 3
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.widthAnchor.constraint(equalToConstant: 6).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 6).isActive = true

        let nameLabel = NSTextField(labelWithString: name)
        nameLabel.font = .systemFont(ofSize: 13, weight: .medium)
        let detailLabel = NSTextField(labelWithString: detail)
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        let textCol = NSStackView(views: [nameLabel, detailLabel])
        textCol.orientation = .vertical
        textCol.alignment = .leading
        textCol.spacing = 1

        let tag = NSTextField(labelWithString: milestone)
        tag.font = .monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
        tag.textColor = .tertiaryLabelColor

        let row = NSStackView(views: [dot, textCol, flexSpacer(), tag])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: 560).isActive = true
        row.alphaValue = 0.7
        return row
    }

    private func maintenancePage(subpageID: String) -> NSView {
        let checkUpdateBtn = NSButton(title: "检查更新…", target: self, action: #selector(checkUpdate))
        let openLogBtn = NSButton(title: "打开运行日志", target: self, action: #selector(openRuntimeLog))
        let restartBtn = NSButton(title: "重启输入法进程", target: self, action: #selector(restartInputMethod))
        let runtimeButtons = NSStackView(views: [checkUpdateBtn, openLogBtn, restartBtn])
        runtimeButtons.orientation = .horizontal
        runtimeButtons.spacing = 8

        let reinstallBtn = NSButton(title: "重新安装输入法", target: self, action: #selector(reinstallInputMethod))
        let openInstallLogBtn = NSButton(title: "打开安装日志", target: self, action: #selector(openInstallLog))
        let installButtons = NSStackView(views: [reinstallBtn, openInstallLogBtn])
        installButtons.orientation = .horizontal
        installButtons.spacing = 8
        let installNote = NSTextField(wrappingLabelWithString:
            "重新安装会从当前源码目录运行 build_install.sh，构建完成后替换并重启输入法进程。")
        installNote.font = .systemFont(ofSize: 11)
        installNote.textColor = .tertiaryLabelColor

        if subpageID == "logs-data" {
            let openConfigBtn = NSButton(title: "打开 \(ProductIdentity.displayName) 数据目录",
                                         target: self,
                                         action: #selector(openDir))
            let dataNote = NSTextField(wrappingLabelWithString:
                "配置、词库学习、插件、统计和练习进度都只保存在 ~/Library/RimeBuffer。缓冲区正文与发送历史不会持久化。")
            dataNote.font = .systemFont(ofSize: 11)
            dataNote.textColor = .tertiaryLabelColor
            let logButtons = NSStackView(views: [openLogBtn, openInstallLogBtn])
            logButtons.orientation = .horizontal
            logButtons.spacing = 8
            return contentColumn([
                title("日志与数据"),
                caption("查看本地诊断信息和应用数据位置。"),
                spacer(8),
                sectionLabel("日志"),
                logButtons,
                spacer(16),
                sectionLabel("本地数据"),
                openConfigBtn,
                dataNote,
            ])
        }
        return contentColumn([
            title("更新与重启"),
            caption("检查更新、重启输入法进程或从当前源码重新安装。"),
            spacer(8),
            sectionLabel("运行状态"),
            runtimeButtons,
            spacer(12),
            sectionLabel("安装"),
            installButtons,
            installStatus,
            installNote,
        ])
    }

    private func contentColumn(_ views: [NSView]) -> NSView {
        let column = NSStackView(views: views)
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 8
        column.edgeInsets = NSEdgeInsets(top: 22, left: 24, bottom: 22, right: 24)
        return column
    }

    private func title(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = .systemFont(ofSize: 20, weight: .semibold)
        l.alignment = .left
        return l
    }

    private func caption(_ s: String) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: s)
        l.font = .systemFont(ofSize: 12)
        l.textColor = .secondaryLabelColor
        l.alignment = .left
        return l
    }

    private func sectionLabel(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = .systemFont(ofSize: 12, weight: .semibold)
        l.textColor = .secondaryLabelColor
        l.alignment = .left
        return l
    }

    private func secondaryLabel(_ s: String) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: s)
        l.font = .systemFont(ofSize: 11)
        l.textColor = .tertiaryLabelColor
        l.alignment = .left
        return l
    }

    private func spacer(_ h: CGFloat) -> NSView {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.heightAnchor.constraint(equalToConstant: h).isActive = true
        return v
    }

    private func flexSpacer() -> NSView {
        let v = NSView()
        v.setContentHuggingPriority(.defaultLow, for: .horizontal)
        v.setContentHuggingPriority(.defaultLow, for: .vertical)
        return v
    }

    private func candidateMetricsView() -> NSView {
        let rows = CandidateWindowMetric.allCases.map(candidateMetricRow)
        let applyBtn = NSButton(title: "应用修改", target: self, action: #selector(applyCandidateMetrics))
        applyBtn.bezelStyle = .rounded
        applyBtn.bezelColor = .controlAccentColor

        let resetBtn = NSButton(title: "恢复默认", target: self, action: #selector(resetCandidateMetrics))
        resetBtn.bezelStyle = .rounded
        let actions = NSStackView(views: [applyBtn, resetBtn])
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = 8

        let stack = NSStackView(views: rows + [actions])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 7
        return stack
    }

    private func candidateMetricRow(_ metric: CandidateWindowMetric) -> NSView {
        let label = NSTextField(labelWithString: metric.title)
        label.alignment = .right
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: 84).isActive = true

        let unit = NSTextField(labelWithString: metric.unit)
        unit.font = .systemFont(ofSize: 11)
        unit.textColor = .tertiaryLabelColor
        unit.translatesAutoresizingMaskIntoConstraints = false
        unit.widthAnchor.constraint(equalToConstant: 20).isActive = true

        let slider = candidateMetricSliders[metric] ?? NSSlider()
        let field = candidateMetricFields[metric] ?? NSTextField(string: "")
        let hint = candidateMetricHints[metric] ?? NSTextField(labelWithString: "")
        slider.removeFromSuperview()
        field.removeFromSuperview()
        hint.removeFromSuperview()

        let row = NSStackView(views: [label, slider, field, unit, hint])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        return row
    }

    // MARK: State

    private func reload() {
        refreshInputConfigurationSelection()
        bufferCheck.state = BufferModel.shared.enabled ? .on : .off
        bufferWindowVisibleCheck.state = BufferWindowController.shared.isVisible ? .on : .off
        bufferPinnedCheck.state = BufferWindowController.shared.pinned ? .on : .off
        if let index = (0..<candidatePlacementPopUp.numberOfItems).first(where: {
            candidatePlacementPopUp.item(at: $0)?.representedObject as? String
                == BufferWindowController.shared.candidatePlacement.rawValue
        }) {
            candidatePlacementPopUp.selectItem(at: index)
        }
        resetOnAppSwitchCheck.state = BufferModel.shared.resetOnAppSwitch ? .on : .off
        gatewayEnableCheck.state = LocalGateway.shared.enabled ? .on : .off
        gatewayConfigField.stringValue = gatewayConfigJSON()
        gatewayCommandField.stringValue = gatewayCommand()
        refreshAIConnectorSelection()
        refreshAIModelConfiguration()
        if let idx = (0..<appearancePopUp.numberOfItems).first(where: {
            appearancePopUp.item(at: $0)?.representedObject as? String == RimeUI.appearance.rawValue
        }) {
            appearancePopUp.selectItem(at: idx)
        }
        refreshCandidateMetricControls()
        refreshChordDurationControl()
        refreshRemoteStatus()
        refreshStats()
    }

    private func refreshInputConfigurationSelection() {
        let inputConfiguration = InputConfigurationStore.shared.configuration
        for encoding in InputEncoding.allCases {
            encodingRadios[encoding]?.state = inputConfiguration.encoding == encoding ? .on : .off
        }
        for mode in KeyingMode.allCases {
            keyingModeRadios[mode]?.state = inputConfiguration.keyingMode == mode ? .on : .off
        }
    }

    private func refreshAIConnectorSelection() {
        let selected = AITextConnectorSelectionStore.shared.selectedKind
        for kind in AITextProviderKind.allCases {
            aiConnectorRadios[kind]?.state = kind == selected ? .on : .off
        }
    }

    private func refreshAIModelConfiguration(statusMessage: String? = nil,
                                             isError: Bool = false) {
        do {
            let configuration = try OpenAICompatibleConfigurationStore.shared.load()
            aiBaseURLField.stringValue = configuration?.baseURL ?? ""
            aiModelField.stringValue = configuration?.model ?? ""
            aiAPIKeyField.stringValue = ""
            aiAPIKeyField.placeholderString = configuration?.apiKey.isEmpty == false
                ? "已保存（留空保持不变）"
                : "API Key（可留空）"
            if let statusMessage {
                aiConfigurationStatus.stringValue = statusMessage
                aiConfigurationStatus.textColor = isError ? .systemRed : .secondaryLabelColor
            } else {
                aiConfigurationStatus.stringValue = configuration == nil
                    ? "尚未保存通用 Open API 端点"
                    : "配置已保存在本机"
                aiConfigurationStatus.textColor = .tertiaryLabelColor
            }
        } catch {
            aiAPIKeyField.stringValue = ""
            aiAPIKeyField.placeholderString = "无法读取已保存密钥"
            aiConfigurationStatus.stringValue = statusMessage ?? "读取配置失败，请检查本地文件权限"
            aiConfigurationStatus.textColor = .systemRed
        }
    }

    private func refreshCodexLoginControls(hasCredential: Bool? = nil) {
        let authenticated = hasCredential
            ?? AITextConnectorRegistry.shared.codexHasStoredChatGPTCredential
        let isRunning = codexLoginOperation != nil
        codexLoginButton.title = AITextCodexLoginPresentation.buttonTitle(
            isRunning: isRunning,
            hasCredential: authenticated
        )
        codexLoginButton.isEnabled = !codexLoginCancelling
        codexCopyLoginLinkButton.isHidden = codexAuthorizationURL == nil
        if isRunning {
            codexLoginSpinner.startAnimation(nil)
        } else {
            codexLoginSpinner.stopAnimation(nil)
        }
        if let codexLoginFeedback {
            codexLoginStatusLabel.stringValue = codexLoginFeedback
            codexLoginStatusLabel.textColor = codexLoginFeedbackIsError
                ? .systemRed
                : .secondaryLabelColor
        } else {
            codexLoginStatusLabel.stringValue = AITextCodexLoginPresentation.idleMessage(
                hasCredential: authenticated
            )
            codexLoginStatusLabel.textColor = authenticated
                ? .systemGreen
                : .tertiaryLabelColor
        }
    }

    private func codexLoginErrorMessage(_ error: AITextProviderError) -> String {
        switch error {
        case let .unavailable(message), let .invalidConfiguration(message):
            return message
        case .invalidResult:
            return "Codex 登录响应无效，请重试。"
        case .resultTooLarge:
            return "Codex 登录响应异常过大，已安全中止。"
        case .timedOut:
            return "等待 Codex 登录超时，请重新发起授权。"
        case .cancelled:
            return "已取消 Codex 登录。"
        case .failed:
            return "Codex 登录暂时不可用，请重试。"
        }
    }

    private func refreshClaudeLoginControls(authenticationStatus: Bool? = nil) {
        let status = authenticationStatus
            ?? AITextConnectorRegistry.shared.claudeAuthenticationStatus
        let isRunning = claudeLoginOperation != nil
        claudeLoginButton.title = AITextClaudeLoginPresentation.buttonTitle(
            isRunning: isRunning,
            authenticationStatus: status
        )
        claudeLoginButton.isEnabled = !claudeLoginCancelling
        if isRunning {
            claudeLoginSpinner.startAnimation(nil)
        } else {
            claudeLoginSpinner.stopAnimation(nil)
        }
        if let claudeLoginFeedback {
            claudeLoginStatusLabel.stringValue = claudeLoginFeedback
            claudeLoginStatusLabel.textColor = claudeLoginFeedbackIsError
                ? .systemRed
                : .secondaryLabelColor
        } else {
            claudeLoginStatusLabel.stringValue = AITextClaudeLoginPresentation.idleMessage(
                authenticationStatus: status
            )
            claudeLoginStatusLabel.textColor = status == true
                ? .systemGreen
                : .tertiaryLabelColor
        }
    }

    private func claudeLoginErrorMessage(_ error: AITextProviderError) -> String {
        switch error {
        case let .unavailable(message), let .invalidConfiguration(message):
            return message
        case .invalidResult:
            return "Claude 登录响应无效，请重试。"
        case .resultTooLarge:
            return "Claude 登录响应异常过大，已安全中止。"
        case .timedOut:
            return "等待 Claude 登录超时，请重新发起授权。"
        case .cancelled:
            return "已取消 Claude 登录。"
        case .failed:
            return "Claude 登录暂时不可用，请重试。"
        }
    }

    private func refreshPluginList(statusMessage: String? = nil) {
        let plugins = PluginRegistry.shared.plugins(capability: .bufferAction)
        pluginRowsStack.arrangedSubviews.forEach {
            pluginRowsStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        if plugins.isEmpty {
            let empty = NSTextField(wrappingLabelWithString:
                "当前没有可用的缓冲插件。")
            empty.alignment = .center
            empty.font = .systemFont(ofSize: 12)
            empty.textColor = .secondaryLabelColor
            empty.translatesAutoresizingMaskIntoConstraints = false
            empty.heightAnchor.constraint(equalToConstant: 58).isActive = true
            pluginRowsStack.addArrangedSubview(empty)
        } else {
            plugins.forEach {
                pluginRowsStack.addArrangedSubview(
                    pluginRow($0, mode: .bufferEnablement)
                )
            }
        }

        if let statusMessage {
            setPluginStatus(statusMessage)
        } else if !pluginDownloadInProgress {
            let enabledCount = plugins.filter(\.isEnabled).count
            let activeName = BufferPluginSelectionStore.shared.activeKey.flatMap { key in
                plugins.first(where: { $0.descriptor.key == key })?.descriptor.name
            }
            let current = activeName ?? BufferPluginMenuCatalog.defaultTitle
            setPluginStatus("已开启 \(enabledCount) 个；工作台当前：\(current)")
        }
    }

    /// Local manager notifications are posted synchronously. Defer and
    /// coalesce the rebuild so an AppKit control is not removed from its row
    /// while that control's action selector is still executing.
    private func schedulePluginListRefresh() {
        guard !pluginRefreshScheduled else { return }
        pluginRefreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pluginRefreshScheduled = false
            guard self.selectedCoreRoute == .plugins else { return }
            self.refreshPluginList()
        }
    }

    private func setPluginDownloadInProgress(_ inProgress: Bool) {
        pluginDownloadInProgress = inProgress
    }

    private func setPluginStatus(_ message: String, isError: Bool = false) {
        pluginStatusLabel.stringValue = message
        pluginStatusLabel.textColor = isError ? .systemRed : .secondaryLabelColor
        pluginStatusLabel.toolTip = message
    }

    func remoteStatusDidChange() {
        guard selectedCoreRoute == .connectors else { return }
        refreshRemoteStatus()
    }

    private func refreshCandidateMetricControls() {
        var stored: [CandidateWindowMetric: Double] = [:]
        for metric in CandidateWindowMetric.allCases {
            stored[metric] = Double(CandidateWindowMetrics.value(for: metric))
        }
        updateCandidateControls(resolveMetricValues(stored))
    }

    /// Current (possibly unsaved) values straight off the live controls.
    private func liveMetricValues() -> [CandidateWindowMetric: Double] {
        var values: [CandidateWindowMetric: Double] = [:]
        for metric in CandidateWindowMetric.allCases {
            values[metric] = candidateMetricSliders[metric]?.doubleValue
                ?? Double(CandidateWindowMetrics.value(for: metric))
        }
        return values
    }

    /// Resolve raw control values through the full dependency chain so an
    /// unsupported interval can never be previewed or committed.
    private func resolveMetricValues(_ raw: [CandidateWindowMetric: Double]) -> [CandidateWindowMetric: Double] {
        CandidateWindowMetrics.resolvedValues(raw)
    }

    /// Push a resolved value set into every control (value + supported bounds +
    /// constraint hint) and refresh the live preview. Does NOT persist.
    private func updateCandidateControls(_ values: [CandidateWindowMetric: Double]) {
        for metric in CandidateWindowMetric.allCases {
            let supported = metric.supportedRange(given: values)
            let value = values[metric] ?? metric.defaultValue

            if let slider = candidateMetricSliders[metric] {
                slider.minValue = supported.lowerBound
                slider.maxValue = supported.upperBound
                slider.doubleValue = value
            }
            candidateMetricFields[metric]?.stringValue = formatMetricValue(CGFloat(value))
            (candidateMetricFields[metric]?.formatter as? NumberFormatter)?
                .maximum = NSNumber(value: supported.upperBound)

            if let hint = candidateMetricHints[metric] {
                let capped = supported.upperBound < metric.range.upperBound - 0.5
                if capped, let dep = metric.containerMetric {
                    hint.stringValue = "≤ \(Int(supported.upperBound))（受\(dep.metric.title)限制）"
                    hint.isHidden = false
                } else {
                    hint.stringValue = ""
                    hint.isHidden = true
                }
            }
        }
        candidatePreview?.metrics = candidateMetrics(from: values)
    }

    private func candidateMetrics(from values: [CandidateWindowMetric: Double]) -> CandidateWindowMetrics {
        func get(_ metric: CandidateWindowMetric) -> CGFloat {
            CGFloat(values[metric] ?? metric.defaultValue)
        }
        return CandidateWindowMetrics(
            baseWidth: get(.baseWidth),
            compactStripHeight: get(.compactStripHeight),
            compactCandidateHeight: get(.compactCandidateHeight),
            preeditHeight: get(.preeditHeight),
            candidateFontSize: get(.candidateFontSize),
            labelFontSize: get(.labelFontSize)
        )
    }

    private func refreshChordDurationControl() {
        let value = ChordSettings.duration
        chordDurationField.stringValue = String(format: "%.2f", value)
        chordDurationStepper.doubleValue = value
    }

    private func formatMetricValue(_ value: CGFloat) -> String {
        "\(Int(value.rounded()))"
    }

    private func refreshStats() {
        let snapshot = KeyFrequencyStore.shared.snapshot(for: statsDatePicker.dateValue)
        heatmapView.snapshot = snapshot
        statsSummary.stringValue = "\(snapshot.dayKey) · 总按键 \(snapshot.total) 次 · 覆盖 \(snapshot.counts.count) 个键"
        if let top = snapshot.topKeyId {
            let count = snapshot.counts[top] ?? 0
            let ratio = snapshot.total > 0 ? Double(count) / Double(snapshot.total) * 100 : 0
            statsTopKey.stringValue = "最高频：\(KeyboardLayout.displayName(for: top)) · \(count) 次 · \(String(format: "%.1f", ratio))%"
        } else {
            statsTopKey.stringValue = "最高频：暂无"
        }
    }

    private func refreshRemoteStatus() {
        remoteCheck.state = RemoteConfig.enabled ? .on : .off
        remoteNameField.stringValue = RemoteConfig.deviceName
        let status = RemoteTypingService.shared.status
        remoteStatusLabel.stringValue = "状态：\(RemoteTypingService.shared.statusSummary)"

        remoteDevicesStack.arrangedSubviews.forEach {
            remoteDevicesStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        remoteDiscoveredIDs.removeAll()
        remoteTrustedKeys.removeAll()

        guard RemoteConfig.enabled else {
            remoteDevicesStack.addArrangedSubview(secondaryLabel("开启后会在局域网和附近设备中发现可配对的 Mac。"))
            return
        }

        let untrusted = status.discovered.filter { !$0.trusted }
        if !untrusted.isEmpty {
            remoteDevicesStack.addArrangedSubview(secondaryLabel("发现的设备"))
            for peer in untrusted {
                let button = NSButton(title: "配对：\(peer.name)", target: self, action: #selector(pairRemoteDevice(_:)))
                button.tag = remoteDiscoveredIDs.count
                remoteDiscoveredIDs.append(peer.id)
                remoteDevicesStack.addArrangedSubview(button)
            }
        }

        if !status.trusted.isEmpty {
            remoteDevicesStack.addArrangedSubview(secondaryLabel("已配对设备"))
            for peer in status.trusted {
                let button = NSButton(title: "取消配对：\(peer.name)", target: self, action: #selector(unpairRemoteDevice(_:)))
                button.tag = remoteTrustedKeys.count
                remoteTrustedKeys.append(peer.pubB64)
                remoteDevicesStack.addArrangedSubview(button)
            }
        }

        if untrusted.isEmpty, status.trusted.isEmpty {
            remoteDevicesStack.addArrangedSubview(secondaryLabel("尚未发现设备。确认另一台 Mac 已开启隔空传字。"))
        }
    }

    // MARK: Actions

    @objc private func routeChosen(_ sender: SettingsRouteButton) {
        guard navigation.selectRoute(sender.routeID, catalog: routeCatalog) else { return }
        reload()
        showCurrentRoute()
    }

    @objc private func subpageChosen(_ sender: NSSegmentedControl) {
        guard let route = selectedRoute,
              route.subpages.indices.contains(sender.selectedSegment) else { return }
        let subpage = route.subpages[sender.selectedSegment].id
        guard navigation.selectSubpage(subpage, catalog: routeCatalog) else { return }
        showCurrentRoute()
    }

    @objc private func openPluginDirectory() {
        let directory = ActionPluginManager.shared.rootURL
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            NSWorkspace.shared.open(directory)
        } catch {
            setPluginStatus("无法打开插件目录：\(error.localizedDescription)", isError: true)
        }
    }

    @objc private func showPluginInstallDialog() {
        guard let window, !pluginDownloadInProgress else { return }
        let alert = NSAlert()
        alert.messageText = "安装缓冲插件"
        alert.informativeText = "从本地插件目录、manifest.json 文件，或 HTTPS 清单地址安装。"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "本地文件…")
        alert.addButton(withTitle: "HTTPS 地址…")
        alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            DispatchQueue.main.async {
                switch response {
                case .alertFirstButtonReturn:
                    self.installLocalPlugin()
                case .alertSecondButtonReturn:
                    self.showRemotePluginInstallDialog()
                default:
                    break
                }
            }
        }
    }

    private func showRemotePluginInstallDialog() {
        guard let window, !pluginDownloadInProgress else { return }
        let field = NSTextField(string: "")
        field.placeholderString = "https://example.com/plugin/manifest.json"
        field.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 430).isActive = true

        let alert = NSAlert()
        alert.messageText = "从 HTTPS 安装"
        alert.informativeText = "只下载并验证 manifest.json，不会执行安装脚本。"
        alert.accessoryView = field
        alert.addButton(withTitle: "安装")
        alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            self.installRemotePlugin(from: field.stringValue)
        }
    }

    @objc private func showPluginUninstallDialog() {
        guard let window else { return }
        let plugins = PluginRegistry.shared.plugins(capability: .bufferAction)
            .filter(\.descriptor.canUninstall)
        guard !plugins.isEmpty else {
            info("当前没有可以卸载的插件。内置插件随应用提供，不能单独卸载。")
            return
        }

        let popup = NSPopUpButton()
        popup.translatesAutoresizingMaskIntoConstraints = false
        popup.widthAnchor.constraint(equalToConstant: 360).isActive = true
        for plugin in plugins {
            popup.addItem(withTitle: "\(plugin.descriptor.name)  ·  v\(plugin.descriptor.version)")
            popup.lastItem?.representedObject = plugin.descriptor.key.rawID
        }

        let alert = NSAlert()
        alert.messageText = "卸载插件"
        alert.informativeText = "选择要从本机插件目录移除的插件。插件服务及其数据不会被启动或修改。"
        alert.alertStyle = .warning
        alert.accessoryView = popup
        alert.addButton(withTitle: "卸载")
        alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self,
                  response == .alertFirstButtonReturn,
                  let pluginID = popup.selectedItem?.representedObject as? String else { return }
            self.uninstallPlugin(id: pluginID)
        }
    }

    @objc private func showPluginManagementDialog() {
        guard let window else { return }
        let bufferPlugins = PluginRegistry.shared.plugins(capability: .bufferAction)
        let externalCount = bufferPlugins.filter { $0.descriptor.canUninstall }.count
        let details = NSTextField(wrappingLabelWithString:
            "缓冲插件：\(bufferPlugins.count)\n外部插件：\(externalCount)\n目录：\(ActionPluginManager.shared.rootURL.path)")
        details.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        details.textColor = .secondaryLabelColor
        details.translatesAutoresizingMaskIntoConstraints = false
        details.widthAnchor.constraint(equalToConstant: 430).isActive = true

        let alert = NSAlert()
        alert.messageText = "管理插件"
        alert.informativeText = "刷新插件清单，或在 Finder 中查看外部插件文件。"
        alert.accessoryView = details
        alert.addButton(withTitle: "刷新")
        alert.addButton(withTitle: "打开插件目录")
        alert.addButton(withTitle: "完成")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            switch response {
            case .alertFirstButtonReturn:
                self.refreshPluginList(statusMessage: "插件列表已刷新")
                ActionPluginHost.shared.refreshStatuses(force: true)
            case .alertSecondButtonReturn:
                self.openPluginDirectory()
            default:
                break
            }
        }
    }

    @objc private func installLocalPlugin() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.title = "安装工作台插件"
        panel.message = "选择包含 manifest.json 的目录，或直接选择 manifest.json 文件。"
        panel.prompt = "安装"
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let source = panel.url else { return }
            do {
                let plugin = try ActionPluginManager.shared.installLocal(url: source)
                self.refreshPluginList(statusMessage: "已安装或更新插件：\(plugin.name)")
            } catch {
                self.setPluginStatus("本地安装失败：\(error.localizedDescription)", isError: true)
                self.refreshPluginList()
            }
        }
    }

    private func installRemotePlugin(from rawValue: String) {
        guard !pluginDownloadInProgress else { return }
        let raw = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: raw),
              url.scheme?.lowercased() == "https",
              !raw.isEmpty else {
            setPluginStatus("请输入有效的 HTTPS manifest.json 地址", isError: true)
            return
        }
        setPluginDownloadInProgress(true)
        setPluginStatus("正在下载并验证插件清单…")
        ActionPluginManager.shared.installRemote(url: url) { [weak self] result in
            guard let self else { return }
            self.setPluginDownloadInProgress(false)
            switch result {
            case let .success(plugin):
                self.refreshPluginList(statusMessage: "已安装或更新插件：\(plugin.name)")
            case let .failure(error):
                self.setPluginStatus("下载安装失败：\(error.localizedDescription)", isError: true)
                self.refreshPluginList()
            }
        }
    }

    @objc private func pluginSwitchToggled(_ sender: SettingsPluginSwitch) {
        let on = sender.state == .on
        let pluginName = PluginRegistry.shared.allPlugins()
            .first(where: { $0.descriptor.key == sender.pluginKey })?
            .descriptor.name ?? sender.pluginKey.rawID
        do {
            switch sender.mode {
            case .bufferEnablement:
                try PluginRegistry.shared.setEnabled(on, for: sender.pluginKey)
                setPluginStatus(on
                    ? "已启用并加入工作台：\(pluginName)"
                    : "已停用并从工作台移除：\(pluginName)")
            case .enablement:
                try PluginRegistry.shared.setEnabled(on, for: sender.pluginKey)
                setPluginStatus(on ? "已启用扩展：\(pluginName)" : "已停用扩展：\(pluginName)")
            }
            DispatchQueue.main.async { [weak self] in self?.refreshPluginList() }
        } catch {
            setPluginStatus("更新插件状态失败：\(error.localizedDescription)", isError: true)
            refreshPluginList()
        }
    }

    @objc private func configureBufferPlugin(
        _ sender: SettingsPluginConfigurationButton
    ) {
        guard let parentWindow = window,
              pluginConfigurationSheet == nil else { return }
        let plugin = PluginRegistry.shared.allPlugins().first {
            $0.descriptor.key == sender.pluginKey
        }
        do {
            guard let controller = try PluginRegistry.shared
                .makePluginConfigurationViewController(
                    pluginKey: sender.pluginKey
                ) else {
                setPluginStatus("这个插件当前没有可配置项", isError: true)
                return
            }
            let sheet = PluginConfigurationSheetFactory.make(
                contentViewController: controller,
                title: "\(plugin?.descriptor.name ?? "插件") 设置"
            )
            pluginConfigurationSheet = sheet
            if let form = controller as? PluginConfigurationViewController {
                form.onDismiss = { [weak self, weak parentWindow, weak sheet] in
                    guard let self, let sheet else { return }
                    parentWindow?.endSheet(sheet)
                    sheet.orderOut(nil)
                    self.pluginConfigurationSheet = nil
                    self.refreshPluginList()
                }
            }
            parentWindow.beginSheet(sheet)
        } catch {
            setPluginStatus(
                "无法打开插件设置：\(error.localizedDescription)",
                isError: true
            )
        }
    }

    private func uninstallPlugin(id pluginID: String) {
        guard let plugin = ActionPluginManager.shared.listInstalledPlugins()
            .first(where: { $0.id == pluginID }) else {
            setPluginStatus("插件列表已经变化，请刷新后重试", isError: true)
            refreshPluginList()
            return
        }
        do {
            try PluginRegistry.shared.setBufferPluginActive(
                false,
                for: PluginKey(domain: .externalActionV1, rawID: plugin.id)
            )
            try ActionPluginManager.shared.uninstall(id: plugin.id)
            refreshPluginList(statusMessage: "已卸载插件：\(plugin.name)")
        } catch {
            setPluginStatus("卸载失败：\(error.localizedDescription)", isError: true)
            refreshPluginList()
        }
    }

    @objc private func inputEncodingSelected(_ sender: NSButton) {
        guard InputEncoding.allCases.indices.contains(sender.tag) else { return }
        _ = InputConfigurationStore.shared.select(
            encoding: InputEncoding.allCases[sender.tag]
        )
        RimeBufferController.applyStoredInputConfiguration()
        reload()
    }

    @objc private func keyingModeSelected(_ sender: NSButton) {
        guard KeyingMode.allCases.indices.contains(sender.tag) else { return }
        let selected = KeyingMode.allCases[sender.tag]
        guard InputConfigurationStore.shared.select(keyingMode: selected) else {
            NSSound.beep()
            reload()
            return
        }
        RimeBufferController.applyStoredInputConfiguration()
        reload()
    }

    @objc private func aiConnectorSelected(_ sender: NSButton) {
        guard AITextProviderKind.allCases.indices.contains(sender.tag) else { return }
        let kind = AITextProviderKind.allCases[sender.tag]
        _ = AITextConnectorRegistry.shared.select(kind)
        refreshAIConnectorSelection()
        BufferWindowController.shared.refresh()
        RimeBufferController.refreshActiveUI()
    }

    @objc private func codexLoginButtonPressed() {
        if let operation = codexLoginOperation {
            codexLoginCancelling = true
            codexAuthorizationURL = nil
            codexLoginFeedback = "正在取消 Codex 登录…"
            codexLoginFeedbackIsError = false
            refreshCodexLoginControls()
            operation.cancel()
            return
        }

        let sessionID = UUID()
        codexLoginSessionID = sessionID
        codexLoginCancelling = false
        codexAuthorizationURL = nil
        codexLoginFeedback = AITextCodexLoginStatus.launching.displayText
        codexLoginFeedbackIsError = false

        let operation = AITextCodexLoginOperation(
            onAuthorizationURL: { [weak self] url in
                guard let self,
                      self.codexLoginSessionID == sessionID,
                      !self.codexLoginCancelling else { return }
                self.codexAuthorizationURL = url
                if NSWorkspace.shared.open(url) {
                    self.codexLoginFeedback = AITextCodexLoginStatus.waitingForBrowser.displayText
                    self.codexLoginFeedbackIsError = false
                } else {
                    self.codexLoginFeedback = "浏览器未能自动打开；可复制登录链接后继续授权。"
                    self.codexLoginFeedbackIsError = true
                }
                self.refreshCodexLoginControls()
            },
            onStatus: { [weak self] status in
                guard let self,
                      self.codexLoginSessionID == sessionID,
                      !self.codexLoginCancelling else { return }
                self.codexLoginFeedback = status.displayText
                self.codexLoginFeedbackIsError = false
                self.refreshCodexLoginControls()
            },
            completion: { [weak self] result in
                guard let self, self.codexLoginSessionID == sessionID else { return }
                self.codexLoginOperation = nil
                self.codexLoginSessionID = nil
                self.codexLoginCancelling = false
                self.codexAuthorizationURL = nil
                var authorizationChanged = false
                switch result {
                case .success:
                    self.codexLoginFeedback = "ChatGPT 订阅授权成功，Codex 连接器已就绪。"
                    self.codexLoginFeedbackIsError = false
                    authorizationChanged = true
                case .failure(.cancelled):
                    self.codexLoginFeedback = "已取消 Codex 登录。"
                    self.codexLoginFeedbackIsError = false
                case let .failure(error):
                    self.codexLoginFeedback = self.codexLoginErrorMessage(error)
                    self.codexLoginFeedbackIsError = true
                }
                self.refreshCodexLoginControls()
                if authorizationChanged {
                    AITextPluginRuntimeRegistry.shared.workspace.configurationDidChange()
                    BufferWindowController.shared.refresh()
                    RimeBufferController.refreshActiveUI()
                }
                DispatchQueue.main.async { [weak self] in
                    guard let self,
                          self.window?.isVisible == true,
                          self.selectedCoreRoute == .connectors,
                          self.navigation.selectedSubpage()?.rawValue == "ai-model" else { return }
                    self.reload()
                    self.showCurrentRoute()
                }
            }
        )
        codexLoginOperation = operation
        refreshCodexLoginControls()
        operation.start()
    }

    @objc private func copyCodexLoginLink() {
        guard let url = codexAuthorizationURL else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(url.absoluteString, forType: .string)
        codexLoginFeedback = "登录链接已复制；请在浏览器中打开并完成授权。"
        codexLoginFeedbackIsError = false
        refreshCodexLoginControls()
    }

    @objc private func claudeLoginButtonPressed() {
        if let operation = claudeLoginOperation {
            claudeLoginCancelling = true
            claudeLoginFeedback = "正在取消 Claude 登录…"
            claudeLoginFeedbackIsError = false
            refreshClaudeLoginControls()
            operation.cancel()
            return
        }

        let sessionID = UUID()
        claudeLoginSessionID = sessionID
        claudeLoginCancelling = false
        claudeLoginFeedback = AITextClaudeLoginStatus.launching.displayText
        claudeLoginFeedbackIsError = false

        let operation = AITextClaudeLoginOperation(
            onStatus: { [weak self] status in
                guard let self,
                      self.claudeLoginSessionID == sessionID,
                      !self.claudeLoginCancelling else { return }
                self.claudeLoginFeedback = status.displayText
                self.claudeLoginFeedbackIsError = false
                self.refreshClaudeLoginControls()
            },
            completion: { [weak self] result in
                guard let self, self.claudeLoginSessionID == sessionID else { return }
                self.claudeLoginOperation = nil
                self.claudeLoginSessionID = nil
                self.claudeLoginCancelling = false
                switch result {
                case .success:
                    self.claudeLoginFeedback = "Claude Code CLI 授权成功，连接器已就绪。"
                    self.claudeLoginFeedbackIsError = false
                    AITextConnectorRegistry.shared.claudeAuthenticationDidChange(true)
                case .failure(.cancelled):
                    self.claudeLoginFeedback = "已取消 Claude 登录。"
                    self.claudeLoginFeedbackIsError = false
                    AITextConnectorRegistry.shared.claudeAuthenticationDidChange(nil)
                case let .failure(error):
                    self.claudeLoginFeedback = self.claudeLoginErrorMessage(error)
                    self.claudeLoginFeedbackIsError = true
                    AITextConnectorRegistry.shared.claudeAuthenticationDidChange(nil)
                }
                self.refreshClaudeLoginControls()
                BufferWindowController.shared.refresh()
                RimeBufferController.refreshActiveUI()
                DispatchQueue.main.async { [weak self] in
                    guard let self,
                          self.window?.isVisible == true,
                          self.selectedCoreRoute == .connectors,
                          self.navigation.selectedSubpage()?.rawValue == "ai-model" else { return }
                    self.reload()
                    self.showCurrentRoute()
                }
            }
        )
        claudeLoginOperation = operation
        refreshClaudeLoginControls()
        operation.start()
    }

    private func persistSchemaSelection(_ ids: [String]? = nil) throws {
        let enabled = ids ?? InputSchemaCatalog.defaultEnabledIDs
        try SchemaListStore.writeEnabledIDs(enabled,
                                            to: userDir.appendingPathComponent("default.custom.yaml"))
        let preferred = InputConfigurationStore.shared.runtimeProfile.schemaID
        UserDefaults.standard.set(preferred, forKey: "preferredSchema")
        IMELog.write("settings: F4 schemas -> \(enabled.joined(separator: ","))")
    }

    @objc private func deployAndRestart() {
        do {
            try persistSchemaSelection()
        } catch {
            info("无法应用方案：\(error.localizedDescription)")
            return
        }
        RimeBufferController.active?.forceCommit()
        info("开始部署…完成后输入法会自动重启。")
        DispatchQueue.global(qos: .userInitiated).async {
            _ = rimeEngine.start()
            let ok = BBRimeDeploy()
            IMELog.write("settings: deploy=\(ok)")
            DispatchQueue.main.async {
                guard ok else {
                    self.info("部署失败，输入法没有重启。请查看运行日志。")
                    return
                }
                InputMetricsPersistence.saveNow()
                exit(0)   // text-input system relaunches us
            }
        }
    }

    @objc private func reinstallInputMethod() {
        guard let script = installScriptURL() else {
            info("找不到 build_install.sh。默认查找：~/Documents/DEV/rime-buffer-1、~/Documents/05-dev/apps/rime-buffer-1 或旧版 rime-buffer 目录。")
            return
        }

        let alert = NSAlert()
        alert.messageText = "重新安装 \(ProductIdentity.displayName)？"
        alert.informativeText = "将从 \(script.deletingLastPathComponent().path) 运行 build_install.sh。构建完成后当前输入法进程会被重启。"
        alert.addButton(withTitle: "重新安装")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        RimeBufferController.active?.forceCommit()
        InputMetricsPersistence.saveNow()

        let command = [
            "cd \(shellQuote(script.deletingLastPathComponent().path))",
            "nohup env RB_KEEP_USERDB=1 /bin/bash ./build_install.sh > \(shellQuote(installLogURL.path)) 2>&1 &",
        ].joined(separator: " && ")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        do {
            try process.run()
            installStatus.stringValue = "安装已启动，日志：~/rimebuffer-install.log"
            IMELog.write("settings: launched install script \(script.path)")
        } catch {
            installStatus.stringValue = "安装启动失败"
            info("安装启动失败：\(error.localizedDescription)")
        }
    }

    private func installScriptURL() -> URL? {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let candidates = [
            home.appendingPathComponent("Documents/DEV/rime-buffer-1/build_install.sh"),
            home.appendingPathComponent("Documents/05-dev/apps/rime-buffer-1/build_install.sh"),
            home.appendingPathComponent("Documents/DEV/rime-buffer/build_install.sh"),
            home.appendingPathComponent("Documents/05-dev/apps/rime-buffer/build_install.sh"),
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    @objc private func resetOnAppSwitchToggled() {
        BufferModel.shared.resetOnAppSwitch = resetOnAppSwitchCheck.state == .on
        IMELog.write("setting resetOnAppSwitch=\(resetOnAppSwitchCheck.state == .on)")
    }

    @objc private func bufferToggled() {
        let enabled = bufferCheck.state == .on
        if enabled {
            BufferModel.shared.enabled = true
            BufferWindowController.shared.show()
        } else {
            ActionPluginHost.shared.cancelActiveInvocationForWorkbench()
            DerivedBufferWorkspaceRouter.selectedWorkspace?.workbenchWillPause()
            BuiltInBufferActionWorkspaceRouter.selectedWorkspace?.workbenchWillPause()
            BufferModel.shared.pauseCapturePreservingContent()
        }
        RimeBufferController.refreshActiveUI()
        reload()
        IMELog.write("setting bufferEnabled=\(enabled)")
    }

    @objc private func bufferWindowVisibilityToggled() {
        if bufferWindowVisibleCheck.state == .on {
            BufferWindowController.shared.openAndResume()
        } else {
            BufferWindowController.shared.closeAndPause()
        }
        reload()
    }

    @objc private func bufferPinnedToggled() {
        BufferWindowController.shared.pinned = bufferPinnedCheck.state == .on
        reload()
    }

    @objc private func bufferCandidatePlacementChanged() {
        guard let raw = candidatePlacementPopUp.selectedItem?.representedObject as? String,
              let placement = BufferCandidatePlacement(rawValue: raw) else { return }
        BufferWindowController.shared.candidatePlacement = placement
        reload()
    }

    @objc private func moveBufferWindow() {
        BufferWindowController.shared.openAndResume()
        BufferWindowController.shared.moveToCurrentScreen()
        reload()
    }

    @objc private func remoteToggled() {
        RemoteConfig.enabled = remoteCheck.state == .on
        if RemoteConfig.enabled {
            RemoteTypingService.shared.restart()
        } else {
            RemoteTypingService.shared.stop()
        }
        IMELog.write("settings: remote typing enabled -> \(RemoteConfig.enabled)")
        refreshRemoteStatus()
    }

    @objc private func applyRemoteName() {
        let trimmed = remoteNameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        RemoteConfig.deviceName = trimmed
        if RemoteConfig.enabled { RemoteTypingService.shared.restart() }
        IMELog.write("settings: remote device name -> \(trimmed)")
        refreshRemoteStatus()
    }

    @objc private func pairRemoteDevice(_ sender: NSButton) {
        guard remoteDiscoveredIDs.indices.contains(sender.tag) else { return }
        RemoteTypingService.shared.requestPair(peerID: remoteDiscoveredIDs[sender.tag])
    }

    @objc private func unpairRemoteDevice(_ sender: NSButton) {
        guard remoteTrustedKeys.indices.contains(sender.tag) else { return }
        RemoteTypingService.shared.unpair(pubB64: remoteTrustedKeys[sender.tag])
    }

    @objc private func appearanceChosen() {
        guard let raw = appearancePopUp.selectedItem?.representedObject as? String,
              let mode = RimeAppearanceMode(rawValue: raw) else { return }
        RimeUI.appearance = mode
        candidatePreview?.reload()
        IMELog.write("appearance -> \(mode.rawValue)")
    }

    @objc private func chordDurationFieldChanged() {
        applyChordDuration(chordDurationField.doubleValue)
    }

    @objc private func chordDurationStepperChanged() {
        applyChordDuration(chordDurationStepper.doubleValue)
    }

    @objc private func resetChordDuration() {
        window?.makeFirstResponder(nil)
        ChordSettings.resetToDefault()
        refreshChordDurationControl()
    }

    /// Persist + broadcast the new chord window (setter clamps to range), then
    /// snap the field/stepper back to the stored value.
    private func applyChordDuration(_ value: Double) {
        ChordSettings.duration = value
        refreshChordDurationControl()
    }

    @objc private func candidateMetricSliderChanged(_ sender: NSSlider) {
        handleCandidateMetricEdit(tag: sender.tag, value: sender.doubleValue)
    }

    @objc private func candidateMetricFieldChanged(_ sender: NSTextField) {
        handleCandidateMetricEdit(tag: sender.tag, value: sender.doubleValue)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        if field === chordDurationField {
            applyChordDuration(field.doubleValue)
            return
        }
        guard candidateMetricFields.values.contains(where: { $0 === field }) else { return }
        handleCandidateMetricEdit(tag: field.tag, value: field.doubleValue)
    }

    /// Live edit of one metric: fold it into the current control values, re-resolve
    /// the supported set (so dependents follow), and push everything back — the
    /// preview updates immediately, nothing is persisted until "应用修改".
    private func handleCandidateMetricEdit(tag: Int, value: Double) {
        guard let metric = CandidateWindowMetric.fromTag(tag) else { return }
        var raw = liveMetricValues()
        raw[metric] = value
        updateCandidateControls(resolveMetricValues(raw))
    }

    @objc private func applyCandidateMetrics() {
        window?.makeFirstResponder(nil)
        let resolved = resolveMetricValues(liveMetricValues())
        CandidateWindowMetrics.apply(resolved)
        updateCandidateControls(resolved)
    }

    @objc private func resetCandidateMetrics() {
        CandidateWindowMetrics.resetToDefaults()
        refreshCandidateMetricControls()
    }

    @objc private func statsDateChanged() {
        refreshStats()
    }

    @objc private func refreshStatsTapped() {
        refreshStats()
    }

    @objc private func clearStatsDay() {
        KeyFrequencyStore.shared.clear(day: statsDatePicker.dateValue)
        refreshStats()
    }

    @objc private func clearStatsAll() {
        KeyFrequencyStore.shared.clear(day: nil)
        refreshStats()
    }

    @objc private func importUserLexicon(_ sender: SettingsLexiconButton) {
        let kind = sender.lexiconKind
        let panel = NSOpenPanel()
        panel.title = "导入\(kind.displayName)"
        panel.message = "选择由 \(ProductIdentity.displayName) 或 Rime 用户词典管理器导出的 TSV；记录会合并，不会替换现有学习数据。"
        panel.prompt = "选择并导入"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.tabSeparatedText, .plainText]
        guard panel.runModal() == .OK, let sourceURL = panel.url else { return }

        let confirmation = NSAlert()
        confirmation.alertStyle = .informational
        confirmation.messageText = "合并到\(kind.displayName)？"
        confirmation.informativeText = "Rime 会短暂收束当前组字并重新建立输入会话；已有词频不会被清空。"
        confirmation.addButton(withTitle: "导入并合并")
        confirmation.addButton(withTitle: "取消")
        guard confirmation.runModal() == .alertFirstButtonReturn else { return }

        do {
            let result = try UserLexiconService.shared.importLearningData(kind,
                                                                          from: sourceURL)
            info("已向\(kind.displayName)合并 \(result.entryCount) 条学习记录。")
            showCurrentRoute()
        } catch {
            showLexiconError(error, operation: "导入")
        }
    }

    @objc private func exportUserLexicon(_ sender: SettingsLexiconButton) {
        let kind = sender.lexiconKind
        let panel = NSSavePanel()
        panel.title = "导出\(kind.displayName)"
        panel.message = "导出为可再次导入的 UTF-8 TSV，不包含基础词库、输入正文或其他统计。"
        panel.prompt = "导出"
        panel.nameFieldStringValue = kind.suggestedFileName
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.tabSeparatedText]
        guard panel.runModal() == .OK, let destinationURL = panel.url else { return }

        do {
            let result = try UserLexiconService.shared.exportLearningData(kind,
                                                                          to: destinationURL)
            info("已导出 \(result.entryCount) 条\(kind.displayName)记录。")
            NSWorkspace.shared.activateFileViewerSelecting([destinationURL])
        } catch {
            showLexiconError(error, operation: "导出")
        }
    }

    private func showLexiconError(_ error: Error, operation: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "学习词库\(operation)失败"
        alert.informativeText = (error as? LocalizedError)?.errorDescription
            ?? error.localizedDescription
        alert.runModal()
    }

    @objc private func openDir() {
        NSWorkspace.shared.open(userDir)
    }

    @objc private func checkUpdate() {
        UpdateManager.shared.checkNowManually()
    }

    @objc private func openRuntimeLog() {
        let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("rimebuffer.log")
        NSWorkspace.shared.open(url)
    }

    @objc private func restartInputMethod() {
        RimeBufferController.active?.forceCommit()
        InputMetricsPersistence.saveNow()
        IMELog.write("settings: restart requested")
        exit(0)
    }

    @objc private func openInstallLog() {
        NSWorkspace.shared.open(installLogURL)
    }

    private func info(_ message: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.runModal()
    }
}
