import ComposableArchitecture
import Foundation
import IdentifiedCollections
import Sharing
import Testing

@testable import SupacodeSettingsShared
@testable import supacode

/// Foundation coverage for the co-located Jujutsu (jj) integration:
///   * pure filesystem detection (`isColocatedJJRepository(at:)`),
///   * the `RepositoryVCS` flavor + backward-compatible `isGitRepository`
///     contract (git / jj+git / none), and
///   * the experimental-gate behavior in the repository loader.
///
/// The whole feature is opt-in: with the gate off the loader must behave
/// byte-for-byte like the historical git/folder classifier, so a
/// colocated repo classifies as plain `.git`.
@MainActor
struct RepositoryJJColocationTests {

  // MARK: - Pure detection (real temp directories)

  /// Creates a unique temp directory and returns it; caller removes it.
  private func makeTempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appending(path: "supacode-jjtest-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func makeChildDirectory(_ name: String, in parent: URL) throws {
    try FileManager.default.createDirectory(
      at: parent.appending(path: name, directoryHint: .isDirectory),
      withIntermediateDirectories: true
    )
  }

  @Test func plainGitRepoIsNotColocated() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try makeChildDirectory(".git", in: root)

    #expect(Repository.isGitRepository(at: root))
    #expect(!Repository.isColocatedJJRepository(at: root))
  }

  @Test func gitRepoWithJJDirectoryIsColocated() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try makeChildDirectory(".git", in: root)
    try makeChildDirectory(".jj", in: root)

    #expect(Repository.isGitRepository(at: root))
    #expect(Repository.isColocatedJJRepository(at: root))
  }

  @Test func jjWithoutGitIsNotColocated() throws {
    // A non-colocated jj repo (`.jj` present, no sibling `.git`) keeps
    // its git store under `.jj/repo/store` — Supacode's git stack can't
    // drive it, so it must NOT be reported as colocated (and isn't a
    // git repo either).
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try makeChildDirectory(".jj", in: root)

    #expect(!Repository.isGitRepository(at: root))
    #expect(!Repository.isColocatedJJRepository(at: root))
  }

  @Test func jjAsRegularFileIsNotColocated() throws {
    // `.jj` must be a directory; a stray regular file named `.jj` next to
    // `.git` is not colocation.
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try makeChildDirectory(".git", in: root)
    try Data("not a dir".utf8).write(
      to: root.appending(path: ".jj", directoryHint: .notDirectory)
    )

    #expect(Repository.isGitRepository(at: root))
    #expect(!Repository.isColocatedJJRepository(at: root))
  }

  @Test func plainFolderIsNeitherGitNorColocated() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    #expect(!Repository.isGitRepository(at: root))
    #expect(!Repository.isColocatedJJRepository(at: root))
  }

  // MARK: - Model: flavor <-> isGitRepository contract

  @Test func backwardCompatibleInitMapsBoolToGitOrFolder() {
    let git = Repository(
      id: "/tmp/a", rootURL: URL(fileURLWithPath: "/tmp/a"), name: "a",
      worktrees: [], isGitRepository: true
    )
    #expect(git.vcs == .git)
    #expect(git.isGitRepository)
    #expect(!git.isColocatedJJ)

    let folder = Repository(
      id: "/tmp/b", rootURL: URL(fileURLWithPath: "/tmp/b"), name: "b",
      worktrees: [], isGitRepository: false
    )
    #expect(folder.vcs == .folder)
    #expect(!folder.isGitRepository)
    #expect(!folder.isColocatedJJ)
  }

  @Test func defaultInitIsGitFlavor() {
    let repo = Repository(
      id: "/tmp/a", rootURL: URL(fileURLWithPath: "/tmp/a"), name: "a", worktrees: []
    )
    #expect(repo.vcs == .git)
    #expect(repo.isGitRepository)
  }

  /// The load-bearing backward-compat guarantee: a
  /// colocated repo still answers `isGitRepository == true`, so every
  /// existing git/none consumer keeps treating it as a git repo.
  @Test func colocatedFlavorStillReportsAsGitRepository() {
    let repo = Repository(
      id: "/tmp/a", rootURL: URL(fileURLWithPath: "/tmp/a"), name: "a",
      worktrees: [], vcs: .gitColocatedJJ
    )
    #expect(repo.vcs == .gitColocatedJJ)
    #expect(repo.isGitRepository)
    #expect(repo.isColocatedJJ)
  }

  // MARK: - Backend resolver (vcs × preferJJ)

  @Test func colocatedWithUnsetPreferenceUsesJujutsu() {
    #expect(Repository.usesJujutsuBackend(vcs: .gitColocatedJJ, preferJJ: nil))
    #expect(Repository.usesJujutsuBackend(vcs: .gitColocatedJJ, preferJJ: true))
  }

  @Test func colocatedWithGitOverrideUsesGit() {
    #expect(!Repository.usesJujutsuBackend(vcs: .gitColocatedJJ, preferJJ: false))
  }

  @Test func plainGitIsNeverJujutsuEvenWhenPreferred() {
    #expect(!Repository.usesJujutsuBackend(vcs: .git, preferJJ: true))
    #expect(!Repository.usesJujutsuBackend(vcs: .git, preferJJ: nil))
  }

  @Test func folderIsNeverJujutsu() {
    #expect(!Repository.usesJujutsuBackend(vcs: .folder, preferJJ: true))
    #expect(!Repository.usesJujutsuBackend(vcs: .folder, preferJJ: nil))
  }

  /// Regression: in-place worktree-set rebuilds MUST preserve `vcs`. Renaming
  /// (and add/remove worktree) used to reconstruct via `init(isGitRepository:)`
  /// — whose default reclassified a co-located jj repo back to `.git`, which
  /// reverted the UI to git vocabulary after any such mutation.
  @Test func replacingWorktreesPreservesVCSFlavor() {
    let root = URL(fileURLWithPath: "/tmp/jj-replace")
    let jjRepo = Repository(id: "jj", rootURL: root, name: "jj", worktrees: [], vcs: .gitColocatedJJ)
    #expect(jjRepo.replacingWorktrees([]).vcs == .gitColocatedJJ)
    #expect(jjRepo.replacingWorktrees([]).isColocatedJJ)

    let folder = Repository(id: "f", rootURL: root, name: "f", worktrees: [], vcs: .folder)
    #expect(folder.replacingWorktrees([]).vcs == .folder)
  }

  // MARK: - Loader gate (git / jj+git / none)

  private func loaderState(root: URL) -> RepositoriesFeature.State {
    let worktree = Worktree(
      id: root.appending(path: "main").path(percentEncoded: false),
      name: "main",
      detail: "",
      workingDirectory: root,
      repositoryRootURL: root
    )
    let repository = Repository(
      id: root.path(percentEncoded: false),
      rootURL: root,
      name: "repo",
      worktrees: IdentifiedArray(uniqueElements: [worktree])
    )
    var state = RepositoriesFeature.State()
    state.repositories = IdentifiedArray(uniqueElements: [repository])
    state.repositoryRoots = [root]
    return state
  }

  @Test func loaderClassifiesColocatedRepoAsPlainGitWhenGateOff() async {
    await withDependencies {
      $0.defaultAppStorage = .inMemory
    } operation: {
      let root = URL(fileURLWithPath: "/tmp/supacode-jj-gateoff")
      let worktree = Worktree(
        id: "/tmp/supacode-jj-gateoff/main", name: "main", detail: "",
        workingDirectory: root, repositoryRootURL: root
      )
      let store = TestStore(initialState: loaderState(root: root)) {
        RepositoriesFeature()
      } withDependencies: {
        // Even though the root *is* colocated on disk, the gate is off
        // (default), so the loader must downgrade it to `.git`.
        $0.gitClient.worktrees = { _ in [worktree] }
        $0.gitClient.isColocatedJJRepository = { _ in true }
      }
      store.exhaustivity = .off

      await store.send(.refreshWorktrees)
      await store.receive(\.reloadRepositories)
      await store.receive(\.repositoriesLoaded)

      let loaded = store.state.repositories[id: root.path(percentEncoded: false)]
      #expect(loaded?.vcs == .git)
      #expect(loaded?.isGitRepository == true)
    }
  }

  @Test func loaderClassifiesColocatedRepoAsGitColocatedJJWhenGateOn() async {
    await withDependencies {
      $0.defaultAppStorage = .inMemory
    } operation: {
      @Shared(.experimentalJJIntegration) var jjEnabled
      $jjEnabled.withLock { $0 = true }

      let root = URL(fileURLWithPath: "/tmp/supacode-jj-gateon")
      let worktree = Worktree(
        id: "/tmp/supacode-jj-gateon/main", name: "main", detail: "",
        workingDirectory: root, repositoryRootURL: root
      )
      let store = TestStore(initialState: loaderState(root: root)) {
        RepositoriesFeature()
      } withDependencies: {
        $0.gitClient.worktrees = { _ in [worktree] }
        $0.gitClient.isColocatedJJRepository = { _ in true }
      }
      store.exhaustivity = .off

      await store.send(.refreshWorktrees)
      await store.receive(\.reloadRepositories)
      await store.receive(\.repositoriesLoaded)

      let loaded = store.state.repositories[id: root.path(percentEncoded: false)]
      #expect(loaded?.vcs == .gitColocatedJJ)
      #expect(loaded?.isGitRepository == true)
      #expect(loaded?.isColocatedJJ == true)
    }
  }

  @Test func loaderClassifiesNonColocatedGitRepoAsGitWhenGateOn() async {
    await withDependencies {
      $0.defaultAppStorage = .inMemory
    } operation: {
      @Shared(.experimentalJJIntegration) var jjEnabled
      $jjEnabled.withLock { $0 = true }

      let root = URL(fileURLWithPath: "/tmp/supacode-jj-plaingit")
      let worktree = Worktree(
        id: "/tmp/supacode-jj-plaingit/main", name: "main", detail: "",
        workingDirectory: root, repositoryRootURL: root
      )
      let store = TestStore(initialState: loaderState(root: root)) {
        RepositoriesFeature()
      } withDependencies: {
        $0.gitClient.worktrees = { _ in [worktree] }
        $0.gitClient.isColocatedJJRepository = { _ in false }
      }
      store.exhaustivity = .off

      await store.send(.refreshWorktrees)
      await store.receive(\.reloadRepositories)
      await store.receive(\.repositoriesLoaded)

      let loaded = store.state.repositories[id: root.path(percentEncoded: false)]
      #expect(loaded?.vcs == .git)
      #expect(loaded?.isColocatedJJ == false)
    }
  }
}
