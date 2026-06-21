import Foundation

public struct SettingsRepositorySummary: Equatable, Hashable, Sendable {
  public var id: String
  public var name: String
  public var isGitRepository: Bool
  /// Whether this repo is a co-located git+jj repository with the experimental
  /// gate on (mirrors `Repository.isColocatedJJ`). Gates the per-repo "prefer
  /// jj" control in repository settings.
  public var isColocatedJJ: Bool

  public var rootURL: URL {
    URL(fileURLWithPath: id).standardizedFileURL
  }

  public init(id: String, name: String, isGitRepository: Bool = true, isColocatedJJ: Bool = false) {
    self.id = id
    self.name = name
    self.isGitRepository = isGitRepository
    self.isColocatedJJ = isColocatedJJ
  }
}
