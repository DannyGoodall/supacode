## Context

Supacode automates Git through a small number of well-defined seams:
- `Repository.isGitRepository(at:)` (`supacode/Domain/Repository.swift:52`) classifies each root as git or folder at load time.
- `GitClientDependency` / `GitClient` shell out to `git` and the bundled `Resources/git-wt` `wt` CLI (worktree create/list), plus `GitReferenceQueries` for branch/ref queries.
- `WorktreeInfoWatcherManager` watches each worktree's `.git/HEAD` (resolved by `GitWorktreeHeadResolver`) to emit branch/file-change events; PR refresh is a separate timer.
- `GithubCLIClient` wraps the `gh` CLI for PR state, checks, merge, and logs.
- `RepositoriesFeature` (the loader at `loadRepositoriesData`, plus create/archive/delete/rename/pin handlers) orchestrates the lifecycle; `WorktreeCreationPromptFeature` and `RenameBranchFeature` drive the UI; `supacode-cli` and the `supacode://` deeplink layer expose the same operations externally.

A **co-located** jj repository (jj's term for `.jj` and `.git` as peers in the root) is still a valid Git repo, so all of the above keeps working. That property is the foundation of this design: jj is added as an *augmentation*, never a replacement.

The foundation phase (detection + flavor + gate, behind `experimentalJJIntegration`) is already implemented and verified green on CI; this design covers the whole capability so later phases land coherently.

## Goals / Non-Goals

**Goals:**
- Detect co-located jj and offer jj-native equivalents (workspaces, bookmarks, fetch/push, diff, working-copy watching) for the Git features Supacode already automates.
- Zero behavior change for non-jj users, and zero change when the experimental gate is off.
- Preserve the git/none contract so the ~50 existing `isGitRepository` consumers are untouched.
- **Present jj-native vocabulary and affordances for jj repos** (workspace/bookmark, not worktree/branch), and never offer a git-only action (e.g. Archive) on a jj workspace. *(Revised after Phase-4–7 GUI testing — see Decision 11. The original goal was "keep one vocabulary regardless of backend"; that undershot the requirement to "offer the jj equivalent — workspaces for worktrees, bookmarks for branches," so the presentation layer is now made flavor-aware. The backend-dispatch rationale in Decision 3 is unaffected.)*

**Non-Goals:**
- Supporting non-colocated jj repositories (no sibling `.git`).
- Replacing or removing any Git code path; Git remains the default even on colocated repos until the user opts in.
- Re-implementing PR creation; GitHub PR tracking continues via `gh`.
- A full jj UI (operation log, rebase, squash); only the automation that mirrors existing Git features is in scope.

## Decisions

**1. Third VCS flavor, not a boolean.** Replace the stored `isGitRepository: Bool` with `vcs: RepositoryVCS` (`.git` / `.gitColocatedJJ` / `.folder`) and keep `isGitRepository` as a computed `vcs != .folder`, plus the historical `init(isGitRepository:)`.
- *Why:* preserves every existing consumer and constructor unchanged while adding the new state.
- *Alternative considered:* a separate `isColocatedJJ: Bool` alongside the existing bool — rejected because two booleans can encode an impossible state (folder + jj) and obscure the single source of truth.

**2. Gate read once in the loader; detection is pure.** `Repository.isColocatedJJRepository(at:)` is a pure FileManager probe; the loader reads `@Shared(.experimentalJJIntegration)` and only promotes a root to `.gitColocatedJJ` when the gate is on. The detection probe is skipped entirely when off.
- *Why:* guarantees byte-for-byte identical behavior when off, and keeps detection testable without the flag.

**3. Two concrete backend clients (`GitClient`, `JJClient`) dispatched per-repo through the existing `GitClientDependency` seam.** `GitClientDependency` is already the VCS abstraction boundary (a struct of `@Sendable` closures injected via swift-dependencies); each live closure resolves the repository's backend with `GitClientDependency.shouldUseJujutsuBackend(for:)` and calls `JJClient` (jj) or `GitClient` (git, unchanged). No separate Swift `protocol` is introduced — that would just duplicate the closure signatures and fight the codebase's struct-of-closures DI idiom.
- *Why:* isolates jj specifics in `JJClient`, keeps Git behavior literally the current code, leaves all reducers/call sites and tests untouched (they depend on `GitClientDependency`, not a backend type), and keeps one user-facing vocabulary since the dependency decides worktree-vs-workspace internally.
- *Refines an earlier note* that named a `VCSBackend` protocol with `GitBackend`/`JJBackend` — the dependency seam already provides that role, so the concrete-clients realization is simpler and equivalent.
- *Alternative considered:* `if vcs == .gitColocatedJJ` branches scattered across the reducer — rejected as unmaintainable and hard to test.

**4. Mapping table.** worktree→workspace (`jj workspace add`/`forget`), branch→bookmark (`jj bookmark …`), base ref→revset/bookmark, fetch→`jj git fetch`, diff `HEAD --shortstat`→`jj diff --stat -r @`, `.git/HEAD` watch→`.jj/` working-copy watch. Read-only jj queries pass `--ignore-working-copy` to avoid snapshot storms.

**5. Bypass `git-wt` for jj.** The bundled `wt` is a Git-worktree tool; the jj backend calls `jj workspace` directly.

**6. Skip Supacode's worktree lock machinery for jj.** The `locked` admin-dir file Supacode writes for Git worktrees has no jj analogue; ownership for jj is tracked via `jj workspace list`.

**7. Always auto-create a bookmark on workspace creation.** Creating a jj workspace SHALL also create a bookmark (named from the prompt's branch/name field) pointing at the new working-copy commit.
- *Why:* keeps the displayed "branch" non-anonymous and gives PR matching + push a stable name without a second user step. Resolves the anonymous-workspace risk by construction.
- *Alternative considered:* create a bookmark only when the user names one — rejected because it leaves PR/branch flows with nothing to match in the common case.

**8. Per-repository "prefer jj" preference (`preferJJ: Bool?`).** Backend selection is `vcs == .gitColocatedJJ && (preferJJ ?? true)`. A root is only ever `.gitColocatedJJ` when the experimental gate is on, so the gate is implicit in the `vcs` guard. `preferJJ` is a persisted per-repo tri-state: `nil` = "use the default" (which for a co-located repo is to prefer jj), `false` = an explicit Git override for that repo, `true` = explicit jj. The per-repo settings UI sets `true`/`false`.
- *Why:* gives the user-requested behavior — a new co-located repo with the gate on prefers jj; with the gate off it's classified `.git` and uses Git; and any co-located repo can be opted back to Git per-repo — without writing a `preferJJ` value into every repo's settings file at load time (no churn). The `nil`-means-default model makes "prefer jj" the effect of opting in globally, while `false` is the durable per-repo escape hatch.
- *Alternative considered:* persist the gate value into `preferJJ` at add-time. Rejected as equivalent in observable behavior but noisier (touches settings files on load) and it still needs a "never set" state for pre-existing repos.
- *Alternative considered:* derive backend purely from the gate with no per-repo control — rejected because it forces an all-or-nothing choice and can't express "jj here, Git there."

**9. Provide a bookmark push action.** A "Push (jj)" action SHALL be exposed (toolbar + CLI/deeplink) for jj repositories, running `jj git push --bookmark <name>` as the PR-prep step (jj has no Supacode push UI today, but jj users expect bookmark push before a PR exists).

**10. Enumerate jj workspaces live via `jj workspace list` + `jj workspace root --name` (no registry).** Empirically verified in jj 0.42.0 (see Open Questions → resolved): `jj workspace list` yields the workspace names, and `jj workspace root --name <NAME>` returns that workspace's absolute filesystem path — even for a non-current workspace at an arbitrary location. So the listing read-path enumerates names, resolves each path with `root --name`, and builds a row per workspace (skipping any whose directory no longer exists, mirroring git's `isMissing`). The workspace's displayed branch is the bookmark at its working-copy commit, resolved via `jj log -r '<NAME>@' -T bookmarks` (may be empty for an anonymous workspace).
- *Why:* this is jj's supported, location-independent enumeration — analogous to git's `wt ls --json`. Crucially it discovers **pre-existing and externally-created** workspaces (a repo brought into Supacode with workspaces already present), which a track-on-create registry could not.
- *Supersedes:* an earlier track-on-create persisted-registry plan (I had missed the `root --name` flag). No registry is needed; nothing extra is persisted for listing.
- *Note:* `jj workspace add` in a colocated repo is still jj-only (not a git worktree), so git worktree enumeration does not see jj workspaces — `JJBackend` owns listing for jj repos.

**11. jj-native presentation layer (flavor-aware UI), superseding the "one vocabulary" goal.** For a row whose repository is co-located jj (and using the jj backend), the worktree UI presents jj vocabulary — "Workspace"/"Bookmark", "New Workspace…", "Rename Bookmark…", "Forget Workspace…", "Copy as Bookmark Name" — and the new-workspace prompt offers jj revsets/bookmarks rather than git refs. Git-only actions with no jj analogue (Archive/Unarchive) are hidden for jj rows. Plain-git and folder rows are unchanged.
- *Why:* the backend was made jj-aware in Phases 3–7 but the UI kept hardcoded git strings, so a jj repo looked and read like git (and offered Archive, which on a jj workspace routes through the now-jj `removeWorktree` = `jj workspace forget` + dir delete — destructive, not an archive). GUI testing surfaced this. Presenting jj-native vocabulary is exactly the "offer the jj equivalent" the original request asked for.
- *Mechanism:* thread the row's flavor (`isColocatedJJ` / a small vocabulary value) to the views via the same seam used elsewhere; views pick labels from a single vocabulary helper keyed off the flavor, so there's one source of truth and no scattered conditionals.
- *Note (diff-stat semantics, not a bug):* a jj row's line-change stat reflects the `@` working-copy **commit**'s diff (`jj diff -r @ --ignore-working-copy`), i.e. "the size of the current change," whereas git's stat is live uncommitted changes. A fresh jj `@` that already contains committed content shows a non-zero stat; an un-snapshotted external edit shows nothing until the next jj command snapshots. This is inherent to jj's working-copy-as-commit model plus the deliberate `--ignore-working-copy` storm guard.

## Risks / Trade-offs

- **No "current branch" in jj / working-copy watching (highest risk)** → `.git/HEAD` has no jj equivalent and jj auto-snapshots on most commands. Mitigation: watch `.jj/working_copy/` with the same DispatchSource mechanism, derive the displayed branch from the bookmark(s) at `@` via `jj log -r @ --ignore-working-copy`, and prototype this phase last (the foundation and read paths don't depend on it).
- **Anonymous workspaces have no bookmark** → PR matching is by branch name. Mitigation: optionally auto-create a bookmark on workspace creation and offer `jj git push --bookmark` for PR prep; show no branch name (not an error) when `@` is anonymous.
- **Conflicted bookmarks (`name??`)** → a state Git has no analogue for. Mitigation: detect and surface in the rename/list UI rather than silently misbehaving.
- **copy ignored/untracked options don't map cleanly** → jj auto-tracks/snapshots. Mitigation: map to `jj workspace add --sparse-patterns` or hide the toggles for jj repos, with a short note in the prompt.
- **Mixing Git worktrees and jj workspaces in one repo** → legal but confusing. Mitigation: a per-repo backend selection (and consistent Supacode-created entries); detect pre-existing `jj workspace list` entries for the sidebar.
- **jj CLI absent** → Mitigation: detect and degrade to the Git backend even with the gate on.
- **Local toolchain** (informational) → Zig 0.15.2 cannot link the macOS 26.4+ SDK (ziglang/zig#31272), so local builds need Xcode <= 26.3 (matching CI) or an `xcrun`-shim workaround; this affects building Supacode at all, not the jj design.
- **GUI-testing isolation** (operational, learned during Phase 4 validation) → A Debug build run on the same machine as the installed release app collides through shared global state: UserDefaults (same bundle id), the hardcoded `~/.supacode` data dir, AND the `$TMPDIR/zmx-<uid>` multiplexer socket dir. The zmx collision is the worst — two instances on one daemon namespace let one app's `zmx attach` disrupt/duplicate the other's live terminal sessions (this repeatedly corrupted the dev's working session during validation). Mitigation (shipped as dev-tooling commits, not part of this change's specs): give Debug builds a distinct bundle id (`…​.debug`), a separate data dir (`~/.supacode-debug`), and an isolated `ZMX_DIR` (`/tmp/zmx-<uid>-dbg`); or simply run only one supacode at a time. Validated end-to-end once isolated: jj workspaces list and open terminals at their `jj workspace root --name` paths.

## Migration Plan

Phased delivery, each phase its own implementable unit; rollback at any point is simply leaving the experimental gate off (no persisted state to revert, `Repository.vcs` is runtime-only).

1. Foundation — detection + flavor + gate (DONE, CI-green).
2. Settings UI toggle for `experimentalJJIntegration`.
3. `VCSBackend` protocol + `GitBackend` extraction (no behavior change).
4. `JJBackend` read paths (workspace list, bookmark list, diff stat); sidebar renders jj workspaces.
5. Create/remove (workspace add/forget) + prompt revsets + per-repo backend selection.
6. Bookmarks (rename/delete), `jj git fetch`, optional bookmark push; CLI/deeplink routing.
7. Working-copy watcher (`.jj/` + bookmark-at-`@`).

## Open Questions

Resolved (see Decisions 7–9):
- Auto-create a bookmark on workspace creation → **Yes, always** (Decision 7).
- Per-repo "prefer jj" default → **per-repo preference, defaulted from the gate at add-time** (Decision 8).
- Bookmark push action → **Yes, add it** (Decision 9).

Still open:
- For colocation detection on secondary working copies (each jj workspace has its own `.jj`), is root-only detection sufficient, or do linked workspaces need their own probe?
- Bookmark naming when the workspace name collides with an existing bookmark (suffix, reject, or reuse?).
- ~~Workspace enumeration~~ — **RESOLVED → Decision 10 (live `jj workspace list` +
  `jj workspace root --name`).** jj 0.42.0's `jj workspace root --name <NAME>` returns
  any workspace's absolute path (verified for a non-current workspace at an arbitrary
  `/tmp` location), so live enumeration works and discovers pre-existing/external
  workspaces. This supersedes the earlier registry idea (I had missed `root --name`).
