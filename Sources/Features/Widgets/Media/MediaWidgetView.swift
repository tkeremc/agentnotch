import AppKit
import SwiftUI

/// Presentation stays independent of how the system's active media session is discovered.
struct MediaWidgetView: View {
    @ObservedObject var settings: NotchSettings
    let hasMedia: Bool
    var isUnavailable: Bool = false
    var onReconnect: () -> Void = {}
    var title: String = ""
    var subtitle: String = ""
    var source: String = ""
    var artwork: NSImage?
    var isPlaying: Bool = false
    var elapsedTime: TimeInterval = 0
    var duration: TimeInterval = 0
    var canControl: Bool = false
    var canPrevious: Bool = true
    var canNext: Bool = true
    let onPrevious: () -> Void
    let onPlayPause: () -> Void
    let onNext: () -> Void

    var body: some View {
        GeometryReader { geometry in
            Group {
                if hasMedia {
                    if geometry.size.width < 280 {
                        compactPlayer
                    } else {
                        player
                    }
                } else if geometry.size.width < 240 {
                    compactEmptyState
                } else {
                    emptyState
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .foregroundStyle(settings.foregroundColor)
        .background {
            artworkBackdrop
                .padding(-16)
        }
    }

    private var player: some View {
        VStack(spacing: 13) {
            HStack(alignment: .center, spacing: 17) {
                MediaArtworkView(artwork: artwork, size: 100, tint: settings.foregroundColor)
                    .shadow(color: .black.opacity(0.24), radius: 9, y: 5)
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 5) {
                        Image(systemName: isPlaying ? "waveform" : "pause.fill")
                            .font(.system(size: 8, weight: .semibold))
                        Text(settings.localization.text(isPlaying ? .mediaNowPlaying : .mediaPaused))
                            .font(.system(size: 9, weight: .semibold))
                            .tracking(0.7)
                        Spacer(minLength: 0)
                        if !source.isEmpty {
                            Text(source)
                                .font(.system(size: 9, weight: .medium))
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .frame(maxWidth: 88, alignment: .trailing)
                        }
                    }
                    .foregroundStyle(settings.foregroundColor.opacity(0.5))
                    .padding(.bottom, 9)

                    Text(displayTitle)
                        .font(.system(size: 15, weight: .semibold))
                        .tracking(-0.25)
                        .lineLimit(1)
                        .help(title)
                    Text(subtitle.isEmpty ? source : subtitle)
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(settings.foregroundColor.opacity(0.54))
                        .lineLimit(1)
                        .padding(.top, 3)

                    transportControls(spacing: 17)
                    .padding(.top, 10)
                    .frame(maxWidth: .infinity)
                }
            }
            playbackProgress
        }
    }

    private var compactPlayer: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                MediaArtworkView(artwork: artwork, size: 46, cornerRadius: 9,
                                 tint: settings.foregroundColor)
                VStack(alignment: .leading, spacing: 4) {
                    Text(displayTitle)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .help(title)
                    Text(subtitle.isEmpty ? source : subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(settings.foregroundColor.opacity(0.54))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            transportControls(spacing: 12)
            playbackProgress
        }
    }

    private func transportControls(spacing: CGFloat) -> some View {
        HStack(spacing: spacing) {
            transportButton(symbol: "backward.end.fill", key: .mediaPrevious,
                            enabled: canControl && canPrevious, action: onPrevious)
            Button(action: onPlayPause) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .offset(x: isPlaying ? 0 : 1)
                    .frame(width: 36, height: 36)
                    .foregroundStyle(settings.backgroundColor)
                    .background(settings.foregroundColor, in: Circle())
            }
            .buttonStyle(MediaTransportButtonStyle())
            .disabled(!canControl)
            .opacity(canControl ? 1 : 0.4)
            .help(settings.localization.text(isPlaying ? .mediaPause : .mediaPlay))
            .accessibilityLabel(settings.localization.text(isPlaying ? .mediaPause : .mediaPlay))
            transportButton(symbol: "forward.end.fill", key: .mediaNext,
                            enabled: canControl && canNext, action: onNext)
        }
    }

    private var playbackProgress: some View {
        VStack(spacing: 6) {
            GeometryReader { geometry in
                Capsule().fill(settings.foregroundColor.opacity(0.12))
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(settings.foregroundColor.opacity(0.75))
                            .frame(width: geometry.size.width * progress)
                    }
            }
            .frame(height: 3)
            HStack {
                Text(Self.timeLabel(elapsedTime))
                Spacer(minLength: 0)
                Text(duration > 0 ? "−" + Self.timeLabel(max(0, duration - elapsedTime)) : "–:––")
            }
            .font(.system(size: 9, weight: .medium, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(settings.foregroundColor.opacity(0.4))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(settings.localization.text(.mediaPlaybackProgress,
                                                      Self.timeLabel(elapsedTime), Self.timeLabel(duration)))
    }

    private var emptyState: some View {
        HStack(spacing: 18) {
            MediaArtworkView(artwork: nil, size: 88, cornerRadius: 14, tint: settings.foregroundColor)
            VStack(alignment: .leading, spacing: 7) {
                Text(settings.localization.text(isUnavailable ? .mediaUnavailable : .mediaEmptyTitle))
                    .font(.system(size: 14, weight: .semibold))
                emptyDescription
                    .font(.system(size: 11))
            }
            Spacer(minLength: 0)
        }
    }

    private var compactEmptyState: some View {
        VStack(spacing: 9) {
            Image(systemName: "music.note")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(settings.foregroundColor.opacity(0.3))
                .accessibilityHidden(true)
            Text(settings.localization.text(isUnavailable ? .mediaUnavailable : .mediaEmptyTitle))
                .font(.system(size: 12, weight: .semibold))
            emptyDescription
                .font(.system(size: 10))
        }
        .multilineTextAlignment(.center)
    }

    @ViewBuilder
    private var emptyDescription: some View {
        if isUnavailable {
            Button(settings.localization.text(.mediaRetry), action: onReconnect)
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(settings.foregroundColor.opacity(0.1), in: Capsule())
        } else {
            Text(settings.localization.text(.mediaEmptyDescription))
                .foregroundStyle(settings.foregroundColor.opacity(0.5))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var artworkBackdrop: some View {
        if hasMedia, let artwork {
            GeometryReader { geometry in
                Image(nsImage: artwork)
                    .resizable()
                    .scaledToFill()
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .blur(radius: 32, opaque: true)
                    .opacity(0.16)
                    .overlay {
                        LinearGradient(colors: [.clear, settings.backgroundColor.opacity(0.5)],
                                       startPoint: .leading, endPoint: .trailing)
                    }
            }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private var progress: Double {
        guard duration.isFinite, elapsedTime.isFinite, duration > 0 else { return 0 }
        return min(1, max(0, elapsedTime / duration))
    }

    private var displayTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? settings.localization.text(.mediaUnknownTitle) : title
    }

    private func transportButton(symbol: String, key: L10nKey, enabled: Bool,
                                 action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 30, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(MediaTransportButtonStyle())
        .disabled(!enabled)
        .opacity(enabled ? 0.86 : 0.22)
        .help(settings.localization.text(key))
        .accessibilityLabel(settings.localization.text(key))
    }

    private static func timeLabel(_ interval: TimeInterval) -> String {
        guard interval.isFinite, interval >= 0 else { return "0:00" }
        let seconds = Int(min(interval, Double(Int.max / 2)))
        if seconds >= 3_600 {
            return String(format: "%d:%02d:%02d", seconds / 3_600, (seconds % 3_600) / 60, seconds % 60)
        }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

private struct MediaTransportButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.65 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.93 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
