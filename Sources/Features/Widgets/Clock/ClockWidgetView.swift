import SwiftUI

// Clock content knows nothing about panel geometry or hover ownership.
struct ClockWidgetView: View {
    @ObservedObject var settings: NotchSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let date: Date
    let animates: Bool

    var body: some View {
        let readout = ClockReadout(date: date)
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(readout.time)
                    .font(.system(size: 44, weight: .light, design: .rounded))
                    .tracking(-1.5)
                    .monospacedDigit()
                    .contentTransition(.numericText(countsDown: false))
                    .animation(digitAnimation, value: readout.time)
                    .accessibilityLabel("Saat \(readout.time)")
                if settings.showsSeconds {
                    Text(readout.seconds)
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(settings.foregroundColor.opacity(0.4))
                        .contentTransition(.numericText(countsDown: false))
                        .animation(digitAnimation, value: readout.seconds)
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity)
            Spacer(minLength: 12)
            Rectangle()
                .fill(settings.foregroundColor.opacity(0.08))
                .frame(height: 1)
                .accessibilityHidden(true)
                .padding(.bottom, 10)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(readout.weekday)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(settings.foregroundColor.opacity(0.8))
                Spacer(minLength: 0)
                Text(readout.shortDate)
                    .font(.system(size: 11))
                    .foregroundStyle(settings.foregroundColor.opacity(0.5))
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(readout.date), \(readout.weekday)")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .foregroundStyle(settings.foregroundColor)
    }

    private var digitAnimation: Animation? {
        reduceMotion || !settings.animationsEnabled || !animates
            ? nil : .smooth(duration: 0.24 / settings.animationSpeed)
    }
}
