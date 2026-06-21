import Dependencies
import Foundation
import Sharing

/// App-storage keys for experimental, opt-in features. Mirrors the
/// `SidebarPersistenceKey` pattern so the key string and default value
/// live in exactly one place and can't drift between the reducer that
/// reads it and the settings UI that toggles it.
nonisolated extension SharedReaderKey where Self == AppStorageKey<Bool>.Default {
  /// "Use experimental co-located JJ integration." Opt-in gate for the
  /// Jujutsu augmentation of git repositories.
  ///
  /// Defaults to OFF so the app behaves exactly as a pure git
  /// orchestrator until the user turns it on. While off, the repository
  /// loader classifies a colocated git+jj root as a plain `.git`
  /// repository (identical to historical behavior), so nothing
  /// downstream sees the new `.gitColocatedJJ` flavor.
  static var experimentalJJIntegration: Self {
    Self[.appStorage("experimentalJJIntegration"), default: false]
  }
}
