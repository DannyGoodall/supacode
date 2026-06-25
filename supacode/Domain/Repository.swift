import Foundation
import IdentifiedCollections
import SupacodeSettingsShared

nonisolated struct Repository: Identifiable, Hashable, Sendable {
  /// Where the repository lives (local URL or remote host + path). The single
  /// source of truth for local-vs-remote: `id`, `host`, `rootURL`, and the
  /// FileManager-safe `localRootURL` all derive from it.
  let location: RepositoryLocation
  /// Git repo vs plain directory. Flips freely on reload when the root is
  /// (un)initialized as a git repo; persistence is unchanged.
  let kind: RepositoryKind
  let name: String
  let worktrees: IdentifiedArrayOf<Worktree>

  /// Branded id derived from the location (local: absolute path; remote:
  /// `<user@host:port><path>`). Stored so legacy/test call sites can pass it
  /// explicitly, but production construction always derives it.
  let id: RepositoryID

  /// True only for a **local** git repo that also has a colocated Jujutsu repo
  /// (a `.jj` directory peer of `.git`), and only ever set when the experimental
  /// jj gate is on — the loader leaves it `false` otherwise. Strictly additive:
  /// when `false`, behavior is byte-for-byte the upstream git/folder contract.
  /// Always `false` for a remote repo, because the colocation probe is
  /// FileManager-based and `location.localRootURL` is `nil` for remote. See
  /// `openspec/changes/add-jj-colocation-support/UPSTREAM-RECONCILIATION.md` §4.1.
  let isColocatedJJ: Bool

  /// SSH host this repository lives on, or `nil` for a local repository.
  var host: RemoteHost? { location.host }

  var isGitRepository: Bool { kind == .git }

  /// Display / settings-key URL. For a remote repo this is a synthetic
  /// `file://` over the remote path; never hand it to FileManager.
  var rootURL: URL { location.displayURL }

  /// The on-disk URL for a local repository, `nil` for a remote one. Use this
  /// for any FileManager work so a remote path can't be touched by accident.
  var localRootURL: URL? { location.localRootURL }

  /// Designated initializer: id is derived from the location.
  init(
    location: RepositoryLocation,
    kind: RepositoryKind,
    name: String,
    worktrees: IdentifiedArrayOf<Worktree>,
    isColocatedJJ: Bool = false
  ) {
    self.location = location
    self.kind = kind
    self.name = name
    self.worktrees = worktrees
    self.id = location.id
    self.isColocatedJJ = isColocatedJJ
  }

  /// Back-compat initializer: builds the location from `rootURL` + `host`.
  /// Kept so existing call sites (and tests) compile while the model migrates.
  init(
    id: RepositoryID,
    rootURL: URL,
    name: String,
    worktrees: IdentifiedArrayOf<Worktree>,
    isGitRepository: Bool = true,
    host: RemoteHost? = nil,
    isColocatedJJ: Bool = false
  ) {
    if let host {
      self.location = .remote(host, path: rootURL.path(percentEncoded: false))
    } else {
      self.location = .local(rootURL)
    }
    self.kind = isGitRepository ? .git : .folder
    self.name = name
    self.worktrees = worktrees
    self.id = id
    self.isColocatedJJ = isColocatedJJ
  }

  /// Copy preserving `location`, `kind`, and the jj flavor, swapping only the
  /// worktree set, so a remote repo's host/kind — and a colocated repo's
  /// `isColocatedJJ` — survive an in-state worktree mutation. In-place
  /// rebuilders MUST use this rather than a fresh `init`, whose `isColocatedJJ`
  /// defaults to `false` and would silently reclassify a colocated repo on the
  /// next worktree mutation.
  func withWorktrees(_ worktrees: IdentifiedArrayOf<Worktree>) -> Repository {
    Repository(
      location: location,
      kind: kind,
      name: name,
      worktrees: worktrees,
      isColocatedJJ: isColocatedJJ
    )
  }

  var initials: String {
    Self.initials(from: name)
  }

  /// Synchronous check for whether a root URL is a git repository.
  /// Approximates git's own `is_git_directory()` heuristic so the
  /// result matches what `git` itself would accept as a repo root:
  ///   1. `.bare` / `.git` root names — cheap short-circuit covering
  ///      Supacode's own `.bare` layout and the common `*.git` bare
  ///      convention when the root is literally the metadata dir.
  ///   2. `rootURL/.git` exists (file or directory) — standard
  ///      worktree root. Primary repo, linked worktree pointer,
  ///      submodule, `--separate-git-dir` pointer, or the git-wt
  ///      bare wrapper all surface through this one check.
  ///   3. `HEAD` + `objects` + `refs` all present at the root — any
  ///      git dir (bare or otherwise) regardless of naming. Catches
  ///      bare repos whose directory name does not end in `.git`.
  ///      `HEAD` must be a regular file; git itself rejects a
  ///      `HEAD` directory, so a directory with three child dirs
  ///      named HEAD / objects / refs is not a repo.
  /// Pure FileManager call — safe to invoke off the main actor from
  /// the `GitClientDependency` closure.
  nonisolated static func isGitRepository(at rootURL: URL) -> Bool {
    let fileManager = FileManager.default
    let lastComponent = rootURL.lastPathComponent
    if lastComponent == ".bare" || lastComponent == ".git" {
      return true
    }
    let dotGitPath =
      rootURL
      .appending(path: ".git", directoryHint: .notDirectory)
      .path(percentEncoded: false)
    if fileManager.fileExists(atPath: dotGitPath) {
      return true
    }
    let headPath = rootURL.appending(path: "HEAD", directoryHint: .notDirectory).path(percentEncoded: false)
    let objectsPath = rootURL.appending(path: "objects", directoryHint: .isDirectory).path(percentEncoded: false)
    let refsPath = rootURL.appending(path: "refs", directoryHint: .isDirectory).path(percentEncoded: false)
    var headIsDirectory: ObjCBool = false
    let headExists = fileManager.fileExists(atPath: headPath, isDirectory: &headIsDirectory)
    guard headExists, !headIsDirectory.boolValue else { return false }
    return fileManager.fileExists(atPath: objectsPath)
      && fileManager.fileExists(atPath: refsPath)
  }

  /// Whether `rootURL` is a git repository with a *colocated* Jujutsu
  /// repo. Colocation, in jj's own terms, means the `.jj` directory sits
  /// as a peer of `.git` in the workspace root, so `git` and `jj`
  /// commands can be used interchangeably. We only report colocation
  /// when the root is already a git repository — a `.jj` without a
  /// sibling git dir is a non-colocated jj repo whose internal git
  /// store lives under `.jj/repo/store`, which Supacode's git-based
  /// stack cannot drive, so it is deliberately not treated as a git
  /// repo here.
  ///
  /// Pure FileManager call — safe to invoke off the main actor from the
  /// `GitClientDependency` closure. Detection alone is harmless; the
  /// loader only sets `isColocatedJJ` on a root when the experimental
  /// setting is enabled.
  nonisolated static func isColocatedJJRepository(at rootURL: URL) -> Bool {
    guard isGitRepository(at: rootURL) else { return false }
    let jjPath =
      rootURL
      .appending(path: ".jj", directoryHint: .isDirectory)
      .path(percentEncoded: false)
    var isDirectory: ObjCBool = false
    let exists = FileManager.default.fileExists(atPath: jjPath, isDirectory: &isDirectory)
    return exists && isDirectory.boolValue
  }

  /// Whether a repository should be driven by the Jujutsu backend rather than
  /// Git. Only co-located repositories are eligible — and `isColocatedJJ` is
  /// only ever `true` when the experimental gate is on, so the gate is implicit
  /// here. `preferJJ` is the persisted per-repository tri-state: `nil` uses the
  /// default (prefer jj for a co-located repo), `false` is an explicit Git
  /// override for that repository, and `true` is explicit jj.
  nonisolated static func usesJujutsuBackend(isColocatedJJ: Bool, preferJJ: Bool?) -> Bool {
    isColocatedJJ && (preferJJ ?? true)
  }

  /// Synthetic worktree id for a local folder repository: the repo root path.
  /// Equals the owning repo id, so it round-trips back via `RepositoryID(_:)`;
  /// it can't collide with a git worktree because a path is git or folder, never
  /// both at once.
  nonisolated static func folderWorktreeID(for rootURL: URL) -> Worktree.ID {
    WorktreeID(RepositoryLocation.local(rootURL.standardizedFileURL).id.rawValue)
  }

  /// Shared trim + fallback for the sidebar header and the highlight-row tag.
  /// Trims `custom`; falls back to `fallback` when the trimmed value is empty.
  static func sidebarDisplayName(custom: String?, fallback: String) -> String {
    guard let trimmed = custom?.trimmingCharacters(in: .whitespacesAndNewlines),
      !trimmed.isEmpty
    else {
      return fallback
    }
    return trimmed
  }

  static func name(for rootURL: URL) -> String {
    let name = rootURL.lastPathComponent
    if name == ".bare" || name == ".git" {
      let parentName = rootURL.deletingLastPathComponent().lastPathComponent
      if !parentName.isEmpty, parentName != "/" {
        return parentName
      }
    }
    if name.isEmpty {
      return rootURL.path(percentEncoded: false)
    }
    return name
  }

  static func initials(from name: String) -> String {
    var parts: [String] = []
    var current = ""
    for character in name {
      if character.isLetter || character.isNumber {
        current.append(character)
      } else if !current.isEmpty {
        parts.append(current)
        current = ""
      }
    }
    if !current.isEmpty {
      parts.append(current)
    }
    let initials: String
    if parts.count >= 2 {
      let first = parts[0].prefix(1)
      let second = parts[1].prefix(1)
      initials = String(first + second)
    } else if let part = parts.first {
      initials = String(part.prefix(2))
    } else {
      initials = String(name.prefix(2))
    }
    return initials.uppercased()
  }
}
