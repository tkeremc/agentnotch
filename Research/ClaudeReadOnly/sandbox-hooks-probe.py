#!/usr/bin/env python3
"""Build and run the sandbox probe in a fresh /private/tmp fixture only."""
import pathlib
import plistlib
import subprocess
import tempfile
import shutil
import os
import json

source = pathlib.Path(__file__).resolve().parent
work = pathlib.Path(tempfile.mkdtemp(prefix="agentnotch-sandbox-hooks-", dir="/private/tmp"))
fixture = work / "fixture"
fixture.mkdir()
(fixture / "sessions").mkdir()
(fixture / "sessions" / "fixture.jsonl").write_text("{}\n")
(fixture / "auth.json").write_text("synthetic-credential-fixture")
bundle = work / "SandboxHooksProbe.app"
executable = bundle / "Contents" / "MacOS" / "probe"
executable.parent.mkdir(parents=True)
helper = bundle / "Contents" / "Resources" / "Claude" / "agentnotch-claude-hook"
helper.parent.mkdir(parents=True)
subprocess.run(["/bin/sh", str(source.parent.parent / "Native" / "build-claude-bridge.sh")],
               env={**os.environ, "AGENTNOTCH_SOURCE_ROOT": str(source.parent.parent),
                    "TARGET_BUILD_DIR": str(bundle / "Contents"),
                    "UNLOCALIZED_RESOURCES_FOLDER_PATH": "Resources",
                    "DERIVED_FILE_DIR": str(work / "helper-build"), "ARCHS": "arm64"}, check=True)
(bundle / "Contents" / "Info.plist").write_bytes(plistlib.dumps({
    "CFBundleExecutable": "probe", "CFBundleIdentifier": "com.agentnotch.ClaudeSandboxHooksProbe",
    "CFBundlePackageType": "APPL", "LSUIElement": True, "ProbeFixture": str(fixture),
}))
entitlements = work / "probe.entitlements"
entitlements.write_bytes(plistlib.dumps({
    "com.apple.security.app-sandbox": True,
    "com.apple.security.temporary-exception.files.absolute-path.read-write": [
        str(fixture / "settings.json"), str(fixture / "agentnotch") + "/",
    ],
    "com.apple.security.temporary-exception.files.absolute-path.read-only": [
        str(fixture / "sessions") + "/",
    ],
}))
print(f"Isolated fixture: {fixture}", flush=True)
main = work / "main.swift"
shutil.copyfile(source / "SandboxHooksProbe.swift", main)
subprocess.run(["xcrun", "swiftc", "-module-cache-path", str(work / "module-cache"),
                str(main), str(source.parent.parent / "Sources" / "Features" / "Widgets" /
                               "Claude" / "ClaudeHookInstaller.swift"),
                "-o", str(executable)], check=True)
subprocess.run(["codesign", "--force", "--sign", "-", "--entitlements", str(entitlements),
                str(bundle)], check=True)
subprocess.run(["codesign", "--verify", "--deep", "--strict", str(bundle)], check=True)
if os.environ.get("AGENTNOTCH_PROBE_BUILD_ONLY") == "1":
    print(f"Desktop probe: {bundle}", flush=True)
    raise SystemExit(0)
subprocess.run([str(executable), str(fixture), str(helper)], check=True)

# Run the installed hook exactly as a shell command, outside the fixture app's
# App Sandbox, like Claude. Neither the real Claude home nor trust is touched.
root = json.loads((fixture / "settings.json").read_text())
command = root["hooks"]["UserPromptSubmit"][0]["hooks"][0]["command"]
result = subprocess.run(["/bin/zsh", "-lc", command], input=json.dumps({
    "hook_event_name": "UserPromptSubmit", "session_id": "fixture-session",
    "turn_id": "fixture-turn", "cwd": str(fixture),
}), text=True, capture_output=True, timeout=5, check=True)
events = list((fixture / "agentnotch/events").glob("*.json"))
assert result.stdout == "" and result.stderr == "" and len(events) == 1
assert not (fixture / "agentnotch/bin/agentnotch-claude-hook").exists()
assert str(helper) in command
print("PASS sandbox-install-to-external-shell-event")
