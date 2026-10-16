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
                    Text("agentnotch").font(.title2.bold())
                    Text(settings.localization.text(.settingsSubtitle))
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(24)

            Form {
                Section {
                    Toggle(settings.localization.text(.settingsEnable), isOn: $settings.isEnabled)
                    Picker(settings.localization.text(.settingsLanguage), selection: $settings.language) {
                        ForEach(LanguagePreference.allCases) { language in
                            Text(language.title(using: settings.localization)).tag(language)
                        }
                    }
                    Text(settings.localization.text(.settingsLanguageDescription))
                        .font(.caption).foregroundStyle(.secondary)
                } header: {
                    Text(settings.localization.text(.settingsGeneral))
                } footer: {
                    Text(settings.localization.text(.settingsDisabledDescription))
                }

                Section(settings.localization.text(.settingsAppearance)) {
                    ColorPicker(settings.localization.text(.settingsBackgroundColor), selection: $settings.backgroundColor, supportsOpacity: false)
                    ColorPicker(settings.localization.text(.settingsForegroundColor), selection: $settings.foregroundColor, supportsOpacity: false)
                    HStack {
                        Text(settings.localization.text(.settingsPalettes))
                        Spacer()
                        palette(settings.localization.text(.paletteBlack), background: "000000", foreground: "FFFFFF")
                        palette(settings.localization.text(.paletteNight), background: "141E36", foreground: "DDE8FF")
                        palette(settings.localization.text(.paletteIce), background: "DDF4FF", foreground: "142838")
                    }
                    Toggle(settings.localization.text(.settingsShowSeconds), isOn: $settings.showsSeconds)
                }

                Section {
                    Toggle(settings.localization.text(.settingsEnableAnimations), isOn: $settings.animationsEnabled)
                    slider(settings.localization.text(.settingsAnimationSpeed), value: $settings.animationSpeed, range: 0.25...3, step: 0.25,
                           readout: settings.animationSpeed.formatted(.number.locale(settings.localization.locale).precision(.significantDigits(1...2))) + "×")
                        .disabled(!settings.animationsEnabled)
                    slider(settings.localization.text(.settingsOpenDelay), value: $settings.openDelay, range: 0...1000, step: 20,
                           readout: "\(Int(settings.openDelay)) ms")
                    slider(settings.localization.text(.settingsCloseDelay), value: $settings.closeDelay, range: 0...1000, step: 20,
                           readout: "\(Int(settings.closeDelay)) ms")
                } header: {
                    Text(settings.localization.text(.settingsMotion))
                } footer: {
                    Text(settings.localization.text(.settingsMotionDescription))
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Text(settings.localization.text(.settingsAutosaved))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(settings.localization.text(.settingsReset)) { settings.reset() }
            }
            .padding(16)
        }
        .frame(width: 540, height: 780)
        .environment(\.locale, settings.localization.locale)
    }

    private func palette(_ title: String, background: String, foreground: String) -> some View {
        Button(title) {
            settings.backgroundHex = background
            settings.foregroundHex = foreground
        }
        .help(settings.localization.text(.paletteApplyHelp, title))
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
