import Foundation
import SwiftUI

/// Drives backup list, creation, browsing, and extraction UI.
@MainActor
final class BackupViewModel: ObservableObject {

    struct BackupActivity: Identifiable {
        enum State: Equatable {
            case queued(position: Int)
            case running
            case completed
            case failed
            case cancelled
        }

        enum Phase: String, CaseIterable, Equatable {
            case unknown
            case sanitization
            case incrementalResume
            case fullBackup
            case fallbackIdevicebackup2
            case finalization
            case verification
            case completed
            case failed
            case cancelled

            var displayName: String {
                switch self {
                case .unknown: return "Detecting..."
                case .sanitization: return "Sanitizing"
                case .incrementalResume: return "Resuming Backup"
                case .fullBackup: return "Full Backup"
                case .fallbackIdevicebackup2: return "Fallback Backup"
                case .finalization: return "Finalizing"
                case .verification: return "Verifying"
                case .completed: return "Completed"
                case .failed: return "Failed"
                case .cancelled: return "Paused"
                }
            }

            var systemImage: String {
                switch self {
                case .unknown: return "questionmark.circle"
                case .sanitization: return "gearshape.2.fill"
                case .incrementalResume: return "arrow.clockwise.circle.fill"
                case .fullBackup: return "externaldrive.badge.plus"
                case .fallbackIdevicebackup2: return "exclamationmark.triangle.fill"
                case .finalization: return "arrow.triangle.2.circlepath.circle.fill"
                case .verification: return "checkmark.shield.fill"
                case .completed: return "checkmark.circle.fill"
                case .failed: return "xmark.circle.fill"
                case .cancelled: return "pause.circle.fill"
                }
            }

            var color: Color {
                switch self {
                case .unknown: return .secondary
                case .sanitization: return .blue
                case .incrementalResume: return .orange
                case .fullBackup: return .brandAccent
                case .fallbackIdevicebackup2: return .yellow
                case .finalization: return .purple
                case .verification: return .green
                case .completed: return .green
                case .failed: return .red
                case .cancelled: return .orange
                }
            }

            var description: String {
                switch self {
                case .unknown: return "Detecting backup phase..."
                case .sanitization: return "Cleaning corrupted plists, checkpointing SQLite WAL"
                case .incrementalResume: return "Delta resume - transferring changed files only"
                case .fullBackup: return "Initial full backup of all selected domains"
                case .fallbackIdevicebackup2: return "Using idevicebackup2 fallback"
                case .finalization: return "Writing Manifest.db, sealing backup"
                case .verification: return "Verifying backup integrity"
                case .completed: return "Backup completed successfully"
                case .failed: return "Backup failed"
                case .cancelled: return "Backup paused - progress saved"
                }
            }
        }

        var id: String { udid }
        let udid: String
        var state: State
        var progressText: String
        var progressFraction: Double?
        var eta: String?
        var speed: String?
        var isResume: Bool = false
        var resumeBaselineFraction: Double = 0.0
        /// Files already on disk when this resume started, from the pre-resume
        /// incomplete-backup stats. Real baseline for the resume phase detail.
        var resumeFileBaseline: Int?
        var isAwaitingPasscode: Bool = false
        var errorMessage: String?

        // Enhanced phase tracking
        var phase: Phase = .unknown
        var manifestSizeBytes: Int64 = 0
        var lastSizeUpdate: Date?
        var processAlive: Bool = true
        var lastProgressUpdate: Date = Date()

        // Observability integration
        var observabilityCoordinator: BackupObservabilityCoordinator?

        /// Set while a pause/restart is in flight. The backup process dies
        /// asynchronously, so without this the activity sits on a stale
        /// "running" state: the button stays live, a second click stacks, and
        /// a slow termination reads as a stall.
        enum Transition: Equatable { case pausing, restarting }
        var transition: Transition?
        var transitionStartTime: Date?
        var isBusy: Bool { transition != nil }
        /// Explicit phase override set by progress signals (sanitization, fallback, terminal).
        var explicitPhase: BackupPhase?
        var sanitizationScanned: Int?
        var sanitizationCleaned: Int?
        var sanitizationWalCheckpointed: Bool?
        var fallbackReason: String?
        var startTime: Date = Date()
        var terminalPhaseDetail: PhaseDetail?
        var currentDomain: String?

        var observabilityPhase: BackupPhase {
            if let explicitPhase { return explicitPhase }
            if isFinalizing { return .finalization }
            if isResume { return .incrementalResume }
            return .fullBackup
        }

        // Enhanced observability fields
        var phaseMetrics: PhaseMetrics?
        var throughputStats: ThroughputHistory.ThroughputStats?
        var predictiveETA: ThroughputHistory.PredictiveETA?
        var throughputTrend: ThroughputHistory.ThroughputTrend = .insufficient

        var finalizationMetrics: FinalizationProgressTracker.Metrics?

        var isActive: Bool {
            switch state {
            case .queued, .running: true
            case .completed, .failed, .cancelled: false
            }
        }

        var isFinalizing: Bool {
            if case .running = state {
                return (progressFraction ?? 0.0) >= 0.99 || finalizationMetrics != nil
            }
            return false
        }

        var isNonResumableFinalizationPhase: Bool {
            if case .running = state, isFinalizing {
                return true
            }
            return false
        }

        var phaseDisplayName: String {
            phase.displayName
        }

        var phaseDescription: String {
            phase.description
        }

        var phaseIcon: String {
            phase.systemImage
        }

        var phaseColor: Color {
            phase.color
        }

        var isStalled: Bool {
            guard transition == nil else { return false }
            guard case .running = state else { return false }
            return Date().timeIntervalSince(lastProgressUpdate) > 300 // 5 minutes without progress
        }

        var transitionElapsedSeconds: Int? {
            guard let transitionStartTime else { return nil }
            return max(0, Int(Date().timeIntervalSince(transitionStartTime)))
        }

        var isQuiet: Bool {
            guard transition == nil else { return false }
            guard case .running = state else { return false }
            let interval = Date().timeIntervalSince(lastProgressUpdate)
            return interval > 30 && interval <= 300 // 30 seconds quiet, not yet stalled
        }

        var displayProgressText: String {
            if let transition {
                let elapsed = transitionElapsedSeconds.map { " (\($0)s)" } ?? ""
                switch transition {
                case .pausing:
                    return "Pausing…\(elapsed) · Saving state to disk"
                case .restarting:
                    return "Restarting…\(elapsed) · Preparing fresh session"
                }
            }
            switch state {
            case .queued(let position): return "Queued · #\(position)"
            case .running:
                var components: [String] = []
                
                // Prepend phase info if available
                if let phaseMetrics = phaseMetrics {
                    components.append("\(phaseMetrics.phase.displayName)")
                    if let detail = phaseMetrics.phaseDetail {
                        components.append(detail.description)
                    }
                }
                
                if isFinalizing {
                    let pct = Int(displayProgressFraction * 100)
                    if let metrics = finalizationMetrics {
                        switch metrics.stage {
                        case .moving:
                            components.append("Finalizing \(pct)%")
                            components.append("\(metrics.filesMoved.formatted()) / ~\(metrics.totalFiles.formatted()) files")
                            if let speed = metrics.formattedSpeed {
                                components.append(speed)
                            }
                            if let eta = metrics.formattedETA {
                                components.append("ETA: \(eta)")
                            }
                        case .verifying(let scanned, let total):
                            components.append("Verifying \(Int(metrics.phaseFraction * 100))%")
                            components.append("Bucket \(scanned)/\(total)")
                            if let eta = metrics.formattedETA {
                                components.append("ETA: \(eta)")
                            }
                        }
                    } else {
                        components.append("Finalizing \(pct)%")
                        components.append("Reorganizing & verifying files...")
                    }
                } else if isResume {
                    let pct = Int(displayProgressFraction * 100)
                    if resumeBaselineFraction > 0 {
                        components.append("Resuming \(pct)%")
                    } else {
                        components.append("Resuming · Preparing...")
                    }
                } else {
                    let pct = Int(displayProgressFraction * 100)
                    components.append("Backing up \(pct)%")
                }
                if isQuiet {
                    let quietSeconds = Int(Date().timeIntervalSince(lastProgressUpdate))
                    let remaining = max(0, 300 - quietSeconds)
                    let remainingStr = PhaseTransitionRecord.formatDuration(TimeInterval(remaining))
                    components.append("Waiting for device… (quiet \(quietSeconds)s, timeout in \(remainingStr))")
                } else {
                    if !isFinalizing {
                        if let speed, !speed.isEmpty {
                            components.append(speed)
                        }
                        if let eta, !eta.isEmpty {
                            components.append("ETA: \(eta)")
                        }
                    }
                    // Add predictive ETA if available
                    if let predictiveETA = predictiveETA, predictiveETA.confidence != .none {
                        components.append("Predicted: \(predictiveETA.formattedETA) (\(predictiveETA.confidence.rawValue))")
                    }
                    // Add throughput trend
                    if throughputTrend != .insufficient {
                        components.append("Trend: \(throughputTrend.description)")
                    }
                }
                return components.joined(separator: " · ")
            case .completed:
                if let terminalPhaseDetail {
                    return terminalPhaseDetail.description
                }
                return "Completed"
            case .failed: return "Failed"
            case .cancelled: return "Cancelled"
            }
        }

        var displayProgressFraction: Double {
            if isFinalizing {
                if let metrics = finalizationMetrics {
                    // Smoothly map phase fraction across the 0.90 -> 0.99 window
                    let scaled = 0.90 + (metrics.phaseFraction * 0.09)
                    return min(max(scaled, 0.90), 0.99)
                }
                return 0.99
            }
            guard let progressFraction else {
                return resumeBaselineFraction > 0 ? resumeBaselineFraction : 0.05
            }
            if isResume && resumeBaselineFraction > 0 {
                // Compute progress over total: baseline + remaining * sessionFraction
                let remainingFraction = 1.0 - resumeBaselineFraction
                let totalFraction = resumeBaselineFraction + (remainingFraction * progressFraction)
                let bounded = min(max(totalFraction, resumeBaselineFraction), 1.0)
                // Cap in-progress running state at 0.99 so 100% is only shown when state becomes .completed
                return state == .completed ? 1.0 : min(bounded, 0.99)
            }
            let bounded = min(max(progressFraction, 0.05), 1.0)
            return state == .completed ? 1.0 : min(bounded, 0.99)
        }
    }

    @Published var backups: [BackupInfo] = []
    @Published var selectedBackup: BackupInfo?
    @Published var isCreating = false
    @Published var progressText = ""
    @Published var progressFraction: Double?
    @Published var showAlert = false
    @Published var alertMessage = ""
    @Published var backupIssue: BackupManager.BackupFailure?
    @Published var loadError: String?
    @Published private(set) var backupActivities: [String: BackupActivity] = [:]

    // Browser state
    @Published var browserDomains: [String] = []
    @Published var browserFiles: [BackupManifest.FileEntry] = []
    @Published var currentDomain: String?
    @Published var searchQuery = ""
    @Published var searchResults: [BackupManifest.FileEntry] = []

    // Encrypted-backup unlock. Set when a browse attempt hits a locked backup;
    // the view presents a password sheet bound to it.
    @Published var pendingUnlock: BackupInfo?
    @Published var unlockError: String?
    @Published var isUnlocking = false

    let backupManager = BackupManager()
    private(set) var queryStore: ManifestQueryStore?
    private var browserLoadTask: Task<Void, Never>?
    private var domainSizeTask: Task<Void, Never>?
    private var searchSizeTask: Task<Void, Never>?
    private var currentDomainToken = UUID()
    private var currentSearchToken = UUID()
    private var sizeResolutionTask: Task<Void, Never>?
    private var latestBackupRequests: [String: BackupRequest] = [:]
    private var failedBackupRequests: [UUID: BackupRequest] = [:]
    private var jobQueue = BackupJobQueue(maxConcurrent: 2)
    private var requestTracker = BackupRequestTracker()
    private var pendingBackupRequests: [String: BackupRequest] = [:]
    private var backupManagers: [String: BackupManager] = [:]
    private var backupJobTasks: [String: Task<Void, Never>] = [:]
    private var finalizationTasks: [String: Task<Void, Never>] = [:]
    private var livenessTasks: [String: Task<Void, Never>] = [:]
    private var backupCompletionContinuations: [String: CheckedContinuation<Void, Never>] = [:]
    private var backupJobWaiters: [String: [BackupJobWaiter]] = [:]

    private struct BackupRequest {
        let id: UUID
        let udid: String
        let incremental: Bool
        let preferNetwork: Bool
        let encrypted: Bool
        let isResume: Bool
        let device: DeviceInfo?

        init(
            id: UUID = UUID(),
            udid: String,
            incremental: Bool = false,
            preferNetwork: Bool = false,
            encrypted: Bool = false,
            isResume: Bool = false,
            device: DeviceInfo? = nil
        ) {
            self.id = id
            self.udid = udid
            self.incremental = incremental
            self.preferNetwork = preferNetwork
            self.encrypted = encrypted
            self.isResume = isResume
            self.device = device
        }
    }

    private struct BackupJobWaiter {
        let requestID: UUID
        let continuation: CheckedContinuation<Void, Never>
    }

    func loadBackups() {
        sizeResolutionTask?.cancel()
        backupManager.discoverBackups()
        backups = backupManager.backups
        loadError = backupManager.lastError
        reconcileSelectedBackupAfterReload()
        resolveBackupSizesInBackground(for: backups)
    }

    private func reconcileSelectedBackupAfterReload() {
        guard let selectedBackup else { return }
        guard backups.contains(where: { $0.id == selectedBackup.id && $0.path == selectedBackup.path }) else {
            clearBrowserState()
            return
        }
    }

    private func resolveBackupSizesInBackground(for snapshot: [BackupInfo]) {
        guard !snapshot.isEmpty else { return }
        let snapshotIds = Set(snapshot.map(\.id))
        sizeResolutionTask = Task.detached(priority: .utility) { [weak self] in
            for backup in snapshot {
                if Task.isCancelled { return }
                let sized = backup.withSize(FileManager.default.directorySize(at: backup.path))
                if Task.isCancelled { return }
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    let currentIds = Set(self.backups.map(\.id))
                    guard currentIds == snapshotIds,
                          let idx = self.backups.firstIndex(where: { $0.id == sized.id }) else { return }
                    self.backups[idx] = sized
                    self.backupManager.backups = self.backups
                }
            }
        }
    }

    func openExistingBackupFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Folder"
        panel.message = "Pick a folder containing iOS backups, or a single UDID backup folder."

        guard panel.runModal() == .OK, let url = panel.url else { return }
        let path = url.path

        let target: String
        if BackupManager.looksLikeBackupFolder(path) {
            // User picked a single UDID backup. Point the directory at its parent so
            // sibling backups also appear, and discovery falls into the normal path.
            target = (path as NSString).deletingLastPathComponent
        } else {
            target = path
        }

        UserDefaults.standard.set(target, forKey: BackupManager.backupDirectoryUserDefaultsKey)
        loadBackups()
        if backups.isEmpty {
            alertMessage = loadError ?? "No backups found in \(target)."
            showAlert = true
        }
    }

    func createBackup(udid: String, incremental: Bool = false, preferNetwork: Bool = false, encrypted: Bool = false, isResume: Bool = false, device: DeviceInfo? = nil) async {
        let request = BackupRequest(
            id: UUID(),
            udid: udid,
            incremental: incremental,
            preferNetwork: preferNetwork,
            encrypted: encrypted,
            isResume: isResume,
            device: device
        )
        latestBackupRequests[udid] = request

        await withTaskCancellationHandler {
            guard !Task.isCancelled else { return }

            switch jobQueue.enqueue(udid: udid) {
            case .duplicate:
                requestTracker.registerWaiter(request.id, udid: udid)
                await withCheckedContinuation { continuation in
                    backupJobWaiters[udid, default: []].append(
                        BackupJobWaiter(requestID: request.id, continuation: continuation)
                    )
                    if Task.isCancelled {
                        cancelBackupRequest(udid: udid, requestID: request.id)
                    }
                }
            case .queued(let position):
                requestTracker.registerOwner(request.id, udid: udid)
                pendingBackupRequests[udid] = request
                backupActivities[udid] = BackupActivity(
                    udid: udid,
                    state: .queued(position: position),
                    progressText: "Queued",
                    progressFraction: nil,
                    isResume: request.isResume,
                    errorMessage: nil
                )
                refreshLegacyProgressState()
                await withCheckedContinuation { continuation in
                    backupCompletionContinuations[udid] = continuation
                    if Task.isCancelled {
                        cancelBackupRequest(udid: udid, requestID: request.id)
                    }
                }
            case .started:
                requestTracker.registerOwner(request.id, udid: udid)
                pendingBackupRequests[udid] = request
                backupActivities[udid] = BackupActivity(
                    udid: udid,
                    state: .running,
                    progressText: request.isResume ? "Preparing to resume..." : "Preparing...",
                    progressFraction: nil,
                    isResume: request.isResume,
                    errorMessage: nil
                )
                refreshLegacyProgressState()
                await withCheckedContinuation { continuation in
                    backupCompletionContinuations[udid] = continuation
                    let task = Task { [weak self] in
                        guard let self else { return }
                        await self.runBackupJob(udid: udid)
                    }
                    backupJobTasks[udid] = task
                    if Task.isCancelled {
                        cancelBackupRequest(udid: udid, requestID: request.id)
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelBackupRequest(udid: udid, requestID: request.id)
            }
        }
    }

    func activity(for udid: String) -> BackupActivity? {
        backupActivities[udid]
    }

    func isBackupActive(for udid: String) -> Bool {
        backupActivities[udid]?.isActive == true
    }

    func cancelBackup(udid: String) {
        switch jobQueue.cancel(udid: udid) {
        case .removedQueued:
            pendingBackupRequests.removeValue(forKey: udid)
            requestTracker.finish(udid: udid)
            backupCompletionContinuations.removeValue(forKey: udid)?.resume()
            resumeBackupWaiters(for: udid)
            updateActivity(udid: udid) {
                $0.state = .cancelled
                $0.progressText = "Cancelled"
            }
            renumberQueuedActivities()
            refreshLegacyProgressState()
        case .cancelRunning:
            if let manager = backupManagers[udid] {
                manager.cancelBackup()
            }
            backupJobTasks[udid]?.cancel()
            updateActivity(udid: udid) {
                $0.progressText = "Pausing..."
                $0.transition = .pausing
                $0.transitionStartTime = Date()
            }
        case .notFound:
            break
        }
    }

    func resumeBackup(udid: String, preferNetwork: Bool = false, encrypted: Bool = false, device: DeviceInfo? = nil) async {
        await createBackup(
            udid: udid,
            incremental: false,
            preferNetwork: preferNetwork,
            encrypted: encrypted,
            isResume: true,
            device: device
        )
    }

    /// Resume click while a job is stalled: the in-flight job is wedged, so a
    /// second enqueue returns .duplicate and parks a waiter on a job that may
    /// never finish — the click looks dead. Cancel it, wait for teardown (the
    /// queue entry is removed on a task hop), then resume fresh.
    /// Never during finalization: cancelling there discards a completed backup.
    func restartStalledBackup(udid: String, device: DeviceInfo? = nil) async {
        guard activity(for: udid)?.isStalled == true else {
            await resumeBackup(udid: udid, device: device)
            return
        }
        guard activity(for: udid)?.isNonResumableFinalizationPhase != true else { return }
        cancelBackup(udid: udid)
        // The user pressed Resume, not Pause: label the teardown accordingly.
        updateActivity(udid: udid) {
            $0.transition = .restarting
            $0.transitionStartTime = Date()
            $0.progressText = "Restarting..."
        }
        for _ in 0..<20 where backupActivities[udid]?.isActive == true {
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        await resumeBackup(udid: udid, device: device)
    }

    /// Human-readable diagnosis of a stalled or failing backup: what phase it
    /// was in, when it last made progress, what the phase timeline and
    /// throughput samples say. This is the answer to "why is Resume doing
    /// nothing" — previously that state produced no visible information at all.
    func diagnosisText(for udid: String) -> String? {
        guard let activity = backupActivities[udid] else {
            // If there's no in-flight activity, provide diagnosis based on preserved backup on disk
            guard let backup = backups.first(where: { $0.udid == udid || $0.id == udid }) else {
                return nil
            }
            var lines: [String] = []
            lines.append("Device: \(backup.deviceName) (\(backup.modelName))")
            lines.append("Identifier: \(backup.deviceIdentityLabel)")
            lines.append("Status: \(backup.isFullBackup ? "Complete backup" : "Preserved partial backup (resumable)")")
            lines.append("Path: \(backup.path)")
            lines.append("Last modified: \(backup.dateString) (\(backup.relativeDate))")
            lines.append("Size on disk: \(backup.sizeResolved ? backup.sizeString : "Calculating...")")
            if backup.appCount > 0 {
                lines.append("Installed applications: \(backup.appCount)")
            }
            lines.append("Encrypted: \(backup.isEncrypted ? "Yes" : "No")")
            lines.append("")
            lines.append("Activity: Idle (No live backup process currently active).")
            return lines.joined(separator: "\n")
        }
        var lines: [String] = []
        lines.append("State: \(activity.state)")
        lines.append("Phase: \((activity.phaseMetrics?.phase ?? activity.observabilityPhase).displayName)")
        lines.append("Last progress: \(activity.progressText)")
        if let fraction = activity.progressFraction {
            lines.append("Progress fraction: \(Int(fraction * 100))%")
        }
        if let transition = activity.transition {
            let elapsed = activity.transitionElapsedSeconds.map { " (\($0)s)" } ?? ""
            lines.append("Transition: \(transition == .restarting ? "restarting" : "pausing")\(elapsed)")
        }
        lines.append("Last progress update: \(Int(Date().timeIntervalSince(activity.lastProgressUpdate)))s ago")
        lines.append("Stalled (no progress for 5+ min): \(activity.isStalled ? "yes" : "no")")
        lines.append("Quiet (waiting for device >30s): \(activity.isQuiet ? "yes" : "no")")
        if let speed = activity.speed { lines.append("Last speed: \(speed)") }
        if let eta = activity.eta { lines.append("Last ETA: \(eta)") }
        if let error = activity.errorMessage { lines.append("Error: \(error)") }

        if let snapshot = activity.observabilityCoordinator?.exportSnapshot() {
            if !snapshot.phaseTransitions.isEmpty {
                lines.append("")
                lines.append("Phase timeline:")
                for transition in snapshot.phaseTransitions {
                    let duration = transition.duration.map { " (\(Int($0))s)" } ?? ""
                    lines.append("  \(transition.from.displayName) -> \(transition.to.displayName) at \(transition.timestamp.formatted(date: .omitted, time: .standard))\(duration)")
                }
            }
            if !snapshot.phaseDurations.isEmpty {
                lines.append("")
                lines.append("Time per phase:")
                for (phase, seconds) in snapshot.phaseDurations.sorted(by: { $0.value > $1.value }) {
                    let name = BackupPhase(rawValue: phase)?.displayName ?? phase
                    lines.append("  \(name): \(PhaseDetail.formatDuration(seconds))")
                }
            }
            let stats = snapshot.throughputStats
            if stats.samplesCount > 0 {
                lines.append("")
                lines.append("Throughput (\(stats.samplesCount) samples):")
                lines.append("  last: \(formatBytesPerSecond(stats.currentBytesPerSecond))")
                lines.append("  avg:  \(formatBytesPerSecond(stats.averageBytesPerSecond))")
                lines.append("  peak: \(formatBytesPerSecond(stats.peakBytesPerSecond))")
                if snapshot.throughputTrend != .insufficient {
                    lines.append("  trend: \(snapshot.throughputTrend.description)")
                }
            } else {
                lines.append("")
                lines.append("Throughput: no speed samples received — the backup tool produced no throughput output.")
            }
        }
        return lines.joined(separator: "\n")
    }

    private func formatBytesPerSecond(_ value: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .file) + "/s"
    }

    private func cancelBackupRequest(udid: String, requestID: UUID) {
        switch requestTracker.cancel(requestID, udid: udid) {
        case .cancelJob:
            cancelBackup(udid: udid)
        case .detachRequest:
            if pendingBackupRequests[udid]?.id == requestID {
                backupCompletionContinuations.removeValue(forKey: udid)?.resume()
            } else if let index = backupJobWaiters[udid]?.firstIndex(where: { $0.requestID == requestID }) {
                let waiter = backupJobWaiters[udid]?.remove(at: index)
                if backupJobWaiters[udid]?.isEmpty == true {
                    backupJobWaiters.removeValue(forKey: udid)
                }
                waiter?.continuation.resume()
            }
        case .notFound:
            break
        }
    }

    private func runBackupJob(udid: String) async {
        guard !Task.isCancelled else {
            updateActivity(udid: udid) {
                $0.state = .cancelled
                $0.progressText = "Cancelled"
            }
            finishBackupJob(udid: udid)
            return
        }
        guard let request = pendingBackupRequests[udid] else {
            finishBackupJob(udid: udid)
            return
        }

        let manager = BackupManager()
        backupManagers[udid] = manager
        let isResume = request.isResume
        var baselineFraction: Double = 0.0
        var resumeFileCount: Int?
        if isResume {
            let stats = await Task.detached(priority: .utility) {
                BackupManager.incompleteBackupStats(for: udid)
            }.value
            if let stats {
                resumeFileCount = stats.fileCount
                if let device = request.device, let calculatedFraction = stats.completionFraction(for: device) {
                    // Accurately reflect preserved progress up to 99%
                    baselineFraction = min(max(calculatedFraction, 0.05), 0.99)
                } else if stats.totalBytes > 1_000_000_000 {
                    // Fallback when device capacity is unknown: scale generously up to 95%
                    baselineFraction = min(Double(stats.totalBytes) / 70_000_000_000.0, 0.95)
                    baselineFraction = max(baselineFraction, 0.10)
                } else if stats.fileCount > 5000 {
                    baselineFraction = 0.10
                } else {
                    baselineFraction = 0.05
                }
            } else {
                baselineFraction = 0.05
            }
        }
        guard !Task.isCancelled else {
            updateActivity(udid: udid) {
                $0.state = .cancelled
                $0.progressText = "Cancelled"
            }
            finishBackupJob(udid: udid)
            return
        }
        updateActivity(udid: udid) {
            $0.state = .running
            $0.isResume = isResume
            $0.resumeBaselineFraction = baselineFraction
            $0.resumeFileBaseline = resumeFileCount
            $0.progressText = isResume ? "Resuming..." : "Preparing..."
            $0.lastProgressUpdate = Date()
        }
        startObservability(udid: udid, isResume: isResume)
        startLivenessMonitor(udid: udid)
        refreshLegacyProgressState()

        let success: Bool
        if request.isResume {
            success = await manager.resumeIncompleteBackup(
                udid: udid,
                encrypted: request.encrypted,
                preferNetwork: request.preferNetwork
            ) { [weak self, weak manager] text in
                guard let manager else { return }
                self?.updateBackupProgress(udid: udid, text: text, manager: manager)
            }
        } else if request.incremental {
            success = await manager.createIncrementalBackup(udid: udid, preferNetwork: request.preferNetwork) { [weak self, weak manager] text in
                guard let manager else { return }
                self?.updateBackupProgress(udid: udid, text: text, manager: manager)
            }
        } else {
            success = await manager.createBackup(udid: udid, encrypted: request.encrypted, preferNetwork: request.preferNetwork) { [weak self, weak manager] text in
                guard let manager else { return }
                self?.updateBackupProgress(udid: udid, text: text, manager: manager)
            }
        }

        if success {
            let duration = Date().timeIntervalSince(activity(for: udid)?.startTime ?? Date())
            let finalStats = await Task.detached(priority: .utility) {
                BackupManager.incompleteBackupStats(for: udid)
            }.value
            let totalBytes = Int64(finalStats?.totalBytes ?? 0)
            let totalFiles = finalStats?.fileCount ?? 0
            let completedDetail = (totalBytes > 0 && totalFiles > 0)
                ? PhaseDetail.completed(totalBytes: totalBytes, totalFiles: totalFiles, duration: duration)
                : nil

            updateActivity(udid: udid) {
                $0.state = .completed
                $0.progressText = "Completed"
                $0.progressFraction = 1
                $0.explicitPhase = .completed
                $0.terminalPhaseDetail = completedDetail
                if let coordinator = $0.observabilityCoordinator {
                    var context = PhaseContext()
                    context.terminalBytes = totalBytes > 0 ? totalBytes : nil
                    context.terminalFiles = totalFiles > 0 ? totalFiles : nil
                    context.terminalDuration = duration
                    coordinator.updateMetrics(
                        phase: .completed,
                        progressFraction: 1.0,
                        bytesTransferred: totalBytes > 0 ? totalBytes : nil,
                        filesTransferred: totalFiles > 0 ? totalFiles : nil,
                        totalBytes: totalBytes > 0 ? totalBytes : nil,
                        totalFiles: totalFiles > 0 ? totalFiles : nil,
                        currentFile: nil,
                        speedBytesPerSec: nil,
                        speedFilesPerSec: nil,
                        eta: nil,
                        isFinalizing: false,
                        finalizationMetrics: nil,
                        context: context
                    )
                    $0.phaseMetrics = coordinator.phaseMetrics
                }
            }
            loadBackups()
        } else if manager.lastOperationWasCancelled {
            updateActivity(udid: udid) {
                $0.state = .cancelled
                $0.progressText = "Stopped (Progress Saved)"
            }
        } else {
            let error = manager.lastBackupFailure?.message ?? manager.lastError ?? "Backup failed"
            updateActivity(udid: udid) {
                $0.state = .failed
                $0.progressText = "Failed"
                $0.errorMessage = error
            }
            if let failure = manager.lastBackupFailure {
                failedBackupRequests[failure.id] = request
                backupIssue = failure
            }
        }

        finishBackupJob(udid: udid)
    }

    private func finishBackupJob(udid: String) {
        updateActivity(udid: udid) { $0.transition = nil }
        finalizationTasks.removeValue(forKey: udid)?.cancel()
        livenessTasks.removeValue(forKey: udid)?.cancel()
        requestTracker.finish(udid: udid)
        pendingBackupRequests.removeValue(forKey: udid)
        backupManagers.removeValue(forKey: udid)
        backupJobTasks.removeValue(forKey: udid)
        backupCompletionContinuations.removeValue(forKey: udid)?.resume()
        resumeBackupWaiters(for: udid)
        let nextUDID = jobQueue.finish(udid: udid)
        renumberQueuedActivities()
        refreshLegacyProgressState()

        if let nextUDID {
            let task = Task { [weak self] in
                guard let self else { return }
                await self.runBackupJob(udid: nextUDID)
            }
            backupJobTasks[nextUDID] = task
        }
    }

    private func updateActivity(udid: String, update: (inout BackupActivity) -> Void) {
        guard var activity = backupActivities[udid] else { return }
        update(&activity)
        backupActivities[udid] = activity
    }

    /// Republishes activity state on a timer so time-derived flags
    /// (`isStalled`, `isProcessAlive`) flip in the UI even when the
    /// backup emits no further progress. Without this the row would only
    /// refresh on the next progress line — i.e. never, when stalled.
    private func startLivenessMonitor(udid: String) {
        livenessTasks[udid]?.cancel()
        livenessTasks[udid] = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { break }
                guard let self else { return }
                let domain = await Task.detached(priority: .utility) {
                    BackupManager.sampleActiveDomain(for: udid)
                }.value
                self.updateActivity(udid: udid) {
                    $0.processAlive = true
                    if let domain { $0.currentDomain = domain }
                }
                self.refreshLegacyProgressState()
            }
        }
    }

    private func startObservability(udid: String, isResume: Bool) {
        let coordinator = BackupObservabilityCoordinator()
        coordinator.startObserving(udid: udid, configuration: nil)
        // Seed initial phase
        let initialPhase: BackupPhase = isResume ? .incrementalResume : .fullBackup
        coordinator.updateMetrics(
            phase: initialPhase,
            progressFraction: nil,
            bytesTransferred: nil,
            filesTransferred: nil,
            totalBytes: nil,
            totalFiles: nil,
            currentFile: nil,
            speedBytesPerSec: nil,
            speedFilesPerSec: nil,
            eta: nil,
            isFinalizing: false,
            finalizationMetrics: nil
        )
        updateActivity(udid: udid) { $0.observabilityCoordinator = coordinator }
    }

    private func resumeBackupWaiters(for udid: String) {
        let waiters = backupJobWaiters.removeValue(forKey: udid) ?? []
        waiters.forEach { $0.continuation.resume() }
    }

    private func renumberQueuedActivities() {
        for (offset, udid) in jobQueue.queuedUDIDs.enumerated() {
            updateActivity(udid: udid) {
                $0.state = .queued(position: offset + 1)
                $0.progressText = "Queued · #\(offset + 1)"
            }
        }
    }

    private func refreshLegacyProgressState() {
        let active = backupActivities.values.filter(\.isActive)
        isCreating = !active.isEmpty
        let representative = active.first(where: { $0.state == .running }) ?? active.first
        progressText = representative?.progressText ?? ""
        progressFraction = representative?.progressFraction
    }

    private func recoveryUdid(for issue: BackupManager.BackupFailure) -> String? {
        issue.udid ?? recoveryRequest(for: issue)?.udid
    }

    private func recoveryRequest(for issue: BackupManager.BackupFailure) -> BackupRequest? {
        if let request = failedBackupRequests[issue.id] { return request }
        if let udid = issue.udid { return latestBackupRequests[udid] }
        return latestBackupRequests.count == 1 ? latestBackupRequests.values.first : nil
    }

    var displayProgressText: String {
        guard let progressFraction else { return "Backing up" }
        return "Backing up \(Int(progressFraction * 100))%"
    }

    var displayProgressFraction: Double {
        guard let progressFraction else { return 0.05 }
        return min(max(progressFraction, 0.05), 1.0)
    }

    private func updateBackupProgress(udid: String, text: String, manager: BackupManager) {
        let lower = text.lowercased()
        let awaitingPasscode = lower.contains("passcode")
            || lower.contains("pin")
            || lower.contains("trust")
            || lower.contains("unlock")
            || lower.contains("not paired")
            || lower.contains("pairing")
        var transferredBytes: Int64?
        var totalBytes: Int64?
        updateActivity(udid: udid) { activity in
            // A pause/restart is tearing the process down; late progress lines
            // must not overwrite the "Pausing..." status the user was promised.
            guard activity.transition == nil else { return }
            activity.progressText = text
            activity.lastProgressUpdate = Date()
            activity.processAlive = true
            if awaitingPasscode {
                activity.isAwaitingPasscode = true
            }
            var parsedProgress = false
            if let details = PyMobileDevice.parseProgressDetails(from: text) {
                parsedProgress = true
                // If we receive active transfer speed or progress, user has completed unlocking
                if details.speed != nil || details.fraction > 0.001 {
                    activity.isAwaitingPasscode = false
                }
                // Ignore transient sub-phase 100% resets unless truly completing
                if details.fraction >= 0.99 && activity.progressFraction ?? 0 < 0.85 {
                    // Transient 100% on metadata preparation phase - do not jump UI to 100%
                } else {
                    let current = activity.progressFraction ?? 0.0
                    activity.progressFraction = max(current, details.fraction)
                }
                if let eta = details.eta { activity.eta = eta }
                if let speed = details.speed { activity.speed = speed }
                if let t = details.transferred { transferredBytes = Self.parseByteCount(t) }
                if let t = details.total { totalBytes = Self.parseByteCount(t) }
            } else if let pct = PyMobileDevice.parseProgress(from: text) {
                parsedProgress = true
                if pct > 0.001 {
                    activity.isAwaitingPasscode = false
                }
                if pct >= 0.99 && activity.progressFraction ?? 0 < 0.85 {
                    // Transient subphase
                } else {
                    let current = activity.progressFraction ?? 0.0
                    activity.progressFraction = max(current, pct)
                }
            } else if manager.backupPercent > 0 {
                parsedProgress = true
                activity.isAwaitingPasscode = false
                let current = activity.progressFraction ?? 0.0
                activity.progressFraction = max(current, manager.backupPercent)
            }

            // Detect phase signals emitted by BackupManager
            if text.hasPrefix("Sanitizing:") {
                activity.explicitPhase = .sanitization
                // Format: "Sanitizing: <scanned> scanned, <cleaned> cleaned, wal: <wal>"
                if let regex = try? NSRegularExpression(pattern: #"Sanitizing:\s*(\d+)\s*scanned,\s*(\d+)\s*cleaned,\s*wal:\s*(true|false)"#) {
                    if let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) {
                        if let r1 = Range(m.range(at: 1), in: text), let s = Int(text[r1]) { activity.sanitizationScanned = s }
                        if let r2 = Range(m.range(at: 2), in: text), let c = Int(text[r2]) { activity.sanitizationCleaned = c }
                        if let r3 = Range(m.range(at: 3), in: text) { activity.sanitizationWalCheckpointed = text[r3] == "true" }
                    }
                }
            } else if text.hasPrefix("Fallback:") {
                activity.explicitPhase = .fallbackIdevicebackup2
                let reason = String(text.dropFirst("Fallback:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !reason.isEmpty { activity.fallbackReason = reason }
            } else if activity.explicitPhase == .sanitization && (parsedProgress || text.contains("Resuming")) {
                activity.explicitPhase = nil
            }

            if activity.isFinalizing {
                startFinalizationWatchdogIfNeeded(udid: udid)
            }

            if let coordinator = activity.observabilityCoordinator {
                coordinator.updateMetrics(
                    phase: activity.observabilityPhase,
                    progressFraction: activity.progressFraction,
                    bytesTransferred: transferredBytes,
                    filesTransferred: nil,
                    totalBytes: totalBytes,
                    totalFiles: nil,
                    currentFile: nil,
                    speedBytesPerSec: activity.speed.flatMap(Self.parseSpeedToBytesPerSecond),
                    speedFilesPerSec: nil,
                    eta: activity.eta.flatMap(Self.parseEtaToSeconds),
                    isFinalizing: activity.isFinalizing,
                    finalizationMetrics: activity.finalizationMetrics,
                    context: {
                        var context = PhaseContext()
                        context.filesResumed = activity.resumeFileBaseline
                        context.resumeBaselineFraction = activity.resumeBaselineFraction > 0 ? activity.resumeBaselineFraction : nil
                        context.sanitizationScanned = activity.sanitizationScanned
                        context.sanitizationCleaned = activity.sanitizationCleaned
                        context.sanitizationWalCheckpointed = activity.sanitizationWalCheckpointed
                        context.fallbackReason = activity.fallbackReason
                        context.currentDomain = activity.currentDomain
                        return context
                    }()
                )
                activity.phaseMetrics = coordinator.phaseMetrics
                activity.predictiveETA = coordinator.predictiveETA
                activity.throughputStats = coordinator.throughputStats
                activity.throughputTrend = coordinator.throughputTrend
            }
        }
        refreshLegacyProgressState()
    }

    /// Parse a tqdm speed string ("39.5MB/s", "1.2GB/s") into bytes/sec.
    /// "it/s" is iteration rate, not a byte rate, so it returns nil.
    private static func parseSpeedToBytesPerSecond(_ s: String) -> Double? {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        guard !trimmed.lowercased().contains("it/s") else { return nil }
        guard let regex = try? NSRegularExpression(pattern: #"^([\d.]+)\s*([kKmMgG]?)[bB]?/?s"#) else { return nil }
        guard let m = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)) else { return nil }
        guard let numRange = Range(m.range(at: 1), in: trimmed), let num = Double(String(trimmed[numRange])) else { return nil }
        let unit = Range(m.range(at: 2), in: trimmed).map { String(trimmed[$0]) } ?? ""
        let factor: Double = switch unit.lowercased() {
        case "g": 1_073_741_824
        case "m": 1_048_576
        case "k": 1_024
        default: 1
        }
        return num * factor
    }

    /// Parse a tqdm size string ("12.3G", "123M", "456K", "789") into bytes.
    private static func parseByteCount(_ s: String) -> Int64? {
        let trimmed = s.trimmingCharacters(in: .whitespaces).uppercased()
        guard let regex = try? NSRegularExpression(pattern: #"^([\d.]+)\s*([KMGT]?)B?$"#) else { return nil }
        guard let m = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)) else { return nil }
        guard let numRange = Range(m.range(at: 1), in: trimmed),
              let num = Double(trimmed[numRange]) else { return nil }
        let unit = Range(m.range(at: 2), in: trimmed).map { String(trimmed[$0]) } ?? ""
        let factor: Double = switch unit {
        case "K": 1_024
        case "M": 1_048_576
        case "G": 1_073_741_824
        case "T": 1_099_511_627_776
        default: 1
        }
        return Int64(num * factor)
    }

    /// Parse a formatted ETA ("5m 30s", "1h 2m 10s") into seconds.
    private static func parseEtaToSeconds(_ s: String) -> TimeInterval? {
        var total: TimeInterval = 0
        for part in s.lowercased().components(separatedBy: " ") {
            let token = part.trimmingCharacters(in: .whitespaces)
            if token.hasSuffix("h"), let v = Double(token.dropLast(1)) { total += v * 3600 }
            else if token.hasSuffix("m"), let v = Double(token.dropLast(1)) { total += v * 60 }
            else if token.hasSuffix("s"), let v = Double(token.dropLast(1)) { total += v }
        }
        return total > 0 ? total : nil
    }

    private func startFinalizationWatchdogIfNeeded(udid: String) {
        guard finalizationTasks[udid] == nil else { return }
        let backupDir = BackupManager.activeBackupDir
        let tracker = FinalizationProgressTracker(backupDirectory: backupDir, udid: udid)

        finalizationTasks[udid] = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if Task.isCancelled { break }
                let metrics = tracker.sampleMetrics()
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    guard let metrics else { return }
                    self.updateActivity(udid: udid) { activity in
                        guard case .running = activity.state else { return }
                        activity.finalizationMetrics = metrics
                        // On-disk consolidation is real progress. Without this a
                        // finalization longer than 5 minutes reads as "stalled" and
                        // the row swaps Pause & Save for a resume that cannot run.
                        activity.lastProgressUpdate = Date()
                    }
                    self.refreshLegacyProgressState()
                }
            }
        }
    }

    func runFullBackup(for issue: BackupManager.BackupFailure) async {
        guard let udid = recoveryUdid(for: issue) else {
            backupIssue = BackupManager.BackupFailure(
                title: "Could Not Start Full Backup",
                message: "Phosphor could not identify which device needs the full backup. Re-select the device and start a full backup manually.",
                technicalDetails: issue.technicalDetails,
                recoveryAction: nil
            )
            return
        }
        let request = recoveryRequest(for: issue)
        backupIssue = nil
        await createBackup(
            udid: udid,
            incremental: false,
            preferNetwork: request?.preferNetwork ?? false,
            encrypted: request?.encrypted ?? false
        )
    }

    func resumeBackup(for issue: BackupManager.BackupFailure) async {
        guard let udid = recoveryUdid(for: issue) else {
            backupIssue = BackupManager.BackupFailure(
                title: "Could Not Resume Backup",
                message: "Phosphor could not identify which device needs to resume the backup. Re-select the device and start a backup manually.",
                technicalDetails: issue.technicalDetails,
                recoveryAction: nil
            )
            return
        }
        let request = recoveryRequest(for: issue)
        backupIssue = nil
        await resumeBackup(
            udid: udid,
            preferNetwork: request?.preferNetwork ?? false,
            encrypted: request?.encrypted ?? false
        )
    }

    func deleteIncompleteBackupAndRunFull(for issue: BackupManager.BackupFailure) async {
        guard let udid = recoveryUdid(for: issue), let path = issue.recoveryPath else {
            backupIssue = BackupManager.BackupFailure(
                title: "Could Not Move Incomplete Backup",
                message: "Phosphor could not identify the incomplete backup folder. Delete it manually or choose another backup folder, then run a full backup again.",
                technicalDetails: issue.technicalDetails,
                recoveryAction: .openBackupSettings
            )
            return
        }
        do {
            let request = recoveryRequest(for: issue)
            let recoveryRoot = (path as NSString).deletingLastPathComponent
            try BackupManager.deleteIncompleteBackup(for: udid, expectedPath: path, in: recoveryRoot)
            backupIssue = nil
            loadBackups()
            await createBackup(
                udid: udid,
                incremental: false,
                preferNetwork: request?.preferNetwork ?? false,
                encrypted: request?.encrypted ?? false
            )
        } catch {
            backupIssue = BackupManager.BackupFailure(
                title: "Could Not Move Incomplete Backup",
                message: "Phosphor could not move the incomplete backup folder to Trash. Choose another backup folder or move it manually, then try a full backup again.",
                technicalDetails: error.localizedDescription,
                recoveryAction: .openBackupSettings,
                udid: udid,
                recoveryPath: path
            )
        }
    }

    func retryBackup(for issue: BackupManager.BackupFailure) async {
        guard let request = recoveryRequest(for: issue) else { return }
        backupIssue = nil
        await createBackup(
            udid: request.udid,
            incremental: request.incremental,
            preferNetwork: request.preferNetwork,
            encrypted: request.encrypted
        )
    }

    // MARK: - Browsing

    private func clearBrowserState() {
        browserLoadTask?.cancel()
        browserLoadTask = nil
        domainSizeTask?.cancel()
        domainSizeTask = nil
        searchSizeTask?.cancel()
        searchSizeTask = nil
        selectedBackup = nil
        queryStore = nil
        browserDomains = []
        browserFiles = []
        currentDomain = nil
        searchQuery = ""
        searchResults = []
    }

    @discardableResult
    func openBackupBrowser(_ backup: BackupInfo) -> Bool {
        clearBrowserState()

        // An encrypted backup that has not been unlocked this session needs a
        // password before anything can be read. Ask for it instead of reporting
        // a failure the user cannot act on.
        if backup.isEncrypted && !BackupUnlockStore.shared.isUnlocked(backup.path) {
            // A remembered password unlocks silently; otherwise ask.
            if !unlockFromKeychain(backup) {
                unlockError = nil
                pendingUnlock = backup
                return false
            }
        }

        guard let manifest = backupManager.openManifest(for: backup) else {
            alertMessage = backupManager.lastError ?? "Failed to open backup."
            showAlert = true
            return false
        }
        let store = ManifestQueryStore(manifest: manifest)
        queryStore = store
        selectedBackup = backup

        browserLoadTask?.cancel()
        browserLoadTask = Task { [weak self] in
            do {
                let domains = try await store.domains()
                if Task.isCancelled { return }
                self?.browserDomains = domains
            } catch {
                guard let self else { return }
                self.clearBrowserState()
                self.alertMessage = "Failed to read backup: \(error.localizedDescription)"
                self.showAlert = true
            }
        }
        return true
    }

    /// Derive the backup's keys and open it. Key derivation runs two PBKDF2 chains,
    /// so it is deliberately slow and belongs off the main actor.
    func submitUnlock(password: String, remember: Bool) async {
        guard let backup = pendingUnlock, !password.isEmpty else { return }
        isUnlocking = true
        unlockError = nil
        defer { isUnlocking = false }

        let path = backup.path
        do {
            try await Task.detached(priority: .userInitiated) { () throws -> Void in
                // Keep the decryptor in BackupUnlockStore. Returning it from this
                // detached task would cross the MainActor boundary with a non-Sendable value.
                _ = try BackupUnlockStore.shared.unlock(backupPath: path, password: password)
            }.value
        } catch {
            unlockError = error.localizedDescription
            return
        }

        if remember {
            // Best effort: a Keychain refusal must not block a successful unlock.
            BackupPasswordKeychain.save(password: password, backupPath: path)
        }
        pendingUnlock = nil
        openBackupBrowser(backup)
    }

    func cancelUnlock() {
        pendingUnlock = nil
        unlockError = nil
    }

    /// Try a password the user previously chose to remember. Returns false when
    /// nothing is stored or the stored password no longer works.
    func unlockFromKeychain(_ backup: BackupInfo) -> Bool {
        guard let stored = BackupPasswordKeychain.password(for: backup.path) else { return false }
        guard (try? BackupUnlockStore.shared.unlock(backupPath: backup.path, password: stored)) != nil else {
            BackupPasswordKeychain.delete(backupPath: backup.path)
            return false
        }
        return true
    }

    func browseDomain(_ domain: String) {
        domainSizeTask?.cancel()
        currentDomain = domain
        let token = UUID()
        currentDomainToken = token
        browserFiles = []
        guard let store = queryStore else { return }
        domainSizeTask = Task { [weak self] in
            do {
                let entries = try await store.files(inDomain: domain)
                try Task.checkCancellation()
                guard let self, self.currentDomainToken == token else { return }
                self.browserFiles = entries
                let chunkSize = 500
                var idx = 0
                while idx < entries.count {
                    try Task.checkCancellation()
                    let end = Swift.min(idx + chunkSize, entries.count)
                    let sized = try await store.resolveSizes(for: Array(entries[idx..<end]))
                    guard self.currentDomainToken == token else { return }
                    self.splice(&self.browserFiles, sized, at: idx)
                    idx = end
                }
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.currentDomainToken == token else { return }
                self.alertMessage = error.localizedDescription
                self.showAlert = true
            }
        }
    }

    /// Navigate out of the current domain, cancelling any in-flight size work.
    func leaveDomain() {
        domainSizeTask?.cancel()
        domainSizeTask = nil
        currentDomainToken = UUID()
        currentDomain = nil
        browserFiles = []
    }

    func searchBackup(_ query: String) {
        searchSizeTask?.cancel()
        let token = UUID()
        currentSearchToken = token
        guard !query.isEmpty, let store = queryStore else {
            searchResults = []
            return
        }
        searchResults = []
        searchSizeTask = Task { [weak self] in
            do {
                let entries = try await store.search(query)
                try Task.checkCancellation()
                guard let self, self.currentSearchToken == token else { return }
                self.searchResults = entries
                let chunkSize = 500
                var idx = 0
                while idx < entries.count {
                    try Task.checkCancellation()
                    let end = Swift.min(idx + chunkSize, entries.count)
                    let sized = try await store.resolveSizes(for: Array(entries[idx..<end]))
                    guard self.currentSearchToken == token else { return }
                    self.splice(&self.searchResults, sized, at: idx)
                    idx = end
                }
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.currentSearchToken == token else { return }
                self.searchResults = []
            }
        }
    }

    /// Overwrite entries in `destination` starting at `offset` with `sized`,
    /// bounds-checked so a stale chunk from an obsolete query cannot corrupt
    /// the freshly published array.
    private func splice(
        _ destination: inout [BackupManifest.FileEntry],
        _ sized: [BackupManifest.FileEntry],
        at offset: Int
    ) {
        guard destination.count >= offset + sized.count else { return }
        for (i, entry) in sized.enumerated() {
            let idx = offset + i
            if destination[idx].id == entry.id {
                destination[idx] = entry
            }
        }
    }

    func extractFiles(_ files: [BackupManifest.FileEntry], to destination: String) -> Int {
        guard let backup = selectedBackup else { return 0 }
        do {
            return try backupManager.extractFiles(from: backup, entries: files, to: destination)
        } catch {
            alertMessage = error.localizedDescription
            showAlert = true
            return 0
        }
    }

    func deleteBackup(_ backup: BackupInfo) {
        do {
            try backupManager.deleteBackup(backup)
            loadBackups()
        } catch {
            alertMessage = "Failed to delete: \(error.localizedDescription)"
            showAlert = true
        }
    }

    var totalSize: String {
        if backups.contains(where: { !$0.sizeResolved }) {
            return "calculating..."
        }
        return backupManager.totalBackupSize.formattedFileSize
    }
}

/// Serializes Manifest.db access off the main actor. All SQLite queries and any
/// FileManager stat calls for size resolution run inside the actor's executor,
/// leaving the UI free from disk I/O.
actor ManifestQueryStore {
    private let manifest: BackupManifest

    init(manifest: BackupManifest) {
        self.manifest = manifest
    }

    func domains() throws -> [String] {
        try manifest.domains()
    }

    func files(inDomain domain: String) throws -> [BackupManifest.FileEntry] {
        try manifest.files(inDomain: domain)
    }

    func children(ofPath path: String, inDomain domain: String) throws -> [BackupManifest.FileEntry] {
        try manifest.children(ofPath: path, inDomain: domain)
    }

    func search(_ query: String) throws -> [BackupManifest.FileEntry] {
        try manifest.search(query)
    }

    /// Resolve on-disk sizes for one chunk. Callers drive chunking from the
    /// main actor so they can splice updates into the published array and
    /// react to cancellation without the store holding a closure.
    func resolveSizes(for slice: [BackupManifest.FileEntry]) throws -> [BackupManifest.FileEntry] {
        try Task.checkCancellation()
        return manifest.resolvingSizes(for: slice)
    }

    func readablePath(for entry: BackupManifest.FileEntry) throws -> String {
        try Task.checkCancellation()
        return try manifest.readablePath(for: entry)
    }

    func extractFile(_ entry: BackupManifest.FileEntry, to destination: String) throws {
        try manifest.extractFile(entry, to: destination)
    }
}
