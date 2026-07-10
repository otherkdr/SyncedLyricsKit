import Foundation

/// Hints how `<span begin="...">` times relate to their parent paragraph.
///
/// Some TTML producers time spans absolutely (from the start of the track),
/// others relative to the enclosing `<p>`. When the source tells you which
/// (as the better-lyrics worker's `binimumTimingType` field does), pass it
/// along; otherwise `.automatic` applies a heuristic that compares each
/// span's time against the paragraph's.
public enum TTMLTimingHint: Sendable, Hashable {
    case automatic
    case absolute
    case relative

    /// Derives a hint from a free-form source string such as
    /// `"absolute"` or `"relative"` (case-insensitive, substring match).
    public init(sourceHint: String?) {
        switch sourceHint?.lowercased() {
        case let hint? where hint.contains("absolute"): self = .absolute
        case let hint? where hint.contains("relative"): self = .relative
        default: self = .automatic
        }
    }
}

/// Parses TTML (Timed Text Markup Language) lyric documents, including the
/// Apple Music dialect: per-syllable `<span>` timing, nested
/// `ttm:role="x-bg"` background vocals, `ttm:agent` duet voices, and
/// untimed per-line translations in the document head.
///
/// The parser is deliberately tolerant — real-world lyric TTML is often
/// malformed, so it walks tags with a depth stack rather than requiring a
/// well-formed XML tree, and unbalanced close tags are ignored.
public struct TTMLParser: Sendable {
    public init() {}

    /// Parses a TTML document into assembled, display-ready lyric lines.
    /// Returns an empty array when the document contains no usable lyrics.
    public func parse(_ ttml: String, timing: TTMLTimingHint = .automatic) -> [LyricLine] {
        LineAssembler.assemble(parseRawLines(ttml, timing: timing))
    }

    // MARK: - Document structure

    func parseRawLines(_ ttml: String, timing: TTMLTimingHint) -> [RawLine] {
        let paragraphPattern = #"<p\b([^>]*)>(.*?)</p>"#
        guard let paragraphRegex = try? NSRegularExpression(
            pattern: paragraphPattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else {
            return []
        }

        let ns = ttml as NSString
        let matches = paragraphRegex.matches(in: ttml, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return [] }

        // Apple Music TTML carries per-line translations in the head instead
        // of timing them independently — `<text for="Lxx">` maps back to the
        // `itunes:key="Lxx"` on the matching `<p>`. Only meaningful when the
        // sung language isn't English; an English source has nothing to
        // translate into itself.
        let translations: [String: String] = isNonEnglishSource(ttml) ? parseTranslations(ttml) : [:]

        var result: [RawLine] = []
        for match in matches {
            guard match.numberOfRanges >= 3 else { continue }
            let attributes = ns.substring(with: match.range(at: 1))
            let body = ns.substring(with: match.range(at: 2))
            let baseTime = ParsingSupport.parseTimeExpression(
                ParsingSupport.attribute(in: attributes, named: "begin")
            )
            // `ttm:agent` references a voice declared in the TTML head; its
            // identity alone is enough to distinguish duet voices.
            let voice = ParsingSupport.attribute(in: attributes, named: "ttm:agent")
                ?? ParsingSupport.attribute(in: attributes, named: "agent")
            let lineID = ParsingSupport.attribute(in: attributes, named: "itunes:key")
                ?? ParsingSupport.attribute(in: attributes, named: "xml:id")

            var lines = parseParagraph(body, baseTime: baseTime, timing: timing, voice: voice)

            if let lineID, let translation = translations[lineID], !translation.isEmpty {
                lines = lines.map { line in
                    var line = line
                    line.translation = translation
                    // Translations render where background vocals would;
                    // showing both would collide.
                    line.backgroundTokens = nil
                    return line
                }
            }

            result.append(contentsOf: lines)
        }

        return result
    }

    /// Builds a line-id → translated-text lookup from the head's
    /// `<translations>` block:
    ///
    ///     <translations><translation xml:lang="en-US">
    ///       <text for="L1">I thought I was gonna grow old with you</text>
    ///     </translation></translations>
    private func parseTranslations(_ ttml: String) -> [String: String] {
        guard let blockRange = ttml.range(of: #"(?s)<translations>.*?</translations>"#, options: .regularExpression) else {
            return [:]
        }
        let block = String(ttml[blockRange])
        guard let regex = try? NSRegularExpression(
            pattern: #"<text\s+for="([^"]+)"[^>]*>(.*?)</text>"#,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else {
            return [:]
        }

        let ns = block as NSString
        let matches = regex.matches(in: block, range: NSRange(location: 0, length: ns.length))
        var result: [String: String] = [:]
        for match in matches where match.numberOfRanges >= 3 {
            let id = ns.substring(with: match.range(at: 1))
            let text = ParsingSupport.normalizeMarkupText(ns.substring(with: match.range(at: 2)))
            guard !text.isEmpty else { continue }
            result[id] = text
        }
        return result
    }

    /// The root `<tt xml:lang="es">` names the language the lyrics are sung
    /// in; translations are only worth surfacing when that isn't English.
    private func isNonEnglishSource(_ ttml: String) -> Bool {
        guard let range = ttml.range(of: #"<tt\b[^>]*>"#, options: .regularExpression) else { return false }
        let tag = String(ttml[range])
        guard let lang = ParsingSupport.attribute(in: tag, named: "xml:lang") else { return false }
        return !lang.lowercased().hasPrefix("en")
    }

    // MARK: - Paragraph parsing

    private func parseParagraph(
        _ body: String,
        baseTime: TimeInterval,
        timing: TTMLTimingHint,
        voice: String?
    ) -> [RawLine] {
        if let spanned = parseSpannedParagraph(body, baseTime: baseTime, timing: timing, voice: voice) {
            return spanned
        }

        // No timed spans: fall back to the paragraph's plain text.
        let plain = body
            .replacingOccurrences(of: #"<br\s*/?>"#, with: "\n", options: .regularExpression)
            .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !plain.isEmpty else { return [] }

        let lines = plain
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if lines.count > 1 {
            // Several visual lines share one paragraph timestamp; stagger
            // them a little so they don't all light up at once.
            return lines.enumerated().map { index, line in
                RawLine(start: baseTime + TimeInterval(index) * 2.5, text: line, voice: voice)
            }
        }

        return [RawLine(start: baseTime, text: plain, voice: voice)]
    }

    /// Walks the paragraph markup as open/close/text tokens over a depth
    /// stack so nested spans keep their structure. Apple-style TTML nests
    /// background vocals — `<span ttm:role="x-bg"><span>syl</span><span>lable</span></span>` —
    /// and a flat non-greedy `<span>(.*?)</span>` regex would truncate that
    /// wrapper at the first inner close tag, dropping the background role
    /// from every syllable after it. Only leaf spans (no child spans) carry
    /// sung text and timing; wrapper spans contribute the vocal stream to
    /// their subtree.
    ///
    /// Word grouping: any non-empty text between spans is a word boundary;
    /// directly-adjacent leaf spans with nothing between them are syllables
    /// of one word. Boundaries never form inside a leaf, so words can't
    /// split apart, and a boundary is forced at every wrapper edge and
    /// stream switch, so words can't fuse across them either.
    private func parseSpannedParagraph(
        _ body: String,
        baseTime: TimeInterval,
        timing: TTMLTimingHint,
        voice: String?
    ) -> [RawLine]? {
        let tokenPattern = #"<span\b([^>]*)>|</span\s*>"#
        guard let regex = try? NSRegularExpression(pattern: tokenPattern, options: [.caseInsensitive]) else {
            return nil
        }
        let ns = body as NSString
        let matches = regex.matches(in: body, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return nil }

        struct OpenSpan {
            let attributes: String
            let isBackground: Bool
            var hasChildSpans = false
            var text = ""
        }

        var mainTokens: [RawToken] = []
        var backgroundTokens: [RawToken] = []
        var mainWordIndex = -1
        var backgroundWordIndex = -1
        var lastWasBackground: Bool? = nil
        var pendingBoundary = false
        var stack: [OpenSpan] = []
        var cursor = 0

        func handleInterstitialText(_ raw: String) {
            if !stack.isEmpty, !stack[stack.count - 1].hasChildSpans {
                // Inside a leaf span so far — this is (part of) its sung text.
                stack[stack.count - 1].text += raw
            } else if gapContainsWordBreak(raw) {
                pendingBoundary = true
            }
        }

        func emitLeaf(_ span: OpenSpan) {
            var cleaned = ParsingSupport.normalizeMarkupText(span.text)
            if span.isBackground {
                // Sources bake literal parentheses into background
                // syllables; renderers add their own, so strip them here.
                cleaned = cleaned
                    .replacingOccurrences(of: "(", with: "")
                    .replacingOccurrences(of: ")", with: "")
                    .trimmingCharacters(in: .whitespaces)
            }

            // Whitespace-only spans are pure spacers: they carry no sung
            // text, so drop them but force the next span to begin a new word.
            guard !cleaned.isEmpty else {
                pendingBoundary = true
                return
            }

            // First span of a stream (or the stream just switched) always
            // starts a fresh word.
            let boundary = pendingBoundary || lastWasBackground != span.isBackground
            pendingBoundary = false

            let begin = ParsingSupport.parseTimeExpression(
                ParsingSupport.attribute(in: span.attributes, named: "begin")
            )
            let end = ParsingSupport.parseTimeExpression(
                ParsingSupport.attribute(in: span.attributes, named: "end")
            )
            let spanStart = resolveSpanTime(begin: begin, baseTime: baseTime, timing: timing)
            let duration = end > begin ? max(end - begin, 0) : nil

            let wordIndex: Int
            if span.isBackground {
                if boundary { backgroundWordIndex += 1 }
                wordIndex = max(backgroundWordIndex, 0)
            } else {
                if boundary { mainWordIndex += 1 }
                wordIndex = max(mainWordIndex, 0)
            }

            let token = RawToken(text: cleaned, start: spanStart, duration: duration, wordIndex: wordIndex)
            if span.isBackground {
                backgroundTokens.append(token)
            } else {
                mainTokens.append(token)
            }
            lastWasBackground = span.isBackground
        }

        for match in matches {
            if match.range.location > cursor {
                handleInterstitialText(ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor)))
            }
            cursor = match.range.location + match.range.length

            if match.range(at: 1).location != NSNotFound {
                let attributes = ns.substring(with: match.range(at: 1))
                if !stack.isEmpty { stack[stack.count - 1].hasChildSpans = true }
                let inheritedBackground = stack.last?.isBackground ?? false
                stack.append(OpenSpan(
                    attributes: attributes,
                    isBackground: inheritedBackground || isBackgroundSpan(attributes)
                ))
            } else {
                // Tolerate unbalanced close tags from malformed sources.
                guard let span = stack.popLast() else { continue }
                if span.hasChildSpans {
                    // Wrapper (e.g. the x-bg container): its children already
                    // emitted; leaving it separates them from what follows.
                    pendingBoundary = true
                } else {
                    emitLeaf(span)
                }
            }
        }
        if cursor < ns.length {
            handleInterstitialText(ns.substring(with: NSRange(location: cursor, length: ns.length - cursor)))
        }

        guard !mainTokens.isEmpty || !backgroundTokens.isEmpty else { return nil }
        let text = mainTokens.isEmpty
            ? displayText(fromGrouped: backgroundTokens)
            : displayText(fromGrouped: mainTokens)
        return [
            RawLine(
                start: mainTokens.first?.start ?? backgroundTokens.first?.start ?? baseTime,
                text: text,
                tokens: mainTokens.isEmpty ? nil : mainTokens,
                backgroundTokens: backgroundTokens.isEmpty ? nil : backgroundTokens,
                voice: voice
            )
        ]
    }

    // MARK: - Helpers

    private func resolveSpanTime(begin: TimeInterval, baseTime: TimeInterval, timing: TTMLTimingHint) -> TimeInterval {
        let isAbsolute: Bool
        switch timing {
        case .absolute:
            isAbsolute = true
        case .relative:
            isAbsolute = false
        case .automatic:
            // Heuristic: spans at or beyond the paragraph's own begin time
            // are almost certainly absolute; a span starting before its
            // paragraph only makes sense as a relative offset.
            if baseTime == 0 { isAbsolute = true }
            else if begin == 0 { isAbsolute = false }
            else { isAbsolute = begin >= baseTime - 0.001 }
        }
        return isAbsolute ? begin : baseTime + begin
    }

    private func isBackgroundSpan(_ attributes: String) -> Bool {
        let role = ParsingSupport.attribute(in: attributes, named: "ttm:role")
            ?? ParsingSupport.attribute(in: attributes, named: "role")
        return role?.lowercased() == "x-bg"
    }

    /// Any non-tag text between two spans (a space, punctuation, etc.) marks
    /// a word boundary. Syllables of one word are emitted as
    /// directly-adjacent spans with nothing between them, so an empty gap
    /// means "same word".
    private func gapContainsWordBreak(_ gap: String) -> Bool {
        let stripped = gap.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        return !stripped.isEmpty
    }

    /// Rebuilds the human-readable line from grouped syllables: syllables
    /// within a word are concatenated with no separator, words are separated
    /// by a single space.
    private func displayText(fromGrouped tokens: [RawToken]) -> String {
        guard !tokens.isEmpty else { return "" }
        var words: [String] = []
        var currentIndex: Int? = nil
        var current = ""
        for token in tokens {
            if token.wordIndex != currentIndex {
                let trimmed = current.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { words.append(trimmed) }
                current = ""
                currentIndex = token.wordIndex
            }
            current += token.text
        }
        let trimmed = current.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { words.append(trimmed) }
        return words.joined(separator: " ")
    }
}
