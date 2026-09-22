import Foundation

/// Pre-configured domain and content profile templates for iOS backups (Issue #5).
public enum BackupProfileType: String, CaseIterable, Identifiable, Codable, Sendable {
    /// 100% of device storage — all domains, photos, videos, and app data.
    case full = "full"
    
    /// Disaster recovery: System identity, Settings, Keychain, Accounts, Wi-Fi, Health, SMS, Contacts.
    /// Excludes Photos, Videos, Podcasts, Music, and third-party app caches.
    case bareMinimal = "bare_minimal"
    
    /// Bare Minimal + Instant Messaging containers (WhatsApp, Signal, Telegram, WeChat).
    case communicationAndIdentity = "communication_identity"
    
    /// Bare Minimal + Photos & Videos (`CameraRollDomain`), excluding third-party app caches.
    case essentialPhotos = "essential_photos"
    
    /// Custom user-selected domain categories and app exclusions.
    case custom = "custom"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .full:
            return "Complete Archive"
        case .bareMinimal:
            return "Bare Minimal (Disaster Recovery)"
        case .communicationAndIdentity:
            return "Communication & Identity"
        case .essentialPhotos:
            return "Photos & Essentials"
        case .custom:
            return "Custom Profile"
        }
    }

    public var iconName: String {
        switch self {
        case .full:
            return "archivebox.fill"
        case .bareMinimal:
            return "shield.lefthalf.filled"
        case .communicationAndIdentity:
            return "bubble.left.and.bubble.right.fill"
        case .essentialPhotos:
            return "photo.on.rectangle.angled"
        case .custom:
            return "slider.horizontal.3"
        }
    }

    public var subtitle: String {
        switch self {
        case .full:
            return "Everything: photos, videos, media, messages, accounts, and all apps."
        case .bareMinimal:
            return "Settings, Keychain, passwords, messages, and contacts. Fast 5-15 min restore."
        case .communicationAndIdentity:
            return "Bare Minimal plus WhatsApp, Telegram, and Signal messaging databases."
        case .essentialPhotos:
            return "Identity and Camera Roll photos/videos. Skips third-party app caches."
        case .custom:
            return "Granular domain rules and custom app exclusion checklist."
        }
    }

    public var estimatedTimeBadge: String {
        switch self {
        case .full:
            return "Full Duration"
        case .bareMinimal:
            return "~5 - 15 min"
        case .communicationAndIdentity:
            return "~10 - 25 min"
        case .essentialPhotos:
            return "Variable"
        case .custom:
            return "Custom"
        }
    }

    /// Apple com.apple.mobilebackup2 domain regex patterns to PRESERVE for this profile.
    /// Returns nil if no domain filtering is needed (full archive).
    public func preservationRegex(
        customDomains: Set<String> = [],
        excludedBundleIds: Set<String> = []
    ) -> [String]? {
        switch self {
        case .full:
            // If full, but user explicitly excluded specific app bundle IDs
            guard !excludedBundleIds.isEmpty else { return nil }
            // Negative lookahead regex to match everything EXCEPT excluded app domains
            let excludedPattern = excludedBundleIds
                .map { NSRegularExpression.escapedPattern(for: $0) }
                .joined(separator: "|")
            return ["^(?!AppDomain(-\(excludedPattern)|Group(-\(excludedPattern))).*).*$"]

        case .bareMinimal:
            // Core identity, communication, health, settings. Excludes CameraRoll, Media, and third-party apps.
            return [
                "^(HomeDomain|SystemPreferencesDomain|KeychainDomain|RootDomain|ManagedPreferencesDomain|WirelessDomain|HealthDomain|TonesDomain|AppDomain-com\\.apple\\..*)$"
            ]

        case .communicationAndIdentity:
            // Bare Minimal + popular communication apps (WhatsApp, Signal, Telegram, WeChat)
            return [
                "^(HomeDomain|SystemPreferencesDomain|KeychainDomain|RootDomain|ManagedPreferencesDomain|WirelessDomain|HealthDomain|TonesDomain|AppDomain-com\\.apple\\..*|AppDomain(-Group)?-(net\\.whatsapp\\.WhatsApp|org\\.whispersystems\\.signal|ph\\.telegra\\.Telegraph|com\\.tencent\\.xin).*)$"
            ]

        case .essentialPhotos:
            // Bare Minimal + Camera Roll photos/videos
            return [
                "^(HomeDomain|SystemPreferencesDomain|KeychainDomain|RootDomain|ManagedPreferencesDomain|WirelessDomain|HealthDomain|TonesDomain|CameraRollDomain|AppDomain-com\\.apple\\..*)$"
            ]

        case .custom:
            guard !customDomains.isEmpty || !excludedBundleIds.isEmpty else { return nil }
            var patterns: [String] = []
            if !customDomains.isEmpty {
                let joined = customDomains.joined(separator: "|")
                patterns.append("^(\(joined)).*$")
            }
            if !excludedBundleIds.isEmpty {
                let excludedPattern = excludedBundleIds
                    .map { NSRegularExpression.escapedPattern(for: $0) }
                    .joined(separator: "|")
                patterns.append("^(?!AppDomain(-\(excludedPattern)|Group(-\(excludedPattern))).*).*$")
            }
            return patterns.isEmpty ? nil : patterns
        }
    }
}
