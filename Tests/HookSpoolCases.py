"""Common regressions for the spool implementation shipped by both helpers."""
import json
import os
import stat
import time
import uuid


class HookSpoolCases:
    @property
    def checkpoint(self):
        return self.spool / ".spool-state-v1"

    def saved_checkpoint(self):
        return json.loads(self.checkpoint.read_text())

    def test_warm_spool_reuses_cleanup_across_processes(self):
        self.invoke(self.payload("Stop"))
        first = self.saved_checkpoint()
        for _ in range(4):
            self.invoke(self.payload("Stop"))
        saved = self.saved_checkpoint()
        self.assertEqual(saved["cleanedAt"], first["cleanedAt"])
        self.assertEqual(saved["count"], 5)
        self.assertEqual(stat.S_IMODE(self.checkpoint.stat().st_mode), 0o600)
        self.assertLess(self.checkpoint.stat().st_size, 1024)

    def test_age_cleanup_expires_and_clock_rollback_reconciles(self):
        self.invoke(self.payload("Stop"))
        event = next(self.spool.glob("*.json"))
        old = time.time() - 8 * 24 * 3600
        # Changing a child's mtime leaves the directory stamp intact. A warm
        # append should defer the full age sweep until the interval expires.
        os.utime(event, (old, old))
        self.invoke(self.payload("Stop"))
        self.assertTrue(event.exists())
        saved = self.saved_checkpoint()
        saved["cleanedAt"] = time.time() - 61
        self.checkpoint.write_text(json.dumps(saved))
        self.invoke(self.payload("Stop"))
        self.assertFalse(event.exists())
        self.assertEqual(self.saved_checkpoint()["count"], 2)
        saved = self.saved_checkpoint()
        saved["cleanedAt"] = time.time() + 3600
        self.checkpoint.write_text(json.dumps(saved))
        self.invoke(self.payload("Stop"))
        self.assertLess(self.saved_checkpoint()["cleanedAt"], saved["cleanedAt"])
        self.assertEqual(self.saved_checkpoint()["count"], 3)

    def test_outside_changes_and_corrupt_checkpoint_trigger_recovery(self):
        self.invoke(self.payload("Stop"))
        stale = self.spool / f"{uuid.uuid4()}.json"
        stale.write_text("{}")
        old = time.time() - 8 * 24 * 3600
        os.utime(stale, (old, old))
        self.invoke(self.payload("Stop"))
        self.assertFalse(stale.exists())
        self.assertEqual(self.saved_checkpoint()["count"], 2)
        self.checkpoint.write_text("partial checkpoint")
        self.invoke(self.payload("Stop"))
        self.assertEqual(self.saved_checkpoint()["count"], 3)

    def test_unsafe_checkpoint_is_untouched_and_delivery_continues(self):
        target = self.spool.parent / "checkpoint-target"
        target.write_text("preserve user contents")
        target.chmod(0o600)
        for kind in ("symlink", "hardlink", "shared", "oversized", "fifo"):
            with self.subTest(kind=kind):
                if kind == "symlink":
                    self.checkpoint.symlink_to(target)
                elif kind == "hardlink":
                    os.link(target, self.checkpoint)
                elif kind == "fifo":
                    os.mkfifo(self.checkpoint, 0o600)
                else:
                    self.checkpoint.write_text("x" * (1025 if kind == "oversized" else 10))
                    self.checkpoint.chmod(0o644 if kind == "shared" else 0o600)
                self.invoke(self.payload("Stop"))
                self.assertEqual(target.read_text(), "preserve user contents")
                if kind == "shared":
                    self.assertEqual(self.checkpoint.read_text(), "x" * 10)
                elif kind == "oversized":
                    self.assertEqual(self.checkpoint.stat().st_size, 1025)
                elif kind == "fifo":
                    self.assertTrue(stat.S_ISFIFO(self.checkpoint.lstat().st_mode))
                self.checkpoint.unlink()
        self.assertEqual(len(list(self.spool.glob("*.json"))), 5)

    def test_capacity_cleanup_preserves_newest_and_leaves_headroom(self):
        now = time.time()
        oldest = self.spool / f"{uuid.uuid4()}.json"
        newest = self.spool / f"{uuid.uuid4()}.json"
        for index in range(4095):
            path = oldest if index == 0 else newest if index == 4094 else self.spool / f"{uuid.uuid4()}.json"
            path.write_text("{}")
            stamp = now - 10_000 + index
            os.utime(path, (stamp, stamp))
        self.invoke(self.payload("Stop"))
        self.assertEqual(len(list(self.spool.glob("*.json"))), 4096)
        self.invoke(self.payload("Stop"))
        self.assertEqual(len(list(self.spool.glob("*.json"))), 3073)
        self.assertFalse(oldest.exists())
        self.assertTrue(newest.exists())
        saved = self.saved_checkpoint()
        self.invoke(self.payload("Stop"))
        self.assertEqual(self.saved_checkpoint()["cleanedAt"], saved["cleanedAt"])
        self.assertEqual(self.saved_checkpoint()["count"], 3074)
