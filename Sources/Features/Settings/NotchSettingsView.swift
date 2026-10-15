import SwiftUI

struct NotchSettingsView: View {
    @ObservedObject var settings: NotchSettings

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image("NotchMark")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 32, height: 32)
                    .foregroundStyle(.primary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("leagent notch").font(.title2.bold())
                    Text("Adanı kendine göre ayarla.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(24)

            Form {
                Section {
                    Toggle("leagent notch’u etkinleştir", isOn: $settings.isEnabled)
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
