import SwiftUI

/// Pre-flight modal sheet presented when the user initiates a backup (Issue #5).
/// Decouples profile selection and app exclusion dials from passive overview screens,
/// adhering to SOTA macOS progressive disclosure standards.
///
/// Implements an in-place step transition (Issues #4 & #5) so third-party app
/// data customization does NOT spawn a secondary stacked sheet, avoiding macOS
/// AppKit window layering and z-order glitches.
struct BackupPreflightSheet: View {
    let device: DeviceInfo
    let incremental: Bool
    let preferNetwork: Bool
    @Binding var configuration: DeviceBackupConfiguration
    var onConfirm: () -> Void = {}
    var onStartBackup: () -> Void

    @Environment(\.dismiss) private var dismiss
    @AppStorage("phosphor.backupDirectory") private var backupDirectory = BackupManager.defaultBackupDir

    enum PreflightStep {
        case options
        case appExclusions
    }

    @State private var currentStep: PreflightStep = .options

    private var destinationPath: String {
        backupDirectory
    }

    var body: some View {
        Group {
            switch currentStep {
            case .options:
                optionsView
            case .appExclusions:
                AppExclusionView(
                    udid: device.id,
                    backupDirectory: backupDirectory,
                    configuration: $configuration,
                    onDismiss: {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            currentStep = .options
                        }
                    }
                )
            }
        }
        .frame(
            width: currentStep == .appExclusions ? 680 : 520,
            height: 640
        )
        .animation(.easeInOut(duration: 0.2), value: currentStep)
    }

    // MARK: - Options Step View

    private var optionsView: some View {
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
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "internaldrive.fill")
                                .foregroundStyle(Color.brandAccent)
                                .font(.system(size: 15))
                                .padding(.top, 2)

                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text("Backup Destination")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(.secondary)

                                    Spacer()

                                    Text(preferNetwork ? "Wi-Fi" : "USB 3.0 / USB-C")
                                        .font(.system(size: 10, weight: .bold))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.primary.opacity(0.06), in: Capsule())
                                        .foregroundStyle(.secondary)
                                }

                                Text(destinationPath)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.primary)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .textSelection(.enabled)
                            }
                        }

                        HStack {
                            Spacer()
                            Button("Change Destination...") {
                                let panel = NSOpenPanel()
                                panel.title = "Select Backup Destination Directory"
                                panel.canChooseFiles = false
                                panel.canChooseDirectories = true
                                panel.canCreateDirectories = true
                                panel.allowsMultipleSelection = false
                                if panel.runModal() == .OK, let url = panel.url {
                                    backupDirectory = url.path
                                }
                            }
                            .controlSize(.small)
                        }
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
                        configuration: $configuration
                    )

                    // Review & Customize Profile Shortcut
                    HStack(spacing: 8) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 13))
                            .foregroundStyle(Color.brandAccent)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Content & App Inclusions")
                                .font(.system(size: 12, weight: .semibold))
                            Text(configuration.profileType.appInclusionSummary)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Button("Review & Customize...") {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                currentStep = .appExclusions
                            }
                        }
                        .controlSize(.small)
                    }
                    .padding(12)
                    .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
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
                    onConfirm()
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
    }
}
