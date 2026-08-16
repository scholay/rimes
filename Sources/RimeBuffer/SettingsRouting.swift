import Foundation

/// Stable navigation identity. UI code may persist this string, use it in
/// render filenames, or restore it after rebuilding the dynamic extension
/// section; it must never depend on a sidebar row or enum ordinal.
struct SettingsRouteID: RawRepresentable, Hashable, Codable, CustomStringConvertible {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    var description: String { rawValue }
}

struct SettingsSubpageID: RawRepresentable, Hashable, Codable, CustomStringConvertible {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    var description: String { rawValue }
}

enum SettingsCoreRoute: String, CaseIterable, Codable {
    case inputMethod = "core.input-method"
    case appearance = "core.appearance"
    case buffer = "core.buffer"
    case connectors = "core.connectors"
    case plugins = "core.plugins"
    case maintenance = "core.maintenance"

    var id: SettingsRouteID { SettingsRouteID(rawValue: rawValue) }

    var title: String {
        switch self {
        case .inputMethod: return "输入法"
        case .appearance: return "外观"
        case .buffer: return "缓冲区"
        case .connectors: return "连接器"
        case .plugins: return "插件"
        case .maintenance: return "维护"
        }
    }

    var symbolName: String {
        switch self {
        case .inputMethod: return "keyboard"
        case .appearance: return "paintpalette"
        case .buffer: return "tray.full"
        case .connectors: return "link"
        case .plugins: return "puzzlepiece.extension"
        case .maintenance: return "wrench.and.screwdriver"
        }
    }
}

enum PluginManagementSubpage: String, CaseIterable, Codable {
    case all = "all"
    case bufferPlugins = "buffer-plugins"
    case builtInExtensions = "built-in-extensions"

    var id: SettingsSubpageID { SettingsSubpageID(rawValue: rawValue) }

    var title: String {
        switch self {
        case .all: return "全部"
        case .bufferPlugins: return "缓冲插件"
        case .builtInExtensions: return "内置扩展"
        }
    }
}

enum CoreSettingsSubpages {
    static func descriptors(for route: SettingsCoreRoute) -> [SettingsSubpageDescriptor] {
        let values: [(String, String)]
        switch route {
        case .inputMethod:
            values = [
                ("encoding", "输入编码"),
                ("typing-mode", "键入模式"),
                ("dictionaries", "词库"),
            ]
        case .appearance:
            values = [("theme", "主题"), ("size", "尺寸")]
        case .buffer:
            values = [("buffer", "缓冲区")]
        case .connectors:
            values = [
                ("ai-model", "AI 模型"),
                ("local-gateway", "本地网关"),
                ("remote-typing", "隔空传字"),
            ]
        case .plugins:
            return PluginManagementSubpage.allCases.map {
                SettingsSubpageDescriptor(id: $0.id, title: $0.title)
            }
        case .maintenance:
            values = [("update-restart", "更新与重启"), ("logs-data", "日志与数据")]
        }
        return values.map {
            SettingsSubpageDescriptor(id: SettingsSubpageID(rawValue: $0.0), title: $0.1)
        }
    }
}

struct SettingsSubpageDescriptor: Hashable {
    let id: SettingsSubpageID
    let title: String
}

enum SettingsRouteSource: Hashable {
    case core(SettingsCoreRoute)
    case builtInPlugin(PluginKey)
}

struct SettingsRouteDescriptor: Hashable {
    let id: SettingsRouteID
    let title: String
    let symbolName: String
    let source: SettingsRouteSource
    let subpages: [SettingsSubpageDescriptor]

    var isDynamicExtension: Bool {
        if case .builtInPlugin = source { return true }
        return false
    }
}

enum SettingsRouteSectionID: String, Hashable {
    case core
    case extensions
}

struct SettingsRouteSection: Hashable {
    let id: SettingsRouteSectionID
    let title: String
    let routes: [SettingsRouteDescriptor]
}

/// Immutable settings-page contribution snapshot. `PluginRegistry` remains the
/// authority for enablement and controller creation; routing only needs these
/// value types and is therefore usable by smoke tests without NSApplication.
struct SettingsPluginRouteContribution: Hashable {
    let pluginKey: PluginKey
    let settings: PluginSettingsContribution
    let order: Int

    init(pluginKey: PluginKey,
         settings: PluginSettingsContribution,
         order: Int = 0) {
        self.pluginKey = pluginKey
        self.settings = settings
        self.order = order
    }
}

enum SettingsRoutingError: Error, Equatable, CustomStringConvertible {
    case externalPluginCannotContributeSettings(PluginKey)
    case invalidIdentifier(String)
    case reservedNamespace(String)
    case emptyTitle(routeID: String)
    case duplicateRouteID(SettingsRouteID)
    case duplicateSubpageID(routeID: SettingsRouteID, subpageID: SettingsSubpageID)

    var description: String {
        switch self {
        case let .externalPluginCannotContributeSettings(key):
            return "external plugin cannot contribute settings UI: \(key)"
        case let .invalidIdentifier(id):
            return "invalid settings identifier: \(id)"
        case let .reservedNamespace(id):
            return "plugin settings identifier uses a reserved namespace: \(id)"
        case let .emptyTitle(routeID):
            return "settings route has an empty title: \(routeID)"
        case let .duplicateRouteID(id):
            return "duplicate settings route: \(id)"
        case let .duplicateSubpageID(routeID, subpageID):
            return "duplicate settings subpage \(subpageID) in \(routeID)"
        }
    }
}

struct SettingsRouteCatalog: Equatable {
    static let extensionNamespace = "extension."

    let coreRoutes: [SettingsRouteDescriptor]
    let extensionRoutes: [SettingsRouteDescriptor]

    var orderedRoutes: [SettingsRouteDescriptor] { coreRoutes + extensionRoutes }

    var sections: [SettingsRouteSection] {
        var result = [
            SettingsRouteSection(id: .core, title: "设置", routes: coreRoutes),
        ]
        if !extensionRoutes.isEmpty {
            result.append(SettingsRouteSection(id: .extensions,
                                               title: "扩展",
                                               routes: extensionRoutes))
        }
        return result
    }

    init(contributions: [SettingsPluginRouteContribution] = []) throws {
        coreRoutes = Self.makeCoreRoutes()

        var seenRouteIDs = Set(coreRoutes.map(\.id))
        var dynamic: [(order: Int, route: SettingsRouteDescriptor)] = []
        dynamic.reserveCapacity(contributions.count)

        for contribution in contributions {
            guard contribution.pluginKey.domain == .builtIn else {
                throw SettingsRoutingError.externalPluginCannotContributeSettings(
                    contribution.pluginKey
                )
            }

            let localID = contribution.settings.id
            try Self.validatePluginRouteIdentifier(localID)
            let routeID = SettingsRouteID(rawValue: Self.extensionNamespace + localID)
            guard seenRouteIDs.insert(routeID).inserted else {
                throw SettingsRoutingError.duplicateRouteID(routeID)
            }

            let title = contribution.settings.title
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else {
                throw SettingsRoutingError.emptyTitle(routeID: routeID.rawValue)
            }

            let subpages = try Self.makeSubpages(
                contribution.settings.subpages,
                routeID: routeID
            )
            dynamic.append((
                contribution.order,
                SettingsRouteDescriptor(
                    id: routeID,
                    title: title,
                    symbolName: contribution.settings.symbolName,
                    source: .builtInPlugin(contribution.pluginKey),
                    subpages: subpages
                )
            ))
        }

        extensionRoutes = dynamic.sorted { lhs, rhs in
            if lhs.order != rhs.order { return lhs.order < rhs.order }
            return lhs.route.id.rawValue < rhs.route.id.rawValue
        }.map(\.route)
    }

    /// Direct adapter for PluginRegistry.enabledSettingsContributions(). The
    /// snapshot order is retained and provides deterministic sidebar ordering.
    init(pluginContributions: [(pluginKey: PluginKey,
                                contribution: PluginSettingsContribution)]) throws {
        try self.init(contributions: pluginContributions.enumerated().map { index, item in
            SettingsPluginRouteContribution(pluginKey: item.pluginKey,
                                            settings: item.contribution,
                                            order: index)
        })
    }

    func route(for id: SettingsRouteID) -> SettingsRouteDescriptor? {
        orderedRoutes.first { $0.id == id }
    }

    func contains(_ id: SettingsRouteID) -> Bool {
        route(for: id) != nil
    }

    private static func makeCoreRoutes() -> [SettingsRouteDescriptor] {
        SettingsCoreRoute.allCases.map { route in
            return SettingsRouteDescriptor(id: route.id,
                                           title: route.title,
                                           symbolName: route.symbolName,
                                           source: .core(route),
                                           subpages: CoreSettingsSubpages.descriptors(for: route))
        }
    }

    private static func makeSubpages(_ raw: [PluginSettingsSubpage],
                                     routeID: SettingsRouteID) throws
        -> [SettingsSubpageDescriptor] {
        var seen = Set<SettingsSubpageID>()
        return try raw.map { item in
            try validateIdentifier(item.id)
            let id = SettingsSubpageID(rawValue: item.id)
            guard seen.insert(id).inserted else {
                throw SettingsRoutingError.duplicateSubpageID(routeID: routeID,
                                                              subpageID: id)
            }
            let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else {
                throw SettingsRoutingError.emptyTitle(
                    routeID: "\(routeID.rawValue)#\(id.rawValue)"
                )
            }
            return SettingsSubpageDescriptor(id: id, title: title)
        }
    }

    private static func validatePluginRouteIdentifier(_ id: String) throws {
        try validateIdentifier(id)
        if id == "core" || id.hasPrefix("core.")
            || id == "extension" || id.hasPrefix(extensionNamespace) {
            throw SettingsRoutingError.reservedNamespace(id)
        }
    }

    private static func validateIdentifier(_ id: String) throws {
        let bytes = Array(id.utf8)
        guard !bytes.isEmpty,
              bytes.count <= 128,
              isASCIILetterOrDigit(bytes[0]),
              bytes.allSatisfy({ byte in
                  isASCIILetterOrDigit(byte)
                      || byte == 46  // .
                      || byte == 95  // _
                      || byte == 45  // -
              }) else {
            throw SettingsRoutingError.invalidIdentifier(id)
        }
    }

    private static func isASCIILetterOrDigit(_ byte: UInt8) -> Bool {
        (65...90).contains(byte)
            || (97...122).contains(byte)
            || (48...57).contains(byte)
    }
}

/// Pure navigation state for both the vertical route and each route's
/// horizontal subpage. Reconciliation is called after PluginRegistry changes.
struct SettingsNavigationState: Equatable {
    private(set) var currentRouteID: SettingsRouteID
    private(set) var selectedSubpageByRoute: [SettingsRouteID: SettingsSubpageID]

    init(catalog: SettingsRouteCatalog,
         initialRouteID: SettingsRouteID = SettingsCoreRoute.inputMethod.id) {
        currentRouteID = catalog.contains(initialRouteID)
            ? initialRouteID
            : SettingsCoreRoute.inputMethod.id
        selectedSubpageByRoute = [:]
        ensureValidSubpage(for: currentRouteID, catalog: catalog)
    }

    @discardableResult
    mutating func selectRoute(_ routeID: SettingsRouteID,
                              catalog: SettingsRouteCatalog) -> Bool {
        guard catalog.contains(routeID) else { return false }
        currentRouteID = routeID
        ensureValidSubpage(for: routeID, catalog: catalog)
        return true
    }

    @discardableResult
    mutating func selectSubpage(_ subpageID: SettingsSubpageID,
                                for routeID: SettingsRouteID? = nil,
                                catalog: SettingsRouteCatalog) -> Bool {
        let targetRouteID = routeID ?? currentRouteID
        guard let route = catalog.route(for: targetRouteID),
              route.subpages.contains(where: { $0.id == subpageID }) else {
            return false
        }
        selectedSubpageByRoute[targetRouteID] = subpageID
        return true
    }

    func selectedSubpage(for routeID: SettingsRouteID? = nil) -> SettingsSubpageID? {
        selectedSubpageByRoute[routeID ?? currentRouteID]
    }

    /// Reconcile after enabled settings contributions change. Disabling the
    /// currently visible extension returns the user to 插件 ▸ 内置扩展, where it
    /// can be re-enabled. Removed subpages fall back to their route's first tab.
    mutating func reconcile(with catalog: SettingsRouteCatalog) {
        selectedSubpageByRoute = selectedSubpageByRoute.filter { routeID, subpageID in
            guard let route = catalog.route(for: routeID) else { return false }
            return route.subpages.contains(where: { $0.id == subpageID })
        }

        if !catalog.contains(currentRouteID) {
            if currentRouteID.rawValue.hasPrefix(SettingsRouteCatalog.extensionNamespace) {
                currentRouteID = SettingsCoreRoute.plugins.id
                selectedSubpageByRoute[currentRouteID] =
                    PluginManagementSubpage.builtInExtensions.id
            } else {
                currentRouteID = SettingsCoreRoute.inputMethod.id
            }
        }
        ensureValidSubpage(for: currentRouteID, catalog: catalog)
    }

    private mutating func ensureValidSubpage(for routeID: SettingsRouteID,
                                             catalog: SettingsRouteCatalog) {
        guard let route = catalog.route(for: routeID),
              let first = route.subpages.first else {
            selectedSubpageByRoute[routeID] = nil
            return
        }
        if let selected = selectedSubpageByRoute[routeID],
           route.subpages.contains(where: { $0.id == selected }) {
            return
        }
        selectedSubpageByRoute[routeID] = first.id
    }
}

/// Executable pure-model coverage. Kept out of main.swift so CI or a future
/// command can call it without instantiating NSApplication.
func runSettingsRoutingSmokeTest() -> Bool {
    func fail(_ message: String) -> Bool {
        print("FAILED: settings routing \(message)")
        return false
    }

    func contribution(pluginID: String,
                      pageID: String,
                      title: String,
                      subpages: [(String, String)],
                      order: Int = 0,
                      domain: PluginDomain = .builtIn)
        -> SettingsPluginRouteContribution {
        SettingsPluginRouteContribution(
            pluginKey: PluginKey(domain: domain, rawID: pluginID),
            settings: PluginSettingsContribution(
                id: pageID,
                title: title,
                symbolName: "chart.bar",
                subpages: subpages.map { PluginSettingsSubpage(id: $0.0, title: $0.1) }
            ),
            order: order
        )
    }

    do {
        let statistics = contribution(
            pluginID: "statistics",
            pageID: "statistics",
            title: "统计",
            subpages: [("daily", "每日"), ("heatmap", "热力图")],
            order: 10
        )
        let chordLearning = contribution(
            pluginID: "feiyao-learning",
            pageID: "feiyao-learning",
            title: "飞耀互击学习",
            subpages: [("overview", "概览")],
            order: 20
        )
        let catalog = try SettingsRouteCatalog(
            contributions: [chordLearning, statistics]
        )

        guard catalog.coreRoutes.map(\.id) == SettingsCoreRoute.allCases.map(\.id),
              catalog.coreRoutes.map(\.title)
                == ["输入法", "外观", "缓冲区", "连接器", "插件", "维护"],
              catalog.extensionRoutes.map(\.id.rawValue)
                == ["extension.statistics", "extension.feiyao-learning"],
              catalog.sections.map(\.id) == [.core, .extensions],
              catalog.route(for: SettingsCoreRoute.plugins.id)?.subpages.map(\.id)
                == PluginManagementSubpage.allCases.map(\.id),
              catalog.route(for: SettingsCoreRoute.appearance.id)?.subpages.map(\.id)
                == [
                    SettingsSubpageID(rawValue: "theme"),
                    SettingsSubpageID(rawValue: "size"),
                ],
              catalog.route(for: SettingsCoreRoute.buffer.id)?.subpages.map(\.id)
                == [SettingsSubpageID(rawValue: "buffer")],
              catalog.route(for: SettingsCoreRoute.connectors.id)?.subpages.map(\.id)
                == [
                    SettingsSubpageID(rawValue: "ai-model"),
                    SettingsSubpageID(rawValue: "local-gateway"),
                    SettingsSubpageID(rawValue: "remote-typing"),
                ] else {
            return fail("stable route catalog")
        }

        var navigation = SettingsNavigationState(catalog: catalog)
        guard navigation.currentRouteID == SettingsCoreRoute.inputMethod.id,
              navigation.selectRoute(SettingsCoreRoute.plugins.id, catalog: catalog),
              navigation.selectedSubpage() == PluginManagementSubpage.all.id,
              navigation.selectSubpage(PluginManagementSubpage.bufferPlugins.id,
                                       catalog: catalog),
              navigation.selectRoute(SettingsRouteID(rawValue: "extension.statistics"),
                                     catalog: catalog),
              navigation.selectedSubpage() == SettingsSubpageID(rawValue: "daily"),
              navigation.selectSubpage(SettingsSubpageID(rawValue: "heatmap"),
                                       catalog: catalog) else {
            return fail("route and horizontal subpage selection")
        }

        let withoutStatistics = try SettingsRouteCatalog(
            contributions: [chordLearning]
        )
        navigation.reconcile(with: withoutStatistics)
        guard navigation.currentRouteID == SettingsCoreRoute.plugins.id,
              navigation.selectedSubpage()
                == PluginManagementSubpage.builtInExtensions.id else {
            return fail("disabled dynamic route fallback")
        }

        let statisticsWithoutHeatmap = contribution(
            pluginID: "statistics",
            pageID: "statistics",
            title: "统计",
            subpages: [("daily", "每日")]
        )
        var subpageNavigation = SettingsNavigationState(catalog: catalog)
        _ = subpageNavigation.selectRoute(
            SettingsRouteID(rawValue: "extension.statistics"),
            catalog: catalog
        )
        _ = subpageNavigation.selectSubpage(
            SettingsSubpageID(rawValue: "heatmap"),
            catalog: catalog
        )
        let reducedCatalog = try SettingsRouteCatalog(
            contributions: [statisticsWithoutHeatmap]
        )
        subpageNavigation.reconcile(with: reducedCatalog)
        guard subpageNavigation.currentRouteID
                == SettingsRouteID(rawValue: "extension.statistics"),
              subpageNavigation.selectedSubpage()
                == SettingsSubpageID(rawValue: "daily") else {
            return fail("removed subpage fallback")
        }

        do {
            _ = try SettingsRouteCatalog(contributions: [
                statistics,
                contribution(pluginID: "other",
                             pageID: "statistics",
                             title: "Duplicate",
                             subpages: []),
            ])
            return fail("duplicate route was accepted")
        } catch SettingsRoutingError.duplicateRouteID(
            SettingsRouteID(rawValue: "extension.statistics")
        ) {
        }

        for reserved in ["core.fake", "extension.fake"] {
            do {
                _ = try SettingsRouteCatalog(contributions: [
                    contribution(pluginID: "bad",
                                 pageID: reserved,
                                 title: "Bad",
                                 subpages: []),
                ])
                return fail("reserved namespace was accepted: \(reserved)")
            } catch SettingsRoutingError.reservedNamespace(reserved) {
            }
        }

        do {
            _ = try SettingsRouteCatalog(contributions: [
                contribution(pluginID: "bad-subpage",
                             pageID: "bad-subpage",
                             title: "Bad",
                             subpages: [("same", "One"), ("same", "Two")]),
            ])
            return fail("duplicate subpage was accepted")
        } catch SettingsRoutingError.duplicateSubpageID(
            routeID: SettingsRouteID(rawValue: "extension.bad-subpage"),
            subpageID: SettingsSubpageID(rawValue: "same")
        ) {
        }

        do {
            _ = try SettingsRouteCatalog(contributions: [
                contribution(pluginID: "external",
                             pageID: "external",
                             title: "External",
                             subpages: [],
                             domain: .externalActionV1),
            ])
            return fail("external plugin settings UI was accepted")
        } catch SettingsRoutingError.externalPluginCannotContributeSettings(
            PluginKey(domain: .externalActionV1, rawID: "external")
        ) {
        }
    } catch {
        return fail("threw \(error)")
    }

    print("settings routing smoke OK")
    return true
}
