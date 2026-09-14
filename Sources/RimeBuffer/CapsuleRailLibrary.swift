import Foundation

/// The Capsule rail's tabs. Recent is the local clipboard history; every other
/// tab is one kind of saved Capsule entry, read-only in the rail.
enum CapsuleRailTab: Hashable {
    case recent
    case saved(CapsuleEntryKind)

    /// Most-used first. Password is last because nothing leaves it from the
    /// rail: it can only be opened in the manager.
    static let ordered: [CapsuleRailTab] = [
        .recent,
        .saved(.note),
        .saved(.image),
        .saved(.pdf),
        .saved(.skill),
        .saved(.password),
    ]

    var label: String {
        switch self {
        case .recent: return "最近"
        case let .saved(kind): return kind.tabLabel
        }
    }

    var savedKind: CapsuleEntryKind? {
        if case let .saved(kind) = self { return kind }
        return nil
    }

    /// The tab `offset` steps away, wrapping at both ends.
    func cycled(by offset: Int) -> CapsuleRailTab {
        let tabs = Self.ordered
        guard let index = tabs.firstIndex(of: self) else { return .recent }
        let count = tabs.count
        return tabs[((index + offset) % count + count) % count]
    }
}

/// One saved entry as the rail shows it.
struct CapsuleRailEntry: Equatable, Identifiable {
    let id: UUID
    let kind: CapsuleEntryKind
    let title: String
    let preview: String
    let updatedAt: Date
    /// Note text, or the absolute path of an Image, PDF or Skill. Always nil
    /// for a password: its secret stays encrypted on disk.
    let payload: String?
    /// Title plus body for ordinary entries; only the title for a password.
    let searchText: String
}

enum CapsuleRailActivationRules {
    enum Action: Equatable {
        /// Plain text: straight into the target box through the focus token.
        case insertText
        /// A file: onto the pasteboard, then pasted into the target app.
        case pasteFile
        /// Nothing leaves the rail.
        case refuse
    }

    static func action(for kind: CapsuleEntryKind) -> Action {
        switch kind {
        case .note: return .insertText
        case .image, .pdf, .skill: return .pasteFile
        case .password: return .refuse
        }
    }

    static func allowsCopy(_ kind: CapsuleEntryKind) -> Bool {
        action(for: kind) != .refuse
    }
}

enum CapsuleRailCountText {
    /// The header count, singular for exactly one.
    static func items(_ count: Int) -> String {
        count == 1 ? "1 ITEM" : "\(count) ITEMS"
    }
}

enum CapsuleRailSearchRules {
    static func filter(_ entries: [CapsuleRailEntry],
                       query: String) -> [CapsuleRailEntry] {
        let terms = query.split(whereSeparator: \Character.isWhitespace)
            .map(String.init)
        guard !terms.isEmpty else { return entries }
        return entries.filter { entry in
            terms.allSatisfy {
                entry.searchText.localizedCaseInsensitiveContains($0)
            }
        }
    }
}

/// The saved entries behind the rail's Capsule tabs. Reading every Markdown
/// file can take a while on a large library, so loads run on a background
/// queue and the rail renders whatever was last published.
final class CapsuleRailLibrary {
    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed
    }

    typealias Loader = () -> (content: Result<[CapsuleRailEntry], Error>,
                               passwords: Result<[CapsuleRailEntry], Error>)

    var onChange: (() -> Void)?
    let savedIndex: CapsuleRailSavedIndex

    private let loader: Loader
    private let queue = DispatchQueue(
        label: "RIMES.CapsuleRail.library",
        qos: .userInitiated
    )
    private var generation: UInt64 = 0
    private var byKind: [CapsuleEntryKind: [CapsuleRailEntry]] = [:]
    private var stateByKind: [CapsuleEntryKind: LoadState] = [:]
    private var notePayloads: Set<String> = []
    private var contentEntryIDs: Set<UUID> = []

    init(loader: @escaping Loader,
         savedIndex: CapsuleRailSavedIndex = CapsuleRailSavedIndex(defaults: nil)) {
        self.loader = loader
        self.savedIndex = savedIndex
    }

    /// A library that never reads anything, for panes built without stores.
    static func inert() -> CapsuleRailLibrary {
        CapsuleRailLibrary(loader: { (.success([]), .success([])) })
    }

    /// Reads the real Capsule stores.
    static func live() -> CapsuleRailLibrary {
        CapsuleRailLibrary(
            loader: { load(contentStore: .shared, passwordStore: .shared) },
            savedIndex: CapsuleRailSavedIndex(defaults: .standard)
        )
    }

    func entries(for kind: CapsuleEntryKind) -> [CapsuleRailEntry] {
        dispatchPrecondition(condition: .onQueue(.main))
        return byKind[kind] ?? []
    }

    func state(for kind: CapsuleEntryKind) -> LoadState {
        dispatchPrecondition(condition: .onQueue(.main))
        return stateByKind[kind] ?? .idle
    }

    /// Whether a Recent card is already in Capsule: saved from the rail into
    /// an entry that still exists, or text that matches a note exactly.
    func isInCapsule(historyItemID: UUID, text: String?) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        if let entry = savedIndex.entryID(forHistoryItem: historyItemID),
           contentEntryIDs.contains(entry) {
            return true
        }
        return text.map(notePayloads.contains) ?? false
    }

    func recordSaved(historyItemID: UUID, entryID: UUID) {
        dispatchPrecondition(condition: .onQueue(.main))
        savedIndex.record(historyItem: historyItemID, entry: entryID)
    }

    /// Starts a fresh read. What is already shown stays until it lands.
    func reload() {
        dispatchPrecondition(condition: .onQueue(.main))
        generation &+= 1
        let generation = generation
        for kind in CapsuleEntryKind.allCases where stateByKind[kind] != .loaded {
            stateByKind[kind] = .loading
        }
        let loader = loader
        queue.async { [weak self] in
            let result = loader()
            DispatchQueue.main.async {
                self?.apply(result, generation: generation)
            }
        }
    }

    private func apply(
        _ result: (content: Result<[CapsuleRailEntry], Error>,
                   passwords: Result<[CapsuleRailEntry], Error>),
        generation: UInt64
    ) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard generation == self.generation else { return }
        let contentKinds = CapsuleEntryKind.allCases.filter { $0 != .password }
        switch result.content {
        case let .success(entries):
            for kind in contentKinds {
                byKind[kind] = entries.filter { $0.kind == kind }
                stateByKind[kind] = .loaded
            }
            notePayloads = Set(entries.filter { $0.kind == .note }.compactMap(\.payload))
            contentEntryIDs = Set(entries.map(\.id))
            savedIndex.prune(keeping: contentEntryIDs)
        case let .failure(error):
            IMELog.write("capsule rail content load failed: \(error.localizedDescription)")
            for kind in contentKinds {
                byKind[kind] = []
                stateByKind[kind] = .failed
            }
        }
        switch result.passwords {
        case let .success(entries):
            byKind[.password] = entries
            stateByKind[.password] = .loaded
        case let .failure(error):
            IMELog.write("capsule rail password load failed: \(error.localizedDescription)")
            byKind[.password] = []
            stateByKind[.password] = .failed
        }
        onChange?()
    }

    /// Projects both stores into rail entries, newest first. Password entries
    /// carry only their title and a fixed mask.
    static func load(contentStore: CapsuleContentStore,
                     passwordStore: CapsulePasswordStore)
        -> (content: Result<[CapsuleRailEntry], Error>,
            passwords: Result<[CapsuleRailEntry], Error>) {
        let content = Result {
            try contentStore.listRecords().map { record in
                CapsuleRailEntry(
                    id: record.summary.id,
                    kind: record.summary.type,
                    title: record.summary.title,
                    preview: record.snippet,
                    updatedAt: record.summary.updatedAt,
                    payload: record.content,
                    searchText: record.summary.title + "\n" + record.content
                )
            }.sorted { $0.updatedAt > $1.updatedAt }
        }
        let passwords = Result {
            try passwordStore.listSummaries().map { summary in
                CapsuleRailEntry(
                    id: summary.id,
                    kind: .password,
                    title: summary.title,
                    preview: summary.maskedPassword,
                    updatedAt: summary.updatedAt,
                    payload: nil,
                    searchText: summary.title
                )
            }.sorted { $0.updatedAt > $1.updatedAt }
        }
        return (content, passwords)
    }
}
