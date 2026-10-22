#!/usr/bin/env python3
"""Compare unchanged monitor ticks against a Git revision using synthetic data.

Measures monitor CPU time only; it is not an application, UI, watcher, memory or
battery benchmark. Temporary fixtures are deleted; real integrations are untouched.
"""
import argparse
import json
import pathlib
import subprocess
import tempfile

repo = pathlib.Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--baseline", default="1b77ca5")
parser.add_argument("--app", type=pathlib.Path, default=pathlib.Path("/Applications/agentnotch.app"))
args = parser.parse_args()
for provider in ("Codex", "Claude"):
    if not (args.app / f"Contents/Resources/{provider}/agentnotch-{provider.lower()}-hook").is_file():
        parser.error(f"{provider} helper missing from --app")
paths = ["Sources/Localization/AppLocalization.swift", "Sources/Localization/L10nKey.swift"]
for provider in ("Codex", "Claude"):
    paths += [f"Sources/Features/Widgets/{provider}/{provider}{name}.swift"
              for name in ("Activity", "HookInstaller", "Store")]
paths += ["Sources/Features/Widgets/Codex/CodexUsageReader.swift"]
with tempfile.TemporaryDirectory(prefix="agentnotch-monitor-benchmark-", dir="/private/tmp") as directory:
    work = pathlib.Path(directory)
    main = work / "Benchmark.swift"
    main.write_text(r'''
import Darwin
import Foundation
@main struct Benchmark {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let resources = URL(fileURLWithPath: CommandLine.arguments[2])
        let codexHome = root.appendingPathComponent("codex")
        let claudeHome = root.appendingPathComponent("claude")
        try FileManager.default.createDirectory(at: codexHome.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: claudeHome, withIntermediateDirectories: true)
        let codexHelper = resources.appendingPathComponent("Codex/agentnotch-codex-hook")
        let claudeHelper = resources.appendingPathComponent("Claude/agentnotch-claude-hook")
        let codexInstaller = CodexHookInstaller(codexHome: codexHome, helperSource: codexHelper)
        let claudeInstaller = ClaudeHookInstaller(claudeHome: claudeHome, helperSource: claudeHelper)
        try codexInstaller.install(); try claudeInstaller.install()
        let now = Date()
        let at = now.addingTimeInterval(-2)
        let timestamp = ISO8601DateFormatter().string(from: at)
        for index in 0..<100 {
            let meta: [String: Any] = ["type": "session_meta", "payload": ["id": "s\(index)",
                "creator_account_id": "account", "creator_user_id": "user"]]
            let quota: [String: Any] = ["type": "event_msg", "timestamp": timestamp,
                "payload": ["type": "token_count", "rate_limits": ["limit_id": "codex",
                    "primary": ["used_percent": 25, "window_minutes": 300]]]]
            var data = try JSONSerialization.data(withJSONObject: meta); data.append(10)
            data.append(try JSONSerialization.data(withJSONObject: quota)); data.append(10)
            try data.write(to: codexHome.appendingPathComponent("sessions/\(index).jsonl"))
        }
        for index in 0..<1000 {
            let session = "agent-\(index % 50)"
            let codex = CodexHookEvent(kind: .userPromptSubmit, timestamp: at, sessionID: session, turnID: "t", project: "fixture")
            let claude = ClaudeHookEvent(kind: .userPromptSubmit, timestamp: at, sessionID: session, project: "fixture")
            try JSONEncoder().encode(codex).write(to: codexInstaller.eventsDirectory.appendingPathComponent("\(codex.id).json"))
            try JSONEncoder().encode(claude).write(to: claudeInstaller.eventsDirectory.appendingPathComponent("\(claude.id).json"))
        }
        let codex = CodexMonitor(home: codexHome, helperSource: codexHelper)
        let claude = ClaudeMonitor(home: claudeHome, helperSource: claudeHelper)
        _ = codex.poll(now: now); _ = claude.poll(now: now)
        let cpuStart = clock()
        let wallStart = ProcessInfo.processInfo.systemUptime
        var signature = 0
        // The new driver requests two recovery scans in a simulated two-minute
        // interval. Include them so this does not measure projection alone.
        for second in 1...120 {
            let date = now.addingTimeInterval(Double(second))
            #if EVENT_DRIVEN
            let changes: MonitorChanges = second % 60 == 0 ? .all : MonitorChanges()
            let a = codex.poll(now: date, changes: changes)
            let b = claude.poll(now: date, changes: changes)
            #else
            let a = codex.poll(now: date)
            let b = claude.poll(now: date)
            #endif
            signature += a.agents.count + b.agents.count
            signature += Int(a.usage.snapshot?.primary?.usedPercent ?? 0)
        }
        let result: [String: Any] = ["cpu_seconds": Double(clock() - cpuStart) / Double(CLOCKS_PER_SEC),
            "wall_seconds": ProcessInfo.processInfo.systemUptime - wallStart,
            "ticks": 120, "session_files": 100, "events_per_provider": 1000, "signature": signature]
        let output = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        print(String(decoding: output, as: UTF8.self))
    }
}
''')
    results = {}
    for mode in ("baseline", "current"):
        sources = []
        for index, path in enumerate(paths):
            if mode == "baseline":
                target = work / f"baseline-{index}.swift"
                target.write_bytes(subprocess.check_output(["git", "show", f"{args.baseline}:{path}"], cwd=repo))
                sources.append(str(target))
            else:
                sources.append(str(repo / path))
        flags = []
        if mode == "current":
            sources.append(str(repo / "Sources/Features/Widgets/Monitoring/LocalMonitorDriver.swift"))
            flags = ["-D", "EVENT_DRIVEN"]
        binary = work / mode
        subprocess.run(["xcrun", "swiftc", "-O", "-module-cache-path", str(work / "module-cache"),
                        *flags, *sources, str(main), "-o", str(binary)], check=True)
        result = subprocess.run([str(binary), str(work / f"fixture-{mode}"), str(args.app / "Contents/Resources")],
                                text=True, capture_output=True, timeout=60, check=True)
        results[mode] = json.loads(result.stdout)
        print(mode, json.dumps(results[mode], sort_keys=True), flush=True)
    assert results["baseline"]["signature"] == results["current"]["signature"], "presentation signatures differ"
    saving = 100 * (1 - results["current"]["cpu_seconds"] / results["baseline"]["cpu_seconds"])
    print(f"Monitor CPU-time reduction in this synthetic workload: {saving:.2f}%")
