import Foundation

/// Flavor-aware vocabulary for the worktree-row UI. For a co-located Jujutsu
/// repository using the jj backend we present jj-native terms (Workspace /
/// Bookmark); otherwise the historical Git terms. `isJJ == false` reproduces
/// the existing Git strings verbatim, so plain-Git and folder rows are
/// visually unchanged. One source of truth for every label, keyed off the
/// row's backend (see `RepositoriesFeature.State.worktreeVocabulary(forRepository:)`).
struct WorktreeVocabulary: Equatable, Sendable {
  let isJJ: Bool

  static let git = WorktreeVocabulary(isJJ: false)
  static let jujutsu = WorktreeVocabulary(isJJ: true)

  var workspaceNoun: String { isJJ ? "Workspace" : "Worktree" }
  var bookmarkNoun: String { isJJ ? "Bookmark" : "Branch" }

  // MARK: Context-menu / row actions
  var renameBranch: String { "Rename \(bookmarkNoun)…" }
  var copyAsBranchName: String { "Copy as \(bookmarkNoun) Name" }
  func archive(plural: Bool) -> String { "Archive \(workspaceNoun)\(plural ? "s" : "")…" }
  func delete(plural: Bool) -> String { "Delete \(workspaceNoun)\(plural ? "s" : "")…" }

  // MARK: New / toolbar / command palette
  var newWorktree: String { "New \(workspaceNoun)" }
  var newWorktreeEllipsis: String { "New \(workspaceNoun)…" }
  var archivedWorktrees: String { "Archived \(workspaceNoun)s" }
  var viewArchivedWorktrees: String { "View Archived \(workspaceNoun)s" }
  var refreshWorktrees: String { "Refresh \(workspaceNoun)s" }

  // MARK: Prompts
  var branchNameField: String { "\(bookmarkNoun) name" }
  var baseRefLabel: String { isJJ ? "Base revision" : "Base ref" }
  var renameTitle: String { "Rename \(bookmarkNoun)" }
}
