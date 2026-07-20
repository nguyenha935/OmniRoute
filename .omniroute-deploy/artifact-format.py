#!/usr/bin/env python3
"""Fail-closed dual-lane request and signed artifact handling for OmniRoute."""

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

SCHEMA_VERSION = 2
ARTIFACT_SCHEMA_VERSION = 3
INDEX_SCHEMA_VERSION = 2
REPOSITORY = "diegosouzapw/OmniRoute"
REQUEST_TYPE = "omniroute-build-request"
DEFAULT_BUILDER_REPOSITORY = "nguyenha935/OmniRoute"
DEFAULT_BUILDER_WORKFLOW = ".github/workflows/omniroute-patch-artifact.yml"
MAX_OUTER_BYTES = 8 * 1024 * 1024 * 1024
MAX_PAYLOAD_BYTES = 12 * 1024 * 1024 * 1024
MAX_FILE_BYTES = 4 * 1024 * 1024 * 1024
MAX_ENTRIES = 200_000
MAX_LINKS = 10_000
MAX_PATH_BYTES = 1_024

ARTIFACT_TYPES = {
    "overlay": "omniroute-runtime-overlay",
    "full-package": "omniroute-full-package",
}
# Kept as a read-only compatibility alias for callers importing the old symbol.
ARTIFACT_TYPE = ARTIFACT_TYPES["overlay"]

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
    "scripts/build/fixTlsClientNodeBinary.mjs",
    "scripts/postinstall.mjs",
    "scripts/dev/responses-ws-proxy.mjs",
    "scripts/dev/tls-options.mjs",
    "scripts/dev/sync-env.mjs",
    "scripts/check/check-supported-node-runtime.ts",
)
EXCLUDED_PARTS = ("__tests__",)
EXCLUDED_SUFFIXES = (".test.ts", ".test.tsx", ".test.js", ".test.mjs", ".spec.ts", ".spec.tsx")
FULL_PACKAGE_ROOTS = (*REPLACE_ROOTS, *SINGLETONS, "node_modules")
FULL_PACKAGE_FORBIDDEN_ROOTS = (
    ".git",
    ".github",
    ".husky",
    ".next/cache",
    "coverage",
    "test",
    "tests",
)
PAYLOAD_METADATA = {
    "payload-files.json",
    "payload-links.json",
    "payload-production-tree.json",
    "payload-native-files.json",
}
FULL_PACKAGE_METADATA = PAYLOAD_METADATA | {"payload-source-lock.json", "payload-source-package.json"}


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


def require_nonnegative_integer(value: Any, name: str) -> int:
    if not isinstance(value, int) or isinstance(value, bool) or value < 0:
        raise ArtifactError(f"{name} must be a non-negative integer")
    return value


def require_mode(mode: Any) -> str:
    if mode not in ARTIFACT_TYPES:
        raise ArtifactError(f"unsupported artifact mode: {mode}")
    return mode


def policy_document(mode: str = "overlay") -> dict[str, Any]:
    mode = require_mode(mode)
    common = {
        "schemaVersion": SCHEMA_VERSION,
        "artifactMode": mode,
        "artifactType": ARTIFACT_TYPES[mode],
        "archiveMembers": "regular-files-only",
        "fileIndex": "payload-files.json",
        "linkIndex": "payload-links.json",
        "nativeIndex": "payload-native-files.json",
        "productionTree": "payload-production-tree.json",
        "limits": {
            "maxEntries": MAX_ENTRIES,
            "maxFileBytes": MAX_FILE_BYTES,
            "maxLinks": MAX_LINKS,
            "maxPathBytes": MAX_PATH_BYTES,
            "maxPayloadBytes": MAX_PAYLOAD_BYTES,
        },
    }
    if mode == "overlay":
        return {
            **common,
            "replaceRoots": list(REPLACE_ROOTS),
            "singletons": list(SINGLETONS),
            "excludedParts": list(EXCLUDED_PARTS),
            "excludedSuffixes": list(EXCLUDED_SUFFIXES),
        }
    return {
        **common,
        "packageRoot": "package",
        "sourceLock": "payload-source-lock.json",
        "sourcePackage": "payload-source-package.json",
        "materializedWorkspaceLinks": True,
        "allowedLinks": ["package/node_modules/**/.bin/*"],
        "allowedPackageRoots": list(FULL_PACKAGE_ROOTS),
        "forbiddenPackageRoots": list(FULL_PACKAGE_FORBIDDEN_ROOTS),
    }


def policy_hash(mode: str = "overlay") -> str:
    return sha256_bytes(canonical_json(policy_document(mode)))


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
    if len(name.encode()) > MAX_PATH_BYTES:
        raise ArtifactError(f"archive path exceeds limit: {name}")
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
    if destination.exists() and (destination.is_symlink() or not destination.is_dir() or any(destination.iterdir())):
        raise ArtifactError(f"extraction destination is not an empty directory: {destination}")
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
                descriptor = os.open(
                    target,
                    os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0),
                    member.mode & 0o777,
                )
            except OSError as error:
                raise ArtifactError(f"could not safely create {name}: {error}") from error
            with source, os.fdopen(descriptor, "wb") as output:
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
                    if len(data) > MAX_FILE_BYTES:
                        raise ArtifactError(f"archive file exceeds limit: {name}")
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
    return member.isfile() and (
        name in ("request.json", "request-files.json")
        or (name.startswith("patches/") and name.endswith(".patch") and name.count("/") == 1)
    )


def normalize_dependency_fingerprint(value: Any, name: str = "dependencyFingerprint") -> dict[str, Any]:
    if not isinstance(value, dict) or set(value) != {"dependencies", "optionalDependencies", "engines"}:
        raise ArtifactError(f"{name} must contain exactly dependencies, optionalDependencies, and engines")
    normalized: dict[str, Any] = {}
    for field in ("dependencies", "optionalDependencies", "engines"):
        section = value.get(field)
        if not isinstance(section, dict) or not all(isinstance(key, str) and isinstance(item, str) for key, item in section.items()):
            raise ArtifactError(f"{name}.{field} must be a string map")
        normalized[field] = dict(sorted(section.items()))
    return normalized


def validate_request_shape(request: dict[str, Any]) -> str:
    if request.get("schemaVersion") != SCHEMA_VERSION or request.get("requestType") != REQUEST_TYPE:
        raise ArtifactError("unsupported build request schema/type")
    if request.get("repository") != REPOSITORY:
        raise ArtifactError("request repository is not allowed")
    if "overlayPolicyHash" in request:
        raise ArtifactError("legacy overlayPolicyHash is not allowed")
    mode = require_mode(request.get("artifactMode"))
    if request.get("artifactType") != ARTIFACT_TYPES[mode]:
        raise ArtifactError("request artifact mode/type mismatch")
    if request.get("artifactPolicyHash") != policy_hash(mode):
        raise ArtifactError("request artifact policy does not match builder policy")
    require_string(request.get("targetRef"), "targetRef")
    target = require_hash(request.get("targetCommit"), "targetCommit", 40)
    require_string(request.get("version"), "version")
    build_sha = require_string(request.get("buildSha"), "buildSha")
    require_string(request.get("createdAt"), "createdAt")
    require_hash(request.get("sourcePackageSha256"), "sourcePackageSha256")
    require_hash(request.get("sourceLockSha256"), "sourceLockSha256")
    normalize_dependency_fingerprint(request.get("dependencyFingerprint"))
    patch_set = request.get("patchSetHash")
    if patch_set != "none":
        require_hash(patch_set, "patchSetHash")
    expected_build_sha = f"source-{target[:12]}-patch-{patch_set[:12]}"
    if build_sha != expected_build_sha:
        raise ArtifactError("request buildSha does not match target and patch set")
    runtime = request.get("runtime")
    if not isinstance(runtime, dict) or not runtime:
        raise ArtifactError("request runtime/platform fingerprint is missing")
    patches = request.get("patches")
    if not isinstance(patches, list):
        raise ArtifactError("request patches must be an array")
    return mode


def validate_request(request: dict[str, Any], request_files: dict[str, Any], root: Path) -> None:
    validate_request_shape(request)
    patches = request["patches"]
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
    if recomputed != request.get("patchSetHash"):
        raise ArtifactError("patch-set hash does not match the ordered request patches")
    indexed_paths: set[str] = set()
    indexed_folded: set[str] = set()
    for entry in files:
        if not isinstance(entry, dict):
            raise ArtifactError("invalid request file index")
        name = safe_name(require_string(entry.get("path"), "request file path"))
        digest = require_hash(entry.get("sha256"), f"request file {name} sha256")
        if name in indexed_paths or name.casefold() in indexed_folded or name not in expected_paths:
            raise ArtifactError(f"unexpected, duplicate, or case-colliding request file index: {name}")
        indexed_paths.add(name)
        indexed_folded.add(name.casefold())
        if sha256_file(root / name) != digest:
            raise ArtifactError(f"request file checksum mismatch: {name}")
    if indexed_paths != expected_paths:
        raise ArtifactError("request file index is incomplete")


def allowed_overlay(name: str, member: tarfile.TarInfo) -> bool:
    if name in PAYLOAD_METADATA:
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


def allowed_full_package(name: str, member: tarfile.TarInfo) -> bool:
    if name in FULL_PACKAGE_METADATA:
        return member.isfile()
    if not (name == "package" or name.startswith("package/")):
        return False
    relative = name.removeprefix("package/") if name != "package" else ""
    if not relative:
        return member.isdir()
    if relative in (".env", "package-lock.json") or "/.git/" in f"/{relative}/":
        return False
    if any(relative == root or relative.startswith(root + "/") for root in FULL_PACKAGE_FORBIDDEN_ROOTS):
        return False
    if not any(relative == root or relative.startswith(root + "/") for root in FULL_PACKAGE_ROOTS):
        return False
    # Production dependencies may legitimately publish test-looking files. Root
    # package residue is forbidden, while node_modules closure is lock-validated.
    if not relative.startswith("node_modules/"):
        parts = PurePosixPath(relative).parts
        if any(part in EXCLUDED_PARTS for part in parts) or relative.endswith(EXCLUDED_SUFFIXES):
            return False
    return True


def allowed_for_mode(mode: str) -> Any:
    return allowed_overlay if require_mode(mode) == "overlay" else allowed_full_package


def _index_entries(index: Any, field: str, filename: str) -> list[dict[str, Any]]:
    entries = index.get(field) if isinstance(index, dict) and index.get("schemaVersion") == INDEX_SCHEMA_VERSION else None
    if not isinstance(entries, list):
        raise ArtifactError(f"{filename} must use the current schema and contain {field}[]")
    return entries


def verify_file_index(root: Path) -> dict[str, Any]:
    index, raw = read_json(root / "payload-files.json", require_canonical=True)
    files = _index_entries(index, "files", "payload-files.json")
    if len(files) > MAX_ENTRIES - len(FULL_PACKAGE_METADATA):
        raise ArtifactError("payload file-index entry limit exceeded")
    expected: dict[str, dict[str, Any]] = {}
    folded: set[str] = set()
    expected_bytes = 0
    for entry in files:
        if not isinstance(entry, dict) or set(entry) != {"path", "mode", "size", "sha256"}:
            raise ArtifactError("invalid payload file index entry")
        name = safe_name(require_string(entry.get("path"), "payload file path"))
        if name in FULL_PACKAGE_METADATA or name in expected or name.casefold() in folded:
            raise ArtifactError(f"duplicate, case-colliding, or reserved payload index path: {name}")
        mode = entry.get("mode")
        if mode not in (0o644, 0o755):
            raise ArtifactError(f"invalid indexed file mode: {name}")
        size = require_nonnegative_integer(entry.get("size"), f"payload file {name} size")
        if size > MAX_FILE_BYTES:
            raise ArtifactError(f"indexed file exceeds size limit: {name}")
        require_hash(entry.get("sha256"), f"payload file {name} sha256")
        expected_bytes += size
        if expected_bytes > MAX_PAYLOAD_BYTES:
            raise ArtifactError("payload file index exceeds unpacked-size limit")
        expected[name] = entry
        folded.add(name.casefold())
    actual: set[str] = set()
    for path in root.rglob("*"):
        if path.is_dir() and not path.is_symlink():
            continue
        name = path.relative_to(root).as_posix()
        if path.is_symlink() or not path.is_file():
            raise ArtifactError(f"unsafe extracted filesystem entry: {name}")
        if name in FULL_PACKAGE_METADATA:
            continue
        actual.add(name)
        entry = expected.get(name)
        if entry is None:
            raise ArtifactError(f"payload contains an unindexed file: {name}")
        details = path.stat(follow_symlinks=False)
        if details.st_size != entry["size"] or sha256_file(path) != entry["sha256"]:
            raise ArtifactError(f"payload file does not match index: {name}")
        if stat.S_IMODE(details.st_mode) != entry["mode"]:
            raise ArtifactError(f"payload file mode does not match index: {name}")
    if actual != set(expected):
        raise ArtifactError("payload file index references missing files")
    return {"index": index, "raw": raw, "entries": expected, "count": len(actual), "bytes": expected_bytes}


def _safe_link_target(path: str, target: Any, indexed_files: set[str]) -> str:
    target = require_string(target, f"link target for {path}")
    if "\\" in target or target.startswith("/") or len(target.encode()) > MAX_PATH_BYTES:
        raise ArtifactError(f"unsafe link target for {path}")
    target_parts = PurePosixPath(target).parts
    if any(part in ("", ".") for part in target_parts):
        raise ArtifactError(f"non-canonical link target for {path}")
    resolved = posixpath.normpath(posixpath.join(posixpath.dirname(path), target))
    if not resolved.startswith("package/") or resolved not in indexed_files:
        raise ArtifactError(f"escaping, dangling, directory, chained, or unindexed link target for {path}")
    if posixpath.relpath(resolved, posixpath.dirname(path)) != target:
        raise ArtifactError(f"non-canonical link target for {path}")
    return target


def verify_link_index(root: Path, mode: str, file_entries: dict[str, dict[str, Any]], *, materialize: bool = False) -> dict[str, Any]:
    index, raw = read_json(root / "payload-links.json", require_canonical=True)
    links = _index_entries(index, "links", "payload-links.json")
    if len(links) > MAX_LINKS:
        raise ArtifactError("payload link-index limit exceeded")
    expected: dict[str, str] = {}
    folded = {name.casefold() for name in file_entries}
    for entry in links:
        if not isinstance(entry, dict) or set(entry) != {"path", "target"}:
            raise ArtifactError("invalid payload link index entry")
        name = safe_name(require_string(entry.get("path"), "payload link path"))
        parts = PurePosixPath(name).parts
        if mode != "full-package" or len(parts) < 4 or parts[0] != "package" or "node_modules" not in parts or parts[-2] != ".bin":
            raise ArtifactError(f"link path is outside the npm .bin policy: {name}")
        if name in expected or name.casefold() in folded:
            raise ArtifactError(f"duplicate or case-colliding payload link: {name}")
        target = _safe_link_target(name, entry.get("target"), set(file_entries))
        expected[name] = target
        folded.add(name.casefold())
    if mode == "overlay" and expected:
        raise ArtifactError("overlay artifacts may not contain links")
    if materialize:
        for name, target in sorted(expected.items()):
            path = root.joinpath(*PurePosixPath(name).parts)
            path.parent.mkdir(parents=True, exist_ok=True)
            if path.exists() or path.is_symlink():
                raise ArtifactError(f"link destination already exists: {name}")
            os.symlink(target, path)
    return {"index": index, "raw": raw, "links": expected, "count": len(expected)}


def _node_module_package_path(name: str) -> str | None:
    if not name.startswith("package/") or not name.endswith("/package.json"):
        return None
    parent = PurePosixPath(name.removeprefix("package/")).parent
    parts = parent.parts
    positions = [index for index, part in enumerate(parts) if part == "node_modules"]
    if not positions:
        return None
    index = positions[-1]
    suffix = parts[index + 1 :]
    if len(suffix) == 1 and not suffix[0].startswith("@"):
        return parent.as_posix()
    if len(suffix) == 2 and suffix[0].startswith("@"):
        return parent.as_posix()
    return None


def _source_lock_package_path(package_root: str, lock_packages: dict[str, Any]) -> str | None:
    """Map a physical runtime package path back to its npm lock identity.

    Next standalone output and trusted runtime assembly may co-locate packages below
    runtime roots such as ``dist/node_modules``.  npm's source lock records those
    packages relative to the source install (``node_modules/...``), not the copied
    runtime prefix.  Preserve the physical path in the payload inventory, but only
    accept a prefixed copy when stripping everything before its first
    ``node_modules`` component resolves to an exact source-lock entry.
    """
    if package_root in lock_packages:
        return package_root
    parts = PurePosixPath(package_root).parts
    try:
        first_node_modules = parts.index("node_modules")
    except ValueError:
        return None
    normalized = PurePosixPath(*parts[first_node_modules:]).as_posix()
    return normalized if normalized in lock_packages else None


def _resolve_dependency_path(package_path: str, dependency: str, installed: set[str]) -> str | None:
    current = PurePosixPath(package_path)
    while True:
        candidate = (current / "node_modules" / dependency).as_posix()
        if candidate in installed:
            return candidate
        if current == PurePosixPath("."):
            break
        parts = current.parts
        if "node_modules" not in parts:
            current = PurePosixPath(".")
            continue
        last = max(index for index, part in enumerate(parts) if part == "node_modules")
        current = PurePosixPath(*parts[:last]) if last else PurePosixPath(".")
    root_candidate = f"node_modules/{dependency}"
    return root_candidate if root_candidate in installed else None


def dependency_fingerprint(package_path: Path) -> dict[str, Any]:
    package, _ = read_json(package_path)
    if not isinstance(package, dict):
        raise ArtifactError("package.json must contain an object")
    return normalize_dependency_fingerprint({
        "dependencies": package.get("dependencies", {}),
        "optionalDependencies": package.get("optionalDependencies", {}),
        "engines": package.get("engines", {}),
    })


def build_production_tree(root: Path, file_entries: dict[str, dict[str, Any]], source_lock: Any) -> dict[str, Any]:
    lock_packages = source_lock.get("packages") if isinstance(source_lock, dict) else None
    if not isinstance(lock_packages, dict) or not isinstance(lock_packages.get(""), dict):
        raise ArtifactError("source package-lock.json does not contain a packages map and root entry")
    package_path = root / "package/package.json"
    package, _ = read_json(package_path)
    if not isinstance(package, dict):
        raise ArtifactError("full-package package.json must contain an object")
    root_lock = lock_packages[""]
    for field in ("dependencies", "optionalDependencies"):
        if package.get(field, {}) != root_lock.get(field, {}):
            raise ArtifactError(f"source package and lock root {field} differ")
    actual_paths: dict[str, dict[str, Any]] = {}
    for indexed_name in file_entries:
        package_root = _node_module_package_path(indexed_name)
        if package_root is None:
            continue
        package_json, _ = read_json(root / "package" / package_root / "package.json")
        if not isinstance(package_json, dict):
            raise ArtifactError(f"installed package metadata is invalid: {package_root}")
        lock_path = _source_lock_package_path(package_root, lock_packages)
        if lock_path is None:
            raise ArtifactError(f"installed package is absent from source lock: {package_root}")
        lock_entry = lock_packages[lock_path]
        if not isinstance(lock_entry, dict):
            raise ArtifactError(f"installed package lock metadata is invalid: {package_root}")
        effective_lock = lock_entry
        workspace = lock_entry.get("link") is True
        if workspace:
            resolved = lock_entry.get("resolved")
            if not isinstance(resolved, str) or resolved.startswith("/") or "\\" in resolved or posixpath.normpath(resolved) != resolved:
                raise ArtifactError(f"invalid workspace lock target: {package_root}")
            effective_lock = lock_packages.get(resolved)
            if not isinstance(effective_lock, dict):
                raise ArtifactError(f"workspace target is absent from source lock: {package_root}")
            if not isinstance(package_json.get("version"), str) and isinstance(effective_lock.get("version"), str):
                package_json = {**package_json, "version": effective_lock["version"]}
        if effective_lock.get("dev") is True:
            raise ArtifactError(f"dev-only package leaked into production tree: {package_root}")
        package_name = require_string(package_json.get("name"), f"{package_root} package name")
        package_version = require_string(package_json.get("version"), f"{package_root} package version")
        lock_version = effective_lock.get("version")
        if isinstance(lock_version, str) and lock_version != package_version:
            raise ArtifactError(f"installed package version differs from source lock: {package_root}")
        actual_paths[package_root] = {
            "path": package_root,
            "name": package_name,
            "version": package_version,
            "optional": effective_lock.get("optional") is True,
            "workspace": workspace,
        }
    required_root = set(package.get("dependencies", {}))
    optional_root = set(package.get("optionalDependencies", {}))
    for dependency in sorted(required_root):
        expected_path = f"node_modules/{dependency}"
        if expected_path not in actual_paths:
            raise ArtifactError(f"required production dependency is missing: {dependency}")
    for dependency in sorted(optional_root):
        expected_path = f"node_modules/{dependency}"
        if expected_path in actual_paths and lock_packages.get(expected_path, {}).get("dev") is True:
            raise ArtifactError(f"dev-only optional dependency leaked into production tree: {dependency}")

    installed = set(actual_paths)
    for package_root in sorted(installed):
        package_json, _ = read_json(root / "package" / package_root / "package.json")
        required = package_json.get("dependencies", {}) if isinstance(package_json, dict) else {}
        optional_dependencies = package_json.get("optionalDependencies", {}) if isinstance(package_json, dict) else {}
        if not isinstance(required, dict) or not isinstance(optional_dependencies, dict):
            raise ArtifactError(f"installed package dependencies are invalid: {package_root}")
        for dependency in sorted(required):
            if dependency in optional_dependencies:
                continue
            if _resolve_dependency_path(package_root, dependency, installed) is None:
                raise ArtifactError(f"transitive production dependency is missing: {package_root} -> {dependency}")

    return {"schemaVersion": INDEX_SCHEMA_VERSION, "packages": [actual_paths[path] for path in sorted(actual_paths)]}


def verify_production_tree(
    root: Path,
    mode: str,
    file_entries: dict[str, dict[str, Any]],
    source_lock: Any | None = None,
) -> dict[str, Any]:
    index, raw = read_json(root / "payload-production-tree.json", require_canonical=True)
    packages = _index_entries(index, "packages", "payload-production-tree.json")
    if mode == "overlay":
        if packages:
            raise ArtifactError("overlay production-tree index must be empty")
        expected = {"schemaVersion": INDEX_SCHEMA_VERSION, "packages": []}
    else:
        if source_lock is None:
            raise ArtifactError("full-package source lock is missing")
        expected = build_production_tree(root, file_entries, source_lock)
    if index != expected:
        raise ArtifactError("production-tree index does not match package files and source lock")
    return {"index": index, "raw": raw, "count": len(packages)}


def build_native_index(file_entries: dict[str, dict[str, Any]]) -> dict[str, Any]:
    native = []
    for name, entry in sorted(file_entries.items()):
        if name.endswith(".node"):
            native.append({key: entry[key] for key in ("path", "mode", "size", "sha256")})
    return {"schemaVersion": INDEX_SCHEMA_VERSION, "files": native}


def verify_native_index(root: Path, file_entries: dict[str, dict[str, Any]]) -> dict[str, Any]:
    index, raw = read_json(root / "payload-native-files.json", require_canonical=True)
    _index_entries(index, "files", "payload-native-files.json")
    expected = build_native_index(file_entries)
    if index != expected:
        raise ArtifactError("native-file index does not match payload file index")
    return {"index": index, "raw": raw, "count": len(expected["files"])}


def verify_materialized_tree(
    root: Path,
    file_entries: dict[str, dict[str, Any]],
    links: dict[str, str],
    metadata: set[str],
) -> None:
    actual_files: set[str] = set()
    actual_links: dict[str, str] = {}
    for directory, directory_names, file_names in os.walk(root, topdown=True, followlinks=False):
        base = Path(directory)
        for directory_name in list(directory_names):
            path = base / directory_name
            name = path.relative_to(root).as_posix()
            if path.is_symlink():
                actual_links[name] = os.readlink(path)
                directory_names.remove(directory_name)
        for file_name in file_names:
            path = base / file_name
            name = path.relative_to(root).as_posix()
            if path.is_symlink():
                actual_links[name] = os.readlink(path)
            elif path.is_file():
                actual_files.add(name)
            else:
                raise ArtifactError(f"special filesystem entry after extraction: {name}")
    if actual_files != set(file_entries) | metadata:
        raise ArtifactError("materialized payload contains missing or extra regular files")
    if actual_links != links:
        raise ArtifactError("materialized payload links do not match link index")


def verify_manifest_shape(manifest: dict[str, Any]) -> str:
    if manifest.get("schemaVersion") != ARTIFACT_SCHEMA_VERSION:
        raise ArtifactError("unsupported artifact schema")
    if manifest.get("repository") != REPOSITORY:
        raise ArtifactError("artifact repository is not allowed")
    if "overlayPolicyHash" in manifest:
        raise ArtifactError("legacy overlayPolicyHash is not allowed")
    mode = require_mode(manifest.get("artifactMode"))
    if manifest.get("artifactType") != ARTIFACT_TYPES[mode]:
        raise ArtifactError("artifact mode/type mismatch")
    if manifest.get("artifactPolicyHash") != policy_hash(mode):
        raise ArtifactError("artifact policy mismatch")
    for field in (
        "requestSha256",
        "sourcePackageSha256",
        "sourceLockSha256",
        "payloadSha256",
        "fileIndexSha256",
        "linkIndexSha256",
        "productionTreeSha256",
        "nativeIndexSha256",
    ):
        require_hash(manifest.get(field), field)
    require_string(manifest.get("targetRef"), "targetRef")
    require_hash(manifest.get("targetCommit"), "targetCommit", 40)
    require_string(manifest.get("version"), "version")
    require_string(manifest.get("buildSha"), "buildSha")
    require_string(manifest.get("createdAt"), "createdAt")
    normalize_dependency_fingerprint(manifest.get("dependencyFingerprint"))
    patch_set = manifest.get("patchSetHash")
    if patch_set != "none":
        require_hash(patch_set, "patchSetHash")
    for field in ("payloadEntryCount", "payloadUnpackedBytes", "payloadLinkCount", "productionPackageCount", "nativeFileCount"):
        require_nonnegative_integer(manifest.get(field), field)
    if manifest["payloadEntryCount"] > MAX_ENTRIES or manifest["payloadUnpackedBytes"] > MAX_PAYLOAD_BYTES:
        raise ArtifactError("manifest payload count/size exceeds hard limit")
    if manifest["payloadLinkCount"] > MAX_LINKS:
        raise ArtifactError("manifest link count exceeds hard limit")
    if manifest.get("buildBundler") != "turbopack":
        raise ArtifactError("artifact was not built with Turbopack")
    runtime = manifest.get("runtime")
    if not isinstance(runtime, dict) or not runtime:
        raise ArtifactError("artifact runtime/platform fingerprint is missing")
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
    return mode


def extract_outer(response: Path, destination: Path) -> None:
    expected = {"artifact-manifest.json", "payload.tar.gz"}
    names = extract_checked(
        response,
        destination,
        max_bytes=MAX_OUTER_BYTES,
        allowed=lambda name, member: member.isfile() and name in expected,
    )
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


def request_manifest_bindings(request: dict[str, Any]) -> dict[str, Any]:
    return {
        "artifactMode": request["artifactMode"],
        "artifactType": request["artifactType"],
        "artifactPolicyHash": request["artifactPolicyHash"],
        "targetRef": request["targetRef"],
        "targetCommit": request["targetCommit"],
        "patchSetHash": request["patchSetHash"],
        "version": request["version"],
        "buildSha": request["buildSha"],
        "sourcePackageSha256": request["sourcePackageSha256"],
        "sourceLockSha256": request["sourceLockSha256"],
        "dependencyFingerprint": request["dependencyFingerprint"],
        "runtime": request["runtime"],
    }


def verify_request_manifest(request: dict[str, Any], request_raw: bytes, manifest: dict[str, Any]) -> str:
    request_mode = validate_request_shape(request)
    manifest_mode = verify_manifest_shape(manifest)
    if request_mode != manifest_mode:
        raise ArtifactError("request and artifact modes differ")
    if manifest.get("requestSha256") != sha256_bytes(request_raw):
        raise ArtifactError("artifact request hash does not match local request")
    for key, value in request_manifest_bindings(request).items():
        if manifest.get(key) != value:
            raise ArtifactError(f"artifact {key} does not match request")
    if manifest.get("patches") != request.get("patches"):
        raise ArtifactError("artifact ordered patch identity does not match request")
    return request_mode


def command_fingerprint(args: argparse.Namespace) -> None:
    print(canonical_json(runtime_fingerprint(args.npm_version)).decode(), end="")


def command_dependency_fingerprint(args: argparse.Namespace) -> None:
    print(canonical_json(dependency_fingerprint(Path(args.package))).decode(), end="")


def command_policy(args: argparse.Namespace) -> None:
    print(canonical_json({**policy_document(args.mode), "policyHash": policy_hash(args.mode)}).decode(), end="")


def command_canonicalize(args: argparse.Namespace) -> None:
    value, _ = read_json(Path(args.input))
    Path(args.output).write_bytes(canonical_json(value))


def command_pack_request(args: argparse.Namespace) -> None:
    root = Path(args.directory).resolve()
    request, _ = read_json(root / "request.json", require_canonical=True)
    request_files, _ = read_json(root / "request-files.json", require_canonical=True)
    validate_request(request, request_files, root)
    entries: list[tuple[str, Path | bytes, int]] = [
        ("request.json", root / "request.json", 0o600),
        ("request-files.json", root / "request-files.json", 0o600),
    ]
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
            member = tarfile.TarInfo(name)
            member.type = tarfile.REGTYPE
            if name in seen or not allowed_overlay(name, member):
                continue
            seen.add(name)
            mode = 0o755 if path.stat().st_mode & 0o111 else 0o644
            result.append((name, path, mode))
    required = {"dist/server.js", "dist/BUILD_SHA", "bin/omniroute.mjs", "package.json"}
    if not required.issubset(seen):
        raise ArtifactError(f"overlay source is missing required files: {sorted(required - seen)}")
    return sorted(result)


def iter_full_package(root: Path) -> tuple[list[tuple[str, Path, int]], list[tuple[str, str]]]:
    files: list[tuple[str, Path, int]] = []
    links: list[tuple[str, str]] = []
    for directory, directory_names, file_names in os.walk(root, topdown=True, followlinks=False):
        base = Path(directory)
        for directory_name in list(directory_names):
            path = base / directory_name
            if path.is_symlink():
                name = f"package/{path.relative_to(root).as_posix()}"
                links.append((name, os.readlink(path)))
                directory_names.remove(directory_name)
        for file_name in file_names:
            path = base / file_name
            name = f"package/{path.relative_to(root).as_posix()}"
            if path.is_symlink():
                links.append((name, os.readlink(path)))
                continue
            if not path.is_file():
                raise ArtifactError(f"full-package source contains a special file: {path}")
            member = tarfile.TarInfo(name)
            member.type = tarfile.REGTYPE
            if not allowed_full_package(name, member):
                raise ArtifactError(f"full-package source path is outside policy: {name}")
            mode = 0o755 if path.stat().st_mode & 0o111 else 0o644
            files.append((name, path, mode))
    names = {name for name, _, _ in files}
    required = {"package/dist/server.js", "package/dist/BUILD_SHA", "package/bin/omniroute.mjs", "package/package.json"}
    if not required.issubset(names):
        raise ArtifactError(f"full-package source is missing required files: {sorted(required - names)}")
    if not any(name.startswith("package/node_modules/") for name in names):
        raise ArtifactError("full-package source has no production node_modules")
    return sorted(files), sorted(links)


def _write_optional(path: str | None, raw: bytes) -> None:
    if path:
        Path(path).write_bytes(raw)


def command_create_payload(args: argparse.Namespace) -> None:
    mode = require_mode(args.mode)
    root = Path(args.source).resolve()
    source_lock_raw: bytes | None = None
    source_package_raw: bytes | None = None
    source_lock: Any | None = None
    if mode == "overlay":
        files = iter_overlay_files(root)
        raw_links: list[tuple[str, str]] = []
    else:
        if not args.source_lock or not args.source_package:
            raise ArtifactError("full-package payload creation requires --source-lock and --source-package")
        source_lock, source_lock_raw = read_json(Path(args.source_lock))
        source_package, source_package_raw = read_json(Path(args.source_package))
        staged_package, staged_package_raw = read_json(root / "package.json")
        if source_package != staged_package or source_package_raw != staged_package_raw:
            raise ArtifactError("full-package staging package.json differs from requested source package")
        files, raw_links = iter_full_package(root)
    extra_metadata = int(source_lock_raw is not None) + int(source_package_raw is not None)
    if len(files) + len(PAYLOAD_METADATA) + extra_metadata > MAX_ENTRIES:
        raise ArtifactError("payload entry limit exceeded")
    index_entries: list[dict[str, Any]] = []
    archive_entries: list[tuple[str, Path | bytes, int]] = []
    total = 0
    for name, path, mode_bits in files:
        size = path.stat().st_size
        if size > MAX_FILE_BYTES:
            raise ArtifactError(f"payload file exceeds limit: {name}")
        total += size
        if total > MAX_PAYLOAD_BYTES:
            raise ArtifactError("payload exceeds unpacked-size limit")
        entry = {"path": name, "mode": mode_bits, "size": size, "sha256": sha256_file(path)}
        index_entries.append(entry)
        archive_entries.append((name, path, mode_bits))
    file_index = {"schemaVersion": INDEX_SCHEMA_VERSION, "files": index_entries}
    file_index_raw = canonical_json(file_index)
    file_entries = {entry["path"]: entry for entry in index_entries}
    if len(raw_links) > MAX_LINKS:
        raise ArtifactError("payload link limit exceeded")
    links = []
    folded = {name.casefold() for name in file_entries}
    for name, target in raw_links:
        safe_name(name)
        parts = PurePosixPath(name).parts
        if len(parts) < 4 or parts[0] != "package" or "node_modules" not in parts or parts[-2] != ".bin":
            raise ArtifactError(f"full-package source link is outside npm .bin policy: {name}")
        if name.casefold() in folded:
            raise ArtifactError(f"duplicate or case-colliding full-package source link: {name}")
        target = _safe_link_target(name, target, set(file_entries))
        links.append({"path": name, "target": target})
        folded.add(name.casefold())
    link_index = {"schemaVersion": INDEX_SCHEMA_VERSION, "links": links}
    link_index_raw = canonical_json(link_index)
    if mode == "overlay":
        production_tree = {"schemaVersion": INDEX_SCHEMA_VERSION, "packages": []}
    else:
        production_tree = build_production_tree(_CreationRoot(root), file_entries, source_lock)
    production_tree_raw = canonical_json(production_tree)
    native_index = build_native_index(file_entries)
    native_index_raw = canonical_json(native_index)
    archive_entries.extend([
        ("payload-files.json", file_index_raw, 0o644),
        ("payload-links.json", link_index_raw, 0o644),
        ("payload-production-tree.json", production_tree_raw, 0o644),
        ("payload-native-files.json", native_index_raw, 0o644),
    ])
    if source_lock_raw is not None:
        archive_entries.append(("payload-source-lock.json", source_lock_raw, 0o644))
    if source_package_raw is not None:
        archive_entries.append(("payload-source-package.json", source_package_raw, 0o644))
    deterministic_tar(Path(args.output), archive_entries)
    Path(args.index_output).write_bytes(file_index_raw)
    _write_optional(args.links_output, link_index_raw)
    _write_optional(args.production_tree_output, production_tree_raw)
    _write_optional(args.native_index_output, native_index_raw)


class _CreationRoot:
    """Expose a staging package as extracted-root/package without copying it."""

    def __init__(self, package: Path):
        self.package = package

    def __truediv__(self, value: str) -> Path:
        prefix = "package/"
        if value == "package":
            return self.package
        if value.startswith(prefix):
            return self.package / value.removeprefix(prefix)
        raise ArtifactError(f"invalid creation-root path: {value}")


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
        verify_request_manifest(request, request_raw, manifest)
        if sha256_file(outer / "payload.tar.gz") != manifest.get("payloadSha256"):
            raise ArtifactError("payload checksum mismatch")
        print(canonical_json({"artifactId": sha256_file(response), "manifestSha256": sha256_bytes(manifest_raw), "manifest": manifest}).decode(), end="")


def command_verify_response(args: argparse.Namespace) -> None:
    response = Path(args.archive).resolve()
    destination = Path(args.destination).resolve()
    request, request_raw = read_json(Path(args.request).resolve(), require_canonical=True)
    artifact_id = sha256_file(response)
    if artifact_id != args.expect_artifact:
        raise ArtifactError(f"artifact pin mismatch: expected {args.expect_artifact}, got {artifact_id}")
    with tempfile.TemporaryDirectory(prefix="omniroute-outer-") as temporary:
        outer = Path(temporary)
        extract_outer(response, outer)
        manifest_path = outer / "artifact-manifest.json"
        manifest, manifest_raw = read_json(manifest_path, require_canonical=True)
        mode = verify_request_manifest(request, request_raw, manifest)
        verify_builder_expectations(manifest, args)
        manifest_sha = sha256_bytes(manifest_raw)
        if manifest_sha != args.expect_manifest:
            raise ArtifactError(f"manifest pin mismatch: expected {args.expect_manifest}, got {manifest_sha}")
        expected_request = {
            "targetRef": args.expect_target_ref,
            "targetCommit": args.expect_target,
            "patchSetHash": args.expect_patch_set,
            "version": args.expect_version,
        }
        for key, value in expected_request.items():
            if request.get(key) != value:
                raise ArtifactError(f"request {key} mismatch")
        local_fingerprint, _ = read_json(Path(args.fingerprint), require_canonical=True)
        if manifest.get("runtime") != local_fingerprint or request.get("runtime") != local_fingerprint:
            raise ArtifactError("artifact runtime/platform fingerprint mismatch")
        installed_fingerprint = dependency_fingerprint(Path(args.installed_package))
        target_fingerprint = normalize_dependency_fingerprint(request.get("dependencyFingerprint"))
        if mode == "overlay" and target_fingerprint != installed_fingerprint:
            raise ArtifactError("overlay artifact dependencies do not match installed package")
        if mode == "full-package" and target_fingerprint == installed_fingerprint:
            raise ArtifactError("full-package artifact is forbidden when installed dependencies already match")
        payload = outer / "payload.tar.gz"
        if sha256_file(payload) != manifest.get("payloadSha256"):
            raise ArtifactError("payload checksum mismatch")
        names = extract_checked(payload, destination, max_bytes=MAX_PAYLOAD_BYTES, allowed=allowed_for_mode(mode))
        indexed = verify_file_index(destination)
        if sha256_bytes(indexed["raw"]) != manifest.get("fileIndexSha256"):
            raise ArtifactError("payload file-index checksum mismatch")
        links = verify_link_index(destination, mode, indexed["entries"])
        if sha256_bytes(links["raw"]) != manifest.get("linkIndexSha256"):
            raise ArtifactError("payload link-index checksum mismatch")
        native = verify_native_index(destination, indexed["entries"])
        if sha256_bytes(native["raw"]) != manifest.get("nativeIndexSha256"):
            raise ArtifactError("native-file index checksum mismatch")
        source_lock = None
        metadata = set(PAYLOAD_METADATA)
        if mode == "full-package":
            source_lock_path = destination / "payload-source-lock.json"
            if sha256_file(source_lock_path) != request.get("sourceLockSha256"):
                raise ArtifactError("full-package source lock checksum mismatch")
            source_lock, _ = read_json(source_lock_path)
            source_package_path = destination / "payload-source-package.json"
            if sha256_file(source_package_path) != request.get("sourcePackageSha256"):
                raise ArtifactError("full-package source package checksum mismatch")
            source_package, source_package_raw = read_json(source_package_path)
            staged_package, staged_package_raw = read_json(destination / "package/package.json")
            if source_package != staged_package or source_package_raw != staged_package_raw:
                raise ArtifactError("full-package staged package differs from source package")
            metadata.update({"payload-source-lock.json", "payload-source-package.json"})
            package_path = destination / "package/package.json"
        else:
            package_path = destination / "package.json"
        if sha256_file(package_path) != request.get("sourcePackageSha256"):
            raise ArtifactError("payload source package checksum mismatch")
        if dependency_fingerprint(package_path) != target_fingerprint:
            raise ArtifactError("payload package dependency fingerprint mismatch")
        production = verify_production_tree(destination, mode, indexed["entries"], source_lock)
        if sha256_bytes(production["raw"]) != manifest.get("productionTreeSha256"):
            raise ArtifactError("production-tree index checksum mismatch")
        counts = {
            "payloadEntryCount": indexed["count"],
            "payloadUnpackedBytes": indexed["bytes"],
            "payloadLinkCount": links["count"],
            "productionPackageCount": production["count"],
            "nativeFileCount": native["count"],
        }
        for key, value in counts.items():
            if manifest.get(key) != value:
                raise ArtifactError(f"payload {key} does not match manifest")
        build_sha_path = destination / ("dist/BUILD_SHA" if mode == "overlay" else "package/dist/BUILD_SHA")
        if build_sha_path.read_text().strip() != request["buildSha"]:
            raise ArtifactError("payload BUILD_SHA mismatch")
        expected_archive_entries = indexed["count"] + len(metadata)
        if len(names) != expected_archive_entries:
            raise ArtifactError("payload archive contains unaccounted entries")
        verify_link_index(destination, mode, indexed["entries"], materialize=True)
        verify_materialized_tree(destination, indexed["entries"], links["links"], metadata)
        print(canonical_json({
            "artifactId": artifact_id,
            "manifestSha256": manifest_sha,
            "artifactMode": mode,
            "artifactType": ARTIFACT_TYPES[mode],
            "manifest": manifest,
            "destination": str(destination),
            "packageRoot": str(destination if mode == "overlay" else destination / "package"),
        }).decode(), end="")


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser()
    sub = result.add_subparsers(dest="command", required=True)

    fingerprint = sub.add_parser("fingerprint")
    fingerprint.add_argument("--npm-version", required=True)
    fingerprint.set_defaults(func=command_fingerprint)

    dependency = sub.add_parser("dependency-fingerprint")
    dependency.add_argument("--package", required=True)
    dependency.set_defaults(func=command_dependency_fingerprint)

    policy = sub.add_parser("policy")
    policy.add_argument("--mode", choices=sorted(ARTIFACT_TYPES), default="overlay")
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
    create_payload.add_argument("--mode", choices=sorted(ARTIFACT_TYPES), default="overlay")
    create_payload.add_argument("--source", required=True)
    create_payload.add_argument("--source-lock")
    create_payload.add_argument("--source-package")
    create_payload.add_argument("--output", required=True)
    create_payload.add_argument("--index-output", required=True)
    create_payload.add_argument("--links-output")
    create_payload.add_argument("--production-tree-output")
    create_payload.add_argument("--native-index-output")
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
