import Foundation

/// Handles device restore operations over MobileBackup2 protocol via pymobiledevice3 or idevicebackup2.
actor BackupRestoreService {
    static let streamingRestoreTimeout: TimeInterval = 7200 // 2 hours for large restores

    static func executeRestore(
        backup: BackupInfo,
        targetUDID: String,
        onProcessSpawned: @escaping (Shell.ManagedProcess) -> Void,
        isCancelled: @escaping () -> Bool,
        onProgress: @escaping (String) -> Void
    ) async -> Bool {
        let backupRoot = (backup.path as NSString).deletingLastPathComponent
        let sourceIdentifier = (backup.path as NSString).lastPathComponent
        guard !sourceIdentifier.isEmpty, !backupRoot.isEmpty else {
            return false
        }

        if isCancelled() { return false }

        // Primary: pymobiledevice3
        if PyMobileDevice.available() {
            return await withCheckedContinuation { continuation in
                guard !isCancelled() else {
                    continuation.resume(returning: false)
                    return
                }
                if let proc = PyMobileDevice.restore(
                    directory: backupRoot,
                    udid: targetUDID,
                    sourceUDID: sourceIdentifier,
                    timeout: streamingRestoreTimeout,
                    onOutput: { output in onProgress(output) },
                    completion: { exitCode in
                        continuation.resume(returning: exitCode == 0)
                    }
                ) {
                    onProcessSpawned(proc)
                } else {
                    continuation.resume(returning: false)
                }
            }
        }

        // Fallback: idevicebackup2
        return await withCheckedContinuation { continuation in
            guard !isCancelled() else {
                continuation.resume(returning: false)
                return
            }
            if let proc = Shell.runStreaming(
                "idevicebackup2",
                arguments: ["-u", targetUDID, "-s", sourceIdentifier, "restore", "--system", "--reboot", backupRoot],
                timeout: streamingRestoreTimeout,
                onOutput: { output in onProgress(output) },
                onError: { _ in },
                completion: { exitCode in
                    continuation.resume(returning: exitCode == 0)
                }
            ) {
                onProcessSpawned(proc)
            } else {
                continuation.resume(returning: false)
            }
        }
    }
}
