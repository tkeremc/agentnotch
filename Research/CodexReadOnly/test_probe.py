"""Synthetic contract tests; never reads a real Codex directory."""

import json
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path

from probe import inspect, read_rollout


NOW = datetime(2026, 10, 20, tzinfo=timezone.utc).timestamp()


def record(kind, payload, seconds=0):
    at = datetime.fromtimestamp(NOW + seconds, timezone.utc).isoformat()
    return {"type": kind, "timestamp": at, "payload": payload}


def meta(**overrides):
    fields = {"id": "example", "cli_version": "0.163.0",
              "creator_account_id": "account-a", "creator_user_id": "user-a",
              "source": "vscode"}
    fields.update(overrides)
    return record("session_meta", fields)


def event(kind, seconds=0, **fields):
    return record("event_msg", dict(fields, type=kind), seconds)


def quota(seconds=0, used=32, bucket="codex", **overrides):
    raw = {"limit_id": bucket,
           "primary": {"used_percent": used, "window_minutes": 300,
                       "resets_at": NOW + 1000},
           "secondary": None}
    raw.update(overrides)
    return event("token_count", seconds, rate_limits=raw)


class ProbeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name) / "sessions"
        self.root.mkdir()

    def tearDown(self):
        self.temp.cleanup()

    def write(self, records, name="example.jsonl", suffix=b""):
        path = self.root / name
        path.write_bytes(b"".join((json.dumps(r) + "\n").encode() for r in records) + suffix)
        return path

    def read(self, records, **kwargs):
        return read_rollout(self.write(records, **kwargs), NOW, 120)

    def test_fresh_open_turn_is_only_a_signal(self):
        row = self.read([meta(), event("task_started", -10, turn_id="t")])
        self.assertEqual(row["activitySignal"], "recent_unclosed_turn")
        self.assertFalse(row["authoritativeLiveStatus"])

    def test_old_open_turn_is_unknown_not_complete(self):
        row = self.read([meta(), event("task_started", -500, turn_id="t")])
        self.assertEqual(row["activitySignal"], "stale_unknown")

    def test_settings_change_cannot_revive_old_open_turn(self):
        row = self.read([meta(), event("task_started", -500, turn_id="t"),
                         event("thread_settings_applied", -1)])
        self.assertEqual(row["activitySignal"], "stale_unknown")

    def test_unrelated_item_cannot_revive_old_open_turn(self):
        row = self.read([meta(), event("task_started", -500, turn_id="t"),
                         event("item_completed", -1, turn_id="different")])
        self.assertEqual(row["activitySignal"], "stale_unknown")

    def test_invalid_item_turn_identifier_is_ignored(self):
        row = self.read([meta(), event("task_started", -500, turn_id="t"),
                         event("item_completed", -1, turn_id=[])])
        self.assertEqual(row["activitySignal"], "stale_unknown")

    def test_completion_closes_only_matching_turn(self):
        row = self.read([meta(), event("task_started", -10, turn_id="a"),
                         event("task_started", -5, turn_id="b"),
                         event("task_complete", -1, turn_id="a")])
        self.assertEqual(row["activitySignal"], "recent_unclosed_turn")
        self.assertEqual(row["openTurnSignals"], 1)

    def test_interruption_is_terminal(self):
        row = self.read([meta(), event("task_started", -10, turn_id="a"),
                         event("turn_aborted", -1, turn_id="a", reason="interrupted")])
        self.assertEqual(row["activitySignal"], "terminal_observed")

    def test_failure_is_terminal_and_message_not_exposed(self):
        row = self.read([meta(), event("task_started", -10, turn_id="a"),
                         event("task_complete", -1, turn_id="a",
                               error={"message": "PRIVATE MESSAGE"})])
        self.assertEqual(row["activitySignal"], "terminal_observed")
        self.assertNotIn("PRIVATE MESSAGE", json.dumps(row))

    def test_fork_ignores_parent_identity_and_unclosed_turn(self):
        row = self.read([meta(parent_thread_id="parent", subagent_history_start_ordinal=2),
                         meta(id="copied-parent", creator_account_id="wrong-account"),
                         event("task_started", -60, turn_id="parent-turn"),
                         event("task_started", -10, turn_id="own-turn"),
                         event("task_complete", -1, turn_id="own-turn")])
        self.assertEqual(row["activitySignal"], "terminal_observed")
        self.assertEqual(row["openTurnSignals"], 0)
        self.assertEqual(row["inheritedEventsIgnored"], 1)
        plain = self.read([meta()])
        self.assertEqual(row["recordedIdentityKey"], plain["recordedIdentityKey"])

    def test_child_without_history_boundary_is_unknown(self):
        row = self.read([meta(parent_thread_id="parent"),
                         event("task_started", -1, turn_id="t"), quota()])
        self.assertEqual(row["activitySignal"], "unknown")
        self.assertTrue(row["unsupportedChildHistory"])
        self.assertEqual(row["quotaBuckets"], {})

    def test_partial_line_is_waited_for_and_not_counted_twice(self):
        path = self.write([meta(), event("task_started", -10, turn_id="t")],
                          suffix=b'{"type":"event_msg","payload":')
        partial = read_rollout(path, NOW, 120)
        self.assertGreater(partial["pendingLineBytes"], 0)
        with path.open("ab") as f:
            f.write(b'{"type":"task_complete","turn_id":"t"}}\n')
        complete = read_rollout(path, NOW, 120)
        self.assertEqual(complete["activitySignal"], "terminal_observed")
        self.assertEqual(complete["pendingLineBytes"], 0)
        self.assertEqual(complete["eventTypes"]["task_started"], 1)

    def test_malformed_completed_line_makes_liveness_uncertain(self):
        row = self.read([meta(), event("task_started", -1, turn_id="t")], suffix=b"bad\n")
        self.assertEqual(row["malformedRecords"], 1)
        self.assertEqual(row["activitySignal"], "unknown")

    def test_missing_turn_id_cannot_close_an_arbitrary_task(self):
        row = self.read([meta(), event("task_started", -10, turn_id="t"),
                         event("task_complete", -1)])
        self.assertEqual(row["openTurnSignals"], 1)
        self.assertEqual(row["activitySignal"], "unknown")

    def test_quota_uses_event_time_and_survives_null_update(self):
        row = self.read([meta(), quota(-30, 20), quota(-20, 31),
                         event("token_count", -1, rate_limits=None)])
        q = row["quotaBuckets"]["codex"]
        self.assertEqual(q["ageSeconds"], 20)
        self.assertEqual(q["windows"]["primary"]["remainingPercentAtObservation"], 69)

    def test_expired_reset_does_not_invent_full_quota(self):
        row = self.read([meta(), quota(-30, 100, primary={
            "used_percent": 100, "window_minutes": 300, "resets_at": NOW - 1})])
        win = row["quotaBuckets"]["codex"]["windows"]["primary"]
        self.assertTrue(win["resetHasPassed"])
        self.assertEqual(win["remainingPercentAtObservation"], 0)

    def test_invalid_percentage_does_not_become_zero_usage(self):
        for used in [None, -1, 101, "12", True, float("nan"), 10**400]:
            with self.subTest(used=used):
                row = self.read([meta(), quota(used=used)])
                self.assertEqual(row["quotaBuckets"], {})

    def test_distinct_accounts_and_buckets_stay_separate(self):
        self.write([meta(), quota(-20), quota(-10, bucket="other")], "a.jsonl")
        self.write([meta(creator_account_id="account-b"), quota(-1)], "b.jsonl")
        report = inspect(self.root, NOW)
        self.assertEqual(len(report["quotaGroups"]), 3)
        self.assertIsNone(report["authoritativeLiveAgentCount"])

    def test_missing_identity_is_not_merged_across_files(self):
        for name in ["a.jsonl", "b.jsonl"]:
            self.write([meta(creator_account_id=None), quota()], name)
        self.assertEqual(len(inspect(self.root, NOW)["quotaGroups"]), 2)

    def test_missing_directory_reports_access_error(self):
        report = inspect(self.root / "missing", NOW)
        self.assertEqual(report["access"], "partial_or_denied")
        self.assertTrue(report["errors"])

    def test_symlinks_cannot_read_outside_selected_directory(self):
        external = Path(self.temp.name) / "auth.json"
        external.write_text('PRIVATE CREDENTIAL SENTINEL\n')
        (self.root / "linked.jsonl").symlink_to(external)
        report = inspect(self.root, NOW)
        self.assertEqual(report["recordCount"], 0)
        self.assertNotIn("PRIVATE CREDENTIAL", json.dumps(report))

    def test_output_excludes_messages_and_tool_arguments(self):
        row = self.read([meta(base_instructions="PRIVATE INSTRUCTIONS"),
                         record("response_item", {"arguments": "PRIVATE TOOL"}),
                         event("task_complete", -1, turn_id="t",
                               last_agent_message="PRIVATE ANSWER")])
        self.assertNotIn("PRIVATE", json.dumps(row))


if __name__ == "__main__":
    unittest.main()
