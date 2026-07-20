#!/usr/bin/env bash
set -euo pipefail

readonly OPS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly DEPLOY="$OPS_DIR/deploy.sh"

fail() { printf 'not ok - %s\n' "$*" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$*"; }

bash -n "$DEPLOY" || fail "deploy syntax"
! grep -Eq 'npm ci|npm run build|npm install ' "$DEPLOY" \
  || fail "automatic deploy contains a Tiny build"
grep -Fq 'candidate_args' "$DEPLOY" || fail "automatic deploy does not resolve candidate pins"
grep -Fq -- '--allow-ancestor-target' "$DEPLOY" || fail "moving release head is not handled"
pass "automatic deploy is artifact-only and pin-aware"

fixture="$(mktemp -d "${TMPDIR:-/tmp}/omniroute-auto-deploy.XXXXXX")"
trap 'rm -rf -- "$fixture"' EXIT
mkdir -p "$fixture/state" "$fixture/bin" "$fixture/artifact"
target="$(printf 'a%.0s' {1..40})"
new_target="$(printf 'c%.0s' {1..40})"
patch_set="$(printf 'b%.0s' {1..64})"
source_digest="$(printf 'd%.0s' {1..40})"
artifact_id="$(printf 'e%.0s' {1..64})"
manifest_id="$(printf 'f%.0s' {1..64})"
touch "$fixture/artifact/response.tar.gz" "$fixture/artifact/request.json" \
  "$fixture/artifact/attestation-bundle.jsonl" "$fixture/artifact/run.json"

cat >"$fixture/bin/core-update" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$FIXTURE_LOG"
case "${1:-}" in
  --check)
    count="$(cat "$FIXTURE_COUNT" 2>/dev/null || printf 0)"
    count=$((count + 1))
    printf '%s\n' "$count" >"$FIXTURE_COUNT"
    printf '[omniroute-update] target-commit: %s\n' \
      "$([ "$count" -eq 1 ] || [ "${FIXTURE_ADVANCE:-0}" -eq 0 ] && printf '%s' "$FIXTURE_TARGET" || printf '%s' "$FIXTURE_NEW_TARGET")"
    printf '[omniroute-update] target-ref: upstream/release/v3.8.49\n'
    printf '[omniroute-update] patch-set-hash: %s\n' "$FIXTURE_PATCH_SET"
    [ "${FIXTURE_CURRENT:-0}" -eq 0 ] || exit 0
    exit 10
    ;;
  --build-artifact)
    jq -n \
      --arg targetCommit "$FIXTURE_TARGET" --arg targetRef upstream/release/v3.8.49 \
      --arg version 3.8.49 --arg patchSetHash "$FIXTURE_PATCH_SET" \
      --arg artifact "$FIXTURE_ARTIFACT/response.tar.gz" \
      --arg request "$FIXTURE_ARTIFACT/request.json" \
      --arg attestationBundle "$FIXTURE_ARTIFACT/attestation-bundle.jsonl" \
      --arg runIdentity "$FIXTURE_ARTIFACT/run.json" \
      --arg artifactId "$FIXTURE_ARTIFACT_ID" --arg manifestSha256 "$FIXTURE_MANIFEST_ID" \
      --arg sourceRef refs/heads/deploy/integration --arg sourceDigest "$FIXTURE_SOURCE_DIGEST" \
      '{schemaVersion:1,targetCommit:$targetCommit,targetRef:$targetRef,version:$version,patchSetHash:$patchSetHash,artifact:$artifact,request:$request,attestationBundle:$attestationBundle,runIdentity:$runIdentity,artifactId:$artifactId,manifestSha256:$manifestSha256,sourceRef:$sourceRef,sourceDigest:$sourceDigest,runId:123,runAttempt:1}' \
      >"$FIXTURE_CANDIDATE"
    ;;
  --preflight|--update|--verify-runtime) ;;
  *) exit 2 ;;
esac
SH
chmod 0755 "$fixture/bin/core-update"
cat >"$fixture/bin/flock" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod 0755 "$fixture/bin/flock"

run_fixture() {
  : >"$fixture/calls.log"
  : >"$fixture/count"
  rm -f "$fixture/state/candidate.json"
  PATH="$fixture/bin:$PATH" FIXTURE_LOG="$fixture/calls.log" FIXTURE_COUNT="$fixture/count" \
  FIXTURE_TARGET="$target" FIXTURE_NEW_TARGET="$new_target" FIXTURE_PATCH_SET="$patch_set" \
  FIXTURE_ARTIFACT="$fixture/artifact" FIXTURE_ARTIFACT_ID="$artifact_id" \
  FIXTURE_MANIFEST_ID="$manifest_id" FIXTURE_SOURCE_DIGEST="$source_digest" \
  FIXTURE_CANDIDATE="$fixture/state/candidate.json" \
  OMNIROUTE_ROOT_DIR="$fixture" OMNIROUTE_CORE_UPDATE="$fixture/bin/core-update" \
  OMNIROUTE_CANDIDATE_FILE="$fixture/state/candidate.json" \
  OMNIROUTE_DEPLOY_LOCK_FILE="$fixture/state/deploy.lock" \
    "$DEPLOY" update >"$fixture/output.log" 2>&1
}

run_fixture || { cat "$fixture/output.log" >&2; fail "exact automatic deploy"; }
grep -Fq -- "--build-artifact --expect-target $target --expect-patch-set $patch_set" "$fixture/calls.log" \
  || fail "candidate build was not pinned automatically"
grep -Fq -- "--preflight --expect-target $target --expect-patch-set $patch_set" "$fixture/calls.log" \
  || fail "artifact preflight was not called"
grep -Fq -- "--update --expect-target $target --expect-patch-set $patch_set" "$fixture/calls.log" \
  || fail "artifact install was not called"
grep -Fq -- '--expect-artifact-ref refs/heads/deploy/integration' "$fixture/calls.log" \
  || fail "integration artifact provenance was not forwarded"
grep -Fxq -- '--verify-runtime' "$fixture/calls.log" || fail "runtime was not verified"
pass "one update command builds, pins, preflights, deploys, and verifies"

FIXTURE_ADVANCE=1 run_fixture \
  || { cat "$fixture/output.log" >&2; fail "ancestor automatic deploy"; }
grep -Fq -- "--allow-ancestor-target --expect-current-head $new_target" "$fixture/calls.log" \
  || fail "moving release head did not use bounded ancestor mode"
pass "release movement during build no longer forces a rebuild loop"

printf '1..3\n'
