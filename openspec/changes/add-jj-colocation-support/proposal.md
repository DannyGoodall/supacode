## Why

Supacode is a Git + Git-worktree orchestrator: every automated operation (creating worktrees, renaming/deleting branches, diffing, watching HEAD, tracking PRs) assumes Git. Many users run **Jujutsu (jj)** co-located on top of Git, where `.jj` and `.git` sit as peers in the repository root. Because a co-located jj repo is *also* a valid Git repo, we can detect it and offer jj-native equivalents (workspaces for worktrees, bookmarks for branches, `jj git fetch/push` for remotes) **without disturbing any existing Git behavior**. This lets jj users drive Supacode with the model they actually work in, while non-jj users are completely unaffected.

This change retrofits the requirements, design, and tasks for that capability. The foundation (detection + classification behind an experimental gate) is already implemented and verified green on CI; the remaining phases are captured here as a roadmap.

## What Changes

- Add a third repository **VCS flavor** alongside the existing git/folder classification: `.git`, `.gitColocatedJJ`, `.folder`. `isGitRepository` stays `true` for both git flavors so all existing consumers are unaffected (**not breaking**).
- Detect co-located jj at load time (`.jj` directory peer of `.git`), gated entirely behind a new **experimental opt-in setting** (`experimentalJJIntegration`, default off). When off, behavior is byte-for-byte identical to today.
- Surface the setting in the Settings UI ("Use experimental co-located JJ integration").
- Introduce a **VCS-backend abstraction** so worktree/branch/diff/remote operations route to either a Git backend (today's behavior, unchanged) or a jj backend, selected per repository.
- Add jj-native automation for co-located repos, mirroring the Git features the product already automates:
  - **Workspaces** ↔ worktrees: `jj workspace add` (create), `jj workspace forget` + dir removal (delete/prune); reflected in the sidebar, command palette, CLI, and deeplinks.
  - **Bookmarks** ↔ branches: `jj bookmark create/rename/delete/list`; bookmark-at-`@` resolution for display and PR matching.
  - **Remotes/PRs**: `jj git fetch`; optional `jj git push --bookmark` for PR prep. GitHub/`gh` PR tracking is unchanged (the colocated `.git` is still present).
  - **Diff/status**: `jj diff --stat` for line-change counts.
  - **Working-copy watching**: replace `.git/HEAD` watching with `.jj/` working-copy watching (the one area with no direct Git analogue).
- Mirror the new operations across the external automation surface: `supacode-cli` (`worktree`/`repo`) and the `supacode://` deeplink layer. The bookmark **push** action is exposed on the CLI/deeplink surface (`supacode worktree push`, `supacode://worktree/<id>/push`), not the toolbar.
- **Present jj-native vocabulary for jj rows.** For a co-located repository using the jj backend, the worktree UI reads in jj terms — *Workspace*/*Bookmark* (e.g. "New Workspace…", "Rename Bookmark…", "Delete Workspace…", "Archive Workspace…", "Copy as Bookmark Name") — across the sidebar context menu, the New button, the toolbar/Worktrees menu, the command palette, the creation prompt, and the rename prompt. The new-workspace prompt offers jj revsets/bookmarks in place of Git base refs. Labels are flavor-aware: plain-Git and folder rows are visually unchanged. All actions stay available because each routes to a jj-safe operation — archive is a sidebar-state move (no filesystem op), delete → `jj workspace forget` + directory removal, rename → `jj bookmark rename`; no action is hidden for safety. *(This revises an earlier "keep one vocabulary regardless of backend" intent, which undershot the original "offer the jj equivalent — workspaces/bookmarks" requirement; surfaced during GUI testing.)*
- Add jj-specific tests, and keep all jointly-relevant tests passing for git / jj+git / none.

## Capabilities

### New Capabilities
- `jj-colocation`: Detection of co-located Jujutsu repositories, the experimental opt-in gate, the VCS-flavor classification (with its backward-compatibility contract), the VCS-backend routing, and the jj-native equivalents of the Git operations Supacode automates (workspaces, bookmarks, fetch/push, diff, working-copy watching) across the reducer, settings, CLI, and deeplink surfaces.

### Modified Capabilities
<!-- No pre-existing specs in openspec/specs/ to modify. The repository-classification
     behavior change (git/none -> git/jj+git/none) and its backward-compatibility
     guarantee are captured as requirements within the new `jj-colocation` capability. -->

## Impact

- **Code**: `supacode/Domain/Repository.swift` (VCS flavor + detection); `supacode/Clients/Repositories/GitClientDependency.swift` and a new `VCSBackend` seam; `supacode/Features/Repositories/Reducer/RepositoriesFeature.swift` (loader + create/remove/rename/fetch flows); `WorktreeInfoWatcherManager` + a jj working-copy resolver; `WorktreeCreationPromptFeature`/`RenameBranchFeature`; Settings UI; `supacode-cli/Commands/*` and `Clients/Deeplink/DeeplinkClient.swift`.
- **Runtime dependency**: requires the `jj` CLI on PATH for jj-flavored repos (detected; absence degrades gracefully to Git).
- **Settings/persistence**: one new `@Shared(.appStorage("experimentalJJIntegration"))` key (default off); optional per-repo "prefer jj" preference. `Repository.vcs` is runtime-only (not persisted) so no migration.
- **No impact when the gate is off**: classification, sidebar, terminal, PR tracking, and the `git-wt` `wt` flows are unchanged for all existing users.
- **Build/CI**: no new build steps; existing `make build-app`/`make test` cover it (CI on macos-26, Xcode <= 26.3).
