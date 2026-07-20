#!/usr/bin/env bash
set -euo pipefail

readonly OPS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly UPDATE="$OPS_DIR/update.sh"
readonly WRAPPER="/usr/local/bin/update-omniroute"

fail() { printf 'not ok - %s\n' "$*" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$*"; }

bash -n "$UPDATE" || fail "updater syntax"
bash -n "$WRAPPER" || fail "wrapper syntax"
pass "updater and wrapper parse"

for forbidden in 'npm ci' 'npm run build' 'npm install -g' 'build_patched_source' 'overlay_built_runtime'; do
  if grep -Fq "$forbidden" "$UPDATE"; then
    fail "Tiny updater still contains forbidden local build operation: $forbidden"
  fi
done
pass "Tiny updater contains no install/build fallback"

grep -Fq -- '--artifact with the GitHub-attested response is required; local build fallback is disabled' "$UPDATE" \
  || fail "attested artifact is not mandatory"
grep -Fq -- '--expect-artifact with the reviewed response SHA-256 is required' "$UPDATE" \
  || fail "response pin is not mandatory"
grep -Fq -- '--expect-manifest with the reviewed manifest SHA-256 is required' "$UPDATE" \
  || fail "manifest pin is not mandatory"
grep -Fq 'GitHub artifact attestation verification failed; production was not touched' "$UPDATE" \
  || fail "attestation verifier is not fail-closed"
pass "artifact path, provenance, and reviewed digest pins are fail-closed gates"

grep -Fq 'rm -rf -- "$candidate_package/$source"' "$UPDATE" \
  || fail "replace roots are not removed before overlay"
grep -Fq 'rm -rf -- "$destination"' "$UPDATE" \
  || fail "singletons are not removed before overlay"
grep -Fq 'candidate_smoke "$runtime_prefix" "$stage" || die "candidate smoke test failed"' "$UPDATE" \
  || fail "candidate smoke is not required"
grep -Fq 'cp -a "$INSTALL_DIR" "$candidate_package"' "$UPDATE" \
  || fail "overlay lane does not inherit the installed package"
grep -Fq 'cp -a "$verified_package" "$candidate_package"' "$UPDATE" \
  || fail "full-package lane does not stage from the verified independent package"
grep -Fq 'case "$ARTIFACT_MODE" in' "$UPDATE" \
  || fail "updater does not dispatch by verified artifact mode"
grep -Fq 'scripts/build/fixTlsClientNodeBinary.mjs' "$UPDATE" \
  || fail "overlay staging omits the TLS client runtime repair singleton"
for provenance in artifactMode artifactType artifactPolicyHash artifactFileIndexSha256 artifactLinkIndexSha256 artifactProductionTreeSha256 artifactNativeIndexSha256; do
  grep -Fq "$provenance" "$UPDATE" || fail "deployment state lacks dual-lane provenance: $provenance"
done
smoke_line="$(grep -n 'candidate_smoke "$runtime_prefix" "$stage"' "$UPDATE" | cut -d: -f1)"
backup_line="$(grep -n 'log "creating application backup"' "$UPDATE" | cut -d: -f1)"
[ "$smoke_line" -lt "$backup_line" ] || fail "candidate smoke does not precede backup/production mutation"
pass "stale runtime files are removed and smoke precedes mutation"

grep -Fq 'systemctl kill --kill-whom=all --signal=TERM "$CANDIDATE_UNIT"' "$UPDATE" \
  || fail "updater cleanup does not kill candidate control group"
grep -Fq 'rollback_update "$DEPLOY_BACKUP" "$DEPLOY_STAMP"' "$UPDATE" \
  || fail "interrupted post-mutation update lacks rollback"
grep -Fq -- '--property=KillMode=control-group' "$WRAPPER" \
  || fail "wrapper does not contain complete cgroup cleanup"
grep -Fq -- '--setenv=GH_CONFIG_DIR="$GH_CONFIG_DIR"' "$WRAPPER" \
  || fail "wrapper does not pass GitHub authentication into the transient unit"
grep -Fq -- '--property=RuntimeMaxSec=100min' "$WRAPPER" \
  || fail "wrapper timeout is shorter than the hosted workflow timeout"
grep -Fq 'artifactRequestSha256' "$UPDATE" || fail "deployment state lacks request provenance"
grep -Fq 'confirmedReleaseHead' "$UPDATE" || fail "deployment state lacks the separately confirmed release head"
grep -Fq -- '--arg sourceCommit "$EXPECTED_TARGET_COMMIT"' "$UPDATE" \
  || fail "deployment state does not preserve the artifact target as sourceCommit"
for provenance in artifactRepository artifactWorkflow artifactRef artifactSourceDigest artifactRunId artifactRunAttempt; do
  grep -Fq "$provenance" "$UPDATE" || fail "deployment state lacks GitHub provenance: $provenance"
done
! grep -Fq 'artifactSigner' "$UPDATE" || fail "deployment state retains obsolete signer provenance"
pass "interruption, rollback, and GitHub artifact provenance gates are present"

fixture="$(mktemp -d "${TMPDIR:-/tmp}/omniroute-update-fixture.XXXXXX")"
trap 'rm -rf -- "$fixture"' EXIT
root="$fixture/root"
state="$root/state"
patch_state="$state/patches"
source="$root/source"
install_dir="$fixture/runtime/lib/node_modules/omniroute"
cli_link="$fixture/runtime/bin/omniroute"
mkdir -p "$patch_state" "$root/data" "$root/config" "$root/backups" "$root/staging" \
  "$root/ops" "$root/home" "$source" "$install_dir/bin" "$(dirname "$cli_link")" "$fixture/bin"
sqlite3 "$root/data/storage.sqlite" 'CREATE TABLE fixture(id INTEGER PRIMARY KEY);'
printf 'PORT=20130\nAPI_PORT=20131\nLIVE_WS_PORT=20132\n' >"$root/config/omniroute.env"
cp "$OPS_DIR/artifact-format.py" "$root/ops/artifact-format.py"
chmod 0755 "$root/ops/artifact-format.py"

git -C "$source" init -q
git -C "$source" config user.name fixture
git -C "$source" config user.email fixture@example.invalid
printf 'fixture\n' >"$source/README.md"
git -C "$source" add README.md
git -C "$source" commit -qm 'fixture source'
target="$(git -C "$source" rev-parse HEAD)"
git -C "$source" remote add upstream "$source"
git -C "$source" update-ref refs/heads/release/v3.8.49 "$target"
git -C "$source" update-ref refs/remotes/upstream/release/v3.8.49 "$target"
printf 'descendant\n' >"$source/descendant.txt"
git -C "$source" add descendant.txt
git -C "$source" commit -qm 'fixture release drift'
current_head="$(git -C "$source" rev-parse HEAD)"
git -C "$source" update-ref refs/heads/release/v3.8.49 "$current_head"
git -C "$source" update-ref refs/remotes/upstream/release/v3.8.49 "$current_head"
non_ancestor="$(git -C "$source" commit-tree "$(git -C "$source" rev-parse "$target^{tree}")" -m 'unrelated fixture head')"
artifact_created_at='2026-07-20T00:00:00Z'
fixture_now_epoch="$(/bin/date -u -d '2026-07-20T00:30:00Z' +%s)"

cat >"$install_dir/package.json" <<'JSON'
{"dependencies":{"fixture":"1.0.0"},"engines":{"node":">=22"},"name":"omniroute","optionalDependencies":{},"version":"3.8.49"}
JSON
cat >"$install_dir/bin/omniroute.mjs" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then printf '3.8.49\n'; exit 0; fi
exit 0
SH
chmod 0755 "$install_dir/bin/omniroute.mjs"
ln -s ../lib/node_modules/omniroute/bin/omniroute.mjs "$cli_link"

cat >"$fixture/bin/npm" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = view ] && { printf '3.8.48\n'; exit 0; }
[ "${1:-}" = --version ] && { printf '10.9.8\n'; exit 0; }
exit 2
SH
cat >"$fixture/bin/systemctl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$OMNIROUTE_FIXTURE_SYSTEMCTL_LOG"
if [ "${1:-}" = is-active ]; then
  if [ "${2:-}" = --quiet ]; then
    unit="${3:-}"
  else
    unit="${2:-}"
  fi
  [ "$unit" = "$OMNIROUTE_FIXTURE_SERVICE_NAME" ] || exit 0
  [ "${OMNIROUTE_FIXTURE_SERVICE_HEALTH:-healthy}" = healthy ]
  exit
fi
if [ "${1:-}" = start ] && [ "${2:-}" = "$OMNIROUTE_FIXTURE_SERVICE_NAME" ]; then
  start_count="$(grep -Ec "^start $OMNIROUTE_FIXTURE_SERVICE_NAME$" "$OMNIROUTE_FIXTURE_SYSTEMCTL_LOG" || true)"
  if [ "${OMNIROUTE_FIXTURE_FAIL_FIRST_SERVICE_START:-0}" = 1 ] && [ "$start_count" -eq 1 ]; then
    exit 1
  fi
fi
exit 0
SH
cat >"$fixture/bin/systemd-run" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$OMNIROUTE_FIXTURE_SYSTEMD_RUN_LOG"
candidate=""
for argument in "$@"; do
  case "$argument" in
    --working-directory=*) candidate="${argument#--working-directory=}" ;;
  esac
done
[ -n "$candidate" ] || { printf 'candidate working directory missing\n' >&2; exit 1; }
printf '%s\n' "$candidate" >"$OMNIROUTE_FIXTURE_CANDIDATE_PATH_FILE"
[ -f "$candidate/node_modules/fixture/runtime.js" ] \
  || { printf 'candidate missing fixture dependency closure\n' >&2; exit 1; }
[ ! -e "$candidate/installed-only.txt" ] \
  || { printf 'candidate inherited stale installed content\n' >&2; exit 1; }
[ -L "$candidate/node_modules/.bin/fixture" ] \
  || { printf 'candidate missing reconstructed npm .bin link\n' >&2; exit 1; }
[ "$(readlink "$candidate/node_modules/.bin/fixture")" = '../fixture/runtime.js' ] \
  || { printf 'candidate npm .bin target mismatch\n' >&2; exit 1; }
touch "$OMNIROUTE_FIXTURE_CANDIDATE_READY_FILE"
exit 0
SH
cat >"$fixture/bin/runuser" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$OMNIROUTE_FIXTURE_RUNUSER_LOG"
exit 0
SH
cat >"$fixture/bin/chown" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat >"$fixture/bin/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat >"$fixture/bin/journalctl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$OMNIROUTE_FIXTURE_JOURNAL_LOG"
exit 0
SH
cat >"$fixture/bin/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ " $* " == *" fixture.invalid/"* ]]; then
  printf '[]\n'
  exit 0
fi
url="${!#}"
if [[ "$url" == *":20133/"* || "$url" == *":20134/"* ]]; then
  [ -f "$OMNIROUTE_FIXTURE_CANDIDATE_READY_FILE" ] || exit 1
fi
printf '{"data":[]}\n'
SH
cat >"$fixture/bin/ss" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
port=""
for argument in "$@"; do
  case "$argument" in
    *:[0-9]*) port="${argument##*:}" ;;
  esac
done
printf 'State Recv-Q Send-Q Local Address:Port Peer Address:Port\n'
case "$port" in
  20133|20134|20135) [ -f "$OMNIROUTE_FIXTURE_CANDIDATE_READY_FILE" ] || exit 0 ;;
esac
printf 'LISTEN 0 128 127.0.0.1:%s 0.0.0.0:*\n' "${port:-fixture}"
SH
cat >"$fixture/bin/date" <<'SH'
#!/usr/bin/env bash
if [ "$*" = '-u +%s' ]; then
  printf '%s\n' "$OMNIROUTE_FIXTURE_NOW_EPOCH"
  exit 0
fi
exec /bin/date "$@"
SH
cat >"$fixture/bin/gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = auth ] && [ "${2:-}" = status ]; then
  exit 1
fi
if [ "${1:-}" = attestation ] && [ "${2:-}" = verify ]; then
  printf '%s\n' "$*" >>"$OMNIROUTE_FIXTURE_GH_LOG"
  [ "${OMNIROUTE_FIXTURE_GH_RESULT:-success}" = success ] || exit 1
  printf '[{"verificationResult":{"signatureVerification":{"verified":true}}}]\n'
  exit 0
fi
exit 2
SH
chmod 0755 "$fixture/bin/npm" "$fixture/bin/systemctl" "$fixture/bin/systemd-run" \
  "$fixture/bin/runuser" "$fixture/bin/chown" "$fixture/bin/sleep" "$fixture/bin/journalctl" \
  "$fixture/bin/curl" "$fixture/bin/ss" "$fixture/bin/date" "$fixture/bin/gh"
: >"$fixture/systemctl.log"
: >"$fixture/systemd-run.log"
: >"$fixture/runuser.log"
: >"$fixture/journalctl.log"
: >"$fixture/gh.log"
printf 'must not inherit\n' >"$install_dir/installed-only.txt"
package_sha="$(sha256sum "$install_dir/package.json" | awk '{print $1}')"
cat >"$state/current.json" <<JSON
{"sourceCommit":"$(printf 'e%.0s' {1..40})","version":"3.8.49"}
JSON

make_artifact() {
  local mode="$1"
  local output_dir="$2"
  local dependency_version="${3:-1.0.0}"
  local source_dir="$output_dir/source"
  local source_lock_file="$source_dir/package-lock.json"
  local payload_source="$source_dir"
  local artifact_type=omniroute-runtime-overlay
  local request_sha payload_sha index_sha link_index_sha production_tree_sha native_index_sha
  local entry_count unpacked_bytes link_count production_count native_count
  local source_package_sha source_lock_sha dependency_fingerprint policy_hash
  local -a payload_args=(--mode overlay --source "$source_dir")

  mkdir -p "$source_dir/dist" "$source_dir/bin"
  cp "$install_dir/package.json" "$source_dir/package.json"
  if [ "$dependency_version" != 1.0.0 ]; then
    jq --arg version "$dependency_version" '.dependencies.fixture=$version' "$source_dir/package.json" \
      >"$source_dir/package.tmp.json"
    mv "$source_dir/package.tmp.json" "$source_dir/package.json"
  fi
  printf '{}\n' >"$source_dir/package-lock.json"
  if [ "$mode" = "full-package" ]; then
    artifact_type=omniroute-full-package
    mkdir -p "$source_dir/node_modules/fixture"
    jq -n --arg version "$dependency_version" \
      '{lockfileVersion:3,name:"omniroute",packages:{"":{dependencies:{fixture:$version},engines:{node:">=22"},optionalDependencies:{}},"node_modules/fixture":{version:$version}}}' \
      >"$source_dir/package-lock.json"
    jq -n --arg version "$dependency_version" \
      '{name:"fixture",version:$version,bin:{fixture:"runtime.js"}}' \
      >"$source_dir/node_modules/fixture/package.json"
    printf '#!/usr/bin/env node\nconsole.log("new closure")\n' >"$source_dir/node_modules/fixture/runtime.js"
    chmod 0755 "$source_dir/node_modules/fixture/runtime.js"
    mkdir -p "$source_dir/node_modules/.bin"
    ln -s ../fixture/runtime.js "$source_dir/node_modules/.bin/fixture"
    cp "$source_dir/package-lock.json" "$output_dir/source-package-lock.json"
    source_lock_file="$output_dir/source-package-lock.json"
    rm "$source_dir/package-lock.json"
    payload_source="$source_dir"
    payload_args=(--mode full-package --source "$payload_source" \
      --source-lock "$source_lock_file" --source-package "$source_dir/package.json")
  fi
  printf '%s\n' "$build_sha" >"$source_dir/dist/BUILD_SHA"
  printf 'fixture server\n' >"$source_dir/dist/server.js"
  printf '#!/usr/bin/env bash\n[ \"${1:-}\" = --version ] && printf \"3.8.49\\n\"\n' >"$source_dir/bin/omniroute.mjs"
  chmod 0755 "$source_dir/bin/omniroute.mjs"
  source_package_sha="$(sha256sum "$source_dir/package.json" | awk '{print $1}')"
  source_lock_sha="$(sha256sum "$source_lock_file" | awk '{print $1}')"
  dependency_fingerprint="$($root/ops/artifact-format.py dependency-fingerprint --package "$source_dir/package.json")"
  policy_hash="$($root/ops/artifact-format.py policy --mode "$mode" | jq -r '.policyHash')"
  jq -n --argjson schemaVersion 2 --arg requestType omniroute-build-request \
    --arg artifactMode "$mode" --arg artifactType "$artifact_type" \
    --arg artifactPolicyHash "$policy_hash" \
    --arg repository diegosouzapw/OmniRoute --arg targetRef upstream/release/v3.8.49 \
    --arg targetCommit "$target" --arg version 3.8.49 --arg patchSetHash none \
    --arg buildSha "$build_sha" --arg sourcePackageSha256 "$source_package_sha" \
    --arg sourceLockSha256 "$source_lock_sha" --arg createdAt "$artifact_created_at" \
    --arg nonce "fixture-$mode" --argjson runtime "$runtime" \
    --argjson dependencyFingerprint "$dependency_fingerprint" \
    '{schemaVersion:$schemaVersion,requestType:$requestType,artifactMode:$artifactMode,artifactType:$artifactType,artifactPolicyHash:$artifactPolicyHash,repository:$repository,targetRef:$targetRef,targetCommit:$targetCommit,version:$version,patchSetHash:$patchSetHash,buildSha:$buildSha,sourcePackageSha256:$sourcePackageSha256,sourceLockSha256:$sourceLockSha256,dependencyFingerprint:$dependencyFingerprint,createdAt:$createdAt,nonce:$nonce,runtime:$runtime,patches:[]}' \
    >"$output_dir/request.tmp.json"
  "$root/ops/artifact-format.py" canonicalize \
    --input "$output_dir/request.tmp.json" --output "$output_dir/local-request.json"
  "$root/ops/artifact-format.py" create-payload "${payload_args[@]}" \
    --output "$output_dir/payload.tar.gz" --index-output "$output_dir/payload-files.json" \
    --links-output "$output_dir/payload-links.json" \
    --production-tree-output "$output_dir/payload-production-tree.json" \
    --native-index-output "$output_dir/payload-native-files.json"
  request_sha="$(sha256sum "$output_dir/local-request.json" | awk '{print $1}')"
  payload_sha="$(sha256sum "$output_dir/payload.tar.gz" | awk '{print $1}')"
  index_sha="$(sha256sum "$output_dir/payload-files.json" | awk '{print $1}')"
  link_index_sha="$(sha256sum "$output_dir/payload-links.json" | awk '{print $1}')"
  production_tree_sha="$(sha256sum "$output_dir/payload-production-tree.json" | awk '{print $1}')"
  native_index_sha="$(sha256sum "$output_dir/payload-native-files.json" | awk '{print $1}')"
  entry_count="$(jq '.files | length' "$output_dir/payload-files.json")"
  unpacked_bytes="$(jq '[.files[].size] | add // 0' "$output_dir/payload-files.json")"
  link_count="$(jq '.links | length' "$output_dir/payload-links.json")"
  production_count="$(jq '.packages | length' "$output_dir/payload-production-tree.json")"
  native_count="$(jq '.files | length' "$output_dir/payload-native-files.json")"
  jq -n --argjson schemaVersion 3 --arg artifactMode "$mode" \
    --arg artifactType "$artifact_type" --arg artifactPolicyHash "$policy_hash" \
    --arg repository diegosouzapw/OmniRoute --arg requestSha256 "$request_sha" \
    --arg targetRef upstream/release/v3.8.49 --arg targetCommit "$target" --arg version 3.8.49 \
    --arg patchSetHash none --arg sourcePackageSha256 "$source_package_sha" --arg sourceLockSha256 "$source_lock_sha" \
    --argjson dependencyFingerprint "$dependency_fingerprint" --arg buildSha "$build_sha" --arg buildBundler turbopack \
    --argjson runtime "$runtime" --arg payloadSha256 "$payload_sha" \
    --arg fileIndexSha256 "$index_sha" --arg linkIndexSha256 "$link_index_sha" \
    --arg productionTreeSha256 "$production_tree_sha" --arg nativeIndexSha256 "$native_index_sha" \
    --argjson payloadEntryCount "$entry_count" --argjson payloadUnpackedBytes "$unpacked_bytes" \
    --argjson payloadLinkCount "$link_count" --argjson productionPackageCount "$production_count" \
    --argjson nativeFileCount "$native_count" --arg builderRepository nguyenha935/OmniRoute \
    --arg builderWorkflow .github/workflows/omniroute-patch-artifact.yml --arg builderRef "$source_ref" \
    --arg builderSourceDigest "$source_digest" --argjson builderRunId "$run_id" \
    --argjson builderRunAttempt "$run_attempt" --arg createdAt "$artifact_created_at" \
    '{schemaVersion:$schemaVersion,artifactMode:$artifactMode,artifactType:$artifactType,artifactPolicyHash:$artifactPolicyHash,repository:$repository,requestSha256:$requestSha256,targetRef:$targetRef,targetCommit:$targetCommit,version:$version,patchSetHash:$patchSetHash,patches:[],appliedPatches:[],skippedUpstreamedPatches:[],sourcePackageSha256:$sourcePackageSha256,sourceLockSha256:$sourceLockSha256,dependencyFingerprint:$dependencyFingerprint,buildSha:$buildSha,buildBundler:$buildBundler,runtime:$runtime,payloadSha256:$payloadSha256,fileIndexSha256:$fileIndexSha256,linkIndexSha256:$linkIndexSha256,productionTreeSha256:$productionTreeSha256,nativeIndexSha256:$nativeIndexSha256,payloadEntryCount:$payloadEntryCount,payloadUnpackedBytes:$payloadUnpackedBytes,payloadLinkCount:$payloadLinkCount,productionPackageCount:$productionPackageCount,nativeFileCount:$nativeFileCount,builder:{repository:$builderRepository,workflow:$builderWorkflow,ref:$builderRef,sourceDigest:$builderSourceDigest,runId:$builderRunId,runAttempt:$builderRunAttempt,runnerEnvironment:"github-hosted"},createdAt:$createdAt}' \
    >"$output_dir/manifest.tmp.json"
  "$root/ops/artifact-format.py" canonicalize \
    --input "$output_dir/manifest.tmp.json" --output "$output_dir/artifact-manifest.json"
  "$root/ops/artifact-format.py" create-response --manifest "$output_dir/artifact-manifest.json" \
    --payload "$output_dir/payload.tar.gz" --output "$output_dir/response.tar.gz"
  printf '{"fixture":"bundle"}\n' >"$output_dir/attestation-bundle.jsonl"
  cp "$artifact_dir/run.valid.json" "$output_dir/run.json" 2>/dev/null || true
}

artifact_dir="$fixture/artifact"
mkdir -p "$artifact_dir"
build_sha="source-${target:0:12}-patch-none"
runtime="$($root/ops/artifact-format.py fingerprint --npm-version 10.9.8)"
source_digest="$(printf 'c%.0s' {1..40})"
source_ref="refs/heads/deploy/artifact/$(printf 'd%.0s' {1..64})"
run_id=12345
run_attempt=1
jq -n --arg repository nguyenha935/OmniRoute \
  --arg workflow .github/workflows/omniroute-patch-artifact.yml --arg ref "$source_ref" \
  --arg sourceDigest "$source_digest" --argjson runId "$run_id" --argjson runAttempt "$run_attempt" \
  '{repository:$repository,workflow:$workflow,ref:$ref,sourceDigest:$sourceDigest,runId:$runId,runAttempt:$runAttempt,runnerEnvironment:"github-hosted"}' \
  >"$artifact_dir/run.valid.json"
make_artifact overlay "$artifact_dir"
cp "$artifact_dir/run.valid.json" "$artifact_dir/run.json"
cp "$artifact_dir/attestation-bundle.jsonl" "$artifact_dir/attestation-bundle.valid.jsonl"
artifact_id="$(sha256sum "$artifact_dir/response.tar.gz" | awk '{print $1}')"
manifest_id="$(sha256sum "$artifact_dir/artifact-manifest.json" | awk '{print $1}')"

run_update_fixture() {
  local output="$1"
  shift
  git -C "$source" update-ref refs/heads/release/v3.8.49 "${OMNIROUTE_FIXTURE_RELEASE_HEAD:-$current_head}"
  PATH="$fixture/bin:$PATH" \
  OMNIROUTE_ROOT_DIR="$root" \
  OMNIROUTE_CONFIG_FILE="$root/config/omniroute.env" \
  OMNIROUTE_DATA_DIR="$root/data" \
  OMNIROUTE_SOURCE_DIR="$source" \
  OMNIROUTE_UPSTREAM_URL="$source" \
  OMNIROUTE_GITHUB_API_URL='https://fixture.invalid' \
  OMNIROUTE_STATE_DIR="$state" \
  OMNIROUTE_BACKUP_DIR="$root/backups" \
  OMNIROUTE_STAGING_DIR="$root/staging" \
  OMNIROUTE_INSTALL_DIR="$install_dir" \
  OMNIROUTE_CLI="$cli_link" \
  OMNIROUTE_CLI_LINK="$cli_link" \
  OMNIROUTE_CLI_LINK_TARGET='../lib/node_modules/omniroute/bin/omniroute.mjs' \
  OMNIROUTE_ARTIFACT_FORMAT_TOOL="$root/ops/artifact-format.py" \
  OMNIROUTE_ARTIFACT_REPOSITORY=nguyenha935/OmniRoute \
  OMNIROUTE_ARTIFACT_WORKFLOW=.github/workflows/omniroute-patch-artifact.yml \
  OMNIROUTE_FIXTURE_SYSTEMCTL_LOG="$fixture/systemctl.log" \
  OMNIROUTE_FIXTURE_SYSTEMD_RUN_LOG="$fixture/systemd-run.log" \
  OMNIROUTE_FIXTURE_RUNUSER_LOG="$fixture/runuser.log" \
  OMNIROUTE_FIXTURE_JOURNAL_LOG="$fixture/journalctl.log" \
  OMNIROUTE_FIXTURE_CANDIDATE_PATH_FILE="$fixture/candidate-package.path" \
  OMNIROUTE_FIXTURE_CANDIDATE_READY_FILE="$fixture/candidate.ready" \
  OMNIROUTE_FIXTURE_SERVICE_NAME=omniroute-fixture.service \
  OMNIROUTE_FIXTURE_GH_LOG="$fixture/gh.log" \
  OMNIROUTE_FIXTURE_NOW_EPOCH="$fixture_now_epoch" \
  OMNIROUTE_SERVICE_NAME=omniroute-fixture.service \
    "$UPDATE" "$@" >"$output" 2>&1
}

assert_no_production_mutation() {
  local label="$1"
  [ -f "$install_dir/package.json" ] || fail "$label removed the installed package"
  [ -f "$install_dir/installed-only.txt" ] || fail "$label changed installed package contents"
  [ "$(sha256sum "$install_dir/package.json" | awk '{print $1}')" = "$package_sha" ] \
    || fail "$label changed the installed package"
  [ "$(readlink "$cli_link")" = '../lib/node_modules/omniroute/bin/omniroute.mjs' ] \
    || fail "$label changed the CLI link"
  [ -z "$(find "$root/backups" -mindepth 1 -maxdepth 1 -print -quit)" ] \
    || fail "$label created a production backup"
  ! grep -Eq '(^| )(stop|start) omniroute-fixture\.service($| )' "$fixture/systemctl.log" \
    || fail "$label stopped or restarted production"
}

reset_failure_evidence() {
  rm -rf -- "$root/staging"/* "$root/backups"/*
  rm -f -- "$fixture/candidate-package.path" "$fixture/candidate.ready"
  : >"$fixture/systemctl.log"
  : >"$fixture/systemd-run.log"
  : >"$fixture/runuser.log"
  : >"$fixture/journalctl.log"
  : >"$fixture/gh.log"
  cp "$artifact_dir/run.valid.json" "$artifact_dir/run.json"
  cp "$artifact_dir/attestation-bundle.valid.jsonl" "$artifact_dir/attestation-bundle.jsonl"
}

artifact_args=(
  --preflight --expect-target "$target" --expect-patch-set none
  --artifact "$artifact_dir/response.tar.gz"
  --expect-artifact "$artifact_id" --expect-manifest "$manifest_id"
  --expect-artifact-source "$source_digest" --expect-artifact-ref "$source_ref"
  --expect-artifact-run "$run_id" --expect-artifact-attempt "$run_attempt"
)

if OMNIROUTE_FIXTURE_RELEASE_HEAD="$target" run_update_fixture "$fixture/missing.log" \
  --update --expect-target "$target" --expect-patch-set none; then
  fail "update without a GitHub-attested artifact unexpectedly succeeded"
fi
grep -Fq 'local build fallback is disabled' "$fixture/missing.log" \
  || { perl -ne 'print if $. <= 200' "$fixture/missing.log" >&2; fail "missing-artifact failure did not identify disabled local fallback"; }
assert_no_production_mutation "missing-artifact failure"
pass "isolated updater fails before backup, swap, or restart when artifact is absent"

if run_update_fixture "$fixture/bad-pin.log" \
  --preflight --expect-target "$(printf 'f%.0s' {1..40})" --expect-patch-set none; then
  fail "preflight with a stale target pin unexpectedly succeeded"
fi
grep -Fq 'target drifted' "$fixture/bad-pin.log" \
  || fail "stale target pin did not fail closed"
assert_no_production_mutation "stale-pin preflight"
pass "isolated updater rejects stale target pin without mutation"

ancestor_args=(
  --preflight --expect-target "$target" --expect-patch-set none
  --allow-ancestor-target --expect-current-head "$current_head"
  --artifact "$artifact_dir/response.tar.gz"
  --expect-artifact "$artifact_id" --expect-manifest "$manifest_id"
  --expect-artifact-source "$source_digest" --expect-artifact-ref "$source_ref"
  --expect-artifact-run "$run_id" --expect-artifact-attempt "$run_attempt"
)

reset_failure_evidence
if run_update_fixture "$fixture/ancestor-missing-opt-in.log" \
  --preflight --expect-target "$target" --expect-patch-set none \
  --expect-current-head "$current_head"; then
  fail "ancestor current-head pin without explicit opt-in unexpectedly succeeded"
fi
grep -Fq -- '--expect-current-head requires --allow-ancestor-target' "$fixture/ancestor-missing-opt-in.log" \
  || fail "missing ancestor opt-in did not fail closed"
assert_no_production_mutation "missing ancestor opt-in"
pass "ancestor policy requires explicit opt-in"

reset_failure_evidence
if run_update_fixture "$fixture/ancestor-missing-head.log" \
  --preflight --expect-target "$target" --expect-patch-set none --allow-ancestor-target; then
  fail "ancestor policy without current-head pin unexpectedly succeeded"
fi
grep -Fq -- '--expect-current-head with the reviewed current release head is required' "$fixture/ancestor-missing-head.log" \
  || fail "missing current-head pin did not fail closed"
assert_no_production_mutation "missing current-head pin"
pass "ancestor policy requires an exact current release-head pin"

reset_failure_evidence
if run_update_fixture "$fixture/ancestor-wrong-head.log" \
  --preflight --expect-target "$target" --expect-patch-set none \
  --allow-ancestor-target --expect-current-head "$(printf 'f%.0s' {1..40})"; then
  fail "ancestor policy with wrong current-head pin unexpectedly succeeded"
fi
grep -Fq 'current release head drifted' "$fixture/ancestor-wrong-head.log" \
  || fail "wrong current-head pin did not fail closed"
assert_no_production_mutation "wrong current-head pin"
pass "ancestor policy rejects a mismatched current release-head pin"

reset_failure_evidence
if OMNIROUTE_FIXTURE_RELEASE_HEAD="$non_ancestor" run_update_fixture "$fixture/ancestor-non-ancestor.log" \
  --preflight --expect-target "$target" --expect-patch-set none \
  --allow-ancestor-target --expect-current-head "$non_ancestor"; then
  fail "non-ancestor release head unexpectedly succeeded"
fi
grep -Fq 'artifact target is not an ancestor of the pinned current release head' "$fixture/ancestor-non-ancestor.log" \
  || fail "non-ancestor target did not fail at ancestry gate"
assert_no_production_mutation "non-ancestor target"
pass "ancestor policy rejects unrelated release history"

reset_failure_evidence
if OMNIROUTE_UPDATE_CHANNEL=stable run_update_fixture "$fixture/ancestor-wrong-release.log" \
  "${ancestor_args[@]}"; then
  fail "ancestor artifact for a different release target unexpectedly succeeded"
fi
grep -Fq 'ancestor target policy requires the same active release branch and version' "$fixture/ancestor-wrong-release.log" \
  || fail "different release/version did not fail closed"
assert_no_production_mutation "different release/version"
pass "ancestor policy is limited to the same active release branch and version"

reset_failure_evidence
fixture_now_epoch="$(/bin/date -u -d '2026-07-20T01:01:00Z' +%s)"
if run_update_fixture "$fixture/ancestor-stale.log" "${ancestor_args[@]}"; then
  fail "stale ancestor artifact unexpectedly succeeded"
fi
grep -Fq 'artifact request is older than 60 minutes' "$fixture/ancestor-stale.log" \
  || fail "stale artifact did not fail at age gate"
assert_no_production_mutation "stale ancestor artifact"
fixture_now_epoch="$(/bin/date -u -d '2026-07-20T00:30:00Z' +%s)"
pass "ancestor policy rejects artifacts older than 60 minutes"

reset_failure_evidence
if run_update_fixture "$fixture/ancestor-patch-drift.log" \
  --preflight --expect-target "$target" \
  --expect-patch-set "$(printf 'f%.0s' {1..64})" \
  --allow-ancestor-target --expect-current-head "$current_head"; then
  fail "ancestor policy with patch-set drift unexpectedly succeeded"
fi
grep -Fq 'patch set drifted' "$fixture/ancestor-patch-drift.log" \
  || fail "ancestor patch-set drift did not fail closed"
assert_no_production_mutation "ancestor patch-set drift"
pass "ancestor policy retains exact patch-set pinning"

reset_failure_evidence
run_update_fixture "$fixture/ancestor-valid.log" "${ancestor_args[@]}" \
  || { perl -ne 'print if $. <= 260' "$fixture/ancestor-valid.log" >&2; fail "valid bounded ancestor artifact preflight"; }
grep -Fq 'bounded ancestor target verified' "$fixture/ancestor-valid.log" \
  || fail "valid ancestor policy was not confirmed"
assert_no_production_mutation "valid ancestor artifact preflight"
pass "fresh same-release ancestor artifact preflight succeeds without mutation"

reset_failure_evidence
OMNIROUTE_FIXTURE_RELEASE_HEAD="$target" run_update_fixture "$fixture/valid.log" "${artifact_args[@]}" \
  || { perl -ne 'print if $. <= 240' "$fixture/valid.log" >&2; fail "valid GitHub-attested artifact preflight"; }
grep -Fq -- "--repo nguyenha935/OmniRoute" "$fixture/gh.log" \
  || fail "attestation verifier did not pin repository"
grep -Fq -- "--signer-workflow nguyenha935/OmniRoute/.github/workflows/omniroute-patch-artifact.yml" "$fixture/gh.log" \
  || fail "attestation verifier did not pin workflow"
grep -Fq -- "--source-ref $source_ref" "$fixture/gh.log" \
  || fail "attestation verifier did not pin source ref"
grep -Fq -- "--source-digest $source_digest" "$fixture/gh.log" \
  || fail "attestation verifier did not pin source digest"
grep -Fq -- '--deny-self-hosted-runners' "$fixture/gh.log" \
  || fail "attestation verifier permits self-hosted runners"
assert_no_production_mutation "valid artifact preflight"
pass "valid artifact preflight verifies exact GitHub identity without mutation"

for scenario in wrong-repo wrong-workflow wrong-ref wrong-source wrong-run wrong-attempt; do
  reset_failure_evidence
  case "$scenario" in
    wrong-repo) jq '.repository="attacker/OmniRoute"' "$artifact_dir/run.valid.json" >"$artifact_dir/run.json" ;;
    wrong-workflow) jq '.workflow=".github/workflows/other.yml"' "$artifact_dir/run.valid.json" >"$artifact_dir/run.json" ;;
    wrong-ref) jq '.ref="refs/heads/deploy/artifact/ffffffffffffffff"' "$artifact_dir/run.valid.json" >"$artifact_dir/run.json" ;;
    wrong-source) jq '.sourceDigest="ffffffffffffffffffffffffffffffffffffffff"' "$artifact_dir/run.valid.json" >"$artifact_dir/run.json" ;;
    wrong-run) jq '.runId=99999' "$artifact_dir/run.valid.json" >"$artifact_dir/run.json" ;;
    wrong-attempt) jq '.runAttempt=2' "$artifact_dir/run.valid.json" >"$artifact_dir/run.json" ;;
  esac
  if OMNIROUTE_FIXTURE_RELEASE_HEAD="$target" run_update_fixture "$fixture/$scenario.log" "${artifact_args[@]}"; then
    fail "$scenario workflow identity unexpectedly succeeded"
  fi
  grep -Fq 'GitHub workflow run identity does not match reviewed pins' "$fixture/$scenario.log" \
    || fail "$scenario did not fail at workflow identity gate"
  [ ! -s "$fixture/gh.log" ] || fail "$scenario invoked attestation before run identity matched"
  assert_no_production_mutation "$scenario"
done
pass "repository, workflow, ref, source SHA, run ID, and attempt mismatches fail before attestation or mutation"

reset_failure_evidence
rm -f "$artifact_dir/attestation-bundle.jsonl"
if OMNIROUTE_FIXTURE_RELEASE_HEAD="$target" run_update_fixture "$fixture/missing-bundle.log" "${artifact_args[@]}"; then
  fail "missing attestation bundle unexpectedly succeeded"
fi
grep -Fq 'GitHub attestation bundle is missing next to response' "$fixture/missing-bundle.log" \
  || fail "missing attestation bundle did not fail closed"
[ ! -s "$fixture/gh.log" ] || fail "missing bundle invoked attestation verifier"
assert_no_production_mutation "missing attestation bundle"
pass "absent attestation bundle fails before verifier or mutation"

reset_failure_evidence
if OMNIROUTE_FIXTURE_GH_RESULT=failure OMNIROUTE_FIXTURE_RELEASE_HEAD="$target" run_update_fixture "$fixture/bad-attestation.log" "${artifact_args[@]}"; then
  fail "failed GitHub attestation unexpectedly succeeded"
fi
grep -Fq 'GitHub artifact attestation verification failed; production was not touched' "$fixture/bad-attestation.log" \
  || fail "failed attestation did not fail closed"
[ -s "$fixture/gh.log" ] || fail "failed attestation did not invoke verifier"
assert_no_production_mutation "failed attestation"
pass "attestation verifier failure stops before backup, swap, or restart"

reset_failure_evidence
bad_digest="$(printf 'f%.0s' {1..64})"
if OMNIROUTE_FIXTURE_RELEASE_HEAD="$target" run_update_fixture "$fixture/bad-digest.log" \
  --preflight --expect-target "$target" --expect-patch-set none \
  --artifact "$artifact_dir/response.tar.gz" --expect-artifact "$bad_digest" --expect-manifest "$manifest_id" \
  --expect-artifact-source "$source_digest" --expect-artifact-ref "$source_ref" \
  --expect-artifact-run "$run_id" --expect-artifact-attempt "$run_attempt"; then
  fail "wrong reviewed response digest unexpectedly succeeded"
fi
grep -Fq 'attested artifact content verification failed; production was not touched' "$fixture/bad-digest.log" \
  || fail "wrong response digest did not fail at inner verifier"
[ -s "$fixture/gh.log" ] || fail "wrong response digest skipped outer attestation"
assert_no_production_mutation "wrong response digest"
pass "response digest mismatch fails after attestation but before mutation"

full_artifact_dir="$fixture/full-package-artifact"
mkdir -p "$full_artifact_dir"
cp "$artifact_dir/run.valid.json" "$full_artifact_dir/run.valid.json"
make_artifact full-package "$full_artifact_dir" 2.0.0
cp "$full_artifact_dir/run.valid.json" "$full_artifact_dir/run.json"
cp "$full_artifact_dir/attestation-bundle.jsonl" "$full_artifact_dir/attestation-bundle.valid.jsonl"
full_artifact_id="$(sha256sum "$full_artifact_dir/response.tar.gz" | awk '{print $1}')"
full_manifest_id="$(sha256sum "$full_artifact_dir/artifact-manifest.json" | awk '{print $1}')"
full_artifact_args=(
  --expect-target "$target" --expect-patch-set none
  --artifact "$full_artifact_dir/response.tar.gz"
  --expect-artifact "$full_artifact_id" --expect-manifest "$full_manifest_id"
  --expect-artifact-source "$source_digest" --expect-artifact-ref "$source_ref"
  --expect-artifact-run "$run_id" --expect-artifact-attempt "$run_attempt"
)

reset_failure_evidence
wrong_full_dir="$fixture/wrong-lane-full-package"
mkdir -p "$wrong_full_dir"
cp "$artifact_dir/run.valid.json" "$wrong_full_dir/run.valid.json"
make_artifact full-package "$wrong_full_dir" 1.0.0
cp "$wrong_full_dir/run.valid.json" "$wrong_full_dir/run.json"
wrong_full_id="$(sha256sum "$wrong_full_dir/response.tar.gz" | awk '{print $1}')"
wrong_full_manifest="$(sha256sum "$wrong_full_dir/artifact-manifest.json" | awk '{print $1}')"
if OMNIROUTE_FIXTURE_RELEASE_HEAD="$target" run_update_fixture "$fixture/wrong-lane-full-package.log" \
  --preflight --expect-target "$target" --expect-patch-set none \
  --artifact "$wrong_full_dir/response.tar.gz" --expect-artifact "$wrong_full_id" \
  --expect-manifest "$wrong_full_manifest" --expect-artifact-source "$source_digest" \
  --expect-artifact-ref "$source_ref" --expect-artifact-run "$run_id" \
  --expect-artifact-attempt "$run_attempt"; then
  fail "full-package artifact without dependency drift unexpectedly succeeded"
fi
grep -Fq 'full-package artifact is forbidden when installed dependencies already match' "$fixture/wrong-lane-full-package.log" \
  || { perl -ne 'print if $. <= 240' "$fixture/wrong-lane-full-package.log" >&2; fail "non-drift full package did not fail at lane gate"; }
[ ! -s "$fixture/systemd-run.log" ] || fail "wrong-lane full package reached candidate smoke"
[ ! -s "$fixture/runuser.log" ] || fail "wrong-lane full package reached backup"
assert_no_production_mutation "wrong-lane full package"
pass "full-package lane rejects matching dependencies before smoke or production mutation"

reset_failure_evidence
wrong_overlay_dir="$fixture/wrong-lane-overlay"
mkdir -p "$wrong_overlay_dir"
cp "$artifact_dir/run.valid.json" "$wrong_overlay_dir/run.valid.json"
make_artifact overlay "$wrong_overlay_dir" 2.0.0
cp "$wrong_overlay_dir/run.valid.json" "$wrong_overlay_dir/run.json"
wrong_overlay_id="$(sha256sum "$wrong_overlay_dir/response.tar.gz" | awk '{print $1}')"
wrong_overlay_manifest="$(sha256sum "$wrong_overlay_dir/artifact-manifest.json" | awk '{print $1}')"
if OMNIROUTE_FIXTURE_RELEASE_HEAD="$target" run_update_fixture "$fixture/wrong-lane-overlay.log" \
  --preflight --expect-target "$target" --expect-patch-set none \
  --artifact "$wrong_overlay_dir/response.tar.gz" --expect-artifact "$wrong_overlay_id" \
  --expect-manifest "$wrong_overlay_manifest" --expect-artifact-source "$source_digest" \
  --expect-artifact-ref "$source_ref" --expect-artifact-run "$run_id" \
  --expect-artifact-attempt "$run_attempt"; then
  fail "overlay artifact with dependency drift unexpectedly succeeded"
fi
grep -Fq 'overlay artifact dependencies do not match installed package' "$fixture/wrong-lane-overlay.log" \
  || { perl -ne 'print if $. <= 240' "$fixture/wrong-lane-overlay.log" >&2; fail "dependency-drift overlay did not fail at lane gate"; }
[ ! -s "$fixture/systemd-run.log" ] || fail "wrong-lane overlay reached candidate smoke"
[ ! -s "$fixture/runuser.log" ] || fail "wrong-lane overlay reached backup"
assert_no_production_mutation "wrong-lane overlay"
pass "overlay lane rejects dependency drift before smoke or production mutation"

reset_failure_evidence
if OMNIROUTE_FIXTURE_FAIL_FIRST_SERVICE_START=1 OMNIROUTE_FIXTURE_RELEASE_HEAD="$target" \
  run_update_fixture "$fixture/full-package-rollback.log" --update "${full_artifact_args[@]}"; then
  fail "full-package update with forced production start failure unexpectedly succeeded"
fi
grep -Fq 'update failed; restoring package and data' "$fixture/full-package-rollback.log" \
  || { perl -ne 'print if $. <= 320' "$fixture/full-package-rollback.log" >&2; fail "forced full-package failure did not enter rollback"; }
grep -Fq 'rollback: full runtime surface healthy' "$fixture/full-package-rollback.log" \
  || fail "full-package rollback did not restore a healthy runtime surface"
[ -s "$fixture/candidate-package.path" ] || fail "rollback scenario did not smoke the full-package candidate"
[ -f "$install_dir/installed-only.txt" ] || fail "full-package rollback did not restore original installed content"
[ ! -e "$install_dir/node_modules/fixture/runtime.js" ] || fail "full-package rollback left candidate dependency content installed"
[ "$(sha256sum "$install_dir/package.json" | awk '{print $1}')" = "$package_sha" ] \
  || fail "full-package rollback did not restore the original package"
[ "$(readlink "$cli_link")" = '../lib/node_modules/omniroute/bin/omniroute.mjs' ] \
  || fail "full-package rollback did not restore the CLI link"
[ "$(jq -r '.sourceCommit' "$state/current.json")" = "$(printf 'e%.0s' {1..40})" ] \
  || fail "failed full-package update overwrote deployment state"
[ "$(grep -Ec '^start omniroute-fixture.service$' "$fixture/systemctl.log")" -eq 2 ] \
  || fail "full-package rollback did not attempt one failed start and one recovery start"
pass "post-swap full-package start failure restores package, data, CLI, service, and state"

reset_failure_evidence
OMNIROUTE_FIXTURE_RELEASE_HEAD="$target" run_update_fixture "$fixture/full-package-update.log" \
  --update "${full_artifact_args[@]}" \
  || { perl -ne 'print if $. <= 320' "$fixture/full-package-update.log" >&2; fail "full-package isolated update"; }
[ -s "$fixture/candidate-package.path" ] || fail "full-package update did not run candidate smoke"
grep -Fq 'candidate-smoke: dashboard, API bridge, and live WebSocket listener healthy' "$fixture/full-package-update.log" \
  || fail "full-package candidate smoke did not complete"
smoke_log_line="$(grep -n 'candidate-smoke:' "$fixture/full-package-update.log" | cut -d: -f1)"
backup_log_line="$(grep -n 'creating application backup' "$fixture/full-package-update.log" | cut -d: -f1)"
[ "$smoke_log_line" -lt "$backup_log_line" ] || fail "full-package candidate smoke did not precede backup"
[ -f "$install_dir/node_modules/fixture/runtime.js" ] || fail "deployed full package lacks the new production dependency closure"
[ ! -e "$install_dir/installed-only.txt" ] || fail "deployed full package inherited stale installed content"
[ -L "$install_dir/node_modules/.bin/fixture" ] || fail "deployed full package lacks reconstructed npm .bin link"
[ "$(readlink "$install_dir/node_modules/.bin/fixture")" = '../fixture/runtime.js' ] \
  || fail "deployed full-package npm .bin target drifted"
[ "$(jq -r '.artifactMode' "$state/current.json")" = full-package ] \
  || fail "deployment state did not record full-package mode"
[ "$(jq -r '.method' "$state/current.json")" = github-attested-full-package ] \
  || fail "deployment state did not record full-package method"
[ -n "$(jq -r '.artifactProductionTreeSha256' "$state/current.json")" ] \
  || fail "deployment state omitted production-tree digest"
[ -n "$(jq -r '.artifactLinkIndexSha256' "$state/current.json")" ] \
  || fail "deployment state omitted link-index digest"
[ -n "$(jq -r '.artifactNativeIndexSha256' "$state/current.json")" ] \
  || fail "deployment state omitted native-index digest"
pass "full-package update smokes an independent linked closure before backup and records provenance"

printf '1..24\n'
