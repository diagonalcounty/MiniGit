import XCTest
import XGit
@testable import MiniGit

final class MiniGitTests: XCTestCase {

    // MARK: - Harness

    private func makeTempRepo() -> GitRepository {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let credentialsManager = CredentialsManager(credentialsFileUrl: dir.appendingPathComponent("credentials.json"))
        return GitRepository(dir, credentialsManager)
    }

    private func write(_ text: String, to name: String, in repo: GitRepository) {
        let url = repo.location.appendingPathComponent(name)
        try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func writeBinary(_ bytes: [UInt8], to name: String, in repo: GitRepository) {
        let url = repo.location.appendingPathComponent(name)
        try! Data(bytes).write(to: url)
    }

    private func readFile(_ name: String, in repo: GitRepository) -> String {
        (try? String(contentsOf: repo.location.appendingPathComponent(name), encoding: .utf8)) ?? ""
    }

    private func tipCommit(of repo: GitRepository) -> GitCommit? {
        repo.updateStatus()
        let refName = "refs/heads/\(repo.status.currentBranch)"
        repo.updateCommitGraph()
        return repo.commitGraph.commits.first { $0.refs.contains { $0.name == refName } }
    }

    // MARK: - #734 treeBlobIds(atRef:)

    func testTreeBlobIdsListsCommittedBlobsByPath() {
        let repo = makeTempRepo()
        repo.create()
        repo.setSignature("Test", "test@example.com")

        write("hello\n", to: "a.md", in: repo)
        write("hello\n", to: "dir/c.md", in: repo)
        write("untracked\n", to: "u.md", in: repo)
        repo.stage("a.md")
        repo.stage("dir/c.md")
        repo.commit("initial")

        let expected = [
            "a.md": "ce013625030ba8dba906f756967f9e9ca394464a",
            "dir/c.md": "ce013625030ba8dba906f756967f9e9ca394464a",
        ]

        let ids = repo.treeBlobIds(atRef: "HEAD")
        XCTAssertEqual(ids, expected)
        XCTAssertNil(ids["u.md"])
        for value in ids.values {
            XCTAssertEqual(value.count, 40)
        }

        write("changed\n", to: "a.md", in: repo)
        XCTAssertEqual(repo.treeBlobIds(atRef: "HEAD"), expected)
        XCTAssertEqual(readFile("a.md", in: repo), "changed\n")

        XCTAssertEqual(repo.treeBlobIds(atRef: "refs/heads/no-such-branch"), [:])
    }

    // MARK: - #735 setIndexBlob(_:oid:)

    private func paths(in diff: Diff) -> [String] {
        diff.deltas.compactMap { $0.theNewFile.path ?? $0.theOldFile.path }
    }

    func testSetIndexBlobWritesIndexWithoutHashingWorktree() {
        let repo = makeTempRepo()
        repo.create()
        repo.setSignature("Test", "test@example.com")

        write("hello\n", to: "a.md", in: repo)
        repo.stage("a.md")
        repo.commit("initial")

        write("other\n", to: "a.md", in: repo)

        XCTAssertTrue(repo.setIndexBlob("a.md", oid: "ce013625030ba8dba906f756967f9e9ca394464a"))
        XCTAssertEqual(readFile("a.md", in: repo), "other\n")

        repo.updateStatus()
        XCTAssertTrue(paths(in: repo.status.unstagedChanges).contains("a.md"))
        XCTAssertFalse(paths(in: repo.status.stagedChanges).contains("a.md"))

        XCTAssertFalse(repo.setIndexBlob("a.md", oid: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"))
        XCTAssertEqual(readFile("a.md", in: repo), "other\n")

        repo.updateStatus()
        XCTAssertTrue(paths(in: repo.status.unstagedChanges).contains("a.md"))
        XCTAssertFalse(paths(in: repo.status.stagedChanges).contains("a.md"))
    }

    // MARK: - #736 checkoutPaths(_:atRef:)

    func testCheckoutPathsRestoresOnlyNamedPaths() {
        let repo = makeTempRepo()
        repo.create()
        repo.setSignature("Test", "test@example.com")

        write("hello\n", to: "a.md", in: repo)
        write("world\n", to: "b.md", in: repo)
        repo.stage("a.md")
        repo.stage("b.md")
        repo.commit("initial")

        let tipBefore = tipCommit(of: repo)?.oid.description

        try! FileManager.default.removeItem(at: repo.location.appendingPathComponent("a.md"))
        write("edited\n", to: "b.md", in: repo)

        XCTAssertTrue(repo.checkoutPaths(["a.md"], atRef: "HEAD"))
        XCTAssertEqual(readFile("a.md", in: repo), "hello\n")
        XCTAssertEqual(readFile("b.md", in: repo), "edited\n")

        XCTAssertEqual(tipCommit(of: repo)?.oid.description, tipBefore)

        XCTAssertTrue(repo.checkoutPaths([], atRef: "HEAD"))
        XCTAssertEqual(readFile("b.md", in: repo), "edited\n")

        XCTAssertFalse(repo.checkoutPaths(["a.md"], atRef: "refs/heads/no-such-branch"))
        XCTAssertEqual(readFile("b.md", in: repo), "edited\n")
    }

    // MARK: - #737 updateDirectRef(_:toOID:)

    func testUpdateDirectRefMovesRefWithoutTouchingWorktree() {
        let repo = makeTempRepo()
        repo.create()
        repo.setSignature("Test", "test@example.com")

        write("v1\n", to: "a.md", in: repo)
        repo.stage("a.md")
        repo.commit("first")

        repo.updateStatus()
        let refName = "refs/heads/\(repo.status.currentBranch)"
        let firstCommitId = tipCommit(of: repo)?.oid.description
        XCTAssertNotNil(firstCommitId)

        write("v2\n", to: "a.md", in: repo)
        repo.stage("a.md")
        repo.commit("second")
        let secondCommitId = tipCommit(of: repo)?.oid.description
        XCTAssertNotNil(secondCommitId)
        XCTAssertNotEqual(firstCommitId, secondCommitId)

        XCTAssertTrue(repo.updateDirectRef(refName, toOID: firstCommitId!))
        XCTAssertEqual(readFile("a.md", in: repo), "v2\n")

        repo.updateCommitGraph()
        XCTAssertEqual(
            repo.commitGraph.commits.first { $0.refs.contains { $0.name == refName } }?.oid.description,
            firstCommitId)

        XCTAssertFalse(repo.updateDirectRef(refName, toOID: "0000000000000000000000000000000000000000"))
        repo.updateCommitGraph()
        XCTAssertEqual(
            repo.commitGraph.commits.first { $0.refs.contains { $0.name == refName } }?.oid.description,
            firstCommitId)
        XCTAssertEqual(readFile("a.md", in: repo), "v2\n")
    }

    // MARK: - #738 blobUTF8Text(_:)

    func testBlobUTF8TextReadsCommittedBlobWithoutTouchingWorktree() {
        let repo = makeTempRepo()
        repo.create()
        repo.setSignature("Test", "test@example.com")

        write("hello\n", to: "a.md", in: repo)
        repo.stage("a.md")
        repo.commit("initial")

        write("other\n", to: "a.md", in: repo)

        XCTAssertEqual(repo.blobUTF8Text("ce013625030ba8dba906f756967f9e9ca394464a"), "hello\n")
        XCTAssertEqual(readFile("a.md", in: repo), "other\n")

        XCTAssertNil(repo.blobUTF8Text("0000000000000000000000000000000000000000"))

        writeBinary([0xff, 0xfe], to: "bin.dat", in: repo)
        repo.stage("bin.dat")
        repo.commit("binary")

        XCTAssertNil(repo.blobUTF8Text("46b134b197f35e75e0784bedbf94a8dd124693b1"))
        XCTAssertEqual(try? Data(contentsOf: repo.location.appendingPathComponent("bin.dat")), Data([0xff, 0xfe]))
    }
}
