import Foundation

struct ClockReadout {
    let time: String
    let seconds: String
    let weekday: String
    let date: String
    let shortDate: String

    init(date: Date, timeZone: TimeZone = .autoupdatingCurrent) {
        let locale = Locale(identifier: "tr_TR")
        let style = Date.FormatStyle(locale: locale, timeZone: timeZone)
        time = date.formatted(style.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
        seconds = date.formatted(style.second(.twoDigits))
        weekday = date.formatted(style.weekday(.wide))
        self.date = date.formatted(style.day().month(.wide).year())
        shortDate = date.formatted(style.day().month(.wide))
    }
}
