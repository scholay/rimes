import Foundation

/// Builds the environment a spawned codex gets.
///
/// This exists because of a failure that is invisible until it happens: the
/// homebrew `codex` is a `#!/usr/bin/env node` script, and an input method
/// launched by launchd at login inherits `/usr/bin:/bin:/usr/sbin:/sbin` —
/// no homebrew, no node. Codex then exits 127 with `env: node: No such file
/// or directory` before printing anything, which in a terminal pane looks
/// like the terminal is broken rather than like a missing interpreter.
///
/// Verifying by hand proves nothing here: a build installed from a shell
/// inherits that shell's PATH and works, while the same build launched at
/// login does not.
enum CodexProcessEnvironment {
    /// Locations a user's toolchain actually lives in, ordered ahead of the
    /// system directories so a homebrew node wins over an older one.
    static let toolchainDirectories = [
        "/opt/homebrew/bin",
        "/opt/homebrew/sbin",
        "/usr/local/bin",
        "/usr/bin",
        "/bin",
        "/usr/sbin",
        "/sbin",
    ]

    /// Union of the inherited PATH, the interpreter directories, and the
    /// directory codex itself was found in — de-duplicated, order preserved.
    /// Nothing is removed: a user who put a toolchain on their PATH meant it.
    static func searchPath(inherited: String?,
                           executable: URL?,
                           homeDirectory: URL) -> String {
        var seen = Set<String>()
        var ordered: [String] = []
        func add(_ directory: String) {
            let trimmed = directory.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !seen.contains(trimmed) else { return }
            seen.insert(trimmed)
            ordered.append(trimmed)
        }
        if let executable {
            add(executable.deletingLastPathComponent().path)
        }
        (inherited ?? "").split(separator: ":", omittingEmptySubsequences: true)
            .forEach { add(String($0)) }
        toolchainDirectories.forEach(add)
        add(homeDirectory.appendingPathComponent(".local/bin").path)
        add(homeDirectory.appendingPathComponent(".bun/bin").path)
        add(homeDirectory.appendingPathComponent(".cargo/bin").path)
        return ordered.joined(separator: ":")
    }

    /// `KEY=value` pairs for `startProcess`. `base` carries SwiftTerm's own
    /// terminal variables; anything this adds overrides a same-named entry so
    /// the child never sees the key twice.
    static func variables(base: [String],
                          inheritedPath: String?,
                          executable: URL?,
                          workspace: URL,
                          homeDirectory: URL,
                          shell: String?) -> [String] {
        var overrides: [String: String] = [
            "PATH": searchPath(inherited: inheritedPath,
                               executable: executable,
                               homeDirectory: homeDirectory),
            "HOME": homeDirectory.path,
            "PWD": workspace.path,
        ]
        if let shell, !shell.isEmpty { overrides["SHELL"] = shell }
        var result = base.filter { entry in
            guard let separator = entry.firstIndex(of: "=") else { return true }
            return !overrides.keys.contains(String(entry[entry.startIndex..<separator]))
        }
        result += overrides.keys.sorted().map { "\($0)=\(overrides[$0]!)" }
        return result
    }
}
