import CryptoKit
import Darwin
import Foundation
import LocalAuthentication
import Security

protocol EnvironmentReading: Sendable {
    func value(for name: String) -> String?
}

struct ProcessEnvironmentReader: EnvironmentReading {
    var processEnvironment: [String: String] = ProcessInfo.processInfo.environment
    var shellEnvironment: LoginShellEnvironment = .shared
    var launchSnapshot: @Sendable () -> ShellEnvironmentSnapshot? = { ShellEnvironmentSnapshotStore.launchSnapshot }
    /// `false` reads the login-shell capture only when it is already warm, never spawning or waiting
    /// for it. Launch account discovery uses this: it runs off the main thread (where a cold read
    /// would otherwise block on the bounded 5s capture) but must keep the immediate-return semantics
    /// it had on the main thread, so a slow shell profile can't delay the menu-bar icon.
    var blocksOnShellCapture = true

    private static let identityKeys = Set(ShellEnvironmentSnapshot.capturedKeys)

    func value(for name: String) -> String? {
        // The process environment first (set by launchd, `launchctl setenv`, or a terminal launch),
        // then the captured login-shell environment — so keys a user exports in their shell profile
        // still resolve in a packaged app launched from Finder/Dock. See `LoginShellEnvironment`.
        if let value = processEnvironment[name]?.nilIfEmpty {
            return value
        }
        // Identity-relevant keys (provider home overrides, OAuth endpoint switches) resolve from the
        // persisted shell-environment snapshot when one exists: those facts — including "verifiably
        // NOT exported" — are frozen for the whole session, so every reader (the launch account pass
        // at init, the provider auth stores and log scanners whenever they run) sees the same home
        // overrides no matter when the async login-shell capture lands. Without the pin, an export
        // changed since the last launch would split them: identity read from the snapshot's home,
        // usage fetched from the freshly captured one, mis-stamping the shared snapshot cache. A
        // changed export applies from the next launch (the snapshot refresh task persists and logs
        // it). Every other key reads the live capture as before.
        if Self.identityKeys.contains(name), let snapshot = launchSnapshot() {
            return snapshot.values[name]?.nilIfEmpty
        }
        return blocksOnShellCapture
            ? shellEnvironment.value(for: name)
            : shellEnvironment.cachedValue(for: name)
    }
}


protocol SQLiteAccessing: Sendable {
    func queryValue(path: String, sql: String) throws -> String?
    /// Read-only query whose rows come back as a JSON array of objects (sqlite3 `-json` output).
    /// `nil` means the database is absent or the query matched no rows.
    func queryJSONRows(path: String, sql: String) throws -> String?
}

struct SQLiteCLIAccessor: SQLiteAccessing {
    var processRunner: ProcessRunning

    init(processRunner: ProcessRunning = SystemProcessRunner()) {
        self.processRunner = processRunner
    }

    func queryValue(path: String, sql: String) throws -> String? {
        // A normal sqlite3 open can create a missing database. Credential probes must be read-only and
        // side-effect free, so absence returns nil before a process is launched.
        guard try databaseExists(path) else { return nil }
        let result = try run(path: path, sql: sql, readOnly: true)
        guard result.succeeded else {
            throw SQLiteError.queryFailed(result.stderr)
        }
        let value = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    func queryJSONRows(path: String, sql: String) throws -> String? {
        // Same no-create discipline as `queryValue`: absence returns nil before sqlite3 launches.
        guard try databaseExists(path) else { return nil }
        var result = try run(path: path, sql: sql, readOnly: true, json: true)
        if !result.succeeded, result.stderr.contains("unable to open database file") {
            // A WAL-mode database whose -shm/-wal sidecars are missing cannot be opened with
            // -readonly (sqlite3 would have to create them). Nothing is writing such a database,
            // so an immutable open — read-only by definition, no sidecars needed — is safe.
            result = try run(
                path: immutableURI(forExpandedPath: expandHome(path)),
                sql: sql,
                readOnly: true,
                json: true
            )
        }
        guard result.succeeded else {
            throw SQLiteError.queryFailed(result.stderr)
        }
        let value = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func immutableURI(forExpandedPath path: String) -> String {
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        return "file:\(encoded)?immutable=1"
    }

    private func run(
        path: String,
        sql: String,
        readOnly: Bool = false,
        json: Bool = false
    ) throws -> ProcessResult {
        var arguments = ["-batch", "-noheader"]
        if readOnly { arguments.append("-readonly") }
        if json { arguments.append("-json") }
        arguments += [
            "-cmd", ".timeout 1000",
            expandHome(path),
            sql
        ]
        return try processRunner.run(
            executable: "/usr/bin/sqlite3",
            arguments: arguments,
            environment: [:],
            timeout: 5
        )
    }

    private func databaseExists(_ path: String) throws -> Bool {
        do {
            _ = try FileManager.default.attributesOfItem(atPath: expandHome(path))
            return true
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return false
        }
    }
}

enum SQLiteError: Error, LocalizedError, Equatable {
    case queryFailed(String)

    var errorDescription: String? {
        switch self {
        case .queryFailed(let message):
            return message.isEmpty ? "SQLite query failed." : message
        }
    }
}

enum NonInteractiveKeychainRead: Equatable, Sendable {
    case value(String)
    case missing
    case unavailable
}

/// Read-only view of the Keychain. Stores that consume another app's credentials (Claude, Copilot,
/// Antigravity, the default-account observer) receive ONLY this type, so writing a foreign
/// credential store is unrepresentable there at compile time — the ownership rule "only the app
/// that owns a credential may modify it", enforced by the type system.
protocol KeychainReading: Sendable {
    func readGenericPassword(service: String) throws -> String?
    func readGenericPasswordForCurrentUser(service: String) throws -> String?
    /// Interactive Security.framework reads used only after an explicit user action. These are
    /// separate requirements from the historical `security`-CLI reads so another app's Keychain ACL
    /// grants access to Runway itself, not to the `/usr/bin/security` helper process.
    func readGenericPasswordAllowingUserInteraction(service: String) throws -> String?
    func readGenericPasswordForCurrentUserAllowingUserInteraction(service: String) throws -> String?
    /// Reads a service-level item only when access is already authorized. Production forbids UI;
    /// `.unavailable` means validation would require interaction or the keychain could not be read.
    func readGenericPasswordWithoutUserInteraction(service: String) -> NonInteractiveKeychainRead
    func readGenericPasswordForCurrentUserWithoutUserInteraction(service: String) -> NonInteractiveKeychainRead
    /// Read a generic password scoped to an explicit account (`-a`). Used when another app stored the
    /// item under a known account name (e.g. Antigravity's `agy` token under service `gemini`,
    /// account `antigravity`) rather than the current user.
    func readGenericPassword(service: String, account: String) throws -> String?
    /// Account-scoped variants of the non-interactive / explicit-user-action reads, for foreign
    /// items stored under a known account name. Automatic refreshes use the non-interactive form
    /// (never a prompt); the interactive form runs only on a manual refresh and authorizes Runway
    /// itself, not a helper process.
    func readGenericPasswordWithoutUserInteraction(service: String, account: String) -> NonInteractiveKeychainRead
    func readGenericPasswordAllowingUserInteraction(service: String, account: String) throws -> String?
    /// Attributes-only existence probes. Keeping both overloads as protocol requirements is essential:
    /// callers hold `any KeychainReading`, so an extension-only service overload would statically call
    /// the fallback secret read instead of production's prompt-free Security.framework implementation.
    /// `nil` means the probe failed, not that the item is absent.
    func genericPasswordExists(service: String) -> Bool?
    func genericPasswordExists(service: String, account: String) -> Bool?
    /// Existence probe for the CURRENT-USER item specifically. It shares the exact
    /// `(service, currentUser)` identity that `readGenericPasswordForCurrentUserWithoutUserInteraction`
    /// uses, so a recovery probe joins that read's flight and breaker instead of launching an
    /// unrelated service-wide query that neither waits on it nor sees it fail.
    func genericPasswordForCurrentUserExists(service: String) -> Bool?
    /// Why this item's last non-interactive read failed: `true` = its ACL has not approved Runway
    /// (a manual refresh + Always Allow fixes it), `false` = the keychain itself couldn't be read
    /// (unlock it), `nil` = no failure recorded. Taken from the read's own `OSStatus`, so it stays
    /// answerable after the breaker trips — a follow-up probe would just be answered locally.
    func lastReadWasPermissionDenied(service: String, account: String) -> Bool?
    /// The same verdict for a SERVICE-WIDE read (no account), which is a distinct coordinator key
    /// from any account-scoped read of the same service.
    func lastReadWasPermissionDenied(service: String) -> Bool?
    /// The same verdict for the CURRENT-USER item, whose account name only the accessor knows.
    func lastReadForCurrentUserWasPermissionDenied(service: String) -> Bool?
    /// Opaque digest of an account-scoped item's non-secret attributes (including its modification
    /// date). Discovery binds a cached account identity to this so replacing a keyring item invalidates
    /// the old identity without reading its secret on the launch path.
    func genericPasswordAttributeFingerprint(service: String, account: String) -> String?
}

extension KeychainReading {
    func readGenericPasswordForCurrentUser(service: String) throws -> String? {
        try readGenericPassword(service: service)
    }

    func readGenericPasswordAllowingUserInteraction(service: String) throws -> String? {
        try readGenericPassword(service: service)
    }

    func readGenericPasswordForCurrentUserAllowingUserInteraction(service: String) throws -> String? {
        try readGenericPasswordForCurrentUser(service: service)
    }

    func readGenericPasswordWithoutUserInteraction(service: String) -> NonInteractiveKeychainRead {
        do {
            return try readGenericPassword(service: service).map(NonInteractiveKeychainRead.value) ?? .missing
        } catch {
            return .unavailable
        }
    }

    func readGenericPasswordForCurrentUserWithoutUserInteraction(service: String) -> NonInteractiveKeychainRead {
        do {
            return try readGenericPasswordForCurrentUser(service: service)
                .map(NonInteractiveKeychainRead.value) ?? .missing
        } catch {
            return .unavailable
        }
    }

    /// Default for mocks that don't model accounts: fall back to the service-only lookup. The real
    /// `SecurityKeychainAccessor` overrides this to pass `-a <account>`.
    func readGenericPassword(service: String, account: String) throws -> String? {
        try readGenericPassword(service: service)
    }

    /// Defaults for mocks: route the account-scoped modes through the plain account read, mirroring
    /// the service-only defaults above. Production overrides these with prompt-free / prompt-capable
    /// in-process queries.
    func readGenericPasswordWithoutUserInteraction(service: String, account: String) -> NonInteractiveKeychainRead {
        do {
            return try readGenericPassword(service: service, account: account)
                .map(NonInteractiveKeychainRead.value) ?? .missing
        } catch {
            return .unavailable
        }
    }

    func readGenericPasswordAllowingUserInteraction(service: String, account: String) throws -> String? {
        try readGenericPassword(service: service, account: account)
    }

    /// Whether an item exists for `service`, without reading its secret. `nil` means the probe
    /// itself failed (locked keychain, denied) — the caller picks its own safe side, which is not
    /// the same for every caller. The default (for mocks) falls back to a read; the real
    /// `SecurityKeychainAccessor` overrides this with an in-process attributes-only probe, safe for
    /// the launch path — it can't trigger an unlock prompt and returns in microseconds.
    func genericPasswordExists(service: String) -> Bool? {
        do {
            return try readGenericPassword(service: service) != nil
        } catch {
            return nil
        }
    }

    func genericPasswordExists(service: String, account: String) -> Bool? {
        do {
            return try readGenericPassword(service: service, account: account) != nil
        } catch {
            return nil
        }
    }

    func genericPasswordForCurrentUserExists(service: String) -> Bool? {
        genericPasswordExists(service: service)
    }

    func lastReadWasPermissionDenied(service: String, account: String) -> Bool? {
        nil
    }

    func lastReadWasPermissionDenied(service: String) -> Bool? {
        nil
    }

    func lastReadForCurrentUserWasPermissionDenied(service: String) -> Bool? {
        nil
    }

    func genericPasswordAttributeFingerprint(service: String, account: String) -> String? {
        nil
    }
}

/// Process-wide guard that keeps Security.framework from showing ANY keychain UI while a
/// non-interactive operation runs. `LAContext.interactionNotAllowed` (via
/// `kSecUseAuthenticationContext`) only governs data-protection keychain items; Claude Code and
/// other CLIs store classic login-keychain items, whose ACL confirmation dialog ("Runway wants to
/// use your confidential information…") ignores that flag AND `kSecUseAuthenticationUI` — verified
/// empirically on macOS 15: both query shapes still block on the dialog. The one switch securityd's
/// classic path honors is `SecKeychainSetUserInteractionAllowed`; under it a protected item returns
/// `errSecAuthFailed` immediately instead of prompting.
///
/// The switch is process-global, so the two sides exclude each other for their whole durations:
/// an interactive operation registers itself, waits out any in-flight suppressed call (those are
/// prompt-free by construction and finish in milliseconds), and keeps new suppressed entrants
/// parked until it completes — an approval dialog can sit open for minutes, and a background read
/// slipping in under it would flip the flag to `false` right when the user clicks Always Allow.
/// Suppressed calls only ever wait on a user-attended dialog, never on each other (they refcount),
/// so background refreshes pause at most while the user is answering a prompt they asked for.
enum KeychainUISuppression {
    /// How long either side waits on the other before giving up. Both directions are bounded so a
    /// wedged or abandoned operation degrades to a friendly local failure instead of a hang.
    private static let interactiveGateWait: TimeInterval = 2
    private static let condition = NSCondition()
    nonisolated(unsafe) private static var suppressedDepth = 0
    nonisolated(unsafe) private static var interactiveCount = 0
    /// Whether an interactive operation currently holds the gate. See `withUIAllowed`.
    nonisolated(unsafe) private static var interactiveInFlight = false
    /// Whether the outermost scope's disable call actually succeeded. The setter essentially never
    /// fails, but if it does, running the protected query anyway could show the exact background
    /// dialog this gate exists to prevent — so bodies receive this and skip the prompt-capable call.
    nonisolated(unsafe) private static var suppressionActive = false
    /// A failed restore would leave the process unable to show approval prompts; interactive
    /// callers retry it.
    nonisolated(unsafe) private static var restoreFailed = false

    /// `body` receives whether keychain UI is genuinely disabled. When `false` (the disable call
    /// failed — logged loudly), the body must NOT issue a prompt-capable Security.framework call
    /// and should report its non-interactive "unavailable" outcome instead.
    static func withUISuppressed<T>(_ body: (_ isSuppressed: Bool) throws -> T) rethrows -> T {
        condition.lock()
        // Bounded, like the interactive side. An approval dialog can sit open for minutes — or be
        // abandoned behind another window — and parking here forever would strand every concurrent
        // refresh in exactly the contention this gate exists to prevent. Past the deadline the body
        // runs with `isSuppressed: false`, which by contract means "do not issue a prompt-capable
        // call": the caller reports its local unavailable outcome without touching Security.framework.
        let deadline = Date().addingTimeInterval(interactiveGateWait)
        while interactiveCount > 0, Date() < deadline {
            condition.wait(until: deadline)
        }
        if interactiveCount > 0 {
            condition.unlock()
            AppLog.warn(.keychain, "keychain UI gate still held by an interactive operation; treating this background read as unavailable")
            return try body(false)
        }
        suppressedDepth += 1
        if suppressedDepth == 1 {
            let status = SecKeychainSetUserInteractionAllowed(false)
            suppressionActive = status == errSecSuccess
            if !suppressionActive {
                AppLog.error(.keychain, "failed to disable keychain UI for a background operation (status \(status)); treating the operation as unavailable")
            }
        }
        let isSuppressed = suppressionActive
        condition.unlock()
        defer {
            condition.lock()
            suppressedDepth -= 1
            if suppressedDepth == 0 {
                // Runway never disables keychain UI outside this scope, so the process default
                // (allowed) is the correct restore value.
                let status = SecKeychainSetUserInteractionAllowed(true)
                if status != errSecSuccess {
                    restoreFailed = true
                    AppLog.error(.keychain, "failed to re-enable keychain UI after a background operation (status \(status)); approval prompts may not appear until retried")
                }
                suppressionActive = false
                condition.broadcast()
            }
            condition.unlock()
        }
        return try body(isSuppressed)
    }

    /// Runs one interactive Security.framework operation with the gate held: registered first (so
    /// no new suppressed call can start underneath it), then waiting out in-flight suppressed calls.
    /// No deadlock is possible: a registered interactive caller only waits on suppressed calls that
    /// already hold `suppressedDepth`, and those never wait on anything once entered. The deadline
    /// only guards against a wedged suppressed call — it cannot be extended by new entrants, because
    /// those park on `interactiveCount` instead.
    /// What the gate could give this caller. The two failure modes need OPPOSITE handling, so they
    /// must not collapse into one flag:
    ///
    /// - `.suppressionStuck` — UI is still disabled by a wedged suppressed call. Running the query
    ///   is safe and worthwhile (an already-authorized item reads fine), but a FAILURE says nothing
    ///   about the item's ACL, because no prompt was possible.
    /// - `.peerBusy` — another provider's approval dialog is open and UI is ENABLED. The query must
    ///   NOT run: it would put a second dialog on screen beside the first, which is the storm this
    ///   gate exists to prevent.
    enum InteractiveUI {
        case available
        case suppressionStuck
        case peerBusy
    }

    static func withUIAllowed<T>(_ body: (_ ui: InteractiveUI) throws -> T) rethrows -> T {
        condition.lock()
        // Interactive operations are EXCLUSIVE of one another, not just of suppressed ones. A
        // Refresh All starts every provider at once, so without this a single click could put
        // several macOS approval dialogs on screen together — the prompt storm this gate exists to
        // prevent. The wait is bounded because an approval dialog can be abandoned: waiting forever
        // would hang every other provider's manual refresh behind an unrelated dialog. Past the
        // deadline the caller is told UI is unavailable, so it reports "keychain busy" instead of
        // either hanging or opening a second dialog next to the first.
        let peerDeadline = Date().addingTimeInterval(interactiveGateWait)
        while interactiveInFlight, Date() < peerDeadline {
            condition.wait(until: peerDeadline)
        }
        guard !interactiveInFlight else {
            condition.unlock()
            AppLog.warn(.keychain, "interactive keychain operation skipped: another approval dialog is still open")
            return try body(.peerBusy)
        }
        interactiveInFlight = true
        interactiveCount += 1
        let deadline = Date().addingTimeInterval(interactiveGateWait)
        while suppressedDepth > 0, Date() < deadline {
            condition.wait(until: deadline)
        }
        // A previously failed restore leaves the process-wide flag disabled; retry before an
        // interactive query so approval prompts aren't permanently broken.
        if restoreFailed, suppressedDepth == 0,
           SecKeychainSetUserInteractionAllowed(true) == errSecSuccess
        {
            restoreFailed = false
        }
        let suppressionStuck = suppressedDepth > 0
        condition.unlock()
        if suppressionStuck {
            // A suppressed call has been wedged in securityd for over 2s — pathological. Still run
            // the body rather than fail preemptively or wait forever: an already-authorized item
            // reads fine even with UI disabled. But the body is told UI is unavailable, because a
            // needs-prompt item will now fail with a status that LOOKS like an ACL denial when in
            // truth the prompt was never possible.
            AppLog.warn(.keychain, "interactive keychain operation proceeding while a suppressed call is stuck; an approval prompt may not appear")
        }
        defer {
            condition.lock()
            interactiveCount -= 1
            interactiveInFlight = false
            condition.broadcast()
            condition.unlock()
        }
        return try body(suppressionStuck ? .suppressionStuck : .available)
    }
}

/// Every read here goes through Security.framework in this process. There is no `/usr/bin/security`
/// path any more: a subprocess's approval names the helper binary rather than Runway, so it could
/// never turn into a durable Always Allow — which is how one approval became a recurring prompt.
struct SecurityKeychainAccessor: KeychainReading {
    /// Gates every in-process secret read: change-gated caching, single-flight per item, and a
    /// circuit breaker after denials. See `KeychainReadCoordinator`.
    let coordinator: KeychainReadCoordinator

    init(coordinator: KeychainReadCoordinator = .shared) {
        self.coordinator = coordinator
    }

    /// The plain throwing reads are protocol requirements that exist for mocks; no auth store calls
    /// them, because each one picks the explicit non-interactive or interactive form. They are
    /// implemented here as prompt-free in-process reads so that even a future caller cannot bring
    /// back a dialog on an automatic path — this is where the `/usr/bin/security` subprocess used to
    /// be, and its prompts authorized the helper binary rather than Runway.
    func readGenericPassword(service: String) throws -> String? {
        try promptFreeValue(service: service, account: nil)
    }

    private func promptFreeValue(service: String, account: String?) throws -> String? {
        switch performNonInteractiveRead(service: service, account: account) {
        case .value(let value):
            return value
        case .missing:
            return nil
        case .unavailable:
            throw KeychainError.readFailed("The keychain item could not be read without asking you.")
        }
    }

    func readGenericPasswordAllowingUserInteraction(service: String) throws -> String? {
        try readGenericPasswordAllowingUserInteraction(service: service, account: nil)
    }

    func readGenericPasswordForCurrentUserAllowingUserInteraction(service: String) throws -> String? {
        try readGenericPasswordAllowingUserInteraction(service: service, account: currentUserAccount())
    }

    func readGenericPasswordAllowingUserInteraction(service: String, account: String) throws -> String? {
        try readGenericPasswordAllowingUserInteraction(service: service, account: account as String?)
    }

    private func readGenericPasswordAllowingUserInteraction(
        service: String,
        account: String?
    ) throws -> String? {
        try coordinator.interactiveRead(
            service: service,
            account: account,
            fingerprint: { attributeFingerprint(service: service, account: account) },
            read: { ticket in try performInteractiveRead(service: service, account: account, ticket: ticket) }
        )
    }

    /// Runs the approval query inside Runway. Keychain access-control decisions, including
    /// "Always Allow", are attached to the requesting executable, so routing this through the
    /// `security` command would authorize that helper rather than the app's later silent reads.
    private func performInteractiveRead(
        service: String,
        account: String?,
        ticket: KeychainReadCoordinator.ReadTicket
    ) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ].merging(account.map { [kSecAttrAccount as String: $0] } ?? [:]) { current, _ in current }
        var item: CFTypeRef?
        var gateUI = KeychainUISuppression.InteractiveUI.available
        let status = KeychainUISuppression.withUIAllowed { ui -> OSStatus in
            gateUI = ui
            // A peer's dialog is open and UI is ENABLED, so querying here would put a second dialog
            // beside it. Don't call Security at all.
            guard ui != .peerBusy else { return errSecNotAvailable }
            return SecItemCopyMatching(query as CFDictionary, &item)
        }
        if gateUI == .peerBusy || (status != errSecSuccess && status != errSecItemNotFound && gateUI != .available) {
            // Either no prompt was possible, or none was attempted. A denial-shaped status here says
            // nothing about this item's ACL, and recording it would trip the item and hand the user
            // an Always Allow instruction for a dialog that was never shown.
            coordinator.recordContention(ticket)
            AppLog.warn(.keychain, "interactive read for service '\(service)' skipped or failed while the UI gate was unavailable")
            throw KeychainError.readFailed("The keychain was busy. Try refreshing again.")
        }
        switch status {
        case errSecSuccess:
            guard let data = item as? Data,
                  let value = String(data: data, encoding: .utf8)
            else {
                return ""
            }
            return value
        case errSecItemNotFound:
            return nil
        default:
            // The user just answered the dialog, so a denial here is the strongest evidence about
            // this item's ACL there is. Record it: this read trips the breaker, and every later
            // probe is then answered locally with no status to classify.
            coordinator.recordFailureCategory(
                ticket,
                permissionDenied: status == errSecAuthFailed
                    || status == errSecInteractionNotAllowed
                    || status == errSecUserCanceled
                    || status == errAuthorizationDenied
            )
            let message = SecCopyErrorMessageString(status, nil) as String?
                ?? "Keychain read failed with status \(status)."
            AppLog.warn(.keychain, "in-process read failed for service '\(service)' (status \(status))")
            throw KeychainError.readFailed(message)
        }
    }

    func readGenericPasswordWithoutUserInteraction(service: String) -> NonInteractiveKeychainRead {
        readGenericPasswordWithoutUserInteraction(service: service, account: nil)
    }

    func readGenericPasswordForCurrentUserWithoutUserInteraction(service: String) -> NonInteractiveKeychainRead {
        readGenericPasswordWithoutUserInteraction(service: service, account: currentUserAccount())
    }

    func readGenericPasswordWithoutUserInteraction(service: String, account: String) -> NonInteractiveKeychainRead {
        readGenericPasswordWithoutUserInteraction(service: service, account: account as String?)
    }

    private func readGenericPasswordWithoutUserInteraction(
        service: String,
        account: String?
    ) -> NonInteractiveKeychainRead {
        coordinator.nonInteractiveRead(
            service: service,
            account: account,
            fingerprint: { attributeFingerprint(service: service, account: account) },
            read: { ticket in performNonInteractiveRead(service: service, account: account, ticket: ticket) }
        )
    }

    private func performNonInteractiveRead(
        service: String,
        account: String?,
        ticket: KeychainReadCoordinator.ReadTicket
    ) -> NonInteractiveKeychainRead {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
            kSecUseAuthenticationContext as String: Self.nonInteractiveAuthenticationContext(),
        ].merging(account.map { [kSecAttrAccount as String: $0] } ?? [:]) { current, _ in current }
        var item: CFTypeRef?
        // Whether the gate actually engaged. When it didn't, another provider's approval dialog held
        // it and this read never reached securityd — the synthetic status below says nothing about
        // THIS item, so it must not be read as an ACL denial or trip its breaker.
        var gateEngaged = true
        let status = KeychainUISuppression.withUISuppressed { isSuppressed in
            gateEngaged = isSuppressed
            return isSuppressed ? SecItemCopyMatching(query as CFDictionary, &item) : errSecInteractionNotAllowed
        }
        guard gateEngaged else {
            coordinator.recordContention(ticket)
            AppLog.debug(.keychain, "read for service '\(service)' skipped: another approval dialog holds the keychain UI gate")
            return .unavailable
        }
        switch status {
        case errSecSuccess:
            guard let data = item as? Data,
                  let value = String(data: data, encoding: .utf8)
            else {
                return .value("")
            }
            return .value(value)
        case errSecItemNotFound:
            return .missing
        default:
            // errSecAuthFailed / errSecInteractionNotAllowed mean the item EXISTS and its ACL does
            // not (yet) authorize Runway — the status itself distinguishes that from a keychain we
            // simply could not read, so remember it rather than probing again later (the breaker
            // would answer that probe locally). Log the status only — never the item value.
            coordinator.recordFailureCategory(
                ticket,
                permissionDenied: status == errSecAuthFailed || status == errSecInteractionNotAllowed
            )
            AppLog.debug(.keychain, "non-interactive read unavailable for service '\(service)' (status \(status))")
            return .unavailable
        }
    }

    /// Attributes-only existence probe used on the launch path: an in-process Security-framework
    /// query (no subprocess, returns in microseconds) that never requests the secret and forbids
    /// any UI, so it can neither trigger an unlock prompt nor stall launch. A failed probe (locked
    /// keychain, denied) reports `nil` ("unknown"), never a definite answer, so callers can pick
    /// their safe side.
    func genericPasswordExists(service: String) -> Bool? {
        coordinator.probe(service: service, account: nil) {
            rawGenericPasswordExists(service: service, account: nil)
        }
    }

    func genericPasswordExists(service: String, account: String) -> Bool? {
        coordinator.probe(service: service, account: account) {
            rawGenericPasswordExists(service: service, account: account)
        }
    }

    func lastReadWasPermissionDenied(service: String, account: String) -> Bool? {
        coordinator.lastFailureWasPermissionDenied(service: service, account: account)
    }

    func lastReadWasPermissionDenied(service: String) -> Bool? {
        coordinator.lastFailureWasPermissionDenied(service: service, account: nil)
    }

    func lastReadForCurrentUserWasPermissionDenied(service: String) -> Bool? {
        coordinator.lastFailureWasPermissionDenied(service: service, account: currentUserAccount())
    }

    func genericPasswordForCurrentUserExists(service: String) -> Bool? {
        let account = currentUserAccount()
        return coordinator.probe(service: service, account: account) {
            rawGenericPasswordExists(service: service, account: account)
        }
    }

    private func rawGenericPasswordExists(service: String, account: String?) -> Bool? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: Self.nonInteractiveAuthenticationContext(),
        ].merging(account.map { [kSecAttrAccount as String: $0] } ?? [:]) { current, _ in current }
        let status = KeychainUISuppression.withUISuppressed { isSuppressed in
            isSuppressed ? SecItemCopyMatching(query as CFDictionary, nil) : errSecInteractionNotAllowed
        }
        switch status {
        case errSecSuccess: return true
        case errSecItemNotFound: return false
        default: return nil
        }
    }

    func readGenericPasswordForCurrentUser(service: String) throws -> String? {
        try promptFreeValue(service: service, account: currentUserAccount())
    }

    func readGenericPassword(service: String, account: String) throws -> String? {
        try promptFreeValue(service: service, account: account)
    }

    func genericPasswordAttributeFingerprint(service: String, account: String) -> String? {
        coordinator.probe(service: service, account: account) {
            attributeFingerprint(service: service, account: account)
        }
    }

    /// Attributes-only fingerprint (no `kSecReturnData`, so the item's ACL is never evaluated):
    /// prompt-free, in-process, microseconds. `nil` means the item is absent or the probe failed —
    /// the coordinator treats both as "cannot cache". Deliberately RAW (not routed through
    /// `coordinator.probe`): the coordinated read paths invoke it while already holding the item's
    /// flight, which the probe gate would wait on.
    private func attributeFingerprint(service: String, account: String?) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnAttributes as String: true,
            kSecUseAuthenticationContext as String: Self.nonInteractiveAuthenticationContext(),
        ].merging(account.map { [kSecAttrAccount as String: $0] } ?? [:]) { current, _ in current }
        var item: CFTypeRef?
        let status = KeychainUISuppression.withUISuppressed { isSuppressed in
            isSuppressed ? SecItemCopyMatching(query as CFDictionary, &item) : errSecInteractionNotAllowed
        }
        guard status == errSecSuccess,
              let attributes = item as? [String: Any]
        else {
            return nil
        }

        // The query never requests `kSecReturnData`, so this contains metadata only. Normalize every
        // attribute before hashing; callers receive no raw account, path, dates, labels, or access
        // group, and an in-place `-U` update changes the modification-date component.
        let normalized = attributes.map { key, value in
            "\(key)=\(Self.stableKeychainAttribute(value))"
        }.sorted().joined(separator: "\n")
        guard !normalized.isEmpty else { return nil }
        return SHA256.hash(data: Data(normalized.precomposedStringWithCanonicalMapping.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func stableKeychainAttribute(_ value: Any) -> String {
        switch value {
        case let value as Data:
            return value.base64EncodedString()
        case let value as Date:
            return String(value.timeIntervalSinceReferenceDate)
        case let value as String:
            return value
        case let value as NSNumber:
            return value.stringValue
        default:
            return String(describing: value)
        }
    }

    private static func nonInteractiveAuthenticationContext() -> LAContext {
        let context = LAContext()
        context.interactionNotAllowed = true
        return context
    }

    private func currentUserAccount() -> String {
        ProcessInfo.processInfo.environment["USER"]?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        ?? NSUserName()
    }
}

enum KeychainError: Error, LocalizedError {
    case writeFailed(String)
    case readFailed(String)

    var errorDescription: String? {
        switch self {
        case .writeFailed(let message):
            return message.isEmpty ? "Keychain write failed." : message
        case .readFailed(let message):
            return message.isEmpty ? "Keychain read failed." : message
        }
    }
}

func expandHome(_ path: String) -> String {
    guard path == "~" || path.hasPrefix("~/") else { return path }
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    if path == "~" { return home }
    return home + String(path.dropFirst())
}
