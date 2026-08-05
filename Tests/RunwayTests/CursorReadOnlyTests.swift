import XCTest
@testable import Runway

@MainActor
final class CursorReadOnlyCredentialTests: XCTestCase {
    func testExpiredTokenNeverRefreshesOrWritesAndReportsRenewal() async {
        // Runway is a read-only consumer of Cursor's credentials: an expired token means NO
        // token-endpoint call, NO state-database or keychain write, and a renewal notice.
        let sqlite = FakeCursorSQLite(values: [
            CursorAuthStore.accessTokenKey: makeSharedCursorJWT(exp: 1),
            CursorAuthStore.membershipTypeKey: "pro"
        ])
        let http = FakeHTTPClient(response: HTTPResponse(statusCode: 200, headers: [:], body: Data()))
        let provider = CursorProvider(
            authStore: CursorAuthStore(sqlite: sqlite, keychain: FakeKeychain()),
            usageClient: CursorUsageClient(http: http)
        )

        let snapshot = await provider.refresh()

        XCTAssertTrue(http.requests.isEmpty, "an expired token short-circuits before any network call")
        XCTAssertTrue(sqlite.writtenValues.isEmpty, "Cursor's state database is never written by Runway")
        XCTAssertEqual(
            snapshot.lines.compactMap { line -> String? in
                guard case .badge(_, let text, _, _) = line, line.label == "Error" else { return nil }
                return text
            }.first,
            CursorAuthError.loginRenewalRequired.localizedDescription
        )
    }

    func testUsage401ReportsRenewalWithoutARetryOrTokenEndpointCall() async {
        let sqlite = FakeCursorSQLite(values: [
            CursorAuthStore.accessTokenKey: makeSharedCursorJWT(),
            CursorAuthStore.membershipTypeKey: "pro"
        ])
        let http = RoutingHTTPClient { request in
            XCTAssertFalse(
                request.url.absoluteString.contains("token"),
                "the token endpoint must never be contacted"
            )
            return HTTPResponse(statusCode: 401, headers: [:], body: Data())
        }
        let provider = CursorProvider(
            authStore: CursorAuthStore(sqlite: sqlite, keychain: FakeKeychain()),
            usageClient: CursorUsageClient(http: http)
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(http.requests.count, 1, "no refresh-and-retry: one usage call, then renewal")
        XCTAssertEqual(
            snapshot.lines.compactMap { line -> String? in
                guard case .badge(_, let text, _, _) = line, line.label == "Error" else { return nil }
                return text
            }.first,
            CursorAuthError.loginRenewalRequired.localizedDescription
        )
    }
}

@MainActor
final class CursorPromptBoundTests: XCTestCase {
    func testDeniedAccessPromptDoesNotRaiseTheRefreshPromptToo() {
        // Approval is per item, but a denial of the first prompt means "no" — the companion item's
        // prompt must not follow in the same pass.
        let keychain = DenyingCursorKeychain()
        let store = CursorAuthStore(sqlite: EmptySQLite(), keychain: keychain)

        XCTAssertEqual(store.loadCredentials(allowKeychainInteraction: true), .keychainPermissionRequired)
        XCTAssertEqual(keychain.interactiveReads, 1, "a denial must not chain into a second prompt")
    }
}



@MainActor
final class CursorRevokedTokenFallbackTests: XCTestCase {
    func testServerRejectionRetriesTheSameAccountKeychainTokenOnce() async {
        // An unexpired SQLite token that the server revoked (signed out elsewhere). Runway can't
        // refresh it, but the agent CLI's keychain copy for the SAME account is still live — it must
        // be tried once instead of reporting renewal while a working credential sits unread.
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let revoked = makeSharedCursorJWT(sub: "auth0|same-user", exp: now.timeIntervalSince1970 + 3_600)
        let live = makeSharedCursorJWT(sub: "auth0|same-user", exp: now.timeIntervalSince1970 + 3_600)
        let http = RoutingHTTPClient { request in
            XCTAssertFalse(request.url.absoluteString.contains("oauth/token"), "no OAuth token-endpoint call may be made")
            guard request.headers["Authorization"]?.contains(live) == true else {
                return HTTPResponse(statusCode: 401, headers: [:], body: Data())
            }
            return HTTPResponse(
                statusCode: 200,
                headers: [:],
                body: Data(#"{"enabled":true,"planUsage":{"limit":40000,"totalPercentUsed":20}}"#.utf8)
            )
        }
        let provider = CursorProvider(
            authStore: CursorAuthStore(
                sqlite: FakeCursorSQLite(values: [
                    CursorAuthStore.accessTokenKey: revoked,
                    CursorAuthStore.membershipTypeKey: "pro"
                ]),
                keychain: ServiceKeychain(values: [
                    CursorAuthStore.keychainAccessTokenService: live
                ]),
                now: { now }
            ),
            usageClient: CursorUsageClient(http: http),
            now: { now }
        )

        let snapshot = await provider.refresh()

        XCTAssertNil(
            snapshot.lines.compactMap { line -> String? in
                guard case .badge(_, let text, _, _) = line, line.label == "Error" else { return nil }
                return text
            }.first,
            "the live same-account token should have served this refresh"
        )
    }

    func testAlternativeCredentialsNetworkFailureIsNotReportedAsRenewal() async {
        // The selected token was rejected and the same-account alternative hit a server error.
        // Telling the user to sign in again over a Cursor outage would send them down the wrong
        // path — the alternative may be perfectly valid.
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let revoked = makeSharedCursorJWT(sub: "auth0|same-user", exp: now.timeIntervalSince1970 + 3_600)
        let live = makeSharedCursorJWT(sub: "auth0|same-user", exp: now.timeIntervalSince1970 + 3_600)
        let http = RoutingHTTPClient { request in
            guard request.headers["Authorization"]?.contains(live) == true else {
                return HTTPResponse(statusCode: 401, headers: [:], body: Data())
            }
            return HTTPResponse(statusCode: 503, headers: [:], body: Data())
        }
        let provider = CursorProvider(
            authStore: CursorAuthStore(
                sqlite: FakeCursorSQLite(values: [
                    CursorAuthStore.accessTokenKey: revoked,
                    CursorAuthStore.membershipTypeKey: "pro"
                ]),
                keychain: ServiceKeychain(values: [
                    CursorAuthStore.keychainAccessTokenService: live
                ]),
                now: { now }
            ),
            usageClient: CursorUsageClient(http: http),
            now: { now }
        )

        let snapshot = await provider.refresh()

        let error = snapshot.lines.compactMap { line -> String? in
            guard case .badge(_, let text, _, _) = line, line.label == "Error" else { return nil }
            return text
        }.first
        XCTAssertEqual(error, ProviderUsageErrorText.requestFailed(statusCode: 503))
        XCTAssertNotEqual(error, CursorAuthError.loginRenewalRequired.localizedDescription)
    }

    func testServerRejectionDoesNotRetryADifferentAccountsToken() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let revoked = makeSharedCursorJWT(sub: "auth0|user-a", exp: now.timeIntervalSince1970 + 3_600)
        let otherAccount = makeSharedCursorJWT(sub: "auth0|user-b", exp: now.timeIntervalSince1970 + 3_600)
        let http = RoutingHTTPClient { _ in HTTPResponse(statusCode: 401, headers: [:], body: Data()) }
        let provider = CursorProvider(
            authStore: CursorAuthStore(
                sqlite: FakeCursorSQLite(values: [
                    CursorAuthStore.accessTokenKey: revoked,
                    CursorAuthStore.membershipTypeKey: "pro"
                ]),
                keychain: ServiceKeychain(values: [
                    CursorAuthStore.keychainAccessTokenService: otherAccount
                ]),
                now: { now }
            ),
            usageClient: CursorUsageClient(http: http),
            now: { now }
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(http.requests.count, 1, "another account's token must never be tried")
        XCTAssertEqual(
            snapshot.lines.compactMap { line -> String? in
                guard case .badge(_, let text, _, _) = line, line.label == "Error" else { return nil }
                return text
            }.first,
            CursorAuthError.loginRenewalRequired.localizedDescription
        )
    }
}

@MainActor
final class CursorExpiredKeychainPreferenceTests: XCTestCase {
    func testFreeSQLiteLoginIsKeptWhenTheAgentTokenHasExpired() {
        // The agent login usually is the paid account and wins a free SQLite membership — but not
        // when it's expired, because Runway can't refresh it and would trade live data for a
        // renewal notice.
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let liveSQLite = makeSharedCursorJWT(sub: "auth0|free-user", exp: now.timeIntervalSince1970 + 3_600)
        let expiredAgent = makeSharedCursorJWT(sub: "auth0|paid-user", exp: now.timeIntervalSince1970 - 60)
        let store = CursorAuthStore(
            sqlite: FakeCursorSQLite(values: [
                CursorAuthStore.accessTokenKey: liveSQLite,
                CursorAuthStore.membershipTypeKey: "free"
            ]),
            keychain: ServiceKeychain(values: [
                CursorAuthStore.keychainAccessTokenService: expiredAgent
            ]),
            now: { now }
        )

        let state = store.loadCredentials().state

        XCTAssertEqual(state?.source, .sqlite)
        XCTAssertEqual(state?.accessToken, liveSQLite)
    }
}

@MainActor
final class CursorProtectedAlternativeTests: XCTestCase {
    func testRejectedTokenWithAProtectedAlternativeAsksForApproval() async {
        // The unexpired SQLite token was rejected server-side and the same-account agent token sits
        // that hasn't been loaded this process. The live credential may be exactly the one Runway
        // hasn't read yet, so the card offers the connect prompt rather than telling the user to
        // sign in again.
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let revoked = makeSharedCursorJWT(sub: "auth0|same-user", exp: now.timeIntervalSince1970 + 3_600)
        let http = RoutingHTTPClient { _ in HTTPResponse(statusCode: 401, headers: [:], body: Data()) }
        let provider = CursorProvider(
            authStore: CursorAuthStore(
                sqlite: FakeCursorSQLite(values: [
                    CursorAuthStore.accessTokenKey: revoked,
                    CursorAuthStore.membershipTypeKey: "pro"
                ]),
                keychain: UnavailableCursorKeychain(),
                now: { now }
            ),
            usageClient: CursorUsageClient(http: http),
            now: { now }
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(
            snapshot.lines.compactMap { line -> String? in
                guard case .badge(_, let text, _, _) = line, line.label == "Connect" else { return nil }
                return text
            }.first,
            CursorAuthError.keychainConnectRequired.localizedDescription
        )
    }
}
