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
        let callback: ((AITextCLIProcessResult) -> Void)?
        lock.lock()
        callback = invocations.indices.contains(index)
            ? invocations[index].completion
            : nil
        lock.unlock()
        guard let callback else { return false }
        callback(AITextCLIProcessResult(
            terminationStatus: 0,
            standardOutput: output,
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

    for privateDirectory in [
        credentialStore.rootDirectory,
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
        ]
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
          locatorSpec.timeout <= 10,
          locatorSpec.maximumOutputBytes == 8 * 1_024 else {
        transportTask.cancel()
        return "SSH locator process specification"
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

    let documentID = "11111111-1111-1111-1111-111111111111"
    let pageID = "22222222-2222-2222-2222-222222222222"
    guard runner.succeed(
        request: 0,
        output: Data("\(documentID)\t0\n".utf8)
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
            "pages": [["id": pageID]],
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

    let opaquePageBytes = Data([0x72, 0x4D, 0x36, 0x00])
    guard runner.succeed(request: 2, output: opaquePageBytes),
          remarkableSmokeWaitUntil({ runner.requestCount == 4 }),
          let secondPageSpec = runner.spec(at: 3),
          secondPageSpec.arguments.last == expectedPageCommand,
          secondPageSpec.maximumOutputBytes == 8 * 1_024 * 1_024,
          runner.succeed(request: 3, output: opaquePageBytes),
          remarkableSmokeWaitUntil({ resultBox.value != nil }) else {
        transportTask.cancel()
        return "SSH stable double read"
    }
    guard case let .success(snapshot)? = resultBox.value,
          snapshot.documentID == documentID,
          snapshot.pageID == pageID,
          snapshot.data == opaquePageBytes else {
        return "SSH snapshot result"
    }

    let changedResultBox = RemarkableSmokeResultBox<
        Result<RemarkablePageSnapshot, RemarkablePullError>
    >()
    let changedTask = puller.pullLatestPage(from: target) {
        changedResultBox.store($0)
    }
    guard remarkableSmokeWaitUntil({ runner.requestCount == 5 }),
          runner.succeed(
              request: 4,
              output: Data("\(documentID)\t0\n".utf8)
          ),
          remarkableSmokeWaitUntil({ runner.requestCount == 6 }),
          runner.succeed(request: 5, output: contentData),
          remarkableSmokeWaitUntil({ runner.requestCount == 7 }),
          runner.succeed(request: 6, output: Data([0x01])),
          remarkableSmokeWaitUntil({ runner.requestCount == 8 }),
          runner.succeed(request: 7, output: Data([0x02])),
          remarkableSmokeWaitUntil({ changedResultBox.value != nil }) else {
        changedTask.cancel()
        return "SSH changed-page setup"
    }
    guard case .failure(.pageChangedWhileReading)? = changedResultBox.value else {
        return "SSH changed-page rejection"
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
    let workspace = RemarkableWorkspace(
        defaults: defaults,
        credentialStore: nil,
        bufferModel: model,
        puller: puller,
        notificationCenter: NotificationCenter(),
        isSelected: { true },
        secureInputEnabled: { false }
    )
    workspace.start()
    defer { workspace.stop() }

    guard workspace.invoke(),
          puller.requestCount == 1,
          puller.target(at: 0)?.destination == targetDestination,
          puller.finish(
              request: 0,
              with: .success(RemarkablePageSnapshot(
                  documentID: documentID,
                  pageID: pageID,
                  data: fixture
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
    guard workspace.invoke(),
          puller.requestCount == 2,
          puller.finish(
              request: 1,
              with: .success(RemarkablePageSnapshot(
                  documentID: documentID,
                  pageID: pageID,
                  data: fixture
              ))
          ),
          remarkableSmokeWaitUntil({
              workspace.actionPresentation.statusText.contains("没有变化")
          }),
          model.blocks.count == stagedBlockCount,
          model.stagedText == expectedText else {
        return "workspace duplicate suppression"
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
            pageID: pageID
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

private func remarkableWorkspaceTombstoneSmoke(
    transition: RemarkableSmokeTombstoneTransition,
    defaults: UserDefaults,
    fixture: Data,
    documentID: String,
    pageID: String
) -> Bool {
    let model = BufferModel()
    let puller = RemarkableSmokePuller()
    let notificationCenter = NotificationCenter()
    var secureInputEnabled = false
    let workspace = RemarkableWorkspace(
        defaults: defaults,
        credentialStore: nil,
        bufferModel: model,
        puller: puller,
        notificationCenter: notificationCenter,
        isSelected: { true },
        secureInputEnabled: { secureInputEnabled }
    )
    workspace.start()
    defer { workspace.stop() }
    guard workspace.invoke(),
          puller.requestCount == 1,
          let cancellation = puller.cancellation(at: 0) else {
        return false
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
                  data: fixture
              ))
          ),
          remarkableSmokeWaitUntil({
              cancellation.wasCancelled && workspace.phase == .idle
          }) else {
        return false
    }

    remarkableSmokePumpMainRunLoop(for: 0.25)
    return model.blocks.isEmpty
}
