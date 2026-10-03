import Foundation
import Combine
#if canImport(SQLite3)
import SQLite3
#endif

/// Handles iOS backup operations: discovery, creation, browsing, and selective restore.
/// Primary: pymobiledevice3 (supports iOS 17-26+). Fallback: idevicebackup2.
@MainActor
final class BackupManager: ObservableObject {

    @Published var backups: [BackupInfo] = []
    @Published var isCreatingBackup = false
    @Published var backupProgress: String = ""
    @Published var backupPercent: Double = 0
    @Published var lastError: String?
    @Published var lastBackupFailure: BackupFailure?
    @Published var lastOperationWasCancelled = false

    enum RecoveryAction: String, Hashable {
        case resumeBackup
        case runFullBackup
        case deleteIncompleteAndRunFull
        case openBackupSettings
        case retry
    }

    struct BackupFailure: Identifiable, Hashable {
        let id = UUID()
        let title: String
        let message: String
        let technicalDetails: String?
        let recoveryAction: RecoveryAction?
        let udid: String?
        let recoveryPath: String?

        init(
            title: String,
            message: String,
            technicalDetails: String?,
            recoveryAction: RecoveryAction?,
            udid: String? = nil,
            recoveryPath: String? = nil
        ) {
            self.title = title
            self.message = message
            self.technicalDetails = technicalDetails
            self.recoveryAction = recoveryAction
            self.udid = udid
            self.recoveryPath = recoveryPath
        }
    }

    enum BackupMetadataHealth: Equatable {
        case complete
        case missing
        case incomplete(path: String)
    }

    /// Active managed backup session leader for cancellation (#63 replaced
    /// Foundation.Process with a posix_spawn session leader so the whole process
    /// group can be signalled). Ownership is shared across manager instances by
    /// device UDID, allowing different devices to run concurrently without
    /// permitting two writers to operate on the same physical device (#60).
    private static var operationRegistry = BackupOperationRegistry()
    private var activeProcess: Shell.ManagedProcess?
    private var operationCoordinator = BackupDeviceCoordinator()
    private var cancelledOperationIDs: Set<UUID> = []
    private var cancellationDrainTasks: [UUID: Task<Void, Never>] = [:]
    private var applicationTerminationWaiters: [CheckedContinuation<Void, Never>] = []

    private func beginCancellableOperation(udid: String) -> UUID? {
        // Reset before either rejection branch, not between them. With these
        // below the first guard, a contention refusal left the PREVIOUS
        // operation's lastBackupFailure in place, so BackupViewModel.createBackup
        // read it and re-presented a stale "Incomplete Backup Found" recovery
        // sheet - offering "Delete Incomplete Backup and Run Full Backup" in
        // response to an unrelated event, while the real reason sat unread in
        // lastError.
        lastOperationWasCancelled = false
        lastBackupFailure = nil
        guard operationCoordinator.activeOperationID == nil else {
            lastError = "Another backup or restore operation is already running."
            return nil
        }
        guard let operationID = operationCoordinator.begin(
            udid: udid,
            registry: &Self.operationRegistry
        ) else {
            lastError = "Another backup or restore operation is already running for this device."
            return nil
        }
        guard ApplicationTerminationCoordinator.shared.register(self) else {
            _ = operationCoordinator.finish(operationID: operationID, registry: &Self.operationRegistry)
            lastError = "Phosphor is quitting; no new backup or restore can start."
            return nil
        }
        return operationID
    }

    private func operationWasCancelled(_ id: UUID) -> Bool {
        cancelledOperationIDs.contains(id)
    }

    private func awaitCancellationDrain(_ id: UUID) async {
        guard let drain = cancellationDrainTasks[id] else { return }
        await drain.value
        cancellationDrainTasks.removeValue(forKey: id)
    }

    private func finishOperation(_ id: UUID) {
        if operationCoordinator.finish(operationID: id, registry: &Self.operationRegistry) {
            activeProcess = nil
            isCreatingBackup = false
            ApplicationTerminationCoordinator.shared.unregister(self)
            let waiters = applicationTerminationWaiters
            applicationTerminationWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
        cancelledOperationIDs.remove(id)
    }

    private func markOperationCancelled(_ id: UUID, progress: String = "Cancelled") {
        if operationCoordinator.activeOperationID == id {
            lastOperationWasCancelled = true
            backupProgress = progress
            lastError = nil
            lastBackupFailure = nil
        }
        finishOperation(id)
    }

    /// Maximum number of trailing stderr lines to retain for diagnostics on failure.
    private static let stderrTailLineLimit = 20

    /// Device backup/restore subprocesses should eventually complete. Bound them so
    /// a wedged CLI cannot leave backup UI progress and checked continuations stuck forever.
    private static let streamingBackupTimeout: TimeInterval = 6 * 60 * 60
    private static let streamingRestoreTimeout: TimeInterval = 6 * 60 * 60

    /// Lines retained from the most recent pymobiledevice3 stderr stream.
    private var pymobiledeviceStderrTail: [String] = []

    /// Translate a pymobiledevice3 or idevicebackup2 stderr blob into a short actionable hint.
    static func diagnostic(for stderr: String) -> (hint: String?, action: RecoveryAction?) {
        BackupDiagnosticClassifier.diagnostic(for: stderr)
    }

    /// Build a composite error string combining stderr tail and diagnostic hint.
    static func composeFailureMessage(primary: String, stderr: String) -> String {
        BackupDiagnosticClassifier.composeFailureMessage(primary: primary, stderr: stderr)
    }

    static func backupFailure(primary: String, stderr: String, udid: String? = nil, recoveryPath: String? = nil) -> BackupFailure {
        BackupDiagnosticClassifier.backupFailure(primary: primary, stderr: stderr, udid: udid, recoveryPath: recoveryPath)
    }

    /// Preflight check: verify the active backup directory exists and is readable/writable.
    static func validateBackupDirectory(_ path: String, createIfMissing: Bool = true) -> (ok: Bool, reason: String?) {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if !fm.fileExists(atPath: path, isDirectory: &isDir) {
            guard createIfMissing else {
                return (false, "Backup directory does not exist at \(path).")
            }
            do {
                try fm.createDirectory(atPath: path, withIntermediateDirectories: true)
            } catch {
                return (false, "Cannot create backup directory at \(path): \(error.localizedDescription)")
            }
            return (true, nil)
        }
        if !isDir.boolValue {
            return (false, "\(path) exists but is not a directory.")
        }
        if !fm.isReadableFile(atPath: path) || !fm.isWritableFile(atPath: path) {
            let isMobileSync = (path == systemMobileSyncDir)
            var msg = "Phosphor cannot read or write \(path)."
            if isMobileSync {
                msg += """


                This is the system MobileSync directory which macOS protects with TCC.
                Grant Phosphor 'Full Disk Access':
                System Settings -> Privacy & Security -> Full Disk Access -> enable Phosphor, then restart the app.
                Alternatively, pick a different backup directory in Phosphor > Settings (for example ~/Documents/Phosphor Backups).
                """
            }
            return (false, msg)
        }
        return (true, nil)
    }

    static func backupDirectoryWarning(for path: String) -> String? {
        let expanded = (path as NSString).expandingTildeInPath
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let cloudRoots = [
            "\(home)/Library/CloudStorage",
            "\(home)/Library/Mobile Documents",
            "\(home)/Dropbox",
            "\(home)/Google Drive",
            "\(home)/OneDrive",
            "\(home)/SynologyDrive"
        ]
        if cloudRoots.contains(where: { expanded == $0 || expanded.hasPrefix($0 + "/") }) {
            return "Cloud-synced folders are not recommended for live iOS backups. Use a local folder, then sync or export completed backups afterward."
        }
        return nil
    }

    /// Phosphor's default backup location: inside ~/Documents so no special permission
    /// grant is needed, and so Phosphor never shares a directory with Finder's backups
    /// (a misbehaving run could otherwise corrupt the user's Finder backups).
    nonisolated static let defaultBackupDir: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Documents/Phosphor Backups"
    }()

    /// Apple's MobileSync directory. Kept as a named constant so settings UI and
    /// migration logic can offer it to users who explicitly opt in.
    nonisolated static let systemMobileSyncDir: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Library/Application Support/MobileSync/Backup"
    }()

    /// UserDefaults key for the active backup directory.
    nonisolated static let backupDirectoryUserDefaultsKey = "phosphor.backupDirectory"

    /// Active backup directory. Falls back to the default when no override is set.
    nonisolated static var activeBackupDir: String {
        let custom = UserDefaults.standard.string(forKey: backupDirectoryUserDefaultsKey)
        if let custom, !custom.isEmpty {
            return custom
        }
        return defaultBackupDir
    }

    /// One-time migration for users upgrading from <= 1.0.3. Earlier versions defaulted to
    /// the system MobileSync directory without recording the choice in UserDefaults. Rather
    /// than silently orphan their backups when the default flipped to Documents, pin the
    /// MobileSync path as an explicit override if it actually contains Phosphor-visible
    /// backup directories. Safe to call on every launch - the `migrated` flag makes it idempotent.
    static func migrateLegacyBackupDirectory(defaults: UserDefaults = .standard) {
        let migrationKey = "phosphor.backupDirectory.migratedFromMobileSync"
        if defaults.bool(forKey: migrationKey) { return }
        defer { defaults.set(true, forKey: migrationKey) }

        // User already has a chosen directory - nothing to migrate.
        if let existing = defaults.string(forKey: backupDirectoryUserDefaultsKey),
           !existing.isEmpty {
            return
        }

        let fm = FileManager.default
        guard fm.fileExists(atPath: systemMobileSyncDir) else { return }

        // Only pin MobileSync if we can actually read it AND it holds a UDID-shaped backup
        // Info.plist. Otherwise the new Documents default is strictly better.
        let contents = (try? fm.contentsOfDirectory(atPath: systemMobileSyncDir)) ?? []
        let hasBackup = contents.contains { name in
            let info = "\(systemMobileSyncDir)/\(name)/Info.plist"
            return fm.isReadableFile(atPath: info)
        }
        if hasBackup {
            defaults.set(systemMobileSyncDir, forKey: backupDirectoryUserDefaultsKey)
        }
    }

    // MARK: - Discovery

    func discoverBackups(at directory: String? = nil) {
        let dir = directory ?? Self.activeBackupDir
        let result = BackupDiscoveryService.discoverBackups(at: dir)
        self.backups = result.backups
        self.lastError = result.error
    }

    static func isNonEmptyFile(_ path: String) -> Bool {
        BackupDiscoveryService.isNonEmptyFile(path)
    }

    static func looksLikeBackupFolder(_ path: String) -> Bool {
        BackupDiscoveryService.looksLikeBackupFolder(path)
    }

    nonisolated static func backupPath(for udid: String, in directory: String? = nil) -> String {
        let rootDirectory = directory ?? activeBackupDir
        return (rootDirectory as NSString).appendingPathComponent(udid)
    }

    static func backupMetadataHealth(for udid: String, in directory: String? = nil) -> BackupMetadataHealth {
        BackupDiscoveryService.backupMetadataHealth(for: udid, in: directory ?? activeBackupDir)
    }

    /// Incremental backups require an existing valid backup metadata folder for
    /// the target UDID. If the folder is missing or partially-created, both
    /// backup backends fail with low-level MBErrorDomain/205 plist errors.
    static func hasExistingBackup(for udid: String, in directory: String? = nil) -> Bool {
        backupMetadataHealth(for: udid, in: directory) == .complete
    }

    static func incompleteBackupHasKnownMarkers(_ path: String) -> Bool {
        let knownMarkers = ["Info.plist", "Status.plist", "Manifest.plist", "Manifest.db", "Manifest.mbdb"]
        return knownMarkers.contains { marker in
            FileManager.default.fileExists(atPath: (path as NSString).appendingPathComponent(marker))
        }
    }

    static func deleteIncompleteBackup(for udid: String, expectedPath: String? = nil, in directory: String? = nil) throws {
        guard case .incomplete(let path) = backupMetadataHealth(for: udid, in: directory) else { return }
        if let expectedPath, (expectedPath as NSString).standardizingPath != (path as NSString).standardizingPath {
            throw NSError(domain: "Phosphor.Backup", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "The incomplete backup path changed. Refresh backups and try again."
            ])
        }

        let expectedBackupPath = backupPath(for: udid, in: directory)
        guard (path as NSString).standardizingPath == (expectedBackupPath as NSString).standardizingPath else {
            throw NSError(domain: "Phosphor.Backup", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Refusing to delete an unexpected backup path: \(path)"
            ])
        }

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            throw NSError(domain: "Phosphor.Backup", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "Refusing to delete a non-directory backup path: \(path)"
            ])
        }

        guard incompleteBackupHasKnownMarkers(path) else {
            throw NSError(domain: "Phosphor.Backup", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "Refusing to delete \(path) because it does not contain recognizable iOS backup metadata. Delete it manually if you are sure it is safe."
            ])
        }

        var trashedURL: NSURL?
        try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: &trashedURL)
    }

    /// True when the incomplete backup folder contains real payload data (hashed directories/files).
    static func incompleteBackupHasPayloadData(_ path: String) -> Bool {
        BackupDiscoveryService.incompleteBackupHasPayloadData(path)
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

    /// Fast inspect statistics of an interrupted/saved backup folder.
    /// Trustworthiness of a backup's manifest, or nil when it cannot be opened.
    nonisolated static func backupIntegrity(for udid: String, in directory: String? = nil) -> BackupManifest.IntegrityReport? {
        guard let manifest = try? BackupManifest(backupPath: backupPath(for: udid, in: directory)) else {
            return nil
        }
        return manifest.integrityReport()
    }

    nonisolated static func incompleteBackupStats(for udid: String, in directory: String? = nil) -> IncompleteBackupStats? {
        BackupDiscoveryService.incompleteBackupStats(for: udid, in: directory ?? activeBackupDir)
    }

    nonisolated static func sampleActiveDomain(for udid: String, in directory: String? = nil) -> String? {
        BackupDiscoveryService.sampleActiveDomain(for: udid, in: directory ?? activeBackupDir)
    }

    struct SanitizeResult: Sendable, Equatable {
        let filesScanned: Int
        let filesCleaned: Int
        let walCheckpointed: Bool
    }

    @discardableResult
    static func sanitizeIncompleteBackup(at path: String) -> SanitizeResult {
        BackupDiscoveryService.sanitizeIncompleteBackup(at: path)
    }

    // MARK: - Backup Creation

    private func finalizeSuccessfulBackup(
        udid: String,
        directory: String,
        operationID: UUID,
        onProgress: @escaping (String) -> Void
    ) -> Bool {
        switch Self.backupMetadataHealth(for: udid, in: directory) {
        case .complete:
            finishOperation(operationID)
            backupProgress = "Backup complete"
            backupPercent = 1.0
            discoverBackups(at: directory)
            onProgress("Backup complete")
            return true
        case .missing:
            let path = Self.backupPath(for: udid, in: directory)
            finishOperation(operationID)
            backupProgress = "Backup metadata incomplete"
            lastBackupFailure = BackupFailure(
                title: "Backup Metadata Incomplete",
                message: "The backup command finished, but Phosphor could not find complete backup metadata. Run a fresh full backup with the device unlocked and connected over USB when possible.",
                technicalDetails: path,
                recoveryAction: .runFullBackup,
                udid: udid,
                recoveryPath: path
            )
            lastError = lastBackupFailure?.message
            onProgress(lastError ?? "Backup metadata incomplete.")
            return false
        case .incomplete(let path):
            let hasPayload = Self.incompleteBackupHasPayloadData(path)
            finishOperation(operationID)
            backupProgress = "Backup metadata incomplete"
            let recoveryAction: RecoveryAction = hasPayload ? .resumeBackup : .deleteIncompleteAndRunFull
            let message = hasPayload
                ? "The backup command finished, but the resulting backup metadata is incomplete. You can resume to complete remaining files, or move the folder to Trash and start fresh."
                : "The backup command finished, but the resulting backup metadata is incomplete. Move the incomplete folder to Trash, then run a fresh full backup with the device unlocked and connected over USB when possible."
            // Without the tool output this failure is undiagnosable: the device
            // console is the only place the resume's actual errors live, and the
            // generic metadata message intentionally explains none of them.
            let stderrTail = pymobiledeviceStderrTail.joined(separator: "\n")
            lastBackupFailure = BackupFailure(
                title: "Backup Metadata Incomplete",
                message: message,
                technicalDetails: stderrTail.isEmpty ? path : "\(path)\n\n\(stderrTail)",
                recoveryAction: recoveryAction,
                udid: udid,
                recoveryPath: path
            )
            lastError = lastBackupFailure?.message
            onProgress(lastError ?? "Backup metadata incomplete.")
            return false
        }
    }

    /// Create a new backup. pymobiledevice3 primary, idevicebackup2 fallback.
    func createBackup(
        udid: String,
        encrypted: Bool = false,
        preferNetwork: Bool = false,
        onProgress: @escaping (String) -> Void
    ) async -> Bool {
        // Per-device ownership first (#60): if another owner already holds this
        // UDID we must not take the comparison gate on its behalf.
        guard let operationID = beginCancellableOperation(udid: udid) else { return false }
        let backupRoot = Self.activeBackupDir
        // Then the reader/writer gate (#70). beginBackup preempts any in-flight
        // comparison rather than being refused by one, so this always succeeds.
        let coordinatorToken = BackupOperationCoordinator.shared.beginBackup()
        defer {
            if let coordinatorToken { BackupOperationCoordinator.shared.endBackup(coordinatorToken) }
        }
        isCreatingBackup = true
        backupProgress = "Starting backup..."
        backupPercent = 0
        lastError = nil
        lastBackupFailure = nil

        // Preflight: bail early with a clear message when the directory is unreadable
        // (most commonly a Full Disk Access grant missing on the default location).
        let preflight = Self.validateBackupDirectory(backupRoot)
        if !preflight.ok {
            finishOperation(operationID)
            backupProgress = "Backup failed"
            lastError = preflight.reason
            lastBackupFailure = BackupFailure(
                title: "Backup Folder Not Accessible",
                message: preflight.reason ?? "Phosphor cannot read or write the selected backup folder.",
                technicalDetails: backupRoot,
                recoveryAction: .openBackupSettings,
                udid: udid,
                recoveryPath: backupRoot
            )
            onProgress(preflight.reason ?? "Backup directory is not accessible.")
            return false
        }

        if case .incomplete(let path) = Self.backupMetadataHealth(for: udid, in: backupRoot) {
            let hasPayload = Self.incompleteBackupHasPayloadData(path)
            finishOperation(operationID)
            backupProgress = "Incomplete backup found"
            let recoveryAction: RecoveryAction = hasPayload ? .resumeBackup : .deleteIncompleteAndRunFull
            let message = hasPayload
                ? "An interrupted backup with existing files was found for this device. You can resume this backup to transfer only remaining files, or delete it and start fresh."
                : "A previous backup for this device did not finish, so iOS may reject another backup in this folder. Delete the incomplete folder, then run a full backup again."
            lastBackupFailure = BackupFailure(
                title: "Incomplete Backup Found",
                message: message,
                technicalDetails: path,
                recoveryAction: recoveryAction,
                udid: udid,
                recoveryPath: path
            )
            lastError = lastBackupFailure?.message
            onProgress(lastError ?? "Incomplete backup found.")
            return false
        }

        if operationWasCancelled(operationID) {
            markOperationCancelled(operationID)
            return false
        }

        // Primary: pymobiledevice3
        let pySuccess = await createBackupViaPymobiledevice(
            udid: udid,
            directory: backupRoot,
            full: true,
            preferNetwork: preferNetwork,
            operationID: operationID,
            onProgress: onProgress
        )
        if pySuccess {
            return finalizeSuccessfulBackup(udid: udid, directory: backupRoot, operationID: operationID, onProgress: onProgress)
        }
        if operationWasCancelled(operationID) {
            markOperationCancelled(operationID)
            return false
        }

        let pymobiledeviceStderr = pymobiledeviceStderrTail.joined(separator: "\n")
        let lowerStderr = pymobiledeviceStderr.lowercased()

        // If pymobiledevice3 timed out or failed due to passcode/pairing dismissal or RemoteXPC/iOS17+ requirement,
        // do not fall back into idevicebackup2 which cannot succeed and risks locking USB/lockdownd.
        let shouldInhibitFallback = lowerStderr.contains("timed out")
            || lowerStderr.contains("remotexpc")
            || lowerStderr.contains("invalidservice")
            || lowerStderr.contains("passcodesetuprequired")

        if shouldInhibitFallback {
            finishOperation(operationID)
            backupProgress = "Backup failed"
            let primaryMessage = lowerStderr.contains("timed out")
                ? "Backup timed out."
                : "Backup failed via pymobiledevice3."
            let failure = Self.backupFailure(
                primary: primaryMessage,
                stderr: pymobiledeviceStderr,
                udid: udid,
                recoveryPath: Self.backupPath(for: udid, in: backupRoot)
            )
            self.lastBackupFailure = failure
            self.lastError = Self.composeFailureMessage(
                primary: primaryMessage,
                stderr: pymobiledeviceStderr
            )
            return false
        }

        // Fallback: idevicebackup2
        let fallbackReason = pymobiledeviceStderr.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n").last ?? "pymobiledevice3 failed"
        onProgress("Fallback: \(fallbackReason)")
        backupProgress = "Backing up..."

        let args = idevicebackupArguments(udid: udid, directory: backupRoot, full: true, preferNetwork: preferNetwork)
        var idevicebackupStderr = ""

        return await withCheckedContinuation { continuation in
            guard !operationWasCancelled(operationID) else {
                markOperationCancelled(operationID)
                continuation.resume(returning: false)
                return
            }
            activeProcess = Shell.runStreaming(
                "idevicebackup2",
                arguments: args,
                timeout: Self.streamingBackupTimeout,
                onOutput: { [weak self] output in
                    let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
                    self?.backupProgress = trimmed
                    if let pct = PyMobileDevice.parseProgress(from: trimmed) {
                        self?.backupPercent = pct
                    }
                    onProgress(output)
                },
                onError: { error in
                    idevicebackupStderr.append(error)
                },
                completion: { [weak self] exitCode in
                    Task { @MainActor in
                        guard let self else {
                            continuation.resume(returning: false)
                            return
                        }
                        if self.operationWasCancelled(operationID) {
                            await self.awaitCancellationDrain(operationID)
                            self.markOperationCancelled(operationID)
                            continuation.resume(returning: false)
                            return
                        }
                        if exitCode == 0 {
                            let verified = self.finalizeSuccessfulBackup(udid: udid, directory: backupRoot, operationID: operationID, onProgress: onProgress)
                            continuation.resume(returning: verified)
                            return
                        } else {
                            let combinedStderr = [pymobiledeviceStderr, idevicebackupStderr]
                                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                                .joined(separator: "\n---\n")
                            self.finishOperation(operationID)
                            self.backupProgress = "Backup failed"
                            let failure = Self.backupFailure(
                                primary: "Both backup methods failed.",
                                stderr: combinedStderr,
                                udid: udid,
                                recoveryPath: Self.backupPath(for: udid, in: backupRoot)
                            )
                            self.lastBackupFailure = failure
                            self.lastError = Self.composeFailureMessage(
                                primary: "Both backup methods failed.",
                                stderr: combinedStderr
                            )
                        }
                        continuation.resume(returning: false)
                    }
                }
            )
        }
    }

    private func idevicebackupArguments(udid: String, directory: String, full: Bool, preferNetwork: Bool) -> [String] {
        var args = ["-u", udid]
        if preferNetwork { args.append("-n") }
        args.append("backup")
        if full { args.append("--full") }
        args.append(directory)
        return args
    }

    /// Backup using pymobiledevice3.
    private func createBackupViaPymobiledevice(
        udid: String,
        directory: String,
        full: Bool,
        preferNetwork: Bool,
        configuration: DeviceBackupConfiguration? = nil,
        operationID: UUID,
        onProgress: @escaping (String) -> Void
    ) async -> Bool {
    // Use configuration as local variable for backward compatibility
    let configuration = configuration
        // Entering this async helper is an actor suspension point. Quit may request
        // cancellation after ownership is acquired but before a child is assigned.
        guard !operationWasCancelled(operationID) else { return false }
        guard PyMobileDevice.available() else {
            lastError = "pymobiledevice3 not installed. Install with: pipx install pymobiledevice3"
            return false
        }

        // Generate domain preservation regex from configuration
        let onlyRegex: [String]? = {
            guard let config = configuration else { return nil }
            return config.profileType.preservationRegex(
                customDomains: config.customIncludedDomains,
                excludedBundleIds: config.excludedBundleIds,
                excludeMediaFiles: config.excludeMediaAbove50MB,
                excludeAppCaches: config.excludeAppCaches,
                excludedFilePatterns: config.excludedFilePatterns,
                excludedRelativePaths: config.excludedRelativePaths
            )
        }()

        backupProgress = "Backing up..."
        onProgress("Backing up")
        pymobiledeviceStderrTail.removeAll()

        return await withCheckedContinuation { continuation in
            guard !operationWasCancelled(operationID) else {
                continuation.resume(returning: false)
                return
            }
            activeProcess = PyMobileDevice.backup(
                directory: directory,
                udid: udid,
                full: full,
                preferNetwork: preferNetwork,
                onlyRegex: onlyRegex,
                patchManifest: onlyRegex != nil && !onlyRegex!.isEmpty,
                timeout: Self.streamingBackupTimeout,
                onOutput: { [weak self] output in
                    let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        self?.backupProgress = trimmed
                        if let pct = PyMobileDevice.parseProgress(from: trimmed) {
                            self?.backupPercent = pct
                        }
                        onProgress(trimmed)
                    }
                },
                onError: { [weak self] error in
                    let trimmed = error.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    // pymobiledevice3 sends progress on stderr.
                    if let pct = PyMobileDevice.parseProgress(from: trimmed) {
                        self?.backupPercent = pct
                        self?.backupProgress = trimmed
                        onProgress(trimmed)
                        return
                    }
                    // Retain non-progress stderr lines so a failure surfaces the real reason.
                    guard let self else { return }
                    for line in trimmed.components(separatedBy: "\n") {
                        let l = line.trimmingCharacters(in: .whitespacesAndNewlines)
                        if l.isEmpty { continue }
                        let lower = l.lowercased()
                        if lower.contains("passcode") || lower.contains("pin") || lower.contains("trust") || lower.contains("unlock") || lower.contains("pair") {
                            self.backupProgress = l
                            onProgress(l)
                        }
                        self.pymobiledeviceStderrTail.append(l)
                        if self.pymobiledeviceStderrTail.count > Self.stderrTailLineLimit {
                            self.pymobiledeviceStderrTail.removeFirst(
                                self.pymobiledeviceStderrTail.count - Self.stderrTailLineLimit
                            )
                        }
                    }
                },
                completion: { [weak self] exitCode in
                    Task { @MainActor in
                        guard let self else {
                            continuation.resume(returning: false)
                            return
                        }
                        if self.operationCoordinator.activeOperationID == operationID {
                            self.activeProcess = nil
                        }
                        if self.operationWasCancelled(operationID) {
                            await self.awaitCancellationDrain(operationID)
                            continuation.resume(returning: false)
                            return
                        }
                        continuation.resume(returning: exitCode == 0)
                    }
                }
            )
        }
    }

    /// Create an incremental backup (only changed files).
    func createIncrementalBackup(
        udid: String,
        preferNetwork: Bool = false,
        onProgress: @escaping (String) -> Void
    ) async -> Bool {
        // Per-device ownership first (#60): if another owner already holds this
        // UDID we must not take the comparison gate on its behalf.
        guard let operationID = beginCancellableOperation(udid: udid) else { return false }
        let backupRoot = Self.activeBackupDir
        // Then the reader/writer gate (#70). beginBackup preempts any in-flight
        // comparison rather than being refused by one, so this always succeeds.
        let coordinatorToken = BackupOperationCoordinator.shared.beginBackup()
        defer {
            if let coordinatorToken { BackupOperationCoordinator.shared.endBackup(coordinatorToken) }
        }
        isCreatingBackup = true
        backupProgress = "Starting incremental backup..."
        backupPercent = 0
        lastError = nil
        lastBackupFailure = nil

        let preflight = Self.validateBackupDirectory(backupRoot)
        if !preflight.ok {
            finishOperation(operationID)
            backupProgress = "Backup failed"
            lastError = preflight.reason
            lastBackupFailure = BackupFailure(
                title: "Backup Folder Not Accessible",
                message: preflight.reason ?? "Phosphor cannot read or write the selected backup folder.",
                technicalDetails: backupRoot,
                recoveryAction: .openBackupSettings,
                udid: udid,
                recoveryPath: backupRoot
            )
            onProgress(preflight.reason ?? "Backup directory is not accessible.")
            return false
        }

        switch Self.backupMetadataHealth(for: udid, in: backupRoot) {
        case .complete:
            break
        case .missing:
            finishOperation(operationID)
            backupProgress = "Backup needs a full backup first"
            lastBackupFailure = BackupFailure(
                title: "Full Backup Required",
                message: "No complete backup exists for this device yet. Run a full backup first; future Wi-Fi backups can be incremental.",
                technicalDetails: Self.backupPath(for: udid, in: backupRoot),
                recoveryAction: .runFullBackup,
                udid: udid,
                recoveryPath: Self.backupPath(for: udid, in: backupRoot)
            )
            lastError = lastBackupFailure?.message
            onProgress(lastError ?? "Run a full backup first.")
            return false
        case .incomplete(let path):
            let hasPayload = Self.incompleteBackupHasPayloadData(path)
            finishOperation(operationID)
            backupProgress = "Incomplete backup found"
            let recoveryAction: RecoveryAction = hasPayload ? .resumeBackup : .deleteIncompleteAndRunFull
            let message = hasPayload
                ? "An interrupted backup with existing files was found for this device. You can resume this backup to transfer only remaining files, or delete it and start fresh."
                : "A previous backup for this device did not finish. Delete the incomplete folder, then run a full backup again."
            lastBackupFailure = BackupFailure(
                title: "Incomplete Backup Found",
                message: message,
                technicalDetails: path,
                recoveryAction: recoveryAction,
                udid: udid,
                recoveryPath: path
            )
            lastError = lastBackupFailure?.message
            onProgress(lastError ?? "Incomplete backup found.")
            return false
        }

        if operationWasCancelled(operationID) {
            markOperationCancelled(operationID)
            return false
        }

        // Primary: pymobiledevice3 (without --full flag)
        if PyMobileDevice.available() {
            let success = await createBackupViaPymobiledevice(
                udid: udid,
                directory: backupRoot,
                full: false,
                preferNetwork: preferNetwork,
                operationID: operationID,
                onProgress: onProgress
            )
            if success {
                return finalizeSuccessfulBackup(udid: udid, directory: backupRoot, operationID: operationID, onProgress: onProgress)
            }
            if operationWasCancelled(operationID) {
                markOperationCancelled(operationID)
                return false
            }
        }

        let pymobiledeviceStderr = pymobiledeviceStderrTail.joined(separator: "\n")
        let lowerStderr = pymobiledeviceStderr.lowercased()

        // If pymobiledevice3 timed out or failed due to passcode/pairing dismissal or RemoteXPC/iOS17+ requirement,
        // do not fall back into idevicebackup2 which cannot succeed and risks locking USB/lockdownd.
        let shouldInhibitFallback = lowerStderr.contains("timed out")
            || lowerStderr.contains("remotexpc")
            || lowerStderr.contains("invalidservice")
            || lowerStderr.contains("passcodesetuprequired")

        if shouldInhibitFallback {
            finishOperation(operationID)
            backupProgress = "Backup failed"
            let primaryMessage = lowerStderr.contains("timed out")
                ? "Incremental backup timed out."
                : "Incremental backup failed via pymobiledevice3."
            let failure = Self.backupFailure(
                primary: primaryMessage,
                stderr: pymobiledeviceStderr,
                udid: udid,
                recoveryPath: Self.backupPath(for: udid, in: backupRoot)
            )
            self.lastBackupFailure = failure
            self.lastError = Self.composeFailureMessage(
                primary: primaryMessage,
                stderr: pymobiledeviceStderr
            )
            return false
        }

        var idevicebackupStderr = ""

        // Fallback: idevicebackup2
        let fallbackReason = pymobiledeviceStderr.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n").last ?? "pymobiledevice3 failed"
        onProgress("Fallback: \(fallbackReason)")
        return await withCheckedContinuation { continuation in
            guard !operationWasCancelled(operationID) else {
                markOperationCancelled(operationID)
                continuation.resume(returning: false)
                return
            }
            activeProcess = Shell.runStreaming(
                "idevicebackup2",
                arguments: idevicebackupArguments(udid: udid, directory: backupRoot, full: false, preferNetwork: preferNetwork),
                timeout: Self.streamingBackupTimeout,
                onOutput: { [weak self] output in
                    let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
                    self?.backupProgress = trimmed
                    if let pct = PyMobileDevice.parseProgress(from: trimmed) {
                        self?.backupPercent = pct
                    }
                    onProgress(output)
                },
                onError: { error in
                    idevicebackupStderr.append(error)
                },
                completion: { [weak self] exitCode in
                    Task { @MainActor in
                        guard let self else {
                            continuation.resume(returning: false)
                            return
                        }
                        if self.operationWasCancelled(operationID) {
                            await self.awaitCancellationDrain(operationID)
                            self.markOperationCancelled(operationID)
                            continuation.resume(returning: false)
                            return
                        }
                        if exitCode == 0 {
                            let verified = self.finalizeSuccessfulBackup(udid: udid, directory: backupRoot, operationID: operationID, onProgress: onProgress)
                            continuation.resume(returning: verified)
                            return
                        } else {
                            let combinedStderr = [pymobiledeviceStderr, idevicebackupStderr]
                                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                                .joined(separator: "\n---\n")
                            self.finishOperation(operationID)
                            self.backupProgress = "Backup failed"
                            let failure = Self.backupFailure(
                                primary: "Incremental backup failed via both backends.",
                                stderr: combinedStderr,
                                udid: udid,
                                recoveryPath: Self.backupPath(for: udid, in: backupRoot)
                            )
                            self.lastBackupFailure = failure
                            self.lastError = Self.composeFailureMessage(
                                primary: "Incremental backup failed via both backends.",
                                stderr: combinedStderr
                            )
                        }
                        continuation.resume(returning: false)
                    }
                }
            )
        }
    }

    /// Resume an incomplete backup by sanitizing any corrupted plists or uncheckpointed
    /// WAL journals first, then invoking the backup runner so iOS can delta-verify
    /// already-transferred files and only stream remaining chunks.
    func resumeIncompleteBackup(
        udid: String,
        encrypted: Bool = false,
        preferNetwork: Bool = false,
        onProgress: @escaping (String) -> Void
    ) async -> Bool {
        guard let operationID = beginCancellableOperation(udid: udid) else { return false }
        let backupRoot = Self.activeBackupDir
        let coordinatorToken = BackupOperationCoordinator.shared.beginBackup()
        defer {
            if let coordinatorToken { BackupOperationCoordinator.shared.endBackup(coordinatorToken) }
        }
        isCreatingBackup = true
        backupProgress = "Preparing to resume backup..."
        backupPercent = 0
        lastError = nil
        lastBackupFailure = nil

        let preflight = Self.validateBackupDirectory(backupRoot)
        if !preflight.ok {
            finishOperation(operationID)
            backupProgress = "Backup failed"
            lastError = preflight.reason
            lastBackupFailure = BackupFailure(
                title: "Backup Folder Not Accessible",
                message: preflight.reason ?? "Phosphor cannot read or write the selected backup folder.",
                technicalDetails: backupRoot,
                recoveryAction: .openBackupSettings,
                udid: udid,
                recoveryPath: backupRoot
            )
            onProgress(preflight.reason ?? "Backup directory is not accessible.")
            return false
        }

        let targetPath = Self.backupPath(for: udid, in: backupRoot)
        // Perform pre-resume sanitization to remove 0-byte/corrupted plists and checkpoint SQLite WAL.
        let sanitizeResult = Self.sanitizeIncompleteBackup(at: targetPath)
        onProgress("Sanitizing: \(sanitizeResult.filesScanned) scanned, \(sanitizeResult.filesCleaned) cleaned, wal: \(sanitizeResult.walCheckpointed)")

        if operationWasCancelled(operationID) {
            markOperationCancelled(operationID)
            return false
        }

        backupProgress = "Resuming backup..."
        onProgress("Resuming backup...")

        // Primary: pymobiledevice3 without --full flag to allow delta resumption
        if PyMobileDevice.available() {
            let pySuccess = await createBackupViaPymobiledevice(
                udid: udid,
                directory: backupRoot,
                full: false,
                preferNetwork: preferNetwork,
                operationID: operationID,
                onProgress: onProgress
            )
            if pySuccess {
                return finalizeSuccessfulBackup(udid: udid, directory: backupRoot, operationID: operationID, onProgress: onProgress)
            }
            if operationWasCancelled(operationID) {
                markOperationCancelled(operationID)
                return false
            }
        }

        let pymobiledeviceStderr = pymobiledeviceStderrTail.joined(separator: "\n")
        let fallbackReason = pymobiledeviceStderr.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n").last ?? "pymobiledevice3 failed"
        onProgress("Fallback: \(fallbackReason)")

        // Fallback: idevicebackup2 without --full flag
        let args = idevicebackupArguments(udid: udid, directory: backupRoot, full: false, preferNetwork: preferNetwork)
        var idevicebackupStderr = ""

        return await withCheckedContinuation { continuation in
            guard !operationWasCancelled(operationID) else {
                markOperationCancelled(operationID)
                continuation.resume(returning: false)
                return
            }
            activeProcess = Shell.runStreaming(
                "idevicebackup2",
                arguments: args,
                timeout: Self.streamingBackupTimeout,
                onOutput: { [weak self] output in
                    let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
                    self?.backupProgress = trimmed
                    if let pct = PyMobileDevice.parseProgress(from: trimmed) {
                        self?.backupPercent = pct
                    }
                    onProgress(output)
                },
                onError: { error in
                    idevicebackupStderr.append(error)
                },
                completion: { [weak self] exitCode in
                    Task { @MainActor in
                        guard let self else {
                            continuation.resume(returning: false)
                            return
                        }
                        if self.operationWasCancelled(operationID) {
                            await self.awaitCancellationDrain(operationID)
                            self.markOperationCancelled(operationID)
                            continuation.resume(returning: false)
                            return
                        }
                        if exitCode == 0 {
                            let verified = self.finalizeSuccessfulBackup(udid: udid, directory: backupRoot, operationID: operationID, onProgress: onProgress)
                            continuation.resume(returning: verified)
                            return
                        } else {
                            let combinedStderr = [pymobiledeviceStderr, idevicebackupStderr]
                                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                                .joined(separator: "\n---\n")
                            self.finishOperation(operationID)
                            self.backupProgress = "Backup failed"
                            let failure = Self.backupFailure(
                                primary: "Resume backup failed via both backends.",
                                stderr: combinedStderr,
                                udid: udid,
                                recoveryPath: Self.backupPath(for: udid, in: backupRoot)
                            )
                            self.lastBackupFailure = failure
                            self.lastError = Self.composeFailureMessage(
                                primary: "Resume backup failed via both backends.",
                                stderr: combinedStderr
                            )
                        }
                        continuation.resume(returning: false)
                    }
                }
            )
        }
    }

    // MARK: - Restore

    /// Restore a backup to a device. pymobiledevice3 primary, idevicebackup2 fallback.
    func restoreBackup(
        backup: BackupInfo,
        targetUDID: String,
        onProgress: @escaping (String) -> Void
    ) async -> Bool {
        // Both backends open `backupRoot/<source>`, so the source has to be the
        // folder name on disk. It is NOT backup.udid: that comes from Info.plist's
        // "Target Identifier", and timestamped or imported backup folders routinely
        // have a directory name that differs from it. Deriving both halves from
        // backup.path keeps `backupRoot + source == backup.path` true by construction,
        // which is what stops a restore from silently targeting another snapshot.
        let backupRoot = (backup.path as NSString).deletingLastPathComponent
        let sourceIdentifier = (backup.path as NSString).lastPathComponent
        guard !sourceIdentifier.isEmpty, !backupRoot.isEmpty else {
            lastError = "Cannot restore: \(backup.path) is not a backup folder inside a backup directory."
            return false
        }

        guard let operationID = beginCancellableOperation(udid: targetUDID) else { return false }
        if operationWasCancelled(operationID) {
            markOperationCancelled(operationID, progress: "Restore cancelled")
            return false
        }

        let success = await BackupRestoreService.executeRestore(
            backup: backup,
            targetUDID: targetUDID,
            onProcessSpawned: { [weak self] proc in
                Task { @MainActor in self?.activeProcess = proc }
            },
            isCancelled: { [weak self] in
                self?.operationWasCancelled(operationID) == true
            },
            onProgress: onProgress
        )

        if operationWasCancelled(operationID) {
            await awaitCancellationDrain(operationID)
            markOperationCancelled(operationID, progress: "Restore cancelled")
            return false
        }
        finishOperation(operationID)
        return success
    }

    /// Cancel an active backup/restore.
    func cancelBackup() {
        if let activeOperationID = operationCoordinator.activeOperationID {
            cancelledOperationIDs.insert(activeOperationID)
            if let activeProcess, cancellationDrainTasks[activeOperationID] == nil {
                // Fast cancel for pause/save: SIGTERM with grace window, then clean reap
                cancellationDrainTasks[activeOperationID] = Task {
                    await Shell.cancelAndWait(activeProcess)
                }
            }
        }
        lastOperationWasCancelled = true
        lastError = nil
        lastBackupFailure = nil
        backupProgress = "Cancelled"
    }

    /// Cancel this manager's current process tree and do not return until both
    /// process-group cleanup and the operation completion callback have finished.
    func cancelForApplicationTermination() async {
        guard let activeOperationID = operationCoordinator.activeOperationID else { return }
        cancelledOperationIDs.insert(activeOperationID)
        lastOperationWasCancelled = true
        lastError = nil
        lastBackupFailure = nil

        if let activeProcess {
            await Shell.terminateAndWait(activeProcess)
        }

        guard operationCoordinator.activeOperationID != nil else { return }
        await withCheckedContinuation { continuation in
            applicationTerminationWaiters.append(continuation)
        }
    }

    // MARK: - Backup Browsing

    func openManifest(for backup: BackupInfo) -> BackupManifest? {
        do {
            return try BackupManifest(backupPath: backup.path)
        } catch {
            lastError = "Failed to open backup manifest: \(error.localizedDescription)"
            return nil
        }
    }

    // MARK: - Selective Extract

    func extractFiles(
        from backup: BackupInfo,
        entries: [BackupManifest.FileEntry],
        to destination: String
    ) throws -> Int {
        try BackupExtractionService.extractFiles(from: backup, entries: entries, to: destination) { [weak self] errorMsg in
            self?.lastError = errorMsg
        }
    }

    func extractDomain(
        from backup: BackupInfo,
        domain: String,
        to destination: String
    ) throws -> Int {
        try BackupExtractionService.extractDomain(from: backup, domain: domain, to: destination) { [weak self] errorMsg in
            self?.lastError = errorMsg
        }
    }

    // MARK: - Encryption

    func enableEncryption(udid: String, password: String) async -> Bool {
        let (success, error) = await BackupEncryptionService.setBackupEncryption(udid: udid, enabled: true, password: password)
        if !success { lastError = error }
        return success
    }

    func disableEncryption(udid: String, password: String) async -> Bool {
        let (success, error) = await BackupEncryptionService.setBackupEncryption(udid: udid, enabled: false, password: password)
        if !success { lastError = error }
        return success
    }

    func changeEncryptionPassword(udid: String, oldPassword: String, newPassword: String) async -> Bool {
        let (success, error) = await BackupEncryptionService.changeEncryptionPassword(udid: udid, oldPassword: oldPassword, newPassword: newPassword)
        if !success { lastError = error }
        return success
    }

    func isEncryptionEnabled(udid: String) async -> Bool {
        await BackupEncryptionService.isEncryptionEnabled(udid: udid)
    }

    // MARK: - Cleanup

    func deleteBackup(_ backup: BackupInfo) throws {
        try FileManager.default.removeItem(atPath: backup.path)
        backups.removeAll { $0.id == backup.id }
    }

    var totalBackupSize: UInt64 {
        backups.reduce(0) { $0 + $1.size }
    }
}
