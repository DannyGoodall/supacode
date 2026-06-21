import ComposableArchitecture
import Foundation
import SupacodeSettingsShared

struct GitClientDependency: Sendable {
  var repoRoot: @Sendable (URL) async throws -> URL
  var isGitRepository: @Sendable (URL) async -> Bool
  /// Whether the root is a git repository with a colocated Jujutsu repo
  /// (`.jj` peer of `.git`). Pure detection — the loader only promotes a
  /// root to `.gitColocatedJJ` when the experimental setting is on.
  /// Routed through the dependency (like `isGitRepository`) so tests can
  /// override it without touching the filesystem.
  var isColocatedJJRepository: @Sendable (URL) async -> Bool
  /// Whether a root URL still points at a readable directory on
  /// disk. Separate from `isGitRepository` because a folder-kind
  /// root can exist without being a git repository, and we need
  /// to distinguish "directory is gone" (surface a load failure)
  /// from "directory exists but isn't git" (classify as folder).
  /// Defaults to `true` in `testValue` so fixtures with fake
  /// `/tmp/...` paths keep working; tests that exercise the
  /// missing-directory path override explicitly.
  var rootDirectoryExists: @Sendable (URL) async -> Bool
  var worktrees: @Sendable (URL) async throws -> [Worktree]
  var reconcileSupacodeLocks: @Sendable (URL) async -> Void
  var localBranchNames: @Sendable (URL) async throws -> Set<String>
  var renameBranch: @Sendable (_ oldName: String, _ newName: String, _ repoRoot: URL) async throws -> Void
  var isValidBranchName: @Sendable (String, URL) async -> Bool
  var branchInventory: @Sendable (URL, [String]) async throws -> GitBranchInventory
  var defaultRemoteBranchRef: @Sendable (URL) async throws -> String?
  var automaticWorktreeBaseRef: @Sendable (URL) async -> String?
  var ignoredFileCount: @Sendable (URL) async throws -> Int
  var untrackedFileCount: @Sendable (URL) async throws -> Int
  var createWorktree:
    @Sendable (
      _ name: String,
      _ repoRoot: URL,
      _ baseDirectory: URL,
      _ copyIgnored: Bool,
      _ copyUntracked: Bool,
      _ baseRef: String
    ) async throws
      -> Worktree
  var createWorktreeStream:
    @Sendable (
      _ name: String,
      _ repoRoot: URL,
      _ baseDirectory: URL,
      _ copyIgnored: Bool,
      _ copyUntracked: Bool,
      _ baseRef: String,
      _ directoryOverride: URL?
    ) -> AsyncThrowingStream<GitWorktreeCreateEvent, Error>
  var removeWorktree: @Sendable (_ worktree: Worktree, _ deleteBranch: Bool) async throws -> URL
  var isBareRepository: @Sendable (_ repoRoot: URL) async throws -> Bool
  var branchName: @Sendable (URL) async -> String?
  /// jj change id of `@` for the working copy (prefix + rest), `nil` for git.
  var jjChangeId: @Sendable (_ worktreeURL: URL) async -> ChangeIdDisplay?
  var lineChanges: @Sendable (URL) async -> (added: Int, removed: Int)?
  var remoteNames: @Sendable (_ repoRoot: URL) async throws -> [String]
  var fetchRemote: @Sendable (_ remote: String, _ repoRoot: URL) async throws -> Void
  /// Pushes a worktree's branch/bookmark to its remote for PR prep. Routed:
  /// jj → `jj git push --bookmark`; git → `git push -u origin`.
  var pushBranch: @Sendable (_ name: String, _ repoRoot: URL) async throws -> Void
  var remoteInfo: @Sendable (_ repositoryRoot: URL) async -> GithubRemoteInfo?
}

extension GitClientDependency: DependencyKey {
  static let liveValue = GitClientDependency(
    repoRoot: { try await GitClient().repoRoot(for: $0) },
    isGitRepository: { Repository.isGitRepository(at: $0) },
    isColocatedJJRepository: { Repository.isColocatedJJRepository(at: $0) },
    rootDirectoryExists: { url in
      var isDirectory: ObjCBool = false
      let exists = FileManager.default.fileExists(
        atPath: url.standardizedFileURL.path(percentEncoded: false),
        isDirectory: &isDirectory
      )
      return exists && isDirectory.boolValue
    },
    worktrees: { root in
      // Route co-located repos that prefer jj to the Jujutsu backend; on any
      // jj failure (CLI missing/errored) degrade gracefully to Git so a
      // colocated repo never fails to load.
      if GitClientDependency.shouldUseJujutsuBackend(for: root) {
        do {
          return try await JJClient().workspaces(for: root)
        } catch {
          return try await GitClient().worktrees(for: root)
        }
      }
      return try await GitClient().worktrees(for: root)
    },
    reconcileSupacodeLocks: { await GitClient().reconcileSupacodeLocks(for: $0) },
    localBranchNames: { root in
      if GitClientDependency.shouldUseJujutsuBackend(for: root) {
        return try await JJClient().bookmarkNames(for: root)
      }
      return try await GitClient().localBranchNames(for: root)
    },
    renameBranch: { oldName, newName, repoRoot in
      if GitClientDependency.shouldUseJujutsuBackend(for: repoRoot) {
        return try await JJClient().renameBookmark(from: oldName, to: newName, repoRoot: repoRoot)
      }
      try await GitClient().renameBranch(from: oldName, to: newName, for: repoRoot)
    },
    isValidBranchName: { branchName, repoRoot in
      await GitClient().isValidBranchName(branchName, for: repoRoot)
    },
    branchInventory: { try await GitClient().branchInventory(for: $0, remoteNames: $1) },
    defaultRemoteBranchRef: { try await GitClient().defaultRemoteBranchRef(for: $0) },
    automaticWorktreeBaseRef: { await GitClient().automaticWorktreeBaseRef(for: $0) },
    ignoredFileCount: { try await GitClient().ignoredFileCount(for: $0) },
    untrackedFileCount: { try await GitClient().untrackedFileCount(for: $0) },
    createWorktree: { name, repoRoot, baseDirectory, copyIgnored, copyUntracked, baseRef in
      if GitClientDependency.shouldUseJujutsuBackend(for: repoRoot) {
        // jj auto-snapshots; the copy-ignored/untracked flags don't apply.
        return try await JJClient().createWorkspace(
          named: name,
          in: repoRoot,
          baseDirectory: baseDirectory,
          baseRef: baseRef,
          directoryOverride: nil
        )
      }
      return try await GitClient().createWorktree(
        named: name,
        in: repoRoot,
        baseDirectory: baseDirectory,
        copyFiles: (ignored: copyIgnored, untracked: copyUntracked),
        baseRef: baseRef
      )
    },
    createWorktreeStream: { name, repoRoot, baseDirectory, copyIgnored, copyUntracked, baseRef, directoryOverride in
      if GitClientDependency.shouldUseJujutsuBackend(for: repoRoot) {
        return JJClient().createWorkspaceStream(
          named: name,
          in: repoRoot,
          baseDirectory: baseDirectory,
          baseRef: baseRef,
          directoryOverride: directoryOverride
        )
      }
      return GitClient().createWorktreeStream(
        named: name,
        in: repoRoot,
        baseDirectory: baseDirectory,
        copyFiles: (ignored: copyIgnored, untracked: copyUntracked),
        baseRef: baseRef,
        directoryOverride: directoryOverride
      )
    },
    removeWorktree: { worktree, deleteBranch in
      if GitClientDependency.shouldUseJujutsuBackend(for: worktree.repositoryRootURL) {
        return try await JJClient().removeWorkspace(worktree, deleteBookmark: deleteBranch)
      }
      return try await GitClient().removeWorktree(worktree, deleteBranch: deleteBranch)
    },
    isBareRepository: { repoRoot in
      try await GitClient().isBareRepository(for: repoRoot)
    },
    branchName: { url in
      if GitClientDependency.shouldUseJujutsuBackendForWorkingCopy(at: url) {
        return await JJClient().branchName(forWorkspaceAt: url)
      }
      return await GitClient().branchName(for: url)
    },
    jjChangeId: { url in
      guard GitClientDependency.shouldUseJujutsuBackendForWorkingCopy(at: url) else { return nil }
      return await JJClient().changeId(forWorkspaceAt: url)
    },
    lineChanges: { url in
      if GitClientDependency.shouldUseJujutsuBackendForWorkingCopy(at: url) {
        return await JJClient().lineChanges(at: url)
      }
      return await GitClient().lineChanges(at: url)
    },
    remoteNames: { root in
      if GitClientDependency.shouldUseJujutsuBackend(for: root) {
        return try await JJClient().remoteNames(for: root)
      }
      return try await GitClient().remoteNames(for: root)
    },
    fetchRemote: { remote, repoRoot in
      if GitClientDependency.shouldUseJujutsuBackend(for: repoRoot) {
        return try await JJClient().fetch(remote: remote, repoRoot: repoRoot)
      }
      try await GitClient().fetchRemote(remote, for: repoRoot)
    },
    pushBranch: { name, repoRoot in
      if GitClientDependency.shouldUseJujutsuBackend(for: repoRoot) {
        return try await JJClient().pushBookmark(named: name, remote: nil, repoRoot: repoRoot)
      }
      try await GitClient().pushBranch(name, for: repoRoot)
    },
    remoteInfo: { repositoryRoot in
      await GitClient().remoteInfo(for: repositoryRoot)
    }
  )
  // Tests default to "git repository" classification so existing
  // fixtures that mock `gitClient.worktrees` without creating real
  // `.git` directories on disk keep exercising the git code path.
  // Folder-kind tests override this closure explicitly.
  static var testValue: GitClientDependency {
    var value = liveValue
    value.isGitRepository = { _ in true }
    // Default to "not colocated" so existing fixtures with fake
    // `/tmp/...` paths keep classifying as plain `.git`. jj-specific
    // tests override this closure explicitly.
    value.isColocatedJJRepository = { _ in false }
    value.rootDirectoryExists = { _ in true }
    value.reconcileSupacodeLocks = { _ in }
    return value
  }
}

extension GitClientDependency {
  /// Whether VCS operations for `root` should be routed to the Jujutsu
  /// backend. True only when the experimental gate is on, the root is a
  /// colocated git+jj repository, and the per-repo `preferJJ` is not an
  /// explicit Git override (`preferJJ ?? true`). Pure/synchronous reads so it
  /// can gate the dependency's live closures cheaply.
  nonisolated static func shouldUseJujutsuBackend(for root: URL) -> Bool {
    @Shared(.experimentalJJIntegration) var experimentalJJIntegration
    guard experimentalJJIntegration else { return false }
    guard Repository.isColocatedJJRepository(at: root) else { return false }
    @Shared(.repositorySettings(root)) var repositorySettings
    return Repository.usesJujutsuBackend(vcs: .gitColocatedJJ, preferJJ: repositorySettings.preferJJ)
  }

  /// Working-copy-level variant for ops keyed by a worktree/workspace path
  /// (e.g. `branchName`, `lineChanges`) rather than a repo root. A jj working
  /// copy has a `.jj` directory: a colocated *primary* also has `.git` (so we
  /// honor that repo's `preferJJ`), while a secondary jj workspace is jj-only.
  nonisolated static func shouldUseJujutsuBackendForWorkingCopy(at url: URL) -> Bool {
    @Shared(.experimentalJJIntegration) var experimentalJJIntegration
    guard experimentalJJIntegration else { return false }
    let base = url.standardizedFileURL
    // Colocated primary (git + `.jj`) — single source of the colocation
    // definition. Honor the per-repo preferJJ override.
    if Repository.isColocatedJJRepository(at: base) {
      @Shared(.repositorySettings(base)) var repositorySettings
      return Repository.usesJujutsuBackend(vcs: .gitColocatedJJ, preferJJ: repositorySettings.preferJJ)
    }
    // Secondary jj-only workspace (a `.jj` directory with no sibling `.git`):
    // gate on + `.jj` present → jj.
    let jjPath = base.appending(path: ".jj", directoryHint: .isDirectory).path(percentEncoded: false)
    var isDirectory: ObjCBool = false
    return FileManager.default.fileExists(atPath: jjPath, isDirectory: &isDirectory) && isDirectory.boolValue
  }
}

extension DependencyValues {
  var gitClient: GitClientDependency {
    get { self[GitClientDependency.self] }
    set { self[GitClientDependency.self] = newValue }
  }
}
