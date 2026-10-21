// Standalone visual QA harness. Compile with the Claude/Codex/widget/localization
// sources, never with AgentNotchApp.swift. No hooks are installed by this tool.
import AppKit
import SwiftUI

@main
@MainActor
struct RenderClaude {
    static func main() throws {
        _ = NSApplication.shared
        if CommandLine.arguments.dropFirst().first == "--probe" {
            let agents = ClaudeRuntimeReader(home: ClaudeLocations.configuredHome()).poll(now: Date())
            print("claude-runtime agents=\(agents.count) active=\(agents.filter { $0.status == .working || $0.status == .approvalRequested }.count)")
            return
        }
        let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "/tmp/agentnotch-claude-visual/images", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var previewWindow: NSWindow?
        for language in [LanguagePreference.turkish, .english] {
            let suite = "ClaudeVisual.\(UUID())"
            let defaults = UserDefaults(suiteName: suite)!
            let settings = NotchSettings(defaults: defaults)
            settings.language = language
            defer { defaults.removePersistentDomain(forName: suite) }
            let now = Date()
            let usage = CodexUsageSnapshot(primary: CodexUsageWindow(usedPercent: 20,
                windowMinutes: 300, resetsAt: now.addingTimeInterval(5400)),
                secondary: CodexUsageWindow(usedPercent: 18, windowMinutes: 10080,
                    resetsAt: now.addingTimeInterval(3 * 86400)),
                observedAt: now, planType: nil, limitID: "claude", identityKey: "fixture")
            let oldUsage = CodexUsageSnapshot(primary: nil,
                secondary: CodexUsageWindow(usedPercent: 86, windowMinutes: 10080,
                    resetsAt: now.addingTimeInterval(3 * 86400)),
                observedAt: now.addingTimeInterval(-3600), planType: nil, limitID: "claude", identityKey: "fixture")
            let working = [
                CodexAgentSnapshot(id: "a", project: "agentnotch", name: nil,
                                   status: .working, updatedAt: now),
                CodexAgentSnapshot(id: "b", project: "bayinext", name: "fixture-child",
                                   status: .working, updatedAt: now.addingTimeInterval(-2), parentID: "a")
            ]
            let permission = CodexApprovalSnapshot(id: "p", sessionID: "a", turnID: "t",
                project: "agentnotch", summary: language == .turkish
                    ? "Testleri çalıştırmak için ağ erişimi gerekiyor."
                    : "Network access is needed to run the tests.",
                toolName: "Bash", requestedAt: now)
            let content = VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 18) {
                    card("Disconnected", settings: settings) {
                        CodexWidgetContent(settings: settings, isClaude: true, usage: nil, now: now)
                    }
                    card("Working", settings: settings) {
                        CodexWidgetContent(settings: settings, isClaude: true, usage: usage, agents: working,
                            connection: .receiving, now: now)
                    }
                }
                HStack(alignment: .top, spacing: 18) {
                    card("Permission request", settings: settings) {
                        CodexWidgetContent(settings: settings, isClaude: true, usage: usage,
                            agents: working, approvals: [permission], connection: .receiving, now: now)
                    }
                    card("Old quota / unknown activity", settings: settings) {
                        CodexWidgetContent(settings: settings, isClaude: true, usage: oldUsage,
                            agents: [CodexAgentSnapshot(id: "c", project: "agentnotch", name: nil,
                                status: .unknown, updatedAt: now.addingTimeInterval(-600))],
                            connection: .receiving, now: now)
                    }
                }
            }
            .padding(24)
            .background(Color(red: 0.035, green: 0.04, blue: 0.045))
            .environment(\.colorScheme, .dark)
            .environment(\.locale, settings.localization.locale)
            if CommandLine.arguments.count == 1 && language == .turkish {
                let window = NSWindow(contentViewController: NSHostingController(rootView: content))
                window.title = "Claude widget · visual QA"
                window.styleMask = [.titled, .closable]
                window.setContentSize(NSSize(width: 894, height: 470))
                window.center()
                window.makeKeyAndOrderFront(nil)
                previewWindow = window
            }
            let renderer = ImageRenderer(content: content)
            renderer.scale = 2
            guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            try png.write(to: output.appendingPathComponent("claude-\(language.rawValue).png"))
        }
        if previewWindow != nil { NSApp.run() }
    }

    static func card<Content: View>(_ title: String, settings: NotchSettings,
                                   @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.system(size: 10)).foregroundStyle(.white.opacity(0.45))
            content()
                .padding(16)
                .frame(width: 414, height: WidgetKind.codex.descriptor.height)
                .background(settings.foregroundColor.opacity(0.055), in: RoundedRectangle(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(settings.foregroundColor.opacity(0.065)))
        }
    }
}
