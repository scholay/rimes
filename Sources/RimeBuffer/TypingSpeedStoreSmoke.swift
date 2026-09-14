import Foundation

/// Executable coverage for the aggregate typing-speed model. `main.swift` may
/// wire this function to a smoke argument; the test itself never needs an IMK
/// client, focus object, settings window or committed text.
func runTypingSpeedStoreSmokeTest() -> Bool {
    func fail(_ message: String) -> Bool {
        print("FAILED: typing speed store \(message)")
        return false
    }

    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(
        "rimebuffer-typing-speed-smoke-\(UUID().uuidString.lowercased())",
        isDirectory: true
    )

    do {
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        guard let firstDay = calendar.date(from: DateComponents(
            year: 2026, month: 7, day: 18, hour: 23, minute: 58, second: 40
        )) else {
            return fail("calendar fixture")
        }
        let firstTimestamp = firstDay.timeIntervalSince1970
        let store = TypingSpeedStore(storageRoot: root,
                                     autosaveDelay: 60,
                                     inactivityThreshold: 10)

        let privateKeyID = "private-key-token-must-not-persist"
        let privateSchemaID = "private-schema-token-must-not-persist"
        store.consume(.key(.init(keyID: privateKeyID,
                                 timestamp: firstTimestamp,
                                 isRepeat: false,
                                 modifierFlags: 0,
                                 schemaID: privateSchemaID)))
        store.consume(.commit(.init(characterCount: 4,
                                    timestamp: firstTimestamp + 5,
                                    source: .direct,
                                    schemaID: privateSchemaID)))
        store.consume(.chord(.init(rimeKeyCodes: [113, 121],
                                   timestamp: firstTimestamp + 10,
                                   duration: 0.08,
                                   handledReleaseCount: 2,
                                   schemaID: privateSchemaID)))

        let firstSnapshot = store.snapshot(for: firstDay)
        guard firstSnapshot.keyCount == 1,
              firstSnapshot.committedCharacterCount == 4,
              firstSnapshot.chordCount == 1,
              firstSnapshot.activeSeconds == 10,
              firstSnapshot.sessionCount == 1,
              firstSnapshot.keysPerMinute == 6,
              firstSnapshot.charactersPerMinute == 24 else {
            return fail("same-session aggregation")
        }

        let separated = TypingSpeedStore(storageRoot: root.appendingPathComponent("boundaries"),
                                         autosaveDelay: 60)
        separated.consume(.commit(.init(characterCount: 2, timestamp: firstTimestamp,
                                         source: .direct, schemaID: "smoke")))
        separated.consume(.commit(.init(characterCount: 2, timestamp: firstTimestamp + 2,
                                         source: .direct, schemaID: "smoke")))
        separated.endCurrentSession()
        separated.consume(.commit(.init(characterCount: 2, timestamp: firstTimestamp + 4,
                                         source: .direct, schemaID: "smoke")))
        guard separated.snapshot(for: firstDay).activeSeconds == 2,
              separated.snapshot(for: firstDay).sessionCount == 2 else {
            return fail("practice/disabled time bridged into daily active duration")
        }
        separated.saveNow()

        // More than the inactivity threshold creates another session without
        // adding idle time to either the session or its daily aggregate.
        store.consume(.key(.init(keyID: privateKeyID,
                                 timestamp: firstTimestamp + 21,
                                 isRepeat: false,
                                 modifierFlags: 0,
                                 schemaID: privateSchemaID)))
        let afterGap = store.snapshot(for: firstDay)
        guard afterGap.keyCount == 2,
              afterGap.activeSeconds == 10,
              afterGap.sessionCount == 2,
              store.historySnapshot().recentSessions.count == 2 else {
            return fail("inactivity session boundary")
        }

        // Repeats, host shortcuts, and pure navigation never inflate the
        // typing-speed aggregate or start phantom sessions.
        store.consume(.key(.init(keyID: privateKeyID,
                                 timestamp: firstTimestamp + 22,
                                 isRepeat: true,
                                 modifierFlags: 0,
                                 schemaID: privateSchemaID)))
        store.consume(.key(.init(keyID: "KeyC",
                                 timestamp: firstTimestamp + 23,
                                 isRepeat: false,
                                 modifierFlags: UInt(1) << 20,
                                 schemaID: privateSchemaID)))
        store.consume(.key(.init(keyID: "ArrowLeft",
                                 timestamp: firstTimestamp + 24,
                                 isRepeat: false,
                                 modifierFlags: 0,
                                 schemaID: privateSchemaID)))
        store.consume(.commit(.init(characterCount: -1,
                                    timestamp: firstTimestamp + 25,
                                    source: .direct,
                                    schemaID: privateSchemaID)))
        store.consume(.chord(.init(rimeKeyCodes: [113],
                                   timestamp: .nan,
                                   duration: 0.08,
                                   handledReleaseCount: 1,
                                   schemaID: privateSchemaID)))
        guard store.snapshot(for: firstDay) == afterGap,
              store.historySnapshot().recentSessions.count == 2 else {
            return fail("non-typing key filtering")
        }

        // A new local calendar day is always a new session, even when the
        // elapsed wall time is below the inactivity threshold.
        guard let nextDay = calendar.date(byAdding: .day, value: 1,
                                          to: calendar.startOfDay(for: firstDay)) else {
            return fail("next-day fixture")
        }
        let nextTimestamp = nextDay.addingTimeInterval(2).timeIntervalSince1970
        store.consume(.commit(.init(characterCount: 2,
                                    timestamp: nextTimestamp,
                                    source: .buffer,
                                    schemaID: privateSchemaID)))
        let secondSnapshot = store.snapshot(for: nextDay)
        let historyBeforeSave = store.historySnapshot()
        guard secondSnapshot.keyCount == 0,
              secondSnapshot.committedCharacterCount == 2,
              secondSnapshot.activeSeconds == 0,
              secondSnapshot.sessionCount == 1,
              historyBeforeSave.days.count == 2,
              historyBeforeSave.recentSessions.count == 3,
              historyBeforeSave.recentSessions.first?.dayKey == secondSnapshot.dayKey else {
            return fail("cross-day session boundary")
        }

        store.saveNow()
        let reloaded = TypingSpeedStore(storageRoot: root,
                                        autosaveDelay: 60,
                                        inactivityThreshold: 10)
        guard reloaded.storageIssue == nil,
              reloaded.snapshot(for: firstDay) == afterGap,
              reloaded.snapshot(for: nextDay) == secondSnapshot,
              reloaded.historySnapshot() == historyBeforeSave else {
            return fail("persistence reload")
        }

        let storageURL = root.appendingPathComponent("stats/typing_speed.json")
        let directoryPermissions = (try fileManager.attributesOfItem(
            atPath: storageURL.deletingLastPathComponent().path
        )[.posixPermissions] as? NSNumber)?.intValue ?? -1
        let filePermissions = (try fileManager.attributesOfItem(
            atPath: storageURL.path
        )[.posixPermissions] as? NSNumber)?.intValue ?? -1
        guard directoryPermissions & 0o777 == 0o700,
              filePermissions & 0o777 == 0o600 else {
            return fail("storage permissions")
        }
        let persisted = try String(contentsOf: storageURL, encoding: .utf8)
        guard !persisted.contains(privateKeyID),
              !persisted.contains(privateSchemaID),
              !persisted.localizedCaseInsensitiveContains("text"),
              !persisted.localizedCaseInsensitiveContains("focus"),
              !persisted.localizedCaseInsensitiveContains("keyID"),
              !persisted.localizedCaseInsensitiveContains("schemaID") else {
            return fail("privacy boundary")
        }

        let invalidRoot = root.appendingPathComponent("invalid", isDirectory: true)
        let invalidURL = invalidRoot.appendingPathComponent("stats/typing_speed.json")
        try fileManager.createDirectory(at: invalidURL.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
        let invalidJSON = #"{"version":1,"days":not-valid-json"#
        try Data(invalidJSON.utf8).write(to: invalidURL, options: .atomic)
        let invalidStore = TypingSpeedStore(storageRoot: invalidRoot,
                                            autosaveDelay: 60)
        guard invalidStore.storageIssue != nil else {
            return fail("invalid JSON was accepted")
        }

        var repairNotificationCount = 0
        let repairObserver = NotificationCenter.default.addObserver(
            forName: .typingSpeedDidChange,
            object: invalidStore,
            queue: nil
        ) { _ in
            repairNotificationCount += 1
        }
        defer { NotificationCenter.default.removeObserver(repairObserver) }
        guard invalidStore.repairReadOnlyStore(),
              invalidStore.storageIssue == nil else {
            return fail("invalid JSON repair")
        }
        let invalidDirectory = invalidURL.deletingLastPathComponent()
        let invalidBackups = try fileManager.contentsOfDirectory(
            at: invalidDirectory,
            includingPropertiesForKeys: nil
        ).filter {
            $0.lastPathComponent.hasPrefix("typing_speed.corrupt-")
                && $0.pathExtension == "json"
        }
        let invalidBackupContents = try invalidBackups.first.map {
            try String(contentsOf: $0, encoding: .utf8)
        }
        let invalidBackupIsBesideStore = invalidBackups.first?
            .deletingLastPathComponent().standardizedFileURL
            == invalidDirectory.standardizedFileURL
        let rebuiltStoreIsSymlink = LocalMetricsFileSecurity
            .pathEntryIsSymbolicLink(invalidURL)
        guard invalidBackups.count == 1,
              invalidBackupIsBesideStore,
              invalidBackupContents == invalidJSON,
              repairNotificationCount > 0,
              !rebuiltStoreIsSymlink else {
            return fail("invalid JSON backup preservation "
                + "(count=\(invalidBackups.count), content=\(invalidBackupContents == invalidJSON), "
                + "beside=\(invalidBackupIsBesideStore), symlink=\(rebuiltStoreIsSymlink), "
                + "notifications=\(repairNotificationCount))")
        }

        invalidStore.consume(.key(.init(keyID: "KeyA",
                                        timestamp: firstTimestamp,
                                        isRepeat: false,
                                        modifierFlags: 0,
                                        schemaID: privateSchemaID)))
        invalidStore.consume(.commit(.init(characterCount: 3,
                                           timestamp: firstTimestamp + 1,
                                           source: .buffer,
                                           schemaID: privateSchemaID)))
        invalidStore.saveNow()
        let repairedReload = TypingSpeedStore(storageRoot: invalidRoot,
                                              autosaveDelay: 60)
        let repairedSnapshot = repairedReload.snapshot(for: firstDay)
        guard repairedReload.storageIssue == nil,
              repairedSnapshot.keyCount == 1,
              repairedSnapshot.committedCharacterCount == 3 else {
            return fail("collection after repair")
        }

        let oversizedRoot = root.appendingPathComponent("oversized", isDirectory: true)
        let oversizedURL = oversizedRoot.appendingPathComponent("stats/typing_speed.json")
        try fileManager.createDirectory(at: oversizedURL.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
        try Data(repeating: 0x61,
                 count: TypingSpeedStore.maximumFileBytes + 1)
            .write(to: oversizedURL, options: .atomic)
        let oversizedStore = TypingSpeedStore(storageRoot: oversizedRoot,
                                              autosaveDelay: 60)
        guard oversizedStore.storageIssue != nil else {
            return fail("oversized file was accepted")
        }

        let symlinkRoot = root.appendingPathComponent("symlink", isDirectory: true)
        let symlinkURL = symlinkRoot.appendingPathComponent("stats/typing_speed.json")
        let symlinkTarget = root.appendingPathComponent("typing-symlink-target.json")
        try fileManager.createDirectory(at: symlinkURL.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
        let symlinkTargetContents = Data("external-target-must-not-change".utf8)
        try symlinkTargetContents.write(to: symlinkTarget, options: .atomic)
        try fileManager.createSymbolicLink(at: symlinkURL,
                                           withDestinationURL: symlinkTarget)
        let symlinkStore = TypingSpeedStore(storageRoot: symlinkRoot,
                                            autosaveDelay: 60)
        guard symlinkStore.storageIssue != nil else {
            return fail("symlink file was accepted")
        }
        let symlinkRepairSucceeded = symlinkStore.repairReadOnlyStore()
        let symlinkTargetUnchanged = try Data(contentsOf: symlinkTarget)
            == symlinkTargetContents
        let rebuiltSymlinkStoreIsLink = LocalMetricsFileSecurity
            .pathEntryIsSymbolicLink(symlinkURL)
        guard symlinkRepairSucceeded,
              symlinkStore.storageIssue == nil,
              symlinkTargetUnchanged,
              !rebuiltSymlinkStoreIsLink else {
            let entries = try fileManager.contentsOfDirectory(
                atPath: symlinkURL.deletingLastPathComponent().path
            ).map { name in
                let candidate = symlinkURL.deletingLastPathComponent()
                    .appendingPathComponent(name)
                return "\(name):link=\(LocalMetricsFileSecurity.pathEntryIsSymbolicLink(candidate))"
            }.joined(separator: ",")
            return fail("symlink repair followed or changed target "
                + "(success=\(symlinkRepairSucceeded), issue=\(symlinkStore.storageIssue ?? "none"), "
                + "target=\(symlinkTargetUnchanged), rebuiltLink=\(rebuiltSymlinkStoreIsLink), "
                + "entries=\(entries))")
        }
        let symlinkBackups = try fileManager.contentsOfDirectory(
            at: symlinkURL.deletingLastPathComponent(),
            includingPropertiesForKeys: nil
        ).filter {
            $0.lastPathComponent.hasPrefix("typing_speed.corrupt-")
                && $0.pathExtension == "json"
        }
        guard symlinkBackups.count == 1,
              LocalMetricsFileSecurity.pathEntryIsSymbolicLink(symlinkBackups[0]) else {
            return fail("symlink path entry was not preserved as backup")
        }
        symlinkStore.consume(.commit(.init(characterCount: 2,
                                           timestamp: nextTimestamp,
                                           source: .direct,
                                           schemaID: privateSchemaID)))
        symlinkStore.saveNow()
        let repairedSymlinkReload = TypingSpeedStore(storageRoot: symlinkRoot,
                                                     autosaveDelay: 60)
        guard repairedSymlinkReload.storageIssue == nil,
              repairedSymlinkReload.snapshot(for: nextDay)
                  .committedCharacterCount == 2,
              try Data(contentsOf: symlinkTarget) == symlinkTargetContents else {
            return fail("symlink repair persistence")
        }

        // An unsafe parent directory cannot be repaired in place. Recovery
        // remains fail-closed and does not touch the directory link or target.
        let unsafeRoot = root.appendingPathComponent("unsafe-parent", isDirectory: true)
        let unsafeStatsLink = unsafeRoot.appendingPathComponent("stats",
                                                                isDirectory: true)
        let unsafeTarget = root.appendingPathComponent("unsafe-parent-target",
                                                       isDirectory: true)
        try fileManager.createDirectory(at: unsafeRoot,
                                        withIntermediateDirectories: true)
        try fileManager.createDirectory(at: unsafeTarget,
                                        withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(at: unsafeStatsLink,
                                           withDestinationURL: unsafeTarget)
        let unsafeStore = TypingSpeedStore(storageRoot: unsafeRoot,
                                           autosaveDelay: 60)
        guard unsafeStore.storageIssue != nil,
              !unsafeStore.repairReadOnlyStore(),
              unsafeStore.storageIssue != nil,
              LocalMetricsFileSecurity.pathEntryIsSymbolicLink(unsafeStatsLink),
              !fileManager.fileExists(
                atPath: unsafeTarget.appendingPathComponent("typing_speed.json").path
              ) else {
            return fail("unsafe parent repair was not fail-closed")
        }

        reloaded.clearAll()
        guard reloaded.historySnapshot().days.isEmpty,
              reloaded.historySnapshot().recentSessions.isEmpty else {
            return fail("clear all")
        }

        print("typing speed store smoke OK")
        return true
    } catch {
        return fail("threw \(error.localizedDescription)")
    }
}
