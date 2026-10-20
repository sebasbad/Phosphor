import Foundation

/// Represents an iOS backup stored on disk.
struct BackupInfo: Identifiable, Hashable, Sendable {
    enum HealthState: String, Hashable, Sendable {
        case complete = "Complete"
        case paused = "Paused"
        case broken = "Broken"
    }

    let id: String // backup directory name (usually UDID or UDID+timestamp)
    let path: String
    let deviceName: String
    let displayName: String
    let productType: String
    let iosVersion: String
    let serialNumber: String
    let udid: String
    let lastBackupDate: Date?
    let isEncrypted: Bool
    let isFullBackup: Bool
    let size: UInt64
    let sizeResolved: Bool
    let appCount: Int

    var modelName: String {
        BackupInfoPlist(
            deviceName: deviceName,
            displayName: displayName,
            productType: productType,
            productVersion: iosVersion,
            buildVersion: "",
            serialNumber: serialNumber,
            udid: udid,
            iccid: nil, imei: nil, meid: nil, phoneNumber: nil,
            lastBackupDate: lastBackupDate,
            isEncrypted: isEncrypted
        ).modelName
    }

    /// Short, stable discriminator. Prefer the authoritative backup UDID, then
    /// fall back to its serial or backup-folder identity for incomplete metadata.
    var shortUDID: String {
        let source = !udid.isEmpty ? udid : (!serialNumber.isEmpty ? serialNumber : id)
        guard !source.isEmpty else { return "Unknown" }
        return String(source.suffix(8))
    }

    /// Shared user-facing identity for backup lists and pickers. The identifier
    /// suffix keeps same-name, same-model backups visibly distinct without
    /// exposing a complete hardware identifier throughout the UI.
    var deviceIdentityLabel: String {
        let identifier: String
        if !udid.isEmpty {
            identifier = "ID …\(shortUDID)"
        } else if !serialNumber.isEmpty {
            identifier = "Serial …\(shortUDID)"
        } else if !id.isEmpty {
            identifier = "Backup …\(shortUDID)"
        } else {
            identifier = "Unknown device ID"
        }
        return "\(deviceName) • \(modelName) • \(identifier)"
    }

    var dateString: String {
        lastBackupDate?.shortString ?? "Unknown"
    }

    var relativeDate: String {
        lastBackupDate?.relativeString ?? "Unknown"
    }

    var sizeString: String {
        size.formattedFileSize
    }

    /// Deterministic 3-state health classification (Issue #8):
    /// - `.complete`: Manifest metadata exists, payload buckets (`00`..`ff`) exist at root, no unpromoted `Snapshot/`, and `SnapshotState == "finished"`.
    /// - `.paused`: Payload files exist in `00`..`ff` or `Snapshot/`, and backup is awaiting resumption (`Snapshot/` exists or `SnapshotState != "finished"`).
    /// - `.broken`: Metadata files exist (`Info.plist` / `Manifest.db`), but zero payload files exist in `00`..`ff` or `Snapshot/`.
    var healthState: HealthState {
        let manifestDb = (path as NSString).appendingPathComponent("Manifest.db")
        let manifestPlist = (path as NSString).appendingPathComponent("Manifest.plist")
        let fm = FileManager.default
        let hasManifest = (fm.fileExists(atPath: manifestDb) && ((try? fm.attributesOfItem(atPath: manifestDb)[.size] as? UInt64) ?? 0) > 0) ||
                          (fm.fileExists(atPath: manifestPlist) && ((try? fm.attributesOfItem(atPath: manifestPlist)[.size] as? UInt64) ?? 0) > 0)
        let hasRootPayload = BackupManager.backupRootHasPayloadData(path)
        let hasAnyPayload = hasRootPayload || BackupManager.incompleteBackupHasPayloadData(path)
        guard hasAnyPayload else { return .broken }
        guard hasManifest else { return .paused }

        let snapshotPath = (path as NSString).appendingPathComponent("Snapshot")
        var isSnapshotDir: ObjCBool = false
        if fm.fileExists(atPath: snapshotPath, isDirectory: &isSnapshotDir), isSnapshotDir.boolValue,
           BackupManager.backupRootHasPayloadData(snapshotPath) {
            return .paused
        }

        let statusPath = (path as NSString).appendingPathComponent("Status.plist")
        guard let data = fm.contents(atPath: statusPath),
              let plist = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any],
              let snapshotState = plist["SnapshotState"] as? String else {
            return hasRootPayload ? .paused : .broken
        }
        return (hasRootPayload && snapshotState.lowercased() == "finished") ? .complete : .paused
    }

    /// Whether this backup has sealed metadata and completed snapshot files.
    var isComplete: Bool {
        healthState == .complete
    }

    /// Initialize from a backup directory by parsing its plists.
    /// Size calculation recursively walks the whole backup and can be very slow
    /// for large backups, so startup discovery can skip it and fill sizes later.
    static func fromDirectory(_ path: String, includeSize: Bool = true) -> BackupInfo? {
        let dirName = (path as NSString).lastPathComponent
        guard let info = PlistParser.parseBackupInfo(path) else { return nil }
        let status = PlistParser.parseBackupStatus(path)
        let manifest = PlistParser.parseManifest(path)
        let size = includeSize ? FileManager.default.directorySize(at: path) : 0

        let manifestDbPath = (path as NSString).appendingPathComponent("Manifest.db")
        let manifestDbDate = (try? FileManager.default.attributesOfItem(atPath: manifestDbPath)[.modificationDate]) as? Date
        let resolvedDate: Date? = {
            if let infoDate = info.lastBackupDate { return infoDate }
            // If Status.plist is a pre-handshake "BackupState = new" stub from an aborted run,
            // prefer Manifest.db's modification date over the aborted attempt timestamp.
            if status?.backupState.lowercased() == "new", let manifestDbDate {
                return manifestDbDate
            }
            return status?.date ?? manifestDbDate
        }()

        return BackupInfo(
            id: dirName,
            path: path,
            deviceName: info.deviceName,
            displayName: info.displayName,
            productType: info.productType,
            iosVersion: info.productVersion,
            serialNumber: info.serialNumber,
            udid: info.udid,
            lastBackupDate: resolvedDate,
            isEncrypted: manifest?.isEncrypted ?? info.isEncrypted,
            isFullBackup: status?.isFullBackup ?? false,
            size: size,
            sizeResolved: includeSize,
            appCount: manifest?.applicationBundleIds.count ?? info.appCount
        )
    }

    func withSize(_ size: UInt64) -> BackupInfo {
        BackupInfo(
            id: id,
            path: path,
            deviceName: deviceName,
            displayName: displayName,
            productType: productType,
            iosVersion: iosVersion,
            serialNumber: serialNumber,
            udid: udid,
            lastBackupDate: lastBackupDate,
            isEncrypted: isEncrypted,
            isFullBackup: isFullBackup,
            size: size,
            sizeResolved: true,
            appCount: appCount
        )
    }
}
