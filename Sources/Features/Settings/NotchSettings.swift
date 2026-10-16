import AppKit
import Combine
import SwiftUI

@MainActor
final class NotchSettings: ObservableObject {
    private let defaults: UserDefaults
    private let preferredLanguages: () -> [String]
    private var localeObserver: AnyCancellable?

    @Published var language: LanguagePreference {
        didSet {
            defaults.set(language.rawValue, forKey: "island.language")
            refreshSystemLanguage()
        }
    }
    @Published private(set) var localization: AppLocalization

    @Published var isEnabled: Bool { didSet { defaults.set(isEnabled, forKey: "island.enabled") } }
    @Published var animationsEnabled: Bool { didSet { defaults.set(animationsEnabled, forKey: "island.animations") } }
    @Published var animationSpeed: Double { didSet { defaults.set(animationSpeed, forKey: "island.speed") } }
    @Published var openDelay: Double { didSet { defaults.set(openDelay, forKey: "island.openDelay") } }
    @Published var closeDelay: Double { didSet { defaults.set(closeDelay, forKey: "island.closeDelay") } }
    @Published var backgroundHex: String { didSet { defaults.set(backgroundHex, forKey: "island.background") } }
    @Published var foregroundHex: String { didSet { defaults.set(foregroundHex, forKey: "island.foreground") } }
    @Published var showsSeconds: Bool { didSet { defaults.set(showsSeconds, forKey: "island.seconds") } }
    @Published private(set) var widgets: [WidgetKind] {
        didSet { defaults.set(widgets.map(\.rawValue), forKey: "island.widgets") }
    }

    init(defaults: UserDefaults = .standard,
         preferredLanguages: @escaping () -> [String] = { Locale.preferredLanguages }) {
        self.defaults = defaults
        self.preferredLanguages = preferredLanguages
        let savedLanguage = defaults.string(forKey: "island.language")
            .flatMap(LanguagePreference.init(rawValue:)) ?? .system
        language = savedLanguage
        localization = AppLocalization(language: savedLanguage.resolved(preferredLanguages: preferredLanguages()))
        defaults.register(defaults: [
            "island.enabled": true, "island.animations": true, "island.speed": 1.0,
            "island.openDelay": 60.0, "island.closeDelay": 160.0,
            "island.background": "000000", "island.foreground": "FFFFFF",
            "island.seconds": true
        ])
        isEnabled = defaults.bool(forKey: "island.enabled")
        animationsEnabled = defaults.bool(forKey: "island.animations")
        animationSpeed = Self.clamped(defaults.double(forKey: "island.speed"), to: 0.25...3, fallback: 1)
        openDelay = Self.clamped(defaults.double(forKey: "island.openDelay"), to: 0...1000, fallback: 60)
        closeDelay = Self.clamped(defaults.double(forKey: "island.closeDelay"), to: 0...1000, fallback: 160)
        backgroundHex = defaults.string(forKey: "island.background") ?? "000000"
        foregroundHex = defaults.string(forKey: "island.foreground") ?? "FFFFFF"
        showsSeconds = defaults.bool(forKey: "island.seconds")
        if let saved = defaults.stringArray(forKey: "island.widgets") {
            var seen = Set<WidgetKind>()
            widgets = saved.compactMap(WidgetKind.init(rawValue:)).filter { seen.insert($0).inserted }
        } else {
            widgets = [.clock]
        }
        localeObserver = NotificationCenter.default.publisher(for: NSLocale.currentLocaleDidChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshSystemLanguage() }
    }

    func refreshSystemLanguage() {
        localization = AppLocalization(language: language.resolved(preferredLanguages: preferredLanguages()))
    }

    func addWidget(_ widget: WidgetKind) {
        guard !widgets.contains(widget) else { return }
        widgets.append(widget)
    }

    func removeWidget(_ widget: WidgetKind) {
        widgets.removeAll { $0 == widget }
    }

    func moveWidget(_ widget: WidgetKind, to destination: Int) {
        guard let source = widgets.firstIndex(of: widget) else { return }
        var reordered = widgets
        reordered.remove(at: source)
        reordered.insert(widget, at: min(max(0, destination), reordered.count))
        if reordered != widgets { widgets = reordered }
    }

    var backgroundColor: Color {
        get { Self.color(hex: backgroundHex, fallback: .black) }
        set { backgroundHex = Self.hex(color: newValue) }
    }

    var foregroundColor: Color {
        get { Self.color(hex: foregroundHex, fallback: .white) }
        set { foregroundHex = Self.hex(color: newValue) }
    }

    func reset() {
        language = .system
        isEnabled = true
        animationsEnabled = true
        animationSpeed = 1
        openDelay = 60
        closeDelay = 160
        backgroundHex = "000000"
        foregroundHex = "FFFFFF"
        showsSeconds = true
        widgets = [.clock]
    }

    private static func clamped(_ value: Double, to range: ClosedRange<Double>, fallback: Double) -> Double {
        value.isFinite ? min(max(value, range.lowerBound), range.upperBound) : fallback
    }

    private static func color(hex: String, fallback: Color) -> Color {
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return fallback }
        return Color(.sRGB, red: Double((value >> 16) & 255) / 255,
                     green: Double((value >> 8) & 255) / 255,
                     blue: Double(value & 255) / 255, opacity: 1)
    }

    private static func hex(color: Color) -> String {
        guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return "000000" }
        return String(format: "%02X%02X%02X",
                      Int((min(max(rgb.redComponent, 0), 1) * 255).rounded()),
                      Int((min(max(rgb.greenComponent, 0), 1) * 255).rounded()),
                      Int((min(max(rgb.blueComponent, 0), 1) * 255).rounded()))
    }
}
