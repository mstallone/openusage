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
    /// Returns a manually seeded in-memory value when its metadata is unchanged. Production never
    /// requests foreign secret data here; `.unavailable` means a manual read is required or the
    /// Keychain metadata could not be inspected.
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
    /// Why this item's last non-interactive read failed: `true` = the item exists and needs a manual
    /// secret read, `false` = its metadata could not be inspected, `nil` = no failure recorded.
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
    /// the service-only defaults above. Production overrides these with metadata/cache-only and
    /// prompt-capable in-process paths.
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
    /// `SecurityKeychainAccessor` overrides this with an in-process attributes-only probe that does
    /// not evaluate the item's secret ACL.
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

/// Serializes the prompt-capable Keychain reads started by explicit user actions. A manual
/// Refresh All starts providers concurrently, but macOS approval dialogs must appear one at a time.
/// Queued work remains cancellation-aware so an abandoned refresh never opens a stale dialog later.
///
/// Automatic paths never enter this gate and never request foreign secret data. This deliberately
/// avoids the deprecated process-global interaction switch: `LAContext.interactionNotAllowed` still
/// fails to suppress classic login-keychain ACL dialogs on macOS 26.6, while that switch can remain
/// disabled around an unbounded synchronous `SecItemCopyMatching` call.
enum InteractiveKeychainReadGate {
    private static let cancellationPollInterval: TimeInterval = 0.1
    private static let condition = NSCondition()
    nonisolated(unsafe) private static var nextInteractiveTicket: UInt64 = 0
    nonisolated(unsafe) private static var interactiveQueue: [UInt64] = []
    nonisolated(unsafe) private static var inFlight = false

    enum Turn {
        case available
        case cancelled
    }

    static func withTurn<T>(_ body: (_ turn: Turn) throws -> T) rethrows -> T {
        condition.lock()
        let ticket = nextInteractiveTicket
        nextInteractiveTicket &+= 1
        interactiveQueue.append(ticket)
        while inFlight || interactiveQueue.first != ticket {
            if Task.isCancelled {
                interactiveQueue.removeAll { $0 == ticket }
                condition.broadcast()
                condition.unlock()
                AppLog.debug(.keychain, "cancelled an interactive keychain operation while it was queued")
                return try body(.cancelled)
            }
            condition.wait(until: Date().addingTimeInterval(cancellationPollInterval))
        }
        interactiveQueue.removeFirst()
        if Task.isCancelled {
            condition.broadcast()
            condition.unlock()
            AppLog.debug(.keychain, "cancelled an interactive keychain operation before it reached Security.framework")
            return try body(.cancelled)
        }
        inFlight = true
        condition.unlock()
        defer {
            condition.lock()
            inFlight = false
            condition.broadcast()
            condition.unlock()
        }
        return try body(.available)
    }
}

/// Per-query UI suppression for metadata-only Keychain checks. The macOS 26.6 experiment showed
/// that this context does not suppress a classic item's ACL dialog when secret data is requested,
/// so automatic paths never use it for secrets. Metadata checks do not evaluate that item ACL, but
/// a locked login keychain can still ask to authenticate; this context makes that check fail locally
/// with `errSecInteractionNotAllowed` instead of presenting an unattended unlock dialog.
enum NonInteractiveKeychainMetadataQuery {
    static func applying(to query: [String: Any]) -> [String: Any] {
        var query = query
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        return query
    }
}

/// Every Keychain operation here goes through Security.framework in this process. There is no `/usr/bin/security`
/// path any more: a subprocess's approval names the helper binary rather than Runway, so it could
/// never turn into a durable Always Allow — which is how one approval became a recurring prompt.
struct SecurityKeychainAccessor: KeychainReading {
    private static let metadataTimestampResolution: TimeInterval = 1
    private static let metadataStabilizationLimit: TimeInterval = 2

    /// Gates every in-process secret read: change-gated caching, single-flight per item, and a
    /// circuit breaker after denials. See `KeychainReadCoordinator`.
    let coordinator: KeychainReadCoordinator
    private let metadataNow: @Sendable () -> Date
    private let waitForMetadataStability: @Sendable (TimeInterval) -> Void
    private let copyMatching: @Sendable (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus

    init(
        coordinator: KeychainReadCoordinator = .shared,
        metadataNow: @escaping @Sendable () -> Date = Date.init,
        waitForMetadataStability: @escaping @Sendable (TimeInterval) -> Void = {
            Thread.sleep(forTimeInterval: $0)
        },
        copyMatching: @escaping @Sendable (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus = {
            SecItemCopyMatching($0, $1)
        }
    ) {
        self.coordinator = coordinator
        self.metadataNow = metadataNow
        self.waitForMetadataStability = waitForMetadataStability
        self.copyMatching = copyMatching
    }

    /// The plain throwing reads are protocol requirements that exist for mocks; no auth store calls
    /// them, because each one picks the explicit non-interactive or interactive form. They are
    /// implemented here through the automatic metadata/cache-only path so that even a future caller
    /// cannot request foreign secret data without choosing the interactive API.
    func readGenericPassword(service: String) throws -> String? {
        try promptFreeValue(service: service, account: nil)
    }

    private func promptFreeValue(service: String, account: String?) throws -> String? {
        // Through the coordinator, not straight at Security: these reads get the same single-flight,
        // change-gating, and breaker as every other one, and the read is handed the ticket it needs
        // to attribute what it observes.
        switch readGenericPasswordWithoutUserInteraction(service: service, account: account) {
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
            fingerprint: { stabilizedAttributeFingerprint(service: service, account: account) },
            read: { ticket in try performInteractiveRead(service: service, account: account, ticket: ticket) }
        )
    }

    /// Runs the approval query inside Runway. Keychain access-control decisions, including
    /// "Always Allow", are attached to the requesting executable, so routing this through the
    /// `security` command would authorize that helper rather than Runway's future manual reads.
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
        var gateTurn = InteractiveKeychainReadGate.Turn.available
        let status = InteractiveKeychainReadGate.withTurn { turn -> OSStatus in
            gateTurn = turn
            guard turn != .cancelled else { return errSecNotAvailable }
            return copyMatching(query as CFDictionary, &item)
        }
        if status != errSecSuccess && status != errSecItemNotFound && gateTurn != .available {
            // The refresh was cancelled before this read reached Security.framework. A synthetic
            // failure says nothing about the item's ACL and must not trip its breaker.
            coordinator.recordContention(ticket)
            AppLog.warn(.keychain, "interactive read for service '\(service)' was cancelled before reaching Security.framework")
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
        // `LAContext.interactionNotAllowed` does not suppress classic login-keychain ACL dialogs on
        // macOS 26.6. Automatic paths therefore inspect metadata only and never request secret data.
        // An explicit user action seeds the coordinator's process-lifetime in-memory cache;
        // unchanged items are served from that cache before this method is reached.
        switch rawGenericPasswordExists(service: service, account: account) {
        case true:
            coordinator.recordFailureCategory(ticket, permissionDenied: true)
            AppLog.debug(.keychain, "automatic secret read deferred for service '\(service)'; manual refresh required")
            return .unavailable
        case false:
            return .missing
        case nil:
            coordinator.recordFailureCategory(ticket, permissionDenied: false)
            AppLog.debug(.keychain, "automatic secret read unavailable for service '\(service)'; metadata probe failed")
            return .unavailable
        }
    }

    /// Attributes-only existence probe used on the launch path: an in-process Security-framework
    /// query (no subprocess) that never requests the secret or evaluates its ACL. A failed probe
    /// reports `nil` ("unknown"), never a definite answer, so callers can pick their safe side.
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
        let query = NonInteractiveKeychainMetadataQuery.applying(to: [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ].merging(account.map { [kSecAttrAccount as String: $0] } ?? [:]) { current, _ in current })
        let status = copyMatching(query as CFDictionary, nil)
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
        guard let attributes = genericPasswordAttributes(service: service, account: account) else {
            return nil
        }
        return Self.fingerprint(attributes)
    }

    /// Keychain modification dates have one-second resolution. If a manual read occurs in the same
    /// second as a secret-only update, hashing the attributes immediately could bind the old secret
    /// to the new item's indistinguishable fingerprint for the rest of the process. Wait until the
    /// observed modification second closes, query the attributes again, and only then perform the
    /// one user-approved secret read. Continuous updates are bounded to two seconds and return no
    /// cacheable fingerprint rather than delaying the refresh indefinitely.
    private func stabilizedAttributeFingerprint(service: String, account: String?) -> String? {
        let deadline = metadataNow().addingTimeInterval(Self.metadataStabilizationLimit)
        while let attributes = genericPasswordAttributes(service: service, account: account) {
            guard let modifiedAt = attributes[kSecAttrModificationDate as String] as? Date else {
                return nil
            }
            let now = metadataNow()
            let stableAt = modifiedAt.addingTimeInterval(Self.metadataTimestampResolution)
            guard stableAt > now else { return Self.fingerprint(attributes) }
            guard stableAt <= deadline else { return nil }
            waitForMetadataStability(stableAt.timeIntervalSince(now) + 0.01)
        }
        return nil
    }

    private func genericPasswordAttributes(service: String, account: String?) -> [String: Any]? {
        let query = NonInteractiveKeychainMetadataQuery.applying(to: [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnAttributes as String: true,
        ].merging(account.map { [kSecAttrAccount as String: $0] } ?? [:]) { current, _ in current })
        var item: CFTypeRef?
        let status = copyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let attributes = item as? [String: Any]
        else {
            return nil
        }
        return attributes
    }

    private static func fingerprint(_ attributes: [String: Any]) -> String? {
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
