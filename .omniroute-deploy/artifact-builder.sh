#!/usr/bin/env bash
set -euo pipefail

readonly LOG_TAG="[omniroute-builder]"
readonly FORMAT_TOOL="${OMNIROUTE_ARTIFACT_FORMAT_TOOL:-${GITHUB_WORKSPACE:-}/.omniroute-deploy/artifact-format.py}"
readonly WORK_ROOT="${OMNIROUTE_BUILDER_WORK_ROOT:-${RUNNER_TEMP:-}/omniroute-builder}"
readonly REPOSITORY_URL="${OMNIROUTE_REPOSITORY_URL:-https://github.com/diegosouzapw/OmniRoute.git}"
readonly BUILD_MEMORY_MB="${OMNIROUTE_BUILD_MEMORY_MB:-14336}"
readonly BUILDER_REPOSITORY="${GITHUB_REPOSITORY:-}"
readonly BUILDER_WORKFLOW="${OMNIROUTE_GITHUB_WORKFLOW:-.github/workflows/omniroute-patch-artifact.yml}"
readonly BUILDER_REF="${GITHUB_REF:-}"
readonly BUILDER_SOURCE_DIGEST="${GITHUB_SHA:-}"
readonly BUILDER_RUN_ID="${GITHUB_RUN_ID:-}"
readonly BUILDER_RUN_ATTEMPT="${GITHUB_RUN_ATTEMPT:-}"
readonly RUNNER_ENVIRONMENT_VALUE="${RUNNER_ENVIRONMENT:-}"

log() { printf '%s %s\n' "$LOG_TAG" "$*" >&2; }
die() { printf '%s ERROR: %s\n' "$LOG_TAG" "$*" >&2; exit 20; }

cleanup() {
  local exit_code=$?
  [ -z "${WORKSPACE:-}" ] || rm -rf -- "$WORKSPACE"
  return "$exit_code"
}

repair_known_runtime_timeout_sidecar() {
  local tree="$1"
  local wrapper="$tree/dist/server-ws.mjs"
  local source_import='from "../../src/shared/utils/runtimeTimeouts.ts"'
  local bundled_import='from "./runtime-timeouts.mjs"'
  [ -f "$wrapper" ] || return 0
  grep -Fq "$source_import" "$wrapper" || return 0
  log "repairing known runtime-timeout sidecar packaging defect"
  "$tree/node_modules/.bin/esbuild" \
    "$tree/src/shared/utils/runtimeTimeouts.ts" \
    --bundle --platform=node --format=esm \
    --outfile="$tree/dist/runtime-timeouts.mjs" >&2
  node --input-type=module - "$wrapper" "$source_import" "$bundled_import" <<'NODE'
import fs from "node:fs";
const [file, sourceImport, bundledImport] = process.argv.slice(2);
const source = fs.readFileSync(file, "utf8");
if (!source.includes(sourceImport)) process.exit(2);
fs.writeFileSync(file, source.replace(sourceImport, bundledImport));
NODE
}

[ "${GITHUB_ACTIONS:-}" = "true" ] || die "builder must run in GitHub Actions"
[ "$RUNNER_ENVIRONMENT_VALUE" = "github-hosted" ] || die "builder requires a GitHub-hosted runner"
[ "${RUNNER_OS:-}" = "Linux" ] || die "builder requires a Linux runner"
[ "$BUILDER_REPOSITORY" = "nguyenha935/OmniRoute" ] || die "unexpected GitHub repository"
[[ "$BUILDER_REF" =~ ^refs/heads/deploy/artifact/[0-9a-f]{16,64}$ ]] || die "unexpected deployment ref"
[[ "$BUILDER_SOURCE_DIGEST" =~ ^[0-9a-f]{40}$ ]] || die "invalid GitHub source digest"
[[ "$BUILDER_RUN_ID" =~ ^[1-9][0-9]*$ ]] || die "invalid GitHub run ID"
[[ "$BUILDER_RUN_ATTEMPT" =~ ^[1-9][0-9]*$ ]] || die "invalid GitHub run attempt"
[ -x "$FORMAT_TOOL" ] || die "artifact format tool is unavailable"
[ -n "$WORK_ROOT" ] || die "GitHub runner temporary directory is unavailable"
mkdir -p "$WORK_ROOT"
WORKSPACE="$(mktemp -d "$WORK_ROOT/request.XXXXXX")"
trap cleanup EXIT INT TERM HUP
chmod 0700 "$WORKSPACE"

readonly REQUEST_ARCHIVE="$WORKSPACE/request.tar.gz"
readonly REQUEST_DIR="$WORKSPACE/request"
readonly SOURCE_TREE="$WORKSPACE/source"
readonly PAYLOAD="$WORKSPACE/payload.tar.gz"
readonly FILE_INDEX="$WORKSPACE/payload-files.json"
readonly MANIFEST="$WORKSPACE/artifact-manifest.json"
readonly RESPONSE="$WORKSPACE/response.tar.gz"

cat >"$REQUEST_ARCHIVE"
mkdir -p "$REQUEST_DIR"
request_sha="$($FORMAT_TOOL extract-request --archive "$REQUEST_ARCHIVE" --destination "$REQUEST_DIR")"
request="$REQUEST_DIR/request.json"
target="$(jq -r '.targetCommit' "$request")"
target_ref="$(jq -r '.targetRef' "$request")"
version="$(jq -r '.version' "$request")"
patch_set="$(jq -r '.patchSetHash' "$request")"
expected_build="$(jq -r '.buildSha' "$request")"
expected_runtime="$(jq -c '.runtime' "$request")"

npm_version="$(npm --version)"
actual_runtime="$($FORMAT_TOOL fingerprint --npm-version "$npm_version")"
[ "$(jq -cS . <<<"$actual_runtime")" = "$(jq -cS . <<<"$expected_runtime")" ] \
  || die "builder runtime fingerprint does not match request"

log "fetching exact target $target_ref@$target"
git init -q "$SOURCE_TREE"
git -C "$SOURCE_TREE" remote add upstream "$REPOSITORY_URL"
git -C "$SOURCE_TREE" fetch -q --no-tags --depth=1 upstream "$target"
git -C "$SOURCE_TREE" checkout -q --detach FETCH_HEAD
[ "$(git -C "$SOURCE_TREE" rev-parse HEAD)" = "$target" ] || die "fetched target commit mismatch"

applied='[]'
skipped='[]'
patch_count="$(jq '.patches | length' "$request")"
for ((index=0; index<patch_count; index++)); do
  branch="$(jq -r ".patches[$index].branch" "$request")"
  patch_file="$(jq -r ".patches[$index].file" "$request")"
  patch="$REQUEST_DIR/$patch_file"
  if git -C "$SOURCE_TREE" apply --reverse --check "$patch" >/dev/null 2>&1; then
    log "patch already upstream: $branch"
    skipped="$(jq -c --arg branch "$branch" '. + [$branch]' <<<"$skipped")"
  elif git -C "$SOURCE_TREE" apply --check "$patch" >/dev/null 2>&1; then
    log "applying patch: $branch"
    git -C "$SOURCE_TREE" apply "$patch"
    applied="$(jq -c --arg branch "$branch" '. + [$branch]' <<<"$applied")"
  else
    git -C "$SOURCE_TREE" apply --check "$patch" >&2 || true
    die "patch does not apply: $branch"
  fi
done

if ! git -C "$SOURCE_TREE" diff --quiet -- package.json package-lock.json; then
  die "request changes package dependencies; a full-package migration is required"
fi
[ "$(node -p "require('$SOURCE_TREE/package.json').version")" = "$version" ] \
  || die "source package version does not match request"

export OMNIROUTE_SKIP_SYSTEM_TRUST=1
export DISABLE_SQLITE_AUTO_BACKUP=true
export DATA_DIR="$WORKSPACE/data"
export JWT_SECRET="builder-fake-jwt-secret-with-sufficient-length"
export API_KEY_SECRET="builder-fake-api-key-secret-with-sufficient-length"
export INITIAL_PASSWORD="builder-fake-password-not-for-runtime"
export CI=1
export CIRCLE_NODE_TOTAL=1
export NEXT_TELEMETRY_DISABLED=1
mkdir -p "$DATA_DIR"

cd "$SOURCE_TREE"
log "installing dependencies on GitHub-hosted runner"
npm ci --no-audit --no-fund >&2
log "running focused release gates"
npm run check:build-scope >&2
npm run typecheck:core >&2
if ! git diff --quiet -- src/i18n/messages; then
  node --import tsx/esm --test tests/unit/i18n-vi-completeness.test.ts >&2
fi
log "building one webpack release artifact"
OMNIROUTE_USE_TURBOPACK=0 \
OMNIROUTE_BUILD_MEMORY_MB="$BUILD_MEMORY_MB" \
npm run build:release >&2
OMNIROUTE_BUILD_SHA="$expected_build" node scripts/build/write-build-sha.mjs >&2
repair_known_runtime_timeout_sidecar "$SOURCE_TREE"
[ -f dist/server.js ] || die "release build did not produce dist/server.js"
[ "$(cat dist/BUILD_SHA)" = "$expected_build" ] || die "release BUILD_SHA mismatch"

log "creating deterministic runtime overlay"
"$FORMAT_TOOL" create-payload --source "$SOURCE_TREE" --output "$PAYLOAD" --index-output "$FILE_INDEX"
payload_sha="$(sha256sum "$PAYLOAD" | awk '{print $1}')"
index_sha="$(sha256sum "$FILE_INDEX" | awk '{print $1}')"
payload_count="$(jq '.files | length' "$FILE_INDEX")"
payload_bytes="$(jq '[.files[].size] | add // 0' "$FILE_INDEX")"
package_sha="$(sha256sum package.json | awk '{print $1}')"
lock_sha="$(sha256sum package-lock.json | awk '{print $1}')"
dependency_fingerprint="$(node - <<'NODE'
const pkg = require(process.cwd() + "/package.json");
process.stdout.write(JSON.stringify({
  dependencies: pkg.dependencies || {},
  optionalDependencies: pkg.optionalDependencies || {},
  engines: pkg.engines || {},
}));
NODE
)"
created_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
policy_hash="$($FORMAT_TOOL policy | jq -r '.policyHash')"
patches="$(jq -c '.patches' "$request")"

jq -n \
  --argjson schemaVersion 2 \
  --arg artifactType omniroute-runtime-overlay \
  --arg repository diegosouzapw/OmniRoute \
  --arg requestSha256 "$request_sha" \
  --arg targetRef "$target_ref" \
  --arg targetCommit "$target" \
  --arg version "$version" \
  --arg patchSetHash "$patch_set" \
  --arg overlayPolicyHash "$policy_hash" \
  --arg buildSha "$expected_build" \
  --arg buildBundler webpack \
  --arg sourcePackageSha256 "$package_sha" \
  --arg sourceLockSha256 "$lock_sha" \
  --arg payloadSha256 "$payload_sha" \
  --arg fileIndexSha256 "$index_sha" \
  --argjson payloadEntryCount "$payload_count" \
  --argjson payloadUnpackedBytes "$payload_bytes" \
  --arg builderRepository "$BUILDER_REPOSITORY" \
  --arg builderWorkflow "$BUILDER_WORKFLOW" \
  --arg builderRef "$BUILDER_REF" \
  --arg builderSourceDigest "$BUILDER_SOURCE_DIGEST" \
  --argjson builderRunId "$BUILDER_RUN_ID" \
  --argjson builderRunAttempt "$BUILDER_RUN_ATTEMPT" \
  --arg createdAt "$created_at" \
  --argjson runtime "$actual_runtime" \
  --argjson dependencyFingerprint "$dependency_fingerprint" \
  --argjson patches "$patches" \
  --argjson appliedPatches "$applied" \
  --argjson skippedUpstreamedPatches "$skipped" \
  '{schemaVersion:$schemaVersion,artifactType:$artifactType,repository:$repository,requestSha256:$requestSha256,targetRef:$targetRef,targetCommit:$targetCommit,version:$version,patchSetHash:$patchSetHash,patches:$patches,appliedPatches:$appliedPatches,skippedUpstreamedPatches:$skippedUpstreamedPatches,sourcePackageSha256:$sourcePackageSha256,sourceLockSha256:$sourceLockSha256,dependencyFingerprint:$dependencyFingerprint,buildSha:$buildSha,buildBundler:$buildBundler,runtime:$runtime,overlayPolicyHash:$overlayPolicyHash,payloadSha256:$payloadSha256,fileIndexSha256:$fileIndexSha256,payloadEntryCount:$payloadEntryCount,payloadUnpackedBytes:$payloadUnpackedBytes,builder:{repository:$builderRepository,workflow:$builderWorkflow,ref:$builderRef,sourceDigest:$builderSourceDigest,runId:$builderRunId,runAttempt:$builderRunAttempt,runnerEnvironment:"github-hosted"},createdAt:$createdAt}' \
  >"$WORKSPACE/manifest.tmp.json"
"$FORMAT_TOOL" canonicalize --input "$WORKSPACE/manifest.tmp.json" --output "$MANIFEST"
chmod 0644 "$PAYLOAD" "$MANIFEST"
"$FORMAT_TOOL" create-response \
  --manifest "$MANIFEST" --payload "$PAYLOAD" --output "$RESPONSE"
log "build complete target=$target patches=$patch_set artifact=$(sha256sum "$RESPONSE" | awk '{print $1}') manifest=$(sha256sum "$MANIFEST" | awk '{print $1}')"
cat "$RESPONSE"
