// Standalone visual QA harness. Compile with the Codex/widget/localization
// sources, never with AgentNotchApp.swift. No hooks are installed by this tool.
import AppKit
import SwiftUI

@main
@MainActor
struct RenderCodex {
    static func main() throws {
        _ = NSApplication.shared
        if CommandLine.arguments[1] == "--probe" {
            let result = CodexUsageReader(sessionsDirectory: CodexLocations.defaultHome
                .appendingPathComponent("sessions")).refresh()
            print("sandbox-reader availability=\(result.availability) files=\(result.scannedFiles) snapshot=\(result.snapshot != nil)")
            return
        }
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for language in [LanguagePreference.turkish, .english] {
            let suite = "CodexVisual.\(UUID())"
            let defaults = UserDefaults(suiteName: suite)!
            let settings = NotchSettings(defaults: defaults)
            settings.language = language
            defer { defaults.removePersistentDomain(forName: suite) }
            let now = Date()
            let usage = CodexUsageSnapshot(primary: CodexUsageWindow(usedPercent: 20,
                windowMinutes: 300, resetsAt: now.addingTimeInterval(5400)),
                secondary: CodexUsageWindow(usedPercent: 18, windowMinutes: 10080,
                    resetsAt: now.addingTimeInterval(3 * 86400)),
                observedAt: now, planType: "pro", limitID: "codex", identityKey: "fixture")
            let oldUsage = CodexUsageSnapshot(primary: CodexUsageWindow(usedPercent: 100,
                windowMinutes: 300, resetsAt: now.addingTimeInterval(-600)),
                secondary: CodexUsageWindow(usedPercent: 86, windowMinutes: 10080,
                    resetsAt: now.addingTimeInterval(3 * 86400)),
                observedAt: now.addingTimeInterval(-3600), planType: "pro", limitID: "codex", identityKey: "fixture")
            let working = [
                CodexAgentSnapshot(id: "a", project: "agentnotch", name: nil,
                                   status: .working, updatedAt: now),
                CodexAgentSnapshot(id: "b", project: "bayinext", name: "fixture-child",
                                   status: .working, updatedAt: now.addingTimeInterval(-2))
            ]
            let permission = CodexApprovalSnapshot(id: "p", sessionID: "a", turnID: "t",
                project: "agentnotch", summary: language == .turkish
                    ? "Testleri çalıştırmak için ağ erişimi gerekiyor."
                    : "Network access is needed to run the tests.",
                toolName: "Bash", requestedAt: now)
            let content = VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 18) {
                    card("Question / failure / interruption", settings: settings) {
                        CodexWidgetContent(settings: settings, usage: usage, agents: [
                            CodexAgentSnapshot(id: "question", project: "agentnotch", name: nil, status: .awaitingInput, updatedAt: now),
                            CodexAgentSnapshot(id: "failed", project: "agentnotch", name: "Reviewer", status: .failed, updatedAt: now),
                            CodexAgentSnapshot(id: "interrupted", project: "bayinext", name: nil, status: .interrupted, updatedAt: now)
                        ], connection: .receiving, now: now)
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(["GPTMark", "ClaudeMark"], id: \.self) { provider in
                            ForEach([false, true], id: \.self) { child in
                                HStack(spacing: 20) {
                                    ForEach(Array([CodexIndicator.working, .question, .approval, .failed, .interrupted].enumerated()), id: \.offset) { _, indicator in
                                        VStack(spacing: 8) {
                                            CompactAgentMark(iconName: provider, isSubagent: child, foreground: .white,
                                                background: .black, statusSymbol: indicator.symbol,
                                                statusColor: indicator == .working ? .green : indicator == .failed ? .red : .orange,
                                                animates: false)
                                            Text(settings.localization.text(indicator.title)).font(.system(size: 8))
                                        }
                                    }
                                }
                            }
                        }
                    }.padding(16).foregroundStyle(.white).frame(width: 414)
                }
                HStack(alignment: .top, spacing: 18) {
                    card("Disconnected", settings: settings) {
                        CodexWidgetContent(settings: settings, usage: usage, now: now)
                    }
                    card("Working", settings: settings) {
                        CodexWidgetContent(settings: settings, usage: usage, agents: working,
                            connection: .receiving, now: now)
                    }
                }
                HStack(alignment: .top, spacing: 18) {
                    card("Permission request", settings: settings) {
                        CodexWidgetContent(settings: settings, usage: usage,
                            agents: working, approvals: [permission], connection: .receiving, now: now)
                    }
                    card("Old quota / unknown activity", settings: settings) {
                        CodexWidgetContent(settings: settings, usage: oldUsage,
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
            // A live host realizes ScrollView/LazyVStack rows; ImageRenderer
            // silently omits them and cannot validate activity labels.
            let host = NSHostingView(rootView: content)
            let size = host.fittingSize
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            window.orderFront(nil)
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
                throw CocoaError(.fileWriteUnknown)
            }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            guard
                  let png = bitmap.representation(using: .png, properties: [:]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            try png.write(to: output.appendingPathComponent("codex-\(language.rawValue).png"))
            window.orderOut(nil)
        }
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
