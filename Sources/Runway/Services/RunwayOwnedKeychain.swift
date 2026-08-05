import Foundation

/// Storage for small durable values Runway itself owns. Provider credentials remain read-only and
/// continue to use `KeychainReading`; the iCloud device identity is not a credential or encryption
/// key, so it belongs in Runway's private Application Support directory instead of behind a
/// prompt-capable login-keychain call on the launch path.
protocol RunwayOwnedSecretStoring: Sendable {
    func read(service: String) throws -> String?
    func write(service: String, value: String) throws
}

/// Private, atomic file storage for Runway-owned identity values. `LocalTextFileAccessor.writeText`
/// publishes through a 0600 temporary file and rename, so a partial write cannot invent a new
/// iCloud identity and another local account cannot read the value. The service remains part of the
/// filename to keep development and production bundle identities isolated.
struct RunwayOwnedFileStore: RunwayOwnedSecretStoring {
    private let files: any TextFileAccessing
    private let directory: String

    init(
        files: any TextFileAccessing = LocalTextFileAccessor(),
        directory: String = "~/Library/Application Support/Runway/identity"
    ) {
        self.files = files
        self.directory = directory
    }

    func read(service: String) throws -> String? {
        try files.readTextIfPresent(path(for: service))
    }

    func write(service: String, value: String) throws {
        try files.writeText(path(for: service), value)
    }

    private func path(for service: String) -> String {
        let safeName = service.map { character in
            character.isLetter || character.isNumber || character == "." || character == "-"
                ? character
                : "_"
        }
        return "\(directory)/\(String(safeName))"
    }
}
