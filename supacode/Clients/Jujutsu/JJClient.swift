import Foundation
import SupacodeSettingsShared

/// Jujutsu backend for co-located repositories — the jj counterpart to the
/// parts of `GitClient` that Supacode automates. Shells out to the `jj` CLI.
/// Selected per-repository by `GitClientDependency` only when
/// `Repository.usesJujutsuBackend` is true (gate on, colocated, not a per-repo
/// Git override). All operations are `nonisolated` so they run off the main
/// actor like `GitClient`.
struct JJClient {
  private let shell: ShellClient

  nonisolated init(shell: ShellClient = .live) {
    self.shell = shell
  }

  /// Live workspace enumeration (Decision 10). jj cannot list workspaces with
  /// their paths in one call, so: `jj workspace list` yields the names and
  /// `jj workspace root --name <NAME>` resolves each absolute path (works for
  /// non-current workspaces at arbitrary locations). Workspaces whose resolved
  /// directory no longer exists are skipped, mirroring a missing git worktree.
  /// This discovers pre-existing / externally-created workspaces too.
  nonisolated func workspaces(for repoRoot: URL) async throws -> [Worktree] {
    let repositoryRootURL = repoRoot.standardizedFileURL
    let names = try await workspaceNames(for: repositoryRootURL)
    let fileManager = FileManager.default
    var worktrees: [Worktree] = []
    for name in names {
      guard
        let pathOutput = try? await runJJ(
          ["workspace", "root", "--name", name, "--ignore-working-copy"],
          cwd: repositoryRootURL
        )
      else { continue }
      let trimmedPath = pathOutput.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmedPath.isEmpty else { continue }
      let workspaceURL = URL(fileURLWithPath: trimmedPath).standardizedFileURL
      guard fileManager.fileExists(atPath: workspaceURL.path(percentEncoded: false)) else {
        continue
      }
      let detail = Self.relativePath(from: repositoryRootURL, to: workspaceURL)
      let id = workspaceURL.path(percentEncoded: false)
      let resourceValues = try? workspaceURL.resourceValues(forKeys: [
        .creationDateKey, .contentModificationDateKey,
      ])
      let createdAt = resourceValues?.creationDate ?? resourceValues?.contentModificationDate
      worktrees.append(
        Worktree(
          id: id,
          name: name,
          detail: detail,
          workingDirectory: workspaceURL,
          repositoryRootURL: repositoryRootURL,
          createdAt: createdAt,
          isMissing: false,
          isAttached: true
        )
      )
    }
    return worktrees
  }

  /// Workspace names via `jj workspace list -T 'self.name() ++ "\n"'`.
  nonisolated private func workspaceNames(for repoRoot: URL) async throws -> [String] {
    let template = "self.name() ++ \"\\n\""
    let output = try await runJJ(
      ["workspace", "list", "--ignore-working-copy", "-T", template],
      cwd: repoRoot
    )
    return
      output
      .split(whereSeparator: \.isNewline)
      .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
  }

  /// Runs `jj` via a login shell so the user's PATH (mise / brew / cargo
  /// installs) is honored, matching how `GitClient` reaches the bundled `wt`.
  nonisolated private func runJJ(_ arguments: [String], cwd: URL) async throws -> String {
    let env = URL(fileURLWithPath: "/usr/bin/env")
    return try await shell.runLogin(env, ["jj"] + arguments, cwd).stdout
  }

  /// Relative path from `base` to `target` (mirrors `GitClient`'s detail
  /// computation so jj rows render identically to git worktree rows).
  nonisolated private static func relativePath(from base: URL, to target: URL) -> String {
    let baseComponents = base.standardizedFileURL.pathComponents
    let targetComponents = target.standardizedFileURL.pathComponents
    var index = 0
    while index < min(baseComponents.count, targetComponents.count),
      baseComponents[index] == targetComponents[index]
    {
      index += 1
    }
    var result: [String] = []
    if index < baseComponents.count {
      result.append(contentsOf: Array(repeating: "..", count: baseComponents.count - index))
    }
    if index < targetComponents.count {
      result.append(contentsOf: targetComponents[index...])
    }
    if result.isEmpty {
      return "."
    }
    return result.joined(separator: "/")
  }
}
