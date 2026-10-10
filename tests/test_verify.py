import importlib.util
import json
import pathlib
import unittest
from unittest import mock

spec = importlib.util.spec_from_file_location(
    "verify", pathlib.Path(__file__).resolve().parents[1] / "scripts" / "verify.py"
)
verify = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verify)


class CounterAssertionsTest(unittest.TestCase):
    def test_preserved_memory_and_filesystem(self):
        result = verify.parse_counter(
            "hello from: 10.244.0.1 | preserved memory count: 6 | preserved file counter: 6\n", 6
        )
        self.assertEqual((result["memoryCount"], result["fileCount"]), (6, 6))

    def test_memory_reset_fails(self):
        with self.assertRaisesRegex(RuntimeError, "State continuity failure"):
            verify.parse_counter(
                "hello from: 10.244.0.1 | preserved memory count: 1 | preserved file counter: 6\n", 6
            )

    def test_filesystem_reset_fails(self):
        with self.assertRaisesRegex(RuntimeError, "State continuity failure"):
            verify.parse_counter(
                "hello from: 10.244.0.1 | preserved memory count: 6 | preserved file counter: 1\n", 6
            )

    def test_wrong_count_fails(self):
        with self.assertRaisesRegex(RuntimeError, "State continuity failure"):
            verify.parse_counter(
                "hello from: 10.244.0.1 | preserved memory count: 7 | preserved file counter: 7\n", 6
            )

    def test_success_shaped_malformed_response_fails(self):
        with self.assertRaisesRegex(RuntimeError, "Unexpected counter response"):
            verify.parse_counter("ok", 6)

    def test_crashed_actor_fails_immediately(self):
        with mock.patch.object(verify, "actor_status", return_value={"state": "ACTOR_STATE_CRASHED"}):
            with self.assertRaisesRegex(RuntimeError, "Actor crashed"):
                verify.wait_state("test", "ACTOR_STATE_SUSPENDED")

    def test_suspend_requires_a_durable_detached_snapshot(self):
        with mock.patch.object(verify, "run"), mock.patch.object(
            verify, "wait_state", return_value={"state": "ACTOR_STATE_SUSPENDED"}
        ):
            with self.assertRaisesRegex(RuntimeError, "lacks a detached durable snapshot"):
                verify.suspend("test")

    def test_public_application_service_fails(self):
        pod = {
            "metadata": {"name": "healthy"},
            "status": {
                "phase": "Running",
                "conditions": [{"type": "Ready", "status": "True"}],
            },
        }
        service = {"metadata": {"name": "public"}, "spec": {"type": "LoadBalancer"}}
        with mock.patch.object(verify, "run", side_effect=[
            json.dumps({"items": [pod]}), json.dumps({"items": [service]}),
        ]):
            with self.assertRaisesRegex(RuntimeError, "Public application service"):
                verify.health()


if __name__ == "__main__":
    unittest.main()
