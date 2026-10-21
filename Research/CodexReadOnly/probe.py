#!/usr/bin/env python3
"""Research only: inspect local rollout evidence without contacting Codex.

Reads JSONL under one sessions directory. Does not read auth/config, connect to
App Server, modify Codex files, or output conversations/tool arguments.
The resulting activity signals are NOT authoritative live-agent statuses.
"""

import argparse
import collections
import hashlib
import json
import math
from datetime import datetime, timezone
from pathlib import Path


def fingerprint(value):
    return hashlib.sha256(str(value).encode()).hexdigest()[:16]


def timestamp(value):
    if not isinstance(value, str):
        return None
    try:
        result = datetime.fromisoformat(value.replace("Z", "+00:00"))
        return result.timestamp() if result.tzinfo is not None else None
    except (ValueError, OverflowError):
        return None


def number(value):
    try:
        return (isinstance(value, (int, float)) and not isinstance(value, bool)
                and math.isfinite(value))
    except OverflowError:
        return False


def window(raw, now):
    if not isinstance(raw, dict):
        return None
    used = raw.get("used_percent")
    if not number(used) or not 0 <= used <= 100:
        return None
    reset = raw.get("resets_at")
    reset = reset if number(reset) and reset > 0 else None
    duration = raw.get("window_minutes")
    duration = duration if number(duration) and duration > 0 else None
    return {
        "usedPercentAtObservation": used,
        "remainingPercentAtObservation": 100 - used,
        "windowMinutes": duration,
        "resetsAt": reset,
        # Passing a reset timestamp never proves that quota was replenished.
        "resetHasPassed": reset is not None and reset <= now,
    }


def read_rollout(path, now, stale_seconds):
    snapshot_now = datetime.now(timezone.utc).timestamp() if now is None else now
    metadata = None
    cutoff = -1
    inherited = 0
    malformed = 0
    pending_bytes = 0
    event_types = collections.Counter()
    open_turns = set()
    latest_lifecycle = None
    last_activity = None
    terminal_at = None
    quotas = {}
    identity = None
    child = False
    unsupported_child_history = False
    history_uncertain = False
    saw_terminal = False

    # Ordinals are physical JSONL line ordinals, including non-event records.
    with path.open("rb") as handle:
        for ordinal, line in enumerate(handle):
            if not line.endswith(b"\n"):
                pending_bytes = len(line)
                break
            try:
                record = json.loads(line)
            except (ValueError, UnicodeDecodeError):
                malformed += 1
                history_uncertain = True
                continue
            if not isinstance(record, dict):
                malformed += 1
                history_uncertain = True
                continue
            payload = record.get("payload")
            if not isinstance(payload, dict):
                continue
            if record.get("type") == "session_meta":
                if metadata is not None:
                    # Forks contain additional copies of the parent's metadata.
                    continue
                metadata = payload
                source = payload.get("source")
                child = payload.get("parent_thread_id") is not None or (
                    isinstance(source, dict) and "subagent" in source)
                boundary = payload.get("subagent_history_start_ordinal")
                if child and type(boundary) is int and boundary >= 0:
                    cutoff = boundary
                elif child:
                    unsupported_child_history = True
                account = payload.get("creator_account_id")
                user = payload.get("creator_user_id")
                # Missing identity stays isolated by file; never merges accounts.
                identity = fingerprint([account, user]) if account and user else None
                continue
            if record.get("type") != "event_msg":
                continue
            if metadata is None:
                history_uncertain = True
                continue
            if ordinal <= cutoff:
                inherited += 1
                continue
            if unsupported_child_history:
                continue
            kind = payload.get("type")
            if not isinstance(kind, str):
                continue
            event_types[kind] += 1
            at = timestamp(record.get("timestamp"))
            turn = payload.get("turn_id")
            work_event = (kind in ("task_started", "task_complete", "turn_aborted")
                          or (kind == "token_count" and bool(open_turns))
                          or (kind == "item_completed" and isinstance(turn, str)
                              and turn in open_turns))
            if at is not None and work_event:
                last_activity = max(at, last_activity or at)
            if kind == "task_started":
                latest_lifecycle = kind
                if isinstance(turn, str) and turn:
                    open_turns.add(turn)
                else:
                    history_uncertain = True
            elif kind in ("task_complete", "turn_aborted"):
                latest_lifecycle = kind
                saw_terminal = True
                terminal_at = at
                if isinstance(turn, str) and turn:
                    open_turns.discard(turn)
                else:
                    # An unattributed completion cannot close some other turn.
                    history_uncertain = True
            if kind != "token_count" or at is None:
                continue
            raw = payload.get("rate_limits")
            if not isinstance(raw, dict):
                continue
            windows = {k: window(raw.get(k), snapshot_now) for k in ("primary", "secondary")}
            windows = {k: v for k, v in windows.items() if v is not None}
            if not windows:
                continue
            bucket = raw.get("limit_id")
            bucket = bucket if isinstance(bucket, str) and bucket else "unlabelled"
            snapshot = {"observedAt": at, "windows": windows}
            if at >= quotas.get(bucket, {}).get("observedAt", -1):
                quotas[bucket] = snapshot

    # Read-time writes may be a few milliseconds newer than the scan start.
    # Use the end of this read for live scans; fixtures supply a fixed clock.
    now = datetime.now(timezone.utc).timestamp() if now is None else now
    for snapshot in quotas.values():
        snapshot["ageSeconds"] = max(0, now - snapshot["observedAt"])
        if snapshot["observedAt"] > now:
            snapshot["clockSkew"] = True
        for value in snapshot["windows"].values():
            value["resetHasPassed"] = (value["resetsAt"] is not None
                                       and value["resetsAt"] <= now)
    signal = "unknown"
    if metadata is not None and not unsupported_child_history and not history_uncertain:
        if open_turns and last_activity is not None and last_activity <= now:
            signal = ("recent_unclosed_turn" if now - last_activity <= stale_seconds
                      else "stale_unknown")
        elif not open_turns and saw_terminal:
            signal = "terminal_observed"
    return {
        "recordKey": fingerprint(str(path)),
        "cliVersion": metadata.get("cli_version") if metadata else None,
        "isSubagent": child,
        "recordedIdentityKey": identity,
        "identitySource": "recorded_creator_metadata" if identity else "unattributed",
        "activitySignal": signal,
        "authoritativeLiveStatus": False,
        "approvalState": "unavailable",
        "openTurnSignals": len(open_turns),
        "lastActivityAt": last_activity,
        "lastTerminalAt": terminal_at,
        "lastLifecycleEvent": latest_lifecycle,
        "inheritedEventsIgnored": inherited,
        "unsupportedChildHistory": unsupported_child_history,
        "malformedRecords": malformed,
        "pendingLineBytes": pending_bytes,
        "eventTypes": dict(event_types),
        "quotaBuckets": quotas,
    }


def inspect(sessions, now=None, stale_seconds=120):
    root = Path(sessions).expanduser()
    rows = []
    errors = []
    try:
        # Unlike rglob on some Python versions, directory failures are explicit.
        def visit(folder):
            for entry in folder.iterdir():
                if entry.is_symlink():
                    continue
                if entry.is_dir():
                    yield from visit(entry)
                elif entry.suffix == ".jsonl" and entry.is_file():
                    yield entry
        for path in sorted(visit(root)):
            try:
                rows.append(read_rollout(path, now, stale_seconds))
            except OSError as error:
                errors.append({"recordKey": fingerprint(str(path)), "errno": error.errno})
    except OSError as error:
        errors.append({"scope": "discovery", "errno": error.errno})
    now = datetime.now(timezone.utc).timestamp() if now is None else now
    groups = {}
    for row in rows:
        group = row["recordedIdentityKey"] or "unattributed-" + row["recordKey"]
        for bucket, quota in row["quotaBuckets"].items():
            key = group + ":" + bucket
            if quota["observedAt"] >= groups.get(key, {}).get("observedAt", -1):
                groups[key] = dict(quota, identitySource=row["identitySource"], bucket=bucket)
    return {
        "generatedAt": now,
        "access": "partial_or_denied" if errors else "readable",
        "method": "local_rollout_evidence_only",
        "authoritativeLiveAgentCount": None,
        "recordCount": len(rows),
        "activitySignals": dict(collections.Counter(r["activitySignal"] for r in rows)),
        "inheritedEventsIgnored": sum(r["inheritedEventsIgnored"] for r in rows),
        "quotaGroups": groups,
        "errors": errors,
        "records": rows,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sessions", required=True, type=Path,
                        help="Explicit sessions directory; no auth/config discovery")
    parser.add_argument("--stale-seconds", type=float, default=120,
                        help="Research heuristic only; not proof of a crashed agent")
    args = parser.parse_args()
    if not math.isfinite(args.stale_seconds) or args.stale_seconds <= 0:
        parser.error("--stale-seconds must be positive and finite")
    report = inspect(args.sessions, stale_seconds=args.stale_seconds)
    print(json.dumps(report, ensure_ascii=False, indent=2, allow_nan=False))
    return 1 if report["errors"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
