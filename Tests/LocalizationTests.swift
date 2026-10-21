import Combine
import Foundation
@testable import AgentNotch

@MainActor
enum LocalizationTests {
    static let cases: [(String, @MainActor () throws -> Void)] = [
        ("language negotiation follows ordered supported preferences", negotiation),
        ("manual language choice persists and leaves system preferences alone", persistence),
        ("invalid language storage falls back to system", invalidStorage),
        ("system refresh respects explicit language and reset", systemRefresh),
        ("system locale notification refreshes automatic and preserves manual choice", localeNotification),
        ("missing Turkish keys and resources fall back to English", englishFallback),
        ("every typed localization key has compiled EN and TR translations", catalogCoverage),
        ("localized substitutions preserve literal user payloads", substitutions),
        ("compiled catalog resolves English and Turkish count plurals", plurals),
        ("retained shelf errors change language without losing cause", retainedError),
        ("English clock preserves 24-hour time across midnight", englishClock)
    ]

    private struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(description: message) }
    }

    private static func resources() throws -> Bundle {
        guard let path = ProcessInfo.processInfo.environment["AGENTNOTCH_TEST_LOCALIZATION_BUNDLE"],
              let bundle = Bundle(path: path) else {
            throw Failure(description: "Run Tests/run.sh to supply the compiled localization fixture bundle")
        }
        return bundle
    }

    private static func localization(_ language: AppLanguage) throws -> AppLocalization {
        AppLocalization(language: language, resources: try resources())
    }

    private static func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suite = "AgentNotch.LocalizationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    private static func negotiation() throws {
        let checks: [([String], AppLanguage)] = [
            (["tr-TR"], .turkish), (["tr-CY"], .turkish), (["tr_TR"], .turkish),
            (["en-GB"], .english), (["en-US"], .english), (["en_AU"], .english),
            (["de-DE", "tr-TR", "en-US"], .turkish),
            (["ja-JP", "en-GB", "tr-TR"], .english),
            (["de-DE", "ja-JP"], .english), ([], .english)
        ]
        for (preferences, language) in checks {
            try expect(LanguagePreference.system.resolved(preferredLanguages: preferences) == language,
                       "Wrong automatic language for \(preferences)")
        }
        try expect(LanguagePreference.english.resolved(preferredLanguages: ["tr-TR"]) == .english,
                   "An explicit English choice overrides Turkish system preferences")
        try expect(LanguagePreference.turkish.resolved(preferredLanguages: ["en-GB"]) == .turkish,
                   "An explicit Turkish choice overrides English system preferences")
    }

    private static func persistence() throws {
        try withDefaults { defaults in
            defaults.set(["ja-JP"], forKey: "AppleLanguages")
            let settings = NotchSettings(defaults: defaults, preferredLanguages: { ["tr-TR"] })
            try expect(settings.language == .system && settings.localization.language == .turkish,
                       "First run follows the system's supported language")
            settings.language = .english
            try expect(defaults.string(forKey: "island.language") == "en", "Manual choice saves immediately")
            let reloaded = NotchSettings(defaults: defaults, preferredLanguages: { ["tr-TR"] })
            try expect(reloaded.language == .english && reloaded.localization.language == .english,
                       "Explicit choice survives app restart")
            reloaded.language = .turkish
            try expect(NotchSettings(defaults: defaults, preferredLanguages: { ["en-US"] }).language == .turkish,
                       "Turkish override also survives restart")
            try expect(defaults.stringArray(forKey: "AppleLanguages") == ["ja-JP"],
                       "App language must not rewrite system language defaults")
        }
    }

    private static func invalidStorage() throws {
        for invalid: Any in ["de", "future-language", "", 42, ["tr"], ["language": "en"]] {
            try withDefaults { defaults in
                defaults.set(invalid, forKey: "island.language")
                let settings = NotchSettings(defaults: defaults, preferredLanguages: { ["tr-TR"] })
                try expect(settings.language == .system && settings.localization.language == .turkish,
                           "Malformed or unsupported saved preference must follow system: \(invalid)")
            }
        }
    }

    private static func systemRefresh() throws {
        try withDefaults { defaults in
            var preferences = ["en-US"]
            let settings = NotchSettings(defaults: defaults, preferredLanguages: { preferences })
            preferences = ["tr-TR"]
            settings.refreshSystemLanguage()
            try expect(settings.language == .system && settings.localization.language == .turkish,
                       "Automatic mode refreshes when system language changes")
            settings.language = .english
            settings.refreshSystemLanguage()
            try expect(settings.language == .english && settings.localization.language == .english,
                       "System refresh must preserve explicit English override")
            settings.language = .turkish
            preferences = ["en-GB"]
            settings.refreshSystemLanguage()
            try expect(settings.language == .turkish && settings.localization.language == .turkish,
                       "System refresh must preserve explicit Turkish override")
            settings.reset()
            try expect(settings.language == .system && settings.localization.language == .english,
                       "Reset restores automatic selection using current system preferences")
            try expect(defaults.string(forKey: "island.language") == "system", "Reset persists automatic mode")
        }
    }

    private static func localeNotification() throws {
        try withDefaults { defaults in
            var preferences = ["en-US"]
            let settings = NotchSettings(defaults: defaults, preferredLanguages: { preferences })
            var deliveries = 0
            let observation = settings.$localization.dropFirst().sink { _ in deliveries += 1 }
            defer { observation.cancel() }

            @MainActor func postAndWait() throws {
                let previousDeliveries = deliveries
                NotificationCenter.default.post(name: NSLocale.currentLocaleDidChangeNotification, object: nil)
                let deadline = Date().addingTimeInterval(0.5)
                while deliveries == previousDeliveries && Date() < deadline {
                    RunLoop.main.run(until: Date().addingTimeInterval(0.005))
                }
                try expect(deliveries > previousDeliveries,
                           "Locale notification must reach the production observer through the main run loop")
            }

            preferences = ["tr-TR"]
            try postAndWait()
            try expect(settings.language == .system && settings.localization.language == .turkish,
                       "Real notification refreshes automatic mode from changed system preferences")
            settings.language = .english
            try postAndWait()
            try expect(settings.language == .english && settings.localization.language == .english,
                       "Real notification must preserve explicit English choice")
            settings.language = .turkish
            preferences = ["en-GB"]
            try postAndWait()
            try expect(settings.language == .turkish && settings.localization.language == .turkish,
                       "Real notification must preserve explicit Turkish choice")
        }
    }

    private static func englishFallback() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LocalizationFallback-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for includesTurkish in [true, false] {
            let url = root.appendingPathComponent("Fixture-\(UUID()).bundle")
            let english = url.appendingPathComponent("en.lproj")
            try FileManager.default.createDirectory(at: english, withIntermediateDirectories: true)
            let info: [String: String] = [
                "CFBundleIdentifier": "com.agentnotch.fallback-tests.\(UUID().uuidString)",
                "CFBundleName": "FallbackFixture",
                "CFBundlePackageType": "BNDL",
                "CFBundleDevelopmentRegion": "en"
            ]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                .write(to: url.appendingPathComponent("Info.plist"))
            try #"""
                "settings.title" = "English fallback title";
                "settings.language" = "English language label";
                "widget.remove" = "Remove %@ widget";
                """#.write(to: english.appendingPathComponent("Localizable.strings"), atomically: true, encoding: .utf8)
            if includesTurkish {
                let turkish = url.appendingPathComponent("tr.lproj")
                try FileManager.default.createDirectory(at: turkish, withIntermediateDirectories: true)
                try #"""
                    "settings.language" = "Türkçe fixture";
                    """#.write(to: turkish.appendingPathComponent("Localizable.strings"), atomically: true, encoding: .utf8)
            }
            guard let bundle = Bundle(url: url) else { throw Failure(description: "Cannot load fallback fixture") }
            let localizer = AppLocalization(language: .turkish, resources: bundle)
            try expect(localizer.text(.settingsTitle) == "English fallback title",
                       "Missing Turkish key or lproj must resolve the English source")
            try expect(localizer.text(.widgetRemove, "Saat") == "Remove Saat widget",
                       "Fallback strings must still substitute arguments")
            let label = includesTurkish ? "Türkçe fixture" : "English language label"
            try expect(localizer.text(.settingsLanguage) == label,
                       "Available Turkish translation wins; missing Turkish bundle uses English")
        }
    }

    private static func catalogCoverage() throws {
        guard let path = ProcessInfo.processInfo.environment["AGENTNOTCH_TEST_LOCALIZATION_CATALOG"],
              let catalog = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any],
              let strings = catalog["strings"] as? [String: [String: Any]] else {
            throw Failure(description: "Missing String Catalog fixture")
        }
        try expect(catalog["sourceLanguage"] as? String == "en", "English must remain the source language")
        // Xcode may extract literal branding such as "agentnotch" alongside
        // semantic keys. Keep those existing catalog entries intact.
        let semanticKeys = Set(strings.keys.filter { $0.contains(".") })
        try expect(semanticKeys == Set(L10nKey.allCases.map(\.rawValue)),
                   "Catalog and typed keys must stay complete and in sync")
        for language in AppLanguage.allCases {
            let localizer = try localization(language)
            for key in L10nKey.allCases {
                let entry = strings[key.rawValue]!
                try expect(!(entry["comment"] as? String ?? "").isEmpty, "Missing translator context: \(key)")
                guard let translations = entry["localizations"] as? [String: [String: Any]],
                      let translation = translations[language.rawValue] else {
                    throw Failure(description: "Missing \(language) translation for \(key)")
                }
                if key == .shelfItemCount {
                    try expect(translation["variations"] != nil, "Count uses native plural rules")
                    continue
                }
                guard let unit = translation["stringUnit"] as? [String: String], let expected = unit["value"] else {
                    throw Failure(description: "Missing translation value for \(key)")
                }
                try expect(unit["state"] == "translated", "Unfinished translation for \(key)")
                try expect(localizer.text(key) == expected,
                           "Compiled \(language) resource differs or falls back for \(key)")
                try expect(localizer.text(key) != key.rawValue, "Semantic key leaked into UI for \(key)")
            }
        }
    }

    private static func substitutions() throws {
        let payload = "100% %@ %lld Türkçe 🗂.txt"
        let dynamicKeys: [L10nKey] = [
            .paletteApplyHelp, .widgetRemove, .widgetAlreadyAdded, .widgetAddNamed,
            .clockTimeAccessibility, .fileShelfDragItem, .fileShelfRemoveItem,
            .fileShelfCannotAccess, .fileShelfCannotAdd, .fileShelfCannotRefreshAccess
        ]
        for language in AppLanguage.allCases {
            let localizer = try localization(language)
            for key in dynamicKeys {
                try expect(localizer.text(key, payload).contains(payload),
                           "Format characters or Unicode in user data were damaged for \(key)")
            }
            try expect(localizer.text(.clockDateAccessibility, "date", "weekday") == "date, weekday",
                       "Positional accessibility arguments keep the intended order")
        }
    }

    private static func plurals() throws {
        let en = try localization(.english)
        let tr = try localization(.turkish)
        for count: Int64 in [0, 1, 2, 4_294_967_297] {
            let englishNumber = count.formatted(.number.locale(en.locale))
            let turkishNumber = count.formatted(.number.locale(tr.locale))
            let englishNoun = count == 1 ? "item" : "items"
            try expect(en.text(.shelfItemCount, count) == "\(englishNumber) \(englishNoun)",
                       "English plural or 64-bit count incorrect at \(count)")
            try expect(tr.text(.shelfItemCount, count) == "\(turkishNumber) öğe",
                       "Turkish count or localized number formatting incorrect at \(count)")
        }
    }

    private static func retainedError() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LocalizationErrors-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FileShelfStore(storageURL: root.appendingPathComponent("shelf.json"))
        let name = "Türkçe 100% %@.txt"
        try expect(!store.add([root.appendingPathComponent(name)]), "Missing file must cause an access error")
        let original = store.errorMessage
        let en = try localization(.english)
        let tr = try localization(.turkish)
        try expect(original?.localized(using: en) == "Cannot access file: \(name)", "English error text")
        try expect(original?.localized(using: tr) == "Dosyaya erişilemiyor: \(name)", "Existing error retranslates")
        try expect(store.errorMessage == original, "Translation must retain the original semantic cause")
        let errors: [FileShelfError] = [.cannotAccess(name), .cannotAdd(name), .cannotRefreshAccess(name),
                                        .someRecordsUnreadable, .cannotRead, .cannotSave]
        for error in errors {
            try expect(error.localized(using: en) != error.localized(using: tr),
                       "Every retained error responds to language selection")
        }
    }

    private static func englishClock() throws {
        let instant = ISO8601DateFormatter().date(from: "2026-10-15T21:05:09Z")!
        let locale = Locale(identifier: "en_US")
        let utc = ClockReadout(date: instant, timeZone: TimeZone(secondsFromGMT: 0)!, locale: locale)
        try expect(utc.time == "21:05" && utc.seconds == "09", "English clock keeps padded 24-hour time")
        try expect(utc.weekday == "Thursday" && utc.date.contains("October"), "English date and weekday")
        let midnight = ClockReadout(date: instant, timeZone: TimeZone(identifier: "Europe/Istanbul")!, locale: locale)
        try expect(midnight.time == "00:05" && midnight.weekday == "Friday",
                   "English clock uses zero-based midnight and follows the supplied time zone")
        try expect(midnight.date.contains("16") && midnight.shortDate.contains("October"),
                   "English dates roll over with the clock")
    }
}
