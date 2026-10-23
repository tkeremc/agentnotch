import Foundation

struct ClockReadout {
    let time: String
    let seconds: String
    let weekday: String
    let date: String
    let shortDate: String

    init(date: Date, timeZone: TimeZone = .autoupdatingCurrent, locale: Locale) {
        let style = Date.FormatStyle(locale: locale, calendar: Calendar(identifier: .gregorian), timeZone: timeZone)
        time = date.formatted(.verbatim(
            "\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits)",
            locale: locale, timeZone: timeZone, calendar: Calendar(identifier: .gregorian)))
        seconds = date.formatted(style.second(.twoDigits))
        weekday = date.formatted(style.weekday(.wide))
        self.date = date.formatted(style.day().month(.wide).year())
        shortDate = date.formatted(style.day().month(.wide))
    }
}

struct ClockMonthReadout {
    struct Day {
        let date: Date
        let number: Int
        let isToday: Bool
        let accessibilityLabel: String
    }

    let title: String
    let weekdays: [String]
    // Always reserve six weeks, keeping the card steady at month boundaries.
    let days: [Day?]

    init(date: Date, timeZone: TimeZone = .autoupdatingCurrent, locale: Locale) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        calendar.timeZone = timeZone
        let style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: timeZone)
        title = date.formatted(style.month(.wide).year())
        let symbols = calendar.shortStandaloneWeekdaySymbols
        weekdays = (0..<7).map { symbols[(calendar.firstWeekday - 1 + $0) % 7] }

        guard let month = calendar.dateInterval(of: .month, for: date),
              let range = calendar.range(of: .day, in: .month, for: date) else {
            days = Array(repeating: nil, count: 42)
            return
        }
        let leadingDays = (calendar.component(.weekday, from: month.start) - calendar.firstWeekday + 7) % 7
        let today = calendar.component(.day, from: date)
        days = (0..<42).map { slot in
            let number = slot - leadingDays + 1
            guard range.contains(number),
                  let day = calendar.date(byAdding: .day, value: number - 1, to: month.start) else { return nil }
            return Day(date: day, number: number, isToday: number == today,
                       accessibilityLabel: day.formatted(style.weekday(.wide).day().month(.wide).year()))
        }
    }
}
