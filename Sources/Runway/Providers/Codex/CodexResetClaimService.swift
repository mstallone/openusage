import Foundation
import SwiftUI

/// The outcome of a reset-credit claim, as the resets popover renders it — the consume endpoint's four
/// `code` values collapsed to what the user needs to know (`reset` and `already_redeemed` are both
/// "claimed": the latter is the idempotency key doing its job on a retry), plus a transport/HTTP
/// `.failed`.
enum ResetClaimOutcome: Equatable, Sendable {
    case success
    case nothingToReset
    case noCredit
    case failed
}

/// Claims a Codex rate-limit reset credit — the app's only provider-API write, so it is deliberately
/// narrow: one credit per call, always by explicit credit id, guarded by the caller's idempotency key.
/// The protocol was reverse-engineered from the open-source Codex CLI and verified live once; see
/// docs/research/codex-reset-credit-claim.md.
///
/// The claim re-fetches the credit list at claim time and matches the target credit by its expiry
/// instant (the identity the popover timeline carries), rather than trusting a cached id: the list is a
/// safe GET, the id is guaranteed fresh, and a credit that raced away (claimed from the CLI or web in
/// the meantime) simply fails to match → `.noCredit`, exactly the truth. A successful claim awaits a
/// forced Codex refresh before returning, so by the time the popover shows its result banner the
/// Session/Weekly meters and the credit count already tell the post-reset story.
@MainActor
final class CodexResetClaimService {
    typealias Credentials = (accessToken: String, accountID: String?)

    private let usageClient: CodexUsageClient
    private let credentialCandidates: (_ allowKeychainInteraction: Bool) async -> [Credentials]
    private let refreshAfterClaim: () async -> Void
    private let interactiveCredentialTimeout: TimeInterval
    /// The credit id each idempotency key was matched to, kept for the key's retries: if a consume
    /// succeeded but its response was lost, the credit is gone from a re-fetched list — a fresh match
    /// would misread the retry as "no longer available" instead of replaying the POST and letting the
    /// server answer `already_redeemed`. Session-lived, keyed by the popover's per-credit UUIDs.
    private var matchedCreditIDs: [String: String] = [:]

    /// Test seam: injected credential candidates and refresh hook, the same `usageClient` the requests
    /// go through. Candidates are tried in order until one authenticates (see `claim`).
    init(
        usageClient: CodexUsageClient,
        credentialCandidates: @escaping (_ allowKeychainInteraction: Bool) async -> [Credentials],
        refreshAfterClaim: @escaping () async -> Void = {},
        interactiveCredentialTimeout: TimeInterval = WidgetDataStore.defaultProviderRefreshTimeout
    ) {
        precondition(interactiveCredentialTimeout > 0)
        self.usageClient = usageClient
        self.credentialCandidates = credentialCandidates
        self.refreshAfterClaim = refreshAfterClaim
        self.interactiveCredentialTimeout = interactiveCredentialTimeout
    }

    /// Production wiring: shares the Codex provider's auth store and usage client, so credential
    /// selection can't drift from `refresh()` — every usable candidate in the provider's order (files
    /// first, then keychain), and `claim` falls back across them on an auth rejection the same way the
    /// provider's probe does. No token refresh here: the claim runs seconds after a successful usage
    /// fetch (which rotates tokens back to disk), so a candidate that still fails auth is genuinely
    /// dead and the next one is the right move.
    convenience init(
        authStore: CodexAuthStore,
        usageClient: CodexUsageClient,
        refreshAfterClaim: @escaping () async -> Void
    ) {
        self.init(
            usageClient: usageClient,
            credentialCandidates: { allowKeychainInteraction in
                var candidates = authStore.loadAuthCandidates()
                // Don't touch the Keychain at all while a usable file credential exists. The read
                // is a synchronous securityd round trip, so a wedged securityd would otherwise
                // block this claim indefinitely — leaving the row on "Resetting…" — even though the
                // file credential could have completed it on its own.
                if !allowKeychainInteraction, candidates.contains(where: \.hasUsableAccessToken) {
                    return candidates.compactMap { candidate in
                        guard candidate.hasUsableAccessToken, let token = candidate.auth.tokens?.accessToken else {
                            return nil
                        }
                        return (token, candidate.auth.tokens?.accountID)
                    }
                }
                // Claiming a reset credit is an explicit user action, so — like a manual refresh —
                // it may ask macOS to approve a protected keyring item. The caller only sets the
                // flag once the file credentials have actually been rejected, so a user whose
                // auth.json works never sees a dialog.
                let keychainLoad = await loadOffMainActor {
                    authStore.loadKeychainCredentials(allowKeychainInteraction: allowKeychainInteraction)
                }
                if case .permissionRequired = keychainLoad {
                    AppLog.warn(
                        LogTag.auth("codex"),
                        "reset claim could not read the Codex keyring item; approve it for Runway and try again"
                    )
                } else if case .connectRequired = keychainLoad {
                    AppLog.info(
                        LogTag.auth("codex"),
                        "reset claim deferred the Codex keyring read; connect the login and try again"
                    )
                }
                if let keychain = keychainLoad.state {
                    candidates.append(keychain)
                }
                return candidates.compactMap { candidate in
                    guard candidate.hasUsableAccessToken, let token = candidate.auth.tokens?.accessToken else {
                        return nil
                    }
                    return (token, candidate.auth.tokens?.accountID)
                }
            },
            refreshAfterClaim: refreshAfterClaim
        )
    }

    /// Claims the credit expiring at `expiry`. Never throws — every failure mode is logged loudly and
    /// collapsed to an outcome the popover can render.
    func claim(creditExpiringAt expiry: Date, redeemRequestID: String) async -> ResetClaimOutcome {
        // Prompt-free first, so a user whose `auth.json` works never sees a dialog and the happy
        // path costs exactly the same requests as before.
        let candidates = await credentialCandidates(false)
        let attempt = await claim(
            creditExpiringAt: expiry,
            redeemRequestID: redeemRequestID,
            candidates: candidates
        )
        // ONLY auth exhaustion justifies a dialog. A timeout or a 5xx says nothing about whether a
        // credential Runway can't read would have worked, and prompting through an outage would be
        // a dialog the user cannot act on.
        guard attempt.allRejected else { return attempt.outcome }

        // Every local credential was refused. A file token can be structurally fine and still be
        // dead, and the protected keyring item may hold the live one — so for this explicit user
        // action, ask for approval and try once more with whatever that adds.
        guard let approved = await interactiveCredentialCandidates() else {
            AppLog.warn(
                LogTag.plugin("codex"),
                "reset claim: timed out waiting for interactive Keychain credentials after "
                    + "\(Int(interactiveCredentialTimeout * 1000))ms"
            )
            return .failed
        }
        let seen = Set(candidates.map { "\($0.accessToken)|\($0.accountID ?? "")" })
        let fresh = approved.filter { !seen.contains("\($0.accessToken)|\($0.accountID ?? "")") }
        guard !fresh.isEmpty else { return attempt.outcome }
        AppLog.info(LogTag.plugin("codex"), "reset claim: retrying with a newly approved credential")
        return await claim(
            creditExpiringAt: expiry,
            redeemRequestID: redeemRequestID,
            candidates: fresh
        ).outcome
    }

    /// A claim is not owned by `WidgetDataStore`'s provider watchdog. Give its interactive
    /// credential read the same ceiling so a claim queued behind an abandoned approval dialog
    /// cannot leave the reset row pinned forever. The credential task is deliberately not awaited
    /// after losing the race: cancellation reaches `loadOffMainActor`, which removes a queued
    /// Keychain read without touching Security.framework; an already-active system dialog remains
    /// the one exclusive dialog and finishes harmlessly into the discarded task.
    private func interactiveCredentialCandidates() async -> [Credentials]? {
        await withCheckedContinuation { continuation in
            final class RaceState {
                var resumed = false
                var watchdog: Task<Void, Never>?
            }
            let state = RaceState()
            let credentialTask = Task {
                let candidates = await credentialCandidates(true)
                guard !state.resumed else { return }
                state.resumed = true
                state.watchdog?.cancel()
                continuation.resume(returning: candidates)
            }
            state.watchdog = Task { [interactiveCredentialTimeout] in
                try? await Task.sleep(for: .seconds(interactiveCredentialTimeout))
                guard !state.resumed, !Task.isCancelled else { return }
                state.resumed = true
                credentialTask.cancel()
                continuation.resume(returning: nil)
            }
        }
    }

    /// `allRejected` is true only when every credential was refused as unauthenticated — the sole
    /// case where asking for Keychain approval could change the answer. A timeout, a 5xx, or a
    /// non-auth consume failure must never raise a dialog.
    private func claim(
        creditExpiringAt expiry: Date,
        redeemRequestID: String,
        candidates: [Credentials]
    ) async -> (outcome: ResetClaimOutcome, allRejected: Bool) {
        guard !candidates.isEmpty else {
            AppLog.error(LogTag.plugin("codex"), "reset claim: no usable Codex credentials")
            // Nothing local at all: an approved keyring item is exactly what could supply one.
            return (.failed, true)
        }

        // A retry of an idempotency key that already matched replays the exact same (key, credit) pair
        // instead of re-matching: after a consume whose response was lost, the credit is no longer in
        // the list, and only the replay lets the server's `already_redeemed` prove the claim landed.
        let creditID: String
        var preferredCandidates = candidates
        if let replayID = matchedCreditIDs[redeemRequestID] {
            creditID = replayID
        } else {
            switch await matchCredit(expiringAt: expiry, candidates: candidates) {
            case .allRejected:
                return (.failed, true)
            case .matched(let id, let authenticated):
                creditID = id
                matchedCreditIDs[redeemRequestID] = id
                // Lead with the credential that just authenticated the list fetch. Deduplicate by the
                // full (token, account) pair — ChatGPT-Account-Id changes what a token is authorized
                // for, so a same-token candidate with a different account is a distinct fallback.
                preferredCandidates = [authenticated] + candidates.filter {
                    $0.accessToken != authenticated.accessToken || $0.accountID != authenticated.accountID
                }
            case .noCredit:
                // Not an error: the credit was claimed elsewhere (CLI/web) or expired since the popover
                // rendered. The refresh reconciles the timeline with reality.
                AppLog.warn(LogTag.plugin("codex"), "reset claim: no available credit matches the picked expiry")
                await refreshAfterClaim()
                return (.noCredit, false)
            case .failed:
                return (.failed, false)
            }
        }

        let consumed = await consume(
            creditID: creditID, redeemRequestID: redeemRequestID, candidates: preferredCandidates
        )
        if consumed.outcome != .failed {
            // The world changed (or turned out different from the snapshot): refresh before returning,
            // so the result banner appears over already-reconciled meters and credit count.
            await refreshAfterClaim()
        }
        return consumed
    }

    /// POSTs the consume, falling back across credential candidates on an auth rejection (401/403).
    /// Safe to repeat: every attempt carries the same idempotency key, so at most one credit is ever
    /// spent no matter how many candidates are tried.
    private func consume(
        creditID: String, redeemRequestID: String, candidates: [Credentials]
    ) async -> (outcome: ResetClaimOutcome, allRejected: Bool) {
        var lastRejection: Int?
        for credentials in candidates {
            let response: HTTPResponse
            do {
                response = try await usageClient.consumeResetCredit(
                    accessToken: credentials.accessToken,
                    accountID: credentials.accountID,
                    creditID: creditID,
                    redeemRequestID: redeemRequestID
                )
            } catch {
                AppLog.error(LogTag.plugin("codex"), "reset claim: consume request failed: \(error.localizedDescription)")
                return (.failed, false)
            }
            if response.statusCode == 401 || response.statusCode == 403 {
                lastRejection = response.statusCode
                continue
            }
            let outcome = Self.outcome(fromConsume: response)
            if outcome == .failed {
                AppLog.error(
                    LogTag.plugin("codex"),
                    "reset claim: consume failed (\(response.statusCode)): "
                        + LogRedaction.bodyPreview(String(decoding: response.body, as: UTF8.self), limit: 300)
                )
            }
            return (outcome, false)
        }
        AppLog.error(LogTag.plugin("codex"), "reset claim: consume rejected for every credential (last: \(lastRejection.map(String.init) ?? "none"))")
        return (.failed, true)
    }

    private enum MatchResult {
        case matched(creditID: String, credentials: Credentials)
        case noCredit
        /// Every candidate was rejected as unauthenticated (401/403) — the only failure where a
        /// credential Runway cannot read yet might be the one that works.
        case allRejected
        case failed
    }

    /// Fresh credit list (safe GET) → the id of the credit the user picked, matched by expiry. Tries
    /// each credential candidate in order, moving on when one is rejected as unauthenticated (401/403)
    /// — the same fallback the provider's probe applies — so a stale first auth file can't strand the
    /// claim while the dashboard works off a later one.
    private func matchCredit(expiringAt expiry: Date, candidates: [Credentials]) async -> MatchResult {
        var lastFailure = "no credential candidate authenticated"
        for credentials in candidates {
            let list: HTTPResponse
            do {
                list = try await usageClient.fetchResetCredits(
                    accessToken: credentials.accessToken, accountID: credentials.accountID
                )
            } catch {
                AppLog.error(LogTag.plugin("codex"), "reset claim: credit list fetch failed: \(error.localizedDescription)")
                return .failed
            }
            if list.statusCode == 401 || list.statusCode == 403 {
                lastFailure = "credit list fetch rejected (\(list.statusCode))"
                continue
            }
            guard (200..<300).contains(list.statusCode), let body = ProviderParse.jsonObject(list.body) else {
                AppLog.error(LogTag.plugin("codex"), "reset claim: credit list fetch failed (\(list.statusCode))")
                return .failed
            }
            guard let matched = Self.creditID(in: body, expiringAt: expiry) else { return .noCredit }
            return .matched(creditID: matched, credentials: credentials)
        }
        AppLog.error(LogTag.plugin("codex"), "reset claim: \(lastFailure)")
        return .allRejected
    }

    /// The id of the still-available credit whose `expires_at` matches `expiry` (±1s — the popover's
    /// dates round-trip through the same ISO-8601 parsing as this list, so a real match is exact; the
    /// tolerance only absorbs sub-second truncation). Mirrors the mapper's status filter: a credit with
    /// no `status` counts as available, only an explicit non-"available" state is skipped.
    static func creditID(in body: [String: Any], expiringAt expiry: Date) -> String? {
        guard let credits = body["credits"] as? [[String: Any]] else { return nil }
        return credits.first { credit in
            if let status = credit["status"] as? String, status != "available" { return false }
            guard let date = parseExpiry(credit["expires_at"]) else { return false }
            return abs(date.timeIntervalSince(expiry)) < 1
        }?["id"] as? String
    }

    /// Collapses a consume response to the popover's outcome. All four protocol codes arrive as HTTP
    /// 200 — the outcome is in the body — so a non-2xx or an unrecognized code is `.failed`.
    static func outcome(fromConsume response: HTTPResponse) -> ResetClaimOutcome {
        guard (200..<300).contains(response.statusCode),
              let body = ProviderParse.jsonObject(response.body),
              let code = body["code"] as? String
        else {
            return .failed
        }
        switch code {
        case "reset", "already_redeemed":
            return .success
        case "nothing_to_reset":
            return .nothingToReset
        case "no_credit":
            return .noCredit
        default:
            return .failed
        }
    }

    private static func parseExpiry(_ value: Any?) -> Date? {
        if let string = value as? String, let date = RunwayISO8601.date(from: string) {
            return date
        }
        if let seconds = ProviderParse.number(value) {
            return Date(timeIntervalSince1970: seconds)
        }
        return nil
    }
}

/// Exact-card routing for the app's only provider write. Every Codex card owns a service built from
/// that runtime's scoped auth store and HTTP client; a row can therefore never claim a reset against
/// whichever Codex login happened to be registered first.
@MainActor
final class CodexResetClaimRouter {
    private let servicesByProviderID: [String: CodexResetClaimService]

    init(servicesByProviderID: [String: CodexResetClaimService]) {
        self.servicesByProviderID = servicesByProviderID
    }

    func service(for providerID: String) -> CodexResetClaimService? {
        servicesByProviderID[providerID]
    }
}

/// Hands the claim service to the resets popover through the environment: `nil` (the default — previews,
/// share-card renders, reorder previews) renders the timeline read-only with no "Use" affordance.
private struct CodexResetClaimServiceKey: EnvironmentKey {
    static let defaultValue: CodexResetClaimService? = nil
}

extension EnvironmentValues {
    var codexResetClaim: CodexResetClaimService? {
        get { self[CodexResetClaimServiceKey.self] }
        set { self[CodexResetClaimServiceKey.self] = newValue }
    }
}
