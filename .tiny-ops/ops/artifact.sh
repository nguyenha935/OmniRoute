#!/usr/bin/env bash
set -euo pipefail

readonly LOG_TAG="[omniroute-artifact]"
readonly ROOT_DIR="${OMNIROUTE_ROOT_DIR:-/opt/omniroute}"
readonly SOURCE_DIR="${OMNIROUTE_SOURCE_DIR:-$ROOT_DIR/source}"
readonly STATE_DIR="${OMNIROUTE_STATE_DIR:-$ROOT_DIR/state}"
readonly PATCH_STATE_DIR="$STATE_DIR/patches"
readonly ARTIFACT_DIR="${OMNIROUTE_ARTIFACT_DIR:-$ROOT_DIR/artifacts}"
readonly STAGING_DIR="${OMNIROUTE_STAGING_DIR:-$ROOT_DIR/staging}"
readonly FORMAT_TOOL="${OMNIROUTE_ARTIFACT_FORMAT_TOOL:-$ROOT_DIR/ops/artifact-format.py}"
readonly BUILDER_TOOL="${OMNIROUTE_ARTIFACT_BUILDER_TOOL:-$ROOT_DIR/ops/artifact-builder.sh}"
# Read-only: the exact installed package supplies the dependency baseline that
# decides overlay-vs-full-package. Never mutated here.
readonly INSTALL_DIR="${OMNIROUTE_INSTALL_DIR:-/usr/lib/node_modules/omniroute}"
readonly UPSTREAM_REPO="${OMNIROUTE_UPSTREAM_REPO:-diegosouzapw/OmniRoute}"
readonly FORK_REPO="${OMNIROUTE_ARTIFACT_REPOSITORY:-nguyenha935/OmniRoute}"
readonly WORKFLOW_PATH=".github/workflows/omniroute-patch-artifact.yml"
readonly WORKFLOW_NAME="OmniRoute patch artifact"
readonly INTEGRATION_BRANCH="${OMNIROUTE_INTEGRATION_BRANCH:-deploy/integration}"
readonly CANDIDATE_FILE="${OMNIROUTE_CANDIDATE_FILE:-$STATE_DIR/candidate.json}"
readonly LOCK_FILE="${OMNIROUTE_ARTIFACT_LOCK_FILE:-$STATE_DIR/artifact.lock}"
readonly COMMAND="${1:-help}"

EXPECTED_TARGET=""
EXPECTED_PATCH_SET=""
TARGET_REF=""
TARGET_VERSION=""
DEPLOY_TREE=""
DEPLOY_BRANCH=""
DEPLOY_COMMIT=""
WORKSPACE=""
REQUEST_SOURCE_TREE=""
ARTIFACT_MODE=""
ARTIFACT_TYPE=""
DEPLOY_COMMIT_CREATED=0

log() { printf '%s %s\n' "$LOG_TAG" "$*"; }
die() { printf '%s ERROR: %s\n' "$LOG_TAG" "$*" >&2; exit 20; }
safe_slug() { printf '%s' "$1" | sed 's#[^A-Za-z0-9._-]#-#g'; }
sha256_file() { sha256sum "$1" | awk '{print $1}'; }

cleanup() {
  local exit_code=$?
  if [ -n "$DEPLOY_TREE" ] && [ -e "$DEPLOY_TREE/.git" ]; then
    git -C "$SOURCE_DIR" worktree remove "$DEPLOY_TREE" --force >/dev/null 2>&1 || true
  fi
  if [ -n "$REQUEST_SOURCE_TREE" ] && [ -e "$REQUEST_SOURCE_TREE/.git" ]; then
    git -C "$SOURCE_DIR" worktree remove "$REQUEST_SOURCE_TREE" --force >/dev/null 2>&1 || true
  fi
  [ -z "$WORKSPACE" ] || rm -rf -- "$WORKSPACE"
  return "$exit_code"
}

parse_args() {
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --expect-target) EXPECTED_TARGET="${2:-}"; shift 2 ;;
      --expect-patch-set) EXPECTED_PATCH_SET="${2:-}"; shift 2 ;;
      --target-ref) TARGET_REF="${2:-}"; shift 2 ;;
      --target-version) TARGET_VERSION="${2:-}"; shift 2 ;;
      *) die "unknown argument: $1" ;;
    esac
  done
  [[ "$EXPECTED_TARGET" =~ ^[0-9a-f]{40}$ ]] || die "--expect-target requires a 40-character commit SHA"
  [[ "$EXPECTED_PATCH_SET" = "none" || "$EXPECTED_PATCH_SET" =~ ^[0-9a-f]{64}$ ]] \
    || die "--expect-patch-set requires a SHA-256 hash or none"
  [[ "$TARGET_REF" =~ ^upstream/release/v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "unsupported target ref: $TARGET_REF"
  [[ "$TARGET_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "--target-version is required"
}

metadata_base_commit() {
  local metadata="$1" path="$2" base commit
  base="$(jq -r '.base' "$metadata")"
  commit="$(git -C "$path" merge-base "upstream/$base" HEAD 2>/dev/null || true)"
  if [ -n "$commit" ] && git -C "$path" cat-file -e "$commit^{commit}" 2>/dev/null; then
    printf '%s\n' "$commit"
    return
  fi
  commit="$(jq -r '.baseCommit // empty' "$metadata")"
  [ -n "$commit" ] && git -C "$path" cat-file -e "$commit^{commit}" 2>/dev/null \
    || die "$(jq -r '.branch' "$metadata"): base commit unavailable"
  printf '%s\n' "$commit"
}

prepare_request_source() {
  local request_dir="$1" patch_count branch patch_file patch
  local target_package_sha target_lock_sha

  REQUEST_SOURCE_TREE="$WORKSPACE/request-source"
  git -C "$SOURCE_DIR" cat-file -e "$EXPECTED_TARGET^{commit}" \
    || die "pinned target is unavailable in the source repository"
  git -C "$SOURCE_DIR" worktree add --detach "$REQUEST_SOURCE_TREE" "$EXPECTED_TARGET" >/dev/null
  [ "$(git -C "$REQUEST_SOURCE_TREE" rev-parse HEAD)" = "$EXPECTED_TARGET" ] \
    || die "request source target commit mismatch"
  [ -f "$REQUEST_SOURCE_TREE/package.json" ] \
    || die "exact target package.json is missing"
  [ -f "$REQUEST_SOURCE_TREE/package-lock.json" ] \
    || die "exact target package-lock.json is missing"
  target_package_sha="$(sha256_file "$REQUEST_SOURCE_TREE/package.json")"
  target_lock_sha="$(sha256_file "$REQUEST_SOURCE_TREE/package-lock.json")"

  patch_count="$(jq '.patches | length' "$request_dir/patch-list.json")"
  for ((index=0; index<patch_count; index++)); do
    branch="$(jq -r ".patches[$index].branch" "$request_dir/patch-list.json")"
    patch_file="$(jq -r ".patches[$index].file" "$request_dir/patch-list.json")"
    patch="$request_dir/$patch_file"
    if git -C "$REQUEST_SOURCE_TREE" apply --reverse --check "$patch" >/dev/null 2>&1; then
      log "request patch already upstream: $branch"
    elif git -C "$REQUEST_SOURCE_TREE" apply --check "$patch" >/dev/null 2>&1; then
      log "staging request patch: $branch"
      git -C "$REQUEST_SOURCE_TREE" apply "$patch"
    else
      git -C "$REQUEST_SOURCE_TREE" apply --check "$patch" >&2 || true
      die "request patch does not apply to exact target: $branch"
    fi
  done

  [ "$(sha256_file "$REQUEST_SOURCE_TREE/package.json")" = "$target_package_sha" ] \
    || die "local patches must not modify target package.json"
  [ "$(sha256_file "$REQUEST_SOURCE_TREE/package-lock.json")" = "$target_lock_sha" ] \
    || die "local patches must not modify target package-lock.json"
  [ "$(node -p "require('$REQUEST_SOURCE_TREE/package.json').version")" = "$TARGET_VERSION" ] \
    || die "exact target package version does not match requested version"
}

select_artifact_mode() {
  local target_fingerprint="$1" installed_fingerprint="$2"
  if [ "$(jq -cS . <<<"$target_fingerprint")" = "$(jq -cS . <<<"$installed_fingerprint")" ]; then
    ARTIFACT_MODE="overlay"
    ARTIFACT_TYPE="omniroute-runtime-overlay"
  else
    ARTIFACT_MODE="full-package"
    ARTIFACT_TYPE="omniroute-full-package"
  fi
}

build_request() {
  local request_dir="$1" metadata branch path patch commit recorded base_commit patch_sha expected_sha
  local index=0 payload="" patch_json='[]' files_json='[]' filename
  mkdir -p "$request_dir/patches"

  while IFS= read -r -d '' metadata; do
    branch="$(jq -r '.branch' "$metadata")"
    path="$(jq -r '.path' "$metadata")"
    patch="$(jq -r '.patch // empty' "$metadata")"
    [ -d "$path" ] || die "$branch: patch worktree missing"
    [ -z "$(git -C "$path" status --porcelain)" ] || die "$branch: patch worktree is dirty"
    [ -n "$patch" ] && [ -s "$patch" ] || die "$branch: patch snapshot missing"
    commit="$(git -C "$path" rev-parse HEAD)"
    recorded="$(jq -r '.commit // empty' "$metadata")"
    [ -z "$recorded" ] || [ "$recorded" = "$commit" ] || die "$branch: metadata commit is stale"
    base_commit="$(metadata_base_commit "$metadata" "$path")"
    patch_sha="$(sha256_file "$patch")"
    expected_sha="$(git -C "$path" diff --binary "$base_commit...HEAD" | sha256sum | awk '{print $1}')"
    [ "$patch_sha" = "$expected_sha" ] || die "$branch: patch snapshot is stale"
    index=$((index + 1))
    printf -v filename 'patches/%04d-%s.patch' "$index" "$(safe_slug "$branch")"
    install -m 0600 "$patch" "$request_dir/$filename"
    patch_json="$(jq -c \
      --arg branch "$branch" --arg commit "$commit" --arg baseCommit "$base_commit" \
      --arg file "$filename" --arg sha256 "$patch_sha" \
      '. + [{branch:$branch,commit:$commit,baseCommit:$baseCommit,file:$file,sha256:$sha256}]' \
      <<<"$patch_json")"
    files_json="$(jq -c --arg path "$filename" --arg sha256 "$patch_sha" '. + [{path:$path,sha256:$sha256}]' <<<"$files_json")"
    payload+="$branch:$commit:$patch_sha"$'\n'
  done < <(find "$PATCH_STATE_DIR" -maxdepth 1 -type f -name '*.json' -print0 2>/dev/null | sort -z)

  local actual_patch_set="none"
  [ "$index" -eq 0 ] || actual_patch_set="$(printf '%s' "$payload" | sha256sum | awk '{print $1}')"
  [ "$actual_patch_set" = "$EXPECTED_PATCH_SET" ] \
    || die "patch-set drifted: expected $EXPECTED_PATCH_SET, got $actual_patch_set"

  jq -n --argjson patches "$patch_json" '{patches:$patches}' >"$request_dir/patch-list.json"
  prepare_request_source "$request_dir"

  [ -f "$INSTALL_DIR/package.json" ] \
    || die "installed package.json is unavailable for artifact lane selection"
  local npm_version runtime policy_hash nonce created_at expected_build request_tmp
  local source_package_sha source_lock_sha target_fingerprint installed_fingerprint dependency_delta
  source_package_sha="$(sha256_file "$REQUEST_SOURCE_TREE/package.json")"
  source_lock_sha="$(sha256_file "$REQUEST_SOURCE_TREE/package-lock.json")"
  target_fingerprint="$($FORMAT_TOOL dependency-fingerprint --package "$REQUEST_SOURCE_TREE/package.json")"
  installed_fingerprint="$($FORMAT_TOOL dependency-fingerprint --package "$INSTALL_DIR/package.json")"
  select_artifact_mode "$target_fingerprint" "$installed_fingerprint"
  policy_hash="$($FORMAT_TOOL policy --mode "$ARTIFACT_MODE" | jq -r '.policyHash')"
  dependency_delta="$(jq -n --argjson installed "$installed_fingerprint" --argjson target "$target_fingerprint" \
    '{installed:$installed,target:$target}')"
  log "selected artifact mode=$ARTIFACT_MODE type=$ARTIFACT_TYPE"
  log "dependency-delta: $(jq -cS . <<<"$dependency_delta")"

  npm_version="$(npm --version)"
  runtime="$($FORMAT_TOOL fingerprint --npm-version "$npm_version")"
  nonce="$(openssl rand -hex 16)"
  created_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  expected_build="source-${EXPECTED_TARGET:0:12}-patch-${EXPECTED_PATCH_SET:0:12}"
  request_tmp="$request_dir/request.tmp.json"
  jq -n \
    --argjson schemaVersion 2 \
    --arg requestType omniroute-build-request \
    --arg artifactMode "$ARTIFACT_MODE" \
    --arg artifactType "$ARTIFACT_TYPE" \
    --arg artifactPolicyHash "$policy_hash" \
    --arg repository "$UPSTREAM_REPO" \
    --arg targetRef "$TARGET_REF" \
    --arg targetCommit "$EXPECTED_TARGET" \
    --arg version "$TARGET_VERSION" \
    --arg patchSetHash "$EXPECTED_PATCH_SET" \
    --arg buildSha "$expected_build" \
    --arg sourcePackageSha256 "$source_package_sha" \
    --arg sourceLockSha256 "$source_lock_sha" \
    --arg createdAt "$created_at" \
    --arg nonce "$nonce" \
    --argjson runtime "$runtime" \
    --argjson dependencyFingerprint "$target_fingerprint" \
    --argjson patches "$patch_json" \
    '{schemaVersion:$schemaVersion,requestType:$requestType,artifactMode:$artifactMode,artifactType:$artifactType,artifactPolicyHash:$artifactPolicyHash,repository:$repository,targetRef:$targetRef,targetCommit:$targetCommit,version:$version,patchSetHash:$patchSetHash,buildSha:$buildSha,sourcePackageSha256:$sourcePackageSha256,sourceLockSha256:$sourceLockSha256,dependencyFingerprint:$dependencyFingerprint,createdAt:$createdAt,nonce:$nonce,runtime:$runtime,patches:$patches}' \
    >"$request_tmp"
  "$FORMAT_TOOL" canonicalize --input "$request_tmp" --output "$request_dir/request.json"
  rm -f "$request_tmp" "$request_dir/patch-list.json"
  files_json="$(jq -c --arg path request.json --arg sha256 "$(sha256_file "$request_dir/request.json")" '. + [{path:$path,sha256:$sha256}]' <<<"$files_json")"
  jq -n --argjson schemaVersion 2 --argjson files "$files_json" '{schemaVersion:$schemaVersion,files:$files}' \
    >"$request_dir/request-files.tmp.json"
  "$FORMAT_TOOL" canonicalize --input "$request_dir/request-files.tmp.json" --output "$request_dir/request-files.json"
  rm -f "$request_dir/request-files.tmp.json"

  git -C "$SOURCE_DIR" worktree remove "$REQUEST_SOURCE_TREE" --force >/dev/null
  REQUEST_SOURCE_TREE=""
}

write_workflow() {
  local destination="$1"
  mkdir -p "$(dirname "$destination")"
  cat >"$destination" <<'YAML'
name: OmniRoute patch artifact

on:
  push:
    branches:
      - "deploy/integration"

permissions:
  contents: read
  id-token: write
  attestations: write

concurrency:
  group: omniroute-artifact-${{ github.sha }}
  cancel-in-progress: false

jobs:
  build:
    if: github.ref == 'refs/heads/deploy/integration'
    runs-on: ubuntu-24.04
    timeout-minutes: 90
    env:
      CI: "1"
      NEXT_TELEMETRY_DISABLED: "1"
      OMNIROUTE_GITHUB_WORKFLOW: .github/workflows/omniroute-patch-artifact.yml
      OMNIROUTE_NEXT_CACHE_DIR: ${{ github.workspace }}/.omniroute-deploy/cache/next
    steps:
      - name: Checkout immutable deployment request
        uses: actions/checkout@df4cb1c069e1874edd31b4311f1884172cec0e10 # v6.0.2
        with:
          fetch-depth: 1
          persist-credentials: false

      - name: Set up Tiny-compatible Node
        uses: actions/setup-node@249970729cb0ef3589644e2896645e5dc5ba9c38 # v6.2.0
        with:
          node-version: 22.22.3
          cache: npm
          cache-dependency-path: package-lock.json

      - name: Pin npm and validate hosted runtime
        shell: bash
        run: |
          set -euo pipefail
          npm install --global npm@10.9.8 --no-audit --no-fund
          test "$RUNNER_ENVIRONMENT" = github-hosted
          test "$RUNNER_OS" = Linux
          test "$(node --version)" = v22.22.3
          test "$(npm --version)" = 10.9.8
          test "$(node -p 'process.versions.modules')" = 127
          test "$(getconf GNU_LIBC_VERSION)" = 'glibc 2.39'

      - name: Restore Turbopack cache
        uses: actions/cache@0400d5f644dc74513175e3cd8d07132dd4860809 # v4.2.4
        with:
          path: .omniroute-deploy/cache/next
          key: omniroute-next-${{ runner.os }}-${{ hashFiles('package-lock.json') }}-${{ github.sha }}
          restore-keys: |
            omniroute-next-${{ runner.os }}-${{ hashFiles('package-lock.json') }}-

      - name: Validate and pack reviewed request
        shell: bash
        run: |
          set -euo pipefail
          chmod 0755 .omniroute-deploy/artifact-format.py .omniroute-deploy/artifact-builder.sh
          mkdir -p "$RUNNER_TEMP/reviewed-request/patches"
          cp .omniroute-deploy/input/request.data "$RUNNER_TEMP/reviewed-request/request.json"
          cp .omniroute-deploy/input/request-files.data "$RUNNER_TEMP/reviewed-request/request-files.json"
          cp -a .omniroute-deploy/input/patches/. "$RUNNER_TEMP/reviewed-request/patches/"
          .omniroute-deploy/artifact-format.py pack-request \
            --directory "$RUNNER_TEMP/reviewed-request" \
            --output "$RUNNER_TEMP/request.tar.gz"

      - name: Build one reviewed Turbopack artifact
        shell: bash
        run: |
          set -uo pipefail
          mkdir -p .omniroute-deploy/output
          monitor_pid=""
          cleanup_monitor() {
            [ -z "$monitor_pid" ] || kill "$monitor_pid" 2>/dev/null || true
            [ -z "$monitor_pid" ] || wait "$monitor_pid" 2>/dev/null || true
          }
          monitor_resources() {
            while sleep 60; do
              echo "::group::hosted runner resources $(date -u +%Y-%m-%dT%H:%M:%SZ)"
              free -h || true
              ps -eo pid,ppid,rss,vsz,etime,comm --sort=-rss | head -n 16 || true
              echo "::endgroup::"
            done
          }
          trap cleanup_monitor EXIT INT TERM HUP
          monitor_resources &
          monitor_pid=$!
          status=0
          .omniroute-deploy/artifact-builder.sh \
            <"$RUNNER_TEMP/request.tar.gz" \
            >.omniroute-deploy/output/response.tar.gz \
            2>.omniroute-deploy/output/build.log || status=$?
          cleanup_monitor
          monitor_pid=""
          # Always surface the builder log on the console: on failure the upload
          # step is skipped, so the file alone would be lost with the runner.
          echo "::group::artifact builder log"
          cat .omniroute-deploy/output/build.log || true
          echo "::endgroup::"
          if [ "$status" -ne 0 ]; then
            echo "::error::artifact builder exited with status $status"
            exit "$status"
          fi
          set -e
          cp "$RUNNER_TEMP/request.tar.gz" .omniroute-deploy/output/request.tar.gz
          cp "$RUNNER_TEMP/reviewed-request/request.json" .omniroute-deploy/output/request.json
          sha256sum \
            .omniroute-deploy/output/response.tar.gz \
            .omniroute-deploy/output/request.tar.gz \
            .omniroute-deploy/output/request.json \
            >.omniroute-deploy/output/SHA256SUMS

      - name: Upload builder diagnostics
        if: ${{ always() }}
        uses: actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a # v7.0.1
        with:
          name: omniroute-build-log-${{ github.sha }}
          path: .omniroute-deploy/output/build.log
          if-no-files-found: warn
          compression-level: 0
          retention-days: 30

      - name: Attest exact response archive
        id: attest
        uses: actions/attest-build-provenance@0f67c3f4856b2e3261c31976d6725780e5e4c373 # v4.1.1
        with:
          subject-path: .omniroute-deploy/output/response.tar.gz

      - name: Preserve provenance bundle and run identity
        shell: bash
        env:
          BUNDLE_PATH: ${{ steps.attest.outputs.bundle-path }}
        run: |
          set -euo pipefail
          cp "$BUNDLE_PATH" .omniroute-deploy/output/attestation-bundle.jsonl
          jq -n \
            --arg repository "$GITHUB_REPOSITORY" \
            --arg workflow ".github/workflows/omniroute-patch-artifact.yml" \
            --arg ref "$GITHUB_REF" \
            --arg sourceDigest "$GITHUB_SHA" \
            --argjson runId "$GITHUB_RUN_ID" \
            --argjson runAttempt "$GITHUB_RUN_ATTEMPT" \
            '{repository:$repository,workflow:$workflow,ref:$ref,sourceDigest:$sourceDigest,runId:$runId,runAttempt:$runAttempt,runnerEnvironment:"github-hosted"}' \
            >.omniroute-deploy/output/run.json

      - name: Upload immutable artifact evidence
        uses: actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a # v7.0.1
        with:
          name: omniroute-patch-${{ github.sha }}
          path: .omniroute-deploy/output/
          if-no-files-found: error
          compression-level: 0
          retention-days: 30
YAML
}

prepare_deployment_commit() {
  local request_dir="$1" request_sha branch deploy_payload commit remote_commit=""
  request_sha="$(sha256sum "$request_dir/request.json" | awk '{print $1}')"
  branch="$INTEGRATION_BRANCH"
  git -C "$SOURCE_DIR" cat-file -e "$EXPECTED_TARGET^{commit}" \
    || die "pinned target is unavailable in the source repository"

  DEPLOY_TREE="$WORKSPACE/deployment-tree"
  remote_commit="$(git -C "$SOURCE_DIR" ls-remote origin "refs/heads/$branch" 2>/dev/null | awk 'NR==1 {print $1}')"
  if [ -n "$remote_commit" ]; then
    git -C "$SOURCE_DIR" fetch --no-tags origin \
      "+refs/heads/$branch:refs/remotes/origin/$branch" >/dev/null
    git -C "$SOURCE_DIR" worktree add --detach "$DEPLOY_TREE" "$remote_commit" >/dev/null
    git -C "$DEPLOY_TREE" read-tree --reset -u "$EXPECTED_TARGET"
  else
    git -C "$SOURCE_DIR" worktree add --detach "$DEPLOY_TREE" "$EXPECTED_TARGET" >/dev/null
  fi

  rm -rf -- "$DEPLOY_TREE/.omniroute-deploy"
  rm -f -- "$DEPLOY_TREE/$WORKFLOW_PATH"
  deploy_payload="$DEPLOY_TREE/.omniroute-deploy"
  mkdir -p "$deploy_payload/input/patches"
  install -m 0600 "$request_dir/request.json" "$deploy_payload/input/request.data"
  install -m 0600 "$request_dir/request-files.json" "$deploy_payload/input/request-files.data"
  cp -a "$request_dir/patches/." "$deploy_payload/input/patches/"
  install -m 0755 "$FORMAT_TOOL" "$deploy_payload/artifact-format.py"
  install -m 0755 "$BUILDER_TOOL" "$deploy_payload/artifact-builder.sh"
  write_workflow "$DEPLOY_TREE/$WORKFLOW_PATH"

  git -C "$DEPLOY_TREE" add -A
  # Intentionally no whitespace-lint gate before committing the payload: the
  # immutable payload embeds the patch snapshots verbatim, and real locale diffs
  # legitimately carry trailing whitespace that such a lint would reject. Payload
  # integrity is bound by the request-SHA branch name and re-hashed per file
  # downstream; a corrupted patch would fail `git apply` on the runner.
  if git -C "$DEPLOY_TREE" diff --cached --quiet; then
    commit="$(git -C "$DEPLOY_TREE" rev-parse HEAD)"
    [ -n "$remote_commit" ] && [ "$commit" = "$remote_commit" ] \
      || die "unchanged integration tree is not bound to the remote integration head"
    log "integration request already published: $request_sha"
  else
    git -C "$DEPLOY_TREE" commit \
      -m "chore(deploy): candidate $request_sha" >/dev/null
    commit="$(git -C "$DEPLOY_TREE" rev-parse HEAD)"
    DEPLOY_COMMIT_CREATED=1
  fi
  [ -z "$(git -C "$DEPLOY_TREE" status --porcelain)" ] || die "deployment worktree is dirty after commit"
  DEPLOY_BRANCH="$branch"
  DEPLOY_COMMIT="$commit"
}

wait_for_run() {
  # The deployment workflow lives only on the integration branch, never on
  # the fork default branch, so `gh run list --workflow <path>` returns HTTP 404.
  # Select by the exact integration commit and push event instead, then keep only
  # this workflow by name. No upstream push workflow triggers on deploy/integration,
  # so exactly one run matches; more than one is a fail-closed ambiguity.
  local source_digest="$1" run_json="" matched="" attempt
  for attempt in $(seq 1 30); do
    run_json="$(gh run list --repo "$FORK_REPO" --commit "$source_digest" --event push --limit 20 \
      --json databaseId,attempt,status,conclusion,event,headSha,headBranch,url,workflowName 2>/dev/null || true)"
    if [ -n "$run_json" ] && [ "$(jq 'type' <<<"$run_json" 2>/dev/null)" = '"array"' ]; then
      matched="$(jq -c --arg name "$WORKFLOW_NAME" --arg sha "$source_digest" \
        '[.[] | select(.workflowName==$name and .headSha==$sha and .event=="push")]' <<<"$run_json")"
      if [ "$(jq 'length' <<<"$matched")" -eq 1 ]; then
        jq -c '.[0]' <<<"$matched"
        return
      fi
      [ "$(jq 'length' <<<"$matched")" -le 1 ] || die "more than one workflow run matched immutable deployment commit"
    fi
    sleep 10
  done
  die "GitHub Actions did not create a run for deployment commit $source_digest"
}

verify_downloaded_artifact() {
  local destination="$1" request_file="$2" branch="$3" source_digest="$4" run_id="$5" run_attempt="$6"
  local response="$destination/response.tar.gz" bundle="$destination/attestation-bundle.jsonl"
  local downloaded_request="$destination/request.json" run_file="$destination/run.json" verification="$destination/attestation-verification.json"
  [ -f "$response" ] && [ -f "$bundle" ] && [ -f "$downloaded_request" ] && [ -f "$run_file" ] \
    || die "downloaded artifact evidence is incomplete"
  cmp -s "$request_file" "$downloaded_request" || die "downloaded request differs from the local reviewed request"
  jq -e \
    --arg repo "$FORK_REPO" --arg workflow "$WORKFLOW_PATH" --arg ref "refs/heads/$branch" \
    --arg source "$source_digest" --argjson runId "$run_id" --argjson attempt "$run_attempt" \
    '.repository==$repo and .workflow==$workflow and .ref==$ref and .sourceDigest==$source and .runId==$runId and .runAttempt==$attempt and .runnerEnvironment=="github-hosted"' \
    "$run_file" >/dev/null || die "downloaded GitHub run identity mismatch"

  gh attestation verify "$response" \
    --repo "$FORK_REPO" \
    --bundle "$bundle" \
    --signer-workflow "$FORK_REPO/$WORKFLOW_PATH" \
    --source-ref "refs/heads/$branch" \
    --source-digest "$source_digest" \
    --deny-self-hosted-runners \
    --format json >"$verification" \
    || die "GitHub artifact attestation verification failed"
  jq -e 'type=="array" and length>0' "$verification" >/dev/null \
    || die "GitHub attestation verifier returned no verified statements"

  local inspection artifact_id manifest_id
  inspection="$($FORMAT_TOOL artifact-id --archive "$response" --request "$request_file")" \
    || die "inner artifact inspection failed"
  artifact_id="$(jq -r '.artifactId' <<<"$inspection")"
  manifest_id="$(jq -r '.manifestSha256' <<<"$inspection")"
  jq -e \
    --arg repo "$FORK_REPO" --arg workflow "$WORKFLOW_PATH" --arg ref "refs/heads/$branch" \
    --arg source "$source_digest" --argjson runId "$run_id" --argjson attempt "$run_attempt" \
    '.manifest.builder.repository==$repo and .manifest.builder.workflow==$workflow and .manifest.builder.ref==$ref and .manifest.builder.sourceDigest==$source and .manifest.builder.runId==$runId and .manifest.builder.runAttempt==$attempt and .manifest.builder.runnerEnvironment=="github-hosted"' \
    <<<"$inspection" >/dev/null || die "inner artifact builder provenance mismatch"
  jq -e --arg target "$EXPECTED_TARGET" --arg patches "$EXPECTED_PATCH_SET" \
    --arg mode "$ARTIFACT_MODE" --arg type "$ARTIFACT_TYPE" \
    '.manifest.targetCommit==$target and .manifest.patchSetHash==$patches and .manifest.artifactMode==$mode and .manifest.artifactType==$type' \
    <<<"$inspection" >/dev/null || die "inner artifact target, patch-set, or lane mismatch"

  log "artifact: $response"
  log "artifact-mode: $ARTIFACT_MODE"
  log "artifact-sha256: $artifact_id"
  log "manifest-sha256: $manifest_id"
  log "deployment-source: $source_digest"
  log "workflow-run: $run_id attempt=$run_attempt"
}

request_identity() {
  jq -cS '{
    artifactMode,artifactType,artifactPolicyHash,targetRef,targetCommit,version,
    patchSetHash,buildSha,sourcePackageSha256,sourceLockSha256,
    dependencyFingerprint,runtime,patches
  }' "$1"
}

candidate_is_reusable() {
  local request_file="$1" artifact request candidate_request expected_artifact
  [ -f "$CANDIDATE_FILE" ] || return 1
  artifact="$(jq -r '.artifact // empty' "$CANDIDATE_FILE")"
  candidate_request="$(jq -r '.request // empty' "$CANDIDATE_FILE")"
  expected_artifact="$(jq -r '.artifactId // empty' "$CANDIDATE_FILE")"
  [ -f "$artifact" ] && [ -f "$candidate_request" ] || return 1
  [ "$(sha256_file "$artifact")" = "$expected_artifact" ] || return 1
  [ "$(request_identity "$request_file")" = "$(request_identity "$candidate_request")" ] || return 1
  log "reusing verified candidate: $artifact"
  log "artifact-sha256: $expected_artifact"
  log "manifest-sha256: $(jq -r '.manifestSha256' "$CANDIDATE_FILE")"
  log "deployment-source: $(jq -r '.sourceDigest' "$CANDIDATE_FILE")"
  log "workflow-run: $(jq -r '.runId' "$CANDIDATE_FILE") attempt=$(jq -r '.runAttempt' "$CANDIDATE_FILE")"
}

reuse_published_request() {
  local request_dir="$1" remote_commit published patch_count index patch_file
  remote_commit="$(git -C "$SOURCE_DIR" ls-remote origin "refs/heads/$INTEGRATION_BRANCH" 2>/dev/null | awk 'NR==1 {print $1}')"
  [ -n "$remote_commit" ] || return 1
  git -C "$SOURCE_DIR" fetch --no-tags origin \
    "+refs/heads/$INTEGRATION_BRANCH:refs/remotes/origin/$INTEGRATION_BRANCH" >/dev/null
  published="$WORKSPACE/published-request"
  mkdir -p "$published/patches"
  git -C "$SOURCE_DIR" show \
    "$remote_commit:.omniroute-deploy/input/request.data" >"$published/request.json" 2>/dev/null \
    || return 1
  [ "$(request_identity "$request_dir/request.json")" = "$(request_identity "$published/request.json")" ] \
    || return 1
  git -C "$SOURCE_DIR" show \
    "$remote_commit:.omniroute-deploy/input/request-files.data" >"$published/request-files.json" \
    || die "published integration request file index is missing"
  patch_count="$(jq '.patches | length' "$published/request.json")"
  for ((index=0; index<patch_count; index++)); do
    patch_file="$(jq -r ".patches[$index].file" "$published/request.json")"
    [[ "$patch_file" =~ ^patches/[A-Za-z0-9._-]+\.patch$ ]] \
      || die "published integration request has an unsafe patch path"
    git -C "$SOURCE_DIR" show \
      "$remote_commit:.omniroute-deploy/input/$patch_file" >"$published/$patch_file" \
      || die "published integration patch is missing: $patch_file"
  done
  rm -rf -- "$request_dir"
  mv "$published" "$request_dir"
  DEPLOY_BRANCH="$INTEGRATION_BRANCH"
  DEPLOY_COMMIT="$remote_commit"
  DEPLOY_COMMIT_CREATED=0
  log "resuming published integration request at $remote_commit"
}

write_candidate() {
  local destination="$1" request_file="$2" branch="$3" source_digest="$4" run_id="$5" run_attempt="$6"
  local inspection artifact_id manifest_id request_sha temporary
  inspection="$($FORMAT_TOOL artifact-id \
    --archive "$destination/response.tar.gz" --request "$request_file")"
  artifact_id="$(jq -r '.artifactId' <<<"$inspection")"
  manifest_id="$(jq -r '.manifestSha256' <<<"$inspection")"
  request_sha="$(sha256_file "$request_file")"
  temporary="$CANDIDATE_FILE.tmp"
  jq -n \
    --arg createdAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg targetCommit "$EXPECTED_TARGET" \
    --arg targetRef "$TARGET_REF" \
    --arg version "$TARGET_VERSION" \
    --arg patchSetHash "$EXPECTED_PATCH_SET" \
    --arg requestSha256 "$request_sha" \
    --arg artifact "$destination/response.tar.gz" \
    --arg request "$destination/local-request.json" \
    --arg attestationBundle "$destination/attestation-bundle.jsonl" \
    --arg runIdentity "$destination/run.json" \
    --arg artifactId "$artifact_id" \
    --arg manifestSha256 "$manifest_id" \
    --arg sourceRef "refs/heads/$branch" \
    --arg sourceDigest "$source_digest" \
    --argjson runId "$run_id" \
    --argjson runAttempt "$run_attempt" \
    '{schemaVersion:1,createdAt:$createdAt,targetCommit:$targetCommit,targetRef:$targetRef,version:$version,patchSetHash:$patchSetHash,requestSha256:$requestSha256,artifact:$artifact,request:$request,attestationBundle:$attestationBundle,runIdentity:$runIdentity,artifactId:$artifactId,manifestSha256:$manifestSha256,sourceRef:$sourceRef,sourceDigest:$sourceDigest,runId:$runId,runAttempt:$runAttempt}' \
    >"$temporary"
  mv "$temporary" "$CANDIDATE_FILE"
  chmod 0600 "$CANDIDATE_FILE"
}

build_artifact() {
  parse_args "$@"
  [ "$(id -u)" -eq 0 ] || die "must run as root"
  [ -x "$FORMAT_TOOL" ] || die "artifact format tool is missing"
  [ -x "$BUILDER_TOOL" ] || die "artifact builder tool is missing"
  [ -e "$SOURCE_DIR/.git" ] || die "source repository missing"
  command -v gh >/dev/null || die "GitHub CLI is unavailable"
  gh auth status >/dev/null 2>&1 || die "GitHub CLI is not authenticated"
  mkdir -p "$ARTIFACT_DIR" "$STATE_DIR" "$STAGING_DIR"
  exec 8>"$LOCK_FILE"
  flock -n 8 || die "another artifact build is already running"

  WORKSPACE="$(mktemp -d "$STAGING_DIR/artifact-request.XXXXXX")"
  trap cleanup EXIT INT TERM HUP
  local request_dir="$WORKSPACE/request"
  mkdir -p "$request_dir"
  build_request "$request_dir"
  if candidate_is_reusable "$request_dir/request.json"; then
    rm -rf -- "$WORKSPACE"
    WORKSPACE=""
    trap - EXIT INT TERM HUP
    return 0
  fi

  local branch source_digest run_json run_id run_attempt destination artifact_name
  if ! reuse_published_request "$request_dir"; then
    prepare_deployment_commit "$request_dir"
  fi
  branch="$DEPLOY_BRANCH"
  source_digest="$DEPLOY_COMMIT"
  [[ "$source_digest" =~ ^[0-9a-f]{40}$ ]] || die "could not determine deployment commit"
  if [ "$DEPLOY_COMMIT_CREATED" -eq 1 ]; then
    log "publishing integration candidate $branch at $source_digest"
    git -C "$DEPLOY_TREE" push origin "HEAD:refs/heads/$branch"
  else
    log "integration candidate already exists at $source_digest"
  fi

  run_json="$(wait_for_run "$source_digest")"
  run_id="$(jq -r '.databaseId' <<<"$run_json")"
  run_attempt="$(jq -r '.attempt' <<<"$run_json")"
  log "waiting for GitHub-hosted workflow run $run_id"
  gh run watch "$run_id" --repo "$FORK_REPO" --exit-status --interval 20 \
    || die "GitHub-hosted artifact build failed; no local build fallback"

  run_json="$(gh run view "$run_id" --repo "$FORK_REPO" --json attempt,status,conclusion,event,headSha,headBranch,url)"
  jq -e \
    --arg sha "$source_digest" --arg branch "$branch" \
    '.status=="completed" and .conclusion=="success" and .event=="push" and .headSha==$sha and .headBranch==$branch' \
    <<<"$run_json" >/dev/null || die "completed workflow run identity or result mismatch"
  run_attempt="$(jq -r '.attempt' <<<"$run_json")"
  artifact_name="omniroute-patch-$source_digest"
  destination="$ARTIFACT_DIR/${EXPECTED_TARGET}-${EXPECTED_PATCH_SET}/$source_digest"
  [ ! -e "$destination" ] || die "content-addressed artifact destination already exists: $destination"
  mkdir -p "$destination"
  gh run download "$run_id" --repo "$FORK_REPO" --name "$artifact_name" --dir "$destination" \
    || die "could not download exact workflow artifact"
  install -m 0600 "$request_dir/request.json" "$destination/local-request.json"
  verify_downloaded_artifact "$destination" "$request_dir/request.json" "$branch" "$source_digest" "$run_id" "$run_attempt"
  write_candidate "$destination" "$request_dir/request.json" "$branch" "$source_digest" "$run_id" "$run_attempt"

  if [ -n "$DEPLOY_TREE" ] && [ -e "$DEPLOY_TREE/.git" ]; then
    git -C "$SOURCE_DIR" worktree remove "$DEPLOY_TREE" --force >/dev/null
    DEPLOY_TREE=""
  fi
  rm -rf -- "$WORKSPACE"
  WORKSPACE=""
  trap - EXIT INT TERM HUP
}

case "$COMMAND" in
  build) build_artifact "$@" ;;
  -h|--help|help)
    printf '%s\n' 'Usage: artifact.sh build --expect-target <sha40> --expect-patch-set <sha256|none> --target-ref upstream/release/vX.Y.Z --target-version X.Y.Z'
    ;;
  *) die "unknown command: $COMMAND" ;;
esac
