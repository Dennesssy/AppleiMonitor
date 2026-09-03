import Foundation

/// Raw per-file iCloud values as reported by `URLResourceValues`, isolated from the
/// `URL` API so the interpretation logic below can be unit tested without a real
/// ubiquity container on disk.
public struct ICloudRawStatus: Hashable {
    public let isUbiquitousItem: Bool
    public let downloadingStatus: String?
    public let isUploaded: Bool?
    public let isUploading: Bool?
    public let hasUnresolvedConflicts: Bool?

    public init(
        isUbiquitousItem: Bool,
        downloadingStatus: String?,
        isUploaded: Bool?,
        isUploading: Bool?,
        hasUnresolvedConflicts: Bool?
    ) {
        self.isUbiquitousItem = isUbiquitousItem
        self.downloadingStatus = downloadingStatus
        self.isUploaded = isUploaded
        self.isUploading = isUploading
        self.hasUnresolvedConflicts = hasUnresolvedConflicts
    }
}

/// The practically-useful classification of a file's iCloud sync state, collapsing
/// the raw resource-value combinations into buckets that map to what a user actually
/// wants to know: "will touching this file be instant, or will it stall on a
/// download/upload round trip?"
public enum ICloudSyncState: String, Hashable, CaseIterable {
    case notICloudManaged
    case fullySynced
    case pendingUpload
    case downloading
    case datalessPlaceholder
    case conflicted
    case unknown

    public var displayName: String {
        switch self {
        case .notICloudManaged: return "Not iCloud-managed"
        case .fullySynced: return "Synced"
        case .pendingUpload: return "Pending upload"
        case .downloading: return "Downloading"
        case .datalessPlaceholder: return "Dataless placeholder (not downloaded)"
        case .conflicted: return "Sync conflict"
        case .unknown: return "Unknown iCloud state"
        }
    }

    /// Whether reading this file's contents is expected to block on a network
    /// round trip rather than resolve from local disk immediately.
    public var accessMayStall: Bool {
        switch self {
        case .datalessPlaceholder, .downloading, .conflicted, .unknown:
            return true
        case .notICloudManaged, .fullySynced, .pendingUpload:
            return false
        }
    }
}

public enum ICloudSyncClassifier {
    public static func classify(_ status: ICloudRawStatus) -> ICloudSyncState {
        guard status.isUbiquitousItem else { return .notICloudManaged }
        if status.hasUnresolvedConflicts == true { return .conflicted }

        switch status.downloadingStatus {
        case URLUbiquitousItemDownloadingStatus.notDownloaded.rawValue:
            return .datalessPlaceholder
        case URLUbiquitousItemDownloadingStatus.current.rawValue:
            if status.isUploading == true { return .pendingUpload }
            if status.isUploaded == false { return .pendingUpload }
            return .fullySynced
        case URLUbiquitousItemDownloadingStatus.downloaded.rawValue:
            if status.isUploading == true { return .pendingUpload }
            return .downloading
        default:
            return .unknown
        }
    }

    /// Reads the real per-file resource values for `url`. Returns `.notICloudManaged`
    /// (rather than throwing) for any file the resource values can't be read for,
    /// since a plain local file legitimately has no ubiquity values to report.
    public static func status(for url: URL) -> ICloudSyncState {
        classify(rawStatus(for: url))
    }

    public static func rawStatus(for url: URL) -> ICloudRawStatus {
        let keys: Set<URLResourceKey> = [
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey,
            .ubiquitousItemIsUploadedKey,
            .ubiquitousItemIsUploadingKey,
            .ubiquitousItemHasUnresolvedConflictsKey
        ]
        guard let values = try? url.resourceValues(forKeys: keys) else {
            return ICloudRawStatus(
                isUbiquitousItem: false,
                downloadingStatus: nil,
                isUploaded: nil,
                isUploading: nil,
                hasUnresolvedConflicts: nil
            )
        }
        return ICloudRawStatus(
            isUbiquitousItem: values.isUbiquitousItem ?? false,
            downloadingStatus: values.ubiquitousItemDownloadingStatus?.rawValue,
            isUploaded: values.ubiquitousItemIsUploaded,
            isUploading: values.ubiquitousItemIsUploading,
            hasUnresolvedConflicts: values.ubiquitousItemHasUnresolvedConflicts
        )
    }
}
