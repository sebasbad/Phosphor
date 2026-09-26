import Foundation
import OSLog

/// Central coordinator for all backup observability components
/// Provides unified interface for metrics collection, phase tracking, and throughput analysis
@MainActor
final class BackupObservabilityCoordinator: ObservableObject {

    // MARK: - Published State

    @Published var currentPhase: BackupPhase = .detecting
    @Published var phaseMetrics: PhaseMetrics?
    @Published var throughputStats: ThroughputHistory.ThroughputStats
    @Published var predictiveETA: ThroughputHistory.PredictiveETA?
    @Published var phaseTransitions: [PhaseTransitionRecord] = []
    @Published var isStalled = false
    @Published var isProcessAlive = true
    @Published var throughputTrend: ThroughputHistory.ThroughputTrend = .insufficient

    // MARK: - Private State

    private let logger = Logger(subsystem: "com.phosphor.backup", category: "observability")
    private let metricsCollector = BackupMetricsCollector()
    private let phaseTracker = PhaseTransitionTracker()
    private let throughputHistory = ThroughputHistory()

    // Phase tracking
    private var phaseStartTime = Date()
    private var lastSizeUpdate: Date?
    private var lastProgressUpdate = Date()

    // Process monitoring
    private var processAlive = true

    // Sampling
    // ponytail: nonisolated(unsafe) so deinit can invalidate the timer; all other
    // access stays on MainActor.
    nonisolated(unsafe) private var samplingTimer: Timer?
    private let samplingInterval: TimeInterval = 1.0

    // MARK: - Initialization

    init() {
        throughputStats = ThroughputHistory.ThroughputStats(
            currentBytesPerSecond: 0,
            averageBytesPerSecond: 0,
            peakBytesPerSecond: 0,
            minBytesPerSecond: 0,
            currentFilesPerSecond: nil,
            averageFilesPerSecond: nil,
            trend: .insufficient,
            samplesCount: 0,
            timeSpan: 0
        )
        predictiveETA = nil
        throughputTrend = .insufficient
        startSampling()
    }

    nonisolated deinit {
        stopSampling()
    }

    // MARK: - Public API

    /// Start observing a backup operation
    func startObserving(udid: String, configuration: DeviceBackupConfiguration?) {
        logger.info("Starting observability for device \(udid)")

        // Reset state
        phaseTransitions = []
        throughputHistory.reset()
        currentPhase = .detecting
        phaseStartTime = Date()
        lastSizeUpdate = nil
        lastProgressUpdate = Date()
        processAlive = true
        isStalled = false
        isProcessAlive = true

        // Start phase
        transitionToPhase(.detecting)

        // Start sampling
        startSampling()
    }

    /// Update metrics from backup process
    func updateMetrics(
        phase: BackupPhase,
        progressFraction: Double?,
        bytesTransferred: Int64?,
        filesTransferred: Int?,
        totalBytes: Int64?,
        totalFiles: Int?,
        currentFile: String?,
        speedBytesPerSec: Double?,
        speedFilesPerSec: Double?,
        eta: TimeInterval?,
        isFinalizing: Bool,
        finalizationMetrics: FinalizationProgressTracker.Metrics?
    ) {
        let now = Date()
        lastProgressUpdate = now
        processAlive = true

        // Detect phase change
        let newPhase = phase
        if newPhase != currentPhase {
            transitionPhase(to: newPhase)
        }

        currentPhase = newPhase

        // Create phase metrics
        let metrics = PhaseMetrics(
            phase: currentPhase,
            timestamp: now,
            duration: Date().timeIntervalSince(phaseStartTime),
            progressFraction: progressFraction ?? 0,
            progressPercent: progressFraction.map { Int($0 * 100) } ?? 0,
            eta: eta,
            speedBytesPerSec: speedBytesPerSec,
            speedFilesPerSec: speedFilesPerSec,
            bytesTransferred: bytesTransferred,
            totalBytes: totalBytes,
            filesTransferred: filesTransferred,
            totalFiles: totalFiles,
            currentFile: currentFile,
            phaseDetail: buildPhaseDetail(
                isFinalizing: isFinalizing,
                finalizationMetrics: finalizationMetrics,
                isResume: false,
                bytesTransferred: bytesTransferred,
                totalBytes: totalBytes,
                filesTransferred: filesTransferred,
                totalFiles: totalFiles,
                currentFile: currentFile
            )
        )

        // Update collector
        metricsCollector.record(sample: metrics)

        // Record throughput
        if let speed = speedBytesPerSec {
            throughputHistory.record(
                bytesPerSecond: speed,
                filesPerSecond: nil,
                phase: currentPhase.rawValue,
                bytesTransferred: 0,
                filesTransferred: nil
            )
        }

        // Update published state
        phaseMetrics = metricsCollector.currentPhaseMetrics
        throughputStats = throughputHistory.stats
        throughputTrend = throughputHistory.trend()
        predictiveETA = throughputHistory.predictiveETA(
            remainingBytes: (totalBytes ?? 0) - (bytesTransferred ?? 0),
            currentPhase: currentPhase.rawValue
        )

        // Update stall detection
        updateStallDetection()

        // Update process liveness
        updateProcessLiveness()
    }

    /// Called when backup process dies unexpectedly
    func markProcessDead() {
        processAlive = false
        logger.warning("Backup process died unexpectedly")
    }

    /// Get exportable snapshot for debugging
    func exportSnapshot() -> BackupObservabilitySnapshot {
        BackupObservabilitySnapshot(
            timestamp: Date(),
            currentPhase: currentPhase,
            phaseMetrics: phaseMetrics,
            throughputStats: throughputStats,
            predictiveETA: predictiveETA,
            phaseTransitions: phaseTransitions,
            throughputHistory: throughputHistory.allSamples,
            isStalled: isStalled,
            isProcessAlive: isProcessAlive,
            throughputTrend: throughputTrend
        )
    }

    // MARK: - Private Implementation

    private func transitionToPhase(_ newPhase: BackupPhase) {
        let now = Date()
        let duration = currentPhase != .detecting ? now.timeIntervalSince(phaseStartTime) : nil

        let transition = PhaseTransitionRecord(
            from: currentPhase,
            to: newPhase,
            timestamp: now,
            duration: duration,
            metadata: nil
        )

        phaseTransitions.append(transition)
        phaseTracker.recordTransition(from: currentPhase.rawValue, to: newPhase.rawValue)

        currentPhase = newPhase
        phaseStartTime = now

        logger.info("Phase transition: \(self.currentPhase.displayName) → \(newPhase.displayName)\(duration.map { " (\(Self.formatDuration($0)))" } ?? "")")
    }

    private func transitionPhase(to newPhase: BackupPhase) {
        let now = Date()
        let duration = currentPhase != .detecting ? now.timeIntervalSince(phaseStartTime) : nil

        let transition = PhaseTransitionRecord(
            from: currentPhase,
            to: newPhase,
            timestamp: now,
            duration: duration,
            metadata: nil
        )

        phaseTransitions.append(transition)
        phaseTracker.recordTransition(from: currentPhase.rawValue, to: newPhase.rawValue)

        currentPhase = newPhase
        phaseStartTime = now

        logger.info("Phase transition: \(self.currentPhase.displayName) → \(newPhase.displayName)\(duration.map { " (\(Self.formatDuration($0)))" } ?? "")")
    }

    private func buildPhaseDetail(
        isFinalizing: Bool,
        finalizationMetrics: FinalizationProgressTracker.Metrics?,
        isResume: Bool,
        bytesTransferred: Int64?,
        totalBytes: Int64?,
        filesTransferred: Int?,
        totalFiles: Int?,
        currentFile: String?
    ) -> PhaseDetail? {
        switch currentPhase {
        case .sanitization:
            return .sanitization(filesScanned: 0, filesCleaned: 0, walCheckpointed: false)
        case .incrementalResume:
            return .incrementalResume(filesResumed: 0, filesRemaining: 0, baselineFraction: 0)
        case .fullBackup:
            return .fullBackup(bytesTransferred: 0, totalBytes: 0, currentDomain: nil)
        case .fallbackIdevicebackup2:
            return .fallbackIdevicebackup2(reason: "Fallback initiated")
        case .finalization:
            if let metrics = finalizationMetrics {
                return .finalization(filesMoved: metrics.filesMoved, totalFiles: metrics.totalFiles, currentStage: "\(metrics.stage)")
            }
            return .finalization(filesMoved: 0, totalFiles: 0, currentStage: "Starting")
        case .verification:
            if let metrics = finalizationMetrics {
                if case .verifying(let scanned, let total) = metrics.stage {
                    return .verification(bucketsScanned: scanned, totalBuckets: total, currentBucket: nil)
                }
            }
            return .verification(bucketsScanned: 0, totalBuckets: 256, currentBucket: nil)
        case .completed:
            return .completed(totalBytes: 0, totalFiles: 0, duration: 0)
        case .failed:
            return .failed(error: "Unknown error")
        case .cancelled:
            return .cancelled(savedProgress: 0)
        default:
            return nil
        }
    }

    private func startSampling() {
        samplingTimer = Timer.scheduledTimer(withTimeInterval: samplingInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkStallAndLiveness()
            }
        }
    }

    nonisolated private func stopSampling() {
        samplingTimer?.invalidate()
        samplingTimer = nil
    }

    private func updateStallDetection() {
        guard let lastUpdate = lastSizeUpdate else {
            isStalled = false
            return
        }

        let staleInterval = Date().timeIntervalSince(lastUpdate)
        isStalled = staleInterval > 300 // 5 minutes
    }

    private func updateProcessLiveness() {
        let staleInterval = Date().timeIntervalSince(lastProgressUpdate)
        isProcessAlive = processAlive && staleInterval < 60 // 60 seconds
    }

    private func checkStallAndLiveness() {
        updateStallDetection()
        updateProcessLiveness()

        if isStalled {
            logger.warning("Backup stalled - no progress for 5+ minutes")
        }

        if !isProcessAlive {
            logger.warning("Backup process appears dead - no progress updates for 60+ seconds")
        }
    }

    static func formatDuration(_ interval: TimeInterval) -> String {
        let total = Int(interval)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return "\(h)h \(m)m \(s)s" }
        if m > 0 { return "\(m)m \(s)s" }
        return "\(Int(interval))s"
    }
}

/// Snapshot of observability state for debugging/export
struct BackupObservabilitySnapshot: Codable, Sendable {
    let timestamp: Date
    let currentPhase: BackupPhase
    let phaseMetrics: PhaseMetrics?
    let throughputStats: ThroughputHistory.ThroughputStats
    let predictiveETA: ThroughputHistory.PredictiveETA?
    let phaseTransitions: [PhaseTransitionRecord]
    let throughputHistory: [ThroughputHistory.VelocitySample]
    let isStalled: Bool
    let isProcessAlive: Bool
    let throughputTrend: ThroughputHistory.ThroughputTrend
}