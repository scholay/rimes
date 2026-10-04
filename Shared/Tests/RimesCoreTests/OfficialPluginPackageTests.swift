import Foundation
import XCTest
@testable import RimesCore

final class OfficialPluginPackageTests: XCTestCase {
    private func fixture() throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "polisher-v2", withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    private func read(_ data: Data, platform: String = "macos", host: String = "1.1.0") throws -> OfficialPluginPackage {
        try .validated(data, expectedID: "builtin.polisher", expectedVersion: "1.1.0",
                       platform: platform, hostVersion: host)
    }

    private func changed(_ key: String, to value: Any) throws -> Data {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture()) as? [String: Any])
        object[key] = value
        return try JSONSerialization.data(withJSONObject: object)
    }

    func testPublishedFormatCarriesInstructionAndPlatformAliases() throws {
        let package = try read(fixture())
        XCTAssertTrue(try package.instruction().contains("Preserve its meaning"))
        XCTAssertEqual(package.platforms["ios"]?.legacyID, "ai.polish")
        XCTAssertEqual(package.platforms["android"]?.legacyID, "polish")
        XCTAssertThrowsError(try package.instruction(mode: "image"))
    }

    func testUnsupportedPlatformAndOlderHostCannotLoad() throws {
        XCTAssertThrowsError(try read(fixture(), platform: "windows"))
        XCTAssertThrowsError(try read(fixture(), host: "1.0.0")) { error in
            XCTAssertEqual(error as? PluginPackageError, .hostTooOld)
        }
        XCTAssertNoThrow(try read(fixture(), platform: "ios", host: "1.10.0"))
    }

    func testRejectIdentityRuntimeSDKAndCapabilityChanges() throws {
        for (key, value) in [("id", "builtin.other" as Any), ("version", "1.1.1" as Any),
                             ("sdkVersion", 2 as Any), ("runtime", "native" as Any),
                             ("capabilities", ["credentials.read"] as Any)] {
            XCTAssertThrowsError(try read(changed(key, to: value)), key)
        }
    }

    func testRejectInvalidContentBeforeReturningAnInstruction() throws {
        for contents in ["", "\0", String(repeating: "x", count: 32769)] {
            XCTAssertThrowsError(try read(changed("contribution", to: [
                "type": "ai.prompt.v1", "instructions": ["default": contents]
            ])))
        }
        XCTAssertThrowsError(try read(Data(repeating: 32, count: OfficialPluginPackage.maximumBytes + 1)))
    }

    func testVersionComparisonIsNumericAndStrict() throws {
        XCTAssertLessThan(try XCTUnwrap(PluginPackageVersion("1.2.9")),
                          try XCTUnwrap(PluginPackageVersion("1.10.0")))
        for invalid in ["1.1", "01.1.0", "1.1.0-preview.1", "1.1.0\n", "9999999999999999999999.1.0"] {
            XCTAssertNil(PluginPackageVersion(invalid), invalid)
        }
    }
}
