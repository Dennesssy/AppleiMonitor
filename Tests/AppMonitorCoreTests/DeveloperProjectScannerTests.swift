import XCTest
@testable import AppMonitorCore

final class DeveloperProjectScannerTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("DevProjectScannerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    private func write(_ relativePath: String, contents: String = "x", under root: URL) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: Marker discovery

    func testDiscoversNpmRustSwiftAndGitMarkers() throws {
        try write("npm-project/package.json", contents: "{}", under: tempRoot)
        try write("rust-project/Cargo.toml", contents: "[package]", under: tempRoot)
        try write("swift-project/Package.swift", contents: "// swift-tools-version:5.9", under: tempRoot)
        try FileManager.default.createDirectory(at: tempRoot.appendingPathComponent("git-project/.git"), withIntermediateDirectories: true)

        let scanner = DeveloperProjectScanner()
        let roots = scanner.discoverProjectRoots(under: tempRoot)
        let names = Set(roots.map(\.lastPathComponent))

        XCTAssertTrue(names.contains("npm-project"))
        XCTAssertTrue(names.contains("rust-project"))
        XCTAssertTrue(names.contains("swift-project"))
        XCTAssertTrue(names.contains("git-project"))
    }

    func testDoesNotDescendIntoNodeModulesWhileDiscovering() throws {
        try write("app/package.json", contents: "{}", under: tempRoot)
        try write("app/node_modules/some-dep/package.json", contents: "{}", under: tempRoot)

        let scanner = DeveloperProjectScanner()
        let roots = scanner.discoverProjectRoots(under: tempRoot)

        XCTAssertFalse(roots.contains { $0.path.contains("node_modules") })
    }

    // MARK: Bloat sizing

    func testMeasuresNodeModulesAndBuildDirectorySizes() throws {
        try write("app/package.json", contents: "{}", under: tempRoot)
        try write("app/node_modules/dep/index.js", contents: String(repeating: "a", count: 1000), under: tempRoot)
        try write("app/.build/debug/binary", contents: String(repeating: "b", count: 500), under: tempRoot)

        let scanner = DeveloperProjectScanner()
        let projectURL = tempRoot.appendingPathComponent("app")
        let items = scanner.bloatItems(in: projectURL)

        let nodeModules = items.first { $0.kind == .nodeModules }
        let build = items.first { $0.kind == .swiftBuild }

        XCTAssertNotNil(nodeModules)
        XCTAssertGreaterThanOrEqual(nodeModules?.sizeBytes ?? 0, 1000)
        XCTAssertNotNil(build)
        XCTAssertGreaterThanOrEqual(build?.sizeBytes ?? 0, 500)
    }

    func testNoBloatItemsWhenNoBuildDirectoriesExist() throws {
        try write("app/package.json", contents: "{}", under: tempRoot)
        let scanner = DeveloperProjectScanner()
        let items = scanner.bloatItems(in: tempRoot.appendingPathComponent("app"))
        XCTAssertTrue(items.isEmpty)
    }

    // MARK: Git status parsing

    func testParsesCleanPorcelainOutput() {
        let status = GitStatusReader.parse(porcelainOutput: "## main...origin/main\n")
        XCTAssertEqual(status.branch, "main")
        XCTAssertTrue(status.isClean)
        XCTAssertEqual(status.aheadCount, 0)
        XCTAssertEqual(status.behindCount, 0)
    }

    func testParsesUncommittedAndUntrackedCounts() {
        let output = """
        ## main...origin/main [ahead 2, behind 1]
         M Sources/Foo.swift
        A  Sources/Bar.swift
        ?? Sources/NewFile.swift
        ?? scratch.txt
        """
        let status = GitStatusReader.parse(porcelainOutput: output)
        XCTAssertEqual(status.branch, "main")
        XCTAssertEqual(status.uncommittedFileCount, 2)
        XCTAssertEqual(status.untrackedFileCount, 2)
        XCTAssertEqual(status.aheadCount, 2)
        XCTAssertEqual(status.behindCount, 1)
        XCTAssertFalse(status.isClean)
    }

    func testGitStatusReturnsNilWhenCommandFails() {
        let status = GitStatusReader.status(atPath: "/nonexistent") { _, _ in ("", 128) }
        XCTAssertNil(status)
    }

    func testGitStatusAgainstRealRepository() throws {
        let repoURL = tempRoot.appendingPathComponent("real-repo")
        try FileManager.default.createDirectory(at: repoURL, withIntermediateDirectories: true)

        func run(_ arguments: [String]) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["git", "-C", repoURL.path] + arguments
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            try process.run()
            process.waitUntilExit()
        }

        try run(["init", "-q"])
        try run(["config", "user.email", "test@example.com"])
        try run(["config", "user.name", "Test"])
        try write("real-repo/committed.txt", contents: "v1", under: tempRoot)
        try run(["add", "committed.txt"])
        try run(["commit", "-q", "-m", "initial"])

        // Clean immediately after commit.
        let cleanStatus = GitStatusReader.status(atPath: repoURL.path)
        XCTAssertEqual(cleanStatus?.isClean, true)

        // Dirty the tree with an untracked file and a modification.
        try write("real-repo/untracked.txt", contents: "new", under: tempRoot)
        try "v2".write(to: repoURL.appendingPathComponent("committed.txt"), atomically: true, encoding: .utf8)

        let dirtyStatus = GitStatusReader.status(atPath: repoURL.path)
        XCTAssertEqual(dirtyStatus?.untrackedFileCount, 1)
        XCTAssertEqual(dirtyStatus?.uncommittedFileCount, 1)
        XCTAssertEqual(dirtyStatus?.isClean, false)
    }

    // MARK: Combined scan

    func testScanProjectAttachesGitStatusOnlyWhenGitMarkerPresent() throws {
        try write("no-git/package.json", contents: "{}", under: tempRoot)
        let scanner = DeveloperProjectScanner()
        let project = scanner.scanProject(at: tempRoot.appendingPathComponent("no-git"))
        XCTAssertNil(project.gitStatus)
        XCTAssertFalse(project.markers.contains(.git))
    }

    // MARK: iCloud exposure

    func testICloudExposureReportsAllLocalFilesAsNotManaged() throws {
        try write("app/package.json", contents: "{}", under: tempRoot)
        try write("app/src/main.js", contents: "console.log(1)", under: tempRoot)

        let scanner = DeveloperProjectScanner()
        let summary = scanner.iCloudExposure(for: tempRoot.appendingPathComponent("app"))

        XCTAssertGreaterThanOrEqual(summary.inspectedFileCount, 2)
        XCTAssertEqual(summary.datalessPlaceholderCount, 0)
        XCTAssertFalse(summary.isWithinICloudContainer)
        XCTAssertFalse(summary.mayStallOnAccess)
    }

    func testICloudExposureSkipsBloatDirectoryContents() throws {
        try write("app/package.json", contents: "{}", under: tempRoot)
        try write("app/node_modules/dep/index.js", contents: "x", under: tempRoot)

        let scanner = DeveloperProjectScanner()
        let summary = scanner.iCloudExposure(for: tempRoot.appendingPathComponent("app"))

        // Only package.json should be inspected; node_modules contents are pruned.
        XCTAssertEqual(summary.inspectedFileCount, 1)
    }
}
