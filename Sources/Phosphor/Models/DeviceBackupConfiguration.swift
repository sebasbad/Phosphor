import Foundation

/// Per-device persistent backup configuration for profile and app exclusions (Issues #4 & #5).
public struct DeviceBackupConfiguration: Codable, Equatable, Sendable {
    public var profileType: BackupProfileType
    public var excludedBundleIds: Set<String>
    public var excludeMediaAbove50MB: Bool
    public var excludeAppCaches: Bool
    public var excludedFilePatterns: [String]
    public var excludedRelativePaths: Set<String>
    public var customIncludedDomains: Set<String>
    public var alwaysUseProfile: Bool

    public init(
        profileType: BackupProfileType = .full,
        excludedBundleIds: Set<String> = [],
        excludeMediaAbove50MB: Bool = false,
        excludeAppCaches: Bool = false,
        excludedFilePatterns: [String] = [],
        excludedRelativePaths: Set<String> = [],
        customIncludedDomains: Set<String> = [],
        alwaysUseProfile: Bool = false
    ) {
        self.profileType = profileType
        self.excludedBundleIds = excludedBundleIds
        self.excludeMediaAbove50MB = excludeMediaAbove50MB
        self.excludeAppCaches = excludeAppCaches
        self.excludedFilePatterns = excludedFilePatterns
        self.excludedRelativePaths = excludedRelativePaths
        self.customIncludedDomains = customIncludedDomains
        self.alwaysUseProfile = alwaysUseProfile
    }

    private static func storageKey(for udid: String) -> String {
        "Phosphor.DeviceBackupConfiguration.\(udid)"
    }

    /// Load saved configuration for a given device UDID, or default to .full.
    public static func load(for udid: String) -> DeviceBackupConfiguration {
        guard !udid.isEmpty,
              let data = UserDefaults.standard.data(forKey: storageKey(for: udid)),
              let decoded = try? JSONDecoder().decode(DeviceBackupConfiguration.self, from: data) else {
            return DeviceBackupConfiguration()
        }
        return decoded
    }

    /// Save configuration for a given device UDID.
    public func save(for udid: String) {
        guard !udid.isEmpty,
              let encoded = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(encoded, forKey: Self.storageKey(for: udid))
    }

    /// Infers the backup profile and excluded app bundle IDs directly from an existing
    /// `<UDID>/Manifest.db` and `Info.plist` on disk (portable across any Mac without
    /// requiring local `UserDefaults` or non-Apple sidecar files inside `<UDID>/`).
    public static func inferFromExistingBackup(udid: String, in directory: String) -> DeviceBackupConfiguration? {
        let backupPath = (directory as NSString).appendingPathComponent(udid)
        let manifestDbPath = (backupPath as NSString).appendingPathComponent("Manifest.db")
        guard FileManager.default.fileExists(atPath: manifestDbPath) else { return nil }

        // Only query unencrypted Manifest.db directly; encrypted backups cannot be queried without password unlock.
        if let manifestPlist = PlistParser.parseManifest(backupPath), manifestPlist.isEncrypted {
            return nil
        }
        guard let db = try? SQLiteReader(path: manifestDbPath),
              let rows = try? db.query("SELECT DISTINCT domain FROM Files") else {
            return nil
        }

        let domains = Set(rows.compactMap { $0["domain"] as? String })
        guard !domains.isEmpty else { return nil }

        let hasCameraRoll = domains.contains("CameraRollDomain")
        let backedUpThirdPartyApps: Set<String> = Set(
            domains.compactMap { domain -> String? in
                guard domain.hasPrefix("AppDomain-") else { return nil }
                let bundleId = String(domain.dropFirst("AppDomain-".count))
                guard !bundleId.hasPrefix("com.apple.") else { return nil }
                return bundleId
            }
        )

        let communicationApps: Set<String> = [
            "net.whatsapp.WhatsApp",
            "net.whatsapp.WhatsAppSMB",
            "org.whispersystems.signal",
            "ph.telegra.Telegraph",
            "com.tencent.xin"
        ]

        // Parse Info.plist Installed Applications to see which 3rd-party apps existed on the device at backup time
        let infoPath = (backupPath as NSString).appendingPathComponent("Info.plist")
        let installedThirdPartyApps: Set<String> = {
            guard let dict = PlistParser.parse(infoPath) else { return [] }
            if let installed = dict["Installed Applications"] as? [String] {
                return Set(installed.filter { !$0.hasPrefix("com.apple.") })
            }
            if let appsDict = dict["Applications"] as? [String: Any] {
                return Set(appsDict.keys.filter { !$0.hasPrefix("com.apple.") })
            }
            return []
        }()

        if backedUpThirdPartyApps.isEmpty {
            if hasCameraRoll {
                return DeviceBackupConfiguration(profileType: .essentialPhotos)
            } else {
                return DeviceBackupConfiguration(profileType: .bareMinimal)
            }
        }

        if !hasCameraRoll && backedUpThirdPartyApps.isSubset(of: communicationApps) {
            return DeviceBackupConfiguration(profileType: .communicationAndIdentity)
        }

        let excludedApps = installedThirdPartyApps.subtracting(backedUpThirdPartyApps)
        return DeviceBackupConfiguration(
            profileType: .full,
            excludedBundleIds: excludedApps
        )
    }

    /// True when two configurations produce the same effective backup domain/exclusion filter.
    public func isCompatibleForIncremental(with existing: DeviceBackupConfiguration) -> Bool {
        profileType == existing.profileType && excludedBundleIds == existing.excludedBundleIds
    }
}
