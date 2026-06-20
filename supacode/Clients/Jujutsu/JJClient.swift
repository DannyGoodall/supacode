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
      guard let workspaceURL = await workspaceRootURL(named: name, repoRoot: repositoryRootURL) else {
        continue
      }
      guard fileManager.fileExists(atPath: workspaceURL.path(percentEncoded: false)) else {
        continue
      }
      // Display the bookmark at the workspace's working-copy commit when one
      // exists; otherwise fall back to the workspace name. An anonymous
      // workspace (no bookmark) is treated as not attached, mirroring a
      // detached-HEAD git worktree.
      let bookmark = await bookmarkAtWorkspace(named: name, repoRoot: repositoryRootURL)
      let isAttached = !bookmark.isEmpty
      let detail = WorktreeTextFormatting.relativePath(from: repositoryRootURL, to: workspaceURL)
      let id = workspaceURL.path(percentEncoded: false)
      let resourceValues = try? workspaceURL.resourceValues(forKeys: [
        .creationDateKey, .contentModificationDateKey,
      ])
      let createdAt = resourceValues?.creationDate ?? resourceValues?.contentModificationDate
      worktrees.append(
        Worktree(
          id: id,
          name: isAttached ? bookmark : name,
          detail: detail,
          workingDirectory: workspaceURL,
          repositoryRootURL: repositoryRootURL,
          createdAt: createdAt,
          isMissing: false,
          isAttached: isAttached
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

  /// Bookmark name at the working-copy commit of workspace `name`, resolved
  /// from the primary via the `<name>@` revset. Empty when the workspace is
  /// anonymous; jj errors are swallowed to empty.
  nonisolated private func bookmarkAtWorkspace(named name: String, repoRoot: URL) async -> String {
    let output = try? await runJJ(
      ["log", "--ignore-working-copy", "--no-graph", "-r", "\(name)@", "-T", Self.bookmarkTemplate],
      cwd: repoRoot
    )
    return Self.firstBookmark(from: output)
  }

  /// Bookmark at `@` for the workspace rooted at `workspaceURL` (the jj
  /// counterpart to `GitClient.branchName`). nil when there is no bookmark or
  /// jj fails.
  nonisolated func branchName(forWorkspaceAt workspaceURL: URL) async -> String? {
    let url = workspaceURL.standardizedFileURL
    let output = try? await runJJ(
      ["log", "--ignore-working-copy", "--no-graph", "-r", "@", "-T", Self.bookmarkTemplate],
      cwd: url
    )
    let bookmark = Self.firstBookmark(from: output)
    if !bookmark.isEmpty { return bookmark }
    // Anonymous `@` (no bookmark) — fall back to the workspace name, matching
    // the listing's "bookmark else workspace name" rule, so the watcher CLEARS
    // a stale bookmark label (e.g. after `jj new` moves `@` off a bookmark)
    // instead of leaving it stuck. `jj` resolves the repo from any workspace
    // cwd, so we can enumerate using the workspace dir itself.
    return try? await workspaceName(forPath: url, repoRoot: url)
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

  nonisolated private static let bookmarkTemplate =
    "local_bookmarks.map(|b| b.name()).join(\",\") ++ \"\\n\""

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
      id: canonicalURL.path(percentEncoded: false),
      name: name,
      detail: detail,
      workingDirectory: canonicalURL,
      repositoryRootURL: repositoryRootURL,
      createdAt: createdAt,
      isMissing: false,
      isAttached: true
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
  /// (`jj git push --bookmark <name> --allow-new`). `--allow-new` lets the
  /// first push of a not-yet-remote bookmark create the remote branch; jj's
  /// own force-with-lease-style safety checks still apply.
  nonisolated func pushBookmark(named name: String, remote: String?, repoRoot: URL) async throws {
    var arguments = ["git", "push", "--bookmark", name, "--allow-new"]
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
