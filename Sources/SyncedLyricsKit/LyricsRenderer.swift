#if canImport(SwiftUI)
import SwiftUI

/// Styling for ``SyncedLyricsRenderer``.
///
/// This deliberately uses ordinary SwiftUI values rather than hiding the
/// renderer behind a fixed theme. Copy it, extend it, or provide a different
/// configuration anywhere you use the package.
@available(macOS 13.0, *)
public struct LyricsRendererStyle {
    public var activeColor: Color
    public var inactiveColor: Color
    public var backgroundColor: Color
    public var lyricFont: Font
    public var translationFont: Font
    /// Font for the background/harmony-vocal sub-line. Usually smaller than
    /// ``lyricFont``.
    public var backgroundVocalFont: Font
    /// Whether to show the background/harmony-vocal sub-line on the active
    /// line. Off hides it entirely.
    public var showBackgroundVocals: Bool
    public var lineSpacing: CGFloat
    public var horizontalPadding: CGFloat
    public var verticalPadding: CGFloat
    public var inactiveScale: CGFloat
    public var scrollAnimation: Animation?

    public init(
        activeColor: Color = .primary,
        inactiveColor: Color = .secondary.opacity(0.55),
        backgroundColor: Color = .clear,
        lyricFont: Font = .system(size: 28, weight: .bold, design: .rounded),
        translationFont: Font = .system(size: 15, weight: .regular),
        backgroundVocalFont: Font = .system(size: 17, weight: .regular),
        showBackgroundVocals: Bool = true,
        lineSpacing: CGFloat = 22,
        horizontalPadding: CGFloat = 24,
        verticalPadding: CGFloat = 80,
        inactiveScale: CGFloat = 0.96,
        scrollAnimation: Animation? = .easeInOut(duration: 0.35)
    ) {
        self.activeColor = activeColor
        self.inactiveColor = inactiveColor
        self.backgroundColor = backgroundColor
        self.lyricFont = lyricFont
        self.translationFont = translationFont
        self.backgroundVocalFont = backgroundVocalFont
        self.showBackgroundVocals = showBackgroundVocals
        self.lineSpacing = lineSpacing
        self.horizontalPadding = horizontalPadding
        self.verticalPadding = verticalPadding
        self.inactiveScale = inactiveScale
        self.scrollAnimation = scrollAnimation
    }
}

/// A small, editable SwiftUI starting point for displaying ``ParsedLyrics``.
///
/// Pass the player's current time on every playback update. The renderer
/// selects and scrolls to the active line, then fills that line according to
/// its timing. Line-timed lyrics use the complete line interval, so they get
/// the same progressive highlighting behavior as richer sources. When the
/// active line carries background/harmony vocals, they appear as a single
/// dimmed sub-line beneath it (toggle with ``LyricsRendererStyle/showBackgroundVocals``).
///
/// ```swift
/// SyncedLyricsRenderer(lyrics: lyrics, time: player.currentTime) { start in
///     player.seek(to: start)
/// }
/// ```
@available(macOS 13.0, *)
public struct SyncedLyricsRenderer: View {
    public let lyrics: ParsedLyrics
    public let time: TimeInterval
    public var style: LyricsRendererStyle
    public var onLineTap: ((TimeInterval) -> Void)?

    public init(
        lyrics: ParsedLyrics,
        time: TimeInterval,
        style: LyricsRendererStyle = LyricsRendererStyle(),
        onLineTap: ((TimeInterval) -> Void)? = nil
    ) {
        self.lyrics = lyrics
        self.time = time
        self.style = style
        self.onLineTap = onLineTap
    }

    public var body: some View {
        Group {
            switch lyrics {
            case .timed(let lines):
                timedLyrics(lines)
            case .plain(let text):
                ScrollView {
                    Text(text)
                        .font(style.lyricFont)
                        .foregroundStyle(style.activeColor)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, style.horizontalPadding)
                        .padding(.vertical, style.verticalPadding)
                }
            }
        }
        .background(style.backgroundColor)
    }

    private func timedLyrics(_ lines: [LyricLine]) -> some View {
        let activeID = LyricsRendererTimeline.activeLine(in: lines, at: time)?.id

        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: style.lineSpacing) {
                    ForEach(lines) { line in
                        lineView(line, isActive: line.id == activeID)
                            .id(line.id)
                            .contentShape(Rectangle())
                            .onTapGesture { onLineTap?(line.start) }
                    }
                }
                .padding(.horizontal, style.horizontalPadding)
                .padding(.vertical, style.verticalPadding)
            }
            .onChange(of: activeID) { newID in
                guard let newID else { return }
                if let animation = style.scrollAnimation {
                    withAnimation(animation) { proxy.scrollTo(newID, anchor: .center) }
                } else {
                    proxy.scrollTo(newID, anchor: .center)
                }
            }
        }
    }

    private func lineView(_ line: LyricLine, isActive: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            ProgressiveLyricText(
                text: line.text,
                progress: LyricsRendererTimeline.progress(for: line, at: time),
                font: style.lyricFont,
                activeColor: style.activeColor,
                inactiveColor: style.inactiveColor
            )

            if let translation = line.translation, !translation.isEmpty {
                Text(translation)
                    .font(style.translationFont)
                    .foregroundStyle(isActive ? style.activeColor.opacity(0.72) : style.inactiveColor)
            }

            // Background / harmony vocals: a single dimmed, italic sub-line,
            // shown only on the active line so idle rows stay as cheap as
            // possible (no per-word timing, no view built when inactive).
            if isActive, style.showBackgroundVocals,
               let background = LyricsRendererTimeline.backgroundVocalText(for: line) {
                Text(background)
                    .font(style.backgroundVocalFont)
                    .italic()
                    .foregroundStyle(style.inactiveColor)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .scaleEffect(isActive ? 1 : style.inactiveScale, anchor: .leading)
        .opacity(isActive ? 1 : 0.82)
        .animation(.easeOut(duration: 0.2), value: isActive)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(line.text)
        .accessibilityValue(isActive ? "Current lyric" : "")
    }
}

@available(macOS 13.0, *)
private struct ProgressiveLyricText: View {
    let text: String
    let progress: Double
    let font: Font
    let activeColor: Color
    let inactiveColor: Color

    var body: some View {
        Text(text)
            .font(font)
            .foregroundStyle(inactiveColor)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .leading) {
                GeometryReader { geometry in
                    Text(text)
                        .font(font)
                        .foregroundStyle(activeColor)
                        .frame(width: geometry.size.width, alignment: .leading)
                        .mask(alignment: .leading) {
                            Rectangle()
                                .frame(width: geometry.size.width * progress)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                }
                .allowsHitTesting(false)
            }
    }
}
#endif

/// Timing calculations used by the basic renderer and available to custom
/// renderers that want the same active-line behavior.
public enum LyricsRendererTimeline {
    /// Returns the most recently started line whose interval contains `time`.
    /// Choosing the latest line gives predictable behavior for overlapping
    /// duet vocals while preserving the original line array.
    public static func activeLine(in lines: [LyricLine], at time: TimeInterval) -> LyricLine? {
        lines.last { time >= $0.start && time < $0.end }
    }

    /// Returns the elapsed fraction of a line, clamped to `0...1`.
    /// This works for line timing as well as word/syllable timing and is the
    /// intentionally simple fill rule used by ``SyncedLyricsRenderer``.
    public static func progress(for line: LyricLine, at time: TimeInterval) -> Double {
        guard line.end > line.start else { return time >= line.start ? 1 : 0 }
        return min(max((time - line.start) / (line.end - line.start), 0), 1)
    }

    /// The line's background/harmony vocals as a single display string, or
    /// `nil` when there are none. Deliberately simple: it joins the backing
    /// words rather than timing them, so a renderer can show them as one
    /// dimmed sub-line with no per-word work.
    public static func backgroundVocalText(for line: LyricLine) -> String? {
        guard let words = line.backgroundWords, !words.isEmpty else { return nil }
        let joined = words
            .map { $0.text.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return joined.isEmpty ? nil : joined
    }
}
