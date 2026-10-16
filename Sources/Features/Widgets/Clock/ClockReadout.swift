import Foundation

struct ClockReadout {
    let time: String
    let seconds: String
    let weekday: String
    let date: String
    let shortDate: String

    init(date: Date, timeZone: TimeZone = .autoupdatingCurrent, locale: Locale) {
        let style = Date.FormatStyle(locale: locale, timeZone: timeZone)
        time = date.formatted(.verbatim(
            "\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits)",
            locale: locale, timeZone: timeZone, calendar: Calendar(identifier: .gregorian)))
        seconds = date.formatted(style.second(.twoDigits))
        weekday = date.formatted(style.weekday(.wide))
        self.date = date.formatted(style.day().month(.wide).year())
        shortDate = date.formatted(style.day().month(.wide))
    }
}
