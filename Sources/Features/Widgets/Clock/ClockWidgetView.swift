import SwiftUI

// Clock content knows nothing about panel geometry or hover ownership.
struct ClockWidgetView: View {
    @ObservedObject var settings: NotchSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let date: Date
    let animates: Bool

    var body: some View {
        let readout = ClockReadout(date: date, locale: settings.localization.locale)
        let month = ClockMonthReadout(date: date, locale: settings.localization.locale)
        GeometryReader { geometry in
            let isWide = geometry.size.width >= 280
            Group {
                if isWide {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 10) {
                            time(readout, size: 51)
                            dateLabel(readout, compact: false)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                        Rectangle()
                            .fill(settings.foregroundColor.opacity(0.08))
                            .frame(width: 1)
                            .accessibilityHidden(true)
                        monthCalendar(month, compact: false)
                            .frame(width: min(198, geometry.size.width * 0.5))
                    }
                } else {
                    VStack(spacing: 8) {
                        HStack(alignment: .center, spacing: 6) {
                            time(readout, size: 30)
                            Spacer(minLength: 0)
                            dateLabel(readout, compact: true)
                        }
                        monthCalendar(month, compact: true)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .foregroundStyle(settings.foregroundColor)
        }
    }

    private func time(_ readout: ClockReadout, size: CGFloat) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(readout.time)
                .font(.system(size: size, weight: .light, design: .rounded))
                .tracking(-1.5)
                .monospacedDigit()
                .contentTransition(.numericText(countsDown: false))
                .animation(digitAnimation, value: readout.time)
                .accessibilityLabel(settings.localization.text(.clockTimeAccessibility, readout.time))
            if settings.showsSeconds {
                Text(readout.seconds)
                    .font(.system(size: size > 40 ? 14 : 10, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(settings.foregroundColor.opacity(0.4))
                    .contentTransition(.numericText(countsDown: false))
                    .animation(digitAnimation, value: readout.seconds)
                    .accessibilityHidden(true)
            }
        }
    }

    private func dateLabel(_ readout: ClockReadout, compact: Bool) -> some View {
        VStack(alignment: compact ? .trailing : .leading, spacing: 3) {
            Text(readout.weekday)
                .font(.system(size: compact ? 10 : 13, weight: .medium))
                .foregroundStyle(settings.foregroundColor.opacity(0.8))
            Text(readout.shortDate)
                .font(.system(size: compact ? 9 : 12))
                .foregroundStyle(settings.foregroundColor.opacity(0.5))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(settings.localization.text(.clockDateAccessibility, readout.date, readout.weekday))
    }

    private func monthCalendar(_ month: ClockMonthReadout, compact: Bool) -> some View {
        let rowHeight: CGFloat = compact ? 12 : 16
        let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 7)
        return VStack(spacing: compact ? 3 : 6) {
            Text(month.title)
                .font(.system(size: compact ? 10 : 12, weight: .medium))
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
            LazyVGrid(columns: columns, spacing: compact ? 1 : 2) {
                ForEach(month.weekdays.indices, id: \.self) { index in
                    Text(month.weekdays[index])
                        .font(.system(size: compact ? 8 : 9, weight: .medium))
                        .foregroundStyle(settings.foregroundColor.opacity(0.4))
                        .frame(maxWidth: .infinity)
                        .frame(height: rowHeight)
                        .accessibilityHidden(true)
                }
                ForEach(month.days.indices, id: \.self) { index in
                    if let day = month.days[index] {
                        Text(day.number.formatted(.number.locale(settings.localization.locale)))
                            .font(.system(size: compact ? 9 : 10, weight: day.isToday ? .bold : .regular))
                            .monospacedDigit()
                            .foregroundStyle(settings.foregroundColor.opacity(day.isToday ? 1 : 0.7))
                            .frame(width: rowHeight, height: rowHeight)
                            .background {
                                if day.isToday {
                                    Circle().fill(settings.foregroundColor.opacity(0.2))
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .accessibilityLabel(day.accessibilityLabel)
                            .accessibilityAddTraits(day.isToday ? .isSelected : [])
                    } else {
                        Color.clear.frame(height: rowHeight).accessibilityHidden(true)
                    }
                }
            }
        }
    }

    private var digitAnimation: Animation? {
        reduceMotion || !settings.animationsEnabled || !animates
            ? nil : .smooth(duration: 0.24 / settings.animationSpeed)
    }
}
