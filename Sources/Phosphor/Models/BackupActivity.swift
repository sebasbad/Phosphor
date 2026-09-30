import Foundation
import SwiftUI

/// Tracks the active progress, phases, transitions, and observable metrics for a device backup.
struct BackupActivity: Identifiable, Sendable {
    enum State: Equatable, Sendable {
        case queued(position: Int)
        case running
        case completed
        case failed
        case cancelled
    }

    enum Phase: String, CaseIterable, Equatable, Sendable {
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
    enum Transition: Equatable, Sendable { case pausing, restarting }
    var transition: Transition?
    var transitionStartTime: Date?
    var isBusy: Bool { transition != nil }
    var actionLiveness: ActionLivenessStatus?
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

    var isQuiet: Bool {
        guard transition == nil else { return false }
        guard case .running = state else { return false }
        let interval = Date().timeIntervalSince(lastProgressUpdate)
        return interval > 30 && interval <= 300 // 30 seconds quiet, not yet stalled
    }

    var displayProgressText: String {
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
                components.append("Quiet (\(quietSeconds)s) · Timeout in \(PhaseTransitionRecord.formatDuration(TimeInterval(remaining)))")
                if let note = actionLiveness?.currentActionNote {
                    components.append(note)
                } else {
                    components.append("Waiting for device response")
                }
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

            // Add action elapsed time so user knows operation is ticking
            let elapsedTotal = Int(Date().timeIntervalSince(startTime))
            if elapsedTotal > 5 {
                components.append("Elapsed: \(PhaseTransitionRecord.formatDuration(TimeInterval(elapsedTotal)))")
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

    init(
        udid: String,
        state: State,
        progressText: String,
        progressFraction: Double? = nil,
        eta: String? = nil,
        speed: String? = nil,
        isResume: Bool = false,
        resumeBaselineFraction: Double = 0.0,
        resumeFileBaseline: Int? = nil,
        isAwaitingPasscode: Bool = false,
        errorMessage: String? = nil
    ) {
        self.udid = udid
        self.state = state
        self.progressText = progressText
        self.progressFraction = progressFraction
        self.eta = eta
        self.speed = speed
        self.isResume = isResume
        self.resumeBaselineFraction = resumeBaselineFraction
        self.resumeFileBaseline = resumeFileBaseline
        self.isAwaitingPasscode = isAwaitingPasscode
        self.errorMessage = errorMessage
    }
}
