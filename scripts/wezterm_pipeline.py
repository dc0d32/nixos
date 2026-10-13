#!/usr/bin/env python3
"""Data-only WezTerm coordinator; untrusted Nix runs only without credentials.

Publishing uses createCommitOnBranch(expectedHeadOid): GitHub atomically
compares the existing ref and commits all additions, including on ancestor
resets. New refs are first created at the captured default SHA. PR/default
checks are separate guards, not a cross-PR transaction.

Workflow contract: seed emits trusted default/head checkout SHAs; prepare
discovers hashes using only the trusted default's fixed expression, in its
own job. Pass its proposal via authenticated GitHub needs outputs, never
artifacts or outputs from a candidate-execution job. A separate token-free
job checks the exact current candidate SHA, materializes the proposal using
the trusted default's script, then checks the proposed tree. No outputs
from that candidate job are consumed by a writer.
"""

import argparse
import base64
import copy
import datetime as dt
import hashlib
import io
import json
import os
from pathlib import Path
import re
import stat
import struct
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
import zipfile
import zlib

REPO = "dc0d32/nixos"
BRANCH = "automation/update-flake-lock"
SOURCE = "wezterm/wezterm"
BUILDS = "dc0d32/wezterm-builds"
REQUEST = ".github/wezterm-request.json"
PIN = "overlays/wezterm-pin.nix"
API = "https://api.github.com"
WRITE_PATHS = frozenset((PIN, REQUEST, "flake.lock", "flake.nix"))
CREATE_COMMIT_QUERY = """mutation CreateCommit($input: CreateCommitOnBranchInput!) {
  createCommitOnBranch(input: $input) {
    commit { oid }
  }
}"""
FAKE_HASH = "sha256-" + base64.b64encode(bytes(32)).decode()
MAX_ZIP = 1024 * 1024 * 1024
REQUEST_KEYS = {
    "schema", "repository", "branch", "source_repository", "source_sha",
    "request_id", "nonce", "requested_at",
}
MANIFEST_KEYS = {
    "schema", "source_repository", "source_sha", "build_repository", "run_id",
    "run_attempt", "build_id", "version", "assets", "success", "request_id",
    "nonce", "requested_at",
}
MANIFEST_ASSET_KEYS = {"name", "architecture", "archive_root", "sha256", "size"}
WINDOWS_ARCHITECTURES = ("x86_64", "aarch64")
WINDOWS_EXECUTABLES = {
    "wezterm.exe", "wezterm-gui.exe", "wezterm-mux-server.exe",
    "strip-ansi-escapes.exe",
}
WINDOWS_PDBS = {name.removesuffix(".exe") + ".pdb" for name in WINDOWS_EXECUTABLES}
X86_SIDECARS = {
    "conpty.dll", "OpenConsole.exe", "libEGL.dll", "libGLESv2.dll",
    "mesa/opengl32.dll",
}
PE_MACHINES = {"x86_64": 0x8664, "aarch64": 0xAA64}


def require(ok, message):
    if not ok:
        raise ValueError(message)


def hexstr(value, length=40):
    return isinstance(value, str) and re.fullmatch(r"[0-9a-f]{%d}" % length, value) is not None


def positive(value):
    return type(value) is int and value > 0


def unique(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, "duplicate JSON key")
        result[key] = value
    return result


def parse(data):
    return json.loads(data, object_pairs_hook=unique,
                      parse_constant=lambda _: require(False, "nonfinite JSON"))


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True)


def encode(value):
    return base64.b64encode(canonical(value).encode()).decode()


def decode(value):
    require(isinstance(value, str) and len(value) < 8 * 1024 * 1024, "encoded data size")
    return parse(base64.b64decode(value, validate=True))


def sri(hex_digest):
    require(hexstr(hex_digest, 64), "SHA256 digest")
    return "sha256-" + base64.b64encode(bytes.fromhex(hex_digest)).decode()


def valid_sri(value):
    if not isinstance(value, str) or not value.startswith("sha256-"):
        return False
    try:
        raw = base64.b64decode(value[7:], validate=True)
        return len(raw) == 32 and base64.b64encode(raw).decode() == value[7:]
    except ValueError:
        return False


def validate_request(obj):
    require(type(obj) is dict and set(obj) == REQUEST_KEYS, "request keys")
    require(type(obj["schema"]) is int and obj["schema"] == 1, "request schema")
    require(obj["repository"] == REPO and obj["branch"] == BRANCH
            and obj["source_repository"] == SOURCE, "request repositories/branch")
    require(hexstr(obj["source_sha"]) and hexstr(obj["request_id"], 64), "request SHA")
    require(isinstance(obj["nonce"], str)
            and re.fullmatch(r"[1-9][0-9]*", obj["nonce"]), "request nonce")
    stamp = obj["requested_at"]
    require(isinstance(stamp, str) and re.fullmatch(
        r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,6})?Z", stamp), "UTC request date")
    dt.datetime.fromisoformat(stamp.replace("Z", "+00:00"))
    material = f"{REPO}\n{BRANCH}\n{obj['source_sha']}\n{obj['nonce']}"
    require(hashlib.sha256(material.encode()).hexdigest() == obj["request_id"], "request identity")
    return obj


def make_request(sha, nonce, now=None):
    obj = dict(schema=1, repository=REPO, branch=BRANCH, source_repository=SOURCE,
               source_sha=sha, nonce=nonce,
               requested_at=(now or dt.datetime.now(dt.timezone.utc)).astimezone(
                   dt.timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z"))
    obj["request_id"] = hashlib.sha256(f"{REPO}\n{BRANCH}\n{sha}\n{nonce}".encode()).hexdigest()
    return validate_request(obj)


class AnonymousRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        require(urllib.parse.urlsplit(newurl).scheme == "https", "HTTPS redirects only")
        redirected = super().redirect_request(req, fp, code, msg, headers, newurl)
        if redirected:
            redirected.remove_header("Authorization")
        return redirected


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args):
        raise ValueError("authenticated redirects forbidden")


class PublicAPI:
    """Never reads environment tokens, even when used in a privileged job."""

    def __init__(self):
        self.opener = urllib.request.build_opener(AnonymousRedirect())

    def raw(self, url, limit=4 * 1024 * 1024, octets=False):
        require(urllib.parse.urlsplit(url).scheme == "https", "HTTPS reads only")
        req = urllib.request.Request(url, headers={
            "Accept": "application/octet-stream" if octets else "application/vnd.github+json",
            "User-Agent": "dc0d32-nixos-wezterm", "X-GitHub-Api-Version": "2022-11-28",
            "Cache-Control": "no-cache",
        })
        with self.opener.open(req, timeout=120) as response:
            content = response.read(limit + 1)
        require(len(content) <= limit, "public response size")
        return content

    def get(self, path):
        require(path.startswith("/repos/") and not path.startswith("//"), "public API route")
        return parse(self.raw(API + path))

    def pages(self, path, key=None):
        for page in range(1, 1001):
            sep = "&" if "?" in path else "?"
            result = self.get(f"{path}{sep}per_page=100&page={page}")
            rows = result[key] if key else result
            require(type(rows) is list, "API pagination")
            yield from rows
            if len(rows) < 100:
                return
        raise ValueError("pagination limit")


class OwnAPI(PublicAPI):
    """Authentication is confined to allowlisted coordinator repository routes."""

    def __init__(self, token):
        require(isinstance(token, str) and bool(token), "GITHUB_TOKEN required")
        self.token = token
        self.opener = urllib.request.build_opener(NoRedirect())

    def call(self, method, suffix, data=None):
        routes = {
            "POST": r"/(?:git/refs|pulls|statuses/[0-9a-f]{40})",
            "GET": r"(?:|/pulls(?:\?[^#]*)?|/pulls/[1-9][0-9]*|/git/ref/heads/[A-Za-z0-9._/-]+"
                   r"|/contents/[A-Za-z0-9._/-]+\?ref=[0-9a-f]{40}|/git/commits/[0-9a-f]{40}"
                   r"|/commits/[0-9a-f]{40}/statuses(?:\?per_page=100&page=[1-9][0-9]*)?)",
        }
        require(method in routes and re.fullmatch(routes[method], suffix), "own API route")
        require(".." not in suffix and "//" not in suffix, "unsafe own route")
        if method == "POST" and suffix == "/git/refs":
            require(type(data) is dict and set(data) == {"ref", "sha"}
                    and data["ref"] == "refs/heads/" + BRANCH and hexstr(data["sha"]),
                    "fixed new ref")
        req = urllib.request.Request(API + "/repos/" + REPO + suffix, method=method,
                                     data=None if data is None else canonical(data).encode(),
                                     headers={"Authorization": "Bearer " + self.token,
                                              "Accept": "application/vnd.github+json",
                                              "Content-Type": "application/json",
                                              "User-Agent": "dc0d32-nixos-wezterm",
                                              "X-GitHub-Api-Version": "2022-11-28"})
        with self.opener.open(req, timeout=120) as response:
            return parse(response.read(8 * 1024 * 1024))

    def graphql(self, query, variables):
        """Only this typed, fixed-repository exact-head mutation may use the token."""
        require(query == CREATE_COMMIT_QUERY, "fixed GraphQL query")
        validate_commit_variables(variables)
        req = urllib.request.Request(
            API + "/graphql", method="POST",
            data=canonical({"query": CREATE_COMMIT_QUERY, "variables": variables}).encode(),
            headers={"Authorization": "Bearer " + self.token,
                     "Accept": "application/vnd.github+json", "Content-Type": "application/json",
                     "User-Agent": "dc0d32-nixos-wezterm",
                     "X-GitHub-Api-Version": "2022-11-28"})
        with self.opener.open(req, timeout=120) as response:
            raw = response.read(8 * 1024 * 1024 + 1)
        require(len(raw) <= 8 * 1024 * 1024, "GraphQL response size")
        result = parse(raw)
        require(type(result) is dict and "errors" not in result, "GraphQL errors")
        data = result.get("data")
        require(type(data) is dict, "GraphQL data")
        mutation = data.get("createCommitOnBranch")
        require(type(mutation) is dict and type(mutation.get("commit")) is dict
                and hexstr(mutation["commit"].get("oid")), "GraphQL commit")
        return mutation["commit"]["oid"]

    def get(self, path):
        prefix = "/repos/" + REPO
        require(path == prefix or path.startswith(prefix + "/"), "authenticated own repository only")
        return self.call("GET", path[len(prefix):])


def validate_write_files(files):
    require(type(files) is dict and 0 < len(files) <= len(WRITE_PATHS), "write files")
    for path, text in files.items():
        require(path in WRITE_PATHS and isinstance(text, str)
                and len(text.encode("utf-8")) <= 4 * 1024 * 1024
                and "\r" not in text, "write file allowlist/LF")
    return files


def commit_variables(head, files, message):
    validate_write_files(files)
    variables = {"input": {
        "branch": {"repositoryNameWithOwner": REPO, "branchName": BRANCH},
        "expectedHeadOid": head, "message": {"headline": message},
        "fileChanges": {"additions": [
            {"path": path, "contents": base64.b64encode(text.encode("utf-8")).decode("ascii")}
            for path, text in sorted(files.items())]},
    }}
    validate_commit_variables(variables)
    return variables


def validate_commit_variables(variables):
    require(type(variables) is dict and set(variables) == {"input"}, "GraphQL variables")
    value = variables["input"]
    require(type(value) is dict and set(value) == {
        "branch", "expectedHeadOid", "message", "fileChanges"}, "GraphQL input")
    require(value["branch"] == {"repositoryNameWithOwner": REPO, "branchName": BRANCH}
            and hexstr(value["expectedHeadOid"]), "GraphQL fixed branch/head")
    message = value["message"]
    require(type(message) is dict and set(message) == {"headline"}
            and isinstance(message["headline"], str) and 0 < len(message["headline"]) <= 256
            and not re.search(r"[\r\n\x00]", message["headline"]), "GraphQL message")
    changes = value["fileChanges"]
    require(type(changes) is dict and set(changes) == {"additions"}
            and type(changes["additions"]) is list
            and 0 < len(changes["additions"]) <= len(WRITE_PATHS), "GraphQL additions")
    files = {}
    for addition in changes["additions"]:
        require(type(addition) is dict and set(addition) == {"path", "contents"},
                "GraphQL addition")
        path, contents = addition["path"], addition["contents"]
        require(isinstance(path, str) and path in WRITE_PATHS and path not in files
                and isinstance(contents, str) and len(contents) <= 4 * ((4 * 1024 * 1024 + 2) // 3),
                "GraphQL addition path/size")
        raw = base64.b64decode(contents, validate=True)
        require(base64.b64encode(raw).decode("ascii") == contents, "GraphQL base64")
        files[path] = raw.decode("utf-8")
    validate_write_files(files)


def optional(api, path):
    try:
        return api.get(path)
    except urllib.error.HTTPError as exc:
        if exc.code == 404:
            return None
        raise


def branch_ref(api, branch):
    require(isinstance(branch, str) and re.fullmatch(r"[A-Za-z0-9._/-]+", branch)
            and ".." not in branch and "//" not in branch, "branch name")
    obj = api.get(f"/repos/{REPO}/git/ref/heads/{branch}")
    require(obj.get("ref") == "refs/heads/" + branch
            and obj.get("object", {}).get("type") == "commit"
            and hexstr(obj["object"].get("sha")), "commit ref")
    return obj["object"]["sha"]


def content(api, path, sha, missing=False):
    require(hexstr(sha), "content ref SHA")
    obj = optional(api, f"/repos/{REPO}/contents/{path}?ref={sha}") if missing else api.get(
        f"/repos/{REPO}/contents/{path}?ref={sha}")
    if obj is None:
        return None, None
    require(obj.get("type") == "file" and obj.get("path") == path
            and obj.get("encoding") == "base64" and hexstr(obj.get("sha"))
            and type(obj.get("size")) is int and 0 < obj["size"] <= 4 * 1024 * 1024,
            "content metadata")
    raw = base64.b64decode(obj["content"].replace("\n", ""), validate=True)
    require(len(raw) == obj["size"] and hashlib.sha1(
        f"blob {len(raw)}\0".encode() + raw).hexdigest() == obj["sha"], "content blob identity")
    return raw, obj["sha"]


def valid_pr(pr, default):
    head, base = pr.get("head") or {}, pr.get("base") or {}
    repo = head.get("repo") or {}
    return (pr.get("state") == "open" and pr.get("merged_at") is None
            and pr.get("merged", False) is False and repo.get("full_name") == REPO
            and repo.get("fork") is False and head.get("ref") == BRANCH
            and hexstr(head.get("sha")) and (base.get("repo") or {}).get("full_name") == REPO
            and base.get("ref") == default and positive(pr.get("number")))


def snapshot(api, require_pr=True):
    default = api.get("/repos/" + REPO)["default_branch"]
    default_sha = branch_ref(api, default)
    rows = list(api.pages(f"/repos/{REPO}/pulls?state=open&head=dc0d32:{BRANCH}"))
    require(len(rows) <= 1, "ambiguous update PR")
    ref = optional(api, f"/repos/{REPO}/git/ref/heads/{BRANCH}")
    head = default_sha if ref is None else branch_ref(api, BRANCH)
    if not rows:
        if require_pr:
            return None
        return dict(default_branch=default, default_sha=default_sha, head=head,
                    branch_exists=ref is not None, pr_number=None)
    pr = api.get(f"/repos/{REPO}/pulls/{rows[0]['number']}")
    require(valid_pr(pr, default) and pr["head"]["sha"] == head, "invalid update PR")
    return dict(default_branch=default, default_sha=default_sha, head=head,
                branch_exists=True, pr_number=pr["number"])


def source_info(api, sha=None):
    if sha is None:
        metadata = api.get(f"/repos/{SOURCE}")
        require(type(metadata) is dict, "upstream repository metadata")
        branch = metadata.get("default_branch")
        require(isinstance(branch, str) and 0 < len(branch) <= 255
                and re.fullmatch(r"[A-Za-z0-9_][A-Za-z0-9._/-]*", branch)
                and ".." not in branch and "//" not in branch
                and all(part and not part.startswith(".") and not part.endswith((".", ".lock"))
                        for part in branch.split("/")), "upstream default branch")
        ref = urllib.parse.quote(branch, safe="")
    else:
        ref = sha
    commit = api.get(f"/repos/{SOURCE}/commits/{ref}")
    resolved = commit["sha"]
    require(hexstr(resolved) and (sha is None or sha == resolved), "exact upstream SHA")
    stamp = dt.datetime.fromisoformat(commit["commit"]["committer"]["date"].replace("Z", "+00:00"))
    require(stamp.tzinfo is not None, "upstream timestamp timezone")
    stamp = stamp.astimezone(dt.timezone.utc)
    return resolved, stamp.isoformat(timespec="seconds").replace("+00:00", "Z"), (
        stamp.strftime("%Y%m%d-%H%M%S") + "-" + resolved[:8])


def validate_manifest(obj):
    require(type(obj) is dict and set(obj) == MANIFEST_KEYS, "manifest keys")
    require(type(obj["schema"]) is int and obj["schema"] == 2 and obj["success"] is True
            and obj["source_repository"] == SOURCE and obj["build_repository"] == BUILDS,
            "manifest repository/schema/success")
    req = {key: obj[key] for key in REQUEST_KEYS if key in obj and key != "schema"}
    req.update(schema=1, repository=REPO, branch=BRANCH)
    validate_request(req)
    require(positive(obj["run_id"]) and positive(obj["run_attempt"]), "manifest run identity")
    identity = f"{obj['source_sha']}-{obj['run_id']}-{obj['run_attempt']}"
    require(obj["build_id"] == identity, "build identity")
    require(isinstance(obj["version"], str) and re.fullmatch(
        r"\d{8}-\d{6}-" + obj["source_sha"][:8], obj["version"]), "manifest version")
    require(type(obj["assets"]) is dict and set(obj["assets"]) == {"windows"},
            "manifest platform assets")
    windows = obj["assets"]["windows"]
    require(type(windows) is dict and set(windows) == set(WINDOWS_ARCHITECTURES),
            "manifest architectures")
    for architecture in WINDOWS_ARCHITECTURES:
        asset = windows[architecture]
        prefix = f"WezTerm-windows-{architecture}-"
        require(type(asset) is dict and set(asset) == MANIFEST_ASSET_KEYS,
                architecture + " manifest asset keys")
        require(asset["architecture"] == architecture
                and asset["name"] == prefix + identity + ".zip",
                architecture + " asset identity")
        root_prefix = "WezTerm-windows-" if architecture == "x86_64" else prefix
        require(asset["archive_root"] == root_prefix + obj["version"],
                architecture + " archive root")
        require(hexstr(asset["sha256"], 64) and positive(asset["size"])
                and asset["size"] <= MAX_ZIP, architecture + " manifest digest/size")
    return obj


def prove_run(api, manifest):
    run_id, attempt = manifest["run_id"], manifest["run_attempt"]
    default = api.get(f"/repos/{BUILDS}")["default_branch"]
    prefix = f"/repos/{BUILDS}/actions/runs/{run_id}/attempts/{attempt}"
    run = api.get(prefix)
    require(type(run.get("id")) is int and run["id"] == run_id
            and type(run.get("run_attempt")) is int and run["run_attempt"] == attempt
            and run.get("path") == ".github/workflows/windows-build.yml"
            and run.get("event") in ("schedule", "workflow_dispatch")
            and (run.get("head_repository") or {}).get("full_name") == BUILDS
            and run.get("head_branch") == default and hexstr(run.get("head_sha"))
            and run.get("status") == "completed" and run.get("conclusion") == "success",
            "durable successful workflow provenance")
    jobs = list(api.pages(prefix + "/jobs", key="jobs"))
    for name in ("build-x64", "build-arm64", "validate-arm64", "publish"):
        selected = [job for job in jobs if job.get("name") == name]
        require(len(selected) == 1 and selected[0].get("run_id") == run_id
                and selected[0].get("run_attempt") == attempt
                and selected[0].get("status") == "completed"
                and selected[0].get("conclusion") == "success", "successful same-attempt " + name)
    return run


def check_pe_machine(data, architecture):
    require(len(data) >= 64 and data[:2] == b"MZ", "Windows PE header")
    offset = struct.unpack_from("<I", data, 0x3c)[0]
    require(offset <= len(data) - 6 and data[offset:offset + 4] == b"PE\0\0"
            and struct.unpack_from("<H", data, offset + 4)[0] == PE_MACHINES[architecture],
            architecture + " PE machine")


def check_zip(data, root, architecture="x86_64"):
    require(architecture in WINDOWS_ARCHITECTURES, "ZIP architecture")
    required = WINDOWS_EXECUTABLES | {"wezterm.pdb"} | (
        X86_SIDECARS if architecture == "x86_64" else set())
    # Per-executable debug symbols are optional, not native runtime dependencies.
    allowed = None if architecture == "x86_64" else required | WINDOWS_PDBS
    with zipfile.ZipFile(io.BytesIO(data)) as archive:
        entries = archive.infolist()
        require(0 < len(entries) <= 10000, "ZIP member count")
        seen, paths, files = set(), {}, set()
        total = 0
        for entry in entries:
            name = entry.filename
            require(name == entry.orig_filename and "\0" not in name and "\\" not in name
                    and name.startswith(root + "/"), "ZIP root/path")
            parts = name.rstrip("/").split("/")
            require(all(part and part not in (".", "..") and not part.endswith((" ", "."))
                        and not re.search(r'[<>:"|?*\x00-\x1f]', part)
                        and not re.fullmatch(
                            r"(?i)(con|prn|aux|nul|com[0-9¹²³]|lpt[0-9¹²³])(?:\..*)?", part)
                        for part in parts), "unsafe ZIP path")
            folded = name.rstrip("/").casefold()
            require(folded not in seen, "duplicate ZIP entry")
            seen.add(folded)
            for index in range(1, len(parts) + 1):
                path = "/".join(parts[:index])
                old = paths.get(path.casefold())
                directory = index < len(parts) or entry.is_dir()
                require(old is None or (old[0] == path and old[1] and directory),
                        "ZIP file/directory or case collision")
                paths[path.casefold()] = (path, directory)
            require(stat.S_IFMT(entry.external_attr >> 16) in (0, stat.S_IFREG, stat.S_IFDIR)
                    and not entry.flag_bits & 1 and entry.compress_type in
                    (zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED), "ZIP special/encoding")
            total += entry.file_size
            require(entry.file_size <= 512 * 1024 * 1024 and total <= 2 * MAX_ZIP,
                    "ZIP expansion limit")
            if not entry.is_dir():
                require(entry.file_size > 0, "empty ZIP member")
                relative = name[len(root) + 1:]
                files.add(relative)
                with archive.open(entry) as stream:
                    while stream.read(1024 * 1024):
                        pass
                if relative.lower().endswith((".exe", ".dll")):
                    with archive.open(entry) as stream:
                        check_pe_machine(stream.read(1024 * 1024), architecture)
        require(required <= files, "missing Windows runtime")
        require(allowed is None or files <= allowed, "unexpected aarch64 runtime")


def release_asset(api, asset, limit):
    require(positive(asset.get("id")) and asset.get("state") == "uploaded"
            and type(asset.get("size")) is int and 0 < asset["size"] <= limit, "asset metadata")
    url = f"{API}/repos/{BUILDS}/releases/assets/{asset['id']}"
    require(asset.get("url") == url, "pinned trusted asset URL")
    data = api.raw(url, limit, octets=True)
    require(len(data) == asset["size"] and asset.get("digest") ==
            "sha256:" + hashlib.sha256(data).hexdigest(), "release asset digest/size")
    return data


def validate_release(api, release, sha, version):
    require(release.get("immutable") is True and release.get("draft") is False
            and release.get("prerelease") is False and positive(release.get("id")),
            "immutable normal release required")
    assets = release.get("assets")
    require(type(assets) is list and len(assets) == 4, "exact release asset count")
    by_name = {asset["name"]: asset for asset in assets}
    require(len(by_name) == 4 and "provenance.json" in by_name
            and "SHA256SUMS" in by_name, "unique release assets")
    manifest = validate_manifest(parse(release_asset(api, by_name["provenance.json"], 16384)))
    require(manifest["source_sha"] == sha and manifest["version"] == version
            and release.get("tag_name") == "wezterm-" + manifest["build_id"]
            and set(by_name) == {"provenance.json", "SHA256SUMS"} | {
                asset["name"] for asset in manifest["assets"]["windows"].values()},
            "release source/tag/version identity")
    run = prove_run(api, manifest)
    tag = api.get(f"/repos/{BUILDS}/git/ref/tags/{release['tag_name']}")
    require(tag.get("ref") == "refs/tags/" + release["tag_name"]
            and tag.get("object", {}).get("type") == "commit"
            and tag["object"].get("sha") == run["head_sha"], "release tag workflow identity")
    sum_lines = [
        (f"{manifest['assets']['windows'][architecture]['sha256']}  "
         f"{manifest['assets']['windows'][architecture]['name']}\n").encode()
        for architecture in sorted(WINDOWS_ARCHITECTURES)
    ]
    sums = release_asset(api, by_name["SHA256SUMS"], 1024)
    require(sums == b"".join(sum_lines), "SHA256SUMS")
    asset_ids = {}
    for architecture in WINDOWS_ARCHITECTURES:
        proof = manifest["assets"]["windows"][architecture]
        archive = by_name[proof["name"]]
        require(archive["size"] == proof["size"]
                and archive.get("digest") == "sha256:" + proof["sha256"],
                architecture + " archive identity")
        data = release_asset(api, archive, MAX_ZIP)
        require(hashlib.sha256(data).hexdigest() == proof["sha256"],
                architecture + " archive SHA256")
        check_zip(data, proof["archive_root"], architecture)
        asset_ids[architecture] = archive["id"]
    return dict(release_id=release["id"], asset_ids=asset_ids, manifest=manifest)


def find_release(api, sha, version):
    for release in api.pages(f"/repos/{BUILDS}/releases"):
        if not str(release.get("tag_name", "")).startswith("wezterm-" + sha + "-"):
            continue
        try:
            return validate_release(api, release, sha, version)
        except (ValueError, KeyError, zipfile.BadZipFile, zlib.error, EOFError) as exc:
            print("Ignoring invalid/incomplete release:", exc, file=sys.stderr)
    return None


def inspect(own, public):
    snap = snapshot(own)
    if snap is None:
        return None
    raw, blob = content(own, REQUEST, snap["head"], missing=True)
    if raw is None:
        return None
    request = validate_request(parse(raw))
    sha, date, version = source_info(public, request["source_sha"])
    released = find_release(public, sha, version)
    if released is None:
        return None
    plan = dict(snapshot=snap, request=request, request_blob=blob,
                commit_date=date, version=version, release=released)
    completed = completed_promotion(own, plan)
    recheck(own, public, plan)
    return None if completed else plan


def recheck(own, public, plan):
    require(type(plan) is dict and set(plan) == {
        "snapshot", "request", "request_blob", "commit_date", "version", "release"}, "plan keys")
    validate_request(plan["request"])
    require(snapshot(own) == plan["snapshot"], "closed, merged or superseded PR/default")
    raw, blob = content(own, REQUEST, plan["snapshot"]["head"])
    require(blob == plan["request_blob"] and parse(raw) == plan["request"], "request superseded")
    sha, date, version = source_info(public, plan["request"]["source_sha"])
    require((sha, date, version) == (
        plan["request"]["source_sha"], plan["commit_date"], plan["version"]),
        "requested upstream commit changed")


class NixData:
    """Parse the complete pin as inert data; interpolation and expressions fail closed."""

    token = re.compile(r'\s+|#[^\n]*|/\*[\s\S]*?\*/|"(?:[^"\\]|\\["\\nrt])*"|'
                       r'[A-Za-z_][A-Za-z0-9_-]*|[0-9]+|[{}=;\[\]]')

    def __init__(self, text):
        self.text, self.tokens, self.pos, self.spans = text, [], 0, {}
        offset = 0
        while offset < len(text):
            match = self.token.match(text, offset)
            require(match is not None, "pin is not inert Nix data")
            token = match.group()
            if not token.isspace() and not token.startswith(("#", "/*")):
                require("${" not in token, "pin interpolation forbidden")
                self.tokens.append((token, match.start(), match.end()))
            offset = match.end()
        self.data = self.value(())
        require(self.pos == len(self.tokens), "trailing pin expression")

    def take(self, expected=None):
        require(self.pos < len(self.tokens), "truncated Nix data")
        item = self.tokens[self.pos]
        self.pos += 1
        require(expected is None or item[0] == expected, "Nix data token")
        return item

    def value(self, path):
        token, start, end = self.take()
        if token == "{":
            value = {}
            while self.tokens[self.pos][0] != "}":
                key = self.take()[0]
                require(re.fullmatch(r"[A-Za-z_][A-Za-z0-9_-]*", key)
                        and key not in value, "Nix duplicate/invalid key")
                self.take("=")
                value[key] = self.value(path + (key,))
                self.take(";")
            end = self.take("}")[2]
        elif token == "[":
            value = []
            while self.tokens[self.pos][0] != "]":
                value.append(self.value(path + (str(len(value)),)))
            end = self.take("]")[2]
        elif token.startswith('"'):
            value = json.loads(token)
        elif token.isdigit():
            value = int(token)
        elif token in ("true", "false"):
            value = token == "true"
        elif token == "null":
            value = None
        else:
            raise ValueError("executable Nix pin rejected")
        self.spans[path] = (start, end)
        return value

    def rewrite(self, changes):
        replacements = []
        for path, value in changes.items():
            require(path in self.spans, "missing pin field")
            start, end = self.spans[path]
            line = self.text[self.text.rfind("\n", 0, start) + 1:start]
            # Inline fixtures have no field indentation; use the attribute depth.
            field = re.fullmatch(r'([ \t]*)[A-Za-z_][A-Za-z0-9_-]*\s*=\s*', line)
            indent = field[1] if field else "  " * len(path)
            replacements.append((start, end, nix_pin_literal(value, indent)))
        text = self.text
        for start, end, replacement in sorted(replacements, reverse=True):
            text = text[:start] + replacement + text[end:]
        return text


def nix_literal(value):
    if value is None:
        return "null"
    if isinstance(value, str):
        require("${" not in value, "Nix interpolation")
        return json.dumps(value)
    if type(value) is bool:
        return "true" if value else "false"
    if type(value) is int:
        return str(value)
    if type(value) is list:
        return "[ " + " ".join(nix_literal(item) for item in value) + " ]"
    if type(value) is dict:
        require(all(re.fullmatch(r"[A-Za-z_][A-Za-z0-9_-]*", key) for key in value), "Nix keys")
        return "{ " + " ".join(key + " = " + nix_literal(item) + ";" for key, item in value.items()) + " }"
    raise ValueError("Nix data type")


def nix_pin_literal(value, indent=""):
    """Render inert pin values, without invoking Nix or changing surrounding bytes."""
    if value is None:
        return "null"
    if isinstance(value, str):
        require("${" not in value, "Nix interpolation")
        require(all(ord(char) >= 32 or char in "\n\r\t" for char in value),
                "Nix string control character")
        return json.dumps(value, ensure_ascii=False)
    if type(value) is dict:
        require(all(isinstance(key, str) and re.fullmatch(
            r"[A-Za-z_][A-Za-z0-9_-]*", key) for key in value), "Nix keys")
        if not value:
            return "{ }"
        child_indent = indent + "  "
        fields = [key + " = " + nix_pin_literal(item, child_indent) + ";"
                  for key, item in value.items()]
        if len(fields) == 1 and "\n" not in fields[0]:
            return "{ " + fields[0] + " }"
        return "{\n" + "\n".join(child_indent + field for field in fields) + "\n" + indent + "}"
    if type(value) is list:
        items = [nix_pin_literal(item, indent + "  ") for item in value]
        if any("\n" in item for item in items):
            return "[\n" + "\n".join(indent + "  " + item for item in items) + "\n" + indent + "]"
        return "[ " + " ".join(items) + " ]" if items else "[ ]"
    return nix_literal(value)


def validate_pin(text):
    parsed = NixData(text)
    obj = parsed.data
    required = {"revision", "commitDate", "version", "cargoHash", "assets"}
    require(type(obj) is dict and required <= set(obj)
            and set(obj) <= required | {"sourceHash"}, "pin schema")
    require(hexstr(obj["revision"]) and valid_sri(obj["cargoHash"])
            and ("sourceHash" not in obj or valid_sri(obj["sourceHash"])), "pin source hashes")
    require(isinstance(obj["commitDate"], str) and re.fullmatch(
        r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z", obj["commitDate"])
        and isinstance(obj["version"], str) and re.fullmatch(
            r"\d{8}-\d{6}-[0-9a-f]{8}", obj["version"]), "pin version/date")
    require(type(obj["assets"]) is dict and set(obj["assets"]) == {"windows"}, "pin assets schema")
    windows = obj["assets"]["windows"]
    require(type(windows) is dict and set(windows) == set(WINDOWS_ARCHITECTURES),
            "Windows architecture pin schema")
    keys = {"status", "assetId", "url", "headers", "hash", "sha256", "size",
            "archiveRoot", "architecture"}
    optional_keys = {"sourceRevision", "buildRepository", "buildId", "releaseTag", "runId", "runAttempt"}
    statuses = set()
    for architecture in WINDOWS_ARCHITECTURES:
        asset = windows[architecture]
        if asset is None:
            require(architecture == "aarch64"
                    and windows["x86_64"]["status"] == "bootstrap-unpromoted",
                    "only bootstrap aarch64 pin may be absent")
            continue
        require(type(asset) is dict and keys <= set(asset)
                and set(asset) <= keys | optional_keys, architecture + " Windows pin schema")
        require(asset["status"] in ("bootstrap-unpromoted", "promoted")
                and positive(asset["assetId"]) and positive(asset["size"])
                and hexstr(asset["sha256"], 64) and asset["hash"] == sri(asset["sha256"])
                and asset["headers"] == {"Accept": "application/octet-stream"}
                and asset["architecture"] == architecture, architecture + " Windows pin data")
        expected_repo = SOURCE if asset["status"] == "bootstrap-unpromoted" else BUILDS
        require(asset["url"] == f"{API}/repos/{expected_repo}/releases/assets/{asset['assetId']}",
                architecture + " Windows pinned API URL")
        expected_root = (
            "WezTerm-windows-" if architecture == "x86_64"
            else "WezTerm-windows-aarch64-"
        )
        require(asset["archiveRoot"] == expected_root + obj["version"],
                architecture + " Windows archive root")
        if asset["status"] == "bootstrap-unpromoted":
            require(set(asset) == keys, "bootstrap Windows pin fields")
        else:
            require(set(asset) == keys | optional_keys
                    and asset["sourceRevision"] == obj["revision"]
                    and asset["buildRepository"] == BUILDS
                    and positive(asset["runId"]) and positive(asset["runAttempt"])
                    and asset["buildId"] == (
                        f"{obj['revision']}-{asset['runId']}-{asset['runAttempt']}")
                    and asset["releaseTag"] == "wezterm-" + asset["buildId"],
                    architecture + " promoted provenance")
        statuses.add(asset["status"])
    require((statuses == {"bootstrap-unpromoted"} and windows["aarch64"] is None) or (
        statuses == {"promoted"} and windows["aarch64"] is not None),
        "Windows pins must be bootstrap x86_64-only or dual promoted")
    if statuses == {"promoted"}:
        require(windows["x86_64"]["assetId"] != windows["aarch64"]["assetId"]
                and windows["x86_64"]["sha256"] != windows["aarch64"]["sha256"],
                "promoted architecture assets must be distinct")
    return parsed


def source_node(lock):
    nodes = lock["nodes"]
    root = nodes[lock["root"]]
    node_name = root["inputs"].get("wezterm-src")
    if node_name is None:
        return None
    require(isinstance(node_name, str) and node_name in nodes, "direct wezterm-src lock input")
    node = nodes[node_name]
    require(node.get("flake") is False and node.get("locked", {}).get("type") == "git"
            and node["locked"].get("url") == "https://github.com/wezterm/wezterm"
            and node["locked"].get("submodules") is True, "nonflake WezTerm source lock")
    require(hexstr(node["locked"].get("rev")) and valid_sri(node["locked"].get("narHash")),
            "locked source identity")
    return node_name


def validate_weekly_lock(old, new):
    require(type(new) is dict and set(new) == set(old)
            and new["root"] == old["root"] and new["version"] == old["version"], "lock schema/root")
    root = old["root"]
    require(new["nodes"][root] == old["nodes"][root], "weekly root input changes")
    name = source_node(old)
    require(source_node(new) == name and (
        name is None or old["nodes"][name] == new["nodes"][name]), "weekly changed WezTerm source")


def no_token():
    require(not any(os.environ.get(key) for key in (
        "GITHUB_TOKEN", "GH_TOKEN", "NIX_CONFIG", "NIX_USER_CONF_FILES")), "read-only clean environment required")


def command(args, cwd=None):
    no_token()
    env = os.environ.copy()
    for key in list(env):
        if key.startswith(("GIT_", "NIX_")) or key in ("GH_TOKEN", "GITHUB_TOKEN"):
            env.pop(key)
    env.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL="/dev/null",
               GIT_TERMINAL_PROMPT="0")
    return subprocess.run(args, cwd=cwd, env=env, text=True, capture_output=True, check=False)


def checked(args, cwd=None):
    result = command(args, cwd)
    require(result.returncode == 0, f"command failed: {args[0]}\n{result.stderr[-4000:]}")
    return result.stdout.strip()


def candidate_path(path, sha):
    candidate = Path(path).resolve()
    root = Path.cwd().resolve()
    require(candidate != root and root in candidate.parents, "candidate must be child of checkout")
    head = checked(["git", "-c", "core.hooksPath=/dev/null", "-C", str(candidate),
                    "rev-parse", "HEAD"])
    require(head == sha, "candidate head mismatch")
    return candidate


def read_candidate(candidate, path):
    target = candidate / path
    require(candidate in target.resolve().parents and not target.is_symlink()
            and target.is_file() and target.stat().st_size <= 4 * 1024 * 1024,
            "candidate regular file")
    return target.read_text()


def weekly(public, workdir):
    no_token()
    snap = snapshot(public, require_pr=False)
    require(snap["pr_number"] is not None or not snap["branch_exists"]
            or snap["head"] == snap["default_sha"],
            "retained branch without an open PR: owner must delete the stale automation branch")
    candidate = candidate_path(workdir, snap["head"])
    before = read_candidate(candidate, "flake.lock")
    pin_before = read_candidate(candidate, PIN)
    lock = parse(before)
    source_node(lock)
    root_inputs = lock["nodes"][lock["root"]]["inputs"]
    inputs = sorted(key for key in root_inputs if key != "wezterm-src")
    require(inputs and all(re.fullmatch(r"[A-Za-z][A-Za-z0-9_-]*", key) for key in inputs),
            "named root inputs")
    checked(["nix", "flake", "update", *inputs, "--option", "accept-flake-config", "false"], candidate)
    after = read_candidate(candidate, "flake.lock")
    validate_weekly_lock(lock, parse(after))
    require(read_candidate(candidate, PIN) == pin_before, "weekly changed pin")
    original_lock, _ = content(public, "flake.lock", snap["head"])
    require(original_lock.decode() == before, "candidate starting lock differs from branch")
    files = {"flake.lock": after}
    try:
        sha, _, _ = source_info(public)
        request = make_request(sha, os.environ.get("GITHUB_RUN_ID"))
        files[REQUEST] = canonical(request) + "\n"
    except (ValueError, KeyError, urllib.error.URLError) as exc:
        print("Upstream request unavailable; ordinary lock update continues:", exc, file=sys.stderr)
    require(snapshot(public, require_pr=False) == snap, "weekly branch raced")
    return dict(kind="weekly", snapshot=snap, files=files)


def discover_hashes(public, plan):
    no_token()
    sha = plan["request"]["source_sha"]
    prefetched = parse(checked([
        "nix", "flake", "prefetch", "--json",
        f"git+https://github.com/{SOURCE}?rev={sha}&submodules=1"]))
    source_hash = prefetched.get("hash")
    require(valid_sri(source_hash), "source prefetch hash")
    locked = prefetched.get("locked")
    require(type(locked) is dict, "source prefetch locked metadata")
    source_locked = dict(locked)
    if "narHash" in source_locked:
        require(source_locked["narHash"] == source_hash, "source prefetch hash identity")
    source_locked["narHash"] = source_hash
    validate_source_locked(source_locked, sha, source_hash, plan["commit_date"])
    raw, _ = content(public, "flake.lock", plan["snapshot"]["default_sha"])
    lock = parse(raw)
    pkgs_name = lock["nodes"][lock["root"]]["inputs"]["nixpkgs"]
    pkgs = lock["nodes"][pkgs_name]["locked"]
    require(pkgs.get("type") == "github" and pkgs.get("owner") == "NixOS"
            and pkgs.get("repo") == "nixpkgs" and hexstr(pkgs.get("rev"))
            and valid_sri(pkgs.get("narHash")), "trusted nixpkgs lock")
    # This fixed expression imports only the trusted default's package definitions.
    prefix = ("let pkgs = import (builtins.fetchTree " + nix_literal({
        "type": "github", "owner": "NixOS", "repo": "nixpkgs",
        "rev": pkgs["rev"], "narHash": pkgs["narHash"]}) + ").outPath "
        '{ system = "x86_64-linux"; }; src = builtins.fetchTree ' + nix_literal(source_locked)
        + "; in pkgs.rustPlatform.fetchCargoVendor { pname = \"wezterm\"; version = "
        + nix_literal(plan["version"]) + "; src = src.outPath; hash = ")

    def expression(hash_value):
        return prefix + nix_literal(hash_value) + "; }"

    # fetchCargoVendor wraps its FOD; only vendorStaging carries cargoHash.
    drv = checked(["nix", "eval", "--raw", "--expr",
                   "(" + expression(FAKE_HASH) + ").vendorStaging.drvPath"])
    require(re.fullmatch(r"/nix/store/[a-z0-9]{32}-[^/\n]+\.drv", drv), "known Cargo derivation")
    derivations = parse(checked(["nix", "derivation", "show", drv]))
    validate_fixed_derivation(derivations, drv)
    result = command(["nix", "build", "--no-link", "--print-build-logs", drv + "^out"])
    require(result.returncode != 0, "fake Cargo hash unexpectedly succeeded")
    pattern = (r"error: hash mismatch in fixed-output derivation '" + re.escape(drv)
               + r"':\s+specified:\s+" + re.escape(FAKE_HASH)
               + r"\s+got:\s+(sha256-[A-Za-z0-9+/]{43}=)(?:\s|$)")
    matches = re.findall(pattern, result.stderr)
    require(len(matches) == 1 and valid_sri(matches[0]), "exact Cargo mismatch proof missing")
    cargo_hash = matches[0]
    checked(["nix", "build", "--no-link", "--print-build-logs", "--expr", expression(cargo_hash)])
    return source_hash, cargo_hash, source_locked


def validate_fixed_derivation(metadata, drv):
    require(type(metadata) is dict, "Cargo derivation metadata")
    if "derivations" in metadata:
        require(set(metadata) == {"version", "derivations"}
                and type(metadata["version"]) is int and metadata["version"] == 4,
                "unsupported versioned derivation metadata")
        derivations = metadata["derivations"]
        key = Path(drv).name
        require(type(derivations) is dict and set(derivations) == {key},
                "exact Cargo derivation metadata")
        outputs = derivations[key]["outputs"]
        require(set(outputs) == {"out"} and outputs["out"].get("method") == "nar"
                and outputs["out"].get("hash") == FAKE_HASH,
                "expected fake fixed-output derivation")
    else:
        require(set(metadata) == {drv}, "exact Cargo derivation metadata")
        outputs = metadata[drv]["outputs"]
        require(set(outputs) == {"out"} and outputs["out"].get("hashAlgo") == "r:sha256"
                and outputs["out"].get("hash") == "0" * 64,
                "expected fake fixed-output derivation")


def validate_source_locked(locked, sha, source_hash, commit_date):
    required = {"type", "url", "submodules", "rev", "narHash", "lastModified"}
    require(type(locked) is dict and required <= set(locked)
            and set(locked) <= required | {"ref", "revCount"}, "source locked keys")
    require(hexstr(sha) and valid_sri(source_hash)
            and locked["type"] == "git"
            and locked["url"] == "https://github.com/wezterm/wezterm"
            and locked["submodules"] is True and locked["rev"] == sha
            and locked["narHash"] == source_hash, "source locked identity")
    require(isinstance(commit_date, str) and re.fullmatch(
        r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z", commit_date), "source commit date")
    stamp = int(dt.datetime.fromisoformat(commit_date.replace("Z", "+00:00")).timestamp())
    require(type(locked["lastModified"]) is int and locked["lastModified"] >= 0
            and locked["lastModified"] == stamp, "source locked timestamp")
    if "revCount" in locked:
        require(type(locked["revCount"]) is int and locked["revCount"] >= 0,
                "source locked revision count")
    if "ref" in locked:
        ref = locked["ref"]
        require(isinstance(ref, str) and len(ref) <= 255 and re.fullmatch(
            r"refs/heads/[A-Za-z0-9][A-Za-z0-9._/-]*", ref)
            and ".." not in ref and "//" not in ref
            and all(part and not part.startswith(".") and not part.endswith((".", ".lock"))
                    for part in ref.split("/")), "source locked ref")
    return locked


def promotion_files(api, plan, source_hash, cargo_hash, *, source_locked=None):
    require(valid_sri(source_hash) and valid_sri(cargo_hash), "promotion hashes")
    snap, manifest = plan["snapshot"], validate_manifest(plan["release"]["manifest"])
    require(manifest["source_sha"] == plan["request"]["source_sha"]
            and manifest["version"] == plan["version"], "promotion source identity")
    if source_locked is not None:
        validate_source_locked(source_locked, manifest["source_sha"], source_hash,
                               plan["commit_date"])
    trusted, _ = content(api, PIN, snap["default_sha"])
    trusted_pin = validate_pin(trusted.decode())
    raw, _ = content(api, PIN, snap["head"])
    pin = validate_pin(raw.decode())
    require(set(pin.data) == set(trusted_pin.data), "trusted pin schema changed")
    updates = {("revision",): manifest["source_sha"], ("commitDate",): plan["commit_date"],
               ("version",): plan["version"], ("cargoHash",): cargo_hash}
    if "sourceHash" in pin.data:
        updates[("sourceHash",)] = source_hash
    promoted = {}
    for architecture in WINDOWS_ARCHITECTURES:
        asset_id = plan["release"]["asset_ids"][architecture]
        require(positive(asset_id), architecture + " Windows asset ID")
        asset = manifest["assets"]["windows"][architecture]
        promoted[architecture] = {
            "status": "promoted", "assetId": asset_id,
            "url": f"{API}/repos/{BUILDS}/releases/assets/{asset_id}",
            "headers": {"Accept": "application/octet-stream"},
            "hash": sri(asset["sha256"]), "sha256": asset["sha256"], "size": asset["size"],
            "archiveRoot": asset["archive_root"], "architecture": architecture,
            "sourceRevision": manifest["source_sha"], "buildRepository": BUILDS,
            "buildId": manifest["build_id"], "releaseTag": "wezterm-" + manifest["build_id"],
            "runId": manifest["run_id"], "runAttempt": manifest["run_attempt"],
        }
    updates[("assets", "windows")] = promoted
    rewritten = pin.rewrite(updates)
    validate_pin(rewritten)
    files = {PIN: rewritten}
    lock_raw, _ = content(api, "flake.lock", snap["head"])
    lock = parse(lock_raw)
    node_name = source_node(lock)
    if node_name is not None:
        node = lock["nodes"][node_name]
        if source_locked is not None:
            node["locked"] = dict(source_locked)
        else:
            # Direct callers without prefetch proof must not inherit another revision's metadata.
            if node["locked"]["rev"] != manifest["source_sha"]:
                node["locked"].pop("revCount", None)
                node["locked"].pop("ref", None)
            node["locked"].update(rev=manifest["source_sha"], narHash=source_hash,
                                  lastModified=int(dt.datetime.fromisoformat(
                                      plan["commit_date"].replace("Z", "+00:00")).timestamp()))
        require(node.get("original", {}).get("type") == "git"
                and node["original"].get("url") == "https://github.com/wezterm/wezterm",
                "source original lock")
        node["original"] = dict(type="git", url="https://github.com/wezterm/wezterm",
                                rev=manifest["source_sha"], submodules=True)
        files["flake.lock"] = json.dumps(lock, indent=2) + "\n"
        flake_raw, _ = content(api, "flake.nix", snap["head"])
        text = flake_raw.decode()
        pattern = r'(url\s*=\s*"git\+https://github\.com/wezterm/wezterm\?rev=)[0-9a-f]{40}(&submodules=1"\s*;)'
        require(len(re.findall(pattern, text)) == 1, "single literal source flake URL")
        files["flake.nix"] = re.sub(pattern, lambda m: m[1] + manifest["source_sha"] + m[2], text)
    else:
        require("sourceHash" in pin.data, "sourceHash required without source lock")
    return files


def completed_promotion(own, plan):
    """Only an unchanged promoted tree with exact-head native proof is complete."""
    head = plan["snapshot"]["head"]
    require(hexstr(head), "completed promotion head")
    try:
        raw, _ = content(own, PIN, head)
        pin = validate_pin(raw.decode()).data
        lock_raw, _ = content(own, "flake.lock", head)
        lock = parse(lock_raw)
        node_name = source_node(lock)
        source_hash = (lock["nodes"][node_name]["locked"]["narHash"]
                       if node_name is not None else pin["sourceHash"])
        if source_hash == FAKE_HASH or pin["cargoHash"] == FAKE_HASH:
            return False
        source_locked = lock["nodes"][node_name]["locked"] if node_name is not None else None
        expected = promotion_files(own, plan, source_hash, pin["cargoHash"],
                                   source_locked=source_locked)
        if pin != validate_pin(expected[PIN]).data:
            return False
        for path, text in expected.items():
            if path == PIN:
                continue
            current, _ = content(own, path, head)
            if path == "flake.lock":
                if parse(current) != parse(text):
                    return False
            elif current.decode() != text:
                return False
    except (ValueError, KeyError, TypeError, IndexError):
        return False
    # GitHub returns newest first; do not let an older success override a retry.
    # Status objects need not contain a SHA: the authenticated route pins it.
    for row in own.pages(f"/repos/{REPO}/commits/{head}/statuses"):
        if row.get("context") == "wezterm/native-linux":
            return row.get("state") == "success" and row.get("sha", head) == head
    return False


def prepare(public, candidate, plan):
    no_token()
    recheck(public, public, plan)
    path = candidate_path(candidate, plan["snapshot"]["head"])
    for name in (PIN, "flake.lock", "flake.nix"):
        expected, _ = content(public, name, plan["snapshot"]["head"])
        require(read_candidate(path, name) == expected.decode(), "candidate data mismatch")
    source_hash, cargo_hash, source_locked = discover_hashes(public, plan)
    require(source_locked is not None, "source prefetch locked metadata")
    files = promotion_files(public, plan, source_hash, cargo_hash, source_locked=source_locked)
    proposal = dict(kind="promotion", snapshot=plan["snapshot"], source_hash=source_hash,
                    cargo_hash=cargo_hash, source_locked=source_locked, files=files)
    materialize(candidate, proposal)
    recheck(public, public, plan)
    return proposal


def validate_snapshot(snap):
    require(type(snap) is dict and set(snap) == {
        "default_branch", "default_sha", "head", "branch_exists", "pr_number"},
        "proposal snapshot")
    default = snap["default_branch"]
    require(isinstance(default, str) and re.fullmatch(r"[A-Za-z0-9._/-]+", default)
            and ".." not in default and "//" not in default
            and hexstr(snap["default_sha"]) and hexstr(snap["head"])
            and type(snap["branch_exists"]) is bool
            and (snap["pr_number"] is None or positive(snap["pr_number"]))
            and (snap["branch_exists"] or (
                snap["pr_number"] is None and snap["head"] == snap["default_sha"])),
            "proposal snapshot identity")


def materialize(candidate, proposal):
    """Rehydrate data only, from a trusted script, in the disposable check job."""
    no_token()
    require(type(proposal) is dict, "materialize proposal")
    kind = proposal.get("kind")
    if kind == "weekly":
        require(set(proposal) == {"kind", "snapshot", "files"}, "weekly proposal")
        allowed, required = {"flake.lock", REQUEST}, {"flake.lock"}
    else:
        require(kind == "promotion" and set(proposal) == {
            "kind", "snapshot", "source_hash", "cargo_hash", "source_locked", "files"}
            and valid_sri(proposal["source_hash"]) and valid_sri(proposal["cargo_hash"]),
            "promotion proposal")
        allowed, required = {PIN, "flake.lock", "flake.nix"}, {PIN}
    validate_snapshot(proposal["snapshot"])
    files = validate_write_files(proposal["files"])
    require(required <= set(files) <= allowed, "materialize files")
    if kind == "promotion":
        require(("flake.lock" in files) == ("flake.nix" in files), "promotion paired files")
        pin = validate_pin(files[PIN]).data
        validate_source_locked(proposal["source_locked"], pin["revision"],
                               proposal["source_hash"], pin["commitDate"])
        require(pin["cargoHash"] == proposal["cargo_hash"]
                and pin.get("sourceHash", proposal["source_hash"]) == proposal["source_hash"],
                "promotion pin hash identity")
    if "flake.lock" in files:
        lock = parse(files["flake.lock"])
        node_name = source_node(lock)
        if kind == "promotion":
            require(node_name is not None
                    and lock["nodes"][node_name]["locked"] == proposal["source_locked"],
                    "promotion source locked metadata")
    if REQUEST in files:
        validate_request(parse(files[REQUEST]))
    raw_path = Path(os.path.abspath(candidate))
    root = Path.cwd().resolve()
    require(raw_path != root and root in raw_path.parents, "candidate must be child of checkout")
    for parent in (raw_path, *raw_path.parents):
        require(not parent.is_symlink(), "candidate symlink")
        if parent == root:
            break
    path = candidate_path(candidate, proposal["snapshot"]["head"])
    # Preflight every target before writing any data; never follow candidate links.
    for name in files:
        target = path / name
        for parent in (target, *target.parents):
            require(not parent.is_symlink(), "candidate symlink")
            if parent == path:
                break
        require(not target.exists() or (
            target.is_file() and target.stat().st_nlink == 1), "candidate regular file")
        require(all(not parent.exists() or parent.is_dir()
                    for parent in target.parents if parent != path and path in parent.parents),
                "candidate directory")
    for name, text in files.items():
        target = path / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(text.encode("utf-8"))


def write_commit(own, snap, files, message, before_ref=None):
    validate_snapshot(snap)
    variables = commit_variables(snap["head"], files, message)
    require(snapshot(own, require_pr=False) == snap, "branch changed before commit")
    expected = snap
    if not snap["branch_exists"]:
        # POST fails atomically if another writer created this ref. Never adopt it.
        own.call("POST", "/git/refs", {"ref": "refs/heads/" + BRANCH, "sha": snap["default_sha"]})
        expected = dict(snap, branch_exists=True)
    require(snapshot(own, require_pr=False) == expected, "branch changed before ref update")
    if before_ref is not None:
        before_ref()
    head = own.graphql(CREATE_COMMIT_QUERY, variables)
    require(hexstr(head), "created commit SHA")
    require(branch_ref(own, BRANCH) == head, "published ref differs")
    return head


def publish_weekly(own, public, proposal):
    require(type(proposal) is dict and set(proposal) == {"kind", "snapshot", "files"}
            and proposal["kind"] == "weekly", "weekly proposal")
    snap, files = proposal["snapshot"], proposal["files"]
    require(type(files) is dict and "flake.lock" in files
            and set(files) <= {"flake.lock", REQUEST}, "weekly files")
    require(snapshot(own, require_pr=False) == snap, "weekly stale snapshot")
    require(snap["pr_number"] is not None or not snap["branch_exists"]
            or snap["head"] == snap["default_sha"], "retained branch without an open PR")
    old, _ = content(own, "flake.lock", snap["head"])
    validate_weekly_lock(parse(old), parse(files["flake.lock"]))
    if REQUEST in files:
        request = validate_request(parse(files[REQUEST]))
        try:
            source_info(public, request["source_sha"])
        except (ValueError, KeyError, urllib.error.URLError) as exc:
            print("Skipping unavailable/invalid request; ordinary lock update continues:",
                  exc, file=sys.stderr)
            files = {name: text for name, text in files.items() if name != REQUEST}
    changed = {}
    for name, text in files.items():
        old, _ = content(own, name, snap["head"], missing=True)
        if old is None or old.decode() != text:
            changed[name] = text
    if not changed:
        return snap["head"]
    head = write_commit(own, snap, changed, "flake.lock: weekly input bump and WezTerm request")
    if snap["pr_number"] is None:
        current = snapshot(own, require_pr=False)
        require(current["head"] == head and current["default_sha"] == snap["default_sha"]
                and current["default_branch"] == snap["default_branch"], "PR creation raced")
        if current["pr_number"] is None:
            own.call("POST", "/pulls", {
                "title": "flake.lock: weekly input bump", "head": BRANCH, "base": snap["default_branch"],
                "body": "Weekly named input update; WezTerm remains pinned until a verified Windows release "
                        "and native Linux pure flake check succeed. Review the exact-head status."})
        current = snapshot(own)
        require(current is not None and current["head"] == head
                and current["default_sha"] == snap["default_sha"], "published PR state raced")
    return head


def publish(own, public, plan, proposal):
    require(type(proposal) is dict and set(proposal) == {
        "kind", "snapshot", "source_hash", "cargo_hash", "source_locked", "files"}
        and proposal["kind"] == "promotion" and proposal["snapshot"] == plan["snapshot"],
        "promotion proposal")
    recheck(own, public, plan)
    release = public.get(f"/repos/{BUILDS}/releases/{plan['release']['release_id']}")
    verified = validate_release(public, release, plan["request"]["source_sha"], plan["version"])
    require(verified == plan["release"], "release changed")
    validate_source_locked(proposal["source_locked"], plan["request"]["source_sha"],
                           proposal["source_hash"], plan["commit_date"])
    expected = promotion_files(own, plan, proposal["source_hash"], proposal["cargo_hash"],
                               source_locked=proposal["source_locked"])
    require(expected == proposal["files"], "tampered/non-atomic promotion")
    recheck(own, public, plan)
    changed = {}
    for name, text in expected.items():
        raw, _ = content(own, name, plan["snapshot"]["head"])
        if raw.decode() != text:
            changed[name] = text
    if not changed:
        return plan["snapshot"]["head"]
    # One CAS commit includes every changed Unix/Windows field; untouched data stays put.
    return write_commit(own, plan["snapshot"], changed,
                        "wezterm: promote verified source and immutable Windows build",
                        before_ref=lambda: recheck(own, public, plan))


def status(own, head, state, description, url):
    require(hexstr(head) and state in ("pending", "success", "failure"), "status identity/state")
    require(isinstance(description, str) and 0 < len(description) <= 140
            and not re.search(r"[\r\n\x00]", description), "status description")
    require(isinstance(url, str) and re.fullmatch(
        r"https://github\.com/dc0d32/nixos/actions/runs/[1-9][0-9]*(?:/attempts/[1-9][0-9]*)?",
        url), "own Actions status URL")
    own.call("POST", "/statuses/" + head, {
        "state": state, "context": "wezterm/native-linux", "description": description,
        "target_url": url})


def output(path, **values):
    lines = []
    for key, value in values.items():
        text = str(value).lower() if type(value) is bool else str(value)
        require(re.fullmatch(r"[a-z_]+", key) and "\n" not in text and "\r" not in text,
                "output line injection")
        lines.append(f"{key}={text}\n")
    if path:
        target = Path(path)
        require(not target.is_symlink(), "output symlink")
        with target.open("a") as stream:
            stream.writelines(lines)
    else:
        sys.stdout.write("".join(lines))


def verify_runtime(default_sha):
    """Defense in depth for writer jobs: only unchanged trusted control files."""
    require(hexstr(default_sha), "trusted runtime SHA")
    root = Path(__file__).absolute().parents[1]
    require(root == root.resolve(), "runtime checkout symlink")
    env = {key: value for key, value in os.environ.items()
           if not key.startswith(("GIT_", "NIX_")) and key not in ("GH_TOKEN", "GITHUB_TOKEN")}
    env.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL="/dev/null", GIT_TERMINAL_PROMPT="0")
    for name in ("scripts/wezterm_pipeline.py", "scripts/wezterm-request.py",
                 "scripts/promote-wezterm.py"):
        path = root / name
        require(path.resolve() == path and path.is_file()
                and not path.stat().st_mode & 0o022, "unsafe runtime script permissions")
        result = subprocess.run(
            ["git", "-c", "core.hooksPath=/dev/null", "--no-pager", "-C", str(root),
             "show", default_sha + ":" + name],
            env=env, capture_output=True, check=False)
        require(result.returncode == 0 and result.stdout == path.read_bytes(),
                "runtime scripts differ from trusted default")


def main(request_only=False):
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    names = ("weekly",) if request_only else (
        "seed", "inspect", "prepare", "materialize", "publish-weekly", "publish", "status")
    for name in names:
        cmd = sub.add_parser(name)
        cmd.add_argument("--output", default=os.environ.get("GITHUB_OUTPUT"))
        if name == "weekly":
            cmd.add_argument("--workdir", required=True)
        if name in ("prepare", "materialize"):
            cmd.add_argument("--candidate", required=True)
        if name in ("prepare", "publish"):
            cmd.add_argument("--plan-b64", required=True)
        if name in ("materialize", "publish-weekly", "publish"):
            cmd.add_argument("--proposal-b64", required=True)
        if name == "status":
            for flag in ("head", "state", "description", "url"):
                cmd.add_argument("--" + flag, required=True)
    args = parser.parse_args()
    public = PublicAPI()
    own = None
    if args.command in ("seed", "inspect", "publish-weekly", "publish", "status"):
        require(os.environ.get("GITHUB_REPOSITORY") == REPO, "fixed coordinator repository")
        own = OwnAPI(os.environ.get("GITHUB_TOKEN"))
        default = own.get("/repos/" + REPO)["default_branch"]
        require(os.environ.get("GITHUB_EVENT_NAME") in ("schedule", "workflow_dispatch")
                and os.environ.get("GITHUB_REF") == "refs/heads/" + default,
                "trusted default-branch workflow only")
        verify_runtime(branch_ref(own, default))
    if args.command == "weekly":
        proposal = weekly(public, args.workdir)
        output(args.output, proposal=encode(proposal), head=proposal["snapshot"]["head"],
               default_sha=proposal["snapshot"]["default_sha"])
    elif args.command == "seed":
        snap = snapshot(own, require_pr=False)
        validate_snapshot(snap)
        verify_runtime(snap["default_sha"])
        output(args.output, head=snap["head"], default_sha=snap["default_sha"])
    elif args.command == "inspect":
        plan = inspect(own, public)
        if plan is None:
            output(args.output, eligible=False, head="", request="", default_sha="", plan="")
        else:
            output(args.output, eligible=True, head=plan["snapshot"]["head"],
                   request=encode(plan["request"]), default_sha=plan["snapshot"]["default_sha"],
                   plan=encode(plan))
    elif args.command == "prepare":
        proposal = prepare(public, args.candidate, decode(args.plan_b64))
        output(args.output, proposal=encode(proposal))
    elif args.command == "materialize":
        materialize(args.candidate, decode(args.proposal_b64))
    elif args.command == "publish-weekly":
        head = publish_weekly(own, public, decode(args.proposal_b64))
        output(args.output, head=head)
    elif args.command == "publish":
        head = publish(own, public, decode(args.plan_b64), decode(args.proposal_b64))
        output(args.output, head=head)
    else:
        status(own, args.head, args.state, args.description, args.url)


def cli(request_only=False):
    try:
        main(request_only)
    except (ValueError, KeyError, IndexError, OSError, zipfile.BadZipFile, zlib.error, EOFError) as exc:
        print("WezTerm pipeline rejected operation:", exc, file=sys.stderr)
        sys.exit(1)
