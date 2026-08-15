import Foundation
import Security
import Darwin
import CryptoKit

extension Notification.Name {
    static let marineChromeCredentialsDidReset = Notification.Name(
        "RimeBuffer.MarineChrome.credentialsDidReset"
    )
    static let marineChromePairingDidChange = Notification.Name(
        "RimeBuffer.MarineChrome.pairingDidChange"
    )
}

/// Cross-queue snapshot of whether the optional Marine Chrome plug-in is both
/// installed and enabled. `PluginRegistry` remains main-thread owned; the
/// loopback gateway reads only this fail-closed value from its Network queue.
final class MarineChromeGatewayAvailability {
    static let shared = MarineChromeGatewayAvailability()

    private let lock = NSLock()
    private var available: Bool

    init(initiallyAvailable: Bool = false) {
        available = initiallyAvailable
    }

    var isAvailable: Bool {
        lock.lock()
        defer { lock.unlock() }
        return available
    }

    /// Returns true only for a real availability transition.
    @discardableResult
    func update(_ newValue: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard available != newValue else { return false }
        available = newValue
        return true
    }

    /// Linearizes a persistence-capable operation with availability revocation.
    /// Once `update(false)` returns, no guarded operation can still be writing a
    /// newly issued proof credential or pairing origin.
    func valueIfAvailable<T>(
        _ operation: () throws -> T
    ) rethrows -> T? {
        lock.lock()
        defer { lock.unlock() }
        guard available else { return nil }
        return try operation()
    }

    func optionalValueIfAvailable<T>(
        _ operation: () -> T?
    ) -> T? {
        lock.lock()
        defer { lock.unlock() }
        guard available else { return nil }
        return operation()
    }
}

enum MarineChromeGatewayAvailabilityLifecycle {
    /// Applies a Registry snapshot and revokes every in-memory authority exactly
    /// once on an available -> unavailable transition.
    static func reconcile(
        _ available: Bool,
        snapshot: MarineChromeGatewayAvailability = .shared,
        cancelPairing: () -> Void,
        cancelPrompt: () -> Void,
        clearContext: () -> Void
    ) {
        let changed = snapshot.update(available)
        guard changed, !available else { return }
        cancelPairing()
        cancelPrompt()
        clearContext()
    }
}

enum MarineChromeGatewayFiles {
    static var root: URL {
        let url = ProcessInfo.processInfo.environment["RIMEBUFFER_USER_DIR"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        } ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/RimeBuffer", isDirectory: true)
        try? FileManager.default.createDirectory(at: url,
                                                 withIntermediateDirectories: true)
        return url
    }
}

enum MarineChromeGatewayTokenError: Error {
    case randomnessUnavailable
    case encodingFailed
}

private enum MarineChromeCredentialTransactionError: Error {
    case lockUnavailable
    case generationUnavailable
}

private enum MarineChromeCredentialFileLock {
    private static var url: URL {
        MarineChromeGatewayFiles.root.appendingPathComponent(
            "marine-chrome-credential.lock"
        )
    }

    static func withLock<T>(_ body: () throws -> T) throws -> T {
        let descriptor: Int32 = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return -1 }
            return Darwin.open(path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        }
        guard descriptor >= 0 else {
            throw MarineChromeCredentialTransactionError.lockUnavailable
        }
        defer { Darwin.close(descriptor) }
        guard Darwin.fchmod(descriptor, S_IRUSR | S_IWUSR) == 0,
              Darwin.lockf(descriptor, F_LOCK, 0) == 0 else {
            throw MarineChromeCredentialTransactionError.lockUnavailable
        }
        defer { _ = Darwin.lockf(descriptor, F_ULOCK, 0) }
        return try body()
    }
}

private enum MarineChromeCredentialGeneration {
    private static var url: URL {
        MarineChromeGatewayFiles.root.appendingPathComponent(
            "marine-chrome-generation"
        )
    }

    static func current() throws -> String {
        if let data = try? Data(contentsOf: url),
           let value = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           UUID(uuidString: value) != nil {
            return value
        }
        return try advance()
    }

    @discardableResult
    static func advance() throws -> String {
        let value = UUID().uuidString
        try Data(value.utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
        return value
    }
}

struct MarineChromeIssuedCredential: Equatable {
    let token: String
    let generation: String
}

/// Linearizes browser credential issuance and CLI reset across helper and live
/// IME processes. A claim freezes the current generation; reset advances it
/// before changing token/origin, so pre-reset approvals can no longer issue.
enum MarineChromeCredentialTransaction {
    private static let processLock = NSLock()

    static func currentGeneration() -> String? {
        try? locked { try MarineChromeCredentialGeneration.current() }
    }

    static func matchesGeneration(_ expected: String) -> Bool {
        (try? locked {
            try MarineChromeCredentialGeneration.current() == expected
        }) ?? false
    }

    static func issue(origin: String,
                      expectedGeneration: String) -> MarineChromeIssuedCredential? {
        try? locked {
            guard try MarineChromeCredentialGeneration.current()
                    == expectedGeneration else {
                return nil
            }
            // Keep credential locks in the same token -> origin order used by
            // reset and authenticated requests to avoid an in-process inversion.
            let token = try MarineChromeGatewayToken.regenerate()
            guard MarineChromePairingOrigin.approve(origin: origin),
                  try MarineChromeCredentialGeneration.current()
                    == expectedGeneration else { return nil }
            return MarineChromeIssuedCredential(
                token: token,
                generation: expectedGeneration
            )
        }
    }

    static func reset() throws -> String {
        try locked {
            _ = try MarineChromeCredentialGeneration.advance()
            do {
                let replacementToken = try MarineChromeGatewayToken.regenerate()
                MarineChromePairingOrigin.reset()
                return replacementToken
            } catch {
                // A reset must fail closed even if secure randomness or the
                // credential write becomes unavailable after generation moved.
                MarineChromeGatewayToken.invalidate()
                MarineChromePairingOrigin.reset()
                throw error
            }
        }
    }

    private static func locked<T>(_ body: () throws -> T) throws -> T {
        processLock.lock()
        defer { processLock.unlock() }
        return try MarineChromeCredentialFileLock.withLock(body)
    }
}

/// A capability token scoped to the browser-context routes. It is deliberately
/// separate from the MCP/HTTP inbox token stored by GatewayToken.
enum MarineChromeGatewayToken {
    private static let lock = NSLock()
    private static var url: URL {
        MarineChromeGatewayFiles.root.appendingPathComponent(
            "marine-chrome-token"
        )
    }

    static func current() throws -> String {
        lock.lock()
        defer { lock.unlock() }
        if let data = try? Data(contentsOf: url),
           let value = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           value.utf8.count == 43,
           value.utf8.allSatisfy({
               (48...57).contains(Int($0))
                   || (65...90).contains(Int($0))
                   || (97...122).contains(Int($0))
                   || $0 == 45 || $0 == 95
           }) {
            return value
        }
        return try regenerateLocked()
    }

    @discardableResult
    static func regenerate() throws -> String {
        lock.lock()
        defer { lock.unlock() }
        return try regenerateLocked()
    }

    static func matches(_ candidate: String) -> Bool {
        guard let expectedValue = try? current() else { return false }
        let expected = Data(expectedValue.utf8)
        let received = Data(candidate.utf8)
        guard expected.count == received.count else { return false }
        var difference: UInt8 = 0
        for index in expected.indices {
            difference |= expected[index] ^ received[index]
        }
        return difference == 0
    }

    static func invalidate() {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: url)
    }

    private static func regenerateLocked() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
                == errSecSuccess else {
            throw MarineChromeGatewayTokenError.randomnessUnavailable
        }
        let value = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        guard let data = value.data(using: .utf8) else {
            throw MarineChromeGatewayTokenError.encodingFailed
        }
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
        IMELog.write("marine-chrome gateway token generated")
        return value
    }
}

enum MarineChromeServerProofError: Error, Equatable {
    case invalidJSON
    case unsupportedVersion
    case invalidNonce
}

/// Proves that the loopback listener owns the same scoped credential that the
/// extension received during interactive pairing. The nonce is canonical
/// unpadded base64url for exactly 32 bytes; accepting alternate encodings would
/// make the signed transcript ambiguous across implementations.
enum MarineChromeServerProof {
    private struct Payload: Decodable {
        let protocolVersion: Int
        let nonce: String
    }

    private static let domain = "marine-chrome-server-v1"

    static func decodeRequest(_ data: Data) throws -> String {
        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: data)
        } catch {
            throw MarineChromeServerProofError.invalidJSON
        }
        guard payload.protocolVersion == MarineChromeProtocol.version else {
            throw MarineChromeServerProofError.unsupportedVersion
        }
        guard decodeNonce(payload.nonce) != nil else {
            throw MarineChromeServerProofError.invalidNonce
        }
        return payload.nonce
    }

    static func make(nonce: String) throws -> String {
        try make(nonce: nonce, token: MarineChromeGatewayToken.current())
    }

    static func make(nonce: String, token: String) throws -> String {
        guard decodeNonce(nonce) != nil else {
            throw MarineChromeServerProofError.invalidNonce
        }
        let message = Data("\(domain)\n\(nonce)".utf8)
        let key = SymmetricKey(data: Data(token.utf8))
        let authenticationCode = HMAC<SHA256>.authenticationCode(
            for: message,
            using: key
        )
        return encodeBase64URL(Data(authenticationCode))
    }

    static func decodeNonce(_ value: String) -> Data? {
        guard value.utf8.count == 43,
              value.utf8.allSatisfy({
                  (48...57).contains(Int($0))
                      || (65...90).contains(Int($0))
                      || (97...122).contains(Int($0))
                      || $0 == 45 || $0 == 95
              }) else {
            return nil
        }
        let standard = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/") + "="
        guard let decoded = Data(base64Encoded: standard),
              decoded.count == 32,
              encodeBase64URL(decoded) == value else {
            return nil
        }
        return decoded
    }

    private static func encodeBase64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

enum MarineChromeExtensionOrigin {
    static func normalized(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let origin = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard let components = URLComponents(string: origin),
              components.scheme == "chrome-extension",
              let identifier = components.host,
              identifier.utf8.count == 32,
              identifier.utf8.allSatisfy({ (97...112).contains(Int($0)) }),
              components.port == nil,
              components.user == nil,
              components.password == nil,
              components.path.isEmpty,
              components.query == nil,
              components.fragment == nil,
              origin == "chrome-extension://\(identifier)" else {
            return nil
        }
        return origin
    }
}

/// `manifest.key` keeps the unpacked companion on one Chrome origin. The key
/// itself is public and is not treated as authentication; it only narrows the
/// browser-facing surface before the interactive claim is approved.
enum MarineChromeExtensionIdentity {
    static let identifier = "gpieknckmapliabifhgcedcjoigdjaah"
    static let origin = "chrome-extension://\(identifier)"

    static func matches(origin rawOrigin: String?) -> Bool {
        MarineChromeExtensionOrigin.normalized(rawOrigin) == origin
    }
}

enum MarineChromePairingClaimError: Error, Equatable {
    case invalidJSON
    case unsupportedVersion
    case invalidIdentity
    case invalidClaim
}

struct MarineChromePairingClaim: Equatable {
    let requestID: UUID
    let claimSecret: String
    let displayCode: String
    let origin: String
    let force: Bool

    private struct Payload: Decodable {
        let protocolVersion: Int
        let extensionId: String
        let requestId: String
        let claimSecret: String
        let displayCode: String
        let force: Bool?
    }

    static func decode(_ data: Data,
                       origin rawOrigin: String?) throws -> Self {
        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: data)
        } catch {
            throw MarineChromePairingClaimError.invalidJSON
        }
        guard payload.protocolVersion == MarineChromeProtocol.version else {
            throw MarineChromePairingClaimError.unsupportedVersion
        }
        guard payload.extensionId == MarineChromeExtensionIdentity.identifier,
              MarineChromeExtensionIdentity.matches(origin: rawOrigin),
              let origin = MarineChromeExtensionOrigin.normalized(rawOrigin)
        else {
            throw MarineChromePairingClaimError.invalidIdentity
        }
        guard let requestID = UUID(uuidString: payload.requestId),
              validSecret(payload.claimSecret),
              validDisplayCode(payload.displayCode) else {
            throw MarineChromePairingClaimError.invalidClaim
        }
        return Self(requestID: requestID,
                    claimSecret: payload.claimSecret,
                    displayCode: payload.displayCode,
                    origin: origin,
                    force: payload.force ?? false)
    }

    private static func validSecret(_ value: String) -> Bool {
        value.utf8.count == 43 && value.utf8.allSatisfy {
            (48...57).contains(Int($0))
                || (65...90).contains(Int($0))
                || (97...122).contains(Int($0))
                || $0 == 45 || $0 == 95
        }
    }

    private static func validDisplayCode(_ value: String) -> Bool {
        value.utf8.count == 6 && value.utf8.allSatisfy {
            (50...57).contains(Int($0))
                || (65...72).contains(Int($0))
                || (74...78).contains(Int($0))
                || (80...90).contains(Int($0))
        }
    }
}

/// In-memory, short-lived interactive claim broker. A spoofed HTTP Origin is
/// not enough to receive the credential: RIMES must approve the exact request,
/// and the caller must keep proving possession of its 256-bit claim secret.
final class MarineChromePairingBroker {
    struct ApprovalRequest: Equatable {
        let requestID: UUID
        let displayCode: String
    }

    typealias ApprovalResponder = (Bool) -> Void
    typealias ApprovalHandler = (
        _ request: ApprovalRequest,
        _ respond: @escaping ApprovalResponder
    ) -> Void

    enum Outcome: Equatable {
        case pending(expiresAt: TimeInterval)
        case issued(token: String, expiresAt: TimeInterval)
        case denied
        case expired
        case busy(retryAfter: TimeInterval)
        case failed
    }

    private enum State {
        case pending
        case approved
        case issuing
        case issued(String)
    }

    private enum TerminalState {
        case denied
        case expired
        case failed

        var outcome: Outcome {
            switch self {
            case .denied: return .denied
            case .expired: return .expired
            case .failed: return .failed
            }
        }
    }

    private struct Session {
        let claim: MarineChromePairingClaim
        let credentialGeneration: String
        let expiresAt: TimeInterval
        var state: State
    }

    static let shared = MarineChromePairingBroker(
        currentGeneration: {
            MarineChromeGatewayAvailability.shared
                .optionalValueIfAvailable {
                    MarineChromeCredentialTransaction.currentGeneration()
                }
        },
        generationMatches: { expected in
            MarineChromeGatewayAvailability.shared.valueIfAvailable {
                MarineChromeCredentialTransaction.matchesGeneration(expected)
            } ?? false
        },
        issueCredential: { origin, generation in
            // The gateway checks before submitting/polling a claim, and the
            // approval UI checks again before presentation. Holding the same
            // gate here closes the last race before credential persistence.
            guard let credential = MarineChromeGatewayAvailability.shared
                .optionalValueIfAvailable({
                    MarineChromeCredentialTransaction.issue(
                        origin: origin,
                        expectedGeneration: generation
                    )
                }) else { return nil }
            DispatchQueue.main.async {
                MarineChromeContextStore.shared.clear()
            }
            return credential
        }
    )

    private let lock = NSLock()
    private let now: () -> TimeInterval
    private let lifetime: TimeInterval
    private let cooldown: TimeInterval
    private let currentGeneration: () -> String?
    private let generationMatches: (String) -> Bool
    private let issueCredential: (String, String) -> MarineChromeIssuedCredential?
    private var session: Session?
    // Never reuse a request UUID during this process lifetime. In particular,
    // an expired or denied HTTP body cannot later open a fresh approval panel.
    private var terminalRequests: [UUID: TerminalState] = [:]
    private var blockedUntil: TimeInterval = 0
    private var approvalHandler: ApprovalHandler?
    private var cancellationHandler: ((UUID) -> Void)?

    init(lifetime: TimeInterval = 60,
         cooldown: TimeInterval = 10,
         now: @escaping () -> TimeInterval = {
             Date().timeIntervalSince1970
         },
         currentGeneration: @escaping () -> String? = {
             MarineChromeCredentialTransaction.currentGeneration()
         },
         generationMatches: @escaping (String) -> Bool = {
             MarineChromeCredentialTransaction.matchesGeneration($0)
         },
         issueCredential: @escaping (
             String,
             String
         ) -> MarineChromeIssuedCredential?) {
        self.lifetime = lifetime
        self.cooldown = cooldown
        self.now = now
        self.currentGeneration = currentGeneration
        self.generationMatches = generationMatches
        self.issueCredential = issueCredential
    }

    func setApprovalHandler(
        _ handler: @escaping ApprovalHandler
    ) {
        lock.lock()
        approvalHandler = handler
        lock.unlock()
    }

    func setCancellationHandler(_ handler: @escaping (UUID) -> Void) {
        lock.lock()
        cancellationHandler = handler
        lock.unlock()
    }

    /// Invalidates the live prompt and every not-yet-expired retry response.
    /// Used when the gateway stops and when another process resets credentials.
    func cancelAll() {
        let requestID: UUID?
        let handler: ((UUID) -> Void)?
        lock.lock()
        if let active = session {
            requestID = active.claim.requestID
            terminalRequests[active.claim.requestID] = .expired
            session = nil
            blockedUntil = max(blockedUntil, now() + cooldown)
            handler = cancellationHandler
        } else {
            requestID = nil
            handler = nil
        }
        lock.unlock()
        if let requestID { handler?(requestID) }
    }

    func submit(_ claim: MarineChromePairingClaim) -> Outcome {
        let instant = now()

        lock.lock()
        if let terminal = terminalRequests[claim.requestID] {
            lock.unlock()
            return terminal.outcome
        }
        if let active = session, instant >= active.expiresAt {
            let wasSameClaim = matches(active.claim, claim)
            terminalRequests[active.claim.requestID] = .expired
            session = nil
            blockedUntil = max(blockedUntil, instant + cooldown)
            let handler = cancellationHandler
            let requestID = active.claim.requestID
            lock.unlock()
            handler?(requestID)
            return wasSameClaim
                ? .expired
                : .busy(retryAfter: blockedUntil)
        }
        if let active = session,
           !generationMatches(active.credentialGeneration) {
            terminalRequests[active.claim.requestID] = .expired
            session = nil
            blockedUntil = max(blockedUntil, instant + cooldown)
            let handler = cancellationHandler
            let requestID = active.claim.requestID
            lock.unlock()
            handler?(requestID)
            return matches(active.claim, claim)
                ? .expired
                : .busy(retryAfter: blockedUntil)
        }
        if var active = session {
            guard matches(active.claim, claim) else {
                let retryAfter = active.expiresAt
                lock.unlock()
                return .busy(retryAfter: retryAfter)
            }
            switch active.state {
            case .pending, .issuing:
                let expiresAt = active.expiresAt
                lock.unlock()
                return .pending(expiresAt: expiresAt)
            case .issued(let token):
                let expiresAt = active.expiresAt
                lock.unlock()
                return .issued(token: token, expiresAt: expiresAt)
            case .approved:
                active.state = .issuing
                session = active
                let generation = active.credentialGeneration
                lock.unlock()
                let credential = issueCredential(claim.origin, generation)
                lock.lock()
                guard var current = session,
                      matches(current.claim, claim),
                      case .issuing = current.state else {
                    let outcome = terminalRequests[claim.requestID]?.outcome
                        ?? .failed
                    lock.unlock()
                    return outcome
                }
                guard generationMatches(current.credentialGeneration) else {
                    terminalRequests[claim.requestID] = .expired
                    session = nil
                    blockedUntil = max(blockedUntil, now() + cooldown)
                    lock.unlock()
                    return .expired
                }
                guard let credential,
                      credential.generation == current.credentialGeneration else {
                    terminalRequests[claim.requestID] = .failed
                    session = nil
                    blockedUntil = max(blockedUntil, now() + cooldown)
                    lock.unlock()
                    return .failed
                }
                current.state = .issued(credential.token)
                session = current
                let expiresAt = current.expiresAt
                lock.unlock()
                return .issued(token: credential.token, expiresAt: expiresAt)
            }
        }
        guard instant >= blockedUntil else {
            let retryAfter = blockedUntil
            lock.unlock()
            return .busy(retryAfter: retryAfter)
        }
        guard let handler = approvalHandler,
              let generation = currentGeneration() else {
            terminalRequests[claim.requestID] = .failed
            blockedUntil = max(blockedUntil, instant + cooldown)
            lock.unlock()
            return .failed
        }
        let expiresAt = instant + lifetime
        session = Session(claim: claim,
                          credentialGeneration: generation,
                          expiresAt: expiresAt,
                          state: .pending)
        let prompt = ApprovalRequest(requestID: claim.requestID,
                                     displayCode: claim.displayCode)
        lock.unlock()

        DispatchQueue.main.async { [weak self] in
            guard self?.mayPresent(
                requestID: claim.requestID,
                claimSecret: claim.claimSecret
            ) == true else { return }
            handler(prompt) { approved in
                self?.resolve(requestID: claim.requestID,
                              claimSecret: claim.claimSecret,
                              approved: approved)
            }
        }
        return .pending(expiresAt: expiresAt)
    }

    private func mayPresent(requestID: UUID,
                            claimSecret: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let active = session,
              active.claim.requestID == requestID,
              constantTimeEqual(active.claim.claimSecret, claimSecret),
              case .pending = active.state,
              now() < active.expiresAt,
              generationMatches(active.credentialGeneration) else {
            return false
        }
        return true
    }

    private func resolve(requestID: UUID,
                         claimSecret: String,
                         approved: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard var active = session,
              active.claim.requestID == requestID,
              constantTimeEqual(active.claim.claimSecret, claimSecret),
              case .pending = active.state else { return }
        guard now() < active.expiresAt,
              generationMatches(active.credentialGeneration) else {
            terminalRequests[requestID] = .expired
            session = nil
            blockedUntil = max(blockedUntil, now() + cooldown)
            return
        }
        if approved {
            active.state = .approved
            session = active
        } else {
            terminalRequests[requestID] = .denied
            session = nil
            blockedUntil = max(blockedUntil, now() + cooldown)
        }
    }

    private func matches(_ lhs: MarineChromePairingClaim,
                         _ rhs: MarineChromePairingClaim) -> Bool {
        lhs.requestID == rhs.requestID
            && lhs.origin == rhs.origin
            && lhs.displayCode == rhs.displayCode
            && lhs.force == rhs.force
            && constantTimeEqual(lhs.claimSecret, rhs.claimSecret)
    }

    private func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let left = Data(lhs.utf8)
        let right = Data(rhs.utf8)
        guard left.count == right.count else { return false }
        var difference: UInt8 = 0
        for index in left.indices {
            difference |= left[index] ^ right[index]
        }
        return difference == 0
    }
}

enum MarineChromeGatewayRoutePolicy {
    private static let methodsByPath: [String: Set<String>] = [
        "/v1/marine-chrome/health": ["GET"],
        "/v1/marine-chrome/prove": ["PUT"],
        "/v1/marine-chrome/pair/request": ["PUT"],
        "/v1/marine-chrome/pair": ["PUT"],
        "/v1/marine-chrome/context": ["PUT", "DELETE"],
        "/v1/marine-chrome/heartbeat": ["PUT"],
    ]

    static func allowedMethods(for path: String) -> Set<String>? {
        methodsByPath[path]
    }

    /// The public health probe is deliberately inert and may stay reachable so
    /// the companion can diagnose that RIMES is running. Every route capable of
    /// proving, pairing, authenticating, or mutating context is fail-closed
    /// while the optional plug-in is absent or disabled.
    static func permitsPluginAvailability(path: String,
                                          isAvailable: Bool) -> Bool {
        path == "/v1/marine-chrome/health" || isAvailable
    }

    static func allows(method: String, path: String) -> Bool {
        methodsByPath[path]?.contains(method.uppercased()) == true
    }

    static func allowsPreflight(path: String,
                                requestedMethod: String?,
                                requestedHeaders: Set<String>) -> Bool {
        guard let requestedMethod,
              allows(method: requestedMethod, path: path) else { return false }
        return requestedHeaders.isSubset(of: [
            "authorization",
            "content-type",
        ])
    }

    static func requiresJSON(method: String) -> Bool {
        let normalized = method.uppercased()
        return normalized == "PUT" || normalized == "DELETE"
    }
}

/// An approved interactive claim pins the stable Chrome origin and rotates the
/// credential. The manual diagnostic path may also pin that same fixed origin
/// after a successful token check. Later requests and preflights must match it.
enum MarineChromePairingOrigin {
    private static let lock = NSLock()
    private static var url: URL {
        MarineChromeGatewayFiles.root.appendingPathComponent(
            "marine-chrome-origin"
        )
    }

    static func current() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return currentLocked()
    }

    static func permitsPreflight(_ rawOrigin: String?, path: String) -> Bool {
        guard let origin = MarineChromeExtensionOrigin.normalized(rawOrigin) else {
            return false
        }
        if path == "/v1/marine-chrome/pair/request"
            || path == "/v1/marine-chrome/prove" {
            return MarineChromeExtensionIdentity.matches(origin: origin)
        }
        lock.lock()
        defer { lock.unlock() }
        return currentLocked().map { $0 == origin }
            ?? MarineChromeExtensionIdentity.matches(origin: origin)
    }

    static func authenticateAndPair(origin rawOrigin: String?,
                                    bearerToken: String) -> Bool {
        guard MarineChromeGatewayToken.matches(bearerToken),
              MarineChromeExtensionIdentity.matches(origin: rawOrigin),
              let origin = MarineChromeExtensionOrigin.normalized(rawOrigin) else {
            return false
        }
        lock.lock()
        defer { lock.unlock() }
        if let current = currentLocked() {
            return current == origin
                && MarineChromeGatewayToken.matches(bearerToken)
        }
        do {
            try Data(origin.utf8).write(to: url, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
            // A reset can rotate the token from a short-lived helper process
            // while this request is between its first check and the origin
            // write. Recheck after the write so an old extension cannot pin
            // itself again with a token that has just been retired.
            guard MarineChromeGatewayToken.matches(bearerToken) else {
                if currentLocked() == origin {
                    try? FileManager.default.removeItem(at: url)
                }
                return false
            }
            IMELog.write("marine-chrome extension origin paired")
            notifyPairingDidChange()
            return true
        } catch {
            IMELog.write("marine-chrome extension origin pairing failed")
            return false
        }
    }

    static func approve(origin rawOrigin: String?) -> Bool {
        guard MarineChromeExtensionIdentity.matches(origin: rawOrigin),
              let origin = MarineChromeExtensionOrigin.normalized(rawOrigin) else {
            return false
        }
        lock.lock()
        defer { lock.unlock() }
        do {
            try Data(origin.utf8).write(to: url, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
            IMELog.write("marine-chrome extension origin approved")
            notifyPairingDidChange()
            return true
        } catch {
            IMELog.write("marine-chrome extension origin approval failed")
            return false
        }
    }

    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: url)
        IMELog.write("marine-chrome extension origin pairing reset")
        notifyPairingDidChange()
    }

    private static func notifyPairingDidChange() {
        // Origin mutations happen while the credential lock is held. Publish
        // asynchronously so UI observers may call current() without inverting
        // that lock or blocking the gateway request.
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .marineChromePairingDidChange,
                object: nil
            )
        }
    }

    private static func currentLocked() -> String? {
        guard let data = try? Data(contentsOf: url),
              let value = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              let origin = MarineChromeExtensionOrigin.normalized(value) else {
            return nil
        }
        return origin
    }
}
