import SwiftUI

/// Profile selector dropdown / card component for backup templates (Issue #5).
struct BackupProfileSelectorView: View {
    let udid: String
    @Binding var configuration: DeviceBackupConfiguration
    var onCustomizeApps: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Backup Profile")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)

                Spacer()

                Menu {
                    ForEach(BackupProfileType.allCases) { profile in
                        Button {
                            configuration.profileType = profile
                            configuration.save(for: udid)
                        } label: {
                            HStack {
                                Text(profile.title)
                                if configuration.profileType == profile {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: configuration.profileType.iconName)
                            .foregroundStyle(Color.brandAccent)
                        Text(configuration.profileType.title)
                            .font(.system(size: 12, weight: .medium))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                }
                .menuStyle(.borderlessButton)
            }

            HStack(spacing: 8) {
                Text(configuration.profileType.subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                Spacer()

                Text(configuration.profileType.estimatedTimeBadge)
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.brandAccent.opacity(0.12), in: Capsule())
                    .foregroundStyle(Color.brandAccent)
            }

            if !configuration.excludedBundleIds.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "minus.circle.fill")
                        .foregroundStyle(.orange)
                        .font(.system(size: 11))
                    Text("\(configuration.excludedBundleIds.count) apps excluded")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Edit Exclusions") {
                        onCustomizeApps()
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
                }
                .padding(.top, 2)
            } else if configuration.profileType == .full || configuration.profileType == .custom {
                Button {
                    onCustomizeApps()
                } label: {
                    Label("Customize App Data...", systemImage: "slider.horizontal.3")
                        .font(.system(size: 11))
                }
                .buttonStyle(.link)
                .padding(.top, 2)
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }
}
