import SwiftUI
import AppKit

struct BackupRow: View {
    let backup: BackupInfo
    var activity: BackupViewModel.BackupActivity?
    let onBrowse: () -> Void
    let onDelete: () -> Void
    let onResume: () -> Void
    let onPause: () -> Void
    var onDiagnose: () -> Void = {}
    @State private var isExporting = false

    private var isActive: Bool { activity?.isActive == true }
    private var isStalled: Bool { activity?.isStalled == true }
    private var isQuiet: Bool { activity?.isQuiet == true }
    private var isBusy: Bool { activity?.isBusy == true }

    /// Progress for a backup running inside this row. The row keeps its identity
    /// while resuming instead of handing the device off to a separate card.
    @ViewBuilder
    private var activityStatus: some View {
        if let activity, isActive {
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: activity.displayProgressFraction, total: 1.0)
                    .progressViewStyle(.linear)
                    .tint(isStalled ? .orange : (isQuiet ? .secondary : .brandAccent))

                HStack(spacing: 6) {
                    let statusText: String = {
                        if isStalled {
                            return "Quiet (>5 min) · Device may be processing large files"
                        }
                        if isQuiet {
                            return "Waiting for device response… (\(activity.progressText))"
                        }
                        if activity.isFinalizing {
                            let pct = Int(activity.displayProgressFraction * 100)
                            return "Finalizing & sealing (\(pct)%)"
                        }
                        return activity.progressText
                    }()
                    Text(statusText)
                        .font(.system(size: 10))
                        .foregroundStyle(isStalled ? Color.orange : Color.secondary)
                        .lineLimit(1)
                    if let speed = activity.speed {
                        Text("· Speed: \(speed)")
                        if let eta = activity.eta { Text("· Est. Remaining: \(eta)") }
                    }
                }
                .font(.system(size: 10))

                if let phase = activity.phaseMetrics?.phase {
                    let phaseText = activity.phaseMetrics?.phaseDetail?.description ?? phase.displayName
                    HStack(spacing: 8) {
                        Label {
                            Text(phaseText)
                        } icon: {
                            Image(systemName: phase.systemImage)
                        }
                        if let phaseMetrics = activity.phaseMetrics {
                            if let transferred = phaseMetrics.filesTransferred, let total = phaseMetrics.totalFiles, total > 0 {
                                let remaining = max(0, total - transferred)
                                Text("· Files: \(transferred.formatted()) / \(total.formatted()) (\(remaining.formatted()) left)")
                            }
                            if let bytes = phaseMetrics.bytesTransferred, let totalB = phaseMetrics.totalBytes, totalB > 0 {
                                Text("· Data: \(bytes.formattedFileSize) / \(totalB.formattedFileSize)")
                            }
                        }
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                }

                if let stats = activity.throughputStats, stats.samplesCount >= 5 {
                    HStack(spacing: 6) {
                        Text("Avg: \(Self.formatRate(stats.averageBytesPerSecond))")
                        Text("· Peak: \(Self.formatRate(stats.peakBytesPerSecond))")
                        if activity.throughputTrend != .insufficient {
                            Text("· Trend: \(activity.throughputTrend.description)")
                        }
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                }

                if let predicted = activity.predictiveETA,
                   predicted.confidence != .none,
                   predicted.estimatedSeconds > 0 {
                    Text("Predicted Remaining: \(Self.formatDuration(predicted.estimatedSeconds)) (\(predicted.confidence.rawValue) confidence)")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }

                if let metrics = activity.finalizationMetrics {
                    Text("Finalizing: \(metrics.filesMoved.formatted()) / ~\(metrics.totalFiles.formatted()) files moved")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }

                if isQuiet {
                    let quietSecs = Int(Date().timeIntervalSince(activity.lastProgressUpdate))
                    Text("Device response quiet for \(quietSecs)s · Transfer is still running in background")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private static func formatRate(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond > 0 else { return "-" }
        return ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .file) + "/s"
    }

    private static func formatDuration(_ interval: TimeInterval) -> String {
        let total = Int(interval)
        if total >= 3600 { return "\(total / 3600)h \((total % 3600) / 60)m" }
        if total >= 60 { return "\(total / 60)m \(total % 60)s" }
        return "\(total)s"
    }

    var body: some View {
        HStack(spacing: 14) {
            // Device icon
            GradientIconTile(
                systemName: backup.productType.hasPrefix("iPad") ? "ipad" : "iphone",
                color: .blue,
                size: 44,
                iconSize: 20
            )

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(backup.deviceIdentityLabel)
                        .font(.system(size: 14, weight: .medium))
                        .lineLimit(1)
                        .help("Full device ID: \(backup.udid.isEmpty ? "Unavailable" : backup.udid)")

                    if backup.isEncrypted {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.orange)
                            .help("Encrypted backup")
                    }

                    if backup.isComplete {
                        StatusChip(text: backup.isFullBackup ? "Full" : "Incremental", color: .brandAccent)
                    } else {
                        StatusChip(text: "Incomplete", color: .orange)
                    }
                }

                HStack(spacing: 8) {
                    Text("iOS \(backup.iosVersion)")
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    Text(backup.dateString)
                    Text("(\(backup.relativeDate))")
                    Text("-")
                    if backup.sizeResolved {
                        Text(backup.sizeString)
                    } else {
                        Label("Calculating...", systemImage: "clock")
                    }
                    if backup.appCount > 0 {
                        Text("-")
                        Text("\(backup.appCount) apps")
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)

                activityStatus
            }

            Spacer()

            HStack(spacing: 8) {
                if isBusy {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        let elapsed = activity?.transitionElapsedSeconds.map { " (\($0)s)" } ?? ""
                        Text(activity?.transition == .restarting ? "Restarting…\(elapsed)" : "Pausing…\(elapsed)")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                } else if isActive {
                    if isStalled {
                        Button("Resume", action: onResume)
                            .buttonStyle(.borderedProminent)
                            .tint(.orange)
                            .controlSize(.small)
                            .help("No progress for 5+ minutes - restarts this backup from saved progress")
                        Button("Pause & Save", action: onPause)
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .help("Stops the backup and saves progress. You can resume later.")
                        Button("Diagnose…") { onDiagnose() }
                            .controlSize(.small)
                            .help("Show why this backup stalled")
                    } else {
                        Button("Pause & Save", action: onPause)
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .help("Stops the backup and saves progress. You can resume later.")
                    }
                } else if !backup.isComplete {
                    Button("Resume", action: onResume)
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                        .controlSize(.small)
                        .help("Resume incomplete backup from saved progress")
                }

                Button("Browse") { onBrowse() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                Menu {
                    Button("Browse Contents") { onBrowse() }

                    Divider()

                    Button {
                        exportAsArchive()
                    } label: {
                        Label("Export as .phosphor Archive", systemImage: "archivebox")
                    }

                    Divider()

                    Button {
                        onDiagnose()
                    } label: {
                        Label("Diagnose & Activity Log…", systemImage: "stethoscope")
                    }

                    Divider()

                    Button("Show in Finder") {
                        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: backup.path)
                    }

                    Divider()

                    Button("Delete Backup", role: .destructive) { onDelete() }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 24)
            }
        }
        .padding(.vertical, 6)
        .overlay {
            if isExporting {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.7)
                    Text("Exporting archive...").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.regularMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func exportAsArchive() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        isExporting = true
        Task {
            let path = await BackupArchiver.createArchive(from: backup, to: url.path) { _ in }
            isExporting = false
            if let path {
                NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: url.path)
            }
        }
    }
}
