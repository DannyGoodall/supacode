import Foundation
import SupacodeSettingsShared

/// Jujutsu backend for co-located repositories — the jj counterpart to the
/// parts of `GitClient` that Supacode automates. Shells out to the `jj` CLI.
/// Selected per-repository by `GitClientDependency` only when
/// `Repository.usesJujutsuBackend` is true (gate on, colocated, not a per-repo
/// Git override). All operations are `nonisolated` so they run off the main
/// actor like `GitClient`.
struct JJClient {
  private let shell: ShellClient

  nonisolated init(shell: ShellClient = .live) {
    self.shell = shell
  }

  /// Live workspace enumeration (Decision 10). jj cannot list workspaces with
  /// their paths in one call, so: `jj workspace list` yields the names and
  /// `jj workspace root --name <NAME>` resolves each absolute path (works for
  /// non-current workspaces at arbitrary locations). Workspaces whose resolved
  /// directory no longer exists are skipped, mirroring a missing git worktree.
  /// This discovers pre-existing / externally-created workspaces too.
  nonisolated func workspaces(for repoRoot: URL) async throws -> [Worktree] {
    let repositoryRootURL = repoRoot.standardizedFileURL
    let names = try await workspaceNames(for: repositoryRootURL)
    let fileManager = FileManager.default
    var worktrees: [Worktree] = []
    for name in names {
      // The `default` workspace is the colocated checkout at the repo root.
      // Older `.jj` repos (created before jj recorded workspace paths) answer
      // `jj workspace root --name default` with "no recorded path", so fall
      // back to the repo root rather than dropping the row — otherwise the repo
      // enumerates zero workspaces and can't be selected / opened.
      let resolvedURL = await workspaceRootURL(named: name, repoRoot: repositoryRootURL)
      guard let workspaceURL = resolvedURL ?? (name == Self.defaultWorkspaceName ? repositoryRootURL : nil)
      else {
        continue
      }
      guard fileManager.fileExists(atPath: workspaceURL.path(percentEncoded: false)) else {
        continue
      }
      // Display the bookmark at the workspace's working-copy commit when one
      // exists; otherwise fall back to the workspace name. An anonymous
      // workspace (no bookmark) is treated as not attached, mirroring a
      // detached-HEAD git worktree.
      let head = await headInfo(named: name, repoRoot: repositoryRootURL)
      let isAttached = !head.bookmark.isEmpty
      let detail = WorktreeTextFormatting.relativePath(from: repositoryRootURL, to: workspaceURL)
      let resourceValues = try? workspaceURL.resourceValues(forKeys: [
        .creationDateKey, .contentModificationDateKey,
      ])
      let createdAt = resourceValues?.creationDate ?? resourceValues?.contentModificationDate
      worktrees.append(
        Worktree(
          location: .local(workingDirectory: workspaceURL, repositoryRoot: repositoryRootURL),
          kind: .git,
          name: isAttached ? head.bookmark : name,
          detail: detail,
          createdAt: createdAt,
          isMissing: false,
          isAttached: isAttached,
          jjChangeId: head.changeId,
          jjWorkspaceName: name
        )
      )
    }
    return worktrees
  }

  /// Workspace names via `jj workspace list -T 'self.name() ++ "\n"'`.
  nonisolated private func workspaceNames(for repoRoot: URL) async throws -> [String] {
    let template = "self.name() ++ \"\\n\""
    let output = try await runJJ(
      ["workspace", "list", "--ignore-working-copy", "-T", template],
      cwd: repoRoot
    )
    return
      output
      .split(whereSeparator: \.isNewline)
      .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
  }

  /// Bookmark + change id at the working-copy commit of workspace `name`,
  /// resolved from the primary via the `<name>@` revset in a single `jj log`
  /// call (no extra subprocess per workspace). Bookmark is empty when anonymous.
  nonisolated private func headInfo(
    named name: String,
    repoRoot: URL
  ) async -> (bookmark: String, changeId: ChangeIdDisplay?) {
    let output = try? await runJJ(
      ["log", "--ignore-working-copy", "--no-graph", "-r", "\(name)@", "-T", Self.headTemplate],
      cwd: repoRoot
    )
    return Self.parseHead(output)
  }

  /// Change id of `@` for the workspace rooted at `workspaceURL` — the watcher
  /// refreshes this live alongside `branchName`. Cheap single `jj log`; safe on
  /// the (quiet) op-log watcher path.
  nonisolated func changeId(forWorkspaceAt workspaceURL: URL) async -> ChangeIdDisplay? {
    let output = try? await runJJ(
      ["log", "--ignore-working-copy", "--no-graph", "-r", "@", "-T", Self.headTemplate],
      cwd: workspaceURL.standardizedFileURL
    )
    return Self.parseHead(output).changeId
  }

  /// Bookmark at `@` for the workspace (jj counterpart to `GitClient.branchName`).
  /// `nil` when `@` is anonymous — the caller (the reducer's branch handler)
  /// falls back to the cached `Worktree.jjWorkspaceName`, so we DON'T re-run the
  /// expensive `jj workspace list` + per-workspace `root --name` enumeration on
  /// every op (that was the ~5s anonymous-`@` latency). One cheap `jj log`.
  nonisolated func branchName(forWorkspaceAt workspaceURL: URL) async -> String? {
    let output = try? await runJJ(
      ["log", "--ignore-working-copy", "--no-graph", "-r", "@", "-T", Self.bookmarkTemplate],
      cwd: workspaceURL.standardizedFileURL
    )
    let bookmark = Self.firstBookmark(from: output)
    return bookmark.isEmpty ? nil : bookmark
  }

  /// Line changes for the workspace at `workspaceURL` via `jj diff --stat -r @`.
  /// nil when jj fails (mirrors `GitClient.lineChanges` returning nil).
  nonisolated func lineChanges(at workspaceURL: URL) async -> (added: Int, removed: Int)? {
    guard
      let output = try? await runJJ(
        ["diff", "--stat", "-r", "@", "--ignore-working-copy"],
        cwd: workspaceURL.standardizedFileURL
      )
    else {
      return nil
    }
    return WorktreeTextFormatting.parseShortstat(output)
  }

  /// jj's primary/initial workspace name — the colocated checkout at the repo
  /// root. Used as the fall-back path when an older `.jj` can't report it.
  nonisolated private static let defaultWorkspaceName = "default"

  nonisolated private static let bookmarkTemplate =
    "local_bookmarks.map(|b| b.name()).join(\",\") ++ \"\\n\""

  /// Tab-separated `change-id-prefix ⇥ change-id-rest ⇥ bookmarks` for a single
  /// revision. `shortest(8)` mirrors jj's default log: `.prefix()` is the
  /// shortest UNIQUE prefix (highlighted) and `.rest()` pads to 8 chars (dim).
  /// Plain `shortest()` would leave `.rest()` empty (its "shortest" form is just
  /// the unique prefix), which hid the dim remainder.
  ///
  /// Field order is load-bearing: `ShellClient` trims leading/trailing
  /// whitespace off the whole stdout, so the change-id prefix — which is ALWAYS
  /// non-empty — must lead. The bookmarks field is empty for an anonymous `@`;
  /// putting it last means a trimmed trailing tab just drops the (empty) field
  /// instead of shifting `prefix`/`rest` into the wrong slots (the bug where an
  /// anonymous workspace rendered its change-id prefix as a bookmark name).
  nonisolated private static let headTemplate =
    "change_id.shortest(8).prefix() ++ \"\\t\" ++ change_id.shortest(8).rest() ++ \"\\t\""
    + " ++ local_bookmarks.map(|b| b.name()).join(\",\") ++ \"\\n\""

  /// First bookmark from the comma-joined template output (empty when none).
  nonisolated private static func firstBookmark(from output: String?) -> String {
    guard let output else { return "" }
    let line =
      output
      .split(whereSeparator: \.isNewline)
      .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
      .first { !$0.isEmpty } ?? ""
    return line.split(separator: ",").first.map(String.init) ?? line
  }

  /// Parses `headTemplate` output into the first bookmark + the change id.
  nonisolated private static func parseHead(
    _ output: String?
  ) -> (bookmark: String, changeId: ChangeIdDisplay?) {
    guard
      let line = output?.split(whereSeparator: \.isNewline)
        .map(String.init)
        .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
    else {
      return ("", nil)
    }
    // Field order matches `headTemplate`: prefix ⇥ rest ⇥ bookmarks. The prefix
    // is always present (every commit has a change id); rest and bookmarks may
    // be empty/absent after the shell trims trailing whitespace.
    let fields = line.components(separatedBy: "\t")
    let prefix = fields.first?.trimmingCharacters(in: .whitespaces) ?? ""
    let rest = fields.count > 1 ? fields[1].trimmingCharacters(in: .whitespaces) : ""
    let bookmarks = fields.count > 2 ? fields[2] : ""
    let bookmark =
      bookmarks.split(separator: ",").first.map(String.init)?
      .trimmingCharacters(in: .whitespaces) ?? ""
    let changeId = (prefix + rest).isEmpty ? nil : ChangeIdDisplay(prefix: prefix, rest: rest)
    return (bookmark, changeId)
  }
  // MARK: - Create

  /// Streaming create matching `GitClient.createWorktreeStream`'s event shape.
  /// jj workspace creation is a couple of fast commands, so this wraps the
  /// async `createWorkspace` and emits a single `.finished` (plus error
  /// propagation) rather than streaming subprocess lines.
  nonisolated func createWorkspaceStream(
    named name: String,
    in repoRoot: URL,
    baseDirectory: URL,
    baseRef: String,
    directoryOverride: URL?
  ) -> AsyncThrowingStream<GitWorktreeCreateEvent, Error> {
    AsyncThrowingStream { continuation in
      Task {
        do {
          let worktree = try await self.createWorkspace(
            named: name,
            in: repoRoot,
            baseDirectory: baseDirectory,
            baseRef: baseRef,
            directoryOverride: directoryOverride
          )
          continuation.yield(.finished(worktree))
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
    }
  }

  /// Creates a jj workspace (`jj workspace add`) and auto-creates a bookmark at
  /// its working-copy commit (Decision 7), so the workspace's "branch" is
  /// non-anonymous and PR/push flows resolve a name. The base ref is resolved
  /// to a jj revset (a git-style `remote/branch` is translated to `branch@remote`
  /// only when the prefix is a known remote, so slashed bookmark names survive).
  nonisolated func createWorkspace(
    named name: String,
    in repoRoot: URL,
    baseDirectory: URL,
    baseRef: String,
    directoryOverride: URL?
  ) async throws -> Worktree {
    let repositoryRootURL = repoRoot.standardizedFileURL
    // No `.isDirectory` hint: that appends a trailing slash, which would make
    // the created workspace's path (and Worktree id) differ from the
    // no-trailing-slash path the listing derives via `jj workspace root --name`
    // for the same directory.
    let targetURL = (directoryOverride ?? baseDirectory.appending(path: name)).standardizedFileURL
    // `jj workspace add` doesn't create missing parent directories, whereas the
    // git path (`wt`) creates the base dir. Mirror that so a first workspace
    // under a not-yet-existing base (e.g. ~/.supacode/repos/<repo>/) doesn't
    // fail with "Cannot access … No such file or directory".
    try FileManager.default.createDirectory(
      at: targetURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    var addArguments = ["workspace", "add", targetURL.path(percentEncoded: false), "--name", name]
    if let revset = await revset(forBaseRef: baseRef, repoRoot: repositoryRootURL) {
      addArguments += ["-r", revset]
    }
    _ = try await runJJ(addArguments, cwd: repositoryRootURL)
    // Auto-create the bookmark at the new workspace's working-copy commit.
    // Best-effort: a name collision shouldn't fail the whole create.
    _ = try? await runJJ(["bookmark", "create", name, "-r", "\(name)@"], cwd: repositoryRootURL)
    // Build the Worktree from the SAME canonical path the listing enumerates
    // via `jj workspace root --name` (jj may canonicalize symlinks/firmlinks,
    // so it can differ from `targetURL`). If they differ, the post-create
    // reload would treat this worktree's id as removed — tearing down its
    // freshly-opened terminal — then re-add it under the canonical id.
    let canonicalURL = await workspaceRootURL(named: name, repoRoot: repositoryRootURL) ?? targetURL
    let detail = WorktreeTextFormatting.relativePath(from: repositoryRootURL, to: canonicalURL)
    let createdAt = try? canonicalURL.resourceValues(forKeys: [.creationDateKey]).creationDate
    return Worktree(
      location: .local(workingDirectory: canonicalURL, repositoryRoot: repositoryRootURL),
      kind: .git,
      name: name,
      detail: detail,
      createdAt: createdAt,
      isMissing: false,
      isAttached: true,
      jjWorkspaceName: name
    )
  }

  // MARK: - Remove

  /// Removes a jj workspace: resolve its workspace name from the path, `jj
  /// workspace forget` it, delete its directory, and (when requested) delete
  /// its bookmark. No git lock/prune machinery — that's git-worktree-specific.
  /// Returns the removed working directory (matching `GitClient.removeWorktree`).
  nonisolated func removeWorkspace(_ worktree: Worktree, deleteBookmark: Bool) async throws -> URL {
    let repositoryRootURL = worktree.repositoryRootURL.standardizedFileURL
    let targetURL = worktree.workingDirectory.standardizedFileURL
    if let workspaceName = try await workspaceName(forPath: targetURL, repoRoot: repositoryRootURL) {
      _ = try await runJJ(["workspace", "forget", workspaceName], cwd: repositoryRootURL)
    }
    if deleteBookmark, !worktree.name.isEmpty {
      _ = try? await runJJ(["bookmark", "delete", worktree.name], cwd: repositoryRootURL)
    }
    // Remove off the calling task so a large tree doesn't block the reducer.
    Task.detached {
      try? FileManager.default.removeItem(at: targetURL)
    }
    return worktree.workingDirectory
  }

  /// Resolves the workspace *name* (needed for `jj workspace forget`) whose
  /// resolved root matches `path`. The displayed `Worktree.name` is the bookmark
  /// (or workspace name), so we can't assume it; match by path instead.
  nonisolated private func workspaceName(forPath path: URL, repoRoot: URL) async throws -> String? {
    let target = path.standardizedFileURL.path(percentEncoded: false)
    for name in try await workspaceNames(for: repoRoot) {
      guard let resolved = await workspaceRootURL(named: name, repoRoot: repoRoot) else { continue }
      if resolved.path(percentEncoded: false) == target { return name }
    }
    return nil
  }

  /// Canonical root URL of workspace `name` via `jj workspace root --name`.
  /// `nil` on command failure or empty output. `--ignore-working-copy` keeps
  /// the read from auto-snapshotting; `.standardizedFileURL` is the same
  /// canonicalization the listing uses, so create / list / forget stay in
  /// lockstep on the workspace id.
  nonisolated private func workspaceRootURL(named name: String, repoRoot: URL) async -> URL? {
    guard
      let output = try? await runJJ(
        ["workspace", "root", "--name", name, "--ignore-working-copy"],
        cwd: repoRoot
      )
    else { return nil }
    let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    return URL(fileURLWithPath: trimmed).standardizedFileURL
  }

  /// Maps a base ref to a jj revset: nil for empty (jj defaults to the current
  /// workspace's parent); a git-style `remote/branch` becomes `branch@remote`
  /// only when the prefix is a known remote (so a slashed bookmark like
  /// `feature/x` is left intact); otherwise used as-is (bookmark or revset).
  nonisolated private func revset(forBaseRef baseRef: String, repoRoot: URL) async -> String? {
    let trimmed = baseRef.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let remotes = (try? await remoteNames(for: repoRoot)) ?? []
    if let match = GitReferenceQueries.remotePrefixMatch(ref: trimmed, remoteNames: remotes) {
      return "\(match.branch)@\(match.remote)"
    }
    return trimmed
  }

  // MARK: - Bookmarks / remotes / fetch

  /// Local bookmark names (lowercased, matching `GitClient.localBranchNames`)
  /// via `jj bookmark list -T 'name() ++ "\n"'`. The `-T` template emits one
  /// bare name per line (robust to display/conflict formatting), matching how
  /// `workspaceNames` reads `jj workspace list`. Used for rename dedup and
  /// branch listing.
  nonisolated func bookmarkNames(for repoRoot: URL) async throws -> Set<String> {
    let output = try await runJJ(
      ["bookmark", "list", "--ignore-working-copy", "-T", "name() ++ \"\\n\""],
      cwd: repoRoot.standardizedFileURL
    )
    var names: Set<String> = []
    for rawLine in output.split(whereSeparator: \.isNewline) {
      let name = String(rawLine).trimmingCharacters(in: .whitespaces)
      if !name.isEmpty { names.insert(name.lowercased()) }
    }
    return names
  }

  /// Renames a bookmark (`jj bookmark rename`) — the jj counterpart to
  /// `git branch -m`.
  nonisolated func renameBookmark(from oldName: String, to newName: String, repoRoot: URL) async throws {
    _ = try await runJJ(["bookmark", "rename", oldName, newName], cwd: repoRoot.standardizedFileURL)
  }

  /// Pushes a bookmark to its remote for pull-request prep
  /// (`jj git push --bookmark <name>`). jj creates a not-yet-remote bookmark by
  /// default and applies force-with-lease-style safety checks on updates.
  nonisolated func pushBookmark(named name: String, remote: String?, repoRoot: URL) async throws {
    // jj 0.42 has no `--allow-new` flag (it rejects it, suggesting `--all`) and
    // creates a not-yet-remote bookmark by default, so we must NOT pass it.
    var arguments = ["git", "push", "--bookmark", name]
    if let remote, !remote.trimmingCharacters(in: .whitespaces).isEmpty {
      arguments += ["--remote", remote]
    }
    _ = try await runJJ(arguments, cwd: repoRoot.standardizedFileURL)
  }

  /// Fetches from a remote (`jj git fetch [--remote <name>]`).
  nonisolated func fetch(remote: String, repoRoot: URL) async throws {
    var arguments = ["git", "fetch"]
    let trimmed = remote.trimmingCharacters(in: .whitespaces)
    if !trimmed.isEmpty { arguments += ["--remote", trimmed] }
    _ = try await runJJ(arguments, cwd: repoRoot.standardizedFileURL)
  }

  /// Remote names via `jj git remote list` (each line: `<name> <url>`).
  nonisolated func remoteNames(for repoRoot: URL) async throws -> [String] {
    let output = try await runJJ(["git", "remote", "list"], cwd: repoRoot)
    return
      output
      .split(whereSeparator: \.isNewline)
      .compactMap { $0.split(separator: " ", maxSplits: 1).first.map(String.init) }
      .filter { !$0.isEmpty }
  }

  /// Runs `jj` via a login shell so the user's PATH (mise / brew / cargo
  /// installs) is honored, matching how `GitClient` reaches the bundled `wt`.
  nonisolated private func runJJ(_ arguments: [String], cwd: URL) async throws -> String {
    let env = URL(fileURLWithPath: "/usr/bin/env")
    return try await shell.runLogin(env, ["jj"] + arguments, cwd).stdout
  }

}
