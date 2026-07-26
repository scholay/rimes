import AppKit
import Foundation

extension Notification.Name {
    static let pluginRegistryDidChange = Notification.Name("RimeBuffer.PluginRegistry.didChange")
    static let externalActionManifestSetDidChange = Notification.Name(
        "RimeBuffer.ExternalActionManifestSet.didChange"
    )
    static let activeBufferPluginDidChange = Notification.Name(
        "RimeBuffer.ActiveBufferPlugin.didChange"
    )
}

enum PluginSource: String, Codable, CaseIterable {
    case builtIn
    case external

    var title: String {
        switch self {
        case .builtIn: return "内置扩展"
        case .external: return "外部插件"
        }
    }
}

enum PluginDomain: String, Hashable, Codable {
    case builtIn
    case externalActionV1
}

/// The domain is part of identity so a future external package cannot shadow
/// a compiled-in module that happens to use the same raw identifier.
struct PluginKey: Hashable, Codable, CustomStringConvertible {
    let domain: PluginDomain
    let rawID: String

    var description: String { "\(domain.rawValue):\(rawID)" }
}

/// Capabilities are deliberately additive. A plugin can contribute a settings
/// page and observe metrics at the same time; forcing it into one exclusive
/// "type" would make the product model diverge from the actual runtime.
enum PluginCapability: String, Codable, CaseIterable, Hashable {
    case bufferAction
    case settingsPage
    case keyMetrics
    case commitMetrics
    case chordLearning
    case localStorage
    case connector

    var title: String {
        switch self {
        case .bufferAction: return "缓冲区动作"
        case .settingsPage: return "设置页"
        case .keyMetrics: return "按键统计"
        case .commitMetrics: return "输入速度"
        case .chordLearning: return "并击学习"
        case .localStorage: return "本地数据"
        case .connector: return "连接器"
        }
    }
}

struct PluginSettingsSubpage: Hashable {
    let id: String
    let title: String
}

struct PluginSettingsContribution: Hashable {
    let id: String
    let title: String
    let symbolName: String
    let subpages: [PluginSettingsSubpage]
}

struct PluginDescriptor: Identifiable, Hashable {
    let key: PluginKey
    /// Preserved external protocol identity. Never derive ActionPluginKey or
    /// Buffer metadata from the registry's namespaced `key`.
    let wireID: String?
    let name: String
    /// Compact SF Symbol identity shared by Settings and the workbench
    /// selector. External v1 plugins inherit their first action symbol so old
    /// manifests gain an icon without a schema change.
    let symbolName: String
    let version: String
    let summary: String
    let source: PluginSource
    let capabilities: Set<PluginCapability>
    let settings: PluginSettingsContribution?
    let canUninstall: Bool

    var id: PluginKey { key }
}

/// Only trusted, compiled-in modules conform to this protocol. External Action
/// Plugins continue to use the loopback wire protocol and can never inject an
/// arbitrary AppKit view into the input-method process.
protocol InternalPlugin: AnyObject {
    var descriptor: PluginDescriptor { get }
    func start()
    func stop()
    func makeSettingsViewController(subpageID: String) -> NSViewController?
}

struct RegisteredPlugin: Identifiable, Equatable {
    let descriptor: PluginDescriptor
    let isEnabled: Bool

    var id: PluginKey { descriptor.key }
}

enum PluginVisualIdentity {
    static let fallbackSymbolName = "puzzlepiece.extension"
    private static let legacyFallbackSymbolName = "puzzlepiece"
    static let defaultWorkbenchSymbolName = "square.grid.2x2"

    static func resolvedSymbolName(_ preferred: String?) -> String {
        if let preferred = preferred?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !preferred.isEmpty,
           NSImage(systemSymbolName: preferred,
                   accessibilityDescription: nil) != nil {
            return preferred
        }
        if NSImage(systemSymbolName: fallbackSymbolName,
                   accessibilityDescription: nil) != nil {
            return fallbackSymbolName
        }
        return legacyFallbackSymbolName
    }

    static func image(symbolName: String,
                      accessibilityDescription: String,
                      pointSize: CGFloat,
                      weight: NSFont.Weight = .regular) -> NSImage? {
        let resolved = resolvedSymbolName(symbolName)
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize,
                                                        weight: weight)
        let image = NSImage(
            systemSymbolName: resolved,
            accessibilityDescription: accessibilityDescription
        )?.withSymbolConfiguration(configuration)
        image?.isTemplate = true
        return image
    }
}

struct BufferPluginMenuEntry: Equatable {
    let key: PluginKey?
    let title: String
    let symbolName: String
}

enum BufferPluginMenuCatalog {
    static let defaultTitle = "Default"

    /// Settings owns the enabled set. The workbench only chooses an active
    /// owner from that set, plus the explicit Default (no-plugin) state.
    static func entries(from plugins: [RegisteredPlugin]) -> [BufferPluginMenuEntry] {
        let enabled = plugins.compactMap { plugin -> BufferPluginMenuEntry? in
            guard plugin.isEnabled,
                  plugin.descriptor.capabilities.contains(.bufferAction) else {
                return nil
            }
            return BufferPluginMenuEntry(
                key: plugin.descriptor.key,
                title: plugin.descriptor.name,
                symbolName: plugin.descriptor.symbolName
            )
        }
        return [
            BufferPluginMenuEntry(
                key: nil,
                title: defaultTitle,
                symbolName: PluginVisualIdentity.defaultWorkbenchSymbolName
            ),
        ] + enabled
    }
}

enum BufferPluginActivationError: LocalizedError, Equatable {
    case unavailable(PluginKey)
    case stateChanged(PluginKey)

    var errorDescription: String? {
        switch self {
        case let .unavailable(key):
            return "缓冲插件不可用：\(key)"
        case let .stateChanged(key):
            return "缓冲插件状态已经变化，请重试：\(key)"
        }
    }
}

/// Enablement answers whether code may load; this store answers which one
/// buffer workspace currently owns the exclusive action surface. Statistics,
/// learning and other non-buffer capabilities remain freely composable.
final class BufferPluginSelectionStore {
    static let shared = BufferPluginSelectionStore()

    private enum Key {
        static let hasSelection = "plugins.buffer.active.hasValue.v1"
        static let domain = "plugins.buffer.active.domain.v1"
        static let rawID = "plugins.buffer.active.rawID.v1"
        // Once this marker exists, a false value is an intentional Default
        // owner and later plugin install/enable events must not replace it.
        static let selectionSemanticsV2 = "plugins.buffer.active.semantics.v2"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var activeKey: PluginKey? {
        guard defaults.bool(forKey: Key.hasSelection),
              let domainRaw = defaults.string(forKey: Key.domain),
              let domain = PluginDomain(rawValue: domainRaw),
              let rawID = defaults.string(forKey: Key.rawID),
              !rawID.isEmpty else { return nil }
        return PluginKey(domain: domain, rawID: rawID)
    }

    func isSelected(_ key: PluginKey) -> Bool {
        activeKey == key
    }

    func isSelectedExternal(pluginID: String) -> Bool {
        activeKey == PluginKey(domain: .externalActionV1, rawID: pluginID)
    }

    /// Validated user-facing selection. Missing, disabled or non-buffer
    /// plugins cannot replace the previous valid owner.
    @discardableResult
    func select(_ key: PluginKey,
                among plugins: [RegisteredPlugin]) -> Bool {
        guard plugins.contains(where: {
            $0.descriptor.key == key
                && $0.isEnabled
                && $0.descriptor.capabilities.contains(.bufferAction)
        }) else { return false }
        persist(key)
        return true
    }

    func clear() {
        persist(nil)
    }

    func clearIfSelected(_ key: PluginKey) {
        guard activeKey == key else { return }
        persist(nil)
    }

    /// One-time compatibility migration: an existing enabled external Action
    /// Plugin remains the initial owner. Translation is never activated merely
    /// by upgrading the app, so local text is not processed unexpectedly.
    func migrateDefaultIfNeeded(from plugins: [RegisteredPlugin]) {
        if defaults.bool(forKey: Key.hasSelection) {
            defaults.set(true, forKey: Key.selectionSemanticsV2)
            reconcile(with: plugins)
            return
        }
        let external = plugins.first {
            $0.isEnabled
                && $0.descriptor.source == .external
                && $0.descriptor.capabilities.contains(.bufferAction)
        }
        let hasStoredSelection = defaults.object(forKey: Key.hasSelection) != nil
        if hasStoredSelection && defaults.bool(forKey: Key.selectionSemanticsV2) {
            return
        }
        // This method is called once at process startup. Preserve a legacy
        // enabled external owner when it already exists; otherwise establish
        // Default now so a later Settings enable/install action changes only
        // the enabled set, never the active owner.
        persist(external?.descriptor.key)
    }

    func reconcile(with plugins: [RegisteredPlugin]) {
        guard let activeKey else { return }
        if let current = plugins.first(where: { $0.descriptor.key == activeKey }) {
            if !current.isEnabled
                || !current.descriptor.capabilities.contains(.bufferAction) {
                persist(nil)
            }
            return
        }
        // External manifests may temporarily disappear while another process
        // replaces or restores their directory. Preserve the desired owner so
        // it resumes automatically; explicit disable/uninstall paths revoke it
        // via clearIfSelected(). Missing built-ins are not recoverable.
        if activeKey.domain != .externalActionV1 { persist(nil) }
    }

    private func persist(_ key: PluginKey?, notify: Bool = true) {
        let previous = activeKey
        let hasStoredSelection = defaults.object(forKey: Key.hasSelection) != nil
        let hasV2Semantics = defaults.bool(forKey: Key.selectionSemanticsV2)
        guard previous != key || !hasStoredSelection || !hasV2Semantics else {
            return
        }
        defaults.set(key != nil, forKey: Key.hasSelection)
        defaults.set(key?.domain.rawValue, forKey: Key.domain)
        defaults.set(key?.rawID, forKey: Key.rawID)
        defaults.set(true, forKey: Key.selectionSemanticsV2)
        guard notify, previous != key else { return }
        NotificationCenter.default.post(name: .activeBufferPluginDidChange,
                                        object: self,
                                        userInfo: ["previous": previous as Any,
                                                   "current": key as Any])
    }
}

final class PluginRegistry {
    static let shared = PluginRegistry(internalPlugins: BuiltInPlugins.makeAll())

    static let disabledInternalPluginIDsKey = "plugins.internal.disabledIDs"

    private let defaults: UserDefaults
    private let externalManager: ActionPluginManager
    private let bufferPluginSelection: BufferPluginSelectionStore
    private var internalPlugins: [String: any InternalPlugin] = [:]
    private var disabledInternalIDs: Set<String>
    private var actionPluginObserver: NSObjectProtocol?
    private var manifestSetObserver: NSObjectProtocol?

    init(internalPlugins plugins: [any InternalPlugin],
         defaults: UserDefaults = .standard,
         externalManager: ActionPluginManager = .shared,
         bufferPluginSelection: BufferPluginSelectionStore = .shared) {
        self.defaults = defaults
        self.externalManager = externalManager
        self.bufferPluginSelection = bufferPluginSelection
        disabledInternalIDs = Set(
            defaults.stringArray(forKey: Self.disabledInternalPluginIDsKey) ?? []
        )
        for plugin in plugins {
            let descriptor = plugin.descriptor
            precondition(descriptor.key.domain == .builtIn,
                         "Internal plugin must use the built-in domain")
            precondition(descriptor.source == .builtIn,
                         "Internal plugin descriptor source must be built-in")
            precondition(descriptor.wireID == nil,
                         "Internal plugin cannot claim an Action Plugin wire ID")
            precondition(internalPlugins[descriptor.key.rawID] == nil,
                         "Duplicate internal plugin ID: \(descriptor.key.rawID)")
            internalPlugins[descriptor.key.rawID] = plugin
        }
        // Drop stale IDs so renamed/removed built-ins do not accumulate in
        // preferences forever.
        disabledInternalIDs.formIntersection(internalPlugins.keys)
        persistInternalEnablement()
        for plugin in internalPlugins.values where !disabledInternalIDs.contains(plugin.descriptor.key.rawID) {
            plugin.start()
        }
        actionPluginObserver = NotificationCenter.default.addObserver(
            forName: ActionPluginManager.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  notification.userInfo?[ActionPluginManager.rootPathUserInfoKey] as? String
                    == self.externalManager.rootURL.path else { return }
            if let pluginID = notification.userInfo?[ActionPluginManager.changedPluginIDUserInfoKey]
                as? String {
                let key = PluginKey(domain: .externalActionV1, rawID: pluginID)
                let remainsSelectable = self.externalManager.listInstalledPlugins().contains {
                    $0.id == pluginID && $0.isEnabled
                }
                if !remainsSelectable {
                    self.bufferPluginSelection.clearIfSelected(key)
                }
            }
            self.notifyChange()
        }
        manifestSetObserver = NotificationCenter.default.addObserver(
            forName: .externalActionManifestSetDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  notification.userInfo?[ActionPluginManager.rootPathUserInfoKey] as? String
                    == self.externalManager.rootURL.path else { return }
            self.notifyChange()
        }
    }

    deinit {
        if let actionPluginObserver {
            NotificationCenter.default.removeObserver(actionPluginObserver)
        }
        if let manifestSetObserver {
            NotificationCenter.default.removeObserver(manifestSetObserver)
        }
        for plugin in internalPlugins.values { plugin.stop() }
    }

    func allPlugins() -> [RegisteredPlugin] {
        let builtIns = internalPlugins.values.map { plugin in
            RegisteredPlugin(
                descriptor: plugin.descriptor,
                isEnabled: !disabledInternalIDs.contains(plugin.descriptor.key.rawID)
            )
        }
        let external = externalManager.listInstalledPlugins().map { managed in
            RegisteredPlugin(
                descriptor: PluginDescriptor(
                    key: PluginKey(domain: .externalActionV1, rawID: managed.id),
                    wireID: managed.id,
                    name: managed.manifest.name,
                    symbolName: PluginVisualIdentity.resolvedSymbolName(
                        managed.actions.first?.symbol
                    ),
                    version: managed.manifest.version ?? "1",
                    summary: "为缓冲工作台提供 \(managed.actions.count) 个动作",
                    source: .external,
                    capabilities: [.bufferAction],
                    settings: nil,
                    canUninstall: true
                ),
                isEnabled: managed.isEnabled
            )
        }
        return (builtIns + external).sorted { lhs, rhs in
            if lhs.descriptor.source != rhs.descriptor.source {
                return lhs.descriptor.source == .builtIn
            }
            let order = lhs.descriptor.name.localizedCaseInsensitiveCompare(rhs.descriptor.name)
            return order == .orderedSame
                ? lhs.id.description < rhs.id.description
                : order == .orderedAscending
        }
    }

    func plugins(source: PluginSource? = nil,
                 capability: PluginCapability? = nil) -> [RegisteredPlugin] {
        allPlugins().filter { item in
            guard source == nil || item.descriptor.source == source else {
                return false
            }
            guard let capability else {
                return true
            }
            return item.descriptor.capabilities.contains(capability)
        }
    }

    func enabledSettingsContributions() -> [(pluginKey: PluginKey, contribution: PluginSettingsContribution)] {
        internalPlugins.values.compactMap { plugin in
            // Buffer plugins are configured from the core plugin/workbench
            // surfaces. They must never masquerade as dynamic extensions,
            // even if a future descriptor accidentally carries page metadata.
            guard !disabledInternalIDs.contains(plugin.descriptor.key.rawID),
                  !plugin.descriptor.capabilities.contains(.bufferAction),
                  let settings = plugin.descriptor.settings else { return nil }
            return (plugin.descriptor.key, settings)
        }.sorted {
            $0.contribution.title.localizedStandardCompare($1.contribution.title) == .orderedAscending
        }
    }

    func isEnabled(_ key: PluginKey) -> Bool {
        switch key.domain {
        case .builtIn:
            return internalPlugins[key.rawID] != nil
                && !disabledInternalIDs.contains(key.rawID)
        case .externalActionV1:
            return externalManager.isEnabled(pluginID: key.rawID)
        }
    }

    func setEnabled(_ enabled: Bool, for key: PluginKey) throws {
        if key.domain == .builtIn, let plugin = internalPlugins[key.rawID] {
            let changed: Bool
            if enabled {
                changed = disabledInternalIDs.remove(key.rawID) != nil
                if changed { plugin.start() }
            } else {
                changed = disabledInternalIDs.insert(key.rawID).inserted
                if changed { plugin.stop() }
            }
            guard changed else { return }
            if !enabled { bufferPluginSelection.clearIfSelected(key) }
            persistInternalEnablement()
            notifyChange()
            return
        }
        guard key.domain == .externalActionV1 else { return }
        try externalManager.setEnabled(enabled, pluginID: key.rawID)
        if !enabled { bufferPluginSelection.clearIfSelected(key) }
    }

    /// Applies the workbench's exclusive active owner selection. Settings
    /// separately manages the multi-select enablement set; a stale menu item
    /// can never resurrect a plugin that Settings has just disabled.
    func setBufferPluginActive(_ active: Bool, for key: PluginKey) throws {
        guard active else {
            // A stale off event from a row that is no longer selected must not
            // close the newer owner.
            bufferPluginSelection.clearIfSelected(key)
            return
        }

        guard allPlugins().contains(where: {
            $0.descriptor.key == key
                && $0.isEnabled
                && $0.descriptor.capabilities.contains(.bufferAction)
        }) else {
            throw BufferPluginActivationError.unavailable(key)
        }

        guard bufferPluginSelection.select(key, among: allPlugins()) else {
            throw BufferPluginActivationError.stateChanged(key)
        }
    }

    func makeSettingsViewController(pluginKey: PluginKey,
                                    subpageID: String) -> NSViewController? {
        guard pluginKey.domain == .builtIn,
              !disabledInternalIDs.contains(pluginKey.rawID) else { return nil }
        return internalPlugins[pluginKey.rawID]?.makeSettingsViewController(subpageID: subpageID)
    }

    /// Declarative plugin configuration is available independently from
    /// enablement: users may prepare credentials or preferences before adding
    /// a plugin to the workbench. External packages still cannot inject UI;
    /// only host-owned catalog entries (currently Marine) are eligible.
    func hasConfiguration(for pluginKey: PluginKey) -> Bool {
        if pluginKey.domain == .builtIn,
           internalPlugins[pluginKey.rawID]
            is any PluginConfigurationProviding {
            return true
        }
        do {
            return try PluginConfigurationCatalog.makeModel(
                pluginID: pluginKey.rawID
            ) != nil
        } catch {
            return false
        }
    }

    func makePluginConfigurationViewController(
        pluginKey: PluginKey
    ) throws -> NSViewController? {
        if pluginKey.domain == .builtIn,
           let provider = internalPlugins[pluginKey.rawID]
            as? any PluginConfigurationProviding {
            return try provider.makePluginConfigurationViewController()
        }
        guard let model = try PluginConfigurationCatalog.makeModel(
            pluginID: pluginKey.rawID
        ) else {
            return nil
        }
        return PluginConfigurationViewController(model: model)
    }

    func internalPlugin(pluginKey: PluginKey) -> (any InternalPlugin)? {
        guard pluginKey.domain == .builtIn else { return nil }
        return internalPlugins[pluginKey.rawID]
    }

    private func persistInternalEnablement() {
        defaults.set(disabledInternalIDs.sorted(),
                     forKey: Self.disabledInternalPluginIDsKey)
    }

    private func notifyChange() {
        // Registry mutations update availability only. Startup owns the sole
        // compatibility migration that may choose a legacy external owner.
        bufferPluginSelection.reconcile(with: allPlugins())
        NotificationCenter.default.post(name: .pluginRegistryDidChange, object: self)
    }
}
