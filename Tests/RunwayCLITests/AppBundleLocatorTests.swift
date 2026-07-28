import XCTest
@testable import RunwayCLI

final class AppBundleLocatorTests: XCTestCase {
    func testFindsContainingAppThroughHelperSymlink() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let app = root.appendingPathComponent("Runway.app")
        let contents = app.appendingPathComponent("Contents")
        let helpers = contents.appendingPathComponent("Helpers")
        let bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleIdentifier": "com.example.runway",
            "CFBundleShortVersionString": "1.2.3"
        ]
        let plistData = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try plistData.write(to: contents.appendingPathComponent("Info.plist"))
        let helper = helpers.appendingPathComponent("runway")
        try Data().write(to: helper)
        let symlink = bin.appendingPathComponent("runway")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: helper)
        defer { try? FileManager.default.removeItem(at: root) }

        let located = AppBundleLocator.locate(
            executableURL: symlink,
            environment: [:]
        )

        XCTAssertEqual(located.bundleIdentifier, "com.example.runway")
        XCTAssertEqual(located.version, "1.2.3")
    }

    func testEnvironmentCanSelectDefaultsSuiteForDevelopment() {
        let located = AppBundleLocator.locate(
            executableURL: URL(fileURLWithPath: "/tmp/runway"),
            environment: ["RUNWAY_DEFAULTS_SUITE": "com.example.dev"]
        )

        XCTAssertEqual(located.bundleIdentifier, "com.example.dev")
    }
}
