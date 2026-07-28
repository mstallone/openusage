import CommonCrypto
import CryptoKit
import Foundation
import LocalAuthentication
import Security

struct SakanaBrowserSession: Hashable, Sendable {
    var token: String
    var browserName: String
}

enum SakanaAuthError: Error, LocalizedError, Equatable {
    case notLoggedIn
    case permissionRequired
    case credentialsUnreadable
    case invalidCookie
    case sessionExpired

    var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            return "Sign in to Sakana AI Console in Chrome, Arc, Brave, or Edge to see Fugu usage."
        case .permissionRequired:
            return "Allow Runway to read your browser's Safe Storage key in Keychain, then refresh again. Choose Always Allow to permit automatic updates."
        case .credentialsUnreadable:
            return "Couldn't read the signed-in Sakana browser session. Open Sakana AI Console in a supported browser and refresh again."
        case .invalidCookie:
            return "The Sakana browser session couldn't be decoded. Sign in to Sakana AI Console again, then refresh."
        case .sessionExpired:
            return "The Sakana browser session expired. Sign in to Sakana AI Console again, then refresh."
        }
    }
}

struct SakanaBrowserCookieSource: Hashable, Sendable {
    var browserName: String
    var databasePath: String
    var safeStorageService: String
}

protocol SakanaSafeStorageKeyReading: Sendable {
    func readPassword(service: String, allowInteraction: Bool) throws -> String?
}

struct SakanaSafeStorageKeyReader: SakanaSafeStorageKeyReading {
    func readPassword(service: String, allowInteraction: Bool) throws -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true
        ]
        if !allowInteraction {
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context
        }

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data,
                  let password = String(data: data, encoding: .utf8),
                  !password.isEmpty
            else {
                throw SakanaBrowserCredentialError.invalidSafeStorageKey
            }
            return password
        case errSecItemNotFound:
            return nil
        case errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled:
            throw SakanaBrowserCredentialError.permissionRequired
        default:
            throw SakanaBrowserCredentialError.keychainFailure(Int(status))
        }
    }
}

enum SakanaBrowserCredentialError: Error, Sendable {
    case permissionRequired
    case invalidSafeStorageKey
    case keychainFailure(Int)
    case invalidCiphertext
    case decryptionFailed(Int32)
}

/// Borrows Sakana Console's Auth.js cookie from a signed-in Chromium browser. The cookie database is
/// read-only, the decrypted token exists only in memory, and Runway never refreshes or mutates it.
struct SakanaAuthStore: Sendable {
    static let cookieHost = "console.sakana.ai"
    static let cookieName = "__Secure-authjs.session-token"

    var sqlite: any SQLiteAccessing
    var files: any TextFileAccessing
    var keyReader: any SakanaSafeStorageKeyReading
    var sources: @Sendable () -> [SakanaBrowserCookieSource]
    private let keyCache: SakanaSafeStorageKeyCache

    init(
        sqlite: any SQLiteAccessing = SQLiteCLIAccessor(),
        files: any TextFileAccessing = LocalTextFileAccessor(),
        keyReader: any SakanaSafeStorageKeyReading = SakanaSafeStorageKeyReader(),
        sources: (@Sendable () -> [SakanaBrowserCookieSource])? = nil,
        homeDirectory: @escaping @Sendable () -> URL = { FileManager.default.homeDirectoryForCurrentUser },
        keyCache: SakanaSafeStorageKeyCache = SakanaSafeStorageKeyCache()
    ) {
        self.sqlite = sqlite
        self.files = files
        self.keyReader = keyReader
        self.sources = sources ?? { Self.discoverSources(homeDirectory: homeDirectory()) }
        self.keyCache = keyCache
    }

    /// Prompt-free local evidence used by first-run/new-provider detection. It checks the same exact
    /// cookie rows `loadSession` reads, but deliberately does not access Keychain or decrypt a secret.
    func hasBrowserSessionFootprint() -> Bool {
        scanCandidates().candidates.isEmpty == false
    }

    func loadSession(allowInteraction: Bool) throws -> SakanaBrowserSession {
        let scan = scanCandidates()
        let available = scan.candidates.sorted { $0.updatedAt > $1.updatedAt }
        guard !available.isEmpty else {
            if scan.sawMalformedCookie { throw SakanaAuthError.invalidCookie }
            if scan.sawDatabaseError { throw SakanaAuthError.credentialsUnreadable }
            throw SakanaAuthError.notLoggedIn
        }

        var sawUnreadableKey = false
        var sawInvalidCookie = false
        for candidate in available {
            do {
                let plaintext: Data
                switch candidate.storage {
                case .plain(let data):
                    plaintext = data
                case .encrypted(let data):
                    guard let key = try safeStorageKey(
                        service: candidate.source.safeStorageService,
                        allowInteraction: allowInteraction
                    ) else {
                        sawUnreadableKey = true
                        continue
                    }
                    plaintext = try Self.decryptCookie(data, key: key, host: candidate.host)
                }
                guard let token = Self.validToken(plaintext) else {
                    sawInvalidCookie = true
                    continue
                }
                return SakanaBrowserSession(token: token, browserName: candidate.source.browserName)
            } catch SakanaBrowserCredentialError.permissionRequired {
                throw SakanaAuthError.permissionRequired
            } catch {
                sawInvalidCookie = true
                AppLog.error(LogTag.auth("sakana"), "Sakana browser credential read failed: \(error.localizedDescription)")
            }
        }
        if sawUnreadableKey { throw SakanaAuthError.credentialsUnreadable }
        if sawInvalidCookie { throw SakanaAuthError.invalidCookie }
        throw SakanaAuthError.credentialsUnreadable
    }

    private enum StoredCookie {
        case plain(Data)
        case encrypted(Data)
    }

    private struct Candidate {
        var source: SakanaBrowserCookieSource
        var host: String
        var updatedAt: UInt64
        var storage: StoredCookie
    }

    private struct CandidateScan {
        var candidates: [Candidate] = []
        var sawDatabaseError = false
        var sawMalformedCookie = false
    }

    private func scanCandidates() -> CandidateScan {
        var scan = CandidateScan()
        for source in sources() {
            guard files.exists(source.databasePath) else { continue }
            do {
                if let candidate = try candidate(from: source) {
                    scan.candidates.append(candidate)
                }
            } catch is SakanaBrowserCredentialError {
                scan.sawMalformedCookie = true
                AppLog.error(LogTag.auth("sakana"), "Sakana browser cookie row was malformed.")
            } catch {
                scan.sawDatabaseError = true
                AppLog.error(LogTag.auth("sakana"), "Sakana browser cookie database read failed: \(error.localizedDescription)")
            }
        }
        return scan
    }

    private func candidate(from source: SakanaBrowserCookieSource) throws -> Candidate? {
        let sql = """
        SELECT hex(CAST(host_key AS BLOB)) || '|' ||
               CAST(last_update_utc AS TEXT) || '|' ||
               CASE
                   WHEN length(value) > 0 THEN 'plain:' || hex(CAST(value AS BLOB))
                   ELSE 'encrypted:' || hex(encrypted_value)
               END
        FROM cookies
        WHERE name = '\(Self.cookieName)'
          AND host_key IN ('\(Self.cookieHost)', '.\(Self.cookieHost)')
        ORDER BY last_update_utc DESC
        LIMIT 1;
        """
        guard let encoded = try sqlite.queryValue(path: source.databasePath, sql: sql) else {
            return nil
        }
        let fields = encoded.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
        guard fields.count == 3,
              let hostData = Self.data(hex: String(fields[0])),
              let host = String(data: hostData, encoding: .utf8),
              let updatedAt = UInt64(fields[1]),
              let separator = fields[2].firstIndex(of: ":"),
              let stored = Self.data(hex: String(fields[2][fields[2].index(after: separator)...]))
        else {
            throw SakanaBrowserCredentialError.invalidCiphertext
        }
        let mode = fields[2][..<separator]
        let storage: StoredCookie
        if mode == "plain" {
            storage = .plain(stored)
        } else if mode == "encrypted" {
            storage = .encrypted(stored)
        } else {
            throw SakanaBrowserCredentialError.invalidCiphertext
        }
        return Candidate(source: source, host: host, updatedAt: updatedAt, storage: storage)
    }

    private func safeStorageKey(service: String, allowInteraction: Bool) throws -> Data? {
        if let cached = keyCache.value(for: service) { return cached }
        guard let password = try keyReader.readPassword(
            service: service,
            allowInteraction: allowInteraction
        ) else {
            return nil
        }
        let key = try Self.deriveKey(password: password)
        keyCache.set(key, for: service)
        return key
    }

    static func discoverSources(homeDirectory: URL) -> [SakanaBrowserCookieSource] {
        let browsers = [
            ("Chrome", "Library/Application Support/Google/Chrome", "Chrome Safe Storage"),
            ("Arc", "Library/Application Support/Arc/User Data", "Arc Safe Storage"),
            ("Brave", "Library/Application Support/BraveSoftware/Brave-Browser", "Brave Safe Storage"),
            ("Edge", "Library/Application Support/Microsoft Edge", "Microsoft Edge Safe Storage")
        ]
        let manager = FileManager.default
        var result: [SakanaBrowserCookieSource] = []
        for (name, relativeRoot, service) in browsers {
            let root = homeDirectory.appendingPathComponent(relativeRoot, isDirectory: true)
            let profiles = (try? manager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            for profile in profiles.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let candidates = [
                    profile.appendingPathComponent("Network/Cookies"),
                    profile.appendingPathComponent("Cookies")
                ]
                if let database = candidates.first(where: { manager.fileExists(atPath: $0.path) }) {
                    result.append(SakanaBrowserCookieSource(
                        browserName: "\(name) (\(profile.lastPathComponent))",
                        databasePath: database.path,
                        safeStorageService: service
                    ))
                }
            }
        }
        return result
    }

    static func deriveKey(password: String) throws -> Data {
        let passwordData = Data(password.utf8)
        let salt = Data("saltysalt".utf8)
        var key = Data(count: kCCKeySizeAES128)
        let keyCount = key.count
        let status = key.withUnsafeMutableBytes { keyBytes in
            passwordData.withUnsafeBytes { passwordBytes in
                salt.withUnsafeBytes { saltBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.bindMemory(to: Int8.self).baseAddress,
                        passwordData.count,
                        saltBytes.bindMemory(to: UInt8.self).baseAddress,
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                        1003,
                        keyBytes.bindMemory(to: UInt8.self).baseAddress,
                        keyCount
                    )
                }
            }
        }
        guard status == kCCSuccess else {
            throw SakanaBrowserCredentialError.invalidSafeStorageKey
        }
        return key
    }

    static func decryptCookie(_ encrypted: Data, key: Data, host: String) throws -> Data {
        guard encrypted.count > 3,
              encrypted.prefix(3) == Data("v10".utf8) || encrypted.prefix(3) == Data("v11".utf8),
              key.count == kCCKeySizeAES128
        else {
            throw SakanaBrowserCredentialError.invalidCiphertext
        }
        let payload = encrypted.dropFirst(3)
        let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)
        var output = Data(count: payload.count + kCCBlockSizeAES128)
        var outputLength = 0
        let capacity = output.count
        let status = output.withUnsafeMutableBytes { outputBytes in
            payload.withUnsafeBytes { payloadBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress,
                            key.count,
                            ivBytes.baseAddress,
                            payloadBytes.baseAddress,
                            payload.count,
                            outputBytes.baseAddress,
                            capacity,
                            &outputLength
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else {
            throw SakanaBrowserCredentialError.decryptionFailed(status)
        }
        output.count = outputLength
        let hostHash = Data(SHA256.hash(data: Data(host.utf8)))
        return output.starts(with: hostHash) ? Data(output.dropFirst(hostHash.count)) : output
    }

    private static func validToken(_ data: Data) -> String? {
        guard let value = String(data: data, encoding: .utf8) else { return nil }
        let token = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard token.count >= 32,
              !token.contains(";"),
              token.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
        else {
            return nil
        }
        return token
    }

    private static func data(hex: String) -> Data? {
        guard hex.count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return Data(bytes)
    }
}

final class SakanaSafeStorageKeyCache: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]

    func value(for service: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return values[service]
    }

    func set(_ value: Data, for service: String) {
        lock.lock()
        values[service] = value
        lock.unlock()
    }
}
