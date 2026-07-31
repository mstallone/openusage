import Foundation
import XCTest

final class ProvisioningProfileScriptTests: XCTestCase {
    func testProfileMatcherAcceptsBareAndMatchingTeamPrefixedContainerIdentifiers() throws {
        XCTAssertTrue(try matches(containerID: "iCloud.com.mattstallone.runway.dev"))
        XCTAssertTrue(try matches(containerID: "TEAM123.iCloud.com.mattstallone.runway.dev"))
    }

    func testProfileMatcherRejectsWrongTeamBundleAndContainerIdentifiers() throws {
        XCTAssertFalse(try matches(containerID: "OTHERTEAM.iCloud.com.mattstallone.runway.dev"))
        XCTAssertFalse(try matches(
            applicationID: "TEAM123.com.mattstallone.some-other-app",
            containerID: "TEAM123.iCloud.com.mattstallone.runway.dev"
        ))
        XCTAssertFalse(try matches(containerID: "TEAM123.iCloud.com.mattstallone.runway"))
    }

    func testProfileCloudKitCheckAcceptsWildcardAndExplicitCloudKit() throws {
        XCTAssertTrue(try authorizesCloudKit("*"))
        XCTAssertTrue(try authorizesCloudKit("Array {\n    CloudKit\n}"))
        XCTAssertTrue(try authorizesCloudKit("Array {\n    CloudDocuments\n    CloudKit\n}"))
    }

    func testProfileCloudKitCheckRejectsDocumentsOnlyAndMissingServices() throws {
        XCTAssertFalse(try authorizesCloudKit("Array {\n    CloudDocuments\n}"))
        XCTAssertFalse(try authorizesCloudKit(""))
    }

    private func matches(
        applicationID: String = "TEAM123.com.mattstallone.runway.dev",
        containerID: String
    ) throws -> Bool {
        try runSourcedFunction(
            "profile_matches_identifiers \"$2\" \"$3\" \"$4\" \"$5\"",
            arguments: [
                applicationID,
                containerID,
                "com.mattstallone.runway.dev",
                "iCloud.com.mattstallone.runway.dev"
            ]
        )
    }

    private func authorizesCloudKit(_ services: String) throws -> Bool {
        try runSourcedFunction("profile_authorizes_cloudkit \"$2\"", arguments: [services])
    }

    private func runSourcedFunction(_ invocation: String, arguments: [String]) throws -> Bool {
        let script = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("script/find_icloud_provisioning_profile.sh")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", "source \"$1\"; \(invocation)", "profile-script-test", script.path] + arguments
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}
