import Foundation

/// jj counterpart to `GitWorktreeHeadResolver`: resolves the filesystem path a
/// `WorktreeInfoWatcherManager` watches for state changes in a co-located jj
/// repository.
///
/// We watch the repository's operation-log head directory
/// (`.jj/repo/op_heads/heads`). Its single entry is replaced on every real jj
/// operation — commit, new, edit, bookmark, working-copy snapshot — but NOT by
/// our `--ignore-working-copy` reads, which create no operation. That is the
/// key property: it can't feed back into itself the way watching
/// `.jj/working_copy` did (that directory churned and each event spawned
/// login-shell `jj` reads, saturating the main actor). The op-log head is
/// shared across a repo's workspaces, which all carry the same
/// `repositoryRootURL`.
enum JJWorktreeStateResolver {
  /// The operation-log head directory for the (co-located) repository:
  /// `<repoRoot>/.jj/repo/op_heads/heads` (see the type doc for why this is the
  /// watch target). Returns `nil` when the directory is absent.
  static func opHeadsURL(forRepositoryRoot repoRoot: URL, fileManager: FileManager) -> URL? {
    let heads =
      repoRoot
      .appending(path: ".jj").appending(path: "repo")
      .appending(path: "op_heads").appending(path: "heads")
    var isDirectory = ObjCBool(false)
    guard
      fileManager.fileExists(atPath: heads.path(percentEncoded: false), isDirectory: &isDirectory),
      isDirectory.boolValue
    else {
      return nil
    }
    return heads
  }
}
