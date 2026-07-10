import Foundation
import CryptoKit

/// A persistent, self-maintaining disk cache for parsed lyrics.
///
/// Lyrics rarely change once fetched, so caching aggressively is almost pure
/// win: it saves your users' bandwidth, your worker's provider quotas, and
/// the YouTube search units the fetcher spends resolving video IDs. Hand an
/// instance to ``LyricsFetcher`` and every successful fetch is remembered
/// across launches:
///
/// ```swift
/// let cache = LyricsDiskCache()
/// let fetcher = LyricsFetcher(configuration: config, cache: cache)
/// ```
///
/// Housekeeping is automatic — expired entries are swept on startup, the
/// cache never grows past its size limit (oldest entries evicted first), and
/// bumping the internal schema version after a model change invalidates
/// stale payloads rather than serving them broken.
public actor LyricsDiskCache {
    /// Bump to invalidate every on-disk entry after a model/schema change.
    private static let schemaVersion = 1

    private struct Envelope: Codable {
        let schemaVersion: Int
        let lyrics: ParsedLyrics
        let cachedAt: Date
        let expiresAt: Date
    }

    private let fileManager = FileManager.default
    private let directory: URL
    private let retentionDays: Int
    private let maxSizeBytes: Int

    /// - Parameters:
    ///   - directory: Where to keep cache files. Defaults to
    ///     `Application Support/SyncedLyricsKit/LyricsCache` in the user
    ///     domain — survives relaunches, removed with the app's data.
    ///   - retentionDays: How long entries stay valid, clamped to 7–30 days.
    ///   - maxSizeBytes: Size ceiling; oldest entries are evicted past it.
    public init(
        directory: URL? = nil,
        retentionDays: Int = 14,
        maxSizeBytes: Int = 100 * 1024 * 1024
    ) {
        self.retentionDays = max(7, min(retentionDays, 30))
        self.maxSizeBytes = maxSizeBytes

        if let directory {
            self.directory = directory
        } else if let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            self.directory = support
                .appendingPathComponent("SyncedLyricsKit", isDirectory: true)
                .appendingPathComponent("LyricsCache", isDirectory: true)
        } else {
            self.directory = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("SyncedLyricsKit-LyricsCache", isDirectory: true)
        }

        Self.createDirectoryIfNeeded(at: self.directory)
        Self.sweepExpiredEntries(in: self.directory)
        Self.enforceSizeLimit(in: self.directory, maxSizeBytes: maxSizeBytes)
    }

    // MARK: - Public API

    /// Returns cached lyrics for a track, or `nil` on a miss. Expired and
    /// schema-stale entries are deleted on sight rather than returned.
    public func lyrics(
        title: String,
        artist: String,
        album: String = "",
        duration: TimeInterval = 0
    ) -> ParsedLyrics? {
        let url = fileURL(title: title, artist: artist, album: album, duration: duration)
        guard let data = try? Data(contentsOf: url),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else {
            return nil
        }

        guard envelope.schemaVersion == Self.schemaVersion, Date() <= envelope.expiresAt else {
            try? fileManager.removeItem(at: url)
            return nil
        }

        return envelope.lyrics
    }

    /// Stores lyrics for a track, stamping the current schema version and a
    /// retention-based expiry.
    public func store(
        _ lyrics: ParsedLyrics,
        title: String,
        artist: String,
        album: String = "",
        duration: TimeInterval = 0
    ) {
        let now = Date()
        let expiry = Calendar.current.date(byAdding: .day, value: retentionDays, to: now)
            ?? now.addingTimeInterval(TimeInterval(retentionDays) * 86_400)
        let envelope = Envelope(
            schemaVersion: Self.schemaVersion,
            lyrics: lyrics,
            cachedAt: now,
            expiresAt: expiry
        )

        guard let data = try? JSONEncoder().encode(envelope) else { return }
        let url = fileURL(title: title, artist: artist, album: album, duration: duration)
        try? data.write(to: url, options: .atomic)
        Self.enforceSizeLimit(in: directory, maxSizeBytes: maxSizeBytes)
    }

    /// Removes every cached entry — the escape hatch for "my lyrics look
    /// wrong, start fresh".
    public func clearAll() {
        try? fileManager.removeItem(at: directory)
        Self.createDirectoryIfNeeded(at: directory)
    }

    // MARK: - Keys

    private func fileURL(title: String, artist: String, album: String, duration: TimeInterval) -> URL {
        let components = [
            title.trimmingCharacters(in: .whitespacesAndNewlines),
            artist.trimmingCharacters(in: .whitespacesAndNewlines),
            album.trimmingCharacters(in: .whitespacesAndNewlines),
            String(Int(duration.rounded()))
        ].joined(separator: "|")

        let digest = SHA256.hash(data: Data(components.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name + ".json")
    }

    // MARK: - Housekeeping
    // Static (nonisolated) so the synchronous init can run them too.

    private static func createDirectoryIfNeeded(at directory: URL) {
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: directory.path) else { return }
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private static func sweepExpiredEntries(in directory: URL) {
        let fileManager = FileManager.default
        guard let contents = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return
        }
        for url in contents {
            guard let data = try? Data(contentsOf: url),
                  let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else {
                continue
            }
            if Date() > envelope.expiresAt || envelope.schemaVersion != Self.schemaVersion {
                try? fileManager.removeItem(at: url)
            }
        }
    }

    private static func enforceSizeLimit(in directory: URL, maxSizeBytes: Int) {
        let fileManager = FileManager.default
        guard let contents = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .creationDateKey]
        ) else {
            return
        }

        var totalSize = 0
        var files: [(url: URL, size: Int, created: Date)] = []
        for url in contents {
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .creationDateKey]) else { continue }
            let size = values.fileSize ?? 0
            totalSize += size
            files.append((url, size, values.creationDate ?? .distantPast))
        }

        guard totalSize > maxSizeBytes else { return }

        var toFree = totalSize - maxSizeBytes
        for file in files.sorted(by: { $0.created < $1.created }) {
            guard toFree > 0 else { break }
            try? fileManager.removeItem(at: file.url)
            toFree -= file.size
        }
    }
}
