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
6. **Git-path parity.** A jj vocabulary or behavior change must leave the
   **git path's exact wording and selection semantics identical**. Upstream's
   tests assert them, so any divergence (a mis-pluralized noun, a selection that
   now fires where it didn't) is a regression, not a feature. The full suite is
   the guard — see §4.6.

## 2. Where things stand (update each cycle)

| Item | Value (refresh on each cycle) |
| --- | --- |
| Fork remote | `origin` → `github.com/DannyGoodall/supacode` |
| Upstream remote | `upstream` → `github.com/supabitapp/supacode` |
| Original branch point | `2df2b75` (`#393` CI restructure) — where the stack first forked |
| Last reconciled to | `4f33f61c` (upstream `v0.10.5`+) on integration branch `jj-integrate-upstream-0.10.5` (merge `731342c`) — builds + `make test` green (2260 tests). Prior: `v0.10.4` (merge `3af8d0a9`). |
| Stack size | ~50 jj commits + identity commit + two merge commits |
| Published stack branches | `jj-stack-2-backend-read` … `jj-stack-6-native-ui` on `origin` |
| OpenSpec change | `openspec/changes/add-jj-colocation-support/` |

> The first reconciliation (→ `v0.10.4`) was done as a **merge** on a real
> integration branch (not the rebase of §1.3) because it's a long testing phase
> with repeated re-merges; the clean rebase/reflow happens later, when actually
> preparing the upstream PR. A merge resolves the model collision **once**; a
> rebase would re-hit it across all 50 commits.

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
6. **Reconcile + validate** (mutating, on a dedicated integration branch):
   ```bash
   git switch -c jj-integrate-upstream-<ver>         # not the stack tip
   git merge upstream/main                           # merge for a long test phase; rebase only at PR time
   # resolve per §4, then build + test:
   export DEVELOPER_DIR=/Applications/Xcode-26.3.0.app/Contents/Developer  # Zig can't link 26.4+ SDK
   mise install                                      # build-app's preflight needs swiftlint/xcbeautify/swift-format
   make build-app                                    # runs `tuist generate` + `doctor` first
   make test                                         # ALSO compile-migrate the test target — see §4.6
   ```
   Commit the merge ONLY after both are green. **Watch the commit boundary:**
   build errors are fixed *after* you stage with `git add -u`, so `git commit`
   captures a stale tree — `git add` the post-build fixes and `git commit --amend`
   before moving on. Keep unrelated WIP stashed (step 3) out of the merge commit.
   Only once green do you reflow (§5) and update the published stack branches.

   **Stuck-merge technique — reset-to-theirs + re-apply the delta.** When a
   textual 3-way merge tangles a large file (the tell: **duplicated symbols** —
   the same `case`/`func` appearing twice, "switch must be exhaustive", redeclared
   members), do NOT hand-edit the markers. Take upstream's whole file and re-apply
   the jj delta as discrete hunks:
   ```bash
   F=path/to/File.swift
   git diff 2df2b75a HEAD -- "$F" > /tmp/jj.diff   # the jj delta vs the original branch point
   git show :3:"$F" > "$F"                          # reset the file to THEIRS (upstream)
   # then walk /tmp/jj.diff hunk-by-hunk, applying each onto upstream's structure
   ```
   This trades an unreviewable tangle for N small, deliberate edits. Used for
   `RepositoriesFeature.swift` (§4.4); reach for it on any file whose conflict
   markers contain duplicated declarations.

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

### 4.4 `RepositoriesFeature.swift` — the churn hot zone (DON'T hand-merge)

Largest upstream churn (remote-SSH + id consolidation). The textual merge
**tangles and duplicates case arms** in the giant reducer switch — it does not
compile and is not safely hand-editable. Use the **reset-to-theirs + re-apply
the delta** technique from §3 step 6: `git show :3:` the file, then replay the
jj delta (≈15 hunks) onto upstream's structure. Reality notes from the last run:

- The jj surface really is small (~15 hunks: `isColocatedJJ` wiring,
  `pushWorktreeBookmark` + `worktreeChangeIdLoaded` actions, the change-id
  watcher fetch, jj delete/rename vocabulary, the new-repo auto-select).
- **Adapt each hunk to upstream's possibly-renamed anchor.** The jj delta was
  written against the old code: it patched `classifyRoot`, but upstream renamed
  that to `worktreesFetchResult` (and added the `#480` duplicate-path guard).
  Thread `isColocatedJJ` through upstream's function — don't paste the jj version
  over it. Same for `replacingWorktrees` → upstream's `withWorktrees`.
- **Split-reducer passthrough gotcha.** The reducer is split into composed
  sub-reducers (`worktreeNotificationReducer`, `githubIntegrationReducer`, …),
  each a full `switch action`. A NEW action case must be added in **two** places:
  its real handler in the owning sub-reducer, AND a passthrough entry in the
  `body` switch's grouped `case … : return .none` arms (which is exhaustive with
  no `default`). Miss the second and you get "switch must be exhaustive".

### 4.6 Tests are a reconciliation surface too (run `make test`, not just build)

`make build-app` does **not** compile the test target, so a green app build can
still leave `make test` broken. Budget for it every cycle:

- **Model migration.** jj-only test files construct `Repository`/`Worktree` with
  the old String-id init. Migrate to the new model: prefer the designated
  `location:` inits (`Worktree(location: .local(workingDirectory:repositoryRoot:),
  kind: .git, …)`, `Repository(location: .local(url), kind:, …, isColocatedJJ:)`),
  and where a back-compat init or a `[id:]` subscript is used, wrap raw strings
  in `RepositoryID(…)` / `WorktreeID(…)` (neither is `ExpressibleByStringLiteral`).
  Iterate with `xcodebuild build-for-testing` (faster than a full run).
- **Upstream's tests are a correctness oracle for the jj code.** The full suite
  caught two latent jj bugs the app build did not: (1) the delete dialog rendered
  "branch**s**" because the jj vocab did `\(bookmarkNoun)s` on the git path — fixed
  with a `bookmarkNounPlural` (`Branches`/`Bookmarks`); (2) the "opening a repo
  selects it" feature hijacked the **initial load** (and remote-resolution, which
  routes through the same action), breaking upstream tests that expect
  `selection: nil` — fixed by gating on `!previousRoots.isEmpty`. General rule
  (and invariant §1.6): a jj vocabulary/behavior change must leave the **git
  path's exact wording and selection semantics unchanged**; upstream asserts them.
- The "known issues" in the run summary are intentional `withKnownIssue` markers
  — a green run reports them as passing with `xcodebuild` exit 0.

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

- **Toolchain (`#468`, self-diagnosing macOS 26.4+).** Adds a `doctor`/preflight
  that `make build-app` now runs — it fails with "mise tools missing" until you
  `mise install` (swiftlint, xcbeautify, swift-format). NOTE (verified at
  `v0.10.4`): this did **not** obsolete the "build with Xcode ≤26.3" constraint —
  Zig 0.15.2 still can't link the 26.4+ SDK, so you must still
  `export DEVELOPER_DIR=…/Xcode-26.3.0.app/…`. Keep the carry-note for now;
  re-test whether it can be dropped on a future Zig/Xcode bump.
- **Duplicate-worktree-path guard (`#480`).** Verified at `v0.10.4`: jj workspace
  creation uses distinct paths and does not trip it; the folder/duplicate tests
  pass. Re-confirm each cycle.
