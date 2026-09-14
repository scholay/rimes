import Cocoa
import Foundation
import ImageIO
import UniformTypeIdentifiers
import zlib

/// A lossless, bounded representation of one system-pasteboard write.
///
/// The JSON shape intentionally matches Paste 5.0.5's decoded payload:
/// a top-level array of objects containing `types` and `dataByType`, where
/// Foundation encodes every `Data` value as base64. Compression is raw DEFLATE
/// (a negative zlib window size), not a zlib- or gzip-wrapped stream.
struct ClipboardPasteboardArchive: Equatable, Sendable {
    /// AppKit advertises this UTF-16 conversion for ordinary string items on
    /// recent macOS releases even though `data(forType:)` returns nil. It is a
    /// synthesized projection of the readable UTF-8/plain-text value, not an
    /// independent source representation. Unknown unreadable types remain a
    /// fail-closed archive error.
    private static let unreadableSynthesizedTextTypeNames: Set<String> = [
        "public.utf16-external-plain-text",
    ]
    private static let readablePlainTextEncodings: [String: [String.Encoding]] = [
        NSPasteboard.PasteboardType.string.rawValue: [.utf8],
        "public.utf16-plain-text": [
            .utf16,
            .utf16LittleEndian,
            .utf16BigEndian,
        ],
        "public.plain-text": [.utf8],
        "NSStringPboardType": [.utf8, .utf16],
    ]

    struct Item: Codable, Equatable, Sendable {
        let types: [String]
        let dataByType: [String: Data]

        init(types: [String], dataByType: [String: Data]) {
            self.types = types
            self.dataByType = dataByType
        }

        private enum CodingKeys: String, CodingKey {
            case types
            case dataByType
        }

        init(from decoder: Decoder) throws {
            let raw = try decoder.container(
                keyedBy: ClipboardPasteboardArchiveCodingKey.self
            )
            let actualKeys = Set(raw.allKeys.map(\.stringValue))
            let expectedKeys: Set<String> = [
                CodingKeys.types.rawValue,
                CodingKeys.dataByType.rawValue,
            ]
            guard actualKeys == expectedKeys else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: decoder.codingPath,
                        debugDescription: "Unexpected pasteboard archive keys."
                    )
                )
            }

            let container = try decoder.container(keyedBy: CodingKeys.self)
            types = try container.decode([String].self, forKey: .types)
            dataByType = try container.decode(
                [String: Data].self,
                forKey: .dataByType
            )
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(types, forKey: .types)
            try container.encode(dataByType, forKey: .dataByType)
        }
    }

    struct Limits: Equatable, Sendable {
        static let standard = Limits()

        let maximumCompressedBytes: Int
        let maximumInflatedBytes: Int
        let maximumExpansionRatio: Int
        let minimumInflatedAllowanceBytes: Int
        let maximumItems: Int
        let maximumTypesPerItem: Int
        let maximumTypeNameBytes: Int
        let maximumDataBytesPerType: Int
        let maximumTotalDataBytes: Int

        init(
            maximumCompressedBytes: Int = 256 * 1_024 * 1_024,
            maximumInflatedBytes: Int = 256 * 1_024 * 1_024,
            maximumExpansionRatio: Int = 512,
            minimumInflatedAllowanceBytes: Int = 4 * 1_024 * 1_024,
            maximumItems: Int = 64,
            maximumTypesPerItem: Int = 128,
            maximumTypeNameBytes: Int = 4 * 1_024,
            maximumDataBytesPerType: Int = 128 * 1_024 * 1_024,
            maximumTotalDataBytes: Int = 192 * 1_024 * 1_024
        ) {
            self.maximumCompressedBytes = max(1, maximumCompressedBytes)
            self.maximumInflatedBytes = max(1, maximumInflatedBytes)
            // Paste data observed in the migration reaches roughly 173:1.
            // Keep the default comfortably above that and never allow callers
            // to accidentally configure a lower compatibility ceiling.
            self.maximumExpansionRatio = max(256, maximumExpansionRatio)
            self.minimumInflatedAllowanceBytes = max(
                1,
                minimumInflatedAllowanceBytes
            )
            self.maximumItems = max(1, maximumItems)
            self.maximumTypesPerItem = max(1, maximumTypesPerItem)
            self.maximumTypeNameBytes = max(1, maximumTypeNameBytes)
            self.maximumDataBytesPerType = max(1, maximumDataBytesPerType)
            self.maximumTotalDataBytes = max(1, maximumTotalDataBytes)
        }
    }

    enum ArchiveError: LocalizedError {
        case emptyCompressedPayload
        case compressedPayloadTooLarge
        case inflatedPayloadTooLarge
        case invalidCompressedPayload
        case invalidJSON
        case noPasteboardItems
        case tooManyItems
        case tooManyTypes
        case invalidTypeName
        case duplicateType
        case mismatchedTypes
        case dataValueTooLarge
        case totalDataTooLarge
        case confidentialContent
        case unreadablePasteboardType
        case pasteboardItemCreationFailed
        case pasteboardChanged
        case pasteboardWriteFailed
        case invalidCompressionLevel

        var errorDescription: String? {
            switch self {
            case .emptyCompressedPayload:
                return "剪贴板归档的压缩负载为空。"
            case .compressedPayloadTooLarge:
                return "剪贴板归档的压缩负载超过安全上限。"
            case .inflatedPayloadTooLarge:
                return "剪贴板归档解压后超过安全上限。"
            case .invalidCompressedPayload:
                return "剪贴板归档不是有效的 raw-DEFLATE 数据。"
            case .invalidJSON:
                return "剪贴板归档的 JSON 结构无效。"
            case .noPasteboardItems:
                return "剪贴板归档不包含任何条目。"
            case .tooManyItems:
                return "剪贴板归档包含过多条目。"
            case .tooManyTypes:
                return "剪贴板条目包含过多数据类型。"
            case .invalidTypeName:
                return "剪贴板条目包含无效的数据类型名称。"
            case .duplicateType:
                return "剪贴板条目包含重复的数据类型。"
            case .mismatchedTypes:
                return "剪贴板条目的类型列表与数据不一致。"
            case .dataValueTooLarge:
                return "剪贴板条目的单项数据超过安全上限。"
            case .totalDataTooLarge:
                return "剪贴板条目的总数据超过安全上限。"
            case .confidentialContent:
                return "机密或临时剪贴板内容不会被归档。"
            case .unreadablePasteboardType:
                return "无法完整读取剪贴板中的某个数据类型。"
            case .pasteboardItemCreationFailed:
                return "无法重建剪贴板条目。"
            case .pasteboardChanged:
                return "准备期间系统剪贴板已变化；未覆盖较新的内容。"
            case .pasteboardWriteFailed:
                return "无法将归档内容写回系统剪贴板。"
            case .invalidCompressionLevel:
                return "raw-DEFLATE 压缩级别无效。"
            }
        }
    }

    let items: [Item]

    /// Joins several clipboard events into one ordered pasteboard write. The
    /// regular archive limits remain authoritative for the aggregate so a
    /// large multi-selection cannot bypass the existing payload bounds.
    static func merging(
        _ archives: [ClipboardPasteboardArchive],
        limits: Limits = .standard
    ) throws -> ClipboardPasteboardArchive {
        try ClipboardPasteboardArchive(
            items: archives.flatMap(\.items),
            limits: limits
        )
    }

    init(items: [Item], limits: Limits = .standard) throws {
        try Self.validate(items, limits: limits)
        self.items = items
    }

    static func decodeRawDeflate(
        _ compressedData: Data,
        limits: Limits = .standard
    ) throws -> ClipboardPasteboardArchive {
        let jsonData = try inflateRawDeflate(
            compressedData,
            limits: limits
        )
        let decodedItems: [Item]
        do {
            decodedItems = try JSONDecoder().decode(
                [Item].self,
                from: jsonData
            )
        } catch {
            throw ArchiveError.invalidJSON
        }
        return try ClipboardPasteboardArchive(
            items: decodedItems,
            limits: limits
        )
    }

    func encodeRawDeflate(
        compressionLevel: Int32 = Z_DEFAULT_COMPRESSION,
        limits: Limits = .standard
    ) throws -> Data {
        try Self.validate(items, limits: limits)
        let jsonData: Data
        do {
            jsonData = try JSONEncoder().encode(items)
        } catch {
            throw ArchiveError.invalidJSON
        }
        guard jsonData.count <= limits.maximumInflatedBytes else {
            throw ArchiveError.inflatedPayloadTooLarge
        }
        return try Self.deflateRaw(
            jsonData,
            compressionLevel: compressionLevel,
            limits: limits
        )
    }

    /// Captures every readable representation without coercing it through a
    /// String. Confidential markers are checked before any payload is read.
    static func capture(
        from pasteboard: NSPasteboard = .general,
        limits: Limits = .standard
    ) throws -> ClipboardPasteboardArchive {
        guard let pasteboardItems = pasteboard.pasteboardItems,
              !pasteboardItems.isEmpty else {
            throw ArchiveError.noPasteboardItems
        }
        guard pasteboardItems.count <= limits.maximumItems else {
            throw ArchiveError.tooManyItems
        }

        // Preflight the complete item/type graph before asking any lazy data
        // provider for bytes. A confidential marker on a later item must block
        // the entire capture without materializing an earlier item's payload.
        let typeLists: [[String]] = try pasteboardItems.map { pasteboardItem in
            let types = pasteboardItem.types.map(\.rawValue)
            guard !types.isEmpty,
                  types.count <= limits.maximumTypesPerItem,
                  Set(types).count == types.count,
                  types.allSatisfy({ typeName in
                      !typeName.isEmpty
                          && !typeName.contains("\0")
                          && typeName.lengthOfBytes(using: .utf8)
                              <= limits.maximumTypeNameBytes
                  }) else {
                throw ArchiveError.invalidTypeName
            }
            guard confidentialTypeNames.isDisjoint(with: types) else {
                throw ArchiveError.confidentialContent
            }
            return types
        }

        var archivedItems: [Item] = []
        archivedItems.reserveCapacity(pasteboardItems.count)
        var totalDataBytes = 0
        for (pasteboardItem, types) in zip(pasteboardItems, typeLists) {
            var dataByType: [String: Data] = [:]
            dataByType.reserveCapacity(types.count)
            var unreadableTypes: [String] = []
            for typeName in types {
                let type = NSPasteboard.PasteboardType(typeName)
                guard let data = pasteboardItem.data(forType: type) else {
                    unreadableTypes.append(typeName)
                    continue
                }
                guard data.count <= limits.maximumDataBytesPerType else {
                    throw ArchiveError.dataValueTooLarge
                }
                let (nextTotal, overflow) = totalDataBytes
                    .addingReportingOverflow(data.count)
                guard !overflow,
                      nextTotal <= limits.maximumTotalDataBytes else {
                    throw ArchiveError.totalDataTooLarge
                }
                totalDataBytes = nextTotal
                dataByType[typeName] = data
            }
            let hasReadablePlainText = Self.hasDecodablePlainText(
                in: dataByType
            )
            guard !dataByType.isEmpty,
                  unreadableTypes.allSatisfy({ typeName in
                    hasReadablePlainText
                        && Self.unreadableSynthesizedTextTypeNames
                            .contains(typeName)
                  }) else {
                throw ArchiveError.unreadablePasteboardType
            }
            let readableTypes = types.filter { dataByType[$0] != nil }
            archivedItems.append(
                Item(types: readableTypes, dataByType: dataByType)
            )
        }
        return try ClipboardPasteboardArchive(
            items: archivedItems,
            limits: limits
        )
    }

    private static func hasDecodablePlainText(
        in dataByType: [String: Data]
    ) -> Bool {
        readablePlainTextEncodings.contains { typeName, encodings in
            guard let data = dataByType[typeName] else { return false }
            return encodings.contains { encoding in
                String(data: data, encoding: encoding) != nil
            }
        }
    }

    @MainActor
    func makePasteboardItems(
        limits: Limits = .standard
    ) throws -> [NSPasteboardItem] {
        try Self.validate(items, limits: limits)
        return try items.map { archivedItem in
            let pasteboardItem = NSPasteboardItem()
            for typeName in archivedItem.types {
                guard let data = archivedItem.dataByType[typeName],
                      pasteboardItem.setData(
                          data,
                          forType: NSPasteboard.PasteboardType(typeName)
                      ) else {
                    throw ArchiveError.pasteboardItemCreationFailed
                }
            }
            return pasteboardItem
        }
    }

    /// Returns the pasteboard change count after a successful write so the
    /// history monitor can baseline its own mutation immediately.
    @MainActor
    @discardableResult
    func write(
        to pasteboard: NSPasteboard = .general,
        limits: Limits = .standard,
        expectedChangeCount: Int? = nil
    ) throws -> Int {
        let pasteboardItems = try makePasteboardItems(limits: limits)
        if let expectedChangeCount,
           pasteboard.changeCount != expectedChangeCount {
            throw ArchiveError.pasteboardChanged
        }
        pasteboard.clearContents()
        guard pasteboard.writeObjects(pasteboardItems) else {
            throw ArchiveError.pasteboardWriteFailed
        }
        return pasteboard.changeCount
    }

    /// Returns true unless the archive is exactly one ordinary plain-text item.
    /// An allowlist is intentionally used here: silently flattening an unknown
    /// or future UTI would make the history look successful while discarding a
    /// representation that Paste had preserved.
    var requiresPasteboardRestorationForTextInsertion: Bool {
        guard items.count == 1, let item = items.first else { return true }
        let plainTextTypes: Set<String> = [
            "public.utf8-plain-text",
            "public.utf16-external-plain-text",
            "public.utf16-plain-text",
            "public.plain-text",
            "public.text",
            "nsstringpboardtype",
            "com.apple.traditional-mac-plain-text",
            "com.trolltech.anymime.text--plain",
        ]
        return item.types.contains { typeName in
            !plainTextTypes.contains(typeName.lowercased())
        }
    }

    /// Builds a bounded raster preview without constructing a full-size
    /// `NSImage`. ImageIO performs source decoding and downsampling on the
    /// caller's background queue; AppKit image creation can happen later on
    /// the main thread from the returned `CGImage`.
    func makeImageThumbnail(maximumPixelSize: Int) -> CGImage? {
        let maximumPixelSize = max(1, maximumPixelSize)
        let options: CFDictionary = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary

        for archivedItem in items {
            for typeName in Self.preferredImageTypes(in: archivedItem.types) {
                guard let data = archivedItem.dataByType[typeName],
                      !data.isEmpty,
                      let source = CGImageSourceCreateWithData(
                        data as CFData,
                        nil
                      ),
                      let thumbnail = CGImageSourceCreateThumbnailAtIndex(
                        source,
                        0,
                        options
                      ) else { continue }
                return thumbnail
            }
        }
        return nil
    }

    /// Whether any archived pasteboard item carries an encoded image
    /// representation. A clipboard item can be classified as `.files` because
    /// it also contains a file URL while still carrying a PNG/HEIC/etc.
    /// preview; callers must not infer thumbnail eligibility from the primary
    /// item kind alone.
    var containsImageRepresentation: Bool {
        items.contains { item in
            item.types.contains(where: Self.isImageRepresentationType)
        }
    }

    private static let confidentialTypeNames: Set<String> = [
        "org.nspasteboard.ConcealedType",
        "org.nspasteboard.TransientType",
        "com.agilebits.onepassword",
    ]

    private static func preferredImageTypes(in typeNames: [String]) -> [String] {
        let explicitOrder = [
            NSPasteboard.PasteboardType.png.rawValue,
            "public.jpeg",
            NSPasteboard.PasteboardType.tiff.rawValue,
            "public.heic",
            "public.heif",
            "public.avif",
            "com.compuserve.gif",
            "org.webmproject.webp",
            "public.webp",
            "public.image",
        ]
        let indexed = Dictionary(
            uniqueKeysWithValues: explicitOrder.enumerated().map { ($1, $0) }
        )
        return typeNames.filter(Self.isImageRepresentationType).sorted { lhs, rhs in
            let left = indexed[lhs.lowercased()] ?? explicitOrder.count
            let right = indexed[rhs.lowercased()] ?? explicitOrder.count
            if left != right { return left < right }
            return lhs < rhs
        }
    }

    /// Shared image-representation classifier for capture projection and
    /// thumbnail decoding. UniformTypeIdentifiers provides the authoritative
    /// conformance check; explicit identifiers keep common image formats
    /// deterministic even when a third-party UTI declaration is unavailable
    /// in the current process.
    static func isImageRepresentationType(_ identifier: String) -> Bool {
        let lowered = identifier
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !lowered.isEmpty else { return false }
        if let type = UTType(lowered), type.conforms(to: .image) { return true }
        return [
            NSPasteboard.PasteboardType.png.rawValue.lowercased(),
            NSPasteboard.PasteboardType.tiff.rawValue.lowercased(),
            "public.jpeg",
            "public.jpg",
            "public.heic",
            "public.heif",
            "public.avif",
            "com.compuserve.gif",
            "org.webmproject.webp",
            "public.webp",
            "public.image",
        ].contains(lowered)
    }

    private static let zlibChunkBytes = 64 * 1_024

    private static func validate(_ items: [Item], limits: Limits) throws {
        guard !items.isEmpty else { throw ArchiveError.noPasteboardItems }
        guard items.count <= limits.maximumItems else {
            throw ArchiveError.tooManyItems
        }

        var totalDataBytes = 0
        for item in items {
            guard !item.types.isEmpty else {
                throw ArchiveError.mismatchedTypes
            }
            guard item.types.count <= limits.maximumTypesPerItem,
                  item.dataByType.count <= limits.maximumTypesPerItem else {
                throw ArchiveError.tooManyTypes
            }

            let typeSet = Set(item.types)
            guard typeSet.count == item.types.count else {
                throw ArchiveError.duplicateType
            }
            guard confidentialTypeNames.isDisjoint(with: typeSet) else {
                throw ArchiveError.confidentialContent
            }
            guard typeSet == Set(item.dataByType.keys) else {
                throw ArchiveError.mismatchedTypes
            }

            for typeName in item.types {
                guard !typeName.isEmpty,
                      !typeName.contains("\0"),
                      typeName.lengthOfBytes(using: .utf8)
                          <= limits.maximumTypeNameBytes else {
                    throw ArchiveError.invalidTypeName
                }
                guard let data = item.dataByType[typeName] else {
                    throw ArchiveError.mismatchedTypes
                }
                guard data.count <= limits.maximumDataBytesPerType else {
                    throw ArchiveError.dataValueTooLarge
                }
                let (nextTotal, overflow) = totalDataBytes
                    .addingReportingOverflow(data.count)
                guard !overflow,
                      nextTotal <= limits.maximumTotalDataBytes else {
                    throw ArchiveError.totalDataTooLarge
                }
                totalDataBytes = nextTotal
            }
        }
    }

    private static func inflateRawDeflate(
        _ input: Data,
        limits: Limits
    ) throws -> Data {
        guard !input.isEmpty else {
            throw ArchiveError.emptyCompressedPayload
        }
        guard input.count <= limits.maximumCompressedBytes,
              input.count <= Int(uInt.max) else {
            throw ArchiveError.compressedPayloadTooLarge
        }

        let ratioProduct: Int
        let (product, overflow) = input.count.multipliedReportingOverflow(
            by: limits.maximumExpansionRatio
        )
        ratioProduct = overflow ? Int.max : product
        let ratioBound = max(
            limits.minimumInflatedAllowanceBytes,
            ratioProduct
        )
        let outputLimit = min(limits.maximumInflatedBytes, ratioBound)

        var stream = z_stream()
        guard inflateInit2_(
            &stream,
            -15,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        ) == Z_OK else {
            throw ArchiveError.invalidCompressedPayload
        }
        defer { inflateEnd(&stream) }

        var output = Data()
        output.reserveCapacity(min(outputLimit, input.count * 2))
        return try input.withUnsafeBytes { rawInput -> Data in
            guard let inputBase = rawInput
                .bindMemory(to: Bytef.self)
                .baseAddress else {
                throw ArchiveError.emptyCompressedPayload
            }
            stream.next_in = UnsafeMutablePointer(mutating: inputBase)
            stream.avail_in = uInt(input.count)

            var chunk = [UInt8](
                repeating: 0,
                count: Self.zlibChunkBytes
            )
            while true {
                let status: Int32 = chunk.withUnsafeMutableBytes { rawOutput in
                    stream.next_out = rawOutput
                        .bindMemory(to: Bytef.self)
                        .baseAddress
                    stream.avail_out = uInt(rawOutput.count)
                    return inflate(&stream, Z_NO_FLUSH)
                }
                let produced = chunk.count - Int(stream.avail_out)
                if produced > 0 {
                    let (newCount, countOverflow) = output.count
                        .addingReportingOverflow(produced)
                    guard !countOverflow, newCount <= outputLimit else {
                        throw ArchiveError.inflatedPayloadTooLarge
                    }
                    output.append(contentsOf: chunk[0..<produced])
                }

                switch status {
                case Z_STREAM_END:
                    guard stream.avail_in == 0 else {
                        throw ArchiveError.invalidCompressedPayload
                    }
                    return output
                case Z_OK:
                    continue
                default:
                    throw ArchiveError.invalidCompressedPayload
                }
            }
        }
    }

    private static func deflateRaw(
        _ input: Data,
        compressionLevel: Int32,
        limits: Limits
    ) throws -> Data {
        let validLevel = compressionLevel == Z_DEFAULT_COMPRESSION
            || (compressionLevel >= Z_NO_COMPRESSION
                && compressionLevel <= Z_BEST_COMPRESSION)
        guard validLevel else { throw ArchiveError.invalidCompressionLevel }
        guard input.count <= limits.maximumInflatedBytes,
              input.count <= Int(uInt.max) else {
            throw ArchiveError.inflatedPayloadTooLarge
        }

        var stream = z_stream()
        guard deflateInit2_(
            &stream,
            compressionLevel,
            Z_DEFLATED,
            -15,
            8,
            Z_DEFAULT_STRATEGY,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        ) == Z_OK else {
            throw ArchiveError.invalidCompressedPayload
        }
        defer { deflateEnd(&stream) }

        var output = Data()
        output.reserveCapacity(min(input.count, limits.maximumCompressedBytes))
        return try input.withUnsafeBytes { rawInput -> Data in
            stream.next_in = UnsafeMutablePointer(
                mutating: rawInput.bindMemory(to: Bytef.self).baseAddress
            )
            stream.avail_in = uInt(input.count)

            var chunk = [UInt8](
                repeating: 0,
                count: Self.zlibChunkBytes
            )
            while true {
                let status: Int32 = chunk.withUnsafeMutableBytes { rawOutput in
                    stream.next_out = rawOutput
                        .bindMemory(to: Bytef.self)
                        .baseAddress
                    stream.avail_out = uInt(rawOutput.count)
                    return deflate(&stream, Z_FINISH)
                }
                let produced = chunk.count - Int(stream.avail_out)
                if produced > 0 {
                    let (newCount, countOverflow) = output.count
                        .addingReportingOverflow(produced)
                    guard !countOverflow,
                          newCount <= limits.maximumCompressedBytes else {
                        throw ArchiveError.compressedPayloadTooLarge
                    }
                    output.append(contentsOf: chunk[0..<produced])
                }

                switch status {
                case Z_STREAM_END:
                    return output
                case Z_OK:
                    continue
                default:
                    throw ArchiveError.invalidCompressedPayload
                }
            }
        }
    }
}

private struct ClipboardPasteboardArchiveCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}
