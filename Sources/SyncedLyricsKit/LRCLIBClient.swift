import Foundation

/// A source of lyrics used as a fallback when the primary worker path fails
/// or returns nothing usable. Abstracted so tests can inject a stub without
/// touching the network.
public protocol LyricsFallbackClient: Sendable {
    /// Looks up lyrics for a track. Returns `nil` when nothing was found;
    /// throws only for unexpected transport failures.
    func fetchLyrics(
        title: String,
        artist: String,
        album: String,
        duration: TimeInterval
    ) async throws -> ParsedLyrics?
}

/// The default ``LyricsFallbackClient``: a direct, **keyless** client for the
/// free [LRCLIB](https://lrclib.net/) API. No worker, no account, no API key.
///
/// It first tries the exact `/api/get` lookup (which matches on
/// title/artist/album/duration), and when that misses — most often because
/// no `duration` was supplied, or it was slightly off — falls back to
/// `/api/search` and picks the closest result. Synced lyrics are preferred;
/// plain lyrics are used only when no synced version exists.
public struct LRCLIBClient: LyricsFallbackClient {
    private static let baseURL = URL(string: "https://lrclib.net/api")!

    private let session: URLSession
    private let userAgent: String

    /// - Parameters:
    ///   - session: Override for testing. When `nil`, an ephemeral session is
    ///     built (no cookies/credentials, bypasses the URL cache).
    ///   - userAgent: Identifies this client to LRCLIB, which asks callers to
    ///     send a descriptive User-Agent.
    public init(
        session: URLSession? = nil,
        userAgent: String = "SyncedLyricsKit (+https://github.com/otherkdr/SyncedLyricsKit)"
    ) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(configuration: configuration)
        }
        self.userAgent = userAgent
    }

    public func fetchLyrics(
        title: String,
        artist: String,
        album: String,
        duration: TimeInterval
    ) async throws -> ParsedLyrics? {
        // Exact match first — cheapest and most accurate when duration is known.
        if let track = try await get(title: title, artist: artist, album: album, duration: duration),
           let lyrics = track.parsedLyrics {
            return lyrics
        }

        // Fall back to fuzzy search (handles missing/mismatched duration).
        let results = try await search(title: title, artist: artist)
        guard let best = Self.bestMatch(results, title: title, artist: artist, duration: duration) else {
            return nil
        }
        return best.parsedLyrics
    }

    // MARK: - Endpoints

    private func get(title: String, artist: String, album: String, duration: TimeInterval) async throws -> Track? {
        var items = [
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "artist_name", value: artist)
        ]
        if !album.isEmpty { items.append(URLQueryItem(name: "album_name", value: album)) }
        if duration > 0 { items.append(URLQueryItem(name: "duration", value: String(Int(duration.rounded())))) }

        guard let data = try await requestJSON(path: "get", queryItems: items) else { return nil }
        return try? JSONDecoder().decode(Track.self, from: data)
    }

    private func search(title: String, artist: String) async throws -> [Track] {
        let items = [
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "artist_name", value: artist)
        ]
        guard let data = try await requestJSON(path: "search", queryItems: items) else { return [] }
        return (try? JSONDecoder().decode([Track].self, from: data)) ?? []
    }

    /// Returns response data for a 200, `nil` for a 404 (LRCLIB's "not found"),
    /// and throws for other transport failures.
    private func requestJSON(path: String, queryItems: [URLQueryItem]) async throws -> Data? {
        var components = URLComponents(url: Self.baseURL.appending(path: path), resolvingAgainstBaseURL: false)
        components?.queryItems = queryItems
        guard let url = components?.url else { return nil }

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode == 404 { return nil }
        return data
    }

    // MARK: - Matching

    /// Picks the closest search hit: exact-ish title/artist, then the nearest
    /// duration when one is known.
    static func bestMatch(_ tracks: [Track], title: String, artist: String, duration: TimeInterval) -> Track? {
        let normTitle = TrackMetadataNormalizer.normalized(title)
        let normArtist = TrackMetadataNormalizer.normalized(artist)

        let scored = tracks.filter { track in
            let t = TrackMetadataNormalizer.normalized(track.trackName)
            let a = TrackMetadataNormalizer.normalized(track.artistName)
            let titleOK = normTitle.isEmpty || t.contains(normTitle) || normTitle.contains(t)
            let artistOK = normArtist.isEmpty || a.contains(normArtist) || normArtist.contains(a)
            return titleOK && artistOK
        }
        guard !scored.isEmpty else { return nil }

        guard duration > 0 else { return scored.first }
        return scored.min { lhs, rhs in
            abs((lhs.duration ?? 0) - duration) < abs((rhs.duration ?? 0) - duration)
        }
    }

    // MARK: - Response model

    struct Track: Decodable {
        let trackName: String
        let artistName: String
        let duration: TimeInterval?
        let syncedLyrics: String?
        let plainLyrics: String?
        let instrumental: Bool?

        /// Synced lyrics preferred; plain text only when there is no synced
        /// version. Instrumental tracks yield nothing.
        var parsedLyrics: ParsedLyrics? {
            if instrumental == true { return nil }
            if let synced = syncedLyrics, !synced.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let lyrics = SyncedLyrics.parse(lrc: synced) {
                return lyrics
            }
            if let plain = plainLyrics?.trimmingCharacters(in: .whitespacesAndNewlines), !plain.isEmpty {
                return .plain(plain)
            }
            return nil
        }
    }
}
