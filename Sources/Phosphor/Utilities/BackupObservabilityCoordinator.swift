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
                finalizationMetrics: finalizationMetrics,
                bytesTransferred: bytesTransferred,
                totalBytes: totalBytes
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
        // Only project an ETA when the transfer sizes are actually known. With
        // nil sizes the subtraction below yields 0 remaining, which produces a
        // confident-looking "0s" estimate for a backup that has barely started.
        if let totalBytes, let bytesTransferred, totalBytes > bytesTransferred {
            predictiveETA = throughputHistory.predictiveETA(
                remainingBytes: totalBytes - bytesTransferred,
                currentPhase: currentPhase.rawValue
            )
        }

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
            phaseDurations: phaseTracker.allPhaseDurations,
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

    /// Detail for the current phase, using only data the coordinator actually
    /// has. It previously returned zero-filled cases for every phase, so a full
    /// backup announced "0 bytes of 0 bytes" in the row and to VoiceOver.
    /// Returning nil falls back to the phase name, which is honest.
    private func buildPhaseDetail(
        finalizationMetrics: FinalizationProgressTracker.Metrics?,
        bytesTransferred: Int64?,
        totalBytes: Int64?
    ) -> PhaseDetail? {
        switch currentPhase {
        case .fullBackup:
            // Sizes come from the parsed tqdm progress line.
            guard let bytesTransferred, let totalBytes, totalBytes > 0 else { return nil }
            return .fullBackup(bytesTransferred: bytesTransferred, totalBytes: totalBytes, currentDomain: nil)
        case .finalization:
            guard let metrics = finalizationMetrics else { return nil }
            return .finalization(filesMoved: metrics.filesMoved, totalFiles: metrics.totalFiles, currentStage: "\(metrics.stage)")
        case .verification:
            guard let metrics = finalizationMetrics,
                  case .verifying(let scanned, let total) = metrics.stage else { return nil }
            return .verification(bucketsScanned: scanned, totalBuckets: total, currentBucket: nil)
        case .sanitization, .incrementalResume, .fallbackIdevicebackup2,
             .completed, .failed, .cancelled, .detecting:
            // No real counts are plumbed out of these paths yet; the phase name
            // is shown instead of invented numbers.
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
    /// Real elapsed time per phase, summed from the transition timeline.
    let phaseDurations: [String: TimeInterval]
    let throughputHistory: [ThroughputHistory.VelocitySample]
    let isStalled: Bool
    let isProcessAlive: Bool
    let throughputTrend: ThroughputHistory.ThroughputTrend
}