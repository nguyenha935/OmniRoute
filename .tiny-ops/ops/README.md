# OmniRoute native operations on Tiny

> Bắt buộc đọc `/opt/omniroute/AGENTS.md` trước khi kiểm tra, cập nhật,
> sửa mã nguồn hoặc tạo PR. File đó là quy tắc local có hiệu lực cho toàn bộ
> cây `/opt/omniroute` nhưng được đặt ngoài checkout upstream để giữ source sạch.

OmniRoute production is a native, versioned package managed under
`/usr/lib/node_modules/omniroute` and runs under `omniroute.service`. A release
may be the official npm package or a validated source-release package with
local patches. The production process never reads files from the source
checkout or a patch worktree.

## Layout

```text
/opt/omniroute/
  config/                 root-only environment and initial password
  data/                   production SQLite data
  home/                   home directory for the omniroute service account
  source/                 canonical fork checkout; never develop here
    .claude/worktrees/    one isolated worktree per patch
  patches/                immutable patch snapshots associated with PRs
  staging/                disposable candidate and upstream verification trees
  backups/                pre-update package, config, and data snapshots
  state/                  deployment history and patch metadata
  ops/                    local operational scripts
```

## Runtime operations

```bash
update-omniroute --check
update-omniroute --update
update-omniroute --verify-runtime
systemctl status omniroute
journalctl -u omniroute -f
```

Running `update-omniroute` without an option is equivalent to `--check`.
`--update` is the single public deployment command: it locks the current target
and ordered patch set, dry-runs the patches, builds or reuses a candidate from
GitHub, resolves every artifact/provenance pin from `state/candidate.json`, runs
artifact-aware preflight, smoke-tests, backs up, swaps atomically, rolls back on
failure, and verifies the runtime. Operators do not pass target, digest, ref or
run IDs manually in the normal flow.

Candidate requests are published as fast-forward commits on the persistent
`deploy/integration` branch. The commit SHA remains immutable provenance while
the branch avoids one throwaway branch per build. npm downloads and Turbopack's
`.build/next/cache` are cached on GitHub-hosted runners. A candidate with the same
target, patch identity, lane, runtime and dependency fingerprint is reused. If
the release branch advances while a fresh candidate is building, the automatic
flow uses the existing bounded-ancestor verification instead of restarting the
build loop.
If the caller or SSH session ends, the next `--update` reads the published
integration request and resumes its exact run when the patch set/ref match, the
target is an ancestor of the current release head, and the request is at most
60 minutes old.
`--check` never fetches, checks out, stashes, restarts, or edits production data.
It exits `0` when healthy and current, `10` when an update is available, and
`20` when a blocker is detected.

The default update channel is `release`: when upstream exposes a `release/v*`
branch, the highest versioned branch is the source target. This preserves the
separate pre-stable release flow instead of downgrading a source build to an
older npm package. Set `OMNIROUTE_UPDATE_CHANNEL=stable` only when an explicit
npm-stable deployment is wanted.

The GitHub-hosted builder fetches the exact source commit into a clean detached
tree, applies the remaining ordered snapshots, and verifies that the resulting
`package.json` and `package-lock.json` match the hashes in the canonical request.
Before that request is published, the requestor compares the exact target
`dependencyFingerprint` with the installed package: a match selects `overlay` /
`omniroute-runtime-overlay`; a difference selects `full-package` /
`omniroute-full-package`. Mode, type, mode-specific policy hash, dependency
fingerprint, and source package/lock hashes are request identity and cannot be
silently changed by the builder or updater.

The workflow runs the focused release gates and exactly one Turbopack release
build with development dependencies on GitHub-hosted `ubuntu-24.04`. The overlay
lane emits only the approved runtime roots. For dependency drift, the
full-package lane assembles an independent package and production-pruned
`node_modules` on the runner, materializes the workspace closure, runs approved
native repair there with fail-closed network guards, and verifies the lockfile,
production/optional dependency closure, and native inventory. Development-only
packages and build/test residue are rejected. The workflow uses fake secrets and
a temporary data directory, then returns deterministic payload, file/link,
production-tree and native indexes bound to the canonical manifest. GitHub
attests the exact response archive; builder or attestation failure is terminal
and never moves `npm ci`, npm install, lifecycle scripts, native rebuild or a
source build back to Tiny.

Tiny stores artifacts content-addressed and treats them as untrusted until the
full verifier succeeds. Overlay deployment is allowed only when the target and
installed dependency fingerprints match; it starts from an independent copy of
the installed package, removes every fixed replace root and singleton, then
copies only verified overlay files. Full-package deployment is allowed only when
the fingerprints differ; its candidate is copied directly from the verified
independent package and never inherits installed files or `node_modules`. A
wrong lane is rejected before candidate smoke or production mutation.

Payload archives contain directories and regular files only. Allowed npm
`node_modules/**/.bin/*` links are recorded in a canonical link index rather than
stored as tar links. Tiny verifies every file hash, mode, count and byte total,
requires each relative link target to resolve to an indexed regular file inside
the package, extracts without following existing links, and reconstructs links
only after the regular-file tree is complete. Absolute, escaping, dangling,
chained, unindexed and case-colliding links are rejected.

The update path never uses `npm pack`, never installs or builds on Tiny, never
runs lifecycle/postinstall or native rebuild on Tiny, never stashes a worktree,
and never runs coverage on Tiny. Both lanes share the same transaction: candidate
smoke uses fake secrets and isolated data on loopback ports before any production
mutation. After the candidate passes, package/data/config backups are created and
the package is swapped atomically. A failed production health check restores both
the previous package and the pre-migration data snapshot. The updater records
response and manifest IDs, request SHA, exact GitHub repository/workflow/ref/
source/run provenance, the verified `artifactMode`/`artifactType`, mode-specific
policy hash, source package/lock, dependency fingerprint, production-tree, file,
link and native index digests, and method `github-attested-<mode>` in deployment
state.

The read-only check reports two independent update dimensions:

1. official npm version drift;
2. deployed local patch-set drift.

It returns `10` when either dimension requires an update. It does not fetch,
checkout, stash, create a worktree, restart a service, or edit state.

## Patch and PR workflow

```bash
omniroute-patch status
omniroute-patch new fix/example
cd /opt/omniroute/source/.claude/worktrees/fix-example
# edit, run only targeted single-worker tests, and commit
omniroute-patch snapshot fix/example
omniroute-patch pr fix/example
```

Do not run `omniroute-patch test` on Tiny. Its current implementation installs
dependencies when missing and then runs the complete lint, unit, Vitest,
coverage, and production-build chain. Use the resource-safe targeted-test rules
in `/opt/omniroute/AGENTS.md`; full validation belongs in CI or a separately
approved isolated environment.

`snapshot` exports the committed delta from the patch's recorded base commit,
writes an immutable patch file under `/opt/omniroute/patches`, and updates the
metadata with the worktree commit and SHA-256. Artifact request creation verifies
those snapshots against clean worktrees and recomputes the ordered patch-set, so
committed local work cannot silently disappear. Dirty worktrees are blockers.

`new` detects the highest active `release/v*` branch and falls back to `main`
only when no release branch exists. `pr` opens a draft PR so its number can be
used in the required `changelog.d` fragment.

A draft PR does not prove CI is green: upstream intentionally skips heavy jobs
while a PR is draft. After the user authorizes ready-for-review and the
changelog/metadata are complete, let GitHub run the full required suite on its
sharded hosted or dedicated runners. Never reproduce that full CI load on Tiny.
Do not report the PR ready to merge until this command exits `0`:

```bash
gh pr checks <PR> --repo diegosouzapw/OmniRoute --required --watch --interval 10
```

Exit code `8` means checks are still pending. A local targeted-test pass, a
draft skip, or a green non-required check cannot replace required CI.

After a stable update, merged patch worktrees are removed only when all of the
following are true:

1. GitHub reports the PR as merged.
2. The worktree is clean.
3. A saved patch snapshot exists.
4. The patch is verifiably present in the installed release tag.

No operation uses `git stash`.

The builder removes generated intermediates after producing the response; Tiny
retains the reviewed attested artifact and deployment backups for audit/rollback.
A full Next.js build is still required even for a locale-only patch, but it runs
exactly once on the GitHub-hosted `ubuntu-24.04` runner, never on Tiny and never
once per test phase.

## Incident memory

Operational incidents and verified recovery rules are recorded in
`/opt/omniroute/ops/INCIDENTS.md`. Read that file before running tests, builds,
updates, or recovery commands.

## Public endpoint

Cloudflare Tunnel hiện có phục vụ toàn bộ dashboard và API tại:

```text
https://api.nguyenthanhha.com/*        -> http://127.0.0.1:20130
wss://api.nguyenthanhha.com/live-ws   -> http://127.0.0.1:20132
```

Không tạo reverse proxy cho hostname này trong CloudPanel/Nginx. Cổng API
bridge `20131` và live WebSocket `20132` vẫn chỉ bind loopback; tunnel chuyển
tiếp riêng WebSocket theo path `/live-ws` mà không mở cổng trực tiếp.
