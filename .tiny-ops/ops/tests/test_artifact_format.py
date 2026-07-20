#!/usr/bin/env python3

import gzip
import importlib.util
import io
import json
import os
import stat
import tarfile
import tempfile
import unittest
from pathlib import Path

MODULE_PATH = Path(__file__).parents[1] / "artifact-format.py"
SPEC = importlib.util.spec_from_file_location("artifact_format", MODULE_PATH)
artifact = importlib.util.module_from_spec(SPEC)
assert SPEC.loader
SPEC.loader.exec_module(artifact)


class ArtifactFormatTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)

    def tearDown(self):
        self.temporary.cleanup()

    def write_tar(self, path: Path, entries):
        with path.open("wb") as raw:
            with gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0) as compressed:
                with tarfile.open(fileobj=compressed, mode="w", format=tarfile.PAX_FORMAT) as archive:
                    for info, data in entries:
                        info.size = len(data)
                        archive.addfile(info, io.BytesIO(data))

    def regular(self, name, data=b"x", mode=0o644):
        info = tarfile.TarInfo(name)
        info.mode = mode
        return info, data

    def runtime(self):
        return {
            "node": "22.22.3",
            "npm": "10.9.8",
            "modulesAbi": "127",
            "platform": "linux",
            "arch": "x64",
            "osId": "ubuntu",
            "osVersion": "24.04",
            "libc": "glibc",
            "libcVersion": "2.39",
        }

    def package(self, dependencies=None):
        return {
            "name": "omniroute",
            "version": "3.8.49",
            "dependencies": dependencies or {"fixture": "1.0.0"},
            "optionalDependencies": {},
            "engines": {"node": ">=22.22.2"},
        }

    def write_package(self, path: Path, package):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(artifact.canonical_json(package))

    def request(self, mode, package_path, lock_path, *, patches=None):
        patches = patches or []
        payload = "".join(f"{patch['branch']}:{patch['commit']}:{patch['sha256']}\n" for patch in patches).encode()
        patch_set = artifact.sha256_bytes(payload) if patches else "none"
        target = "a" * 40
        return {
            "schemaVersion": artifact.SCHEMA_VERSION,
            "requestType": artifact.REQUEST_TYPE,
            "repository": artifact.REPOSITORY,
            "artifactMode": mode,
            "artifactType": artifact.ARTIFACT_TYPES[mode],
            "artifactPolicyHash": artifact.policy_hash(mode),
            "targetRef": "upstream/release/v3.8.49",
            "targetCommit": target,
            "version": "3.8.49",
            "patchSetHash": patch_set,
            "buildSha": f"source-{target[:12]}-patch-{patch_set[:12]}",
            "sourcePackageSha256": artifact.sha256_file(package_path),
            "sourceLockSha256": artifact.sha256_file(lock_path),
            "dependencyFingerprint": artifact.dependency_fingerprint(package_path),
            "createdAt": "2026-07-20T00:00:00Z",
            "nonce": "fixture",
            "runtime": self.runtime(),
            "patches": patches,
        }

    def test_mode_policy_hashes_are_stable_and_distinct(self):
        overlay = artifact.policy_hash("overlay")
        full = artifact.policy_hash("full-package")
        self.assertEqual(overlay, artifact.sha256_bytes(artifact.canonical_json(artifact.policy_document("overlay"))))
        self.assertEqual(full, artifact.sha256_bytes(artifact.canonical_json(artifact.policy_document("full-package"))))
        self.assertNotEqual(overlay, full)
        self.assertEqual(artifact.ARTIFACT_TYPES["overlay"], "omniroute-runtime-overlay")
        self.assertEqual(artifact.ARTIFACT_TYPES["full-package"], "omniroute-full-package")

    def test_deterministic_archive_is_byte_identical(self):
        first = self.root / "one.tar.gz"
        second = self.root / "two.tar.gz"
        entries = [("payload", b"payload", 0o644)]
        artifact.deterministic_tar(first, entries)
        artifact.deterministic_tar(second, entries)
        self.assertEqual(first.read_bytes(), second.read_bytes())

    def test_extract_checked_accepts_regular_file(self):
        archive = self.root / "valid.tar.gz"
        artifact.deterministic_tar(archive, [("dist/server.js", b"ok", 0o644)])
        destination = self.root / "out"
        names = artifact.extract_checked(archive, destination, max_bytes=1024, allowed=artifact.allowed_overlay)
        self.assertEqual(names, ["dist/server.js"])
        self.assertEqual((destination / "dist/server.js").read_text(), "ok")

    def test_rejects_malicious_members_and_nonempty_destination(self):
        cases = [
            ("absolute", self.regular("/etc/passwd")),
            ("traversal", self.regular("../escape")),
            ("backslash", self.regular(r"dist\escape")),
            ("world-writable", self.regular("dist/file", mode=0o666)),
        ]
        symlink = tarfile.TarInfo("dist/link")
        symlink.type = tarfile.SYMTYPE
        symlink.linkname = "/etc/passwd"
        cases.append(("symlink", (symlink, b"")))
        hardlink = tarfile.TarInfo("dist/hard")
        hardlink.type = tarfile.LNKTYPE
        hardlink.linkname = "dist/file"
        cases.append(("hardlink", (hardlink, b"")))
        fifo = tarfile.TarInfo("dist/fifo")
        fifo.type = tarfile.FIFOTYPE
        cases.append(("fifo", (fifo, b"")))
        device = tarfile.TarInfo("dist/device")
        device.type = tarfile.CHRTYPE
        cases.append(("device", (device, b"")))
        pax = tarfile.TarInfo("dist/pax")
        pax.pax_headers = {"path": "dist/other"}
        cases.append(("pax", (pax, b"x")))

        for label, entry in cases:
            with self.subTest(label=label):
                archive = self.root / f"{label}.tar.gz"
                self.write_tar(archive, [entry])
                with self.assertRaises(artifact.ArtifactError):
                    artifact.extract_checked(archive, self.root / f"out-{label}", max_bytes=1024)

        archive = self.root / "destination.tar.gz"
        artifact.deterministic_tar(archive, [("dist/a", b"a", 0o644)])
        destination = self.root / "not-empty"
        destination.mkdir()
        (destination / "existing").write_text("x")
        with self.assertRaises(artifact.ArtifactError):
            artifact.extract_checked(archive, destination, max_bytes=1024)

    def test_rejects_duplicates_case_collisions_unexpected_roots_and_long_paths(self):
        duplicate = self.root / "duplicate.tar.gz"
        self.write_tar(duplicate, [self.regular("dist/a"), self.regular("dist/a")])
        with self.assertRaises(artifact.ArtifactError):
            artifact.extract_checked(duplicate, self.root / "dupe-out", max_bytes=1024)

        collision = self.root / "collision.tar.gz"
        self.write_tar(collision, [self.regular("dist/a"), self.regular("DIST/A")])
        with self.assertRaises(artifact.ArtifactError):
            artifact.extract_checked(collision, self.root / "collision-out", max_bytes=1024)

        unexpected = self.root / "unexpected.tar.gz"
        artifact.deterministic_tar(unexpected, [("secrets/token", b"no", 0o600)])
        with self.assertRaises(artifact.ArtifactError):
            artifact.extract_checked(unexpected, self.root / "unexpected-out", max_bytes=1024, allowed=artifact.allowed_overlay)

        with self.assertRaises(artifact.ArtifactError):
            artifact.safe_name("a" * (artifact.MAX_PATH_BYTES + 1))

    def test_request_recomputes_patch_set_and_rejects_mode_type_policy_mismatch(self):
        request_root = self.root / "request"
        (request_root / "patches").mkdir(parents=True)
        package_path = request_root / "package.json.fixture"
        lock_path = request_root / "package-lock.json.fixture"
        self.write_package(package_path, self.package())
        lock_path.write_bytes(artifact.canonical_json({"lockfileVersion": 3, "packages": {}}))
        patch = request_root / "patches/0001-test.patch"
        patch.write_bytes(b"patch")
        patch_hash = artifact.sha256_file(patch)
        patches = [{
            "branch": "fix/test",
            "commit": "b" * 40,
            "baseCommit": "c" * 40,
            "file": "patches/0001-test.patch",
            "sha256": patch_hash,
        }]
        request = self.request("overlay", package_path, lock_path, patches=patches)
        (request_root / "request.json").write_bytes(artifact.canonical_json(request))
        index = {"files": [
            {"path": "patches/0001-test.patch", "sha256": patch_hash},
            {"path": "request.json", "sha256": artifact.sha256_file(request_root / "request.json")},
        ]}
        artifact.validate_request(request, index, request_root)

        mutations = [
            ("patchSetHash", "d" * 64),
            ("artifactType", artifact.ARTIFACT_TYPES["full-package"]),
            ("artifactPolicyHash", artifact.policy_hash("full-package")),
        ]
        for field, value in mutations:
            with self.subTest(field=field):
                bad = dict(request)
                bad[field] = value
                with self.assertRaises(artifact.ArtifactError):
                    artifact.validate_request(bad, index, request_root)
        legacy = dict(request)
        legacy["overlayPolicyHash"] = artifact.policy_hash("overlay")
        with self.assertRaises(artifact.ArtifactError):
            artifact.validate_request(legacy, index, request_root)

    def test_file_link_native_indexes_detect_tampering(self):
        payload = self.root / "payload"
        (payload / "package/node_modules/tool/bin").mkdir(parents=True)
        target = payload / "package/node_modules/tool/bin/cli.js"
        target.write_bytes(b"#!/usr/bin/env node\n")
        os.chmod(target, 0o755)
        file_entry = {
            "path": "package/node_modules/tool/bin/cli.js",
            "mode": 0o755,
            "size": target.stat().st_size,
            "sha256": artifact.sha256_file(target),
        }
        file_index = {"schemaVersion": artifact.INDEX_SCHEMA_VERSION, "files": [file_entry]}
        (payload / "payload-files.json").write_bytes(artifact.canonical_json(file_index))
        (payload / "payload-links.json").write_bytes(artifact.canonical_json({
            "schemaVersion": artifact.INDEX_SCHEMA_VERSION,
            "links": [{"path": "package/node_modules/.bin/tool", "target": "../tool/bin/cli.js"}],
        }))
        (payload / "payload-production-tree.json").write_bytes(artifact.canonical_json({
            "schemaVersion": artifact.INDEX_SCHEMA_VERSION, "packages": []
        }))
        (payload / "payload-native-files.json").write_bytes(artifact.canonical_json({
            "schemaVersion": artifact.INDEX_SCHEMA_VERSION, "files": []
        }))
        indexed = artifact.verify_file_index(payload)
        links = artifact.verify_link_index(payload, "full-package", indexed["entries"], materialize=True)
        self.assertEqual(links["count"], 1)
        self.assertTrue((payload / "package/node_modules/.bin/tool").is_symlink())
        self.assertEqual(os.readlink(payload / "package/node_modules/.bin/tool"), "../tool/bin/cli.js")

        target.write_text("tamper")
        with self.assertRaises(artifact.ArtifactError):
            artifact.verify_file_index(payload)

    def test_link_index_rejects_unsafe_targets_and_paths(self):
        root = self.root / "links"
        root.mkdir()
        files = {"package/node_modules/tool/bin/cli.js": {
            "path": "package/node_modules/tool/bin/cli.js", "mode": 0o755, "size": 1, "sha256": "a" * 64
        }}
        cases = [
            ("absolute", "package/node_modules/.bin/tool", "/etc/passwd"),
            ("escaping", "package/node_modules/.bin/tool", "../../../../etc/passwd"),
            ("dangling", "package/node_modules/.bin/tool", "../missing/bin.js"),
            ("outside-bin", "package/node_modules/tool/link", "bin/cli.js"),
            ("backslash", "package/node_modules/.bin/tool", r"..\tool\bin\cli.js"),
        ]
        for label, path, target in cases:
            with self.subTest(label=label):
                index = {"schemaVersion": artifact.INDEX_SCHEMA_VERSION, "links": [{"path": path, "target": target}]}
                (root / "payload-links.json").write_bytes(artifact.canonical_json(index))
                with self.assertRaises(artifact.ArtifactError):
                    artifact.verify_link_index(root, "full-package", files)

        (root / "payload-links.json").write_bytes(artifact.canonical_json({
            "schemaVersion": artifact.INDEX_SCHEMA_VERSION,
            "links": [{"path": "package/node_modules/.bin/tool", "target": "../tool/bin/cli.js"}],
        }))
        with self.assertRaises(artifact.ArtifactError):
            artifact.verify_link_index(root, "overlay", files)

    def test_production_tree_uses_exact_package_and_lock_closure(self):
        root = self.root / "tree"
        package = self.package({"fixture": "1.0.0", "playwright": "1.61.1"})
        self.write_package(root / "package/package.json", package)
        self.write_package(root / "package/node_modules/fixture/package.json", {"name": "fixture", "version": "1.0.0"})
        self.write_package(root / "package/node_modules/playwright/package.json", {"name": "playwright", "version": "1.61.1"})
        files = {}
        for name in (
            "package/package.json",
            "package/node_modules/fixture/package.json",
            "package/node_modules/playwright/package.json",
        ):
            path = root / name
            files[name] = {"path": name, "mode": 0o644, "size": path.stat().st_size, "sha256": artifact.sha256_file(path)}
        lock = {"lockfileVersion": 3, "packages": {
            "": {"dependencies": package["dependencies"], "optionalDependencies": {}},
            "node_modules/fixture": {"version": "1.0.0"},
            "node_modules/playwright": {"version": "1.61.1"},
            "node_modules/fumadocs-mdx": {"version": "15.0.7", "dev": True},
        }}
        tree = artifact.build_production_tree(root, files, lock)
        self.assertEqual([entry["name"] for entry in tree["packages"]], ["fixture", "playwright"])

        # Next standalone output copies traced dependencies below dist/node_modules,
        # while npm records their identity at node_modules/* in the source lock.
        # The physical payload path remains distinct, but it must resolve to that
        # exact lock entry rather than being rejected or accepted without provenance.
        self.write_package(
            root / "package/dist/node_modules/fixture/package.json",
            {"name": "fixture", "version": "1.0.0"},
        )
        standalone_name = "package/dist/node_modules/fixture/package.json"
        standalone_path = root / standalone_name
        standalone_files = dict(files)
        standalone_files[standalone_name] = {
            "path": standalone_name,
            "mode": 0o644,
            "size": standalone_path.stat().st_size,
            "sha256": artifact.sha256_file(standalone_path),
        }
        standalone_tree = artifact.build_production_tree(root, standalone_files, lock)
        self.assertEqual(
            [entry["path"] for entry in standalone_tree["packages"]],
            ["dist/node_modules/fixture", "node_modules/fixture", "node_modules/playwright"],
        )

        leaked = dict(files)
        self.write_package(root / "package/node_modules/fumadocs-mdx/package.json", {"name": "fumadocs-mdx", "version": "15.0.7"})
        path = root / "package/node_modules/fumadocs-mdx/package.json"
        name = "package/node_modules/fumadocs-mdx/package.json"
        leaked[name] = {"path": name, "mode": 0o644, "size": path.stat().st_size, "sha256": artifact.sha256_file(path)}
        with self.assertRaises(artifact.ArtifactError):
            artifact.build_production_tree(root, leaked, lock)

    def make_attested_response(self, mode="overlay"):
        target = "a" * 40
        patch_set = "b" * 64
        version = "3.8.49"
        source_digest = "c" * 40
        source_ref = f"refs/heads/deploy/artifact/{'d' * 64}"
        build_sha = f"source-{target[:12]}-patch-{patch_set[:12]}"
        package = self.package({"fixture": "1.0.0"} if mode == "overlay" else {"fixture": "2.0.0"})
        source = self.root / f"source-{mode}"
        (source / "dist").mkdir(parents=True)
        (source / "bin").mkdir()
        (source / "dist/server.js").write_text("server")
        (source / "dist/BUILD_SHA").write_text(build_sha + "\n")
        (source / "bin/omniroute.mjs").write_text("#!/usr/bin/env node\n")
        os.chmod(source / "bin/omniroute.mjs", 0o755)
        self.write_package(source / "package.json", package)
        lock = {"lockfileVersion": 3, "packages": {
            "": {"dependencies": package["dependencies"], "optionalDependencies": {}},
            "node_modules/fixture": {"version": package["dependencies"]["fixture"]},
        }}
        lock_path = self.root / f"source-lock-{mode}.json"
        lock_path.write_bytes(artifact.canonical_json(lock))
        request = self.request(mode, source / "package.json", lock_path)
        request["patchSetHash"] = patch_set
        request["buildSha"] = build_sha
        request_path = self.root / f"request-{mode}.json"
        request_path.write_bytes(artifact.canonical_json(request))

        payload = self.root / f"payload-{mode}.tar.gz"
        file_index = self.root / f"payload-files-{mode}.json"
        links_index = self.root / f"payload-links-{mode}.json"
        production_index = self.root / f"payload-production-{mode}.json"
        native_index = self.root / f"payload-native-{mode}.json"
        if mode == "full-package":
            (source / "node_modules/fixture").mkdir(parents=True)
            self.write_package(source / "node_modules/fixture/package.json", {"name": "fixture", "version": "2.0.0"})
        artifact.command_create_payload(type("Args", (), {
            "mode": mode,
            "source": str(source),
            "source_lock": str(lock_path) if mode == "full-package" else None,
            "source_package": str(source / "package.json") if mode == "full-package" else None,
            "output": str(payload),
            "index_output": str(file_index),
            "links_output": str(links_index),
            "production_tree_output": str(production_index),
            "native_index_output": str(native_index),
        })())
        index = json.loads(file_index.read_bytes())
        links = json.loads(links_index.read_bytes())
        production = json.loads(production_index.read_bytes())
        native = json.loads(native_index.read_bytes())
        manifest = {
            "schemaVersion": artifact.ARTIFACT_SCHEMA_VERSION,
            "artifactMode": mode,
            "artifactType": artifact.ARTIFACT_TYPES[mode],
            "artifactPolicyHash": artifact.policy_hash(mode),
            "repository": artifact.REPOSITORY,
            "requestSha256": artifact.sha256_file(request_path),
            "targetRef": request["targetRef"],
            "targetCommit": target,
            "version": version,
            "patchSetHash": patch_set,
            "patches": [],
            "appliedPatches": [],
            "skippedUpstreamedPatches": [],
            "sourcePackageSha256": request["sourcePackageSha256"],
            "sourceLockSha256": request["sourceLockSha256"],
            "dependencyFingerprint": request["dependencyFingerprint"],
            "buildSha": build_sha,
            "buildBundler": "turbopack",
            "runtime": self.runtime(),
            "payloadSha256": artifact.sha256_file(payload),
            "fileIndexSha256": artifact.sha256_file(file_index),
            "linkIndexSha256": artifact.sha256_file(links_index),
            "productionTreeSha256": artifact.sha256_file(production_index),
            "nativeIndexSha256": artifact.sha256_file(native_index),
            "payloadEntryCount": len(index["files"]),
            "payloadUnpackedBytes": sum(entry["size"] for entry in index["files"]),
            "payloadLinkCount": len(links["links"]),
            "productionPackageCount": len(production["packages"]),
            "nativeFileCount": len(native["files"]),
            "builder": {
                "repository": artifact.DEFAULT_BUILDER_REPOSITORY,
                "workflow": artifact.DEFAULT_BUILDER_WORKFLOW,
                "ref": source_ref,
                "sourceDigest": source_digest,
                "runId": 12345,
                "runAttempt": 1,
                "runnerEnvironment": "github-hosted",
            },
            "createdAt": "2026-07-20T00:00:00Z",
        }
        manifest_path = self.root / f"artifact-manifest-{mode}.json"
        manifest_path.write_bytes(artifact.canonical_json(manifest))
        response = self.root / f"response-{mode}.tar.gz"
        artifact.command_create_response(type("Args", (), {
            "manifest": str(manifest_path), "payload": str(payload), "output": str(response)
        })())
        fingerprint = self.root / f"fingerprint-{mode}.json"
        fingerprint.write_bytes(artifact.canonical_json(self.runtime()))
        installed = self.root / f"installed-{mode}.json"
        installed_package = package if mode == "overlay" else self.package({"fixture": "1.0.0"})
        self.write_package(installed, installed_package)
        return {
            "mode": mode,
            "target": target,
            "patch_set": patch_set,
            "version": version,
            "request": request_path,
            "response": response,
            "manifest": manifest_path,
            "payload": payload,
            "artifact_id": artifact.sha256_file(response),
            "manifest_id": artifact.sha256_file(manifest_path),
            "fingerprint": fingerprint,
            "installed_package": installed,
            "source_digest": source_digest,
            "source_ref": source_ref,
        }

    def verify_fixture(self, fixture, destination, **overrides):
        values = {
            "archive": str(fixture["response"]),
            "request": str(fixture["request"]),
            "expect_artifact": fixture["artifact_id"],
            "expect_manifest": fixture["manifest_id"],
            "expect_target": fixture["target"],
            "expect_target_ref": "upstream/release/v3.8.49",
            "expect_patch_set": fixture["patch_set"],
            "expect_version": fixture["version"],
            "expect_builder_repository": artifact.DEFAULT_BUILDER_REPOSITORY,
            "expect_workflow": artifact.DEFAULT_BUILDER_WORKFLOW,
            "expect_source_ref": fixture["source_ref"],
            "expect_source_digest": fixture["source_digest"],
            "expect_run_id": 12345,
            "expect_run_attempt": 1,
            "fingerprint": str(fixture["fingerprint"]),
            "installed_package": str(fixture["installed_package"]),
            "destination": str(destination),
        }
        values.update(overrides)
        artifact.command_verify_response(type("Args", (), values)())

    def test_complete_attested_overlay_and_full_package_responses(self):
        for mode in ("overlay", "full-package"):
            with self.subTest(mode=mode):
                fixture = self.make_attested_response(mode)
                destination = self.root / f"verified-{mode}"
                self.verify_fixture(fixture, destination)
                prefix = destination if mode == "overlay" else destination / "package"
                self.assertEqual((prefix / "dist/BUILD_SHA").read_text().strip(), f"source-{'a' * 12}-patch-{'b' * 12}")
                if mode == "full-package":
                    self.assertEqual((prefix / "node_modules/fixture/package.json").is_file(), True)

    def test_pin_builder_runtime_and_lane_mismatches_fail(self):
        fixture = self.make_attested_response("overlay")
        for field, value in (
            ("expect_artifact", "e" * 64),
            ("expect_manifest", "f" * 64),
            ("expect_target", "d" * 40),
            ("expect_target_ref", "upstream/release/v9.9.9"),
            ("expect_patch_set", "e" * 64),
            ("expect_version", "9.9.9"),
            ("expect_builder_repository", "attacker/OmniRoute"),
            ("expect_workflow", ".github/workflows/other.yml"),
            ("expect_source_ref", "refs/heads/main"),
            ("expect_source_digest", "f" * 40),
            ("expect_run_id", 999),
            ("expect_run_attempt", 2),
        ):
            with self.subTest(field=field):
                with self.assertRaises(artifact.ArtifactError):
                    self.verify_fixture(fixture, self.root / f"bad-{field}", **{field: value})

        bad_runtime = self.root / "bad-runtime.json"
        runtime = json.loads(fixture["fingerprint"].read_bytes())
        runtime["modulesAbi"] = "999"
        bad_runtime.write_bytes(artifact.canonical_json(runtime))
        with self.assertRaises(artifact.ArtifactError):
            self.verify_fixture(fixture, self.root / "bad-runtime", fingerprint=str(bad_runtime))

        bad_package = self.root / "bad-package.json"
        self.write_package(bad_package, self.package({"fixture": "2.0.0"}))
        with self.assertRaises(artifact.ArtifactError):
            self.verify_fixture(fixture, self.root / "wrong-overlay-lane", installed_package=str(bad_package))

        full = self.make_attested_response("full-package")
        matching = self.root / "matching-full.json"
        self.write_package(matching, self.package({"fixture": "2.0.0"}))
        with self.assertRaises(artifact.ArtifactError):
            self.verify_fixture(full, self.root / "wrong-full-lane", installed_package=str(matching))

    def test_tampered_file_link_tree_native_and_response_fail(self):
        fixture = self.make_attested_response("full-package")
        outer = self.root / "outer"
        artifact.extract_outer(fixture["response"], outer)
        extracted = self.root / "payload-extracted"
        artifact.extract_checked(outer / "payload.tar.gz", extracted, max_bytes=artifact.MAX_PAYLOAD_BYTES, allowed=artifact.allowed_full_package)
        for filename in (
            "payload-files.json",
            "payload-links.json",
            "payload-production-tree.json",
            "payload-native-files.json",
        ):
            with self.subTest(filename=filename):
                destination = self.root / f"tamper-{filename}"
                destination.mkdir()
                for path in extracted.iterdir():
                    if path.is_dir():
                        import shutil
                        shutil.copytree(path, destination / path.name)
                    else:
                        (destination / path.name).write_bytes(path.read_bytes())
                value = json.loads((destination / filename).read_bytes())
                key = "links" if "links" in value else "packages" if "packages" in value else "files"
                value[key].append(value[key][0] if value[key] else {"path": "invalid"})
                (destination / filename).write_bytes(artifact.canonical_json(value))
                with self.assertRaises(artifact.ArtifactError):
                    indexed = artifact.verify_file_index(destination)
                    artifact.verify_link_index(destination, "full-package", indexed["entries"])
                    artifact.verify_native_index(destination, indexed["entries"])
                    lock, _ = artifact.read_json(destination / "payload-source-lock.json")
                    artifact.verify_production_tree(destination, "full-package", indexed["entries"], lock)

        tampered = self.root / "tampered-response.tar.gz"
        manifest = json.loads(fixture["manifest"].read_bytes())
        manifest["buildBundler"] = "other"
        artifact.deterministic_tar(tampered, [
            ("artifact-manifest.json", artifact.canonical_json(manifest), 0o644),
            ("payload.tar.gz", fixture["payload"], 0o644),
        ])
        with self.assertRaises(artifact.ArtifactError):
            self.verify_fixture(fixture, self.root / "tampered-response", archive=str(tampered))


if __name__ == "__main__":
    unittest.main()
