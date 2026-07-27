import XCTest
@testable import OpenUsage

final class KimiOAuthRefreshLockTests: XCTestCase {
    func testLockUsesOfficialPathAndReleasesIt() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("openusage-kimi-lock-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let lock = KimiOAuthRefreshLock(environment: FakeEnvironment())

        let lease = try await lock.acquire(
            homeDirectory: root.path,
            credentialName: "kimi-code"
        )

        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("oauth/kimi-code").path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("oauth/kimi-code.lock").path
        ))
        await lease.release()
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("oauth/kimi-code.lock").path
        ))
    }

    func testDisableSwitchAvoidsFilesystemMutation() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("openusage-kimi-no-lock-\(UUID().uuidString)", isDirectory: true)
        let lock = KimiOAuthRefreshLock(
            environment: FakeEnvironment(["KIMI_DISABLE_OAUTH_LOCK": "1"])
        )

        let lease = try await lock.acquire(
            homeDirectory: root.path,
            credentialName: "kimi-code"
        )
        await lease.release()

        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testEndpointScopedCredentialUsesItsOwnOfficialLockSlot() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("openusage-kimi-scoped-lock-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let lock = KimiOAuthRefreshLock(environment: FakeEnvironment())

        let lease = try await lock.acquire(
            homeDirectory: root.path,
            credentialName: "kimi-code-env-31aeeb1500100059"
        )

        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("oauth/kimi-code-env-31aeeb1500100059.lock").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("oauth/kimi-code.lock").path
        ))
        await lease.release()
    }

    func testRecoversOfficiallyStaleLockDirectory() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("openusage-kimi-stale-lock-\(UUID().uuidString)", isDirectory: true)
        let stale = root.appendingPathComponent("oauth/kimi-code.lock", isDirectory: true)
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-10)],
            ofItemAtPath: stale.path
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let lease = try await KimiOAuthRefreshLock(environment: FakeEnvironment()).acquire(
            homeDirectory: root.path,
            credentialName: "kimi-code"
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: stale.path))
        await lease.release()
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
    }
}
