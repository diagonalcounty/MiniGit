import XCTest
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
}
