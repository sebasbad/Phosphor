import Foundation

/// Classifies stderr and exit codes from pymobiledevice3 / idevicebackup2 into actionable diagnoses.
enum BackupDiagnosticClassifier {

    /// Translate a pymobiledevice3 or idevicebackup2 stderr blob into a short actionable hint.
    static func diagnostic(for stderr: String) -> (hint: String?, action: BackupManager.RecoveryAction?) {
        let lower = stderr.lowercased()
        if lower.contains("not paired") || lower.contains("pairingdialogresponsepending") || lower.contains("trust this computer") {
            return ("Device is not trusted. Unlock it and tap 'Trust' when prompted, then try again.", .retry)
        }
        if lower.contains("passcodesetuprequired") || lower.contains("setpasscode") {
            return ("Set a passcode on the device before running an encrypted backup.", .retry)
        }
        if lower.contains("no device found") || lower.contains("no devices connected") {
            return ("No device detected. Reconnect the cable and ensure the device is unlocked.", .retry)
        }
        if lower.contains("backupdomainoverridden") || lower.contains("mobilebackup2error") {
            return ("iOS rejected the backup request. Disable/re-enable encryption or reboot the device.", .retry)
        }
        if lower.contains("modulenotfounderror") || lower.contains("no module named") {
            return ("pymobiledevice3 is installed but missing dependencies. Reinstall with: pipx reinstall pymobiledevice3", nil)
        }
        if lower.contains("invalidservice") || lower.contains("remotexpc") || lower.contains("tunneld") {
            return ("Backup requires an up-to-date pymobiledevice3. Upgrade with: pipx upgrade pymobiledevice3", .retry)
        }
        if lower.contains("zero-length") || lower.contains("cannot parse a null") || lower.contains("mberrordomain/205") || lower.contains("error reading backup properties") {
            return ("The existing backup metadata appears incomplete or corrupt. Delete the incomplete backup or choose a fresh local backup folder, then run a full backup with the device unlocked.", .deleteIncompleteAndRunFull)
        }
        if lower.contains("mberrordomain/208") || lower.contains("device locked") {
            return ("Device is locked or display went to sleep. Unlock the device with passcode, set Auto-Lock to Never in Settings, and try again.", .retry)
        }
        if lower.contains("is not readable") || lower.contains("permission denied") || lower.contains("operation not permitted") {
            return ("""
            macOS is blocking access to the backup directory. The easiest fix is to switch Phosphor's backup directory to a user-owned location:
            Phosphor -> Settings -> Backup Directory -> ~/Documents/Phosphor Backups.
            Only if you specifically want Phosphor to read Apple's shared MobileSync backups do you need to grant Full Disk Access (System Settings -> Privacy & Security -> Full Disk Access). Full Disk Access is not recommended - Phosphor does not need it for its own backups.
            """, .openBackupSettings)
        }
        if lower.contains("timed out") {
            return ("Backup operation timed out. For large backups, ensure a stable high-speed USB connection and keep the device awake.", .retry)
        }
        return (nil, nil)
    }

    /// Build a composite error string combining stderr tail and diagnostic hint.
    static func composeFailureMessage(primary: String, stderr: String) -> String {
        let failure = backupFailure(primary: primary, stderr: stderr)
        return [failure.title, failure.message, failure.technicalDetails.map { "Details:\n\($0)" }]
            .compactMap { $0 }
            .joined(separator: "\n\n")
    }

    static func backupFailure(primary: String, stderr: String, udid: String? = nil, recoveryPath: String? = nil) -> BackupManager.BackupFailure {
        let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let diag = diagnostic(for: trimmed)
        let hint = diag.hint
        let action = diag.action

        let message: String
        if let hint {
            message = "\(primary)\n\n\(hint)"
        } else {
            message = primary
        }

        let technicalDetails = trimmed.isEmpty ? nil : trimmed

        return BackupManager.BackupFailure(
            title: "Backup Failed",
            message: message,
            technicalDetails: technicalDetails,
            recoveryAction: action,
            udid: udid,
            recoveryPath: recoveryPath
        )
    }
}
