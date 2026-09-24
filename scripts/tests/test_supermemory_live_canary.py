import contextlib
import copy
import importlib.util
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("canary", Path(__file__).parents[1] / "supermemory_live_canary.py")
c = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(c)


class FakeVendor:
    """Protocol fixture, not vendor lifecycle evidence. No network calls."""
    def __init__(self, state):
        self.calls, self.docs, self.keys, self.retained = [], {}, {}, {}
        self.empty_search = self.leak = self.lost_create = self.retain_memory = self.bad_cleanup = False
        self.early = next(d["custom"] for d in state["documents"] if d.get("early_delete"))
        self.created_count = 0

    @staticmethod
    def matches(filters, metadata):
        if "AND" in filters: return all(FakeVendor.matches(x, metadata) for x in filters["AND"])
        if "OR" in filters: return any(FakeVendor.matches(x, metadata) for x in filters["OR"])
        return metadata.get(filters["key"]) == filters["value"]

    def request(self, method, path, credential, body=None):
        self.calls.append((method, path, credential, copy.deepcopy(body)))
        if path == "/v3/auth/scoped-key":
            number = len(self.keys) + 1
            secret, kid = "SECRET_TEST_" + str(number), "key_" + str(number)
            self.keys[secret] = (kid, body["containerTag"])
            return 200, {"key": secret, "id": kid, "containerTag": body["containerTag"]}
        if path.startswith("/v3/auth/scoped-key/"):
            kid = path.rsplit("/", 1)[1]
            self.keys = {k: v for k, v in self.keys.items() if v[0] != kid}
            return 200, {"success": True}
        tag = self.keys.get(credential, (None, None))[1]
        def permitted(target): return credential == "MASTER_TEST" or tag == target
        if path == "/v3/documents" and method == "POST":
            if not permitted(body["containerTag"]): return 403, {}
            self.created_count += 1
            did = "document_" + str(self.created_count)
            value = {"id": did, "customId": body["customId"], "metadata": body["metadata"],
                     "containerTags": [body["containerTag"]], "status": "done", "dreamingStatus": "done",
                     "memories": [{"id": "memory_" + did}]}
            if body["customId"] == self.early: value["status"] = "queued"
            self.docs[did] = value
            if self.lost_create: raise c.ProbeError("transport_or_json_failure")
            return 200, {"id": did, "status": "queued"}
        if path == "/v3/documents/list":
            return 200, {"memories": [d for d in self.docs.values() if d["containerTags"] == body["containerTags"]
                and self.matches(body["filters"], d["metadata"])], "pagination": {"totalPages": 1}}
        if path.startswith("/v3/documents/"):
            did = path.rsplit("/", 1)[1]
            if did not in self.docs: return 404, {}
            doc = self.docs[did]
            if not permitted(doc["containerTags"][0]): return 403, {}
            if method == "GET": return 200, copy.deepcopy(doc)
            if self.bad_cleanup: raise c.ProbeError("cleanup_transport_failure")
            if self.retain_memory: self.retained[did] = copy.deepcopy(doc)
            del self.docs[did]
            return 204, {}
        if path == "/v3/search":
            if not permitted(body["containerTag"]): return 403, {}
            docs = [d for d in self.docs.values() if d["containerTags"] == [body["containerTag"]]
                    and self.matches(body["filters"], d["metadata"])]
            if self.empty_search: docs = []
            if self.leak: docs = list(self.docs.values())
            return 200, {"results": [{"documentId": d["id"], "score": 0.9, "metadata": d["metadata"]} for d in docs]}
        if path == "/v4/search": return 200, {"results": []}
        if path == "/v4/memories/list":
            docs = list(self.docs.values()) + list(self.retained.values())
            return 200, {"memoryEntries": [{"id": "memory_" + d["id"], "documentIds": [d["id"]]}
                for d in docs if d["containerTags"] == body["containerTags"]], "pagination": {"totalPages": 1}}
        if path == "/v4/profile": return 200, {"profile": {"static": [], "dynamic": []}}
        raise AssertionError("Unexpected fixture route")


class CanaryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.directory = Path(self.temp.name) / "state"
        self.store = c.Store(self.directory)
        self.state = c.make_plan()
        self.store.save(self.state)
        self.vendor = FakeVendor(self.state)
        self.runner = c.Canary(self.state, self.store, self.vendor, "MASTER_TEST", rounds=1, interval=0, sleep=lambda _: None)

    def tearDown(self):
        self.store.close()
        self.temp.cleanup()

    def test_full_probe_flow_and_cleanup_never_enable_production(self):
        self.assertTrue(self.runner.run())
        self.assertEqual(self.vendor.created_count, 8)
        self.assertEqual(self.vendor.docs, {})
        self.assertEqual(self.vendor.keys, {})
        self.assertFalse(self.state["production_ready"])
        self.assertEqual(self.state["lifecycle_guarantee"], "unverified")
        self.assertNotIn("SECRET_TEST", (self.directory / "state.json").read_text())
        self.assertNotIn("MASTER_TEST", (self.directory / "state.json").read_text())
        checks = {e["check"] for e in self.state["events"] if e["result"] == "passed"}
        self.assertIn("delete_during_processing", checks)
        self.assertIn("cross_principal_reads", checks)
        self.assertIn("cross_principal_delete_denied", checks)
        self.assertIn("adversarial_namespace_scope_filters", checks)
        self.assertEqual(self.store.load()["run"], self.state["run"])

    def test_empty_search_cannot_pass_positive_controls(self):
        self.vendor.empty_search = True
        self.assertFalse(self.runner.run())
        self.assertIn("positive_search_control_missing", json.dumps(self.state["events"]))
        self.assertEqual(self.vendor.keys, {})

    def test_foreign_hit_fails_and_still_cleans_up(self):
        self.vendor.leak = True
        self.assertFalse(self.runner.run())
        self.assertIn("foreign_search_result", json.dumps(self.state["events"]))
        self.assertEqual(self.vendor.keys, {})
        self.assertEqual(self.vendor.docs, {})

    def test_malformed_key_response_never_persists_credential_as_id(self):
        original = self.vendor.request
        def malformed(method, path, credential, body=None):
            status, result = original(method, path, credential, body)
            if path == "/v3/auth/scoped-key": result["id"] = result["key"]
            return status, result
        self.vendor.request = malformed
        self.assertFalse(self.runner.run())
        self.assertNotIn("SECRET_TEST", (self.directory / "state.json").read_text())
        self.assertFalse(self.state["cleanup_observed"])
        self.assertEqual(self.vendor.created_count, 0)

    def test_lost_create_response_is_discovered_for_cleanup_not_replayed(self):
        self.vendor.lost_create = True
        self.assertFalse(self.runner.run())
        self.assertEqual(self.vendor.created_count, 1)
        self.assertEqual(self.vendor.docs, {})
        with self.assertRaisesRegex(c.ProbeError, "run_replay_refused"):
            self.runner.run()
        self.assertEqual(self.vendor.created_count, 1)

    def test_unknown_create_never_marked_clean_or_resent(self):
        doc = self.state["documents"][0]
        doc["phase"] = "dispatching"
        self.assertFalse(self.runner.cleanup())
        self.assertEqual(doc["cleanup"], "uncertain_create_unresolved")
        self.assertEqual(self.vendor.created_count, 0)

    def test_retained_derived_memory_prevents_clean_result(self):
        self.vendor.retain_memory = True
        self.assertFalse(self.runner.run())
        self.assertFalse(self.state["cleanup_observed"])
        self.assertEqual(self.vendor.keys, {})

    def test_cleanup_failure_still_revokes_every_scoped_key(self):
        self.vendor.bad_cleanup = True
        self.assertFalse(self.runner.run())
        self.assertEqual(self.vendor.keys, {})
        self.assertFalse(self.state["cleanup_observed"])

    def test_run_plan_principals_scopes_and_shared_canonical_canary(self):
        groups = self.state["groups"]
        self.assertEqual(len(set(g["tag"] for g in groups.values())), 5)
        self.assertTrue(all(len(g["tag"]) <= 100 for g in groups.values()))
        user_docs = [d for d in self.state["documents"] if d["label"].endswith("_user")]
        self.assertEqual(len({d["canonical"] for d in user_docs}), 1)
        self.assertEqual(len({d["custom"] for d in self.state["documents"]}), 8)
        self.assertEqual(len({d["scope"] for d in self.state["documents"]}), 3)

    def test_tampered_plan_and_unsafe_files_are_rejected(self):
        altered = copy.deepcopy(self.state)
        altered["documents"][0]["custom"] = "existing_customer_document"
        self.store.save(altered)
        with self.assertRaisesRegex(c.ProbeError, "invalid_plan"): self.store.load()
        self.store.save(self.state)
        os.chmod(self.directory / "state.json", 0o644)
        with self.assertRaisesRegex(c.ProbeError, "unsafe_state_file"): self.store.load()

    def test_second_worker_cannot_use_same_state_directory(self):
        with self.assertRaisesRegex(c.ProbeError, "run_already_active"): c.Store(self.directory)

    def test_cleanup_checks_metadata_before_deleting(self):
        self.runner.mint_keys()
        doc = self.state["documents"][0]
        self.runner.ingest(doc)
        self.vendor.docs[doc["id"]]["metadata"]["ag_run"] = "foreign"
        self.assertFalse(self.runner.cleanup())
        self.assertIn(doc["id"], self.vendor.docs)
        self.assertEqual(self.vendor.keys, {})

    def test_live_opt_in_and_key_are_required_before_network(self):
        self.store.close()
        self.store = None
        with patch.dict(os.environ, {}, clear=True), patch.object(c.HTTP, "request") as request, contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(c.main(["run", "--state-dir", str(self.directory)]), 2)
            request.assert_not_called()
        with patch.dict(os.environ, {"SUPERMEMORY_LIVE_TESTS": "1"}, clear=True), patch.object(c.HTTP, "request") as request, contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(c.main(["run", "--state-dir", str(self.directory)]), 2)
            request.assert_not_called()
        self.store = c.Store(self.directory)

    def test_mutation_claim_is_saved_before_request(self):
        self.runner.mint_keys()
        original = self.vendor.request
        def inspect(method, path, credential, body=None):
            if path == "/v3/documents":
                self.assertEqual(self.store.load()["documents"][0]["phase"], "dispatching")
            return original(method, path, credential, body)
        self.vendor.request = inspect
        self.runner.ingest(self.state["documents"][0])
        self.assertTrue(self.runner.cleanup())


class Response:
    def __init__(self, status=200, data=b'{"ok":true}', headers=None):
        self.status, self.buffer = status, io.BytesIO(data)
        self.headers = {"Content-Type": "application/json"} if headers is None else headers
    def getheader(self, key, default=None): return self.headers.get(key, default)
    def read1(self, count): return self.buffer.read(count)


class TransportTests(unittest.TestCase):
    def call(self, response):
        with patch.object(c.http.client, "HTTPSConnection") as constructor:
            conn = constructor.return_value
            conn.getresponse.return_value = response
            return c.HTTP().request("POST", "/v3/search", "TOKEN", {"q": "synthetic"})

    def test_json_and_no_content_responses(self):
        self.assertEqual(self.call(Response()), (200, {"ok": True}))
        self.assertEqual(self.call(Response(204, b"", {})), (204, {}))

    def test_redirect_mime_declared_and_streamed_limits(self):
        cases = [(Response(302), "redirect_refused"),
                 (Response(headers={"Content-Type": "text/html"}), "invalid_content_type"),
                 (Response(headers={"Content-Length": str(c.MAX_BYTES + 1)}), "response_too_large"),
                 (Response(data=b"x" * (c.MAX_BYTES + 1)), "response_too_large")]
        for response, error in cases:
            with self.subTest(error=error), self.assertRaisesRegex(c.ProbeError, error): self.call(response)

    def test_transport_failure_does_not_echo_credential_or_body(self):
        with patch.object(c.http.client, "HTTPSConnection") as constructor:
            constructor.return_value.request.side_effect = OSError("private TOKEN response")
            with self.assertRaisesRegex(c.ProbeError, "^transport_or_json_failure$"):
                c.HTTP().request("POST", "/v3/search", "TOKEN", {})

    def test_invalid_credentials_and_budgets_send_nothing(self):
        with patch.object(c.http.client, "HTTPSConnection") as constructor:
            for bad in ("", "a\r\nb", "white space", "雪"):
                with self.assertRaises(c.ProbeError): c.HTTP().request("GET", "/v3/documents/x", bad)
            with self.assertRaisesRegex(c.ProbeError, "request_budget_exhausted"):
                c.HTTP(requests=0).request("GET", "/v3/documents/x", "TOKEN")
            constructor.assert_not_called()


if __name__ == "__main__": unittest.main()
