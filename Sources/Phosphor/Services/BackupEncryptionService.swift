import Foundation

/// Handles device backup encryption password changes and status checks via idevicebackup2 / pymobiledevice3.
enum BackupEncryptionService {

    /// Toggle backup encryption without leaking the password through argv.
    static func setBackupEncryption(udid: String, enabled: Bool, password: String) async -> (success: Bool, error: String?) {
        let mode = enabled ? "on" : "off"
        let result = await Shell.runAsync(
            "idevicebackup2",
            arguments: ["-u", udid, "encryption", mode],
            extraEnvironment: ["BACKUP_PASSWORD": password]
        )
        guard result.succeeded else {
            return (false, "Could not change backup encryption without exposing the password on the command line. Ensure idevicebackup2 is installed and try again.")
        }
        return (true, nil)
    }

    /// Change the backup password using idevicebackup2's environment-variable interface.
    static func changeEncryptionPassword(udid: String, oldPassword: String, newPassword: String) async -> (success: Bool, error: String?) {
        let result = await Shell.runAsync(
            "idevicebackup2",
            arguments: ["-u", udid, "changepw"],
            extraEnvironment: [
                "BACKUP_PASSWORD": oldPassword,
                "BACKUP_PASSWORD_NEW": newPassword,
            ]
        )
        guard result.succeeded else {
            return (false, "Could not change the backup password without exposing it on the command line. Ensure idevicebackup2 is installed and try again.")
        }
        return (true, nil)
    }

    /// Check if backup encryption is enabled for a device.
    static func isEncryptionEnabled(udid: String) async -> Bool {
        if PyMobileDevice.available() {
            return await PyMobileDevice.encryptionStatus(udid: udid)
        }
        let result = await Shell.runAsync("idevicebackup2", arguments: ["-u", udid, "encryption"])
        return result.output.contains("on")
    }
}
