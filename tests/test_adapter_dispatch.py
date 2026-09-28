#!/usr/bin/env python3
"""Regression tests for the Sendspin adapter dispatch contract.

Exercises `select_action` and `main` with the three Sendspin hook
invocation contracts, plus the legacy/manual paths. Does not touch the
real Yamaha controller: `http_post`/`http_get` are stubbed in-memory.

Run directly:
    python3 tests/test_adapter_dispatch.py

Or via the shell wrapper:
    bash tests/smoke-dispatch.sh
"""

from __future__ import annotations

import json
import os
import runpy
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

REPO_ROOT = Path(__file__).resolve().parent.parent
ADAPTER = REPO_ROOT / "adapters" / "sendspin" / "yas207-sendspin"
EXAMPLE_CONFIG = REPO_ROOT / "examples" / "profiles" / "analogue-sendspin.json"


def _load_adapter_module() -> dict:
    """Load the adapter as a runpy module dict so tests can introspect symbols."""
    # `run_name` must NOT be "__main__", otherwise the adapter's bottom
    # `if __name__ == "__main__": sys.exit(main(sys.argv))` block would fire
    # at import time and try to talk to a real controller.
    return runpy.run_path(str(ADAPTER), run_name="yas207_sendspin_module")


class _AdapterHarness:
    """Context manager that loads the adapter, isolates env/runtime, and
    stubs the controller's HTTP layer so `main()` does not need a real
    controller. Returns the loaded module dict."""

    def __init__(self) -> None:
        self._tmpdir_ctx = tempfile.TemporaryDirectory()
        self._tmpdir = Path(self._tmpdir_ctx.name)
        self._env_backup = {
            k: os.environ.get(k) for k in (
                "YAS207_CONFIG", "YAS207_RUNTIME_DIR", "SENDSPIN_EVENT",
            )
        }
        self._rt = self._tmpdir / "runtime"
        self._rt.mkdir()
        os.environ["YAS207_CONFIG"] = str(EXAMPLE_CONFIG)
        os.environ["YAS207_RUNTIME_DIR"] = str(self._rt)
        # Force a clean env for dispatch tests; tests set/unset per-case.
        os.environ.pop("SENDSPIN_EVENT", None)
        self.module = _load_adapter_module()
        # `runpy.run_path` returns a *new* dict, NOT the real module dict
        # that the adapter functions use as their globals. Patching
        # `self.module` would not affect what `main()` sees. We must patch
        # the dict that the functions actually look symbols up in.
        self.globals = self.module["main"].__globals__
        # Stub controller HTTP layer.
        self.calls: list[tuple[str, dict, str]] = []
        self._orig_post = self.globals["http_post"]
        self._orig_get = self.globals["http_get"]

        def fake_post(cfg, path, data, timeout=5.0):
            self.calls.append((path, dict(data), "POST"))
            # Mimic the upstream /start-session success.
            if path == "/start-session":
                return 200, json.dumps({"ok": True})
            if path == "/stop-session":
                return 200, json.dumps({"ok": True})
            return 200, json.dumps({"ok": True})

        def fake_get(cfg, path, timeout=5.0):
            self.calls.append((path, {}, "GET"))
            return 200, json.dumps({
                "session": {"active": False, "restoring": False},
            })

        self.globals["http_post"] = fake_post
        self.globals["http_get"] = fake_get

    def __enter__(self) -> "_AdapterHarness":
        return self

    def __exit__(self, exc_type=None, exc=None, tb=None) -> None:
        os.environ.update({k: v for k, v in self._env_backup.items() if v is not None})
        for k in ("YAS207_CONFIG", "YAS207_RUNTIME_DIR", "SENDSPIN_EVENT"):
            os.environ.pop(k, None)
        self._tmpdir_ctx.cleanup()

    def close(self) -> None:
        self.__exit__()


class SelectActionContractTests(unittest.TestCase):
    """Dispatch-table coverage for `select_action`."""

    def setUp(self) -> None:
        self.h = _AdapterHarness()
        self.h.__enter__()
        self.select = self.h.module["select_action"]
        self.addCleanup(self.h.__exit__)

    def _select(self, argv, event=None):
        if event is None:
            os.environ.pop("SENDSPIN_EVENT", None)
        else:
            os.environ["SENDSPIN_EVENT"] = event
        return self.select(argv)

    def test_sendspin_event_start(self):
        action, raw = self._select(["script"], event="start")
        self.assertEqual(action, "start")
        self.assertIsNone(raw)

    def test_sendspin_event_stop(self):
        action, raw = self._select(["script"], event="stop")
        self.assertEqual(action, "stop")
        self.assertIsNone(raw)

    def test_sendspin_event_set_volume_with_arg(self):
        action, raw = self._select(["script", "24"], event="set-volume")
        self.assertEqual(action, "set_volume")
        self.assertEqual(raw, "24")

    def test_sendspin_event_set_volume_without_arg(self):
        # Acceptable: set-volume form WITHOUT a positional arg still selects
        # the action; `cmd_volume` will raise later if raw_value is missing.
        action, raw = self._select(["script"], event="set-volume")
        self.assertEqual(action, "set_volume")
        self.assertIsNone(raw)

    def test_bare_integer_argv_is_set_volume(self):
        # This is the HookVolumeController production form.
        action, raw = self._select(["script", "24"])
        self.assertEqual(action, "set_volume")
        self.assertEqual(raw, "24")

    def test_explicit_volume_keyword_still_works(self):
        action, raw = self._select(["script", "volume", "24"])
        self.assertEqual(action, "set_volume")
        self.assertEqual(raw, "24")

    def test_cleanup_token_still_works(self):
        action, raw = self._select(["script", "cleanup", "abc123"])
        self.assertEqual(action, "cleanup")
        self.assertEqual(raw, "abc123")

    def test_malformed_bare_argv_rejected(self):
        with self.assertRaises(SystemExit) as cm:
            self._select(["script", "not-a-number"])
        self.assertEqual(cm.exception.code, 2)

    def test_bare_argv_with_extra_args_rejected(self):
        # More than two args + non-keyword -> reject (no silent acceptance).
        with self.assertRaises(SystemExit) as cm:
            self._select(["script", "24", "extra"])
        self.assertEqual(cm.exception.code, 2)

    def test_volume_keyword_without_value_rejected(self):
        with self.assertRaises(SystemExit) as cm:
            self._select(["script", "volume"])
        self.assertEqual(cm.exception.code, 2)

    def test_cleanup_without_token_rejected(self):
        with self.assertRaises(SystemExit) as cm:
            self._select(["script", "cleanup"])
        self.assertEqual(cm.exception.code, 2)

    def test_no_args_rejected(self):
        with self.assertRaises(SystemExit) as cm:
            self._select(["script"])
        self.assertEqual(cm.exception.code, 2)

    def test_unknown_event_rejected(self):
        with self.assertRaises(SystemExit) as cm:
            self._select(["script"], event="frobnicate")
        self.assertEqual(cm.exception.code, 2)

    def test_event_takes_precedence_over_argv(self):
        # If SENDSPIN_EVENT is set, argv keyword forms are ignored.
        action, raw = self._select(["script", "volume", "24"], event="start")
        self.assertEqual(action, "start")
        self.assertIsNone(raw)


class MainVolumeDispatchTests(unittest.TestCase):
    """End-to-end: both set-volume invocation forms reach the same
    /send intent and update adapter state."""

    def setUp(self) -> None:
        self.h = _AdapterHarness()
        self.h.__enter__()
        self.main = self.h.module["main"]
        self.addCleanup(self.h.__exit__)

    def _open_session(self):
        os.environ["SENDSPIN_EVENT"] = "start"
        rc = self.main(["script"])
        self.assertEqual(rc, 0, "start should succeed with mocked controller")
        # Drop the start event so volume calls don't see it.
        os.environ.pop("SENDSPIN_EVENT", None)

    def test_bare_integer_form_and_explicit_keyword_form_produce_same_intent(self):
        self._open_session()
        # Form A: HookVolumeController production form.
        os.environ.pop("SENDSPIN_EVENT", None)
        self.h.calls.clear()
        rc_a = self.main(["script", "24"])
        # Form B: explicit legacy/manual form.
        rc_b = self.main(["script", "volume", "24"])
        self.assertEqual(rc_a, 0)
        self.assertEqual(rc_b, 0)
        # Both should produce at least one /send call carrying the volume intent.
        send_intents = [data for path, data, m in self.h.calls if path == "/send"]
        self.assertEqual(len(send_intents), 2, "expected two /send calls")
        # /send's data['intent'] is a JSON string of the actual intent dict.
        intent_a = json.loads(send_intents[0]["intent"])
        intent_b = json.loads(send_intents[1]["intent"])
        self.assertEqual(intent_a, intent_b)
        # And that intent is exactly the volume-mapping for MA=24% under the
        # active config's max_raw policy. Compute expected dynamically so
        # this test passes against any installation ceiling.
        cfg = json.loads(EXAMPLE_CONFIG.read_text())
        max_raw = cfg["volume"]["max_raw"]
        expected_volume = round(24 * max_raw / 100)
        self.assertEqual(intent_a.get("mute"), False)
        self.assertEqual(intent_a.get("volume"), expected_volume)

    def test_out_of_range_volume_rejected(self):
        # cmd_volume clamps to 0..100 internally; "abc" is rejected by cmd_volume.
        os.environ.pop("SENDSPIN_EVENT", None)
        with self.assertRaises(SystemExit) as cm:
            self.main(["script", "abc"])
        self.assertEqual(cm.exception.code, 2)


class SpawnCleanupEnvTests(unittest.TestCase):
    """Regression: spawn_cleanup() must NOT pass SENDSPIN_EVENT to the child.

    The cleanup child is an internal invocation, not a Sendspin hook. If it
    inherits $SENDSPIN_EVENT from the parent stop-hook invocation,
    select_action dispatches it back to cmd_stop, which spawns yet another
    cleanup child -> fork-bomb of cleanup processes, no cleanup ever commits.
    """

    def setUp(self) -> None:
        self.h = _AdapterHarness()
        self.h.__enter__()
        self.spawn_cleanup = self.h.module["spawn_cleanup"]
        self.globals = self.h.globals
        self.addCleanup(self.h.__exit__)

    def _spawn_capture(self, token):
        """Run spawn_cleanup() but intercept subprocess.Popen so we can
        inspect the argv + env it would have launched."""
        captured = {}

        real_popen = self.globals["subprocess"].Popen

        def fake_popen(argv, *args, **kwargs):
            captured["argv"] = list(argv)
            captured["env"] = dict(kwargs.get("env", {}))
            captured["kwargs"] = {k: v for k, v in kwargs.items() if k != "env"}
            # Don't actually fork; return a no-op handle.
            class _Noop:
                def wait(self_inner, *_a, **_k): return 0
                def poll(self_inner): return 0
            return _Noop()

        self.globals["subprocess"].Popen = fake_popen
        try:
            # Set up a realistic stop-hook parent environment.
            os.environ["SENDSPIN_EVENT"] = "stop"
            os.environ["SENDSPIN_SERVER_NAME"] = "Music Assistant (media)"
            os.environ["YAS207_CONFIG"] = str(EXAMPLE_CONFIG)
            self.spawn_cleanup(token, self.h.module["Log"](self.h._rt / "yas207-sendspin.log"))
        finally:
            self.globals["subprocess"].Popen = real_popen
            os.environ.pop("SENDSPIN_EVENT", None)
        return captured

    def test_cleanup_child_has_no_sendspin_event(self):
        captured = self._spawn_capture("test-token-abc")
        self.assertIn("env", captured)
        self.assertNotIn(
            "SENDSPIN_EVENT", captured["env"],
            "spawn_cleanup must strip SENDSPIN_EVENT to prevent cleanup -> "
            "stop recursion",
        )

    def test_cleanup_child_argv_is_cleanup_token(self):
        captured = self._spawn_capture("test-token-xyz")
        # argv[-2:] should be ["cleanup", "test-token-xyz"] (after python exe).
        argv = captured["argv"]
        self.assertEqual(argv[-2], "cleanup")
        self.assertEqual(argv[-1], "test-token-xyz")

    def test_cleanup_child_preserves_other_env(self):
        # Pre-existing env vars other than SENDSPIN_EVENT must be preserved.
        os.environ["SENDSPIN_SERVER_NAME"] = "Music Assistant (media)"
        os.environ["YAS207_CONFIG"] = str(EXAMPLE_CONFIG)
        os.environ["PATH"] = "/usr/bin"
        try:
            captured = self._spawn_capture("tkn")
            env = captured["env"]
            self.assertEqual(env.get("SENDSPIN_SERVER_NAME"), "Music Assistant (media)")
            self.assertEqual(env.get("YAS207_CONFIG"), str(EXAMPLE_CONFIG))
            self.assertEqual(env.get("PATH"), "/usr/bin")
            self.assertNotIn("SENDSPIN_EVENT", env)
        finally:
            for k in ("SENDSPIN_SERVER_NAME", "YAS207_CONFIG", "PATH"):
                os.environ.pop(k, None)

    def test_spawn_cleanup_uses_start_new_session(self):
        captured = self._spawn_capture("tkn")
        self.assertTrue(captured["kwargs"].get("start_new_session"))
        self.assertTrue(captured["kwargs"].get("close_fds"))

    def test_spawn_cleanup_without_parent_sendpin_event(self):
        # Defensive: even when the parent has NO SENDSPIN_EVENT (e.g. some
        # future non-Sendspin caller), the child env must still be safe.
        os.environ.pop("SENDSPIN_EVENT", None)
        captured = self._spawn_capture("tkn")
        self.assertNotIn("SENDSPIN_EVENT", captured["env"])


def main() -> int:
    suite = unittest.defaultTestLoader.loadTestsFromModule(sys.modules[__name__])
    runner = unittest.TextTestRunner(verbosity=2)
    result = runner.run(suite)
    return 0 if result.wasSuccessful() else 1


if __name__ == "__main__":
    sys.exit(main())