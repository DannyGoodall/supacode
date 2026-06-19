import Foundation
import Testing

@testable import SupacodeSettingsShared
@testable import supacode

/// Coverage for the Jujutsu backend's live workspace enumeration
/// (`jj workspace list` + `jj workspace root --name`), incl. the missing-dir
/// skip and the discovery of a workspace at an arbitrary location.
@MainActor
struct JJClientTests {
  private func makeTempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appending(path: "supacode-jjclient-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  /// Builds a ShellClient stubbing the jj subcommands JJClient uses:
  /// `workspace list` → `names`; `workspace root --name <n>` → `paths[n]`;
  /// `log -r <n>@` → `bookmarks[n]`; `log -r @` → `currentBookmark`;
  /// `diff --stat` → `diffStat`.
  private func makeShell(
    names: [String],
    paths: [String: String],
    bookmarks: [String: String] = [:],
    currentBookmark: String = "",
    diffStat: String = "0 files changed, 0 insertions(+), 0 deletions(-)"
  ) -> ShellClient {
    ShellClient(
      run: { _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) },
      runLoginImpl: { _, arguments, _, _ in
        // arguments == ["jj", <subcommand...>]
        func value(after flag: String) -> String? {
          guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else {
            return nil
          }
          return arguments[index + 1]
        }
        if arguments.count >= 3, arguments[1] == "workspace", arguments[2] == "list" {
          return ShellOutput(stdout: names.joined(separator: "\n") + "\n", stderr: "", exitCode: 0)
        }
        if arguments.count >= 5, arguments[1] == "workspace", arguments[2] == "root",
          arguments[3] == "--name"
        {
          return ShellOutput(stdout: (paths[arguments[4]] ?? "") + "\n", stderr: "", exitCode: 0)
        }
        if arguments.count >= 2, arguments[1] == "log" {
          let revset = value(after: "-r") ?? ""
          let bookmark: String
          if revset == "@" {
            bookmark = currentBookmark
          } else {
            bookmark = bookmarks[String(revset.dropLast())] ?? ""  // strip trailing "@"
          }
          return ShellOutput(stdout: bookmark + "\n", stderr: "", exitCode: 0)
        }
        if arguments.count >= 2, arguments[1] == "diff" {
          return ShellOutput(stdout: diffStat + "\n", stderr: "", exitCode: 0)
        }
        return ShellOutput(stdout: "", stderr: "", exitCode: 0)
      }
    )
  }

  @Test func enumeratesWorkspacesWithResolvedPaths() async throws {
    let root = try makeTempDir()
    let feature = try makeTempDir()
    defer {
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.removeItem(at: feature)
    }
    let shell = makeShell(
      names: ["default", "feature"],
      paths: [
        "default": root.path(percentEncoded: false),
        "feature": feature.path(percentEncoded: false),
      ]
    )

    let result = try await JJClient(shell: shell).workspaces(for: root)

    #expect(result.count == 2)
    let byName = Dictionary(uniqueKeysWithValues: result.map { ($0.name, $0) })
    // No bookmarks in this stub → rows fall back to the workspace name.
    #expect(byName["default"]?.workingDirectory.standardizedFileURL == root.standardizedFileURL)
    #expect(byName["feature"]?.workingDirectory.standardizedFileURL == feature.standardizedFileURL)
    #expect(byName["feature"]?.repositoryRootURL.standardizedFileURL == root.standardizedFileURL)
  }

  @Test func skipsWorkspaceWhoseDirectoryIsMissing() async throws {
    let root = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let shell = makeShell(
      names: ["default", "stale"],
      paths: [
        "default": root.path(percentEncoded: false),
        "stale": "/tmp/supacode-jjclient-does-not-exist-\(UUID().uuidString)",
      ]
    )

    let result = try await JJClient(shell: shell).workspaces(for: root)

    #expect(result.map(\.name) == ["default"])
  }

  @Test func usesBookmarkAsNameWhenPresentElseWorkspaceName() async throws {
    let root = try makeTempDir()
    let feature = try makeTempDir()
    defer {
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.removeItem(at: feature)
    }
    let shell = makeShell(
      names: ["default", "feature"],
      paths: [
        "default": root.path(percentEncoded: false),
        "feature": feature.path(percentEncoded: false),
      ],
      bookmarks: ["feature": "feat-x"]  // default has no bookmark
    )

    let result = try await JJClient(shell: shell).workspaces(for: root)
    let byPath = Dictionary(uniqueKeysWithValues: result.map { ($0.workingDirectory.standardizedFileURL, $0) })
    // default: no bookmark → workspace name, not attached
    #expect(byPath[root.standardizedFileURL]?.name == "default")
    #expect(byPath[root.standardizedFileURL]?.isAttached == false)
    // feature: bookmark → shown as the bookmark, attached
    #expect(byPath[feature.standardizedFileURL]?.name == "feat-x")
    #expect(byPath[feature.standardizedFileURL]?.isAttached == true)
  }

  @Test func branchNameReturnsBookmarkAtHeadElseNil() async throws {
    let workspace = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: workspace) }
    let withBookmark = makeShell(names: [], paths: [:], currentBookmark: "main")
    #expect(await JJClient(shell: withBookmark).branchName(forWorkspaceAt: workspace) == "main")
    let anonymous = makeShell(names: [], paths: [:], currentBookmark: "")
    #expect(await JJClient(shell: anonymous).branchName(forWorkspaceAt: workspace) == nil)
  }

  @Test func lineChangesParsesDiffStat() async throws {
    let workspace = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: workspace) }
    let shell = makeShell(
      names: [], paths: [:],
      diffStat: "3 files changed, 10 insertions(+), 2 deletions(-)"
    )
    let changes = await JJClient(shell: shell).lineChanges(at: workspace)
    #expect(changes?.added == 10)
    #expect(changes?.removed == 2)
  }

  @Test func discoversWorkspaceAtArbitraryLocation() async throws {
    // The "pre-existing / external workspace brought into the app" case: a
    // workspace whose path is nowhere near the repo root is still listed.
    let root = try makeTempDir()
    let elsewhere = try makeTempDir()
    defer {
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.removeItem(at: elsewhere)
    }
    let shell = makeShell(
      names: ["default", "elsewhere"],
      paths: [
        "default": root.path(percentEncoded: false),
        "elsewhere": elsewhere.path(percentEncoded: false),
      ]
    )

    let result = try await JJClient(shell: shell).workspaces(for: root)

    #expect(result.contains { $0.name == "elsewhere" })
  }

  // MARK: - Create / remove

  /// Recording shell: captures every jj argv and answers list/root/remote.
  private func makeRecordingShell(
    recorder: JJCommandRecorder,
    names: [String] = [],
    paths: [String: String] = [:],
    remotes: [String] = [],
    bookmarkList: String = ""
  ) -> ShellClient {
    ShellClient(
      run: { _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) },
      runLoginImpl: { _, arguments, _, _ in
        recorder.record(arguments)
        if arguments.count >= 3, arguments[1] == "workspace", arguments[2] == "list" {
          return ShellOutput(stdout: names.joined(separator: "\n") + "\n", stderr: "", exitCode: 0)
        }
        if arguments.count >= 5, arguments[1] == "workspace", arguments[2] == "root" {
          return ShellOutput(stdout: (paths[arguments[4]] ?? "") + "\n", stderr: "", exitCode: 0)
        }
        if arguments.count >= 3, arguments[1] == "git", arguments[2] == "remote" {
          let lines = remotes.map { "\($0) https://example.com/\($0).git" }
          return ShellOutput(stdout: lines.joined(separator: "\n") + "\n", stderr: "", exitCode: 0)
        }
        if arguments.count >= 3, arguments[1] == "bookmark", arguments[2] == "list" {
          return ShellOutput(stdout: bookmarkList, stderr: "", exitCode: 0)
        }
        return ShellOutput(stdout: "", stderr: "", exitCode: 0)
      }
    )
  }

  @Test func bookmarkNamesParsesLocalBookmarksLowercased() async throws {
    let recorder = JJCommandRecorder()
    let shell = makeRecordingShell(
      recorder: recorder,
      bookmarkList: "Main: qpv 123 (empty)\nfeature/x: abc 456\n  (some indented continuation)\n"
    )
    let names = try await JJClient(shell: shell).bookmarkNames(for: URL(fileURLWithPath: "/tmp/repo"))
    #expect(names == ["main", "feature/x"])
  }

  @Test func renameBookmarkIssuesRenameCommand() async throws {
    let recorder = JJCommandRecorder()
    let shell = makeRecordingShell(recorder: recorder)
    try await JJClient(shell: shell).renameBookmark(from: "old", to: "new", repoRoot: URL(fileURLWithPath: "/tmp/repo"))
    #expect(recorder.commands().contains(["bookmark", "rename", "old", "new"]))
  }

  @Test func pushBookmarkIssuesAllowNewPush() async throws {
    let recorder = JJCommandRecorder()
    let shell = makeRecordingShell(recorder: recorder)
    let client = JJClient(shell: shell)
    try await client.pushBookmark(named: "feat", remote: nil, repoRoot: URL(fileURLWithPath: "/tmp/repo"))
    try await client.pushBookmark(named: "feat", remote: "origin", repoRoot: URL(fileURLWithPath: "/tmp/repo"))
    let cmds = recorder.commands()
    #expect(cmds.contains(["git", "push", "--bookmark", "feat", "--allow-new"]))
    #expect(cmds.contains(["git", "push", "--bookmark", "feat", "--allow-new", "--remote", "origin"]))
  }

  @Test func fetchIssuesJJGitFetch() async throws {
    let recorder = JJCommandRecorder()
    let shell = makeRecordingShell(recorder: recorder)
    let client = JJClient(shell: shell)
    try await client.fetch(remote: "origin", repoRoot: URL(fileURLWithPath: "/tmp/repo"))
    try await client.fetch(remote: "", repoRoot: URL(fileURLWithPath: "/tmp/repo"))
    let cmds = recorder.commands()
    #expect(cmds.contains(["git", "fetch", "--remote", "origin"]))
    #expect(cmds.contains(["git", "fetch"]))
  }

  @Test func createWorkspaceAddsWorkspaceTranslatesRemoteRefAndCreatesBookmark() async throws {
    let recorder = JJCommandRecorder()
    let root = URL(fileURLWithPath: "/tmp/repo")
    let baseDir = URL(fileURLWithPath: "/tmp/wts")
    let shell = makeRecordingShell(recorder: recorder, remotes: ["origin"])

    let worktree = try await JJClient(shell: shell).createWorkspace(
      named: "feat", in: root, baseDirectory: baseDir, baseRef: "origin/main", directoryOverride: nil
    )

    #expect(worktree.workingDirectory.standardizedFileURL == baseDir.appending(path: "feat").standardizedFileURL)
    #expect(worktree.name == "feat")
    let cmds = recorder.commands()
    // `origin/main` → `main@origin` because `origin` is a known remote.
    #expect(cmds.contains(["workspace", "add", "/tmp/wts/feat", "--name", "feat", "-r", "main@origin"]))
    #expect(cmds.contains(["bookmark", "create", "feat", "-r", "feat@"]))
  }

  @Test func createWorkspaceLeavesSlashedBookmarkUntranslated() async throws {
    let recorder = JJCommandRecorder()
    let shell = makeRecordingShell(recorder: recorder, remotes: ["origin"])  // no remote named "feature"

    _ = try await JJClient(shell: shell).createWorkspace(
      named: "ws", in: URL(fileURLWithPath: "/tmp/repo"),
      baseDirectory: URL(fileURLWithPath: "/tmp/wts"), baseRef: "feature/x", directoryOverride: nil
    )

    #expect(recorder.commands().contains(["workspace", "add", "/tmp/wts/ws", "--name", "ws", "-r", "feature/x"]))
  }

  @Test func removeWorkspaceForgetsByPathMatchAndDeletesBookmark() async throws {
    let root = URL(fileURLWithPath: "/tmp/repo")
    let wsURL = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: wsURL) }
    let recorder = JJCommandRecorder()
    let shell = makeRecordingShell(
      recorder: recorder,
      names: ["default", "feat"],
      paths: [
        "default": root.path(percentEncoded: false),
        "feat": wsURL.path(percentEncoded: false),
      ]
    )
    let worktree = Worktree(
      id: wsURL.path(percentEncoded: false), name: "feat-bookmark", detail: "",
      workingDirectory: wsURL, repositoryRootURL: root
    )

    let removed = try await JJClient(shell: shell).removeWorkspace(worktree, deleteBookmark: true)

    #expect(removed.standardizedFileURL == wsURL.standardizedFileURL)
    let cmds = recorder.commands()
    #expect(cmds.contains(["workspace", "forget", "feat"]))  // resolved by path match, not display name
    #expect(cmds.contains(["bookmark", "delete", "feat-bookmark"]))
  }
}

/// Thread-safe recorder of jj argv arrays for the create/remove tests.
private nonisolated final class JJCommandRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [[String]] = []

  func record(_ arguments: [String]) {
    lock.lock()
    defer { lock.unlock() }
    // Drop the leading "jj" so assertions read as the subcommand argv.
    recorded.append(Array(arguments.dropFirst()))
  }

  func commands() -> [[String]] {
    lock.lock()
    defer { lock.unlock() }
    return recorded
  }
}
