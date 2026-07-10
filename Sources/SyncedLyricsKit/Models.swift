import Foundation

/// A lightweight callback for emitting diagnostic messages from parsing and fetching.
public typealias LyricsLogger = @Sendable (String) -> Void

/// How finely a lyric line is timed.
public enum TimingGranularity: String, Sendable, Codable, Hashable {
    /// Only the line itself carries a start time.
    case line
    /// Every word carries its own start time (and usually a duration).
    case word
    /// Words are subdivided into individually timed syllables.
    case syllable
}

/// A single timed syllable within a word.
///
/// Syllables only appear when the source format provides timing finer than
/// whole words (Apple Music–style TTML does; plain LRC never does).
public struct LyricSyllable: Sendable, Hashable, Codable, Identifiable {
    public let id: UUID
    /// The syllable's text fragment, e.g. `"hap"` out of `"happy"`.
    public let text: String
    /// Absolute start time in seconds from the beginning of the track.
    public let start: TimeInterval
    /// How long the syllable is sung, when the source provides it.
    public let duration: TimeInterval?
    /// `true` when this syllable belongs to a background/backing vocal.
    public let isBackground: Bool

    public init(
        id: UUID = UUID(),
        text: String,
        start: TimeInterval,
        duration: TimeInterval? = nil,
        isBackground: Bool = false
    ) {
        self.id = id
        self.text = text
        self.start = start
        self.duration = duration
        self.isBackground = isBackground
    }
}

/// A single timed word within a lyric line.
public struct LyricWord: Sendable, Hashable, Codable, Identifiable {
    public let id: UUID
    /// The complete word as it should be displayed.
    public let text: String
    /// Absolute start time in seconds from the beginning of the track.
    public let start: TimeInterval
    /// How long the word is sung. Resolved from the source when available,
    /// otherwise inferred from the start of the next word or line.
    public let duration: TimeInterval?
    /// Individually timed syllables, when the source provides them.
    /// Empty for word-level or line-level sources — a word with fewer than
    /// two syllables animates at word granularity, so single-syllable words
    /// never populate this array.
    public let syllables: [LyricSyllable]

    /// Absolute end time, when a duration is known.
    public var end: TimeInterval? { duration.map { start + $0 } }

    public init(
        id: UUID = UUID(),
        text: String,
        start: TimeInterval,
        duration: TimeInterval? = nil,
        syllables: [LyricSyllable] = []
    ) {
        self.id = id
        self.text = text
        self.start = start
        self.duration = duration
        self.syllables = syllables
    }
}

/// One display line of synchronized lyrics.
public struct LyricLine: Sendable, Hashable, Codable, Identifiable {
    public let id: UUID
    /// Absolute start time in seconds from the beginning of the track.
    public let start: TimeInterval
    /// Absolute end time. Taken from the last timed word when the source
    /// carries word durations (so duet overlaps and pre-line gaps survive),
    /// otherwise snapped to the start of the following line.
    public let end: TimeInterval
    /// The full human-readable line text (main vocal only).
    public let text: String
    /// The timed words of the main vocal. Always contains at least one entry
    /// for a non-empty line; line-level sources yield a single word spanning
    /// the whole line.
    public let words: [LyricWord]
    /// Timed backing/background vocals (e.g. parenthetical ad-libs), when the
    /// source distinguishes them from the main vocal.
    public let backgroundWords: [LyricWord]?
    /// A translation of the line, when the source embeds one (Apple Music
    /// TTML ships untimed per-line translations for non-English lyrics).
    public let translation: String?
    /// The voice/singer this line belongs to, from TTML `ttm:agent` duet
    /// metadata. `nil` for single-voice sources such as LRC.
    public let voice: String?
    /// The finest timing this line actually carries.
    public let granularity: TimingGranularity

    public init(
        id: UUID = UUID(),
        start: TimeInterval,
        end: TimeInterval,
        text: String,
        words: [LyricWord],
        backgroundWords: [LyricWord]? = nil,
        translation: String? = nil,
        voice: String? = nil,
        granularity: TimingGranularity = .line
    ) {
        self.id = id
        self.start = start
        self.end = end
        self.text = text
        self.words = words
        self.backgroundWords = backgroundWords
        self.translation = translation
        self.voice = voice
        self.granularity = granularity
    }
}

/// The result of parsing a lyrics document.
public enum ParsedLyrics: Sendable, Hashable {
    /// Time-synchronized lyrics, ordered by start time.
    case timed([LyricLine])
    /// Unsynchronized plain text.
    case plain(String)

    /// The synchronized lines, when this payload is timed.
    public var lines: [LyricLine]? {
        if case .timed(let lines) = self { return lines }
        return nil
    }

    /// The plain-text lyrics, when this payload is unsynchronized.
    public var plainText: String? {
        if case .plain(let text) = self { return text }
        return nil
    }

    /// The finest timing granularity present in the payload.
    public var granularity: TimingGranularity {
        guard case .timed(let lines) = self else { return .line }
        if lines.contains(where: { $0.granularity == .syllable }) { return .syllable }
        if lines.contains(where: { $0.granularity == .word }) { return .word }
        return .line
    }

    /// `true` when the payload carries no usable content.
    public var isEmpty: Bool {
        switch self {
        case .timed(let lines):
            return lines.isEmpty
        case .plain(let text):
            return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}

extension ParsedLyrics: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, lines, text
    }

    private enum PayloadType: String, Codable {
        case timed, plain
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(PayloadType.self, forKey: .type) {
        case .timed:
            self = .timed(try container.decode([LyricLine].self, forKey: .lines))
        case .plain:
            self = .plain(try container.decode(String.self, forKey: .text))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .timed(let lines):
            try container.encode(PayloadType.timed, forKey: .type)
            try container.encode(lines, forKey: .lines)
        case .plain(let text):
            try container.encode(PayloadType.plain, forKey: .type)
            try container.encode(text, forKey: .text)
        }
    }
}
