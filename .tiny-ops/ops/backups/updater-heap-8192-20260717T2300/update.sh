#!/usr/bin/env bash
set -euo pipefail

readonly LOG_TAG="[omniroute-update]"
readonly ROOT_DIR="${OMNIROUTE_ROOT_DIR:-/opt/omniroute}"
readonly CONFIG_FILE="${OMNIROUTE_CONFIG_FILE:-$ROOT_DIR/config/omniroute.env}"
readonly DATA_DIR="${OMNIROUTE_DATA_DIR:-$ROOT_DIR/data}"
readonly SOURCE_DIR="${OMNIROUTE_SOURCE_DIR:-$ROOT_DIR/source}"
readonly STATE_DIR="${OMNIROUTE_STATE_DIR:-$ROOT_DIR/state}"
readonly PATCH_STATE_DIR="$STATE_DIR/patches"
readonly COMBINED_PATCH_STATE_FILE="$STATE_DIR/combined-patch.json"
readonly BACKUP_DIR="${OMNIROUTE_BACKUP_DIR:-$ROOT_DIR/backups}"
readonly STAGING_DIR="${OMNIROUTE_STAGING_DIR:-$ROOT_DIR/staging}"
readonly LOCK_FILE="$STATE_DIR/update.lock"
readonly HISTORY_FILE="$STATE_DIR/history.log"
readonly SERVICE_NAME="${OMNIROUTE_SERVICE_NAME:-omniroute.service}"
readonly APP_USER="${OMNIROUTE_APP_USER:-omniroute}"
readonly UPSTREAM_REPO="${OMNIROUTE_UPSTREAM_REPO:-diegosouzapw/OmniRoute}"
readonly INSTALL_DIR="${OMNIROUTE_INSTALL_DIR:-/usr/lib/node_modules/omniroute}"
readonly BUILD_MEMORY_MB="${OMNIROUTE_BUILD_MEMORY_MB:-7168}"
readonly UPDATE_CHANNEL="${OMNIROUTE_UPDATE_CHANNEL:-release}"
MODE="${1:---check}"
EXPECTED_TARGET_COMMIT="${OMNIROUTE_EXPECT_TARGET_COMMIT:-}"
EXPECTED_PATCH_SET_HASH="${OMNIROUTE_EXPECT_PATCH_SET_HASH:-}"

PORT="${OMNIROUTE_PORT:-20130}"
API_PORT="${OMNIROUTE_API_PORT:-20131}"
LIVE_WS_PORT="${OMNIROUTE_LIVE_WS_PORT:-20132}"
CANDIDATE_PORT="${OMNIROUTE_CANDIDATE_PORT:-20133}"
BLOCKERS=0
UPDATE_AVAILABLE=0
CURRENT_VERSION=""
STABLE_VERSION=""
LATEST_VERSION=""
ACTIVE_RELEASE=""
TARGET_KIND=""
TARGET_REF=""
TARGET_REF_LABEL=""
TARGET_COMMIT=""
ACTIVE_PATCH_COUNT=0
SINGLE_PATCH_HEAD=""
PATCH_SET_HASH="none"
BUILD_TREE=""
RUNTIME_PREFIX=""
SOURCE_BUILD_REQUIRED=0
ACTIVE_STAGE=""
DEPLOY_BACKUP=""
DEPLOY_STAMP=""
DEPLOY_MUTATED=0
UPDATE_ATTEMPT_ACTIVE=0
UPDATE_ATTEMPT_STARTED=""
APPLIED_PATCHES=()
SKIPPED_PATCHES=()

log() {
  printf '%s %s\n' "$LOG_TAG" "$*"
}

warn() {
  printf '%s WARNING: %s\n' "$LOG_TAG" "$*" >&2
}

die() {
  printf '%s ERROR: %s\n' "$LOG_TAG" "$*" >&2
  exit 20
}

parse_args() {
  [ "$#" -gt 0 ] && shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --expect-target)
        [ "$#" -ge 2 ] || die "--expect-target requires a 40-character commit SHA"
        EXPECTED_TARGET_COMMIT="$2"
        shift 2
        ;;
      --expect-patch-set)
        [ "$#" -ge 2 ] || die "--expect-patch-set requires a SHA-256 hash or 'none'"
        EXPECTED_PATCH_SET_HASH="$2"
        shift 2
        ;;
      *) die "unknown argument: $1" ;;
    esac
  done
}

require_expected_state() {
  [[ "$EXPECTED_TARGET_COMMIT" =~ ^[0-9a-f]{40}$ ]] \
    || die "--expect-target with the reviewed 40-character commit SHA is required"
  [[ "$EXPECTED_PATCH_SET_HASH" = "none" || "$EXPECTED_PATCH_SET_HASH" =~ ^[0-9a-f]{64}$ ]] \
    || die "--expect-patch-set with the reviewed SHA-256 hash (or 'none') is required"
}

verify_expected_state() {
  local phase="$1"
  [ "$TARGET_COMMIT" = "$EXPECTED_TARGET_COMMIT" ] \
    || die "$phase: target drifted: expected $EXPECTED_TARGET_COMMIT, got ${TARGET_COMMIT:-missing}"
  [ "$PATCH_SET_HASH" = "$EXPECTED_PATCH_SET_HASH" ] \
    || die "$phase: patch set drifted: expected $EXPECTED_PATCH_SET_HASH, got $PATCH_SET_HASH"
  log "$phase: pinned target and patch set verified"
}

record_update_attempt() {
  local result="$1"
  printf '%s attempt result=%s target=%s patches=%s\n' \
    "$(date -Is)" "$result" "${TARGET_COMMIT:-unknown}" "${PATCH_SET_HASH:-unknown}" \
    >>"$HISTORY_FILE"
}

require_root() {
  [ "$(id -u)" -eq 0 ] || die "must run as root"
}

require_source() {
  [ -e "$SOURCE_DIR/.git" ] || die "source repository missing: $SOURCE_DIR"
}

load_runtime_port() {
  if [ -f "$CONFIG_FILE" ]; then
    local configured="" configured_api="" configured_ws=""
    configured="$(sed -n 's/^PORT=//p' "$CONFIG_FILE" | tail -n 1)"
    configured_api="$(sed -n 's/^API_PORT=//p' "$CONFIG_FILE" | tail -n 1)"
    configured_ws="$(sed -n 's/^LIVE_WS_PORT=//p' "$CONFIG_FILE" | tail -n 1)"
    [ -n "$configured" ] && PORT="$configured"
    [ -n "$configured_api" ] && API_PORT="$configured_api"
    [ -n "$configured_ws" ] && LIVE_WS_PORT="$configured_ws"
  fi
}

semver_from_text() {
  grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1
}

current_version() {
  [ -x /usr/bin/omniroute ] || return 1
  /usr/bin/omniroute --version 2>/dev/null | semver_from_text
}

latest_version() {
  npm view omniroute version --prefer-online --json 2>/dev/null | tr -d '"[:space:]'
}

github_api() {
  local endpoint="$1"
  if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    gh api "$endpoint"
  else
    curl -fsSL \
      -H 'Accept: application/vnd.github+json' \
      -H 'User-Agent: omniroute-native-ops' \
      "https://api.github.com/$endpoint"
  fi
}

active_release_branch() {
  local branch=""
  branch="$(git ls-remote --heads "https://github.com/$UPSTREAM_REPO.git" 'refs/heads/release/v*' 2>/dev/null \
    | awk '{sub("refs/heads/", "", $2); print $2}' \
    | sort -V \
    | tail -n 1)"
  printf '%s\n' "$branch"
}

resolve_update_target() {
  local release_version tag_ref
  STABLE_VERSION="$(latest_version || true)"
  ACTIVE_RELEASE="$(active_release_branch)"
  TARGET_KIND="stable"
  TARGET_REF=""
  TARGET_REF_LABEL=""
  TARGET_COMMIT=""

  case "$UPDATE_CHANNEL" in
    release)
      if [ -n "$ACTIVE_RELEASE" ]; then
        release_version="${ACTIVE_RELEASE#release/v}"
        TARGET_KIND="release"
        LATEST_VERSION="$release_version"
        TARGET_REF="refs/heads/$ACTIVE_RELEASE"
        TARGET_REF_LABEL="upstream/$ACTIVE_RELEASE"
        TARGET_COMMIT="$(git ls-remote "https://github.com/$UPSTREAM_REPO.git" "$TARGET_REF" 2>/dev/null | awk 'NR==1 {print $1}')"
        return 0
      fi
      ;;
    stable) ;;
    *) die "unsupported update channel: $UPDATE_CHANNEL (use release or stable)" ;;
  esac

  LATEST_VERSION="$STABLE_VERSION"
  [ -n "$LATEST_VERSION" ] || return 1
  tag_ref="refs/tags/v$LATEST_VERSION"
  TARGET_REF="$tag_ref"
  TARGET_REF_LABEL="$tag_ref"
  TARGET_COMMIT="$(git ls-remote --tags "https://github.com/$UPSTREAM_REPO.git" "$tag_ref^{}" 2>/dev/null | awk 'NR==1 {print $1}')"
  if [ -z "$TARGET_COMMIT" ]; then
    TARGET_COMMIT="$(git ls-remote --tags "https://github.com/$UPSTREAM_REPO.git" "$tag_ref" 2>/dev/null | awk 'NR==1 {print $1}')"
  fi
}

version_is_less_than() {
  local left="$1"
  local right="$2"
  [ "$left" != "$right" ] && [ "$(printf '%s\n%s\n' "$left" "$right" | sort -V | head -n 1)" = "$left" ]
}

open_release_freeze() {
  github_api "repos/$UPSTREAM_REPO/issues?state=open&labels=release-freeze&per_page=10" 2>/dev/null \
    | jq -r '.[0].title // empty' 2>/dev/null || true
}

service_is_active() {
  systemctl is-active --quiet "$SERVICE_NAME"
}

health_is_ok() {
  curl -fsS --max-time 5 "http://127.0.0.1:$PORT/api/monitoring/health" >/dev/null
}


port_is_listening() {
  local port="$1"
  ss -lnt "sport = :$port" | tail -n +2 | grep -q .
}

bridge_is_ok() {
  curl -fsS --max-time 5 "http://127.0.0.1:$API_PORT/v1/models" \
    | jq -e '.data | type == "array"' >/dev/null
}

database_is_ok() {
  [ -f "$DATA_DIR/storage.sqlite" ] \
    && [ "$(sqlite3 -readonly "$DATA_DIR/storage.sqlite" 'PRAGMA quick_check;' 2>/dev/null || true)" = "ok" ]
}

runtime_surface_is_ok() {
  service_is_active \
    && health_is_ok \
    && port_is_listening "$PORT" \
    && port_is_listening "$API_PORT" \
    && port_is_listening "$LIVE_WS_PORT" \
    && bridge_is_ok \
    && database_is_ok
}

wait_for_runtime_surface() {
  local attempts="${1:-60}"
  local interval="${2:-2}"
  local _
  for _ in $(seq 1 "$attempts"); do
    if runtime_surface_is_ok; then
      return 0
    fi
    sleep "$interval"
  done
  return 1
}

node_is_supported() {
  local version major minor
  version="$(node --version 2>/dev/null | sed 's/^v//')"
  major="${version%%.*}"
  minor="${version#*.}"
  minor="${minor%%.*}"
  if [ "$major" = "22" ]; then
    [ "$minor" -ge 22 ]
    return
  fi
  [ "$major" -ge 24 ] && [ "$major" -lt 27 ]
}

patch_metadata_files() {
  [ -d "$PATCH_STATE_DIR" ] || return 0
  find "$PATCH_STATE_DIR" -maxdepth 1 -type f -name '*.json' -print0 2>/dev/null | sort -z
}

metadata_base_commit() {
  local metadata="$1"
  local path="$2"
  local base_commit base
  base="$(jq -r '.base' "$metadata")"
  base_commit="$(git -C "$path" merge-base "upstream/$base" HEAD 2>/dev/null || true)"
  if [ -n "$base_commit" ] && git -C "$path" cat-file -e "$base_commit^{commit}" 2>/dev/null; then
    printf '%s\n' "$base_commit"
    return 0
  fi
  base_commit="$(jq -r '.baseCommit // empty' "$metadata")"
  if [ -n "$base_commit" ] && git -C "$path" cat-file -e "$base_commit^{commit}" 2>/dev/null; then
    printf '%s\n' "$base_commit"
    return 0
  fi
  return 1
}

refresh_patch_state() {
  local metadata branch path head base_commit diff_sha payload=""
  ACTIVE_PATCH_COUNT=0
  SINGLE_PATCH_HEAD=""
  PATCH_SET_HASH="none"

  while IFS= read -r -d '' metadata; do
    branch="$(jq -r '.branch' "$metadata")"
    path="$(jq -r '.path' "$metadata")"
    [ -d "$path" ] || return 1
    [ -z "$(git -C "$path" status --porcelain 2>/dev/null || true)" ] || return 1
    head="$(git -C "$path" rev-parse HEAD 2>/dev/null)" || return 1
    base_commit="$(metadata_base_commit "$metadata" "$path")" || return 1
    diff_sha="$(git -C "$path" diff --binary "$base_commit...HEAD" | sha256sum | awk '{print $1}')"
    payload+="$branch:$head:$diff_sha"$'\n'
    ACTIVE_PATCH_COUNT=$((ACTIVE_PATCH_COUNT + 1))
    SINGLE_PATCH_HEAD="$head"
  done < <(patch_metadata_files)

  if [ "$ACTIVE_PATCH_COUNT" -gt 0 ]; then
    PATCH_SET_HASH="$(printf '%s' "$payload" | sha256sum | awk '{print $1}')"
  fi
}

deployed_patch_set_matches() {
  local deployed_hash deployed_build
  [ "$ACTIVE_PATCH_COUNT" -gt 0 ] || return 0
  deployed_hash="$(jq -r '.patchSetHash // empty' "$STATE_DIR/current.json" 2>/dev/null || true)"
  if [ -n "$deployed_hash" ] && [ "$deployed_hash" = "$PATCH_SET_HASH" ]; then
    return 0
  fi

  deployed_build="$(jq -r '.buildSha // empty' "$STATE_DIR/current.json" 2>/dev/null || true)"
  [ "$ACTIVE_PATCH_COUNT" -eq 1 ] && [ -n "$deployed_build" ] \
    && [[ "$SINGLE_PATCH_HEAD" == "$deployed_build"* ]]
}

deployed_source_commit() {
  local source_commit metadata count=0 fallback=""
  source_commit="$(jq -r '.sourceCommit // empty' "$STATE_DIR/current.json" 2>/dev/null || true)"
  if [ -n "$source_commit" ]; then
    printf '%s\n' "$source_commit"
    return 0
  fi

  while IFS= read -r -d '' metadata; do
    count=$((count + 1))
    fallback="$(jq -r '.baseCommit // empty' "$metadata")"
  done < <(patch_metadata_files)
  [ "$count" -eq 1 ] && printf '%s\n' "$fallback"
}

source_summary() {
  if [ ! -e "$SOURCE_DIR/.git" ]; then
    warn "source repository missing: $SOURCE_DIR"
    BLOCKERS=1
    return
  fi

  local head dirty upstream_sha
  head="$(git -C "$SOURCE_DIR" rev-parse --short HEAD 2>/dev/null || true)"
  dirty="$(git -C "$SOURCE_DIR" status --porcelain 2>/dev/null || true)"
  if [ -n "$ACTIVE_RELEASE" ]; then
    upstream_sha="$(git -C "$SOURCE_DIR" ls-remote upstream "refs/heads/$ACTIVE_RELEASE" 2>/dev/null | awk '{print substr($1,1,12)}')"
  else
    upstream_sha=""
  fi
  log "source-head: ${head:-unknown}"
  log "active-release: ${ACTIVE_RELEASE:-none}"
  log "active-release-remote-head: ${upstream_sha:-unavailable}"
  if [ -n "$dirty" ]; then
    warn "canonical source checkout is dirty; update will not modify or stash it"
  else
    log "source-tree: clean"
  fi
}

patch_summary() {
  local metadata branch base path pr pr_state dirty patch base_commit expected_sha actual_sha snapshot head
  if ! refresh_patch_state; then
    warn "active patch metadata is incomplete, dirty, or references a missing worktree/base"
    BLOCKERS=1
  fi

  if [ "$ACTIVE_PATCH_COUNT" -eq 0 ]; then
    log "patches: none"
    return
  fi

  log "patches:"
  while IFS= read -r -d '' metadata; do
    branch="$(jq -r '.branch' "$metadata")"
    base="$(jq -r '.base' "$metadata")"
    path="$(jq -r '.path' "$metadata")"
    pr="$(jq -r '.pr // empty' "$metadata")"
    patch="$(jq -r '.patch // empty' "$metadata")"
    pr_state="local"
    [ -n "$pr" ] && pr_state="$(gh pr view "$pr" --repo "$UPSTREAM_REPO" --json state --jq .state 2>/dev/null || printf unknown)"
    dirty="clean"
    [ -d "$path" ] && [ -n "$(git -C "$path" status --porcelain 2>/dev/null || true)" ] && dirty="dirty"
    snapshot="missing"
    if [ -d "$path" ] && [ -n "$patch" ] && [ -s "$patch" ]; then
      head="$(git -C "$path" rev-parse HEAD 2>/dev/null || true)"
      base_commit="$(metadata_base_commit "$metadata" "$path" 2>/dev/null || true)"
      if [ -n "$head" ] && [ -n "$base_commit" ]; then
        expected_sha="$(git -C "$path" diff --binary "$base_commit...HEAD" | sha256sum | awk '{print $1}')"
        actual_sha="$(sha256sum "$patch" | awk '{print $1}')"
        [ "$expected_sha" = "$actual_sha" ] && snapshot="current" || snapshot="stale"
      fi
    fi
    log "  $branch base=$base pr=${pr:-none} state=$pr_state tree=$dirty snapshot=$snapshot"
  done < <(patch_metadata_files)

  log "patch-set-hash: $PATCH_SET_HASH"
  if deployed_patch_set_matches; then
    log "patch-deployment: current"
  else
    log "patch-deployment: update-required"
    UPDATE_AVAILABLE=1
  fi
}

collect_check() {
  BLOCKERS=0
  UPDATE_AVAILABLE=0
  load_runtime_port
  CURRENT_VERSION="$(current_version || true)"
  if ! resolve_update_target; then
    LATEST_VERSION=""
  fi

  log "check $(date -Is)"
  log "install-method: native npm/source-patch + systemd"
  log "service: $SERVICE_NAME"
  log "port: 127.0.0.1:$PORT"
  log "current-version: ${CURRENT_VERSION:-missing}"
  log "latest-stable: ${STABLE_VERSION:-unavailable}"
  log "update-channel: $UPDATE_CHANNEL"
  log "target-kind: ${TARGET_KIND:-unavailable}"
  log "target-version: ${LATEST_VERSION:-unavailable}"
  log "target-ref: ${TARGET_REF_LABEL:-unavailable}"
  log "target-commit: ${TARGET_COMMIT:-unavailable}"

  if ! node_is_supported; then
    warn "unsupported Node.js version: $(node --version 2>/dev/null || printf missing)"
    BLOCKERS=1
  else
    log "node: $(node --version)"
  fi
  log "npm: $(npm --version 2>/dev/null || printf missing)"

  if service_is_active; then
    log "service-state: active"
  else
    warn "service is not active"
    BLOCKERS=1
  fi
  if health_is_ok; then
    log "health: healthy"
  else
    warn "health endpoint failed"
    BLOCKERS=1
  fi

  if [ -z "$CURRENT_VERSION" ]; then
    warn "installed version could not be determined"
    BLOCKERS=1
  elif [ -n "$LATEST_VERSION" ]; then
    if version_is_less_than "$CURRENT_VERSION" "$LATEST_VERSION"; then
      UPDATE_AVAILABLE=1
      log "upstream-update: available $CURRENT_VERSION -> $LATEST_VERSION"
    elif version_is_less_than "$LATEST_VERSION" "$CURRENT_VERSION"; then
      log "upstream-update: current version is ahead of target; downgrade disabled"
    elif [ "$TARGET_KIND" = "release" ]; then
      local deployed_source
      deployed_source="$(deployed_source_commit || true)"
      if [ -n "$TARGET_COMMIT" ] && [ "$deployed_source" != "$TARGET_COMMIT" ]; then
        UPDATE_AVAILABLE=1
        log "source-update: available ${deployed_source:-unknown} -> $TARGET_COMMIT"
      else
        log "source-update: up-to-date"
      fi
    else
      log "upstream-update: up-to-date"
    fi
  else
    warn "update target could not be determined"
    BLOCKERS=1
  fi

  if [ -f "$DATA_DIR/storage.sqlite" ]; then
    local db_check
    db_check="$(sqlite3 -readonly "$DATA_DIR/storage.sqlite" 'PRAGMA quick_check;' 2>/dev/null || true)"
    if [ "$db_check" = "ok" ]; then
      log "database: quick_check=ok"
    else
      warn "database quick_check failed"
      BLOCKERS=1
    fi
  else
    warn "database missing: $DATA_DIR/storage.sqlite"
    BLOCKERS=1
  fi

  local free_kb freeze latest_backup
  free_kb="$(df -Pk "$ROOT_DIR" | awk 'NR==2 {print $4}')"
  log "disk-free-gib: $((free_kb / 1024 / 1024))"
  if [ "$free_kb" -lt 15728640 ]; then
    warn "less than 15 GiB free; patched source build and rollback snapshot are unsafe"
    BLOCKERS=1
  fi

  freeze="$(open_release_freeze)"
  log "release-freeze: ${freeze:-none}"
  latest_backup="$(find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d \( -name 'pre-update-*' -o -name 'pre-translation-*' \) 2>/dev/null | sort | tail -n 1)"
  log "latest-backup: ${latest_backup:-none}"
  source_summary
  patch_summary
}

run_check() {
  collect_check
  if [ "$BLOCKERS" -ne 0 ]; then
    return 20
  fi
  if [ "$UPDATE_AVAILABLE" -ne 0 ]; then
    return 10
  fi
  return 0
}

run_verify_runtime() {
  load_runtime_port
  if runtime_surface_is_ok; then
    log "runtime verification: service, DB, dashboard, API bridge, and all listeners healthy"
    return 0
  fi
  die "runtime verification failed"
}

run_preflight() {
  require_root
  require_source
  require_expected_state
  mkdir -p "$STATE_DIR" "$STAGING_DIR"
  collect_check
  [ "$BLOCKERS" -eq 0 ] || die "preflight check has blockers"
  runtime_surface_is_ok || die "preflight runtime surface failed"
  require_current_patch_snapshots
  verify_expected_state "preflight"
  if [ "$UPDATE_AVAILABLE" -eq 0 ]; then
    log "preflight: runtime is already current for the pinned target and patch set"
  else
    log "preflight: update is required and pinned inputs are unchanged"
  fi
  preflight_source_and_patches
}

snapshot_active_patches() {
  local metadata branch
  while IFS= read -r -d '' metadata; do
    branch="$(jq -r '.branch' "$metadata")"
    "$ROOT_DIR/ops/patch.sh" snapshot "$branch"
  done < <(patch_metadata_files)
  refresh_patch_state || die "could not refresh patch set after snapshot"
}

prepare_build_tree() {
  local stage="$1"
  local local_ref
  require_source
  if [ "$TARGET_KIND" = "release" ]; then
    local_ref="refs/remotes/upstream/$ACTIVE_RELEASE"
    git -C "$SOURCE_DIR" fetch upstream "+$TARGET_REF:$local_ref" --tags
  else
    local_ref="refs/tags/v$LATEST_VERSION"
    git -C "$SOURCE_DIR" fetch upstream "+$TARGET_REF:$local_ref" --tags
  fi
  git -C "$SOURCE_DIR" rev-parse -q --verify "$local_ref^{commit}" >/dev/null \
    || die "upstream source ref is unavailable: $TARGET_REF_LABEL"
  BUILD_TREE="$stage/source"
  git -C "$SOURCE_DIR" worktree add --detach "$BUILD_TREE" "$local_ref" >/dev/null
  TARGET_COMMIT="$(git -C "$BUILD_TREE" rev-parse HEAD)"
  log "source-stage: $TARGET_REF_LABEL@$TARGET_COMMIT"
}

cleanup_build_tree() {
  if [ -n "$BUILD_TREE" ] && [ -e "$BUILD_TREE/.git" ]; then
    git -C "$SOURCE_DIR" worktree remove "$BUILD_TREE" --force >/dev/null 2>&1 \
      || warn "could not remove build worktree: $BUILD_TREE"
  fi
  BUILD_TREE=""
}

cleanup_update_workspace() {
  local exit_code=$?
  if [ "$DEPLOY_MUTATED" -eq 1 ] && [ -n "$DEPLOY_BACKUP" ] && [ -n "$DEPLOY_STAMP" ]; then
    warn "update interrupted after package mutation; rolling back"
    rollback_update "$DEPLOY_BACKUP" "$DEPLOY_STAMP" || true
    DEPLOY_MUTATED=0
  fi
  cleanup_build_tree
  if [ -n "$ACTIVE_STAGE" ] && [ -d "$ACTIVE_STAGE" ]; then
    rm -rf -- "$ACTIVE_STAGE"
  fi
  if [ "$UPDATE_ATTEMPT_ACTIVE" -eq 1 ]; then
    record_update_attempt "failed(exit=$exit_code,started=$UPDATE_ATTEMPT_STARTED)"
    UPDATE_ATTEMPT_ACTIVE=0
  fi
  return "$exit_code"
}

cleanup_preflight_workspace() {
  local exit_code=$?
  cleanup_build_tree
  if [ -n "$ACTIVE_STAGE" ] && [ -d "$ACTIVE_STAGE" ]; then
    rm -rf -- "$ACTIVE_STAGE"
  fi
  ACTIVE_STAGE=""
  return "$exit_code"
}

require_current_patch_snapshots() {
  local metadata branch path patch head recorded_commit base_commit expected_sha actual_sha
  while IFS= read -r -d '' metadata; do
    branch="$(jq -r '.branch' "$metadata")"
    path="$(jq -r '.path' "$metadata")"
    patch="$(jq -r '.patch // empty' "$metadata")"
    [ -d "$path" ] || die "$branch: patch worktree is missing"
    [ -z "$(git -C "$path" status --porcelain 2>/dev/null || true)" ] \
      || die "$branch: patch worktree is dirty"
    [ -n "$patch" ] && [ -s "$patch" ] || die "$branch: patch snapshot is missing"
    head="$(git -C "$path" rev-parse HEAD 2>/dev/null)" \
      || die "$branch: patch worktree HEAD is unavailable"
    recorded_commit="$(jq -r '.commit // empty' "$metadata")"
    [ -z "$recorded_commit" ] || [ "$recorded_commit" = "$head" ] \
      || die "$branch: patch metadata commit is stale"
    base_commit="$(metadata_base_commit "$metadata" "$path")" \
      || die "$branch: patch base commit is unavailable"
    expected_sha="$(git -C "$path" diff --binary "$base_commit...HEAD" | sha256sum | awk '{print $1}')"
    actual_sha="$(sha256sum "$patch" | awk '{print $1}')"
    [ "$expected_sha" = "$actual_sha" ] \
      || die "$branch: patch snapshot is stale; run omniroute-patch snapshot first"
  done < <(patch_metadata_files)
  [ "$ACTIVE_PATCH_COUNT" -eq 0 ] \
    || log "preflight: all patch snapshots match their clean worktrees"
}

preflight_source_and_patches() {
  local stamp stage
  if [ "$TARGET_KIND" != "release" ] && [ "$ACTIVE_PATCH_COUNT" -eq 0 ]; then
    log "preflight source dry-run: official stable package requires no source patch probe"
    return 0
  fi

  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  stage="$STAGING_DIR/preflight-$stamp-$$"
  mkdir -p "$stage"
  ACTIVE_STAGE="$stage"
  trap cleanup_preflight_workspace EXIT

  prepare_build_tree "$stage"
  refresh_patch_state || die "preflight could not refresh patch state after target fetch"
  require_current_patch_snapshots
  verify_expected_state "preflight post-fetch"
  if [ "$ACTIVE_PATCH_COUNT" -gt 0 ]; then
    apply_patch_series
  fi

  cleanup_build_tree
  rm -rf -- "$stage"
  ACTIVE_STAGE=""
  trap - EXIT
  log "preflight source dry-run: pinned target and patch series apply cleanly"
}

combined_patch_for_current_set() {
  [ -f "$COMBINED_PATCH_STATE_FILE" ] || return 1
  local base_commit patch_set patch expected_sha actual_sha
  base_commit="$(jq -r '.baseCommit // empty' "$COMBINED_PATCH_STATE_FILE")"
  patch_set="$(jq -r '.patchSetHash // empty' "$COMBINED_PATCH_STATE_FILE")"
  [ "$base_commit" = "$TARGET_COMMIT" ] || return 1
  [ "$patch_set" = "$PATCH_SET_HASH" ] || return 1

  patch="$(jq -r '.patch // empty' "$COMBINED_PATCH_STATE_FILE")"
  expected_sha="$(jq -r '.patchSha256 // empty' "$COMBINED_PATCH_STATE_FILE")"
  [ -n "$patch" ] && [ -s "$patch" ] \
    || die "combined patch snapshot is missing for the pinned target and patch set"
  actual_sha="$(sha256sum "$patch" | awk '{print $1}')"
  [ -n "$expected_sha" ] && [ "$actual_sha" = "$expected_sha" ] \
    || die "combined patch snapshot checksum mismatch"
  printf '%s\n' "$patch"
}

apply_patch_series() {
  local metadata branch patch combined_patch=""
  APPLIED_PATCHES=()
  SKIPPED_PATCHES=()
  combined_patch="$(combined_patch_for_current_set || true)"
  if [ -n "$combined_patch" ]; then
    if git -C "$BUILD_TREE" apply --reverse --check "$combined_patch" >/dev/null 2>&1; then
      log "patch skip-upstreamed: combined series"
      while IFS= read -r -d '' metadata; do
        SKIPPED_PATCHES+=("$(jq -r '.branch' "$metadata")")
      done < <(patch_metadata_files)
      return 0
    fi
    if git -C "$BUILD_TREE" apply --check "$combined_patch" >/dev/null 2>&1; then
      log "patch apply: combined series for pinned target and patch set"
      git -C "$BUILD_TREE" apply "$combined_patch"
      while IFS= read -r -d '' metadata; do
        APPLIED_PATCHES+=("$(jq -r '.branch' "$metadata")")
      done < <(patch_metadata_files)
      return 0
    fi

    git -C "$BUILD_TREE" apply --check "$combined_patch" || true
    die "combined patch conflicts with $TARGET_REF_LABEL; production was not touched"
  fi

  while IFS= read -r -d '' metadata; do
    branch="$(jq -r '.branch' "$metadata")"
    patch="$(jq -r '.patch // empty' "$metadata")"
    [ -n "$patch" ] && [ -s "$patch" ] || die "$branch: patch snapshot is missing"

    if git -C "$BUILD_TREE" apply --reverse --check "$patch" >/dev/null 2>&1; then
      log "patch skip-upstreamed: $branch"
      SKIPPED_PATCHES+=("$branch")
      continue
    fi
    if git -C "$BUILD_TREE" apply --check "$patch" >/dev/null 2>&1; then
      log "patch apply: $branch"
      git -C "$BUILD_TREE" apply "$patch"
      APPLIED_PATCHES+=("$branch")
      continue
    fi

    git -C "$BUILD_TREE" apply --check "$patch" || true
    die "$branch: patch conflicts with $TARGET_REF_LABEL; production was not touched"
  done < <(patch_metadata_files)
}

build_patched_source() {
  [ "$SOURCE_BUILD_REQUIRED" -eq 1 ] || return 0
  cd "$BUILD_TREE"
  if ! git diff --quiet -- package.json package-lock.json; then
    die "a local patch changes package dependencies; add an explicit dependency migration before update"
  fi

  rm -rf coverage .build dist
  log "installing source dependencies"
  npm ci --no-audit --no-fund
  log "validating source candidate (build scope + core typecheck; lint/tests/coverage stay in PR validation)"
  npm run check:build-scope
  npm run typecheck:core
  if ! git diff --quiet -- src/i18n/messages; then
    node --import tsx/esm --test tests/unit/i18n-vi-completeness.test.ts
  fi
  log "building source candidate once with webpack"
  OMNIROUTE_USE_TURBOPACK=0 \
    OMNIROUTE_BUILD_MEMORY_MB="$BUILD_MEMORY_MB" \
    NEXT_TELEMETRY_DISABLED=1 \
    npm run build:release
  OMNIROUTE_BUILD_SHA="source-${TARGET_COMMIT:0:12}-patch-${PATCH_SET_HASH:0:12}" \
    node scripts/build/write-build-sha.mjs
  repair_known_runtime_timeout_sidecar
  [ -f dist/server.js ] || die "patched build did not produce dist/server.js"
}

repair_known_runtime_timeout_sidecar() {
  local wrapper="$BUILD_TREE/dist/server-ws.mjs"
  local source_import='from "../../src/shared/utils/runtimeTimeouts.ts"'
  local bundled_import='from "./runtime-timeouts.mjs"'
  [ -f "$wrapper" ] || return 0
  if ! grep -Fq "$source_import" "$wrapper"; then
    return 0
  fi

  log "repairing known v3.8.49 runtime-timeout sidecar packaging defect"
  "$BUILD_TREE/node_modules/.bin/esbuild" \
    "$BUILD_TREE/src/shared/utils/runtimeTimeouts.ts" \
    --bundle \
    --platform=node \
    --format=esm \
    --outfile="$BUILD_TREE/dist/runtime-timeouts.mjs"
  node --input-type=module - "$wrapper" "$source_import" "$bundled_import" <<'NODE'
import fs from "node:fs";
const [file, sourceImport, bundledImport] = process.argv.slice(2);
const source = fs.readFileSync(file, "utf8");
if (!source.includes(sourceImport)) process.exit(2);
fs.writeFileSync(file, source.replace(sourceImport, bundledImport));
NODE
}

overlay_built_runtime() {
  local candidate_package="$1"
  local source destination
  [ "$SOURCE_BUILD_REQUIRED" -eq 1 ] || return 0

  rm -rf "$candidate_package/dist"
  cp -a "$BUILD_TREE/dist" "$candidate_package/dist"

  for source in bin @omniroute open-sse src/domain src/lib src/models src/mitm src/server src/shared src/sse src/types; do
    destination="$candidate_package/$source"
    rm -rf "$destination"
    mkdir -p "$(dirname "$destination")"
    rsync -a \
      --exclude='__tests__/' \
      --exclude='*.test.*' \
      --exclude='*.spec.*' \
      "$BUILD_TREE/$source/" "$destination/"
  done

  for source in \
    .env.example README.md LICENSE package.json \
    scripts/build/postinstall.mjs \
    scripts/build/postinstallSupport.mjs \
    scripts/build/runtime-env.mjs \
    scripts/build/colocateOptionals.mjs \
    scripts/build/sync-env.mjs \
    scripts/build/native-binary-compat.mjs \
    scripts/build/build-next-isolated.mjs \
    scripts/postinstall.mjs \
    scripts/dev/responses-ws-proxy.mjs \
    scripts/dev/tls-options.mjs \
    scripts/dev/sync-env.mjs \
    scripts/check/check-supported-node-runtime.ts; do
    [ -e "$BUILD_TREE/$source" ] || continue
    destination="$candidate_package/$source"
    mkdir -p "$(dirname "$destination")"
    rm -rf "$destination"
    cp -a "$BUILD_TREE/$source" "$destination"
  done
}

dependency_fingerprint() {
  local package_file="$1"
  node - "$package_file" <<'NODE'
const pkg = require(process.argv[2]);
const selected = {
  dependencies: pkg.dependencies || {},
  optionalDependencies: pkg.optionalDependencies || {},
  engines: pkg.engines || {},
};
process.stdout.write(JSON.stringify(selected));
NODE
}

require_source_dependencies_compatible() {
  local installed_fingerprint source_fingerprint
  installed_fingerprint="$(dependency_fingerprint "$INSTALL_DIR/package.json")"
  source_fingerprint="$(dependency_fingerprint "$BUILD_TREE/package.json")"
  [ "$installed_fingerprint" = "$source_fingerprint" ] \
    || die "release branch dependencies changed before npm publication; refusing an unsafe source-only dependency migration"
}

stage_runtime() {
  local stage="$1"
  RUNTIME_PREFIX="$stage/runtime"
  local candidate_package="$RUNTIME_PREFIX/lib/node_modules/omniroute"
  if [ "$TARGET_KIND" = "stable" ]; then
    log "staging official omniroute@$LATEST_VERSION in an isolated global prefix"
    npm install -g \
      --prefix "$RUNTIME_PREFIX" \
      "omniroute@$LATEST_VERSION" \
      --include=optional \
      --no-audit \
      --no-fund
  else
    require_source_dependencies_compatible
    log "staging release-branch runtime from the current independent package"
    mkdir -p "$RUNTIME_PREFIX/lib/node_modules" "$RUNTIME_PREFIX/bin"
    cp -a "$INSTALL_DIR" "$candidate_package"
  fi
  overlay_built_runtime "$candidate_package"
  rm -f "$candidate_package/.env"
  ln -sfn ../lib/node_modules/omniroute/bin/omniroute.mjs "$RUNTIME_PREFIX/bin/omniroute"
  [ -x "$RUNTIME_PREFIX/bin/omniroute" ] || die "staged CLI is missing"
  [ -d "$candidate_package" ] || die "staged package is missing"
}

candidate_smoke() {
  local runtime_prefix="$1"
  local stage="$2"
  local candidate="$runtime_prefix/bin/omniroute"
  local candidate_package="$runtime_prefix/lib/node_modules/omniroute"
  local candidate_data="$stage/smoke-data"
  local unit="omniroute-candidate-$$.service"
  local candidate_password candidate_api_port candidate_ws_port candidate_port

  [ -x "$candidate" ] || return 1
  candidate_api_port=$((CANDIDATE_PORT + 1))
  candidate_ws_port=$((CANDIDATE_PORT + 2))
  for candidate_port in "$CANDIDATE_PORT" "$candidate_api_port" "$candidate_ws_port"; do
    if port_is_listening "$candidate_port"; then
      warn "candidate port $candidate_port is already in use"
      return 1
    fi
  done

  mkdir -p "$candidate_data"
  chown -R "$APP_USER:$APP_USER" "$candidate_data"
  candidate_password="$(openssl rand -hex 24)"
  systemd-run \
    --unit="$unit" \
    --collect \
    --uid="$APP_USER" \
    --gid="$APP_USER" \
    --working-directory="$candidate_package" \
    --setenv="HOME=$ROOT_DIR/home" \
    --setenv=NODE_ENV=production \
    --setenv=OMNIROUTE_CLI_SKIP_REPO_ENV=1 \
    --setenv="DATA_DIR=$candidate_data" \
    --setenv="PORT=$CANDIDATE_PORT" \
    --setenv="DASHBOARD_PORT=$CANDIDATE_PORT" \
    --setenv="API_PORT=$candidate_api_port" \
    --setenv="LIVE_WS_PORT=$candidate_ws_port" \
    --setenv=OMNIROUTE_SERVER_HOST=127.0.0.1 \
    --setenv=API_HOST=127.0.0.1 \
    --setenv=LIVE_WS_HOST=127.0.0.1 \
    --setenv="JWT_SECRET=$(openssl rand -base64 48 | tr -d '\n')" \
    --setenv="API_KEY_SECRET=$(openssl rand -hex 32)" \
    --setenv="INITIAL_PASSWORD=$candidate_password" \
    --setenv=DISABLE_SQLITE_AUTO_BACKUP=true \
    --setenv=OMNIROUTE_SKIP_SYSTEM_TRUST=1 \
    "$candidate" serve --port "$CANDIDATE_PORT" --no-open --no-recovery --log >/dev/null

  for _ in $(seq 1 60); do
    if curl -fsS --max-time 4 "http://127.0.0.1:$CANDIDATE_PORT/api/monitoring/health" >/dev/null 2>&1 \
      && curl -fsS --max-time 4 "http://127.0.0.1:$candidate_api_port/v1/models" \
        | jq -e '.data | type == "array"' >/dev/null 2>&1 \
      && port_is_listening "$candidate_ws_port"; then
      systemctl stop "$unit" >/dev/null 2>&1 || true
      log "candidate-smoke: dashboard, API bridge, and live WebSocket listener healthy"
      return 0
    fi
    if ! systemctl is-active --quiet "$unit"; then
      break
    fi
    sleep 2
  done

  journalctl -u "$unit" -n 100 --no-pager >&2 || true
  systemctl stop "$unit" >/dev/null 2>&1 || true
  return 1
}

rollback_update() {
  local backup="$1"
  local failed_stamp="$2"
  local failed_package="$STAGING_DIR/failed-package-$failed_stamp"
  warn "update failed; restoring package and data from $backup"
  systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true

  if [ -d "$INSTALL_DIR" ]; then
    mv "$INSTALL_DIR" "$failed_package"
  fi
  mv "$backup/package" "$INSTALL_DIR"
  ln -sfn ../lib/node_modules/omniroute/bin/omniroute.mjs /usr/bin/omniroute

  if [ -d "$DATA_DIR" ]; then
    mv "$DATA_DIR" "$ROOT_DIR/failed-data-$failed_stamp"
  fi
  if [ -d "$ROOT_DIR/config" ]; then
    mv "$ROOT_DIR/config" "$ROOT_DIR/failed-config-$failed_stamp"
  fi
  tar -C "$ROOT_DIR" -xzf "$backup/data-config.tar.gz"
  chown -R "$APP_USER:$APP_USER" "$DATA_DIR" "$ROOT_DIR/home"
  chown root:root "$ROOT_DIR/config"
  chmod 700 "$ROOT_DIR/config"
  find "$ROOT_DIR/config" -type f -exec chmod 600 {} +

  systemctl start "$SERVICE_NAME"
  if wait_for_runtime_surface 60 2; then
    log "rollback: full runtime surface healthy"
    return 0
  fi
  warn "rollback completed but service is still unhealthy"
  return 1
}

record_current_state() {
  local version="$1"
  local previous="$2"
  local stamp="$3"
  local build_sha="$4"
  local backup="$5"
  local method="native-npm"
  local upstream_tag=""
  local applied_json skipped_json tmp
  if [ "$TARGET_KIND" = "release" ]; then
    method="native-source-release"
  else
    upstream_tag="v$version"
  fi
  [ "${#APPLIED_PATCHES[@]}" -eq 0 ] || method="native-patched-source"
  applied_json="$(printf '%s\n' "${APPLIED_PATCHES[@]}" | jq -Rsc 'split("\n") | map(select(length > 0))')"
  skipped_json="$(printf '%s\n' "${SKIPPED_PATCHES[@]}" | jq -Rsc 'split("\n") | map(select(length > 0))')"
  tmp="$STATE_DIR/current.json.tmp"
  jq -n \
    --arg version "$version" \
    --arg previousVersion "$previous" \
    --arg installedAt "$stamp" \
    --arg method "$method" \
    --arg updateChannel "$UPDATE_CHANNEL" \
    --arg stableVersion "$STABLE_VERSION" \
    --arg upstreamTag "$upstream_tag" \
    --arg sourceRef "$TARGET_REF_LABEL" \
    --arg sourceCommit "$TARGET_COMMIT" \
    --arg buildSha "$build_sha" \
    --arg patchSetHash "$PATCH_SET_HASH" \
    --arg backup "$backup" \
    --argjson appliedPatches "$applied_json" \
    --argjson skippedUpstreamedPatches "$skipped_json" \
    '{version:$version,previousVersion:$previousVersion,installedAt:$installedAt,method:$method,updateChannel:$updateChannel,stableVersion:$stableVersion,upstreamTag:(if $upstreamTag=="" then null else $upstreamTag end),sourceRef:$sourceRef,sourceCommit:$sourceCommit,buildSha:$buildSha,patchSetHash:$patchSetHash,appliedPatches:$appliedPatches,skippedUpstreamedPatches:$skippedUpstreamedPatches,backup:$backup}' \
    >"$tmp"
  mv "$tmp" "$STATE_DIR/current.json"
  printf '%s update %s -> %s build=%s patches=%s healthy\n' \
    "$stamp" "$previous" "$version" "$build_sha" "$PATCH_SET_HASH" >>"$HISTORY_FILE"
}

prune_backups() {
  local keep="${OMNIROUTE_BACKUP_RETENTION:-5}"
  local entry
  mapfile -t old < <(find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -name 'pre-update-*' -printf '%f\n' 2>/dev/null | sort -r | tail -n +$((keep + 1)))
  for entry in "${old[@]}"; do
    rm -rf -- "${BACKUP_DIR:?}/$entry"
  done
}

run_update() {
  require_root
  require_source
  require_expected_state
  mkdir -p "$STATE_DIR" "$STAGING_DIR" "$BACKUP_DIR"
  cd "$ROOT_DIR"
  exec 9>"$LOCK_FILE"
  flock -n 9 || die "another update is already running"

  collect_check
  [ "$BLOCKERS" -eq 0 ] || die "pre-update check has blockers"
  verify_expected_state "pre-update check"
  if [ "$UPDATE_AVAILABLE" -eq 0 ]; then
    log "already current: version=$CURRENT_VERSION patch-set=$PATCH_SET_HASH"
    return 0
  fi

  local free_kb stamp stage backup runtime_prefix candidate_package candidate_version builtin_backup build_sha expected_build_sha
  free_kb="$(df -Pk "$ROOT_DIR" | awk 'NR==2 {print $4}')"
  [ "$free_kb" -ge 15728640 ] || die "less than 15 GiB free"
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  stage="$STAGING_DIR/update-$LATEST_VERSION-$stamp"
  backup="$BACKUP_DIR/pre-update-$stamp-$CURRENT_VERSION-to-$LATEST_VERSION"
  mkdir -p "$stage" "$backup"
  ACTIVE_STAGE="$stage"
  chmod 0755 "$STAGING_DIR" "$stage"
  UPDATE_ATTEMPT_STARTED="$(date -Is)"
  UPDATE_ATTEMPT_ACTIVE=1
  record_update_attempt "started"
  trap cleanup_update_workspace EXIT

  SOURCE_BUILD_REQUIRED=0
  if [ "$TARGET_KIND" = "release" ] || [ "$ACTIVE_PATCH_COUNT" -gt 0 ]; then
    SOURCE_BUILD_REQUIRED=1
  fi
  if [ "$ACTIVE_PATCH_COUNT" -gt 0 ]; then
    snapshot_active_patches
  fi
  verify_expected_state "post-snapshot"
  if [ "$SOURCE_BUILD_REQUIRED" -eq 1 ]; then
    prepare_build_tree "$stage"
    verify_expected_state "post-fetch"
    if [ "$ACTIVE_PATCH_COUNT" -gt 0 ]; then
      apply_patch_series
    else
      APPLIED_PATCHES=()
      SKIPPED_PATCHES=()
    fi
    build_patched_source
  fi

  stage_runtime "$stage"
  runtime_prefix="$RUNTIME_PREFIX"
  candidate_package="$runtime_prefix/lib/node_modules/omniroute"
  candidate_version="$("$runtime_prefix/bin/omniroute" --version 2>/dev/null | semver_from_text || true)"
  [ "$candidate_version" = "$LATEST_VERSION" ] || die "staged version mismatch: ${candidate_version:-missing}"
  candidate_smoke "$runtime_prefix" "$stage" || die "candidate smoke test failed"

  log "creating application backup"
  builtin_backup="pre-update-$stamp"
  runuser -u "$APP_USER" -- env \
    HOME="$ROOT_DIR/home" \
    DATA_DIR="$DATA_DIR" \
    /usr/bin/omniroute backup create --name "$builtin_backup" --retention 10

  log "stopping $SERVICE_NAME for a consistent filesystem snapshot"
  systemctl stop "$SERVICE_NAME"
  if ! tar -C "$ROOT_DIR" -czf "$backup/data-config.tar.gz" data config; then
    systemctl start "$SERVICE_NAME" || true
    die "could not create the consistent data/config snapshot; production package was not changed"
  fi
  printf '%s\n' "$CURRENT_VERSION" >"$backup/version.txt"
  if ! mv "$INSTALL_DIR" "$backup/package"; then
    systemctl start "$SERVICE_NAME" || true
    die "could not move the current package into backup"
  fi
  DEPLOY_BACKUP="$backup"
  DEPLOY_STAMP="$stamp"
  DEPLOY_MUTATED=1
  if ! mv "$candidate_package" "$INSTALL_DIR"; then
    mv "$backup/package" "$INSTALL_DIR" || true
    systemctl start "$SERVICE_NAME" || true
    DEPLOY_MUTATED=0
    die "could not move the candidate package into production"
  fi
  if ! ln -sfn ../lib/node_modules/omniroute/bin/omniroute.mjs /usr/bin/omniroute; then
    rollback_update "$backup" "$stamp" || true
    DEPLOY_MUTATED=0
    return 20
  fi

  if ! systemctl start "$SERVICE_NAME"; then
    rollback_update "$backup" "$stamp" || true
    DEPLOY_MUTATED=0
    return 20
  fi
  if ! wait_for_runtime_surface 60 2; then
    journalctl -u "$SERVICE_NAME" -n 100 --no-pager >&2 || true
    rollback_update "$backup" "$stamp" || true
    DEPLOY_MUTATED=0
    return 20
  fi

  candidate_version="$(current_version || true)"
  if [ "$candidate_version" != "$LATEST_VERSION" ]; then
    warn "running package version mismatch: ${candidate_version:-missing}"
    rollback_update "$backup" "$stamp" || true
    DEPLOY_MUTATED=0
    return 20
  fi

  build_sha="$(cat "$INSTALL_DIR/dist/BUILD_SHA" 2>/dev/null || true)"
  if [ "$SOURCE_BUILD_REQUIRED" -eq 1 ]; then
    expected_build_sha="source-${EXPECTED_TARGET_COMMIT:0:12}-patch-${EXPECTED_PATCH_SET_HASH:0:12}"
    if [ "$build_sha" != "$expected_build_sha" ]; then
      warn "running BUILD_SHA mismatch: expected $expected_build_sha, got ${build_sha:-missing}"
      rollback_update "$backup" "$stamp" || true
      DEPLOY_MUTATED=0
      return 20
    fi
  elif [ -z "$build_sha" ]; then
    build_sha="v$LATEST_VERSION"
  fi
  DEPLOY_MUTATED=0

  if [ -x "$ROOT_DIR/ops/patch.sh" ]; then
    "$ROOT_DIR/ops/patch.sh" cleanup-merged --installed-version "$LATEST_VERSION" \
      || warn "merged-patch cleanup reported a warning; runtime update remains successful"
  fi
  refresh_patch_state || die "runtime is healthy but post-update patch state is invalid"
  record_current_state "$LATEST_VERSION" "$CURRENT_VERSION" "$(date -Is)" "$build_sha" "$backup"
  UPDATE_ATTEMPT_ACTIVE=0
  prune_backups
  cleanup_build_tree
  rm -rf -- "$stage"
  ACTIVE_STAGE=""
  trap - EXIT
  log "updated successfully: $CURRENT_VERSION -> $LATEST_VERSION patch-set=$PATCH_SET_HASH"
}

parse_args "$@"

case "$MODE" in
  --check|check)
    run_check
    ;;
  --preflight|preflight)
    run_preflight
    ;;
  --verify-runtime|verify-runtime)
    run_verify_runtime
    ;;
  --update|update)
    run_update
    ;;
  -h|--help|help)
    printf '%s\n' \
      'Usage:' \
      '  update-omniroute --check' \
      '  update-omniroute --preflight --expect-target <40-char-sha> --expect-patch-set <sha256|none>' \
      '  update-omniroute --verify-runtime' \
      '  update-omniroute --update --expect-target <40-char-sha> --expect-patch-set <sha256|none>' \
      '  --check      read-only health, upstream, and active-patch assessment' \
      '  --preflight  require reviewed target/patch pins and verify them without deploying' \
      '  --verify-runtime  check DB, dashboard, bridge, and listeners without deploying' \
      '  --update     verify pins again, build once, smoke, backup, deploy, and rollback on gate failure'
    ;;
  *)
    printf 'Usage: update-omniroute [--check|--preflight|--verify-runtime|--update] [pin options]\n' >&2
    exit 2
    ;;
esac
