import SwiftUI

/// Pre-flight modal sheet presented when the user initiates a backup (Issue #5).
/// Decouples profile selection and app exclusion dials from passive overview screens,
/// adhering to SOTA macOS progressive disclosure standards.
struct BackupPreflightSheet: View {
    let device: DeviceInfo
    let incremental: Bool
    let preferNetwork: Bool
    @Binding var configuration: DeviceBackupConfiguration
    var onStartBackup: () -> Void
    var onCustomizeApps: () -> Void

    @Environment(\.dismiss) private var dismiss
    @AppStorage("phosphor.backupDirectory") private var backupDirectory = BackupManager.defaultBackupDir

    private var destinationPath: String {
        backupDirectory
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.brandAccent.opacity(0.15))
                        .frame(width: 44, height: 44)
                    Image(systemName: preferNetwork ? "wifi" : "cable.connector")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Color.brandAccent)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(incremental ? "Incremental Backup" : "Start Full Backup")
                        .font(.title3.weight(.bold))
                    Text(device.name)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.secondary.opacity(0.7))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 16)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    // Destination Callout
                    HStack(spacing: 10) {
                        Image(systemName: "internaldrive.fill")
                            .foregroundStyle(.secondary)
                            .font(.system(size: 14))

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Backup Destination")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                            Text(destinationPath)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }

                        Spacer()

                        Text(preferNetwork ? "Wi-Fi" : "USB 3.0 / USB-C")
                            .font(.system(size: 10, weight: .bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Color.primary.opacity(0.06), in: Capsule())
                            .foregroundStyle(.secondary)
                    }
                    .padding(12)
                    .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))

                    // Profile Selection
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Configure Backup Profile")
                            .font(.headline)
                        Text("Choose what data domains to stream from iOS onto disk.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    BackupProfileSelectorView(
                        udid: device.id,
                        configuration: $configuration,
                        onCustomizeApps: onCustomizeApps
                    )

                    // App Exclusion Shortcut
                    HStack(spacing: 8) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 13))
                            .foregroundStyle(Color.brandAccent)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Third-Party App Exclusions")
                                .font(.system(size: 12, weight: .semibold))
                            if configuration.excludedBundleIds.isEmpty {
                                Text("No apps excluded. All installed apps are included.")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("\(configuration.excludedBundleIds.count) apps excluded from backup.")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.orange)
                            }
                        }

                        Spacer()

                        Button("Customize...") {
                            onCustomizeApps()
                        }
                        .controlSize(.small)
                    }
                    .padding(12)
                    .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))

                    // Don't show again preference
                    Toggle(isOn: $configuration.alwaysUseProfile) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Always use this profile for \(device.name)")
                                .font(.system(size: 12, weight: .medium))
                            Text("Skip this screen on future backups. You can re-enable it in Settings.")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.checkbox)
                    .onChange(of: configuration.alwaysUseProfile) { _, _ in
                        configuration.save(for: device.id)
                    }
                    .padding(.top, 4)
                }
                .padding(24)
            }

            Divider()

            // Footer actions
            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button {
                    dismiss()
                    onStartBackup()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.right.circle.fill")
                        Text("Start Backup")
                            .fontWeight(.semibold)
                    }
                    .padding(.horizontal, 10)
                }
                .buttonStyle(.borderedProminent)
                .tint(.brandAccent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .background(Color.groupedBackground.opacity(0.5))
        }
        .frame(width: 520, height: 640)
    }
}
