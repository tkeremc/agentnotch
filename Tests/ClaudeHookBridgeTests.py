#!/usr/bin/env python3
"""Native Claude hook/statusline integration with isolated fixtures only."""
import base64
import concurrent.futures
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import time
import unittest
import uuid

HELPER = Path(sys.argv.pop(1)).resolve()


class ClaudeHookBridgeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="agentnotch-claude-fixture-")
        self.addCleanup(self.temp.cleanup)
        self.integration = Path(self.temp.name) / "agentnotch"
        self.integration.mkdir(mode=0o700)
        self.spool = self.integration / "events"
        self.spool.mkdir(mode=0o700)

    def invoke(self, payload, statusline=False, spool=None):
        raw = payload if isinstance(payload, bytes) else json.dumps(payload).encode()
        args = [str(HELPER), "--events-dir", str(spool or self.spool)]
        if statusline:
            args.append("--statusline")
        result = subprocess.run(args, input=raw, capture_output=True, timeout=6)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stderr, b"")
        return result.stdout

    def payload(self, kind="PermissionRequest"):
        return {"hook_event_name": kind, "session_id": "session-id", "agent_id": "agent-id",
                "agent_type": "Explore", "cwd": "/private/projects/project-name", "tool_name": "Bash",
                "tool_use_id": "tool-use", "prompt": "PROMPT MUST NOT LEAK", "auth": "AUTH MUST NOT LEAK",
                "message": "MESSAGE MUST NOT LEAK", "transcript_path": "/private/full-transcript.jsonl",
                "tool_input": {"command": "SECRET SHELL COMMAND", "description": "SECRET DESCRIPTION"}}

    def event(self):
        paths = list(self.spool.glob("*.json"))
        self.assertEqual(len(paths), 1)
        return json.loads(paths[0].read_text())

    def manifest(self, command, **fields):
        original = {"type": "command", "command": command, "padding": 2}
        data = {"schemaVersion": 1, "originalStatusLine": base64.b64encode(json.dumps(original).encode()).decode()}
        data.update(fields)
        path = self.integration / "installation.json"
        path.write_text(json.dumps(data))
        path.chmod(0o600)
        return path

    def test_allowlist_and_privacy(self):
        self.assertEqual(self.invoke(self.payload()), b"")
        event = self.event()
        self.assertEqual(event["kind"], "PermissionRequest")
        self.assertEqual(event["project"], "project-name")
        self.assertEqual(event["agentType"], "Explore")
        self.assertEqual(len(event["toolFingerprint"]), 64)
        self.assertEqual(set(event), {"schemaVersion", "id", "kind", "timestamp", "sessionID", "agentID",
                                     "project", "toolName", "toolUseID", "toolFingerprint", "agentType"})
        path = next(self.spool.glob("*.json"))
        self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
        for secret in ["PROMPT", "AUTH", "SECRET", "MESSAGE", "full-transcript", "/private/projects"]:
            self.assertNotIn(secret, path.read_text())

    def test_all_lifecycle_events_and_notification_metadata(self):
        events = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest", "PostToolUse",
                  "PostToolUseFailure", "Notification", "SubagentStart", "SubagentStop", "Stop", "StopFailure", "SessionEnd"]
        for kind in events:
            payload = self.payload(kind)
            payload["notification_type"] = "permission_prompt"
            self.invoke(payload)
        output = [json.loads(p.read_text()) for p in self.spool.glob("*.json")]
        self.assertEqual({e["kind"] for e in output}, set(events))
        for event in output:
            self.assertEqual("notificationType" in event, event["kind"] == "Notification")
            self.assertNotIn("message", event)

    def test_fingerprint_matches_canonical_input(self):
        first = self.payload("PreToolUse")
        second = self.payload("PermissionRequest")
        second["tool_input"] = dict(reversed(list(first["tool_input"].items())))
        del second["tool_use_id"]
        self.invoke(first)
        self.invoke(second)
        events = [json.loads(p.read_text()) for p in self.spool.glob("*.json")]
        self.assertEqual(events[0]["toolFingerprint"], events[1]["toolFingerprint"])

    def test_statusline_usage_is_flat_validated_and_no_token_data_leaks(self):
        payload = self.payload()
        payload.update({"rate_limits": {"five_hour": {"used_percentage": 32.5, "resets_at": 1800000000},
                                        "seven_day": {"used_percentage": 78, "resets_at": 1800200000}},
                        "model": {"id": "SECRET MODEL ID", "display_name": "Claude Sonnet"},
                        "context_window": {"used_percentage": 14, "total_input_tokens": 1234567},
                        "command": "touch /tmp/never-execute-input-command"})
        self.assertEqual(self.invoke(payload, statusline=True), b"")
        event = self.event()
        self.assertEqual(event["kind"], "StatusLine")
        self.assertEqual(event["fiveHourUsedPercent"], 32.5)
        self.assertEqual(event["fiveHourResetsAt"], 1800000000)
        self.assertEqual(event["sevenDayUsedPercent"], 78)
        self.assertEqual(event["contextUsedPercent"], 14)
        self.assertEqual(event["model"], "Claude Sonnet")
        self.assertNotIn("toolName", event)
        self.assertNotIn("SECRET", json.dumps(event))
        self.assertNotIn("1234567", json.dumps(event))

    def test_statusline_unavailable_or_invalid_limits_are_not_invented(self):
        payload = {"session_id": "api-session", "rate_limits": {
            "five_hour": {"used_percentage": True, "resets_at": -1},
            "seven_day": {"used_percentage": 101, "resets_at": "1800000000"}}}
        self.invoke(payload, statusline=True)
        event = self.event()
        self.assertNotIn("fiveHourUsedPercent", event)
        self.assertNotIn("fiveHourResetsAt", event)
        self.assertNotIn("sevenDayUsedPercent", event)
        self.assertNotIn("sevenDayResetsAt", event)

    def test_original_statusline_receives_exact_stdin_and_preserves_stdout(self):
        script = Path(self.temp.name) / "existing-line.py"
        script.write_text("import sys\nsys.stdout.buffer.write(b'LINE: ' + sys.stdin.buffer.read() + b'\\x1b[0m\\n')\n")
        self.manifest(f"/usr/bin/python3 '{script}'")
        raw = b' { "session_id" : "s", "padding" : "keep exact input" }\n'
        self.assertEqual(self.invoke(raw, statusline=True), b"LINE: " + raw + b"\x1b[0m\n")
        self.assertEqual(self.event()["sessionID"], "s")
        # Even future/invalid JSON does not break the user's original status line.
        self.assertEqual(self.invoke(b"future-format", statusline=True), b"LINE: future-format\x1b[0m\n")

    def test_payload_cannot_select_command_or_manifest(self):
        marker = Path(self.temp.name) / "should-not-exist"
        payload = {"session_id": "s", "command": f"touch '{marker}'", "statusLine": {"command": f"touch '{marker}'"},
                   "originalStatusLine": {"command": f"touch '{marker}'"}}
        self.invoke(payload, statusline=True)
        self.assertFalse(marker.exists())

    def test_hung_or_failed_original_statusline_is_bounded_and_never_fails_hook(self):
        self.manifest("printf 'before'; sleep 30; printf 'after'")
        start = time.monotonic()
        self.assertEqual(self.invoke({"session_id": "s"}, statusline=True), b"before")
        self.assertLess(time.monotonic() - start, 3.5)
        self.manifest("printf 'preserved'; exit 17")
        self.assertEqual(self.invoke({"session_id": "s"}, statusline=True), b"preserved")

    def test_recursive_or_unsafe_manifest_is_not_executed(self):
        marker = Path(self.temp.name) / "should-not-exist"
        path = self.manifest(f"touch '{marker}'; '{HELPER}' --events-dir '{self.spool}' --statusline")
        self.invoke({"session_id": "s"}, statusline=True)
        self.assertFalse(marker.exists())
        self.manifest(f"touch '{marker}'").chmod(0o644)
        self.invoke({"session_id": "s"}, statusline=True)
        self.assertFalse(marker.exists())
        path.unlink()
        elsewhere = Path(self.temp.name) / "foreign-manifest.json"
        elsewhere.write_text(json.dumps({"schemaVersion": 1, "originalStatusLine": base64.b64encode(
            json.dumps({"type": "command", "command": f"touch '{marker}'"}).encode()).decode()}))
        path.symlink_to(elsewhere)
        self.invoke({"session_id": "s"}, statusline=True)
        self.assertFalse(marker.exists())

    def test_invalid_oversized_or_unknown_input_is_ignored(self):
        for value in [b"{broken", b"[]", b"x" * 1_048_577,
                      {"hook_event_name": "Unknown", "session_id": "s"}, {"hook_event_name": "Stop"}]:
            self.assertEqual(self.invoke(value), b"")
        self.assertEqual(list(self.spool.iterdir()), [])

    def test_incomplete_stdin_is_bounded(self):
        process = subprocess.Popen([str(HELPER), "--events-dir", str(self.spool)],
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            process.stdin.write(b"{"); process.stdin.flush()
            self.assertEqual(process.wait(timeout=2.8), 0)
            self.assertEqual(process.stdout.read(), b"")
            self.assertEqual(process.stderr.read(), b"")
        finally:
            process.stdin.close(); process.stdout.close(); process.stderr.close()
            if process.poll() is None:
                process.kill(); process.wait()

    def test_parallel_writers_and_private_spool(self):
        with concurrent.futures.ThreadPoolExecutor(max_workers=12) as pool:
            list(pool.map(lambda _: self.invoke(self.payload("UserPromptSubmit")), range(48)))
        self.assertEqual(len(list(self.spool.glob("*.json"))), 48)
        self.assertFalse(list(self.spool.glob("*.tmp")))
        for path in self.spool.iterdir():
            path.unlink()
        link = Path(self.temp.name) / "link"
        link.symlink_to(self.spool, target_is_directory=True)
        self.invoke(self.payload(), spool=link)
        self.spool.chmod(0o755)
        self.invoke(self.payload())
        self.assertEqual(list(self.spool.iterdir()), [])

    def test_spool_bounded_without_deleting_user_files(self):
        stale = self.spool / f"{uuid.uuid4()}.json"
        stale.write_text("{}")
        old = time.time() - 8 * 24 * 3600
        os.utime(stale, (old, old))
        foreign = self.spool / "user-file.json"
        foreign.write_text("keep")
        for _ in range(4096):
            (self.spool / f"{uuid.uuid4()}.json").write_text("{}")
        self.invoke(self.payload("Stop"))
        self.assertEqual(len(list(self.spool.glob("*.json"))), 4097)
        self.assertFalse(stale.exists())
        self.assertEqual(foreign.read_text(), "keep")


if __name__ == "__main__":
    unittest.main()
