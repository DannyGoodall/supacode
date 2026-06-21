import Testing

@testable import supacode

struct WorktreeVocabularyTests {
  /// The git vocabulary MUST reproduce the pre-existing hardcoded strings
  /// verbatim, so plain-git and folder rows are visually unchanged.
  @Test func gitVocabularyReproducesExistingStrings() {
    let vocab = WorktreeVocabulary.git
    #expect(vocab.renameBranch == "Rename Branch…")
    #expect(vocab.copyAsBranchName == "Copy as Branch Name")
    #expect(vocab.archive(plural: false) == "Archive Worktree…")
    #expect(vocab.archive(plural: true) == "Archive Worktrees…")
    #expect(vocab.delete(plural: false) == "Delete Worktree…")
    #expect(vocab.delete(plural: true) == "Delete Worktrees…")
    #expect(vocab.newWorktree == "New Worktree")
    #expect(vocab.archivedWorktrees == "Archived Worktrees")
    #expect(vocab.viewArchivedWorktrees == "View Archived Worktrees")
    #expect(vocab.refreshWorktrees == "Refresh Worktrees")
    #expect(vocab.branchNameField == "Branch name")
    #expect(vocab.baseRefLabel == "Base ref")
    #expect(vocab.renameTitle == "Rename Branch")
  }

  @Test func jujutsuVocabularyUsesWorkspaceAndBookmark() {
    let vocab = WorktreeVocabulary.jujutsu
    #expect(vocab.workspaceNoun == "Workspace")
    #expect(vocab.bookmarkNoun == "Bookmark")
    #expect(vocab.renameBranch == "Rename Bookmark…")
    #expect(vocab.copyAsBranchName == "Copy as Bookmark Name")
    #expect(vocab.archive(plural: false) == "Archive Workspace…")
    #expect(vocab.archive(plural: true) == "Archive Workspaces…")
    #expect(vocab.delete(plural: false) == "Delete Workspace…")
    #expect(vocab.delete(plural: true) == "Delete Workspaces…")
    #expect(vocab.newWorktree == "New Workspace")
    #expect(vocab.archivedWorktrees == "Archived Workspaces")
    #expect(vocab.viewArchivedWorktrees == "View Archived Workspaces")
    #expect(vocab.refreshWorktrees == "Refresh Workspaces")
    #expect(vocab.branchNameField == "Bookmark name")
    #expect(vocab.baseRefLabel == "Base revision")
    #expect(vocab.renameTitle == "Rename Bookmark")
  }
}
