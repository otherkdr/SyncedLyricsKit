import Foundation

/// A single timed text fragment produced by a parser, before assembly.
///
/// For sources with a native word → syllable hierarchy (TTML), consecutive
/// tokens sharing a `wordIndex` are syllables of the same word. For
/// word-level sources (LRC and friends), `wordIndex` is `nil` and every
/// token is already a complete word.
struct RawToken: Sendable {
    var text: String
    var start: TimeInterval
    var duration: TimeInterval?
    var wordIndex: Int?

    init(text: String, start: TimeInterval, duration: TimeInterval? = nil, wordIndex: Int? = nil) {
        self.text = text
        self.start = start
        self.duration = duration
        self.wordIndex = wordIndex
    }
}

/// One parsed-but-unassembled lyric line.
struct RawLine: Sendable {
    var start: TimeInterval
    var text: String
    var tokens: [RawToken]?
    var backgroundTokens: [RawToken]?
    var translation: String?
    var voice: String?

    init(
        start: TimeInterval,
        text: String,
        tokens: [RawToken]? = nil,
        backgroundTokens: [RawToken]? = nil,
        translation: String? = nil,
        voice: String? = nil
    ) {
        self.start = start
        self.text = text
        self.tokens = tokens
        self.backgroundTokens = backgroundTokens
        self.translation = translation
        self.voice = voice
    }
}

/// Turns parser output into display-ready `LyricLine`s: groups syllables
/// into words, resolves word and line durations, folds parenthetical
/// background-vocal lines into their neighbors, and classifies timing
/// granularity.
enum LineAssembler {
    /// Background-only parenthetical lines are merged into the previous line
    /// when they begin within this many seconds of that line's end.
    private static let backgroundMergeWindow: TimeInterval = 1.2

    static func assemble(_ rawLines: [RawLine]) -> [LyricLine] {
        var result: [LyricLine] = []
        let sorted = rawLines.sorted { $0.start < $1.start }

        for (index, raw) in sorted.enumerated() {
            let nextLineStart = index + 1 < sorted.count ? sorted[index + 1].start : nil
            let words = buildWords(
                from: raw.tokens,
                lineText: raw.text,
                lineStart: raw.start,
                nextLineStart: nextLineStart
            )

            var backgroundWords: [LyricWord]? = nil
            if let bgTokens = raw.backgroundTokens, !bgTokens.isEmpty {
                let bgText = bgTokens.map(\.text).joined(separator: " ")
                backgroundWords = buildWords(
                    from: bgTokens,
                    lineText: bgText,
                    lineStart: bgTokens.first?.start ?? raw.start,
                    nextLineStart: nextLineStart,
                    isBackground: true
                )
            }

            // A line whose entire text is parenthetical (e.g. "(ooh yeah)")
            // reads as backing vocals, not a standalone lyric. When its
            // timing sits close enough to the previous line, fold its
            // background words into that line instead of emitting it — but
            // only when close, so unrelated ad-libs don't get glued onto an
            // earlier lyric.
            let trimmed = raw.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let isParenthetical = trimmed.hasPrefix("(") && trimmed.hasSuffix(")")
                && (words.isEmpty || words.count == (backgroundWords?.count ?? 0))
            // LRC extraction empties the main text of a "(...)"-only line and
            // leaves just background words, so treat that shape as
            // parenthetical too.
            let isBackgroundOnly = words.isEmpty && backgroundWords?.isEmpty == false

            if isParenthetical || isBackgroundOnly, let previous = result.popLast() {
                if raw.start - previous.end <= backgroundMergeWindow {
                    result.append(merge(background: backgroundWords, into: previous, nextLineStart: nextLineStart))
                    continue
                }
                // Too far apart — restore the previous line and emit normally.
                result.append(previous)
            }

            // Prefer the honest end of the sung line (last timed word) over
            // snapping to the next line's start: genuine duet overlaps
            // survive, and the true silent gap before the next line stays
            // visible for interlude detection. Only fall back to the next
            // line's start when no word-level duration exists to trust.
            let sungEnd = words.last.flatMap { word in
                word.duration.map { word.start + $0 }
            }
            let hasWordDurations = words.contains { ($0.duration ?? 0) > 0 }
            let end: TimeInterval
            if hasWordDurations, let sungEnd {
                end = max(sungEnd, raw.start)
            } else {
                end = nextLineStart.map { max($0, raw.start) } ?? raw.start
            }

            result.append(LyricLine(
                start: raw.start,
                end: max(end, raw.start),
                text: raw.text,
                words: words,
                backgroundWords: backgroundWords,
                translation: raw.translation,
                voice: raw.voice,
                granularity: classify(words: words, text: raw.text)
            ))
        }

        return result
    }

    // MARK: - Word construction

    private static func buildWords(
        from tokens: [RawToken]?,
        lineText: String,
        lineStart: TimeInterval,
        nextLineStart: TimeInterval?,
        isBackground: Bool = false
    ) -> [LyricWord] {
        guard let tokens, !tokens.isEmpty else {
            // No per-word timing at all: represent the whole line as one
            // word spanning up to the next line, so line-level sources still
            // flow through a single uniform model.
            let cleaned = lineText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { return [] }
            return [
                LyricWord(
                    text: cleaned,
                    start: lineStart,
                    duration: nextLineStart.map { max($0 - lineStart, 0) }
                )
            ]
        }

        if tokens.contains(where: { $0.wordIndex != nil }) {
            return buildSyllableGroupedWords(tokens, nextLineStart: nextLineStart, isBackground: isBackground)
        }

        // Word-level source: every token is already a complete word. Never
        // infer syllables here — fragment heuristics misfire on real words.
        return tokens.enumerated().map { offset, token in
            let nextStart = offset + 1 < tokens.count
                ? tokens[offset + 1].start
                : (nextLineStart ?? token.duration.map { token.start + $0 } ?? token.start)
            let resolved = token.duration ?? max(nextStart - token.start, 0)
            return LyricWord(
                text: token.text.trimmingCharacters(in: .whitespaces),
                start: token.start,
                duration: resolved > 0 ? resolved : nil
            )
        }
    }

    /// Native syllable hierarchy: consecutive tokens sharing a `wordIndex`
    /// are syllables of one word. Group deterministically by that index
    /// instead of re-inferring word membership from fragment text.
    private static func buildSyllableGroupedWords(
        _ tokens: [RawToken],
        nextLineStart: TimeInterval?,
        isBackground: Bool
    ) -> [LyricWord] {
        var groups: [[RawToken]] = []
        var currentIndex: Int? = nil
        for token in tokens {
            if groups.isEmpty || token.wordIndex != currentIndex {
                groups.append([token])
                currentIndex = token.wordIndex
            } else {
                groups[groups.count - 1].append(token)
            }
        }

        return groups.enumerated().map { groupOffset, group in
            let first = group.first!
            let last = group.last!
            let display = group.map { $0.text.trimmingCharacters(in: .whitespaces) }.joined()

            // Only expose syllables for genuinely multi-syllable words;
            // single-syllable words animate at word granularity.
            let syllables: [LyricSyllable] = group.count > 1
                ? group.map {
                    LyricSyllable(text: $0.text, start: $0.start, duration: $0.duration, isBackground: isBackground)
                }
                : []

            let duration: TimeInterval?
            if let d = last.duration, d > 0 {
                duration = (last.start + d) - first.start
            } else if groupOffset + 1 < groups.count {
                duration = max(groups[groupOffset + 1].first!.start - first.start, 0)
            } else if let nextLineStart, nextLineStart > first.start {
                duration = max(nextLineStart - first.start, 0)
            } else {
                duration = nil
            }

            return LyricWord(text: display, start: first.start, duration: duration, syllables: syllables)
        }
    }

    // MARK: - Background merge

    private static func merge(
        background: [LyricWord]?,
        into line: LyricLine,
        nextLineStart: TimeInterval?
    ) -> LyricLine {
        var mergedBackground = line.backgroundWords ?? []
        for word in background ?? [] {
            // Skip exact duplicates by (text, time) so repeated merges stay
            // idempotent.
            let isDuplicate = mergedBackground.contains {
                $0.text == word.text && abs($0.start - word.start) < 0.02
            }
            if !isDuplicate {
                mergedBackground.append(word)
            }
        }

        return LyricLine(
            id: line.id,
            start: line.start,
            end: max(line.end, nextLineStart ?? line.end),
            text: line.text,
            words: line.words,
            backgroundWords: mergedBackground.isEmpty ? nil : mergedBackground,
            translation: line.translation,
            voice: line.voice,
            granularity: line.granularity
        )
    }

    // MARK: - Granularity classification

    private static func classify(words: [LyricWord], text: String) -> TimingGranularity {
        // A word carrying more than one syllable means true syllable-level
        // timing; otherwise fall back to the count-based classifier.
        if words.contains(where: { $0.syllables.count > 1 }) {
            return .syllable
        }

        guard !words.isEmpty else { return .line }

        let tokens = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }

        if words.count == 1 {
            // One timing covering a multi-word line is just line timing;
            // covering a single word, it's honest word timing.
            return tokens.count <= 1 ? .word : .line
        }
        if tokens.isEmpty { return .word }
        return words.count > tokens.count ? .syllable : .word
    }
}
