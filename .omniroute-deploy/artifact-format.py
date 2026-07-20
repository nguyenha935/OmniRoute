#!/usr/bin/env python3
"""Fail-closed request and signed runtime-overlay artifact handling for OmniRoute."""

from __future__ import annotations

import argparse
import gzip
import hashlib
import io
import json
import os
import platform
import posixpath
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
from pathlib import Path, PurePosixPath
from typing import Any, Iterable

SCHEMA_VERSION = 1
ARTIFACT_SCHEMA_VERSION = 2
REPOSITORY = "diegosouzapw/OmniRoute"
ARTIFACT_TYPE = "omniroute-runtime-overlay"
REQUEST_TYPE = "omniroute-build-request"
DEFAULT_BUILDER_REPOSITORY = "nguyenha935/OmniRoute"
DEFAULT_BUILDER_WORKFLOW = ".github/workflows/omniroute-patch-artifact.yml"
MAX_OUTER_BYTES = 8 * 1024 * 1024 * 1024
MAX_PAYLOAD_BYTES = 12 * 1024 * 1024 * 1024
MAX_FILE_BYTES = 4 * 1024 * 1024 * 1024
MAX_ENTRIES = 100_000

REPLACE_ROOTS = (
    "dist",
    "bin",
    "@omniroute",
    "open-sse",
    "src/domain",
    "src/lib",
    "src/models",
    "src/mitm",
    "src/server",
    "src/shared",
    "src/sse",
    "src/types",
)
SINGLETONS = (
    ".env.example",
    "README.md",
    "LICENSE",
    "package.json",
    "scripts/build/postinstall.mjs",
    "scripts/build/postinstallSupport.mjs",
    "scripts/build/runtime-env.mjs",
    "scripts/build/colocateOptionals.mjs",
    "scripts/build/sync-env.mjs",
    "scripts/build/native-binary-compat.mjs",
    "scripts/build/build-next-isolated.mjs",
    "scripts/postinstall.mjs",
    "scripts/dev/responses-ws-proxy.mjs",
    "scripts/dev/tls-options.mjs",
    "scripts/dev/sync-env.mjs",
    "scripts/check/check-supported-node-runtime.ts",
)
EXCLUDED_PARTS = ("__tests__",)
EXCLUDED_SUFFIXES = (".test.ts", ".test.tsx", ".test.js", ".test.mjs", ".spec.ts", ".spec.tsx")


class ArtifactError(RuntimeError):
    pass


def canonical_json(value: Any) -> bytes:
    return (json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False) + "\n").encode()


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def read_json(path: Path, *, require_canonical: bool = False) -> tuple[Any, bytes]:
    raw = path.read_bytes()
    try:
        value = json.loads(raw)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ArtifactError(f"invalid JSON in {path.name}: {error}") from error
    if require_canonical and raw != canonical_json(value):
        raise ArtifactError(f"{path.name} is not canonical JSON")
    return value, raw


def require_hash(value: Any, name: str, length: int = 64) -> str:
    if not isinstance(value, str) or len(value) != length or any(c not in "0123456789abcdef" for c in value):
        raise ArtifactError(f"{name} must be a lowercase {length}-character hex digest")
    return value


def require_string(value: Any, name: str) -> str:
    if not isinstance(value, str) or not value or "\x00" in value:
        raise ArtifactError(f"{name} must be a non-empty string")
    return value


def require_positive_integer(value: Any, name: str) -> int:
    if not isinstance(value, int) or isinstance(value, bool) or value < 1:
        raise ArtifactError(f"{name} must be a positive integer")
    return value


def policy_document() -> dict[str, Any]:
    return {
        "schemaVersion": SCHEMA_VERSION,
        "artifactType": ARTIFACT_TYPE,
        "replaceRoots": list(REPLACE_ROOTS),
        "singletons": list(SINGLETONS),
        "excludedParts": list(EXCLUDED_PARTS),
        "excludedSuffixes": list(EXCLUDED_SUFFIXES),
    }


def policy_hash() -> str:
    return sha256_bytes(canonical_json(policy_document()))


def runtime_fingerprint(npm_version: str) -> dict[str, str]:
    report = json.loads(subprocess.check_output(["node", "-p", "JSON.stringify(process.report.getReport().header)"], text=True))
    versions = json.loads(subprocess.check_output(["node", "-p", "JSON.stringify(process.versions)"], text=True))
    os_release: dict[str, str] = {}
    try:
        for line in Path("/etc/os-release").read_text().splitlines():
            if "=" in line:
                key, value = line.split("=", 1)
                os_release[key] = value.strip().strip('"')
    except OSError:
        pass
    return {
        "node": subprocess.check_output(["node", "--version"], text=True).strip().removeprefix("v"),
        "npm": npm_version,
        "modulesAbi": str(versions.get("modules", "")),
        "platform": sys.platform if sys.platform != "linux" else "linux",
        "arch": "x64" if platform.machine() in ("x86_64", "amd64") else platform.machine(),
        "osId": os_release.get("ID", "unknown"),
        "osVersion": os_release.get("VERSION_ID", "unknown"),
        "libc": "glibc",
        "libcVersion": str(report.get("glibcVersionRuntime", "unknown")),
    }


def safe_name(name: str) -> str:
    if not name or "\x00" in name or "\\" in name:
        raise ArtifactError("archive contains an empty, NUL, or backslash path")
    if name.startswith("/"):
        raise ArtifactError(f"absolute archive path rejected: {name}")
    pure = PurePosixPath(name)
    if any(part in ("", ".", "..") for part in pure.parts):
        raise ArtifactError(f"non-canonical archive path rejected: {name}")
    normalized = posixpath.normpath(name)
    if normalized != name or normalized.startswith("../"):
        raise ArtifactError(f"path traversal rejected: {name}")
    return normalized


def validate_member(member: tarfile.TarInfo, *, allow_dirs: bool = True) -> str:
    name = safe_name(member.name)
    if member.pax_headers:
        raise ArtifactError(f"PAX metadata rejected: {name}")
    if member.issym() or member.islnk():
        raise ArtifactError(f"links rejected: {name}")
    if member.isdev() or member.isfifo() or not (member.isfile() or (allow_dirs and member.isdir())):
        raise ArtifactError(f"non-regular archive member rejected: {name}")
    if member.size < 0 or member.size > MAX_FILE_BYTES:
        raise ArtifactError(f"file size rejected: {name}")
    if member.mode & (stat.S_ISUID | stat.S_ISGID | stat.S_IWOTH):
        raise ArtifactError(f"unsafe mode rejected: {name}")
    return name


def inspected_members(archive: Path, *, max_bytes: int, allow_dirs: bool = True) -> tuple[tarfile.TarFile, list[tuple[tarfile.TarInfo, str]]]:
    if not archive.is_file() or archive.stat().st_size > max_bytes:
        raise ArtifactError(f"archive missing or exceeds size limit: {archive}")
    try:
        opened = tarfile.open(archive, "r:*")
    except (tarfile.TarError, OSError) as error:
        raise ArtifactError(f"invalid archive: {error}") from error
    result: list[tuple[tarfile.TarInfo, str]] = []
    names: set[str] = set()
    folded: set[str] = set()
    total = 0
    try:
        for member in opened:
            if len(result) >= MAX_ENTRIES:
                raise ArtifactError("archive entry limit exceeded")
            name = validate_member(member, allow_dirs=allow_dirs)
            folded_name = name.casefold()
            if name in names or folded_name in folded:
                raise ArtifactError(f"duplicate or case-colliding archive path: {name}")
            names.add(name)
            folded.add(folded_name)
            if member.isfile():
                total += member.size
                if total > max_bytes:
                    raise ArtifactError("archive unpacked-size limit exceeded")
            result.append((member, name))
    except Exception:
        opened.close()
        raise
    return opened, result


def extract_checked(archive: Path, destination: Path, *, max_bytes: int, allowed: Any | None = None) -> list[str]:
    if destination.exists() and any(destination.iterdir()):
        raise ArtifactError(f"extraction destination is not empty: {destination}")
    destination.mkdir(parents=True, exist_ok=True)
    opened, members = inspected_members(archive, max_bytes=max_bytes)
    extracted: list[str] = []
    try:
        for member, name in members:
            if allowed is not None and not allowed(name, member):
                raise ArtifactError(f"unexpected archive path: {name}")
            target = destination.joinpath(*PurePosixPath(name).parts)
            if member.isdir():
                target.mkdir(parents=True, exist_ok=True)
                os.chmod(target, 0o755)
                continue
            target.parent.mkdir(parents=True, exist_ok=True)
            source = opened.extractfile(member)
            if source is None:
                raise ArtifactError(f"could not read archive member: {name}")
            try:
                descriptor = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), member.mode & 0o777)
            except OSError as error:
                raise ArtifactError(f"could not safely create {name}: {error}") from error
            with os.fdopen(descriptor, "wb") as output:
                shutil.copyfileobj(source, output, length=1024 * 1024)
            os.chmod(target, member.mode & 0o777)
            extracted.append(name)
    finally:
        opened.close()
    return extracted


def deterministic_tar(output: Path, entries: Iterable[tuple[str, Path | bytes, int]], *, compress: bool = True) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = output.with_name(f".{output.name}.tmp-{os.getpid()}")
    with temporary.open("wb") as raw:
        stream: Any = gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0) if compress else raw
        try:
            with tarfile.open(fileobj=stream, mode="w", format=tarfile.USTAR_FORMAT) as archive:
                for name, source, mode in sorted(entries, key=lambda item: item[0]):
                    safe_name(name)
                    data = source if isinstance(source, bytes) else source.read_bytes()
                    info = tarfile.TarInfo(name)
                    info.size = len(data)
                    info.mode = mode
                    info.uid = info.gid = 0
                    info.uname = info.gname = ""
                    info.mtime = 0
                    archive.addfile(info, io.BytesIO(data))
        finally:
            if compress:
                stream.close()
    os.replace(temporary, output)


def request_allowed(name: str, member: tarfile.TarInfo) -> bool:
    return member.isfile() and (name in ("request.json", "request-files.json") or (name.startswith("patches/") and name.endswith(".patch") and name.count("/") == 1))


def validate_request(request: dict[str, Any], request_files: dict[str, Any], root: Path) -> None:
    if request.get("schemaVersion") != SCHEMA_VERSION or request.get("requestType") != REQUEST_TYPE:
        raise ArtifactError("unsupported build request schema/type")
    if request.get("repository") != REPOSITORY:
        raise ArtifactError("request repository is not allowed")
    require_string(request.get("targetRef"), "targetRef")
    require_hash(request.get("targetCommit"), "targetCommit", 40)
    require_string(request.get("version"), "version")
    require_string(request.get("buildSha"), "buildSha")
    require_string(request.get("createdAt"), "createdAt")
    patch_set = request.get("patchSetHash")
    if patch_set != "none":
        require_hash(patch_set, "patchSetHash")
    if request.get("overlayPolicyHash") != policy_hash():
        raise ArtifactError("request overlay policy does not match builder policy")
    patches = request.get("patches")
    if not isinstance(patches, list):
        raise ArtifactError("request patches must be an array")
    files = request_files.get("files") if isinstance(request_files, dict) else None
    if not isinstance(files, list):
        raise ArtifactError("request-files.json must contain files[]")
    expected_paths = {"request.json"}
    payload_lines: list[str] = []
    for index, patch in enumerate(patches):
        if not isinstance(patch, dict):
            raise ArtifactError("invalid patch entry")
        branch = require_string(patch.get("branch"), f"patches[{index}].branch")
        commit = require_hash(patch.get("commit"), f"patches[{index}].commit", 40)
        require_hash(patch.get("baseCommit"), f"patches[{index}].baseCommit", 40)
        patch_hash = require_hash(patch.get("sha256"), f"patches[{index}].sha256")
        filename = safe_name(require_string(patch.get("file"), f"patches[{index}].file"))
        if not filename.startswith("patches/") or filename.count("/") != 1 or not filename.endswith(".patch"):
            raise ArtifactError(f"invalid patch filename: {filename}")
        expected_paths.add(filename)
        if sha256_file(root / filename) != patch_hash:
            raise ArtifactError(f"patch checksum mismatch: {filename}")
        payload_lines.append(f"{branch}:{commit}:{patch_hash}\n")
    recomputed = sha256_bytes("".join(payload_lines).encode()) if patches else "none"
    if recomputed != patch_set:
        raise ArtifactError("patch-set hash does not match the ordered request patches")
    indexed_paths: set[str] = set()
    for entry in files:
        if not isinstance(entry, dict):
            raise ArtifactError("invalid request file index")
        name = safe_name(require_string(entry.get("path"), "request file path"))
        digest = require_hash(entry.get("sha256"), f"request file {name} sha256")
        if name in indexed_paths or name not in expected_paths:
            raise ArtifactError(f"unexpected or duplicate request file index: {name}")
        indexed_paths.add(name)
        if sha256_file(root / name) != digest:
            raise ArtifactError(f"request file checksum mismatch: {name}")
    if indexed_paths != expected_paths:
        raise ArtifactError("request file index is incomplete")


def allowed_overlay(name: str, member: tarfile.TarInfo) -> bool:
    if name == "payload-files.json":
        return member.isfile()
    if name == ".env" or name.startswith("node_modules/") or "/.git/" in f"/{name}/":
        return False
    if any(part in EXCLUDED_PARTS for part in PurePosixPath(name).parts):
        return False
    if name.endswith(EXCLUDED_SUFFIXES):
        return False
    if name in SINGLETONS:
        return member.isfile()
    return any(name == root or name.startswith(root + "/") for root in REPLACE_ROOTS)


def verify_file_index(root: Path) -> dict[str, Any]:
    index, raw = read_json(root / "payload-files.json", require_canonical=True)
    files = index.get("files") if isinstance(index, dict) else None
    if not isinstance(files, list):
        raise ArtifactError("payload-files.json must contain files[]")
    expected: dict[str, dict[str, Any]] = {}
    for entry in files:
        if not isinstance(entry, dict):
            raise ArtifactError("invalid payload file index entry")
        name = safe_name(require_string(entry.get("path"), "payload file path"))
        if name == "payload-files.json" or name in expected:
            raise ArtifactError(f"duplicate or reserved payload index path: {name}")
        expected[name] = entry
    actual: set[str] = set()
    for path in root.rglob("*"):
        if path.is_dir():
            continue
        if path.is_symlink() or not path.is_file():
            raise ArtifactError(f"unsafe extracted filesystem entry: {path}")
        name = path.relative_to(root).as_posix()
        if name == "payload-files.json":
            continue
        actual.add(name)
        entry = expected.get(name)
        if entry is None:
            raise ArtifactError(f"payload contains an unindexed file: {name}")
        if path.stat().st_size != entry.get("size") or sha256_file(path) != entry.get("sha256"):
            raise ArtifactError(f"payload file does not match index: {name}")
        if stat.S_IMODE(path.stat().st_mode) != entry.get("mode"):
            raise ArtifactError(f"payload file mode does not match index: {name}")
    if actual != set(expected):
        raise ArtifactError("payload file index references missing files")
    return {"index": index, "raw": raw, "count": len(actual), "bytes": sum((root / name).stat().st_size for name in actual)}


def dependency_fingerprint(package_path: Path) -> dict[str, Any]:
    package, _ = read_json(package_path)
    return {
        "dependencies": package.get("dependencies", {}),
        "optionalDependencies": package.get("optionalDependencies", {}),
        "engines": package.get("engines", {}),
    }


def verify_manifest_shape(manifest: dict[str, Any]) -> None:
    if manifest.get("schemaVersion") != ARTIFACT_SCHEMA_VERSION or manifest.get("artifactType") != ARTIFACT_TYPE:
        raise ArtifactError("unsupported artifact schema/type")
    if manifest.get("repository") != REPOSITORY:
        raise ArtifactError("artifact repository is not allowed")
    require_hash(manifest.get("requestSha256"), "requestSha256")
    require_string(manifest.get("targetRef"), "targetRef")
    require_hash(manifest.get("targetCommit"), "targetCommit", 40)
    require_string(manifest.get("version"), "version")
    require_string(manifest.get("buildSha"), "buildSha")
    require_string(manifest.get("createdAt"), "createdAt")
    patch_set = manifest.get("patchSetHash")
    if patch_set != "none":
        require_hash(patch_set, "patchSetHash")
    require_hash(manifest.get("payloadSha256"), "payloadSha256")
    require_hash(manifest.get("fileIndexSha256"), "fileIndexSha256")
    if manifest.get("overlayPolicyHash") != policy_hash():
        raise ArtifactError("artifact overlay policy mismatch")
    if manifest.get("buildBundler") != "turbopack":
        raise ArtifactError("artifact was not built with Turbopack")
    builder = manifest.get("builder")
    if not isinstance(builder, dict):
        raise ArtifactError("artifact builder provenance is missing")
    require_string(builder.get("repository"), "builder.repository")
    require_string(builder.get("workflow"), "builder.workflow")
    require_string(builder.get("ref"), "builder.ref")
    require_hash(builder.get("sourceDigest"), "builder.sourceDigest", 40)
    require_positive_integer(builder.get("runId"), "builder.runId")
    require_positive_integer(builder.get("runAttempt"), "builder.runAttempt")
    if builder.get("runnerEnvironment") != "github-hosted":
        raise ArtifactError("artifact was not built on a GitHub-hosted runner")


def extract_outer(response: Path, destination: Path) -> None:
    expected = {"artifact-manifest.json", "payload.tar.gz"}
    names = extract_checked(response, destination, max_bytes=MAX_OUTER_BYTES, allowed=lambda name, member: member.isfile() and name in expected)
    if set(names) != expected:
        raise ArtifactError("response archive must contain exactly manifest and payload")


def verify_builder_expectations(manifest: dict[str, Any], args: argparse.Namespace) -> None:
    expected = {
        "repository": args.expect_builder_repository,
        "workflow": args.expect_workflow,
        "ref": args.expect_source_ref,
        "sourceDigest": args.expect_source_digest,
        "runId": args.expect_run_id,
        "runAttempt": args.expect_run_attempt,
        "runnerEnvironment": "github-hosted",
    }
    builder = manifest.get("builder")
    for key, value in expected.items():
        if builder.get(key) != value:
            raise ArtifactError(f"artifact builder {key} mismatch")


def command_fingerprint(args: argparse.Namespace) -> None:
    print(canonical_json(runtime_fingerprint(args.npm_version)).decode(), end="")


def command_policy(_: argparse.Namespace) -> None:
    print(canonical_json({**policy_document(), "policyHash": policy_hash()}).decode(), end="")


def command_canonicalize(args: argparse.Namespace) -> None:
    value, _ = read_json(Path(args.input))
    Path(args.output).write_bytes(canonical_json(value))


def command_pack_request(args: argparse.Namespace) -> None:
    root = Path(args.directory).resolve()
    request, _ = read_json(root / "request.json", require_canonical=True)
    request_files, _ = read_json(root / "request-files.json", require_canonical=True)
    validate_request(request, request_files, root)
    entries: list[tuple[str, Path | bytes, int]] = [("request.json", root / "request.json", 0o600), ("request-files.json", root / "request-files.json", 0o600)]
    for patch in request["patches"]:
        entries.append((patch["file"], root / patch["file"], 0o600))
    deterministic_tar(Path(args.output), entries)


def command_extract_request(args: argparse.Namespace) -> None:
    destination = Path(args.destination)
    names = extract_checked(Path(args.archive), destination, max_bytes=MAX_OUTER_BYTES, allowed=request_allowed)
    if "request.json" not in names or "request-files.json" not in names:
        raise ArtifactError("request archive is incomplete")
    request, _ = read_json(destination / "request.json", require_canonical=True)
    request_files, _ = read_json(destination / "request-files.json", require_canonical=True)
    validate_request(request, request_files, destination)
    print(sha256_file(destination / "request.json"))


def iter_overlay_files(root: Path) -> list[tuple[str, Path, int]]:
    result: list[tuple[str, Path, int]] = []
    candidates = [root / path for path in REPLACE_ROOTS] + [root / path for path in SINGLETONS]
    seen: set[str] = set()
    for candidate in candidates:
        if not candidate.exists():
            continue
        paths = [candidate] if candidate.is_file() else sorted(candidate.rglob("*"))
        for path in paths:
            if path.is_dir():
                continue
            if path.is_symlink() or not path.is_file():
                raise ArtifactError(f"overlay source contains a link or special file: {path}")
            name = path.relative_to(root).as_posix()
            if name in seen or not allowed_overlay(name, tarfile.TarInfo(name)):
                continue
            seen.add(name)
            mode = 0o755 if path.stat().st_mode & 0o111 else 0o644
            result.append((name, path, mode))
    required = {"dist/server.js", "dist/BUILD_SHA", "bin/omniroute.mjs", "package.json"}
    if not required.issubset(seen):
        raise ArtifactError(f"overlay source is missing required files: {sorted(required - seen)}")
    return sorted(result)


def command_create_payload(args: argparse.Namespace) -> None:
    root = Path(args.source).resolve()
    files = iter_overlay_files(root)
    index_entries = []
    archive_entries: list[tuple[str, Path | bytes, int]] = []
    for name, path, mode in files:
        size = path.stat().st_size
        if size > MAX_FILE_BYTES:
            raise ArtifactError(f"overlay file exceeds limit: {name}")
        index_entries.append({"path": name, "mode": mode, "size": size, "sha256": sha256_file(path)})
        archive_entries.append((name, path, mode))
    index_raw = canonical_json({"schemaVersion": SCHEMA_VERSION, "files": index_entries})
    archive_entries.append(("payload-files.json", index_raw, 0o644))
    deterministic_tar(Path(args.output), archive_entries)
    Path(args.index_output).write_bytes(index_raw)


def command_create_response(args: argparse.Namespace) -> None:
    deterministic_tar(
        Path(args.output),
        [
            ("artifact-manifest.json", Path(args.manifest), 0o644),
            ("payload.tar.gz", Path(args.payload), 0o644),
        ],
    )


def command_artifact_id(args: argparse.Namespace) -> None:
    response = Path(args.archive).resolve()
    request, request_raw = read_json(Path(args.request).resolve(), require_canonical=True)
    with tempfile.TemporaryDirectory(prefix="omniroute-inspect-") as temporary:
        outer = Path(temporary)
        extract_outer(response, outer)
        manifest_path = outer / "artifact-manifest.json"
        manifest, manifest_raw = read_json(manifest_path, require_canonical=True)
        verify_manifest_shape(manifest)
        if manifest.get("requestSha256") != sha256_bytes(request_raw):
            raise ArtifactError("artifact request hash does not match local request")
        if manifest.get("patches") != request.get("patches"):
            raise ArtifactError("artifact ordered patch identity does not match request")
        if sha256_file(outer / "payload.tar.gz") != manifest.get("payloadSha256"):
            raise ArtifactError("payload checksum mismatch")
        print(canonical_json({"artifactId": sha256_file(response), "manifestSha256": sha256_bytes(manifest_raw), "manifest": manifest}).decode(), end="")


def command_verify_response(args: argparse.Namespace) -> None:
    response = Path(args.archive).resolve()
    destination = Path(args.destination).resolve()
    request_path = Path(args.request).resolve()
    request, request_raw = read_json(request_path, require_canonical=True)
    artifact_id = sha256_file(response)
    if artifact_id != args.expect_artifact:
        raise ArtifactError(f"artifact pin mismatch: expected {args.expect_artifact}, got {artifact_id}")
    with tempfile.TemporaryDirectory(prefix="omniroute-outer-") as temporary:
        outer = Path(temporary)
        extract_outer(response, outer)
        manifest_path = outer / "artifact-manifest.json"
        manifest, manifest_raw = read_json(manifest_path, require_canonical=True)
        verify_manifest_shape(manifest)
        verify_builder_expectations(manifest, args)
        manifest_sha = sha256_bytes(manifest_raw)
        if manifest_sha != args.expect_manifest:
            raise ArtifactError(f"manifest pin mismatch: expected {args.expect_manifest}, got {manifest_sha}")
        expected = {
            "requestSha256": sha256_bytes(request_raw),
            "targetRef": args.expect_target_ref,
            "targetCommit": args.expect_target,
            "patchSetHash": args.expect_patch_set,
            "version": args.expect_version,
            "buildSha": f"source-{args.expect_target[:12]}-patch-{args.expect_patch_set[:12]}",
            "overlayPolicyHash": policy_hash(),
        }
        for key, value in expected.items():
            if manifest.get(key) != value:
                raise ArtifactError(f"artifact {key} mismatch")
            if key in {"targetRef", "targetCommit", "patchSetHash", "version", "buildSha", "overlayPolicyHash"} and request.get(key) != value:
                raise ArtifactError(f"request {key} mismatch")
        if manifest.get("patches") != request.get("patches"):
            raise ArtifactError("artifact ordered patch identity does not match request")
        local_fingerprint, _ = read_json(Path(args.fingerprint), require_canonical=True)
        if manifest.get("runtime") != local_fingerprint or request.get("runtime") != local_fingerprint:
            raise ArtifactError("artifact runtime/platform fingerprint mismatch")
        installed_fingerprint = dependency_fingerprint(Path(args.installed_package))
        if manifest.get("dependencyFingerprint") != installed_fingerprint:
            raise ArtifactError("artifact dependencies do not match installed package")
        payload = outer / "payload.tar.gz"
        if sha256_file(payload) != manifest.get("payloadSha256"):
            raise ArtifactError("payload checksum mismatch")
        names = extract_checked(payload, destination, max_bytes=MAX_PAYLOAD_BYTES, allowed=allowed_overlay)
        indexed = verify_file_index(destination)
        if sha256_bytes(indexed["raw"]) != manifest.get("fileIndexSha256"):
            raise ArtifactError("payload file-index checksum mismatch")
        if indexed["count"] != manifest.get("payloadEntryCount") or indexed["bytes"] != manifest.get("payloadUnpackedBytes"):
            raise ArtifactError("payload size/count does not match manifest")
        build_sha = (destination / "dist/BUILD_SHA").read_text().strip()
        if build_sha != expected["buildSha"]:
            raise ArtifactError("payload BUILD_SHA mismatch")
        if len(names) != indexed["count"] + 1:
            raise ArtifactError("payload archive contains unaccounted entries")
        print(canonical_json({"artifactId": artifact_id, "manifestSha256": manifest_sha, "manifest": manifest, "destination": str(destination)}).decode(), end="")


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser()
    sub = result.add_subparsers(dest="command", required=True)

    fingerprint = sub.add_parser("fingerprint")
    fingerprint.add_argument("--npm-version", required=True)
    fingerprint.set_defaults(func=command_fingerprint)

    policy = sub.add_parser("policy")
    policy.set_defaults(func=command_policy)

    canonicalize = sub.add_parser("canonicalize")
    canonicalize.add_argument("--input", required=True)
    canonicalize.add_argument("--output", required=True)
    canonicalize.set_defaults(func=command_canonicalize)

    pack_request = sub.add_parser("pack-request")
    pack_request.add_argument("--directory", required=True)
    pack_request.add_argument("--output", required=True)
    pack_request.set_defaults(func=command_pack_request)

    extract_request = sub.add_parser("extract-request")
    extract_request.add_argument("--archive", required=True)
    extract_request.add_argument("--destination", required=True)
    extract_request.set_defaults(func=command_extract_request)

    create_payload = sub.add_parser("create-payload")
    create_payload.add_argument("--source", required=True)
    create_payload.add_argument("--output", required=True)
    create_payload.add_argument("--index-output", required=True)
    create_payload.set_defaults(func=command_create_payload)

    create_response = sub.add_parser("create-response")
    create_response.add_argument("--manifest", required=True)
    create_response.add_argument("--payload", required=True)
    create_response.add_argument("--output", required=True)
    create_response.set_defaults(func=command_create_response)

    artifact_id = sub.add_parser("artifact-id")
    artifact_id.add_argument("--archive", required=True)
    artifact_id.add_argument("--request", required=True)
    artifact_id.set_defaults(func=command_artifact_id)

    verify = sub.add_parser("verify-response")
    verify.add_argument("--archive", required=True)
    verify.add_argument("--request", required=True)
    verify.add_argument("--expect-artifact", required=True)
    verify.add_argument("--expect-manifest", required=True)
    verify.add_argument("--expect-target", required=True)
    verify.add_argument("--expect-target-ref", required=True)
    verify.add_argument("--expect-patch-set", required=True)
    verify.add_argument("--expect-version", required=True)
    verify.add_argument("--expect-builder-repository", default=DEFAULT_BUILDER_REPOSITORY)
    verify.add_argument("--expect-workflow", default=DEFAULT_BUILDER_WORKFLOW)
    verify.add_argument("--expect-source-ref", required=True)
    verify.add_argument("--expect-source-digest", required=True)
    verify.add_argument("--expect-run-id", type=int, required=True)
    verify.add_argument("--expect-run-attempt", type=int, required=True)
    verify.add_argument("--fingerprint", required=True)
    verify.add_argument("--installed-package", required=True)
    verify.add_argument("--destination", required=True)
    verify.set_defaults(func=command_verify_response)
    return result


def main() -> int:
    try:
        args = parser().parse_args()
        args.func(args)
        return 0
    except ArtifactError as error:
        print(f"[omniroute-artifact] ERROR: {error}", file=sys.stderr)
        return 20
    except (OSError, subprocess.SubprocessError) as error:
        print(f"[omniroute-artifact] ERROR: operation failed: {error}", file=sys.stderr)
        return 20


if __name__ == "__main__":
    raise SystemExit(main())
