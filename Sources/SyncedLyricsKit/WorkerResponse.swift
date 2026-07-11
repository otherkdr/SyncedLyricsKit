import Foundation

/// The JSON response shape of a [better-lyrics/cf-api](https://github.com/better-lyrics/cf-api)
/// worker's `/lyrics` endpoint. Decode it with a plain `JSONDecoder`, then
/// call ``bestLyrics()`` to run the multi-source selection and parsing:
///
/// ```swift
/// let response = try JSONDecoder().decode(WorkerLyricsResponse.self, from: data)
/// let lyrics = response.bestLyrics()
/// ```
///
/// This type performs no networking — fetching the response is your app's
/// job (see the README for a full backend setup guide).
public struct WorkerLyricsResponse: Sendable, Decodable {
    public let song: String?
    public let artist: String?
    public let album: String?
    public let duration: String?
    public let videoId: String?
    /// Timing hint for `binimumTtml`: whether span times are absolute or
    /// relative to their paragraph.
    public let binimumTimingType: String?
    /// Apple Music–style TTML, typically with syllable timing.
    public let binimumTtml: String?
    public let goLyricsApiTtml: String?
    public let goLyricsApiLyrics: String?
    public let qqLyricsApiLyrics: String?
    /// Musixmatch rich-sync (enhanced LRC with inline word tags).
    public let musixmatchWordByWordLyrics: String?
    public let musixmatchSyncedLyrics: String?
    public let lrclibSyncedLyrics: String?
    public let lrclibPlainLyrics: String?
    public let kugouLyricsApiLyrics: String?

    public init(
        song: String? = nil,
        artist: String? = nil,
        album: String? = nil,
        duration: String? = nil,
        videoId: String? = nil,
        binimumTimingType: String? = nil,
        binimumTtml: String? = nil,
        goLyricsApiTtml: String? = nil,
        goLyricsApiLyrics: String? = nil,
        qqLyricsApiLyrics: String? = nil,
        musixmatchWordByWordLyrics: String? = nil,
        musixmatchSyncedLyrics: String? = nil,
        lrclibSyncedLyrics: String? = nil,
        lrclibPlainLyrics: String? = nil,
        kugouLyricsApiLyrics: String? = nil
    ) {
        self.song = song
        self.artist = artist
        self.album = album
        self.duration = duration
        self.videoId = videoId
        self.binimumTimingType = binimumTimingType
        self.binimumTtml = binimumTtml
        self.goLyricsApiTtml = goLyricsApiTtml
        self.goLyricsApiLyrics = goLyricsApiLyrics
        self.qqLyricsApiLyrics = qqLyricsApiLyrics
        self.musixmatchWordByWordLyrics = musixmatchWordByWordLyrics
        self.musixmatchSyncedLyrics = musixmatchSyncedLyrics
        self.lrclibSyncedLyrics = lrclibSyncedLyrics
        self.lrclibPlainLyrics = lrclibPlainLyrics
        self.kugouLyricsApiLyrics = kugouLyricsApiLyrics
    }

    /// Selects and parses the best available lyrics from the response.
    ///
    /// Priority: word-by-word/syllable sources first (Binimum TTML,
    /// GoLyrics TTML, Musixmatch rich-sync), then the same sources at
    /// line level, then the remaining line-synced providers, and finally
    /// LRCLIB plain text. Returns `nil` when no source yields anything.
    public func bestLyrics(logger: LyricsLogger? = nil) -> ParsedLyrics? {
        let ttmlParser = TTMLParser()
        let lrcParser = LRCParser()

        let binimum = binimumTtml.map {
            ttmlParser.parse($0, timing: TTMLTimingHint(sourceHint: binimumTimingType), logger: logger)
        }
        let goLyricsTtml = goLyricsApiTtml.map { ttmlParser.parse($0, logger: logger) }
        let musixmatchRich = musixmatchWordByWordLyrics.map { lrcParser.parse($0, logger: logger) }

        // A line whose granularity beats `.line` — or that carries timed
        // background vocals — means the source has real per-word timing.
        func hasWordTiming(_ lines: [LyricLine]?) -> Bool {
            lines?.contains {
                $0.granularity != .line || $0.backgroundWords?.isEmpty == false
            } == true
        }

        // First pass: prefer sources that actually deliver word timing.
        for candidate in [binimum, goLyricsTtml, musixmatchRich] {
            if let lines = candidate, !lines.isEmpty, hasWordTiming(lines) {
                logger?("WorkerLyricsResponse: selected a word-timed or syllable-timed source because it provided the richest timing")
                return .timed(lines)
            }
        }

        // Second pass: the same sources at line level beat the rest, since
        // they tend to have better text quality.
        for candidate in [binimum, goLyricsTtml, musixmatchRich] {
            if let lines = candidate, !lines.isEmpty {
                logger?("WorkerLyricsResponse: selected a line-level source because richer timing was not available")
                return .timed(lines)
            }
        }

        let lineLevelSources = [
            goLyricsApiLyrics,
            qqLyricsApiLyrics,
            kugouLyricsApiLyrics,
            musixmatchSyncedLyrics,
            lrclibSyncedLyrics
        ]
        for source in lineLevelSources {
            if let source, case let lines = lrcParser.parse(source, logger: logger), !lines.isEmpty {
                logger?("WorkerLyricsResponse: selected an LRC-based source from the worker payload")
                return .timed(lines)
            }
        }

        if let plain = lrclibPlainLyrics?.trimmingCharacters(in: .whitespacesAndNewlines), !plain.isEmpty {
            logger?("WorkerLyricsResponse: falling back to plain text because no synced lyrics were available")
            return .plain(plain)
        }

        return nil
    }
}
