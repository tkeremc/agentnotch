import SwiftUI

@MainActor
final class SettingsNavigation: ObservableObject {
    @Published private(set) var codexRequest: UUID?
    @Published private(set) var claudeRequest: UUID?

    func focusCodex() { codexRequest = UUID(); claudeRequest = nil }
    func focusClaude() { claudeRequest = UUID(); codexRequest = nil }
}

struct NotchSettingsView: View {
    @ObservedObject var settings: NotchSettings
    @ObservedObject var codex: CodexStore
    @ObservedObject var claude: ClaudeStore
    @ObservedObject var navigation: SettingsNavigation
    @State private var confirmsDisconnect = false
    @State private var confirmsClaudeDisconnect = false

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

            ScrollViewReader { proxy in
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

                    Section(settings.localization.text(.widgetCodexTitle)) {
                        connectionRow(codex.connection, failure: codex.connectionFailure,
                            isBusy: codex.isChangingConnection,
                            onConnect: { codex.connect(localization: settings.localization) },
                            onDisconnect: { confirmsDisconnect = true })
                    }
                    .id("codex-connection")
                    Section(settings.localization.text(.widgetClaudeTitle)) {
                        connectionRow(claude.connection, failure: claude.connectionFailure,
                            isBusy: claude.isChangingConnection,
                            onConnect: { claude.connect(localization: settings.localization) },
                            onDisconnect: { confirmsClaudeDisconnect = true })
                    }
                    .id("claude-connection")
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
                .onAppear {
                    if navigation.codexRequest != nil { proxy.scrollTo("codex-connection", anchor: .top) }
                    if navigation.claudeRequest != nil { proxy.scrollTo("claude-connection", anchor: .top) }
                }
                .onChange(of: navigation.claudeRequest) { _, request in
                    if request != nil { proxy.scrollTo("claude-connection", anchor: .top) }
                }
                .onChange(of: navigation.codexRequest) { _, request in
                    if request != nil { proxy.scrollTo("codex-connection", anchor: .top) }
                }
            }

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
        .onAppear { codex.refreshConnection(); claude.refreshConnection() }
        .confirmationDialog(settings.localization.text(.codexDisconnectQuestion),
                            isPresented: $confirmsDisconnect) {
            Button(settings.localization.text(.codexDisconnect), role: .destructive) { codex.disconnect() }
            Button(settings.localization.text(.codexCancel), role: .cancel) { }
        } message: {
            Text(settings.localization.text(.codexDisconnectDescription))
        }
        .confirmationDialog(settings.localization.text(.claudeDisconnectQuestion),
                            isPresented: $confirmsClaudeDisconnect) {
            Button(settings.localization.text(.claudeDisconnect), role: .destructive) { claude.disconnect() }
            Button(settings.localization.text(.claudeCancel), role: .cancel) { }
        } message: {
            Text(settings.localization.text(.claudeDisconnectDescription))
        }
    }

    private func connectionRow(_ connection: CodexConnection, failure: L10nKey?, isBusy: Bool,
                               onConnect: @escaping () -> Void,
                               onDisconnect: @escaping () -> Void) -> some View {
        HStack {
            Text(settings.localization.text(failure == nil ? connection.title : .agentConnectionFailed))
                .foregroundStyle(failure != nil || connection == .repairRequired || connection == .unavailable
                    ? Color.orange : Color.secondary)
                .help(settings.localization.text(failure ?? connection.title))
            Spacer()
            if connection == .notInstalled || connection == .repairRequired {
                Button(settings.localization.text(connection == .repairRequired ? .codexRepair : .codexConnect),
                       action: onConnect)
            } else {
                Button(settings.localization.text(.codexDisconnect), role: .destructive, action: onDisconnect)
            }
        }
        .disabled(isBusy)
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
