#!/usr/bin/env bash
set -euo pipefail

readonly LOG_TAG="[omniroute-patch]"
readonly ROOT_DIR="${OMNIROUTE_ROOT_DIR:-/opt/omniroute}"
readonly SOURCE_DIR="${OMNIROUTE_SOURCE_DIR:-$ROOT_DIR/source}"
readonly WORKTREE_DIR="$SOURCE_DIR/.claude/worktrees"
readonly STATE_DIR="$ROOT_DIR/state/patches"
readonly ARCHIVE_DIR="$STATE_DIR/archive"
readonly PATCH_DIR="$ROOT_DIR/patches"
readonly STAGING_DIR="$ROOT_DIR/staging"
readonly UPSTREAM_REPO="${OMNIROUTE_UPSTREAM_REPO:-diegosouzapw/OmniRoute}"
readonly FORK_OWNER="${OMNIROUTE_FORK_OWNER:-nguyenha935}"
readonly COMMAND="${1:-status}"

log() {
  printf '%s %s\n' "$LOG_TAG" "$*"
}

warn() {
  printf '%s WARNING: %s\n' "$LOG_TAG" "$*" >&2
}

die() {
  printf '%s ERROR: %s\n' "$LOG_TAG" "$*" >&2
  exit 1
}

require_source() {
  [ -e "$SOURCE_DIR/.git" ] || die "source repository missing: $SOURCE_DIR"
}

require_root() {
  [ "$(id -u)" -eq 0 ] || die "must run as root"
}

safe_slug() {
  printf '%s' "$1" | sed 's#[^A-Za-z0-9._-]#-#g'
}

active_release_branch() {
  local branch
  branch="$(git -C "$SOURCE_DIR" ls-remote --heads upstream 'refs/heads/release/v*' 2>/dev/null \
    | awk '{sub("refs/heads/", "", $2); print $2}' \
    | sort -V \
    | tail -n 1)"
  printf '%s\n' "${branch:-main}"
}

metadata_for_branch() {
  local branch="$1"
  local file
  shopt -s nullglob
  for file in "$STATE_DIR"/*.json; do
    if [ "$(jq -r '.branch' "$file")" = "$branch" ]; then
      printf '%s\n' "$file"
      shopt -u nullglob
      return 0
    fi
  done
  shopt -u nullglob
  return 1
}

write_metadata() {
  local file="$1"
  local branch="$2"
  local base="$3"
  local path="$4"
  local pr="${5:-}"
  local patch="${6:-}"
  local base_commit
  base_commit="$(git -C "$path" rev-parse HEAD)"
  local tmp="$file.tmp"
  jq -n \
    --arg branch "$branch" \
    --arg base "$base" \
    --arg path "$path" \
    --arg pr "$pr" \
    --arg patch "$patch" \
    --arg baseCommit "$base_commit" \
    --arg createdAt "$(date -Is)" \
    '{branch:$branch,base:$base,baseCommit:$baseCommit,path:$path,pr:(if $pr=="" then null else ($pr|tonumber) end),patch:(if $patch=="" then null else $patch end),createdAt:$createdAt}' >"$tmp"
  mv "$tmp" "$file"
}

base_commit_for_patch() {
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

snapshot_to_path() {
  local metadata="$1"
  local path="$2"
  local patch="$3"
  local base_commit head patch_sha tmp metadata_tmp
  base_commit="$(base_commit_for_patch "$metadata" "$path")"
  head="$(git -C "$path" rev-parse HEAD)"
  tmp="$(mktemp "$PATCH_DIR/.snapshot.XXXXXX")"
  metadata_tmp="$metadata.tmp"

  git -C "$path" diff --binary "$base_commit...HEAD" >"$tmp"
  [ -s "$tmp" ] || {
    rm -f "$tmp"
    die "patch is empty: $(jq -r '.branch' "$metadata")"
  }

  mv "$tmp" "$patch"
  patch_sha="$(sha256sum "$patch" | awk '{print $1}')"
  jq \
    --arg patch "$patch" \
    --arg commit "$head" \
    --arg baseCommit "$base_commit" \
    --arg patchSha256 "$patch_sha" \
    '.patch=$patch | .commit=$commit | .baseCommit=$baseCommit | .patchSha256=$patchSha256 | .updatedAt=(now|todate)' \
    "$metadata" >"$metadata_tmp"
  mv "$metadata_tmp" "$metadata"
  log "snapshot: $patch sha256=$patch_sha"
}

new_patch() {
  require_root
  require_source
  local branch="${2:-}"
  local base="${3:-}"
  local slug path metadata
  [ -n "$branch" ] || die "usage: omniroute-patch new <feat|fix|refactor|docs|test|chore/name> [base]"
  [[ "$branch" =~ ^(feat|fix|refactor|docs|test|chore)/[A-Za-z0-9._/-]+$ ]] || die "invalid branch name: $branch"
  base="${base:-$(active_release_branch)}"
  slug="$(safe_slug "$branch")"
  path="$WORKTREE_DIR/$slug"
  metadata="$STATE_DIR/$slug.json"
  [ ! -e "$path" ] || die "worktree already exists: $path"
  [ ! -e "$metadata" ] || die "patch metadata already exists: $metadata"

  mkdir -p "$WORKTREE_DIR" "$STATE_DIR" "$ARCHIVE_DIR" "$PATCH_DIR"
  log "base: upstream/$base"
  git -C "$SOURCE_DIR" fetch upstream "$base" --tags
  git -C "$SOURCE_DIR" worktree add "$path" -b "$branch" "upstream/$base"
  write_metadata "$metadata" "$branch" "$base" "$path"
  log "created: $path"
}

status_patches() {
  require_source
  local file branch base path pr state dirty commit head patch base_commit expected_sha actual_sha snapshot
  shopt -s nullglob
  local files=("$STATE_DIR"/*.json)
  shopt -u nullglob
  if [ "${#files[@]}" -eq 0 ]; then
    log "no active patches"
    return 0
  fi
  for file in "${files[@]}"; do
    branch="$(jq -r '.branch' "$file")"
    base="$(jq -r '.base' "$file")"
    path="$(jq -r '.path' "$file")"
    pr="$(jq -r '.pr // empty' "$file")"
    state="local"
    [ -n "$pr" ] && state="$(gh pr view "$pr" --repo "$UPSTREAM_REPO" --json state --jq .state 2>/dev/null || printf unknown)"
    dirty="clean"
    [ -d "$path" ] && [ -n "$(git -C "$path" status --porcelain 2>/dev/null || true)" ] && dirty="dirty"
    snapshot="missing"
    commit="$(jq -r '.commit // empty' "$file")"
    patch="$(jq -r '.patch // empty' "$file")"
    if [ -d "$path" ]; then
      head="$(git -C "$path" rev-parse HEAD 2>/dev/null || true)"
      base_commit="$(base_commit_for_patch "$file" "$path" 2>/dev/null || true)"
      if [ -n "$patch" ] && [ -s "$patch" ] && [ -n "$base_commit" ]; then
        expected_sha="$(git -C "$path" diff --binary "$base_commit...HEAD" | sha256sum | awk '{print $1}')"
        actual_sha="$(sha256sum "$patch" | awk '{print $1}')"
        if [ "$expected_sha" = "$actual_sha" ] && { [ -z "$commit" ] || [ "$commit" = "$head" ]; }; then
          snapshot="current"
        else
          snapshot="stale"
        fi
      fi
    fi
    log "$branch base=$base pr=${pr:-none} state=$state tree=$dirty snapshot=$snapshot"
  done
}

snapshot_patch() {
  require_root
  require_source
  local branch="${2:-}"
  local metadata path patch slug pr
  [ -n "$branch" ] || die "usage: omniroute-patch snapshot <branch>"
  metadata="$(metadata_for_branch "$branch")" || die "unknown patch branch: $branch"
  path="$(jq -r '.path' "$metadata")"
  [ -d "$path" ] || die "worktree missing: $path"
  [ -z "$(git -C "$path" status --porcelain)" ] || die "worktree is dirty; commit changes before snapshot"

  mkdir -p "$PATCH_DIR"
  slug="$(safe_slug "$branch")"
  pr="$(jq -r '.pr // empty' "$metadata")"
  patch="$(jq -r '.patch // empty' "$metadata")"
  if [ -z "$patch" ]; then
    if [ -n "$pr" ]; then
      patch="$PATCH_DIR/$pr-$slug.patch"
    else
      patch="$PATCH_DIR/local-$slug.patch"
    fi
  fi
  snapshot_to_path "$metadata" "$path" "$patch"
}

find_pr_for_branch() {
  local branch="$1"
  gh api \
    "repos/$UPSTREAM_REPO/pulls?state=all&head=$FORK_OWNER:$branch&per_page=100" \
    --jq '.[0].number // empty'
}

test_patch() {
  require_source
  local branch="${2:-}"
  local metadata path
  [ -n "$branch" ] || die "usage: omniroute-patch test <branch>"
  metadata="$(metadata_for_branch "$branch")" || die "unknown patch branch: $branch"
  path="$(jq -r '.path' "$metadata")"
  [ -d "$path" ] || die "worktree missing: $path"

  cd "$path"
  trap 'rm -rf "$path/coverage" "$path/.build"' EXIT
  if [ ! -d node_modules ]; then
    npm ci
  fi
  npm run lint
  npm run test:unit
  npm run test:vitest
  npm run test:coverage
  rm -rf coverage
  npm run build
  rm -rf .build
  log "validation complete: $branch"
}

open_pr() {
  require_root
  require_source
  gh auth status >/dev/null 2>&1 || die "GitHub CLI is not authenticated"
  local branch="${2:-}"
  local metadata path base pr patch slug
  [ -n "$branch" ] || die "usage: omniroute-patch pr <branch>"
  metadata="$(metadata_for_branch "$branch")" || die "unknown patch branch: $branch"
  path="$(jq -r '.path' "$metadata")"
  base="$(jq -r '.base' "$metadata")"
  [ -d "$path" ] || die "worktree missing: $path"
  [ -z "$(git -C "$path" status --porcelain)" ] || die "worktree is dirty; commit changes before opening the PR"

  git -C "$path" push -u origin "$branch"
  pr="$(find_pr_for_branch "$branch")"
  if [ -z "$pr" ]; then
    (
      cd "$path"
      gh pr create \
        --repo "$UPSTREAM_REPO" \
        --base "$base" \
        --head "$FORK_OWNER:$branch" \
        --draft \
        --fill
    )
    pr="$(find_pr_for_branch "$branch")"
    [ -n "$pr" ] || die "GitHub did not return a PR for $FORK_OWNER:$branch after creation"
  fi

  slug="$(safe_slug "$branch")"
  patch="$PATCH_DIR/$pr-$slug.patch"
  jq --argjson pr "$pr" '.pr=$pr' "$metadata" >"$metadata.tmp"
  mv "$metadata.tmp" "$metadata"
  snapshot_to_path "$metadata" "$path" "$patch"
  log "draft PR: https://github.com/$UPSTREAM_REPO/pull/$pr"
  log "add changelog.d fragment using PR number $pr before marking ready"
}

cleanup_merged() {
  require_root
  require_source
  local installed_version=""
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --installed-version) installed_version="${2:-}"; shift 2 ;;
      *) die "unknown cleanup argument: $1" ;;
    esac
  done
  [ -n "$installed_version" ] || die "--installed-version is required"

  mkdir -p "$ARCHIVE_DIR" "$STAGING_DIR"
  git -C "$SOURCE_DIR" fetch upstream --tags
  local tag="v$installed_version"
  git -C "$SOURCE_DIR" rev-parse -q --verify "refs/tags/$tag" >/dev/null || {
    warn "release tag $tag is not available; no patch cleanup performed"
    return 0
  }

  local metadata branch path pr state patch slug probe
  shopt -s nullglob
  local files=("$STATE_DIR"/*.json)
  shopt -u nullglob
  for metadata in "${files[@]}"; do
    branch="$(jq -r '.branch' "$metadata")"
    path="$(jq -r '.path' "$metadata")"
    pr="$(jq -r '.pr // empty' "$metadata")"
    patch="$(jq -r '.patch // empty' "$metadata")"
    [ -n "$pr" ] || continue
    state="$(gh pr view "$pr" --repo "$UPSTREAM_REPO" --json state --jq .state 2>/dev/null || printf unknown)"
    [ "$state" = "MERGED" ] || continue
    [ -n "$patch" ] && [ -s "$patch" ] || {
      warn "$branch: merged but no patch snapshot is available"
      continue
    }
    if [ -d "$path" ] && [ -n "$(git -C "$path" status --porcelain)" ]; then
      warn "$branch: merged but worktree is dirty; keeping it"
      continue
    fi

    slug="$(safe_slug "$branch")"
    probe="$STAGING_DIR/upstream-check-$slug-$$"
    git -C "$SOURCE_DIR" worktree add --detach "$probe" "refs/tags/$tag" >/dev/null
    if git -C "$probe" apply --reverse --check "$patch" >/dev/null 2>&1; then
      git -C "$SOURCE_DIR" worktree remove "$probe" --force >/dev/null
      [ ! -d "$path" ] || git -C "$SOURCE_DIR" worktree remove "$path"
      git -C "$SOURCE_DIR" branch -D "$branch" >/dev/null 2>&1 || true
      mv "$metadata" "$ARCHIVE_DIR/$(basename "$metadata")"
      log "$branch: merged and included in $tag; local worktree archived"
    else
      git -C "$SOURCE_DIR" worktree remove "$probe" --force >/dev/null
      log "$branch: merged but not yet verifiably included in $tag; keeping it"
    fi
  done
}

case "$COMMAND" in
  new) new_patch "$@" ;;
  status) status_patches ;;
  snapshot) snapshot_patch "$@" ;;
  test) test_patch "$@" ;;
  pr) open_pr "$@" ;;
  cleanup-merged) cleanup_merged "$@" ;;
  -h|--help|help)
    printf '%s\n' \
      'Usage:' \
      '  omniroute-patch status' \
      '  omniroute-patch new <branch> [base]' \
      '  omniroute-patch snapshot <branch>' \
      '  omniroute-patch test <branch>' \
      '  omniroute-patch pr <branch>' \
      '  omniroute-patch cleanup-merged --installed-version <x.y.z>'
    ;;
  *) die "unknown command: $COMMAND" ;;
esac
