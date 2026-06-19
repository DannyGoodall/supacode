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
- Keep one user-facing vocabulary (worktree/branch/new/delete) regardless of backend.

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

**3. `VCSBackend` protocol with `GitBackend` (today) and `JJBackend`.** Route the operations the product automates through a backend selected per repository, behind the existing `GitClientDependency` seam so reducers and tests are unaffected.
- *Why:* isolates jj specifics, keeps Git behavior literally the current code, and lets the backend decide worktree-vs-workspace so the UI/CLI vocabulary stays single.
- *Alternative considered:* `if vcs == .gitColocatedJJ` branches scattered across the reducer — rejected as unmaintainable and hard to test.

**4. Mapping table.** worktree→workspace (`jj workspace add`/`forget`), branch→bookmark (`jj bookmark …`), base ref→revset/bookmark, fetch→`jj git fetch`, diff `HEAD --shortstat`→`jj diff --stat -r @`, `.git/HEAD` watch→`.jj/` working-copy watch. Read-only jj queries pass `--ignore-working-copy` to avoid snapshot storms.

**5. Bypass `git-wt` for jj.** The bundled `wt` is a Git-worktree tool; the jj backend calls `jj workspace` directly.

**6. Skip Supacode's worktree lock machinery for jj.** The `locked` admin-dir file Supacode writes for Git worktrees has no jj analogue; ownership for jj is tracked via `jj workspace list`.

## Risks / Trade-offs

- **No "current branch" in jj / working-copy watching (highest risk)** → `.git/HEAD` has no jj equivalent and jj auto-snapshots on most commands. Mitigation: watch `.jj/working_copy/` with the same DispatchSource mechanism, derive the displayed branch from the bookmark(s) at `@` via `jj log -r @ --ignore-working-copy`, and prototype this phase last (the foundation and read paths don't depend on it).
- **Anonymous workspaces have no bookmark** → PR matching is by branch name. Mitigation: optionally auto-create a bookmark on workspace creation and offer `jj git push --bookmark` for PR prep; show no branch name (not an error) when `@` is anonymous.
- **Conflicted bookmarks (`name??`)** → a state Git has no analogue for. Mitigation: detect and surface in the rename/list UI rather than silently misbehaving.
- **copy ignored/untracked options don't map cleanly** → jj auto-tracks/snapshots. Mitigation: map to `jj workspace add --sparse-patterns` or hide the toggles for jj repos, with a short note in the prompt.
- **Mixing Git worktrees and jj workspaces in one repo** → legal but confusing. Mitigation: a per-repo backend selection (and consistent Supacode-created entries); detect pre-existing `jj workspace list` entries for the sidebar.
- **jj CLI absent** → Mitigation: detect and degrade to the Git backend even with the gate on.
- **Local toolchain** (informational) → Zig 0.15.2 cannot link the macOS 26.4+ SDK (ziglang/zig#31272), so local builds need Xcode <= 26.3 (matching CI) or an `xcrun`-shim workaround; this affects building Supacode at all, not the jj design.

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

- Should workspace creation always auto-create a bookmark, or only when the user names one? (Affects PR matching for otherwise-anonymous workspaces.)
- Default for a per-repo "prefer jj" preference when colocation is detected: default to Git (opt-in per repo) or to jj? Leaning Git-by-default for safety.
- Should a bookmark "push" action be added to the toolbar/CLI now, or deferred until PR-prep demand is confirmed?
- For colocation detection on secondary working copies (each jj workspace has its own `.jj`), is root-only detection sufficient, or do linked workspaces need their own probe?
