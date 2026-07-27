import Darwin
import Foundation

/// Programmatic coverage for the minimal reMarkable v6 typed-text reader. The
/// optional real-fixture path never prints either the expected or extracted
/// document text.
func runRemarkablePluginSmokeTest() -> Bool {
    func fail(_ message: String) -> Bool {
        print("FAILED: reMarkable plugin \(message)")
        return false
    }

    func extracts(_ fixture: Data, as expected: String) -> Bool {
        do {
            return try RemarkableSceneTextExtractor.extract(from: fixture) == expected
        } catch {
            return false
        }
    }

    func rejects(
        _ fixture: Data,
        as expected: RemarkableSceneTextExtractionError
    ) -> Bool {
        do {
            _ = try RemarkableSceneTextExtractor.extract(from: fixture)
            return false
        } catch let error as RemarkableSceneTextExtractionError {
            return error == expected
        } catch {
            return false
        }
    }

    let end = RemarkableSmokeID(author: 0, clock: 0)

    let plainText = "Hello，reMarkable。"
    let plainFixture = RemarkableSmokeFixture.file(items: [
        .text(
            id: .init(author: 1, clock: 16),
            left: end,
            right: end,
            plainText
        ),
    ])
    guard extracts(plainFixture, as: plainText) else {
        return fail("plain text")
    }

    // Serialize the runs out of order; their CRDT links, including the
    // paragraph separators, are the source of truth.
    let multiFixture = RemarkableSmokeFixture.file(items: [
        .text(
            id: .init(author: 1, clock: 24),
            left: .init(author: 1, clock: 23),
            right: end,
            "第三段"
        ),
        .text(
            id: .init(author: 1, clock: 16),
            left: end,
            right: .init(author: 1, clock: 20),
            "第一段\n"
        ),
        .text(
            id: .init(author: 1, clock: 20),
            left: .init(author: 1, clock: 19),
            right: .init(author: 1, clock: 24),
            "第二段\n"
        ),
    ])
    guard extracts(multiFixture, as: "第一段\n第二段\n第三段") else {
        return fail("paragraph ordering")
    }

    // "B" is inserted between the implicit character IDs for "A" and "C".
    // This catches implementations that sort only the serialized string runs.
    let extensionFixture = RemarkableSmokeFixture.file(items: [
        .text(
            id: .init(author: 2, clock: 1),
            left: .init(author: 1, clock: 50),
            right: .init(author: 1, clock: 51),
            "B"
        ),
        .text(
            id: .init(author: 1, clock: 50),
            left: end,
            right: end,
            "AC"
        ),
    ])
    guard extracts(extensionFixture, as: "ABC") else {
        return fail("implicit CRDT character IDs")
    }

    // Higher author IDs win concurrent insertion ties, matching rmscene 0.8's
    // deterministic heap ordering.
    let concurrentFixture = RemarkableSmokeFixture.file(items: [
        .text(
            id: .init(author: 1, clock: 2),
            left: .init(author: 1, clock: 1),
            right: end,
            "Z"
        ),
        .text(
            id: .init(author: 1, clock: 3),
            left: .init(author: 1, clock: 1),
            right: .init(author: 1, clock: 2),
            "_"
        ),
        .text(
            id: .init(author: 2, clock: 1),
            left: .init(author: 1, clock: 1),
            right: .init(author: 1, clock: 2),
            "12"
        ),
        .text(
            id: .init(author: 1, clock: 1),
            left: end,
            right: end,
            "A"
        ),
    ])
    guard extracts(concurrentFixture, as: "A12_Z") else {
        return fail("concurrent CRDT ordering")
    }

    let hiddenFixture = RemarkableSmokeFixture.file(items: [
        .format(
            id: .init(author: 2, clock: 1),
            left: .init(author: 1, clock: 13),
            right: .init(author: 1, clock: 11),
            code: 1
        ),
        .tombstone(
            id: .init(author: 1, clock: 12),
            left: .init(author: 1, clock: 10),
            right: .init(author: 1, clock: 11),
            deletedLength: 2
        ),
        .text(
            id: .init(author: 1, clock: 11),
            left: .init(author: 1, clock: 10),
            right: end,
            "Z"
        ),
        .text(
            id: .init(author: 1, clock: 10),
            left: end,
            right: .init(author: 1, clock: 11),
            "A"
        ),
    ])
    guard extracts(hiddenFixture, as: "AZ") else {
        return fail("format and tombstone filtering")
    }

    var unsupportedHeader = plainFixture
    unsupportedHeader[unsupportedHeader.startIndex] = 0
    guard rejects(unsupportedHeader, as: .unsupportedHeader) else {
        return fail("unsupported header boundary")
    }

    var truncated = plainFixture
    truncated.removeLast()
    guard rejects(truncated, as: .truncatedInput) else {
        return fail("truncated block boundary")
    }

    var malformedHeader = plainFixture
    let reservedByte = RemarkableSmokeFixture.header.count + 4
    malformedHeader[reservedByte] = 1
    guard rejects(malformedHeader, as: .malformedStructure) else {
        return fail("reserved block header boundary")
    }

    let invalidUTF8 = RemarkableSmokeFixture.file(items: [
        .rawText(
            id: .init(author: 1, clock: 1),
            left: end,
            right: end,
            bytes: [0xC3, 0x28]
        ),
    ])
    guard rejects(invalidUTF8, as: .invalidUTF8) else {
        return fail("UTF-8 boundary")
    }

    let nulText = RemarkableSmokeFixture.file(items: [
        .rawText(
            id: .init(author: 1, clock: 1),
            left: end,
            right: end,
            bytes: [0x41, 0x00, 0x42]
        ),
    ])
    guard rejects(nulText, as: .nulCharacter) else {
        return fail("NUL boundary")
    }

    let cyclic = RemarkableSmokeFixture.file(items: [
        .text(
            id: .init(author: 1, clock: 1),
            left: .init(author: 1, clock: 2),
            right: end,
            "A"
        ),
        .text(
            id: .init(author: 1, clock: 2),
            left: .init(author: 1, clock: 1),
            right: end,
            "B"
        ),
    ])
    guard rejects(cyclic, as: .cyclicCRDT) else {
        return fail("cyclic CRDT boundary")
    }

    let missingRoot = RemarkableSmokeFixture.header
        + RemarkableSmokeFixture.topLevelBlock(type: 0x7F, payload: Data())
    guard rejects(missingRoot, as: .missingRootText) else {
        return fail("missing root-text boundary")
    }

    let maximumText = String(
        repeating: "x",
        count: RemarkableSceneTextExtractor.maximumOutputBytes
    )
    let maximumOutputFixture = RemarkableSmokeFixture.file(items: [
        .text(
            id: .init(author: 1, clock: 1),
            left: end,
            right: end,
            maximumText
        ),
    ])
    guard extracts(maximumOutputFixture, as: maximumText) else {
        return fail("maximum output acceptance")
    }

    let oversizedOutput = RemarkableSmokeFixture.file(items: [
        .rawText(
            id: .init(author: 1, clock: 1),
            left: end,
            right: end,
            bytes: [UInt8](
                repeating: 0x78,
                count: RemarkableSceneTextExtractor.maximumOutputBytes + 1
            )
        ),
    ])
    guard rejects(oversizedOutput, as: .outputTooLarge) else {
        return fail("maximum output rejection")
    }

    let paddingSize = RemarkableSceneTextExtractor.maximumInputBytes
        - plainFixture.count
        - 8
    guard paddingSize >= 0 else {
        return fail("maximum input fixture")
    }
    var maximumInput = plainFixture
    maximumInput.append(RemarkableSmokeFixture.topLevelBlock(
        type: 0x7F,
        payload: Data(repeating: 0, count: paddingSize)
    ))
    guard maximumInput.count == RemarkableSceneTextExtractor.maximumInputBytes,
          extracts(maximumInput, as: plainText) else {
        return fail("maximum input acceptance")
    }

    var oversizedInput = maximumInput
    oversizedInput.append(0)
    guard rejects(oversizedInput, as: .inputTooLarge) else {
        return fail("maximum input rejection")
    }

    let environment = ProcessInfo.processInfo.environment
    let fixturePath = environment["RIMEBUFFER_REMARKABLE_FIXTURE"]
    let expectedText = environment["RIMEBUFFER_REMARKABLE_EXPECTED"]
    switch (fixturePath, expectedText) {
    case (nil, nil):
        break
    case let (path?, expected?):
        guard !path.isEmpty else {
            return fail("real fixture configuration")
        }
        do {
            let fixtureURL = URL(fileURLWithPath: path)
            if let fileSize = try fixtureURL.resourceValues(
                forKeys: [.fileSizeKey]
            ).fileSize,
               fileSize > RemarkableSceneTextExtractor.maximumInputBytes {
                return fail("real fixture input boundary")
            }
            let fixture = try Data(contentsOf: fixtureURL, options: [.mappedIfSafe])
            guard try RemarkableSceneTextExtractor.extract(from: fixture) == expected else {
                return fail("real fixture mismatch")
            }
        } catch {
            return fail("real fixture read or parse")
        }
    default:
        return fail("real fixture environment pair")
    }

    if let languageResolverFailure =
        remarkableVisionLanguageResolverSmoke() {
        return fail(languageResolverFailure)
    }

    if let transportFailure = remarkableTransportSmoke() {
        return fail(transportFailure)
    }

    if let workspaceFailure = remarkableWorkspaceSmoke(
        fixture: plainFixture,
        expectedText: plainText
    ) {
        return fail(workspaceFailure)
    }

    print("reMarkable plugin smoke OK")
    return true
}

private func remarkableVisionLanguageResolverSmoke() -> String? {
    var successfulProviderCalls = 0
    let successfulResolver = RemarkableVisionLanguageResolver {
        successfulProviderCalls += 1
        return ["en-US", "zh-Hant", "zh-Hans"]
    }
    do {
        let simplified = try successfulResolver.resolve(.simplifiedChinese)
        let automatic = try successfulResolver.resolve(.automatic)
        guard successfulProviderCalls == 1,
              simplified == RemarkableVisionLanguageConfiguration(
                  recognitionLanguages: ["zh-Hans", "en-US"],
                  automaticallyDetectsLanguage: false
              ),
              automatic == RemarkableVisionLanguageConfiguration(
                  recognitionLanguages: ["zh-Hans", "zh-Hant", "en-US"],
                  automaticallyDetectsLanguage: true
              ) else {
            return "Vision language resolution and successful cache"
        }
    } catch {
        return "Vision language resolution setup"
    }

    var recoveryProviderCalls = 0
    let recoveryResolver = RemarkableVisionLanguageResolver {
        recoveryProviderCalls += 1
        if recoveryProviderCalls == 1 {
            throw RemarkableLocalOCRError.renderingFailed
        }
        return ["zh-Hans", "en-US"]
    }
    do {
        _ = try recoveryResolver.resolve(.simplifiedChinese)
        return "Vision language provider failure accepted"
    } catch RemarkableLocalOCRError.renderingFailed {
        // Expected. A failed provider call must not populate the cache.
    } catch {
        return "Vision language provider failure classification"
    }
    do {
        let recovered = try recoveryResolver.resolve(.simplifiedChinese)
        guard recoveryProviderCalls == 2,
              recovered == RemarkableVisionLanguageConfiguration(
                  recognitionLanguages: ["zh-Hans", "en-US"],
                  automaticallyDetectsLanguage: false
              ) else {
            return "Vision language provider recovery"
        }
    } catch {
        return "Vision language provider retry"
    }

    var disjointProviderCalls = 0
    let disjointResolver = RemarkableVisionLanguageResolver {
        disjointProviderCalls += 1
        return ["fr-FR"]
    }
    do {
        _ = try disjointResolver.resolve(.simplifiedChinese)
        return "Vision unsupported language intersection accepted"
    } catch RemarkableLocalOCRError.recognitionFailed {
        guard disjointProviderCalls == 1 else {
            return "Vision unsupported language provider count"
        }
    } catch {
        return "Vision unsupported language classification"
    }

    return nil
}

private struct RemarkableSmokeID {
    let author: UInt8
    let clock: UInt64
}

private struct RemarkableSmokeItem {
    let id: RemarkableSmokeID
    let left: RemarkableSmokeID
    let right: RemarkableSmokeID
    let deletedLength: UInt32
    let textBytes: [UInt8]?
    let formatCode: UInt32?

    static func text(
        id: RemarkableSmokeID,
        left: RemarkableSmokeID,
        right: RemarkableSmokeID,
        _ text: String
    ) -> RemarkableSmokeItem {
        rawText(
            id: id,
            left: left,
            right: right,
            bytes: Array(text.utf8)
        )
    }

    static func rawText(
        id: RemarkableSmokeID,
        left: RemarkableSmokeID,
        right: RemarkableSmokeID,
        bytes: [UInt8]
    ) -> RemarkableSmokeItem {
        RemarkableSmokeItem(
            id: id,
            left: left,
            right: right,
            deletedLength: 0,
            textBytes: bytes,
            formatCode: nil
        )
    }

    static func format(
        id: RemarkableSmokeID,
        left: RemarkableSmokeID,
        right: RemarkableSmokeID,
        code: UInt32
    ) -> RemarkableSmokeItem {
        RemarkableSmokeItem(
            id: id,
            left: left,
            right: right,
            deletedLength: 0,
            textBytes: [],
            formatCode: code
        )
    }

    static func tombstone(
        id: RemarkableSmokeID,
        left: RemarkableSmokeID,
        right: RemarkableSmokeID,
        deletedLength: UInt32
    ) -> RemarkableSmokeItem {
        RemarkableSmokeItem(
            id: id,
            left: left,
            right: right,
            deletedLength: deletedLength,
            textBytes: nil,
            formatCode: nil
        )
    }
}

private enum RemarkableSmokeFixture {
    static let header = Data(
        "reMarkable .lines file, version=6          ".utf8
    )

    static func file(items: [RemarkableSmokeItem]) -> Data {
        var itemList = Data()
        appendVarUInt(UInt64(items.count), to: &itemList)
        for item in items {
            itemList.append(textItem(item))
        }

        let itemSection = subblock(
            index: 1,
            payload: subblock(index: 1, payload: itemList)
        )

        var emptyStyleList = Data()
        appendVarUInt(0, to: &emptyStyleList)
        let styleSection = subblock(
            index: 2,
            payload: subblock(index: 1, payload: emptyStyleList)
        )

        var textValue = Data()
        textValue.append(itemSection)
        textValue.append(styleSection)

        var rootPayload = Data()
        appendID(.init(author: 0, clock: 0), index: 1, to: &rootPayload)
        rootPayload.append(subblock(index: 2, payload: textValue))
        rootPayload.append(subblock(
            index: 3,
            payload: Data(repeating: 0, count: 16)
        ))
        appendTag(index: 4, type: 0x04, to: &rootPayload)
        appendUInt32(0, to: &rootPayload)

        return header + topLevelBlock(type: 0x07, payload: rootPayload)
    }

    static func topLevelBlock(type: UInt8, payload: Data) -> Data {
        precondition(payload.count <= Int(UInt32.max))
        var result = Data()
        appendUInt32(UInt32(payload.count), to: &result)
        result.append(0)
        result.append(1)
        result.append(1)
        result.append(type)
        result.append(payload)
        return result
    }

    private static func textItem(_ item: RemarkableSmokeItem) -> Data {
        var payload = Data()
        appendID(item.id, index: 2, to: &payload)
        appendID(item.left, index: 3, to: &payload)
        appendID(item.right, index: 4, to: &payload)
        appendTag(index: 5, type: 0x04, to: &payload)
        appendUInt32(item.deletedLength, to: &payload)

        if item.textBytes != nil || item.formatCode != nil {
            let bytes = item.textBytes ?? []
            var value = Data()
            appendVarUInt(UInt64(bytes.count), to: &value)
            value.append(1)
            value.append(contentsOf: bytes)
            if let formatCode = item.formatCode {
                appendTag(index: 2, type: 0x04, to: &value)
                appendUInt32(formatCode, to: &value)
            }
            payload.append(subblock(index: 6, payload: value))
        }

        return subblock(index: 0, payload: payload)
    }

    private static func subblock(index: UInt64, payload: Data) -> Data {
        precondition(payload.count <= Int(UInt32.max))
        var result = Data()
        appendTag(index: index, type: 0x0C, to: &result)
        appendUInt32(UInt32(payload.count), to: &result)
        result.append(payload)
        return result
    }

    private static func appendID(
        _ id: RemarkableSmokeID,
        index: UInt64,
        to data: inout Data
    ) {
        appendTag(index: index, type: 0x0F, to: &data)
        data.append(id.author)
        appendVarUInt(id.clock, to: &data)
    }

    private static func appendTag(
        index: UInt64,
        type: UInt64,
        to data: inout Data
    ) {
        appendVarUInt((index << 4) | type, to: &data)
    }

    private static func appendUInt32(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(truncatingIfNeeded: value))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
        data.append(UInt8(truncatingIfNeeded: value >> 16))
        data.append(UInt8(truncatingIfNeeded: value >> 24))
    }

    private static func appendVarUInt(_ original: UInt64, to data: inout Data) {
        var value = original
        repeat {
            var byte = UInt8(value & 0x7F)
            value >>= 7
            if value != 0 {
                byte |= 0x80
            }
            data.append(byte)
        } while value != 0
    }
}

private final class RemarkableSmokeCancellation: AITextCancellable {
    private let lock = NSLock()
    private var cancelled = false

    var wasCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

private final class RemarkableSmokeRunner: AITextCLIProcessRunning {
    private struct Invocation {
        let spec: AITextCLIProcessSpec
        let completion: (AITextCLIProcessResult) -> Void
        let cancellation: RemarkableSmokeCancellation
    }

    private let lock = NSLock()
    private var invocations: [Invocation] = []

    var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return invocations.count
    }

    @discardableResult
    func run(_ spec: AITextCLIProcessSpec,
             onStandardOutput: @escaping (Data) -> Void,
             completion: @escaping (AITextCLIProcessResult) -> Void)
        -> any AITextCancellable {
        let cancellation = RemarkableSmokeCancellation()
        lock.lock()
        invocations.append(Invocation(
            spec: spec,
            completion: completion,
            cancellation: cancellation
        ))
        lock.unlock()
        return cancellation
    }

    func spec(at index: Int) -> AITextCLIProcessSpec? {
        lock.lock()
        defer { lock.unlock() }
        guard invocations.indices.contains(index) else { return nil }
        return invocations[index].spec
    }

    func cancellation(at index: Int) -> RemarkableSmokeCancellation? {
        lock.lock()
        defer { lock.unlock() }
        guard invocations.indices.contains(index) else { return nil }
        return invocations[index].cancellation
    }

    func succeed(request index: Int, output: Data) -> Bool {
        complete(
            request: index,
            terminationStatus: 0,
            standardOutput: output
        )
    }

    func complete(
        request index: Int,
        terminationStatus: Int32,
        standardOutput: Data = Data(),
        standardError: Data = Data()
    ) -> Bool {
        let callback: ((AITextCLIProcessResult) -> Void)?
        lock.lock()
        callback = invocations.indices.contains(index)
            ? invocations[index].completion
            : nil
        lock.unlock()
        guard let callback else { return false }
        callback(AITextCLIProcessResult(
            terminationStatus: terminationStatus,
            standardOutput: standardOutput,
            standardError: standardError,
            timedOut: false,
            cancelled: false,
            outputTooLarge: false
        ))
        return true
    }
}

private final class RemarkableSmokeResultBox<Value> {
    private let lock = NSLock()
    private var storedValue: Value?

    var value: Value? {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }

    func store(_ value: Value) {
        lock.lock()
        storedValue = value
        lock.unlock()
    }
}

private final class RemarkableSmokePuller: RemarkablePagePulling {
    private struct Invocation {
        let target: RemarkableSSHTarget
        let completion: (Result<RemarkablePageSnapshot,
                                RemarkablePullError>) -> Void
        let cancellation: RemarkableSmokeCancellation
    }

    private let lock = NSLock()
    private var invocations: [Invocation] = []

    var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return invocations.count
    }

    @discardableResult
    func pullLatestPage(
        from target: RemarkableSSHTarget,
        completion: @escaping (Result<RemarkablePageSnapshot,
                                     RemarkablePullError>) -> Void
    ) -> any AITextCancellable {
        let cancellation = RemarkableSmokeCancellation()
        lock.lock()
        invocations.append(Invocation(
            target: target,
            completion: completion,
            cancellation: cancellation
        ))
        lock.unlock()
        return cancellation
    }

    func target(at index: Int) -> RemarkableSSHTarget? {
        lock.lock()
        defer { lock.unlock() }
        guard invocations.indices.contains(index) else { return nil }
        return invocations[index].target
    }

    func cancellation(at index: Int) -> RemarkableSmokeCancellation? {
        lock.lock()
        defer { lock.unlock() }
        guard invocations.indices.contains(index) else { return nil }
        return invocations[index].cancellation
    }

    func finish(
        request index: Int,
        with result: Result<RemarkablePageSnapshot, RemarkablePullError>
    ) -> Bool {
        let callback: ((Result<RemarkablePageSnapshot,
                               RemarkablePullError>) -> Void)?
        lock.lock()
        callback = invocations.indices.contains(index)
            ? invocations[index].completion
            : nil
        lock.unlock()
        guard let callback else { return false }
        callback(result)
        return true
    }
}

private final class RemarkableSmokeTextRecognizer:
    RemarkablePDFTextRecognizing {
    struct Request {
        let pdfData: Data
        let pageIndex: Int
        let expectedPageCount: Int
        let language: RemarkableOCRLanguageMode
    }

    private struct Invocation {
        let request: Request
        let completion: (
            Result<RemarkableOCRResult, RemarkableLocalOCRError>
        ) -> Void
        let cancellation: RemarkableSmokeCancellation
    }

    private let lock = NSLock()
    private var invocations: [Invocation] = []

    var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return invocations.count
    }

    func recognizeText(
        in pdfData: Data,
        pageIndex: Int,
        expectedPageCount: Int,
        language: RemarkableOCRLanguageMode,
        completion: @escaping (
            Result<RemarkableOCRResult, RemarkableLocalOCRError>
        ) -> Void
    ) -> any AITextCancellable {
        let cancellation = RemarkableSmokeCancellation()
        let invocation = Invocation(
            request: Request(
                pdfData: pdfData,
                pageIndex: pageIndex,
                expectedPageCount: expectedPageCount,
                language: language
            ),
            completion: completion,
            cancellation: cancellation
        )
        lock.lock()
        invocations.append(invocation)
        lock.unlock()
        return cancellation
    }

    func request(at index: Int) -> Request? {
        lock.lock()
        defer { lock.unlock() }
        guard invocations.indices.contains(index) else { return nil }
        return invocations[index].request
    }

    func cancellation(at index: Int) -> RemarkableSmokeCancellation? {
        lock.lock()
        defer { lock.unlock() }
        guard invocations.indices.contains(index) else { return nil }
        return invocations[index].cancellation
    }

    func finish(
        request index: Int,
        with result: Result<RemarkableOCRResult, RemarkableLocalOCRError>
    ) -> Bool {
        let callback: ((
            Result<RemarkableOCRResult, RemarkableLocalOCRError>
        ) -> Void)?
        lock.lock()
        callback = invocations.indices.contains(index)
            ? invocations[index].completion
            : nil
        lock.unlock()
        guard let callback else { return false }
        callback(result)
        return true
    }
}

private func remarkableSmokeWaitUntil(
    timeout: TimeInterval = 1,
    _ predicate: () -> Bool
) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
        if predicate() { return true }
        _ = RunLoop.main.run(
            mode: .default,
            before: Date().addingTimeInterval(0.005)
        )
    } while Date() < deadline
    return predicate()
}

private func remarkableSmokePumpMainRunLoop(for interval: TimeInterval) {
    let deadline = Date().addingTimeInterval(interval)
    repeat {
        _ = RunLoop.main.run(
            mode: .default,
            before: min(deadline, Date().addingTimeInterval(0.005))
        )
    } while Date() < deadline
}

private func remarkableTransportSmoke() -> String? {
    let defaultsSuite = "RimeBuffer.RemarkableSmoke.Target.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: defaultsSuite) else {
        return "SSH target defaults setup"
    }
    defer { defaults.removePersistentDomain(forName: defaultsSuite) }

    guard (try? RemarkableSSHTarget.configured(in: defaults))?.destination
        == RemarkableSSHTarget.defaultDestination else {
        return "SSH target default"
    }
    defaults.set("root@remarkable-usb", forKey: RemarkableSSHTarget.defaultsKey)
    guard (try? RemarkableSSHTarget.configured(in: defaults))?.destination
        == "root@remarkable-usb" else {
        return "SSH target configured alias"
    }

    let credentialRoot = URL(
        fileURLWithPath: NSTemporaryDirectory(),
        isDirectory: true
    ).appendingPathComponent(
        "rimebuffer-remarkable-credentials-\(UUID().uuidString)",
        isDirectory: true
    )
    do {
        try FileManager.default.createDirectory(
            at: credentialRoot,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o755]
        )
    } catch {
        return "SSH credential root setup"
    }
    let credentialStore = RemarkableCredentialStore(
        rootDirectory: credentialRoot
    )
    defer {
        try? FileManager.default.removeItem(at: credentialRoot)
    }
    let passwordCanary = "smoke-password-\(UUID().uuidString)"
    let savedConfiguration = RemarkableSSHConfiguration(
        host: "remarkable-usb",
        username: "root",
        password: passwordCanary
    )
    var dumpedConfiguration = ""
    dump(savedConfiguration, to: &dumpedConfiguration)
    guard !String(describing: savedConfiguration).contains(passwordCanary),
          !String(reflecting: savedConfiguration).contains(passwordCanary),
          !dumpedConfiguration.contains(passwordCanary) else {
        return "SSH credential description redaction"
    }
    do {
        try credentialStore.save(savedConfiguration)
    } catch {
        return "SSH credential save"
    }
    guard (try? credentialStore.load()) == savedConfiguration,
          let savedTarget = try? credentialStore.configuredTarget(
              fallingBackTo: defaults
          ),
          savedTarget.destination == "root@remarkable-usb",
          savedTarget.username == "root",
          savedTarget.host == "remarkable-usb",
          savedTarget.passwordCredentialURL
            == credentialStore.configurationURL.standardizedFileURL else {
        return "SSH credential load"
    }

    var sharedRootInfo = stat()
    guard lstat(credentialStore.rootDirectory.path, &sharedRootInfo) == 0,
          (sharedRootInfo.st_mode & S_IFMT) == S_IFDIR,
          (sharedRootInfo.st_mode & 0o777) == 0o755 else {
        return "SSH credential shared root permissions"
    }
    for privateDirectory in [
        credentialStore.configurationDirectoryURL.deletingLastPathComponent(),
        credentialStore.configurationDirectoryURL,
    ] {
        var info = stat()
        guard lstat(privateDirectory.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR,
              (info.st_mode & 0o777) == 0o700 else {
            return "SSH credential directory permissions"
        }
    }
    var credentialInfo = stat()
    guard lstat(credentialStore.configurationURL.path, &credentialInfo) == 0,
          (credentialInfo.st_mode & S_IFMT) == S_IFREG,
          (credentialInfo.st_mode & 0o777) == 0o600 else {
        return "SSH credential file permissions"
    }

    let configurationSchema = PluginConfigurationSchema(
        pluginID: BuiltInPluginID.remarkable,
        title: "Remarkable smoke",
        fields: [
            .text(
                id: RemarkablePluginConfigurationFieldID.host,
                title: "Host"
            ),
            .text(
                id: RemarkablePluginConfigurationFieldID.username,
                title: "Username"
            ),
            .choice(
                id: RemarkablePluginConfigurationFieldID.ocrLanguage,
                title: "Language",
                options: RemarkableOCRLanguageMode.allCases.map {
                    PluginConfigurationChoice(
                        value: $0.rawValue,
                        title: $0.displayName
                    )
                },
                defaultValue: RemarkableOCRLanguageMode.defaultMode.rawValue
            ),
            .secureText(
                id: RemarkablePluginConfigurationFieldID.password,
                title: "Password"
            ),
        ]
    )
    let configurationStore = RemarkablePluginConfigurationStore(
        credentialStore: credentialStore,
        defaults: defaults
    )
    guard RemarkableOCRLanguageMode.defaultMode == .simplifiedChinese,
          RemarkableOCRLanguageMode.configured(in: defaults)
            == .simplifiedChinese,
          (try? configurationStore.load(
              schema: configurationSchema
          ))??.string(RemarkablePluginConfigurationFieldID.ocrLanguage)
            == RemarkableOCRLanguageMode.simplifiedChinese.rawValue else {
        return "Remarkable OCR language simplified Chinese default"
    }
    let simplifiedSnapshot = PluginConfigurationSnapshot(values: [
        RemarkablePluginConfigurationFieldID.host:
            .string(savedConfiguration.host),
        RemarkablePluginConfigurationFieldID.username:
            .string(savedConfiguration.username),
        RemarkablePluginConfigurationFieldID.ocrLanguage:
            .string(RemarkableOCRLanguageMode.simplifiedChinese.rawValue),
        RemarkablePluginConfigurationFieldID.password:
            .string(savedConfiguration.password),
    ])
    var automaticSnapshot = simplifiedSnapshot
    automaticSnapshot[
        RemarkablePluginConfigurationFieldID.ocrLanguage
    ] = .string(RemarkableOCRLanguageMode.automatic.rawValue)
    do {
        try configurationStore.save(
            automaticSnapshot,
            schema: configurationSchema
        )
    } catch {
        return "Remarkable explicit automatic language save"
    }
    guard RemarkableOCRLanguageMode.configured(in: defaults) == .automatic,
          (try? configurationStore.load(
              schema: configurationSchema
          ))??.string(RemarkablePluginConfigurationFieldID.ocrLanguage)
            == RemarkableOCRLanguageMode.automatic.rawValue else {
        return "Remarkable explicit automatic language load"
    }
    do {
        try configurationStore.save(
            simplifiedSnapshot,
            schema: configurationSchema
        )
    } catch {
        return "Remarkable OCR language save"
    }
    guard RemarkableOCRLanguageMode.configured(in: defaults)
            == .simplifiedChinese,
          (try? configurationStore.load(
              schema: configurationSchema
          ))??.string(RemarkablePluginConfigurationFieldID.ocrLanguage)
            == RemarkableOCRLanguageMode.simplifiedChinese.rawValue else {
        return "Remarkable OCR language load"
    }
    var invalidLanguageSnapshot = simplifiedSnapshot
    invalidLanguageSnapshot[
        RemarkablePluginConfigurationFieldID.ocrLanguage
    ] = .string("not-a-language")
    do {
        try configurationStore.save(
            invalidLanguageSnapshot,
            schema: configurationSchema
        )
        return "Remarkable OCR language invalid value accepted"
    } catch PluginConfigurationError.corruptDocument {
        // Expected.
    } catch {
        return "Remarkable OCR language invalid value classification"
    }
    guard RemarkableOCRLanguageMode.configured(in: defaults)
        == .simplifiedChinese else {
        return "Remarkable OCR language invalid save mutation"
    }

    let emptyCredentialRoot = credentialRoot.deletingLastPathComponent()
        .appendingPathComponent(
            "rimebuffer-remarkable-empty-credentials-\(UUID().uuidString)",
            isDirectory: true
        )
    do {
        try FileManager.default.createDirectory(
            at: emptyCredentialRoot,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o755]
        )
    } catch {
        return "Remarkable empty credential root setup"
    }
    defer { try? FileManager.default.removeItem(at: emptyCredentialRoot) }
    let emptyCredentialStore = RemarkableCredentialStore(
        rootDirectory: emptyCredentialRoot
    )
    guard !FileManager.default.fileExists(
        atPath: emptyCredentialStore.configurationURL.path
    ) else {
        return "Remarkable empty credential fixture"
    }
    var emptyDeleteNotificationCount = 0
    let emptyDeleteObserver = NotificationCenter.default.addObserver(
        forName: .remarkableConfigurationDidChange,
        object: emptyCredentialStore,
        queue: nil
    ) { _ in
        emptyDeleteNotificationCount += 1
    }
    defer { NotificationCenter.default.removeObserver(emptyDeleteObserver) }
    do {
        try emptyCredentialStore.delete()
    } catch {
        return "Remarkable missing credential delete"
    }
    guard emptyDeleteNotificationCount == 1 else {
        return "Remarkable missing credential delete notification"
    }

    let resetDefaultsSuite =
        "RimeBuffer.RemarkableSmoke.EmptyReset.\(UUID().uuidString)"
    guard let resetDefaults = UserDefaults(suiteName: resetDefaultsSuite) else {
        return "Remarkable empty credential reset defaults setup"
    }
    defer {
        resetDefaults.removePersistentDomain(forName: resetDefaultsSuite)
    }
    resetDefaults.set(
        "root@legacy-remarkable",
        forKey: RemarkableSSHTarget.defaultsKey
    )
    resetDefaults.set(
        RemarkableOCRLanguageMode.traditionalChinese.rawValue,
        forKey: RemarkableOCRLanguageMode.defaultsKey
    )
    let emptyConfigurationStore = RemarkablePluginConfigurationStore(
        credentialStore: emptyCredentialStore,
        defaults: resetDefaults
    )
    do {
        try emptyConfigurationStore.delete(schema: configurationSchema)
    } catch {
        return "Remarkable missing credential adapter reset"
    }
    guard emptyDeleteNotificationCount == 2,
          resetDefaults.object(
              forKey: RemarkableSSHTarget.defaultsKey
          ) == nil,
          resetDefaults.object(
              forKey: RemarkableOCRLanguageMode.defaultsKey
          ) == nil,
          RemarkableOCRLanguageMode.configured(in: resetDefaults)
            == .simplifiedChinese,
          !FileManager.default.fileExists(
              atPath: emptyCredentialStore.configurationURL.path
          ) else {
        return "Remarkable missing credential adapter reset cleanup"
    }
    resetDefaults.set(
        RemarkableOCRLanguageMode.english.rawValue,
        forKey: RemarkableOCRLanguageMode.defaultsKey
    )
    guard let languageOnlySnapshot = try? emptyConfigurationStore.load(
              schema: configurationSchema
          ),
          languageOnlySnapshot.string(
              RemarkablePluginConfigurationFieldID.host
          ) == "10.11.99.1",
          languageOnlySnapshot.string(
              RemarkablePluginConfigurationFieldID.username
          ) == "root",
          languageOnlySnapshot.string(
              RemarkablePluginConfigurationFieldID.ocrLanguage
          ) == RemarkableOCRLanguageMode.english.rawValue else {
        return "Remarkable workbench-only language settings load"
    }
    resetDefaults.removeObject(
        forKey: RemarkableOCRLanguageMode.defaultsKey
    )

    let orphanURL = credentialStore.configurationDirectoryURL
        .appendingPathComponent(
            ".credentials.\(UUID().uuidString).tmp",
            isDirectory: false
        )
    guard FileManager.default.createFile(
              atPath: orphanURL.path,
              contents: Data(passwordCanary.utf8),
              attributes: [.posixPermissions: 0o600]
          ),
          (try? credentialStore.load()) == savedConfiguration,
          !FileManager.default.fileExists(atPath: orphanURL.path) else {
        return "SSH orphan credential cleanup"
    }

    let askPassPipe = Pipe()
    let askPassEnvironment = [
        RemarkableSSHAskPassHandler.requestEnvironmentKey: "1",
        RemarkableSSHAskPassHandler.credentialPathEnvironmentKey:
            credentialStore.configurationURL.path,
        RemarkableSSHAskPassHandler.destinationEnvironmentKey:
            "root@remarkable-usb",
    ]
    guard RemarkableSSHAskPassHandler.handleIfRequested(
        environment: askPassEnvironment,
        arguments: [
            "/tmp/RimeBuffer-smoke-executable",
            "root@remarkable-usb's password:",
        ],
        expectedCredentialURL: credentialStore.configurationURL,
        parentSSHCheck: { true },
        output: askPassPipe.fileHandleForWriting
    ) == 0 else {
        return "SSH askpass response"
    }
    try? askPassPipe.fileHandleForWriting.close()
    guard String(
        data: askPassPipe.fileHandleForReading.readDataToEndOfFile(),
        encoding: .utf8
    ) == passwordCanary + "\n",
          RemarkableSSHAskPassHandler.handleIfRequested(
              environment: [:],
              arguments: [],
              expectedCredentialURL: credentialStore.configurationURL,
              parentSSHCheck: { true },
              output: .standardOutput
          ) == nil else {
        return "SSH askpass value"
    }

    let rejectedAskPassOutput = Pipe()
    let acceptedPromptArguments = [
        "/tmp/RimeBuffer-smoke-executable",
        "root@remarkable-usb's password:",
    ]
    let symlinkRoot = credentialRoot.deletingLastPathComponent()
        .appendingPathComponent(
            "rimebuffer-remarkable-symlink-\(UUID().uuidString)",
            isDirectory: true
        )
    let symlinkConfigRoot = symlinkRoot.appendingPathComponent(
        "plugin-config",
        isDirectory: true
    )
    let symlinkCredentialURL = symlinkConfigRoot
        .appendingPathComponent("builtin.remarkable", isDirectory: true)
        .appendingPathComponent("credentials.json", isDirectory: false)
    do {
        try FileManager.default.createDirectory(
            at: symlinkRoot,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.createSymbolicLink(
            at: symlinkConfigRoot,
            withDestinationURL:
                credentialStore.configurationDirectoryURL
                    .deletingLastPathComponent()
        )
    } catch {
        return "SSH askpass symlink fixture"
    }
    defer { try? FileManager.default.removeItem(at: symlinkRoot) }
    var symlinkAskPassEnvironment = askPassEnvironment
    symlinkAskPassEnvironment[
        RemarkableSSHAskPassHandler.credentialPathEnvironmentKey
    ] = symlinkCredentialURL.path
    guard RemarkableSSHAskPassHandler.handleIfRequested(
              environment: askPassEnvironment,
              arguments: [
                  "/tmp/RimeBuffer-smoke-executable",
                  "Enter passphrase for key:",
              ],
              expectedCredentialURL: credentialStore.configurationURL,
              parentSSHCheck: { true },
              output: rejectedAskPassOutput.fileHandleForWriting
          ) == 1,
          RemarkableSSHAskPassHandler.handleIfRequested(
              environment: askPassEnvironment,
              arguments: acceptedPromptArguments,
              expectedCredentialURL: credentialStore.configurationURL,
              parentSSHCheck: { false },
              output: rejectedAskPassOutput.fileHandleForWriting
          ) == 1,
          RemarkableSSHAskPassHandler.handleIfRequested(
              environment: askPassEnvironment,
              arguments: acceptedPromptArguments,
              expectedCredentialURL: credentialRoot.appendingPathComponent(
                  "other-credentials.json",
                  isDirectory: false
              ),
              parentSSHCheck: { true },
              output: rejectedAskPassOutput.fileHandleForWriting
          ) == 1,
          RemarkableSSHAskPassHandler.handleIfRequested(
              environment: symlinkAskPassEnvironment,
              arguments: acceptedPromptArguments,
              expectedCredentialURL: symlinkCredentialURL,
              parentSSHCheck: { true },
              output: rejectedAskPassOutput.fileHandleForWriting
          ) == 1 else {
        return "SSH askpass trust gates"
    }
    try? rejectedAskPassOutput.fileHandleForWriting.close()
    guard rejectedAskPassOutput.fileHandleForReading
        .readDataToEndOfFile().isEmpty else {
        return "SSH askpass rejection output"
    }

    for invalid in [
        "",
        "-oProxyCommand=bad",
        " root@10.11.99.1",
        "root@10.11.99.1 ",
        "root@@10.11.99.1",
        "root@host;command",
        "root@host/name",
        "root@host..name",
        "@10.11.99.1",
    ] {
        if (try? RemarkableSSHTarget(validating: invalid)) != nil {
            return "SSH target rejection"
        }
    }
    for invalidUsername in ["", "-root", "root name", "root@admin"] {
        if (try? RemarkableSSHTarget(
            username: invalidUsername,
            host: "remarkable-usb"
        )) != nil {
            return "SSH username rejection"
        }
    }
    for invalidHost in ["", "-host", "host/name", "host..name", "host "] {
        if (try? RemarkableSSHTarget(
            username: "root",
            host: invalidHost
        )) != nil {
            return "SSH host rejection"
        }
    }

    let destination = "root@remarkable-usb"
    guard let target = try? RemarkableSSHTarget(validating: destination) else {
        return "SSH target acceptance"
    }
    let documentID = "11111111-1111-1111-1111-111111111111"
    let otherPageID = "77777777-7777-7777-7777-777777777777"
    let pageID = "22222222-2222-2222-2222-222222222222"
    let pageIndex = 1
    let pageCount = 2
    let opaquePageBytes = Data([0x72, 0x4D, 0x36, 0x00])
    let validPDFBytes = Data("%PDF-1.7 smoke\n%%EOF\n".utf8)
    let runner = RemarkableSmokeRunner()
    let resultBox = RemarkableSmokeResultBox<
        Result<RemarkablePageSnapshot, RemarkablePullError>
    >()
    let puller = RemarkableSSHPagePuller(
        runner: runner,
        processEnvironment: [
            "HOME": "/tmp/remarkable-smoke-home",
            "SSH_AUTH_SOCK": "/tmp/remarkable-smoke-agent",
            "LANG": "en_US.UTF-8",
            "PATH": "/usr/bin:/bin",
            "SECRET_SHOULD_NOT_PASS": "private",
        ],
        pdfValidator: {
            $0 == validPDFBytes && $1 == pageIndex && $2 == pageCount
        }
    )
    let transportTask = puller.pullLatestPage(from: target) {
        resultBox.store($0)
    }

    guard remarkableSmokeWaitUntil({ runner.requestCount == 1 }),
          let locatorSpec = runner.spec(at: 0) else {
        transportTask.cancel()
        return "SSH locator launch"
    }
    let requiredOptions = [
        "BatchMode=yes",
        "StrictHostKeyChecking=yes",
        "ConnectTimeout=5",
        "ConnectionAttempts=1",
        "ClearAllForwardings=yes",
        "PermitLocalCommand=no",
    ]
    guard locatorSpec.executableURL.path == "/usr/bin/ssh",
          locatorSpec.arguments.first == "-T",
          requiredOptions.allSatisfy(locatorSpec.arguments.contains),
          locatorSpec.arguments.dropLast(1).last == destination,
          locatorSpec.arguments.dropLast(2).last == "--",
          locatorSpec.arguments.last?.contains("*.metadata") == true,
          locatorSpec.standardInput.isEmpty,
          locatorSpec.currentDirectoryURL.path == "/",
          locatorSpec.environment == [
              "HOME": "/tmp/remarkable-smoke-home",
              "SSH_AUTH_SOCK": "/tmp/remarkable-smoke-agent",
              "LANG": "en_US.UTF-8",
              "PATH": "/usr/bin:/bin",
          ],
          locatorSpec.timeout > 0,
          locatorSpec.timeout <= 60,
          locatorSpec.maximumOutputBytes == 8 * 1_024,
          locatorSpec.maximumStandardErrorBytes == 8 * 1_024 else {
        transportTask.cancel()
        return "SSH locator process specification"
    }

    func classifiesSSHFailure(
        name: String,
        terminationStatus: Int32 = 255,
        standardError: String,
        as expected: RemarkablePullError
    ) -> String? {
        let classificationRunner = RemarkableSmokeRunner()
        let classificationResultBox = RemarkableSmokeResultBox<
            Result<RemarkablePageSnapshot, RemarkablePullError>
        >()
        let classificationPuller = RemarkableSSHPagePuller(
            runner: classificationRunner,
            processEnvironment: [
                "HOME": "/tmp/remarkable-smoke-home",
                "PATH": "/usr/bin:/bin",
            ]
        )
        let classificationTask = classificationPuller.pullLatestPage(
            from: target
        ) {
            classificationResultBox.store($0)
        }
        let privateCanary =
            "remarkable-private-stderr-\(UUID().uuidString)"
        let capturedStandardError = Data(
            "\(standardError)\n\(privateCanary)\n".utf8
        )
        guard remarkableSmokeWaitUntil({
                  classificationRunner.requestCount == 1
              }),
              classificationRunner.spec(at: 0)?
                .maximumStandardErrorBytes == 8 * 1_024,
              classificationRunner.complete(
                  request: 0,
                  terminationStatus: terminationStatus,
                  standardError: capturedStandardError
              ),
              remarkableSmokeWaitUntil({
                  classificationResultBox.value != nil
              }) else {
            classificationTask.cancel()
            return "SSH \(name) classification setup"
        }
        guard case let .failure(error)? = classificationResultBox.value,
              error == expected,
              !error.localizedDescription.contains(privateCanary),
              !error.logCode.contains(privateCanary) else {
            return "SSH \(name) classification"
        }
        return nil
    }

    let classifiedFailures: [(
        name: String,
        terminationStatus: Int32,
        standardError: String,
        expected: RemarkablePullError
    )] = [
        (
            "missing known host",
            255,
            """
            No ED25519 host key is known for remarkable-usb and you have \
            requested strict checking.
            Host key verification failed.
            """,
            .hostKeyNotTrusted
        ),
        (
            "changed host key",
            255,
            """
            WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!
            Host key verification failed.
            """,
            .hostKeyChanged
        ),
        (
            "permission denied",
            255,
            "root@remarkable-usb: Permission denied (publickey,password).",
            .authenticationFailed
        ),
        (
            "connection refused",
            255,
            """
            ssh: connect to host remarkable-usb port 22: Connection refused
            """,
            .connectionFailed
        ),
        (
            "remote data unavailable",
            1,
            "cat: page.rm: No such file or directory",
            .remoteDataUnavailable(.locator)
        ),
    ]
    for failure in classifiedFailures {
        if let failureMessage = classifiesSSHFailure(
            name: failure.name,
            terminationStatus: failure.terminationStatus,
            standardError: failure.standardError,
            as: failure.expected
        ) {
            transportTask.cancel()
            return failureMessage
        }
    }

    guard let passwordTarget = try? credentialStore.configuredTarget(
        fallingBackTo: defaults
    ) else {
        return "SSH password target"
    }
    let passwordRunner = RemarkableSmokeRunner()
    let passwordPuller = RemarkableSSHPagePuller(
        runner: passwordRunner,
        processEnvironment: [
            "HOME": "/tmp/remarkable-smoke-home",
            "PATH": "/usr/bin:/bin",
            "SECRET_SHOULD_NOT_PASS": "private",
        ],
        askPassExecutableURL: URL(
            fileURLWithPath: "/tmp/RimeBuffer-smoke-executable"
        )
    )
    let passwordTask = passwordPuller.pullLatestPage(
        from: passwordTarget
    ) { _ in }
    guard remarkableSmokeWaitUntil({ passwordRunner.requestCount == 1 }),
          let passwordSpec = passwordRunner.spec(at: 0) else {
        passwordTask.cancel()
        transportTask.cancel()
        return "SSH password launch"
    }
    guard passwordSpec.arguments.contains("BatchMode=no"),
          passwordSpec.arguments.contains("NumberOfPasswordPrompts=1"),
          passwordSpec.arguments.contains("PubkeyAuthentication=no"),
          passwordSpec.arguments.contains(
              "PreferredAuthentications=keyboard-interactive,password"
          ),
          !passwordSpec.arguments.contains(
              "PreferredAuthentications=publickey,keyboard-interactive,password"
          ),
          passwordSpec.arguments.contains("StrictHostKeyChecking=yes"),
          passwordSpec.environment["SSH_ASKPASS"]
            == "/tmp/RimeBuffer-smoke-executable",
          passwordSpec.environment["SSH_ASKPASS_REQUIRE"] == "force",
          passwordSpec.environment[
              RemarkableSSHAskPassHandler.requestEnvironmentKey
          ] == "1",
          passwordSpec.environment[
              RemarkableSSHAskPassHandler.credentialPathEnvironmentKey
          ] == credentialStore.configurationURL.path,
          passwordSpec.environment[
              RemarkableSSHAskPassHandler.destinationEnvironmentKey
          ] == passwordTarget.destination,
          !passwordSpec.arguments.contains(where: {
              $0.contains(passwordCanary)
          }),
          !passwordSpec.environment.values.contains(where: {
              $0.contains(passwordCanary)
          }),
          String(
              data: passwordSpec.standardInput,
              encoding: .utf8
          )?.contains(passwordCanary) == false else {
        passwordTask.cancel()
        transportTask.cancel()
        return "SSH password process specification"
    }
    passwordTask.cancel()

    let timeoutRunner = RemarkableSmokeRunner()
    let timeoutResultBox = RemarkableSmokeResultBox<
        Result<RemarkablePageSnapshot, RemarkablePullError>
    >()
    let timeoutPuller = RemarkableSSHPagePuller(
        runner: timeoutRunner,
        processEnvironment: [
            "HOME": "/tmp/remarkable-smoke-home",
            "PATH": "/usr/bin:/bin",
        ],
        totalTimeout: 0.05
    )
    let timeoutTask = timeoutPuller.pullLatestPage(from: target) {
        timeoutResultBox.store($0)
    }
    guard remarkableSmokeWaitUntil({
              timeoutResultBox.value != nil
          }),
          case .failure(.timedOut)? = timeoutResultBox.value,
          timeoutRunner.cancellation(at: 0)?.wasCancelled == true else {
        timeoutTask.cancel()
        transportTask.cancel()
        return "SSH operation watchdog"
    }

    guard runner.succeed(
        request: 0,
        output: Data("\(documentID)\t\(pageIndex)\n".utf8)
    ),
          remarkableSmokeWaitUntil({ runner.requestCount == 2 }),
          let contentSpec = runner.spec(at: 1),
          contentSpec.arguments.dropLast(1).last == destination,
          contentSpec.arguments.last
            == "cat '/home/root/.local/share/remarkable/xochitl/\(documentID).content'",
          contentSpec.maximumOutputBytes == 2 * 1_024 * 1_024 else {
        transportTask.cancel()
        return "SSH content step"
    }

    let contentObject: [String: Any] = [
        "cPages": [
            "lastOpened": ["value": pageID],
            "pages": [["id": otherPageID], ["id": pageID]],
        ],
    ]
    guard let contentData = try? JSONSerialization.data(
        withJSONObject: contentObject
    ),
          runner.succeed(request: 1, output: contentData),
          remarkableSmokeWaitUntil({ runner.requestCount == 3 }),
          let firstPageSpec = runner.spec(at: 2) else {
        transportTask.cancel()
        return "SSH first page step"
    }
    let expectedPageCommand =
        "cat '/home/root/.local/share/remarkable/xochitl/\(documentID)/\(pageID).rm'"
    guard firstPageSpec.arguments.dropLast(1).last == destination,
          firstPageSpec.arguments.last == expectedPageCommand,
          firstPageSpec.maximumOutputBytes == 8 * 1_024 * 1_024 else {
        transportTask.cancel()
        return "SSH first page specification"
    }

    guard runner.succeed(request: 2, output: opaquePageBytes),
          remarkableSmokeWaitUntil({ runner.requestCount == 4 }),
          let secondPageSpec = runner.spec(at: 3),
          secondPageSpec.arguments.last == expectedPageCommand,
          secondPageSpec.maximumOutputBytes == 8 * 1_024 * 1_024,
          runner.succeed(request: 3, output: opaquePageBytes),
          remarkableSmokeWaitUntil({ runner.requestCount == 5 }),
          let pdfExportSpec = runner.spec(at: 4),
          pdfExportSpec.arguments.last
            == "/usr/bin/wget -Y off -qO- 'http://10.11.99.1/download/\(documentID)/pdf'",
          pdfExportSpec.maximumOutputBytes == 32 * 1_024 * 1_024,
          runner.succeed(request: 4, output: validPDFBytes),
          remarkableSmokeWaitUntil({ runner.requestCount == 6 }),
          let revalidatedLocatorSpec = runner.spec(at: 5),
          revalidatedLocatorSpec.arguments.last == locatorSpec.arguments.last,
          revalidatedLocatorSpec.maximumOutputBytes == 8 * 1_024,
          runner.succeed(
              request: 5,
              output: Data("\(documentID)\t\(pageIndex)\n".utf8)
          ),
          remarkableSmokeWaitUntil({ runner.requestCount == 7 }),
          let revalidatedContentSpec = runner.spec(at: 6),
          revalidatedContentSpec.arguments.last
            == "cat '/home/root/.local/share/remarkable/xochitl/\(documentID).content'",
          revalidatedContentSpec.maximumOutputBytes == 2 * 1_024 * 1_024,
          runner.succeed(request: 6, output: contentData),
          remarkableSmokeWaitUntil({ runner.requestCount == 8 }),
          let finalPageSpec = runner.spec(at: 7),
          finalPageSpec.arguments.last == expectedPageCommand,
          finalPageSpec.maximumOutputBytes == 8 * 1_024 * 1_024,
          runner.succeed(request: 7, output: opaquePageBytes),
          remarkableSmokeWaitUntil({ resultBox.value != nil }) else {
        transportTask.cancel()
        return "SSH stable page, PDF export, and identity revalidation"
    }
    guard case let .success(snapshot)? = resultBox.value,
          snapshot.documentID == documentID,
          snapshot.pageID == pageID,
          snapshot.pageIndex == pageIndex,
          snapshot.pageCount == pageCount,
          snapshot.data == opaquePageBytes,
          snapshot.pdfData == validPDFBytes else {
        return "SSH snapshot result"
    }

    func makePuller(
        runner smokeRunner: RemarkableSmokeRunner,
        pdfValidator: @escaping (Data, Int, Int) -> Bool = { _, _, _ in true }
    ) -> RemarkableSSHPagePuller {
        RemarkableSSHPagePuller(
            runner: smokeRunner,
            processEnvironment: [
                "HOME": "/tmp/remarkable-smoke-home",
                "PATH": "/usr/bin:/bin",
            ],
            pdfValidator: pdfValidator
        )
    }

    func driveStablePrelude(
        runner smokeRunner: RemarkableSmokeRunner,
        firstData: Data = opaquePageBytes,
        secondData: Data = opaquePageBytes
    ) -> Bool {
        guard remarkableSmokeWaitUntil({ smokeRunner.requestCount == 1 }),
              smokeRunner.succeed(
                  request: 0,
                  output: Data(
                      "\(documentID)\t\(pageIndex)\n".utf8
                  )
              ),
              remarkableSmokeWaitUntil({
                  smokeRunner.requestCount == 2
              }),
              smokeRunner.succeed(request: 1, output: contentData),
              remarkableSmokeWaitUntil({
                  smokeRunner.requestCount == 3
              }),
              smokeRunner.succeed(request: 2, output: firstData),
              remarkableSmokeWaitUntil({
                  smokeRunner.requestCount == 4
              }),
              smokeRunner.succeed(request: 3, output: secondData) else {
            return false
        }
        return true
    }

    let changedRunner = RemarkableSmokeRunner()
    let changedResultBox = RemarkableSmokeResultBox<
        Result<RemarkablePageSnapshot, RemarkablePullError>
    >()
    let changedTask = makePuller(runner: changedRunner).pullLatestPage(
        from: target
    ) {
        changedResultBox.store($0)
    }
    guard driveStablePrelude(
              runner: changedRunner,
              firstData: Data([0x01]),
              secondData: Data([0x02])
          ),
          remarkableSmokeWaitUntil({
              changedResultBox.value != nil
          }) else {
        changedTask.cancel()
        return "SSH changed-page setup"
    }
    guard case .failure(.pageChangedWhileReading)?
        = changedResultBox.value else {
        return "SSH changed-page rejection"
    }

    let changedDocumentID = "55555555-5555-5555-5555-555555555555"
    let changedDocumentRunner = RemarkableSmokeRunner()
    let changedDocumentResultBox = RemarkableSmokeResultBox<
        Result<RemarkablePageSnapshot, RemarkablePullError>
    >()
    let changedDocumentTask = makePuller(
        runner: changedDocumentRunner
    ).pullLatestPage(from: target) {
        changedDocumentResultBox.store($0)
    }
    guard driveStablePrelude(runner: changedDocumentRunner),
          remarkableSmokeWaitUntil({
              changedDocumentRunner.requestCount == 5
          }),
          changedDocumentRunner.succeed(
              request: 4,
              output: validPDFBytes
          ),
          remarkableSmokeWaitUntil({
              changedDocumentRunner.requestCount == 6
          }),
          changedDocumentRunner.succeed(
              request: 5,
              output: Data(
                  "\(changedDocumentID)\t\(pageIndex)\n".utf8
              )
          ),
          remarkableSmokeWaitUntil({
              changedDocumentResultBox.value != nil
          }) else {
        changedDocumentTask.cancel()
        return "SSH post-read document change setup"
    }
    guard case .failure(.pageChangedWhileReading)?
        = changedDocumentResultBox.value else {
        return "SSH post-read document change rejection"
    }

    let changedPageID = "66666666-6666-6666-6666-666666666666"
    let changedContentObject: [String: Any] = [
        "cPages": [
            "lastOpened": ["value": changedPageID],
            "pages": [["id": pageID], ["id": changedPageID]],
        ],
    ]
    guard let changedContentData = try? JSONSerialization.data(
        withJSONObject: changedContentObject
    ) else {
        return "SSH post-read page change content"
    }
    let changedCurrentPageResultBox = RemarkableSmokeResultBox<
        Result<RemarkablePageSnapshot, RemarkablePullError>
    >()
    let changedCurrentPageRunner = RemarkableSmokeRunner()
    let changedCurrentPageTask = makePuller(
        runner: changedCurrentPageRunner
    ).pullLatestPage(from: target) {
        changedCurrentPageResultBox.store($0)
    }
    guard driveStablePrelude(runner: changedCurrentPageRunner),
          remarkableSmokeWaitUntil({
              changedCurrentPageRunner.requestCount == 5
          }),
          changedCurrentPageRunner.succeed(
              request: 4,
              output: validPDFBytes
          ),
          remarkableSmokeWaitUntil({
              changedCurrentPageRunner.requestCount == 6
          }),
          changedCurrentPageRunner.succeed(
              request: 5,
              output: Data(
                  "\(documentID)\t\(pageIndex)\n".utf8
              )
          ),
          remarkableSmokeWaitUntil({
              changedCurrentPageRunner.requestCount == 7
          }),
          changedCurrentPageRunner.succeed(
              request: 6,
              output: changedContentData
          ),
          remarkableSmokeWaitUntil({
              changedCurrentPageResultBox.value != nil
          }) else {
        changedCurrentPageTask.cancel()
        return "SSH post-read current-page change setup"
    }
    guard case .failure(.pageChangedWhileReading)?
        = changedCurrentPageResultBox.value else {
        return "SSH post-read current-page change rejection"
    }

    let changedFinalPageRunner = RemarkableSmokeRunner()
    let changedFinalPageResultBox = RemarkableSmokeResultBox<
        Result<RemarkablePageSnapshot, RemarkablePullError>
    >()
    let changedFinalPageTask = makePuller(
        runner: changedFinalPageRunner
    ).pullLatestPage(from: target) {
        changedFinalPageResultBox.store($0)
    }
    guard driveStablePrelude(runner: changedFinalPageRunner),
          remarkableSmokeWaitUntil({
              changedFinalPageRunner.requestCount == 5
          }),
          changedFinalPageRunner.succeed(
              request: 4,
              output: validPDFBytes
          ),
          remarkableSmokeWaitUntil({
              changedFinalPageRunner.requestCount == 6
          }),
          changedFinalPageRunner.succeed(
              request: 5,
              output: Data(
                  "\(documentID)\t\(pageIndex)\n".utf8
              )
          ),
          remarkableSmokeWaitUntil({
              changedFinalPageRunner.requestCount == 7
          }),
          changedFinalPageRunner.succeed(
              request: 6,
              output: contentData
          ),
          remarkableSmokeWaitUntil({
              changedFinalPageRunner.requestCount == 8
          }),
          changedFinalPageRunner.succeed(
              request: 7,
              output: Data([0x7F])
          ),
          remarkableSmokeWaitUntil({
              changedFinalPageResultBox.value != nil
          }) else {
        changedFinalPageTask.cancel()
        return "SSH final page stability setup"
    }
    guard case .failure(.pageChangedWhileReading)?
        = changedFinalPageResultBox.value else {
        return "SSH final page stability rejection"
    }

    let retryRunner = RemarkableSmokeRunner()
    let retryResultBox = RemarkableSmokeResultBox<
        Result<RemarkablePageSnapshot, RemarkablePullError>
    >()
    let retryTask = makePuller(
        runner: retryRunner,
        pdfValidator: {
            $0 == validPDFBytes && $1 == pageIndex && $2 == pageCount
        }
    ).pullLatestPage(from: target) {
        retryResultBox.store($0)
    }
    let invalidPDFBytes = Data("temporarily incomplete PDF".utf8)
    guard driveStablePrelude(runner: retryRunner),
          remarkableSmokeWaitUntil({ retryRunner.requestCount == 5 }),
          retryRunner.succeed(request: 4, output: invalidPDFBytes),
          remarkableSmokeWaitUntil(
              timeout: 1.25,
              { retryRunner.requestCount == 6 }
          ),
          retryRunner.spec(at: 5)?.arguments.last
            == retryRunner.spec(at: 4)?.arguments.last,
          retryRunner.succeed(request: 5, output: validPDFBytes),
          remarkableSmokeWaitUntil({ retryRunner.requestCount == 7 }),
          retryRunner.succeed(
              request: 6,
              output: Data(
                  "\(documentID)\t\(pageIndex)\n".utf8
              )
          ),
          remarkableSmokeWaitUntil({ retryRunner.requestCount == 8 }),
          retryRunner.succeed(request: 7, output: contentData),
          remarkableSmokeWaitUntil({ retryRunner.requestCount == 9 }),
          retryRunner.succeed(request: 8, output: opaquePageBytes),
          remarkableSmokeWaitUntil({ retryResultBox.value != nil }),
          case .success? = retryResultBox.value else {
        retryTask.cancel()
        return "SSH invalid PDF retry then success"
    }

    let invalidPDFRunner = RemarkableSmokeRunner()
    let invalidPDFResultBox = RemarkableSmokeResultBox<
        Result<RemarkablePageSnapshot, RemarkablePullError>
    >()
    let invalidPDFTask = makePuller(
        runner: invalidPDFRunner,
        pdfValidator: { _, _, _ in false }
    ).pullLatestPage(from: target) {
        invalidPDFResultBox.store($0)
    }
    guard driveStablePrelude(runner: invalidPDFRunner),
          remarkableSmokeWaitUntil({
              invalidPDFRunner.requestCount == 5
          }),
          invalidPDFRunner.succeed(
              request: 4,
              output: invalidPDFBytes
          ),
          remarkableSmokeWaitUntil(
              timeout: 1.25,
              { invalidPDFRunner.requestCount == 6 }
          ),
          invalidPDFRunner.succeed(
              request: 5,
              output: invalidPDFBytes
          ),
          remarkableSmokeWaitUntil(
              timeout: 2,
              { invalidPDFRunner.requestCount == 7 }
          ),
          invalidPDFRunner.succeed(
              request: 6,
              output: invalidPDFBytes
          ),
          remarkableSmokeWaitUntil({
              invalidPDFResultBox.value != nil
          }) else {
        invalidPDFTask.cancel()
        return "SSH invalid PDF retry exhaustion setup"
    }
    guard case .failure(.invalidPDFExport)?
        = invalidPDFResultBox.value else {
        return "SSH invalid PDF retry exhaustion"
    }

    let mappingRunner = RemarkableSmokeRunner()
    let mappingResultBox = RemarkableSmokeResultBox<
        Result<RemarkablePageSnapshot, RemarkablePullError>
    >()
    let mappingTask = makePuller(
        runner: mappingRunner
    ).pullLatestPage(from: target) {
        mappingResultBox.store($0)
    }
    let mismatchedContentObject: [String: Any] = [
        "cPages": [
            "lastOpened": ["value": pageID],
            "pages": [["id": otherPageID]],
        ],
    ]
    guard let mismatchedContentData = try? JSONSerialization.data(
              withJSONObject: mismatchedContentObject
          ),
          remarkableSmokeWaitUntil({ mappingRunner.requestCount == 1 }),
          mappingRunner.succeed(
              request: 0,
              output: Data(
                  "\(documentID)\t\(pageIndex)\n".utf8
              )
          ),
          remarkableSmokeWaitUntil({ mappingRunner.requestCount == 2 }),
          mappingRunner.succeed(
              request: 1,
              output: mismatchedContentData
          ),
          remarkableSmokeWaitUntil({ mappingResultBox.value != nil }) else {
        mappingTask.cancel()
        return "SSH page mapping mismatch setup"
    }
    guard case .failure(.pageMappingMismatch)?
        = mappingResultBox.value else {
        return "SSH page mapping mismatch"
    }

    do {
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o777],
            ofItemAtPath: credentialRoot.path
        )
        do {
            _ = try credentialStore.load()
            return "SSH writable shared root accepted"
        } catch RemarkableCredentialStoreError.invalidPermissions {
            // Expected.
        }
        do {
            _ = try RemarkableCredentialStore.readConfiguration(
                at: credentialStore.configurationURL
            )
            return "SSH askpass writable shared root accepted"
        } catch RemarkableCredentialStoreError.invalidPermissions {
            // Expected.
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: credentialRoot.path
        )
        guard try credentialStore.load() == savedConfiguration else {
            return "SSH shared root permission recovery"
        }
    } catch {
        return "SSH shared root permission boundary"
    }

    do {
        try configurationStore.delete(schema: configurationSchema)
        guard try credentialStore.load() == nil,
              defaults.object(forKey: RemarkableSSHTarget.defaultsKey) == nil,
              defaults.object(
                  forKey: RemarkableOCRLanguageMode.defaultsKey
              ) == nil,
              RemarkableOCRLanguageMode.configured(in: defaults)
                == .simplifiedChinese else {
            return "Remarkable configuration delete cleanup"
        }
    } catch {
        return "Remarkable configuration delete"
    }

    return nil
}

private enum RemarkableSmokeTombstoneTransition {
    case protection
    case secureInput
    case ownerSwitch
    case workbenchPause
    case configuration
}

private func remarkableWorkspaceSmoke(
    fixture: Data,
    expectedText: String
) -> String? {
    let standardDefaults = UserDefaults.standard
    let previousBufferEnabled = standardDefaults.object(
        forKey: "bufferEnabled"
    )
    standardDefaults.set(true, forKey: "bufferEnabled")
    defer {
        if let previousBufferEnabled {
            standardDefaults.set(previousBufferEnabled, forKey: "bufferEnabled")
        } else {
            standardDefaults.removeObject(forKey: "bufferEnabled")
        }
    }

    let documentID = "33333333-3333-3333-3333-333333333333"
    let pageID = "44444444-4444-4444-4444-444444444444"
    let pageIndex = 1
    let pageCount = 2
    let pdfData = Data("%PDF-1.7 workspace smoke\n%%EOF\n".utf8)
    let targetDestination = "root@remarkable-smoke"
    let defaultsSuite =
        "RimeBuffer.RemarkableSmoke.Workspace.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: defaultsSuite) else {
        return "workspace defaults setup"
    }
    defer { defaults.removePersistentDomain(forName: defaultsSuite) }
    defaults.set(targetDestination, forKey: RemarkableSSHTarget.defaultsKey)

    let model = BufferModel()
    let puller = RemarkableSmokePuller()
    let textRecognizer = RemarkableSmokeTextRecognizer()
    let workspace = RemarkableWorkspace(
        defaults: defaults,
        credentialStore: nil,
        bufferModel: model,
        puller: puller,
        textRecognizer: textRecognizer,
        notificationCenter: NotificationCenter(),
        isSelected: { true },
        secureInputEnabled: { false }
    )
    workspace.start()
    defer { workspace.stop() }

    guard let initialOptions = workspace.optionPresentation,
          initialOptions.selectedIdentifier
            == RemarkableOCRLanguageMode.simplifiedChinese.rawValue,
          initialOptions.options.map(\.identifier)
            == RemarkableOCRLanguageMode.allCases.map(\.rawValue),
          initialOptions.options.map(\.title)
            == RemarkableOCRLanguageMode.allCases.map(
                \.workbenchDisplayName
            ),
          initialOptions.isEnabled,
          defaults.object(
              forKey: RemarkableOCRLanguageMode.defaultsKey
          ) == nil,
          workspace.invoke(),
          puller.requestCount == 1,
          puller.target(at: 0)?.destination == targetDestination,
          puller.finish(
              request: 0,
              with: .success(RemarkablePageSnapshot(
                  documentID: documentID,
                  pageID: pageID,
                  pageIndex: pageIndex,
                  pageCount: pageCount,
                  data: fixture,
                  pdfData: pdfData
              ))
          ),
          remarkableSmokeWaitUntil({
              textRecognizer.requestCount == 1
          }),
          let firstOCRRequest = textRecognizer.request(at: 0),
          firstOCRRequest.pdfData == pdfData,
          firstOCRRequest.pageIndex == pageIndex,
          firstOCRRequest.expectedPageCount == pageCount,
          firstOCRRequest.language == .simplifiedChinese,
          textRecognizer.finish(
              request: 0,
              with: .success(RemarkableOCRResult(
                  text: expectedText,
                  observationCount: 2,
                  meanConfidence: 0.91
              ))
          ),
          remarkableSmokeWaitUntil({
              workspace.phase == .succeeded && !model.blocks.isEmpty
          }),
          model.stagedText == expectedText,
          model.blocks.allSatisfy({
              $0.origin == .ssh(host: targetDestination)
          }) else {
        return "workspace staging"
    }

    let stagedBlockCount = model.blocks.count
    let duplicatePDFData = Data("%PDF-1.7 different export\n%%EOF\n".utf8)
    guard workspace.invoke(),
          puller.requestCount == 2,
          puller.finish(
              request: 1,
              with: .success(RemarkablePageSnapshot(
                  documentID: documentID,
                  pageID: pageID,
                  pageIndex: pageIndex,
                  pageCount: pageCount,
                  data: fixture,
                  pdfData: duplicatePDFData
              ))
          ),
          remarkableSmokeWaitUntil({
              workspace.actionPresentation.statusText.contains("没有变化")
          }),
          textRecognizer.requestCount == 1,
          model.blocks.count == stagedBlockCount,
          model.stagedText == expectedText else {
        return "workspace .rm digest duplicate suppression"
    }

    guard workspace.selectOption(
              identifier: RemarkableOCRLanguageMode.automatic.rawValue
          ),
          RemarkableOCRLanguageMode.configured(in: defaults)
            == .automatic,
          workspace.optionPresentation?.selectedIdentifier
            == RemarkableOCRLanguageMode.automatic.rawValue,
          !workspace.selectOption(identifier: "not-a-language"),
          RemarkableOCRLanguageMode.configured(in: defaults)
            == .automatic else {
        return "workspace OCR language option selection"
    }
    let changedLanguageText = "Automatic language OCR result."
    guard workspace.invoke(),
          puller.requestCount == 3,
          puller.finish(
              request: 2,
              with: .success(RemarkablePageSnapshot(
                  documentID: documentID,
                  pageID: pageID,
                  pageIndex: pageIndex,
                  pageCount: pageCount,
                  data: fixture,
                  pdfData: pdfData
              ))
          ),
          remarkableSmokeWaitUntil({
              textRecognizer.requestCount == 2
          }),
          let changedLanguageRequest = textRecognizer.request(at: 1),
          changedLanguageRequest.pdfData == pdfData,
          changedLanguageRequest.pageIndex == pageIndex,
          changedLanguageRequest.expectedPageCount == pageCount,
          changedLanguageRequest.language == .automatic,
          textRecognizer.finish(
              request: 1,
              with: .success(RemarkableOCRResult(
                  text: changedLanguageText,
                  observationCount: 1,
                  meanConfidence: 0.88
              ))
          ),
          remarkableSmokeWaitUntil({
              workspace.phase == .succeeded
                  && model.stagedText == expectedText + changedLanguageText
          }) else {
        return "workspace OCR language change recognition"
    }

    let changedLanguageBlockCount = model.blocks.count
    let changedLanguageStagedText = model.stagedText
    guard workspace.invoke(),
          puller.requestCount == 4,
          puller.finish(
              request: 3,
              with: .success(RemarkablePageSnapshot(
                  documentID: documentID,
                  pageID: pageID,
                  pageIndex: pageIndex,
                  pageCount: pageCount,
                  data: fixture,
                  pdfData: duplicatePDFData
              ))
          ),
          remarkableSmokeWaitUntil({
              workspace.actionPresentation.statusText.contains("没有变化")
          }),
          textRecognizer.requestCount == 2,
          model.blocks.count == changedLanguageBlockCount,
          model.stagedText == changedLanguageStagedText else {
        return "workspace same-language .rm duplicate suppression"
    }

    var changedPageData = fixture
    changedPageData.append(0xA5)
    let changedText = "Changed local OCR text."
    guard workspace.invoke(),
          puller.requestCount == 5,
          puller.finish(
              request: 4,
              with: .success(RemarkablePageSnapshot(
                  documentID: documentID,
                  pageID: pageID,
                  pageIndex: pageIndex,
                  pageCount: pageCount,
                  data: changedPageData,
                  pdfData: pdfData
              ))
          ),
          remarkableSmokeWaitUntil({
              textRecognizer.requestCount == 3
          }),
          textRecognizer.finish(
              request: 2,
              with: .success(RemarkableOCRResult(
                  text: changedText,
                  observationCount: 1,
                  meanConfidence: nil
              ))
          ),
          remarkableSmokeWaitUntil({
              workspace.phase == .succeeded
                  && model.stagedText
                    == expectedText + changedLanguageText + changedText
          }) else {
        return "workspace changed .rm digest recognition"
    }

    let successfulBlockCount = model.blocks.count
    let successfulText = model.stagedText
    var blankPageData = fixture
    blankPageData.append(0xB0)
    guard workspace.invoke(),
          puller.requestCount == 6,
          puller.finish(
              request: 5,
              with: .success(RemarkablePageSnapshot(
                  documentID: documentID,
                  pageID: pageID,
                  pageIndex: pageIndex,
                  pageCount: pageCount,
                  data: blankPageData,
                  pdfData: pdfData
              ))
          ),
          remarkableSmokeWaitUntil({
              textRecognizer.requestCount == 4
          }),
          textRecognizer.finish(
              request: 3,
              with: .success(RemarkableOCRResult(
                  text: " \n\t",
                  observationCount: 0,
                  meanConfidence: nil
              ))
          ) else {
        return "workspace blank OCR result setup"
    }
    guard remarkableSmokeWaitUntil({
        if case .failed = workspace.phase {
            return true
        }
        return false
    }) else {
        return "workspace blank OCR result phase"
    }
    guard workspace.actionPresentation.statusText
        == RemarkableLocalOCRError.invalidText.localizedDescription else {
        return "workspace blank OCR result status"
    }
    guard model.blocks.count == successfulBlockCount,
          model.stagedText == successfulText else {
        return "workspace blank OCR result mutated buffer"
    }

    var failedPageData = fixture
    failedPageData.append(0xB1)
    guard workspace.invoke(),
          puller.requestCount == 7,
          puller.finish(
              request: 6,
              with: .success(RemarkablePageSnapshot(
                  documentID: documentID,
                  pageID: pageID,
                  pageIndex: pageIndex,
                  pageCount: pageCount,
                  data: failedPageData,
                  pdfData: pdfData
              ))
          ),
          remarkableSmokeWaitUntil({
              textRecognizer.requestCount == 5
          }),
          textRecognizer.finish(
              request: 4,
              with: .failure(.recognitionFailed)
          ),
          remarkableSmokeWaitUntil({
              if case .failed = workspace.phase {
                  return true
              }
              return false
          }),
          workspace.actionPresentation.statusText.contains("文字识别失败"),
          model.blocks.count == successfulBlockCount,
          model.stagedText == successfulText else {
        return "workspace OCR failure"
    }

    guard remarkableWorkspaceLanguageRestartSmoke(
        fixture: fixture,
        documentID: documentID,
        pageID: pageID,
        pageIndex: pageIndex,
        pageCount: pageCount,
        pdfData: pdfData
    ) else {
        return "workspace in-flight language switch restart"
    }

    for transition in [
        RemarkableSmokeTombstoneTransition.protection,
        .secureInput,
        .ownerSwitch,
        .workbenchPause,
        .configuration,
    ] {
        if !remarkableWorkspaceTombstoneSmoke(
            transition: transition,
            defaults: defaults,
            fixture: fixture,
            documentID: documentID,
            pageID: pageID,
            pageIndex: pageIndex,
            pageCount: pageCount,
            pdfData: pdfData,
            duringRecognition: false
        ) || !remarkableWorkspaceTombstoneSmoke(
            transition: transition,
            defaults: defaults,
            fixture: fixture,
            documentID: documentID,
            pageID: pageID,
            pageIndex: pageIndex,
            pageCount: pageCount,
            pdfData: pdfData,
            duringRecognition: true
        ) {
            switch transition {
            case .protection:
                return "workspace protection tombstone"
            case .secureInput:
                return "workspace secure-input tombstone"
            case .ownerSwitch:
                return "workspace owner tombstone"
            case .workbenchPause:
                return "workspace pause tombstone"
            case .configuration:
                return "workspace configuration tombstone"
            }
        }
    }

    return nil
}

private func remarkableWorkspaceLanguageRestartSmoke(
    fixture: Data,
    documentID: String,
    pageID: String,
    pageIndex: Int,
    pageCount: Int,
    pdfData: Data
) -> Bool {
    let defaultsSuite =
        "RimeBuffer.RemarkableSmoke.LanguageRestart.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: defaultsSuite) else {
        return false
    }
    defer { defaults.removePersistentDomain(forName: defaultsSuite) }
    defaults.set(
        "root@remarkable-language-restart",
        forKey: RemarkableSSHTarget.defaultsKey
    )

    let model = BufferModel()
    let puller = RemarkableSmokePuller()
    let textRecognizer = RemarkableSmokeTextRecognizer()
    let notificationCenter = NotificationCenter()
    var genericLanguageNotificationCount = 0
    let observer = notificationCenter.addObserver(
        forName: .pluginConfigurationDidChange,
        object: nil,
        queue: nil
    ) { notification in
        guard notification.userInfo?[
                  PluginConfigurationNotificationKey.pluginID
              ] as? String == BuiltInPluginID.remarkable,
              notification.userInfo?[
                  PluginConfigurationNotificationKey.changedFieldIDs
              ] as? [String] == [
                  RemarkablePluginConfigurationFieldID.ocrLanguage,
              ] else {
            return
        }
        genericLanguageNotificationCount += 1
    }
    defer { notificationCenter.removeObserver(observer) }

    let workspace = RemarkableWorkspace(
        defaults: defaults,
        credentialStore: nil,
        bufferModel: model,
        puller: puller,
        textRecognizer: textRecognizer,
        notificationCenter: notificationCenter,
        isSelected: { true },
        secureInputEnabled: { false }
    )
    workspace.start()
    defer { workspace.stop() }

    guard workspace.invoke(),
          puller.requestCount == 1,
          let staleCancellation = puller.cancellation(at: 0),
          workspace.selectOption(
              identifier: RemarkableOCRLanguageMode.english.rawValue
          ),
          remarkableSmokeWaitUntil({
              staleCancellation.wasCancelled
                  && puller.requestCount == 2
                  && workspace.phase == .running
          }),
          genericLanguageNotificationCount == 1,
          workspace.optionPresentation?.selectedIdentifier
            == RemarkableOCRLanguageMode.english.rawValue else {
        return false
    }

    // A late completion from the old language must remain tombstoned.
    guard puller.finish(
              request: 0,
              with: .success(RemarkablePageSnapshot(
                  documentID: documentID,
                  pageID: pageID,
                  pageIndex: pageIndex,
                  pageCount: pageCount,
                  data: fixture,
                  pdfData: pdfData
              ))
          ) else {
        return false
    }
    remarkableSmokePumpMainRunLoop(for: 0.05)
    guard textRecognizer.requestCount == 0,
          puller.finish(
              request: 1,
              with: .success(RemarkablePageSnapshot(
                  documentID: documentID,
                  pageID: pageID,
                  pageIndex: pageIndex,
                  pageCount: pageCount,
                  data: fixture,
                  pdfData: pdfData
              ))
          ),
          remarkableSmokeWaitUntil({
              textRecognizer.requestCount == 1
          }),
          textRecognizer.request(at: 0)?.language == .english,
          textRecognizer.finish(
              request: 0,
              with: .success(RemarkableOCRResult(
                  text: "Language restart result.",
                  observationCount: 1,
                  meanConfidence: 0.9
              ))
          ),
          remarkableSmokeWaitUntil({
              workspace.phase == .succeeded
                  && model.stagedText == "Language restart result."
          }) else {
        return false
    }
    return true
}

private func remarkableWorkspaceTombstoneSmoke(
    transition: RemarkableSmokeTombstoneTransition,
    defaults: UserDefaults,
    fixture: Data,
    documentID: String,
    pageID: String,
    pageIndex: Int,
    pageCount: Int,
    pdfData: Data,
    duringRecognition: Bool
) -> Bool {
    let model = BufferModel()
    let puller = RemarkableSmokePuller()
    let textRecognizer = RemarkableSmokeTextRecognizer()
    let notificationCenter = NotificationCenter()
    var secureInputEnabled = false
    let workspace = RemarkableWorkspace(
        defaults: defaults,
        credentialStore: nil,
        bufferModel: model,
        puller: puller,
        textRecognizer: textRecognizer,
        notificationCenter: notificationCenter,
        isSelected: { true },
        secureInputEnabled: { secureInputEnabled }
    )
    workspace.start()
    defer { workspace.stop() }
    guard workspace.invoke(),
          puller.requestCount == 1,
          let pullCancellation = puller.cancellation(at: 0) else {
        return false
    }

    if duringRecognition {
        guard puller.finish(
                  request: 0,
                  with: .success(RemarkablePageSnapshot(
                      documentID: documentID,
                      pageID: pageID,
                      pageIndex: pageIndex,
                      pageCount: pageCount,
                      data: fixture,
                      pdfData: pdfData
                  ))
              ),
              remarkableSmokeWaitUntil({
                  textRecognizer.requestCount == 1
              }),
              let recognitionCancellation =
                  textRecognizer.cancellation(at: 0) else {
            return false
        }

        switch transition {
        case .protection:
            workspace.setProtected(true)
        case .secureInput:
            secureInputEnabled = true
        case .ownerSwitch:
            workspace.setOwnerActive(false)
        case .workbenchPause:
            workspace.workbenchWillPause()
        case .configuration:
            notificationCenter.post(
                name: .remarkableConfigurationDidChange,
                object: nil
            )
        }
        guard textRecognizer.finish(
                  request: 0,
                  with: .success(RemarkableOCRResult(
                      text: "late OCR result",
                      observationCount: 1,
                      meanConfidence: 0.8
                  ))
              ),
              remarkableSmokeWaitUntil({
                  recognitionCancellation.wasCancelled
                      && workspace.phase == .idle
              }) else {
            return false
        }
        remarkableSmokePumpMainRunLoop(for: 0.05)
        return model.blocks.isEmpty
    }

    switch transition {
    case .protection:
        workspace.setProtected(true)
    case .secureInput:
        // Exercise the final synchronous OS recheck rather than the periodic
        // workbench privacy poll.
        secureInputEnabled = true
    case .ownerSwitch:
        workspace.setOwnerActive(false)
    case .workbenchPause:
        workspace.workbenchWillPause()
    case .configuration:
        notificationCenter.post(
            name: .remarkableConfigurationDidChange,
            object: nil
        )
    }
    guard puller.finish(
              request: 0,
              with: .success(RemarkablePageSnapshot(
                  documentID: documentID,
                  pageID: pageID,
                  pageIndex: pageIndex,
                  pageCount: pageCount,
                  data: fixture,
                  pdfData: pdfData
              ))
          ),
          remarkableSmokeWaitUntil({
              pullCancellation.wasCancelled
                  && workspace.phase == .idle
                  && textRecognizer.requestCount == 0
          }) else {
        return false
    }

    remarkableSmokePumpMainRunLoop(for: 0.05)
    return model.blocks.isEmpty
}
