#!/usr/bin/env python3
"""Verify native monitoring with production-equivalent narrow sandbox grants.

All input, credentials and events are synthetic and confined to a temporary
fixture. No real integration, application or user configuration is changed.
"""
import os
import pathlib
import plistlib
import select
import subprocess
import tempfile

repo = pathlib.Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix="agentnotch-monitor-sandbox-", dir="/private/tmp") as directory:
    work = pathlib.Path(directory)
    home = work / "fixture"
    (home / "sessions").mkdir(parents=True)
    (home / "agentnotch/events").mkdir(parents=True)
    (home / "auth.json").write_text("synthetic-forbidden-credential")
    session = home / "sessions/a.jsonl"
    hooks = home / "hooks.json"
    event = home / "agentnotch/events/a.json"
    for path in (session, hooks, event):
        path.write_text("initial\n")
    app = work / "MonitorProbe.app"
    binary = app / "Contents/MacOS/probe"
    binary.parent.mkdir(parents=True)
    (app / "Contents/Info.plist").write_bytes(plistlib.dumps({
        "CFBundleExecutable": "probe", "CFBundleIdentifier": "com.agentnotch.MonitorProbe",
        "CFBundlePackageType": "APPL", "LSUIElement": True,
    }))
    grants = work / "probe.entitlements"
    grants.write_bytes(plistlib.dumps({
        "com.apple.security.app-sandbox": True,
        "com.apple.security.temporary-exception.files.absolute-path.read-only": [str(home / "sessions") + "/"],
        "com.apple.security.temporary-exception.files.absolute-path.read-write": [
            str(hooks), str(home / "agentnotch") + "/",
        ],
    }))
    source = work / "Probe.swift"
    source.write_text(r'''
import Darwin
import Foundation
@main struct Probe {
    final class State {
        let lock = NSLock()
        private var seen = false
        func mark() { lock.lock(); seen = true; lock.unlock() }
        var received: Bool { lock.lock(); defer { lock.unlock() }; return seen }
    }
    static func main() {
        fputs("probe entered main\n", stderr); fflush(stderr)
        let home = URL(fileURLWithPath: CommandLine.arguments[1])
        let file = URL(fileURLWithPath: CommandLine.arguments[2])
        let queue = DispatchQueue(label: "sandbox-monitor-probe")
        let state = State()
        let driver = LocalMonitorDriver(home: home, observed: [file], queue: queue) { changes in
            if !changes.reconcile, !changes.paths.isEmpty, changes.affects(file),
               (try? String(contentsOf: file, encoding: .utf8)) == "external-change\n" {
                state.mark()
            }
        }
        driver.start()
        queue.sync {}
        print("READY"); fflush(stdout)
        let deadline = Date().addingTimeInterval(6)
        while !state.received && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        driver.stop(); queue.sync {}
        let forbidden = (try? Data(contentsOf: home.appendingPathComponent("auth.json"))) == nil
        print("notification=\(state.received) credentialsDenied=\(forbidden)")
        exit(state.received && forbidden ? 0 : 1)
    }
}
''')
    subprocess.run(["xcrun", "swiftc", "-module-cache-path", str(work / "module-cache"),
                    str(repo / "Sources/Features/Widgets/Monitoring/LocalMonitorDriver.swift"),
                    str(source), "-o", str(binary)], check=True)
    subprocess.run(["codesign", "--force", "--sign", "-", "--entitlements", str(grants), str(app)], check=True)
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    for name, target, atomic in [("session append", session, False),
                                 ("event atomic replacement", event, True),
                                 ("configuration atomic replacement", hooks, True)]:
        target.write_text("initial\n")
        process = subprocess.Popen([str(binary), str(home), str(target)],
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            ready, _, _ = select.select([process.stdout], [], [], 15)
            if not ready or process.stdout.readline().strip() != "READY":
                if process.poll() is None:
                    process.kill()
                output, errors = process.communicate()
                raise RuntimeError(f"sandbox probe did not become ready (exit={process.returncode}): {output} {errors}")
            if atomic:
                temporary = target.with_suffix(".tmp")
                temporary.write_text("external-change\n")
                os.replace(temporary, target)
            else:
                target.write_text("external-change\n")
            output, errors = process.communicate(timeout=10)
            if process.returncode:
                raise RuntimeError(f"{name}: {output}\n{errors}")
            print(f"PASS {name}: {output.strip()}")
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate()
