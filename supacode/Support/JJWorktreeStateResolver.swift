import Foundation

/// jj counterpart to `GitWorktreeHeadResolver`: resolves the filesystem path a
/// `WorktreeInfoWatcherManager` watches for working-copy state changes in a
/// co-located jj repository.
///
/// We watch the workspace-local `.jj/working_copy` directory (every jj
/// workspace has its own). jj rewrites its contents (`tree_state`, `checkout`)
/// via atomic temp-file + rename whenever the working copy is snapshotted or
/// `@` moves, which fires the directory's vnode (`NOTE_WRITE`). Watching the
/// directory rather than a single file is robust to jj's exact write pattern
/// and survives atomic replacement without needing a watcher restart.
///
/// Known limitation (documented; this is the design's highest-risk area): a
/// pure bookmark-only operation that doesn't touch the working copy may not
/// fire the watcher. Those paths are refreshed through the normal reducer flow
/// (Supacode's own bookmark actions reload), and any jj command that moves `@`
/// does rewrite `working_copy`.
enum JJWorktreeStateResolver {
  /// The operation-log head directory for the (co-located) repository:
  /// `<repoRoot>/.jj/repo/op_heads/heads`. Its single entry (named by the
  /// current operation id) is replaced on every real jj operation — commit,
  /// new, edit, bookmark, working-copy snapshot — but NOT by our
  /// `--ignore-working-copy` reads, which create no operation. Watching it
  /// therefore can't feed back into itself the way watching `.jj/working_copy`
  /// did (that directory churned and each event spawned login-shell `jj` reads,
  /// saturating the main actor). It is shared across a repo's workspaces, which
  /// all carry the same `repositoryRootURL`.
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

  static func workingCopyURL(for worktreeURL: URL, fileManager: FileManager) -> URL? {
    let workingCopyURL = worktreeURL.appending(path: ".jj").appending(path: "working_copy")
    var isDirectory = ObjCBool(false)
    guard
      fileManager.fileExists(
        atPath: workingCopyURL.path(percentEncoded: false),
        isDirectory: &isDirectory
      ),
      isDirectory.boolValue
    else {
      return nil
    }
    return workingCopyURL
  }
}
