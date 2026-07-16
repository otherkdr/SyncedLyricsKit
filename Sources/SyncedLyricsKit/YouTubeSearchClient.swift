import Foundation
import YouTubeKit

/// A single video returned by a YouTube search, reduced to the three fields
/// the topic-video resolver scores against.
public struct YouTubeVideoCandidate: Sendable, Hashable {
    /// The YouTube video identifier, e.g. `"dQw4w9WgXcQ"`.
    public let videoId: String
    /// The channel that published the video. Official auto-generated music
    /// channels end in `"- Topic"`, which the resolver scores highest.
    public let channelTitle: String
    /// The video's display title.
    public let title: String

    public init(videoId: String, channelTitle: String, title: String) {
        self.videoId = videoId
        self.channelTitle = channelTitle
        self.title = title
    }
}

/// Abstracts the YouTube search that resolves a track to its official
/// "Topic" video. The production implementation is
/// ``YouTubeKitSearchClient``; tests inject stubs so no network is touched.
public protocol YouTubeSearchClient: Sendable {
    /// Runs one search and returns candidates in ranking order.
    func searchVideos(matching query: String) async throws -> [YouTubeVideoCandidate]
}

/// The default ``YouTubeSearchClient``, backed by
/// [b5i/YouTubeKit](https://github.com/b5i/YouTubeKit). It speaks YouTube's
/// internal (InnerTube) API directly, so **no Google API key and no quota**
/// are involved — each search is a single anonymous HTTPS request.
///
/// Searches run in two tiers:
///
/// 1. **YouTube Music songs search** — a custom InnerTube request (via
///    YouTubeKit's custom-response machinery) against
///    `music.youtube.com` filtered to *songs*. Every song result is the
///    track's auto-generated video on its official `Artist - Topic`
///    channel, which is exactly what the lyrics worker wants; plain web
///    search rarely surfaces those.
/// 2. **Web search fallback** — YouTubeKit's stock ``SearchResponse``
///    against `youtube.com`, used when the songs search returns nothing
///    (obscure uploads, non-music content).
public struct YouTubeKitSearchClient: YouTubeSearchClient {
    /// Search results below this rank are noise for track matching.
    private static let maxCandidates = 12

    public init() {}

    public func searchVideos(matching query: String) async throws -> [YouTubeVideoCandidate] {
        let sanitized = Self.sanitizedQuery(query)
        guard !sanitized.isEmpty else { return [] }

        // YouTubeModel is a lightweight, non-Sendable headers container;
        // building one per request keeps this client safely Sendable.
        let model = YouTubeModel()
        MusicSongSearchResponse.registerHeaders(on: model)

        if let music = try? await MusicSongSearchResponse.sendThrowingRequest(
            youtubeModel: model,
            data: [.query: sanitized]
        ), !music.songs.isEmpty {
            return music.songs.prefix(Self.maxCandidates).map { song in
                YouTubeVideoCandidate(
                    videoId: song.videoId,
                    // Songs live on the artist's auto-generated channel,
                    // which YouTube names "<Artist> - Topic".
                    channelTitle: song.artist.isEmpty ? "" : "\(song.artist) - Topic",
                    title: song.title
                )
            }
        }

        let response = try await SearchResponse.sendThrowingRequest(
            youtubeModel: model,
            data: [.query: sanitized]
        )

        return response.results
            .lazy
            .compactMap { result -> YouTubeVideoCandidate? in
                guard let video = result as? YTVideo, !video.videoId.isEmpty else { return nil }
                return YouTubeVideoCandidate(
                    videoId: video.videoId,
                    channelTitle: video.channel?.name ?? "",
                    title: video.title ?? ""
                )
            }
            .prefix(Self.maxCandidates)
            .map { $0 }
    }

    /// YouTubeKit splices the query into the InnerTube JSON body without
    /// escaping it, so quotes, backslashes, and control characters would
    /// corrupt the request (HTTP 400). None of them carry search relevance
    /// for track titles, so drop them.
    static func sanitizedQuery(_ query: String) -> String {
        String(query.unicodeScalars.filter { scalar in
            scalar != "\"" && scalar != "\\" && !CharacterSet.controlCharacters.contains(scalar)
        })
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// A custom YouTubeKit response for YouTube Music's search endpoint,
/// filtered to *songs*. Built on YouTubeKit's
/// [custom requests and responses](https://github.com/b5i/YouTubeKit#custom-requests-and-responses)
/// support.
struct MusicSongSearchResponse: YouTubeResponse {
    static let customHeadersID = "SyncedLyricsKit.musicSongSearch"
    static let headersType: HeaderTypes = .customHeaders(customHeadersID)
    static let parametersValidationList: ValidationList = [.query: .existenceValidator]

    /// The InnerTube `params` filter for "songs only" search results.
    private static let songsFilterParams = "EgWKAQIIAWoKEAkQBRAKEAMQBA%3D%3D"

    struct Song: Sendable {
        let videoId: String
        let title: String
        let artist: String
    }

    var songs: [Song] = []

    /// Registers the headers generator this response type needs on `model`.
    /// Must be called before sending the request through that model.
    static func registerHeaders(on model: YouTubeModel) {
        // Capture plain strings, not the model, to avoid a retain cycle
        // (the model stores this closure for its lifetime).
        let languageCode = model.selectedLocaleLanguageCode
        let countryCode = model.selectedLocaleCountryCode.uppercased()

        model.customHeadersFunctions[customHeadersID] = {
            HeadersList(
                url: URL(string: "https://music.youtube.com/youtubei/v1/search")!,
                method: .POST,
                headers: [
                    .init(name: "Accept", content: "*/*"),
                    .init(name: "Content-Type", content: "application/json"),
                    .init(name: "Host", content: "music.youtube.com"),
                    .init(name: "Origin", content: "https://music.youtube.com"),
                    .init(name: "Referer", content: "https://music.youtube.com/")
                ],
                addQueryAfterParts: [
                    .init(index: 0, encode: false)
                ],
                httpBody: [
                    #"{"context":{"client":{"clientName":"WEB_REMIX","clientVersion":"1.20250101.01.00","hl":"\#(languageCode)","gl":"\#(countryCode)"}},"query":""#,
                    #"","params":"\#(songsFilterParams)"}"#
                ],
                parameters: [
                    .init(name: "prettyPrint", content: "false")
                ]
            )
        }
    }

    static func decodeJSON(json: JSON) throws -> MusicSongSearchResponse {
        var response = MusicSongSearchResponse()

        // Shape: contents.tabbedSearchResultsRenderer.tabs[].tabRenderer
        //   .content.sectionListRenderer.contents[].musicShelfRenderer
        //   .contents[].musicResponsiveListItemRenderer
        for tab in json["contents", "tabbedSearchResultsRenderer", "tabs"].arrayValue {
            let sections = tab["tabRenderer", "content", "sectionListRenderer", "contents"].arrayValue
            for section in sections {
                for entry in section["musicShelfRenderer", "contents"].arrayValue {
                    let renderer = entry["musicResponsiveListItemRenderer"]
                    let videoId = renderer["playlistItemData", "videoId"].stringValue
                    guard !videoId.isEmpty else { continue }

                    // Column 0 is the song title; column 1's first text run
                    // is the primary artist ("Artist • Album • 3:05").
                    let columns = renderer["flexColumns"].arrayValue
                    let title = columns.first?["musicResponsiveListItemFlexColumnRenderer", "text", "runs"]
                        .arrayValue.first?["text"].stringValue ?? ""
                    let artist = columns.dropFirst().first?["musicResponsiveListItemFlexColumnRenderer", "text", "runs"]
                        .arrayValue.first?["text"].stringValue ?? ""

                    response.songs.append(Song(videoId: videoId, title: title, artist: artist))
                }
            }
        }

        return response
    }
}
