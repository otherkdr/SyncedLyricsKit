import Foundation

/// Normalizes track metadata (titles, artists, albums) for matching and
/// cache keys: strips featured-artist credits, parenthetical qualifiers,
/// edition noise ("Remastered", "Deluxe", …), diacritics, and punctuation,
/// leaving lowercase alphanumeric words.
///
/// Useful when building lookup queries or cache keys around lyrics — two
/// spellings of the same track ("Song (feat. X) [2011 Remaster]" vs.
/// "Song") normalize to the same string.
public enum TrackMetadataNormalizer {
    public static func normalized(_ value: String?) -> String {
        normalized(value ?? "")
    }

    public static func normalized(_ value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .widthInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(
                of: #"\b(feat|ft|featuring|with)\b\.?\s+[^-()\[\]]+"#,
                with: "",
                options: .regularExpression
            )
            .replacingOccurrences(of: #"\s*\([^)]*\)"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s*\[[^\]]*\]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(
                of: #"\b(remaster(?:ed)?|deluxe|anniversary|expanded|explicit|clean|radio edit|single version|album version|live|sped up|slowed|nightcore|karaoke|instrumental|acoustic|demo|edit|version)\b"#,
                with: " ",
                options: .regularExpression
            )
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A normalized cache key for a track identity, joining the components
    /// with a separator that can't appear in normalized output.
    public static func cacheKey(title: String, artist: String, album: String = "") -> String {
        [normalized(title), normalized(artist), normalized(album)]
            .joined(separator: "\u{1F}")
    }
}
