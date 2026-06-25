# Upstream Reconciliation Process (jj-colocation fork)

> **Status:** living runbook. This is a **recurring** process, not a one-off.
> This fork (`DannyGoodall/supacode`) carries a large, intentionally-divergent
> jj-colocation feature on top of `upstream` (`supabitapp/supacode`). The feature
> will be tested for a considerable time and reconciled against a moving
> `upstream/main` **repeatedly** before it is offered back as a PR (or stacked
> PRs). Every reconciliation cycle follows the steps below; every *new* change
> made on this fork must respect the invariants in §1 so the next cycle stays cheap.
>
> This document is fork-private. It lives inside the OpenSpec change folder so it
> never lands in the additive upstream PRs (see §5 — the docs commit is droppable).

## 1. Invariants every change on this fork must respect

The whole point of these invariants is to keep the eventual upstream PR(s)
trivial for the maintainer to assess, and to keep each re-merge against a moving
`upstream/main` cheap. Any new work on this fork **must** preserve them:

1. **Additive, never replacing.** Do not redefine or restructure upstream's
   types/fields. Add fields/properties/cases alongside them. The maintainer's
   review pitch is *"off by default, additive, upstream paths byte-for-byte
   unchanged."* A refactor of an upstream type breaks that pitch and multiplies
   merge conflicts forever.
   - Concretely: **do not reintroduce a `vcs: RepositoryVCS` field** that competes
     with upstream's `kind: RepositoryKind`. The jj flavor rides as a single
     additive `isColocatedJJ: Bool = false` on `Repository` (see §4.1).
2. **Local-only, gated.** jj is only ever active when (a) the experimental gate
   is on, (b) `kind == .git`, and (c) `location.localRootURL != nil`. Remote
   SSH repos and folders must be byte-for-byte unaffected. Gate explicitly even
   when a downstream probe would already fail — the reviewer should not have to
   trace a FileManager probe to convince themselves SSH is safe.
3. **Rebase, never merge.** The integration history offered upstream is a clean
   rebase onto current `upstream/main` with **no merge commits**. Local testing
   may use throwaway merges (see §3) but they are never the thing shipped.
4. **Reflow to reviewable commits.** The 50+ iteration commits squash into the
   small stacked sequence in §5. Maintainers review intent, not debugging history.
5. **Backend dispatch stays inside the existing seam.** Route jj inside
   upstream's `GitClientDependency.make(shell:)` factory, gated to the local
   shell. Do not add a parallel dependency/protocol seam (see §4.2).

## 2. Where things stand (update each cycle)

| Item | Value (refresh on each cycle) |
| --- | --- |
| Fork remote | `origin` → `github.com/DannyGoodall/supacode` |
| Upstream remote | `upstream` → `github.com/supabitapp/supacode` |
| Branch point | `2df2b75` (`#393` CI restructure) — where the stack forked |
| Stack size | ~50 commits, detached `HEAD` lineage |
| Published stack branches | `jj-stack-2-backend-read` … `jj-stack-6-native-ui` on `origin` |
| OpenSpec change | `openspec/changes/add-jj-colocation-support/` |

## 3. The repeatable cycle (runbook)

Run this each time `upstream/main` advances. Steps 1–4 are read-only measurement
on a clean tree; only step 6 mutates branches.

1. **Fetch + scope.**
   ```bash
   git fetch upstream --quiet
   git log --oneline HEAD..upstream/main            # what embracing brings in
   git rev-list --count HEAD..upstream/main         # how far upstream moved
   ```
2. **File overlap.**
   ```bash
   base=$(git merge-base HEAD upstream/main)
   git diff --name-only $base upstream/main | sort > /tmp/up.txt
   git diff --name-only $base HEAD          | sort > /tmp/loc.txt
   comm -12 /tmp/up.txt /tmp/loc.txt                 # files touched by both
   ```
3. **Quantify *real* conflicts** (filename overlap over-counts). Stash WIP first:
   ```bash
   git stash -u
   git merge --no-commit --no-ff upstream/main
   git diff --name-only --diff-filter=U             # the true conflict set
   git merge --abort
   git stash pop
   ```
4. **Triage** the conflict set against the known collision points in §4. New
   files in the conflict set that aren't in §4 get analysed and added there.
5. **Recheck the free wins** (§6) — upstream may have moved tooling/guards that
   obsolete a local workaround.
6. **Reconcile + validate** (mutating, on a scratch branch — never the stack):
   ```bash
   git switch -c reconcile/$(upstream-tip-short)    # throwaway
   git rebase upstream/main                          # or merge to spot-check
   # resolve per §4, then:
   make build-app && make test
   ```
   Only once green do you reflow (§5) and update the published stack branches.

## 4. Known collision points and their resolutions

These are the load-bearing reconciliations. They recur every cycle because the
work sits on the same subsystems upstream is actively evolving (remote-SSH repos,
self-descriptive IDs).

### 4.1 `Repository` / `RepositoryIdentity.swift` — the model

Upstream replaced stored `id`/`rootURL`/`isGitRepository` with
`location: RepositoryLocation` + `kind: RepositoryKind` + derived `RepositoryID`
(`supacode/Domain/RepositoryIdentity.swift`). `RepositoryLocation` is
`.local(URL)` / `.remote(RemoteHost, path:)`, and `location.localRootURL` is
`nil` for remote — **this is the linchpin that makes jj fit cleanly.**

Resolution:
- Keep upstream's `kind`/`location` unchanged. Add **one** additive stored field:
  `var isColocatedJJ: Bool = false`, documented with the invariant from §1.2.
- Drop any `RepositoryVCS` enum. `isGitRepository` stays upstream's `kind == .git`.
- Feed the colocation probe `location.localRootURL` (nil for remote ⇒ remote can
  never classify as jj, for free).

### 4.2 `GitClientDependency.swift` — backend routing

Upstream refactored to a transport factory: `liveValue = make(shell: .live)` and
`static func ssh(host:) = make(shell: .ssh(host:))`, threading `ShellClient`
into `GitClient(shell:)`. The jj work branched per-closure inside one `liveValue`.

Resolution: fold the jj branches into `make(shell:)`, gating each on
`isLocalShell && shouldUseJujutsuBackend(for: root)`. The `.ssh` flavor never
reaches `JJClient`. Keep upstream's factory shape intact.

### 4.3 `Worktree` / `WorktreeLocation` — additive

Upstream added `WorktreeLocation` (`.local(workingDirectory:repositoryRoot:)` /
`.remote(...)`) and `WorktreeID`. jj workspaces are always `.local(...)`. Map
synthesized workspace working dirs onto it; attach jj fields (change-id,
bookmark/workspace name) as additive properties. Re-derive worktree ids through
`WorktreeID`, not raw strings.

### 4.4 `RepositoriesFeature.swift` — the churn hot zone

Largest upstream churn (remote-SSH + id consolidation). Local surface is small
and concentrated in `classifyRoot`. Once §4.1 lands: rewrite `classifyRoot` to
emit `location:`/`kind:` and set `isColocatedJJ` (gate ∧ `localRootURL != nil` ∧
probe). `usesJujutsuBackend(forRepository:)` call sites keep working unchanged.

### 4.5 Vocabulary / UI conflicts — low risk

`CommandPaletteFeature`, `SidebarItemView`/`Feature`, `WorktreeDetailTitleView`/
`View`, `RenameBranchFeature`, `SettingsRepositorySummary`,
`WorktreeInfoWatcherManager`: take upstream's structure, re-apply the additive
jj vocabulary + change-id rendering. The watcher's op-heads-vs-HEAD routing
re-attaches to upstream's reworked watcher; the routing logic itself is unchanged.

## 5. Upstream PR shape (the reflow target)

Stacked, self-contained, each additive and gated. Mirrors the existing
`jj-stack-*` boundaries:

1. **Colocation detection + model field** — `isColocatedJJ`, gated probe, no
   behavior change when gate off.
2. **`JJClient` + routing** — dispatch folded into `make(shell:)`, local-only.
3. **Workspace create / remove / rename + push** — lifecycle ops.
4. **Watcher (op-heads) + jj-native vocabulary/UI** — presentation layer.
5. **Docs / OpenSpec** — *droppable*; this folder (incl. this file) lives here.

Each PR's pitch: *off by default, local-only, additive — git and remote paths
byte-for-byte unchanged.*

## 5a. Fork build identity (preserve across every merge)

The fork build is branded so it can't be confused with an upstream/release
install. **Re-assert these after every merge** — they live in files
upstream's version work (`#486`, `b1cd23c5`) touches, so they can conflict.
`supacode.xcodeproj/project.pbxproj` is **gitignored and regenerated** by
`tuist generate` (which `make build-app` runs), so the source of truth is the
**Tuist manifest `Project.swift`** — never hand-edit the pbxproj.

- **Display name:** Debug settings in `Project.swift` set
  `"SUPACODE_DISPLAY_NAME": "Supacode JJ"`. Upstream's value is `"Supacode (Debug)"`.
- **Version tag:** `Project.swift` Debug settings add `"SUPACODE_VERSION_SUFFIX": "+jj"`;
  the base default is empty in `Configurations/Project.xcconfig`; and
  `supacode/Info.plist` composes
  `CFBundleShortVersionString = $(MARKETING_VERSION)$(SUPACODE_VERSION_SUFFIX)`.
  The fork reports e.g. `0.10.4+jj` ("jj fork based on upstream 0.10.4") while
  `MARKETING_VERSION` stays semver-clean for `make bump-version` and upstream's
  explicit-version logic.
- **Do not** change the Debug `PRODUCT_BUNDLE_IDENTIFIER` (`…supacode.debug`) —
  the `~/.supacode-debug` / `ZMX_DIR` isolation keys off it.

## 6. Free wins to recheck each cycle

- **Toolchain (`#468`, self-diagnosing macOS 26.4+).** `scripts/select-developer-dir.sh`
  + `scripts/doctor.sh` may obsolete the manual "build with Xcode ≤26.3" carry-note
  in `AGENTS.md`/`CLAUDE.md`. If it auto-selects a working Xcode, delete the note in
  the same PR — it signals jj rides on upstream tooling, not around it.
- **Duplicate-worktree-path guard (`#480`).** Confirm jj workspace creation
  doesn't trip it (distinct paths ⇒ should be fine; verify each cycle).
