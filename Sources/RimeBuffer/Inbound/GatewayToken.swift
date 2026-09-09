import Foundation
import CryptoKit

/// Bearer token for the local gateway, stored 0600 at ~/Library/RimeBuffer/
/// gateway-token. Not in the Keychain — ad-hoc signing makes Keychain ACLs
/// re-prompt on every rebuild. The token only guards against OTHER users / the
/// network; a same-user process in the trust domain can read the file, which is
/// the documented threat model.
enum GatewayToken {
    private static var url: URL {
        let dir = ProcessInfo.processInfo.environment["RIMEBUFFER_USER_DIR"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        } ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/\(RimesPaths.directoryName)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("gateway-token")
    }

    /// The current token, generated (0600) on first use.
    static func current() -> String {
        if let data = try? Data(contentsOf: url),
           let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !s.isEmpty {
            return s
        }
        return regenerate()
    }

    @discardableResult
    static func regenerate() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let token = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        try? token.data(using: .utf8)?.write(to: url)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        IMELog.write("gateway token generated")
        return token
    }

    /// Constant-time compare so a bad token can't be guessed by timing.
    static func matches(_ candidate: String) -> Bool {
        let a = Data(current().utf8), b = Data(candidate.utf8)
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<a.count { diff |= a[i] ^ b[i] }
        return diff == 0
    }
}
