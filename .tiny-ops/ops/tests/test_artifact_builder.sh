#!/usr/bin/env bash
set -euo pipefail

readonly OPS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly BUILDER="$OPS_DIR/artifact-builder.sh"

fail() { printf 'not ok - %s\n' "$*" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$*"; }

bash -n "$BUILDER" || fail "builder syntax"
grep -Fq 'builder must run in GitHub Actions' "$BUILDER" || fail "builder lacks GitHub Actions guard"
grep -Fq 'builder requires a GitHub-hosted runner' "$BUILDER" || fail "builder lacks hosted-runner guard"
grep -Fq 'OMNIROUTE_USE_TURBOPACK=0' "$BUILDER" || fail "builder does not force the bounded-memory Webpack lane"
grep -Fq 'restore_next_cache' "$BUILDER" || fail "builder does not restore the Next.js build cache"
grep -Fq 'save_next_cache' "$BUILDER" || fail "builder does not preserve the Next.js build cache"
grep -Fq 'readonly BUILD_MEMORY_MB="${OMNIROUTE_BUILD_MEMORY_MB:-6144}"' "$BUILDER" \
  || fail "builder does not reserve hosted-runner memory outside the Webpack heap"
grep -Fq '$SOURCE_TREE/.build/next/cache' "$BUILDER" \
  || fail "builder cache path does not match OmniRoute NEXT_DIST_DIR"
! grep -Fq '$SOURCE_TREE/.next/cache' "$BUILDER" \
  || fail "builder retains the unused default Next.js cache path"
grep -Fq 'npm run check:dashboard-typecheck' "$BUILDER" || fail "builder omits dashboard typecheck gate"
grep -Fq 'run_typecheck_regression_gate' "$BUILDER" \
  || fail "builder does not compare target and candidate typecheck diagnostics"
grep -Fq 'comm -13 "$baseline_signatures" "$candidate_signatures"' "$BUILDER" \
  || fail "typecheck baseline gate does not reject newly introduced diagnostics"
grep -Fq 'npm ci --omit=dev --ignore-scripts --legacy-peer-deps --no-audit --no-fund' "$BUILDER" \
  || fail "full-package production install does not preserve the reviewed lockfile resolver contract"
grep -Fq 'materialize_workspace' "$BUILDER" || fail "builder does not materialize workspace packages"
grep -Fq 'copy_scoped_runtime_packages' "$BUILDER" \
  || fail "builder does not constrain scoped packages to declared runtime files"
grep -Fq 'prune_full_package_development_residue' "$BUILDER" \
  || fail "builder does not prune root-package test residue"
grep -Fq 'remove_standalone_dependency_duplicates' "$BUILDER" \
  || fail "builder retains the development standalone dependency duplicate"
grep -Fq 'validate_dlopen' "$BUILDER" || fail "builder does not explicitly validate native binaries"
grep -Fq 'wreq-js.linux-x64-gnu.node' "$BUILDER" \
  || fail "builder does not recognize the current wreq-js Linux GNU binary name"
grep -Fq 'wreq-js.linux-x64.node' "$BUILDER" \
  || fail "builder dropped compatibility with the legacy wreq-js binary name"
for forbidden in OMNIROUTE_BUILDER_CGROUP SIGN_HELPER 'sudo -n' artifact-manifest.json.sig \
  'npm rebuild' 'node-pre-gyp install'; do
  ! grep -Fq "$forbidden" "$BUILDER" || fail "builder retains forbidden VM/signing/fallback path: $forbidden"
done
grep -Fq -- '--arg buildBundler webpack' "$BUILDER" \
  || fail "builder manifest does not bind the reviewed Webpack lane"
pass "builder is hosted-only and contains fail-closed full-package assembly"

if OMNIROUTE_ARTIFACT_FORMAT_TOOL=/bin/true OMNIROUTE_BUILDER_WORK_ROOT=/tmp/omniroute-builder-never \
  "$BUILDER" </dev/null >/dev/null 2>"${TMPDIR:-/tmp}/omniroute-builder-direct.err"; then
  fail "direct builder execution unexpectedly succeeded"
fi
grep -Fq 'builder must run in GitHub Actions' "${TMPDIR:-/tmp}/omniroute-builder-direct.err" \
  || fail "direct builder execution did not fail at GitHub Actions guard"
rm -f "${TMPDIR:-/tmp}/omniroute-builder-direct.err"
pass "direct heavy execution fails closed"

fixture="$(mktemp -d "${TMPDIR:-/tmp}/omniroute-builder-fixture.XXXXXX")"
trap 'rm -rf -- "$fixture"' EXIT
repository="$fixture/repository"
mock_bin="$fixture/bin"
work_root="$fixture/work"
mkdir -p "$repository" "$mock_bin" "$work_root"

git -C "$repository" init -q
git -C "$repository" config user.name fixture
git -C "$repository" config user.email fixture@example.invalid
cat >"$repository/package.json" <<'JSON'
{
  "dependencies": {"fixture": "1.0.0"},
  "devDependencies": {"fumadocs-mdx": "1.0.0"},
  "engines": {"node": ">=22"},
  "files": ["bin/", "dist/", "@omniroute/", "open-sse/", "src/", "README.md", "LICENSE"],
  "name": "omniroute",
  "optionalDependencies": {},
  "scripts": {},
  "version": "3.8.49",
  "workspaces": ["open-sse"]
}
JSON
cat >"$repository/package-lock.json" <<'JSON'
{
  "name": "omniroute",
  "lockfileVersion": 3,
  "packages": {
    "": {
      "name": "omniroute",
      "version": "3.8.49",
      "dependencies": {"fixture": "1.0.0"},
      "devDependencies": {"fumadocs-mdx": "1.0.0"},
      "engines": {"node": ">=22"},
      "optionalDependencies": {},
      "workspaces": ["open-sse"]
    },
    "node_modules/@omniroute/open-sse": {"link": true, "resolved": "open-sse"},
    "node_modules/fixture": {"version": "1.0.0"},
    "node_modules/fumadocs-mdx": {"dev": true, "version": "1.0.0"},
    "open-sse": {"name": "@omniroute/open-sse", "version": "3.8.49"}
  }
}
JSON
printf 'base\n' >"$repository/README.md"
printf 'fixture license\n' >"$repository/LICENSE"
printf 'must not ship\n' >"$repository/UNRELATED.md"
mkdir -p "$repository/open-sse/__tests__" "$repository/src/lib/__tests__" \
  "$repository/@omniroute/opencode-plugin/src" \
  "$repository/@omniroute/opencode-plugin/tests" \
  "$repository/scripts/build"
cat >"$repository/open-sse/package.json" <<'JSON'
{"name":"@omniroute/open-sse","version":"3.8.49"}
JSON
printf 'must not ship\n' >"$repository/open-sse/__tests__/runtime.test.ts"
printf 'must not ship\n' >"$repository/src/lib/__tests__/runtime.spec.ts"
cat >"$repository/@omniroute/opencode-plugin/package.json" <<'JSON'
{"name":"@omniroute/opencode-plugin","version":"0.2.0","files":["dist","README.md","LICENSE"]}
JSON
printf 'fixture plugin\n' >"$repository/@omniroute/opencode-plugin/README.md"
printf 'fixture plugin license\n' >"$repository/@omniroute/opencode-plugin/LICENSE"
printf 'must not ship\n' >"$repository/@omniroute/opencode-plugin/src/index.ts"
printf 'must not ship\n' >"$repository/@omniroute/opencode-plugin/tests/features.test.ts"
cat >"$repository/scripts/build/write-build-sha.mjs" <<'NODE'
import fs from "node:fs";
fs.mkdirSync("dist", { recursive: true });
fs.writeFileSync("dist/BUILD_SHA", `${process.env.OMNIROUTE_BUILD_SHA}\n`);
NODE
git -C "$repository" add .
git -C "$repository" commit -qm 'fixture target'
target="$(git -C "$repository" rev-parse HEAD)"
printf 'patched\n' >>"$repository/README.md"
patch_template="$fixture/fixture.patch"
git -C "$repository" diff --binary "$target" -- README.md >"$patch_template"
git -C "$repository" checkout -q -- README.md
patch_sha="$(sha256sum "$patch_template" | cut -d ' ' -f 1)"
patch_commit="$(printf 'f%.0s' {1..40})"
patch_set="$(printf 'fix/fixture:%s:%s\n' "$patch_commit" "$patch_sha" | sha256sum | cut -d ' ' -f 1)"
runtime="$($OPS_DIR/artifact-format.py fingerprint --npm-version 10.9.8)"
build_sha="source-${target:0:12}-patch-${patch_set:0:12}"
source_package_sha="$(sha256sum "$repository/package.json" | cut -d ' ' -f 1)"
source_lock_sha="$(sha256sum "$repository/package-lock.json" | cut -d ' ' -f 1)"
dependency_fingerprint="$($OPS_DIR/artifact-format.py dependency-fingerprint --package "$repository/package.json")"

cat >"$fixture/installed-old-package.json" <<'JSON'
{"dependencies":{"fixture":"0.9.0"},"engines":{"node":">=22"},"optionalDependencies":{}}
JSON

make_request() {
  local mode="$1"
  local request_dir="$fixture/request-$mode"
  local artifact_type policy_hash request_sha
  mkdir -p "$request_dir/patches"
  cp -- "$patch_template" "$request_dir/patches/0001-fix-fixture.patch"
  if [ "$mode" = "overlay" ]; then
    artifact_type=omniroute-runtime-overlay
  else
    artifact_type=omniroute-full-package
  fi
  policy_hash="$($OPS_DIR/artifact-format.py policy --mode "$mode" | jq -r '.policyHash')"
  jq -n \
    --argjson schemaVersion 2 --arg requestType omniroute-build-request \
    --arg artifactMode "$mode" --arg artifactType "$artifact_type" \
    --arg artifactPolicyHash "$policy_hash" \
    --arg repository diegosouzapw/OmniRoute --arg targetRef upstream/release/v3.8.49 \
    --arg targetCommit "$target" --arg version 3.8.49 --arg patchSetHash "$patch_set" \
    --arg buildSha "$build_sha" --arg sourcePackageSha256 "$source_package_sha" \
    --arg sourceLockSha256 "$source_lock_sha" \
    --arg createdAt 2026-07-20T00:00:00Z --arg nonce "fixture-$mode" \
    --argjson runtime "$runtime" --argjson dependencyFingerprint "$dependency_fingerprint" \
    --arg branch fix/fixture --arg commit "$patch_commit" --arg baseCommit "$target" \
    --arg file patches/0001-fix-fixture.patch --arg sha256 "$patch_sha" \
    '{schemaVersion:$schemaVersion,requestType:$requestType,artifactMode:$artifactMode,artifactType:$artifactType,artifactPolicyHash:$artifactPolicyHash,repository:$repository,targetRef:$targetRef,targetCommit:$targetCommit,version:$version,patchSetHash:$patchSetHash,buildSha:$buildSha,sourcePackageSha256:$sourcePackageSha256,sourceLockSha256:$sourceLockSha256,dependencyFingerprint:$dependencyFingerprint,createdAt:$createdAt,nonce:$nonce,runtime:$runtime,patches:[{branch:$branch,commit:$commit,baseCommit:$baseCommit,file:$file,sha256:$sha256}]}' \
    >"$request_dir/request.tmp.json"
  "$OPS_DIR/artifact-format.py" canonicalize \
    --input "$request_dir/request.tmp.json" --output "$request_dir/request.json"
  request_sha="$(sha256sum "$request_dir/request.json" | cut -d ' ' -f 1)"
  jq -n --argjson schemaVersion 2 \
    --arg requestPath request.json --arg requestSha "$request_sha" \
    --arg patchPath patches/0001-fix-fixture.patch --arg patchSha "$patch_sha" \
    '{schemaVersion:$schemaVersion,files:[{path:$patchPath,sha256:$patchSha},{path:$requestPath,sha256:$requestSha}]}' \
    >"$request_dir/request-files.tmp.json"
  "$OPS_DIR/artifact-format.py" canonicalize \
    --input "$request_dir/request-files.tmp.json" --output "$request_dir/request-files.json"
  "$OPS_DIR/artifact-format.py" pack-request \
    --directory "$request_dir" --output "$fixture/request-$mode.tar.gz"
}

make_request overlay
make_request full-package
[ "$(sha256sum "$fixture/request-overlay/request.json" | cut -d ' ' -f 1)" != \
  "$(sha256sum "$fixture/request-full-package/request.json" | cut -d ' ' -f 1)" ] \
  || fail "artifact mode does not change canonical request identity"

cat >"$mock_bin/npm" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\t%s\n' "$PWD" "$*" >>"$OMNIROUTE_FIXTURE_NPM_LOG"
case "${1:-}" in
  --version) printf '10.9.8\n' ;;
  ci)
    if [[ "$PWD" == */package-stage ]]; then
      mkdir -p node_modules/fixture node_modules/@omniroute node_modules/.bin
      cat >node_modules/fixture/package.json <<'JSON'
{"name":"fixture","version":"1.0.0","main":"index.js","bin":{"fixture":"cli.js"}}
JSON
      printf 'module.exports = "fixture runtime";\n' >node_modules/fixture/index.js
      printf '#!/usr/bin/env node\n' >node_modules/fixture/cli.js
      chmod 0755 node_modules/fixture/cli.js
      ln -s ../fixture/cli.js node_modules/.bin/fixture
      ln -s ../../../open-sse node_modules/@omniroute/open-sse
    fi
    ;;
  run)
    case "${2:-}" in
      check:build-scope|typecheck:core|check:dashboard-typecheck) ;;
      build:release)
        mkdir -p dist/node_modules/dev-only bin/cli/runtime @omniroute/opencode-plugin/dist
        printf 'fixture server\n' >dist/server.js
        printf '{"name":"dev-only","version":"1.0.0"}\n' \
          >dist/node_modules/dev-only/package.json
        printf '#!/usr/bin/env node\n' >bin/omniroute.mjs
        printf 'fixture runtime\n' >bin/cli/runtime/entry.mjs
        printf 'fixture plugin runtime\n' >@omniroute/opencode-plugin/dist/index.js
        chmod 0755 bin/omniroute.mjs
        ;;
      *) exit 2 ;;
    esac
    ;;
  *) exit 2 ;;
esac
SH
chmod 0755 "$mock_bin/npm"
source_digest="$(printf 'c%.0s' {1..40})"
run_id=12345
run_attempt=1

run_mode() {
  local mode="$1"
  local source_ref="refs/heads/deploy/integration"
  local installed="$repository/package.json"
  [ "$mode" = "overlay" ] || installed="$fixture/installed-old-package.json"
  : >"$fixture/npm-$mode.log"
  PATH="$mock_bin:$PATH" \
  GITHUB_ACTIONS=true RUNNER_ENVIRONMENT=github-hosted RUNNER_OS=Linux \
  GITHUB_REPOSITORY=nguyenha935/OmniRoute GITHUB_REF="$source_ref" GITHUB_SHA="$source_digest" \
  GITHUB_RUN_ID="$run_id" GITHUB_RUN_ATTEMPT="$run_attempt" \
  OMNIROUTE_FIXTURE_NPM_LOG="$fixture/npm-$mode.log" \
  OMNIROUTE_ARTIFACT_FORMAT_TOOL="$OPS_DIR/artifact-format.py" \
  OMNIROUTE_BUILDER_WORK_ROOT="$work_root" OMNIROUTE_REPOSITORY_URL="$repository" \
    "$BUILDER" <"$fixture/request-$mode.tar.gz" \
    >"$fixture/response-$mode.tar.gz" 2>"$fixture/builder-$mode.log" \
    || { perl -ne 'print if $. <= 240' "$fixture/builder-$mode.log" >&2; fail "$mode hosted builder fixture"; }

  local inspection artifact_id manifest_id
  inspection="$($OPS_DIR/artifact-format.py artifact-id \
    --archive "$fixture/response-$mode.tar.gz" --request "$fixture/request-$mode/request.json")"
  artifact_id="$(jq -r '.artifactId' <<<"$inspection")"
  manifest_id="$(jq -r '.manifestSha256' <<<"$inspection")"
  printf '%s\n' "$runtime" >"$fixture/runtime-fingerprint.json"
  "$OPS_DIR/artifact-format.py" verify-response \
    --archive "$fixture/response-$mode.tar.gz" --request "$fixture/request-$mode/request.json" \
    --expect-artifact "$artifact_id" --expect-manifest "$manifest_id" \
    --expect-target "$target" --expect-target-ref upstream/release/v3.8.49 \
    --expect-patch-set "$patch_set" --expect-version 3.8.49 \
    --expect-builder-repository nguyenha935/OmniRoute \
    --expect-workflow .github/workflows/omniroute-patch-artifact.yml \
    --expect-source-ref "$source_ref" --expect-source-digest "$source_digest" \
    --expect-run-id "$run_id" --expect-run-attempt "$run_attempt" \
    --fingerprint "$fixture/runtime-fingerprint.json" --installed-package "$installed" \
    --destination "$fixture/verified-$mode" >"$fixture/verified-$mode.json"
  jq -e --arg mode "$mode" \
    '.artifactMode == $mode and .manifest.artifactMode == $mode and .manifest.appliedPatches == ["fix/fixture"] and .manifest.skippedUpstreamedPatches == [] and .manifest.builder.runnerEnvironment == "github-hosted"' \
    "$fixture/verified-$mode.json" >/dev/null || fail "$mode manifest identity/provenance result"
}

run_mode overlay
grep -Fqx patched "$fixture/verified-overlay/README.md" || fail "verified overlay lacks applied patch"
[ "$(<"$fixture/verified-overlay/dist/BUILD_SHA")" = "$build_sha" ] || fail "verified overlay BUILD_SHA"
[ "$(grep -c $'\tci --no-audit --no-fund$' "$fixture/npm-overlay.log")" -eq 1 ] \
  || fail "overlay did not run exactly one hosted development install"
! grep -Fq -- '--omit=dev' "$fixture/npm-overlay.log" || fail "overlay unexpectedly ran production prune"
pass "overlay request builds and verifies with dependency-match semantics"

run_mode full-package
full_root="$fixture/verified-full-package/package"
grep -Fqx patched "$full_root/README.md" || fail "full package lacks applied patch"
[ "$(<"$full_root/dist/BUILD_SHA")" = "$build_sha" ] || fail "full package BUILD_SHA"
[ -f "$full_root/node_modules/fixture/package.json" ] || fail "full package lacks production dependency"
[ -f "$full_root/node_modules/@omniroute/open-sse/package.json" ] || fail "workspace was not materialized"
[ ! -L "$full_root/node_modules/@omniroute/open-sse" ] || fail "workspace remains a symlink"
[ -L "$full_root/node_modules/.bin/fixture" ] || fail "verified npm .bin link was not reconstructed"
[ "$(readlink "$full_root/node_modules/.bin/fixture")" = '../fixture/cli.js' ] \
  || fail "reconstructed npm .bin link target differs"
[ -d "$full_root/bin/cli/runtime" ] || fail "full package omits bin/cli/runtime"
[ -f "$full_root/@omniroute/opencode-plugin/dist/index.js" ] \
  || fail "full package omits bundled OpenCode plugin runtime"
[ -f "$full_root/@omniroute/opencode-plugin/package.json" ] \
  || fail "full package omits bundled OpenCode plugin metadata"
[ ! -e "$full_root/@omniroute/opencode-plugin/tests/features.test.ts" ] \
  || fail "scoped package tests leaked into the full package"
[ ! -e "$full_root/@omniroute/opencode-plugin/src/index.ts" ] \
  || fail "scoped package development source leaked into the full package"
[ ! -e "$full_root/open-sse/__tests__/runtime.test.ts" ] \
  || fail "open-sse test residue leaked into the full package"
[ ! -e "$full_root/src/lib/__tests__/runtime.spec.ts" ] \
  || fail "root source test residue leaked into the full package"
[ ! -e "$full_root/dist/node_modules" ] \
  || fail "development standalone dependency duplicate leaked into the full package"
resolved_fixture="$(node --input-type=commonjs - "$full_root" <<'NODE'
const path = require("node:path");
const { createRequire } = require("node:module");
const root = process.argv[2];
process.stdout.write(createRequire(path.join(root, "dist/server.js")).resolve("fixture"));
NODE
)"
[ "$resolved_fixture" = "$full_root/node_modules/fixture/index.js" ] \
  || fail "standalone runtime cannot resolve from the production root"
[ ! -e "$full_root/node_modules/fumadocs-mdx" ] || fail "dev-only fumadocs-mdx leaked"
[ ! -e "$full_root/package-lock.json" ] || fail "source lock leaked into runtime package"
[ ! -e "$full_root/UNRELATED.md" ] || fail "unapproved root file leaked into runtime package"
grep -Fq $'\tci --omit=dev --ignore-scripts --legacy-peer-deps --no-audit --no-fund' "$fixture/npm-full-package.log" \
  || fail "full package omitted hosted production prune"
[ "$(grep -c $'\tci ' "$fixture/npm-full-package.log")" -eq 2 ] \
  || fail "full package did not use exactly one development and one production install"
pass "full package is independent, pruned, link-indexed, and request-bound"

printf '1..4\n'
