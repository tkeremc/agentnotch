#!/usr/bin/env python3
"""GUI check in an isolated app bundle. Never accepts Codex consent or bundles its helper."""
import pathlib
import plistlib
import subprocess
import tempfile

root = pathlib.Path(__file__).resolve().parents[2]
work = pathlib.Path(tempfile.mkdtemp(prefix="agentnotch-settings-flow-", dir="/private/tmp"))
bundle = work / "SettingsFlowCheck.app"
resources = bundle / "Contents/Resources"
binary = bundle / "Contents/MacOS/check"
resources.mkdir(parents=True)
binary.parent.mkdir()
(bundle / "Contents/Info.plist").write_bytes(plistlib.dumps({
    "CFBundleIdentifier": "com.agentnotch.SettingsFlowCheck", "CFBundleExecutable": "check",
    "CFBundlePackageType": "APPL", "LSUIElement": True,
}))
subprocess.run(["xcrun", "xcstringstool", "compile", str(root / "Resources/Localizable.xcstrings"),
                "--output-directory", str(resources)], check=True)
subprocess.run(["xcrun", "actool", str(root / "Resources/Assets.xcassets"), "--platform", "macosx",
                "--minimum-deployment-target", "14.0", "--compile", str(resources)], check=True)
sources = sorted(str(p) for p in (root / "Sources").rglob("*.swift") if p.name != "AgentNotchApp.swift")
subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-module-cache-path", str(work / "module-cache"),
                *sources, str(root / "Research/CodexReadOnly/SettingsFlowCheck.swift"), "-o", str(binary)], check=True)
print(f"GUI screenshots: {work}", flush=True)
subprocess.run([str(binary), str(work)], check=True, timeout=25)
