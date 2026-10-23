#!/usr/bin/env python3
"""Exercise the compiled native helper with isolated hook fixtures only."""
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

from HookSpoolCases import HookSpoolCases

HELPER = Path(sys.argv.pop(1)).resolve()


class HookBridgeTests(HookSpoolCases, unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="agentnotch-hook-fixture-")
        self.addCleanup(self.temp.cleanup)
        self.spool = Path(self.temp.name) / "events"
        self.spool.mkdir(mode=0o700)

    def invoke(self, payload, spool=None):
        raw = payload if isinstance(payload, bytes) else json.dumps(payload).encode()
        result = subprocess.run([str(HELPER), "--events-dir", str(spool or self.spool)],
                                input=raw, capture_output=True, timeout=4)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, b"")
        self.assertEqual(result.stderr, b"")

    def payload(self, kind="PermissionRequest"):
        return {"hook_event_name": kind, "session_id": "session-id", "turn_id": "turn-id",
                "cwd": "/private/projects/project-name", "tool_name": "Bash",
                "prompt": "PROMPT MUST NOT LEAK", "auth": "AUTH MUST NOT LEAK",
                "transcript_path": "/private/full-transcript.jsonl",
                "tool_input": {"command": "SECRET SHELL COMMAND",
                               "description": "Network\n access\x00 requested"}}

    def test_allowlist_private_files_and_no_approval_response(self):
        self.invoke(self.payload())
        files = list(self.spool.glob("*.json"))
        self.assertEqual(len(files), 1)
        event = json.loads(files[0].read_text())
        self.assertEqual(event["schemaVersion"], 1)
        self.assertEqual(event["kind"], "PermissionRequest")
        self.assertEqual(event["project"], "project-name")
        self.assertEqual(event["permissionSummary"], "Network access requested")
        self.assertNotIn("toolUseID", event)  # PermissionRequest need not supply one.
        self.assertEqual(stat.S_IMODE(files[0].stat().st_mode), 0o600)
        self.assertEqual(set(event), {"schemaVersion", "id", "kind", "timestamp", "sessionID",
                                     "turnID", "project", "toolName", "toolFingerprint", "permissionSummary"})
        for secret in ["PROMPT", "AUTH", "SECRET", "full-transcript", "/private/projects"]:
            self.assertNotIn(secret, files[0].read_text())

    def test_pre_tool_use_and_child_transcript_identity(self):
        transcript = Path(self.temp.name) / "child.jsonl"
        transcript.write_text(json.dumps({"type": "session_meta", "payload": {
            "id": "child-thread", "parent_thread_id": "parent-thread",
            "base_instructions": "PRIVATE CONTENT"}}) + "\n")
        payload = self.payload("PreToolUse")
        payload["transcript_path"] = str(transcript)
        self.invoke(payload)
        event = json.loads(next(self.spool.glob("*.json")).read_text())
        self.assertEqual(event["kind"], "PreToolUse")
        self.assertEqual(event["sessionID"], "parent-thread")
        self.assertEqual(event["agentID"], "child-thread")
        self.assertNotIn("PRIVATE CONTENT", json.dumps(event))
        self.assertNotIn(str(transcript), json.dumps(event))

    def test_missing_description_never_falls_back_to_command(self):
        payload = self.payload()
        del payload["tool_input"]["description"]
        self.invoke(payload)
        event = json.loads(next(self.spool.glob("*.json")).read_text())
        self.assertNotIn("permissionSummary", event)
        self.assertNotIn("SECRET", json.dumps(event))

    def test_structured_tool_outcome_retains_only_boolean(self):
        for response, expected in [({"exit_code": 2}, True), ({"exitCode": 0}, False),
                                   ({"isError": True}, True), ({"is_error": False}, False),
                                   ({"exit_code": True}, None), ({"output": "PRIVATE OUTPUT"}, None)]:
            payload = self.payload("PostToolUse")
            payload["tool_response"] = dict(response, secret="PRIVATE OUTPUT")
            before = set(self.spool.glob("*.json"))
            self.invoke(payload)
            event = json.loads((set(self.spool.glob("*.json")) - before).pop().read_text())
            self.assertEqual(event.get("toolFailed"), expected)
            self.assertNotIn("PRIVATE OUTPUT", json.dumps(event))

    def test_invalid_and_oversized_input_is_ignored(self):
        for value in [b"{broken", b"[]", b"x" * 1_048_577,
                      {"hook_event_name": "Unknown", "session_id": "s"},
                      {"hook_event_name": "Stop"}]:
            self.invoke(value)
        self.assertEqual(list(self.spool.iterdir()), [])

    def test_incomplete_stdin_cannot_hold_up_codex(self):
        process = subprocess.Popen([str(HELPER), "--events-dir", str(self.spool)],
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            process.stdin.write(b"{")
            process.stdin.flush()
            self.assertEqual(process.wait(timeout=2.8), 0)
            self.assertEqual(process.stdout.read(), b"")
            self.assertEqual(process.stderr.read(), b"")
            self.assertEqual(list(self.spool.iterdir()), [])
        finally:
            process.stdin.close()
            process.stdout.close()
            process.stderr.close()
            if process.poll() is None:
                process.kill()
                process.wait()

    def test_parallel_writers_preserve_every_event(self):
        with concurrent.futures.ThreadPoolExecutor(max_workers=12) as pool:
            list(pool.map(lambda _: self.invoke(self.payload("UserPromptSubmit")), range(48)))
        files = list(self.spool.glob("*.json"))
        self.assertEqual(len(files), 48)
        self.assertEqual(self.saved_checkpoint()["count"], 48)
        self.assertEqual(len({json.loads(path.read_text())["id"] for path in files}), 48)
        self.assertFalse(list(self.spool.glob("*.tmp")))

    def test_symlink_or_shared_spool_is_not_used(self):
        link = Path(self.temp.name) / "link"
        link.symlink_to(self.spool, target_is_directory=True)
        self.invoke(self.payload(), link)
        self.spool.chmod(0o755)
        self.invoke(self.payload())
        self.assertEqual(list(self.spool.iterdir()), [])

    def test_spool_age_and_count_are_bounded_without_deleting_foreign_files(self):
        stale = self.spool / f"{uuid.uuid4()}.json"
        stale.write_text("{}")
        old = time.time() - 8 * 24 * 3600
        os.utime(stale, (old, old))
        foreign = self.spool / "user-file.json"
        foreign.write_text("keep")
        for _ in range(4096):
            (self.spool / f"{uuid.uuid4()}.json").write_text("{}")
        self.invoke(self.payload("Stop"))
        owned = [p for p in self.spool.glob("*.json") if p != foreign]
        self.assertEqual(len(owned), 3073)
        self.assertFalse(stale.exists())
        self.assertEqual(foreign.read_text(), "keep")

    def test_summary_is_bounded_and_absent_for_nonpermission_event(self):
        payload = self.payload()
        payload["tool_input"]["description"] = "a" * 1000
        self.invoke(payload)
        event = json.loads(next(self.spool.glob("*.json")).read_text())
        self.assertEqual(len(event["permissionSummary"]), 160)
        for path in self.spool.iterdir():
            path.unlink()
        self.invoke(self.payload("PostToolUse"))
        event = json.loads(next(self.spool.glob("*.json")).read_text())
        self.assertNotIn("permissionSummary", event)


if __name__ == "__main__":
    unittest.main()
