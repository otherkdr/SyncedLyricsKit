# SyncedLyricsKit

**Word-by-word and syllable-timed lyrics for Swift — fetched, parsed, and structured. First of its kind.**

Synchronized lyric data is fragmented across multiple providers and formats, each with its own quirks: nested background-vocal markup, duet voice metadata, translations embedded in document heads, and span timestamps that may be absolute or relative depending on the producer. SyncedLyricsKit normalizes all of it behind one API.

Give it raw lyric data — TTML (including the Apple Music dialect), standard LRC, or enhanced/rich-sync LRC — and it returns structured, display-ready Swift models timed down to the individual syllable. For the full pipeline, the built-in [`LyricsFetcher`](#fetching-lyricsfetcher) resolves the currently playing track and retrieves lyrics from your own backend. The parsers themselves never touch the network.

> [!IMPORTANT]
> **`LyricsFetcher` works out of the box with no backend** — it falls back to the free, keyless **[LRCLIB API](https://lrclib.net/)** whenever a worker isn't configured, fails, or returns nothing usable. For the richest results (word-by-word / syllable timing from Musixmatch rich-sync and Apple Music TTML), deploy the optional **[better-lyrics/cf-api](https://github.com/better-lyrics/cf-api)** Cloudflare Worker, which aggregates Musixmatch, LRCLIB, Binimum (Apple Music TTML), GoLyrics, QQ Music, and Kugou into one JSON response this package decodes natively. When both a worker and LRCLIB return lyrics, the worker's are preferred; LRCLIB runs concurrently so it adds no latency. Deployment fits within Cloudflare's free tier; the complete [setup tutorial](#setting-up-a-lyrics-backend-better-lyricscf-api) is below. If you are developing for an app with a wide range of customers, be aware that the worker's upstream providers may cost money in the near future.

> [!INFO]
Now, you may be asking: "Why can't there just be a unified worker in this package?" My reasoning for that is that creating a unified Cloudflare worker would be heavily costly for me and would make it impossible to be open source.

---

## Table of Contents

- [Features](#features)
- [Requirements](#requirements)
- [Installation](#installation)
- [Quick Start](#quick-start)
- [The Data Model](#the-data-model)
- [Supported Formats](#supported-formats)
- [Parsing API](#parsing-api)
- [Working with Worker Responses](#working-with-worker-responses)
- [Fetching (LyricsFetcher)](#fetching-lyricsfetcher)
- [Caching (LyricsDiskCache)](#caching-lyricsdiskcache)
- [Basic SwiftUI Renderer](#basic-swiftui-renderer)
- [Rendering Guidance](#rendering-guidance)
- [Setting Up a Lyrics Backend (better-lyrics/cf-api)](#setting-up-a-lyrics-backend-better-lyricscf-api)
- [Utilities](#utilities)
- [Design Notes](#design-notes)
- [Credits](#credits)
- [Contributing](#contributing)
- [License](#license)

---

## Features

- 🎤 **Syllable-level timing** — Apple Music–style TTML parses into words made of individually timed syllables (`"Hap"` + `"py"`), ready for karaoke-style rendering.
- 🗣 **Word-by-word timing** — Musixmatch rich-sync / enhanced LRC (`<mm:ss.xx>` inline tags) parses into per-word timing with inferred durations.
- 📝 **Line-synced and plain fallbacks** — standard `[mm:ss.xx]` LRC and plain text flow through the same unified model, so your renderer handles every quality level with one code path.
- 🎶 **Background vocals** — parenthetical ad-libs and TTML `x-bg` spans are separated into their own timed stream instead of polluting the main line.
- 🎭 **Duet support** — TTML `ttm:agent` voice metadata survives parsing, so you can align voices left/right.
- 🌍 **Translations** — Apple Music TTML per-line translations are attached to their lines (only for non-English sources, where they're meaningful).
- 🧠 **Smart structuring** — line end-times are taken from the last sung word (so duet overlaps and instrumental gaps stay visible), background-only lines are folded into their neighbors, and every line self-reports its timing granularity.
- 🛡 **Tolerant of real-world data** — unbalanced tags, HTML entities, JSON-wrapped payloads, absolute *or* relative TTML span timing: all handled.
- 🚀 **Complete fetching pipeline** — `LyricsFetcher` resolves the playing track to its official YouTube Topic video, requests your worker, coalesces duplicate in-flight requests, falls back through raw-JSON scanning and embedded-URL following when response shapes drift, and infers missing metadata from the resolved video.
- 💾 **Self-maintaining persistent cache** — `LyricsDiskCache` persists results across launches with expiry, schema versioning, and a size ceiling; empty payloads are never cached, so a transient failure cannot pin a bad result to a track.
- 🔑 **No YouTube API key** — topic-video resolution runs through [YouTubeKit](https://github.com/b5i/YouTubeKit)'s keyless InnerTube access, with a custom YouTube Music *songs* search that surfaces official `Artist - Topic` videos directly. No Google Cloud project, no 10,000-unit daily quota.
- 📦 **Fully `Sendable`, `Codable` models** — everything round-trips through `JSONEncoder` for custom persistence layers. One dependency ([YouTubeKit](https://github.com/b5i/YouTubeKit)), used only by the fetcher; the parsers are dependency-free.

## Requirements

- **macOS 13+**
- **Swift 6.0+** (Xcode 16 or later)

SyncedLyricsKit is macOS-focused because syllable-timed lyric rendering is primarily a desktop music-companion use case, and the package is tested against that platform.

## Installation

### Swift Package Manager (Xcode)

1. In Xcode: **File → Add Package Dependencies…**
2. Enter the repository URL: `https://github.com/otherkdr/SyncedLyricsKit`
3. Add the **SyncedLyricsKit** library to your target.

### Package.swift

```swift
dependencies: [
    .package(url: "https://github.com/otherkdr/SyncedLyricsKit.git", from: "2.0.0")
],
targets: [
    .target(
        name: "YourApp",
        dependencies: ["SyncedLyricsKit"]
    )
]
```

## Quick Start

```swift
import SyncedLyricsKit

// Parse anything — format is auto-detected (TTML, LRC, enhanced LRC, plain).
guard let lyrics = SyncedLyrics.parse(rawLyricString) else {
    // Nothing usable in the input.
    return
}

switch lyrics {
case .timed(let lines):
    for line in lines {
        print("\(line.start)s – \(line.end)s: \(line.text)")
        for word in line.words {
            print("  word '\(word.text)' at \(word.start)s")
            for syllable in word.syllables {
                print("    syllable '\(syllable.text)' at \(syllable.start)s")
            }
        }
    }
case .plain(let text):
    print(text)
}
```

Check what timing quality you got:

```swift
switch lyrics.granularity {
case .syllable: // karaoke-grade: animate syllable by syllable
case .word:     // highlight word by word
case .line:     // highlight line by line
}
```

## The Data Model

Everything parses into three nested value types, all `Sendable`, `Hashable`, `Codable`, and `Identifiable`:

```
ParsedLyrics
├── .timed([LyricLine])          // synchronized lyrics
│     └── LyricLine
│           ├── start / end      // absolute seconds
│           ├── text             // display text (main vocal)
│           ├── words            // [LyricWord] — always ≥ 1 for non-empty lines
│           │     └── LyricWord
│           │           ├── text / start / duration
│           │           └── syllables  // [LyricSyllable] — only for multi-syllable words
│           ├── backgroundWords  // [LyricWord]? — backing vocals / ad-libs
│           ├── translation      // String? — embedded per-line translation
│           ├── voice            // String? — TTML duet agent id
│           └── granularity      // .line / .word / .syllable
└── .plain(String)               // unsynchronized text
```

Key guarantees:

- **Uniform shape.** A plain line-synced source still yields `words` (a single word spanning the line), so one renderer handles everything.
- **Honest end times.** `LyricLine.end` comes from the last timed word when word durations exist — so a genuine silence before the next line is visible (useful for instrumental-break indicators), and overlapping duet lines don't get clipped. Only when no word timing exists does `end` snap to the next line's start.
- **Syllables only when real.** `LyricWord.syllables` is empty unless the source genuinely provided more than one timed fragment for that word. No fake syllable inference.
- **Cache-friendly.** `ParsedLyrics` round-trips through `JSONEncoder`/`JSONDecoder`, so you can persist parsed results and skip re-parsing.

## Supported Formats

| Format | Example | Result |
|---|---|---|
| **TTML** (Apple Music dialect) | `<p begin="10.0"><span begin="10.0" end="10.4">Hap</span><span begin="10.4" end="10.8">py</span></p>` | Syllable-timed words, background vocals, duet voices, translations |
| **Enhanced LRC / rich-sync** | `[00:10.00]<00:10.00>Hello <00:10.50>world` | Word-timed lines, parenthetical background vocals |
| **Standard LRC** | `[00:10.00]Hello world` | Line-timed lines (multiple stamps per line supported) |
| **Plain text** | `Hello world` | `.plain` payload |
| **JSON-wrapped any-of-the-above** | `{"ttml": "<tt…"}`, `{"syncedLyrics": "[00:10…"}` | Unwrapped automatically, then parsed |

TTML details worth knowing:

- **Background vocals** — spans under a `ttm:role="x-bg"` wrapper become `backgroundWords`; literal parentheses baked into the source are stripped (renderers add their own).
- **Duets** — `ttm:agent` on a paragraph becomes `LyricLine.voice`. Map the first voice you see to one side and others to the opposite.
- **Translations** — Apple Music ships untimed `<translations>` in the head, keyed by `itunes:key`; they attach to lines as `translation`, but only when the root `xml:lang` isn't English.
- **Absolute vs. relative span timing** — some producers time spans from track start, others from their paragraph. Auto-detected by default; pass a `TTMLTimingHint` when your source tells you which (the cf-api worker's `binimumTimingType` field does exactly this).

## Parsing API

```swift
// Auto-detecting facade — the right choice most of the time.
SyncedLyrics.parse(_ raw: String) -> ParsedLyrics?

// Format-specific entry points, when you know what you have:
SyncedLyrics.parse(ttml: String, timing: TTMLTimingHint = .automatic) -> ParsedLyrics?
SyncedLyrics.parse(lrc: String) -> ParsedLyrics?

// Or use the parsers directly for [LyricLine] output:
TTMLParser().parse(_ ttml: String, timing: TTMLTimingHint = .automatic) -> [LyricLine]
LRCParser().parse(_ lrc: String) -> [LyricLine]
```

All parsing is synchronous, allocation-light, and safe to run off the main thread. Nothing throws — unusable input yields empty results or `nil`, never a crash.

## Working with Worker Responses

If your backend is a [better-lyrics/cf-api](https://github.com/better-lyrics/cf-api) worker, `WorkerLyricsResponse` decodes its `/lyrics` JSON directly and picks the best source for you:

```swift
import SyncedLyricsKit

// You fetch (networking is your app's concern)…
let (data, _) = try await URLSession.shared.data(for: request)

// …SyncedLyricsKit decodes and selects.
let response = try JSONDecoder().decode(WorkerLyricsResponse.self, from: data)

if let lyrics = response.bestLyrics() {
    render(lyrics)
}
```

`bestLyrics()` priority order:

1. **Word/syllable-timed sources** — Binimum TTML (Apple Music), GoLyrics TTML, Musixmatch rich-sync — any of these that actually delivers per-word timing wins.
2. The same three sources at **line level** (better text quality than the rest).
3. Remaining **line-synced** providers: GoLyrics, QQ Music, Kugou, Musixmatch synced, LRCLIB synced.
4. **LRCLIB plain text** as the last resort.

The Binimum TTML timing hint (`binimumTimingType`) is applied automatically.

## Fetching (LyricsFetcher)

`LyricsFetcher` implements the complete pipeline behind a single call: pass the currently playing track's metadata, receive parsed lyrics. It was extracted from a production music app and retains that implementation's robustness characteristics.

```swift
import SyncedLyricsKit

let fetcher = LyricsFetcher(
    configuration: .init(
        // ⚠️ Placeholder — replace with your own deployed worker (see the
        // backend tutorial below for creating one).
        workerBaseURL: LyricsFetcherConfiguration.placeholderWorkerBaseURL,
        authorizationToken: jwt          // nil while BYPASS_AUTH=true locally
    ),
    cache: LyricsDiskCache()             // optional, strongly recommended
)

// Feed it whatever your now-playing source reports:
let lyrics = try await fetcher.fetchLyrics(
    title: nowPlaying.title,
    artist: nowPlaying.artist,
    album: nowPlaying.album,
    duration: nowPlaying.duration
)
```

### Pipeline stages

1. **Cache check.** With a `LyricsDiskCache` attached, previously fetched tracks return immediately. Only non-empty payloads are trusted, so an empty result cached during a transient upstream failure is never served indefinitely.

2. **Request coalescing.** Concurrent fetches for the same track (duplicate UI requests, track-change races) join the existing in-flight request instead of duplicating it.

3. **YouTube Topic resolution.** The fetcher searches YouTube through [YouTubeKit](https://github.com/b5i/YouTubeKit) — YouTube's internal (InnerTube) API, **no Google API key and no quota** — for the track as an official *"Topic"* video. Searches run in two tiers: first a custom YouTube Music *songs* search (built on YouTubeKit's [custom requests](https://github.com/b5i/YouTubeKit#custom-requests-and-responses)), whose results are precisely the auto-generated `Artist - Topic` videos carrying the cleanest metadata for lyrics matching; then a plain web search as fallback. It builds a prioritized query ladder (`"Artist Song topic"` first, then album variants, symbol-sanitized titles like *Pink + White* → *Pink White*, and bare-metadata fallbacks), scores every candidate (Topic channel +100, artist/title matches, "official"/"audio" markers), and sanity-checks the winner against your metadata. If the top result doesn't plausibly match, it retries with stricter queries (*official audio*, *official video*, *lyrics*, *live*) before settling — and a weak match is deliberately never cached, so a better one can win next time. Resolved video IDs are cached in memory per track.

4. **Metadata inference.** Players sometimes report incomplete metadata (a title with no artist, or vice versa). The resolved video fills the gaps — an `"Artist - Song"` video title splits into both halves — and the inferred values are forwarded to the worker to improve its matching. Caller-supplied metadata is never overwritten, only completed.

5. **Worker request.** The video ID plus song/artist/album/duration are sent to your Cloudflare Worker's `/lyrics` endpoint, with the JWT in the `Authorization` header and a configurable `User-Agent` identifying your app.

6. **Layered response parsing.** The response decodes through `WorkerLyricsResponse.bestLyrics()` for full source-priority selection. If the envelope doesn't match (a worker fork, schema drift), the fetcher scans the raw JSON at any nesting depth for the known lyric fields, in quality order. If the response contains links to lyrics rather than embedded lyrics, each URL is followed and the full decode chain is applied to its content. `nil` is returned only when every path is exhausted.

7. **Store.** Non-empty results are written to the disk cache for subsequent launches.

`LyricsFetcher` is an actor, safe to call concurrently from any context. It throws `LyricsFetchError` for configuration and transport problems (`requestFailed(statusCode:)`, `noTopicVideoFound`), and returns `nil` when the pipeline succeeded but no source had lyrics for the track. Networking runs on an ephemeral `URLSession` (no cookie or credential persistence, waits for connectivity, timeouts configurable).

> [!WARNING]
> `LyricsFetcherConfiguration.placeholderWorkerBaseURL` (`https://better-lyrics-api.your-account.workers.dev`) is a placeholder; nothing is deployed there. Follow [Setting Up a Lyrics Backend](#setting-up-a-lyrics-backend-better-lyricscf-api) to create your own worker, then point `workerBaseURL` at it.

## Caching (LyricsDiskCache)

Lyrics rarely change once fetched, so persistent caching directly reduces bandwidth usage and worker provider quota consumption. `LyricsDiskCache` is a self-maintaining actor constructed once and passed to the fetcher:

```swift
let cache = LyricsDiskCache()                    // sensible defaults, or:
let cache = LyricsDiskCache(retentionDays: 30)   // keep entries longer (7–30)
```

Maintenance is automatic:

- **Expiry** — entries are valid for the retention window (default 14 days); expired files are swept on startup and deleted on read.
- **Schema versioning** — after a model change in a future release, old entries are invalidated rather than decoded incorrectly.
- **Size ceiling** — the cache never exceeds its limit (default 100 MiB); the oldest entries are evicted first.
- **Manual invalidation** — `clearAll()` (or `fetcher.clearCaches()`) removes every entry for a full refresh.

Entries are keyed by title + artist + album + rounded duration (SHA-256 hashed to filenames), and live in `Application Support/SyncedLyricsKit/LyricsCache` by default — pass your own directory if you'd rather keep it elsewhere.

## Basic SwiftUI Renderer

The package includes `SyncedLyricsRenderer`, a deliberately small renderer you can use directly or copy into your app and customize. Supply the current playback time whenever it changes:

```swift
SyncedLyricsRenderer(
    lyrics: lyrics,
    time: player.currentTime,
    style: LyricsRendererStyle(
        activeColor: .white,
        inactiveColor: .white.opacity(0.35),
        lyricFont: .system(size: 32, weight: .bold)
    ),
    onLineTap: { player.seek(to: $0) }
)
```

It provides active-line selection, automatic scrolling, tap-to-seek, plain-text fallback, translations, and progressive highlighting. Standard line-timed LRC is highlighted across the line's full `start...end` interval, so it animates just like richer timing rather than switching the entire line on at once.

For a completely custom view, reuse `LyricsRendererTimeline.activeLine(in:at:)` and `progress(for:at:)` while replacing the included SwiftUI layout.

## Rendering Guidance

SyncedLyricsKit deliberately stops at the model layer, but the model is shaped for rendering:

- **Karaoke highlighting** — drive a `TimelineView`/`CADisplayLink` clock off playback position; for each line where `start <= t < end`, highlight words where `word.start <= t`, and within multi-syllable words, syllables where `syllable.start <= t`.
- **Instrumental breaks** — a gap between `line.end` and the next line's `start` is real silence (end times are honest); show a dots/progress placeholder when it exceeds a few seconds.
- **Backing vocals** — render `backgroundWords` smaller/dimmer beneath the main line, in parentheses.
- **Duets** — group lines by `voice` and alternate leading/trailing alignment.
- **Translations** — show `translation` as a secondary label under the line.

## Setting Up a Lyrics Backend (better-lyrics/cf-api)

This is the full path from zero to fetching word-by-word lyrics your app can parse. The worker is a Cloudflare Worker (generous free tier) that aggregates all the lyric providers behind one endpoint.

### What you'll need

- A [Cloudflare account](https://dash.cloudflare.com/sign-up) (free tier works)
- Node.js 18+ and npm
- A [Google Cloud](https://console.cloud.google.com/) API key (YouTube Data API v3 — used to resolve song metadata from video IDs)

The lyric providers themselves — Musixmatch, LRCLIB, GoLyrics, QQ Music, Kugou — need **no API keys**; the worker reaches them through keyless endpoints. The Google key is the only provider credential you supply.

### Step 1 — Clone and install

```bash
git clone https://github.com/better-lyrics/cf-api.git
cd cf-api
npm install
npm install -g wrangler   # Cloudflare's CLI, if you don't have it
wrangler login
```

### Step 2 — Create the Cloudflare services

**D1 database** (caches lyrics so you don't hammer providers):

1. Cloudflare Dashboard → **Workers & Pages → D1** → *Create database*, name it `lyrics`.
2. Copy the `database_id` and `preview_database_id` into `wrangler.toml`:

```toml
[[d1_databases]]
binding = "DB"
database_name = "lyrics"
database_id = "YOUR_DATABASE_ID"
preview_database_id = "YOUR_PREVIEW_DATABASE_ID"
```

**Rate limiting namespace:**

1. Dashboard → **Workers & Pages → Rate Limiting** → create a namespace.
2. Paste its ID into `wrangler.toml`:

```toml
[[ratelimits]]
name = "RATE_LIMIT"
namespace_id = "YOUR_RATE_LIMIT_NAMESPACE_ID"
```

**Turnstile** (CAPTCHA that gates token issuance, so bots can't drain your API quotas):

1. Dashboard → **Turnstile** → create a site (Managed Challenge mode; use `localhost` for testing).
2. Note the **Site Key** and **Secret Key** for the next step.

### Step 3 — API key

Only one key is consumed **by the worker, server-side** — the Swift client itself needs no API key (topic-video resolution runs keyless through YouTubeKit).

**Google (YouTube Data API v3):**

1. [Google Cloud Console](https://console.cloud.google.com/) → create/select a project.
2. Enable **YouTube Data API v3**.
3. Credentials → *Create Credentials → API Key*; restrict it to YouTube Data API v3.

**Musixmatch, LRCLIB, GoLyrics, QQ Music, and Kugou** need no keys — they're reached through keyless endpoints and are already integrated.

### Step 4 — Environment variables

For local development, create `.dev.vars` in the repo root (never commit it):

```bash
TURNSTILE_SECRET_KEY=your_turnstile_secret_key
TURNSTILE_SITE_KEY=your_turnstile_site_key
GOOGLE_API_KEY=your_google_api_key
```

For local testing you can also set `BYPASS_AUTH = "true"` under `[vars]` in `wrangler.toml` to skip the Turnstile/JWT flow (**never in production**).

### Step 5 — Run locally and verify

```bash
npm run dev
```

Then hit it (with `BYPASS_AUTH` on):

```bash
curl "http://localhost:8787/lyrics?videoId=Y4gOQSZg5bQ&song=Song&artist=Artist"
```

You should get back JSON with fields like `musixmatchWordByWordLyrics`, `binimumTtml`, `lrclibSyncedLyrics` — exactly what `WorkerLyricsResponse` decodes.

### Step 6 — Deploy

Push your secrets and deploy:

```bash
wrangler secret put TURNSTILE_SECRET_KEY
wrangler secret put GOOGLE_API_KEY
npm run deploy
```

Your worker lands at `https://your-worker.your-account.workers.dev`. In `wrangler.toml`, set `BYPASS_AUTH = "false"` and lock `ALLOWED_ORIGINS` down to your domains.

### Step 7 — Authentication flow (production)

> [!TIP]
> Auth is optional. If you set `BYPASS_AUTH = "true"` in `wrangler.toml`, the worker skips Turnstile and JWTs entirely, and you can drop the whole challenge/verify flow below — `LyricsFetcher` just calls `/lyrics` directly with no token. This is the simplest setup for a private or personal backend; only enable auth when your worker is publicly reachable and you need to protect its quotas.

With auth enabled, clients authenticate once and reuse a JWT:

1. `GET /challenge` → Turnstile challenge page
2. Complete the challenge → `POST /verify-turnstile` with the token
3. Receive a JWT → send `Authorization: Bearer {JWT}` on every `/lyrics` request

### Step 8 — Wire it into Swift

```swift
import SyncedLyricsKit

func fetchLyrics(videoId: String, song: String, artist: String, jwt: String) async throws -> ParsedLyrics? {
    var components = URLComponents(string: "https://your-worker.your-account.workers.dev/lyrics")!
    components.queryItems = [
        URLQueryItem(name: "videoId", value: videoId),
        URLQueryItem(name: "song", value: song),
        URLQueryItem(name: "artist", value: artist)
    ]

    var request = URLRequest(url: components.url!)
    request.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")

    let (data, _) = try await URLSession.shared.data(for: request)
    let response = try JSONDecoder().decode(WorkerLyricsResponse.self, from: data)
    return response.bestLyrics()
}
```

> [!TIP]
> Cache parsed results. `ParsedLyrics` is `Codable` — encode it once per track (keyed by `TrackMetadataNormalizer.cacheKey(title:artist:album:)`) and you'll rarely touch the network twice for the same song.

For deeper configuration (admin endpoints, cache TTLs, streaming `/lyrics/v2`, troubleshooting), see the [cf-api setup guide](https://github.com/better-lyrics/cf-api).

## Utilities

**`TrackMetadataNormalizer`** — normalize titles/artists for matching and cache keys:

```swift
TrackMetadataNormalizer.normalized("Song Title (feat. Someone) [2011 Remaster]")
// → "song title"

TrackMetadataNormalizer.cacheKey(title: "Song (feat. X)", artist: "Artist")
// == TrackMetadataNormalizer.cacheKey(title: "Song", artist: "Artist")
```

## Design Notes

- **Regex-tolerant, not XML-strict.** Real-world lyric TTML is frequently malformed; the parser walks tags with a depth stack and shrugs off unbalanced close tags rather than failing an entire document.
- **Deterministic syllable grouping.** Syllables group into words by structural adjacency (spans with no text between them belong to one word), never by text-fragment heuristics that misfire on short real words like "to"/"do".
- **Background-only lines merge.** A line that is nothing but a parenthetical ("(ooh yeah)") folds into the previous line's background stream when it starts within 1.2 s of that line's end — so ad-libs render as backing vocals under the lyric they belong to, not as ghost lines.
- **No logging, no I/O, no state.** Parsers are pure value types; call them from anywhere.

## Credits

- The parsing and structuring logic originated in **MiniMusix**, a macOS music companion app, and was extracted, restructured, and hardened into this standalone package.
- Lyrics aggregation backend: [**better-lyrics/cf-api**](https://github.com/better-lyrics/cf-api).
- Lyric data providers this ecosystem builds on: [Musixmatch](https://www.musixmatch.com/), [LRCLIB](https://lrclib.net/), Binimum, GoLyrics, QQ Music, and Kugou.

## Contributing

Issues and pull requests are welcome — bug reports with sample lyric payloads are especially useful, since real-world format quirks drive most of this package's edge-case handling.

Run the tests with the native build system:

```bash
swift test --build-system native
```

The default SwiftPM build system leaves an unremovable `com.apple.provenance` xattr on the signed test bundle, which fails codesigning on macOS; `--build-system native` avoids it. CI runs exactly this command.

## License

MIT — see [LICENSE](LICENSE).
