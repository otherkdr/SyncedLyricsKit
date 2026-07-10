# BetterLyricsKit

**Word-by-word and syllable-timed lyrics parsing for Swift.**

BetterLyricsKit turns raw lyric data — TTML (including the Apple Music dialect), standard LRC, and enhanced/rich-sync LRC — into clean, structured, display-ready Swift models with timing down to the individual syllable. It handles the messy parts for you: syllable grouping, background/backing vocals, duet voices, embedded translations, malformed markup, and duration inference.

It is a **pure parsing library**: no networking, no API keys, no UI. You bring the lyric data; BetterLyricsKit brings the structure.

> [!IMPORTANT]
> **You need a lyrics source.** This package does not fetch lyrics — it parses them. To actually get word-by-word or syllable-timed lyric data for songs, you will need a backend such as the **[better-lyrics/cf-api](https://github.com/better-lyrics/cf-api)** Cloudflare Worker, which aggregates Musixmatch, LRCLIB, Binimum (Apple Music TTML), GoLyrics, QQ Music, and Kugou into a single JSON response that this package decodes natively. A complete [setup tutorial](#setting-up-a-lyrics-backend-better-lyricscf-api) is included below. Simpler line-synced sources like the free [LRCLIB API](https://lrclib.net/) also work out of the box.

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
- [Rendering Guidance](#rendering-guidance)
- [Setting Up a Lyrics Backend (better-lyrics/cf-api)](#setting-up-a-lyrics-backend-better-lyricscf-api)
- [Utilities](#utilities)
- [Design Notes](#design-notes)
- [Credits](#credits)
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
- 📦 **Zero dependencies, fully `Sendable`, `Codable` models** — cache parsed results straight to disk with `JSONEncoder`.

## Requirements

- **macOS 13+**
- **Swift 6.0+** (Xcode 16 or later)

BetterLyricsKit is macOS-focused because syllable-timed lyric rendering is primarily a desktop music-companion use case, and the package is tested against that platform.

## Installation

### Swift Package Manager (Xcode)

1. In Xcode: **File → Add Package Dependencies…**
2. Enter the repository URL: `https://github.com/otherkdr/BetterLyricsKit`
3. Add the **BetterLyricsKit** library to your target.

### Package.swift

```swift
dependencies: [
    .package(url: "https://github.com/otherkdr/BetterLyricsKit.git", from: "1.0.0")
],
targets: [
    .target(
        name: "YourApp",
        dependencies: ["BetterLyricsKit"]
    )
]
```

## Quick Start

```swift
import BetterLyricsKit

// Parse anything — format is auto-detected (TTML, LRC, enhanced LRC, plain).
guard let lyrics = BetterLyrics.parse(rawLyricString) else {
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
BetterLyrics.parse(_ raw: String) -> ParsedLyrics?

// Format-specific entry points, when you know what you have:
BetterLyrics.parse(ttml: String, timing: TTMLTimingHint = .automatic) -> ParsedLyrics?
BetterLyrics.parse(lrc: String) -> ParsedLyrics?

// Or use the parsers directly for [LyricLine] output:
TTMLParser().parse(_ ttml: String, timing: TTMLTimingHint = .automatic) -> [LyricLine]
LRCParser().parse(_ lrc: String) -> [LyricLine]
```

All parsing is synchronous, allocation-light, and safe to run off the main thread. Nothing throws — unusable input yields empty results or `nil`, never a crash.

## Working with Worker Responses

If your backend is a [better-lyrics/cf-api](https://github.com/better-lyrics/cf-api) worker, `WorkerLyricsResponse` decodes its `/lyrics` JSON directly and picks the best source for you:

```swift
import BetterLyricsKit

// You fetch (networking is your app's concern)…
let (data, _) = try await URLSession.shared.data(for: request)

// …BetterLyricsKit decodes and selects.
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

## Rendering Guidance

BetterLyricsKit deliberately stops at the model layer, but the model is shaped for rendering:

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
- A [Musixmatch developer](https://developer.musixmatch.com/) API key (for word-by-word lyrics)

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

### Step 3 — API keys

**Google (YouTube Data API v3):**

1. [Google Cloud Console](https://console.cloud.google.com/) → create/select a project.
2. Enable **YouTube Data API v3**.
3. Credentials → *Create Credentials → API Key*; restrict it to YouTube Data API v3.

**Musixmatch:**

1. Sign up at [developer.musixmatch.com](https://developer.musixmatch.com/).
2. Create an application and copy your API key.

**LRCLIB** needs no key — it's free and already integrated.

### Step 4 — Environment variables

For local development, create `.dev.vars` in the repo root (never commit it):

```bash
TURNSTILE_SECRET_KEY=your_turnstile_secret_key
TURNSTILE_SITE_KEY=your_turnstile_site_key
GOOGLE_API_KEY=your_google_api_key
MUSIXMATCH_API_KEY=your_musixmatch_api_key
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
wrangler secret put MUSIXMATCH_API_KEY
npm run deploy
```

Your worker lands at `https://your-worker.your-account.workers.dev`. In `wrangler.toml`, set `BYPASS_AUTH = "false"` and lock `ALLOWED_ORIGINS` down to your domains.

### Step 7 — Authentication flow (production)

With auth enabled, clients authenticate once and reuse a JWT:

1. `GET /challenge` → Turnstile challenge page
2. Complete the challenge → `POST /verify-turnstile` with the token
3. Receive a JWT → send `Authorization: Bearer {JWT}` on every `/lyrics` request

### Step 8 — Wire it into Swift

```swift
import BetterLyricsKit

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

## License

MIT — see [LICENSE](LICENSE).
