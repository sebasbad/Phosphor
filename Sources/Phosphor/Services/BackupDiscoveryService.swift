import Foundation
#if canImport(SQLite3)
import SQLite3
#endif

/// Handles discovery, integrity checking, and sanitization of iOS backup folders.
enum BackupDiscoveryService {

    /// True when a backup metadata file exists AND has real content.
    static func isNonEmptyFile(_ path: String) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? UInt64 else {
            return false
        }
        return size > 0
    }

    /// True when `path` looks like a single iOS backup folder (UDID dir with Info.plist + Manifest.*).
    static func looksLikeBackupFolder(_ path: String) -> Bool {
        let info = (path as NSString).appendingPathComponent("Info.plist")
        let manifestPlist = (path as NSString).appendingPathComponent("Manifest.plist")
        let manifestDb = (path as NSString).appendingPathComponent("Manifest.db")
        return isNonEmptyFile(info) &&
               (isNonEmptyFile(manifestPlist) || isNonEmptyFile(manifestDb))
    }

    /// Discover backups in a target directory.
    static func discoverBackups(at dir: String) -> (backups: [BackupInfo], error: String?) {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dir, isDirectory: &isDir) else {
            return ([], nil)
        }
        guard isDir.boolValue else {
            return ([], "\(dir) is not a directory.")
        }

        // Single-backup case: directory is itself a backup folder
        if looksLikeBackupFolder(dir) {
            if let backup = BackupInfo.fromDirectory(dir, includeSize: false) {
                return ([backup], nil)
            }
            return ([], nil)
        }

        guard let items = try? fm.contentsOfDirectory(atPath: dir) else {
            return ([], "Cannot read backup directory at \(dir).")
        }

        var discovered: [BackupInfo] = []
        for item in items {
            let fullPath = (dir as NSString).appendingPathComponent(item)
            var itemIsDir: ObjCBool = false
            guard fm.fileExists(atPath: fullPath, isDirectory: &itemIsDir), itemIsDir.boolValue else { continue }
            guard looksLikeBackupFolder(fullPath) else { continue }

            if let backup = BackupInfo.fromDirectory(fullPath, includeSize: false) {
                discovered.append(backup)
            }
        }

        let sorted = discovered.sorted { ($0.lastBackupDate ?? .distantPast) > ($1.lastBackupDate ?? .distantPast) }
        return (sorted, nil)
    }

    /// Check whether a device has complete backup metadata, missing folder, or incomplete partial folder.
    static func backupMetadataHealth(for udid: String, in rootDirectory: String) -> BackupManager.BackupMetadataHealth {
        let deviceDirectory = (rootDirectory as NSString).appendingPathComponent(udid)
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: deviceDirectory, isDirectory: &isDir) else {
            return .missing
        }
        guard isDir.boolValue else { return .incomplete(path: deviceDirectory) }
        return looksLikeBackupFolder(deviceDirectory) ? .complete : .incomplete(path: deviceDirectory)
    }

    static func incompleteBackupHasKnownMarkers(_ path: String) -> Bool {
        let knownMarkers = ["Info.plist", "Status.plist", "Manifest.plist", "Manifest.db", "Manifest.mbdb"]
        return knownMarkers.contains { marker in
            FileManager.default.fileExists(atPath: (path as NSString).appendingPathComponent(marker))
        }
    }

    /// True when the incomplete backup folder contains real payload data (hashed directories/files).
    static func incompleteBackupHasPayloadData(_ path: String) -> Bool {
        let fm = FileManager.default
        let checkPayloadDir: (String) -> Bool = { dirPath in
            guard let entries = try? fm.contentsOfDirectory(atPath: dirPath) else { return false }
            for entry in entries {
                if entry.count == 2 || entry.count == 40 {
                    let subPath = (dirPath as NSString).appendingPathComponent(entry)
                    var isDir: ObjCBool = false
                    if fm.fileExists(atPath: subPath, isDirectory: &isDir) {
                        if isDir.boolValue {
                            if let subEntries = try? fm.contentsOfDirectory(atPath: subPath), !subEntries.isEmpty {
                                return true
                            }
                        } else if isNonEmptyFile(subPath) {
                            return true
                        }
                    }
                }
            }
            return false
        }

        if checkPayloadDir(path) { return true }

        let snapshotPath = (path as NSString).appendingPathComponent("Snapshot")
        var isSnapshotDir: ObjCBool = false
        if fm.fileExists(atPath: snapshotPath, isDirectory: &isSnapshotDir), isSnapshotDir.boolValue {
            if checkPayloadDir(snapshotPath) { return true }
        }

        return false
    }

    /// Sanitize an interrupted backup folder before resuming to prevent com.apple.mobilebackup2
    /// and idevicebackup2 / pymobiledevice3 from failing with MBErrorDomain/205.
    @discardableResult
    static func sanitizeIncompleteBackup(at path: String) -> BackupManager.SanitizeResult {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            return BackupManager.SanitizeResult(filesScanned: 0, filesCleaned: 0, walCheckpointed: false)
        }

        var scanned = 0
        var cleaned = 0
        var walCheckpointed = false

        // 1. Remove 0-byte or unparseable Status.plist so mobilebackup2 starts a clean phase
        let statusPath = (path as NSString).appendingPathComponent("Status.plist")
        if fm.fileExists(atPath: statusPath) {
            scanned += 1
            if !isNonEmptyFile(statusPath) {
                if (try? fm.removeItem(atPath: statusPath)) != nil { cleaned += 1 }
            } else if let data = try? Data(contentsOf: URL(fileURLWithPath: statusPath)),
                      (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) == nil {
                if (try? fm.removeItem(atPath: statusPath)) != nil { cleaned += 1 }
            }
        }

        // 2. Remove 0-byte Info.plist if unparseable
        let infoPath = (path as NSString).appendingPathComponent("Info.plist")
        if fm.fileExists(atPath: infoPath) {
            scanned += 1
            if !isNonEmptyFile(infoPath) {
                if (try? fm.removeItem(atPath: infoPath)) != nil { cleaned += 1 }
            } else if let data = try? Data(contentsOf: URL(fileURLWithPath: infoPath)),
                      (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) == nil {
                if (try? fm.removeItem(atPath: infoPath)) != nil { cleaned += 1 }
            }
        }

        // 3. Remove 0-byte Manifest.plist if unparseable
        let manifestPlistPath = (path as NSString).appendingPathComponent("Manifest.plist")
        if fm.fileExists(atPath: manifestPlistPath) {
            scanned += 1
            if !isNonEmptyFile(manifestPlistPath) {
                if (try? fm.removeItem(atPath: manifestPlistPath)) != nil { cleaned += 1 }
            } else if let data = try? Data(contentsOf: URL(fileURLWithPath: manifestPlistPath)),
                      (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) == nil {
                if (try? fm.removeItem(atPath: manifestPlistPath)) != nil { cleaned += 1 }
            }
        }

        // 4. Checkpoint SQLite Manifest.db if WAL sidecars exist
        let manifestDbPath = (path as NSString).appendingPathComponent("Manifest.db")
        let walPath = (path as NSString).appendingPathComponent("Manifest.db-wal")
        let shmPath = (path as NSString).appendingPathComponent("Manifest.db-shm")
        if fm.fileExists(atPath: manifestDbPath) && isNonEmptyFile(manifestDbPath) {
            scanned += 1
            if fm.fileExists(atPath: walPath) || fm.fileExists(atPath: shmPath) {
                scanned += (fm.fileExists(atPath: walPath) ? 1 : 0) + (fm.fileExists(atPath: shmPath) ? 1 : 0)
                var dbPointer: OpaquePointer?
                if sqlite3_open(manifestDbPath, &dbPointer) == SQLITE_OK, let db = dbPointer {
                    var logFrames: Int32 = 0
                    var ckptFrames: Int32 = 0
                    if sqlite3_wal_checkpoint_v2(db, nil, SQLITE_CHECKPOINT_TRUNCATE, &logFrames, &ckptFrames) == SQLITE_OK {
                        walCheckpointed = true
                    }
                    sqlite3_close(db)
                }
                if fm.fileExists(atPath: walPath) && !isNonEmptyFile(walPath) {
                    if (try? fm.removeItem(atPath: walPath)) != nil { cleaned += 1 }
                }
                if fm.fileExists(atPath: shmPath) && !isNonEmptyFile(shmPath) {
                    if (try? fm.removeItem(atPath: shmPath)) != nil { cleaned += 1 }
                }
            }
        } else if fm.fileExists(atPath: manifestDbPath) && !isNonEmptyFile(manifestDbPath) {
            scanned += 1
            if (try? fm.removeItem(atPath: manifestDbPath)) != nil { cleaned += 1 }
            if fm.fileExists(atPath: walPath) {
                scanned += 1
                if (try? fm.removeItem(atPath: walPath)) != nil { cleaned += 1 }
            }
            if fm.fileExists(atPath: shmPath) {
                scanned += 1
                if (try? fm.removeItem(atPath: shmPath)) != nil { cleaned += 1 }
            }
        }

        // 5. Clean up leftover temporary/partial download files (.tmp, .staging)
        if let entries = try? fm.contentsOfDirectory(atPath: path) {
            for entry in entries where entry.hasSuffix(".tmp") || entry.hasSuffix(".staging") {
                scanned += 1
                if (try? fm.removeItem(atPath: (path as NSString).appendingPathComponent(entry))) != nil {
                    cleaned += 1
                }
            }
        }

        return BackupManager.SanitizeResult(filesScanned: scanned, filesCleaned: cleaned, walCheckpointed: walCheckpointed)
    }

    /// Fast inspect statistics of an interrupted/saved backup folder.
    static func incompleteBackupStats(for udid: String, in rootDirectory: String) -> BackupManager.IncompleteBackupStats? {
        let fm = FileManager.default
        let path = (rootDirectory as NSString).appendingPathComponent(udid)
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return nil }

        // Fast path: if Manifest.db is present and readable via SQLite
        let manifestDbPath = (path as NSString).appendingPathComponent("Manifest.db")
        if fm.fileExists(atPath: manifestDbPath),
           let reader = try? SQLiteReader(path: manifestDbPath) {
            let countQuery = "SELECT count(*) FROM Files WHERE flags = 1"
            let rowCount: Int? = try? reader.scalar(countQuery)
            if let rowCount, rowCount > 0 {
                let modDate = (try? fm.attributesOfItem(atPath: manifestDbPath)[.modificationDate]) as? Date
                let sizeQuery = "SELECT sum(length(file)) FROM Files WHERE flags = 1"
                let metadataBytes: Int? = try? reader.scalar(sizeQuery)
                let estimatedBytes = UInt64(metadataBytes ?? (rowCount * 100_000))
                return BackupManager.IncompleteBackupStats(fileCount: rowCount, totalBytes: estimatedBytes, lastModified: modDate)
            }
        }

        let snapshotPath = (path as NSString).appendingPathComponent("Snapshot")
        let targetDir = fm.fileExists(atPath: snapshotPath, isDirectory: &isDir) && isDir.boolValue ? snapshotPath : path

        var count = 0
        var totalBytes: UInt64 = 0
        var latestDate: Date?

        guard let subdirs = try? fm.contentsOfDirectory(atPath: targetDir) else { return nil }
        for sub in subdirs where sub.count == 2 || sub.count == 40 {
            if Task.isCancelled { return nil }
            let subPath = (targetDir as NSString).appendingPathComponent(sub)
            if let files = try? fm.contentsOfDirectory(atPath: subPath) {
                count += files.count
                for file in files {
                    if Task.isCancelled { return nil }
                    let filePath = (subPath as NSString).appendingPathComponent(file)
                    if let attrs = try? fm.attributesOfItem(atPath: filePath) {
                        if let size = attrs[.size] as? UInt64 {
                            totalBytes += size
                        }
                        if let mod = attrs[.modificationDate] as? Date {
                            if latestDate == nil || mod > latestDate! {
                                latestDate = mod
                            }
                        }
                    }
                }
            }
        }

        guard count > 0 || totalBytes > 0 else { return nil }
        return BackupManager.IncompleteBackupStats(fileCount: count, totalBytes: totalBytes, lastModified: latestDate)
    }

    /// Samples the currently written domain by finding the most recently modified
    /// file in the active backup directory and resolving its domain from Manifest.db.
    nonisolated static func sampleActiveDomain(for udid: String, in rootDirectory: String) -> String? {
        let fm = FileManager.default
        let path = (rootDirectory as NSString).appendingPathComponent(udid)
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return nil }

        let snapshotPath = (path as NSString).appendingPathComponent("Snapshot")
        let targetDir = fm.fileExists(atPath: snapshotPath, isDirectory: &isDir) && isDir.boolValue ? snapshotPath : path

        guard let subdirs = try? fm.contentsOfDirectory(atPath: targetDir) else { return nil }
        var newestFileID: String?
        var newestDate: Date?

        var sampledSubdirs = 0
        for sub in subdirs where sub.count == 2 {
            if Task.isCancelled { return nil }
            sampledSubdirs += 1
            if sampledSubdirs > 10 { break }
            let subPath = (targetDir as NSString).appendingPathComponent(sub)
            guard let files = try? fm.contentsOfDirectory(atPath: subPath) else { continue }
            for file in files {
                if Task.isCancelled { return nil }
                let filePath = (subPath as NSString).appendingPathComponent(file)
                if let attrs = try? fm.attributesOfItem(atPath: filePath),
                   let mod = attrs[.modificationDate] as? Date {
                    if newestDate == nil || mod > newestDate! {
                        newestDate = mod
                        newestFileID = file
                    }
                }
            }
        }

        guard let fileID = newestFileID else { return nil }
        guard let manifest = try? BackupManifest(backupPath: path) else { return nil }
        return manifest.entry(withFileID: fileID)?.domain
    }
}
