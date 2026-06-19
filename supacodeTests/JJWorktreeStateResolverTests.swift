import Foundation
import Testing

@testable import supacode

struct JJWorktreeStateResolverTests {
  private func makeTempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  @Test func returnsWorkingCopyDirectoryWhenPresent() throws {
    let root = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let workingCopy = root.appending(path: ".jj").appending(path: "working_copy")
    try FileManager.default.createDirectory(at: workingCopy, withIntermediateDirectories: true)

    let resolved = JJWorktreeStateResolver.workingCopyURL(for: root, fileManager: .default)

    #expect(resolved?.standardizedFileURL == workingCopy.standardizedFileURL)
  }

  @Test func returnsOpHeadsDirectoryWhenPresent() throws {
    let root = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let heads = root.appending(path: ".jj").appending(path: "repo")
      .appending(path: "op_heads").appending(path: "heads")
    try FileManager.default.createDirectory(at: heads, withIntermediateDirectories: true)

    let resolved = JJWorktreeStateResolver.opHeadsURL(forRepositoryRoot: root, fileManager: .default)

    #expect(resolved?.standardizedFileURL == heads.standardizedFileURL)
  }

  @Test func opHeadsReturnsNilWhenAbsent() throws {
    let root = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(
      at: root.appending(path: ".git"), withIntermediateDirectories: true
    )

    #expect(JJWorktreeStateResolver.opHeadsURL(forRepositoryRoot: root, fileManager: .default) == nil)
  }

  @Test func returnsNilWhenJJDirectoryAbsent() throws {
    let root = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    // A plain git worktree with no .jj peer.
    try FileManager.default.createDirectory(
      at: root.appending(path: ".git"), withIntermediateDirectories: true
    )

    #expect(JJWorktreeStateResolver.workingCopyURL(for: root, fileManager: .default) == nil)
  }

  @Test func returnsNilWhenWorkingCopyIsAFileNotADirectory() throws {
    let root = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let jjDir = root.appending(path: ".jj")
    try FileManager.default.createDirectory(at: jjDir, withIntermediateDirectories: true)
    // working_copy exists as a regular file — must not be treated as watchable.
    try Data().write(to: jjDir.appending(path: "working_copy"))

    #expect(JJWorktreeStateResolver.workingCopyURL(for: root, fileManager: .default) == nil)
  }
}
