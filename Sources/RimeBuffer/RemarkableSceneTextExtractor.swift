import Foundation

/// Failures produced by the deliberately small, read-only reMarkable scene
/// parser. None of the cases retain file bytes or extracted text.
enum RemarkableSceneTextExtractionError: Error, Equatable, LocalizedError {
    case inputTooLarge
    case outputTooLarge
    case unsupportedHeader
    case truncatedInput
    case malformedStructure
    case invalidUTF8
    case nulCharacter
    case missingRootText
    case cyclicCRDT
    case crdtTooLarge

    var errorDescription: String? {
        switch self {
        case .inputTooLarge:
            return "The reMarkable file exceeds the supported input size."
        case .outputTooLarge:
            return "The reMarkable typed text exceeds the supported output size."
        case .unsupportedHeader:
            return "The file is not a supported reMarkable version 6 scene."
        case .truncatedInput:
            return "The reMarkable scene is truncated."
        case .malformedStructure:
            return "The reMarkable scene has an invalid structure."
        case .invalidUTF8:
            return "The reMarkable typed text is not valid UTF-8."
        case .nulCharacter:
            return "The reMarkable typed text contains a NUL character."
        case .missingRootText:
            return "The reMarkable scene does not contain typed text."
        case .cyclicCRDT:
            return "The reMarkable typed-text ordering contains a cycle."
        case .crdtTooLarge:
            return "The reMarkable typed-text history is too large."
        }
    }
}

/// Minimal software-3/v6 typed-text extraction.
///
/// The tagged-block layout, text-item expansion, and CRDT ordering are based on
/// rmscene 0.8.0 (Rick Lupton), used under its MIT License. This is an
/// independent, read-only Swift implementation and intentionally ignores text
/// styling and every scene block other than RootTextBlock (0x07).
enum RemarkableSceneTextExtractor {
    static let maximumInputBytes = 8 * 1024 * 1024
    static let maximumOutputBytes = 1 * 1024 * 1024

    // A page can contain hidden tombstones and formatting nodes in addition to
    // visible text. Keep their total graph no larger than the already bounded
    // 1 MiB output surface so cancellation cannot leave a huge sort running.
    private static let maximumCRDTElements = 1 * 1024 * 1024
    private static let headerV6 = Array(
        "reMarkable .lines file, version=6          ".utf8
    )

    static func extract(from data: Data) throws -> String {
        guard data.count <= maximumInputBytes else {
            throw RemarkableSceneTextExtractionError.inputTooLarge
        }

        let bytes = [UInt8](data)
        guard bytes.count >= headerV6.count,
              bytes.prefix(headerV6.count).elementsEqual(headerV6) else {
            throw RemarkableSceneTextExtractionError.unsupportedHeader
        }

        var stream = RemarkableByteReader(
            bytes: bytes,
            position: headerV6.count,
            limit: bytes.count
        )
        var latestRootText: [RemarkableRawTextItem]?

        while !stream.isAtEnd {
            guard stream.remaining >= 8 else {
                throw RemarkableSceneTextExtractionError.truncatedInput
            }

            let payloadLength = Int(try stream.readUInt32())
            let reserved = try stream.readByte()
            let minimumVersion = try stream.readByte()
            let currentVersion = try stream.readByte()
            let blockType = try stream.readByte()

            guard reserved == 0, minimumVersion <= currentVersion else {
                throw RemarkableSceneTextExtractionError.malformedStructure
            }

            var payload = try stream.readSlice(count: payloadLength)
            if blockType == 0x07 {
                latestRootText = try parseRootTextBlock(from: &payload)
            }
        }

        guard let latestRootText else {
            throw RemarkableSceneTextExtractionError.missingRootText
        }
        return try render(latestRootText)
    }

    private static func parseRootTextBlock(
        from payload: inout RemarkableByteReader
    ) throws -> [RemarkableRawTextItem] {
        let blockID = try payload.readID(index: 1)
        guard blockID == .endMarker else {
            throw RemarkableSceneTextExtractionError.malformedStructure
        }

        var textValue = try payload.readSubblock(index: 2)
        var itemsSection = try textValue.readSubblock(index: 1)
        var itemsList = try itemsSection.readSubblock(index: 1)
        let itemCount = try itemsList.readCount()

        // Every item must at least have a subblock tag and its uint32 length.
        guard itemCount <= itemsList.remaining / 5 else {
            throw RemarkableSceneTextExtractionError.malformedStructure
        }

        var items: [RemarkableRawTextItem] = []
        items.reserveCapacity(itemCount)
        var visibleUTF8Bytes = 0

        for _ in 0..<itemCount {
            let item = try parseTextItem(from: &itemsList)
            let (nextVisibleBytes, overflow) = visibleUTF8Bytes.addingReportingOverflow(
                item.visibleUTF8Bytes
            )
            guard !overflow, nextVisibleBytes <= maximumOutputBytes else {
                throw RemarkableSceneTextExtractionError.outputTooLarge
            }
            visibleUTF8Bytes = nextVisibleBytes
            items.append(item)
        }

        // Paragraph and inline style records are intentionally ignored, but
        // their declared outer boundary is still validated.
        _ = try textValue.readSubblock(index: 2)

        // RootTextBlock's trailing geometry is part of the known v6 shape. Its
        // values have no bearing on text extraction.
        var position = try payload.readSubblock(index: 3)
        try position.skip(count: 16)
        try payload.readTag(index: 4, type: .byte4)
        try payload.skip(count: 4)

        return items
    }

    private static func parseTextItem(
        from itemsList: inout RemarkableByteReader
    ) throws -> RemarkableRawTextItem {
        var item = try itemsList.readSubblock(index: 0)
        let itemID = try item.readID(index: 2)
        let leftID = try item.readID(index: 3)
        let rightID = try item.readID(index: 4)
        let deletedLength = Int(try item.readTaggedUInt32(index: 5))

        var text: String?
        var hasFormatCode = false
        if try item.nextTagMatches(index: 6, type: .length4) {
            var value = try item.readSubblock(index: 6)
            let byteCount = try value.readCount()
            let stringMarker = try value.readByte()
            guard stringMarker == 1 else {
                throw RemarkableSceneTextExtractionError.malformedStructure
            }
            let textBytes = try value.readBytes(count: byteCount)
            guard let decoded = String(bytes: textBytes, encoding: .utf8) else {
                throw RemarkableSceneTextExtractionError.invalidUTF8
            }
            guard !decoded.unicodeScalars.contains(where: { $0.value == 0 }) else {
                throw RemarkableSceneTextExtractionError.nulCharacter
            }
            text = decoded

            if try value.nextTagMatches(index: 2, type: .byte4) {
                _ = try value.readTaggedUInt32(index: 2)
                hasFormatCode = true
            }
        }

        return RemarkableRawTextItem(
            itemID: itemID,
            leftID: leftID,
            rightID: rightID,
            deletedLength: deletedLength,
            text: text,
            hasFormatCode: hasFormatCode
        )
    }

    private static func render(_ rawItems: [RemarkableRawTextItem]) throws -> String {
        if rawItems.count == 1,
           let only = rawItems.first,
           only.deletedLength == 0,
           !only.hasFormatCode,
           only.leftID == .endMarker,
           only.rightID == .endMarker {
            let text = only.text ?? ""
            guard !text.isEmpty else { return "" }
            let scalarCount = text.unicodeScalars.count
            guard scalarCount <= maximumCRDTElements else {
                throw RemarkableSceneTextExtractionError.crdtTooLarge
            }
            guard only.itemID != .endMarker,
                  UInt64(scalarCount - 1) <= UInt64.max - only.itemID.clock else {
                throw RemarkableSceneTextExtractionError.malformedStructure
            }
            return text
        }

        var runs: [RemarkableTextRun] = []
        runs.reserveCapacity(rawItems.count)
        var totalElementCount = 0
        var outputByteCount = 0

        for item in rawItems {
            let payload: RemarkableTextRun.Payload
            let count: Int

            if item.deletedLength > 0 {
                guard (item.text ?? "").isEmpty, !item.hasFormatCode else {
                    throw RemarkableSceneTextExtractionError.malformedStructure
                }
                payload = .hidden
                count = item.deletedLength
            } else if item.hasFormatCode {
                guard (item.text ?? "").isEmpty else {
                    throw RemarkableSceneTextExtractionError.malformedStructure
                }
                payload = .hidden
                count = 1
            } else {
                let scalarValues = (item.text ?? "").unicodeScalars.map(\.value)
                guard !scalarValues.isEmpty else { continue }
                payload = .text(scalarValues)
                count = scalarValues.count
                outputByteCount += (item.text ?? "").utf8.count
            }

            let (nextCount, countOverflow) = totalElementCount.addingReportingOverflow(count)
            guard !countOverflow, nextCount <= maximumCRDTElements else {
                throw RemarkableSceneTextExtractionError.crdtTooLarge
            }
            guard item.itemID != .endMarker,
                  count > 0,
                  UInt64(count - 1) <= UInt64.max - item.itemID.clock else {
                throw RemarkableSceneTextExtractionError.malformedStructure
            }

            totalElementCount = nextCount
            runs.append(RemarkableTextRun(
                firstID: item.itemID,
                leftID: item.leftID,
                rightID: item.rightID,
                count: count,
                payload: payload
            ))
        }

        guard outputByteCount <= maximumOutputBytes else {
            throw RemarkableSceneTextExtractionError.outputTooLarge
        }
        guard !runs.isEmpty else { return "" }

        var intervalsByAuthor = Array(
            repeating: [RemarkableRunInterval](),
            count: 256
        )
        for (index, run) in runs.enumerated() {
            intervalsByAuthor[Int(run.firstID.author)].append(
                RemarkableRunInterval(
                    firstClock: run.firstID.clock,
                    lastClock: run.lastClock,
                    runIndex: index
                )
            )
        }
        for author in intervalsByAuthor.indices {
            intervalsByAuthor[author].sort {
                if $0.firstClock != $1.firstClock {
                    return $0.firstClock < $1.firstClock
                }
                return $0.lastClock < $1.lastClock
            }
            for index in intervalsByAuthor[author].indices.dropFirst() {
                guard intervalsByAuthor[author][index].firstClock
                        > intervalsByAuthor[author][index - 1].lastClock else {
                    throw RemarkableSceneTextExtractionError.malformedStructure
                }
            }
        }

        func resolve(_ id: RemarkableCRDTID) -> RemarkableNodeReference? {
            guard id != .endMarker else { return nil }
            let intervals = intervalsByAuthor[Int(id.author)]
            var lower = 0
            var upper = intervals.count
            while lower < upper {
                let middle = lower + (upper - lower) / 2
                if intervals[middle].firstClock <= id.clock {
                    lower = middle + 1
                } else {
                    upper = middle
                }
            }
            guard lower > 0 else { return nil }
            let interval = intervals[lower - 1]
            guard id.clock <= interval.lastClock else { return nil }
            return RemarkableNodeReference(
                runIndex: interval.runIndex,
                offset: Int(id.clock - interval.firstClock)
            )
        }

        var startDependents: [Int] = []
        var leftDependents: [RemarkableNodeReference: [Int]] = [:]
        var rightIncoming: [RemarkableNodeReference: Int] = [:]
        var rightTargets = Array<RemarkableNodeReference?>(
            repeating: nil,
            count: runs.count
        )
        var endRemaining = 0

        for (runIndex, run) in runs.enumerated() {
            if let left = resolve(run.leftID) {
                leftDependents[left, default: []].append(runIndex)
            } else {
                startDependents.append(runIndex)
            }

            if let right = resolve(run.rightID) {
                rightTargets[runIndex] = right
                let oldCount = rightIncoming[right, default: 0]
                guard oldCount < Int.max else {
                    throw RemarkableSceneTextExtractionError.malformedStructure
                }
                rightIncoming[right] = oldCount + 1
            } else {
                endRemaining += 1
            }
        }

        var remainingOverrides: [RemarkableNodeReference: Int] = [:]
        var ready = RemarkableNodeHeap(runs: runs)

        func initialDegree(_ node: RemarkableNodeReference) -> Int {
            1 + (rightIncoming[node] ?? 0)
        }

        func decrement(_ node: RemarkableNodeReference) throws {
            let remaining = remainingOverrides[node] ?? initialDegree(node)
            guard remaining > 0 else {
                throw RemarkableSceneTextExtractionError.malformedStructure
            }
            if remaining == 1 {
                remainingOverrides.removeValue(forKey: node)
                ready.push(node)
            } else {
                remainingOverrides[node] = remaining - 1
            }
        }

        for runIndex in startDependents {
            try decrement(RemarkableNodeReference(runIndex: runIndex, offset: 0))
        }

        var output: [UInt8] = []
        output.reserveCapacity(outputByteCount)
        var processedCount = 0

        while let node = ready.pop() {
            processedCount += 1
            let run = runs[node.runIndex]
            if case let .text(scalars) = run.payload {
                appendUTF8(scalars[node.offset], to: &output)
            }

            if node.offset + 1 < run.count {
                try decrement(RemarkableNodeReference(
                    runIndex: node.runIndex,
                    offset: node.offset + 1
                ))
            } else if let right = rightTargets[node.runIndex] {
                try decrement(right)
            } else {
                guard endRemaining > 0 else {
                    throw RemarkableSceneTextExtractionError.malformedStructure
                }
                endRemaining -= 1
            }

            if let dependents = leftDependents[node] {
                for runIndex in dependents {
                    try decrement(RemarkableNodeReference(runIndex: runIndex, offset: 0))
                }
            }
        }

        guard processedCount == totalElementCount else {
            throw RemarkableSceneTextExtractionError.cyclicCRDT
        }
        guard endRemaining == 0, output.count == outputByteCount,
              let result = String(bytes: output, encoding: .utf8) else {
            throw RemarkableSceneTextExtractionError.malformedStructure
        }
        return result
    }

    private static func appendUTF8(_ scalar: UInt32, to output: inout [UInt8]) {
        if scalar <= 0x7F {
            output.append(UInt8(scalar))
        } else if scalar <= 0x7FF {
            output.append(UInt8(0xC0 | (scalar >> 6)))
            output.append(UInt8(0x80 | (scalar & 0x3F)))
        } else if scalar <= 0xFFFF {
            output.append(UInt8(0xE0 | (scalar >> 12)))
            output.append(UInt8(0x80 | ((scalar >> 6) & 0x3F)))
            output.append(UInt8(0x80 | (scalar & 0x3F)))
        } else {
            output.append(UInt8(0xF0 | (scalar >> 18)))
            output.append(UInt8(0x80 | ((scalar >> 12) & 0x3F)))
            output.append(UInt8(0x80 | ((scalar >> 6) & 0x3F)))
            output.append(UInt8(0x80 | (scalar & 0x3F)))
        }
    }
}

private struct RemarkableRawTextItem {
    let itemID: RemarkableCRDTID
    let leftID: RemarkableCRDTID
    let rightID: RemarkableCRDTID
    let deletedLength: Int
    let text: String?
    let hasFormatCode: Bool

    var visibleUTF8Bytes: Int {
        guard deletedLength == 0, !hasFormatCode else { return 0 }
        return text?.utf8.count ?? 0
    }
}

private struct RemarkableCRDTID: Hashable {
    let author: UInt8
    let clock: UInt64

    static let endMarker = RemarkableCRDTID(author: 0, clock: 0)
}

private struct RemarkableTextRun {
    enum Payload {
        case text([UInt32])
        case hidden
    }

    let firstID: RemarkableCRDTID
    let leftID: RemarkableCRDTID
    let rightID: RemarkableCRDTID
    let count: Int
    let payload: Payload

    var lastClock: UInt64 {
        firstID.clock + UInt64(count - 1)
    }
}

private struct RemarkableRunInterval {
    let firstClock: UInt64
    let lastClock: UInt64
    let runIndex: Int
}

private struct RemarkableNodeReference: Hashable {
    let runIndex: Int
    let offset: Int
}

private struct RemarkableNodeHeap {
    private var storage: [RemarkableNodeReference] = []
    private let runs: [RemarkableTextRun]

    init(runs: [RemarkableTextRun]) {
        self.runs = runs
    }

    mutating func push(_ node: RemarkableNodeReference) {
        storage.append(node)
        var child = storage.count - 1
        while child > 0 {
            let parent = (child - 1) / 2
            guard precedes(storage[child], storage[parent]) else { break }
            storage.swapAt(child, parent)
            child = parent
        }
    }

    mutating func pop() -> RemarkableNodeReference? {
        guard !storage.isEmpty else { return nil }
        if storage.count == 1 {
            return storage.removeLast()
        }

        let result = storage[0]
        storage[0] = storage.removeLast()
        var parent = 0

        while true {
            let left = parent * 2 + 1
            guard left < storage.count else { break }
            let right = left + 1
            var child = left
            if right < storage.count, precedes(storage[right], storage[left]) {
                child = right
            }
            guard precedes(storage[child], storage[parent]) else { break }
            storage.swapAt(child, parent)
            parent = child
        }
        return result
    }

    private func precedes(
        _ lhs: RemarkableNodeReference,
        _ rhs: RemarkableNodeReference
    ) -> Bool {
        let lhsID = id(for: lhs)
        let rhsID = id(for: rhs)
        if lhsID.author != rhsID.author {
            return lhsID.author > rhsID.author
        }
        return lhsID.clock < rhsID.clock
    }

    private func id(for node: RemarkableNodeReference) -> RemarkableCRDTID {
        let run = runs[node.runIndex]
        return RemarkableCRDTID(
            author: run.firstID.author,
            clock: run.firstID.clock + UInt64(node.offset)
        )
    }
}

private enum RemarkableTagType: UInt64 {
    case id = 0x0F
    case length4 = 0x0C
    case byte4 = 0x04
}

private struct RemarkableByteReader {
    let bytes: [UInt8]
    var position: Int
    let limit: Int

    var remaining: Int { limit - position }
    var isAtEnd: Bool { position == limit }

    mutating func readByte() throws -> UInt8 {
        guard position < limit else {
            throw RemarkableSceneTextExtractionError.truncatedInput
        }
        defer { position += 1 }
        return bytes[position]
    }

    mutating func readBytes(count: Int) throws -> ArraySlice<UInt8> {
        guard count >= 0, count <= remaining else {
            throw RemarkableSceneTextExtractionError.truncatedInput
        }
        let start = position
        position += count
        return bytes[start..<position]
    }

    mutating func skip(count: Int) throws {
        _ = try readBytes(count: count)
    }

    mutating func readSlice(count: Int) throws -> RemarkableByteReader {
        guard count >= 0, count <= remaining else {
            throw RemarkableSceneTextExtractionError.truncatedInput
        }
        let start = position
        position += count
        return RemarkableByteReader(
            bytes: bytes,
            position: start,
            limit: start + count
        )
    }

    mutating func readUInt32() throws -> UInt32 {
        let b0 = UInt32(try readByte())
        let b1 = UInt32(try readByte())
        let b2 = UInt32(try readByte())
        let b3 = UInt32(try readByte())
        return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
    }

    mutating func readVarUInt() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0

        for index in 0..<10 {
            let byte = try readByte()
            let payload = UInt64(byte & 0x7F)
            if index == 9, payload > 1 {
                throw RemarkableSceneTextExtractionError.malformedStructure
            }
            result |= payload << shift
            if byte & 0x80 == 0 {
                return result
            }
            shift += 7
        }
        throw RemarkableSceneTextExtractionError.malformedStructure
    }

    mutating func readCount() throws -> Int {
        let count = try readVarUInt()
        guard count <= UInt64(Int.max) else {
            throw RemarkableSceneTextExtractionError.malformedStructure
        }
        return Int(count)
    }

    mutating func readTag(index: UInt64, type: RemarkableTagType) throws {
        let tag = try readVarUInt()
        guard tag >> 4 == index, tag & 0x0F == type.rawValue else {
            throw RemarkableSceneTextExtractionError.malformedStructure
        }
    }

    mutating func nextTagMatches(
        index: UInt64,
        type: RemarkableTagType
    ) throws -> Bool {
        guard !isAtEnd else { return false }
        var copy = self
        let tag = try copy.readVarUInt()
        return tag >> 4 == index && tag & 0x0F == type.rawValue
    }

    mutating func readID(index: UInt64) throws -> RemarkableCRDTID {
        try readTag(index: index, type: .id)
        return RemarkableCRDTID(
            author: try readByte(),
            clock: try readVarUInt()
        )
    }

    mutating func readTaggedUInt32(index: UInt64) throws -> UInt32 {
        try readTag(index: index, type: .byte4)
        return try readUInt32()
    }

    mutating func readSubblock(index: UInt64) throws -> RemarkableByteReader {
        try readTag(index: index, type: .length4)
        return try readSlice(count: Int(try readUInt32()))
    }
}
