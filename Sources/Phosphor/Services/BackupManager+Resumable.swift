import Foundation
import SQLite3

extension BackupManager {

    /// True when the incomplete backup folder contains real payload data (hashed directories/files).
    static func incompleteBackupHasPayloadData(_ path: String) -> Bool {
        let fm = FileManager.default
        let checkPayloadDir: (String) -> Bool = { dirPath in
            guard let entries = try? fm.contentsOfDirectory(atPath: dirPath) else { return false }
            for entry in entries {
                // iOS stores payload files in 2-hex-character subdirectories (00-ff) or SHA-1 hashes (40 chars)
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

        // Check the backup root directory
        if checkPayloadDir(path) {
            return true
        }

        // MobileBackup2 / pymobiledevice3 stores in-flight files in a 'Snapshot/' subdirectory before promotion
        let snapshotPath = (path as NSString).appendingPathComponent("Snapshot")
        var isSnapshotDir: ObjCBool = false
        if fm.fileExists(atPath: snapshotPath, isDirectory: &isSnapshotDir), isSnapshotDir.boolValue {
            if checkPayloadDir(snapshotPath) {
                return true
            }
        }

        return false
    }

    struct IncompleteBackupStats {
        let fileCount: Int
        let totalBytes: UInt64
        let lastModified: Date?

        var formattedSize: String {
            totalBytes.formattedFileSize
        }

        var relativeTimeDescription: String {
            guard let lastModified else { return "recently" }
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .full
            return formatter.localizedString(for: lastModified, relativeTo: Date())
        }

        /// Calculate completion percentage against target device used storage.
        /// Returns nil if device storage capacity is unknown (retrocompatible).
        func completionFraction(for device: DeviceInfo?) -> Double? {
            guard let device else { return nil }
            // If device total & available disk space are reported from lockdown
            if let total = device.totalDiskCapacity, let available = device.availableDiskSpace, total > available {
                let used = total - available
                if used > 0 {
                    let fraction = Double(totalBytes) / Double(used)
                    return min(max(fraction, 0.01), 0.99)
                }
            }
            // Fallback to totalDataCapacity if available
            if let totalData = device.totalDataCapacity, totalData > 0 {
                let fraction = Double(totalBytes) / Double(totalData)
                return min(max(fraction, 0.01), 0.99)
            }
            return nil
        }

        /// Calculate remaining payload bytes against target device used storage.
        /// Returns nil if device storage capacity is unknown.
        func remainingBytes(for device: DeviceInfo?) -> UInt64? {
            guard let device else { return nil }
            if let total = device.totalDiskCapacity, let available = device.availableDiskSpace, total > available {
                let used = total - available
                return used > totalBytes ? (used - totalBytes) : 0
            }
            if let totalData = device.totalDataCapacity, totalData > totalBytes {
                return totalData - totalBytes
            }
            return nil
        }

        /// Estimated time to resume remaining data based on connection type.
        /// USB ~35 MB/s, Wi-Fi ~10 MB/s. Returns nil if remaining bytes are unknown.
        func estimatedResumeTime(for device: DeviceInfo?) -> String? {
            guard let remaining = remainingBytes(for: device), remaining > 0 else { return nil }
            let bytesPerSec: Double = (device?.connectionType == .wifi) ? 10_000_000 : 35_000_000
            let seconds = Int(Double(remaining) / bytesPerSec)
            if seconds < 60 {
                return "~1m"
            } else if seconds < 3600 {
                let m = max(1, seconds / 60)
                return "~\(m)m"
            } else {
                let h = seconds / 3600
                let m = (seconds % 3600) / 60
                return m > 0 ? "~\(h)h \(m)m" : "~\(h)h"
            }
        }
    }

    /// Trustworthiness of a backup's manifest, or nil when it cannot be opened.
    nonisolated static func backupIntegrity(for udid: String, in directory: String? = nil) -> BackupManifest.IntegrityReport? {
        guard let manifest = try? BackupManifest(backupPath: backupPath(for: udid, in: directory)) else {
            return nil
        }
        return manifest.integrityReport()
    }

    nonisolated static func incompleteBackupStats(for udid: String, in directory: String? = nil) -> IncompleteBackupStats? {
        let fm = FileManager.default
        let path = backupPath(for: udid, in: directory)
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return nil }

        // Fast path: if Manifest.db is present and readable via SQLite, query count and total size in milliseconds
        // instead of crawling hundreds of thousands of files across an external drive.
        let manifestDbPath = (path as NSString).appendingPathComponent("Manifest.db")
        if fm.fileExists(atPath: manifestDbPath),
           let reader = try? SQLiteReader(path: manifestDbPath) {
            let countQuery = "SELECT count(*) FROM Files WHERE flags = 1"
            let rowCount: Int? = try? reader.scalar(countQuery)
            if let rowCount, rowCount > 0 {
                let modDate = (try? fm.attributesOfItem(atPath: manifestDbPath)[.modificationDate]) as? Date
                // Try to get total file size if recorded, otherwise estimate ~100KB per file
                let sizeQuery = "SELECT sum(length(file)) FROM Files WHERE flags = 1"
                let metadataBytes: Int? = try? reader.scalar(sizeQuery)
                let estimatedBytes = UInt64(metadataBytes ?? (rowCount * 100_000))
                return IncompleteBackupStats(fileCount: rowCount, totalBytes: estimatedBytes, lastModified: modDate)
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
        return IncompleteBackupStats(fileCount: count, totalBytes: totalBytes, lastModified: latestDate)
    }

    /// Samples the currently written domain by finding the most recently modified
    /// file in the active backup directory and resolving its domain from Manifest.db.
    /// Returns nil if no Manifest.db exists yet or if the file cannot be mapped.
    nonisolated static func sampleActiveDomain(for udid: String, in directory: String? = nil) -> String? {
        let fm = FileManager.default
        let path = backupPath(for: udid, in: directory)
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return nil }

        let snapshotPath = (path as NSString).appendingPathComponent("Snapshot")
        let targetDir = fm.fileExists(atPath: snapshotPath, isDirectory: &isDir) && isDir.boolValue ? snapshotPath : path

        guard let subdirs = try? fm.contentsOfDirectory(atPath: targetDir) else { return nil }
        var newestFileID: String?
        var newestDate: Date?

        // Check a bounded sample of recent entries without doing an exhaustive recursive walk
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

    /// Sanitize an interrupted backup folder before resuming to prevent com.apple.mobilebackup2
    /// and idevicebackup2 / pymobiledevice3 from failing with MBErrorDomain/205 ("cannot parse null plist").
    /// - Checks and cleans up 0-byte or corrupted plist stubs (Status.plist, Info.plist).
    struct SanitizeResult: Sendable, Equatable {
        let filesScanned: Int
        let filesCleaned: Int
        let walCheckpointed: Bool
    }

    /// Sanitize an interrupted backup folder before resuming to prevent com.apple.mobilebackup2
    /// and idevicebackup2 / pymobiledevice3 from failing with MBErrorDomain/205 ("cannot parse null plist").
    /// - Checks and cleans up 0-byte or corrupted plist stubs (Status.plist, Info.plist).
    /// - Performs SQLite WAL checkpoint and removes stale lock files (Manifest.db-wal, Manifest.db-shm).
    /// - Removes transient staging or temp files.
    @discardableResult
    static func sanitizeIncompleteBackup(at path: String) -> SanitizeResult {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            return SanitizeResult(filesScanned: 0, filesCleaned: 0, walCheckpointed: false)
        }
        // Do not touch a backup that already completed with no leftover WAL/SHM sidecars.
        let walFile = (path as NSString).appendingPathComponent("Manifest.db-wal")
        let shmFile = (path as NSString).appendingPathComponent("Manifest.db-shm")
        if looksLikeBackupFolder(path) && !fm.fileExists(atPath: walFile) && !fm.fileExists(atPath: shmFile) {
            return SanitizeResult(filesScanned: 0, filesCleaned: 0, walCheckpointed: false)
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
                // Execute a quick truncate checkpoint if possible via sqlite3
                var dbPointer: OpaquePointer?
                if sqlite3_open(manifestDbPath, &dbPointer) == SQLITE_OK, let db = dbPointer {
                    var logFrames: Int32 = 0
                    var ckptFrames: Int32 = 0
                    if sqlite3_wal_checkpoint_v2(db, nil, SQLITE_CHECKPOINT_TRUNCATE, &logFrames, &ckptFrames) == SQLITE_OK {
                        walCheckpointed = true
                    }
                    sqlite3_close(db)
                }
                // If WAL is still 0-bytes or leftover, remove it
                if fm.fileExists(atPath: walPath) && !isNonEmptyFile(walPath) {
                    if (try? fm.removeItem(atPath: walPath)) != nil { cleaned += 1 }
                }
                if fm.fileExists(atPath: shmPath) && !isNonEmptyFile(shmPath) {
                    if (try? fm.removeItem(atPath: shmPath)) != nil { cleaned += 1 }
                }
            }
        } else if fm.fileExists(atPath: manifestDbPath) && !isNonEmptyFile(manifestDbPath) {
            scanned += 1
            // A zero-byte Manifest.db will cause sqlite3 / mobilebackup2 to fail
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

        return SanitizeResult(filesScanned: scanned, filesCleaned: cleaned, walCheckpointed: walCheckpointed)
    }
}
