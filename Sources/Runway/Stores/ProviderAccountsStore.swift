import CryptoKit
import Foundation
import Observation

/// Card-id helpers for the account-first model. The account occupying a family's default home when
/// first observed keeps the bare family id (`claude`, `codex`) as its permanent record id — that is
/// what makes existing installs migrate by doing nothing. Any later account of the same family mints
/// `family@<hash8>` from its identity key.
enum ProviderAccountID {
    /// The family ids that participate in the account-first model.
    static let families: Set<String> = ["claude", "codex"]

    /// `claude@ab12cd34` — a stable, non-reversible id derived from the account's identity key.
    static func make(family: String, identityKey: String) -> String {
        "\(family)@\(hash8(identityKey))"
    }

    /// The 8-hex-char identity digest card ids are built from, exposed for other identity-derived
    /// ids (the iCloud remote-only pseudo providers).
    static func hash8(_ identityKey: String) -> String {
        let digest = SHA256.hash(data: Data(identityKey.lowercased().utf8))
        return digest.prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    /// The family a card id belongs to: `claude@ab12cd34` → `claude`, bare ids map to themselves.
    static func family(of cardID: String) -> String {
        cardID.firstIndex(of: "@").map { String(cardID[..<$0]) } ?? cardID
    }

    /// Whether a card id names an extra account card (`claude@ab12cd34`) rather than a bare
    /// provider id.
    static func isAccountCard(_ cardID: String) -> Bool {
        cardID.contains("@")
    }
}

/// One place an account is signed in. "Default" is a badge on a source (`holdsDefaultSource`), never
/// a key: it marks who currently occupies the default home, and it never drives ids or sort order —
/// a swap re-points source edges, cards don't move. Phase 1 only observes the default home; later
/// phases add config dirs, cswap vault slots, Codex homes, and Desktop logins as more kinds.
struct ProviderAccountSource: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        /// The provider's standard home for this machine (`~/.claude`, `~/.codex`, env override).
        case defaultHome
        /// A custom Claude config dir (a `CLAUDE_CONFIG_DIR` home kept besides the default).
        case configDir
        /// A Codex CLI home kept alongside the home currently supplying the default Codex card.
        case codexHome
    }

    var kind: Kind
    /// Canonical home path the source was observed at.
    var anchor: String?
    var holdsDefaultSource: Bool
    /// `configDir` only: the literal string whose hash names the source's keychain item (Claude Code
    /// hashes `CLAUDE_CONFIG_DIR` exactly as typed, so `~/x` and its absolute spelling differ).
    var keychainLiteral: String?

    init(kind: Kind, anchor: String?, holdsDefaultSource: Bool, keychainLiteral: String? = nil) {
        self.kind = kind
        self.anchor = anchor
        self.holdsDefaultSource = holdsDefaultSource
        self.keychainLiteral = keychainLiteral
    }
}

/// An account as the account-first model sees it: opaque identity key, stable record id minted at
/// creation, and the sources currently attaching to it.
struct ProviderAccountRecord: Codable, Equatable, Sendable {
    /// Stable id minted when the account is first seen; never re-derived. The first account observed
    /// at a family's default home gets the bare family id.
    var id: String
    var family: String
    var identityKey: String
    var label: String?
    /// A user-chosen card name (Rename in the card's context menu / Customize). Wins over `label`
    /// and the id-derived fallback; never touched by reconciliation.
    var customLabel: String?
    var sources: [ProviderAccountSource]
    /// Set by a future "Remove Account…". A tombstoned account is never resurrected by rescans.
    var removedTombstone: Bool = false

    /// The name a card carries without a rename. One active account keeps the stock family name;
    /// when discovery finds siblings, every account — including the bare-id/default card — carries
    /// its full account label so none is the ambiguous odd one out. A missing label falls back to
    /// the record id (owner decision 2: short-hash fallback, one rename away from good).
    ///
    /// Never contains `customLabel` — this is what gets baked into the launch `Provider`, and baking
    /// a rename there is how stale-name bugs are born.
    func derivedDisplayName(disambiguating: Bool) -> String {
        guard disambiguating else { return family.capitalized }
        guard let label = label?.nilIfEmpty else { return id }
        // Labels are our own "email (Org Name)" format. Keep the whole value: the email is the
        // useful account discriminator, while the org still distinguishes same-email logins.
        return "\(family.capitalized) — \(label)"
    }
}

/// The account-first registry (`runway.providerAccounts.v1`). Reconciled at every launch from the
/// default-home identity reads and the config-dir scan; authoritative from day one — there is no
/// parallel card model to drift from. Extra account cards render straight from these records, and
/// the UI observes it live for renames (`customLabel`).
@MainActor
@Observable
final class ProviderAccountsStore {
    static let storageKey = "runway.providerAccounts.v1"

    private let defaults: UserDefaults
    private(set) var records: [ProviderAccountRecord]
    /// Record ids observed during this launch's discovery pass. This is deliberately not persisted:
    /// an old account record remains available for customization/history, but must not make a lone
    /// currently discovered account use a disambiguated default name.
    @ObservationIgnored private var activeRecordIDs: Set<String> = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey) {
            do {
                self.records = try JSONDecoder().decode([ProviderAccountRecord].self, from: data)
            } catch {
                AppLog.error(.config, "provider-account records were undecodable; starting a fresh registry: \(error.localizedDescription)")
                self.records = []
            }
        } else {
            self.records = []
        }
    }

    /// One account observed this launch, before reconciliation assigns (or re-finds) its record id.
    /// (Named to avoid colliding with the `Observation` module the `@Observable` macro expands into.)
    struct AccountObservation {
        var family: String
        var identityKey: String
        var label: String?
        var sources: [ProviderAccountSource]
    }

    /// Merges this launch's observations into the persisted set. Phase 1 semantics: an observation
    /// updates its account's label and sources, or creates the record; the first account of a family
    /// gets the bare family id, a later one mints `family@<hash8>`. Records never move or vanish here
    /// — an account that went unobserved (logged out, unreadable identity) is simply left as it was,
    /// except that a newly observed default-home holder takes the default badge off every sibling.
    @discardableResult
    func reconcile(with observations: [AccountObservation]) -> [ProviderAccountRecord] {
        var updated = records
        var changed = false

        for observation in observations {
            let index = updated.firstIndex {
                $0.family == observation.family && $0.identityKey == observation.identityKey
            }
            if let index {
                guard !updated[index].removedTombstone else { continue }
                var record = updated[index]
                record.label = observation.label ?? record.label
                record.sources = observation.sources
                if record != updated[index] {
                    updated[index] = record
                    changed = true
                }
            } else {
                updated.append(ProviderAccountRecord(
                    id: Self.availableID(for: observation, in: updated),
                    family: observation.family,
                    identityKey: observation.identityKey,
                    label: observation.label,
                    sources: observation.sources
                ))
                changed = true
            }

            // The default badge is exclusive per family: when this observation holds it, strip it
            // from every sibling record (the account that swapped out no longer answers the bare id).
            if observation.sources.contains(where: \.holdsDefaultSource) {
                for index in updated.indices
                where updated[index].family == observation.family
                    && updated[index].identityKey != observation.identityKey
                    && updated[index].sources.contains(where: \.holdsDefaultSource)
                {
                    updated[index].sources = updated[index].sources.map { source in
                        var source = source
                        source.holdsDefaultSource = false
                        return source
                    }
                    changed = true
                }
            }
        }

        activeRecordIDs = Set(updated.compactMap { record in
            guard !record.removedTombstone,
                  observations.contains(where: {
                      $0.family == record.family && $0.identityKey == record.identityKey
                  })
            else {
                return nil
            }
            return record.id
        })

        if changed {
            records = updated
            persist()
        }
        return records
    }

    /// The derived default for a card id. The family name stays bare when only one account of that
    /// family was discovered this launch; two or more active siblings all include their labels.
    func derivedDisplayName(cardID: String) -> String? {
        guard let record = record(backingCardID: cardID) else { return nil }
        let activeSiblingCount = records.lazy.filter {
            $0.family == record.family && self.activeRecordIDs.contains($0.id)
        }.count
        return record.derivedDisplayName(
            disambiguating: activeRecordIDs.contains(record.id) && activeSiblingCount > 1
        )
    }

    /// The resolved card title for a card id, or `nil` when the card has no account record (a
    /// non-account provider keeps its static `Provider.displayName`). This is the one place a rename
    /// becomes a card title; the baked provider name always remains the derived default.
    func resolvedDisplayName(cardID: String) -> String? {
        guard let record = record(backingCardID: cardID) else { return nil }
        return record.customLabel?.nilIfEmpty ?? derivedDisplayName(cardID: cardID)
    }

    /// The account record supplying a runtime card this launch. Claude still uses one unscoped bare-id
    /// runtime for whichever login occupies the default home, so after a login swap that runtime can
    /// be backed by an `@`-suffixed record. Codex already builds scoped runtimes under each stable
    /// record id and therefore keeps the ordinary exact-id lookup.
    func record(backingCardID cardID: String) -> ProviderAccountRecord? {
        if cardID == "claude",
           let defaultHolder = records.first(where: {
               $0.family == "claude"
                   && activeRecordIDs.contains($0.id)
                   && $0.sources.contains(where: \.holdsDefaultSource)
           })
        {
            return defaultHolder
        }
        return records.first { $0.id == cardID }
    }

    /// Card id → resolved title for every record — the map the CLI/API boundary applies to its
    /// snapshots (`LocalUsageAPI.State.resolvingDisplayNames`).
    var resolvedDisplayNamesByCardID: [String: String] {
        Dictionary(uniqueKeysWithValues: records.compactMap { record in
            resolvedDisplayName(cardID: record.id).map { (record.id, $0) }
        })
    }

    /// Stores a user rename for a card; `nil` or blank clears it back to the derived name.
    func rename(cardID: String, to name: String?) {
        guard let recordID = record(backingCardID: cardID)?.id,
              let index = records.firstIndex(where: { $0.id == recordID })
        else {
            return
        }
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        guard records[index].customLabel != trimmed else { return }
        records[index].customLabel = trimmed
        persist()
    }

    /// The record currently holding a family's default badge, if any.
    func defaultBadgeHolder(family: String) -> ProviderAccountRecord? {
        records.first { record in
            record.family == family
                && !record.removedTombstone
                && record.sources.contains(where: \.holdsDefaultSource)
        }
    }

    /// The bare family id when free (the migration-killing rule: the first account observed at the
    /// default home IS the existing card), else an identity-derived `family@<hash8>` id. Only an
    /// account observed at the family's DEFAULT home may claim the bare id — that id's runtime reads
    /// the default home, so handing it to a custom-config-dir account would point the existing card
    /// at a login it can't read.
    private static func availableID(for observation: AccountObservation, in records: [ProviderAccountRecord]) -> String {
        let observedAtDefaultHome = observation.sources.contains { $0.kind == .defaultHome }
        if observedAtDefaultHome, !records.contains(where: { $0.id == observation.family }) {
            return observation.family
        }
        let derived = ProviderAccountID.make(family: observation.family, identityKey: observation.identityKey)
        guard records.contains(where: { $0.id == derived }) else { return derived }
        // A hash-prefix collision between two distinct identities of one family; salt until free.
        var attempt = 0
        while true {
            let salted = ProviderAccountID.make(
                family: observation.family,
                identityKey: "\(observation.identityKey)|\(attempt)"
            )
            if !records.contains(where: { $0.id == salted }) { return salted }
            attempt += 1
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(records) else {
            AppLog.error(.config, "failed to encode provider-account records; keeping previous persisted state")
            return
        }
        defaults.set(data, forKey: Self.storageKey)
    }
}
