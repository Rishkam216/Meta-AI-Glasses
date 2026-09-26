#!/usr/bin/env python3
"""Opt-in vendor API probes. Never enables the production Swift adapter.

Only synthetic documents in fresh run-specific containers are written. Credentials
stay in memory. Creates are never automatically replayed after an uncertain result.
"""
import argparse
import base64
import fcntl
import getpass
import http.client
import json
import math
import os
from pathlib import Path
import re
import socket
import stat
import sys
import time
from urllib.parse import quote
import uuid

HOST = "api.supermemory.ai"
MAX_BYTES = 1_048_576
MAX_REQUESTS = 400


class ProbeError(Exception):
    """Only fixed safe diagnostic codes; never vendor bodies or credentials."""


def check(condition, code):
    if not condition:
        raise ProbeError(code)


def token(value):
    check(isinstance(value, str) and 0 < len(value) <= 4096
          and all(33 <= ord(c) <= 126 for c in value), "invalid_credential")
    return value


def identifier(value):
    check(isinstance(value, str) and re.fullmatch(r"[A-Za-z0-9_-]{1,128}", value), "invalid_remote_id")
    return value


def scope_token(kind, reference=None):
    value = {"kind": kind}
    if reference is not None:
        value["referenceID"] = reference
    return base64.urlsafe_b64encode(json.dumps(value, ensure_ascii=False, sort_keys=True,
        separators=(",", ":")).encode()).decode().rstrip("=")


def condition(key, value):
    return {"key": key, "value": value, "filterType": "metadata", "ignoreCase": False}


def make_plan(run_id=None):
    run = uuid.UUID(run_id) if run_id else uuid.uuid4()
    def uid(name): return uuid.uuid5(run, name)
    tenant, user, account = uid("tenant"), uid("user"), uid("account")
    principals = [("owner", tenant, user, account),
                  ("other_user", tenant, uid("user2"), account),
                  ("other_tenant", uid("tenant2"), user, account),
                  ("other_account", tenant, user, uid("account2")),
                  ("no_account", tenant, user, None)]
    groups = {label: {"tag": "n" + t.hex + "_" + u.hex + "_" + (a.hex if a else "none")}
              for label, t, u, a in principals}
    docs = []
    for label in groups:
        scopes = [("user", None)]
        if label == "owner": scopes += [("project", "canary-project"), ("workspace", "canary-workspace")]
        for kind, reference in scopes:
            name = label + "_" + kind
            docs.append({"label": name, "group": label, "scope": scope_token(kind, reference),
                         "canonical": str(uid("canonical-" + kind)), "custom": "canary_" + uid(name).hex,
                         "marker": "CANARY" + uid("marker-" + name).hex, "phase": "planned"})
    docs.append({"label": "owner_processing_delete", "group": "owner", "scope": scope_token("user"),
                 "canonical": str(uid("early-delete")), "custom": "canary_" + uid("early-custom").hex,
                 "marker": "CANARY" + uid("early-marker").hex, "phase": "planned", "early_delete": True})
    return {"version": 1, "run": str(run), "deployment": "canary." + run.hex,
            "phase": "planned", "groups": groups, "documents": docs, "keys": [], "unresolved_key_mints": [], "events": [],
            "production_ready": False, "lifecycle_guarantee": "unverified"}


class Store:
    """Private, locked, fsynced state/report. One invocation per directory."""
    def __init__(self, directory):
        self.path = Path(directory).absolute()
        self.path.mkdir(mode=0o700, parents=False, exist_ok=True)
        info = self.path.lstat()
        check(stat.S_ISDIR(info.st_mode) and info.st_uid == os.getuid() and not info.st_mode & 0o077,
              "private_state_directory_required")
        self.lock = os.open(self.path / "run.lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        info = os.fstat(self.lock)
        check(stat.S_ISREG(info.st_mode) and info.st_nlink == 1 and info.st_uid == os.getuid()
              and not info.st_mode & 0o077, "unsafe_lock_file")
        try:
            fcntl.flock(self.lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            os.close(self.lock)
            raise ProbeError("run_already_active") from None

    def close(self):
        os.close(self.lock)

    def save(self, value, name="state.json"):
        target = self.path / name
        if target.exists() or target.is_symlink():
            info = target.lstat()
            check(stat.S_ISREG(info.st_mode) and info.st_nlink == 1 and info.st_uid == os.getuid()
                  and not info.st_mode & 0o077, "unsafe_state_file")
        temporary = self.path / (".tmp-" + uuid.uuid4().hex)
        fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        try:
            with os.fdopen(fd, "wb") as stream:
                stream.write(json.dumps(value, sort_keys=True, indent=2, allow_nan=False).encode())
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(temporary, target)
            directory_fd = os.open(self.path, os.O_DIRECTORY)
            try: os.fsync(directory_fd)
            finally: os.close(directory_fd)
        finally:
            temporary.unlink(missing_ok=True)

    def load(self):
        file = self.path / "state.json"
        if not file.exists() and not file.is_symlink(): return None
        fd = os.open(file, os.O_RDONLY | os.O_NOFOLLOW)
        try:
            info = os.fstat(fd)
            check(stat.S_ISREG(info.st_mode) and info.st_nlink == 1 and info.st_uid == os.getuid()
                  and not info.st_mode & 0o077 and info.st_size <= MAX_BYTES, "unsafe_state_file")
            with os.fdopen(fd, "rb", closefd=False) as stream:
                value = json.load(stream)
        finally: os.close(fd)
        expected = make_plan(value["run"])
        check(value["version"] == 1 and value["deployment"] == expected["deployment"]
              and value["groups"] == expected["groups"] and value["production_ready"] is False
              and len(value["documents"]) == len(expected["documents"]), "invalid_plan")
        for actual, planned in zip(value["documents"], expected["documents"]):
            check(all(actual[k] == v for k, v in planned.items() if k != "phase"), "invalid_plan")
            if "id" in actual: identifier(actual["id"])
        for key in value["keys"]: identifier(key["id"])
        return value


class HTTP:
    """Fixed TLS host, no redirects/proxies/retries, bounded time/bytes/calls."""
    def __init__(self, seconds=600, requests=MAX_REQUESTS, clock=time.monotonic):
        self.clock = clock
        self.deadline = clock() + seconds
        self.remaining = requests

    def request(self, method, path, credential, body=None):
        token(credential)
        check(path.startswith("/v3/") or path.startswith("/v4/"), "invalid_endpoint")
        check(self.remaining > 0 and self.clock() < self.deadline, "request_budget_exhausted")
        self.remaining -= 1
        conn = http.client.HTTPSConnection(HOST, timeout=min(10, self.deadline - self.clock()))
        try:
            encoded = json.dumps(body, separators=(",", ":")).encode() if body is not None else None
            conn.request(method, path, encoded, {"Authorization": "Bearer " + credential,
                "Content-Type": "application/json", "Accept": "application/json", "Connection": "close"})
            response = conn.getresponse()
            check(not 300 <= response.status < 400, "redirect_refused")
            length = response.getheader("Content-Length")
            if length is not None:
                check(length.isdigit() and int(length) <= MAX_BYTES, "response_too_large")
            data = bytearray()
            while True:
                remaining = self.deadline - self.clock()
                check(remaining > 0, "request_budget_exhausted")
                if conn.sock: conn.sock.settimeout(min(10, remaining))
                chunk = response.read1(min(65_536, MAX_BYTES + 1 - len(data)))
                if not chunk: break
                data.extend(chunk)
                check(len(data) <= MAX_BYTES, "response_too_large")
            if response.status in (204, 401, 403, 404): return response.status, {}
            check(response.getheader("Content-Type", "").split(";")[0].lower() == "application/json",
                  "invalid_content_type")
            value = json.loads(data)
            check(isinstance(value, dict), "invalid_json_shape")
            return response.status, value
        except ProbeError: raise
        except socket.gaierror: raise ProbeError("network_dns_failure") from None
        except Exception: raise ProbeError("transport_or_json_failure") from None
        finally: conn.close()


class Canary:
    def __init__(self, state, store, http, master, rounds=20, interval=2, sleep=time.sleep):
        self.state, self.store, self.http, self.master = state, store, http, token(master)
        self.rounds, self.interval, self.sleep = rounds, interval, sleep
        self.credentials = {}

    def save(self): self.store.save(self.state)

    def event(self, name, result, **details):
        self.state["events"].append({"check": name, "result": result, **details})
        self.save()

    def metadata(self, doc):
        return {"ag_run": self.state["run"], "ag_namespace": self.state["groups"][doc["group"]]["tag"],
                "ag_deployment": self.state["deployment"], "ag_scope": doc["scope"], "ag_id": doc["canonical"]}

    def search_body(self, doc, include_scope=True):
        metadata = self.metadata(doc)
        filters = [condition(k, metadata[k]) for k in ("ag_namespace", "ag_deployment")]
        if include_scope: filters.append({"OR": [condition("ag_scope", doc["scope"])]})
        return {"q": doc["marker"], "containerTag": metadata["ag_namespace"], "limit": 100,
                "filters": {"AND": filters}, "includeFullDocs": False, "includeSummary": False,
                "onlyMatchingChunks": True, "rewriteQuery": False, "rerank": False}

    def call(self, method, path, credential=None, body=None, statuses=(200,)):
        status, value = self.http.request(method, path, credential or self.master, body)
        check(status in statuses, "unexpected_http_" + str(status))
        return status, value

    def mint_keys(self):
        for label, group in self.state["groups"].items():
            # If the response is lost, the unrecorded key expires after one day.
            self.state.setdefault("unresolved_key_mints", []).append(label)
            self.event("mint_" + label, "dispatching")
            _, result = self.call("POST", "/v3/auth/scoped-key", body={"containerTag": group["tag"],
                "name": "canary-" + self.state["run"] + "-" + label, "expiresInDays": 1})
            key_id = identifier(result.get("id"))
            check(key_id not in (self.master, result.get("key")) and key_id not in self.credentials.values(), "invalid_remote_id")
            self.state["keys"].append({"id": key_id, "group": label, "revoked": False})
            self.state["unresolved_key_mints"].remove(label)
            self.save()  # Persist revocation ID before using returned credential.
            check(result.get("containerTag") == group["tag"], "scoped_key_identity_mismatch")
            self.credentials[label] = token(result.get("key"))

    def ingest(self, doc):
        check(doc["phase"] == "planned", "mutation_replay_refused")
        doc["phase"] = "dispatching"
        self.save()
        metadata = self.metadata(doc)
        _, result = self.call("POST", "/v3/documents", self.credentials[doc["group"]], {
            "content": "Synthetic evaluation only. The fictional user's launch phrase is " + doc["marker"]
                       + ". This fact belongs only to this test container and scope.",
            "customId": doc["custom"], "containerTag": metadata["ag_namespace"], "metadata": metadata,
            "filterByMetadata": {k: metadata[k] for k in ("ag_namespace", "ag_deployment", "ag_scope")},
            "dreaming": "instant", "taskType": "memory"})
        remote_id = identifier(result.get("id"))
        check(remote_id != self.master and remote_id not in self.credentials.values(), "invalid_remote_id")
        doc["id"] = remote_id
        doc["phase"] = "accepted"
        self.save()

    def validate_document(self, doc, value):
        check(value.get("id") == doc["id"] and value.get("customId") == doc["custom"], "document_identity_mismatch")
        check(isinstance(value.get("metadata"), dict) and all(value["metadata"].get(k) == v
              for k, v in self.metadata(doc).items()), "document_metadata_mismatch")
        tags = value.get("containerTags")
        if tags is not None:
            check(tags == [self.metadata(doc)["ag_namespace"]], "document_container_mismatch")

    def wait_ready(self, doc):
        for attempt in range(self.rounds):
            _, value = self.call("GET", "/v3/documents/" + quote(doc["id"], safe=""), self.credentials[doc["group"]])
            self.validate_document(doc, value)
            check(value.get("status") != "failed", "document_processing_failed")
            if value.get("status") == "done" and value.get("dreamingStatus") == "done":
                # Ready for probing, explicitly NOT a strong lifecycle guarantee.
                doc["phase"] = "ready_observed"
                doc["memory_ids"] = [identifier(x["id"]) for x in value.get("memories", [])]
                self.save()
                return
            if attempt + 1 < self.rounds: self.sleep(self.interval)
        raise ProbeError("readiness_not_observed_within_budget")

    def validate_hits(self, results, allowed):
        check(isinstance(results, list) and len(results) <= 100, "invalid_search_results")
        by_id = {d["id"]: d for d in allowed}
        found = set()
        for hit in results:
            check(isinstance(hit, dict) and hit.get("documentId") in by_id, "foreign_search_result")
            doc = by_id[hit["documentId"]]
            check(hit["documentId"] not in found, "duplicate_search_result")
            found.add(hit["documentId"])
            check(isinstance(hit.get("metadata"), dict) and all(hit["metadata"].get(k) == v
                  for k, v in self.metadata(doc).items()), "foreign_search_metadata")
            score = hit.get("score")
            check(type(score) in (int, float) and math.isfinite(score) and 0 <= score <= 1, "invalid_search_score")
        return found

    def isolation_checks(self):
        docs = [d for d in self.state["documents"] if not d.get("early_delete")]
        for doc in docs:
            _, value = self.call("POST", "/v3/search", self.credentials[doc["group"]], self.search_body(doc))
            found = self.validate_hits(value.get("results"), [doc])
            check(doc["id"] in found, "positive_search_control_missing")
            # Master-key request verifies filtering independently of key scoping.
            _, value = self.call("POST", "/v3/search", body=self.search_body(doc))
            check(doc["id"] in self.validate_hits(value.get("results"), [doc]), "positive_search_control_missing")
            self.event("self_scope_" + doc["label"], "passed")
        for doc in docs:
            for label, key in self.credentials.items():
                if label == doc["group"]: continue
                status, result = self.call("POST", "/v3/search", key, self.search_body(doc), statuses=(200, 401, 403, 404))
                check(status != 200 or result.get("results") == [], "cross_principal_search_allowed")
                status, _ = self.call("GET", "/v3/documents/" + quote(doc["id"], safe=""), key, statuses=(200, 401, 403, 404))
                check(status != 200, "cross_principal_document_allowed")
        self.event("cross_principal_reads", "passed")
        owner_docs = [d for d in docs if d["group"] == "owner"]
        for target in owner_docs:
            for foreign in docs:
                if target == foreign: continue
                body = self.search_body(target)
                body["q"] = foreign["marker"]
                _, value = self.call("POST", "/v3/search", body=body)
                self.validate_hits(value.get("results"), [target])
        self.event("adversarial_namespace_scope_filters", "passed")
        for doc in docs:
            if doc["group"] == "owner": continue
            status, _ = self.call("DELETE", "/v3/documents/" + quote(doc["id"], safe=""),
                self.credentials["owner"], statuses=(200, 204, 401, 403, 404))
            check(status not in (200, 204), "cross_principal_delete_allowed")
            _, value = self.call("GET", "/v3/documents/" + quote(doc["id"], safe=""), self.credentials[doc["group"]])
            self.validate_document(doc, value)
        self.event("cross_principal_delete_denied", "passed")

    def delete_document(self, doc):
        # Verify exact ownership before destructive action. No bulk/global deletes.
        status, value = self.call("GET", "/v3/documents/" + quote(doc["id"], safe=""), statuses=(200, 404))
        if status == 404:
            doc["cleanup"] = "absence_observed"
            self.save()
            return
        self.validate_document(doc, value)
        if doc.get("early_delete"):
            doc["processing_at_delete_observed"] = value.get("status") in (
                "queued", "extracting", "chunking", "embedding", "indexing")
        doc["cleanup"] = "delete_dispatching"
        self.save()
        self.call("DELETE", "/v3/documents/" + quote(doc["id"], safe=""), statuses=(204, 404))
        doc["cleanup"] = "delete_response_received"
        self.save()

    def absence_probe(self, doc):
        status, value = self.call("GET", "/v3/documents/" + quote(doc["id"], safe=""), statuses=(200, 404))
        if status == 200: self.validate_document(doc, value)
        _, search = self.call("POST", "/v3/search", body=self.search_body(doc))
        hits = self.validate_hits(search.get("results"), [doc])
        metadata = self.metadata(doc)
        body = {"q": doc["marker"], "containerTag": metadata["ag_namespace"], "limit": 100,
                "searchMode": "memories", "threshold": 0, "include": {"forgottenMemories": True},
                "filters": {"AND": [condition(k, v) for k, v in metadata.items()]}}
        _, memories = self.call("POST", "/v4/search", body=body)
        check(isinstance(memories.get("results"), list), "invalid_memory_results")
        retained_memory = False
        for page in (1, 2):
            _, listing = self.call("POST", "/v4/memories/list", body={
                "containerTags": [metadata["ag_namespace"]], "limit": 100, "page": page})
            entries, pagination = listing.get("memoryEntries"), listing.get("pagination")
            check(isinstance(entries, list) and len(entries) <= 100 and isinstance(pagination, dict),
                  "invalid_memory_listing")
            pages = pagination.get("totalPages")
            check(type(pages) is int and 0 <= pages <= 2, "memory_listing_exceeds_budget")
            for memory in entries:
                check(isinstance(memory, dict) and isinstance(memory.get("documentIds"), list), "invalid_memory_entry")
                retained_memory |= (doc["id"] in memory["documentIds"]
                    or memory.get("id") in doc.get("memory_ids", [])
                    or doc["marker"] in json.dumps(memory))
            if page >= pages: break
        _, profile = self.call("POST", "/v4/profile", body={"containerTag": metadata["ag_namespace"]})
        check(isinstance(profile.get("profile"), dict), "invalid_profile_response")
        # Save only booleans, never profile text or provider response bodies.
        profile_marker = doc["marker"] in json.dumps(profile["profile"])
        return status == 404 and not hits and not memories["results"] and not retained_memory and not profile_marker

    def cleanup(self):
        complete = not self.state.get("unresolved_key_mints")
        for doc in self.state["documents"]:
            if doc["phase"] == "planned": continue
            try:
                if "id" not in doc:
                    # Discover an uncertain create only inside its owned namespace.
                    _, listing = self.call("POST", "/v3/documents/list", body={"containerTags": [self.metadata(doc)["ag_namespace"]],
                        "limit": 100, "page": 1, "filters": {"AND": [condition("ag_run", self.state["run"])]}})
                    check(isinstance(listing.get("memories"), list), "invalid_document_list")
                    matches = [x for x in listing["memories"] if x.get("customId") == doc["custom"]]
                    if len(matches) != 1:
                        doc["cleanup"] = "uncertain_create_unresolved"
                        complete = False
                        self.save()
                        continue
                    doc["id"] = identifier(matches[0].get("id"))
                    self.save()
                if doc.get("cleanup") not in ("delete_dispatching", "delete_response_received", "absence_observed"):
                    self.delete_document(doc)
                absent = self.absence_probe(doc)
                doc["cleanup"] = "absence_observed" if absent else "removal_not_observed"
                complete &= absent
                self.save()
            except Exception as error:
                complete = False
                self.state["events"].append({"check": "cleanup_" + doc["label"], "result": "incomplete",
                    "code": str(error) if isinstance(error, ProbeError) else "cleanup_local_or_response_failure"})
        # Even incomplete document cleanup must not leave scoped credentials live.
        for key in self.state["keys"]:
            if key["revoked"]: continue
            try:
                status, result = self.call("DELETE", "/v3/auth/scoped-key/" + quote(key["id"], safe=""), statuses=(200, 204, 404))
                check(status in (204, 404) or result.get("success") is True, "key_revocation_unconfirmed")
                key["revoked"] = True
                self.save()
            except Exception as error:
                complete = False
                self.state["events"].append({"check": "revoke_scoped_key", "result": "incomplete",
                    "code": str(error) if isinstance(error, ProbeError) else "cleanup_local_or_response_failure"})
        self.state["cleanup_observed"] = complete
        self.save()
        return complete

    def smoke(self):
        """One document, no key minting, <=20 probe + 10 cleanup requests."""
        check(self.state["phase"] == "planned", "run_replay_refused_use_cleanup")
        if isinstance(self.http, HTTP): self.http = HTTP(seconds=120, requests=20)
        self.state.update(phase="running", mode="smoke", request_limit=30)
        self.save()
        self.credentials["owner"] = self.master
        self.rounds = min(self.rounds, 6)
        passed = False
        try:
            doc = self.state["documents"][0]
            self.ingest(doc)
            self.wait_ready(doc)
            _, value = self.call("POST", "/v3/search", body=self.search_body(doc))
            check(doc["id"] in self.validate_hits(value.get("results"), [doc]),
                  "positive_search_control_missing")
            self.event("single_document_ingestion_retrieval", "passed")
            passed = True
        except Exception as error:
            self.event("smoke_checks", "failed", code=str(error) if isinstance(error, ProbeError)
                       else "local_or_response_failure")
        finally:
            if isinstance(self.http, HTTP):
                self.state["probe_requests_attempted"] = 20 - self.http.remaining
                self.http = HTTP(seconds=120, requests=10)
            clean = self.cleanup()
            if isinstance(self.http, HTTP):
                self.state["cleanup_requests_attempted"] = 10 - self.http.remaining
            self.credentials.clear()
            self.state["phase"] = "smoke_observed_pass" if passed and clean else "incomplete_or_failed"
            self.save()
        return passed and clean

    def run(self):
        check(self.state["phase"] == "planned", "run_replay_refused_use_cleanup")
        self.state["phase"] = "running"
        self.save()
        passed = False
        try:
            self.mint_keys()
            for doc in self.state["documents"]:
                self.ingest(doc)
                if doc.get("early_delete"): self.delete_document(doc)
            for doc in self.state["documents"]:
                if not doc.get("early_delete"): self.wait_ready(doc)
            self.isolation_checks()
            # Delete one fully observed fixture, then watch for visible return.
            victim = self.state["documents"][0]
            self.delete_document(victim)
            early = next(d for d in self.state["documents"] if d.get("early_delete"))
            for _ in range(3):
                for removed in (victim, early):
                    check(self.absence_probe(removed), "deleted_canary_still_observable")
                self.sleep(self.interval)
            self.event("bounded_post_delete_observations", "passed", observations=3)
            exercised = early.get("processing_at_delete_observed", False)
            self.event("delete_during_processing", "passed" if exercised else "not_exercised")
            passed = exercised
        except Exception as error:
            self.event("live_checks", "failed", code=str(error) if isinstance(error, ProbeError)
                       else "local_or_response_failure")
        finally:
            # Separate bounded cleanup budget even if probe request budget expired.
            if isinstance(self.http, HTTP): self.http = HTTP(seconds=180, requests=100)
            clean = self.cleanup()
            self.credentials.clear()
            self.state["phase"] = "observed_pass" if passed and clean else "incomplete_or_failed"
            self.save()
        return passed and clean


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("plan", "smoke", "run", "cleanup"))
    parser.add_argument("--state-dir", required=True)
    parser.add_argument("--prompt-key", action="store_true", help="Read the API key privately from an interactive terminal")
    parser.add_argument("--poll-rounds", type=int, default=20, choices=range(1, 31))
    parser.add_argument("--poll-interval", type=float, default=2)
    args = parser.parse_args(argv)
    store = None
    try:
        check(0 <= args.poll_interval <= 10, "invalid_poll_interval")
        store = Store(args.state_dir)
        state = store.load()
        if args.action == "plan":
            check(state is None, "existing_plan_refused")
            state = make_plan()
            store.save(state)
            print("Plan saved: 8 synthetic documents, 5 isolated principals. No network requests made.")
            return 0
        check(state is not None, "plan_required")
        check(os.environ.get("SUPERMEMORY_LIVE_TESTS") == "1", "explicit_live_opt_in_required")
        secret = os.environ.get("SUPERMEMORY_API_KEY", "")
        if args.prompt_key:
            check(sys.stdin.isatty(), "interactive_terminal_required")
            secret = getpass.getpass("Supermemory test-organization API key: ")
        check(bool(secret), "SUPERMEMORY_API_KEY_required")
        master = token(secret)
        smoke_budget = args.action == "smoke" or state.get("mode") == "smoke"
        http = HTTP(seconds=120, requests=20 if args.action == "smoke" else 10) if smoke_budget else HTTP()
        runner = Canary(state, store, http, master, args.poll_rounds, args.poll_interval)
        success = runner.smoke() if args.action == "smoke" else runner.run() if args.action == "run" else runner.cleanup()
        store.save({"run": state["run"], "result": "observed_pass" if success else "incomplete_or_failed",
                    "mode": state.get("mode", "full"),
                    "production_ready": False, "lifecycle_guarantee": "unverified",
                    "events": state["events"], "cleanup_observed": state.get("cleanup_observed", False)}, "report.json")
        print("Observations saved. Production writes remain disabled.")
        return 0 if success else 1
    except ProbeError as error:
        print("Blocked: " + str(error), file=sys.stderr)
        return 2
    except (OSError, ValueError, KeyError, TypeError):
        print("Blocked: local_state_or_configuration_error", file=sys.stderr)
        return 2
    finally:
        if store is not None: store.close()


if __name__ == "__main__":
    sys.exit(main())
