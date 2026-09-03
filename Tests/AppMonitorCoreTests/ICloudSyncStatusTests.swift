import XCTest
@testable import AppMonitorCore

final class ICloudSyncStatusTests: XCTestCase {
    func testPlainLocalFileIsNotICloudManaged() {
        let status = ICloudRawStatus(isUbiquitousItem: false, downloadingStatus: nil, isUploaded: nil, isUploading: nil, hasUnresolvedConflicts: nil)
        XCTAssertEqual(ICloudSyncClassifier.classify(status), .notICloudManaged)
        XCTAssertFalse(ICloudSyncClassifier.classify(status).accessMayStall)
    }

    func testDatalessPlaceholderIsFlaggedAsStalling() {
        let status = ICloudRawStatus(
            isUbiquitousItem: true,
            downloadingStatus: URLUbiquitousItemDownloadingStatus.notDownloaded.rawValue,
            isUploaded: true,
            isUploading: false,
            hasUnresolvedConflicts: false
        )
        let classified = ICloudSyncClassifier.classify(status)
        XCTAssertEqual(classified, .datalessPlaceholder)
        XCTAssertTrue(classified.accessMayStall)
    }

    func testFullyDownloadedAndUploadedFileIsSynced() {
        let status = ICloudRawStatus(
            isUbiquitousItem: true,
            downloadingStatus: URLUbiquitousItemDownloadingStatus.current.rawValue,
            isUploaded: true,
            isUploading: false,
            hasUnresolvedConflicts: false
        )
        let classified = ICloudSyncClassifier.classify(status)
        XCTAssertEqual(classified, .fullySynced)
        XCTAssertFalse(classified.accessMayStall)
    }

    func testDownloadedButNotYetUploadedIsPendingUpload() {
        let status = ICloudRawStatus(
            isUbiquitousItem: true,
            downloadingStatus: URLUbiquitousItemDownloadingStatus.current.rawValue,
            isUploaded: false,
            isUploading: true,
            hasUnresolvedConflicts: false
        )
        XCTAssertEqual(ICloudSyncClassifier.classify(status), .pendingUpload)
    }

    func testUnresolvedConflictTakesPrecedence() {
        let status = ICloudRawStatus(
            isUbiquitousItem: true,
            downloadingStatus: URLUbiquitousItemDownloadingStatus.current.rawValue,
            isUploaded: true,
            isUploading: false,
            hasUnresolvedConflicts: true
        )
        XCTAssertEqual(ICloudSyncClassifier.classify(status), .conflicted)
    }

    func testRealLocalFileReportsNotICloudManaged() throws {
        let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        try "hello".write(to: tempFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        XCTAssertEqual(ICloudSyncClassifier.status(for: tempFile), .notICloudManaged)
    }
}
