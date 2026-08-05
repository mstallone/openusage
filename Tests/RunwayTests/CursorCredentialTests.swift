import XCTest
@testable import Runway

/// Cursor credential handling: which local source wins, what stays prompt-free, and how a lapsed or
/// rejected token is reported now that Runway never refreshes or writes Cursor's credentials.
final class CursorAuthStoreTests: XCTestCase {
    func testExpiredSQLiteTokenYieldsToAUsableSameAccountKeychainToken() {
        // Read-only means a lapsed selected token ends the refresh, so a usable token for the SAME
        // account must win instead of reporting renewal while a working credential sits unread.
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let expiredSQLite = makeSharedCursorJWT(sub: "auth0|same-user", exp: now.timeIntervalSince1970 - 60)
        let liveKeychain = makeSharedCursorJWT(sub: "auth0|same-user", exp: now.timeIntervalSince1970 + 3_600)
        let store = CursorAuthStore(
            sqlite: FakeCursorSQLite(values: [
                CursorAuthStore.accessTokenKey: expiredSQLite,
                CursorAuthStore.membershipTypeKey: "free"
            ]),
            keychain: ServiceKeychain(values: [
                CursorAuthStore.keychainAccessTokenService: liveKeychain
            ]),
            now: { now }
        )

        let state = store.loadCredentials().state

        XCTAssertEqual(state?.source, .keychain)
        XCTAssertEqual(state?.accessToken, liveKeychain)
    }

    func testExpiredPaidSQLiteLoginCanStillReachAProtectedKeychainToken() {
        // A usable paid SQLite login suppresses keychain prompts, but an EXPIRED one must not: the
        // protected item may hold this account's still-valid token, and it is the only thing that
        // can save the refresh. Automatic passes stay silent and report the approval need.
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let expiredSQLite = makeSharedCursorJWT(sub: "auth0|same-user", exp: now.timeIntervalSince1970 - 60)
        let liveKeychain = makeSharedCursorJWT(sub: "auth0|same-user", exp: now.timeIntervalSince1970 + 3_600)
        let keychain = ApprovableCursorKeychain(approvedValue: liveKeychain)
        let store = CursorAuthStore(
            sqlite: FakeCursorSQLite(values: [
                CursorAuthStore.accessTokenKey: expiredSQLite,
                CursorAuthStore.membershipTypeKey: "pro"
            ]),
            keychain: keychain,
            now: { now }
        )

        // Automatic: silent, and the protected item is surfaced as the neutral connect state.
        XCTAssertEqual(store.loadCredentials(), .connectRequired)
        XCTAssertEqual(keychain.interactiveReads, 0)

        // Manual: the prompt is allowed, and the same-account token wins over the dead one.
        let approved = store.loadCredentials(allowKeychainInteraction: true).state
        XCTAssertEqual(approved?.source, .keychain)
        XCTAssertEqual(approved?.accessToken, liveKeychain)
        XCTAssertEqual(keychain.interactiveReads, 1)
    }

    func testExpiredSQLiteTokenNeverCrossesToADifferentAccountsKeychainToken() {
        // The same fallback must not bridge accounts: a different subject keeps SQLite selected (a
        // paid membership here), so the card reports renewal for its own account instead of
        // silently showing another account's usage.
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let expiredSQLite = makeSharedCursorJWT(sub: "auth0|user-a", exp: now.timeIntervalSince1970 - 60)
        let otherAccount = makeSharedCursorJWT(sub: "auth0|user-b", exp: now.timeIntervalSince1970 + 3_600)
        let store = CursorAuthStore(
            sqlite: FakeCursorSQLite(values: [
                CursorAuthStore.accessTokenKey: expiredSQLite,
                CursorAuthStore.membershipTypeKey: "pro"
            ]),
            keychain: ServiceKeychain(values: [
                CursorAuthStore.keychainAccessTokenService: otherAccount
            ]),
            now: { now }
        )

        let state = store.loadCredentials().state

        XCTAssertEqual(state?.source, .sqlite)
        XCTAssertEqual(state?.accessToken, expiredSQLite)
    }

    func testPrefersKeychainWhenSQLiteLooksFreeAndSubjectsDiffer() {
        let sqliteToken = makeSharedCursorJWT(sub: "google-oauth2|sqlite-user")
        let keychainToken = makeSharedCursorJWT(sub: "auth0|keychain-user")
        let sqlite = FakeCursorSQLite(values: [
            CursorAuthStore.accessTokenKey: sqliteToken,
            CursorAuthStore.membershipTypeKey: "free"
        ])
        let keychain = ServiceKeychain(values: [
            CursorAuthStore.keychainAccessTokenService: keychainToken
        ])
        let store = CursorAuthStore(sqlite: sqlite, keychain: keychain)

        let state = store.loadCredentials().state

        XCTAssertEqual(state?.source, .keychain)
        XCTAssertEqual(state?.accessToken, keychainToken)
    }

}

@MainActor
final class CursorKeychainReadModeTests: XCTestCase {
    func testAutomaticKeychainLoadIsPromptFreeAndManualLoadMayPrompt() {
        // Regression for the 2026-08-03 prompt loop: Cursor's keychain items must never be read
        // through a prompt-capable path on an automatic refresh or at launch. Only a manual refresh
        // may use the interactive read (which prompts once, for Runway itself).
        let keychain = ReadModeTrackingKeychain(value: "cursor-token")
        let store = CursorAuthStore(sqlite: EmptySQLite(), keychain: keychain)

        XCTAssertEqual(store.loadCredentials().state?.accessToken, "cursor-token")
        XCTAssertEqual(keychain.interactiveReads, 0)
        XCTAssertGreaterThan(keychain.nonInteractiveReads, 0)
        XCTAssertEqual(keychain.plainReads, 0, "the subprocess-style read path must not be used")

        XCTAssertEqual(store.loadCredentials(allowKeychainInteraction: true).state?.accessToken, "cursor-token")
        XCTAssertGreaterThan(keychain.interactiveReads, 0)
        XCTAssertEqual(keychain.plainReads, 0)
    }

    func testProtectedKeychainItemsCountAsConnectRequiredNotLoggedOut() {
        // A Cursor login stored only in protected Keychain items must be reported as the neutral
        // connect state — a real footprint the user connects via an explicit action — never
        // silently collapsed into "not logged in" or dressed as a denial.
        let store = CursorAuthStore(sqlite: EmptySQLite(), keychain: UnavailableCursorKeychain())

        XCTAssertEqual(store.loadCredentials(), .connectRequired)
    }

    func testUnreadableKeychainIsNotReportedAsNeedingApproval() {
        // "Choose Always Allow" cannot fix a locked login keychain or a failing securityd. The
        // read's own status told the two apart, so the load must carry that distinction rather
        // than collapsing both into an approval request.
        let store = CursorAuthStore(sqlite: EmptySQLite(), keychain: UnreadableCursorKeychain())

        XCTAssertEqual(store.loadCredentials(), .unreadable)
    }

    func testFreeSQLiteTokenDoesNotSilentlyBypassAProtectedKeychainLogin() {
        // The keychain (agent CLI) login can be the real paid account; with its items protected the
        // free-vs-different-subject comparison is impossible, so the load surfaces the connect
        // prompt instead of silently showing the free SQLite account. A paid SQLite login keeps winning.
        let sqlite = FakeCursorSQLite(values: [
            CursorAuthStore.accessTokenKey: "sqlite-free-token",
            CursorAuthStore.membershipTypeKey: "free"
        ])
        let protected = CursorAuthStore(sqlite: sqlite, keychain: UnavailableCursorKeychain())
        XCTAssertEqual(protected.loadCredentials(), .connectRequired)

        let paidSqlite = FakeCursorSQLite(values: [
            CursorAuthStore.accessTokenKey: "sqlite-pro-token",
            CursorAuthStore.membershipTypeKey: "pro"
        ])
        let paid = CursorAuthStore(sqlite: paidSqlite, keychain: UnavailableCursorKeychain())
        XCTAssertEqual(paid.loadCredentials().state?.accessToken, "sqlite-pro-token")
    }

    func testManualRefreshWithAPaidSQLiteLoginNeverPromptsForStaleKeychainEntries() {
        // A paid SQLite login is returned unconditionally, so a manual refresh must not raise
        // approval dialogs for keychain entries it would then ignore.
        let sqlite = FakeCursorSQLite(values: [
            CursorAuthStore.accessTokenKey: "sqlite-pro-token",
            CursorAuthStore.membershipTypeKey: "pro"
        ])
        let keychain = ReadModeTrackingKeychain(value: "stale-agent-token")
        let store = CursorAuthStore(sqlite: sqlite, keychain: keychain)

        let state = store.loadCredentials(allowKeychainInteraction: true).state

        XCTAssertEqual(state?.accessToken, "sqlite-pro-token")
        XCTAssertEqual(keychain.interactiveReads, 0, "keychain entries that cannot win must not prompt")
    }

}


/// Cursor keychain items Runway isn't authorized to read prompt-free: non-interactive reads report
/// `.unavailable` while the attributes-only existence probe still confirms the items.
/// The item could not be read for a reason approval cannot fix: the recorded category says the
/// failure was NOT an ACL denial.
private final class UnreadableCursorKeychain: KeychainReading, @unchecked Sendable {
    func readGenericPassword(service: String) throws -> String? {
        XCTFail("the subprocess-style read path must not be used")
        return nil
    }

    func readGenericPasswordWithoutUserInteraction(service: String) -> NonInteractiveKeychainRead {
        .unavailable
    }

    func lastReadFailure(service: String) -> KeychainReadFailure? {
        .unreadable
    }

    func genericPasswordExists(service: String) -> Bool? {
        XCTFail("the recorded category answers this; no probe should be needed")
        return nil
    }
}

