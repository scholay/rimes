import Foundation

/// The one place that decides where RIMES keeps its data, and the one place
/// that knows the directory used to be called something else.
///
/// Thirty-nine call sites used to spell `~/Library/RimeBuffer` themselves.
/// That is survivable until the name changes, at which point each one is an
/// opportunity to read from the old location and write to the new — which for
/// a directory holding Rime user dictionaries, learned phrases and the Capsule
/// store means silently losing work rather than failing loudly.
enum RimesPaths {
    static let directoryName = "RIMES"
    static let legacyDirectoryName = "RimeBuffer"
    private static let migrationMarker = ".rimes-migrated-from-rimebuffer"

    /// Honours the old variable names as well as the new ones. Existing
    /// scripts and the smoke suites set the old spelling, and breaking them
    /// as a side effect of a rename would be its own bug.
    private static func override(_ names: [String],
                                 environment: [String: String]) -> URL? {
        for name in names {
            if let value = environment[name], !value.isEmpty {
                return URL(fileURLWithPath: value, isDirectory: true)
            }
        }
        return nil
    }

    static func userDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL {
        if let overridden = override(["RIMES_USER_DIR", "RIMEBUFFER_USER_DIR"],
                                     environment: environment) {
            return overridden
        }
        return home(fileManager)
            .appendingPathComponent("Library/\(directoryName)", isDirectory: true)
    }

    static func localDataRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL {
        if let overridden = override(["RIMES_LOCAL_DATA_ROOT",
                                      "RIMEBUFFER_LOCAL_DATA_ROOT"],
                                     environment: environment) {
            return overridden
        }
        return userDirectory(environment: environment, fileManager: fileManager)
    }

    static func legacyUserDirectory(fileManager: FileManager = .default) -> URL {
        home(fileManager)
            .appendingPathComponent("Library/\(legacyDirectoryName)",
                                    isDirectory: true)
    }

    private static func home(_ fileManager: FileManager) -> URL {
        fileManager.homeDirectoryForCurrentUser
    }
}

enum RimesDataMigrationOutcome: Equatable {
    case notNeeded
    case alreadyMigrated
    case copied(fileCount: Int)
    case failed(String)
}

/// Copies the old data directory to the new name exactly once.
///
/// It copies rather than moves, and never deletes the original. A move that
/// fails halfway through 249 MB of dictionaries and password records leaves
/// nothing to fall back on; a copy that fails halfway leaves the user exactly
/// where they started. Reclaiming the space is a decision for the user to make
/// once they are satisfied, not something to take on their behalf during a
/// rename they did not watch.
enum RimesDataMigration {
    private static let markerName = ".rimes-migrated-from-rimebuffer"

    @discardableResult
    static func migrateIfNeeded(
        from legacy: URL,
        to destination: URL,
        fileManager: FileManager = .default
    ) -> RimesDataMigrationOutcome {
        var legacyIsDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: legacy.path,
                                     isDirectory: &legacyIsDirectory),
              legacyIsDirectory.boolValue else {
            return .notNeeded
        }
        let marker = destination.appendingPathComponent(markerName)
        if fileManager.fileExists(atPath: marker.path) {
            return .alreadyMigrated
        }
        // A destination that already holds data was not created by this
        // migration. Adopting it would interleave two histories.
        if fileManager.fileExists(atPath: destination.path) {
            let existing = (try? fileManager.contentsOfDirectory(
                atPath: destination.path
            )) ?? []
            guard existing.isEmpty else {
                try? Data().write(to: marker)
                return .alreadyMigrated
            }
            try? fileManager.removeItem(at: destination)
        }
        do {
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fileManager.copyItem(at: legacy, to: destination)
            let count = fileManager.enumerator(atPath: destination.path)?
                .allObjects.count ?? 0
            try? Data().write(to: marker)
            IMELog.write(
                "data migration: copied \(count) entries from "
                    + "\(legacy.lastPathComponent) to \(destination.lastPathComponent); "
                    + "the original was left in place"
            )
            return .copied(fileCount: count)
        } catch {
            IMELog.write(
                "data migration failed: \(error.localizedDescription); "
                    + "continuing to use \(legacy.path)"
            )
            return .failed(error.localizedDescription)
        }
    }
}

/// Carries preferences across the bundle-identifier change.
///
/// `UserDefaults` is keyed by bundle identifier, so renaming the app presents
/// the user with factory settings and no explanation. Every key is copied, and
/// only keys the new domain does not already hold — a second run must not
/// overwrite a choice made after the migration.
enum RimesPreferenceMigration {
    static let markerKey = "rimes.preferencesMigratedFromRimeBuffer.v1"

    @discardableResult
    static func migrateIfNeeded(from legacyDomain: String,
                                into defaults: UserDefaults = .standard) -> Int {
        guard !defaults.bool(forKey: markerKey) else { return 0 }
        defer { defaults.set(true, forKey: markerKey) }
        guard let legacy = defaults.persistentDomain(forName: legacyDomain),
              !legacy.isEmpty else { return 0 }
        var copied = 0
        for (key, value) in legacy where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
            copied += 1
        }
        IMELog.write("preference migration: copied \(copied) keys from \(legacyDomain)")
        return copied
    }
}
