import Foundation

/// A jj change id split into its shortest-unique-prefix and the remainder, so
/// the UI can highlight the identifying prefix (bold) and dim the rest —
/// mirroring jj's own log output. `nil` for git worktrees.
struct ChangeIdDisplay: Hashable, Sendable {
  let prefix: String
  let rest: String
}

struct Worktree: Identifiable, Hashable, Sendable {
  let id: String
  let name: String
  let detail: String
  let workingDirectory: URL
  let repositoryRootURL: URL
  let createdAt: Date?
  /// The admin entry exists but the working dir is gone on disk.
  /// Drives the orphan UI (warning icon, gated open actions).
  let isMissing: Bool
  /// `false` for detached-HEAD git worktrees and folder synthetics. Gates
  /// branch-targeted actions so they don't reach a `git branch -m` call
  /// that has no real ref to operate on.
  let isAttached: Bool
  /// jj change id of `@` (prefix + rest), for the jj-native row label. `nil`
  /// for git. Sourced at enumeration; refreshed live by the op-log watcher.
  let jjChangeId: ChangeIdDisplay?
  /// The jj workspace name (e.g. `ws2`), captured at enumeration. `nil` for git.
  /// Lets the watcher fall back to it for an anonymous `@` WITHOUT re-running
  /// `jj workspace list` + per-workspace `root --name` on every op.
  let jjWorkspaceName: String?

  nonisolated init(
    id: String,
    name: String,
    detail: String,
    workingDirectory: URL,
    repositoryRootURL: URL,
    createdAt: Date? = nil,
    isMissing: Bool = false,
    isAttached: Bool = true,
    jjChangeId: ChangeIdDisplay? = nil,
    jjWorkspaceName: String? = nil
  ) {
    self.id = id
    self.name = name
    self.detail = detail
    self.workingDirectory = workingDirectory
    self.repositoryRootURL = repositoryRootURL
    self.createdAt = createdAt
    self.isMissing = isMissing
    self.isAttached = isAttached
    self.jjChangeId = jjChangeId
    self.jjWorkspaceName = jjWorkspaceName
  }
}

extension Worktree {
  /// Base environment variables for Supacode scripts (supplemented per-surface).
  var scriptEnvironment: [String: String] {
    [
      "SUPACODE_WORKTREE_PATH": workingDirectory.path(percentEncoded: false),
      "SUPACODE_ROOT_PATH": repositoryRootURL.path(percentEncoded: false),
    ]
  }

}
