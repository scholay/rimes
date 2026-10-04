import Foundation
import XCTest
@testable import RimesCore

final class OfficialPluginStoreTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("RIMES-PluginTests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    private func store(legacy: Bool = false) throws -> OfficialPluginStore {
        .init(root: root.appendingPathComponent("packages"), platform: "ios", hostVersion: "1.1.0",
              catalog: try .bundled(), legacyProfile: legacy)
    }

    func testEveryDeclaredAdapterValidatesAndMobileIdentityIsPreserved() throws {
        let catalog = try OfficialPluginCatalog.bundled()
        XCTAssertEqual(catalog.plugins.count, 24)
        for entry in catalog.plugins {
            let data = try OfficialPluginCatalog.bundledData(entry)
            for platform in entry.platforms.keys {
                let package = try OfficialPluginPackage.validated(data, expectedID: entry.id, expectedVersion: entry.version,
                                                                  platform: platform, hostVersion: "1.1.0")
                XCTAssertEqual(package.id, entry.id)
            }
        }
        XCTAssertEqual(try store().entry(legacyID: "ai.polish")?.id, "builtin.polisher")
        XCTAssertEqual(try store().entry(legacyID: "ai.poem")?.id, "builtin.poem")
    }

    func testOptionalInstallEnableRevokeAndReinstallKeepUserFiles() throws {
        let store = try store(); try store.bootstrap()
        let entry = try XCTUnwrap(store.entry(legacyID: "ai.polish"))
        let userFile = root.appendingPathComponent("user-document.txt")
        try Data("retained".utf8).write(to: userFile)
        XCTAssertEqual(store.state(entry.id)?.installed, false)
        XCTAssertThrowsError(try store.package(entry.id))
        try store.install(OfficialPluginCatalog.bundledData(entry), id: entry.id)
        XCTAssertEqual(store.state(entry.id)?.installed, true)
        XCTAssertFalse(store.isEnabled(legacyID: "ai.polish"))
        try store.setEnabled(true, id: entry.id)
        let grant = try XCTUnwrap(store.state(entry.id)?.installationID)
        XCTAssertTrue(try store.package(entry.id).instruction().contains("Preserve"))
        try store.setEnabled(false, id: entry.id)
        XCTAssertNotEqual(store.state(entry.id)?.installationID, grant)
        XCTAssertThrowsError(try store.package(entry.id))
        try store.uninstall(entry.id)
        try store.install(OfficialPluginCatalog.bundledData(entry), id: entry.id)
        XCTAssertFalse(store.isEnabled(legacyID: "ai.polish"))
        XCTAssertNotEqual(store.state(entry.id)?.installationID, grant)
        XCTAssertEqual(try String(contentsOf: userFile), "retained")
    }

    func testLegacyProfileWorksOfflineButExplicitUninstallSurvivesRestart() throws {
        let store = try store(legacy: true); try store.bootstrap()
        XCTAssertTrue(store.isEnabled(legacyID: "ai.ask"))
        try store.uninstall("builtin.ask")
        XCTAssertFalse(try self.store(legacy: true).isEnabled(legacyID: "ai.ask"))
        XCTAssertEqual(try self.store(legacy: true).state("builtin.ask")?.installed, false)
    }

    func testFreshBootstrapCannotLaterBeGrandfatheredByNewUserConfiguration() throws {
        try store(legacy: false).bootstrap()
        XCTAssertEqual(try store(legacy: true).state("builtin.ask")?.installed, false)
    }

    func testBundledUninstallRestoresDisabledAndStaleDownloadCannotReinstall() async throws {
        let store = try store(); try store.bootstrap()
        XCTAssertTrue(store.isEnabled(legacyID: "apple.translation"))
        try store.uninstall("builtin.apple-translation")
        XCTAssertFalse(store.isEnabled(legacyID: "apple.translation"))
        try await store.install("builtin.apple-translation")
        XCTAssertEqual(store.state("builtin.apple-translation")?.installed, true)
        XCTAssertFalse(store.isEnabled(legacyID: "apple.translation"))
        let entry = try XCTUnwrap(store.entry(legacyID: "ai.polish"))
        let before = try XCTUnwrap(store.state(entry.id))
        try store.uninstall(entry.id)
        XCTAssertThrowsError(try store.install(OfficialPluginCatalog.bundledData(entry), id: entry.id, expectedState: before))
    }

    func testTamperedContentAndStateCannotRetainAuthorization() throws {
        let store = try store(); try store.bootstrap()
        let entry = try XCTUnwrap(store.entry(legacyID: "ai.polish"))
        try store.install(OfficialPluginCatalog.bundledData(entry), id: entry.id)
        try store.setEnabled(true, id: entry.id)
        let directory = root.appendingPathComponent("packages")
        try Data("changed".utf8).write(to: directory.appendingPathComponent(entry.id + ".json"))
        XCTAssertFalse(store.isEnabled(legacyID: "ai.polish"))
        try Data("broken receipt".utf8).write(to: directory.appendingPathComponent(entry.id + ".state.json"))
        XCTAssertNil(store.state(entry.id))
        XCTAssertThrowsError(try store.install(Data("untrusted".utf8), id: entry.id))
    }

    func testCorruptMigrationCannotReactivateLegacyPlugins() throws {
        let store = try store(legacy: true); try store.bootstrap()
        try Data("invalid".utf8).write(to: root.appendingPathComponent("packages/migration.json"))
        XCTAssertNil(store.state("builtin.ask"))
        XCTAssertFalse(store.isEnabled(legacyID: "ai.ask"))
    }

    func testRejectSymlinkWithoutTouchingItsTarget() throws {
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("packages"), withDestinationURL: outside)
        let store = try store(legacy: true)
        XCTAssertThrowsError(try store.bootstrap())
        XCTAssertThrowsError(try store.uninstall("builtin.ask"))
        XCTAssertFalse(store.isEnabled(legacyID: "ai.ask"))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }
}
