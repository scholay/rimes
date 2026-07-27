import CryptoKit
import Darwin
import Foundation
import GRDB
import NaturalLanguage

enum MyPromptSourceKind: String, Codable, CaseIterable, Sendable {
    case automatic
    case fabricDirectory
    case markdownDirectory
    case obsidianMarkdown
    case aggregateMarkdown
    case remoteSnapshot
}

struct MyPromptSource: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var kind: MyPromptSourceKind
    var displayName: String
    var location: String
    var importedAt: Date

    init(
        id: String = UUID().uuidString.lowercased(),
        kind: MyPromptSourceKind = .automatic,
        displayName: String,
        location: String,
        importedAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.displayName = displayName
        self.location = location
        self.importedAt = importedAt
    }

    static func local(
        _ url: URL,
        kind: MyPromptSourceKind = .automatic
    ) -> MyPromptSource {
        let standardized = url.standardizedFileURL
        let sourceID = MyPromptStableIdentity.uuid(
            sourceID: "local-source",
            sourceKey: standardized.path
        ).uuidString.lowercased()
        return MyPromptSource(
            id: sourceID,
            kind: kind,
            displayName: standardized.deletingPathExtension()
                .lastPathComponent,
            location: standardized.path
        )
    }
}

struct MyPromptRecord: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var sourceID: String
    var sourceKey: String
    var title: String
    var summary: String
    var tags: [String]
    var systemPrompt: String
    var userPrompt: String?
    var favorite: Bool
    var useCount: Int
    var lastUsedAt: Date?
    var updatedAt: Date

    init(
        id: UUID? = nil,
        sourceID: String,
        sourceKey: String,
        title: String,
        summary: String = "",
        tags: [String] = [],
        systemPrompt: String,
        userPrompt: String? = nil,
        favorite: Bool = false,
        useCount: Int = 0,
        lastUsedAt: Date? = nil,
        updatedAt: Date = Date()
    ) {
        self.id = id ?? MyPromptStableIdentity.uuid(
            sourceID: sourceID,
            sourceKey: sourceKey
        )
        self.sourceID = sourceID
        self.sourceKey = sourceKey
        self.title = title
        self.summary = summary
        self.tags = tags
        self.systemPrompt = systemPrompt
        self.userPrompt = userPrompt
        self.favorite = favorite
        self.useCount = useCount
        self.lastUsedAt = lastUsedAt
        self.updatedAt = updatedAt
    }

    /// Fabric's `user.md` is normally a call-time input template. It is kept
    /// separately and is deliberately not appended to the default delivery.
    var deliveryText: String { systemPrompt }
    var stableDeliveryID: UUID { id }
}

struct MyPromptSearchResult: Equatable, Identifiable, Sendable {
    let record: MyPromptRecord
    let source: MyPromptSource
    let score: Double

    var id: UUID { record.id }
    var stableDeliveryID: UUID { record.id }
    var title: String { record.title }
    var systemPrompt: String { record.systemPrompt }
    var userPrompt: String? { record.userPrompt }

    var snippet: String {
        let candidate = record.summary.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty ? record.systemPrompt : record.summary
        // The visible rail needs only a short preview. Bound work before the
        // regular-expression pass so a valid multi-megabyte prompt cannot add
        // multi-megabyte string processing to every search result render.
        let compact = String(candidate.prefix(1_024)).replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )
        guard compact.count > 180 else { return compact }
        return String(compact.prefix(180)) + "…"
    }
}

enum MyPromptStoreError: LocalizedError {
    case unsafeStorage
    case invalidPermissions
    case invalidRecord
    case tooManyRecords
    case oversizedRecord
    case duplicateSourceKey

    var errorDescription: String? {
        switch self {
        case .unsafeStorage:
            return "My Prompt 的数据库路径不安全。"
        case .invalidPermissions:
            return "My Prompt 的数据库权限不符合要求。"
        case .invalidRecord:
            return "提示词记录格式无效。"
        case .tooManyRecords:
            return "一次导入的提示词数量超过上限。"
        case .oversizedRecord:
            return "提示词记录超过大小上限。"
        case .duplicateSourceKey:
            return "同一来源中存在重复的提示词标识。"
        }
    }
}

/// Thread-safe local prompt index. All methods are synchronous and may block;
/// callers should run imports and interactive searches on a non-main queue.
final class MyPromptStore: @unchecked Sendable {
    static let maximumBatchRecords = 100_000
    static let maximumPromptBytes = 2 * 1_024 * 1_024
    static let maximumSummaryBytes = 64 * 1_024

    let rootDirectory: URL
    let databaseURL: URL

    private let databasePool: DatabasePool
    private let securityLock = NSLock()

    init(rootDirectory requestedRoot: URL? = nil) throws {
        let fileManager = FileManager.default
        let root: URL
        if let requestedRoot {
            root = requestedRoot.standardizedFileURL
            try MyPromptStorageSecurity.ensurePrivateDirectory(
                root,
                fileManager: fileManager
            )
        } else {
            let sharedRoot = fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("RimeBuffer", isDirectory: true)
            try MyPromptStorageSecurity.ensureSharedRoot(
                sharedRoot,
                fileManager: fileManager
            )
            root = sharedRoot.appendingPathComponent(
                "my-prompt",
                isDirectory: true
            )
            try MyPromptStorageSecurity.ensurePrivateDirectory(
                root,
                fileManager: fileManager
            )
        }

        let databaseURL = root.appendingPathComponent(
            "prompts.sqlite",
            isDirectory: false
        )
        try MyPromptStorageSecurity.prepareDatabaseFile(databaseURL)
        for suffix in ["-wal", "-shm"] {
            try MyPromptStorageSecurity.validateOptionalDatabaseFile(
                URL(fileURLWithPath: databaseURL.path + suffix)
            )
        }

        var configuration = Configuration()
        configuration.busyMode = .timeout(2.0)
        configuration.maximumReaderCount = 4
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
        }

        let pool = try DatabasePool(
            path: databaseURL.path,
            configuration: configuration
        )
        self.rootDirectory = root
        self.databaseURL = databaseURL
        self.databasePool = pool

        try pool.writeWithoutTransaction { db in
            _ = try String.fetchOne(
                db,
                sql: "PRAGMA journal_mode = WAL"
            )
        }
        try Self.makeMigrator().migrate(pool)
        try tightenDatabaseFiles()
    }

    @discardableResult
    func replaceSource(
        _ source: MyPromptSource,
        records: [MyPromptRecord]
    ) throws -> Int {
        guard records.count <= Self.maximumBatchRecords else {
            throw MyPromptStoreError.tooManyRecords
        }
        try validate(source)

        var normalizedRecords: [MyPromptRecord] = []
        normalizedRecords.reserveCapacity(records.count)
        var sourceKeys = Set<String>()
        for record in records {
            let normalized = try normalized(record, sourceID: source.id)
            guard sourceKeys.insert(normalized.sourceKey).inserted else {
                throw MyPromptStoreError.duplicateSourceKey
            }
            normalizedRecords.append(normalized)
        }

        try databasePool.write { db in
            let usageRows = try Row.fetchAll(
                db,
                sql: """
                    SELECT source_key, favorite, use_count, last_used_at
                    FROM prompts
                    WHERE source_id = ?
                    """,
                arguments: [source.id]
            )
            var previousUsage: [String: (Bool, Int, Date?)] = [:]
            previousUsage.reserveCapacity(usageRows.count)
            for row in usageRows {
                let sourceKey: String = row["source_key"]
                let favorite: Bool = row["favorite"]
                let useCount: Int = row["use_count"]
                let lastUsed: Double? = row["last_used_at"]
                previousUsage[sourceKey] = (
                    favorite,
                    useCount,
                    lastUsed.map(Date.init(timeIntervalSince1970:))
                )
            }

            try db.execute(
                sql: """
                    INSERT INTO prompt_sources
                        (id, kind, display_name, location, imported_at)
                    VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        kind = excluded.kind,
                        display_name = excluded.display_name,
                        location = excluded.location,
                        imported_at = excluded.imported_at
                    """,
                arguments: [
                    source.id,
                    source.kind.rawValue,
                    source.displayName,
                    source.location,
                    source.importedAt.timeIntervalSince1970,
                ]
            )
            try db.execute(
                sql: "DELETE FROM prompts WHERE source_id = ?",
                arguments: [source.id]
            )

            for var record in normalizedRecords {
                if let usage = previousUsage[record.sourceKey] {
                    record.favorite = usage.0
                    record.useCount = usage.1
                    record.lastUsedAt = usage.2
                }
                let index = MyPromptSearchIndex(record: record)
                let tagsData = try JSONEncoder().encode(record.tags)
                guard let tagsJSON = String(
                    data: tagsData,
                    encoding: .utf8
                ) else {
                    throw MyPromptStoreError.invalidRecord
                }
                try db.execute(
                    sql: """
                        INSERT INTO prompts (
                            id, source_id, source_key, title, summary,
                            tags_json, tags_text, system_prompt, user_prompt,
                            favorite, use_count, last_used_at, updated_at,
                            content_hash, title_terms, summary_terms,
                            body_terms, tag_terms, pinyin_terms,
                            initial_terms
                        ) VALUES (
                            ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
                            ?, ?, ?, ?, ?
                        )
                        """,
                    arguments: [
                        record.id.uuidString.lowercased(),
                        record.sourceID,
                        record.sourceKey,
                        record.title,
                        record.summary,
                        tagsJSON,
                        record.tags.joined(separator: " "),
                        record.systemPrompt,
                        record.userPrompt,
                        record.favorite,
                        record.useCount,
                        record.lastUsedAt?.timeIntervalSince1970,
                        record.updatedAt.timeIntervalSince1970,
                        MyPromptStableIdentity.contentHash(record),
                        index.titleTerms,
                        index.summaryTerms,
                        index.bodyTerms,
                        index.tagTerms,
                        index.pinyinTerms,
                        index.initialTerms,
                    ]
                )
            }
        }
        try tightenDatabaseFiles()
        return normalizedRecords.count
    }

    @discardableResult
    func replaceSource(with result: MyPromptImportResult) throws -> Int {
        try replaceSource(result.source, records: result.records)
    }

    func search(
        _ query: String,
        limit requestedLimit: Int = 5
    ) throws -> [MyPromptSearchResult] {
        guard requestedLimit > 0 else { return [] }
        let limit = min(requestedLimit, 100)
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return try databasePool.read { db in
            if trimmed.isEmpty {
                let rows = try Row.fetchAll(
                    db,
                    sql: Self.baseSelect + """

                        FROM prompts p
                        JOIN prompt_sources s ON s.id = p.source_id
                        ORDER BY p.favorite DESC,
                            p.last_used_at IS NULL ASC,
                            p.last_used_at DESC,
                            p.use_count DESC,
                            p.title COLLATE NOCASE ASC,
                            p.id ASC
                        LIMIT ?
                        """,
                    arguments: [limit]
                )
                return try rows.map { try Self.decodeResult($0, score: 0) }
            }

            guard let expression = MyPromptTextAnalysis.searchExpression(
                trimmed
            ) else {
                return []
            }

            let rows = try Row.fetchAll(
                db,
                sql: Self.baseSelect + """
                    , bm25(prompt_fts, 10.0, 4.0, 1.0, 8.0, 5.0, 5.0)
                        AS search_rank
                    FROM prompt_fts
                    JOIN prompts p ON p.rowid = prompt_fts.rowid
                    JOIN prompt_sources s ON s.id = p.source_id
                    WHERE prompt_fts MATCH ?
                    ORDER BY
                        search_rank -
                            CASE WHEN p.favorite THEN 0.35 ELSE 0 END ASC,
                        p.last_used_at IS NULL ASC,
                        p.last_used_at DESC,
                        p.title COLLATE NOCASE ASC,
                        p.id ASC
                    LIMIT ?
                    """,
                arguments: [expression, limit]
            )
            return try rows.map {
                let rank: Double = $0["search_rank"]
                return try Self.decodeResult($0, score: -rank)
            }
        }
    }

    func prompt(id: UUID) throws -> MyPromptRecord? {
        try databasePool.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT p.*
                    FROM prompts p
                    WHERE p.id = ?
                    """,
                arguments: [id.uuidString.lowercased()]
            ) else {
                return nil
            }
            return try Self.decodeRecord(row)
        }
    }

    func sources() throws -> [MyPromptSource] {
        try databasePool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT id, kind, display_name, location, imported_at
                    FROM prompt_sources
                    ORDER BY display_name COLLATE NOCASE, id
                    """
            ).map { try Self.decodeSource($0) }
        }
    }

    func promptCount(sourceID: String? = nil) throws -> Int {
        try databasePool.read { db in
            if let sourceID {
                return try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM prompts WHERE source_id = ?",
                    arguments: [sourceID]
                ) ?? 0
            }
            return try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM prompts"
            ) ?? 0
        }
    }

    func setFavorite(promptID: UUID, isFavorite: Bool) throws {
        try databasePool.write { db in
            try db.execute(
                sql: "UPDATE prompts SET favorite = ? WHERE id = ?",
                arguments: [
                    isFavorite,
                    promptID.uuidString.lowercased(),
                ]
            )
        }
        try tightenDatabaseFiles()
    }

    func markUsed(promptID: UUID, at date: Date = Date()) throws {
        try databasePool.write { db in
            try db.execute(
                sql: """
                    UPDATE prompts
                    SET use_count = use_count + 1, last_used_at = ?
                    WHERE id = ?
                    """,
                arguments: [
                    date.timeIntervalSince1970,
                    promptID.uuidString.lowercased(),
                ]
            )
        }
        try tightenDatabaseFiles()
    }

    func removeSource(id: String) throws {
        try databasePool.write { db in
            try db.execute(
                sql: "DELETE FROM prompt_sources WHERE id = ?",
                arguments: [id]
            )
        }
        try tightenDatabaseFiles()
    }

    private func validate(_ source: MyPromptSource) throws {
        let values = [
            source.id,
            source.displayName,
            source.location,
        ]
        guard values.allSatisfy({
            !$0.isEmpty && !$0.contains("\0") && $0.utf8.count <= 16_384
        }) else {
            throw MyPromptStoreError.invalidRecord
        }
    }

    private func normalized(
        _ input: MyPromptRecord,
        sourceID: String
    ) throws -> MyPromptRecord {
        let sourceKey = input.sourceKey.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let title = input.title.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let systemPrompt = input.systemPrompt.trimmingCharacters(
            in: .newlines
        )
        guard !sourceKey.isEmpty,
              !title.isEmpty,
              !systemPrompt.isEmpty,
              !sourceKey.contains("\0"),
              !title.contains("\0"),
              !systemPrompt.contains("\0"),
              input.userPrompt?.contains("\0") != true,
              !input.summary.contains("\0"),
              !input.tags.contains(where: {
                  $0.isEmpty || $0.contains("\0") || $0.utf8.count > 512
              }) else {
            throw MyPromptStoreError.invalidRecord
        }
        guard sourceKey.utf8.count <= 8_192,
              title.utf8.count <= 8_192,
              systemPrompt.utf8.count <= Self.maximumPromptBytes,
              (input.userPrompt?.utf8.count ?? 0) <=
                Self.maximumPromptBytes,
              input.summary.utf8.count <= Self.maximumSummaryBytes,
              input.tags.count <= 128 else {
            throw MyPromptStoreError.oversizedRecord
        }
        return MyPromptRecord(
            id: MyPromptStableIdentity.uuid(
                sourceID: sourceID,
                sourceKey: sourceKey
            ),
            sourceID: sourceID,
            sourceKey: sourceKey,
            title: title,
            summary: input.summary.trimmingCharacters(
                in: .whitespacesAndNewlines
            ),
            tags: MyPromptTextAnalysis.unique(
                input.tags.map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines)
                }.filter { !$0.isEmpty }
            ),
            systemPrompt: systemPrompt,
            userPrompt: input.userPrompt?.trimmingCharacters(in: .newlines),
            favorite: input.favorite,
            useCount: max(0, input.useCount),
            lastUsedAt: input.lastUsedAt,
            updatedAt: input.updatedAt
        )
    }

    private func tightenDatabaseFiles() throws {
        securityLock.lock()
        defer { securityLock.unlock() }
        try MyPromptStorageSecurity.tightenDatabaseFiles(databaseURL)
    }

    private static let baseSelect = """
        SELECT
            p.id, p.source_id, p.source_key, p.title, p.summary,
            p.tags_json, p.system_prompt, p.user_prompt, p.favorite,
            p.use_count, p.last_used_at, p.updated_at,
            s.id AS source__id, s.kind AS source__kind,
            s.display_name AS source__display_name,
            s.location AS source__location,
            s.imported_at AS source__imported_at
        """

    private static func decodeResult(
        _ row: Row,
        score: Double
    ) throws -> MyPromptSearchResult {
        MyPromptSearchResult(
            record: try decodeRecord(row),
            source: try decodeSource(
                row,
                prefix: "source__"
            ),
            score: score
        )
    }

    private static func decodeRecord(_ row: Row) throws -> MyPromptRecord {
        let idText: String = row["id"]
        guard let id = UUID(uuidString: idText) else {
            throw MyPromptStoreError.invalidRecord
        }
        let tagsJSON: String = row["tags_json"]
        guard let tagsData = tagsJSON.data(using: .utf8) else {
            throw MyPromptStoreError.invalidRecord
        }
        let tags = try JSONDecoder().decode([String].self, from: tagsData)
        let lastUsed: Double? = row["last_used_at"]
        let updatedAt: Double = row["updated_at"]
        return MyPromptRecord(
            id: id,
            sourceID: row["source_id"],
            sourceKey: row["source_key"],
            title: row["title"],
            summary: row["summary"],
            tags: tags,
            systemPrompt: row["system_prompt"],
            userPrompt: row["user_prompt"],
            favorite: row["favorite"],
            useCount: row["use_count"],
            lastUsedAt: lastUsed.map(Date.init(timeIntervalSince1970:)),
            updatedAt: Date(timeIntervalSince1970: updatedAt)
        )
    }

    private static func decodeSource(
        _ row: Row,
        prefix: String = ""
    ) throws -> MyPromptSource {
        let kindText: String = row[prefix + "kind"]
        guard let kind = MyPromptSourceKind(rawValue: kindText) else {
            throw MyPromptStoreError.invalidRecord
        }
        let importedAt: Double = row[prefix + "imported_at"]
        return MyPromptSource(
            id: row[prefix + "id"],
            kind: kind,
            displayName: row[prefix + "display_name"],
            location: row[prefix + "location"],
            importedAt: Date(timeIntervalSince1970: importedAt)
        )
    }

    private static func makeMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("my-prompt-v1") { db in
            try db.execute(sql: """
                CREATE TABLE prompt_sources (
                    id TEXT PRIMARY KEY NOT NULL,
                    kind TEXT NOT NULL,
                    display_name TEXT NOT NULL,
                    location TEXT NOT NULL,
                    imported_at DOUBLE NOT NULL
                );

                CREATE TABLE prompts (
                    id TEXT PRIMARY KEY NOT NULL,
                    source_id TEXT NOT NULL
                        REFERENCES prompt_sources(id) ON DELETE CASCADE,
                    source_key TEXT NOT NULL,
                    title TEXT NOT NULL,
                    summary TEXT NOT NULL,
                    tags_json TEXT NOT NULL,
                    tags_text TEXT NOT NULL,
                    system_prompt TEXT NOT NULL,
                    user_prompt TEXT,
                    favorite BOOLEAN NOT NULL DEFAULT 0,
                    use_count INTEGER NOT NULL DEFAULT 0,
                    last_used_at DOUBLE,
                    updated_at DOUBLE NOT NULL,
                    content_hash TEXT NOT NULL,
                    title_terms TEXT NOT NULL,
                    summary_terms TEXT NOT NULL,
                    body_terms TEXT NOT NULL,
                    tag_terms TEXT NOT NULL,
                    pinyin_terms TEXT NOT NULL,
                    initial_terms TEXT NOT NULL,
                    UNIQUE(source_id, source_key)
                );

                CREATE INDEX prompts_source_id
                    ON prompts(source_id);
                CREATE INDEX prompts_recent
                    ON prompts(favorite DESC, last_used_at DESC, use_count DESC);

                CREATE VIRTUAL TABLE prompt_fts USING fts5(
                    title_terms,
                    summary_terms,
                    body_terms,
                    tag_terms,
                    pinyin_terms,
                    initial_terms,
                    content = 'prompts',
                    content_rowid = 'rowid',
                    tokenize = 'unicode61 remove_diacritics 2',
                    prefix = '1 2 3 4'
                );

                CREATE TRIGGER prompts_fts_insert
                AFTER INSERT ON prompts BEGIN
                    INSERT INTO prompt_fts(
                        rowid, title_terms, summary_terms, body_terms,
                        tag_terms, pinyin_terms, initial_terms
                    ) VALUES (
                        new.rowid, new.title_terms, new.summary_terms,
                        new.body_terms, new.tag_terms, new.pinyin_terms,
                        new.initial_terms
                    );
                END;

                CREATE TRIGGER prompts_fts_delete
                AFTER DELETE ON prompts BEGIN
                    INSERT INTO prompt_fts(
                        prompt_fts, rowid, title_terms, summary_terms,
                        body_terms, tag_terms, pinyin_terms, initial_terms
                    ) VALUES (
                        'delete', old.rowid, old.title_terms,
                        old.summary_terms, old.body_terms, old.tag_terms,
                        old.pinyin_terms, old.initial_terms
                    );
                END;

                CREATE TRIGGER prompts_fts_update
                AFTER UPDATE ON prompts BEGIN
                    INSERT INTO prompt_fts(
                        prompt_fts, rowid, title_terms, summary_terms,
                        body_terms, tag_terms, pinyin_terms, initial_terms
                    ) VALUES (
                        'delete', old.rowid, old.title_terms,
                        old.summary_terms, old.body_terms, old.tag_terms,
                        old.pinyin_terms, old.initial_terms
                    );
                    INSERT INTO prompt_fts(
                        rowid, title_terms, summary_terms, body_terms,
                        tag_terms, pinyin_terms, initial_terms
                    ) VALUES (
                        new.rowid, new.title_terms, new.summary_terms,
                        new.body_terms, new.tag_terms, new.pinyin_terms,
                        new.initial_terms
                    );
                END;
                """)
        }
        return migrator
    }
}

private struct MyPromptSearchIndex {
    let titleTerms: String
    let summaryTerms: String
    let bodyTerms: String
    let tagTerms: String
    let pinyinTerms: String
    let initialTerms: String

    init(record: MyPromptRecord) {
        titleTerms = MyPromptTextAnalysis.indexTerms(
            record.title,
            includeCJKUnigrams: true
        )
            .joined(separator: " ")
        summaryTerms = MyPromptTextAnalysis.indexTerms(record.summary)
            .joined(separator: " ")
        bodyTerms = MyPromptTextAnalysis.indexTerms(record.systemPrompt)
            .joined(separator: " ")
        tagTerms = MyPromptTextAnalysis.indexTerms(
            record.tags.joined(separator: " "),
            includeCJKUnigrams: true
        ).joined(separator: " ")
        var fullPinyin: [String] = []
        var initials: [String] = []
        for value in [record.title] + record.tags {
            let pinyin = MyPromptTextAnalysis.pinyinTerms(value)
            fullPinyin.append(contentsOf: pinyin.full)
            initials.append(contentsOf: pinyin.initials)
        }
        pinyinTerms = MyPromptTextAnalysis.unique(fullPinyin)
            .joined(separator: " ")
        initialTerms = MyPromptTextAnalysis.unique(initials)
            .joined(separator: " ")
    }
}

private enum MyPromptTextAnalysis {
    static func searchExpression(_ text: String) -> String? {
        let folded = fold(String(text.prefix(512)))
        var groups: [String] = []
        var remainingTerms = 24
        var cjkRun: [UnicodeScalar] = []
        var word = ""

        func quotedPrefix(_ value: String) -> String {
            let escaped = value.replacingOccurrences(
                of: "\"",
                with: "\"\""
            )
            return "\"\(escaped)\"*"
        }

        func appendWord() {
            guard remainingTerms > 0 else {
                word.removeAll(keepingCapacity: true)
                return
            }
            let term = canonicalTerm(word)
            word.removeAll(keepingCapacity: true)
            guard !term.isEmpty, term.utf8.count <= 256 else { return }
            groups.append(quotedPrefix(term))
            remainingTerms -= 1
        }

        func appendCJKRun() {
            guard remainingTerms > 0, !cjkRun.isEmpty else {
                cjkRun.removeAll(keepingCapacity: true)
                return
            }
            let run = cjkRun.map(String.init).joined()
            cjkRun.removeAll(keepingCapacity: true)
            var terms: [String] = []
            if run.utf8.count <= 256 {
                terms.append(run)
            }
            terms.append(contentsOf: cjkBigrams(run))
            terms = Array(unique(terms).prefix(remainingTerms))
            guard !terms.isEmpty else { return }
            remainingTerms -= terms.count
            if terms.count == 1 {
                groups.append(quotedPrefix(terms[0]))
                return
            }
            let exact = quotedPrefix(terms[0])
            let coverage = terms.dropFirst()
                .map(quotedPrefix)
                .joined(separator: " AND ")
            groups.append("(\(exact) OR (\(coverage)))")
        }

        for scalar in folded.unicodeScalars {
            if isCJK(scalar) {
                appendWord()
                cjkRun.append(scalar)
            } else {
                appendCJKRun()
                if CharacterSet.alphanumerics.contains(scalar)
                    || scalar == "_" {
                    word.unicodeScalars.append(scalar)
                } else {
                    appendWord()
                }
            }
        }
        appendCJKRun()
        appendWord()
        guard !groups.isEmpty else { return nil }
        return groups.joined(separator: " AND ")
    }

    static func indexTerms(
        _ text: String,
        includeCJKUnigrams: Bool = false
    ) -> [String] {
        guard !text.isEmpty else { return [] }
        let folded = fold(text)
        var terms: [String] = []
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = folded
        tokenizer.enumerateTokens(
            in: folded.startIndex..<folded.endIndex
        ) { range, _ in
            let token = canonicalTerm(String(folded[range]))
            if !token.isEmpty {
                terms.append(token)
            }
            return true
        }
        terms.append(contentsOf: cjkBigrams(folded))
        if includeCJKUnigrams {
            terms.append(contentsOf: cjkUnigrams(folded))
        }
        return unique(terms)
    }

    static func pinyinTerms(
        _ text: String
    ) -> (full: [String], initials: [String]) {
        let bounded = String(text.prefix(256))
        guard let latin = bounded.applyingTransform(
            .mandarinToLatin,
            reverse: false
        ) else {
            return ([], [])
        }
        let normalized = fold(latin)
        var words: [String] = []
        var current = ""
        for scalar in normalized.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                current.unicodeScalars.append(scalar)
            } else if !current.isEmpty {
                words.append(current)
                current.removeAll(keepingCapacity: true)
            }
        }
        if !current.isEmpty { words.append(current) }
        words = Array(words.prefix(64))
        guard !words.isEmpty else { return ([], []) }
        let compactSuffixes = words.indices.compactMap { index -> String? in
            let value = words[index...].joined()
            return value.utf8.count <= 256 ? value : nil
        }
        let initialCharacters = words.compactMap(\.first)
        let initialSuffixes = initialCharacters.indices.map {
            String(initialCharacters[$0...])
        }
        return (
            unique(words + compactSuffixes),
            unique(initialSuffixes)
        )
    }

    static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    private static func fold(_ text: String) -> String {
        text.folding(
            options: [
                .caseInsensitive,
                .diacriticInsensitive,
                .widthInsensitive,
            ],
            locale: Locale(identifier: "zh_Hans")
        ).lowercased()
    }

    private static func canonicalTerm(_ text: String) -> String {
        var output = ""
        for scalar in text.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) ||
                scalar == "_" {
                output.unicodeScalars.append(scalar)
            }
        }
        return output
    }

    private static func cjkBigrams(_ text: String) -> [String] {
        var output: [String] = []
        var run: [UnicodeScalar] = []

        func appendRun() {
            guard run.count >= 2 else {
                run.removeAll(keepingCapacity: true)
                return
            }
            for index in 0..<(run.count - 1) {
                output.append(String(run[index]) + String(run[index + 1]))
            }
            run.removeAll(keepingCapacity: true)
        }

        for scalar in text.unicodeScalars {
            if isCJK(scalar) {
                run.append(scalar)
            } else {
                appendRun()
            }
        }
        appendRun()
        return output
    }

    private static func cjkUnigrams(_ text: String) -> [String] {
        text.unicodeScalars.compactMap {
            isCJK($0) ? String($0) : nil
        }
    }

    private static func isCJK(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x4DBF,
             0x4E00...0x9FFF,
             0xF900...0xFAFF,
             0x20000...0x2FA1F:
            return true
        default:
            return false
        }
    }
}

private enum MyPromptStableIdentity {
    static func uuid(sourceID: String, sourceKey: String) -> UUID {
        let digest = SHA256.hash(
            data: Data((sourceID + "\0" + sourceKey).utf8)
        )
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    static func contentHash(_ record: MyPromptRecord) -> String {
        var data = Data()
        for value in [
            record.title,
            record.summary,
            record.tags.joined(separator: "\0"),
            record.systemPrompt,
            record.userPrompt ?? "",
        ] {
            data.append(contentsOf: value.utf8)
            data.append(0)
        }
        return SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

private enum MyPromptStorageSecurity {
    static func ensureSharedRoot(
        _ url: URL,
        fileManager: FileManager
    ) throws {
        var info = stat()
        if lstat(url.path, &info) != 0 {
            guard errno == ENOENT else {
                throw MyPromptStoreError.unsafeStorage
            }
            try fileManager.createDirectory(
                at: url,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        }
        guard lstat(url.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == geteuid() else {
            throw MyPromptStoreError.unsafeStorage
        }
        let mode = info.st_mode & 0o777
        guard (mode & 0o700) == 0o700, (mode & 0o022) == 0 else {
            throw MyPromptStoreError.invalidPermissions
        }
    }

    static func ensurePrivateDirectory(
        _ url: URL,
        fileManager: FileManager
    ) throws {
        var info = stat()
        if lstat(url.path, &info) != 0 {
            guard errno == ENOENT else {
                throw MyPromptStoreError.unsafeStorage
            }
            try fileManager.createDirectory(
                at: url,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        }
        guard lstat(url.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == geteuid() else {
            throw MyPromptStoreError.unsafeStorage
        }
        guard chmod(url.path, S_IRWXU) == 0 else {
            throw MyPromptStoreError.invalidPermissions
        }
    }

    static func prepareDatabaseFile(_ url: URL) throws {
        var info = stat()
        if lstat(url.path, &info) == 0 {
            try validateDatabaseStat(info)
            guard chmod(url.path, S_IRUSR | S_IWUSR) == 0 else {
                throw MyPromptStoreError.invalidPermissions
            }
            return
        }
        guard errno == ENOENT else {
            throw MyPromptStoreError.unsafeStorage
        }
        let descriptor = open(
            url.path,
            O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw MyPromptStoreError.unsafeStorage
        }
        defer { close(descriptor) }
        guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
            throw MyPromptStoreError.invalidPermissions
        }
    }

    static func validateOptionalDatabaseFile(_ url: URL) throws {
        var info = stat()
        if lstat(url.path, &info) != 0 {
            guard errno == ENOENT else {
                throw MyPromptStoreError.unsafeStorage
            }
            return
        }
        try validateDatabaseStat(info)
    }

    static func tightenDatabaseFiles(_ databaseURL: URL) throws {
        for path in [
            databaseURL.path,
            databaseURL.path + "-wal",
            databaseURL.path + "-shm",
        ] {
            var info = stat()
            if lstat(path, &info) != 0 {
                guard errno == ENOENT else {
                    throw MyPromptStoreError.unsafeStorage
                }
                continue
            }
            try validateDatabaseStat(info)
            guard chmod(path, S_IRUSR | S_IWUSR) == 0 else {
                throw MyPromptStoreError.invalidPermissions
            }
        }
    }

    private static func validateDatabaseStat(_ info: stat) throws {
        guard (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == geteuid() else {
            throw MyPromptStoreError.unsafeStorage
        }
    }
}
