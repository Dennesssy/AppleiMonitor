import Foundation

// MARK: - Models

public enum DeveloperProjectMarker: String, Codable, CaseIterable, Hashable {
    case git
    case npm
    case rust
    case swiftPackage
    case xcodeProject

    public var displayName: String {
        switch self {
        case .git: return "Git"
        case .npm: return "npm/Node"
        case .rust: return "Rust/Cargo"
        case .swiftPackage: return "Swift Package"
        case .xcodeProject: return "Xcode Project"
        }
    }
}

public enum DeveloperBloatKind: String, Codable, CaseIterable, Identifiable, Hashable {
    case nodeModules = "node_modules"
    case rustTarget = "target"
    case swiftBuild = ".build"
    case xcodeDerivedData = "DerivedData"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .nodeModules: return "node_modules (npm/yarn/pnpm)"
        case .rustTarget: return "target (Cargo)"
        case .swiftBuild: return ".build (SwiftPM)"
        case .xcodeDerivedData: return "DerivedData (Xcode)"
        }
    }
}

public struct DeveloperBloatItem: Identifiable, Hashable {
    public let id: String
    public let kind: DeveloperBloatKind
    public let path: String
    public let sizeBytes: Int64

    public init(kind: DeveloperBloatKind, path: String, sizeBytes: Int64) {
        self.kind = kind
        self.path = path
        self.sizeBytes = sizeBytes
        self.id = path
    }
}

public struct GitWorkingTreeStatus: Hashable {
    public let branch: String?
    public let uncommittedFileCount: Int
    public let untrackedFileCount: Int
    public let aheadCount: Int
    public let behindCount: Int

    public var isClean: Bool { uncommittedFileCount == 0 && untrackedFileCount == 0 }

    public init(branch: String?, uncommittedFileCount: Int, untrackedFileCount: Int, aheadCount: Int, behindCount: Int) {
        self.branch = branch
        self.uncommittedFileCount = uncommittedFileCount
        self.untrackedFileCount = untrackedFileCount
        self.aheadCount = aheadCount
        self.behindCount = behindCount
    }
}

public struct ICloudExposureSummary: Hashable {
    public let inspectedFileCount: Int
    public let datalessPlaceholderCount: Int
    public let pendingUploadCount: Int
    public let fullySyncedCount: Int
    public let notICloudManagedCount: Int
    public let truncated: Bool

    public var isWithinICloudContainer: Bool { inspectedFileCount > notICloudManagedCount }

    /// True when accessing files in this project (e.g. `git status`, a build) is
    /// likely to stall while iCloud faults dataless placeholders back in.
    public var mayStallOnAccess: Bool { datalessPlaceholderCount > 0 }

    public init(
        inspectedFileCount: Int,
        datalessPlaceholderCount: Int,
        pendingUploadCount: Int,
        fullySyncedCount: Int,
        notICloudManagedCount: Int,
        truncated: Bool
    ) {
        self.inspectedFileCount = inspectedFileCount
        self.datalessPlaceholderCount = datalessPlaceholderCount
        self.pendingUploadCount = pendingUploadCount
        self.fullySyncedCount = fullySyncedCount
        self.notICloudManagedCount = notICloudManagedCount
        self.truncated = truncated
    }
}

public struct DeveloperProject: Identifiable, Hashable {
    public let id: String
    public let path: String
    public let name: String
    public let markers: Set<DeveloperProjectMarker>
    public let bloatItems: [DeveloperBloatItem]
    public let gitStatus: GitWorkingTreeStatus?

    public var totalBloatBytes: Int64 { bloatItems.reduce(0) { $0 + $1.sizeBytes } }

    public init(
        path: String,
        markers: Set<DeveloperProjectMarker>,
        bloatItems: [DeveloperBloatItem],
        gitStatus: GitWorkingTreeStatus?
    ) {
        self.path = path
        self.name = (path as NSString).lastPathComponent
        self.markers = markers
        self.bloatItems = bloatItems
        self.gitStatus = gitStatus
        self.id = path
    }
}

// MARK: - Git status parsing

public enum GitStatusReader {
    /// Injectable so tests can supply canned porcelain output instead of shelling out.
    public typealias ProcessRunner = (_ path: String, _ arguments: [String]) -> (output: String, exitCode: Int32)

    public static func status(atPath path: String, runner: ProcessRunner = runGit) -> GitWorkingTreeStatus? {
        let (output, exitCode) = runner(path, ["status", "--porcelain=v1", "--branch"])
        guard exitCode == 0 else { return nil }
        return parse(porcelainOutput: output)
    }

    static func parse(porcelainOutput: String) -> GitWorkingTreeStatus {
        var branch: String?
        var ahead = 0
        var behind = 0
        var uncommitted = 0
        var untracked = 0

        for rawLine in porcelainOutput.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine)
            if line.hasPrefix("## ") {
                let content = String(line.dropFirst(3))
                if let bracketRange = content.range(of: "[") {
                    branch = content[content.startIndex..<bracketRange.lowerBound]
                        .trimmingCharacters(in: .whitespaces)
                    let bracket = content[bracketRange.lowerBound...]
                    ahead = extractCount(from: bracket, label: "ahead") ?? 0
                    behind = extractCount(from: bracket, label: "behind") ?? 0
                } else {
                    branch = content.trimmingCharacters(in: .whitespaces)
                }
                if let dotsRange = branch?.range(of: "...") {
                    branch = String(branch![branch!.startIndex..<dotsRange.lowerBound])
                }
            } else if line.hasPrefix("??") {
                untracked += 1
            } else {
                uncommitted += 1
            }
        }

        return GitWorkingTreeStatus(
            branch: branch,
            uncommittedFileCount: uncommitted,
            untrackedFileCount: untracked,
            aheadCount: ahead,
            behindCount: behind
        )
    }

    private static func extractCount(from substring: Substring, label: String) -> Int? {
        guard let labelRange = substring.range(of: label) else { return nil }
        var digits = ""
        var index = labelRange.upperBound
        while index < substring.endIndex, substring[index] == " " {
            index = substring.index(after: index)
        }
        while index < substring.endIndex, substring[index].isNumber {
            digits.append(substring[index])
            index = substring.index(after: index)
        }
        return Int(digits)
    }

    public static func runGit(atPath path: String, arguments: [String]) -> (output: String, exitCode: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", path] + arguments
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return ("", -1)
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (String(data: data, encoding: .utf8) ?? "", process.terminationStatus)
    }
}

// MARK: - Scanner

public struct DeveloperProjectScanner {
    public struct Options {
        public var maxDiscoveryDepth: Int
        /// Directory names never descended into while *looking for* project roots.
        public var discoverySkipDirectoryNames: Set<String>
        /// Directory names treated as reclaimable build/dependency bloat.
        public var bloatDirectoryNames: Set<String>
        public var computeGitStatus: Bool

        public init(
            maxDiscoveryDepth: Int = 6,
            discoverySkipDirectoryNames: Set<String> = ["node_modules", ".build", "target", "DerivedData", ".git", "Pods", ".venv", "venv"],
            bloatDirectoryNames: Set<String> = ["node_modules", "target", ".build", "DerivedData"],
            computeGitStatus: Bool = true
        ) {
            self.maxDiscoveryDepth = maxDiscoveryDepth
            self.discoverySkipDirectoryNames = discoverySkipDirectoryNames
            self.bloatDirectoryNames = bloatDirectoryNames
            self.computeGitStatus = computeGitStatus
        }
    }

    private let fileManager: FileManager
    private let options: Options

    public init(fileManager: FileManager = .default, options: Options = Options()) {
        self.fileManager = fileManager
        self.options = options
    }

    // MARK: Discovery

    public func discoverProjectRoots(under rootURL: URL) -> [URL] {
        var found: [URL] = []
        walk(rootURL, depth: 0, into: &found)
        return found
    }

    private func walk(_ url: URL, depth: Int, into found: inout [URL]) {
        guard depth <= options.maxDiscoveryDepth else { return }
        if !markers(at: url).isEmpty {
            found.append(url)
        }
        guard let entries = try? fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for entry in entries {
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            if options.discoverySkipDirectoryNames.contains(entry.lastPathComponent) { continue }
            walk(entry, depth: depth + 1, into: &found)
        }
    }

    public func markers(at url: URL) -> Set<DeveloperProjectMarker> {
        var result: Set<DeveloperProjectMarker> = []
        if fileManager.fileExists(atPath: url.appendingPathComponent(".git").path) { result.insert(.git) }
        if fileManager.fileExists(atPath: url.appendingPathComponent("package.json").path) { result.insert(.npm) }
        if fileManager.fileExists(atPath: url.appendingPathComponent("Cargo.toml").path) { result.insert(.rust) }
        if fileManager.fileExists(atPath: url.appendingPathComponent("Package.swift").path) { result.insert(.swiftPackage) }
        if let contents = try? fileManager.contentsOfDirectory(atPath: url.path),
           contents.contains(where: { $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") }) {
            result.insert(.xcodeProject)
        }
        return result
    }

    // MARK: Bloat

    public func bloatItems(in projectURL: URL) -> [DeveloperBloatItem] {
        options.bloatDirectoryNames.compactMap { name -> DeveloperBloatItem? in
            let candidate = projectURL.appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                return nil
            }
            guard let kind = DeveloperBloatKind(rawValue: name) else { return nil }
            return DeveloperBloatItem(kind: kind, path: candidate.path, sizeBytes: directorySize(candidate))
        }.sorted { $0.sizeBytes > $1.sizeBytes }
    }

    private func directorySize(_ url: URL) -> Int64 {
        var total: Int64 = 0
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey],
            options: [.skipsHiddenFiles],
            errorHandler: nil
        ) else { return 0 }

        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]),
                  values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        return total
    }

    // MARK: iCloud exposure

    /// Walks a project's files (including `.git`, deliberately, since dataless
    /// objects inside `.git` are what stall `git status`/builds) reporting per-file
    /// iCloud sync state. Heavy dependency/build directories are pruned for cost.
    public func iCloudExposure(for projectURL: URL, maxFilesToInspect: Int = 3000) -> ICloudExposureSummary {
        var inspected = 0
        var dataless = 0
        var pendingUpload = 0
        var synced = 0
        var notManaged = 0
        var truncated = false

        let keys: [URLResourceKey] = [
            .isRegularFileKey,
            .isDirectoryKey,
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey,
            .ubiquitousItemIsUploadedKey,
            .ubiquitousItemIsUploadingKey,
            .ubiquitousItemHasUnresolvedConflictsKey
        ]

        guard let enumerator = fileManager.enumerator(
            at: projectURL,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: nil
        ) else {
            return ICloudExposureSummary(
                inspectedFileCount: 0, datalessPlaceholderCount: 0, pendingUploadCount: 0,
                fullySyncedCount: 0, notICloudManagedCount: 0, truncated: false
            )
        }

        for case let itemURL as URL in enumerator {
            guard let values = try? itemURL.resourceValues(forKeys: Set(keys)) else { continue }

            if values.isDirectory == true {
                if options.bloatDirectoryNames.contains(itemURL.lastPathComponent) {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard values.isRegularFile == true else { continue }
            if inspected >= maxFilesToInspect { truncated = true; break }
            inspected += 1

            let raw = ICloudRawStatus(
                isUbiquitousItem: values.isUbiquitousItem ?? false,
                downloadingStatus: values.ubiquitousItemDownloadingStatus?.rawValue,
                isUploaded: values.ubiquitousItemIsUploaded,
                isUploading: values.ubiquitousItemIsUploading,
                hasUnresolvedConflicts: values.ubiquitousItemHasUnresolvedConflicts
            )
            switch ICloudSyncClassifier.classify(raw) {
            case .notICloudManaged: notManaged += 1
            case .datalessPlaceholder: dataless += 1
            case .pendingUpload, .downloading, .conflicted, .unknown: pendingUpload += 1
            case .fullySynced: synced += 1
            }
        }

        return ICloudExposureSummary(
            inspectedFileCount: inspected,
            datalessPlaceholderCount: dataless,
            pendingUploadCount: pendingUpload,
            fullySyncedCount: synced,
            notICloudManagedCount: notManaged,
            truncated: truncated
        )
    }

    // MARK: Combined scan

    public func scanProject(at projectURL: URL) -> DeveloperProject {
        let foundMarkers = markers(at: projectURL)
        let bloat = bloatItems(in: projectURL)
        let git = (foundMarkers.contains(.git) && options.computeGitStatus)
            ? GitStatusReader.status(atPath: projectURL.path)
            : nil
        return DeveloperProject(path: projectURL.path, markers: foundMarkers, bloatItems: bloat, gitStatus: git)
    }

    public func scanAllProjects(under rootURL: URL) -> [DeveloperProject] {
        discoverProjectRoots(under: rootURL).map(scanProject(at:))
    }
}
