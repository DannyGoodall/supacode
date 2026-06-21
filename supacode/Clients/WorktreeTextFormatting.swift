import Foundation

/// Backend-agnostic text helpers shared by `GitClient` and `JJClient` so the
/// two backends render worktree/workspace rows identically and can't drift.
/// A caseless enum (not free functions) per the project's "static on a type"
/// rule.
nonisolated enum WorktreeTextFormatting {

  /// Relative path from `base` to `target`, climbing out of `base` with `..`
  /// segments when `target` is not a descendant. Returns `"."` when the two
  /// paths are equal. Used for the sidebar row detail under both backends.
  static func relativePath(from base: URL, to target: URL) -> String {
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

  /// Parses a git/jj shortstat trailer (`… N insertions(+), M deletions(-)`)
  /// into added/removed line counts. `git diff --shortstat` and `jj diff
  /// --stat` share this wording, so one parser serves both backends.
  static func parseShortstat(_ output: String) -> (added: Int, removed: Int) {
    let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return (0, 0)
    }
    var added = 0
    var removed = 0
    if let match = trimmed.firstMatch(of: /(\d+)\s+insertions?\(\+\)/) {
      added = Int(match.1) ?? 0
    }
    if let match = trimmed.firstMatch(of: /(\d+)\s+deletions?\(-\)/) {
      removed = Int(match.1) ?? 0
    }
    return (added, removed)
  }
}
