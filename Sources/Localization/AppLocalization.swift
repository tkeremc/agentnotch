import Foundation

enum AppLanguage: String, CaseIterable {
    case english = "en"
    case turkish = "tr"
}

enum LanguagePreference: String, CaseIterable, Identifiable {
    case system
    case english = "en"
    case turkish = "tr"

    var id: String { rawValue }

    func resolved(preferredLanguages: [String]) -> AppLanguage {
        if let explicit = AppLanguage(rawValue: rawValue) { return explicit }
        for identifier in preferredLanguages {
            let code = Locale(identifier: identifier).language.languageCode?.identifier
            if let code, let supported = AppLanguage(rawValue: code) { return supported }
        }
        return .english
    }

    func title(using localization: AppLocalization) -> String {
        switch self {
        case .system: return localization.text(.languageSystem)
        case .english: return localization.text(.languageEnglish)
        case .turkish: return localization.text(.languageTurkish)
        }
    }
}

/// Explicit bundles allow all AppKit and SwiftUI surfaces to switch immediately.
/// AppleLanguages and Bundle.main's process-wide language selection stay untouched.
struct AppLocalization {
    let language: AppLanguage
    let locale: Locale
    private let bundle: Bundle
    private let fallbackBundle: Bundle

    init(language: AppLanguage, resources: Bundle = .main) {
        self.language = language
        let region = Locale.autoupdatingCurrent.region?.identifier
            ?? (language == .turkish ? "TR" : "US")
        locale = Locale(identifier: "\(language.rawValue)_\(region)")
        fallbackBundle = Self.bundle(for: .english, in: resources) ?? resources
        bundle = Self.bundle(for: language, in: resources) ?? fallbackBundle
    }

    func text(_ key: L10nKey, _ arguments: CVarArg...) -> String {
        let fallback = fallbackBundle.localizedString(forKey: key.rawValue, value: nil, table: "Localizable")
        let format = bundle.localizedString(forKey: key.rawValue, value: fallback, table: "Localizable")
        // Foundation resolves String Catalog plural rules from the compiled stringsdict.
        return arguments.isEmpty ? format : String(format: format, locale: locale, arguments: arguments)
    }

    private static func bundle(for language: AppLanguage, in resources: Bundle) -> Bundle? {
        resources.url(forResource: language.rawValue, withExtension: "lproj").flatMap(Bundle.init(url:))
    }
}
