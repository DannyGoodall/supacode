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
- [x] 3.4 Add the backend resolver `usesJujutsuBackend(vcs:preferJJ:) = vcs == .gitColocatedJJ && (preferJJ ?? true)` and wire it into `shouldUseJujutsuBackend(for:)` / `...ForWorkingCopy(at:)`
- [x] 3.5 Per-repo settings UI: a "Version Control" Picker (Default/Use Jujutsu/Use Git → preferJJ nil/true/false) in RepositorySettingsView, shown only for colocated repos (threaded via SettingsRepositorySummary.isColocatedJJ)
- [x] 3.6 Tests: resolver matrix `usesJujutsuBackend(vcs:preferJJ:)` across all vcs × preferJJ combinations (`RepositoryJJColocationTests:137–152`); existing git/folder reducer tests pass unchanged through the seam (full suite — 8.1/8.2).

## 4. JJBackend read paths

- [x] 4.1 Implement `JJClient` workspace listing via `jj workspace list` + `jj workspace root --name <NAME>` (Decision 10), mapped to the worktree row model; skip workspaces whose resolved dir is missing
- [x] 4.2 Resolve each workspace's displayed branch from its bookmark at `<NAME>@`; route the `branchName` working-copy op to `JJClient.branchName(forWorkspaceAt:)`. (Standalone `jj bookmark list` deferred to the bookmark-write phase where it's needed.)
- [x] 4.3 Implement line-change counts via `jj diff --stat -r @`; route the `lineChanges` working-copy op to `JJClient.lineChanges(at:)`
- [x] 4.4 Render jj workspaces in the sidebar/command palette — free: jj workspaces flow through `worktrees`/`branchName`/`lineChanges` into the existing `[Worktree]` row model
- [x] 4.5 Graceful degradation: `worktrees` falls back to Git on jj failure; working-copy ops only route to jj when a `.jj` dir is present (else Git)
- [x] 4.6 Tests: ✅ `worktrees` enumeration (list + root --name, missing-dir skip, arbitrary location), ✅ bookmark-as-name, ✅ branchName, ✅ lineChanges. Reducer-level routing intent is covered by the loader-classification tests (`RepositoryJJColocationTests` gate-on/off → `vcs`) + the resolver matrix (3.6); the degradation fallback (jj CLI missing → git) is implemented in the `worktrees` closure do/catch. A live-routing unit test isn't added — `JJClient()` is constructed inline in the live closures (not injected), so it can't be deterministically stubbed at the reducer level.

## 5. Workspace create / remove

- [x] 5.1 Implement create via `jj workspace add <path> --name <name> [-r <revset>]`; base-ref→revset translation (remote/branch → branch@remote only for known remotes). (Copy-ignored/untracked are dropped for jj since it auto-snapshots; surfacing this in the prompt UI — hide/relabel the toggles for jj repos — is a small follow-up.)
- [x] 5.2 Auto-create a bookmark named from the name field at the new workspace's `@` on every create (Decision 7)
- [x] 5.3 Implement remove via `jj workspace forget` (workspace name resolved by path-match) + directory removal + optional `jj bookmark delete`; no Git lock/prune machinery
- [x] 5.4 Routing handles it: colocated repos are git repos so they pass the existing `isGitRepository` guards, then `shouldUseJujutsuBackend` sends create/remove to the jj backend; the main-worktree guard still protects the primary
- [x] 5.5 Tests: create (add + remote-ref translation + auto-bookmark), slashed-bookmark untranslated, remove (forget-by-path-match + bookmark delete)

## 6. Bookmarks, fetch, push + external automation

- [x] 6.1 Branch rename → `jj bookmark rename` (routed; rename flow works for jj workspaces); delete → `jj bookmark delete` (via `removeWorkspace`, Phase 5). ⏳ Follow-up: re-author `RenameBranchFeature` stderr translation for jj messages + detect conflicted bookmarks (`name??`).
- [x] 6.2 Map fetch to `jj git fetch` (routed `fetchRemote`/`remoteNames`)
- [x] 6.3 Bookmark push: backend (`JJClient.pushBookmark`) + surface as **CLI + deeplink** (`supacode worktree push`, `supacode://worktree/<id>/push` → `RepositoriesFeature.pushWorktreeBookmark` → routed `GitClientDependency.pushBranch`). Toolbar action intentionally omitted (user chose CLI/deeplink). Push also works for git worktrees (`git push -u origin`).
- [x] 6.4 No code: GitHub PR tracking matches by `headRefName` = the pushed bookmark/branch name, so a pushed bookmark is tracked exactly like a git branch (the `gh`/GraphQL path is backend-agnostic).
- [x] 6.5 Existing CLI/deeplink verbs (`repo worktree-new`, `worktree delete`, rename) already route to the jj backend — they dispatch the same reducer actions → routed `GitClientDependency` closures. New `push` verb added (6.3).
- [x] 6.6 Tests: bookmark name parsing, rename, fetch, push command shapes (`JJClientTests`); push deeplink routing (`AppFeatureDeeplinkTests`). Reducer-level routing coverage as noted in 4.6.

## 7. Working-copy watcher

- [x] 7.1 `JJWorktreeStateResolver.opHeadsURL(forRepositoryRoot:fileManager:)` (sibling to `GitWorktreeHeadResolver`) returns the repository's `.jj/repo/op_heads/heads` directory to watch (nil when absent / not a dir)
- [x] 7.2 `WorktreeInfoWatcherManager.watchURL(for:)` seam: routes to the jj watch path for backends where `shouldUseJujutsuBackend(for:)` is true, else `.git/HEAD`; the rest of the DispatchSource pipeline (debounce + `branchChanged`/`filesChanged` emit) is shared. Watch **`.jj/repo/op_heads/heads`** (the op-log head), which changes only on real jj operations and never on our `--ignore-working-copy` reads. (An earlier attempt watching the `.jj/working_copy` directory churned and each event spawned login-shell `jj` reads, saturating the main actor — GUI testing surfaced this; op_heads is the quiet, no-feedback target.)
- [x] 7.3 Already satisfied: every `JJClient` read used by the watcher pipeline (`branchName`, `lineChanges`, bookmark/workspace reads) passes `--ignore-working-copy`, so a watcher-triggered read can't auto-snapshot and re-fire the watcher (no storm). Branch label re-derives downstream via the jj-routed `gitClient.branchName`.
- [x] 7.4 Tests: deterministic `JJWorktreeStateResolverTests` (present/absent/file-not-dir); `WorktreeInfoWatcherManager` seam test (gate-on co-located worktree routes through the jj path and loads cleanly). Real DispatchSource firing is not unit-tested — same as the existing git watcher (non-deterministic real-time fire can't be driven by TestClock).

## 8. Wrap-up

- [x] 8.1 All jointly-relevant tests pass for git / jj+git / none (full suite: 1696 passed under Xcode 26.3)
- [x] 8.2 `make check` (format + lint) and full `make test` green
- [x] 8.3 Update CLAUDE.md / docs with the co-located jj behavior and the experimental setting (added "Jujutsu (jj) co-located integration" section to `AGENTS.md`, the real target of the `CLAUDE.md` symlink)

## 9. jj-native presentation layer (added after GUI testing — Decision 11)

The backend routes to jj, but the UI kept hardcoded git vocabulary. Make the worktree UI flavor-aware for co-located jj repos. **Audit finding:** no action needs hiding for safety — archive is a sidebar-state move (no fs/git op), delete → `jj workspace forget` + dir removal, rename → `jj bookmark rename`. So this phase is relabeling + the prompt's revset source.

- [x] 9.1 `WorktreeVocabulary` helper (Workspace/Bookmark vs Worktree/Branch, keyed off `isJJ`); git path reproduces existing strings verbatim. Resolvers `RepositoriesFeature.State.usesJujutsuBackend(forRepository:)` + `worktreeVocabulary(forRepository:)` / `worktreeVocabulary(forWorktree:)`.
- [x] 9.2 Flavor reached per view: sidebar context menu + New button via the parent store; toolbar/Worktrees menu via `WorktreeMenuSnapshot.selectedWorktreeVocabulary`; `isColocatedJJ` threaded into `WorktreeCreationPromptFeature.State` + `RenameBranchFeature.State` (set at creation) and a `vocab` param into `MissingWorktreeDetailView`.
- [x] 9.3 Relabelled for jj rows: sidebar context menu (slice A), New button (A), toolbar/Worktrees menu (B), create + rename prompts (C), missing-worktree detail (D). ⏳ Command palette deferred — its view holds only `CommandPaletteFeature` state, so a row must carry an `isJJ` flag built in the reducer (follow-up). Archived empty-state header left generic (no repo → no flavor).
- [x] 9.4 Effectively satisfied for co-located repos: the prompt's base-ref menu lists git refs which, in a co-located repo, ARE the bookmarks (jj exports bookmarks to git refs), the field is relabelled "Base revision", and `JJClient.createWorkspace` translates the selected ref → revset on submit. ⏳ Optional refinement: route `branchInventory` to native `jj bookmark` enumeration (incl. `@`/`trunk()` revsets).
- [x] 9.5 Tests: `WorktreeVocabularyTests` (git-verbatim + jj strings). Flavor-gated selection is build-verified and exercised through the resolver matrix (`RepositoryJJColocationTests`).

## 10. Polish / follow-ups (post-GUI-testing)

Live updates restored via the `.jj/op_heads` watcher (Phase 7 note). All done after GUI testing:

- [x] 10.1 Command palette relabel — `isJJ` flag on `CommandPaletteItem` (built in `CommandPaletteFeature` from the selected/row repo's backend); global New/Refresh/View-Archived + rename items read jj vocabulary, help text follows `row.isJJ`.
- [x] 10.2 jj **change id** on the sidebar row label — `change_id.shortest(8)` (bold unique prefix + dim remainder, baseline-aligned, `.caption` monospaced). Combined bookmark+change-id enumeration template (no extra subprocess); carried on `Worktree.jjChangeId`, refreshed live by the watcher (`.worktreeChangeIdLoaded`).
- [x] 10.3 **Bird icon** (SF Symbol) next to the branch glyph for jj rows, top-aligned/tight, gated on `SidebarItemFeature.State.isColocatedJJ`.
- [x] 10.4 Watcher latency fixed — workspace name cached at enumeration (`Worktree.jjWorkspaceName`, preserved across `updateWorktreeName`); `branchName` is one cheap `jj log`, and the reducer falls back to the cached name for an anonymous `@` (no re-enumeration on the op path).
