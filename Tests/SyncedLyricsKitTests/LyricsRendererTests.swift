import Foundation
import Testing
@testable import SyncedLyricsKit

@Suite("Basic renderer timeline")
struct LyricsRendererTests {
    private func line(start: TimeInterval, end: TimeInterval, text: String = "Line") -> LyricLine {
        LyricLine(
            start: start,
            end: end,
            text: text,
            words: [LyricWord(text: text, start: start, duration: end - start)]
        )
    }

    @Test("Line timing highlights progressively and clamps at both ends")
    func lineProgress() {
        let lyric = line(start: 10, end: 14)
        #expect(LyricsRendererTimeline.progress(for: lyric, at: 8) == 0)
        #expect(LyricsRendererTimeline.progress(for: lyric, at: 12) == 0.5)
        #expect(LyricsRendererTimeline.progress(for: lyric, at: 16) == 1)
    }

    @Test("Active line follows song time")
    func activeLine() {
        let lines = [line(start: 5, end: 8, text: "First"), line(start: 8, end: 12, text: "Second")]
        #expect(LyricsRendererTimeline.activeLine(in: lines, at: 4) == nil)
        #expect(LyricsRendererTimeline.activeLine(in: lines, at: 7)?.text == "First")
        #expect(LyricsRendererTimeline.activeLine(in: lines, at: 8)?.text == "Second")
        #expect(LyricsRendererTimeline.activeLine(in: lines, at: 12) == nil)
    }

    @Test("Latest overlapping line becomes active")
    func overlappingLines() {
        let lines = [line(start: 5, end: 10, text: "Lead"), line(start: 7, end: 9, text: "Duet")]
        #expect(LyricsRendererTimeline.activeLine(in: lines, at: 8)?.text == "Duet")
    }

    @Test("Zero-duration lines avoid division by zero")
    func zeroDuration() {
        let lyric = line(start: 10, end: 10)
        #expect(LyricsRendererTimeline.progress(for: lyric, at: 9) == 0)
        #expect(LyricsRendererTimeline.progress(for: lyric, at: 10) == 1)
    }
}
