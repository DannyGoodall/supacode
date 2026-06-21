import Dependencies
import Foundation
import Sharing

public nonisolated struct RepositorySettingsKeyID: Hashable, Sendable {
  public let repositoryID: String

  public init(repositoryID: String) {
    self.repositoryID = repositoryID
  }
}

public nonisolated struct RepositorySettingsKey: SharedKey {
  public let repositoryID: String
  public let rootURL: URL

  public init(rootURL: URL) {
    self.rootURL = rootURL.standardizedFileURL
    repositoryID = self.rootURL.path(percentEncoded: false)
  }

  public var id: RepositorySettingsKeyID {
    RepositorySettingsKeyID(repositoryID: repositoryID)
  }

  public func load(
    context: LoadContext<RepositorySettings>,
    continuation: LoadContinuation<RepositorySettings>
  ) {
    @Dependency(\.repositoryLocalSettingsStorage) var repositoryLocalSettingsStorage
    let repositorySettingsURL = SupacodePaths.repositorySettingsURL(for: rootURL)
    if let localData = try? repositoryLocalSettingsStorage.load(repositorySettingsURL) {
      let decoder = JSONDecoder()
      if let settings = try? decoder.decode(RepositorySettings.self, from: localData) {
        continuation.resume(returning: settings)
        return
      }
      let path = repositorySettingsURL.path(percentEncoded: false)
      SupaLogger("Settings").warning(
        "Unable to decode repository settings at \(path); falling back to global settings."
      )
    }

    // Read WITHOUT `withLock` when the entry already exists: `withLock`
    // republishes `settingsFile` to every observer unconditionally (even for a
    // read), and views that observe `settingsFile` while the render path reads
    // `@Shared(.repositorySettings(...))` would otherwise feed back into an
    // infinite re-render loop. Only take the publishing lock to seed a default.
    @Shared(.settingsFile) var settingsFile: SettingsFile
    if let existing = settingsFile.repositories[repositoryID] {
      continuation.resume(returning: existing)
      return
    }
    let defaults = context.initialValue ?? .default
    $settingsFile.withLock { $0.repositories[repositoryID] = defaults }
    continuation.resume(returning: defaults)
  }

  public func subscribe(
    context _: LoadContext<RepositorySettings>,
    subscriber _: SharedSubscriber<RepositorySettings>
  ) -> SharedSubscription {
    SharedSubscription {}
  }

  public func save(
    _ value: RepositorySettings,
    context _: SaveContext,
    continuation: SaveContinuation
  ) {
    @Dependency(\.repositoryLocalSettingsStorage) var repositoryLocalSettingsStorage
    let repositorySettingsURL = SupacodePaths.repositorySettingsURL(for: rootURL)
    if (try? repositoryLocalSettingsStorage.load(repositorySettingsURL)) != nil {
      do {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        try repositoryLocalSettingsStorage.save(data, repositorySettingsURL)
        continuation.resume()
      } catch {
        continuation.resume(throwing: error)
      }
      return
    }

    @Shared(.settingsFile) var settingsFile: SettingsFile
    $settingsFile.withLock {
      $0.repositories[repositoryID] = value
    }
    continuation.resume()
  }
}
nonisolated extension SharedReaderKey where Self == RepositorySettingsKey.Default {
  public static func repositorySettings(_ rootURL: URL) -> Self {
    Self[RepositorySettingsKey(rootURL: rootURL), default: .default]
  }
}
