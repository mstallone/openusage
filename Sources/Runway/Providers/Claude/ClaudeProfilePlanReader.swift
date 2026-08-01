import Foundation

/// Reads the plan values the badge should trust from Claude Code's state file (`.claude.json`),
/// which its regular profile refetch keeps current — unlike the credential blob's copies, written
/// once at login and stale after a plan change. `read()` returns `nil` (no file, no account,
/// nothing usable) to keep the blob's values. A file that exists but can't be read or parsed also
/// falls back — the badge must never fail a refresh — but is logged so a stale badge stays
/// diagnosable.
struct ClaudeProfilePlanReader: Sendable {
    var environment: EnvironmentReading
    var files: TextFileAccessing
    let scope: ClaudeCredentialScope

    func read() -> (subscriptionType: String?, rateLimitTier: String?)? {
        let text: String?
        do {
            text = try files.readTextIfPresent(stateFilePath())
        } catch {
            AppLog.warn(LogTag.auth("claude"), "state file unreadable; plan badge falls back to login-time values: \(error.localizedDescription)")
            return nil
        }
        guard let text else { return nil }
        guard let parsed = try? JSONDecoder().decode(
            DefaultAccountObserver.ClaudeStateFile.self, from: Data(text.utf8)
        ) else {
            AppLog.warn(LogTag.auth("claude"), "state file did not parse; plan badge falls back to login-time values")
            return nil
        }
        // A state file without `oauthAccount` is a normal logged-out shape, not an error.
        guard let account = parsed.oauthAccount else { return nil }
        let tier = account.userRateLimitTier?.nilIfEmpty ?? account.organizationRateLimitTier?.nilIfEmpty
        // Only a plan-shaped org type (`claude_max` → "max") may replace the blob's subscriptionType;
        // an unrecognized shape keeps the login value rather than guessing at a family.
        let subscription = account.organizationType?.nilIfEmpty.flatMap { orgType -> String? in
            guard orgType.hasPrefix("claude_") else { return nil }
            return String(orgType.dropFirst("claude_".count)).nilIfEmpty
        }
        // An empty plan is deliberately NOT treated as "subscription cleared": absent keys are
        // indistinguishable from a pre-plan-fields Claude Code state file, and unknown org shapes
        // (Team/enterprise) land here too. The blob's login-time values stand; a truly lapsed
        // subscription surfaces through the failing usage fetch, not the badge.
        guard tier != nil || subscription != nil else { return nil }
        return (subscription, tier)
    }

    /// Claude Code's state file for this scope — inside a custom config dir, but next to (not
    /// inside) the default home: Claude Code keeps the default's state at `~/.claude.json`.
    private func stateFilePath() -> String {
        if case .configDir(let path, _) = scope {
            return "\(path)/.claude.json"
        }
        guard let override = environment.value(for: "CLAUDE_CONFIG_DIR")?
            .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        else {
            return "~/.claude.json"
        }
        let isDefaultHome = (override as NSString).expandingTildeInPath
            == (ClaudeAuthStore.defaultClaudeHome as NSString).expandingTildeInPath
        return isDefaultHome ? "~/.claude.json" : "\(override)/.claude.json"
    }
}
