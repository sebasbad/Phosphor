import Foundation

/// Entity representing an installed application for selective backup exclusion (Issue #4).
public struct AppBackupTarget: Identifiable, Hashable, Sendable {
    public let id: String // CFBundleIdentifier
    public let displayName: String
    public let version: String
    // Storage footprint (nil while calculating in background, or Int64 bytes when resolved)
    public var dynamicDiskBytesOptional: Int64?
    public var staticDiskBytesOptional: Int64?

    public var dynamicDiskBytes: Int64 {
        dynamicDiskBytesOptional ?? 0
    }

    public var staticDiskBytes: Int64 {
        staticDiskBytesOptional ?? 0
    }

    public var isExcluded: Bool
    public var isMediaExcludedOnly: Bool // Keep settings/DBs, exclude videos > 50 MB
    public let isSystemApp: Bool

    public init(
        id: String,
        displayName: String,
        version: String = "",
        dynamicDiskBytes: Int64? = nil,
        staticDiskBytes: Int64? = nil,
        isExcluded: Bool = false,
        isMediaExcludedOnly: Bool = false,
        isSystemApp: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.version = version
        self.dynamicDiskBytesOptional = dynamicDiskBytes
        self.staticDiskBytesOptional = staticDiskBytes
        self.isExcluded = isExcluded
        self.isMediaExcludedOnly = isMediaExcludedOnly
        self.isSystemApp = isSystemApp
    }

    public var isSizeResolved: Bool {
        dynamicDiskBytesOptional != nil || staticDiskBytesOptional != nil
    }

    public var effectiveDynamicBytes: Int64 {
        dynamicDiskBytesOptional ?? 0
    }

    public var effectiveTotalBytes: Int64 {
        (dynamicDiskBytesOptional ?? 0) + (staticDiskBytesOptional ?? 0)
    }

    public var formattedDynamicSize: String {
        guard let bytes = dynamicDiskBytesOptional else {
            // If static size was resolved, dynamic usage is either 0 or restricted by sandbox
            if staticDiskBytesOptional != nil {
                return "0 KB"
            }
            return "Calculating..."
        }
        guard bytes > 0 else { return "0 KB" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    public var formattedTotalSize: String {
        guard dynamicDiskBytesOptional != nil || staticDiskBytesOptional != nil else {
            return "Calculating..."
        }
        let total = (dynamicDiskBytesOptional ?? 0) + (staticDiskBytesOptional ?? 0)
        guard total > 0 else { return "0 KB" }
        return ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
    }
}
