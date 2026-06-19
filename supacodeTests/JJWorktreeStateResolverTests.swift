import Foundation
import Testing

@testable import supacode

struct JJWorktreeStateResolverTests {
  private func makeTempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
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
}
