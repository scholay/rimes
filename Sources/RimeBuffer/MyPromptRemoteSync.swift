import CryptoKit
import Foundation

struct MyPromptRemoteRepositorySnapshot: Equatable {
    let repositoryURL: URL
    let checkoutURL: URL
    let sourceID: String
    let displayName: String
}

struct MyPromptRemoteSyncResult {
    let snapshots: [MyPromptRemoteRepositorySnapshot]
    let failedCount: Int
}

/// User-configured, credential-free HTTPS repositories are synchronized into
/// private, host-owned
/// checkouts. Search never calls this type: the importer indexes each completed
/// checkout and every keystroke subsequently stays inside local SQLite.
final class MyPromptRemoteRepositorySynchronizer {
    private let fileManager: FileManager
    private let runner: any AITextCLIProcessRunning
    private let inheritedEnvironment: [String: String]

    init(fileManager: FileManager = .default,
         runner: any AITextCLIProcessRunning =
            AITextFoundationCLIProcessRunner(),
         inheritedEnvironment: [String: String] =
            ProcessInfo.processInfo.environment) {
        self.fileManager = fileManager
        self.runner = runner
        self.inheritedEnvironment = inheritedEnvironment
    }

    func synchronize(
        repositories: [URL],
        checkoutsRoot: URL
    ) -> MyPromptRemoteSyncResult {
        guard preparePrivateDirectory(
                checkoutsRoot.deletingLastPathComponent()
              ),
              preparePrivateDirectory(checkoutsRoot) else {
            return MyPromptRemoteSyncResult(
                snapshots: [],
                failedCount: repositories.count
            )
        }
        var snapshots: [MyPromptRemoteRepositorySnapshot] = []
        var failedCount = 0
        for repository in repositories {
            guard let snapshot = synchronize(
                repository,
                checkoutsRoot: checkoutsRoot
            ) else {
                failedCount += 1
                continue
            }
            snapshots.append(snapshot)
        }
        return MyPromptRemoteSyncResult(
            snapshots: snapshots,
            failedCount: failedCount
        )
    }

    private func synchronize(
        _ repository: URL,
        checkoutsRoot: URL
    ) -> MyPromptRemoteRepositorySnapshot? {
        guard Self.isSafeHTTPSRepositoryURL(repository) else { return nil }
        let identity = Self.identity(for: repository)
        let checkout = checkoutsRoot.appendingPathComponent(
            identity,
            isDirectory: true
        )
        if fileManager.fileExists(atPath: checkout.path) {
            // These directories are private, product-owned cache snapshots.
            // A depth-one fetch often has no common ancestor object with the
            // previous shallow tip, so `merge --ff-only FETCH_HEAD` falsely
            // reports unrelated histories. Re-point the disposable worktree
            // at the newly fetched, already origin-validated snapshot instead.
            guard isOrdinaryDirectory(checkout),
                  currentOrigin(of: checkout) == repository.absoluteString,
                  git(
                    ["-C", checkout.path, "fetch", "--depth", "1",
                     "--no-tags", "origin"],
                    currentDirectory: checkoutsRoot
                  )?.terminationStatus == 0,
                  git(
                    [
                        "-C", checkout.path,
                        "reset", "--hard", "FETCH_HEAD",
                    ],
                    currentDirectory: checkoutsRoot
                  )?.terminationStatus == 0 else {
                return nil
            }
        } else {
            let incoming = checkoutsRoot.appendingPathComponent(
                ".incoming-\(identity)-\(UUID().uuidString.lowercased())",
                isDirectory: true
            )
            defer {
                if fileManager.fileExists(atPath: incoming.path) {
                    try? fileManager.removeItem(at: incoming)
                }
            }
            guard git(
                ["clone", "--depth", "1", "--single-branch", "--no-tags",
                 repository.absoluteString, incoming.path],
                currentDirectory: checkoutsRoot,
                timeout: 180
            )?.terminationStatus == 0,
                  isOrdinaryDirectory(incoming) else {
                return nil
            }
            do {
                try fileManager.moveItem(at: incoming, to: checkout)
                guard chmod(checkout.path, S_IRWXU) == 0 else { return nil }
            } catch {
                return nil
            }
        }
        return MyPromptRemoteRepositorySnapshot(
            repositoryURL: repository,
            checkoutURL: checkout,
            sourceID: "git:\(identity)",
            displayName: Self.displayName(for: repository)
        )
    }

    private func currentOrigin(of checkout: URL) -> String? {
        guard let result = git(
            ["-C", checkout.path, "remote", "get-url", "origin"],
            currentDirectory: checkout
        ), result.terminationStatus == 0,
           !result.outputTooLarge,
           !result.timedOut,
           let value = String(data: result.standardOutput, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           let url = URL(string: value),
           Self.isSafeHTTPSRepositoryURL(url) else {
            return nil
        }
        return url.absoluteString
    }

    private func git(
        _ arguments: [String],
        currentDirectory: URL,
        timeout: TimeInterval = 90
    ) -> AITextCLIProcessResult? {
        let executable = URL(fileURLWithPath: "/usr/bin/git")
        guard fileManager.isExecutableFile(atPath: executable.path) else {
            return nil
        }
        var environment = inheritedEnvironment
        for key in environment.keys
        where key.hasPrefix("GIT_") || key.hasPrefix("SSH_") {
            environment.removeValue(forKey: key)
        }
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_CONFIG_SYSTEM"] = "/dev/null"
        environment["GIT_CONFIG_COUNT"] = "3"
        environment["GIT_CONFIG_KEY_0"] = "protocol.file.allow"
        environment["GIT_CONFIG_VALUE_0"] = "never"
        environment["GIT_CONFIG_KEY_1"] = "protocol.ext.allow"
        environment["GIT_CONFIG_VALUE_1"] = "never"
        environment["GIT_CONFIG_KEY_2"] = "core.hooksPath"
        environment["GIT_CONFIG_VALUE_2"] = "/dev/null"

        let semaphore = DispatchSemaphore(value: 0)
        var captured: AITextCLIProcessResult?
        _ = runner.run(
            AITextCLIProcessSpec(
                executableURL: executable,
                arguments: arguments,
                standardInput: Data(),
                currentDirectoryURL: currentDirectory,
                environment: environment,
                timeout: timeout,
                maximumOutputBytes: 16 * 1_024,
                maximumStandardErrorBytes: 2 * 1_024
            ),
            onStandardOutput: { _ in },
            completion: {
                captured = $0
                semaphore.signal()
            }
        )
        guard semaphore.wait(
            timeout: .now() + timeout + 5
        ) == .success else {
            return nil
        }
        guard let captured,
              !captured.timedOut,
              !captured.cancelled,
              !captured.outputTooLarge else {
            return nil
        }
        return captured
    }

    private func preparePrivateDirectory(_ url: URL) -> Bool {
        do {
            if fileManager.fileExists(atPath: url.path) {
                guard isOrdinaryDirectory(url) else { return false }
            } else {
                try fileManager.createDirectory(
                    at: url,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            }
            return chmod(url.path, S_IRWXU) == 0
        } catch {
            return false
        }
    }

    private func isOrdinaryDirectory(_ url: URL) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return false }
        return info.st_mode & S_IFMT == S_IFDIR
    }

    private static func isSafeHTTPSRepositoryURL(_ url: URL) -> Bool {
        guard let components = URLComponents(
                url: url,
                resolvingAgainstBaseURL: false
              ),
              components.scheme?.lowercased() == "https",
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              let host = components.host,
              !host.isEmpty else {
            return false
        }
        return true
    }

    private static func identity(for repository: URL) -> String {
        let digest = SHA256.hash(data: Data(repository.absoluteString.utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    private static func displayName(for repository: URL) -> String {
        let component = repository
            .deletingPathExtension()
            .lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return component.isEmpty ? repository.host ?? "Remote prompts" : component
    }
}
