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

  /// Builds a ShellClient that answers `jj workspace list` with `names` and
  /// `jj workspace root --name <n>` from `paths[n]`.
  private func makeShell(names: [String], paths: [String: String]) -> ShellClient {
    ShellClient(
      run: { _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) },
      runLoginImpl: { _, arguments, _, _ in
        // arguments == ["jj", <subcommand...>]
        if arguments.count >= 3, arguments[1] == "workspace", arguments[2] == "list" {
          return ShellOutput(stdout: names.joined(separator: "\n") + "\n", stderr: "", exitCode: 0)
        }
        if arguments.count >= 5, arguments[1] == "workspace", arguments[2] == "root",
          arguments[3] == "--name"
        {
          let name = arguments[4]
          return ShellOutput(stdout: (paths[name] ?? "") + "\n", stderr: "", exitCode: 0)
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
    #expect(byName["default"]?.workingDirectory.standardizedFileURL == root.standardizedFileURL)
    #expect(byName["feature"]?.workingDirectory.standardizedFileURL == feature.standardizedFileURL)
    #expect(byName["feature"]?.repositoryRootURL.standardizedFileURL == root.standardizedFileURL)
    #expect(byName["feature"]?.isAttached == true)
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
}
