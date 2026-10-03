import SwiftUI

/// Hero card displayed when the device has an interrupted/paused backup that can be resumed.
struct ResumableBackupHeroCard: View {
    let device: DeviceInfo
    @EnvironmentObject private var backupVM: BackupViewModel
    @State private var cachedIncompleteStats: BackupManager.IncompleteBackupStats?
    @State private var isLoadingIncompleteStats = false

    let onResume: () -> Void
    let onDiscard: (String) -> Void

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color.orange.opacity(0.22), Color.orange.opacity(0.06)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: 92, height: 92)
                Image(systemName: "pause.circle.fill")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(Color.orange)
            }
            .padding(.bottom, 2)

            VStack(spacing: 4) {
                Text("Backup Paused for \(device.name)")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)

                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.secondary.opacity(0.4))
                        .frame(width: 7, height: 7)
                    Text("Idle · Safe to disconnect or exit")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }

            if let stats = cachedIncompleteStats {
                let activity = backupVM.activity(for: device.id)
                let activityFraction = activity?.displayProgressFraction
                let calculatedFraction = stats.completionFraction(for: device)
                let rawFraction = activityFraction ?? calculatedFraction ?? (stats.totalBytes > 1_000_000_000 ? min(Double(stats.totalBytes) / 70_000_000_000.0, 0.95) : nil)
                // A paused/interrupted backup is never 100% complete (which would be finalized). Cap at 0.99.
                let fraction = rawFraction.map { min($0, 0.99) }

                let remaining = stats.remainingBytes(for: device)
                let eta = activity?.eta ?? stats.estimatedResumeTime(for: device)

                VStack(spacing: 8) {
                    // Header progress metrics: % completed and remaining data
                    HStack(spacing: 6) {
                        if let fraction {
                            Text("\(Int(fraction * 100))% saved")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Color.orange)
                        } else {
                            Text("Saved")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }

                        Text("•")
                            .foregroundStyle(.secondary)

                        if let remaining, remaining > 0 {
                            Text("\(remaining.formattedFileSize) remaining")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)
                        } else if let fraction, fraction > 0, fraction < 0.99 {
                            let totalEst = Double(stats.totalBytes) / fraction
                            let remBytes = UInt64(max(totalEst - Double(stats.totalBytes), 0))
                            Text("~\(remBytes.formattedFileSize) remaining")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Ready to finalize")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)
                        }

                        if let eta, !eta.isEmpty {
                            Text("•")
                                .foregroundStyle(.secondary)
                            Text("Est. \(eta)")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                    }

                    // Progress bar
                    if let fraction {
                        ProgressView(value: fraction, total: 1.0)
                            .progressViewStyle(.linear)
                            .tint(Color.orange)
                            .frame(maxWidth: 320)
                    }

                    // Saved file count, total saved size, and paused time
                    Text("\(stats.fileCount.formatted()) files saved (\(stats.formattedSize)) • Paused \(stats.relativeTimeDescription)")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary.opacity(0.85))
                }
            } else if isLoadingIncompleteStats {
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.7)
                    Text("Reading saved files from disk…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            Text("Progress is saved. You can safely disconnect your device or close Phosphor. When ready, reconnect and resume anytime without starting over.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)

            HStack(spacing: 12) {
                Button {
                    onResume()
                } label: {
                    Label("Resume Backup", systemImage: "play.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .controlSize(.regular)

                Button("Discard & Start Fresh...", role: .destructive) {
                    if case .incomplete(let path) = BackupManager.backupMetadataHealth(for: device.id) {
                        onDiscard(path)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: device.id) {
            await loadIncompleteStatsInBackground(for: device.id)
        }
    }

    private func loadIncompleteStatsInBackground(for udid: String) async {
        isLoadingIncompleteStats = true
        let stats = await Task.detached(priority: .utility) {
            BackupManager.incompleteBackupStats(for: udid)
        }.value
        if !Task.isCancelled {
            cachedIncompleteStats = stats
            isLoadingIncompleteStats = false
        }
    }
}
