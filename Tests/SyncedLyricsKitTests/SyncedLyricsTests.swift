import Foundation
import Testing
@testable import SyncedLyricsKit

final class MessageRecorder: @unchecked Sendable {
    private var messages: [String] = []
    private let lock = NSLock()

    func append(_ message: String) {
        lock.lock()
        messages.append(message)
        lock.unlock()
    }

    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return messages
    }
}

@Suite("Auto-detection and worker responses")
struct SyncedLyricsTests {
    @Test("TTML input auto-detects")
    func detectsTTML() {
        let ttml = """
        <tt xml:lang="en"><body><div>
        <p begin="1.0" end="2.0"><span begin="1.0" end="1.5">Hello</span></p>
        </div></body></tt>
        """

        let lyrics = SyncedLyrics.parse(ttml)
        #expect(lyrics?.lines?.first?.text == "Hello")
    }

    @Test("LRC input auto-detects")
    func detectsLRC() {
        let lyrics = SyncedLyrics.parse("[00:10.00]Hello world")
        #expect(lyrics?.lines?.first?.text == "Hello world")
        #expect(lyrics?.lines?.first?.start == 10.0)
    }

    @Test("Untimed input falls back to plain text")
    func fallsBackToPlain() {
        let lyrics = SyncedLyrics.parse("Just words\non lines")
        #expect(lyrics?.plainText == "Just words\non lines")
    }

    @Test("Parsing emits log messages when a handler is provided")
    func parsingLogsToHandler() {
        let recorder = MessageRecorder()
        let lyrics = SyncedLyrics.parse("[00:10.00]Hello world", logger: { recorder.append($0) })

        #expect(lyrics != nil)
        #expect(recorder.snapshot().contains { $0.contains("LRC") || $0.contains("parsing") })
    }

    @Test("Empty input returns nil")
    func emptyInput() {
        #expect(SyncedLyrics.parse("   \n  ") == nil)
    }

    @Test("JSON-wrapped payloads unwrap before parsing")
    func unwrapsJSON() {
        let wrapped = #"{"syncedLyrics": "[00:10.00]Hello world"}"#
        let lyrics = SyncedLyrics.parse(wrapped)
        #expect(lyrics?.lines?.first?.text == "Hello world")
    }

    @Test("JSON-encoded strings unwrap before parsing")
    func unwrapsJSONString() {
        let wrapped = "\"[00:10.00]Hello world\""
        let lyrics = SyncedLyrics.parse(wrapped)
        #expect(lyrics?.lines?.first?.text == "Hello world")
    }

    @Test("ParsedLyrics survives an encode/decode round trip")
    func codableRoundTrip() throws {
        let original = SyncedLyrics.parse("[00:10.00]<00:10.00>Hello <00:10.50>world")!
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ParsedLyrics.self, from: data)
        #expect(decoded == original)
        #expect(decoded.granularity == .word)
    }

    @Test("Worker responses prefer word-timed sources over line-synced ones")
    func workerSourcePriority() {
        let response = WorkerLyricsResponse(
            musixmatchWordByWordLyrics: "[00:10.00]<00:10.00>Word <00:10.50>timed",
            lrclibSyncedLyrics: "[00:10.00]Line timed"
        )

        let lyrics = response.bestLyrics()
        #expect(lyrics?.lines?.first?.text == "Word timed")
        #expect(lyrics?.granularity == .word)
    }

    @Test("Worker responses fall back to plain lyrics when nothing is synced")
    func workerPlainFallback() {
        let response = WorkerLyricsResponse(lrclibPlainLyrics: "Only plain text here")
        #expect(response.bestLyrics()?.plainText == "Only plain text here")
    }

    @Test("Empty worker responses yield nil")
    func workerEmpty() {
        #expect(WorkerLyricsResponse().bestLyrics() == nil)
    }

    @Test("Worker responses decode from real JSON")
    func workerDecoding() throws {
        let json = #"""
        {
            "song": "Test Song",
            "artist": "Test Artist",
            "videoId": "abc123",
            "lrclibSyncedLyrics": "[00:05.00]From the worker"
        }
        """#

        let response = try JSONDecoder().decode(WorkerLyricsResponse.self, from: Data(json.utf8))
        #expect(response.song == "Test Song")
        #expect(response.bestLyrics()?.lines?.first?.text == "From the worker")
    }
}

@Suite("Metadata normalization")
struct TrackMetadataNormalizerTests {
    @Test("Featured credits, qualifiers, and edition noise strip away")
    func normalization() {
        #expect(
            TrackMetadataNormalizer.normalized("Song Title (feat. Someone) [2011 Remaster]")
            == "song title"
        )
        #expect(TrackMetadataNormalizer.normalized("Beyoncé") == "beyonce")
        #expect(TrackMetadataNormalizer.normalized("Track - Radio Edit") == "track")
    }

    @Test("Different spellings of the same track share a cache key")
    func cacheKeyStability() {
        let a = TrackMetadataNormalizer.cacheKey(title: "Song (feat. X)", artist: "Artist")
        let b = TrackMetadataNormalizer.cacheKey(title: "Song", artist: "Artist")
        #expect(a == b)
    }
}
