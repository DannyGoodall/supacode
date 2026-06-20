## ADDED Requirements

### Requirement: Co-located Jujutsu detection
The system SHALL classify a repository root as co-located Jujutsu when, and only when, the root is already a Git repository AND a `.jj` directory exists as a peer of `.git` in that root. A `.jj` without a sibling Git directory SHALL NOT be treated as co-located (nor as a Git repository), because Supacode's Git stack cannot drive a non-colocated jj repo whose Git store lives under `.jj/repo/store`.

#### Scenario: Git repo with a .jj directory
- **WHEN** a root contains both a Git directory and a `.jj` directory and detection runs
- **THEN** the root is reported as co-located Jujutsu

#### Scenario: Plain Git repo without .jj
- **WHEN** a root is a Git repository with no `.jj` directory
- **THEN** the root is reported as a plain Git repository, not co-located

#### Scenario: jj-only root without Git
- **WHEN** a root contains a `.jj` directory but no Git directory
- **THEN** the root is reported as neither a Git repository nor co-located

#### Scenario: .jj is a regular file, not a directory
- **WHEN** a Git root has a regular file (not a directory) named `.jj`
- **THEN** the root is reported as a plain Git repository, not co-located

### Requirement: Experimental opt-in gate
The Jujutsu integration SHALL be gated behind a single experimental setting (`experimentalJJIntegration`) that defaults to OFF. While OFF, no root is ever promoted to the co-located flavor and all behavior is identical to the pre-existing Git/folder product.

#### Scenario: Gate off downgrades colocated repo to plain Git
- **WHEN** the experimental setting is off and a co-located root is loaded
- **THEN** the repository is classified as a plain Git repository and no jj behavior is exposed

#### Scenario: Gate on promotes colocated repo
- **WHEN** the experimental setting is on and a co-located root is loaded
- **THEN** the repository is classified as co-located Jujutsu

#### Scenario: Setting is discoverable in Settings
- **WHEN** the user opens Settings
- **THEN** a "Use experimental co-located JJ integration" toggle is presented and its state drives classification on the next load

### Requirement: VCS-flavor classification preserves the Git/none contract
The repository model SHALL expose a VCS flavor of `git`, `gitColocatedJJ`, or `folder`. `isGitRepository` SHALL remain `true` for both `git` and `gitColocatedJJ` and `false` only for `folder`, so that every existing consumer of `isGitRepository` is unaffected by the introduction of the co-located flavor.

#### Scenario: Colocated flavor still reports as a Git repository
- **WHEN** a repository has the co-located Jujutsu flavor
- **THEN** `isGitRepository` is `true` and all Git-gated features (worktree creation, branch operations, PR tracking) remain available

#### Scenario: Folder flavor unchanged
- **WHEN** a non-git folder is loaded
- **THEN** `isGitRepository` is `false` and the limited folder behavior is unchanged

### Requirement: VCS-backend routing
VCS operations that Supacode automates (list/create/remove working copies, branch/bookmark management, base-ref resolution, diff stats, fetch) SHALL be routed through a backend abstraction that selects a Git backend or a Jujutsu backend per repository. The Git backend SHALL preserve current behavior exactly; the Jujutsu backend SHALL be used only for co-located repositories when the gate is on.

#### Scenario: Git repository uses the Git backend
- **WHEN** an operation runs against a plain Git repository
- **THEN** it is handled by the Git backend with unchanged behavior

#### Scenario: Co-located repository uses the Jujutsu backend
- **WHEN** an operation runs against a co-located repository with the gate on
- **THEN** it is handled by the Jujutsu backend

### Requirement: Jujutsu workspace lifecycle mirrors worktrees
For co-located repositories, creating a working copy SHALL create a Jujutsu workspace (`jj workspace add`) and removing one SHALL forget the workspace (`jj workspace forget`) and remove its directory, mirroring the Git worktree create/remove flows. The new-workspace prompt SHALL offer a base revision (bookmark or revset) in place of a Git base ref. Creating a workspace SHALL also create a bookmark, named from the prompt's branch/name field, pointing at the new working-copy commit, so downstream branch/PR/push flows always resolve a name.

#### Scenario: Create a workspace
- **WHEN** the user creates a new working copy in a co-located repository
- **THEN** a Jujutsu workspace is created at the chosen location with the chosen base revision and appears in the sidebar

#### Scenario: Workspace creation auto-creates a bookmark
- **WHEN** a Jujutsu workspace is created
- **THEN** a bookmark named from the prompt's branch/name field is created at the workspace's working-copy commit and shown as the workspace's branch

#### Scenario: Remove a workspace
- **WHEN** the user deletes a co-located working copy
- **THEN** the workspace is forgotten (`jj workspace forget`) and its directory removed, without invoking `git worktree remove`

### Requirement: Workspace discovery via live enumeration
The sidebar listing for a co-located repository SHALL be built by enumerating jj workspaces live: `jj workspace list` for the names, and `jj workspace root --name <NAME>` for each workspace's absolute filesystem path. A row SHALL be produced per workspace, skipping any whose resolved directory no longer exists on disk (mirroring a missing git worktree). This enumeration SHALL include workspaces that were created outside Supacode or already existed when the repository was added.

#### Scenario: Listing enumerates all workspaces with paths
- **WHEN** a co-located repository is listed
- **THEN** every workspace from `jj workspace list` is shown, each at the path returned by `jj workspace root --name`

#### Scenario: Pre-existing / externally-created workspace is listed
- **WHEN** a repository with workspaces created outside Supacode is loaded
- **THEN** those workspaces appear in the listing (live enumeration does not depend on Supacode having created them)

#### Scenario: Missing workspace directory is skipped
- **WHEN** a workspace's resolved directory no longer exists
- **THEN** that workspace is omitted from the listing

### Requirement: Bookmarks mirror branches
For co-located repositories, branch operations SHALL map to Jujutsu bookmarks: rename maps to `jj bookmark rename`, delete maps to `jj bookmark delete`, and branch listing maps to `jj bookmark list`. The displayed "branch" for a workspace SHALL be the bookmark pointing at the working-copy commit (`@`), which MAY be empty when the workspace is anonymous.

#### Scenario: Rename a bookmark
- **WHEN** the user renames the branch of a co-located workspace
- **THEN** the corresponding Jujutsu bookmark is renamed and the new name is reflected in the UI

#### Scenario: Anonymous workspace has no bookmark
- **WHEN** a co-located workspace has no bookmark at `@`
- **THEN** the UI shows no branch name rather than an error

### Requirement: Remote and pull-request operations
For co-located repositories, fetching SHALL use `jj git fetch`, and the product SHALL provide a bookmark push action (`jj git push --bookmark <name> --allow-new`) as a pull-request preparation step, exposed on the CLI/deeplink surface (`supacode worktree push`, `supacode://worktree/<id>/push`). GitHub pull-request tracking, merge, close, and checks SHALL continue to operate via the `gh` CLI unchanged, matching pull requests to workspaces by the pushed bookmark name.

#### Scenario: Fetch on a co-located repository
- **WHEN** a fetch is requested for a co-located repository
- **THEN** `jj git fetch` is used and remote state is updated

#### Scenario: Push a bookmark for PR prep
- **WHEN** the user invokes the push action on a co-located workspace via the CLI (`supacode worktree push`) or the `supacode://worktree/<id>/push` deeplink
- **THEN** the workspace's bookmark is pushed with `jj git push --bookmark <name> --allow-new` so a pull request can be opened against it, and any failure surfaces as an alert (the CLI response reports the error)

#### Scenario: PR tracking still works
- **WHEN** a workspace's bookmark has been pushed and a pull request exists for it
- **THEN** the pull request is tracked and displayed for that workspace exactly as for a Git branch

### Requirement: Per-repository jj preference
For co-located repositories, the Jujutsu backend SHALL be selected when, and only when, `vcs == .gitColocatedJJ` and the per-repository `preferJJ` preference is not an explicit Git override — i.e. backend = jj iff `preferJJ ?? true`. `preferJJ` is a persisted per-repository tri-state: `nil` means "use the default" (prefer jj for a co-located repo), `false` is an explicit Git override for that repository, and `true` is explicit jj. Since a root is only classified `.gitColocatedJJ` when the experimental gate is on, the gate is implicit in the `vcs` guard.

#### Scenario: Co-located repo with the gate on (default)
- **WHEN** a co-located repository is loaded with the experimental gate on and `preferJJ` is unset
- **THEN** the Jujutsu backend is used

#### Scenario: Gate off
- **WHEN** a repository is loaded while the experimental gate is off
- **THEN** it is classified `.git` and the Git backend is used regardless of `preferJJ`

#### Scenario: Plain Git repo is never jj
- **WHEN** a plain `.git` repository has `preferJJ == true`
- **THEN** the Git backend is still used (only `.gitColocatedJJ` repositories are eligible)

#### Scenario: User overrides a co-located repo back to Git
- **WHEN** the user sets `preferJJ` to false for a specific co-located repository
- **THEN** that repository uses the Git backend while other co-located repositories are unaffected

### Requirement: Diff and working-copy change tracking
For co-located repositories, line-change counts SHALL be computed with `jj diff --stat` against the working-copy commit, and live change/branch notifications SHALL be derived by watching the Jujutsu working-copy state rather than `.git/HEAD`. Read-only jj queries used by watchers SHALL avoid triggering working-copy snapshots.

#### Scenario: Line-change counts for a workspace
- **WHEN** a co-located workspace has uncommitted changes
- **THEN** added/removed line counts are derived from `jj diff --stat`

#### Scenario: Live update on external jj edit
- **WHEN** the working copy of a co-located workspace changes outside the app
- **THEN** the sidebar refreshes the workspace's branch label and change indicators

### Requirement: External automation mirrors jj operations
The `supacode-cli` and `supacode://` deeplink surfaces SHALL route their verbs (new, delete, pin, unpin, archive, focus, push) to the appropriate behavior for the target repository, so that creating or removing a working copy on a co-located repository performs the Jujutsu equivalent. The CLI/deeplink **verb vocabulary** SHALL remain stable and backend-neutral (e.g. `worktree new`/`worktree delete`/`worktree push`, not renamed per backend) so existing scripts keep working; this is distinct from the GUI, which presents jj-native vocabulary per the "jj-native UI presentation" requirement.

#### Scenario: CLI new on a co-located repository
- **WHEN** the user runs the worktree/repo "new" command against a co-located repository
- **THEN** a Jujutsu workspace is created via the same command and flags used for Git worktrees

#### Scenario: CLI verbs stay backend-neutral
- **WHEN** a script invokes `supacode worktree new` / `delete` / `push` against a co-located repository
- **THEN** the verbs are unchanged (not renamed to "workspace"/"bookmark") and perform the Jujutsu equivalent

### Requirement: Graceful degradation without the jj CLI
When the `jj` CLI is not available on PATH, a co-located repository SHALL fall back to Git behavior rather than failing, even when the experimental gate is on.

#### Scenario: jj CLI missing
- **WHEN** the experimental gate is on, a root is co-located, but `jj` is not installed
- **THEN** the repository operates via the Git backend and the user is not blocked

### Requirement: jj-native UI presentation
For a row whose repository is co-located Jujutsu and using the jj backend, the GUI SHALL present jj-native vocabulary in place of Git terms — "workspace" for worktree and "bookmark" for branch — across the sidebar context menu, the "new" affordance, the toolbar/Worktrees menu, the command palette, the worktree detail view, the archived-items view, the new-workspace prompt, and the rename prompt. Plain-Git and folder rows SHALL be visually unchanged. No worktree action SHALL be hidden solely because the repository is Jujutsu — every action routes to a jj-safe operation (archive is a sidebar-state move with no filesystem effect; delete maps to `jj workspace forget` + directory removal; rename maps to `jj bookmark rename`). The new-workspace prompt SHALL offer jj bookmarks/revsets in place of Git base refs for a co-located repository.

#### Scenario: jj row shows workspace/bookmark vocabulary
- **WHEN** a co-located workspace row's menus and prompts are shown
- **THEN** they read in jj terms (e.g. "New Workspace…", "Rename Bookmark…", "Delete Workspace…", "Archive Workspace…", "Copy as Bookmark Name", "Base bookmark/revision")

#### Scenario: Git and folder rows are unchanged
- **WHEN** a plain-Git worktree row or a folder row's menus are shown
- **THEN** they read in the existing Git/folder vocabulary, unchanged

#### Scenario: No action hidden for a jj row
- **WHEN** a co-located workspace row's context menu is shown
- **THEN** archive, delete, rename, pin/unpin, and Open Pull Request are all available, each routing to a jj-safe operation

#### Scenario: New-workspace prompt offers jj base revisions
- **WHEN** the new-workspace prompt is shown for a co-located repository
- **THEN** it offers jj bookmarks/revsets as the base revision rather than Git refs
