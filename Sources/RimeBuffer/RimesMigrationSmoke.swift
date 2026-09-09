import Foundation

/// The rename touches 249 MB of Rime dictionaries, learned phrases and the
/// Capsule store. These assertions exist because a migration that goes wrong
/// quietly is indistinguishable from a fresh install.
func runRimesMigrationSmokeTest() -> Bool {
    print("== RIMES migration smoke ==")
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory
        .appendingPathComponent("rimes-migration-\(UUID().uuidString)",
                                isDirectory: true)
    defer { try? fileManager.removeItem(at: root) }

    let legacy = root.appendingPathComponent("RimeBuffer", isDirectory: true)
    let destination = root.appendingPathComponent("RIMES", isDirectory: true)

    // Nothing to move is a normal state, not an error: a fresh install has no
    // legacy directory and must not be told a migration failed.
    guard RimesDataMigration.migrateIfNeeded(from: legacy,
                                             to: destination,
                                             fileManager: fileManager)
            == .notNeeded else {
        return migrationFail("absent legacy directory must be a no-op")
    }

    try? fileManager.createDirectory(
        at: legacy.appendingPathComponent("capsule/passwords", isDirectory: true),
        withIntermediateDirectories: true
    )
    let secret = legacy
        .appendingPathComponent("capsule/passwords/entry.md")
    try? Data("---\ncapsule: password\n---\nsecret".utf8).write(to: secret)
    let userdb = legacy.appendingPathComponent("rime_ice.userdb")
    try? Data(repeating: 0x41, count: 4096).write(to: userdb)

    guard case let .copied(count) = RimesDataMigration.migrateIfNeeded(
        from: legacy, to: destination, fileManager: fileManager
    ), count > 0 else {
        return migrationFail("populated legacy directory must copy")
    }
    // The copy is verified by content, not by the call returning.
    let movedSecret = destination
        .appendingPathComponent("capsule/passwords/entry.md")
    guard let moved = try? Data(contentsOf: movedSecret),
          String(decoding: moved, as: UTF8.self).contains("secret"),
          (try? Data(contentsOf: destination
            .appendingPathComponent("rime_ice.userdb")))?.count == 4096 else {
        return migrationFail("copied content must match the original")
    }
    // The original is never removed: a user who finds the new location wrong
    // must still have their dictionaries.
    guard fileManager.fileExists(atPath: secret.path),
          fileManager.fileExists(atPath: userdb.path) else {
        return migrationFail("the legacy directory must be left in place")
    }

    // Running again must not copy over work done since.
    let addedAfter = destination.appendingPathComponent("written-later.txt")
    try? Data("later".utf8).write(to: addedAfter)
    try? Data("changed after migration".utf8).write(to: movedSecret)
    guard RimesDataMigration.migrateIfNeeded(from: legacy,
                                             to: destination,
                                             fileManager: fileManager)
            == .alreadyMigrated,
          let after = try? Data(contentsOf: movedSecret),
          String(decoding: after, as: UTF8.self) == "changed after migration",
          fileManager.fileExists(atPath: addedAfter.path) else {
        return migrationFail("a second run must not overwrite newer data")
    }

    // A destination that already holds unrelated data was not made by this
    // migration; interleaving two histories would corrupt both.
    let occupied = root.appendingPathComponent("Occupied", isDirectory: true)
    try? fileManager.createDirectory(at: occupied,
                                     withIntermediateDirectories: true)
    try? Data("pre-existing".utf8).write(
        to: occupied.appendingPathComponent("keep.txt")
    )
    // Reported, never marked: recording an occupied destination as migrated
    // is what turned an ordering mistake into a permanent one, leaving the
    // real data behind with nothing left to notice it.
    guard RimesDataMigration.migrateIfNeeded(from: legacy,
                                             to: occupied,
                                             fileManager: fileManager)
            == .destinationOccupied,
          !fileManager.fileExists(
            atPath: occupied
                .appendingPathComponent(".rimes-migrated-from-rimebuffer").path
          ),
          // Still retryable once the destination is cleared.
          {
              try? fileManager.removeItem(at: occupied)
              if case .copied = RimesDataMigration.migrateIfNeeded(
                  from: legacy, to: occupied, fileManager: fileManager
              ) { return true }
              return false
          }(),
          fileManager.fileExists(atPath: occupied
            .appendingPathComponent("capsule/passwords/entry.md").path) else {
        return migrationFail("an occupied destination must be reported, not marked")
    }

    // Preferences follow the bundle identifier, so a rename presents factory
    // settings unless every key is carried across.
    let suiteName = "rimes-migration-\(UUID().uuidString)"
    let legacyDomain = "rimes-migration-legacy-\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
        return migrationFail("could not create a defaults suite")
    }
    defer {
        defaults.removePersistentDomain(forName: suiteName)
        defaults.removePersistentDomain(forName: legacyDomain)
    }
    defaults.setPersistentDomain([
        "bufferWindow.autoSend.v1": true,
        "clipboard.activationPolicy.v1": "clipboardOnly",
        "bufferWindow.autoSendLifetime.v1": 3.0,
    ], forName: legacyDomain)
    // A key already set in the new domain is a decision made after the
    // rename and must win over the old value.
    defaults.set("pasteIntoApp", forKey: "clipboard.activationPolicy.v1")

    let copied = RimesPreferenceMigration.migrateIfNeeded(from: legacyDomain,
                                                          into: defaults)
    guard copied == 2,
          defaults.bool(forKey: "bufferWindow.autoSend.v1"),
          defaults.double(forKey: "bufferWindow.autoSendLifetime.v1") == 3,
          defaults.string(forKey: "clipboard.activationPolicy.v1")
            == "pasteIntoApp" else {
        return migrationFail("preference copy: \(copied) keys")
    }
    guard RimesPreferenceMigration.migrateIfNeeded(from: legacyDomain,
                                                   into: defaults) == 0 else {
        return migrationFail("preference migration must run once")
    }

    // The old environment variable names keep working: the smoke suites and
    // any of the user's scripts set them, and breaking those as a side effect
    // of a rename would be its own bug.
    let legacyEnv = ["RIMEBUFFER_USER_DIR": "/tmp/legacy-user"]
    let newEnv = ["RIMES_USER_DIR": "/tmp/new-user"]
    let bothEnv = ["RIMEBUFFER_USER_DIR": "/tmp/legacy-user",
                   "RIMES_USER_DIR": "/tmp/new-user"]
    guard RimesPaths.userDirectory(environment: legacyEnv).path
            == "/tmp/legacy-user",
          RimesPaths.userDirectory(environment: newEnv).path == "/tmp/new-user",
          RimesPaths.userDirectory(environment: bothEnv).path == "/tmp/new-user",
          RimesPaths.userDirectory(environment: [:]).path
            .hasSuffix("/Library/RIMES") else {
        return migrationFail("path overrides")
    }

    print("RIMES migration smoke: OK")
    return true
}

private func migrationFail(_ message: String) -> Bool {
    print("FAILED: \(message)")
    return false
}
