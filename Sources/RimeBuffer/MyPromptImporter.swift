import Darwin
import CryptoKit
import Foundation

struct MyPromptImportResult: Equatable, Sendable {
    var source: MyPromptSource
    var records: [MyPromptRecord]

    var count: Int { records.count }
}

enum MyPromptImporterError: LocalizedError {
    case sourceMissing
    case sourceIsSymbolicLink
    case unsupportedSource
    case unsafeEntry
    case oversizedFile
    case oversizedImport
    case containsNUL
    case invalidUTF8
    case malformedMarkdown
    case noPrompts
    case tooManyPrompts

    var errorDescription: String? {
        switch self {
        case .sourceMissing:
            return "没有找到要导入的提示词来源。"
        case .sourceIsSymbolicLink:
            return "为避免读取到意外位置，不能从符号链接导入。"
        case .unsupportedSource:
            return "请选择 Fabric 提示词目录或 Markdown 文件。"
        case .unsafeEntry:
            return "提示词来源中包含不安全的文件。"
        case .oversizedFile:
            return "单个提示词文件超过大小上限。"
        case .oversizedImport:
            return "本次导入的文件总量超过上限。"
        case .containsNUL:
            return "提示词文件包含不支持的 NUL 字节。"
        case .invalidUTF8:
            return "提示词文件必须使用 UTF-8 编码。"
        case .malformedMarkdown:
            return "Markdown 提示词格式不完整。"
        case .noPrompts:
            return "所选来源中没有可导入的提示词。"
        case .tooManyPrompts:
            return "所选来源中的提示词数量超过上限。"
        }
    }
}

/// Stateless, synchronous scanner for local prompt libraries. Run it off the
/// main thread. It never mutates the source and never follows symlinks.
struct MyPromptImporter: Sendable {
    static let maximumFileBytes = 2 * 1_024 * 1_024
    static let maximumTotalBytes = 128 * 1_024 * 1_024
    static let maximumPromptCount = 100_000

    init() {}

    func scan(rootURL: URL) throws -> MyPromptImportResult {
        try scan(
            rootURL: rootURL,
            source: MyPromptSource.local(rootURL)
        )
    }

    func importPrompts(
        rootURL: URL,
        source: MyPromptSource
    ) throws -> MyPromptImportResult {
        try scan(rootURL: rootURL, source: source)
    }

    func scan(
        rootURL: URL,
        source originalSource: MyPromptSource
    ) throws -> MyPromptImportResult {
        let rootURL = rootURL.standardizedFileURL
        let type = try entryType(rootURL)
        var bytesRead = 0
        var source = originalSource
        source.location = rootURL.path
        source.importedAt = Date()
        if source.displayName.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty {
            source.displayName = rootURL.deletingPathExtension()
                .lastPathComponent
        }

        let records: [MyPromptRecord]
        switch type {
        case .directory:
            guard source.kind == .automatic ||
                    source.kind == .fabricDirectory ||
                    source.kind == .markdownDirectory ||
                    source.kind == .remoteSnapshot else {
                throw MyPromptImporterError.unsupportedSource
            }
            if let patternsRoot = try detectPatternsRoot(rootURL),
               source.kind != .markdownDirectory {
                if source.kind != .remoteSnapshot {
                    source.kind = .fabricDirectory
                }
                records = try scanFabricDirectory(
                    rootURL,
                    patternsRoot: patternsRoot,
                    source: source,
                    bytesRead: &bytesRead
                )
            } else if source.kind == .fabricDirectory {
                records = try scanFabricDirectory(
                    rootURL,
                    patternsRoot: rootURL,
                    source: source,
                    bytesRead: &bytesRead
                )
            } else {
                if source.kind != .remoteSnapshot {
                    source.kind = .markdownDirectory
                }
                records = try scanMarkdownDirectory(
                    rootURL,
                    source: source,
                    bytesRead: &bytesRead
                )
            }
        case .regularFile:
            guard rootURL.pathExtension.lowercased() == "md",
                  source.kind != .fabricDirectory else {
                throw MyPromptImporterError.unsupportedSource
            }
            let text = try readUTF8(
                rootURL,
                bytesRead: &bytesRead
            )
            if hasYAMLFrontMatter(text) {
                if source.kind != .remoteSnapshot {
                    source.kind = .obsidianMarkdown
                }
                records = [
                    try parseObsidianMarkdown(
                        text,
                        url: rootURL,
                        source: source
                    ),
                ]
            } else {
                let aggregate = try parseAggregateMarkdown(
                    text,
                    source: source,
                    sourceKeyPrefix: rootURL.lastPathComponent
                )
                if source.kind == .aggregateMarkdown ||
                    ((source.kind == .automatic ||
                        source.kind == .remoteSnapshot) &&
                        !aggregate.isEmpty) {
                    guard !aggregate.isEmpty else {
                        throw MyPromptImporterError.noPrompts
                    }
                    if source.kind != .remoteSnapshot {
                        source.kind = .aggregateMarkdown
                    }
                    records = aggregate.map {
                        var record = $0
                        record.sourceID = source.id
                        record.id = MyPromptRecord(
                            sourceID: source.id,
                            sourceKey: record.sourceKey,
                            title: record.title,
                            summary: record.summary,
                            tags: record.tags,
                            systemPrompt: record.systemPrompt,
                            userPrompt: record.userPrompt
                        ).id
                        return record
                    }
                } else {
                    if source.kind != .remoteSnapshot {
                        source.kind = .obsidianMarkdown
                    }
                    records = [
                        try parseObsidianMarkdown(
                            text,
                            url: rootURL,
                            source: source
                        ),
                    ]
                }
            }
        }

        if case .regularFile = type, records.isEmpty {
            throw MyPromptImporterError.noPrompts
        }
        guard records.count <= Self.maximumPromptCount else {
            throw MyPromptImporterError.tooManyPrompts
        }
        return MyPromptImportResult(source: source, records: records)
    }

    private func scanFabricDirectory(
        _ selectedRoot: URL,
        patternsRoot: URL,
        source: MyPromptSource,
        bytesRead: inout Int
    ) throws -> [MyPromptRecord] {
        let descriptions = try loadPatternDescriptions(
            selectedRoot: selectedRoot,
            patternsRoot: patternsRoot,
            bytesRead: &bytesRead
        )
        let children = try FileManager.default.contentsOfDirectory(
            at: patternsRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).sorted {
            $0.lastPathComponent.localizedStandardCompare(
                $1.lastPathComponent
            ) == .orderedAscending
        }

        var records: [MyPromptRecord] = []
        records.reserveCapacity(min(children.count, 4_096))
        for child in children {
            switch try entryType(child) {
            case .regularFile:
                continue
            case .directory:
                break
            }

            let systemURL = child.appendingPathComponent(
                "system.md",
                isDirectory: false
            )
            guard try optionalRegularFileExists(systemURL) else {
                continue
            }
            let systemPrompt = try readUTF8(
                systemURL,
                bytesRead: &bytesRead
            ).trimmingCharacters(in: .newlines)
            guard !systemPrompt.isEmpty else { continue }

            let userURL = child.appendingPathComponent(
                "user.md",
                isDirectory: false
            )
            let userPrompt: String?
            if try optionalRegularFileExists(userURL) {
                let value = try readUTF8(
                    userURL,
                    bytesRead: &bytesRead
                ).trimmingCharacters(in: .newlines)
                userPrompt = value.isEmpty ? nil : value
            } else {
                userPrompt = nil
            }

            let readmeURL = child.appendingPathComponent(
                "README.md",
                isDirectory: false
            )
            let readmeSummary: String
            if try optionalRegularFileExists(readmeURL) {
                let readme = try readUTF8(
                    readmeURL,
                    bytesRead: &bytesRead
                )
                readmeSummary = firstParagraph(readme)
            } else {
                readmeSummary = ""
            }

            let key = child.lastPathComponent
            let metadata = descriptions[key]
            let title = metadata?.title.nonEmpty ??
                humanizedTitle(key)
            let summary = metadata?.summary.nonEmpty ?? readmeSummary
            records.append(
                MyPromptRecord(
                    sourceID: source.id,
                    sourceKey: key,
                    title: title,
                    summary: summary,
                    tags: metadata?.tags ?? [],
                    systemPrompt: systemPrompt,
                    userPrompt: userPrompt
                )
            )
            guard records.count <= Self.maximumPromptCount else {
                throw MyPromptImporterError.tooManyPrompts
            }
        }
        return records
    }

    private func scanMarkdownDirectory(
        _ root: URL,
        source: MyPromptSource,
        bytesRead: inout Int
    ) throws -> [MyPromptRecord] {
        var pendingDirectories = [root]
        var markdownFiles: [(url: URL, relativePath: String)] = []
        var visitedEntries = 0

        while let directory = pendingDirectories.popLast() {
            let children = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            for child in children {
                visitedEntries += 1
                guard visitedEntries <= 250_000 else {
                    throw MyPromptImporterError.tooManyPrompts
                }
                let relativePath = try safeRelativePath(
                    child,
                    beneath: root
                )
                guard relativePath.split(separator: "/").count <= 64 else {
                    throw MyPromptImporterError.unsafeEntry
                }
                switch try entryType(child) {
                case .directory:
                    pendingDirectories.append(child)
                case .regularFile:
                    guard child.pathExtension.lowercased() == "md" else {
                        continue
                    }
                    markdownFiles.append((child, relativePath))
                }
            }
        }
        markdownFiles.sort {
            $0.relativePath.localizedStandardCompare($1.relativePath)
                == .orderedAscending
        }

        var records: [MyPromptRecord] = []
        for item in markdownFiles {
            let text = try readUTF8(
                item.url,
                bytesRead: &bytesRead
            )
            if hasYAMLFrontMatter(text) {
                do {
                    records.append(
                        try parseObsidianMarkdown(
                            text,
                            url: item.url,
                            source: source,
                            sourceKey: item.relativePath
                        )
                    )
                } catch MyPromptImporterError.noPrompts {
                    continue
                }
            } else {
                let aggregate = try parseAggregateMarkdown(
                    text,
                    source: source,
                    sourceKeyPrefix: item.relativePath
                )
                if aggregate.isEmpty {
                    // A root README without prompt sections is repository
                    // documentation. Nested README notes remain valid
                    // Obsidian-style single prompts.
                    if item.relativePath.lowercased() == "readme.md" {
                        continue
                    }
                    do {
                        records.append(
                            try parseObsidianMarkdown(
                                text,
                                url: item.url,
                                source: source,
                                sourceKey: item.relativePath
                            )
                        )
                    } catch MyPromptImporterError.noPrompts {
                        continue
                    }
                } else {
                    records.append(contentsOf: aggregate)
                }
            }
            guard records.count <= Self.maximumPromptCount else {
                throw MyPromptImporterError.tooManyPrompts
            }
        }
        return records
    }

    private func detectPatternsRoot(_ root: URL) throws -> URL? {
        let dataDirectory = root.appendingPathComponent(
            "data",
            isDirectory: true
        )
        if try optionalDirectoryExists(dataDirectory) {
            let nested = dataDirectory.appendingPathComponent(
                "patterns",
                isDirectory: true
            )
            if try optionalDirectoryExists(nested) {
                return nested
            }
        }
        let directPatterns = root.appendingPathComponent(
            "patterns",
            isDirectory: true
        )
        if try optionalDirectoryExists(directPatterns) {
            return directPatterns
        }
        let children = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        for child in children {
            guard case .directory = try entryType(child) else { continue }
            let systemURL = child.appendingPathComponent("system.md")
            if try optionalRegularFileExists(systemURL) {
                return root
            }
        }
        return nil
    }

    private func parseObsidianMarkdown(
        _ text: String,
        url: URL,
        source: MyPromptSource,
        sourceKey: String? = nil
    ) throws -> MyPromptRecord {
        let parsed = try parseFrontMatter(text)
        let body = parsed.body.trimmingCharacters(in: .newlines)
        guard !body.isEmpty else {
            throw MyPromptImporterError.noPrompts
        }
        let fallbackTitle = url.deletingPathExtension().lastPathComponent
        return MyPromptRecord(
            sourceID: source.id,
            sourceKey: sourceKey ?? url.lastPathComponent,
            title: parsed.title.nonEmpty ?? humanizedTitle(fallbackTitle),
            summary: parsed.summary,
            tags: parsed.tags,
            systemPrompt: body,
            favorite: parsed.favorite
        )
    }

    private func safeRelativePath(
        _ child: URL,
        beneath root: URL
    ) throws -> String {
        let rootPath = root.standardizedFileURL.path
        let childPath = child.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard childPath.hasPrefix(prefix) else {
            throw MyPromptImporterError.unsafeEntry
        }
        let relative = String(childPath.dropFirst(prefix.count))
        guard !relative.isEmpty,
              !relative.split(separator: "/").contains("..") else {
            throw MyPromptImporterError.unsafeEntry
        }
        return relative
    }

    private struct AggregateSection {
        var level: Int
        var title: String
        var parentTitle: String?
        var prose: [String] = []
        var fences: [String] = []
    }

    private func parseAggregateMarkdown(
        _ text: String,
        source: MyPromptSource,
        sourceKeyPrefix: String
    ) throws -> [MyPromptRecord] {
        let lines = text.components(separatedBy: .newlines)
        var current: AggregateSection?
        var parentH2: String?
        var fenceMarker: Character?
        var fenceLines: [String] = []
        var completed: [AggregateSection] = []

        func finishSection() {
            if let current {
                completed.append(current)
            }
            current = nil
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let marker = fenceMarker {
                if isFenceClose(trimmed, marker: marker) {
                    current?.fences.append(
                        fenceLines.joined(separator: "\n")
                            .trimmingCharacters(in: .newlines)
                    )
                    fenceMarker = nil
                    fenceLines.removeAll(keepingCapacity: true)
                } else {
                    fenceLines.append(line)
                }
                continue
            }

            if let heading = markdownHeading(trimmed) {
                finishSection()
                if heading.level == 2 {
                    parentH2 = heading.title
                    current = AggregateSection(
                        level: 2,
                        title: heading.title
                    )
                } else {
                    current = AggregateSection(
                        level: 3,
                        title: heading.title,
                        parentTitle: parentH2
                    )
                }
                continue
            }
            if let marker = fenceOpen(trimmed), current != nil {
                fenceMarker = marker
                fenceLines.removeAll(keepingCapacity: true)
                continue
            }
            if current != nil, !trimmed.isEmpty {
                current?.prose.append(trimmed)
            }
        }
        guard fenceMarker == nil else {
            throw MyPromptImporterError.malformedMarkdown
        }
        finishSection()

        var duplicateCounts: [String: Int] = [:]
        var records: [MyPromptRecord] = []
        for section in completed where
            section.fences.contains(where: { !$0.isEmpty }) {
            let title = section.title.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !title.isEmpty else { continue }
            let baseKey = slug(title)
            let nonemptyFences = section.fences.filter { !$0.isEmpty }
            let summary = firstParagraph(
                section.prose.joined(separator: "\n")
            )
            let tags = section.level == 3
                ? [section.parentTitle].compactMap { $0 }
                : []
            for (fenceIndex, body) in nonemptyFences.enumerated() {
                let hash = aggregateFenceHash(body)
                let identity = "\(baseKey)-\(hash)"
                let duplicate = (duplicateCounts[identity] ?? 0) + 1
                duplicateCounts[identity] = duplicate
                let keySuffix = duplicate == 1
                    ? identity
                    : "\(identity)-\(duplicate)"
                let recordTitle = nonemptyFences.count == 1
                    ? title
                    : "\(title) \(fenceIndex + 1)"
                records.append(
                    MyPromptRecord(
                        sourceID: source.id,
                        sourceKey: "\(sourceKeyPrefix)#\(keySuffix)",
                        title: recordTitle,
                        summary: summary,
                        tags: tags,
                        systemPrompt: body
                    )
                )
            }
        }
        return records
    }

    private struct FrontMatter {
        var title = ""
        var summary = ""
        var tags: [String] = []
        var favorite = false
        var body = ""
    }

    private func parseFrontMatter(_ text: String) throws -> FrontMatter {
        let lines = text.components(separatedBy: .newlines)
        guard lines.first?.trimmingCharacters(in: .whitespacesAndNewlines)
                == "---" else {
            return FrontMatter(body: text)
        }
        guard let end = lines.dropFirst().prefix(257).firstIndex(where: {
            $0.trimmingCharacters(in: .whitespacesAndNewlines) == "---"
        }) else {
            throw MyPromptImporterError.malformedMarkdown
        }
        let headerLines = lines[1..<end]
        guard headerLines.joined(separator: "\n").utf8.count <= 64 * 1_024
        else {
            throw MyPromptImporterError.malformedMarkdown
        }

        var result = FrontMatter()
        var collectingTags = false
        for rawLine in headerLines {
            let trimmed = rawLine.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            if collectingTags, trimmed.hasPrefix("- ") {
                let tag = safeYAMLScalar(String(trimmed.dropFirst(2)))
                if !tag.isEmpty { result.tags.append(tag) }
                continue
            }
            collectingTags = false
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"),
                  let colon = trimmed.firstIndex(of: ":") else {
                continue
            }
            let key = trimmed[..<colon].lowercased()
            let rawValue = String(trimmed[trimmed.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
            switch key {
            case "title", "name":
                result.title = safeYAMLScalar(rawValue)
            case "description", "summary":
                result.summary = safeYAMLScalar(rawValue)
            case "tags":
                if rawValue.isEmpty {
                    collectingTags = true
                } else {
                    result.tags.append(contentsOf: parseInlineTags(rawValue))
                }
            case "favorite", "favourite":
                result.favorite = ["true", "yes", "1"].contains(
                    rawValue.lowercased()
                )
            default:
                continue
            }
        }
        result.tags = unique(result.tags)
        result.body = lines[(end + 1)...].joined(separator: "\n")
        return result
    }

    private func hasYAMLFrontMatter(_ text: String) -> Bool {
        guard let firstLine = text.split(
            separator: "\n",
            maxSplits: 1,
            omittingEmptySubsequences: false
        ).first else {
            return false
        }
        return firstLine.trimmingCharacters(
            in: .whitespacesAndNewlines
        ) == "---"
    }

    private struct FabricMetadata {
        var title = ""
        var summary = ""
        var tags: [String] = []
    }

    private func loadPatternDescriptions(
        selectedRoot: URL,
        patternsRoot: URL,
        bytesRead: inout Int
    ) throws -> [String: FabricMetadata] {
        var candidates: [URL] = []
        let scriptsDirectory = selectedRoot.appendingPathComponent(
            "scripts",
            isDirectory: true
        )
        if try optionalDirectoryExists(scriptsDirectory) {
            let descriptionsDirectory = scriptsDirectory
                .appendingPathComponent(
                    "pattern_descriptions",
                    isDirectory: true
                )
            if try optionalDirectoryExists(descriptionsDirectory) {
                candidates.append(
                    descriptionsDirectory.appendingPathComponent(
                        "pattern_descriptions.json"
                    )
                )
            }
        }
        candidates.append(contentsOf: [
            selectedRoot.appendingPathComponent(
                "pattern_descriptions.json"
            ),
            patternsRoot.deletingLastPathComponent()
                .appendingPathComponent("pattern_descriptions.json"),
        ])
        guard let url = try candidates.first(where: {
            try optionalRegularFileExists($0)
        }) else {
            return [:]
        }
        let data = try readData(url, bytesRead: &bytesRead)
        let object = try JSONSerialization.jsonObject(
            with: data,
            options: [.fragmentsAllowed]
        )
        var output: [String: FabricMetadata] = [:]

        func metadata(_ value: Any) -> FabricMetadata {
            if let summary = value as? String {
                return FabricMetadata(summary: summary)
            }
            guard let dictionary = value as? [String: Any] else {
                return FabricMetadata()
            }
            return FabricMetadata(
                title: dictionary["title"] as? String ?? "",
                summary: dictionary["description"] as? String ??
                    dictionary["summary"] as? String ?? "",
                tags: dictionary["tags"] as? [String] ?? []
            )
        }

        if let dictionary = object as? [String: Any] {
            let container = dictionary["patterns"] as? [String: Any] ??
                dictionary
            for (key, value) in container {
                output[key] = metadata(value)
            }
            if let items = dictionary["patterns"] as? [[String: Any]] {
                for item in items {
                    guard let key = item["patternName"] as? String ??
                            item["name"] as? String ??
                            item["id"] as? String else { continue }
                    output[key] = metadata(item)
                }
            }
        } else if let items = object as? [[String: Any]] {
            for item in items {
                guard let key = item["patternName"] as? String ??
                        item["name"] as? String ??
                        item["id"] as? String else { continue }
                output[key] = metadata(item)
            }
        }
        return output
    }

    private enum EntryType {
        case regularFile
        case directory
    }

    private func entryType(_ url: URL) throws -> EntryType {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            if errno == ENOENT {
                throw MyPromptImporterError.sourceMissing
            }
            throw MyPromptImporterError.unsafeEntry
        }
        switch info.st_mode & S_IFMT {
        case S_IFLNK:
            throw MyPromptImporterError.sourceIsSymbolicLink
        case S_IFREG:
            return .regularFile
        case S_IFDIR:
            return .directory
        default:
            throw MyPromptImporterError.unsafeEntry
        }
    }

    private func optionalRegularFileExists(_ url: URL) throws -> Bool {
        var info = stat()
        if lstat(url.path, &info) != 0 {
            if errno == ENOENT { return false }
            throw MyPromptImporterError.unsafeEntry
        }
        guard (info.st_mode & S_IFMT) != S_IFLNK else {
            throw MyPromptImporterError.sourceIsSymbolicLink
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            throw MyPromptImporterError.unsafeEntry
        }
        return true
    }

    private func optionalDirectoryExists(_ url: URL) throws -> Bool {
        var info = stat()
        if lstat(url.path, &info) != 0 {
            if errno == ENOENT { return false }
            throw MyPromptImporterError.unsafeEntry
        }
        guard (info.st_mode & S_IFMT) != S_IFLNK else {
            throw MyPromptImporterError.sourceIsSymbolicLink
        }
        guard (info.st_mode & S_IFMT) == S_IFDIR else {
            throw MyPromptImporterError.unsafeEntry
        }
        return true
    }

    private func readUTF8(
        _ url: URL,
        bytesRead: inout Int
    ) throws -> String {
        let data = try readData(url, bytesRead: &bytesRead)
        guard !data.contains(0) else {
            throw MyPromptImporterError.containsNUL
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw MyPromptImporterError.invalidUTF8
        }
        return text
    }

    private func readData(
        _ url: URL,
        bytesRead: inout Int
    ) throws -> Data {
        var before = stat()
        guard lstat(url.path, &before) == 0 else {
            throw MyPromptImporterError.sourceMissing
        }
        guard (before.st_mode & S_IFMT) == S_IFREG else {
            if (before.st_mode & S_IFMT) == S_IFLNK {
                throw MyPromptImporterError.sourceIsSymbolicLink
            }
            throw MyPromptImporterError.unsafeEntry
        }
        guard before.st_size >= 0,
              before.st_size <= Self.maximumFileBytes else {
            throw MyPromptImporterError.oversizedFile
        }
        guard bytesRead + Int(before.st_size) <= Self.maximumTotalBytes else {
            throw MyPromptImporterError.oversizedImport
        }

        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw MyPromptImporterError.unsafeEntry
        }
        defer { close(descriptor) }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0,
              (opened.st_mode & S_IFMT) == S_IFREG,
              opened.st_dev == before.st_dev,
              opened.st_ino == before.st_ino else {
            throw MyPromptImporterError.unsafeEntry
        }

        var data = Data()
        data.reserveCapacity(Int(opened.st_size))
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw MyPromptImporterError.unsafeEntry
            }
            data.append(buffer, count: count)
            guard data.count <= Self.maximumFileBytes else {
                throw MyPromptImporterError.oversizedFile
            }
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0,
              after.st_dev == opened.st_dev,
              after.st_ino == opened.st_ino,
              after.st_size == opened.st_size,
              data.count == Int(opened.st_size) else {
            throw MyPromptImporterError.unsafeEntry
        }
        bytesRead += data.count
        guard bytesRead <= Self.maximumTotalBytes else {
            throw MyPromptImporterError.oversizedImport
        }
        return data
    }

    private func markdownHeading(
        _ line: String
    ) -> (level: Int, title: String)? {
        let level: Int
        let prefix: String
        if line.hasPrefix("### ") {
            level = 3
            prefix = "### "
        } else if line.hasPrefix("## ") {
            level = 2
            prefix = "## "
        } else {
            return nil
        }
        let title = String(line.dropFirst(prefix.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : (level, title)
    }

    private func fenceOpen(_ line: String) -> Character? {
        if line.hasPrefix("```") { return "`" }
        if line.hasPrefix("~~~") { return "~" }
        return nil
    }

    private func isFenceClose(_ line: String, marker: Character) -> Bool {
        let prefix = String(repeating: String(marker), count: 3)
        return line.hasPrefix(prefix) &&
            line.dropFirst(3).allSatisfy {
                $0 == marker || $0.isWhitespace
            }
    }

    private func parseInlineTags(_ raw: String) -> [String] {
        let unwrapped: String
        if raw.hasPrefix("["), raw.hasSuffix("]") {
            unwrapped = String(raw.dropFirst().dropLast())
        } else {
            unwrapped = raw
        }
        return unwrapped.split(separator: ",").map {
            safeYAMLScalar(String($0))
        }.filter { !$0.isEmpty }
    }

    private func safeYAMLScalar(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return trimmed }
        if (trimmed.first == "\"" && trimmed.last == "\"") ||
            (trimmed.first == "'" && trimmed.last == "'") {
            let inner = String(trimmed.dropFirst().dropLast())
            if trimmed.first == "\"" {
                return inner
                    .replacingOccurrences(of: "\\\"", with: "\"")
                    .replacingOccurrences(of: "\\\\", with: "\\")
            }
            return inner.replacingOccurrences(of: "''", with: "'")
        }
        return trimmed
    }

    private func firstParagraph(_ text: String) -> String {
        let paragraphs = text.components(separatedBy: "\n\n")
        for paragraph in paragraphs {
            let compact = paragraph
                .split(whereSeparator: \.isNewline)
                .map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                .filter {
                    !$0.isEmpty && !$0.hasPrefix("#") &&
                        !$0.hasPrefix("```") && !$0.hasPrefix("~~~")
                }
                .joined(separator: " ")
            if !compact.isEmpty {
                return String(compact.prefix(2_000))
            }
        }
        return ""
    }

    private func humanizedTitle(_ key: String) -> String {
        key.replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
    }

    private func slug(_ title: String) -> String {
        let scalars = title.lowercased().unicodeScalars.map { scalar -> String in
            if CharacterSet.alphanumerics.contains(scalar) {
                return String(scalar)
            }
            return "-"
        }.joined()
        let pieces = scalars.split(separator: "-")
        return pieces.isEmpty ? "prompt" : pieces.joined(separator: "-")
    }

    private func aggregateFenceHash(_ body: String) -> String {
        SHA256.hash(data: Data(body.utf8))
            .prefix(8)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}

private extension String {
    var nonEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
