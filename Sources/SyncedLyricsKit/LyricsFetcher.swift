import Foundation

/// Errors thrown by ``LyricsFetcher``.
public enum LyricsFetchError: Error, Sendable {
    /// No Google API key was configured; YouTube search requires one.
    case missingGoogleAPIKey
    /// A request URL could not be constructed.
    case invalidURL
    /// The server answered with a non-200 status code.
    case requestFailed(statusCode: Int)
    /// No YouTube video could be matched to the track metadata.
    case noTopicVideoFound
}

/// Configuration for ``LyricsFetcher``.
public struct LyricsFetcherConfiguration: Sendable {
    /// A placeholder worker URL. **Replace this with your own deployment** —
    /// see the README's *Setting Up a Lyrics Backend* section for how to
    /// create and deploy a [better-lyrics/cf-api](https://github.com/better-lyrics/cf-api)
    /// Cloudflare Worker. Requests against the placeholder will fail.
    public static let placeholderWorkerBaseURL = URL(string: "https://better-lyrics-api.your-account.workers.dev")!

    /// Base URL of your deployed better-lyrics/cf-api Cloudflare Worker,
    /// e.g. `https://lyrics-api.my-account.workers.dev`.
    public var workerBaseURL: URL

    /// A Google Cloud API key with the **YouTube Data API v3** enabled.
    ///
    /// This key is used exclusively for `search.list` calls that resolve the
    /// currently playing track to its official "Topic" video ID — the worker
    /// needs that video ID to aggregate lyrics. Create one in the
    /// [Google Cloud Console](https://console.cloud.google.com/): enable
    /// *YouTube Data API v3*, then *Credentials → Create Credentials → API
    /// Key*, and restrict the key to that API. Each `search.list` call costs
    /// 100 quota units of the 10,000/day free tier; the fetcher caches
    /// resolved video IDs in memory (and, with a ``LyricsDiskCache``, whole
    /// results on disk) so repeat plays don't re-spend it.
    public var googleAPIKey: String

    /// JWT for the worker's `Authorization: Bearer` header, obtained via its
    /// Turnstile challenge flow. Leave `nil` when the worker runs with
    /// `BYPASS_AUTH = "true"` (local development only).
    public var authorizationToken: String?

    /// The `User-Agent` sent with every request. Identify your app here —
    /// it's good API citizenship and helps provider-side debugging.
    public var userAgent: String

    /// Per-request timeout in seconds.
    public var requestTimeout: TimeInterval

    /// Whole-transfer timeout in seconds.
    public var resourceTimeout: TimeInterval

    public init(
        workerBaseURL: URL = placeholderWorkerBaseURL,
        googleAPIKey: String,
        authorizationToken: String? = nil,
        userAgent: String = "SyncedLyricsKit/1.0 (+https://github.com/otherkdr/SyncedLyricsKit)",
        requestTimeout: TimeInterval = 8,
        resourceTimeout: TimeInterval = 12
    ) {
        self.workerBaseURL = workerBaseURL
        self.googleAPIKey = googleAPIKey
        self.authorizationToken = authorizationToken
        self.userAgent = userAgent
        self.requestTimeout = requestTimeout
        self.resourceTimeout = resourceTimeout
    }
}

/// The full SyncedLyrics fetching pipeline, ready to drop behind any
/// now-playing source:
///
/// 1. **Resolve** — searches YouTube (Data API v3) for the track as an
///    official *"Topic"* video, scores every candidate, sanity-checks the
///    winner against the metadata, and retries with stricter queries when
///    the first pass looks off. When your player reports incomplete
///    metadata, the resolved video's title fills the gaps.
/// 2. **Fetch** — hands the video ID plus track metadata to your
///    [better-lyrics/cf-api](https://github.com/better-lyrics/cf-api)
///    Cloudflare Worker.
/// 3. **Parse** — decodes the response through
///    ``WorkerLyricsResponse/bestLyrics()``; if the payload doesn't match
///    the expected shape, falls back to scanning the raw JSON for known
///    lyric fields, and finally follows any embedded lyric URLs the worker
///    returned.
///
/// Robustness is built in rather than bolted on:
///
/// - **Request coalescing** — concurrent fetches for the same track join a
///   single in-flight request instead of racing each other.
/// - **Two-level caching** — resolved video IDs are cached in memory, and
///   with a ``LyricsDiskCache`` attached, whole parsed results persist
///   across launches. Empty payloads are never cached, so a transient
///   upstream hiccup can't poison a track forever.
///
/// ```swift
/// let fetcher = LyricsFetcher(
///     configuration: .init(
///         workerBaseURL: URL(string: "https://lyrics-api.my-account.workers.dev")!,
///         googleAPIKey: "AIza…"
///     ),
///     cache: LyricsDiskCache()
/// )
///
/// let lyrics = try await fetcher.fetchLyrics(
///     title: "Pink + White", artist: "Frank Ocean",
///     album: "Blonde", duration: 184
/// )
/// ```
public actor LyricsFetcher {
    private let configuration: LyricsFetcherConfiguration
    private let session: URLSession
    private let cache: LyricsDiskCache?

    private var topicVideoCache: [String: String] = [:]
    private var inFlightFetches: [String: Task<ParsedLyrics?, Error>] = [:]

    private static let youtubeSearchBaseURL = "https://www.googleapis.com/youtube/v3/search"

    /// - Parameters:
    ///   - configuration: Endpoints, keys, and timeouts.
    ///   - cache: Optional persistent cache; strongly recommended for apps.
    ///   - session: Override for testing. When `nil`, an ephemeral session
    ///     is built from the configuration's timeouts (no cookie/credential
    ///     persistence, waits for connectivity, bypasses the URL cache since
    ///     caching is handled explicitly).
    public init(
        configuration: LyricsFetcherConfiguration,
        cache: LyricsDiskCache? = nil,
        session: URLSession? = nil
    ) {
        self.configuration = configuration
        self.cache = cache

        if let session {
            self.session = session
        } else {
            let sessionConfiguration = URLSessionConfiguration.ephemeral
            sessionConfiguration.timeoutIntervalForRequest = configuration.requestTimeout
            sessionConfiguration.timeoutIntervalForResource = configuration.resourceTimeout
            sessionConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData
            sessionConfiguration.waitsForConnectivity = true
            self.session = URLSession(configuration: sessionConfiguration)
        }
    }

    // MARK: - Public API

    /// Fetches the best available lyrics for a track.
    ///
    /// Concurrent calls for the same track share one request. Returns `nil`
    /// when everything worked but no source had lyrics; throws for
    /// configuration and transport failures.
    public func fetchLyrics(
        title: String,
        artist: String,
        album: String = "",
        duration: TimeInterval = 0
    ) async throws -> ParsedLyrics? {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAlbum = album.trimmingCharacters(in: .whitespacesAndNewlines)
        let requestKey = [
            TrackMetadataNormalizer.normalized(trimmedTitle),
            TrackMetadataNormalizer.normalized(trimmedArtist),
            TrackMetadataNormalizer.normalized(trimmedAlbum),
            String(Int(duration.rounded()))
        ].joined(separator: "\u{1F}")

        // Persistent cache first — but only trust a payload that actually
        // carries content. An empty result cached during a transient
        // upstream failure would otherwise be served forever.
        if let cached = await cache?.lyrics(title: trimmedTitle, artist: trimmedArtist, album: trimmedAlbum, duration: duration),
           !cached.isEmpty {
            return cached
        }

        // Join an identical fetch already in flight rather than duplicating it.
        if let inFlight = inFlightFetches[requestKey] {
            return try await inFlight.value
        }

        let task = Task<ParsedLyrics?, Error> {
            try await self.performFetch(
                title: trimmedTitle,
                artist: trimmedArtist,
                album: trimmedAlbum,
                duration: duration
            )
        }
        inFlightFetches[requestKey] = task
        defer { inFlightFetches[requestKey] = nil }

        let lyrics = try await task.value
        if let lyrics, !lyrics.isEmpty {
            await cache?.store(lyrics, title: trimmedTitle, artist: trimmedArtist, album: trimmedAlbum, duration: duration)
        }
        return lyrics
    }

    /// Drops the in-memory video-ID cache (and the disk cache, when one is
    /// attached). Use when the user asks for a hard refresh.
    public func clearCaches() async {
        topicVideoCache.removeAll()
        await cache?.clearAll()
    }

    // MARK: - Pipeline

    private func performFetch(
        title: String,
        artist: String,
        album: String,
        duration: TimeInterval
    ) async throws -> ParsedLyrics? {
        let resolution = try await resolveTopicVideo(title: title, artist: artist, album: album)
        let (data, response) = try await requestWorker(
            videoId: resolution.videoId,
            title: title.isEmpty ? (resolution.inferredTitle ?? "") : title,
            artist: artist.isEmpty ? (resolution.inferredArtist ?? "") : artist,
            album: album,
            duration: duration
        )

        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw LyricsFetchError.requestFailed(statusCode: http.statusCode)
        }
        guard !data.isEmpty else { return nil }

        // Preferred path: the typed worker response with source-priority
        // selection.
        if let decoded = try? JSONDecoder().decode(WorkerLyricsResponse.self, from: data),
           let lyrics = decoded.bestLyrics(), !lyrics.isEmpty {
            return lyrics
        }

        // The shape didn't match (worker fork, schema drift) — scan the raw
        // JSON for anything that looks like lyrics under the known keys.
        if let lyrics = Self.lyricsFromRawJSON(data), !lyrics.isEmpty {
            return lyrics
        }

        // Last resort: the response may point at the lyrics rather than
        // embed them. Follow any URLs it contains and parse what they serve.
        if let lyrics = await lyricsFromEmbeddedURLs(in: data), !lyrics.isEmpty {
            return lyrics
        }

        return nil
    }

    // MARK: - Step 1: YouTube topic-video resolution

    struct TopicVideoResolution: Sendable {
        let videoId: String
        let inferredTitle: String?
        let inferredArtist: String?
    }

    private func resolveTopicVideo(title: String, artist: String, album: String) async throws -> TopicVideoResolution {
        let key = configuration.googleAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw LyricsFetchError.missingGoogleAPIKey }

        let normalizedTitle = TrackMetadataNormalizer.normalized(title)
        let normalizedArtist = TrackMetadataNormalizer.normalized(artist)
        let cacheKey = TrackMetadataNormalizer.cacheKey(title: title, artist: artist, album: album)

        if let cached = topicVideoCache[cacheKey] {
            return TopicVideoResolution(videoId: cached, inferredTitle: nil, inferredArtist: nil)
        }

        for query in Self.searchQueries(title: title, artist: artist, album: album) {
            guard let candidates = try? await searchYouTube(query: query, apiKey: key),
                  let best = Self.bestCandidate(from: candidates, title: normalizedTitle, artist: normalizedArtist) else {
                continue
            }

            if Self.candidateMatches(best, title: normalizedTitle, artist: normalizedArtist) {
                topicVideoCache[cacheKey] = best.videoId
                let inferred = Self.inferredMetadata(from: best, title: title, artist: artist)
                return TopicVideoResolution(videoId: best.videoId, inferredTitle: inferred.title, inferredArtist: inferred.artist)
            }

            // The top result didn't obviously match — retry with stricter,
            // more explicit queries before settling for it.
            let stricterQueries = [
                "\(artist) \(title) official audio",
                "\(artist) \(title) official video",
                "\(title) \(artist) lyrics",
                "\(title) \(artist) audio",
                "\(title) \(artist) live"
            ]
            for stricter in stricterQueries {
                guard let retried = try? await searchYouTube(query: stricter, apiKey: key),
                      let candidate = Self.bestCandidate(from: retried, title: normalizedTitle, artist: normalizedArtist),
                      Self.candidateMatches(candidate, title: normalizedTitle, artist: normalizedArtist) else {
                    continue
                }
                topicVideoCache[cacheKey] = candidate.videoId
                let inferred = Self.inferredMetadata(from: candidate, title: title, artist: artist)
                return TopicVideoResolution(videoId: candidate.videoId, inferredTitle: inferred.title, inferredArtist: inferred.artist)
            }

            // Nothing stricter matched either — accept the original best
            // guess rather than failing outright, but don't cache a weak
            // match where it could shadow a better one later.
            let inferred = Self.inferredMetadata(from: best, title: title, artist: artist)
            return TopicVideoResolution(videoId: best.videoId, inferredTitle: inferred.title, inferredArtist: inferred.artist)
        }

        throw LyricsFetchError.noTopicVideoFound
    }

    private func searchYouTube(query: String, apiKey: String) async throws -> [VideoCandidate] {
        var components = URLComponents(string: Self.youtubeSearchBaseURL)
        components?.queryItems = [
            URLQueryItem(name: "part", value: "snippet"),
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "type", value: "video"),
            // Category 10 = Music; keeps results on-topic.
            URLQueryItem(name: "videoCategoryId", value: "10"),
            URLQueryItem(name: "maxResults", value: "10"),
            URLQueryItem(name: "key", value: apiKey)
        ]
        guard let url = components?.url else { throw LyricsFetchError.invalidURL }

        let (data, response) = try await session.data(for: makeRequest(url: url))
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw LyricsFetchError.requestFailed(statusCode: http.statusCode)
        }

        let decoded = try JSONDecoder().decode(SearchResponse.self, from: data)
        return decoded.items.compactMap { item in
            guard let id = item.id.videoId, !id.isEmpty else { return nil }
            return VideoCandidate(videoId: id, channelTitle: item.snippet.channelTitle, title: item.snippet.title)
        }
    }

    // MARK: - Step 2: worker request

    private func requestWorker(
        videoId: String,
        title: String,
        artist: String,
        album: String,
        duration: TimeInterval
    ) async throws -> (Data, URLResponse) {
        var components = URLComponents(
            url: configuration.workerBaseURL.appending(path: "lyrics"),
            resolvingAgainstBaseURL: false
        )

        var queryItems = [URLQueryItem(name: "videoId", value: videoId)]
        if !title.isEmpty { queryItems.append(URLQueryItem(name: "song", value: title)) }
        if !artist.isEmpty { queryItems.append(URLQueryItem(name: "artist", value: artist)) }
        if !album.isEmpty { queryItems.append(URLQueryItem(name: "album", value: album)) }
        if duration > 0 { queryItems.append(URLQueryItem(name: "duration", value: String(Int(duration)))) }
        components?.queryItems = queryItems

        guard let url = components?.url else { throw LyricsFetchError.invalidURL }

        var request = makeRequest(url: url)
        if let token = configuration.authorizationToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return try await session.data(for: request)
    }

    private func makeRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = configuration.requestTimeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(configuration.userAgent, forHTTPHeaderField: "User-Agent")
        return request
    }

    // MARK: - Step 3 fallbacks: raw JSON scan and embedded URLs

    /// The worker field names that can carry lyrics, in quality order.
    private static let knownLyricKeys = [
        "binimumTtml",
        "goLyricsApiTtml",
        "musixmatchWordByWordLyrics",
        "goLyricsApiLyrics",
        "qqLyricsApiLyrics",
        "kugouLyricsApiLyrics",
        "musixmatchSyncedLyrics",
        "lrclibSyncedLyrics",
        "lrclibPlainLyrics"
    ]

    /// Scans arbitrary JSON for the known lyric fields (at any nesting
    /// depth) and parses the first one that yields usable lyrics. Keeps the
    /// fetcher working against worker forks whose envelope drifted from the
    /// canonical schema.
    static func lyricsFromRawJSON(_ data: Data) -> ParsedLyrics? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let strings = collectStrings(from: object) else {
            return nil
        }

        for key in knownLyricKeys {
            guard let candidate = strings[key] else { continue }
            if let lyrics = SyncedLyrics.parse(candidate), !lyrics.isEmpty {
                return lyrics
            }
        }

        return nil
    }

    /// Follows any http(s) URLs found in the response body — some worker
    /// configurations return links to lyrics instead of embedding them —
    /// and tries the full decode chain on whatever each URL serves.
    private func lyricsFromEmbeddedURLs(in data: Data) async -> ParsedLyrics? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let strings = Self.collectStrings(from: object) else {
            return nil
        }

        let urls = Array(Set(strings.values)).filter { value in
            let lower = value.lowercased()
            return lower.hasPrefix("http://") || lower.hasPrefix("https://")
        }

        for candidate in urls {
            guard let url = URL(string: candidate) else { continue }

            var request = makeRequest(url: url)
            request.setValue(
                "application/json,text/html,application/xml,text/xml,*/*",
                forHTTPHeaderField: "Accept"
            )

            guard let (fetched, response) = try? await session.data(for: request) else { continue }
            if let http = response as? HTTPURLResponse, http.statusCode != 200 { continue }
            guard !fetched.isEmpty else { continue }

            if let decoded = try? JSONDecoder().decode(WorkerLyricsResponse.self, from: fetched),
               let lyrics = decoded.bestLyrics(), !lyrics.isEmpty {
                return lyrics
            }
            if let lyrics = Self.lyricsFromRawJSON(fetched), !lyrics.isEmpty {
                return lyrics
            }
            if let body = String(data: fetched, encoding: .utf8),
               let lyrics = SyncedLyrics.parse(body), !lyrics.isEmpty {
                return lyrics
            }
        }

        return nil
    }

    /// Flattens a decoded JSON tree into a key → string map of every
    /// non-empty string value, at any depth.
    static func collectStrings(from object: Any) -> [String: String]? {
        var result: [String: String] = [:]

        func walk(_ value: Any) {
            if let dictionary = value as? [String: Any] {
                for (key, nested) in dictionary {
                    if let string = nested as? String,
                       !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        result[key] = string
                    } else {
                        walk(nested)
                    }
                }
            } else if let array = value as? [Any] {
                for item in array {
                    walk(item)
                }
            }
        }

        walk(object)
        return result.isEmpty ? nil : result
    }

    // MARK: - Pure helpers (internal for testability)

    struct VideoCandidate: Sendable {
        let videoId: String
        let channelTitle: String
        let title: String
    }

    /// Builds the ordered YouTube query list for a track. "Topic" queries
    /// come first because official auto-generated `Artist - Topic` channels
    /// carry the cleanest metadata for lyrics matching; album variants and
    /// symbol-sanitized titles follow; bare-metadata fallbacks close it out.
    static func searchQueries(title: String, artist: String, album: String) -> [String] {
        func compact(_ value: String) -> String {
            value.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
        }

        let song = compact(title)
        let performer = compact(artist)
        let record = compact(album)
        var queries: [String] = []

        if !performer.isEmpty && !song.isEmpty {
            queries.append("\(performer) \(song) topic")
            queries.append("\(song) \(performer) topic")
            queries.append("\(performer) \(song)")
            queries.append("\(song) topic")
        }

        if !record.isEmpty {
            if !performer.isEmpty && !song.isEmpty {
                queries.append("\(performer) \(song) \(record) topic")
            } else if !performer.isEmpty {
                queries.append("\(performer) \(record) topic")
                queries.append("\(record) lyrics")
            } else if !song.isEmpty {
                queries.append("\(song) \(record) topic")
                queries.append("\(record) lyrics")
            }
        }

        // Symbol noise in titles ("Pink + White") hurts search relevance.
        let sanitized = song
            .replacingOccurrences(of: " + ", with: " ")
            .replacingOccurrences(of: "+", with: " ")
        if sanitized != song, !performer.isEmpty {
            queries.append("\(performer) \(sanitized) topic")
            queries.append("\(sanitized) topic")
        }

        if !song.isEmpty && performer.isEmpty {
            queries.append("\(song) lyrics")
            queries.append("\(song) audio")
        }

        if song.isEmpty && !performer.isEmpty {
            queries.append("\(performer) top songs")
            queries.append("\(performer) lyrics")
        }

        // De-duplicate while preserving order.
        var seen = Set<String>()
        return queries.filter { seen.insert($0).inserted }
    }

    /// Scores candidates and returns the strongest one. Official
    /// auto-generated "Topic" channels dominate; artist/title matches and
    /// "official"/"audio" markers break ties.
    static func bestCandidate(from candidates: [VideoCandidate], title: String, artist: String) -> VideoCandidate? {
        func score(_ candidate: VideoCandidate) -> Int {
            let channel = TrackMetadataNormalizer.normalized(candidate.channelTitle)
            let videoTitle = TrackMetadataNormalizer.normalized(candidate.title)
            var value = 0
            if candidate.channelTitle.hasSuffix("- Topic") { value += 100 }
            if !artist.isEmpty, channel.contains(artist) { value += 30 }
            if !title.isEmpty, videoTitle.contains(title) { value += 25 }
            if videoTitle.contains("topic") { value += 10 }
            if videoTitle.contains("official") { value += 8 }
            if videoTitle.contains("audio") { value += 5 }
            if channel.contains("topic") { value += 5 }
            return value
        }
        return candidates.max { score($0) < score($1) }
    }

    /// Sanity check that a candidate plausibly is the searched track.
    static func candidateMatches(_ candidate: VideoCandidate, title: String, artist: String) -> Bool {
        let videoTitle = TrackMetadataNormalizer.normalized(candidate.title)
        let channel = TrackMetadataNormalizer.normalized(candidate.channelTitle)
        if !title.isEmpty, videoTitle.contains(title) { return true }
        if !artist.isEmpty, videoTitle.contains(artist) { return true }
        if !artist.isEmpty, channel.contains(artist) { return true }
        return false
    }

    /// Fills gaps in the caller's metadata from the resolved video: an
    /// `"Artist - Song"` title splits into both halves, otherwise the video
    /// title stands in for a missing song and the channel for a missing
    /// artist. Existing metadata is never overwritten.
    static func inferredMetadata(
        from candidate: VideoCandidate,
        title: String,
        artist: String
    ) -> (title: String?, artist: String?) {
        let videoTitle = candidate.title
            .replacingOccurrences(of: "\0", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let dashSplit = videoTitle.components(separatedBy: " - ")
        if dashSplit.count >= 2 {
            let inferredArtist = dashSplit[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let inferredTitle = dashSplit[1].trimmingCharacters(in: .whitespacesAndNewlines)
            return (
                title: title.isEmpty ? inferredTitle : nil,
                artist: artist.isEmpty ? inferredArtist : nil
            )
        }

        return (
            title: title.isEmpty ? videoTitle : nil,
            artist: artist.isEmpty ? candidate.channelTitle : nil
        )
    }

    // MARK: - YouTube response shapes

    private struct SearchResponse: Decodable {
        let items: [Item]
    }

    private struct Item: Decodable {
        let id: ItemId
        let snippet: Snippet
    }

    private struct ItemId: Decodable {
        let videoId: String?
    }

    private struct Snippet: Decodable {
        let channelTitle: String
        let title: String
    }
}
