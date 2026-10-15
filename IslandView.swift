import SwiftUI

struct IslandView: View {
    @ObservedObject var state: IslandState
    @ObservedObject var settings: NotchSettings

    var body: some View {
        ZStack(alignment: .top) {
            ZStack(alignment: .top) {
                expandedContent
                    // Content always has its final width. The surface reveals
                    // it without reflowing text at every intermediate size.
                    .frame(width: state.expandedWidth)
                    .mask(alignment: .top) {
                        GeometryReader { geometry in
                            Rectangle()
                                .frame(height: geometry.size.height * state.contentProgress)
                        }
                    }
                    .padding(.top, state.topBand)
                    .opacity(Double(state.contentProgress))
                    .allowsHitTesting(state.expanded && state.contentProgress > 0.9)
                    .accessibilityHidden(!state.expanded || state.contentProgress < 0.9)

                settingsButton
                    .padding(.trailing, 20)
                    .frame(width: state.expandedWidth, height: max(28, state.topBand), alignment: .trailing)
                    .opacity(Double(state.contentProgress))
                    .allowsHitTesting(state.expanded && state.contentProgress > 0.9)
                    .accessibilityHidden(!state.expanded || state.contentProgress < 0.9)
            }
            .frame(width: state.surfaceWidth, height: state.surfaceHeight, alignment: .top)
            .background(settings.backgroundColor)
            .clipShape(UnevenRoundedRectangle(
                topLeadingRadius: 8,
                bottomLeadingRadius: 16 + 12 * state.progress,
                bottomTrailingRadius: 16 + 12 * state.progress,
                topTrailingRadius: 8
            ))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private var expandedContent: some View {
        // Removing the timeline when closed avoids a permanent one-second wakeup.
        if state.expanded || state.contentProgress > 0 {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                ClockContent(state: state, settings: settings, date: context.date)
            }
        } else {
            Color.clear.frame(height: state.contentHeight)
        }
    }

    private var settingsButton: some View {
        Button {
            state.openSettings?()
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(settings.foregroundColor.opacity(0.6))
                .frame(width: 28, height: 28)
                .background(settings.foregroundColor.opacity(0.08), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("NotchLab ayarları")
        .accessibilityLabel("NotchLab ayarlarını aç")
    }
}

struct ClockReadout {
    let time: String
    let seconds: String
    let weekday: String
    let date: String

    init(date: Date, timeZone: TimeZone = .autoupdatingCurrent) {
        let locale = Locale(identifier: "tr_TR")
        let style = Date.FormatStyle(locale: locale, timeZone: timeZone)
        time = date.formatted(style.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
        seconds = date.formatted(style.second(.twoDigits))
        weekday = date.formatted(style.weekday(.wide))
        self.date = date.formatted(style.day().month(.wide).year())
    }
}

private struct ClockContent: View {
    @ObservedObject var state: IslandState
    @ObservedObject var settings: NotchSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let date: Date

    var body: some View {
        let readout = ClockReadout(date: date)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(readout.time)
                    .font(.system(size: 52, weight: .light, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText(countsDown: false))
                    .animation(digitAnimation, value: readout.time)
                    .accessibilityLabel("Saat \(readout.time)")
                if settings.showsSeconds {
                    Text(readout.seconds)
                        .font(.system(size: 20, weight: .regular, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(settings.foregroundColor.opacity(0.35))
                        .contentTransition(.numericText(countsDown: false))
                        .animation(digitAnimation, value: readout.seconds)
                        .accessibilityHidden(true)
                }
                Spacer(minLength: 0)
            }
            HStack {
                Text("\(readout.date) · \(readout.weekday)")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(settings.foregroundColor.opacity(0.65))
                    .contentTransition(.opacity)
                    .animation(textAnimation, value: readout.date)
                Spacer()
            }
        }
        .lineLimit(1)
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 18)
        .frame(height: state.contentHeight, alignment: .center)
        .foregroundStyle(settings.foregroundColor)
    }

    private var digitAnimation: Animation? {
        reduceMotion || !settings.animationsEnabled || !state.expanded
            ? nil : .smooth(duration: 0.24 / settings.animationSpeed)
    }

    private var textAnimation: Animation? {
        reduceMotion || !settings.animationsEnabled || !state.expanded
            ? nil : .easeInOut(duration: 0.2 / settings.animationSpeed)
    }

}
