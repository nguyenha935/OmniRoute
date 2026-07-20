#!/usr/bin/env bash
set -euo pipefail

readonly OPS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ORCHESTRATOR="$OPS_DIR/artifact.sh"
readonly WORKFLOW_PATH=".github/workflows/omniroute-patch-artifact.yml"

fail() { printf 'not ok - %s\n' "$*" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$*"; }

bash -n "$ORCHESTRATOR" || fail "orchestrator syntax"
grep -Fq 'runs-on: ubuntu-24.04' "$ORCHESTRATOR" || fail "workflow is not pinned to ubuntu-24.04"
grep -Fq 'persist-credentials: false' "$ORCHESTRATOR" || fail "workflow checkout persists credentials"
grep -Fq 'gh attestation verify' "$ORCHESTRATOR" || fail "download path does not verify GitHub attestation"
grep -Fq -- '--deny-self-hosted-runners' "$ORCHESTRATOR" || fail "attestation accepts self-hosted runners"
grep -Fq 'deploy/integration' "$ORCHESTRATOR" || fail "persistent integration branch is missing"
grep -Fq 'Restore Next.js build cache' "$ORCHESTRATOR" || fail "workflow omits the Next.js build cache"
grep -Fq 'actions/cache/restore@0400d5f644dc74513175e3cd8d07132dd4860809' "$ORCHESTRATOR" \
  || fail "workflow does not use the dedicated cache restore action"
grep -Fq 'actions/cache/save@0400d5f644dc74513175e3cd8d07132dd4860809' "$ORCHESTRATOR" \
  || fail "workflow does not preserve a successful build cache after later failures"
grep -Fq "hashFiles('.omniroute-deploy/cache/next/**') != ''" "$ORCHESTRATOR" \
  || fail "workflow may save an incomplete build cache"
grep -Fq 'Build one reviewed Webpack artifact' "$ORCHESTRATOR" \
  || fail "workflow does not identify the bounded-memory Webpack lane"
grep -Fq 'published_blob_matches' "$ORCHESTRATOR" \
  || fail "published request reuse is not bound to the exact hosted toolchain"
grep -Fq 'monitor_resources' "$ORCHESTRATOR" || fail "workflow omits hosted-runner resource telemetry"
grep -Fq 'trap cleanup_monitor EXIT INT TERM HUP' "$ORCHESTRATOR" \
  || fail "workflow resource monitor is not cleaned up safely"
grep -Fq 'cp -a .omniroute-deploy/input/patches/.' "$ORCHESTRATOR" || fail "workflow does not support an empty patch set"
grep -Fq 'name: Upload builder diagnostics' "$ORCHESTRATOR" || fail "workflow omits failure diagnostics upload"
grep -Fq 'if: ${{ always() }}' "$ORCHESTRATOR" || fail "builder diagnostics are skipped on failure"
! grep -Eq 'git .*push .*--force|git .*push .*-f([[:space:]]|$)' "$ORCHESTRATOR" || fail "orchestrator contains force-push"
for forbidden in 'npm ci' 'npm run build' 'npm install --global npm@10.9.8'; do
  count="$(grep -Fc "$forbidden" "$ORCHESTRATOR" || true)"
  if [ "$forbidden" = 'npm install --global npm@10.9.8' ]; then
    [ "$count" -eq 1 ] || fail "npm pin must exist exactly once inside the hosted workflow"
  else
    [ "$count" -eq 0 ] || fail "Tiny orchestrator contains a local heavy build operation: $forbidden"
  fi
done
! grep -Eq '^[[:space:]]*git .*diff --cached --check' "$ORCHESTRATOR" \
  || fail "deployment commit runs the whitespace linter and rejects real patch snapshots"
pass "orchestrator is integration-based, hosted-only, attested, cached, and has no local build fallback"

# Regression guard: the workflow must pack requests with no local patches. A shell
# wildcard copy fails when the directory is empty, so mirror the generated command.
empty_source="$(mktemp -d "${TMPDIR:-/tmp}/omniroute-empty-patches.XXXXXX")"
empty_target="$(mktemp -d "${TMPDIR:-/tmp}/omniroute-empty-reviewed.XXXXXX")"
mkdir -p "$empty_source/patches" "$empty_target/patches"
cp -a "$empty_source/patches/." "$empty_target/patches/" \
  || fail "empty patch directory copy"
[ -z "$(find "$empty_target/patches" -mindepth 1 -print -quit)" ] \
  || fail "empty patch copy introduced unexpected files"
rm -rf -- "$empty_source" "$empty_target"
pass "workflow accepts an empty patch set"

# Regression guard: the immutable payload embeds patch snapshots verbatim, and real
# locale diffs carry trailing whitespace. Committing such a payload must succeed.
ws_repo="$(mktemp -d "${TMPDIR:-/tmp}/omniroute-ws-check.XXXXXX")"
git -C "$ws_repo" init -q
git -C "$ws_repo" config user.name fixture
git -C "$ws_repo" config user.email fixture@example.invalid
git -C "$ws_repo" config commit.gpgsign false
mkdir -p "$ws_repo/.omniroute-deploy/input/patches"
printf '+context line with trailing space \n+another   \n' >"$ws_repo/.omniroute-deploy/input/patches/0001-fixture.patch"
git -C "$ws_repo" add .omniroute-deploy
if git -C "$ws_repo" -c core.whitespace=blank-at-eol diff --cached --check >/dev/null 2>&1; then
  fail "fixture patch lacks the trailing whitespace this regression targets"
fi
git -C "$ws_repo" commit -qm 'chore(deploy): payload with trailing-whitespace patch' \
  || fail "deployment commit rejected a trailing-whitespace patch payload"
rm -rf -- "$ws_repo"
pass "deployment commit accepts verbatim patch snapshots with trailing whitespace"

fixture="$(mktemp -d "${TMPDIR:-/tmp}/omniroute-orchestrator-fixture.XXXXXX")"
trap '[ "${OMNIROUTE_KEEP_FIXTURE:-0}" = 1 ] || rm -rf -- "$fixture"' EXIT
source="$fixture/source"
installed="$fixture/installed"
remote="$fixture/remote.git"
state="$fixture/state"
artifact_root="$fixture/artifacts"
staging="$fixture/staging"
bin="$fixture/bin"
mkdir -p "$source" "$installed" "$state/patches" "$artifact_root" "$staging" "$bin"
git init -q --bare "$remote"
git -C "$source" init -q
git -C "$source" config user.name fixture
git -C "$source" config user.email fixture@example.invalid
git -C "$source" config commit.gpgsign false
cat >"$source/package.json" <<'JSON'
{"dependencies":{"fixture":"1.0.0"},"engines":{"node":">=22"},"name":"omniroute","optionalDependencies":{},"version":"3.8.49"}
JSON
cat >"$source/package-lock.json" <<'JSON'
{"lockfileVersion":3,"name":"omniroute","packages":{"":{"dependencies":{"fixture":"1.0.0"},"engines":{"node":">=22"},"optionalDependencies":{}},"node_modules/fixture":{"version":"1.0.0"}}}
JSON
cp "$source/package.json" "$installed/package.json"
printf 'fixture\n' >"$source/README.md"
git -C "$source" add .
GIT_AUTHOR_DATE='2026-07-18T00:00:00Z' GIT_COMMITTER_DATE='2026-07-18T00:00:00Z' \
  git -C "$source" commit -qm 'fixture target'
target="$(git -C "$source" rev-parse HEAD)"
git -C "$source" remote add origin "$remote"
git -C "$source" remote add upstream "$remote"
git -C "$source" push -q origin HEAD:refs/heads/release/v3.8.49
git -C "$source" update-ref refs/remotes/upstream/release/v3.8.49 "$target"
git -C "$remote" symbolic-ref HEAD refs/heads/release/v3.8.49

cat >"$bin/npm" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = --version ] && { printf '10.9.8\n'; exit 0; }
printf 'unexpected npm command: %s\n' "$*" >&2
exit 99
SH
cat >"$bin/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat >"$bin/openssl" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = rand ] || exit 2
printf '0123456789abcdef0123456789abcdef\n'
SH
cat >"$bin/date" <<'SH'
#!/usr/bin/env bash
case "$*" in
  '-u +%Y-%m-%dT%H:%M:%SZ') printf '2026-07-19T00:00:00Z\n' ;;
  *) /bin/date "$@" ;;
esac
SH
cat >"$bin/gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$OMNIROUTE_FIXTURE_GH_LOG"
case "${1:-} ${2:-}" in
  'auth status') exit 0 ;;
  'run list')
    sha=""
    have_workflow_flag=0
    args=("$@")
    for ((i=0; i<${#args[@]}; i++)); do
      [ "${args[$i]}" = --workflow ] && have_workflow_flag=1
      if [ "${args[$i]}" = --commit ]; then sha="${args[$((i+1))]}"; fi
    done
    # Real GitHub 404s on --workflow <path> when the workflow is absent from the
    # default branch; the orchestrator must select by commit alone.
    [ "$have_workflow_flag" -eq 0 ] || { printf 'HTTP 404: workflow not found on default branch\n' >&2; exit 1; }
    [ -n "$sha" ] || exit 2
    branch="deploy/integration"
    # A foreign workflow may share the commit; the orchestrator must filter it out by name.
    foreign="$(jq -nc --arg sha "$sha" --arg branch "$branch" '{databaseId:999,attempt:1,status:"completed",conclusion:"success",event:"push",headSha:$sha,headBranch:$branch,url:"https://fixture/run/999",workflowName:"CI"}')"
    if [ "${OMNIROUTE_FIXTURE_DUPLICATE_RUNS:-0}" = 1 ]; then
      jq -nc --arg sha "$sha" --arg branch "$branch" --argjson foreign "$foreign" '[{databaseId:12345,attempt:1,status:"queued",conclusion:null,event:"push",headSha:$sha,headBranch:$branch,url:"https://fixture/run/12345",workflowName:"OmniRoute patch artifact"},{databaseId:12346,attempt:1,status:"queued",conclusion:null,event:"push",headSha:$sha,headBranch:$branch,url:"https://fixture/run/12346",workflowName:"OmniRoute patch artifact"},$foreign]'
    else
      jq -nc --arg sha "$sha" --arg branch "$branch" --argjson foreign "$foreign" '[$foreign,{databaseId:12345,attempt:1,status:"queued",conclusion:null,event:"push",headSha:$sha,headBranch:$branch,url:"https://fixture/run/12345",workflowName:"OmniRoute patch artifact"}]'
    fi
    ;;
  'run watch') exit 0 ;;
  'run view')
    sha="$(git --git-dir="$OMNIROUTE_FIXTURE_REMOTE" rev-parse refs/heads/deploy/integration)"
    branch="deploy/integration"
    jq -nc --arg sha "$sha" --arg branch "$branch" '{attempt:1,status:"completed",conclusion:"success",event:"push",headSha:$sha,headBranch:$branch,url:"https://fixture/run/12345"}'
    ;;
  'run download')
    destination=""
    while [ "$#" -gt 0 ]; do
      if [ "$1" = --dir ]; then destination="$2"; break; fi
      shift
    done
    [ -n "$destination" ] || exit 2
    mkdir -p "$destination"
    source_digest="$(git --git-dir="$OMNIROUTE_FIXTURE_REMOTE" rev-parse refs/heads/deploy/integration)"
    branch="deploy/integration"
    source_ref="refs/heads/$branch"
    expected_source="$(jq -r '.manifest.builder.sourceDigest' "$OMNIROUTE_FIXTURE_STAGING/inspection.json")"
    [ "$source_digest" = "$expected_source" ] || { printf 'actual=%s expected=%s\n' "$source_digest" "$expected_source" >"$OMNIROUTE_FIXTURE_STAGING/digest-mismatch"; exit 91; }
    request="$OMNIROUTE_FIXTURE_STAGING/request.json"
    cp "$request" "$destination/request.json"
    cp "$OMNIROUTE_FIXTURE_STAGING/response.tar.gz" "$destination/response.tar.gz"
    printf '{"fixture":"bundle"}\n' >"$destination/attestation-bundle.jsonl"
    jq -n --arg repository nguyenha935/OmniRoute \
      --arg workflow .github/workflows/omniroute-patch-artifact.yml --arg ref "$source_ref" \
      --arg sourceDigest "$source_digest" \
      '{repository:$repository,workflow:$workflow,ref:$ref,sourceDigest:$sourceDigest,runId:12345,runAttempt:1,runnerEnvironment:"github-hosted"}' \
      >"$destination/run.json"
    ;;
  'attestation verify') printf '[{"verificationResult":{"signatureVerification":{"verified":true}}}]\n' ;;
  *) exit 2 ;;
esac
SH
chmod 0755 "$bin/npm" "$bin/sleep" "$bin/openssl" "$bin/date" "$bin/gh"
: >"$fixture/gh.log"

cat >"$fixture/format-wrapper.py" <<PY
#!/usr/bin/env python3
import os
import sys
if len(sys.argv) > 1 and sys.argv[1] == "artifact-id":
    os.execv("$OPS_DIR/artifact-format.py", ["$OPS_DIR/artifact-format.py", *sys.argv[1:]])
if len(sys.argv) > 1 and sys.argv[1] == "canonicalize":
    os.execv("$OPS_DIR/artifact-format.py", ["$OPS_DIR/artifact-format.py", *sys.argv[1:]])
if len(sys.argv) > 1 and sys.argv[1] == "dependency-fingerprint":
    os.execv("$OPS_DIR/artifact-format.py", ["$OPS_DIR/artifact-format.py", *sys.argv[1:]])
if len(sys.argv) > 1 and sys.argv[1] == "fingerprint":
    os.execv("$OPS_DIR/artifact-format.py", ["$OPS_DIR/artifact-format.py", *sys.argv[1:]])
if len(sys.argv) > 1 and sys.argv[1] == "policy":
    os.execv("$OPS_DIR/artifact-format.py", ["$OPS_DIR/artifact-format.py", *sys.argv[1:]])
raise SystemExit(2)
PY
chmod 0755 "$fixture/format-wrapper.py"

run_orchestrator() {
  local output="$1"
  shift
  PATH="$bin:$PATH" \
  OMNIROUTE_ROOT_DIR="$fixture/root" \
  OMNIROUTE_SOURCE_DIR="$source" \
  OMNIROUTE_STATE_DIR="$state" \
  OMNIROUTE_ARTIFACT_DIR="$artifact_root" \
  OMNIROUTE_STAGING_DIR="$staging" \
  OMNIROUTE_INSTALL_DIR="${install_override:-$installed}" \
  OMNIROUTE_ARTIFACT_FORMAT_TOOL="$fixture/format-wrapper.py" \
  OMNIROUTE_ARTIFACT_BUILDER_TOOL="$OPS_DIR/artifact-builder.sh" \
  OMNIROUTE_ARTIFACT_LOCK_FILE="$state/artifact.lock" \
  OMNIROUTE_CANDIDATE_FILE="$state/candidate.json" \
  OMNIROUTE_FIXTURE_GH_LOG="$fixture/gh.log" \
  OMNIROUTE_FIXTURE_SOURCE="$source" \
  OMNIROUTE_FIXTURE_REMOTE="$remote" \
  OMNIROUTE_FIXTURE_STAGING="$fixture/generated" \
    "$ORCHESTRATOR" build --expect-target "$target" --expect-patch-set none \
      --target-ref upstream/release/v3.8.49 --target-version 3.8.49 "$@" >"$output" 2>&1
}

# Generate the exact deterministic request first by allowing orchestration to stop after its mocked duplicate-run gate.
mkdir -p "$fixture/generated"
export GIT_AUTHOR_DATE='2026-07-19T00:00:00Z'
export GIT_COMMITTER_DATE='2026-07-19T00:00:00Z'
if OMNIROUTE_FIXTURE_DUPLICATE_RUNS=1 run_orchestrator "$fixture/prepare.log"; then
  fail "duplicate exact workflow runs unexpectedly succeeded"
fi
grep -Fq 'more than one workflow run matched immutable deployment commit' "$fixture/prepare.log" \
  || { perl -ne 'print if $. <= 200' "$fixture/prepare.log" >&2; fail "duplicate exact runs did not fail closed"; }
! grep -Fq 'run watch' "$fixture/gh.log" || fail "duplicate-run gate continued to workflow watch"
! grep -Fq 'run download' "$fixture/gh.log" || fail "duplicate-run gate downloaded an ambiguous artifact"
pass "exact-run selection rejects duplicate workflow matches"

branch="deploy/integration"
git --git-dir="$remote" show-ref --verify --quiet "refs/heads/$branch" \
  || fail "integration branch was not created"
! git --git-dir="$remote" show "$branch:$WORKFLOW_PATH" | grep -Fq '.omniroute-deploy/request/request.json' \
  || fail "workflow retains stale request path"
git --git-dir="$remote" show "$branch:.omniroute-deploy/input/request.data" >"$fixture/generated/request.json"
request_sha="$(sha256sum "$fixture/generated/request.json" | awk '{print $1}')"

jq -e \
  --arg policy "$($OPS_DIR/artifact-format.py policy --mode overlay | jq -r '.policyHash')" \
  '.schemaVersion == 2
    and .artifactMode == "overlay"
    and .artifactType == "omniroute-runtime-overlay"
    and .artifactPolicyHash == $policy
    and (.sourcePackageSha256 | test("^[0-9a-f]{64}$"))
    and (.sourceLockSha256 | test("^[0-9a-f]{64}$"))
    and .dependencyFingerprint.dependencies.fixture == "1.0.0"' \
  "$fixture/generated/request.json" >/dev/null \
  || fail "matching dependency fingerprints did not select a canonical overlay request"
grep -Fq 'selected artifact mode=overlay type=omniroute-runtime-overlay' "$fixture/prepare.log" \
  || fail "operator evidence omitted selected overlay lane"

# Build a matching schema-3 response around the reviewed request and immutable deployment commit.
source_digest="$(git --git-dir="$remote" rev-parse "refs/heads/$branch")"
source_ref="refs/heads/$branch"
runtime="$(jq -c '.runtime' "$fixture/generated/request.json")"
request_target="$(jq -r '.targetCommit' "$fixture/generated/request.json")"
request_patch_set="$(jq -r '.patchSetHash' "$fixture/generated/request.json")"
request_build_sha="$(jq -r '.buildSha' "$fixture/generated/request.json")"
request_mode="$(jq -r '.artifactMode' "$fixture/generated/request.json")"
request_type="$(jq -r '.artifactType' "$fixture/generated/request.json")"
request_policy="$(jq -r '.artifactPolicyHash' "$fixture/generated/request.json")"
mkdir -p "$fixture/generated/payload-source/dist" "$fixture/generated/payload-source/bin"
cp "$source/package.json" "$fixture/generated/payload-source/package.json"
printf '%s\n' "$request_build_sha" >"$fixture/generated/payload-source/dist/BUILD_SHA"
printf 'fixture server\n' >"$fixture/generated/payload-source/dist/server.js"
printf '#!/usr/bin/env node\n' >"$fixture/generated/payload-source/bin/omniroute.mjs"
chmod 0755 "$fixture/generated/payload-source/bin/omniroute.mjs"
"$OPS_DIR/artifact-format.py" create-payload --mode "$request_mode" \
  --source "$fixture/generated/payload-source" \
  --output "$fixture/generated/payload.tar.gz" \
  --index-output "$fixture/generated/payload-files.json" \
  --links-output "$fixture/generated/payload-links.json" \
  --production-tree-output "$fixture/generated/payload-production-tree.json" \
  --native-index-output "$fixture/generated/payload-native-files.json"
request_file_sha="$(sha256sum "$fixture/generated/request.json" | awk '{print $1}')"
payload_sha="$(sha256sum "$fixture/generated/payload.tar.gz" | awk '{print $1}')"
index_sha="$(sha256sum "$fixture/generated/payload-files.json" | awk '{print $1}')"
link_index_sha="$(sha256sum "$fixture/generated/payload-links.json" | awk '{print $1}')"
production_tree_sha="$(sha256sum "$fixture/generated/payload-production-tree.json" | awk '{print $1}')"
native_index_sha="$(sha256sum "$fixture/generated/payload-native-files.json" | awk '{print $1}')"
package_sha="$(jq -r '.sourcePackageSha256' "$fixture/generated/request.json")"
lock_sha="$(jq -r '.sourceLockSha256' "$fixture/generated/request.json")"
entry_count="$(jq '.files | length' "$fixture/generated/payload-files.json")"
unpacked_bytes="$(jq '[.files[].size] | add // 0' "$fixture/generated/payload-files.json")"
link_count="$(jq '.links | length' "$fixture/generated/payload-links.json")"
production_count="$(jq '.packages | length' "$fixture/generated/payload-production-tree.json")"
native_count="$(jq '.files | length' "$fixture/generated/payload-native-files.json")"
dependency_fingerprint="$(jq -c '.dependencyFingerprint' "$fixture/generated/request.json")"
jq -n --argjson schemaVersion 3 --arg artifactMode "$request_mode" --arg artifactType "$request_type" \
  --arg artifactPolicyHash "$request_policy" --arg repository diegosouzapw/OmniRoute \
  --arg requestSha256 "$request_file_sha" --arg targetRef upstream/release/v3.8.49 \
  --arg targetCommit "$request_target" --arg version 3.8.49 --arg patchSetHash "$request_patch_set" \
  --arg sourcePackageSha256 "$package_sha" --arg sourceLockSha256 "$lock_sha" \
  --argjson dependencyFingerprint "$dependency_fingerprint" --arg buildSha "$request_build_sha" \
  --arg buildBundler webpack --argjson runtime "$runtime" --arg payloadSha256 "$payload_sha" \
  --arg fileIndexSha256 "$index_sha" --arg linkIndexSha256 "$link_index_sha" \
  --arg productionTreeSha256 "$production_tree_sha" --arg nativeIndexSha256 "$native_index_sha" \
  --argjson payloadEntryCount "$entry_count" --argjson payloadUnpackedBytes "$unpacked_bytes" \
  --argjson payloadLinkCount "$link_count" --argjson productionPackageCount "$production_count" \
  --argjson nativeFileCount "$native_count" --arg builderRef "$source_ref" \
  --arg builderSourceDigest "$source_digest" \
  '{schemaVersion:$schemaVersion,artifactMode:$artifactMode,artifactType:$artifactType,repository:$repository,requestSha256:$requestSha256,targetRef:$targetRef,targetCommit:$targetCommit,version:$version,patchSetHash:$patchSetHash,patches:[],appliedPatches:[],skippedUpstreamedPatches:[],sourcePackageSha256:$sourcePackageSha256,sourceLockSha256:$sourceLockSha256,dependencyFingerprint:$dependencyFingerprint,buildSha:$buildSha,buildBundler:$buildBundler,runtime:$runtime,artifactPolicyHash:$artifactPolicyHash,payloadSha256:$payloadSha256,fileIndexSha256:$fileIndexSha256,linkIndexSha256:$linkIndexSha256,productionTreeSha256:$productionTreeSha256,nativeIndexSha256:$nativeIndexSha256,payloadEntryCount:$payloadEntryCount,payloadUnpackedBytes:$payloadUnpackedBytes,payloadLinkCount:$payloadLinkCount,productionPackageCount:$productionPackageCount,nativeFileCount:$nativeFileCount,builder:{repository:"nguyenha935/OmniRoute",workflow:".github/workflows/omniroute-patch-artifact.yml",ref:$builderRef,sourceDigest:$builderSourceDigest,runId:12345,runAttempt:1,runnerEnvironment:"github-hosted"},createdAt:"2026-07-19T00:00:00Z"}' \
  >"$fixture/generated/manifest.tmp.json"
"$OPS_DIR/artifact-format.py" canonicalize --input "$fixture/generated/manifest.tmp.json" --output "$fixture/generated/artifact-manifest.json"
"$OPS_DIR/artifact-format.py" create-response --manifest "$fixture/generated/artifact-manifest.json" \
  --payload "$fixture/generated/payload.tar.gz" --output "$fixture/generated/response.tar.gz"
"$OPS_DIR/artifact-format.py" artifact-id --archive "$fixture/generated/response.tar.gz" \
  --request "$fixture/generated/request.json" >"$fixture/generated/inspection.json"

# A second transaction reuses the same integration commit and exact run without
# rewriting branch history.
export GIT_AUTHOR_DATE='2026-07-19T00:00:00Z'
export GIT_COMMITTER_DATE='2026-07-19T00:00:00Z'
: >"$fixture/gh.log"
run_orchestrator "$fixture/success.log" \
  || { perl -ne 'print if $. <= 260' "$fixture/success.log" >&2; fail "mocked hosted artifact orchestration"; }
! grep -Eq 'run list.*--workflow' "$fixture/gh.log" || fail "orchestrator selected runs by workflow path (404s on real GitHub)"
grep -Fq 'run watch 12345 --repo nguyenha935/OmniRoute' "$fixture/gh.log" || fail "orchestrator did not watch exact run ID"
grep -Fq "run download 12345 --repo nguyenha935/OmniRoute --name omniroute-patch-" "$fixture/gh.log" || fail "orchestrator did not download exact artifact name"
grep -Fq 'attestation verify' "$fixture/gh.log" || fail "orchestrator did not verify attestation"
grep -Fq -- '--deny-self-hosted-runners' "$fixture/gh.log" || fail "orchestrator did not reject self-hosted attestation"
final_branch="deploy/integration"
final_sha="$(git --git-dir="$remote" rev-parse "refs/heads/$final_branch")"
[ -f "$artifact_root/$target-none/$final_sha/response.tar.gz" ] || fail "content-addressed response was not preserved"
[ -f "$artifact_root/$target-none/$final_sha/local-request.json" ] || fail "local reviewed request was not preserved"
grep -Fq 'resuming published integration request' "$fixture/success.log" \
  || fail "same request did not resume the integration commit"
[ -f "$state/candidate.json" ] || fail "successful build did not persist candidate metadata"
pass "integration commit is reused and exact attested candidate is preserved"

# An identical request must not reuse a published commit whose builder changed.
# The orchestrator must create a new fast-forward commit carrying the reviewed
# builder, format verifier, and workflow before it selects a run.
rm -f "$state/candidate.json"
tamper="$fixture/tamper-integration"
git clone -q "$remote" "$tamper"
git -C "$tamper" config user.name fixture
git -C "$tamper" config user.email fixture@example.invalid
git -C "$tamper" checkout -q "$branch"
printf '\n# stale hosted builder\n' >>"$tamper/.omniroute-deploy/artifact-builder.sh"
git -C "$tamper" add .omniroute-deploy/artifact-builder.sh
git -C "$tamper" commit -qm 'fixture: stale hosted toolchain'
git -C "$tamper" push -q origin "$branch"
tampered_sha="$(git --git-dir="$remote" rev-parse "refs/heads/$branch")"
: >"$fixture/gh.log"
if OMNIROUTE_FIXTURE_DUPLICATE_RUNS=1 run_orchestrator "$fixture/toolchain-refresh.log"; then
  fail "toolchain-refresh duplicate-run fixture unexpectedly succeeded"
fi
grep -Fq 'more than one workflow run matched immutable deployment commit' "$fixture/toolchain-refresh.log" \
  || { perl -ne 'print if $. <= 220' "$fixture/toolchain-refresh.log" >&2; fail "toolchain refresh did not reach exact-run gate"; }
refreshed_sha="$(git --git-dir="$remote" rev-parse "refs/heads/$branch")"
[ "$refreshed_sha" != "$tampered_sha" ] || fail "stale hosted toolchain was incorrectly reused"
git --git-dir="$remote" show "$refreshed_sha:.omniroute-deploy/artifact-builder.sh" \
  | cmp -s - "$OPS_DIR/artifact-builder.sh" \
  || fail "refreshed integration commit does not contain the reviewed builder"
grep -Fq 'publishing integration candidate' "$fixture/toolchain-refresh.log" \
  || fail "toolchain drift did not publish a new integration commit"
pass "integration reuse is bound to the exact hosted toolchain"

# Dependency drift must create a distinct immutable full-package request. The
# requestor selects this lane from exact target-versus-installed fingerprints;
# neither the CLI nor the hosted builder gets a mode override.
drift_installed="$fixture/installed-drift"
mkdir -p "$drift_installed"
cat >"$drift_installed/package.json" <<'JSON'
{"dependencies":{"fixture":"0.9.0"},"engines":{"node":">=22"},"name":"omniroute","optionalDependencies":{},"version":"3.8.48"}
JSON
: >"$fixture/gh.log"
if install_override="$drift_installed" OMNIROUTE_FIXTURE_DUPLICATE_RUNS=1 \
  run_orchestrator "$fixture/full-package.log"; then
  fail "full-package duplicate-run fixture unexpectedly succeeded"
fi
grep -Fq 'more than one workflow run matched immutable deployment commit' "$fixture/full-package.log" \
  || { perl -ne 'print if $. <= 220' "$fixture/full-package.log" >&2; fail "full-package transaction did not reach exact-run gate"; }
grep -Fq 'selected artifact mode=full-package type=omniroute-full-package' "$fixture/full-package.log" \
  || fail "dependency drift did not select full-package lane"
full_branch="deploy/integration"
git --git-dir="$remote" show "$full_branch:.omniroute-deploy/input/request.data" \
  >"$fixture/generated/full-package-request.json"
full_request_sha="$(sha256sum "$fixture/generated/full-package-request.json" | awk '{print $1}')"
[ "$full_request_sha" != "$request_sha" ] \
  || fail "artifact mode did not change canonical request identity"
jq -e \
  --arg policy "$($OPS_DIR/artifact-format.py policy --mode full-package | jq -r '.policyHash')" \
  '.schemaVersion == 2
    and .artifactMode == "full-package"
    and .artifactType == "omniroute-full-package"
    and .artifactPolicyHash == $policy
    and .dependencyFingerprint.dependencies.fixture == "1.0.0"' \
  "$fixture/generated/full-package-request.json" >/dev/null \
  || fail "dependency-drift request does not bind full-package lane contract"
git --git-dir="$remote" show "$full_branch:.omniroute-deploy/input/request-files.data" \
  | jq -e '.schemaVersion == 2 and (.files | map(.path) == ["request.json"])' >/dev/null \
  || fail "full-package request file index does not use schema 2"
! grep -Eq 'npm ci|npm run build|npm install ' "$fixture/full-package.log" \
  || fail "full-package selection performed a local install or build"
pass "dependency drift selects a distinct canonical full-package request without local heavy work"

printf '1..7\n'
