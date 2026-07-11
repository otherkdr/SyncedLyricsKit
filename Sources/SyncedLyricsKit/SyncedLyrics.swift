import Foundation

/// The main entry point: hands a raw lyrics string to the right parser.
///
/// ```swift
/// if let lyrics = SyncedLyrics.parse(rawString) {
///     switch lyrics {
///     case .timed(let lines): render(lines)
///     case .plain(let text):  showPlain(text)
///     }
/// }
/// ```
public enum SyncedLyrics {
    /// Parses a lyrics string of unknown format, auto-detecting between
    /// TTML, enhanced/standard LRC, and plain text — in that order of
    /// preference. JSON-wrapped payloads (a common shape for lyrics APIs,
    /// e.g. `{"ttml": "..."}` or a bare JSON-encoded string) are unwrapped
    /// first.
    ///
    /// Returns `nil` when the input contains nothing usable.
    public static func parse(_ raw: String, logger: LyricsLogger? = nil) -> ParsedLyrics? {
        logger?("SyncedLyrics: starting parse for input of length \(raw.count)")

        if let unwrapped = unwrapNestedPayload(raw), unwrapped != raw {
            logger?("SyncedLyrics: unwrapped a nested JSON/string payload before parsing")
            return parse(unwrapped, logger: logger)
        }

        if raw.contains("<tt") {
            logger?("SyncedLyrics: attempting TTML parsing because the input looks like TTML")
            let lines = TTMLParser().parse(raw, logger: logger)
            if !lines.isEmpty {
                logger?("SyncedLyrics: parsed \(lines.count) TTML line(s) successfully")
                return .timed(lines)
            }
        }

        logger?("SyncedLyrics: attempting LRC parsing as a fallback format")
        let lines = LRCParser().parse(raw, logger: logger)
        if !lines.isEmpty {
            logger?("SyncedLyrics: parsed \(lines.count) LRC line(s) successfully")
            return .timed(lines)
        }

        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            logger?("SyncedLyrics: input was empty after trimming, so no lyrics were parsed")
            return nil
        }

        logger?("SyncedLyrics: falling back to plain text because no timed lyrics were found")
        return .plain(trimmed)
    }

    /// Parses a known-TTML document. Prefer this over `parse(_:)` when you
    /// already know the format, or when you have a timing hint from the
    /// source (see ``TTMLTimingHint``).
    public static func parse(ttml: String, timing: TTMLTimingHint = .automatic, logger: LyricsLogger? = nil) -> ParsedLyrics? {
        logger?("SyncedLyrics: parsing TTML directly with timing hint \(timing)")
        let lines = TTMLParser().parse(ttml, timing: timing, logger: logger)
        return lines.isEmpty ? nil : .timed(lines)
    }

    /// Parses a known-LRC document (standard or enhanced/rich-sync).
    public static func parse(lrc: String, logger: LyricsLogger? = nil) -> ParsedLyrics? {
        logger?("SyncedLyrics: parsing LRC directly as a known LRC document")
        let lines = LRCParser().parse(lrc, logger: logger)
        return lines.isEmpty ? nil : .timed(lines)
    }

    /// Unwraps one layer of JSON packaging around a lyrics string: either an
    /// object exposing a well-known key (`ttml`, `lyrics`, `syncedLyrics`,
    /// `plainLyrics`, `content`) or a bare JSON-encoded string.
    static func unwrapNestedPayload(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let data = trimmed.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) {
            if let dictionary = object as? [String: Any] {
                let knownKeys = ["ttml", "lyrics", "syncedLyrics", "plainLyrics", "content"]
                for key in knownKeys {
                    if let value = dictionary[key] as? String,
                       !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        return value
                    }
                }
            }

            if let string = object as? String,
               !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return string
            }
        }

        if trimmed.first == "\"", trimmed.last == "\"",
           let data = trimmed.data(using: .utf8),
           let value = try? JSONDecoder().decode(String.self, from: data) {
            return value
        }

        return nil
    }
}
