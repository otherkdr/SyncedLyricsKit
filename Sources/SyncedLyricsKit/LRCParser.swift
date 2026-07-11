import Foundation

/// Parses LRC-style lyric documents:
///
/// - **Standard LRC** — `[mm:ss.xx]` line timestamps, including multiple
///   timestamps on one line (repeated choruses).
/// - **Enhanced / rich-sync LRC** — inline `<mm:ss.xx>` word tags (the
///   format Musixmatch uses for word-by-word timing).
/// - **Backing vocals** — parenthetical text is separated into background
///   words rather than polluting the main line.
///
/// Word timing is detected per line, so documents that mix rich-sync and
/// plain-timed lines parse correctly.
public struct LRCParser: Sendable {
    private static let wordTagPattern = #"<\d{1,2}:\d{2}(?:\.\d{1,3})?>"#

    public init() {}

    /// Parses an LRC document into assembled, display-ready lyric lines.
    /// Returns an empty array when the document contains no timed lines.
    public func parse(_ lrc: String, logger: LyricsLogger? = nil) -> [LyricLine] {
        logger?("LRCParser: parsing LRC document with line and word timing support")
        let rawLines = parseRawLines(lrc)
        let lines = LineAssembler.assemble(rawLines)
        logger?("LRCParser: produced \(lines.count) assembled lyric line(s)")
        return lines
    }

    // MARK: - Document parsing

    func parseRawLines(_ lrc: String) -> [RawLine] {
        var parsed: [RawLine] = []

        for rawLine in lrc.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            if line.range(of: Self.wordTagPattern, options: .regularExpression) != nil {
                parsed.append(contentsOf: parseWordTimedLine(line))
            } else if let items = parseLineTimedLine(line) {
                parsed.append(contentsOf: items)
            }
        }

        return parsed
    }

    // MARK: - Line-timed parsing

    /// Parses a line carrying one or more `[mm:ss.xx]` stamps. Each stamp
    /// yields its own `RawLine` (LRC repeats stamps for repeated lines).
    /// Parenthetical text is extracted as background vocals timed to the
    /// line, since this format carries no finer timing for them.
    private func parseLineTimedLine(_ line: String) -> [RawLine]? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let stampPattern = #"\[(\d{1,2}):(\d{2})(?:\.(\d{1,3}))?\]"#
        guard let regex = try? NSRegularExpression(pattern: stampPattern) else {
            return nil
        }

        let range = NSRange(trimmed.startIndex..., in: trimmed)
        let matches = regex.matches(in: trimmed, range: range)
        guard let lastMatch = matches.last,
              let lyricStartRange = Range(lastMatch.range, in: trimmed) else {
            return nil
        }

        let rawLyric = trimmed[lyricStartRange.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawLyric.isEmpty else { return nil }

        // Strip any stray inline word tags. Replace with a space rather than
        // deleting outright — these formats commonly place tags directly
        // against word boundaries with no surrounding whitespace, so an
        // empty-string replace would glue adjacent words together
        // ("to<01:23.60>do" must become "to do", not "todo"). Cleaning here,
        // before backing-vocal extraction, also keeps raw tags out of
        // background word text.
        let lyric = rawLyric
            .replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lyric.isEmpty else { return nil }

        var parsed: [RawLine] = []
        for match in matches {
            guard let minutesRange = Range(match.range(at: 1), in: trimmed),
                  let secondsRange = Range(match.range(at: 2), in: trimmed) else {
                continue
            }

            let minutes = Double(trimmed[minutesRange]) ?? 0
            let seconds = Double(trimmed[secondsRange]) ?? 0
            var fraction = 0.0
            if match.range(at: 3).location != NSNotFound,
               let fractionRange = Range(match.range(at: 3), in: trimmed) {
                fraction = ParsingSupport.parseFraction(String(trimmed[fractionRange]))
            }

            let time = minutes * 60 + seconds + fraction
            let split = extractBackingVocals(from: lyric, at: time)

            parsed.append(RawLine(
                start: time,
                text: split.mainText.isEmpty
                    ? (split.backgroundTokens == nil ? lyric : "")
                    : split.mainText,
                backgroundTokens: split.backgroundTokens
            ))
        }

        return parsed.isEmpty ? nil : parsed
    }

    /// Pulls parenthetical segments out of a lyric and returns them as
    /// line-timed background tokens alongside the cleaned main text.
    private func extractBackingVocals(
        from lyric: String,
        at time: TimeInterval
    ) -> (mainText: String, backgroundTokens: [RawToken]?) {
        let pattern = #"\(([^()]*)\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return (lyric, nil)
        }

        let matches = regex.matches(in: lyric, range: NSRange(lyric.startIndex..., in: lyric))
        guard !matches.isEmpty else { return (lyric, nil) }

        // Collect background words in reading order first, then remove the
        // parenthetical ranges back-to-front so earlier ranges stay valid.
        var extracted: [RawToken] = []
        for match in matches {
            guard let contentRange = Range(match.range(at: 1), in: lyric) else { continue }
            let content = String(lyric[contentRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            let words = content
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
            for word in words {
                extracted.append(RawToken(text: word, start: time))
            }
        }

        var mainText = lyric
        for match in matches.reversed() {
            guard let removeRange = Range(match.range, in: mainText) else { continue }
            mainText.removeSubrange(removeRange)
        }

        return (
            mainText
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            extracted.isEmpty ? nil : extracted
        )
    }

    // MARK: - Word-timed (rich-sync) parsing

    /// Parses a line carrying inline `<mm:ss.xx>` word tags. Segments
    /// between tags become timed words; a parenthesis state machine routes
    /// words into the background stream while a `(` ... `)` run is open, so
    /// multi-word backing phrases stay background throughout.
    private func parseWordTimedLine(_ line: String) -> [RawLine] {
        let tagPattern = #"<(\d{1,2}:\d{2}(?:\.\d{1,3})?)>"#
        guard let regex = try? NSRegularExpression(pattern: tagPattern) else {
            return []
        }

        let ns = line as NSString
        let matches = regex.matches(in: line, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else {
            return parseLineTimedLine(line) ?? []
        }

        struct PendingWord {
            var text: String
            var start: TimeInterval
            var isBackground: Bool
        }

        var mainTokens: [RawToken] = []
        var backgroundTokens: [RawToken] = []
        var insideParentheses = false
        var currentWord: PendingWord? = nil
        var shouldStartNewWord = true

        func commit(_ word: PendingWord) {
            let token = RawToken(text: word.text, start: word.start)
            if word.isBackground {
                backgroundTokens.append(token)
            } else {
                mainTokens.append(token)
            }
        }

        for (index, match) in matches.enumerated() {
            guard let timeRange = Range(match.range(at: 1), in: line) else { continue }
            let currentTime = ParsingSupport.parseMinuteSecondTimestamp(String(line[timeRange]))

            let segmentStart = match.range.location + match.range.length
            let segmentEnd = index + 1 < matches.count ? matches[index + 1].range.location : ns.length
            guard segmentEnd > segmentStart else {
                shouldStartNewWord = true
                continue
            }

            let segment = ns.substring(with: NSRange(location: segmentStart, length: segmentEnd - segmentStart))
            var trimmedSegment = segment.trimmingCharacters(in: .whitespacesAndNewlines)

            if trimmedSegment.isEmpty {
                shouldStartNewWord = true
                continue
            }

            if segment.first?.isWhitespace ?? false {
                shouldStartNewWord = true
            }

            var segmentIsBackground = insideParentheses
            if trimmedSegment.hasPrefix("(") {
                segmentIsBackground = true
                // Persist the open state so every following segment stays a
                // background vocal until the matching ")" — otherwise only
                // the first parenthetical word is tagged background and the
                // rest leaks back into the main lyric.
                insideParentheses = true
                trimmedSegment.removeFirst()
            }

            let endsWithParen = trimmedSegment.hasSuffix(")")
            if endsWithParen {
                trimmedSegment.removeLast()
            }

            let cleanPart = trimmedSegment.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleanPart.isEmpty {
                let parts = cleanPart.components(separatedBy: .whitespaces)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }

                for (partIndex, part) in parts.enumerated() {
                    let isFirstPart = partIndex == 0
                    let needsNewWord = !isFirstPart
                        || shouldStartNewWord
                        || currentWord == nil
                        || currentWord?.isBackground != segmentIsBackground

                    if needsNewWord {
                        if let word = currentWord { commit(word) }
                        currentWord = PendingWord(text: part, start: currentTime, isBackground: segmentIsBackground)
                    } else {
                        currentWord?.text.append(part)
                    }
                    shouldStartNewWord = false
                }
            }

            if endsWithParen {
                insideParentheses = false
            }

            if segment.last?.isWhitespace ?? false {
                shouldStartNewWord = true
            }
        }

        if let word = currentWord {
            commit(word)
        }

        guard !mainTokens.isEmpty || !backgroundTokens.isEmpty else { return [] }

        // Prefer the line-stamp parse for the display text and line time
        // (it handles the leading `[mm:ss]` stamp); the word tokens
        // extracted above supply the timing detail.
        if let baseParsed = parseLineTimedLine(line), let firstLine = baseParsed.first {
            let cleanedText = firstLine.text
                .replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)

            // Rich-sync background tokens carry real per-word times; only
            // fall back to the line-timed extraction when none were found.
            return [RawLine(
                start: firstLine.start,
                text: cleanedText,
                tokens: mainTokens.isEmpty ? nil : mainTokens,
                backgroundTokens: backgroundTokens.isEmpty ? firstLine.backgroundTokens : backgroundTokens
            )]
        }

        let lineStart = mainTokens.first?.start ?? backgroundTokens.first?.start ?? 0
        return [RawLine(
            start: lineStart,
            text: mainTokens.map(\.text).joined(separator: " "),
            tokens: mainTokens.isEmpty ? nil : mainTokens,
            backgroundTokens: backgroundTokens.isEmpty ? nil : backgroundTokens
        )]
    }
}
