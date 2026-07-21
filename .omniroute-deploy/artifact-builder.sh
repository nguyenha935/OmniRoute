#!/usr/bin/env bash
set -euo pipefail

readonly LOG_TAG="[omniroute-builder]"
readonly FORMAT_TOOL="${OMNIROUTE_ARTIFACT_FORMAT_TOOL:-${GITHUB_WORKSPACE:-}/.omniroute-deploy/artifact-format.py}"
readonly WORK_ROOT="${OMNIROUTE_BUILDER_WORK_ROOT:-${RUNNER_TEMP:-}/omniroute-builder}"
readonly REPOSITORY_URL="${OMNIROUTE_REPOSITORY_URL:-https://github.com/diegosouzapw/OmniRoute.git}"
# GitHub-hosted ubuntu-24.04 public runners have 16 GB RAM. Keep Webpack's V8 heap
# at 6 GiB so npm, native modules and the OS retain real headroom. Turbopack is
# intentionally disabled below: its Rust graph reached 15.1 GiB RSS plus 3 GiB
# swap on this source tree and was killed by the hosted runner.
readonly BUILD_MEMORY_MB="${OMNIROUTE_BUILD_MEMORY_MB:-6144}"
readonly BUILDER_REPOSITORY="${GITHUB_REPOSITORY:-}"
readonly BUILDER_WORKFLOW="${OMNIROUTE_GITHUB_WORKFLOW:-.github/workflows/omniroute-patch-artifact.yml}"
readonly BUILDER_REF="${GITHUB_REF:-}"
readonly BUILDER_SOURCE_DIGEST="${GITHUB_SHA:-}"
readonly BUILDER_RUN_ID="${GITHUB_RUN_ID:-}"
readonly BUILDER_RUN_ATTEMPT="${GITHUB_RUN_ATTEMPT:-}"
readonly RUNNER_ENVIRONMENT_VALUE="${RUNNER_ENVIRONMENT:-}"
readonly NEXT_CACHE_DIR="${OMNIROUTE_NEXT_CACHE_DIR:-}"

log() { printf '%s %s\n' "$LOG_TAG" "$*" >&2; }
die() { printf '%s ERROR: %s\n' "$LOG_TAG" "$*" >&2; exit 20; }

cleanup() {
  local exit_code=$?
  [ -z "${WORKSPACE:-}" ] || rm -rf -- "$WORKSPACE"
  return "$exit_code"
}

restore_next_cache() {
  [ -n "$NEXT_CACHE_DIR" ] && [ -d "$NEXT_CACHE_DIR" ] || return 0
  local source_cache="$SOURCE_TREE/.build/next/cache"
  mkdir -p "$source_cache"
  cp -a -- "$NEXT_CACHE_DIR/." "$source_cache/"
  log "restored Next.js build cache"
}

save_next_cache() {
  local source_cache="$SOURCE_TREE/.build/next/cache"
  [ -n "$NEXT_CACHE_DIR" ] && [ -d "$source_cache" ] || return 0
  rm -rf -- "$NEXT_CACHE_DIR"
  mkdir -p "$NEXT_CACHE_DIR"
  cp -a -- "$source_cache/." "$NEXT_CACHE_DIR/"
  log "saved Next.js build cache"
}

prepare_typecheck_baseline() {
  git -C "$SOURCE_TREE" worktree add --detach "$BASELINE_TREE" "$target" >/dev/null
  if [ -d "$SOURCE_TREE/node_modules" ] && [ ! -e "$BASELINE_TREE/node_modules" ]; then
    ln -s "$SOURCE_TREE/node_modules" "$BASELINE_TREE/node_modules"
  fi
}

typecheck_signatures() {
  local input="$1" output="$2"
  sed -E \
    -e "s#${SOURCE_TREE//\#/\\#}#<source>#g" \
    -e "s#${BASELINE_TREE//\#/\\#}#<source>#g" \
    -e 's/^([^(:]+)\([0-9]+,[0-9]+\): /\1: /' \
    "$input" \
    | grep -E 'error TS[0-9]+:' \
    | LC_ALL=C sort -u >"$output" || true
}

run_typecheck_regression_gate() {
  local baseline_log="$WORKSPACE/typecheck-baseline.log"
  local candidate_log="$WORKSPACE/typecheck-candidate.log"
  local baseline_signatures="$WORKSPACE/typecheck-baseline.signatures"
  local candidate_signatures="$WORKSPACE/typecheck-candidate.signatures"
  local new_signatures="$WORKSPACE/typecheck-new.signatures"
  local baseline_status=0 candidate_status=0

  prepare_typecheck_baseline
  (cd "$BASELINE_TREE" && npm run typecheck:core >"$baseline_log" 2>&1) \
    || baseline_status=$?
  (cd "$SOURCE_TREE" && npm run typecheck:core >"$candidate_log" 2>&1) \
    || candidate_status=$?

  if [ "$candidate_status" -eq 0 ]; then
    log "typecheck:core passed on patched candidate"
    return 0
  fi

  typecheck_signatures "$baseline_log" "$baseline_signatures"
  typecheck_signatures "$candidate_log" "$candidate_signatures"
  [ "$baseline_status" -ne 0 ] && [ -s "$baseline_signatures" ] \
    || { cat "$candidate_log" >&2; die "typecheck:core failed only on patched candidate"; }
  [ -s "$candidate_signatures" ] \
    || { cat "$candidate_log" >&2; die "candidate typecheck failed without comparable TypeScript diagnostics"; }
  comm -13 "$baseline_signatures" "$candidate_signatures" >"$new_signatures"
  if [ -s "$new_signatures" ]; then
    log "new typecheck:core diagnostics introduced by patches:"
    cat "$new_signatures" >&2
    die "patched candidate regresses the target typecheck baseline"
  fi
  log "typecheck:core target baseline is red, but patches introduce no new diagnostics"
}

sha256_file() {
  sha256sum "$1" | cut -d ' ' -f 1
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

copy_runtime_path() {
  local relative="$1"
  local source="$SOURCE_TREE/$relative"
  [ -e "$source" ] || return 0
  mkdir -p "$PACKAGE_STAGE/$(dirname "$relative")"
  cp -a -- "$source" "$PACKAGE_STAGE/$relative"
}

copy_scoped_runtime_packages() {
  local scope_source="$SOURCE_TREE/@omniroute"
  [ -d "$scope_source" ] || return 0

  local package_source package_name package_destination relative source destination
  for package_source in "$scope_source"/*; do
    [ -d "$package_source" ] || continue
    [ ! -L "$package_source" ] || die "scoped runtime package is a link: $package_source"
    package_name="${package_source##*/}"
    [[ "$package_name" != *[!A-Za-z0-9._-]* ]] \
      || die "scoped runtime package has an unsafe name: $package_name"
    [ -f "$package_source/package.json" ] && [ ! -L "$package_source/package.json" ] \
      || die "scoped runtime package metadata is missing or unsafe: $package_name"
    jq -e '.files | type == "array" and length > 0 and all(.[]; type == "string")' \
      "$package_source/package.json" >/dev/null \
      || die "scoped runtime package must declare a non-empty files array: $package_name"

    package_destination="$PACKAGE_STAGE/@omniroute/$package_name"
    mkdir -p "$package_destination"
    cp -- "$package_source/package.json" "$package_destination/package.json"
    while IFS= read -r relative; do
      relative="${relative%/}"
      if [ -z "$relative" ] || [[ "$relative" = /* ]] || [[ "$relative" = *\\* ]] \
        || [[ "$relative" = *"*"* ]] || [[ "$relative" = *"?"* ]] \
        || [[ "$relative" = *"["* ]] || [[ "$relative" = ".." ]] \
        || [[ "$relative" = ../* ]] || [[ "$relative" = */../* ]] \
        || [[ "$relative" = */.. ]] || [[ "$relative" = "." ]] \
        || [[ "$relative" = ./* ]] || [[ "$relative" = */./* ]] \
        || [[ "$relative" = */. ]] || [[ "$relative" = *"//"* ]]; then
        die "scoped runtime package declares an unsafe files entry: $package_name/$relative"
      fi
      source="$package_source/$relative"
      [ -e "$source" ] || continue
      [ ! -L "$source" ] || die "scoped runtime package entry is a link: $package_name/$relative"
      destination="$package_destination/$relative"
      mkdir -p "$(dirname "$destination")"
      cp -a -- "$source" "$destination"
    done < <(jq -r '.files[]' "$package_source/package.json")
  done
}

prune_full_package_development_residue() {
  local relative root
  # Never name-prune dist: Next.js production routes legitimately use path
  # segments such as app/api/models/test. The built tree is validated against
  # its app-paths manifest below instead of guessing from directory names.
  local source_roots=(bin @omniroute open-sse src)
  for relative in "${source_roots[@]}"; do
    root="$PACKAGE_STAGE/$relative"
    [ -d "$root" ] || continue
    find "$root" -type d \
      \( -name __tests__ -o -name test -o -name tests -o -name coverage \) \
      -prune -exec rm -rf -- {} +
    find "$root" -type f \
      \( -name '*.test.ts' -o -name '*.test.tsx' -o -name '*.test.js' \
      -o -name '*.test.mjs' -o -name '*.spec.ts' -o -name '*.spec.tsx' \) \
      -delete
  done
}

validate_next_app_route_completeness() {
  local server_root="$PACKAGE_STAGE/dist/.build/next/server"
  local manifest="$server_root/app-paths-manifest.json"
  local relative route_file count=0
  [ -f "$manifest" ] && [ ! -L "$manifest" ] \
    || die "full package is missing a safe Next.js app-paths manifest"
  jq -e 'type == "object" and length > 0 and all(.[]; type == "string")' \
    "$manifest" >/dev/null \
    || die "Next.js app-paths manifest is invalid"

  while IFS= read -r relative; do
    [ -n "$relative" ] || die "Next.js app-paths manifest contains an empty route path"
    if [[ "$relative" = /* ]] || [[ "$relative" = *\\* ]] \
      || [[ "$relative" = ".." ]] || [[ "$relative" = ../* ]] \
      || [[ "$relative" = */../* ]] || [[ "$relative" = */.. ]] \
      || [[ "$relative" = ./* ]] || [[ "$relative" = */./* ]] \
      || [[ "$relative" = */. ]] || [[ "$relative" = *"//"* ]]; then
      die "Next.js app-paths manifest contains an unsafe route path: $relative"
    fi
    route_file="$server_root/$relative"
    [ -f "$route_file" ] && [ ! -L "$route_file" ] \
      || die "Next.js app route declared by manifest is missing or unsafe: $relative"
    count=$((count + 1))
  done < <(jq -er 'to_entries | if length > 0 then .[].value else error("empty manifest") end | select(type == "string")' "$manifest") \
    || die "Next.js app-paths manifest is invalid"

  [ "$count" -gt 0 ] || die "Next.js app-paths manifest declares no routes"
  log "validated $count compiled Next.js app routes"
}

remove_standalone_dependency_duplicates() {
  local standalone_modules="$PACKAGE_STAGE/dist/node_modules"
  [ -e "$standalone_modules" ] || return 0
  [ -d "$standalone_modules" ] && [ ! -L "$standalone_modules" ] \
    || die "standalone dependency tree is not a safe directory"
  rm -rf -- "$standalone_modules"
  log "removed standalone dependency duplicates; runtime resolves from production root"
}

copy_native_file() {
  local source="$1"
  local destination="$2"
  local label="$3"
  [ -f "$source" ] || die "$label is missing from the hosted development install"
  mkdir -p "$(dirname "$destination")"
  cp -f -- "$source" "$destination"
}

validate_dlopen() {
  local binary="$1"
  local label="$2"
  [ -s "$binary" ] || die "$label binary is missing or empty"
  if ! node --input-type=module - "$binary" <<'NODE'
const binary = process.argv[2];
try {
  process.dlopen({ exports: {} }, binary);
} catch (error) {
  console.error(error instanceof Error ? error.message : String(error));
  process.exit(1);
}
NODE
  then
    die "$label binary is not loadable on the requested runtime"
  fi
}

copy_directory_contents() {
  local source="$1"
  local destination="$2"
  local label="$3"
  [ -d "$source" ] || die "$label directory is missing from the hosted development install"
  find "$source" -type f -print -quit | grep -q . || die "$label directory is empty"
  mkdir -p "$destination"
  cp -a -- "$source/." "$destination/"
}

materialize_workspace() {
  local workspace_source="$PACKAGE_STAGE/open-sse"
  local workspace_destination="$PACKAGE_STAGE/node_modules/@omniroute/open-sse"
  [ -f "$workspace_source/package.json" ] || die "open-sse workspace source is missing"
  if [ -L "$workspace_destination" ]; then
    rm -- "$workspace_destination"
  elif [ -e "$workspace_destination" ]; then
    rm -rf -- "$workspace_destination"
  fi
  mkdir -p "$(dirname "$workspace_destination")"
  cp -a -- "$workspace_source" "$workspace_destination"
  [ ! -L "$workspace_destination" ] || die "open-sse workspace remained a link"
}

assemble_native_assets() {
  local source_better="$SOURCE_TREE/node_modules/better-sqlite3/build/Release/better_sqlite3.node"
  local staged_better="$PACKAGE_STAGE/node_modules/better-sqlite3/build/Release/better_sqlite3.node"
  local source_wreq="" staged_wreq="" wreq_name="" candidate
  local source_tls="$SOURCE_TREE/node_modules/tls-client-node/bin"
  local staged_tls="$PACKAGE_STAGE/node_modules/tls-client-node/bin"

  if jq -e '.optionalDependencies["better-sqlite3"] | type == "string"' "$SOURCE_TREE/package.json" >/dev/null; then
    [ -d "$PACKAGE_STAGE/node_modules/better-sqlite3" ] \
      || die "better-sqlite3 is missing from the Linux production install"
    copy_native_file "$source_better" "$staged_better" "better-sqlite3"
    validate_dlopen "$staged_better" "better-sqlite3"
    if [ -d "$PACKAGE_STAGE/dist/node_modules/better-sqlite3" ]; then
      copy_native_file "$source_better" \
        "$PACKAGE_STAGE/dist/node_modules/better-sqlite3/build/Release/better_sqlite3.node" \
        "standalone better-sqlite3"
      validate_dlopen \
        "$PACKAGE_STAGE/dist/node_modules/better-sqlite3/build/Release/better_sqlite3.node" \
        "standalone better-sqlite3"
    fi
  fi

  if jq -e '.optionalDependencies["wreq-js"] | type == "string"' "$SOURCE_TREE/package.json" >/dev/null; then
    [ -d "$PACKAGE_STAGE/node_modules/wreq-js" ] \
      || die "wreq-js is missing from the Linux production install"
    for candidate in \
      "$SOURCE_TREE/node_modules/wreq-js/rust/wreq-js.linux-x64-gnu.node" \
      "$SOURCE_TREE/node_modules/wreq-js/rust/wreq-js.linux-x64.node"; do
      if [ -f "$candidate" ]; then
        source_wreq="$candidate"
        break
      fi
    done
    [ -n "$source_wreq" ] || die "wreq-js Linux x64 GNU binary is missing from the hosted development install"
    wreq_name="${source_wreq##*/}"
    staged_wreq="$PACKAGE_STAGE/node_modules/wreq-js/rust/$wreq_name"
    copy_native_file "$source_wreq" "$staged_wreq" "wreq-js"
    validate_dlopen "$staged_wreq" "wreq-js"
    if [ -d "$PACKAGE_STAGE/dist/node_modules/wreq-js" ]; then
      copy_native_file "$source_wreq" \
        "$PACKAGE_STAGE/dist/node_modules/wreq-js/rust/$wreq_name" \
        "standalone wreq-js"
      validate_dlopen \
        "$PACKAGE_STAGE/dist/node_modules/wreq-js/rust/$wreq_name" \
        "standalone wreq-js"
    fi
  fi

  if jq -e '.optionalDependencies["tls-client-node"] | type == "string"' "$SOURCE_TREE/package.json" >/dev/null; then
    [ -d "$PACKAGE_STAGE/node_modules/tls-client-node" ] \
      || die "tls-client-node is missing from the Linux production install"
    rm -rf -- "$staged_tls"
    copy_directory_contents "$source_tls" "$staged_tls" "tls-client-node bin"
    if [ -d "$PACKAGE_STAGE/dist/node_modules/tls-client-node" ]; then
      rm -rf -- "$PACKAGE_STAGE/dist/node_modules/tls-client-node/bin"
      copy_directory_contents "$source_tls" \
        "$PACKAGE_STAGE/dist/node_modules/tls-client-node/bin" \
        "standalone tls-client-node bin"
    fi
  fi
}

colocate_optional_runtime_closure() {
  [ -f "$PACKAGE_STAGE/scripts/build/colocateOptionals.mjs" ] || return 0
  local result
  result="$(node --input-type=module - "$PACKAGE_STAGE" <<'NODE'
const rootDir = process.argv[2];
const modulePath = new URL(`file://${rootDir}/scripts/build/colocateOptionals.mjs`);
const { colocateLlmlinguaOptionals, SEED_PACKAGES } = await import(modulePath);
const result = colocateLlmlinguaOptionals({ rootDir, log: (message) => console.error(message) });
const fs = await import("node:fs");
const path = await import("node:path");
const rootHasAll = SEED_PACKAGES.every((name) => fs.existsSync(path.join(rootDir, "node_modules", name)));
const distRoot = path.join(rootDir, "dist", "node_modules");
if (rootHasAll && fs.existsSync(distRoot)) {
  for (const name of SEED_PACKAGES) {
    if (!fs.existsSync(path.join(distRoot, name))) {
      console.error(`optional runtime package was not co-located: ${name}`);
      process.exit(1);
    }
  }
}
process.stdout.write(JSON.stringify(result));
NODE
  )" || die "LLMLingua optional runtime closure could not be validated"
  log "optional runtime closure result=$result"
}

assemble_full_package() {
  log "assembling independent production package on GitHub-hosted runner"
  mkdir -p "$PACKAGE_STAGE"
  local runtime_paths=(
    bin dist open-sse
    src/domain src/lib src/models src/mitm src/server src/shared src/sse src/types
    .env.example README.md LICENSE
    scripts/build/postinstall.mjs
    scripts/build/postinstallSupport.mjs
    scripts/build/runtime-env.mjs
    scripts/build/colocateOptionals.mjs
    scripts/build/sync-env.mjs
    scripts/build/native-binary-compat.mjs
    scripts/build/build-next-isolated.mjs
    scripts/build/fixTlsClientNodeBinary.mjs
    scripts/postinstall.mjs
    scripts/dev/responses-ws-proxy.mjs
    scripts/dev/tls-options.mjs
    scripts/dev/sync-env.mjs
    scripts/check/check-supported-node-runtime.ts
  )
  local relative
  for relative in "${runtime_paths[@]}"; do
    copy_runtime_path "$relative"
  done
  copy_scoped_runtime_packages
  cp -- "$SOURCE_TREE/package.json" "$PACKAGE_STAGE/package.json"
  cp -- "$SOURCE_TREE/package-lock.json" "$PACKAGE_STAGE/package-lock.json"

  (
    cd "$PACKAGE_STAGE"
    # The upstream lockfile is generated with legacy-peer-deps=true in .npmrc.
    # Keep that resolver contract explicitly without copying repository npm config
    # (registry/auth settings must never leak into the production payload).
    npm ci --omit=dev --ignore-scripts --legacy-peer-deps --no-audit --no-fund >&2
  )
  materialize_workspace
  remove_standalone_dependency_duplicates
  assemble_native_assets
  colocate_optional_runtime_closure
  prune_full_package_development_residue
  validate_next_app_route_completeness
  rm -- "$PACKAGE_STAGE/package-lock.json"

  [ -f "$PACKAGE_STAGE/dist/server.js" ] || die "full package is missing dist/server.js"
  [ "$(<"$PACKAGE_STAGE/dist/BUILD_SHA")" = "$expected_build" ] \
    || die "full-package BUILD_SHA mismatch"
  [ -f "$PACKAGE_STAGE/bin/omniroute.mjs" ] || die "full package is missing the CLI"
  [ -d "$PACKAGE_STAGE/bin/cli/runtime" ] || die "full package is missing bin/cli/runtime"
  [ -f "$PACKAGE_STAGE/@omniroute/opencode-plugin/dist/index.js" ] \
    || die "full package is missing the bundled OpenCode plugin runtime"
  if jq -e '.dependencies["smol-toml"] // .optionalDependencies["smol-toml"] | type == "string"' \
    "$SOURCE_TREE/package.json" >/dev/null \
    || jq -e '.packages["open-sse"].dependencies["smol-toml"] | type == "string"' \
      "$SOURCE_TREE/package-lock.json" >/dev/null; then
    [ -f "$PACKAGE_STAGE/node_modules/smol-toml/package.json" ] \
      || die "full package is missing required smol-toml dependency"
  fi
}

[ "${GITHUB_ACTIONS:-}" = "true" ] || die "builder must run in GitHub Actions"
[ "$RUNNER_ENVIRONMENT_VALUE" = "github-hosted" ] || die "builder requires a GitHub-hosted runner"
[ "${RUNNER_OS:-}" = "Linux" ] || die "builder requires a Linux runner"
[ "$BUILDER_REPOSITORY" = "nguyenha935/OmniRoute" ] || die "unexpected GitHub repository"
[[ "$BUILDER_REF" =~ ^refs/heads/deploy/(integration|artifact/[0-9a-f]{16,64})$ ]] \
  || die "unexpected deployment ref"
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
readonly BASELINE_TREE="$WORKSPACE/typecheck-baseline"
readonly PACKAGE_STAGE="$WORKSPACE/package-stage"
readonly PAYLOAD="$WORKSPACE/payload.tar.gz"
readonly FILE_INDEX="$WORKSPACE/payload-files.json"
readonly LINK_INDEX="$WORKSPACE/payload-links.json"
readonly PRODUCTION_TREE="$WORKSPACE/payload-production-tree.json"
readonly NATIVE_INDEX="$WORKSPACE/payload-native-files.json"
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
artifact_mode="$(jq -r '.artifactMode' "$request")"
artifact_type="$(jq -r '.artifactType' "$request")"
artifact_policy_hash="$(jq -r '.artifactPolicyHash' "$request")"
expected_package_sha="$(jq -r '.sourcePackageSha256' "$request")"
expected_lock_sha="$(jq -r '.sourceLockSha256' "$request")"
expected_dependency_fingerprint="$(jq -cS '.dependencyFingerprint' "$request")"

case "$artifact_mode:$artifact_type" in
  overlay:omniroute-runtime-overlay|full-package:omniroute-full-package) ;;
  *) die "request artifact mode/type is unsupported" ;;
esac
[ "$($FORMAT_TOOL policy --mode "$artifact_mode" | jq -r '.policyHash')" = "$artifact_policy_hash" ] \
  || die "request artifact policy does not match builder policy"

npm_version="$(npm --version)"
actual_runtime="$($FORMAT_TOOL fingerprint --npm-version "$npm_version")"
[ "$(jq -cS . <<<"$actual_runtime")" = "$(jq -cS . <<<"$expected_runtime")" ] \
  || die "builder runtime fingerprint does not match request"

log "fetching exact target $target_ref@$target mode=$artifact_mode"
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

[ "$(sha256_file "$SOURCE_TREE/package.json")" = "$expected_package_sha" ] \
  || die "patched source package.json does not match request"
[ "$(sha256_file "$SOURCE_TREE/package-lock.json")" = "$expected_lock_sha" ] \
  || die "patched source package-lock.json does not match request"
actual_dependency_fingerprint="$($FORMAT_TOOL dependency-fingerprint --package "$SOURCE_TREE/package.json")"
[ "$(jq -cS . <<<"$actual_dependency_fingerprint")" = "$expected_dependency_fingerprint" ] \
  || die "patched source dependency fingerprint does not match request"
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
restore_next_cache
log "installing development dependencies on GitHub-hosted runner"
npm ci --no-audit --no-fund >&2
log "running focused release gates"
npm run check:build-scope >&2
run_typecheck_regression_gate
npm run check:dashboard-typecheck >&2
if ! git diff --quiet -- src/i18n/messages; then
  node --import tsx/esm --test tests/unit/i18n-vi-completeness.test.ts >&2
fi
log "building one Webpack release artifact"
OMNIROUTE_USE_TURBOPACK=0 \
OMNIROUTE_BUILD_MEMORY_MB="$BUILD_MEMORY_MB" \
npm run build:release >&2
OMNIROUTE_BUILD_SHA="$expected_build" node scripts/build/write-build-sha.mjs >&2
repair_known_runtime_timeout_sidecar "$SOURCE_TREE"
save_next_cache
[ -f dist/server.js ] || die "release build did not produce dist/server.js"
[ "$(<dist/BUILD_SHA)" = "$expected_build" ] || die "release BUILD_SHA mismatch"

if [ "$artifact_mode" = "full-package" ]; then
  assemble_full_package
  payload_source="$PACKAGE_STAGE"
  create_payload_args=(
    --mode full-package
    --source "$payload_source"
    --source-lock "$SOURCE_TREE/package-lock.json"
    --source-package "$SOURCE_TREE/package.json"
  )
else
  log "creating deterministic runtime overlay"
  payload_source="$SOURCE_TREE"
  create_payload_args=(--mode overlay --source "$payload_source")
fi

"$FORMAT_TOOL" create-payload \
  "${create_payload_args[@]}" \
  --output "$PAYLOAD" \
  --index-output "$FILE_INDEX" \
  --links-output "$LINK_INDEX" \
  --production-tree-output "$PRODUCTION_TREE" \
  --native-index-output "$NATIVE_INDEX"
payload_sha="$(sha256_file "$PAYLOAD")"
file_index_sha="$(sha256_file "$FILE_INDEX")"
link_index_sha="$(sha256_file "$LINK_INDEX")"
production_tree_sha="$(sha256_file "$PRODUCTION_TREE")"
native_index_sha="$(sha256_file "$NATIVE_INDEX")"
payload_count="$(jq '.files | length' "$FILE_INDEX")"
payload_bytes="$(jq '[.files[].size] | add // 0' "$FILE_INDEX")"
payload_link_count="$(jq '.links | length' "$LINK_INDEX")"
production_package_count="$(jq '.packages | length' "$PRODUCTION_TREE")"
native_file_count="$(jq '.files | length' "$NATIVE_INDEX")"
created_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
patches="$(jq -c '.patches' "$request")"

jq -n \
  --argjson schemaVersion 3 \
  --arg artifactMode "$artifact_mode" \
  --arg artifactType "$artifact_type" \
  --arg repository diegosouzapw/OmniRoute \
  --arg requestSha256 "$request_sha" \
  --arg targetRef "$target_ref" \
  --arg targetCommit "$target" \
  --arg version "$version" \
  --arg patchSetHash "$patch_set" \
  --arg artifactPolicyHash "$artifact_policy_hash" \
  --arg buildSha "$expected_build" \
  --arg buildBundler webpack \
  --arg sourcePackageSha256 "$expected_package_sha" \
  --arg sourceLockSha256 "$expected_lock_sha" \
  --arg payloadSha256 "$payload_sha" \
  --arg fileIndexSha256 "$file_index_sha" \
  --arg linkIndexSha256 "$link_index_sha" \
  --arg productionTreeSha256 "$production_tree_sha" \
  --arg nativeIndexSha256 "$native_index_sha" \
  --argjson payloadEntryCount "$payload_count" \
  --argjson payloadUnpackedBytes "$payload_bytes" \
  --argjson payloadLinkCount "$payload_link_count" \
  --argjson productionPackageCount "$production_package_count" \
  --argjson nativeFileCount "$native_file_count" \
  --arg builderRepository "$BUILDER_REPOSITORY" \
  --arg builderWorkflow "$BUILDER_WORKFLOW" \
  --arg builderRef "$BUILDER_REF" \
  --arg builderSourceDigest "$BUILDER_SOURCE_DIGEST" \
  --argjson builderRunId "$BUILDER_RUN_ID" \
  --argjson builderRunAttempt "$BUILDER_RUN_ATTEMPT" \
  --arg createdAt "$created_at" \
  --argjson runtime "$actual_runtime" \
  --argjson dependencyFingerprint "$actual_dependency_fingerprint" \
  --argjson patches "$patches" \
  --argjson appliedPatches "$applied" \
  --argjson skippedUpstreamedPatches "$skipped" \
  '{schemaVersion:$schemaVersion,artifactMode:$artifactMode,artifactType:$artifactType,repository:$repository,requestSha256:$requestSha256,targetRef:$targetRef,targetCommit:$targetCommit,version:$version,patchSetHash:$patchSetHash,patches:$patches,appliedPatches:$appliedPatches,skippedUpstreamedPatches:$skippedUpstreamedPatches,sourcePackageSha256:$sourcePackageSha256,sourceLockSha256:$sourceLockSha256,dependencyFingerprint:$dependencyFingerprint,buildSha:$buildSha,buildBundler:$buildBundler,runtime:$runtime,artifactPolicyHash:$artifactPolicyHash,payloadSha256:$payloadSha256,fileIndexSha256:$fileIndexSha256,linkIndexSha256:$linkIndexSha256,productionTreeSha256:$productionTreeSha256,nativeIndexSha256:$nativeIndexSha256,payloadEntryCount:$payloadEntryCount,payloadUnpackedBytes:$payloadUnpackedBytes,payloadLinkCount:$payloadLinkCount,productionPackageCount:$productionPackageCount,nativeFileCount:$nativeFileCount,builder:{repository:$builderRepository,workflow:$builderWorkflow,ref:$builderRef,sourceDigest:$builderSourceDigest,runId:$builderRunId,runAttempt:$builderRunAttempt,runnerEnvironment:"github-hosted"},createdAt:$createdAt}' \
  >"$WORKSPACE/manifest.tmp.json"
"$FORMAT_TOOL" canonicalize --input "$WORKSPACE/manifest.tmp.json" --output "$MANIFEST"
chmod 0644 "$PAYLOAD" "$MANIFEST"
"$FORMAT_TOOL" create-response \
  --manifest "$MANIFEST" --payload "$PAYLOAD" --output "$RESPONSE"
log "build complete mode=$artifact_mode target=$target patches=$patch_set artifact=$(sha256_file "$RESPONSE") manifest=$(sha256_file "$MANIFEST")"
cat "$RESPONSE"
