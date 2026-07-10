import Foundation

/// Shared low-level helpers used by the format parsers.
enum ParsingSupport {
    /// Parses a TTML-style time expression into seconds. Accepts
    /// `hh:mm:ss.fff`, `mm:ss.fff`, and bare seconds with an optional
    /// trailing `s` (`"12.5s"`). Returns 0 for unrecognized input.
    static func parseTimeExpression(_ value: String?) -> TimeInterval {
        guard let value else { return 0 }
        let trimmed = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "s", with: "")

        let patterns = [
            #"^(\d+):(\d{2}):(\d{2})(?:\.(\d{1,3}))?$"#,
            #"^(\d{1,2}):(\d{2})(?:\.(\d{1,3}))?$"#,
            #"^(\d+(?:\.\d+)?)$"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)) else {
                continue
            }

            func group(_ index: Int) -> String {
                guard let range = Range(match.range(at: index), in: trimmed) else { return "" }
                return String(trimmed[range])
            }

            switch match.numberOfRanges {
            case 5:
                let hours = Double(group(1)) ?? 0
                let minutes = Double(group(2)) ?? 0
                let seconds = Double(group(3)) ?? 0
                return hours * 3600 + minutes * 60 + seconds + parseFraction(group(4))
            case 4:
                let minutes = Double(group(1)) ?? 0
                let seconds = Double(group(2)) ?? 0
                return minutes * 60 + seconds + parseFraction(group(3))
            case 2:
                return Double(group(1)) ?? 0
            default:
                continue
            }
        }

        return 0
    }

    /// Parses a compact `m:ss` / `mm:ss.fff` timestamp (the form used inside
    /// LRC word tags) into seconds.
    static func parseMinuteSecondTimestamp(_ value: String) -> TimeInterval {
        let parts = value.split(separator: ":")
        guard parts.count == 2 else { return 0 }
        let minutes = Double(parts[0]) ?? 0
        let seconds = Double(parts[1]) ?? 0
        return minutes * 60 + seconds
    }

    /// Interprets a fractional-seconds group by digit count, so `.5`, `.50`,
    /// and `.500` all mean half a second.
    static func parseFraction(_ text: String) -> TimeInterval {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return 0 }
        if cleaned.count <= 3, let value = Double(cleaned) {
            return value / pow(10, Double(cleaned.count))
        }
        return Double("0.\(cleaned)") ?? 0
    }

    /// Extracts a quoted attribute value (`name="value"`) from a tag's
    /// attribute string, case-insensitively.
    static func attribute(in attributes: String, named name: String) -> String? {
        let pattern = #"\b"# + NSRegularExpression.escapedPattern(for: name) + #"\s*=\s*"([^"]+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: attributes, range: NSRange(attributes.startIndex..., in: attributes)),
              match.numberOfRanges >= 2,
              let range = Range(match.range(at: 1), in: attributes) else {
            return nil
        }
        return String(attributes[range])
    }

    /// Strips markup tags, decodes the common HTML entities lyric sources
    /// emit, and collapses runs of whitespace.
    static func normalizeMarkupText(_ text: String) -> String {
        text
            .replacingOccurrences(of: #"<br\s*/?>"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
