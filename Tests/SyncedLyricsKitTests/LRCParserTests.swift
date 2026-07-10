import Foundation
import Testing
@testable import SyncedLyricsKit

@Suite("LRC parsing")
struct LRCParserTests {
    @Test("Standard line timestamps parse and end times snap to the next line")
    func standardLRC() {
        let lrc = """
        [00:12.00]First line here
        [00:15.50]Second line
        """

        let lines = LRCParser().parse(lrc)
        #expect(lines.count == 2)
        #expect(lines[0].start == 12.0)
        #expect(lines[0].text == "First line here")
        #expect(lines[0].granularity == .line)
        #expect(abs(lines[0].end - 15.5) < 0.001)
        #expect(lines[1].start == 15.5)
    }

    @Test("Multiple timestamps on one line repeat it at each time")
    func repeatedStamps() {
        let lrc = "[00:10.00][00:50.00]Chorus line"

        let lines = LRCParser().parse(lrc)
        #expect(lines.count == 2)
        #expect(lines[0].start == 10.0)
        #expect(lines[1].start == 50.0)
        #expect(lines[0].text == "Chorus line")
        #expect(lines[1].text == "Chorus line")
    }

    @Test("Enhanced word tags produce word-level timing")
    func enhancedLRC() {
        let lrc = "[00:10.00]<00:10.00>Hello <00:10.50>beautiful <00:11.20>world"

        let lines = LRCParser().parse(lrc)
        #expect(lines.count == 1)

        let line = lines[0]
        #expect(line.granularity == .word)
        #expect(line.words.count == 3)
        #expect(line.words[0].text == "Hello")
        #expect(line.words[0].start == 10.0)
        // Duration inferred from the next word's start.
        #expect(line.words[0].duration.map { abs($0 - 0.5) < 0.001 } == true)
        #expect(line.words[1].start == 10.5)
        #expect(line.words[2].text == "world")
    }

    @Test("Word tags glued to word boundaries don't fuse words in the display text")
    func tagStrippingPreservesSpaces() {
        let lrc = "[00:10.00]I want <00:10.50>to<00:10.80>do it"

        let lines = LRCParser().parse(lrc)
        #expect(lines.count == 1)
        // "to<...>do" must read "to do", never "todo".
        #expect(lines[0].text.contains("to do"))
        #expect(!lines[0].text.contains("todo"))
    }

    @Test("Parenthetical text becomes background words on timed lines")
    func lineLevelBackgroundVocals() throws {
        let lrc = """
        [00:10.00]Main lyric here
        [00:14.00]Another main (ooh yeah) lyric
        """

        let lines = LRCParser().parse(lrc)
        #expect(lines.count == 2)
        #expect(lines[1].text == "Another main lyric")

        let background = try #require(lines[1].backgroundWords)
        #expect(background.map(\.text) == ["ooh", "yeah"])
        #expect(background[0].start == 14.0)
    }

    @Test("Parenthetical runs in rich-sync lines route to the background stream")
    func richSyncBackgroundVocals() throws {
        let lrc = "[00:20.00]<00:20.00>Sing <00:20.50>(oh <00:21.00>baby) <00:21.50>tonight"

        let lines = LRCParser().parse(lrc)
        #expect(lines.count == 1)

        let line = lines[0]
        #expect(line.words.map(\.text) == ["Sing", "tonight"])

        // Background words keep their own tag times, not the line time.
        let background = try #require(line.backgroundWords)
        #expect(background.map(\.text) == ["oh", "baby"])
        #expect(background[0].start == 20.5)
        #expect(background[1].start == 21.0)
    }

    @Test("Background-only lines merge into the previous line when close")
    func backgroundOnlyLineMerges() throws {
        let lrc = """
        [00:10.00]Main line here
        [00:12.00](ooh yeah)
        [00:20.00]Next line
        """

        let lines = LRCParser().parse(lrc)
        #expect(lines.count == 2)
        #expect(lines[0].text == "Main line here")

        let background = try #require(lines[0].backgroundWords)
        #expect(background.map(\.text) == ["ooh", "yeah"])
        #expect(lines[1].text == "Next line")
    }

    @Test("A background-only opener with no predecessor stays standalone")
    func backgroundLineWithoutPredecessor() throws {
        let lrc = """
        [00:05.00](ooh yeah)
        [00:10.00]First real line
        """

        let lines = LRCParser().parse(lrc)
        #expect(lines.count == 2)
        #expect(lines[0].text.isEmpty)
        let background = try #require(lines[0].backgroundWords)
        #expect(background.map(\.text) == ["ooh", "yeah"])
        #expect(lines[1].text == "First real line")
    }

    @Test("Untimed input yields no lines")
    func untimedInput() {
        #expect(LRCParser().parse("Just some plain text\nwith no stamps").isEmpty)
    }
}
