import Foundation
import Testing
@testable import SyncedLyricsKit

// Serialized: several tests share the StubWorkerURLProtocol.responseData
// static, which would race under Swift Testing's default parallelism.
@Suite("Lyrics fetcher query building and candidate scoring", .serialized)
struct LyricsFetcherTests {
    @Test("Topic queries lead and duplicates collapse")
    func queryOrdering() {
        let queries = LyricsFetcher.searchQueries(title: "Song", artist: "Artist", album: "")
        #expect(queries.first == "Artist Song topic")
        #expect(queries.count == Set(queries).count)
    }

    @Test("Symbol noise in titles adds a sanitized query variant")
    func sanitizedTitleQuery() {
        let queries = LyricsFetcher.searchQueries(title: "Pink + White", artist: "Frank Ocean", album: "Blonde")
        #expect(queries.contains("Frank Ocean Pink White topic"))
    }

    @Test("Parenthetical featured-artist qualifiers produce a cleaner query")
    func parentheticalFeaturedArtistQuery() {
        let queries = LyricsFetcher.searchQueries(title: "Stars Align (with Drake)", artist: "Jhené Aiko", album: "")
        #expect(queries.contains("Jhené Aiko Stars Align topic"))
        #expect(queries.contains("Stars Align topic"))
    }

    @Test("Missing artist falls back to lyrics/audio queries")
    func missingArtistQueries() {
        let queries = LyricsFetcher.searchQueries(title: "Song", artist: "", album: "")
        #expect(queries.contains("Song lyrics"))
        #expect(queries.contains("Song audio"))
    }

    @Test("Official Topic channels outrank other candidates")
    func topicChannelWins() throws {
        let candidates = [
            LyricsFetcher.VideoCandidate(videoId: "fan", channelTitle: "Some Fan Channel", title: "Song (Lyrics)"),
            LyricsFetcher.VideoCandidate(videoId: "official", channelTitle: "Artist - Topic", title: "Song")
        ]

        let best = try #require(LyricsFetcher.bestCandidate(
            from: candidates,
            title: TrackMetadataNormalizer.normalized("Song"),
            artist: TrackMetadataNormalizer.normalized("Artist")
        ))
        #expect(best.videoId == "official")
    }

    @Test("Retryable network errors include timeouts and connection drops")
    func retryableNetworkErrors() {
        #expect(LyricsFetcher.isRetryableSearchError(URLError(.timedOut)))
        #expect(LyricsFetcher.isRetryableSearchError(URLError(.networkConnectionLost)))
        #expect(!LyricsFetcher.isRetryableSearchError(URLError(.badServerResponse)))
    }

    @Test("Candidate matching accepts title, video-title artist, or channel artist")
    func candidateMatching() {
        let title = TrackMetadataNormalizer.normalized("My Song")
        let artist = TrackMetadataNormalizer.normalized("My Artist")

        let byChannel = LyricsFetcher.VideoCandidate(videoId: "a", channelTitle: "My Artist - Topic", title: "Unrelated")
        #expect(LyricsFetcher.candidateMatches(byChannel, title: title, artist: artist))

        let byTitle = LyricsFetcher.VideoCandidate(videoId: "b", channelTitle: "Random", title: "My Song (Official)")
        #expect(LyricsFetcher.candidateMatches(byTitle, title: title, artist: artist))

        let neither = LyricsFetcher.VideoCandidate(videoId: "c", channelTitle: "Random", title: "Something Else")
        #expect(!LyricsFetcher.candidateMatches(neither, title: title, artist: artist))
    }

    @Test("Connective symbols normalize like the word 'and'")
    func connectiveSymbolNormalization() {
        // "Fire & Desire" and "Fire and Desire" are the same track; the "&"
        // must not collapse to nothing and diverge from the spelled-out form.
        #expect(TrackMetadataNormalizer.normalized("Fire & Desire") == "fire and desire")
        #expect(
            TrackMetadataNormalizer.normalized("Fire & Desire")
                == TrackMetadataNormalizer.normalized("Fire and Desire")
        )
        // "+" reads as "and" too ("Pink + White").
        #expect(
            TrackMetadataNormalizer.normalized("Pink + White")
                == TrackMetadataNormalizer.normalized("Pink and White")
        )
        // A shared spelling means a shared cache key.
        #expect(
            TrackMetadataNormalizer.cacheKey(title: "Fire & Desire", artist: "Drake")
                == TrackMetadataNormalizer.cacheKey(title: "Fire and Desire", artist: "Drake")
        )
    }

    @Test("Strong match needs the track title, not just the artist's channel")
    func strongMatchGuardsAgainstFireAndDesireBug() {
        let title = TrackMetadataNormalizer.normalized("Fire & Desire")
        let artist = TrackMetadataNormalizer.normalized("Drake")

        // The regression: a *different* track from the right artist's Topic
        // channel must NOT strongly match, or it short-circuits the stricter
        // queries and resolves the wrong song.
        let wrongSong = LyricsFetcher.VideoCandidate(videoId: "w", channelTitle: "Drake - Topic", title: "Desires (feat. Future)")
        #expect(!LyricsFetcher.candidateStronglyMatches(wrongSong, title: title, artist: artist))
        #expect(LyricsFetcher.candidateMatches(wrongSong, title: title, artist: artist)) // still a loose fallback

        // The real track — even spelled with "and" — strongly matches thanks
        // to connective-symbol normalization.
        let rightSong = LyricsFetcher.VideoCandidate(videoId: "r", channelTitle: "Drake - Topic", title: "Fire and Desire")
        #expect(LyricsFetcher.candidateStronglyMatches(rightSong, title: title, artist: artist))

        // With no title to check, strong match falls back to the loose signal.
        let noTitle = LyricsFetcher.VideoCandidate(videoId: "n", channelTitle: "Drake - Topic", title: "Anything")
        #expect(LyricsFetcher.candidateStronglyMatches(noTitle, title: "", artist: artist))
    }

    @Test("Configuration can be loaded from a secrets plist")
    func secretsPlistConfiguration() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let plistURL = directory.appendingPathComponent("Secrets.plist")
        let data = try PropertyListSerialization.data(
            fromPropertyList: [
                "AuthorizationToken": "token123",
                "WorkerBaseURL": "https://example.com"
            ],
            format: .xml,
            options: 0
        )
        try data.write(to: plistURL)

        let config = try LyricsFetcherConfiguration(contentsOf: plistURL)
        #expect(config.authorizationToken == "token123")
        #expect(config.workerBaseURL.absoluteString == "https://example.com")
    }

    @Test("Default configuration reads environment variables when no plist is present")
    func defaultConfigurationUsesEnvironment() {
        let config = LyricsFetcherConfiguration.makeDefault(environment: [
            "SYNCED_LYRICS_AUTHORIZATION_TOKEN": "env-token",
            "SYNCED_LYRICS_WORKER_BASE_URL": "https://env.example.com"
        ])

        #expect(config.authorizationToken == "env-token")
        #expect(config.workerBaseURL.absoluteString == "https://env.example.com")
    }

    @Test("Fetch pipeline uses the injected search client and returns worker lyrics")
    func fetchThroughStubSearchClient() async throws {
        StubWorkerURLProtocol.responseData = Data(#"{"lrclibSyncedLyrics": "[00:05.00]Stubbed line"}"#.utf8)

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [StubWorkerURLProtocol.self]

        let searchClient = StubSearchClient(candidates: [
            YouTubeVideoCandidate(videoId: "abc123xyz", channelTitle: "Artist - Topic", title: "Song")
        ])
        let fetcher = LyricsFetcher(
            configuration: .init(workerBaseURL: URL(string: "https://worker.test")!),
            session: URLSession(configuration: sessionConfiguration),
            searchClient: searchClient,
            fallbackClient: StubFallbackClient(lyrics: nil),
            useUserSecretsPlist: false
        )

        let lyrics = try await fetcher.fetchLyrics(title: "Song", artist: "Artist")
        #expect(lyrics?.lines?.first?.text == "Stubbed line")
    }

    @Test("Worker failure with no fallback lyrics surfaces the worker error")
    func searchFailureThrows() async {
        let fetcher = LyricsFetcher(
            configuration: .init(workerBaseURL: URL(string: "https://worker.test")!),
            searchClient: StubSearchClient(candidates: []),
            fallbackClient: StubFallbackClient(lyrics: nil),
            useUserSecretsPlist: false
        )

        await #expect(throws: LyricsFetchError.self) {
            _ = try await fetcher.fetchLyrics(title: "Song", artist: "Artist")
        }
    }

    @Test("LRCLIB fallback is used when the worker returns nothing usable")
    func fallbackWhenWorkerEmpty() async throws {
        StubWorkerURLProtocol.responseData = Data(#"{"song":"Song","artist":"Artist"}"#.utf8)
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [StubWorkerURLProtocol.self]

        let fetcher = LyricsFetcher(
            configuration: .init(workerBaseURL: URL(string: "https://worker.test")!),
            session: URLSession(configuration: sessionConfiguration),
            searchClient: StubSearchClient(candidates: [
                YouTubeVideoCandidate(videoId: "abc123xyz", channelTitle: "Artist - Topic", title: "Song")
            ]),
            fallbackClient: StubFallbackClient(lyrics: SyncedLyrics.parse(lrc: "[00:01.00]Fallback line")),
            useUserSecretsPlist: false
        )

        let lyrics = try await fetcher.fetchLyrics(title: "Song", artist: "Artist")
        #expect(lyrics?.lines?.first?.text == "Fallback line")
    }

    @Test("LRCLIB fallback rescues a worker transport failure")
    func fallbackWhenWorkerThrows() async throws {
        let fetcher = LyricsFetcher(
            configuration: .init(workerBaseURL: URL(string: "https://worker.test")!),
            searchClient: StubSearchClient(candidates: []), // no topic video -> worker throws
            fallbackClient: StubFallbackClient(lyrics: SyncedLyrics.parse(lrc: "[00:02.00]Rescued line")),
            useUserSecretsPlist: false
        )

        let lyrics = try await fetcher.fetchLyrics(title: "Song", artist: "Artist")
        #expect(lyrics?.lines?.first?.text == "Rescued line")
    }

    @Test("Worker lyrics win over the fallback when both succeed")
    func workerWinsOverFallback() async throws {
        StubWorkerURLProtocol.responseData = Data(#"{"song":"Song","artist":"Artist","lrclibSyncedLyrics":"[00:05.00]Worker line"}"#.utf8)
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [StubWorkerURLProtocol.self]

        let fetcher = LyricsFetcher(
            configuration: .init(workerBaseURL: URL(string: "https://worker.test")!),
            session: URLSession(configuration: sessionConfiguration),
            searchClient: StubSearchClient(candidates: [
                YouTubeVideoCandidate(videoId: "abc123xyz", channelTitle: "Artist - Topic", title: "Song")
            ]),
            fallbackClient: StubFallbackClient(lyrics: SyncedLyrics.parse(lrc: "[00:01.00]Fallback line")),
            useUserSecretsPlist: false
        )

        let lyrics = try await fetcher.fetchLyrics(title: "Song", artist: "Artist")
        #expect(lyrics?.lines?.first?.text == "Worker line")
    }

    @Test("Worker answering for a different track defers to the fallback")
    func mismatchDefersToFallback() async throws {
        StubWorkerURLProtocol.responseData = Data(#"{"song":"Completely Other Track","artist":"Artist","lrclibSyncedLyrics":"[00:05.00]Wrong song line"}"#.utf8)
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [StubWorkerURLProtocol.self]

        let fetcher = LyricsFetcher(
            configuration: .init(workerBaseURL: URL(string: "https://worker.test")!),
            session: URLSession(configuration: sessionConfiguration),
            searchClient: StubSearchClient(candidates: [
                YouTubeVideoCandidate(videoId: "abc123xyz", channelTitle: "Artist - Topic", title: "Song")
            ]),
            fallbackClient: StubFallbackClient(lyrics: SyncedLyrics.parse(lrc: "[00:01.00]Fallback line")),
            useUserSecretsPlist: false
        )

        let lyrics = try await fetcher.fetchLyrics(title: "Song", artist: "Artist")
        #expect(lyrics?.lines?.first?.text == "Fallback line")
    }

    @Test("Worker metadata mismatch detection")
    func workerMetadataMismatch() {
        // Total divergence -> mismatch.
        let wrong = WorkerLyricsResponse(song: "Completely Other Track", artist: "Artist")
        #expect(LyricsFetcher.workerMetadataMismatches(wrong, title: "Fire & Desire", artist: "Drake"))

        // Same track, different connective spelling -> not a mismatch.
        let ok = WorkerLyricsResponse(song: "Fire and Desire", artist: "Drake")
        #expect(!LyricsFetcher.workerMetadataMismatches(ok, title: "Fire & Desire", artist: "Drake"))

        // Echoed/absent metadata -> never a mismatch (the common case).
        let echoed = WorkerLyricsResponse(song: nil, artist: nil)
        #expect(!LyricsFetcher.workerMetadataMismatches(echoed, title: "Fire & Desire", artist: "Drake"))
    }

    @Test("LRCLIB bestMatch picks the closest duration among title/artist hits")
    func lrclibBestMatch() throws {
        let tracks = [
            LRCLIBClient.Track(trackName: "Song", artistName: "Artist", duration: 200, syncedLyrics: "[00:01.00]A", plainLyrics: nil, instrumental: false),
            LRCLIBClient.Track(trackName: "Song", artistName: "Artist", duration: 242, syncedLyrics: "[00:01.00]B", plainLyrics: nil, instrumental: false),
            LRCLIBClient.Track(trackName: "Unrelated", artistName: "Someone", duration: 240, syncedLyrics: "[00:01.00]C", plainLyrics: nil, instrumental: false)
        ]
        let best = try #require(LRCLIBClient.bestMatch(tracks, title: "Song", artist: "Artist", duration: 240))
        #expect(best.duration == 242) // closest duration among the matching-title hits
    }

    @Test("Metadata inference splits 'Artist - Song' titles, never overwrites")
    func metadataInference() {
        let candidate = LyricsFetcher.VideoCandidate(
            videoId: "x",
            channelTitle: "Some Channel",
            title: "Frank Ocean - Pink + White"
        )

        // Both fields missing: dash-split fills both.
        let both = LyricsFetcher.inferredMetadata(from: candidate, title: "", artist: "")
        #expect(both.title == "Pink + White")
        #expect(both.artist == "Frank Ocean")

        // Existing metadata is left alone.
        let none = LyricsFetcher.inferredMetadata(from: candidate, title: "Pink + White", artist: "Frank Ocean")
        #expect(none.title == nil)
        #expect(none.artist == nil)

        // No dash: video title stands in for the song, channel for the artist.
        let plain = LyricsFetcher.VideoCandidate(videoId: "y", channelTitle: "Artist - Topic", title: "Song Name")
        let inferred = LyricsFetcher.inferredMetadata(from: plain, title: "", artist: "")
        #expect(inferred.title == "Song Name")
        #expect(inferred.artist == "Artist - Topic")
    }

    @Test("Raw JSON fallback finds lyric fields at any nesting depth")
    func rawJSONFallback() throws {
        let json = #"""
        {
            "wrapper": {
                "data": {
                    "lrclibSyncedLyrics": "[00:05.00]Buried but found"
                }
            }
        }
        """#

        let lyrics = LyricsFetcher.lyricsFromRawJSON(Data(json.utf8))
        #expect(lyrics?.lines?.first?.text == "Buried but found")
    }

    @Test("Raw JSON fallback respects source quality order")
    func rawJSONQualityOrder() {
        let json = #"""
        {
            "lrclibPlainLyrics": "plain text loses",
            "musixmatchWordByWordLyrics": "[00:10.00]<00:10.00>Word <00:10.50>timed"
        }
        """#

        let lyrics = LyricsFetcher.lyricsFromRawJSON(Data(json.utf8))
        #expect(lyrics?.granularity == .word)
    }

    @Test("String collection walks dictionaries and arrays")
    func stringCollection() throws {
        let json = #"{"a": "one", "nested": {"b": "two"}, "list": [{"c": "three"}], "empty": "  "}"#
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8))

        let strings = try #require(LyricsFetcher.collectStrings(from: object))
        #expect(strings["a"] == "one")
        #expect(strings["b"] == "two")
        #expect(strings["c"] == "three")
        #expect(strings["empty"] == nil)
    }
}

/// A ``YouTubeSearchClient`` that serves canned candidates without touching
/// the network.
private struct StubSearchClient: YouTubeSearchClient {
    let candidates: [YouTubeVideoCandidate]

    func searchVideos(matching query: String) async throws -> [YouTubeVideoCandidate] {
        candidates
    }
}

/// A ``LyricsFallbackClient`` that returns canned lyrics (or throws) without
/// touching the network.
private struct StubFallbackClient: LyricsFallbackClient {
    let lyrics: ParsedLyrics?
    var error: Error?

    func fetchLyrics(title: String, artist: String, album: String, duration: TimeInterval) async throws -> ParsedLyrics? {
        if let error { throw error }
        return lyrics
    }
}

/// Answers every request on its session with `responseData` and HTTP 200,
/// standing in for the lyrics worker.
private final class StubWorkerURLProtocol: URLProtocol {
    nonisolated(unsafe) static var responseData = Data()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: 200,
                  httpVersion: nil,
                  headerFields: ["Content-Type": "application/json"]
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseData)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite("Disk cache")
struct LyricsDiskCacheTests {
    private func makeTemporaryCache() -> (LyricsDiskCache, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SyncedLyricsKitTests-\(UUID().uuidString)", isDirectory: true)
        return (LyricsDiskCache(directory: directory), directory)
    }

    @Test("Lyrics round-trip through the cache")
    func roundTrip() async throws {
        let (cache, directory) = makeTemporaryCache()
        defer { try? FileManager.default.removeItem(at: directory) }

        let lyrics = try #require(SyncedLyrics.parse("[00:10.00]Cached line"))
        await cache.store(lyrics, title: "Song", artist: "Artist", duration: 200)

        let loaded = await cache.lyrics(title: "Song", artist: "Artist", duration: 200)
        #expect(loaded == lyrics)
    }

    @Test("Different tracks don't collide")
    func keyIsolation() async throws {
        let (cache, directory) = makeTemporaryCache()
        defer { try? FileManager.default.removeItem(at: directory) }

        let lyrics = try #require(SyncedLyrics.parse("[00:10.00]Cached line"))
        await cache.store(lyrics, title: "Song", artist: "Artist")

        #expect(await cache.lyrics(title: "Other Song", artist: "Artist") == nil)
        #expect(await cache.lyrics(title: "Song", artist: "Other Artist") == nil)
    }

    @Test("clearAll empties the cache")
    func clearAll() async throws {
        let (cache, directory) = makeTemporaryCache()
        defer { try? FileManager.default.removeItem(at: directory) }

        let lyrics = try #require(SyncedLyrics.parse("[00:10.00]Cached line"))
        await cache.store(lyrics, title: "Song", artist: "Artist")
        await cache.clearAll()

        #expect(await cache.lyrics(title: "Song", artist: "Artist") == nil)
    }
}
