## 1. Foundation — detection, flavor, gate (DONE)

- [x] 1.1 Add `RepositoryVCS` enum (`.git` / `.gitColocatedJJ` / `.folder`); make `isGitRepository` a computed `vcs != .folder`; keep the backward-compatible `init(isGitRepository:)`
- [x] 1.2 Add pure `Repository.isColocatedJJRepository(at:)` detection (`.jj` dir peer of `.git`, gated on the root being git)
- [x] 1.3 Add `GitClientDependency.isColocatedJJRepository` closure (live + `testValue` defaulted off so existing fixtures stay plain git)
- [x] 1.4 Add `@Shared(.appStorage("experimentalJJIntegration"))` key, default OFF
- [x] 1.5 Wire the loader to promote a colocated root to `.gitColocatedJJ` only when the gate is on (`classifyRoot` helper)
- [x] 1.6 Tests: detection (git/jj/none), flavor↔`isGitRepository` contract, loader gate in all three outcomes (`RepositoryJJColocationTests`)
- [x] 1.7 Verify `make lint` / `make build-app` / `make test` green (verified via CI on macos-26)

## 2. Settings UI toggle

- [x] 2.1 Surface a "Use experimental co-located JJ integration" toggle in the Settings Developer pane ("Experimental" section), bound to `@Shared(.experimentalJJIntegration)`
- [x] 2.2 Settings path: reachable via the existing Developer settings pane; no dedicated deeplink added (not warranted for a single experimental toggle)
- [x] 2.3 Test: classification-follows-gate is covered by the foundation loader tests (`loaderClassifiesColocatedRepoAsGitColocatedJJWhenGateOn` / `...WhenGateOff`), which set the same `@Shared(.experimentalJJIntegration)` key this toggle writes

## 3. Backend dispatch (GitClient / JJClient via the GitClientDependency seam)

- [x] 3.1 Use the existing `GitClientDependency` closure-DI as the VCS abstraction boundary; add `JJClient` as the jj concrete backend (no separate Swift protocol — see Decision 3)
- [x] 3.2 Route `GitClientDependency` live closures per-repo via `shouldUseJujutsuBackend(for:)` (jj when colocated + gate + `preferJJ ?? true`, else Git unchanged), with graceful Git fallback on jj failure — wired for `worktrees` first
- [x] 3.3 Add a persisted per-repository `preferJJ: Bool?` tri-state (nil = default/prefer-jj for colocated, false = Git override, true = explicit jj) on `RepositorySettings`
- [ ] 3.4 Add the backend resolver `usesJujutsuBackend(vcs:preferJJ:) = vcs == .gitColocatedJJ && (preferJJ ?? true)` and wire it into per-repository backend selection
- [ ] 3.5 Per-repo settings UI control to set `preferJJ` (true/false) for a co-located repository
- [ ] 3.6 Tests: existing git/folder reducer tests pass unchanged through the backend seam (green refactor); the resolver returns the expected backend across vcs × preferJJ combinations

## 4. JJBackend read paths

- [x] 4.1 Implement `JJClient` workspace listing via `jj workspace list` + `jj workspace root --name <NAME>` (Decision 10), mapped to the worktree row model; skip workspaces whose resolved dir is missing
- [ ] 4.2 Resolve each workspace's displayed branch from its bookmark at `<NAME>@` (`jj log -r '<NAME>@' -T bookmarks`); also implement local bookmark listing via `jj bookmark list`
- [ ] 4.3 Implement line-change counts via `jj diff --stat -r @ --ignore-working-copy`
- [ ] 4.4 Render jj workspaces in the sidebar/command palette using the existing row model
- [ ] 4.5 Add graceful degradation to Git when the `jj` CLI is absent
- [ ] 4.6 Tests: workspace enumeration parsing (list + root --name, incl. missing-dir skip and a pre-existing/external workspace) with a stubbed shell, plus the degradation path

## 5. Workspace create / remove

- [ ] 5.1 Implement create via `jj workspace add <path> -r <revset> [--name]`; map prompt base-ref to a revset/bookmark; map or hide copy-ignored/untracked toggles (`--sparse-patterns`)
- [ ] 5.2 Auto-create a bookmark named from the prompt's branch/name field, pointing at the new workspace's working-copy commit, on every workspace creation
- [ ] 5.3 Implement remove via `jj workspace forget` + directory removal; skip Git lock/prune machinery for jj
- [ ] 5.4 Reject/translate folder-style and Git-only paths so jj repos route correctly
- [ ] 5.5 Tests: create and remove flows for a co-located repo (stubbed backend), incl. anonymous-workspace handling

## 6. Bookmarks, fetch, push + external automation

- [ ] 6.1 Map branch rename/delete to `jj bookmark rename` / `jj bookmark delete`; re-author `RenameBranchFeature` stderr translation for jj messages and detect conflicted bookmarks (`name??`)
- [ ] 6.2 Map fetch to `jj git fetch`
- [ ] 6.3 Add a bookmark push action (`jj git push --bookmark <name>`) for PR prep, exposed on the toolbar and the CLI/deeplink surface
- [ ] 6.4 Confirm GitHub PR tracking matches PRs to workspaces by pushed bookmark name (no `gh` changes expected)
- [ ] 6.5 Route `supacode-cli` (`repo worktree-new`, `worktree delete`, etc.) and `supacode://` deeplinks to the jj backend for co-located repos, keeping verbs/vocabulary unchanged
- [ ] 6.6 Tests: bookmark ops, fetch, CLI/deeplink routing for co-located repos

## 7. Working-copy watcher

- [ ] 7.1 Add a jj working-copy resolver (sibling to `GitWorktreeHeadResolver`) returning the `.jj/` paths to watch
- [ ] 7.2 Extend `WorktreeInfoWatcherManager` to watch `.jj/working_copy/` for jj repos and emit branch/file-change events
- [ ] 7.3 Derive the current bookmark from `@` for live branch-label updates using `--ignore-working-copy` reads (avoid snapshot storms)
- [ ] 7.4 Tests: watcher emits change/branch events on simulated jj working-copy changes

## 8. Wrap-up

- [ ] 8.1 Ensure all jointly-relevant tests pass for git / jj+git / none
- [ ] 8.2 `make check` (format + lint) and full `make test` green
- [ ] 8.3 Update CLAUDE.md / docs with the co-located jj behavior and the experimental setting
