import Foundation
import Testing
@testable import SyncedLyricsKit

@Suite("Lyrics fetcher query building and candidate scoring")
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

    @Test("Configuration can be loaded from a secrets plist")
    func secretsPlistConfiguration() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let plistURL = directory.appendingPathComponent("Secrets.plist")
        let data = try PropertyListSerialization.data(
            fromPropertyList: [
                "GoogleAPIKey": "abc123",
                "AuthorizationToken": "token123",
                "WorkerBaseURL": "https://example.com"
            ],
            format: .xml,
            options: 0
        )
        try data.write(to: plistURL)

        let config = try LyricsFetcherConfiguration(contentsOf: plistURL)
        #expect(config.googleAPIKey == "abc123")
        #expect(config.authorizationToken == "token123")
        #expect(config.workerBaseURL.absoluteString == "https://example.com/")
    }

    @Test("Default configuration reads environment variables when no plist is present")
    func defaultConfigurationUsesEnvironment() {
        let config = LyricsFetcherConfiguration.makeDefault(environment: [
            "SYNCED_LYRICS_GOOGLE_API_KEY": "env-key",
            "SYNCED_LYRICS_AUTHORIZATION_TOKEN": "env-token",
            "SYNCED_LYRICS_WORKER_BASE_URL": "https://env.example.com"
        ])

        #expect(config.googleAPIKey == "env-key")
        #expect(config.authorizationToken == "env-token")
        #expect(config.workerBaseURL.absoluteString == "https://env.example.com/")
    }

    @Test("An empty Google API key throws before any network call")
    func missingKeyThrows() async {
        let fetcher = LyricsFetcher(configuration: .init(googleAPIKey: "  "))
        await #expect(throws: LyricsFetchError.self) {
            _ = try await fetcher.fetchLyrics(title: "Song", artist: "Artist")
        }
    }

    @Test("Fetcher emits logs for configuration failures")
    func fetcherLogsConfigurationErrors() async {
        let recorder = MessageRecorder()
        let fetcher = LyricsFetcher(configuration: .init(googleAPIKey: "  "), logger: { recorder.append($0) })

        await #expect(throws: LyricsFetchError.self) {
            _ = try await fetcher.fetchLyrics(title: "Song", artist: "Artist")
        }

        #expect(recorder.snapshot().contains { $0.contains("Google API key") })
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
