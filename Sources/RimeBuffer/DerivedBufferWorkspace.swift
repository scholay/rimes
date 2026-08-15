import Foundation

extension Notification.Name {
    static let derivedBufferWorkspaceDidChange = Notification.Name(
        "RimeBuffer.DerivedBufferWorkspace.didChange"
    )
}

/// Shared presentation/lifecycle surface for trusted two-rail workspaces. The
/// concrete workspace remains the delivery source so ObjectIdentifier-based
/// generation checks never depend on short-lived adapters.
protocol DerivedBufferWorkspace: BufferDeliveryContentSource {
    var workspacePluginKey: PluginKey { get }
    var workbenchDisplayName: String { get }
    var railSnapshot: TranslationRailSnapshot { get }
    var statusText: String { get }

    func setProtected(_ protected: Bool)
    @discardableResult func requestRefresh() -> Bool
    func workbenchWillPause()
}

enum WorkbenchStatusIndicatorTone: Equatable {
    case healthy
    case warning
    case inactive
}

struct WorkbenchStatusIndicator: Equatable {
    let identifier: String
    let text: String
    let detail: String
    let tone: WorkbenchStatusIndicatorTone
}

/// Optional compact diagnostics rendered on the trailing side of the
/// workbench toolbar. They describe integration health, never document text.
protocol WorkbenchStatusIndicatorProviding: AnyObject {
    var workbenchStatusIndicators: [WorkbenchStatusIndicator] { get }
}

extension DerivedBufferWorkspace {
    func workbenchWillPause() {}
}

/// Optional controls are capabilities of a selected derived workspace, not
/// hard-coded cases in the workbench window.
protocol DerivedLanguagePairControls: AnyObject {
    var languageOptions: [TranslationLanguageOption] { get }
    var sourceLanguageID: String { get }
    var targetLanguageID: String { get }
    var canSwapLanguages: Bool { get }
    func setSourceLanguage(_ identifier: String)
    func setTargetLanguage(_ identifier: String)
    @discardableResult func swapLanguages() -> Bool
}

/// A derived workspace may expose a small mutually-exclusive result set. The
/// workbench keeps navigation generic: query ownership and delivery authority
/// remain inside the concrete workspace, while the renderer/controller only
/// forwards a stable block identity or a vertical delta.
protocol DerivedResultSelectionControls: AnyObject {
    var ownsResultNavigation: Bool { get }
    @discardableResult func moveResultSelection(delta: Int) -> Bool
    @discardableResult func selectResult(blockID: UUID) -> Bool
}

/// The right-side workbench control has one shared state machine whether the
/// generator is a trusted two-rail workspace or an external prepared Action
/// Plugin. Keeping this contract outside `DerivedBufferWorkspace` prevents
/// Return routing from treating "built in" as the generation capability.
enum WorkbenchManualGenerationPrimaryAction: Equatable {
    case disabled
    case requestGeneration
    case generating
    case deliver

    var beginsDeliveryGesture: Bool { self == .deliver }
}

enum WorkbenchManualGenerationPrimaryActionRules {
    static func resolve(isGenerating: Bool,
                        hasReadyDelivery: Bool,
                        canGenerate: Bool) -> WorkbenchManualGenerationPrimaryAction {
        if isGenerating { return .generating }
        if hasReadyDelivery { return .deliver }
        if canGenerate { return .requestGeneration }
        return .disabled
    }
}

protocol WorkbenchManualGenerationControls: AnyObject {
    var canGenerate: Bool { get }
    var isGenerating: Bool { get }
    var generationProviderName: String { get }
    var generationStatusText: String { get }
    var generationRequestDescription: String { get }
    var primaryAction: WorkbenchManualGenerationPrimaryAction { get }
    @discardableResult func generate() -> Bool
}

extension WorkbenchManualGenerationControls {
    var generationStatusText: String { "等待内容" }
    var generationRequestDescription: String {
        "用 \(generationProviderName) 处理当前全部缓冲内容"
    }
}

extension AppleTranslationWorkspace: DerivedBufferWorkspace,
                                     DerivedLanguagePairControls {
    var workspacePluginKey: PluginKey { Self.pluginKey }
    var workbenchDisplayName: String { "实时翻译" }

    @discardableResult
    func requestRefresh() -> Bool {
        resetAndRefresh()
        return true
    }
}

extension AITextPluginWorkspace: DerivedBufferWorkspace,
                                 WorkbenchManualGenerationControls {
    var workspacePluginKey: PluginKey { pluginKey }
    var workbenchDisplayName: String { "AI 生成 · \(kind.displayName)" }
    var isGenerating: Bool { phase == .running }
    var generationProviderName: String { kind.displayName }
    var generationStatusText: String { statusText }
    var primaryAction: WorkbenchManualGenerationPrimaryAction {
        WorkbenchManualGenerationPrimaryActionRules.resolve(
            isGenerating: isGenerating,
            hasReadyDelivery: phase == .ready && !deliveryPendingBlocks.isEmpty,
            canGenerate: canGenerate
        )
    }

    @discardableResult
    func requestRefresh() -> Bool { resetAndRefresh() }

    func workbenchWillPause() { reset() }
}

enum WorkbenchManualGenerationRouter {
    /// Resolve built-in controls first. Translation and consciousness-stream
    /// workspaces deliberately do not conform, so their existing Return paths
    /// remain unchanged.
    static var selectedControls: (any WorkbenchManualGenerationControls)? {
        if let controls = DerivedBufferWorkspaceRouter.selectedWorkspace
            as? any WorkbenchManualGenerationControls {
            return controls
        }
        guard ActionPluginHost.shared.primaryGenerationPresentation != nil else {
            return nil
        }
        return ActionPluginHost.shared
    }
}

/// The array stores the stable singleton objects themselves. Returning a new
/// adapter on each lookup would make BufferDeliveryCoordinator reject a valid
/// in-flight generation as changed content.
enum DerivedBufferWorkspaceRouter {
    private static var all: [any DerivedBufferWorkspace] {
        [
            AppleTranslationWorkspace.shared,
            AITextPluginRuntimeRegistry.shared.workspace,
            MarineChromeWorkspace.shared,
            StreamInputWorkspace.shared,
            MyPromptWorkspace.shared,
        ]
    }

    static var selectedWorkspace: (any DerivedBufferWorkspace)? {
        guard let activeKey = BufferPluginSelectionStore.shared.activeKey else {
            return nil
        }
        guard PluginRegistry.shared.isEnabled(activeKey) else { return nil }
        return all.first { $0.workspacePluginKey == activeKey }
    }

    static func setProtectedOnAll(_ protected: Bool) {
        all.forEach { $0.setProtected(protected) }
    }
}
