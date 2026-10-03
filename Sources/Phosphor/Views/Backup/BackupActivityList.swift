import SwiftUI

/// Banner showing live progress for backups that do not currently have a persisted row in the backup list.
struct BackupActivityList: View {
    let activities: [BackupViewModel.BackupActivity]
    let devices: [DeviceInfo]
    @EnvironmentObject private var backupVM: BackupViewModel

    let onResumeStalled: (BackupViewModel.BackupActivity) -> Void
    let onCancel: (BackupViewModel.BackupActivity) -> Void
    let onDiagnose: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(activities) { activity in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: activity.state == .running ? (activity.isFinalizing ? "arrow.triangle.2.circlepath.circle.fill" : "externaldrive.badge.timemachine") : "clock")
                            .foregroundStyle(Color.brandAccent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(deviceIdentity(for: activity.udid))
                                .font(.system(size: 13, weight: .semibold))
                            Text(activity.displayProgressText)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(deviceIdentity(for: activity.udid)), \(activity.displayProgressText)")
                        Spacer()
                        if activity.isBusy {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                let elapsed = activity.transitionElapsedSeconds.map { " (\($0)s)" } ?? ""
                                Text(activity.transition == .restarting ? "Restarting…\(elapsed)" : "Pausing…\(elapsed)")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                        } else if activity.isStalled {
                            Button("Resume") {
                                onResumeStalled(activity)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.orange)
                            .controlSize(.small)
                            .help("No progress for 5+ minutes - restarts this backup from saved progress")
                            Button {
                                onCancel(activity)
                            } label: {
                                Label("Pause & Save", systemImage: "pause.circle")
                            }
                            .controlSize(.small)
                            .help("Stops the backup and saves progress. You can resume later.")
                            Button("Diagnose…") {
                                onDiagnose(activity.udid)
                            }
                            .controlSize(.small)
                            .help("Show why this backup stalled")
                        } else {
                            Button {
                                onCancel(activity)
                            } label: {
                                Label("Pause & Save", systemImage: "pause.circle")
                            }
                            .controlSize(.small)
                            .help(activity.isNonResumableFinalizationPhase ? "Warning: Finalization is non-resumable. Stopping now will abort this completed backup." : "Stops the backup and saves progress. You can resume later.")
                            .accessibilityLabel("Cancel backup for \(deviceIdentity(for: activity.udid))")
                        }
                    }
                    if case .running = activity.state {
                        if activity.isAwaitingPasscode {
                            HStack(spacing: 8) {
                                Image(systemName: "lock.shield.fill")
                                    .foregroundStyle(.orange)
                                    .font(.system(size: 14, weight: .semibold))
                                Text("Please unlock your device and enter your passcode or tap 'Trust' to proceed...")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.orange)
                            }
                            .padding(.vertical, 4)
                            .padding(.horizontal, 8)
                            .background(Color.orange.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            ProgressView(
                                value: activity.displayProgressFraction,
                                total: 1.0
                            )
                            .progressViewStyle(.linear)
                            .tint(activity.isAwaitingPasscode ? .orange : (activity.isQuiet ? .secondary : .brandAccent))

                            Text(activity.isFinalizing ? (activity.finalizationMetrics != nil ? "Reorganizing files from snapshot onto disk. Do not disconnect." : "Consolidating files and sealing backup manifest on disk...") : (activity.isQuiet ? "Waiting for device response…" : "Progress is saved automatically. You can stop or unplug and resume later."))
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                if activity.id != activities.last?.id { Divider() }
            }
        }
        .background(Color.brandAccent.opacity(0.06))
    }

    private func deviceIdentity(for udid: String) -> String {
        let suffix = String(udid.suffix(8))
        guard let device = devices.first(where: { $0.id == udid }) else {
            return "Device · ID …\(suffix)"
        }
        return "\(device.name) · \(device.displayModelName) · ID …\(suffix)"
    }
}
