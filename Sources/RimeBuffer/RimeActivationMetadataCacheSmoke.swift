import Foundation

@discardableResult
func runRimeActivationMetadataCacheSmokeTest() -> Bool {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(
        "rimebuffer-activation-cache-smoke-\(UUID().uuidString)",
        isDirectory: true
    )
    defer { try? fileManager.removeItem(at: root) }

    func fail(_ reason: String) -> Bool {
        print("activation-cache-smoke: FAIL \(reason)")
        return false
    }

    do {
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let watched = root.appendingPathComponent("deployed.yaml")
        try "version: one\n".write(to: watched, atomically: false, encoding: .utf8)

        var cache = RimeFileBackedValueCache<String>()
        guard case .miss(.cold) = cache.lookup(scope: ["alpha"]) else {
            return fail("cold lookup")
        }
        cache.store("one", scope: ["alpha"], watching: [watched])
        guard case .hit("one") = cache.lookup(scope: ["alpha"]) else {
            return fail("warm hit")
        }

        // Non-atomic content changes must invalidate even when the path stays
        // stable; size and nanosecond mtime/ctime are part of the stamp.
        try "version: content-changed\n".write(
            to: watched,
            atomically: false,
            encoding: .utf8
        )
        guard case .miss(.filesChanged) = cache.lookup(scope: ["alpha"]) else {
            return fail("content change invalidation")
        }
        cache.store("two", scope: ["alpha"], watching: [watched])
        guard case .hit("two") = cache.lookup(scope: ["alpha"]) else {
            return fail("reload after content change")
        }

        // Atomic config/deploy writers replace the inode. The fingerprint must
        // notice that replacement even if a writer preserves similar metadata.
        try Data("version: atomic-replacement\n".utf8).write(
            to: watched,
            options: .atomic
        )
        guard case .miss(.filesChanged) = cache.lookup(scope: ["alpha"]) else {
            return fail("atomic replacement invalidation")
        }
        cache.store("three", scope: ["alpha"], watching: [watched])

        guard case .miss(.scopeChanged) = cache.lookup(scope: ["beta"]) else {
            return fail("scope change invalidation")
        }
        cache.store("four", scope: ["beta"], watching: [watched])
        guard cache.invalidate(),
              case .miss(.explicitInvalidation) = cache.lookup(scope: ["beta"]) else {
            return fail("explicit invalidation")
        }

        // A writer can replace a config after the caller reads it but before
        // cache publication. The pre-load stamp must reject that stale value;
        // otherwise it would be bound to the replacement's metadata forever.
        var racingCache = RimeFileBackedValueCache<String>()
        let beforeRace = racingCache.captureStamps(for: [watched])
        try Data("version: raced-replacement\n".utf8).write(
            to: watched,
            options: .atomic
        )
        guard !racingCache.store(
                "stale",
                scope: ["race"],
                watching: [watched],
                expectedStamps: beforeRace
              ),
              case .miss(.filesChanged) = racingCache.lookup(scope: ["race"])
        else {
            return fail("read-to-store race rejection")
        }

        let metrics = cache.diagnostics
        guard metrics.hits == 2,
              metrics.misses == 5,
              metrics.loads == 4,
              metrics.invalidations == 4 else {
            return fail("diagnostics \(metrics)")
        }

        let highPriority = root.appendingPathComponent("build/squirrel.yaml")
        let lowPriority = root.appendingPathComponent("squirrel.yaml")
        try fileManager.createDirectory(
            at: highPriority.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "keyboard_layout: last\n".write(
            to: lowPriority,
            atomically: false,
            encoding: .utf8
        )

        let keyboardCache = RimeKeyboardLayoutOverrideCache()
        let first = keyboardCache.resolve(candidates: [highPriority, lowPriority])
        let second = keyboardCache.resolve(candidates: [highPriority, lowPriority])
        guard first.layout == nil,
              first.source == lowPriority.path,
              first.cacheStatus == .coldLoad,
              second == RimeKeyboardLayoutOverrideResolution(
                layout: nil,
                source: lowPriority.path,
                cacheStatus: .hit
              ) else {
            return fail("keyboard-layout warm cache")
        }

        // Creating a previously-missing higher-priority config must displace
        // the cached lower-priority winner immediately.
        try "keyboard_layout: default\n".write(
            to: highPriority,
            atomically: false,
            encoding: .utf8
        )
        let promoted = keyboardCache.resolve(candidates: [highPriority, lowPriority])
        guard promoted.layout == "com.apple.keylayout.ABC",
              promoted.source == highPriority.path,
              promoted.cacheStatus == .fileChange else {
            return fail("keyboard-layout precedence invalidation")
        }

        print(
            "activation-cache-smoke: PASS "
                + "hits=\(metrics.hits) invalidations=\(metrics.invalidations) "
                + "keyboardHits=\(keyboardCache.diagnostics.hits)"
        )
        return true
    } catch {
        return fail(error.localizedDescription)
    }
}

#if RIME_ACTIVATION_CACHE_SMOKE_MAIN
@main
private enum RimeActivationMetadataCacheSmokeMain {
    static func main() {
        exit(runRimeActivationMetadataCacheSmokeTest() ? 0 : 1)
    }
}
#endif
