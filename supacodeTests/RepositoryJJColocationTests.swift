import ComposableArchitecture
import Foundation
import IdentifiedCollections
import Sharing
import Testing

@testable import SupacodeSettingsShared
@testable import supacode

/// Foundation coverage for the co-located Jujutsu (jj) integration:
///   * pure filesystem detection (`isColocatedJJRepository(at:)`),
///   * the additive `isColocatedJJ` flag + backward-compatible `isGitRepository`
///     contract (git / jj+git / none), and
///   * the experimental-gate behavior in the repository loader.
///
/// The whole feature is opt-in: with the gate off the loader must behave
/// byte-for-byte like the historical git/folder classifier, so a
/// colocated repo classifies as plain `.git` (`isColocatedJJ == false`).
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

  // MARK: - Model: isColocatedJJ <-> isGitRepository contract

  @Test func backwardCompatibleInitMapsBoolToGitOrFolder() {
    let git = Repository(
      id: RepositoryID("/tmp/a"), rootURL: URL(fileURLWithPath: "/tmp/a"), name: "a",
      worktrees: [], isGitRepository: true
    )
    #expect(git.isGitRepository)
    #expect(!git.isColocatedJJ)

    let folder = Repository(
      id: RepositoryID("/tmp/b"), rootURL: URL(fileURLWithPath: "/tmp/b"), name: "b",
      worktrees: [], isGitRepository: false
    )
    #expect(!folder.isGitRepository)
    #expect(!folder.isColocatedJJ)
  }

  @Test func defaultInitIsGitFlavor() {
    let repo = Repository(
      id: RepositoryID("/tmp/a"), rootURL: URL(fileURLWithPath: "/tmp/a"), name: "a", worktrees: []
    )
    #expect(repo.isGitRepository)
    #expect(!repo.isColocatedJJ)
  }

  /// The load-bearing backward-compat guarantee: a colocated repo still answers
  /// `isGitRepository == true`, so every existing git/none consumer keeps
  /// treating it as a git repo while `isColocatedJJ` layers on top.
  @Test func colocatedFlavorStillReportsAsGitRepository() {
    let repo = Repository(
      id: RepositoryID("/tmp/a"), rootURL: URL(fileURLWithPath: "/tmp/a"), name: "a",
      worktrees: [], isGitRepository: true, isColocatedJJ: true
    )
    #expect(repo.isGitRepository)
    #expect(repo.isColocatedJJ)
  }

  // MARK: - Backend resolver (isColocatedJJ × preferJJ)

  @Test func colocatedWithUnsetPreferenceUsesJujutsu() {
    #expect(Repository.usesJujutsuBackend(isColocatedJJ: true, preferJJ: nil))
    #expect(Repository.usesJujutsuBackend(isColocatedJJ: true, preferJJ: true))
  }

  @Test func colocatedWithGitOverrideUsesGit() {
    #expect(!Repository.usesJujutsuBackend(isColocatedJJ: true, preferJJ: false))
  }

  @Test func plainGitIsNeverJujutsuEvenWhenPreferred() {
    #expect(!Repository.usesJujutsuBackend(isColocatedJJ: false, preferJJ: true))
    #expect(!Repository.usesJujutsuBackend(isColocatedJJ: false, preferJJ: nil))
  }

  // MARK: - Worktree-set rebuild preserves the jj flavor

  /// Regression: in-place worktree-set rebuilds MUST preserve `isColocatedJJ`.
  /// Renaming (and add/remove worktree) used to reconstruct via a fresh init
  /// whose default reclassified a co-located jj repo back to plain git, which
  /// reverted the UI to git vocabulary after any such mutation.
  @Test func withWorktreesPreservesJJFlavor() {
    let root = URL(fileURLWithPath: "/tmp/jj-replace")
    let jjRepo = Repository(
      id: RepositoryID("jj"), rootURL: root, name: "jj", worktrees: [], isColocatedJJ: true)
    #expect(jjRepo.withWorktrees([]).isColocatedJJ)

    let folder = Repository(
      id: RepositoryID("f"), rootURL: root, name: "f", worktrees: [], isGitRepository: false)
    #expect(!folder.withWorktrees([]).isGitRepository)
    #expect(!folder.withWorktrees([]).isColocatedJJ)
  }

  // MARK: - Loader gate (git / jj+git / none)

  private func loaderState(root: URL) -> RepositoriesFeature.State {
    let worktree = Worktree(
      location: .local(workingDirectory: root, repositoryRoot: root),
      kind: .git,
      name: "main",
      detail: ""
    )
    let repository = Repository(
      location: .local(root),
      kind: .git,
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
        location: .local(workingDirectory: root, repositoryRoot: root), kind: .git,
        name: "main", detail: ""
      )
      let store = TestStore(initialState: loaderState(root: root)) {
        RepositoriesFeature()
      } withDependencies: {
        // Even though the root *is* colocated on disk, the gate is off
        // (default), so the loader must leave `isColocatedJJ` false.
        $0.gitClient.worktrees = { _ in [worktree] }
        $0.gitClient.isColocatedJJRepository = { _ in true }
      }
      store.exhaustivity = .off

      await store.send(.refreshWorktrees)
      await store.receive(\.reloadRepositories)
      await store.receive(\.repositoriesLoaded)

      let loaded = store.state.repositories[id: RepositoryID(root.path(percentEncoded: false))]
      #expect(loaded?.isColocatedJJ == false)
      #expect(loaded?.isGitRepository == true)
    }
  }

  @Test func loaderClassifiesColocatedRepoAsColocatedJJWhenGateOn() async {
    await withDependencies {
      $0.defaultAppStorage = .inMemory
    } operation: {
      @Shared(.experimentalJJIntegration) var jjEnabled
      $jjEnabled.withLock { $0 = true }

      let root = URL(fileURLWithPath: "/tmp/supacode-jj-gateon")
      let worktree = Worktree(
        location: .local(workingDirectory: root, repositoryRoot: root), kind: .git,
        name: "main", detail: ""
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

      let loaded = store.state.repositories[id: RepositoryID(root.path(percentEncoded: false))]
      #expect(loaded?.isColocatedJJ == true)
      #expect(loaded?.isGitRepository == true)
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
        location: .local(workingDirectory: root, repositoryRoot: root), kind: .git,
        name: "main", detail: ""
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

      let loaded = store.state.repositories[id: RepositoryID(root.path(percentEncoded: false))]
      #expect(loaded?.isColocatedJJ == false)
    }
  }

  // MARK: - op-log watcher discovers externally-created workspaces

  /// A jj `.branchChanged` watcher event (fired when the op-log head advances,
  /// e.g. an agent runs `jj workspace add` in a terminal) must schedule a
  /// debounced full re-enumeration so the new workspace appears without an app
  /// restart. Regression guard for the "new workspaces only show up after
  /// quit + relaunch" bug.
  @Test func jjBranchChangedSchedulesDebouncedReloadToDiscoverNewWorkspaces() async {
    await withDependencies {
      $0.defaultAppStorage = .inMemory
    } operation: {
      @Shared(.experimentalJJIntegration) var jjEnabled
      $jjEnabled.withLock { $0 = true }

      let root = URL(fileURLWithPath: "/tmp/supacode-jj-reload")
      let worktree = Worktree(
        location: .local(workingDirectory: root, repositoryRoot: root), kind: .git,
        name: "main", detail: ""
      )
      let repository = Repository(
        location: .local(root),
        kind: .git,
        name: "repo",
        worktrees: IdentifiedArray(uniqueElements: [worktree]),
        isColocatedJJ: true
      )
      var state = RepositoriesFeature.State()
      state.repositories = IdentifiedArray(uniqueElements: [repository])
      state.repositoryRoots = [root]

      let clock = TestClock()
      let store = TestStore(initialState: state) {
        RepositoriesFeature()
      } withDependencies: {
        $0.continuousClock = clock
        $0.gitClient.branchName = { _ in "main" }
        $0.gitClient.jjChangeId = { _ in nil }
        $0.gitClient.worktrees = { _ in [worktree] }
        $0.gitClient.isColocatedJJRepository = { _ in true }
      }
      store.exhaustivity = .off

      await store.send(.worktreeInfoEvent(.branchChanged(worktreeID: worktree.id)))
      // Nothing reloads until the debounce elapses — a burst of jj ops collapses
      // into a single reload.
      await clock.advance(by: .seconds(2))
      await store.receive(\.reloadRepositories)
      await store.skipReceivedActions()
    }
  }

  /// The reload is jj-only: a plain-git worktree's `.branchChanged` must NOT
  /// schedule a re-enumeration (its HEAD watcher can't see unwatched new paths,
  /// and reloading on every git branch move would be wasteful).
  @Test func gitBranchChangedDoesNotScheduleReload() async {
    await withDependencies {
      $0.defaultAppStorage = .inMemory
    } operation: {
      let root = URL(fileURLWithPath: "/tmp/supacode-git-noreload")
      let worktree = Worktree(
        location: .local(workingDirectory: root, repositoryRoot: root), kind: .git,
        name: "main", detail: ""
      )
      let repository = Repository(
        location: .local(root), kind: .git, name: "repo",
        worktrees: IdentifiedArray(uniqueElements: [worktree])
      )
      var state = RepositoriesFeature.State()
      state.repositories = IdentifiedArray(uniqueElements: [repository])
      state.repositoryRoots = [root]
      state.reconcileSidebarForTesting()

      let clock = TestClock()
      let store = TestStore(initialState: state) {
        RepositoriesFeature()
      } withDependencies: {
        // Stubs match the current row state (name already "main", no change id),
        // so the per-row refresh handlers are no-ops on state — leaving the
        // exhaustive store to catch a stray `.reloadRepositories` if one fired.
        $0.continuousClock = clock
        $0.gitClient.branchName = { _ in "main" }
        $0.gitClient.jjChangeId = { _ in nil }
      }

      await store.send(.worktreeInfoEvent(.branchChanged(worktreeID: worktree.id)))
      await store.receive(\.worktreeBranchNameLoaded)
      await store.receive(\.worktreeChangeIdLoaded)
      // No reload is scheduled for git, so advancing past the debounce window
      // produces nothing; an exhaustive `finish()` would fail on a stray reload.
      await clock.advance(by: .seconds(5))
      await store.finish()
    }
  }
}
