"""Offline coordinator contract tests; all commands and HTTP are intercepted."""

import base64
import contextlib
import copy
import datetime as dt
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import stat
import struct
import subprocess
import unittest
from unittest import mock
import urllib.error
import urllib.parse
import urllib.request
import uuid
import warnings
import zipfile
import zlib


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "wezterm_pipeline_under_test", ROOT / "scripts/wezterm_pipeline.py")
p = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(p)

SHA = "a" * 40
OLD_SHA = "b" * 40
HEAD = "c" * 40
DEFAULT = "d" * 40
BUILD_HEAD = "e" * 40
NEW_HEAD = "f" * 40
DATE = "2026-10-10T07:39:11Z"
VERSION = "20261010-073911-aaaaaaaa"
SOURCE_HASH = "sha256-" + base64.b64encode(bytes(range(32))).decode()
CARGO_HASH = "sha256-" + base64.b64encode(bytes(range(32, 64))).decode()
RUNTIME = (
    "wezterm.exe", "wezterm-gui.exe", "wezterm-mux-server.exe",
    "strip-ansi-escapes.exe", "wezterm.pdb", "conpty.dll", "OpenConsole.exe",
    "libEGL.dll", "libGLESv2.dll", "mesa/opengl32.dll",
)


def request(nonce="12345", sha=SHA):
    material = f"{p.REPO}\n{p.BRANCH}\n{sha}\n{nonce}"
    return {
        "schema": 1, "repository": p.REPO, "branch": p.BRANCH,
        "source_repository": p.SOURCE, "source_sha": sha, "nonce": nonce,
        "requested_at": "2026-10-11T15:30:00Z",
        "request_id": hashlib.sha256(material.encode()).hexdigest(),
    }


def blob(path, data):
    raw = data.encode() if isinstance(data, str) else data
    return {
        "type": "file", "path": path, "encoding": "base64",
        "sha": hashlib.sha1(f"blob {len(raw)}\0".encode() + raw).hexdigest(),
        "size": len(raw), "content": base64.b64encode(raw).decode(),
    }


def ref(branch, sha):
    return {"ref": "refs/heads/" + branch, "object": {"type": "commit", "sha": sha}}


def pull():
    return {
        "number": 42, "state": "open", "merged": False, "merged_at": None,
        "head": {"ref": p.BRANCH, "sha": HEAD,
                 "repo": {"full_name": p.REPO, "fork": False}},
        "base": {"ref": "main", "repo": {"full_name": p.REPO}},
    }


def source_locked():
    return {
        "type": "git", "url": "https://github.com/wezterm/wezterm", "submodules": True,
        "rev": SHA, "narHash": SOURCE_HASH, "lastModified": 1791617951,
        "ref": "refs/heads/main", "revCount": 8718,
    }


def source_prefetch():
    locked = source_locked()
    del locked["narHash"]
    return {"hash": SOURCE_HASH, "locked": locked,
            "original": {key: locked[key] for key in ("rev", "submodules", "type", "url")},
            "storePath": "/nix/store/" + "a" * 32 + "-source"}


def invalid_source_locks():
    good = source_locked()
    cases = [("null", None), ("list", []), ("unknown", dict(good, extra=True))]
    for key in ("type", "url", "submodules", "rev", "narHash", "lastModified"):
        obj = dict(good)
        del obj[key]
        cases.append(("missing_" + key, obj))
    for key, values in {
        "type": ("github", True, None),
        "url": ("https://evil.invalid/source", None),
        "submodules": (False, 1, None),
        "rev": (OLD_SHA, "main", None),
        "narHash": (CARGO_HASH, "bad", None),
        "lastModified": (123, True, -1, 1791617951.0, "1791617951", None),
        "revCount": (True, -1, 8718.0, "8718", None),
        "ref": (True, None, "main", "refs/tags/main", "refs/heads/../main",
                "refs/heads/main//child", "refs/heads/.main", "refs/heads/main.lock",
                "refs/heads/main.", "refs/heads/main/", "refs/heads/main\n",
                "refs/heads/" + "a" * 256),
    }.items():
        for value in values:
            cases.append((f"{key}={value!r}", dict(good, **{key: value})))
    return cases


def lock_data(with_source=True):
    inputs = {"nixpkgs": "nixpkgs", "home-manager": "home-manager"}
    nodes = {
        "root": {"inputs": inputs},
        "nixpkgs": {
            "locked": {"type": "github", "owner": "NixOS", "repo": "nixpkgs",
                       "rev": OLD_SHA, "narHash": SOURCE_HASH},
            "original": {"type": "github", "owner": "NixOS", "repo": "nixpkgs"},
        },
        "home-manager": {"locked": {"rev": OLD_SHA}},
    }
    if with_source:
        inputs["wezterm-src"] = "wezterm-src"
        nodes["wezterm-src"] = {
            "flake": False,
            "locked": {"type": "git", "url": "https://github.com/wezterm/wezterm",
                       "submodules": True, "rev": OLD_SHA, "narHash": SOURCE_HASH,
                       "lastModified": 123, "ref": "refs/heads/old", "revCount": 8000},
            "original": {"type": "git", "url": "https://github.com/wezterm/wezterm",
                         "rev": OLD_SHA, "submodules": True},
        }
    return {"version": 7, "root": "root", "nodes": nodes}


def pin_data(with_hash=True):
    digest = "1" * 64
    data = {
        "revision": OLD_SHA, "commitDate": DATE,
        "version": "20261010-073911-bbbbbbbb", "cargoHash": CARGO_HASH,
        "assets": {"windows": {
            "status": "bootstrap-unpromoted", "assetId": 101,
            "url": f"{p.API}/repos/{p.SOURCE}/releases/assets/101",
            "headers": {"Accept": "application/octet-stream"},
            "hash": p.sri(digest), "sha256": digest, "size": 123,
            "archiveRoot": "WezTerm-windows-20261010-073911-bbbbbbbb",
            "architectures": ["x86_64"],
        }},
    }
    if with_hash:
        data["sourceHash"] = SOURCE_HASH
    return data


def zip_bytes(root="WezTerm-windows-" + VERSION, extra=(), omit=(), compression=0):
    stream = io.BytesIO()
    with warnings.catch_warnings():
        warnings.simplefilter("ignore", UserWarning)
        with zipfile.ZipFile(stream, "w", compression=compression) as archive:
            for name in RUNTIME:
                if name not in omit:
                    archive.writestr(root + "/" + name, b"runtime:" + name.encode())
            for name, value in extra:
                archive.writestr(name, value)
    return stream.getvalue()


def manifest(data, req=None):
    req = req or request()
    build_id = SHA + "-9001-2"
    return {
        "schema": 1, "source_repository": p.SOURCE, "source_sha": SHA,
        "build_repository": p.BUILDS, "run_id": 9001, "run_attempt": 2,
        "build_id": build_id, "version": VERSION,
        "archive_root": "WezTerm-windows-" + VERSION,
        "asset_name": "WezTerm-windows-" + build_id + ".zip",
        "sha256": hashlib.sha256(data).hexdigest(), "size": len(data),
        "success": True, "request_id": req["request_id"],
        "nonce": req["nonce"], "requested_at": req["requested_at"],
    }


class FakeAPI:
    """Exact route fixtures; an unconfigured read or write fails immediately."""

    def __init__(self):
        self.routes = {}
        self.page_routes = {}
        self.raw_routes = {}
        self.calls = []
        self.reads = []
        self.writes = []
        self.advancements = []
        self.on_get = None
        self.on_call = None

    def get(self, path):
        self.reads.append(path)
        if self.on_get:
            self.on_get(path)
        if path not in self.routes:
            raise AssertionError("unmocked GET " + path)
        result = self.routes[path]
        if isinstance(result, Exception):
            raise result
        return copy.deepcopy(result)

    def pages(self, path, key=None):
        self.calls.append(("pages", path, key))
        if (path, key) not in self.page_routes:
            raise AssertionError("unmocked pages " + path)
        yield from copy.deepcopy(self.page_routes[path, key])

    def raw(self, url, limit, octets=False):
        self.calls.append(("raw", url, limit, octets))
        if url not in self.raw_routes:
            raise AssertionError("unmocked asset " + url)
        return self.raw_routes[url]

    def call(self, method, suffix, data=None):
        self.calls.append((method, suffix, copy.deepcopy(data)))
        if method != "GET":
            self.writes.append((method, suffix, copy.deepcopy(data)))
        if self.on_call:
            result = self.on_call(method, suffix, data)
            if result is not None:
                return result
        if method == "GET":
            return self.get("/repos/" + p.REPO + suffix)
        if method == "POST" and suffix == "/git/refs":
            path = f"/repos/{p.REPO}/git/ref/heads/{p.BRANCH}"
            current = self.routes.get(path)
            if current is not None and not (
                    isinstance(current, urllib.error.HTTPError) and current.code == 404):
                raise urllib.error.HTTPError(p.API, 422, "already exists", {}, None)
            self.routes[path] = ref(p.BRANCH, data["sha"])
            return {}
        if method == "POST" and suffix == "/pulls":
            self.page_routes[f"/repos/{p.REPO}/pulls?state=open&head=dc0d32:{p.BRANCH}", None] = [
                {"number": 42}]
            self.routes[f"/repos/{p.REPO}/pulls/42"]["head"]["sha"] = NEW_HEAD
            return {}
        if method == "POST" and suffix.startswith("/statuses/"):
            return {}
        raise AssertionError("unmocked write " + method + " " + suffix)

    def graphql(self, query, variables):
        p.require(query == p.CREATE_COMMIT_QUERY, "fixed GraphQL query")
        p.validate_commit_variables(variables)
        attempt = ("graphql", query, copy.deepcopy(variables))
        self.calls.append(attempt)
        self.writes.append(attempt)
        if self.on_call:
            self.on_call("graphql", query, variables)
        current = self.routes.get(f"/repos/{p.REPO}/git/ref/heads/{p.BRANCH}")
        p.require(type(current) is dict and current["object"]["sha"] ==
                  variables["input"]["expectedHeadOid"], "GraphQL expected head mismatch")
        self.routes[f"/repos/{p.REPO}/git/ref/heads/{p.BRANCH}"] = ref(p.BRANCH, NEW_HEAD)
        self.routes[f"/repos/{p.REPO}/pulls/42"]["head"]["sha"] = NEW_HEAD
        self.advancements.append(copy.deepcopy(variables))
        return NEW_HEAD

    def set_content(self, name, head, data):
        self.routes[f"/repos/{p.REPO}/contents/{name}?ref={head}"] = blob(name, data)


def install_coordinator(api):
    api.routes.update({
        "/repos/" + p.REPO: {"default_branch": "main"},
        f"/repos/{p.REPO}/git/ref/heads/main": ref("main", DEFAULT),
        f"/repos/{p.REPO}/git/ref/heads/{p.BRANCH}": ref(p.BRANCH, HEAD),
        f"/repos/{p.REPO}/pulls/42": pull(),
    })
    api.page_routes[f"/repos/{p.REPO}/pulls?state=open&head=dc0d32:{p.BRANCH}", None] = [
        {"number": 42}]
    for head in (HEAD, DEFAULT):
        api.set_content(p.REQUEST, head, json.dumps(request()) + "\n")
        api.set_content(p.PIN, head, "# Keep this comment and formatting.\n" +
                        p.nix_literal(pin_data()) + "\n")
        api.set_content("flake.lock", head, json.dumps(lock_data(), indent=2) + "\n")
        api.set_content("flake.nix", head, '{ inputs.wezterm-src.url = '
                        f'"git+https://github.com/wezterm/wezterm?rev={OLD_SHA}&submodules=1"; }}\n')


def install_release(api, req=None):
    data = zip_bytes()
    proof = manifest(data, req)
    release = {"id": 301, "immutable": True, "draft": False, "prerelease": False,
               "tag_name": "wezterm-" + proof["build_id"], "assets": []}
    contents = [
        (proof["asset_name"], data),
        ("provenance.json", json.dumps(proof).encode()),
        ("SHA256SUMS", f"{proof['sha256']}  {proof['asset_name']}\n".encode()),
    ]
    for number, (name, payload) in enumerate(contents, 201):
        url = f"{p.API}/repos/{p.BUILDS}/releases/assets/{number}"
        release["assets"].append({
            "id": number, "name": name, "state": "uploaded", "size": len(payload),
            "digest": "sha256:" + hashlib.sha256(payload).hexdigest(), "url": url,
        })
        api.raw_routes[url] = payload
    prefix = f"/repos/{p.BUILDS}/actions/runs/9001/attempts/2"
    api.routes.update({
        "/repos/" + p.BUILDS: {"default_branch": "main"},
        prefix: {
            "id": 9001, "run_attempt": 2, "path": ".github/workflows/windows-build.yml",
            "event": "schedule", "head_repository": {"full_name": p.BUILDS},
            "head_branch": "main", "head_sha": BUILD_HEAD,
            "status": "completed", "conclusion": "success",
        },
        f"/repos/{p.BUILDS}/git/ref/tags/{release['tag_name']}": {
            "ref": "refs/tags/" + release["tag_name"],
            "object": {"type": "commit", "sha": BUILD_HEAD},
        },
        f"/repos/{p.BUILDS}/releases/301": release,
    })
    api.page_routes[prefix + "/jobs", "jobs"] = [
        {"name": name, "run_id": 9001, "run_attempt": 2,
         "status": "completed", "conclusion": "success"}
        for name in ("build", "publish")
    ]
    api.page_routes[f"/repos/{p.BUILDS}/releases", None] = [release]
    api.routes[f"/repos/{p.SOURCE}"] = {"default_branch": "main"}
    for name in ("main", SHA):
        api.routes[f"/repos/{p.SOURCE}/commits/{name}"] = {
            "sha": SHA, "commit": {"committer": {"date": DATE}}}
    return release, proof


def change(obj, path, value):
    for part in path[:-1]:
        obj = obj[part]
    obj[path[-1]] = value


class PipelineCase(unittest.TestCase):
    def setUp(self):
        self.stack = contextlib.ExitStack()
        self.addCleanup(self.stack.close)
        self.stack.enter_context(mock.patch.dict(os.environ, {}, clear=True))
        self.stack.enter_context(mock.patch.object(
            subprocess, "run", side_effect=AssertionError("actual command forbidden")))
        self.stack.enter_context(mock.patch.object(
            urllib.request.OpenerDirector, "open",
            side_effect=AssertionError("actual network forbidden")))
        self.own = FakeAPI()
        self.public = FakeAPI()
        install_coordinator(self.own)
        install_coordinator(self.public)
        self.release, self.manifest = install_release(self.public)

    def plan(self):
        return p.inspect(self.own, self.public)

    def scratch(self):
        parent = ROOT / "tests" / ".test-work"
        path = parent / uuid.uuid4().hex
        path.mkdir(parents=True)

        def cleanup():
            shutil.rmtree(path)
            if parent.exists() and not any(parent.iterdir()):
                parent.rmdir()

        self.addCleanup(cleanup)
        return path

    def candidate(self):
        path = self.scratch()
        for name in (p.PIN, "flake.lock", "flake.nix"):
            target = path / name
            target.parent.mkdir(parents=True, exist_ok=True)
            raw, _ = p.content(self.public, name, HEAD)
            target.write_bytes(raw)
        return path

    def rejected(self, fn, *args, message=None):
        with self.assertRaises(ValueError) as error:
            fn(*args)
        if message:
            self.assertIn(message, str(error.exception))


class RequestTests(PipelineCase):
    def test_request_must_be_object(self):
        for obj in (None, [], list(request()), "request", True):
            with self.subTest(obj=obj):
                self.rejected(p.validate_request, obj)

    def test_exact_contract_keys(self):
        self.assertEqual(set(request()), p.REQUEST_KEYS)
        self.assertEqual(p.validate_request(request()), request())

    def test_hash_material_has_no_trailing_newline(self):
        req = request()
        self.assertNotEqual(req["request_id"], hashlib.sha256(
            f"{p.REPO}\n{p.BRANCH}\n{SHA}\n12345\n".encode()).hexdigest())
        self.assertEqual(p.make_request(SHA, "12345", dt.datetime(
            2026, 10, 11, 15, 30, tzinfo=dt.timezone.utc)), req)

    def test_make_request_normalizes_timezone(self):
        now = dt.datetime(2026, 10, 11, 8, 30, tzinfo=dt.timezone(dt.timedelta(hours=-7)))
        self.assertEqual(p.make_request(SHA, "12345", now)["requested_at"],
                         "2026-10-11T15:30:00Z")

    def test_fractional_utc_date(self):
        for fraction in (".1", ".123456"):
            req = request()
            req["requested_at"] = "2026-10-11T15:30:00" + fraction + "Z"
            self.assertEqual(p.validate_request(req), req)

    def test_missing_each_request_key(self):
        for key in p.REQUEST_KEYS:
            with self.subTest(key=key):
                req = request()
                del req[key]
                self.rejected(p.validate_request, req)

    def test_duplicate_json_nested_keys_rejected(self):
        for raw in ('{"schema":1,"schema":1}', '{"x":{"a":1,"a":2}}'):
            with self.subTest(raw=raw):
                self.rejected(p.parse, raw, message="duplicate")

    def test_nonfinite_json_rejected(self):
        for raw in ("NaN", "Infinity", "-Infinity", '{"x": NaN}'):
            with self.subTest(raw=raw):
                self.rejected(p.parse, raw)

    def test_encoded_json_roundtrip(self):
        self.assertEqual(p.decode(p.encode(request())), request())

    def test_encoded_json_rejects_duplicate_and_bad_base64(self):
        self.rejected(p.decode, base64.b64encode(b'{"x":1,"x":2}').decode())
        self.rejected(p.decode, "not base64!")


class SnapshotTests(PipelineCase):
    def test_list_summary_cannot_replace_full_pr_validation(self):
        key = (f"/repos/{p.REPO}/pulls?state=open&head=dc0d32:{p.BRANCH}", None)
        self.own.page_routes[key] = [pull()]
        self.own.routes[f"/repos/{p.REPO}/pulls/42"]["head"]["repo"]["fork"] = True
        self.rejected(p.snapshot, self.own)

    def test_default_branch_changed_rejects_old_base(self):
        self.own.routes["/repos/" + p.REPO]["default_branch"] = "stable"
        self.own.routes[f"/repos/{p.REPO}/git/ref/heads/stable"] = ref("stable", DEFAULT)
        self.rejected(p.snapshot, self.own)

    def test_ref_changes_between_optional_probe_and_exact_read(self):
        path = f"/repos/{p.REPO}/git/ref/heads/{p.BRANCH}"
        count = 0

        def race(route):
            nonlocal count
            if route == path:
                count += 1
                if count == 2:
                    self.own.routes[path] = ref(p.BRANCH, NEW_HEAD)

        self.own.on_get = race
        self.rejected(p.snapshot, self.own)
        self.assertEqual(count, 2)

    def test_snapshot_reads_full_pr_and_exact_refs(self):
        snap = p.snapshot(self.own)
        self.assertEqual(snap, {
            "default_branch": "main", "default_sha": DEFAULT, "head": HEAD,
            "branch_exists": True, "pr_number": 42,
        })
        self.assertIn(f"/repos/{p.REPO}/pulls/42", self.own.reads)

    def test_no_pr_is_noop(self):
        self.own.page_routes[f"/repos/{p.REPO}/pulls?state=open&head=dc0d32:{p.BRANCH}", None] = []
        self.assertIsNone(p.snapshot(self.own))
        self.assertEqual(p.snapshot(self.own, False)["head"], HEAD)

    def test_absent_branch_weekly_starts_from_default(self):
        self.own.page_routes[f"/repos/{p.REPO}/pulls?state=open&head=dc0d32:{p.BRANCH}", None] = []
        self.own.routes[f"/repos/{p.REPO}/git/ref/heads/{p.BRANCH}"] = urllib.error.HTTPError(
            "https://api.github.com", 404, "missing", {}, None)
        snap = p.snapshot(self.own, False)
        self.assertFalse(snap["branch_exists"])
        self.assertEqual(snap["head"], DEFAULT)

    def test_ambiguous_prs_rejected(self):
        self.own.page_routes[f"/repos/{p.REPO}/pulls?state=open&head=dc0d32:{p.BRANCH}", None] += [
            {"number": 43}]
        self.rejected(p.snapshot, self.own, message="ambiguous")

    def test_head_ref_race_rejected(self):
        self.own.routes[f"/repos/{p.REPO}/git/ref/heads/{p.BRANCH}"]["object"]["sha"] = NEW_HEAD
        self.rejected(p.snapshot, self.own)

    def test_ref_requires_commit_identity(self):
        path = f"/repos/{p.REPO}/git/ref/heads/{p.BRANCH}"
        for fields in ({"ref": "refs/tags/wrong"}, {"object": {"type": "tag", "sha": HEAD}}):
            with self.subTest(fields=fields):
                original = self.own.routes[path]
                self.own.routes[path] = dict(original, **fields)
                self.rejected(p.branch_ref, self.own, p.BRANCH)
                self.own.routes[path] = original

    def test_optional_only_suppresses_404(self):
        path = "/missing"
        for code in (401, 403, 429, 500):
            self.own.routes[path] = urllib.error.HTTPError(path, code, "error", {}, None)
            with self.subTest(code=code), self.assertRaises(urllib.error.HTTPError):
                p.optional(self.own, path)

    def test_request_content_blob_tampering_rejected(self):
        path = f"/repos/{p.REPO}/contents/{p.REQUEST}?ref={HEAD}"
        self.own.routes[path]["content"] = base64.b64encode(b" " * self.own.routes[path]["size"]).decode()
        self.rejected(p.content, self.own, p.REQUEST, HEAD, message="blob identity")

    def test_content_read_uses_immutable_sha(self):
        raw, identity = p.content(self.own, p.REQUEST, HEAD)
        self.assertEqual(json.loads(raw), request())
        self.assertEqual(identity, blob(p.REQUEST, raw)["sha"])
        self.assertEqual(self.own.reads[-1], f"/repos/{p.REPO}/contents/{p.REQUEST}?ref={HEAD}")


class InspectTests(PipelineCase):
    def completed(self, with_source=True, with_hash=True):
        for head in (DEFAULT, HEAD):
            self.own.set_content(p.PIN, head, p.nix_literal(pin_data(with_hash)) + "\n")
        self.own.set_content("flake.lock", HEAD, json.dumps(lock_data(with_source)))
        plan = self.plan()
        for path, text in p.promotion_files(self.own, plan, SOURCE_HASH, CARGO_HASH).items():
            self.own.set_content(path, HEAD, text)
        self.status_route = f"/repos/{p.REPO}/commits/{HEAD}/statuses"
        self.own.page_routes[self.status_route, None] = [
            {"context": "wezterm/native-linux", "state": "success"}]
        return plan

    def test_completed_promotion_skips_without_commands_or_writes(self):
        self.completed()
        with mock.patch.object(p, "discover_hashes", side_effect=AssertionError("Cargo discovery")), \
                mock.patch.object(p, "status", side_effect=AssertionError("status reset")):
            self.assertIsNone(self.plan())
        self.assertIn(("pages", self.status_route, None), self.own.calls)
        self.assertNotIn(("pages", self.status_route, None), self.public.calls)
        self.assertEqual(self.own.writes + self.public.writes, [])

    def test_completed_promotion_compares_current_prefetched_metadata(self):
        plan = self.completed()
        raw, _ = p.content(self.own, "flake.lock", HEAD)
        lock = p.parse(raw)
        lock["nodes"]["wezterm-src"]["locked"] = source_locked()
        self.own.set_content("flake.lock", HEAD, json.dumps(lock))
        with mock.patch.object(p, "promotion_files", wraps=p.promotion_files) as promotion:
            self.assertTrue(p.completed_promotion(self.own, plan))
        self.assertEqual(promotion.call_args.kwargs["source_locked"], source_locked())
        for key, value in (("lastModified", 123), ("rev", OLD_SHA), ("revCount", True)):
            with self.subTest(key=key):
                lock["nodes"]["wezterm-src"]["locked"] = dict(source_locked(), **{key: value})
                self.own.set_content("flake.lock", HEAD, json.dumps(lock))
                self.assertFalse(p.completed_promotion(self.own, plan))
        self.assertEqual(self.own.writes + self.public.writes, [])

    def test_completed_promotion_cli_reports_ineligible(self):
        self.completed()
        with mock.patch.object(p, "PublicAPI", return_value=self.public), \
                mock.patch.object(p, "OwnAPI", return_value=self.own), \
                mock.patch.object(p, "verify_runtime"), \
                mock.patch.dict(os.environ, {
                    "GITHUB_REPOSITORY": p.REPO, "GITHUB_TOKEN": "token",
                    "GITHUB_EVENT_NAME": "schedule", "GITHUB_REF": "refs/heads/main"}), \
                mock.patch("sys.argv", ["promote-wezterm", "inspect"]), \
                contextlib.redirect_stdout(io.StringIO()) as out:
            p.main()
        self.assertEqual(out.getvalue(), "eligible=false\nhead=\nrequest=\ndefault_sha=\nplan=\n")
        self.assertEqual(self.own.writes + self.public.writes, [])

    def test_completed_legacy_and_lock_only_pins_skip(self):
        for with_source, with_hash in ((False, True), (True, False), (True, True)):
            with self.subTest(source=with_source, hash=with_hash):
                self.completed(with_source, with_hash)
                self.assertIsNone(self.plan())

    def test_completed_pin_comments_and_lock_format_are_not_identity(self):
        self.completed()
        raw, _ = p.content(self.own, p.PIN, HEAD)
        self.own.set_content(p.PIN, HEAD, "# preserved comment\n" + raw.decode())
        raw, _ = p.content(self.own, "flake.lock", HEAD)
        self.own.set_content("flake.lock", HEAD, p.canonical(p.parse(raw)) + "\n")
        self.assertIsNone(self.plan())

    def test_completed_repository_pin_deduplicates_formatted_promotion(self):
        original = (ROOT / p.PIN).read_text()
        for head in (HEAD, DEFAULT):
            self.own.set_content(p.PIN, head, original)
        plan = self.plan()
        files = p.promotion_files(self.own, plan, SOURCE_HASH, CARGO_HASH)
        for path, text in files.items():
            self.own.set_content(path, HEAD, text)
        self.assertEqual(p.promotion_files(self.own, plan, SOURCE_HASH, CARGO_HASH), files)
        self.own.page_routes[f"/repos/{p.REPO}/commits/{HEAD}/statuses", None] = [
            {"context": "wezterm/native-linux", "state": "success"}]
        self.assertTrue(p.completed_promotion(self.own, plan))
        self.assertIsNone(self.plan())
        self.assertEqual(self.own.writes + self.public.writes, [])

    def test_newest_matching_status_controls_retry_without_status_sha(self):
        expected = self.completed()
        success = {"context": "wezterm/native-linux", "state": "success"}
        for state in ("failure", "pending", "error", "success"):
            with self.subTest(state=state):
                self.own.page_routes[self.status_route, None] = [
                    {"context": "other/check", "state": "failure"},
                    {"context": success["context"], "state": state}, success]
                self.assertEqual(self.plan(), None if state == "success" else expected)
        self.own.page_routes[self.status_route, None] = []
        self.assertEqual(self.plan(), expected)
        self.own.page_routes[self.status_route, None] = [
            {"context": "other/check", "state": "success"}]
        self.assertEqual(self.plan(), expected)
        self.own.page_routes[self.status_route, None] = [success]
        self.assertIsNone(self.plan())
        self.assertEqual(self.own.writes + self.public.writes, [])

    def test_old_head_success_is_not_consulted(self):
        expected = self.completed()
        self.own.page_routes[f"/repos/{p.REPO}/commits/{OLD_SHA}/statuses", None] = [
            {"context": "wezterm/native-linux", "state": "success"}]
        self.own.page_routes[self.status_route, None] = []
        self.assertEqual(self.plan(), expected)
        self.assertFalse(any(call[0] == "pages" and f"/commits/{OLD_SHA}/statuses" in call[1]
                             for call in self.own.calls))

    def test_status_explicit_sha_must_be_current_head_if_present(self):
        expected = self.completed()
        for sha in (OLD_SHA, None, "main", HEAD):
            with self.subTest(sha=sha):
                self.own.page_routes[self.status_route, None] = [
                    {"context": "wezterm/native-linux", "state": "success", "sha": sha}]
                self.assertEqual(self.plan(), None if sha == HEAD else expected)

    def test_differing_pin_identity_or_windows_proof_never_skips(self):
        expected = self.completed()
        raw, _ = p.content(self.own, p.PIN, HEAD)
        original = p.validate_pin(raw.decode()).data
        mutations = [
            (("revision",), OLD_SHA), (("commitDate",), "2026-10-10T07:40:11Z"),
            (("version",), "20261010-073911-bbbbbbbb"), (("cargoHash",), "invalid"),
            (("cargoHash",), p.FAKE_HASH), (("sourceHash",), CARGO_HASH),
            (("sourceHash",), "invalid"),
            (("assets", "windows", "status"), "bootstrap-unpromoted"),
            (("assets", "windows", "assetId"), 999),
            (("assets", "windows", "url"), f"{p.API}/repos/{p.BUILDS}/releases/assets/999"),
            (("assets", "windows", "headers"), {"Accept": "application/json"}),
            (("assets", "windows", "size"), 123),
            (("assets", "windows", "archiveRoot"), "WezTerm-windows-20261010-073911-bbbbbbbb"),
            (("assets", "windows", "architectures"), ["aarch64"]),
            (("assets", "windows", "sourceRevision"), OLD_SHA),
            (("assets", "windows", "buildRepository"), p.SOURCE),
            (("assets", "windows", "buildId"), SHA + "-9002-2"),
            (("assets", "windows", "releaseTag"), "wezterm-" + SHA + "-9002-2"),
            (("assets", "windows", "runId"), 9002),
            (("assets", "windows", "runAttempt"), 3),
        ]
        for path, value in mutations:
            with self.subTest(path=path, value=value):
                pin = copy.deepcopy(original)
                change(pin, path, value)
                self.own.set_content(p.PIN, HEAD, p.nix_literal(pin))
                self.assertEqual(self.plan(), expected)
        pin = copy.deepcopy(original)
        pin["assets"]["windows"].update(sha256="1" * 64, hash=p.sri("1" * 64))
        self.own.set_content(p.PIN, HEAD, p.nix_literal(pin))
        self.assertEqual(self.plan(), expected)
        for key in ("sourceRevision", "runAttempt"):
            pin = copy.deepcopy(original)
            del pin["assets"]["windows"][key]
            self.own.set_content(p.PIN, HEAD, p.nix_literal(pin))
            self.assertEqual(self.plan(), expected)
        self.assertEqual(self.own.writes + self.public.writes, [])

    def test_differing_lock_or_literal_flake_revision_never_skips(self):
        expected = self.completed()
        raw, _ = p.content(self.own, "flake.lock", HEAD)
        original = p.parse(raw)
        for path, value in (
                (("locked", "rev"), OLD_SHA), (("locked", "narHash"), CARGO_HASH),
                (("locked", "narHash"), "invalid"), (("locked", "lastModified"), 123),
                (("locked", "submodules"), False), (("original", "rev"), OLD_SHA),
                (("original", "submodules"), False), (("original", "type"), "github")):
            with self.subTest(path=path):
                lock = copy.deepcopy(original)
                change(lock["nodes"]["wezterm-src"], path, value)
                self.own.set_content("flake.lock", HEAD, json.dumps(lock))
                self.assertEqual(self.plan(), expected)
        self.own.set_content("flake.lock", HEAD, raw)
        raw, _ = p.content(self.own, "flake.nix", HEAD)
        self.own.set_content("flake.nix", HEAD, raw.decode().replace(SHA, OLD_SHA))
        self.assertEqual(self.plan(), expected)
        self.own.set_content("flake.nix", HEAD, raw.decode().replace(
            f"?rev={SHA}", '?rev=${builtins.getEnv "REV"}'))
        self.assertEqual(self.plan(), expected)

    def test_trusted_pin_schema_is_reread_and_candidate_is_inert(self):
        expected = self.completed()
        original, _ = p.content(self.own, p.PIN, HEAD)
        for text in (original.decode().replace('sourceHash =', 'extraHash ='),
                     original.decode().replace('sourceHash =', '/* sourceHash =') + " */",
                     original.decode() + " // builtins.getEnv \"SECRET\""):
            with self.subTest(text=text):
                self.own.set_content(p.PIN, HEAD, text)
                self.assertEqual(self.plan(), expected)
        self.own.set_content(p.PIN, HEAD, original)
        self.own.set_content(p.PIN, DEFAULT, p.nix_literal(pin_data(False)))
        self.assertEqual(self.plan(), expected)
        self.assertIn(f"/repos/{p.REPO}/contents/{p.PIN}?ref={DEFAULT}", self.own.reads)

    def test_completed_skip_rechecks_source_and_head_after_status_read(self):
        expected = self.completed()
        for race in ("head", "source", "request", "default", "closed"):
            with self.subTest(race=race):
                own_routes = copy.deepcopy(self.own.routes)
                public_routes = copy.deepcopy(self.public.routes)

                def statuses(path, key=None):
                    self.assertEqual(path, self.status_route)
                    if race == "head":
                        self.own.routes[f"/repos/{p.REPO}/git/ref/heads/{p.BRANCH}"] = ref(
                            p.BRANCH, NEW_HEAD)
                    elif race == "source":
                        self.public.routes[f"/repos/{p.SOURCE}/commits/{SHA}"]["sha"] = NEW_HEAD
                    elif race == "request":
                        self.own.set_content(p.REQUEST, HEAD, json.dumps(request("99999")))
                    elif race == "default":
                        self.own.routes[f"/repos/{p.REPO}/git/ref/heads/main"] = ref("main", NEW_HEAD)
                    else:
                        self.own.routes[f"/repos/{p.REPO}/pulls/42"]["state"] = "closed"
                    yield {"context": "wezterm/native-linux", "state": "success"}

                with mock.patch.object(self.own, "pages", side_effect=lambda path, key=None: (
                        statuses(path, key) if path == self.status_route else iter(
                            copy.deepcopy(self.own.page_routes[path, key])))):
                    self.rejected(self.plan)
                self.own.routes = own_routes
                self.public.routes = public_routes
        self.assertEqual(p.recheck(self.own, self.public, expected), None)
        self.assertIsNone(self.plan())

    def test_inspect_no_pr_is_noop_before_request_or_upstream_read(self):
        key = (f"/repos/{p.REPO}/pulls?state=open&head=dc0d32:{p.BRANCH}", None)
        self.own.page_routes[key] = []
        self.assertIsNone(self.plan())
        self.assertFalse(any("/contents/" in route for route in self.own.reads))
        self.assertEqual(self.public.reads, [])

    def test_inspect_final_recheck_detects_close_while_reading_release(self):
        def close(route):
            if route == f"/repos/{p.BUILDS}/actions/runs/9001/attempts/2":
                self.own.routes[f"/repos/{p.REPO}/pulls/42"]["state"] = "closed"

        self.public.on_get = close
        self.rejected(self.plan)

    def test_valid_release_plan(self):
        plan = self.plan()
        self.assertEqual(plan["version"], VERSION)
        self.assertEqual(plan["release"]["asset_id"], 201)
        self.assertEqual(plan["release"]["manifest"], self.manifest)
        self.assertEqual(self.own.writes, [])
        self.assertEqual(self.public.writes, [])

    def test_missing_request_is_noop(self):
        self.own.routes[f"/repos/{p.REPO}/contents/{p.REQUEST}?ref={HEAD}"] = urllib.error.HTTPError(
            p.API, 404, "missing", {}, None)
        self.assertIsNone(self.plan())

    def test_missing_release_is_noop(self):
        self.public.page_routes[f"/repos/{p.BUILDS}/releases", None] = []
        self.assertIsNone(self.plan())

    def test_upstream_advance_does_not_supersede_request(self):
        self.public.routes[f"/repos/{p.SOURCE}/commits/main"]["sha"] = NEW_HEAD
        plan = self.plan()
        self.assertEqual(plan["request"]["source_sha"], SHA)
        self.assertEqual(plan["version"], VERSION)
        self.assertEqual([route for route in self.public.reads
                          if route.startswith(f"/repos/{p.SOURCE}")],
                         [f"/repos/{p.SOURCE}/commits/{SHA}"] * 2)

    def test_inspect_does_not_need_latest_branch_or_metadata(self):
        del self.public.routes[f"/repos/{p.SOURCE}"]
        del self.public.routes[f"/repos/{p.SOURCE}/commits/main"]
        self.assertEqual(self.plan()["request"]["source_sha"], SHA)

    def test_invalid_request_fails_closed(self):
        req = request()
        req["schema"] = True
        self.own.set_content(p.REQUEST, HEAD, json.dumps(req))
        self.rejected(self.plan)

    def test_cross_request_source_dedup(self):
        self.release, self.manifest = install_release(self.public, request("99999"))
        plan = self.plan()
        self.assertNotEqual(plan["request"]["request_id"],
                            plan["release"]["manifest"]["request_id"])
        self.assertEqual(plan["release"]["asset_id"], 201)

    def test_recheck_branch_update_same_request_rejected(self):
        plan = self.plan()
        self.own.routes[f"/repos/{p.REPO}/git/ref/heads/{p.BRANCH}"]["object"]["sha"] = NEW_HEAD
        self.own.routes[f"/repos/{p.REPO}/pulls/42"]["head"]["sha"] = NEW_HEAD
        self.rejected(p.recheck, self.own, self.public, plan, message="superseded")

    def test_recheck_request_blob_change_rejected(self):
        plan = self.plan()
        self.own.set_content(p.REQUEST, HEAD, json.dumps(request("99999")))
        self.rejected(p.recheck, self.own, self.public, plan, message="request superseded")

    def test_recheck_default_head_change_rejected(self):
        plan = self.plan()
        self.own.routes[f"/repos/{p.REPO}/git/ref/heads/main"]["object"]["sha"] = NEW_HEAD
        self.rejected(p.recheck, self.own, self.public, plan)

    def test_recheck_source_commit_change_rejected(self):
        plan = self.plan()
        self.public.routes[f"/repos/{p.SOURCE}/commits/{SHA}"]["sha"] = NEW_HEAD
        self.rejected(p.recheck, self.own, self.public, plan)

    def test_recheck_source_timestamp_change_rejected(self):
        plan = self.plan()
        self.public.routes[f"/repos/{p.SOURCE}/commits/{SHA}"]["commit"]["committer"]["date"] = (
            "2026-10-10T07:40:11Z")
        self.rejected(p.recheck, self.own, self.public, plan)

    def test_source_date_normalizes_utc(self):
        self.public.routes[f"/repos/{p.SOURCE}/commits/{SHA}"]["commit"]["committer"]["date"] = (
            "2026-10-10T08:39:11+01:00")
        self.assertEqual(p.source_info(self.public, SHA), (SHA, DATE, VERSION))

    def test_source_exact_commit_mismatch_rejected(self):
        self.public.routes[f"/repos/{p.SOURCE}/commits/{SHA}"]["sha"] = OLD_SHA
        self.rejected(p.source_info, self.public, SHA)

    def test_source_resolves_valid_default_branch_with_quoted_slashes(self):
        metadata = f"/repos/{p.SOURCE}"
        for branch in ("main", "stable-1.2", "_default", "release/main", "refs/heads/main"):
            with self.subTest(branch=branch):
                self.public.reads.clear()
                self.public.routes[metadata] = {"default_branch": branch}
                route = f"{metadata}/commits/{urllib.parse.quote(branch, safe='')}"
                self.public.routes[route] = {
                    "sha": SHA, "commit": {"committer": {"date": DATE}}}
                self.assertEqual(p.source_info(self.public), (SHA, DATE, VERSION))
                self.assertEqual(self.public.reads, [metadata, route])
        self.assertEqual(self.own.writes + self.public.writes, [])

    def test_source_invalid_default_branch_metadata_has_no_fallback(self):
        metadata = f"/repos/{p.SOURCE}"
        invalid = (None, True, 123, [], "main", {}, {"default_branch": None},
                   {"default_branch": True}, {"default_branch": 123},
                   {"default_branch": []})
        branches = ("", " main", "main ", "main\n", "../main", "main/../next",
                    "main//next", "/main", "main/", ".main", "main/.next",
                    "main.lock", "main/next.lock", "main.", "-main", "main?ref=next",
                    "main#next", "main%2Fnext", "main\\next", "main@{next",
                    "main:next", "https://evil.invalid/main", "a" * 256)
        for obj in (*invalid, *({"default_branch": branch} for branch in branches)):
            with self.subTest(metadata=obj):
                self.public.reads.clear()
                self.public.routes[metadata] = obj
                self.rejected(p.source_info, self.public)
                self.assertEqual(self.public.reads, [metadata])

    def test_source_missing_metadata_has_no_fallback(self):
        route = f"/repos/{p.SOURCE}"
        error = urllib.error.HTTPError(p.API + route, 404, "missing metadata", {}, None)
        self.public.routes[route] = error
        with self.assertRaises(urllib.error.HTTPError) as caught:
            p.source_info(self.public)
        self.assertIs(caught.exception, error)
        self.assertEqual(self.public.reads, [route])

    def test_missing_default_branch_does_not_fall_back_to_main(self):
        metadata = f"/repos/{p.SOURCE}"
        self.public.routes[metadata] = {"default_branch": "release/next"}
        route = metadata + "/commits/release%2Fnext"
        error = urllib.error.HTTPError(p.API + route, 404, "missing branch", {}, None)
        self.public.routes[route] = error
        with self.assertRaises(urllib.error.HTTPError) as caught:
            p.source_info(self.public)
        self.assertIs(caught.exception, error)
        self.assertEqual(self.public.reads, [metadata, route])
        self.assertEqual(self.own.writes + self.public.writes, [])

    def test_source_exact_commit_skips_default_branch_metadata(self):
        self.public.routes[f"/repos/{p.SOURCE}"] = None
        self.assertEqual(p.source_info(self.public, SHA), (SHA, DATE, VERSION))
        self.assertEqual(self.public.reads, [f"/repos/{p.SOURCE}/commits/{SHA}"])

    def test_source_missing_exact_commit_has_no_branch_fallback(self):
        route = f"/repos/{p.SOURCE}/commits/{SHA}"
        error = urllib.error.HTTPError(p.API + route, 404, "missing commit", {}, None)
        self.public.routes[route] = error
        with self.assertRaises(urllib.error.HTTPError) as caught:
            p.source_info(self.public, SHA)
        self.assertIs(caught.exception, error)
        self.assertEqual(self.public.reads, [route])

    def test_source_naive_timestamp_rejected(self):
        self.public.routes[f"/repos/{p.SOURCE}/commits/main"]["commit"]["committer"]["date"] = (
            "2026-10-10T07:39:11")
        self.rejected(p.source_info, self.public)


class ReleaseTests(PipelineCase):
    def test_manifest_missing_each_field_rejected(self):
        for key in p.MANIFEST_KEYS:
            with self.subTest(key=key):
                obj = copy.deepcopy(self.manifest)
                del obj[key]
                self.rejected(p.validate_manifest, obj)

    def test_archive_manifest_hash_mismatch_rejected(self):
        self.manifest["sha256"] = "0" * 64
        self.replace_asset(1, json.dumps(self.manifest).encode())
        self.replace_asset(2, f"{self.manifest['sha256']}  {self.manifest['asset_name']}\n".encode())
        self.rejected(p.validate_release, self.public, self.release, SHA, VERSION,
                      message="archive identity")

    def test_manifest_source_and_requested_version_bound_to_release(self):
        self.rejected(p.validate_release, self.public, self.release, OLD_SHA, VERSION)
        self.rejected(p.validate_release, self.public, self.release, SHA,
                      "20261010-073912-aaaaaaaa")

    def test_release_rejects_identical_bytes_with_wrong_asset_size(self):
        asset = copy.deepcopy(self.release["assets"][0])
        asset["size"] += 1
        self.rejected(p.release_asset, self.public, asset, p.MAX_ZIP)

    def test_asset_metadata_over_limit_rejected_before_download(self):
        asset = copy.deepcopy(self.release["assets"][0])
        asset["size"] = 1025
        self.rejected(p.release_asset, self.public, asset, 1024)
        self.assertFalse(any(call[0] == "raw" for call in self.public.calls))

    def test_malformed_deflate_release_does_not_hide_later_valid_release(self):
        data = bytearray(zip_bytes(compression=zipfile.ZIP_DEFLATED))
        filename_size, extra_size = struct.unpack_from("<HH", data, 26)
        offset = 30 + filename_size + extra_size
        # BTYPE=3 is reserved and fails before any output allocation.
        data[offset] = 0x07
        broken = copy.deepcopy(self.release)
        bad_manifest = manifest(data)
        payloads = (
            bytes(data), json.dumps(bad_manifest).encode(),
            f"{bad_manifest['sha256']}  {bad_manifest['asset_name']}\n".encode(),
        )
        for asset, payload in zip(broken["assets"], payloads):
            asset["id"] += 1000
            asset["url"] = f"{p.API}/repos/{p.BUILDS}/releases/assets/{asset['id']}"
            asset["size"] = len(payload)
            asset["digest"] = "sha256:" + hashlib.sha256(payload).hexdigest()
            self.public.raw_routes[asset["url"]] = payload
        self.public.page_routes[f"/repos/{p.BUILDS}/releases", None] = [broken, self.release]
        with contextlib.redirect_stderr(io.StringIO()):
            result = p.find_release(self.public, SHA, VERSION)
        self.assertEqual(result["asset_id"], 201)

    def test_full_immutable_release(self):
        proof = p.validate_release(self.public, self.release, SHA, VERSION)
        self.assertEqual(proof, {"release_id": 301, "asset_id": 201, "manifest": self.manifest})
        reads = [call for call in self.public.calls if call[0] == "raw"]
        self.assertEqual(len(reads), 3)
        self.assertTrue(all(call[3] for call in reads))

    def test_dispatch_run_supported(self):
        self.public.routes[f"/repos/{p.BUILDS}/actions/runs/9001/attempts/2"]["event"] = (
            "workflow_dispatch")
        self.assertEqual(p.prove_run(self.public, self.manifest)["head_sha"], BUILD_HEAD)

    def test_asset_names_must_be_unique(self):
        self.release["assets"][0]["name"] = "provenance.json"
        self.rejected(p.validate_release, self.public, self.release, SHA, VERSION)

    def test_extra_assets_rejected(self):
        self.release["assets"].append(copy.deepcopy(self.release["assets"][0]))
        self.rejected(p.validate_release, self.public, self.release, SHA, VERSION)

    def test_asset_byte_digest_tampering(self):
        url = self.release["assets"][0]["url"]
        self.public.raw_routes[url] = b"x" * self.release["assets"][0]["size"]
        self.rejected(p.validate_release, self.public, self.release, SHA, VERSION,
                      message="digest/size")

    def test_manifest_duplicate_json_keys_rejected(self):
        self.replace_asset(1, b'{"schema":1,"schema":1}')
        self.rejected(p.validate_release, self.public, self.release, SHA, VERSION)

    def replace_asset(self, index, data):
        asset = self.release["assets"][index]
        self.public.raw_routes[asset["url"]] = data
        asset["size"] = len(data)
        asset["digest"] = "sha256:" + hashlib.sha256(data).hexdigest()

    def test_checksum_exact_newline_and_archive_name(self):
        for payload in (
            f"{self.manifest['sha256']}  other.zip\n",
            f"{self.manifest['sha256']}  {self.manifest['asset_name']}",
            f"{self.manifest['sha256']} {self.manifest['asset_name']}\n",
        ):
            with self.subTest(payload=payload):
                self.replace_asset(2, payload.encode())
                self.rejected(p.validate_release, self.public, self.release, SHA, VERSION,
                              message="SHA256SUMS")

    def test_manifest_size_must_match_archive(self):
        self.manifest["size"] += 1
        self.replace_asset(1, json.dumps(self.manifest).encode())
        self.rejected(p.validate_release, self.public, self.release, SHA, VERSION)

    def test_release_missing_asset(self):
        del self.release["assets"][0]
        self.rejected(p.validate_release, self.public, self.release, SHA, VERSION)

    def test_duplicate_jobs_rejected(self):
        key = (f"/repos/{p.BUILDS}/actions/runs/9001/attempts/2/jobs", "jobs")
        self.public.page_routes[key].append(copy.deepcopy(self.public.page_routes[key][0]))
        self.rejected(p.prove_run, self.public, self.manifest)

    def test_missing_publish_job_rejected(self):
        self.public.page_routes[
            f"/repos/{p.BUILDS}/actions/runs/9001/attempts/2/jobs", "jobs"].pop()
        self.rejected(p.prove_run, self.public, self.manifest)

    def test_missing_build_job_rejected(self):
        self.public.page_routes[
            f"/repos/{p.BUILDS}/actions/runs/9001/attempts/2/jobs", "jobs"].pop(0)
        self.rejected(p.prove_run, self.public, self.manifest)

    def test_find_release_skips_invalid_and_unrelated(self):
        invalid = copy.deepcopy(self.release)
        invalid["immutable"] = False
        self.public.page_routes[f"/repos/{p.BUILDS}/releases", None] = [
            {"tag_name": "unrelated"}, invalid, self.release]
        with contextlib.redirect_stderr(io.StringIO()):
            result = p.find_release(self.public, SHA, VERSION)
        self.assertEqual(result["release_id"], 301)

    def test_find_release_never_adopts_failed_run(self):
        self.public.routes[f"/repos/{p.BUILDS}/actions/runs/9001/attempts/2"]["conclusion"] = "failure"
        with contextlib.redirect_stderr(io.StringIO()):
            self.assertIsNone(p.find_release(self.public, SHA, VERSION))


class ZipTests(PipelineCase):
    def test_single_member_size_bomb_rejected_before_read(self):
        data = bytearray(zip_bytes())
        offset = data.index(b"PK\x01\x02")
        struct.pack_into("<I", data, offset + 24, 512 * 1024 * 1024 + 1)
        self.rejected(p.check_zip, data, "WezTerm-windows-" + VERSION, message="expansion")

    def test_member_count_limit_without_large_archive(self):
        with mock.patch.object(p.zipfile, "ZipFile") as archive:
            archive.return_value.__enter__.return_value.infolist.return_value = [None] * 10001
            self.rejected(p.check_zip, b"", "root", message="member count")

    def test_embedded_nul_filename_rejected(self):
        root = "WezTerm-windows-" + VERSION
        filename = (root + "/nulXsuffix").encode()
        data = zip_bytes(extra=((filename.decode(), b"x"),))
        self.rejected(p.check_zip, data.replace(filename, filename.replace(b"X", b"\0")), root)

    def test_malformed_deflate_is_rejected(self):
        data = bytearray(zip_bytes(compression=zipfile.ZIP_DEFLATED))
        filename_size, extra_size = struct.unpack_from("<HH", data, 26)
        data[30 + filename_size + extra_size] = 0x07
        with self.assertRaises((ValueError, zipfile.BadZipFile, zlib.error)):
            p.check_zip(data, "WezTerm-windows-" + VERSION)

    def test_explicit_directory_members_supported(self):
        root = "WezTerm-windows-" + VERSION
        p.check_zip(zip_bytes(extra=((root + "/", b""), (root + "/mesa/", b""))), root)

    def test_realistic_runtime_stored_and_deflated(self):
        for compression in (zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED):
            with self.subTest(compression=compression):
                p.check_zip(zip_bytes(compression=compression), "WezTerm-windows-" + VERSION)

    def test_each_required_runtime_member(self):
        for name in RUNTIME:
            with self.subTest(name=name):
                self.rejected(p.check_zip, zip_bytes(omit=(name,)),
                              "WezTerm-windows-" + VERSION, message="runtime")

    def test_wrong_root(self):
        self.rejected(p.check_zip, zip_bytes(root="wrong"), "WezTerm-windows-" + VERSION)

    def test_duplicate_entry(self):
        root = "WezTerm-windows-" + VERSION
        self.rejected(p.check_zip, zip_bytes(extra=((root + "/wezterm.exe", b"x"),)), root)

    def test_case_colliding_entry(self):
        root = "WezTerm-windows-" + VERSION
        self.rejected(p.check_zip, zip_bytes(extra=((root + "/WEZTERM.EXE", b"x"),)), root)

    def test_parent_directory_case_collision(self):
        root = "WezTerm-windows-" + VERSION
        self.rejected(p.check_zip, zip_bytes(extra=((root + "/Mesa/other.dll", b"x"),)), root)

    def test_file_directory_collision(self):
        root = "WezTerm-windows-" + VERSION
        self.rejected(p.check_zip, zip_bytes(extra=((root + "/mesa", b"x"),)), root)

    def test_symlink_and_special_entries(self):
        root = "WezTerm-windows-" + VERSION
        for mode in (stat.S_IFLNK, stat.S_IFIFO, stat.S_IFSOCK):
            entry = zipfile.ZipInfo(root + "/special")
            entry.create_system = 3
            entry.external_attr = (mode | 0o777) << 16
            with self.subTest(mode=mode):
                self.rejected(p.check_zip, zip_bytes(extra=((entry, b"target"),)), root)

    def test_unsupported_compression(self):
        root = "WezTerm-windows-" + VERSION
        self.rejected(p.check_zip, zip_bytes(compression=zipfile.ZIP_BZIP2), root)

    def test_crc_corruption_is_scanned(self):
        data = bytearray(zip_bytes())
        position = data.index(b"runtime:wezterm.exe")
        data[position] ^= 1
        with self.assertRaises(zipfile.BadZipFile):
            p.check_zip(data, "WezTerm-windows-" + VERSION)

    def test_empty_member(self):
        root = "WezTerm-windows-" + VERSION
        self.rejected(p.check_zip, zip_bytes(extra=((root + "/empty", b""),)), root)

    def test_encrypted_flag_rejected(self):
        data = bytearray(zip_bytes())
        for signature, flag_offset in ((b"PK\x03\x04", 6), (b"PK\x01\x02", 8)):
            offset = data.index(signature) + flag_offset
            flags = struct.unpack_from("<H", data, offset)[0]
            struct.pack_into("<H", data, offset, flags | 1)
        self.rejected(p.check_zip, data, "WezTerm-windows-" + VERSION)

    def test_expansion_limit_without_allocating_bomb(self):
        root = "WezTerm-windows-" + VERSION
        with mock.patch.object(p, "MAX_ZIP", 10):
            self.rejected(p.check_zip, zip_bytes(), root, message="expansion")

    def test_empty_zip(self):
        stream = io.BytesIO()
        with zipfile.ZipFile(stream, "w"):
            pass
        self.rejected(p.check_zip, stream.getvalue(), "WezTerm-windows-" + VERSION)


class NixDataTests(PipelineCase):
    def test_pin_fixture_validates(self):
        obj = pin_data()
        self.assertEqual(p.validate_pin(p.nix_literal(obj)).data, obj)

    def test_rewrite_preserves_comment_and_untouched_bytes(self):
        text = "# header\n{\n  revision = \"" + OLD_SHA + "\"; # keep\n  nested = [ 1 true ];\n}\n"
        parsed = p.NixData(text)
        rewritten = parsed.rewrite({("revision",): SHA})
        self.assertEqual(rewritten, text.replace(OLD_SHA, SHA))
        self.assertEqual(p.NixData(rewritten).data["nested"], [1, True])

    def test_pin_renderer_multiline_fields_and_inline_headers(self):
        value = {"status": "promoted", "headers": {"Accept": "application/octet-stream"},
                 "architectures": ["x86_64"], "size": 123}
        rendered = p.nix_pin_literal(value, "    ")
        self.assertEqual(rendered, '{\n'
                         '      status = "promoted";\n'
                         '      headers = { Accept = "application/octet-stream"; };\n'
                         '      architectures = [ "x86_64" ];\n'
                         '      size = 123;\n'
                         '    }')
        self.assertEqual(p.NixData(rendered).data, value)
        self.assertNotIn("\n", p.nix_literal(value))

    def test_rewrite_uses_existing_field_indentation_or_path_depth(self):
        value = {"first": 1, "last": 2}
        for text, indent in (
                ("{\n    assets = {\n        windows = { }; # keep\n    };\n}\n", "        "),
                ("{ assets = { windows = { }; }; }\n", "    ")):
            with self.subTest(text=text):
                rewritten = p.NixData(text).rewrite({("assets", "windows"): value})
                self.assertEqual(rewritten, text.replace("{ };", p.nix_pin_literal(value, indent) + ";"))
                self.assertEqual(p.NixData(rewritten).data["assets"]["windows"], value)
                self.assertEqual(p.NixData(rewritten).rewrite({("assets", "windows"): value}), rewritten)

    def test_pin_renderer_safe_strings_lists_and_empty_containers(self):
        value = {"text": 'quote" slash\\ newline\n tab\t return\r café',
                 "items": ["x86_64", 'a"b', "c\\d"], "empty": {}, "none": []}
        rendered = p.nix_pin_literal(value)
        self.assertEqual(p.NixData(rendered).data, value)
        self.assertIn('café";', rendered)
        self.assertIn('items = [ "x86_64" "a\\"b" "c\\\\d" ];', rendered)
        self.assertIn("empty = { };", rendered)
        self.assertIn("none = [ ];", rendered)
        for bad in ("${builtins.readFile /etc/passwd}", "\x00", "\b", "\f",
                    {"bad-key!": 1}, {1: "value"}, None, 1.5):
            with self.subTest(bad=bad):
                self.rejected(p.nix_pin_literal, bad)

    def test_repository_pin_promotion_preserves_surrounding_bytes_and_order(self):
        original = (ROOT / p.PIN).read_text()
        for head in (HEAD, DEFAULT):
            self.own.set_content(p.PIN, head, original)
        plan = self.plan()
        files = p.promotion_files(self.own, plan, SOURCE_HASH, CARGO_HASH)
        rendered = files[p.PIN]
        before, after = p.validate_pin(original), p.validate_pin(rendered)
        expected = copy.deepcopy(before.data)
        expected.update(revision=SHA, commitDate=DATE, version=VERSION,
                        sourceHash=SOURCE_HASH, cargoHash=CARGO_HASH)
        windows = after.data["assets"]["windows"]
        expected["assets"]["windows"] = windows
        self.assertEqual(after.data, expected)
        self.assertEqual(list(windows), [
            "status", "assetId", "url", "headers", "hash", "sha256", "size",
            "archiveRoot", "architectures", "sourceRevision", "buildRepository",
            "buildId", "releaseTag", "runId", "runAttempt"])
        for key, value in (("status", "promoted"), ("assetId", 201),
                           ("sourceRevision", SHA), ("runId", 9001), ("runAttempt", 2)):
            self.assertEqual(windows[key], value)
        self.assertEqual(windows["hash"], p.sri(self.manifest["sha256"]))
        self.assertEqual(windows["headers"], {"Accept": "application/octet-stream"})
        self.assertEqual(windows["architectures"], ["x86_64"])
        self.assertIn('      headers = { Accept = "application/octet-stream"; };\n', rendered)
        self.assertIn('      architectures = [ "x86_64" ];\n', rendered)
        # Erase only the replaced value spans: all comments/field scaffolding must match.
        paths = [("revision",), ("commitDate",), ("version",), ("sourceHash",),
                 ("cargoHash",), ("assets", "windows")]
        def scaffold(parsed):
            text = parsed.text
            for start, end in sorted((parsed.spans[path] for path in paths), reverse=True):
                text = text[:start] + "<value>" + text[end:]
            return text
        self.assertEqual(scaffold(before), scaffold(after))
        self.assertEqual(after.rewrite({path: self.get_path(after.data, path) for path in paths}),
                         rendered)
        self.assertEqual(p.promotion_files(self.own, plan, SOURCE_HASH, CARGO_HASH), files)
        self.assertEqual((ROOT / p.PIN).read_text(), original)

    @staticmethod
    def get_path(value, path):
        for key in path:
            value = value[key]
        return value

    def test_comments_block_and_line_are_inert(self):
        parsed = p.NixData('/* import /evil */ { # ${not-code}\n x = "safe"; }')
        self.assertEqual(parsed.data, {"x": "safe"})

    def test_rewrite_missing_field_rejected(self):
        self.rejected(p.NixData("{}").rewrite, {("missing",): "value"})

    def test_literal_interpolation_rejected(self):
        self.rejected(p.nix_literal, "${builtins.readFile /etc/passwd}")

    def test_literal_invalid_keys_and_types_rejected(self):
        for obj in ({"x.y": 1}, {"bad-key!": 1}, None, 1.5):
            with self.subTest(obj=obj):
                self.rejected(p.nix_literal, obj)

    def test_schema_unknown_top_level_rejected(self):
        obj = pin_data()
        obj["executable"] = "bad"
        self.rejected(p.validate_pin, p.nix_literal(obj))

    def test_schema_unknown_windows_field_rejected(self):
        obj = pin_data()
        obj["assets"]["windows"]["command"] = "bad"
        self.rejected(p.validate_pin, p.nix_literal(obj))

    def test_schema_unknown_platform_rejected(self):
        obj = pin_data()
        obj["assets"]["darwin"] = {}
        self.rejected(p.validate_pin, p.nix_literal(obj))

    def test_sri_roundtrip_and_rejections(self):
        self.assertEqual(p.sri("00" * 32), p.FAKE_HASH)
        self.assertTrue(p.valid_sri(SOURCE_HASH))
        for value in (True, "sha256-no", SOURCE_HASH + "\n", "sha512-" + SOURCE_HASH[7:]):
            with self.subTest(value=value):
                self.assertFalse(p.valid_sri(value))


class NixPinFormatterTests(unittest.TestCase):
    """Optional native formatter oracle; never evaluate or build candidate Nix."""

    def test_repository_promotion_matches_available_nixpkgs_fmt(self):
        formatter = os.environ.get("NIXPKGS_FMT") or shutil.which("nixpkgs-fmt")
        if not formatter:
            self.skipTest("set NIXPKGS_FMT to the repository's locked formatter binary")
        original = (ROOT / p.PIN).read_text()
        own, public = FakeAPI(), FakeAPI()
        install_coordinator(own)
        install_coordinator(public)
        install_release(public)
        for head in (HEAD, DEFAULT):
            own.set_content(p.PIN, head, original)
        with mock.patch.object(subprocess, "run", side_effect=AssertionError("renderer command")), \
                mock.patch.object(urllib.request.OpenerDirector, "open",
                                  side_effect=AssertionError("renderer network")):
            plan = p.inspect(own, public)
            rendered = p.promotion_files(own, plan, SOURCE_HASH, CARGO_HASH)[p.PIN]
        for text in (original, rendered,
                     "{\n  value = " + p.nix_pin_literal({
                         "headers": {"Accept": 'quote" slash\\ line\n tab\t café'},
                         "architectures": ["x86_64", 'a"b', "c\\d"],
                         "empty": {}, "none": [],
                     }, "  ") + ";\n}\n"):
            with self.subTest(text=text):
                result = subprocess.run([formatter], input=text, text=True,
                                        capture_output=True, check=True, timeout=30)
                self.assertEqual(result.stdout, text)
                self.assertEqual(p.NixData(result.stdout).data, p.NixData(text).data)
        self.assertEqual((ROOT / p.PIN).read_text(), original)


class LockTests(PipelineCase):
    def test_weekly_bad_nonce_is_nonblocking(self):
        candidate = self.candidate()
        with mock.patch.object(p, "candidate_path", return_value=candidate), \
                mock.patch.object(p, "checked", return_value=""), \
                mock.patch.dict(os.environ, {"GITHUB_RUN_ID": "0"}), \
                contextlib.redirect_stderr(io.StringIO()):
            proposal = p.weekly(self.public, str(candidate))
        self.assertEqual(set(proposal["files"]), {"flake.lock"})

    def test_weekly_source_node_mutation_rejected(self):
        candidate = self.candidate()

        def update(*args):
            lock = json.loads((candidate / "flake.lock").read_text())
            lock["nodes"]["wezterm-src"]["locked"]["rev"] = SHA
            (candidate / "flake.lock").write_text(json.dumps(lock))
            return ""

        with mock.patch.object(p, "candidate_path", return_value=candidate), \
                mock.patch.object(p, "checked", side_effect=update):
            self.rejected(p.weekly, self.public, str(candidate))

    def test_weekly_unsafe_named_input_rejected_before_command(self):
        candidate = self.candidate()
        lock = lock_data()
        lock["nodes"]["root"]["inputs"]["--override-input"] = "nixpkgs"
        (candidate / "flake.lock").write_text(json.dumps(lock))
        with mock.patch.object(p, "candidate_path", return_value=candidate), \
                mock.patch.object(p, "checked") as checked:
            self.rejected(p.weekly, self.public, str(candidate), message="named root inputs")
            checked.assert_not_called()

    def test_weekly_updates_ordinary_input_only(self):
        old = lock_data()
        new = copy.deepcopy(old)
        new["nodes"]["nixpkgs"]["locked"]["rev"] = NEW_HEAD
        p.validate_weekly_lock(old, new)
        self.assertEqual(p.source_node(new), "wezterm-src")

    def test_source_lock_absent_supported(self):
        self.assertIsNone(p.source_node(lock_data(False)))
        p.validate_weekly_lock(lock_data(False), lock_data(False))

    def test_weekly_preserves_entire_source_node(self):
        old = lock_data()
        for field in ("locked", "original", "flake"):
            new = copy.deepcopy(old)
            new["nodes"]["wezterm-src"][field] = {} if field != "flake" else True
            with self.subTest(field=field):
                self.rejected(p.validate_weekly_lock, old, new)

    def test_weekly_rejects_root_input_changes(self):
        old = lock_data()
        new = copy.deepcopy(old)
        new["nodes"]["root"]["inputs"]["new-input"] = "nixpkgs"
        self.rejected(p.validate_weekly_lock, old, new)

    def test_weekly_rejects_schema_version_change(self):
        old = lock_data()
        new = copy.deepcopy(old)
        new["version"] = 8
        self.rejected(p.validate_weekly_lock, old, new)

    def test_weekly_rejects_followed_source_input(self):
        lock = lock_data()
        lock["nodes"]["root"]["inputs"]["wezterm-src"] = ["other", "wezterm-src"]
        self.rejected(p.source_node, lock)

    def test_weekly_named_inputs_exclude_source_pin_unchanged(self):
        candidate = self.candidate()
        pin_before = (candidate / p.PIN).read_bytes()
        old = json.loads((candidate / "flake.lock").read_text())

        def update(args, cwd=None):
            self.assertEqual(args, [
                "nix", "flake", "update", "home-manager", "nixpkgs",
                "--option", "accept-flake-config", "false"])
            self.assertEqual(cwd, candidate)
            updated = copy.deepcopy(old)
            updated["nodes"]["nixpkgs"]["locked"]["rev"] = NEW_HEAD
            (candidate / "flake.lock").write_text(json.dumps(updated))
            return ""

        with mock.patch.object(p, "candidate_path", return_value=candidate), \
                mock.patch.object(p, "checked", side_effect=update), \
                mock.patch.dict(os.environ, {"GITHUB_RUN_ID": "12345"}):
            proposal = p.weekly(self.public, str(candidate))
        self.assertEqual((candidate / p.PIN).read_bytes(), pin_before)
        updated = json.loads(proposal["files"]["flake.lock"])
        self.assertEqual(updated["nodes"]["wezterm-src"], old["nodes"]["wezterm-src"])
        self.assertEqual(set(proposal["files"]), {"flake.lock", p.REQUEST})
        p.validate_request(json.loads(proposal["files"][p.REQUEST]))

    def test_weekly_upstream_resolution_failure_nonblocking(self):
        candidate = self.candidate()
        self.public.routes[f"/repos/{p.SOURCE}/commits/main"] = urllib.error.URLError("offline")
        with mock.patch.object(p, "candidate_path", return_value=candidate), \
                mock.patch.object(p, "checked", return_value=""), \
                contextlib.redirect_stderr(io.StringIO()):
            proposal = p.weekly(self.public, str(candidate))
        self.assertEqual(set(proposal["files"]), {"flake.lock"})

    def test_weekly_pin_mutation_rejected(self):
        candidate = self.candidate()

        def update(*args):
            (candidate / p.PIN).write_text("changed")
            return ""

        with mock.patch.object(p, "candidate_path", return_value=candidate), \
                mock.patch.object(p, "checked", side_effect=update):
            self.rejected(p.weekly, self.public, str(candidate), message="changed pin")

    def test_weekly_candidate_starting_lock_mismatch_rejected(self):
        candidate = self.candidate()
        lock = lock_data()
        lock["nodes"]["nixpkgs"]["locked"]["rev"] = NEW_HEAD
        (candidate / "flake.lock").write_text(json.dumps(lock))
        with mock.patch.object(p, "candidate_path", return_value=candidate), \
                mock.patch.object(p, "checked", return_value=""):
            self.rejected(p.weekly, self.public, str(candidate), message="starting lock")

    def test_weekly_branch_race_rejected(self):
        candidate = self.candidate()
        snap = p.snapshot(self.public, False)
        raced = dict(snap, head=NEW_HEAD)
        with mock.patch.object(p, "candidate_path", return_value=candidate), \
                mock.patch.object(p, "checked", return_value=""), \
                mock.patch.object(p, "snapshot", side_effect=[snap, raced]), \
                mock.patch.dict(os.environ, {"GITHUB_RUN_ID": "12345"}):
            self.rejected(p.weekly, self.public, str(candidate), message="raced")


class PrepareTests(PipelineCase):
    def test_prepare_materializes_proposal_without_executing_candidate_nix(self):
        plan = self.plan()
        candidate = self.candidate()
        git_args = ["git", "-c", "core.hooksPath=/dev/null", "-C", str(candidate),
                    "rev-parse", "HEAD"]
        with mock.patch.object(p, "checked", return_value=HEAD) as checked, \
                mock.patch.object(p, "discover_hashes",
                                  return_value=(SOURCE_HASH, CARGO_HASH, source_locked())), \
                mock.patch.object(p, "materialize", wraps=p.materialize) as materialize:
            proposal = p.prepare(self.public, str(candidate), plan)
        materialize.assert_called_once_with(str(candidate), proposal)
        self.assertEqual(checked.call_args_list, [mock.call(git_args), mock.call(git_args)])
        self.assertEqual(self.public.writes, [])

    def test_prepare_without_tokens_does_not_modify_request_bytes(self):
        plan = self.plan()
        candidate = self.candidate()
        target = candidate / p.REQUEST
        target.parent.mkdir(parents=True, exist_ok=True)
        request_bytes = b'{"opaque":"leave untouched"}\n'
        target.write_bytes(request_bytes)
        with mock.patch.object(p, "candidate_path", return_value=candidate), \
                mock.patch.object(p, "discover_hashes",
                                  return_value=(SOURCE_HASH, CARGO_HASH, source_locked())):
            p.prepare(self.public, str(candidate), plan)
        self.assertEqual(target.read_bytes(), request_bytes)

    def test_prepare_writes_only_verified_promotion_files(self):
        plan = self.plan()
        candidate = self.candidate()
        expected = p.promotion_files(self.public, plan, SOURCE_HASH, CARGO_HASH,
                                     source_locked=source_locked())
        with mock.patch.object(p, "candidate_path", return_value=candidate), \
                mock.patch.object(p, "discover_hashes",
                                  return_value=(SOURCE_HASH, CARGO_HASH, source_locked())):
            proposal = p.prepare(self.public, str(candidate), plan)
        self.assertEqual(proposal["files"], expected)
        self.assertEqual(proposal["snapshot"], plan["snapshot"])
        self.assertEqual(proposal["source_locked"], source_locked())
        for name, text in expected.items():
            self.assertEqual((candidate / name).read_text(), text)
        self.assertFalse((candidate / p.REQUEST).exists())

    def test_prepare_rechecks_after_hash_discovery(self):
        plan = self.plan()
        candidate = self.candidate()

        def discover(*args):
            self.public.routes[f"/repos/{p.REPO}/pulls/42"]["state"] = "closed"
            return SOURCE_HASH, CARGO_HASH, source_locked()

        with mock.patch.object(p, "candidate_path", return_value=candidate), \
                mock.patch.object(p, "discover_hashes", side_effect=discover):
            self.rejected(p.prepare, self.public, str(candidate), plan)

    def test_prepare_candidate_data_mismatch(self):
        plan = self.plan()
        candidate = self.candidate()
        (candidate / "flake.nix").write_text("evil")
        with mock.patch.object(p, "candidate_path", return_value=candidate), \
                mock.patch.object(p, "discover_hashes") as discover:
            self.rejected(p.prepare, self.public, str(candidate), plan, message="data mismatch")
            discover.assert_not_called()

    def test_candidate_path_requires_matching_head(self):
        candidate = self.candidate()
        with mock.patch.object(p, "checked", return_value=NEW_HEAD):
            self.rejected(p.candidate_path, str(candidate), HEAD)
        with mock.patch.object(p, "checked", return_value=HEAD):
            self.assertEqual(p.candidate_path(str(candidate), HEAD), candidate)

    def test_candidate_checkout_root_rejected(self):
        self.rejected(p.candidate_path, str(ROOT), HEAD)

    def test_candidate_parent_escape_rejected(self):
        self.rejected(p.candidate_path, str(ROOT.parent), HEAD)

    def test_candidate_file_symlink_rejected(self):
        candidate = self.candidate()
        target = candidate / "evil"
        target.symlink_to(candidate / "flake.lock")
        self.rejected(p.read_candidate, candidate, "evil")

    def test_candidate_file_escape_rejected(self):
        candidate = self.candidate()
        self.rejected(p.read_candidate, candidate, "../../test_wezterm_pipeline.py")

    def test_promotion_updates_source_lock_and_literal_flake_url(self):
        files = p.promotion_files(self.own, self.plan(), SOURCE_HASH, CARGO_HASH)
        self.assertEqual(set(files), {p.PIN, "flake.lock", "flake.nix"})
        lock = json.loads(files["flake.lock"])
        node = lock["nodes"]["wezterm-src"]
        self.assertEqual(node["locked"]["rev"], SHA)
        self.assertEqual(node["locked"]["narHash"], SOURCE_HASH)
        self.assertEqual(node["original"]["rev"], SHA)
        self.assertEqual(node["locked"]["lastModified"], 1791617951)
        self.assertNotIn("revCount", node["locked"])
        self.assertNotIn("ref", node["locked"])
        self.assertEqual(lock["nodes"]["nixpkgs"], lock_data()["nodes"]["nixpkgs"])
        self.assertIn("?rev=" + SHA + "&submodules=1", files["flake.nix"])
        pin = p.validate_pin(files[p.PIN]).data
        self.assertEqual(pin["revision"], SHA)
        self.assertEqual(pin["sourceHash"], SOURCE_HASH)
        self.assertEqual(pin["cargoHash"], CARGO_HASH)
        self.assertEqual(pin["assets"]["windows"]["assetId"], 201)
        self.assertEqual(pin["assets"]["windows"]["runAttempt"], 2)
        self.assertTrue(files[p.PIN].startswith("# Keep this comment and formatting.\n"))

    def test_promotion_replaces_entire_locked_and_original_source_metadata(self):
        plan = self.plan()
        before = lock_data()
        before["nodes"]["wezterm-src"]["locked"]["obsolete"] = "discard"
        before["nodes"]["wezterm-src"]["original"]["ref"] = "refs/heads/old"
        self.own.set_content("flake.lock", HEAD, json.dumps(before))
        metadata = source_locked()
        files = p.promotion_files(self.own, plan, SOURCE_HASH, CARGO_HASH,
                                  source_locked=metadata)
        node = p.parse(files["flake.lock"])["nodes"]["wezterm-src"]
        self.assertEqual(node["locked"], source_locked())
        self.assertEqual(node["locked"]["revCount"], 8718)
        self.assertEqual(node["original"], {
            "type": "git", "url": "https://github.com/wezterm/wezterm",
            "submodules": True, "rev": SHA})
        self.assertEqual(metadata, source_locked())
        for key in ("ref", "revCount"):
            del metadata[key]
        files = p.promotion_files(self.own, plan, SOURCE_HASH, CARGO_HASH,
                                  source_locked=metadata)
        self.assertEqual(p.parse(files["flake.lock"])["nodes"]["wezterm-src"]["locked"], metadata)

    def test_direct_promotion_rejects_invalid_source_metadata(self):
        plan = self.plan()
        for name, metadata in invalid_source_locks():
            if metadata is None:
                continue  # None is the direct-call compatibility default.
            with self.subTest(case=name), self.assertRaises(ValueError):
                p.promotion_files(self.own, plan, SOURCE_HASH, CARGO_HASH,
                                  source_locked=metadata)

    def test_source_metadata_bound_to_exact_plan_commit_date(self):
        plan = self.plan()
        for date in (True, None, "bad", "2026-02-30T07:39:11Z",
                     "2026-10-10T07:39:12Z", "2026-10-10T07:39:11+00:00"):
            with self.subTest(date=date), self.assertRaises(ValueError):
                p.promotion_files(self.own, dict(plan, commit_date=date), SOURCE_HASH, CARGO_HASH,
                                  source_locked=source_locked())

    def test_prepare_legacy_sourcehash_without_input_carries_metadata(self):
        for api in (self.own, self.public):
            api.set_content("flake.lock", HEAD, json.dumps(lock_data(False)))
        plan = self.plan()
        candidate = self.candidate()
        with mock.patch.object(p, "candidate_path", return_value=candidate), \
                mock.patch.object(p, "discover_hashes",
                                  return_value=(SOURCE_HASH, CARGO_HASH, source_locked())):
            proposal = p.prepare(self.public, str(candidate), plan)
        self.assertEqual(set(proposal["files"]), {p.PIN})
        self.assertEqual(proposal["source_locked"], source_locked())
        self.assertEqual(p.publish(self.own, self.public, plan, proposal), NEW_HEAD)

    def test_promotion_without_source_lock_requires_pin_source_hash(self):
        self.own.set_content("flake.lock", HEAD, json.dumps(lock_data(False)))
        files = p.promotion_files(self.own, self.plan(), SOURCE_HASH, CARGO_HASH)
        self.assertEqual(set(files), {p.PIN})
        for head in (HEAD, DEFAULT):
            self.own.set_content(p.PIN, head, p.nix_literal(pin_data(False)))
        self.rejected(p.promotion_files, self.own, self.plan(), SOURCE_HASH, CARGO_HASH)

    def test_promotion_rejects_untrusted_pin_schema(self):
        self.own.set_content(p.PIN, HEAD, p.nix_literal(pin_data(False)))
        self.rejected(p.promotion_files, self.own, self.plan(), SOURCE_HASH, CARGO_HASH)

    def test_promotion_rejects_ambiguous_source_flake_url(self):
        raw, _ = p.content(self.own, "flake.nix", HEAD)
        self.own.set_content("flake.nix", HEAD, raw + raw)
        self.rejected(p.promotion_files, self.own, self.plan(), SOURCE_HASH, CARGO_HASH)

    def test_promotion_rejects_source_original_repository(self):
        lock = lock_data()
        lock["nodes"]["wezterm-src"]["original"]["url"] = "https://evil.invalid/source"
        self.own.set_content("flake.lock", HEAD, json.dumps(lock))
        self.rejected(p.promotion_files, self.own, self.plan(), SOURCE_HASH, CARGO_HASH)


class HashDiscoveryTests(PipelineCase):
    DRV = "/nix/store/" + "a" * 32 + "-wezterm-vendor.drv"

    def test_current_nix_version_four_fixed_output_schema(self):
        metadata = {"version": 4, "derivations": {
            Path(self.DRV).name: {"outputs": {
                "out": {"method": "nar", "hash": p.FAKE_HASH, "path": "/nix/store/fixture"}}}}}
        checked_patch, command_patch = self.discovery(metadata=metadata)
        with checked_patch as checked, command_patch:
            self.assertEqual(p.discover_hashes(self.public, self.plan()),
                             (SOURCE_HASH, CARGO_HASH, source_locked()))
        expr = checked.call_args_list[1].args[0][-1]
        self.assertTrue(expr.endswith(".vendorStaging.drvPath"))
        self.assertFalse(checked.call_args_list[-1].args[0][-1].endswith(".vendorStaging"))

    def test_current_nix_metadata_identity_method_hash_and_version_fail_closed(self):
        good = {"version": 4, "derivations": {
            Path(self.DRV).name: {"outputs": {"out": {"method": "nar", "hash": p.FAKE_HASH}}}}}
        cases = []
        for field, value in (("method", "flat"), ("hash", CARGO_HASH)):
            obj = copy.deepcopy(good)
            obj["derivations"][Path(self.DRV).name]["outputs"]["out"][field] = value
            cases.append(obj)
        for version in (True, 5, "4"):
            obj = copy.deepcopy(good)
            obj["version"] = version
            cases.append(obj)
        obj = copy.deepcopy(good)
        obj["derivations"]["wrong.drv"] = obj["derivations"].pop(Path(self.DRV).name)
        cases.append(obj)
        for obj in cases:
            with self.subTest(metadata=obj):
                self.rejected(p.validate_fixed_derivation, obj, self.DRV)

    def test_full_inspect_prepare_publish_with_mocked_hash_commands(self):
        plan = self.plan()
        candidate = self.candidate()
        checked_patch, command_patch = self.discovery()
        with mock.patch.object(p, "candidate_path", return_value=candidate), \
                checked_patch, command_patch:
            proposal = p.prepare(self.public, str(candidate), plan)
        self.assertEqual(p.publish(self.own, self.public, plan, proposal), NEW_HEAD)
        self.assertEqual(set(proposal["files"]), {p.PIN, "flake.nix", "flake.lock"})
        self.assertEqual(self.public.writes, [])
        self.assertEqual(self.own.writes, [(
            "graphql", p.CREATE_COMMIT_QUERY, p.commit_variables(
                HEAD, proposal["files"],
                "wezterm: promote verified source and immutable Windows build"))])
        self.assertEqual(len(self.own.advancements), 1)
        locked = p.parse(proposal["files"]["flake.lock"])["nodes"]["wezterm-src"]["locked"]
        self.assertEqual(locked, source_locked())
        self.assertEqual(proposal["source_locked"], locked)

    def test_prefetch_invalid_metadata_fails_before_cargo_commands(self):
        plan = self.plan()
        for name, metadata in invalid_source_locks():
            if type(metadata) is dict:
                metadata = dict(metadata)
                if metadata.get("narHash") == SOURCE_HASH:
                    del metadata["narHash"]
                elif name == "missing_narHash":
                    continue  # Nix returns narHash separately as hash.
            with self.subTest(case=name):
                prefetch = dict(source_prefetch(), locked=metadata)
                checked_patch, command_patch = self.discovery(prefetch=prefetch)
                with checked_patch as checked, command_patch as command:
                    self.rejected(p.discover_hashes, self.public, plan)
                self.assertEqual(checked.call_count, 1)
                command.assert_not_called()
        for prefetch in ({"hash": SOURCE_HASH}, dict(source_prefetch(), locked={})):
            checked_patch, command_patch = self.discovery(prefetch=prefetch)
            with checked_patch, command_patch:
                self.rejected(p.discover_hashes, self.public, plan)

    def test_prefetch_optional_metadata_is_optional_and_zero_count_is_valid(self):
        for omitted in (("ref",), ("revCount",), ("ref", "revCount"), ()):
            prefetch = source_prefetch()
            prefetch["locked"]["revCount"] = 0
            for key in omitted:
                del prefetch["locked"][key]
            checked_patch, command_patch = self.discovery(prefetch=prefetch)
            with self.subTest(omitted=omitted), checked_patch, command_patch:
                _, _, metadata = p.discover_hashes(self.public, self.plan())
            self.assertEqual(metadata, dict(prefetch["locked"], narHash=SOURCE_HASH))

    def discovery(self, stderr=None, metadata=None, drv=None, prefetch=None):
        drv = drv or self.DRV
        metadata = metadata or {drv: {"outputs": {"out": {"hashAlgo": "r:sha256", "hash": "0" * 64}}}}
        outputs = [
            json.dumps(source_prefetch() if prefetch is None else prefetch),
            drv, json.dumps(metadata), "",
        ]
        stderr = stderr if stderr is not None else (
            f"error: hash mismatch in fixed-output derivation '{drv}':\n"
            f"  specified: {p.FAKE_HASH}\n  got: {CARGO_HASH}\n")
        return mock.patch.object(p, "checked", side_effect=outputs), mock.patch.object(
            p, "command", return_value=subprocess.CompletedProcess([], 1, "", stderr))

    def test_trusted_default_hash_derivation_and_second_verification(self):
        plan = self.plan()
        checked_patch, command_patch = self.discovery()
        with checked_patch as checked, command_patch as command:
            self.assertEqual(p.discover_hashes(self.public, plan),
                             (SOURCE_HASH, CARGO_HASH, source_locked()))
        calls = [entry.args[0] for entry in checked.call_args_list]
        self.assertEqual(calls[0], [
            "nix", "flake", "prefetch", "--json",
            f"git+https://github.com/{p.SOURCE}?rev={SHA}&submodules=1"])
        self.assertIn(f"/repos/{p.REPO}/contents/flake.lock?ref={DEFAULT}", self.public.reads)
        self.assertIn(OLD_SHA, calls[1][-1])
        self.assertIn(SOURCE_HASH, calls[1][-1])
        self.assertIn("revCount = 8718;", calls[1][-1])
        self.assertIn('ref = "refs/heads/main";', calls[1][-1])
        self.assertEqual(command.call_args.args[0][-1], self.DRV + "^out")
        self.assertEqual(calls[-1][:5], ["nix", "build", "--no-link", "--print-build-logs", "--expr"])
        self.assertIn(CARGO_HASH, calls[-1][-1])
        self.assertNotIn(p.FAKE_HASH, calls[-1][-1])

    def test_hash_discovery_rejects_untrusted_nixpkgs(self):
        lock = lock_data()
        lock["nodes"]["nixpkgs"]["locked"]["owner"] = "evil"
        self.public.set_content("flake.lock", DEFAULT, json.dumps(lock))
        with mock.patch.object(p, "checked", return_value=json.dumps(source_prefetch())):
            self.rejected(p.discover_hashes, self.public, self.plan(), message="trusted nixpkgs")

    def test_hash_discovery_wrong_derivation_name_rejected(self):
        checked_patch, command_patch = self.discovery(drv="/nix/store/not-a-derivation.drv")
        with checked_patch, command_patch:
            self.rejected(p.discover_hashes, self.public, self.plan(), message="known Cargo")

    def test_hash_discovery_wrong_derivation_metadata_rejected(self):
        checked_patch, command_patch = self.discovery(metadata={
            self.DRV: {"outputs": {"out": {"hashAlgo": "sha256", "hash": "0" * 64}}}})
        with checked_patch, command_patch:
            self.rejected(p.discover_hashes, self.public, self.plan(), message="fixed-output")

    def test_hash_discovery_multiple_derivations_rejected(self):
        checked_patch, command_patch = self.discovery(metadata={
            self.DRV: {}, self.DRV + "-evil": {}})
        with checked_patch, command_patch:
            self.rejected(p.discover_hashes, self.public, self.plan(), message="exact Cargo")

    def test_hash_discovery_fake_build_success_rejected(self):
        checked_patch, _ = self.discovery()
        with checked_patch, mock.patch.object(p, "command", return_value=(
                subprocess.CompletedProcess([], 0, "", ""))):
            self.rejected(p.discover_hashes, self.public, self.plan(), message="unexpectedly succeeded")

    def test_hash_discovery_second_verification_failure_rejected(self):
        checked_patch, command_patch = self.discovery()
        with checked_patch as checked, command_patch:
            responses = [json.dumps(source_prefetch()), self.DRV,
                         json.dumps({self.DRV: {"outputs": {"out": {
                             "hashAlgo": "r:sha256", "hash": "0" * 64}}}}),
                         ValueError("second verification failed")]
            checked.side_effect = responses
            self.rejected(p.discover_hashes, self.public, self.plan(), message="second verification")

    def test_hash_discovery_rejects_bad_prefetch_hash(self):
        checked_patch, command_patch = self.discovery(prefetch={"hash": "not-sri"})
        with checked_patch, command_patch:
            self.rejected(p.discover_hashes, self.public, self.plan(), message="prefetch hash")


class PublishTests(PipelineCase):
    def test_already_promoted_same_source_is_idempotent(self):
        plan = self.plan()
        proposal = self.proposal(plan)
        for name, text in proposal["files"].items():
            self.own.set_content(name, HEAD, text)
        self.assertEqual(p.publish(self.own, self.public, plan, proposal), HEAD)
        self.assertEqual(self.own.writes, [])

    def test_weekly_retained_closed_branch_is_not_resurrected(self):
        key = (f"/repos/{p.REPO}/pulls?state=open&head=dc0d32:{p.BRANCH}", None)
        self.own.page_routes[key] = []
        proposal = {"kind": "weekly", "snapshot": p.snapshot(self.own, False),
                    "files": {"flake.lock": json.dumps(lock_data())}}
        self.rejected(p.publish_weekly, self.own, self.public, proposal, message="retained")
        self.assertEqual(self.own.writes, [])
        self.public.page_routes[key] = []
        self.rejected(p.weekly, self.public, "candidate", message="retained")

    def test_publish_upstream_advance_before_atomic_commit_succeeds(self):
        plan = self.plan()
        proposal = self.proposal(plan)

        original = p.write_commit

        def supersede(*args, **kwargs):
            before_ref = kwargs["before_ref"]

            def final_check():
                self.public.routes[f"/repos/{p.SOURCE}/commits/main"]["sha"] = NEW_HEAD
                before_ref()

            kwargs["before_ref"] = final_check
            return original(*args, **kwargs)

        with mock.patch.object(p, "write_commit", side_effect=supersede):
            self.assertEqual(p.publish(self.own, self.public, plan, proposal), NEW_HEAD)
        self.assert_additions(proposal["files"])
        self.assertEqual(p.validate_pin(proposal["files"][p.PIN]).data["revision"], SHA)
        self.assertNotIn(f"/repos/{p.SOURCE}", self.public.reads)
        self.assertNotIn(f"/repos/{p.SOURCE}/commits/main", self.public.reads)

    def test_publish_weekly_resolution_failure_does_not_block_lock_change(self):
        lock = lock_data()
        lock["nodes"]["nixpkgs"]["locked"]["rev"] = NEW_HEAD
        proposal = {"kind": "weekly", "snapshot": p.snapshot(self.own, False),
                    "files": {"flake.lock": json.dumps(lock), p.REQUEST: json.dumps(request())}}
        self.public.routes[f"/repos/{p.SOURCE}/commits/{SHA}"] = urllib.error.URLError("offline")
        with contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(p.publish_weekly(self.own, self.public, proposal), NEW_HEAD)
        self.assert_additions({"flake.lock": json.dumps(lock)})

    def test_publish_rejects_request_blob_changed_since_preparation(self):
        plan = self.plan()
        proposal = self.proposal(plan)
        self.own.set_content(p.REQUEST, HEAD, json.dumps(request("54321")))
        self.rejected(p.publish, self.own, self.public, plan, proposal)
        self.assertEqual(self.own.writes, [])

    def test_publish_rejects_proposal_snapshot_changed(self):
        plan = self.plan()
        proposal = self.proposal(plan)
        proposal["snapshot"] = dict(proposal["snapshot"], head=NEW_HEAD)
        self.rejected(p.publish, self.own, self.public, plan, proposal)
        self.assertEqual(self.own.writes, [])

    def test_publish_rejects_extra_proposal_key(self):
        plan = self.plan()
        proposal = self.proposal(plan)
        proposal["force"] = True
        self.rejected(p.publish, self.own, self.public, plan, proposal)
        self.assertEqual(self.own.writes, [])

    def test_tampered_proposal_hash_without_matching_files_rejected(self):
        plan = self.plan()
        proposal = self.proposal(plan)
        proposal["source_hash"] = CARGO_HASH
        self.rejected(p.publish, self.own, self.public, plan, proposal, message="source locked identity")
        self.assertEqual(self.own.writes, [])

    def test_publish_rejects_invalid_or_missing_metadata_without_commands_or_writes(self):
        plan = self.plan()
        for name, metadata in invalid_source_locks():
            with self.subTest(case=name):
                proposal = self.proposal(plan)
                proposal["source_locked"] = metadata
                self.rejected(p.publish, self.own, self.public, plan, proposal)
                self.assertEqual(self.own.writes + self.public.writes, [])
        proposal = self.proposal(plan)
        del proposal["source_locked"]
        self.rejected(p.publish, self.own, self.public, plan, proposal)
        self.assertEqual(self.own.writes + self.public.writes, [])

    def test_publish_metadata_must_match_atomic_files(self):
        plan = self.plan()
        for key, value in (("revCount", 9000), ("ref", "refs/heads/other")):
            proposal = self.proposal(plan)
            proposal["source_locked"][key] = value
            with self.subTest(key=key):
                self.rejected(p.publish, self.own, self.public, plan, proposal, message="tampered")
            self.assertEqual(self.own.writes, [])

    def test_write_commit_stale_snapshot_no_writes(self):
        snap = p.snapshot(self.own, False)
        self.own.routes[f"/repos/{p.REPO}/git/ref/heads/main"]["object"]["sha"] = NEW_HEAD
        self.rejected(p.write_commit, self.own, snap, {"flake.lock": "{}\n"}, "test")
        self.assertEqual(self.own.writes, [])

    def test_write_commit_created_branch_race_is_not_adopted(self):
        self.own.page_routes[f"/repos/{p.REPO}/pulls?state=open&head=dc0d32:{p.BRANCH}", None] = []
        self.own.routes[f"/repos/{p.REPO}/git/ref/heads/{p.BRANCH}"] = urllib.error.HTTPError(
            p.API, 404, "absent", {}, None)
        snap = p.snapshot(self.own, False)

        def conflict(method, route, data):
            if route == "/git/refs":
                self.own.routes[f"/repos/{p.REPO}/git/ref/heads/{p.BRANCH}"] = ref(p.BRANCH, DEFAULT)

        self.own.on_call = conflict
        with self.assertRaises(urllib.error.HTTPError):
            p.write_commit(self.own, snap, {"flake.lock": "{}\n"}, "test")
        self.assertEqual(len(self.own.writes), 1)
        self.assertEqual(self.own.advancements, [])
        self.assertEqual(p.branch_ref(self.own, p.BRANCH), DEFAULT)

    def test_write_commit_post_write_ref_mismatch_rejected(self):
        snap = p.snapshot(self.own, False)

        reads = 0

        def wrong_ref(route):
            nonlocal reads
            if route == f"/repos/{p.REPO}/git/ref/heads/{p.BRANCH}":
                reads += 1
            if reads == 5:
                self.own.routes[f"/repos/{p.REPO}/git/ref/heads/{p.BRANCH}"] = ref(p.BRANCH, OLD_SHA)

        self.own.on_get = wrong_ref
        self.rejected(p.write_commit, self.own, snap, {"flake.lock": "{}\n"}, "test",
                      message="published ref differs")

    def test_publish_weekly_ordinary_lock_change_atomic_commit(self):
        lock = lock_data()
        lock["nodes"]["home-manager"]["locked"]["rev"] = NEW_HEAD
        proposal = {"kind": "weekly", "snapshot": p.snapshot(self.own, False),
                    "files": {"flake.lock": json.dumps(lock)}}
        self.assertEqual(p.publish_weekly(self.own, self.public, proposal), NEW_HEAD)
        self.assert_additions(proposal["files"])

    def test_publish_weekly_opens_pr_only_after_new_branch_commit(self):
        self.own.page_routes[f"/repos/{p.REPO}/pulls?state=open&head=dc0d32:{p.BRANCH}", None] = []
        self.own.routes[f"/repos/{p.REPO}/git/ref/heads/{p.BRANCH}"] = urllib.error.HTTPError(
            p.API, 404, "absent", {}, None)
        lock = lock_data()
        lock["nodes"]["nixpkgs"]["locked"]["rev"] = NEW_HEAD
        proposal = {"kind": "weekly", "snapshot": p.snapshot(self.own, False),
                    "files": {"flake.lock": json.dumps(lock)}}
        self.assertEqual(p.publish_weekly(self.own, self.public, proposal), NEW_HEAD)
        self.assertEqual(self.own.writes[-1][0:2], ("POST", "/pulls"))
        self.assertEqual(self.own.writes[-1][2]["base"], "main")
        self.assertEqual(self.own.writes[-1][2]["head"], p.BRANCH)

    def test_publish_weekly_unknown_file_rejected(self):
        proposal = {"kind": "weekly", "snapshot": p.snapshot(self.own, False),
                    "files": {"flake.lock": json.dumps(lock_data()), p.PIN: "changed"}}
        self.rejected(p.publish_weekly, self.own, self.public, proposal)
        self.assertEqual(self.own.writes, [])

    def proposal(self, plan):
        return {"kind": "promotion", "snapshot": plan["snapshot"],
                "source_hash": SOURCE_HASH, "cargo_hash": CARGO_HASH,
                "source_locked": source_locked(),
                "files": p.promotion_files(self.own, plan, SOURCE_HASH, CARGO_HASH,
                                         source_locked=source_locked())}

    def assert_additions(self, files, head=HEAD):
        self.assertEqual(len(self.own.writes), 1)
        method, query, variables = self.own.writes[0]
        self.assertEqual(method, "graphql")
        self.assertEqual(query, p.CREATE_COMMIT_QUERY)
        self.assertEqual(variables["input"]["expectedHeadOid"], head)
        self.assertEqual(variables["input"]["branch"], {
            "repositoryNameWithOwner": p.REPO, "branchName": p.BRANCH})
        additions = variables["input"]["fileChanges"]["additions"]
        self.assertEqual(additions, [
            {"path": name, "contents": base64.b64encode(text.encode("utf-8")).decode()}
            for name, text in sorted(files.items())])
        self.assertEqual(len(self.own.advancements), 1)

    def test_publish_single_atomic_graphql_commit(self):
        plan = self.plan()
        proposal = self.proposal(plan)
        with mock.patch.object(p, "command", side_effect=AssertionError("writer command")) as command, \
                mock.patch.object(p, "checked", side_effect=AssertionError("writer executable")) as checked:
            self.assertEqual(p.publish(self.own, self.public, plan, proposal), NEW_HEAD)
        command.assert_not_called()
        checked.assert_not_called()
        self.assert_additions(proposal["files"])
        self.assertEqual(self.public.writes, [])

    def test_tampered_proposal_files_rejected_before_write(self):
        plan = self.plan()
        proposal = self.proposal(plan)
        proposal["files"][p.PIN] += "# injected\n"
        self.rejected(p.publish, self.own, self.public, plan, proposal, message="tampered")
        self.assertEqual(self.own.writes, [])

    def test_proposal_unknown_file_rejected_before_write(self):
        plan = self.plan()
        proposal = self.proposal(plan)
        proposal["files"][".github/workflows/evil.yml"] = "evil"
        self.rejected(p.publish, self.own, self.public, plan, proposal)
        self.assertEqual(self.own.writes, [])

    def test_closed_request_rejected_before_write(self):
        plan = self.plan()
        proposal = self.proposal(plan)
        self.own.routes[f"/repos/{p.REPO}/pulls/42"]["state"] = "closed"
        self.rejected(p.publish, self.own, self.public, plan, proposal)
        self.assertEqual(self.own.writes, [])

    def test_requested_source_commit_mismatch_rejected_before_write(self):
        plan = self.plan()
        proposal = self.proposal(plan)
        self.public.routes[f"/repos/{p.SOURCE}/commits/{SHA}"]["sha"] = NEW_HEAD
        self.rejected(p.publish, self.own, self.public, plan, proposal)
        self.assertEqual(self.own.writes, [])

    def test_release_reverified_before_write(self):
        plan = self.plan()
        proposal = self.proposal(plan)
        self.public.routes[f"/repos/{p.BUILDS}/releases/301"]["immutable"] = False
        self.rejected(p.publish, self.own, self.public, plan, proposal)
        self.assertEqual(self.own.writes, [])

    def test_second_recheck_closes_request_during_release_verification(self):
        plan = self.plan()
        proposal = self.proposal(plan)

        def close(path):
            if path == f"/repos/{p.BUILDS}/releases/301":
                self.own.routes[f"/repos/{p.REPO}/pulls/42"]["state"] = "closed"

        self.public.on_get = close
        self.rejected(p.publish, self.own, self.public, plan, proposal)
        self.assertEqual(self.own.writes, [])

    def test_write_commit_race_before_ref_update(self):
        snap = p.snapshot(self.own, False)

        def race(method, route, data):
            if method == "graphql":
                self.own.routes[f"/repos/{p.REPO}/git/ref/heads/{p.BRANCH}"]["object"]["sha"] = NEW_HEAD
                self.own.routes[f"/repos/{p.REPO}/pulls/42"]["head"]["sha"] = NEW_HEAD

        self.own.on_call = race
        self.rejected(p.write_commit, self.own, snap, {"flake.lock": "{}\n"}, "test",
                      message="expected head")
        self.assertEqual(len(self.own.writes), 1)
        self.assertEqual(self.own.advancements, [])

    def test_graphql_transport_conflict_propagates(self):
        snap = p.snapshot(self.own, False)

        def conflict(method, route, data):
            if method == "graphql":
                self.assertEqual(data["input"]["expectedHeadOid"], HEAD)
                raise urllib.error.HTTPError(p.API, 422, "race", {}, None)

        self.own.on_call = conflict
        with self.assertRaises(urllib.error.HTTPError):
            p.write_commit(self.own, snap, {"flake.lock": "{}\n"}, "test")
        self.assertEqual(sum(method == "graphql" for method, _, _ in self.own.writes), 1)
        self.assertEqual(self.own.advancements, [])

    def test_write_commit_new_branch_atomic_creation(self):
        self.own.page_routes[f"/repos/{p.REPO}/pulls?state=open&head=dc0d32:{p.BRANCH}", None] = []
        self.own.routes[f"/repos/{p.REPO}/git/ref/heads/{p.BRANCH}"] = urllib.error.HTTPError(
            p.API, 404, "absent", {}, None)
        snap = p.snapshot(self.own, False)
        self.assertEqual(p.write_commit(self.own, snap, {"flake.lock": "{}\n"}, "test"), NEW_HEAD)
        self.assertEqual(self.own.writes, [
            ("POST", "/git/refs", {"ref": "refs/heads/" + p.BRANCH, "sha": DEFAULT}),
            ("graphql", p.CREATE_COMMIT_QUERY,
             p.commit_variables(DEFAULT, {"flake.lock": "{}\n"}, "test")),
        ])
        self.assertEqual(len(self.own.advancements), 1)

    def test_write_file_allowlist(self):
        self.rejected(p.write_commit, self.own, p.snapshot(self.own, False),
                      {"scripts/evil.py": "evil"}, "test")
        self.assertEqual(self.own.writes, [])

    def test_write_file_lf_only(self):
        self.rejected(p.write_commit, self.own, p.snapshot(self.own, False),
                      {"flake.lock": "{}\r\n"}, "test")
        self.assertEqual(self.own.writes, [])

    def missing_branch(self):
        self.own.page_routes[f"/repos/{p.REPO}/pulls?state=open&head=dc0d32:{p.BRANCH}", None] = []
        self.own.routes[f"/repos/{p.REPO}/git/ref/heads/{p.BRANCH}"] = urllib.error.HTTPError(
            p.API, 404, "absent", {}, None)
        return p.snapshot(self.own, False)

    def test_write_commit_ancestor_reset_after_final_read_is_rejected(self):
        snap = p.snapshot(self.own, False)

        def reset(method, query, variables):
            if method == "graphql":
                self.assertEqual(variables["input"]["expectedHeadOid"], HEAD)
                self.own.routes[f"/repos/{p.REPO}/git/ref/heads/{p.BRANCH}"] = ref(p.BRANCH, DEFAULT)
                self.own.routes[f"/repos/{p.REPO}/pulls/42"]["head"]["sha"] = DEFAULT

        self.own.on_call = reset
        self.rejected(p.write_commit, self.own, snap, {"flake.lock": "{}\n"}, "test",
                      message="expected head")
        self.assertEqual(self.own.advancements, [])
        self.assertEqual(len(self.own.writes), 1)
        self.assertEqual(p.branch_ref(self.own, p.BRANCH), DEFAULT)

    def test_write_commit_delete_after_final_read_is_rejected(self):
        snap = p.snapshot(self.own, False)

        def delete(method, query, variables):
            if method == "graphql":
                self.own.routes[f"/repos/{p.REPO}/git/ref/heads/{p.BRANCH}"] = urllib.error.HTTPError(
                    p.API, 404, "deleted", {}, None)

        self.own.on_call = delete
        self.rejected(p.write_commit, self.own, snap, {"flake.lock": "{}\n"}, "test",
                      message="expected head")
        self.assertEqual(self.own.advancements, [])
        self.assertEqual(len(self.own.writes), 1)

    def test_new_branch_cas_failure_leaves_default_seed(self):
        snap = self.missing_branch()

        def fail(method, query, variables):
            if method == "graphql":
                self.assertEqual(p.branch_ref(self.own, p.BRANCH), DEFAULT)
                self.assertEqual(variables["input"]["expectedHeadOid"], DEFAULT)
                raise ValueError("GraphQL CAS failure")

        self.own.on_call = fail
        self.rejected(p.write_commit, self.own, snap, {"flake.lock": "{}\n"}, "test")
        self.assertEqual(p.branch_ref(self.own, p.BRANCH), DEFAULT)
        self.assertEqual(self.own.advancements, [])
        self.assertEqual([method for method, _, _ in self.own.writes], ["POST", "graphql"])

    def test_before_ref_runs_after_final_snapshot_and_before_graphql(self):
        snap = p.snapshot(self.own, False)

        def before_ref():
            self.assertEqual(self.own.writes, [])
            self.assertEqual(self.own.reads[-1], f"/repos/{p.REPO}/pulls/42")
            self.own.routes[f"/repos/{p.REPO}/git/ref/heads/{p.BRANCH}"] = ref(p.BRANCH, OLD_SHA)

        self.rejected(lambda: p.write_commit(
            self.own, snap, {"flake.lock": "{}\n"}, "test", before_ref=before_ref))
        self.assertEqual(self.own.advancements, [])

    def test_publish_weekly_no_change_no_writes(self):
        snap = p.snapshot(self.own, False)
        raw, _ = p.content(self.own, "flake.lock", HEAD)
        proposal = {"kind": "weekly", "snapshot": snap, "files": {"flake.lock": raw.decode()}}
        self.assertEqual(p.publish_weekly(self.own, self.public, proposal), HEAD)
        self.assertEqual(self.own.writes, [])

    def test_publish_weekly_changed_source_lock_rejected(self):
        new = lock_data()
        new["nodes"]["wezterm-src"]["locked"]["rev"] = SHA
        proposal = {"kind": "weekly", "snapshot": p.snapshot(self.own, False),
                    "files": {"flake.lock": json.dumps(new)}}
        self.rejected(p.publish_weekly, self.own, self.public, proposal)
        self.assertEqual(self.own.writes, [])

    def test_publish_weekly_invalid_requested_source_skipped(self):
        proposal = {"kind": "weekly", "snapshot": p.snapshot(self.own, False),
                    "files": {"flake.lock": json.dumps(lock_data()),
                              p.REQUEST: json.dumps(request(sha=OLD_SHA))}}
        self.public.routes[f"/repos/{p.SOURCE}/commits/{OLD_SHA}"] = {
            "sha": SHA, "commit": {"committer": {"date": DATE}}}
        with contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(p.publish_weekly(self.own, self.public, proposal), NEW_HEAD)
        self.assert_additions({"flake.lock": proposal["files"]["flake.lock"]})

    def test_publish_weekly_upstream_advance_preserves_resolved_request(self):
        req = json.dumps(request("99999"))
        proposal = {"kind": "weekly", "snapshot": p.snapshot(self.own, False),
                    "files": {"flake.lock": json.dumps(lock_data()), p.REQUEST: req}}
        self.public.routes[f"/repos/{p.SOURCE}/commits/main"]["sha"] = NEW_HEAD
        del self.public.routes[f"/repos/{p.SOURCE}"]
        self.assertEqual(p.publish_weekly(self.own, self.public, proposal), NEW_HEAD)
        self.assert_additions(proposal["files"])
        self.assertEqual(self.public.reads, [f"/repos/{p.SOURCE}/commits/{SHA}"])


class APITests(PipelineCase):
    def test_source_default_branch_resolution_is_anonymous_with_tokens_present(self):
        api = p.PublicAPI()
        api.opener = mock.Mock()
        api.opener.open.side_effect = [
            self.response(b'{"default_branch":"refs/heads/main"}'),
            self.response(json.dumps({
                "sha": SHA, "commit": {"committer": {"date": DATE}}}).encode()),
        ]
        with mock.patch.dict(os.environ, {"GITHUB_TOKEN": "own-token", "GH_TOKEN": "other-token"}):
            self.assertEqual(p.source_info(api), (SHA, DATE, VERSION))
        self.assertEqual([call.args[0].full_url for call in api.opener.open.call_args_list], [
            f"{p.API}/repos/{p.SOURCE}",
            f"{p.API}/repos/{p.SOURCE}/commits/refs%2Fheads%2Fmain",
        ])
        for call in api.opener.open.call_args_list:
            self.assertIsNone(call.args[0].get_header("Authorization"))

    def test_own_status_pages_are_authenticated_exact_head_and_newest_first(self):
        api = p.OwnAPI("unit-test-token")
        api.opener = mock.Mock()
        unrelated = [{"context": "other/check", "state": "success"}] * 100
        matching = [{"context": "wezterm/native-linux", "state": "pending"},
                    {"context": "wezterm/native-linux", "state": "success"}]
        api.opener.open.side_effect = [
            self.response(json.dumps(unrelated).encode()),
            self.response(json.dumps(matching).encode())]
        route = f"/repos/{p.REPO}/commits/{HEAD}/statuses"
        self.assertEqual(list(api.pages(route)), unrelated + matching)
        for page, call in enumerate(api.opener.open.call_args_list, 1):
            req = call.args[0]
            self.assertEqual(req.full_url, p.API + route + f"?per_page=100&page={page}")
            self.assertEqual(req.get_method(), "GET")
            self.assertEqual(req.get_header("Authorization"), "Bearer unit-test-token")

    def test_own_status_route_rejects_refs_other_repos_and_arbitrary_queries(self):
        api = p.OwnAPI("unit-test-token")
        api.opener = mock.Mock()
        for repo, sha, suffix in (
                (p.SOURCE, HEAD, ""), (p.BUILDS, HEAD, ""),
                (p.REPO + "-evil", HEAD, ""), (p.REPO, "main", ""),
                (p.REPO, p.BRANCH, ""), (p.REPO, HEAD.upper(), ""),
                (p.REPO, HEAD, "?page=1"), (p.REPO, HEAD, "?per_page=100&page=0"),
                (p.REPO, HEAD, "?per_page=100&page=1&repo=external"),
                (p.REPO, HEAD, "?per_page=100&page=1#fragment")):
            with self.subTest(repo=repo, sha=sha, suffix=suffix):
                self.rejected(api.get, f"/repos/{repo}/commits/{sha}/statuses{suffix}")
        api.opener.open.assert_not_called()

    def test_create_commit_query_contract(self):
        self.assertEqual(p.CREATE_COMMIT_QUERY, (
            "mutation CreateCommit($input: CreateCommitOnBranchInput!) {\n"
            "  createCommitOnBranch(input: $input) {\n"
            "    commit { oid }\n"
            "  }\n"
            "}"))

    def graphql_api(self, result=None):
        api = p.OwnAPI("unit-test-token")
        api.opener = mock.Mock()
        raw = p.canonical(result if result is not None else {
            "data": {"createCommitOnBranch": {"commit": {"oid": NEW_HEAD}}}}).encode()
        api.opener.open.return_value = self.response(raw)
        return api

    def test_graphql_fixed_authenticated_post_and_exact_payload(self):
        api = self.graphql_api()
        variables = p.commit_variables(HEAD, {
            "flake.lock": "{}\n", "flake.nix": "# café 🦀\n"}, "safe headline")
        self.assertEqual(api.graphql(p.CREATE_COMMIT_QUERY, variables), NEW_HEAD)
        req = api.opener.open.call_args.args[0]
        self.assertEqual(req.full_url, "https://api.github.com/graphql")
        self.assertEqual(req.get_method(), "POST")
        self.assertEqual(req.get_header("Authorization"), "Bearer unit-test-token")
        self.assertEqual(req.get_header("Content-type"), "application/json")
        self.assertEqual(req.get_header("Accept"), "application/vnd.github+json")
        self.assertEqual(p.parse(req.data), {"query": p.CREATE_COMMIT_QUERY, "variables": variables})
        self.assertEqual(api.opener.open.call_args.kwargs, {"timeout": 120})
        api.opener.open.return_value.__enter__.return_value.read.assert_called_once_with(
            8 * 1024 * 1024 + 1)

    def test_graphql_query_is_fixed_not_semantically_allowlisted(self):
        api = self.graphql_api()
        variables = p.commit_variables(HEAD, {"flake.lock": "{}\n"}, "test")
        for query in (None, "", "query { viewer { login } }",
                      p.CREATE_COMMIT_QUERY + "\n", p.CREATE_COMMIT_QUERY.replace(
                          "commit { oid }", "commit { oid url }"), p.CREATE_COMMIT_QUERY.replace(
                              "CreateCommit", "OtherMutation", 1)):
            with self.subTest(query=query):
                self.rejected(api.graphql, query, variables)
        api.opener.open.assert_not_called()

    def test_graphql_response_limit_rejects_before_json_parse(self):
        api = self.graphql_api()
        api.opener.open.return_value = self.response(b" " * (8 * 1024 * 1024 + 1))
        self.rejected(api.graphql, p.CREATE_COMMIT_QUERY,
                      p.commit_variables(HEAD, {"flake.lock": "{}\n"}, "test"),
                      message="response size")
        api.opener.open.return_value.__enter__.return_value.read.assert_called_once_with(
            8 * 1024 * 1024 + 1)

    def test_graphql_uses_no_redirect_opener(self):
        with mock.patch.object(urllib.request, "build_opener") as build:
            p.OwnAPI("token")
        self.assertIsInstance(build.call_args.args[0], p.NoRedirect)
        for code in (301, 302, 303, 307, 308):
            with self.subTest(code=code):
                self.rejected(build.call_args.args[0].redirect_request,
                              None, None, code, "", {}, p.API + "/graphql")

    def test_graphql_transport_failure_never_returns_commit(self):
        api = self.graphql_api()
        api.opener.open.side_effect = urllib.error.HTTPError(p.API, 403, "denied", {}, None)
        with self.assertRaises(urllib.error.HTTPError):
            api.graphql(p.CREATE_COMMIT_QUERY, p.commit_variables(
                HEAD, {"flake.lock": "{}\n"}, "test"))

    def test_commit_variables_all_paths_utf8_and_sorted_additions(self):
        files = {name: "# café 🦀\n" for name in reversed(sorted(p.WRITE_PATHS))}
        variables = p.commit_variables(HEAD, files, "x" * 256)
        self.assertEqual(variables["input"]["fileChanges"], {"additions": [
            {"path": name, "contents": base64.b64encode(files[name].encode()).decode()}
            for name in sorted(files)]})
        self.assertIs(p.validate_write_files(files), files)
        p.validate_commit_variables(variables)

    def test_write_file_limit_is_utf8_bytes_not_characters(self):
        limit = 4 * 1024 * 1024
        text = "é" * (limit // 2)
        p.commit_variables(HEAD, {"flake.nix": text}, "test")
        self.rejected(p.commit_variables, HEAD, {"flake.nix": text + "é"}, "test")

    def test_anonymous_external_asset_read_never_sends_own_token(self):
        api = p.OwnAPI("unit-test-token")
        api.opener = mock.Mock()
        api.opener.open.return_value = self.response(b"asset")
        self.assertEqual(api.raw("https://cdn.invalid/asset", 10, octets=True), b"asset")
        req = api.opener.open.call_args.args[0]
        self.assertIsNone(req.get_header("Authorization"))
        self.assertEqual(req.get_header("Accept"), "application/octet-stream")

    def test_redirect_strips_unredirected_authorization_too(self):
        req = urllib.request.Request(p.API + "/asset")
        req.add_unredirected_header("Authorization", "Bearer secret")
        redirected = p.AnonymousRedirect().redirect_request(
            req, None, 302, "found", {}, "https://cdn.invalid/asset")
        self.assertIsNone(redirected.get_header("Authorization"))

    def test_own_missing_token_rejected(self):
        for token in (None, "", False, 123):
            with self.subTest(token=token):
                self.rejected(p.OwnAPI, token)

    def test_public_route_cannot_override_api_host(self):
        api = p.PublicAPI()
        for route in ("//evil.invalid/repos/owner/repo", "https://evil.invalid",
                      "/users/owner"):
            with self.subTest(route=route):
                self.rejected(api.get, route)

    def test_pagination_invalid_page_type_rejected(self):
        api = p.PublicAPI()
        with mock.patch.object(api, "get", return_value={"not": "a list"}):
            self.rejected(lambda: list(api.pages("/repos/example/releases")))

    def test_checked_command_failure_rejected(self):
        with mock.patch.object(p, "command", return_value=(
                subprocess.CompletedProcess([], 1, "", "command failed safely"))):
            self.rejected(p.checked, ["nix", "eval"], message="command failed safely")

    def response(self, data=b"{}"):
        response = mock.MagicMock()
        response.__enter__.return_value.read.return_value = data
        return response

    def test_own_token_only_on_fixed_allowed_repository(self):
        api = p.OwnAPI("unit-test-token")
        api.opener = mock.Mock()
        api.opener.open.return_value = self.response()
        api.get("/repos/" + p.REPO)
        req = api.opener.open.call_args.args[0]
        self.assertEqual(req.full_url, p.API + "/repos/" + p.REPO)
        self.assertEqual(req.get_header("Authorization"), "Bearer unit-test-token")
        for repo in (p.SOURCE, p.BUILDS, p.REPO + "-evil"):
            with self.subTest(repo=repo):
                self.rejected(api.get, "/repos/" + repo)
        self.assertEqual(api.opener.open.call_count, 1)

    def test_public_api_never_uses_environment_tokens(self):
        with mock.patch.dict(os.environ, {"GITHUB_TOKEN": "private", "GH_TOKEN": "private"}):
            api = p.PublicAPI()
            api.opener = mock.Mock()
            api.opener.open.return_value = self.response()
            api.get("/repos/" + p.SOURCE)
        req = api.opener.open.call_args.args[0]
        self.assertIsNone(req.get_header("Authorization"))

    def test_own_write_redirects_rejected(self):
        self.rejected(p.NoRedirect().redirect_request, None, None, 302, "", {}, "https://evil.invalid")

    def test_anonymous_redirect_strips_token(self):
        req = urllib.request.Request(p.API + "/asset", headers={"Authorization": "Bearer secret"})
        redirected = p.AnonymousRedirect().redirect_request(
            req, None, 302, "found", {}, "https://cdn.invalid/asset")
        self.assertIsNone(redirected.get_header("Authorization"))
        self.assertEqual(redirected.full_url, "https://cdn.invalid/asset")

    def test_redirect_downgrade_rejected(self):
        req = urllib.request.Request(p.API + "/asset")
        self.rejected(p.AnonymousRedirect().redirect_request,
                      req, None, 302, "found", {}, "http://cdn.invalid/asset")

    def test_all_patch_ref_requests_removed(self):
        api = p.OwnAPI("token")
        for data in ({"sha": HEAD, "force": True}, {"sha": HEAD}, {"sha": HEAD, "force": 0},
                     {"sha": HEAD, "force": False, "extra": 1}):
            with self.subTest(data=data):
                self.rejected(api.call, "PATCH", "/git/refs/heads/" + p.BRANCH, data)

    def test_own_new_ref_fixed_branch_only(self):
        api = p.OwnAPI("token")
        self.rejected(api.call, "POST", "/git/refs", {"ref": "refs/heads/main", "sha": HEAD})

    def test_own_new_ref_exact_authenticated_post(self):
        api = p.OwnAPI("token")
        api.opener = mock.Mock()
        api.opener.open.return_value = self.response()
        data = {"ref": "refs/heads/" + p.BRANCH, "sha": DEFAULT}
        api.call("POST", "/git/refs", data)
        req = api.opener.open.call_args.args[0]
        self.assertEqual(req.full_url, p.API + "/repos/" + p.REPO + "/git/refs")
        self.assertEqual(req.get_method(), "POST")
        self.assertEqual(req.get_header("Authorization"), "Bearer token")
        self.assertEqual(p.parse(req.data), data)

    def test_public_response_size_bound(self):
        api = p.PublicAPI()
        api.opener = mock.Mock()
        api.opener.open.return_value = self.response(b"12345")
        self.rejected(api.raw, "https://cdn.invalid/asset", 4)
        api.opener.open.return_value.__enter__.return_value.read.assert_called_once_with(5)

    def test_public_https_required(self):
        self.rejected(p.PublicAPI().raw, "http://cdn.invalid/asset")

    def test_pagination_walks_all_pages(self):
        api = p.PublicAPI()
        with mock.patch.object(api, "get", side_effect=[
                {"jobs": list(range(100))}, {"jobs": [100]}]) as get:
            self.assertEqual(list(api.pages("/repos/example/jobs?filter=all", "jobs")), list(range(101)))
        self.assertEqual(get.call_args_list[1].args[0],
                         "/repos/example/jobs?filter=all&per_page=100&page=2")

    def test_command_environment_strips_git_and_nix_settings(self):
        with mock.patch.dict(os.environ, {"GIT_ASKPASS": "evil", "NIX_PATH": "evil", "PATH": "/bin"}), \
                mock.patch.object(subprocess, "run", return_value=(
                    subprocess.CompletedProcess([], 0, "", ""))) as run:
            p.command(["git", "status"], ROOT)
        env = run.call_args.kwargs["env"]
        self.assertNotIn("GIT_ASKPASS", env)
        self.assertNotIn("NIX_PATH", env)
        self.assertEqual(env["GIT_CONFIG_GLOBAL"], "/dev/null")
        self.assertEqual(env["GIT_CONFIG_NOSYSTEM"], "1")
        self.assertEqual(env["GIT_TERMINAL_PROMPT"], "0")


class MaterializeTests(PipelineCase):
    def setUp(self):
        super().setUp()
        self.checked = self.stack.enter_context(mock.patch.object(p, "checked", return_value=HEAD))

    def weekly_proposal(self):
        lock = lock_data()
        lock["nodes"]["nixpkgs"]["locked"]["rev"] = NEW_HEAD
        return {"kind": "weekly", "snapshot": p.snapshot(self.public, False),
                "files": {"flake.lock": p.canonical(lock) + "\n",
                          p.REQUEST: p.canonical(request()) + "\n"}}

    def promotion_proposal(self):
        plan = self.plan()
        return {"kind": "promotion", "snapshot": plan["snapshot"],
                "source_hash": SOURCE_HASH, "cargo_hash": CARGO_HASH,
                "source_locked": source_locked(),
                "files": p.promotion_files(self.public, plan, SOURCE_HASH, CARGO_HASH,
                                         source_locked=source_locked())}

    def test_weekly_writes_exact_utf8_only_proposed_files(self):
        candidate = self.candidate()
        proposal = self.weekly_proposal()
        proposal["files"]["flake.lock"] = json.dumps(
            dict(p.parse(proposal["files"]["flake.lock"]), note="café 🦀"),
            ensure_ascii=False) + "\n"
        pin = (candidate / p.PIN).read_bytes()
        flake = (candidate / "flake.nix").read_bytes()
        sentinel = candidate / "unrelated"
        sentinel.write_bytes(b"unchanged")
        with mock.patch.object(p, "OwnAPI") as own, mock.patch.object(p, "output") as output:
            self.assertIsNone(p.materialize(str(candidate), proposal))
        own.assert_not_called()
        output.assert_not_called()
        for name, text in proposal["files"].items():
            self.assertEqual((candidate / name).read_bytes(), text.encode("utf-8"))
        self.assertEqual((candidate / p.PIN).read_bytes(), pin)
        self.assertEqual((candidate / "flake.nix").read_bytes(), flake)
        self.assertEqual(sentinel.read_bytes(), b"unchanged")
        self.assertEqual(self.checked.call_count, 1)
        args = self.checked.call_args.args
        self.assertEqual(args, (["git", "-c", "core.hooksPath=/dev/null",
                                "-C", str(candidate), "rev-parse", "HEAD"],))
        self.assertEqual(self.own.writes + self.public.writes, [])

    def test_promotion_preserves_request_and_unrelated_bytes(self):
        candidate = self.candidate()
        (candidate / ".github").mkdir()
        request_path = candidate / p.REQUEST
        request_path.write_bytes(b"  untouched request bytes\n")
        proposal = self.promotion_proposal()
        p.materialize(str(candidate), proposal)
        self.assertEqual(request_path.read_bytes(), b"  untouched request bytes\n")
        for name, text in proposal["files"].items():
            self.assertEqual((candidate / name).read_bytes(), text.encode())

    def test_metadata_rejected_before_candidate_commands_or_writes(self):
        candidate = self.candidate()
        original = (candidate / "flake.lock").read_bytes()
        for name, metadata in invalid_source_locks():
            with self.subTest(case=name):
                proposal = self.promotion_proposal()
                proposal["source_locked"] = metadata
                self.rejected(p.materialize, str(candidate), proposal)
                self.checked.assert_not_called()
                self.assertEqual((candidate / "flake.lock").read_bytes(), original)
        proposal = self.promotion_proposal()
        lock = p.parse(proposal["files"]["flake.lock"])
        lock["nodes"]["wezterm-src"]["locked"]["revCount"] = 8000
        proposal["files"]["flake.lock"] = p.canonical(lock)
        self.rejected(p.materialize, str(candidate), proposal, message="source locked metadata")
        self.checked.assert_not_called()
        self.assertEqual((candidate / "flake.lock").read_bytes(), original)

    def test_weekly_without_request_leaves_existing_request(self):
        candidate = self.candidate()
        (candidate / ".github").mkdir()
        (candidate / p.REQUEST).write_bytes(b"untouched\n")
        proposal = self.weekly_proposal()
        del proposal["files"][p.REQUEST]
        p.materialize(str(candidate), proposal)
        self.assertEqual((candidate / p.REQUEST).read_bytes(), b"untouched\n")

    def test_pin_only_promotion_leaves_lock_and_flake(self):
        candidate = self.candidate()
        before = {name: (candidate / name).read_bytes() for name in ("flake.lock", "flake.nix")}
        proposal = self.promotion_proposal()
        proposal["files"] = {p.PIN: proposal["files"][p.PIN]}
        p.materialize(str(candidate), proposal)
        for name, raw in before.items():
            self.assertEqual((candidate / name).read_bytes(), raw)

    def test_wrong_head_fails_before_any_write(self):
        candidate = self.candidate()
        original = (candidate / "flake.lock").read_bytes()
        self.checked.return_value = DEFAULT
        self.rejected(p.materialize, str(candidate), self.weekly_proposal(), message="head mismatch")
        self.assertEqual((candidate / "flake.lock").read_bytes(), original)
        self.assertFalse((candidate / p.REQUEST).exists())

    def test_candidate_checkout_root_rejected_without_commands(self):
        self.rejected(p.materialize, str(ROOT), self.weekly_proposal(), message="child")
        self.checked.assert_not_called()

    def test_candidate_path_itself_requires_exact_head(self):
        candidate = self.candidate()
        self.checked.return_value = DEFAULT
        self.rejected(p.candidate_path, str(candidate), HEAD, message="head mismatch")
        self.assertEqual(self.checked.call_count, 1)

    def test_candidate_path_itself_rejects_checkout_root(self):
        self.rejected(p.candidate_path, str(ROOT), HEAD, message="child")
        self.checked.assert_not_called()

    def test_candidate_outside_checkout_rejected_without_commands(self):
        candidate = self.candidate()
        root = self.scratch()
        with mock.patch.object(Path, "cwd", return_value=root):
            self.rejected(p.materialize, str(candidate), self.weekly_proposal(), message="child")
        self.checked.assert_not_called()

    def test_candidate_path_itself_rejects_outside_checkout(self):
        candidate = self.candidate()
        root = self.scratch()
        with mock.patch.object(Path, "cwd", return_value=root):
            self.rejected(p.candidate_path, str(candidate), HEAD, message="child")
        self.checked.assert_not_called()

    def test_missing_branch_weekly_materializes_at_default_head(self):
        candidate = self.candidate()
        proposal = self.weekly_proposal()
        proposal["snapshot"] = dict(proposal["snapshot"], head=DEFAULT,
                                    branch_exists=False, pr_number=None)
        self.checked.return_value = DEFAULT
        p.materialize(str(candidate), proposal)
        self.assertEqual((candidate / "flake.lock").read_bytes(),
                         proposal["files"]["flake.lock"].encode())

    def test_normalized_relative_candidate_path_allowed(self):
        candidate = self.candidate()
        proposal = self.weekly_proposal()
        p.materialize(str(candidate.relative_to(ROOT)), proposal)
        self.assertEqual((candidate / "flake.lock").read_bytes(),
                         proposal["files"]["flake.lock"].encode())

    def test_candidate_symlink_rejected_even_when_resolves_inside_checkout(self):
        candidate = self.candidate()
        link = self.scratch() / "candidate-link"
        link.symlink_to(candidate, target_is_directory=True)
        self.rejected(p.materialize, str(link), self.weekly_proposal(), message="symlink")
        self.checked.assert_not_called()

    def test_candidate_ancestor_symlink_rejected(self):
        candidate = self.candidate()
        link = self.scratch() / "parent-link"
        link.symlink_to(candidate.parent, target_is_directory=True)
        self.rejected(p.materialize, str(link / candidate.name),
                      self.weekly_proposal(), message="symlink")
        self.checked.assert_not_called()

    def test_all_targets_preflight_before_any_write_for_symlink_target(self):
        candidate = self.candidate()
        original = (candidate / "flake.lock").read_bytes()
        target = self.scratch() / "outside"
        target.write_bytes(b"outside untouched\n")
        (candidate / ".github").mkdir()
        (candidate / p.REQUEST).symlink_to(target)
        self.rejected(p.materialize, str(candidate), self.weekly_proposal(), message="symlink")
        self.assertEqual((candidate / "flake.lock").read_bytes(), original)
        self.assertEqual(target.read_bytes(), b"outside untouched\n")

    def test_all_targets_preflight_for_symlink_parent(self):
        candidate = self.candidate()
        original = (candidate / "flake.lock").read_bytes()
        parent = self.scratch()
        (candidate / ".github").symlink_to(parent, target_is_directory=True)
        self.rejected(p.materialize, str(candidate), self.weekly_proposal(), message="symlink")
        self.assertEqual((candidate / "flake.lock").read_bytes(), original)
        self.assertFalse((parent / "wezterm-request.json").exists())

    def test_dangling_target_symlink_rejected(self):
        candidate = self.candidate()
        (candidate / ".github").mkdir()
        missing = self.scratch() / "missing"
        (candidate / p.REQUEST).symlink_to(missing)
        self.rejected(p.materialize, str(candidate), self.weekly_proposal(), message="symlink")
        self.assertFalse(missing.exists())

    def test_all_targets_preflight_for_hardlink(self):
        candidate = self.candidate()
        original = (candidate / "flake.lock").read_bytes()
        target = self.scratch() / "hardlinked"
        target.write_bytes(b"unchanged\n")
        (candidate / ".github").mkdir()
        os.link(target, candidate / p.REQUEST)
        self.rejected(p.materialize, str(candidate), self.weekly_proposal(), message="regular file")
        self.assertEqual((candidate / "flake.lock").read_bytes(), original)
        self.assertEqual(target.read_bytes(), b"unchanged\n")

    def test_all_targets_preflight_for_fifo(self):
        candidate = self.candidate()
        original = (candidate / "flake.lock").read_bytes()
        (candidate / ".github").mkdir()
        os.mkfifo(candidate / p.REQUEST)
        self.rejected(p.materialize, str(candidate), self.weekly_proposal(), message="regular file")
        self.assertEqual((candidate / "flake.lock").read_bytes(), original)

    def test_all_targets_preflight_for_directory_target(self):
        candidate = self.candidate()
        original = (candidate / "flake.lock").read_bytes()
        (candidate / p.REQUEST).mkdir(parents=True)
        self.rejected(p.materialize, str(candidate), self.weekly_proposal(), message="regular file")
        self.assertEqual((candidate / "flake.lock").read_bytes(), original)

    def test_all_targets_preflight_for_non_directory_parent(self):
        candidate = self.candidate()
        original = (candidate / "flake.lock").read_bytes()
        (candidate / ".github").write_bytes(b"not a directory\n")
        self.rejected(p.materialize, str(candidate), self.weekly_proposal(), message="directory")
        self.assertEqual((candidate / "flake.lock").read_bytes(), original)

    def test_cli_materialize_emits_no_outputs_or_authenticated_api(self):
        candidate = self.candidate()
        proposal = self.weekly_proposal()
        output_path = self.scratch() / "github-output"
        output_path.write_bytes(b"existing=untouched\n")
        with mock.patch.object(p, "OwnAPI") as own, \
                mock.patch.object(p, "output") as output, \
                mock.patch.dict(os.environ, {"GITHUB_OUTPUT": str(output_path)}), \
                mock.patch("sys.argv", ["promote-wezterm", "materialize", "--candidate",
                                       str(candidate), "--proposal-b64", p.encode(proposal)]), \
                contextlib.redirect_stdout(io.StringIO()) as stdout:
            p.main()
        own.assert_not_called()
        output.assert_not_called()
        self.assertEqual(stdout.getvalue(), "")
        self.assertEqual(output_path.read_bytes(), b"existing=untouched\n")
        self.assertEqual((candidate / "flake.lock").read_bytes(),
                         proposal["files"]["flake.lock"].encode())

    def test_cli_materialize_explicit_output_ignored(self):
        candidate = self.candidate()
        output = self.scratch() / "github-output"
        with mock.patch.object(p, "OwnAPI") as own, \
                mock.patch("sys.argv", ["promote-wezterm", "materialize", "--candidate",
                                       str(candidate), "--proposal-b64",
                                       p.encode(self.weekly_proposal()), "--output", str(output)]), \
                contextlib.redirect_stdout(io.StringIO()) as stdout:
            p.main()
        own.assert_not_called()
        self.assertEqual(stdout.getvalue(), "")
        self.assertFalse(output.exists())

    def test_cli_materialize_encoded_malformed_proposals_fail_without_writes(self):
        candidate = self.candidate()
        original = (candidate / "flake.lock").read_bytes()
        for encoded in ("invalid!", base64.b64encode(b'{"x":1,"x":2}').decode(),
                        base64.b64encode(b"not JSON").decode(), p.encode(None),
                        p.encode({"kind": "weekly"})):
            with self.subTest(encoded=encoded), \
                    mock.patch.object(p, "OwnAPI") as own, \
                    mock.patch.object(p, "output") as output, \
                    mock.patch("sys.argv", ["promote-wezterm", "materialize", "--candidate",
                                           str(candidate), "--proposal-b64", encoded]):
                self.rejected(p.main)
                own.assert_not_called()
                output.assert_not_called()
                self.assertEqual((candidate / "flake.lock").read_bytes(), original)
                self.assertFalse((candidate / p.REQUEST).exists())
        self.checked.assert_not_called()


class StatusAndCLITests(PipelineCase):
    def setUp(self):
        super().setUp()
        os.environ.update(GITHUB_EVENT_NAME="schedule", GITHUB_REF="refs/heads/main")
        self.stack.enter_context(mock.patch.object(p, "verify_runtime"))

    def test_cli_rejects_nondefault_event_or_branch_before_runtime(self):
        for event, ref_name in (("pull_request", "refs/heads/main"),
                                ("schedule", "refs/heads/untrusted")):
            with self.subTest(event=event, ref=ref_name), \
                    mock.patch.object(p, "PublicAPI", return_value=self.public), \
                    mock.patch.object(p, "OwnAPI", return_value=self.own), \
                    mock.patch.dict(os.environ, {
                        "GITHUB_REPOSITORY": p.REPO, "GITHUB_TOKEN": "token",
                        "GITHUB_EVENT_NAME": event, "GITHUB_REF": ref_name}), \
                    mock.patch("sys.argv", ["promote-wezterm", "inspect"]):
                self.rejected(p.main, message="default-branch")
                p.verify_runtime.assert_not_called()

    def test_status_only_accepted_states(self):
        for state in ("pending", "success", "failure"):
            with self.subTest(state=state):
                p.status(self.own, HEAD, state, "ok",
                         "https://github.com/dc0d32/nixos/actions/runs/123")
        for state in ("error", "neutral", "cancelled", "success\ninjected"):
            with self.subTest(state=state):
                self.rejected(p.status, self.own, HEAD, state, "ok",
                              "https://github.com/dc0d32/nixos/actions/runs/123")

    def test_output_stdout_and_append_semantics(self):
        with contextlib.redirect_stdout(io.StringIO()) as stdout:
            p.output(None, eligible=False, head=HEAD)
        self.assertEqual(stdout.getvalue(), "eligible=false\nhead=" + HEAD + "\n")
        path = self.scratch() / "output"
        p.output(str(path), eligible=False)
        p.output(str(path), head=HEAD)
        self.assertEqual(path.read_text(), stdout.getvalue())

    def test_cli_bad_encoded_plan_rejected_before_prepare(self):
        with mock.patch.object(p, "PublicAPI", return_value=self.public), \
                mock.patch.object(p, "prepare") as prepare, \
                mock.patch("sys.argv", ["promote-wezterm", "prepare", "--candidate", "candidate",
                                       "--plan-b64", "invalid!"]):
            self.rejected(p.main)
        prepare.assert_not_called()

    def test_cli_output_rejects_mocked_publish_head_injection(self):
        output = self.scratch() / "github-output"
        with mock.patch.object(p, "PublicAPI", return_value=self.public), \
                mock.patch.object(p, "OwnAPI", return_value=self.own), \
                mock.patch.object(p, "publish", return_value="safe\nstatus=success"), \
                mock.patch.dict(os.environ, {"GITHUB_REPOSITORY": p.REPO, "GITHUB_TOKEN": "token"}), \
                mock.patch("sys.argv", ["promote-wezterm", "publish", "--output", str(output),
                                       "--plan-b64", p.encode({}), "--proposal-b64", p.encode({})]):
            self.rejected(p.main, message="injection")
        self.assertFalse(output.exists())

    def test_cli_prepare_never_constructs_authenticated_api(self):
        output = self.scratch() / "github-output"
        with mock.patch.object(p, "PublicAPI", return_value=self.public), \
                mock.patch.object(p, "OwnAPI") as own, \
                mock.patch.object(p, "prepare", return_value={"kind": "promotion"}) as prepare, \
                mock.patch("sys.argv", ["promote-wezterm", "prepare", "--candidate", "candidate",
                                       "--plan-b64", p.encode({}), "--output", str(output)]):
            p.main()
        own.assert_not_called()
        prepare.assert_called_once_with(self.public, "candidate", {})
        self.assertEqual(p.decode(output.read_text().strip().split("=", 1)[1]),
                         {"kind": "promotion"})

    def test_status_exact_head_and_own_run_url(self):
        url = "https://github.com/dc0d32/nixos/actions/runs/123/attempts/2"
        p.status(self.own, HEAD, "success", "Verified native build", url)
        self.assertEqual(self.own.writes, [("POST", "/statuses/" + HEAD, {
            "state": "success", "context": "wezterm/native-linux",
            "description": "Verified native build", "target_url": url})])

    def test_status_rejects_other_head_type(self):
        self.rejected(p.status, self.own, "main", "success", "ok",
                      "https://github.com/dc0d32/nixos/actions/runs/123")
        self.assertEqual(self.own.writes, [])

    def test_status_rejects_description_line_injection(self):
        for description in ("ok\ninjected", "ok\r", "ok\0", "", "x" * 141):
            with self.subTest(description=description):
                self.rejected(p.status, self.own, HEAD, "success", description,
                              "https://github.com/dc0d32/nixos/actions/runs/123")

    def test_output_bool_and_base64_are_single_line(self):
        path = self.scratch() / "output"
        p.output(str(path), eligible=True, plan=p.encode(request()))
        lines = path.read_text().splitlines()
        self.assertEqual(lines[0], "eligible=true")
        self.assertEqual(p.decode(lines[1].split("=", 1)[1]), request())

    def test_output_rejects_newlines_atomically(self):
        path = self.scratch() / "output"
        for value in ("x\nhead=evil", "x\rhead=evil"):
            with self.subTest(value=value):
                self.rejected(lambda: p.output(str(path), safe="ok", plan=value))
                self.assertFalse(path.exists())

    def test_output_rejects_invalid_key(self):
        self.rejected(lambda: p.output(None, **{"head\ninjected": "value"}))

    def test_output_rejects_symlink(self):
        work = self.scratch()
        target = work / "target"
        target.write_text("unchanged")
        link = work / "link"
        link.symlink_to(target)
        self.rejected(lambda: p.output(str(link), head=HEAD))
        self.assertEqual(target.read_text(), "unchanged")

    def test_cli_inspect_noop_single_line_outputs(self):
        output = self.scratch() / "github-output"
        with mock.patch.object(p, "PublicAPI", return_value=self.public), \
                mock.patch.object(p, "OwnAPI", return_value=self.own), \
                mock.patch.object(p, "inspect", return_value=None), \
                mock.patch.dict(os.environ, {"GITHUB_REPOSITORY": p.REPO, "GITHUB_TOKEN": "token"}), \
                mock.patch("sys.argv", ["promote-wezterm", "inspect", "--output", str(output)]):
            p.main()
        self.assertEqual(output.read_text(), "eligible=false\nhead=\nrequest=\ndefault_sha=\nplan=\n")

    def test_cli_inspect_encodes_plan_without_multiline_injection(self):
        plan = self.plan()
        output = self.scratch() / "github-output"
        with mock.patch.object(p, "PublicAPI", return_value=self.public), \
                mock.patch.object(p, "OwnAPI", return_value=self.own), \
                mock.patch.dict(os.environ, {"GITHUB_REPOSITORY": p.REPO, "GITHUB_TOKEN": "token"}), \
                mock.patch("sys.argv", ["promote-wezterm", "inspect", "--output", str(output)]):
            p.main()
        values = dict(line.split("=", 1) for line in output.read_text().splitlines())
        self.assertEqual(len(values), 5)
        self.assertEqual(values["head"], HEAD)
        self.assertEqual(p.decode(values["plan"]), plan)

    def test_cli_wrong_repository_rejected_before_api(self):
        with mock.patch.object(p, "OwnAPI") as own, \
                mock.patch.dict(os.environ, {"GITHUB_REPOSITORY": "fork/nixos", "GITHUB_TOKEN": "token"}), \
                mock.patch("sys.argv", ["promote-wezterm", "inspect"]):
            self.rejected(p.main)
            own.assert_not_called()

    def test_cli_rejection_exits_one(self):
        with mock.patch.object(p, "main", side_effect=ValueError("invalid request")), \
                contextlib.redirect_stderr(io.StringIO()) as error:
            with self.assertRaises(SystemExit) as exit_code:
                p.cli()
        self.assertEqual(exit_code.exception.code, 1)
        self.assertIn("rejected operation", error.getvalue())


class SeedCLITests(PipelineCase):
    def setUp(self):
        super().setUp()
        os.environ.update(GITHUB_REPOSITORY=p.REPO, GITHUB_TOKEN="unit-test-token",
                          GITHUB_EVENT_NAME="schedule", GITHUB_REF="refs/heads/main")
        self.runtime = self.stack.enter_context(mock.patch.object(p, "verify_runtime"))
        self.own_constructor = self.stack.enter_context(
            mock.patch.object(p, "OwnAPI", return_value=self.own))
        self.stack.enter_context(mock.patch.object(p, "PublicAPI", return_value=self.public))

    def seed(self, output=None):
        args = ["promote-wezterm", "seed"]
        if output is not None:
            args += ["--output", str(output)]
        with mock.patch("sys.argv", args), contextlib.redirect_stdout(io.StringIO()) as stdout:
            p.main()
        return stdout.getvalue()

    def test_seed_existing_branch_authenticated_read_only(self):
        self.assertEqual(self.seed(), f"head={HEAD}\ndefault_sha={DEFAULT}\n")
        self.own_constructor.assert_called_once_with("unit-test-token")
        self.assertEqual(self.runtime.call_args_list, [mock.call(DEFAULT), mock.call(DEFAULT)])
        self.assertEqual(self.own.writes + self.public.writes, [])
        self.assertEqual(self.public.calls + self.public.reads, [])
        self.assertFalse(any("/contents/" in route for route in self.own.reads))
        self.assertIn(f"/repos/{p.REPO}/pulls/42", self.own.reads)

    def test_seed_missing_branch_outputs_default_as_candidate_head(self):
        self.own.page_routes[f"/repos/{p.REPO}/pulls?state=open&head=dc0d32:{p.BRANCH}", None] = []
        self.own.routes[f"/repos/{p.REPO}/git/ref/heads/{p.BRANCH}"] = urllib.error.HTTPError(
            p.API, 404, "absent", {}, None)
        output = self.scratch() / "github-output"
        self.assertEqual(self.seed(output), "")
        self.assertEqual(output.read_text(), f"head={DEFAULT}\ndefault_sha={DEFAULT}\n")
        self.assertEqual(self.runtime.call_args_list, [mock.call(DEFAULT), mock.call(DEFAULT)])
        self.assertEqual(self.own.writes, [])

    def test_seed_existing_branch_without_pr_still_captures_exact_head(self):
        self.own.page_routes[f"/repos/{p.REPO}/pulls?state=open&head=dc0d32:{p.BRANCH}", None] = []
        self.assertEqual(self.seed(), f"head={HEAD}\ndefault_sha={DEFAULT}\n")
        self.assertEqual(self.own.writes, [])

    def test_seed_dispatch_on_default_branch_allowed(self):
        os.environ["GITHUB_EVENT_NAME"] = "workflow_dispatch"
        self.assertEqual(self.seed(), f"head={HEAD}\ndefault_sha={DEFAULT}\n")
        self.assertEqual(self.own.writes, [])

    def test_seed_wrong_repository_rejected_before_authentication(self):
        os.environ["GITHUB_REPOSITORY"] = "fork/nixos"
        self.rejected(self.seed)
        self.own_constructor.assert_not_called()
        self.runtime.assert_not_called()
        self.assertEqual(self.own.reads + self.own.writes, [])

    def test_seed_requires_token(self):
        del os.environ["GITHUB_TOKEN"]
        self.own_constructor.side_effect = ValueError("GITHUB_TOKEN required")
        self.rejected(self.seed, message="GITHUB_TOKEN")
        self.runtime.assert_not_called()
        self.assertEqual(self.own.reads + self.own.writes, [])

    def test_seed_event_branch_guard_precedes_runtime_and_snapshot(self):
        for event, branch in (("pull_request", "refs/heads/main"),
                              ("push", "refs/heads/main"),
                              ("schedule", "refs/heads/" + p.BRANCH),
                              ("workflow_dispatch", "refs/tags/main")):
            with self.subTest(event=event, branch=branch), \
                    mock.patch.dict(os.environ, {"GITHUB_EVENT_NAME": event, "GITHUB_REF": branch}), \
                    mock.patch.object(p, "snapshot") as snapshot:
                self.rejected(self.seed, message="default-branch")
                snapshot.assert_not_called()
                self.runtime.assert_not_called()
        self.assertEqual(self.own.writes, [])

    def test_seed_initial_runtime_failure_emits_no_outputs(self):
        self.runtime.side_effect = ValueError("runtime scripts differ")
        output = self.scratch() / "output"
        with mock.patch.object(p, "snapshot") as snapshot:
            self.rejected(self.seed, output)
        snapshot.assert_not_called()
        self.assertFalse(output.exists())
        self.assertEqual(self.own.writes, [])

    def test_seed_revalidates_runtime_at_captured_default_sha(self):
        def advance_default(sha):
            if sha == DEFAULT:
                self.own.routes[f"/repos/{p.REPO}/git/ref/heads/main"] = ref("main", NEW_HEAD)
            else:
                raise ValueError("runtime differs from captured default")

        self.runtime.side_effect = advance_default
        output = self.scratch() / "output"
        self.rejected(self.seed, output, message="captured default")
        self.assertEqual(self.runtime.call_args_list, [mock.call(DEFAULT), mock.call(NEW_HEAD)])
        self.assertFalse(output.exists())
        self.assertEqual(self.own.writes, [])

    def test_seed_invalid_pr_emits_no_outputs(self):
        self.own.routes[f"/repos/{p.REPO}/pulls/42"]["head"]["repo"]["fork"] = True
        output = self.scratch() / "output"
        self.rejected(self.seed, output)
        self.assertFalse(output.exists())
        self.assertEqual(self.own.writes, [])

    def test_seed_never_executes_candidate_or_nix(self):
        with mock.patch.object(p, "candidate_path") as candidate, \
                mock.patch.object(p, "command") as command, \
                mock.patch.object(p, "materialize") as materialize:
            self.seed()
        candidate.assert_not_called()
        command.assert_not_called()
        materialize.assert_not_called()


class RuntimeTests(PipelineCase):
    def runtime(self):
        root = self.scratch()
        (root / "scripts").mkdir()
        for name in ("wezterm_pipeline.py", "wezterm-request.py", "promote-wezterm.py"):
            (root / "scripts" / name).write_text("# trusted\n")
        return root

    def test_unchanged_trusted_runtime_and_sanitized_hookless_git(self):
        root = self.runtime()
        with mock.patch.object(p, "__file__", str(root / "scripts/wezterm_pipeline.py")), \
                mock.patch.object(subprocess, "run", return_value=(
                    subprocess.CompletedProcess([], 0, b"# trusted\n", b""))) as run, \
                mock.patch.dict(os.environ, {"GITHUB_TOKEN": "secret", "GIT_ASKPASS": "evil"}):
            p.verify_runtime(DEFAULT)
        self.assertEqual(run.call_count, 3)
        for call in run.call_args_list:
            self.assertIn("core.hooksPath=/dev/null", call.args[0])
            self.assertNotIn("GITHUB_TOKEN", call.kwargs["env"])
            self.assertNotIn("GIT_ASKPASS", call.kwargs["env"])
            self.assertEqual(call.kwargs["env"]["GIT_CONFIG_GLOBAL"], "/dev/null")

    def test_runtime_modified_script_rejected(self):
        root = self.runtime()
        with mock.patch.object(p, "__file__", str(root / "scripts/wezterm_pipeline.py")), \
                mock.patch.object(subprocess, "run", return_value=(
                    subprocess.CompletedProcess([], 0, b"# other\n", b""))):
            self.rejected(p.verify_runtime, DEFAULT, message="trusted default")

    def test_runtime_missing_git_object_rejected(self):
        root = self.runtime()
        with mock.patch.object(p, "__file__", str(root / "scripts/wezterm_pipeline.py")), \
                mock.patch.object(subprocess, "run", return_value=(
                    subprocess.CompletedProcess([], 128, b"", b"missing"))):
            self.rejected(p.verify_runtime, DEFAULT, message="trusted default")

    def test_runtime_world_or_group_writable_rejected(self):
        for mode in (0o646, 0o664):
            root = self.runtime()
            (root / "scripts/wezterm_pipeline.py").chmod(mode)
            with self.subTest(mode=mode), mock.patch.object(
                    p, "__file__", str(root / "scripts/wezterm_pipeline.py")):
                self.rejected(p.verify_runtime, DEFAULT, message="permissions")

    def test_runtime_symlink_script_rejected(self):
        root = self.runtime()
        entry = root / "scripts/wezterm_pipeline.py"
        entry.unlink()
        entry.symlink_to(root / "scripts/promote-wezterm.py")
        with mock.patch.object(p, "__file__", str(entry)):
            self.rejected(p.verify_runtime, DEFAULT, message="permissions")


def add_cases(cls, label, cases, run):
    """Expose each contract mutation as its own discoverable unittest."""
    for name, value in cases.items():
        def test(self, value=value):
            run(self, copy.deepcopy(value))
        test.__name__ = "test_" + label + "_" + name
        setattr(cls, test.__name__, test)


def reject_request(self, field_value):
    field, value = field_value
    obj = request()
    obj[field] = value
    self.rejected(p.validate_request, obj)


add_cases(RequestTests, "reject", {
    "schema_bool": ("schema", True), "schema_string": ("schema", "1"),
    "schema_float": ("schema", 1.0), "schema_two": ("schema", 2),
    "wrong_repository": ("repository", "fork/nixos"),
    "wrong_branch": ("branch", "main"), "wrong_source": ("source_repository", "fork/wezterm"),
    "sha_uppercase": ("source_sha", "A" * 40), "sha_short": ("source_sha", "a" * 39),
    "hash_uppercase": ("request_id", "A" * 64), "hash_mismatch": ("request_id", "0" * 64),
    "nonce_integer": ("nonce", 12345), "nonce_zero": ("nonce", "0"),
    "nonce_negative": ("nonce", "-1"), "nonce_leading_zero": ("nonce", "01"),
    "nonce_whitespace": ("nonce", "1\n"), "nonce_decimal": ("nonce", "1.0"),
    "date_offset": ("requested_at", "2026-10-11T15:30:00+00:00"),
    "date_impossible": ("requested_at", "2026-02-30T15:30:00Z"),
    "date_fraction_long": ("requested_at", "2026-10-11T15:30:00.1234567Z"),
    "date_newline": ("requested_at", "2026-10-11T15:30:00Z\n"),
    "extra_key": ("unexpected", "value"),
}, reject_request)


def reject_pr(self, path_value):
    path, value = path_value
    obj = self.own.routes[f"/repos/{p.REPO}/pulls/42"]
    change(obj, path, value)
    self.rejected(p.snapshot, self.own)


add_cases(SnapshotTests, "reject_pr", {
    "fork": (("head", "repo", "fork"), True),
    "foreign_head": (("head", "repo", "full_name"), "fork/nixos"),
    "deleted_head_repo": (("head", "repo"), None),
    "closed": (("state",), "closed"), "merged_flag": (("merged",), True),
    "merged_date": (("merged_at",), DATE),
    "wrong_head_branch": (("head", "ref"), "main"),
    "foreign_base": (("base", "repo", "full_name"), "fork/nixos"),
    "changed_base": (("base", "ref"), "old-default"),
    "number_bool": (("number",), True),
    "head_sha_invalid": (("head", "sha"), "main"),
}, reject_pr)


def reject_manifest(self, field_value):
    field, value = field_value
    obj = copy.deepcopy(self.manifest)
    obj[field] = value
    self.rejected(p.validate_manifest, obj)


add_cases(ReleaseTests, "reject_manifest", {
    "schema_bool": ("schema", True), "success_int": ("success", 1),
    "run_bool": ("run_id", True), "run_string": ("run_id", "9001"),
    "attempt_zero": ("run_attempt", 0), "build_id": ("build_id", SHA + "-9001-1"),
    "archive_name": ("asset_name", "../evil.zip"), "root": ("archive_root", "wrong"),
    "sha_uppercase": ("sha256", "A" * 64), "size_bool": ("size", True),
    "size_zero": ("size", 0), "size_limit": ("size", p.MAX_ZIP + 1),
    "repository": ("build_repository", "evil/builds"),
    "nonce": ("nonce", "999"), "request_identity": ("request_id", "0" * 64),
    "version": ("version", "20261010-073911-bbbbbbbb"), "unknown_key": ("extra", 1),
}, reject_manifest)


def reject_run(self, path_value):
    path, value = path_value
    obj = self.public.routes[f"/repos/{p.BUILDS}/actions/runs/9001/attempts/2"]
    change(obj, path, value)
    self.rejected(p.prove_run, self.public, self.manifest)


add_cases(ReleaseTests, "reject_run", {
    "id_bool": (("id",), True), "id_wrong": (("id",), 9002),
    "attempt": (("run_attempt",), 1), "attempt_string": (("run_attempt",), "2"),
    "workflow_path": (("path",), ".github/workflows/evil.yml"),
    "workflow_ref_suffix": (("path",), ".github/workflows/windows-build.yml@main"),
    "pr_event": (("event",), "pull_request"), "push_event": (("event",), "push"),
    "foreign_repo": (("head_repository", "full_name"), "fork/wezterm-builds"),
    "branch": (("head_branch",), "untrusted"), "head_sha": (("head_sha",), "main"),
    "incomplete": (("status",), "in_progress"), "failed": (("conclusion",), "failure"),
}, reject_run)


def reject_job(self, job_field_value):
    name, field, value = job_field_value
    rows = self.public.page_routes[f"/repos/{p.BUILDS}/actions/runs/9001/attempts/2/jobs", "jobs"]
    next(row for row in rows if row["name"] == name)[field] = value
    self.rejected(p.prove_run, self.public, self.manifest)


add_cases(ReleaseTests, "reject_job", {
    f"{name}_{label}": (name, field, value)
    for name in ("build", "publish")
    for label, field, value in (
        ("attempt", "run_attempt", 1), ("run", "run_id", 9002),
        ("failed", "conclusion", "failure"), ("incomplete", "status", "in_progress"),
    )
}, reject_job)


def reject_release(self, field_value):
    field, value = field_value
    self.release[field] = value
    self.rejected(p.validate_release, self.public, self.release, SHA, VERSION)


add_cases(ReleaseTests, "reject_release", {
    "mutable": ("immutable", False), "immutable_integer": ("immutable", 1),
    "draft": ("draft", True), "prerelease": ("prerelease", True),
    "id_bool": ("id", True), "tag": ("tag_name", "wezterm-" + SHA + "-9001-1"),
}, reject_release)


def reject_asset(self, field_value):
    field, value = field_value
    asset = copy.deepcopy(self.release["assets"][0])
    asset[field] = value
    self.rejected(p.release_asset, self.public, asset, p.MAX_ZIP)


add_cases(ReleaseTests, "reject_asset", {
    "id_bool": ("id", True), "id_zero": ("id", 0),
    "size_bool": ("size", True), "state": ("state", "new"),
    "external_url": ("url", "https://evil.invalid/asset"),
    "wrong_repository": ("url", f"{p.API}/repos/{p.SOURCE}/releases/assets/201"),
    "wrong_id_url": ("url", f"{p.API}/repos/{p.BUILDS}/releases/assets/202"),
    "digest": ("digest", "sha256:" + "0" * 64),
}, reject_asset)


def reject_tag(self, path_value):
    path, value = path_value
    obj = self.public.routes[f"/repos/{p.BUILDS}/git/ref/tags/{self.release['tag_name']}"]
    change(obj, path, value)
    self.rejected(p.validate_release, self.public, self.release, SHA, VERSION)


add_cases(ReleaseTests, "reject_tag", {
    "wrong_ref": (("ref",), "refs/tags/wrong"),
    "annotated": (("object", "type"), "tag"),
    "head_mismatch": (("object", "sha"), OLD_SHA),
}, reject_tag)


def reject_zip_path(self, path):
    root = "WezTerm-windows-" + VERSION
    self.rejected(p.check_zip, zip_bytes(extra=((path.replace("{root}", root), b"x"),)), root)


add_cases(ZipTests, "unsafe_path", {
    "traversal": "{root}/../escape", "dot": "{root}/./escape",
    "empty_component": "{root}//escape", "absolute": "/escape",
    "drive_absolute": "C:/escape", "backslash": "{root}/sub\\escape",
    "ads": "{root}/file:stream", "device_con": "{root}/CON",
    "device_extension": "{root}/nul.txt", "device_com": "{root}/COM1.exe",
    "device_unicode": "{root}/LPT¹.txt", "trailing_space": "{root}/file ",
    "trailing_dot": "{root}/file.", "control": "{root}/bad\x01file",
    "wildcard": "{root}/*.exe", "pipe": "{root}/file|name",
}, reject_zip_path)


def reject_nix(self, text):
    self.rejected(p.NixData, text)


add_cases(NixDataTests, "executable", {
    "import": "import ./evil.nix",
    "let": 'let x = 1; in { revision = x; }',
    "function": "{ pkgs }: { revision = pkgs; }",
    "builtins": '{ x = builtins.readFile "/etc/passwd"; }',
    "interpolation": '{ x = "${builtins.readFile /etc/passwd}"; }',
    "escaped_interpolation": '{ x = "\\\\${evil}"; }',
    "inherit": "{ inherit evil; }", "path": "{ x = ./evil; }",
    "concat": '{ x = "a" + "b"; }', "recursive": "rec { x = 1; }",
    "duplicate": "{ x = 1; x = 2; }", "trailing": "{} // {}",
    "quoted_key": '{ "x" = 1; }', "indented_string": "{ x = ''evil''; }",
}, reject_nix)


def reject_pin(self, path_value):
    path, value = path_value
    obj = pin_data()
    change(obj, path, value)
    self.rejected(p.validate_pin, p.nix_literal(obj))


add_cases(NixDataTests, "reject_pin", {
    "revision": (("revision",), "main"), "cargo_hash": (("cargoHash",), "bad"),
    "source_hash": (("sourceHash",), "bad"),
    "headers": (("assets", "windows", "headers"), {"Authorization": "token"}),
    "architectures": (("assets", "windows", "architectures"), ["aarch64"]),
    "asset_bool": (("assets", "windows", "assetId"), True),
    "size_bool": (("assets", "windows", "size"), True),
    "hash_identity": (("assets", "windows", "hash"), SOURCE_HASH),
    "url": (("assets", "windows", "url"), "https://evil.invalid/archive.zip"),
    "status": (("assets", "windows", "status"), "ready"),
}, reject_pin)


def reject_source_node(self, path_value):
    path, value = path_value
    obj = lock_data()
    change(obj["nodes"]["wezterm-src"], path, value)
    self.rejected(p.source_node, obj)


add_cases(LockTests, "reject_source_node", {
    "flake_true": (("flake",), True), "type": (("locked", "type"), "github"),
    "url": (("locked", "url"), "https://evil.invalid/wezterm"),
    "submodules": (("locked", "submodules"), False),
    "revision": (("locked", "rev"), "main"), "hash": (("locked", "narHash"), "bad"),
}, reject_source_node)


def reject_token(self, key):
    plan = self.plan()
    with mock.patch.dict(os.environ, {key: "present"}), \
            mock.patch.object(p, "recheck") as recheck:
        self.rejected(p.prepare, self.public, "unused", plan)
        recheck.assert_not_called()
        self.rejected(p.discover_hashes, self.public, plan)
        self.rejected(p.weekly, self.public, "unused")
        self.rejected(p.command, ["nix", "eval"])


add_cases(PrepareTests, "token_environment", {
    "github_token": "GITHUB_TOKEN", "gh_token": "GH_TOKEN",
    "nix_config": "NIX_CONFIG", "nix_user_conf": "NIX_USER_CONF_FILES",
}, reject_token)


def reject_mismatch(self, stderr):
    checked_patch, command_patch = self.discovery(stderr=stderr)
    with checked_patch, command_patch:
        self.rejected(p.discover_hashes, self.public, self.plan(), message="mismatch proof")


MISMATCH = (
    f"error: hash mismatch in fixed-output derivation '{HashDiscoveryTests.DRV}':\n"
    f"  specified: {p.FAKE_HASH}\n  got: {CARGO_HASH}\n"
)
add_cases(HashDiscoveryTests, "reject_mismatch", {
    "arbitrary_got": "build output: got: " + CARGO_HASH,
    "wrong_derivation": MISMATCH.replace(HashDiscoveryTests.DRV, HashDiscoveryTests.DRV + "-other"),
    "wrong_specified": MISMATCH.replace(p.FAKE_HASH, SOURCE_HASH),
    "duplicate_proof": MISMATCH * 2,
    "bad_hash": MISMATCH.replace(CARGO_HASH, "sha256-invalid"),
}, reject_mismatch)


def reject_own_route(self, method_suffix):
    api = p.OwnAPI("token")
    method, suffix = method_suffix
    self.rejected(api.call, method, suffix, {})


add_cases(APITests, "reject_route", {
    "external_url": ("GET", "https://api.github.com/repos/evil/repo"),
    "releases": ("POST", "/releases"), "delete": ("DELETE", "/git/refs/heads/main"),
    "patch_main": ("PATCH", "/git/refs/heads/main"),
    "traversal": ("GET", "/contents/../secret?ref=" + HEAD),
    "double_slash": ("GET", "/git/ref/heads//main"),
    "contents_branch": ("GET", "/contents/flake.nix?ref=main"),
    "workflow": ("POST", "/actions/workflows/evil.yml/dispatches"),
    "blobs": ("POST", "/git/blobs"), "trees": ("POST", "/git/trees"),
    "commits": ("POST", "/git/commits"),
    "patch_automation": ("PATCH", "/git/refs/heads/" + p.BRANCH),
    "patch_pull": ("PATCH", "/pulls/42"),
}, reject_own_route)


def reject_status_url(self, url):
    self.rejected(p.status, self.own, HEAD, "success", "ok", url)
    self.assertEqual(self.own.writes, [])


add_cases(StatusAndCLITests, "reject_status_url", {
    "external": "https://evil.invalid/actions/runs/123",
    "foreign_repo": "https://github.com/evil/nixos/actions/runs/123",
    "http": "http://github.com/dc0d32/nixos/actions/runs/123",
    "query": "https://github.com/dc0d32/nixos/actions/runs/123?evil=1",
    "newline": "https://github.com/dc0d32/nixos/actions/runs/123\ninjected",
    "zero": "https://github.com/dc0d32/nixos/actions/runs/0",
}, reject_status_url)


def reject_graphql_variables(self, path_value):
    path, value = path_value
    variables = p.commit_variables(HEAD, {"flake.lock": "{}\n"}, "test")
    if path:
        change(variables, path, value)
    else:
        variables = value
    api = self.graphql_api()
    self.rejected(api.graphql, p.CREATE_COMMIT_QUERY, variables)
    api.opener.open.assert_not_called()


add_cases(APITests, "graphql_variables", {
    "null": ((), None), "list": ((), []), "extra": (("extra",), True),
    "input_null": (("input",), None), "input_extra": (("input", "extra"), True),
    "repo": (("input", "branch", "repositoryNameWithOwner"), "fork/nixos"),
    "branch": (("input", "branch", "branchName"), "main"),
    "branch_extra": (("input", "branch", "extra"), True),
    "branch_null": (("input", "branch"), None),
    "head_uppercase": (("input", "expectedHeadOid"), "A" * 40),
    "head_short": (("input", "expectedHeadOid"), "a" * 39),
    "head_long": (("input", "expectedHeadOid"), "a" * 41),
    "head_branch": (("input", "expectedHeadOid"), "main"),
    "head_null": (("input", "expectedHeadOid"), None),
    "message_null": (("input", "message"), None),
    "message_extra": (("input", "message", "body"), "unexpected"),
    "headline_empty": (("input", "message", "headline"), ""),
    "headline_cr": (("input", "message", "headline"), "test\r"),
    "headline_lf": (("input", "message", "headline"), "test\n"),
    "headline_nul": (("input", "message", "headline"), "test\0"),
    "headline_limit": (("input", "message", "headline"), "x" * 257),
    "headline_int": (("input", "message", "headline"), 123),
    "changes_null": (("input", "fileChanges"), None),
    "deletions": (("input", "fileChanges", "deletions"), [{"path": p.PIN}]),
    "additions_empty": (("input", "fileChanges", "additions"), []),
    "additions_dict": (("input", "fileChanges", "additions"), {}),
    "additions_too_many": (("input", "fileChanges", "additions"),
                           [{"path": "flake.lock", "contents": "eA=="}] * 5),
    "addition_null": (("input", "fileChanges", "additions", 0), None),
    "addition_extra": (("input", "fileChanges", "additions", 0, "mode"), "100644"),
    "path_unknown": (("input", "fileChanges", "additions", 0, "path"), "README.md"),
    "path_traversal": (("input", "fileChanges", "additions", 0, "path"), "../flake.lock"),
    "path_absolute": (("input", "fileChanges", "additions", 0, "path"), "/flake.lock"),
    "path_int": (("input", "fileChanges", "additions", 0, "path"), 1),
    "path_duplicate": (("input", "fileChanges", "additions"),
                       [{"path": "flake.lock", "contents": "eA=="}] * 2),
    "content_null": (("input", "fileChanges", "additions", 0, "contents"), None),
    "content_bytes": (("input", "fileChanges", "additions", 0, "contents"), b"eA=="),
    "content_invalid_base64": (("input", "fileChanges", "additions", 0, "contents"), "invalid!"),
    "content_whitespace": (("input", "fileChanges", "additions", 0, "contents"), "eA==\n"),
    "content_noncanonical": (("input", "fileChanges", "additions", 0, "contents"), "eB=="),
    "content_invalid_utf8": (("input", "fileChanges", "additions", 0, "contents"), "/w=="),
    "content_crlf": (("input", "fileChanges", "additions", 0, "contents"),
                     base64.b64encode(b"x\r\n").decode()),
}, reject_graphql_variables)


def reject_graphql_missing_key(self, path_key):
    path, key = path_key
    variables = p.commit_variables(HEAD, {"flake.lock": "{}\n"}, "test")
    target = variables
    for part in path:
        target = target[part]
    del target[key]
    api = self.graphql_api()
    self.rejected(api.graphql, p.CREATE_COMMIT_QUERY, variables)
    api.opener.open.assert_not_called()


add_cases(APITests, "graphql_missing", {
    "input": ((), "input"),
    **{name: (("input",), name) for name in ("branch", "expectedHeadOid", "message", "fileChanges")},
    "repo": (("input", "branch"), "repositoryNameWithOwner"),
    "branch_name": (("input", "branch"), "branchName"),
    "headline": (("input", "message"), "headline"),
    "additions": (("input", "fileChanges"), "additions"),
    "path": (("input", "fileChanges", "additions", 0), "path"),
    "contents": (("input", "fileChanges", "additions", 0), "contents"),
}, reject_graphql_missing_key)


def reject_graphql_result(self, raw):
    api = self.graphql_api()
    api.opener.open.return_value = self.response(raw)
    self.rejected(api.graphql, p.CREATE_COMMIT_QUERY,
                  p.commit_variables(HEAD, {"flake.lock": "{}\n"}, "test"))
    api.opener.open.assert_called_once()


add_cases(APITests, "graphql_result", {
    "null": b"null", "list": b"[]", "scalar": b"true", "empty": b"{}",
    "invalid_json": b"{", "empty_bytes": b"", "nonfinite": b'{"data":NaN}',
    "errors": b'{"errors":[{"message":"expected head mismatch"}]}',
    "partial_data_errors": p.canonical({
        "data": {"createCommitOnBranch": {"commit": {"oid": NEW_HEAD}}},
        "errors": [{"message": "partial failure"}]}).encode(),
    "empty_errors": p.canonical({
        "data": {"createCommitOnBranch": {"commit": {"oid": NEW_HEAD}}}, "errors": []}).encode(),
    "null_errors": p.canonical({
        "data": {"createCommitOnBranch": {"commit": {"oid": NEW_HEAD}}}, "errors": None}).encode(),
    "data_null": b'{"data":null}', "data_list": b'{"data":[]}', "data_empty": b'{"data":{}}',
    "mutation_null": b'{"data":{"createCommitOnBranch":null}}',
    "mutation_list": b'{"data":{"createCommitOnBranch":[]}}',
    "commit_missing": b'{"data":{"createCommitOnBranch":{}}}',
    "commit_null": b'{"data":{"createCommitOnBranch":{"commit":null}}}',
    "commit_list": b'{"data":{"createCommitOnBranch":{"commit":[]}}}',
    **{name: p.canonical({"data": {"createCommitOnBranch": {
        "commit": {"oid": value}}}}).encode()
       for name, value in (("oid_null", None), ("oid_int", 123), ("oid_branch", "main"),
                           ("oid_uppercase", "F" * 40), ("oid_short", "f" * 39))},
    "oid_missing": b'{"data":{"createCommitOnBranch":{"commit":{}}}}',
    "duplicate_key": b'{"data":null,"data":{}}',
}, reject_graphql_result)


def reject_graphql_oversized_content(self, kind):
    variables = p.commit_variables(HEAD, {"flake.lock": "{}\n"}, "test")
    raw = ("é" * (2 * 1024 * 1024) + "x").encode() if kind == "utf8" else (
        b"x" * (4 * 1024 * 1024 + 3))
    variables["input"]["fileChanges"]["additions"][0]["contents"] = base64.b64encode(raw).decode()
    api = self.graphql_api()
    self.rejected(api.graphql, p.CREATE_COMMIT_QUERY, variables)
    api.opener.open.assert_not_called()


add_cases(APITests, "graphql_content_limit", {"utf8": "utf8", "base64": "base64"},
          reject_graphql_oversized_content)


def reject_new_ref_data(self, data):
    api = self.graphql_api()
    self.rejected(api.call, "POST", "/git/refs", data)
    api.opener.open.assert_not_called()


add_cases(APITests, "new_ref_data", {
    "null": None, "list": [], "empty": {}, "missing_ref": {"sha": DEFAULT},
    "missing_sha": {"ref": "refs/heads/" + p.BRANCH},
    "extra": {"ref": "refs/heads/" + p.BRANCH, "sha": DEFAULT, "extra": 1},
    "force": {"ref": "refs/heads/" + p.BRANCH, "sha": DEFAULT, "force": False},
    "tag": {"ref": "refs/tags/" + p.BRANCH, "sha": DEFAULT},
    "upper_sha": {"ref": "refs/heads/" + p.BRANCH, "sha": "D" * 40},
    "short_sha": {"ref": "refs/heads/" + p.BRANCH, "sha": "d" * 39},
    "branch_sha": {"ref": "refs/heads/" + p.BRANCH, "sha": "main"},
}, reject_new_ref_data)


def reject_write_files_before_seed(self, files):
    snap = self.missing_branch()
    self.own.reads.clear()
    self.rejected(p.write_commit, self.own, snap, files, "test")
    self.assertEqual(self.own.writes + self.own.reads, [])
    self.assertEqual(self.own.advancements, [])
    self.assertIsInstance(self.own.routes[f"/repos/{p.REPO}/git/ref/heads/{p.BRANCH}"],
                          urllib.error.HTTPError)


add_cases(PublishTests, "malformed_file_before_seed", {
    "null": None, "list": [], "empty": {}, "unknown": {"scripts/evil.py": "x"},
    "bytes": {"flake.lock": b"{}\n"}, "integer": {"flake.lock": 1},
    "crlf": {"flake.lock": "{}\r\n"}, "surrogate": {"flake.lock": "\ud800"},
    "oversized_utf8": {"flake.lock": "é" * (2 * 1024 * 1024 + 1)},
    "later_invalid": {"flake.lock": "{}\n", p.REQUEST: b"invalid"},
}, reject_write_files_before_seed)


def reject_commit_message_before_seed(self, message):
    snap = self.missing_branch()
    self.own.reads.clear()
    self.rejected(p.write_commit, self.own, snap, {"flake.lock": "{}\n"}, message)
    self.assertEqual(self.own.reads + self.own.writes, [])


add_cases(PublishTests, "malformed_message_before_seed", {
    "empty": "", "cr": "test\r", "lf": "test\n", "nul": "test\0",
    "oversized": "x" * 257, "null": None, "integer": 1,
}, reject_commit_message_before_seed)


def reject_snapshot_before_seed(self, field_value):
    key, value = field_value
    snap = self.missing_branch()
    if value == "missing":
        del snap[key]
    else:
        snap[key] = value
    self.own.reads.clear()
    self.rejected(p.write_commit, self.own, snap, {"flake.lock": "{}\n"}, "test")
    self.assertEqual(self.own.reads + self.own.writes, [])


add_cases(PublishTests, "malformed_snapshot_before_seed", {
    "extra": ("extra", 1), "head_uppercase": ("head", "D" * 40),
    "default_sha": ("default_sha", "main"), "branch_bool": ("branch_exists", 0),
    "branch_traversal": ("default_branch", "../main"),
    "pr_bool": ("pr_number", True), "absent_wrong_head": ("head", HEAD),
    **{f"missing_{key}": (key, "missing") for key in
       ("default_branch", "default_sha", "head", "branch_exists", "pr_number")},
}, reject_snapshot_before_seed)


def reject_seed_post_create_race(self, kind):
    snap = self.missing_branch()
    path = f"/repos/{p.REPO}/git/ref/heads/{p.BRANCH}"
    raced = False

    def race(route):
        nonlocal raced
        if not self.own.writes or raced:
            return
        raced = True
        self.assertEqual(self.own.writes, [
            ("POST", "/git/refs", {"ref": "refs/heads/" + p.BRANCH, "sha": DEFAULT})])
        self.assertEqual(p.branch_ref(self.own, p.BRANCH), DEFAULT)
        if kind == "default":
            self.own.routes[f"/repos/{p.REPO}/git/ref/heads/main"] = ref("main", NEW_HEAD)
        elif kind == "head":
            self.own.routes[path] = ref(p.BRANCH, NEW_HEAD)
        elif kind == "delete":
            self.own.routes[path] = urllib.error.HTTPError(p.API, 404, "deleted", {}, None)
        elif kind == "pr":
            self.own.page_routes[f"/repos/{p.REPO}/pulls?state=open&head=dc0d32:{p.BRANCH}", None] = [
                {"number": 42}]
            self.own.routes[f"/repos/{p.REPO}/pulls/42"]["head"]["sha"] = DEFAULT

    self.own.on_get = race
    self.rejected(p.write_commit, self.own, snap, {"flake.lock": "{}\n"}, "test",
                  message="before ref update")
    self.assertTrue(raced)
    self.assertEqual(len(self.own.writes), 1)
    self.assertEqual(self.own.advancements, [])


add_cases(PublishTests, "post_create_race", {name: name for name in ("default", "head", "pr", "delete")},
          reject_seed_post_create_race)


def reject_materialize_proposal(self, path_value):
    path, value = path_value
    proposal = self.weekly_proposal() if path[0] != "promotion" else self.promotion_proposal()
    if path[0] == "promotion":
        path = path[1:]
    if path:
        change(proposal, path, value)
    else:
        proposal = value
    candidate = self.candidate()
    before = {name: (candidate / name).read_bytes() for name in (p.PIN, "flake.lock", "flake.nix")}
    self.rejected(p.materialize, str(candidate), proposal)
    self.checked.assert_not_called()
    for name, raw in before.items():
        self.assertEqual((candidate / name).read_bytes(), raw)
    self.assertFalse((candidate / p.REQUEST).exists())


add_cases(MaterializeTests, "invalid_proposal", {
    "null": (("promotion",), None), "list": (("promotion",), []),
    "kind": (("kind",), "unknown"), "extra": (("extra",), True),
    "files_empty": (("files",), {}), "files_null": (("files",), None),
    "missing_lock": (("files",), {p.REQUEST: p.canonical(request())}),
    "weekly_pin": (("files", p.PIN), p.nix_literal(pin_data())),
    "weekly_flake": (("files", "flake.nix"), "{}\n"),
    "unknown_path": (("files", "scripts/evil.py"), "evil"),
    "lock_bytes": (("files", "flake.lock"), b"{}\n"),
    "lock_crlf": (("files", "flake.lock"), "{}\r\n"),
    "lock_invalid_json": (("files", "flake.lock"), "invalid"),
    "lock_duplicate_json": (("files", "flake.lock"), '{"nodes":{},"nodes":{}}'),
    "lock_invalid_source": (("files", "flake.lock"), p.canonical(
        dict(lock_data(), nodes={**lock_data()["nodes"], "wezterm-src": {"flake": True}}))),
    "request_invalid_json": (("files", p.REQUEST), "invalid"),
    "request_schema": (("files", p.REQUEST), p.canonical(dict(request(), schema=True))),
    "request_identity": (("files", p.REQUEST), p.canonical(dict(request(), request_id="0" * 64))),
    "snapshot_null": (("snapshot",), None), "snapshot_extra": (("snapshot", "extra"), True),
    "snapshot_default_sha": (("snapshot", "default_sha"), "main"),
    "snapshot_head_uppercase": (("snapshot", "head"), "C" * 40),
    "snapshot_default_branch": (("snapshot", "default_branch"), "../main"),
    "snapshot_default_branch_double_slash": (("snapshot", "default_branch"), "main//child"),
    "snapshot_exists_integer": (("snapshot", "branch_exists"), 1),
    "snapshot_pr_bool": (("snapshot", "pr_number"), True),
    "snapshot_pr_zero": (("snapshot", "pr_number"), 0),
    "snapshot_absent_with_pr": (("snapshot", "branch_exists"), False),
    "snapshot_absent_wrong_head": (("snapshot",), {
        "default_branch": "main", "default_sha": DEFAULT, "head": HEAD,
        "branch_exists": False, "pr_number": None}),
    "promotion_source_hash": (("promotion", "source_hash"), "bad"),
    "promotion_cargo_hash": (("promotion", "cargo_hash"), "bad"),
    "promotion_missing_pin": (("promotion", "files"), {"flake.lock": p.canonical(lock_data()),
                                                       "flake.nix": "{}\n"}),
    "promotion_unpaired_lock": (("promotion", "files"), {
        p.PIN: p.nix_literal(pin_data()), "flake.lock": p.canonical(lock_data())}),
    "promotion_unpaired_flake": (("promotion", "files"), {
        p.PIN: p.nix_literal(pin_data()), "flake.nix": "{}\n"}),
    "promotion_request": (("promotion", "files", p.REQUEST), p.canonical(request())),
    "promotion_executable_pin": (("promotion", "files", p.PIN), "import ./evil.nix"),
    "promotion_invalid_pin": (("promotion", "files", p.PIN), p.nix_literal(
        dict(pin_data(), cargoHash="bad"))),
    "promotion_extra": (("promotion", "extra"), True),
}, reject_materialize_proposal)


def reject_materialize_missing_key(self, kind_path_key):
    kind, path, key = kind_path_key
    proposal = self.weekly_proposal() if kind == "weekly" else self.promotion_proposal()
    target = proposal
    for part in path:
        target = target[part]
    del target[key]
    candidate = self.candidate()
    original = (candidate / "flake.lock").read_bytes()
    self.rejected(p.materialize, str(candidate), proposal)
    self.checked.assert_not_called()
    self.assertEqual((candidate / "flake.lock").read_bytes(), original)


add_cases(MaterializeTests, "missing_key", {
    **{f"weekly_{key}": ("weekly", (), key) for key in ("kind", "snapshot", "files")},
    **{f"promotion_{key}": ("promotion", (), key) for key in
       ("kind", "snapshot", "source_hash", "cargo_hash", "source_locked", "files")},
    **{f"snapshot_{key}": ("weekly", ("snapshot",), key) for key in
       ("default_branch", "default_sha", "head", "branch_exists", "pr_number")},
}, reject_materialize_missing_key)


def reject_materialize_token(self, key):
    candidate = self.candidate()
    original = (candidate / "flake.lock").read_bytes()
    proposal = self.weekly_proposal()
    with mock.patch.dict(os.environ, {key: "present"}):
        self.rejected(p.materialize, str(candidate), proposal, message="clean environment")
        with mock.patch.object(p, "OwnAPI") as own, \
                mock.patch.object(p, "output") as output, \
                mock.patch("sys.argv", ["promote-wezterm", "materialize", "--candidate",
                                       str(candidate), "--proposal-b64", p.encode(proposal)]):
            self.rejected(p.main, message="clean environment")
            own.assert_not_called()
            output.assert_not_called()
    self.checked.assert_not_called()
    self.assertEqual((candidate / "flake.lock").read_bytes(), original)
    self.assertFalse((candidate / p.REQUEST).exists())


add_cases(MaterializeTests, "forbidden_environment", {
    "github_token": "GITHUB_TOKEN", "gh_token": "GH_TOKEN", "nix_config": "NIX_CONFIG",
    "nix_user_conf": "NIX_USER_CONF_FILES",
}, reject_materialize_token)


if __name__ == "__main__":
    unittest.main()
