import Foundation
import Testing
@testable import SyncedLyricsKit

@Suite("TTML parsing")
struct TTMLParserTests {
    @Test("Adjacent spans group into syllable-timed words")
    func syllableGrouping() {
        let ttml = """
        <tt xmlns="http://www.w3.org/ns/ttml" xml:lang="en"><body><div>
        <p begin="10.000" end="12.000" itunes:key="L1" ttm:agent="v1"><span begin="10.000" end="10.400">Hap</span><span begin="10.400" end="10.800">py</span> <span begin="10.900" end="11.300">day</span></p>
        </div></body></tt>
        """

        let lines = TTMLParser().parse(ttml)
        #expect(lines.count == 1)

        let line = lines[0]
        #expect(line.text == "Happy day")
        #expect(line.start == 10.0)
        #expect(line.voice == "v1")
        #expect(line.granularity == .syllable)
        #expect(line.words.count == 2)

        let happy = line.words[0]
        #expect(happy.text == "Happy")
        #expect(happy.syllables.count == 2)
        #expect(happy.syllables[0].text == "Hap")
        #expect(happy.syllables[1].start == 10.4)
        #expect(happy.duration.map { abs($0 - 0.8) < 0.001 } == true)

        // Single-syllable words animate at word granularity, so no
        // syllable array.
        let day = line.words[1]
        #expect(day.text == "day")
        #expect(day.syllables.isEmpty)

        // Line end comes from the last timed word, not the next line.
        #expect(abs(line.end - 11.3) < 0.001)
    }

    @Test("Nested x-bg wrapper marks all inner syllables as background")
    func backgroundVocals() throws {
        let ttml = """
        <tt xml:lang="en"><body><div>
        <p begin="20.0" end="24.0"><span begin="20.0" end="21.0">Lead</span> <span ttm:role="x-bg"><span begin="21.0" end="21.5">(ooh</span> <span begin="21.5" end="22.0">yeah)</span></span></p>
        </div></body></tt>
        """

        let lines = TTMLParser().parse(ttml)
        #expect(lines.count == 1)

        let line = lines[0]
        #expect(line.text == "Lead")
        #expect(line.words.count == 1)

        let background = try #require(line.backgroundWords)
        #expect(background.count == 2)
        // Literal parentheses are stripped from background text.
        #expect(background[0].text == "ooh")
        #expect(background[1].text == "yeah")
        #expect(background[0].start == 21.0)
    }

    @Test("Translations attach to lines by itunes:key for non-English sources")
    func translations() {
        let ttml = """
        <tt xml:lang="es"><head><translations><translation xml:lang="en-US">
        <text for="L1">I thought I was gonna grow old with you</text>
        </translation></translations></head><body><div>
        <p begin="5.0" end="8.0" itunes:key="L1"><span begin="5.0" end="6.0">Pensé</span> <span begin="6.0" end="7.0">que</span></p>
        </div></body></tt>
        """

        let lines = TTMLParser().parse(ttml)
        #expect(lines.count == 1)
        #expect(lines[0].translation == "I thought I was gonna grow old with you")
    }

    @Test("English sources never surface translations")
    func englishSourceSkipsTranslations() {
        let ttml = """
        <tt xml:lang="en"><head><translations><translation xml:lang="en-US">
        <text for="L1">Redundant</text>
        </translation></translations></head><body><div>
        <p begin="5.0" end="8.0" itunes:key="L1"><span begin="5.0" end="6.0">Hello</span></p>
        </div></body></tt>
        """

        let lines = TTMLParser().parse(ttml)
        #expect(lines.count == 1)
        #expect(lines[0].translation == nil)
    }

    @Test("Relative span times offset from the paragraph begin")
    func relativeTiming() {
        let ttml = """
        <tt xml:lang="en"><body><div>
        <p begin="30.0" end="34.0"><span begin="0.0" end="0.5">Hey</span> <span begin="0.5" end="1.0">now</span></p>
        </div></body></tt>
        """

        let lines = TTMLParser().parse(ttml)
        #expect(lines.count == 1)
        // begin="0.0" before the paragraph's 30.0 only makes sense as a
        // relative offset.
        #expect(lines[0].words[0].start == 30.0)
        #expect(lines[0].words[1].start == 30.5)
    }

    @Test("An explicit timing hint overrides the heuristic")
    func timingHint() {
        let ttml = """
        <tt xml:lang="en"><body><div>
        <p begin="30.0" end="34.0"><span begin="31.0" end="31.5">Hey</span></p>
        </div></body></tt>
        """

        let absolute = TTMLParser().parse(ttml, timing: .absolute)
        #expect(absolute[0].words[0].start == 31.0)

        let relative = TTMLParser().parse(ttml, timing: .relative)
        #expect(relative[0].words[0].start == 61.0)
    }

    @Test("Clock-time formats parse: hh:mm:ss.fff, mm:ss.fff, seconds")
    func timeExpressionFormats() {
        #expect(ParsingSupport.parseTimeExpression("1:02:03.500") == 3723.5)
        #expect(ParsingSupport.parseTimeExpression("02:03.500") == 123.5)
        #expect(ParsingSupport.parseTimeExpression("12.5s") == 12.5)
        #expect(ParsingSupport.parseTimeExpression("12.5") == 12.5)
        #expect(ParsingSupport.parseTimeExpression("garbage") == 0)
        // Fraction digits scale by count: .5 == .50 == .500
        #expect(ParsingSupport.parseTimeExpression("00:01.5") == 1.5)
        #expect(ParsingSupport.parseTimeExpression("00:01.50") == 1.5)
        #expect(ParsingSupport.parseTimeExpression("00:01.500") == 1.5)
    }

    @Test("Paragraphs without spans fall back to staggered plain lines")
    func plainParagraphFallback() {
        let ttml = """
        <tt xml:lang="en"><body><div>
        <p begin="10.0" end="20.0">First visual line<br/>Second visual line</p>
        </div></body></tt>
        """

        let lines = TTMLParser().parse(ttml)
        #expect(lines.count == 2)
        #expect(lines[0].text == "First visual line")
        #expect(lines[0].start == 10.0)
        #expect(lines[1].text == "Second visual line")
        #expect(lines[1].start == 12.5)
    }

    @Test("HTML entities decode in sung text")
    func entityDecoding() {
        let ttml = """
        <tt xml:lang="en"><body><div>
        <p begin="1.0" end="2.0"><span begin="1.0" end="1.5">Rock &amp; roll ain&#39;t noise</span></p>
        </div></body></tt>
        """

        let lines = TTMLParser().parse(ttml)
        #expect(lines.count == 1)
        #expect(lines[0].text == "Rock & roll ain't noise")
    }

    @Test("Unbalanced close tags don't crash or drop content")
    func malformedTolerance() {
        let ttml = """
        <tt xml:lang="en"><body><div>
        <p begin="1.0" end="2.0"></span><span begin="1.0" end="1.5">Still</span> <span begin="1.5" end="2.0">here</span></p>
        </div></body></tt>
        """

        let lines = TTMLParser().parse(ttml)
        #expect(lines.count == 1)
        #expect(lines[0].text == "Still here")
    }
}
