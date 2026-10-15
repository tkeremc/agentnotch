import AppKit
import SwiftUI

@main
struct NotchLabApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra("NotchLab", systemImage: "capsule.tophalf.filled") {
            NotchMenu(settings: delegate.settings, openSettings: delegate.showSettings)
        }
    }
}

private struct NotchMenu: View {
    @ObservedObject var settings: NotchSettings
    let openSettings: () -> Void

    var body: some View {
        Toggle("NotchLab etkin", isOn: $settings.isEnabled)
        Button("Ayarlar…", action: openSettings)
            .keyboardShortcut(",")
        Divider()
        Button("NotchLab’den çık") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let settings = NotchSettings()
    var island: IslandController?
    private var settingsWindow: NSWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        island = IslandController(settings: settings) { [weak self] in self?.showSettings() }
        if settings.isEnabled { island?.show() }
    }

    func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(
                rootView: NotchSettingsView(settings: settings)
            ))
            window.title = "NotchLab Ayarları"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 540, height: 720))
            window.center()
            settingsWindow = NSWindowController(window: window)
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.showWindow(nil)
        settingsWindow?.window?.makeKeyAndOrderFront(nil)
    }
}

@MainActor
final class NotchSettings: ObservableObject {
    private let defaults: UserDefaults

    @Published var isEnabled: Bool { didSet { defaults.set(isEnabled, forKey: "island.enabled") } }
    @Published var animationsEnabled: Bool { didSet { defaults.set(animationsEnabled, forKey: "island.animations") } }
    @Published var animationSpeed: Double { didSet { defaults.set(animationSpeed, forKey: "island.speed") } }
    @Published var openDelay: Double { didSet { defaults.set(openDelay, forKey: "island.openDelay") } }
    @Published var closeDelay: Double { didSet { defaults.set(closeDelay, forKey: "island.closeDelay") } }
    @Published var backgroundHex: String { didSet { defaults.set(backgroundHex, forKey: "island.background") } }
    @Published var foregroundHex: String { didSet { defaults.set(foregroundHex, forKey: "island.foreground") } }
    @Published var showsSeconds: Bool { didSet { defaults.set(showsSeconds, forKey: "island.seconds") } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
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
        isEnabled = true
        animationsEnabled = true
        animationSpeed = 1
        openDelay = 60
        closeDelay = 160
        backgroundHex = "000000"
        foregroundHex = "FFFFFF"
        showsSeconds = true
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

private struct NotchSettingsView: View {
    @ObservedObject var settings: NotchSettings

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "capsule.tophalf.filled")
                    .font(.system(size: 28))
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text("NotchLab").font(.title2.bold())
                    Text("Adanı kendine göre ayarla.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(24)

            Form {
                Section {
                    Toggle("NotchLab’i etkinleştir", isOn: $settings.isEnabled)
                } header: {
                    Text("Genel")
                } footer: {
                    Text("Kapattığında ada gizlenir, animasyonlar ve fare takibi durur. Menü çubuğundan tekrar açabilirsin.")
                }

                Section("Görünüm") {
                    ColorPicker("Arka plan rengi", selection: $settings.backgroundColor, supportsOpacity: false)
                    ColorPicker("Yazı rengi", selection: $settings.foregroundColor, supportsOpacity: false)
                    HStack {
                        Text("Hazır renkler")
                        Spacer()
                        palette("Siyah", background: "000000", foreground: "FFFFFF")
                        palette("Gece", background: "141E36", foreground: "DDE8FF")
                        palette("Buz", background: "DDF4FF", foreground: "142838")
                    }
                    Toggle("Saniyeyi göster", isOn: $settings.showsSeconds)
                }

                Section {
                    Toggle("Animasyonları etkinleştir", isOn: $settings.animationsEnabled)
                    slider("Animasyon hızı", value: $settings.animationSpeed, range: 0.25...3, step: 0.25,
                           readout: String(format: "%.2g×", settings.animationSpeed))
                        .disabled(!settings.animationsEnabled)
                    slider("Açılma gecikmesi", value: $settings.openDelay, range: 0...1000, step: 20,
                           readout: "\(Int(settings.openDelay)) ms")
                    slider("Kapanma gecikmesi", value: $settings.closeDelay, range: 0...1000, step: 20,
                           readout: "\(Int(settings.closeDelay)) ms")
                } header: {
                    Text("Hareket")
                } footer: {
                    Text("Hız arttıkça geçişler kısalır. Animasyonları kapattığında ada anında açılıp kapanır. Sistemin Hareketi Azalt seçeneğine her zaman uyulur.")
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Text("Değişiklikler otomatik kaydedilir.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Varsayılanlara dön") { settings.reset() }
            }
            .padding(16)
        }
        .frame(width: 540, height: 720)
    }

    private func palette(_ title: String, background: String, foreground: String) -> some View {
        Button(title) {
            settings.backgroundHex = background
            settings.foregroundHex = foreground
        }
        .help("\(title) renklerini uygula")
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>,
                        step: Double, readout: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Text(readout).monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: value, in: range, step: step) { Text(title) }
                .accessibilityValue(readout)
        }
        .padding(.vertical, 3)
    }
}
