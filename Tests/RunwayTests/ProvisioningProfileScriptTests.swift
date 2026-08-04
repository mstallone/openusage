import Foundation
import XCTest

final class ProvisioningProfileScriptTests: XCTestCase {
    func testProfileDecoderExtractsAValidCMSPayload() throws {
        let fixture = try makeCMSFixture()
        let output = fixture.directory.appendingPathComponent("decoded.plist")

        let result = try runProcess(
            executable: decoderScript,
            arguments: [fixture.profile.path, output.path]
        )

        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(try Data(contentsOf: output), fixture.payload)
    }

    func testProfileDecoderRejectsATamperedCMSPayload() throws {
        let fixture = try makeCMSFixture()
        var signedData = try Data(contentsOf: fixture.profile)
        let marker = Data("RunwayProfileFixture".utf8)
        let markerRange = try XCTUnwrap(signedData.range(of: marker))
        signedData[markerRange.lowerBound] ^= 0x01
        try signedData.write(to: fixture.profile)

        let result = try runProcess(
            executable: decoderScript,
            arguments: [fixture.profile.path, fixture.directory.appendingPathComponent("decoded.plist").path]
        )

        XCTAssertNotEqual(result.status, 0)
        XCTAssertFalse(result.stderr.isEmpty, "verification failure should be reported")
    }

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

    private var decoderScript: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("script/decode_provisioning_profile.sh")
    }

    private func makeCMSFixture() throws -> (directory: URL, profile: URL, payload: Data) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RunwayProvisioningProfileTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        let key = directory.appendingPathComponent("key.pem")
        let certificate = directory.appendingPathComponent("certificate.pem")
        let payloadURL = directory.appendingPathComponent("payload.plist")
        let profile = directory.appendingPathComponent("fixture.mobileprovision")
        let payload = Data("<plist><dict><key>Name</key><string>RunwayProfileFixture</string></dict></plist>".utf8)
        try payload.write(to: payloadURL)

        let certificateResult = try runProcess(
            executable: URL(fileURLWithPath: "/usr/bin/openssl"),
            arguments: [
                "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-sha256",
                "-subj", "/CN=Runway Provisioning Profile Test", "-days", "1",
                "-keyout", key.path, "-out", certificate.path,
            ]
        )
        XCTAssertEqual(certificateResult.status, 0, certificateResult.stderr)

        let signingResult = try runProcess(
            executable: URL(fileURLWithPath: "/usr/bin/openssl"),
            arguments: [
                "cms", "-sign", "-binary", "-nodetach", "-outform", "DER",
                "-in", payloadURL.path, "-signer", certificate.path, "-inkey", key.path,
                "-out", profile.path,
            ]
        )
        XCTAssertEqual(signingResult.status, 0, signingResult.stderr)
        return (directory, profile, payload)
    }

    private func runProcess(executable: URL, arguments: [String]) throws -> (status: Int32, stderr: String) {
        let process = Process()
        let stderr = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, String(decoding: stderrData, as: UTF8.self))
    }
}
