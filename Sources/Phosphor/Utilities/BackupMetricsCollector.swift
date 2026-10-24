import Foundation
import OSLog

/// Collects and aggregates backup phase metrics with throughput tracking
/// Separated from BackupManager to provide focused observability
@MainActor
final class BackupMetricsCollector: ObservableObject {

    // MARK: - Published State

    @Published var currentPhaseMetrics: PhaseMetrics?
    @Published var phaseHistory: [PhaseMetrics] = []
    @Published var throughputStats: ThroughputHistory.ThroughputStats?
    @Published var throughputTrend: ThroughputHistory.ThroughputTrend = .insufficient
    @Published var predictiveETA: ThroughputHistory.PredictiveETA?

    // MARK: - Private State

    private let logger = Logger(subsystem: "com.phosphor.backup", category: "metrics-collector")
    private let throughputHistory = ThroughputHistory()

    // MARK: - Public API

    /// Record a phase metrics sample
    func record(sample: PhaseMetrics) {
        phaseHistory.append(sample)
        currentPhaseMetrics = sample

        // Update throughput history
        if let speed = sample.speedBytesPerSec {
            throughputHistory.record(
                bytesPerSecond: speed,
                filesPerSecond: sample.speedFilesPerSec,
                phase: sample.phase.rawValue,
                bytesTransferred: sample.bytesTransferred ?? 0,
                filesTransferred: sample.filesTransferred
            )
        }

        // Update published throughput stats
        throughputStats = throughputHistory.stats
        throughputTrend = throughputHistory.trend()

        if let totalBytes = sample.totalBytes,
           let bytesTransferred = sample.bytesTransferred {
            let remaining = totalBytes - bytesTransferred
            predictiveETA = throughputHistory.predictiveETA(
                remainingBytes: remaining,
                currentPhase: sample.phase.rawValue
            )
        }

        // Keep history bounded
        if phaseHistory.count > 1000 {
            phaseHistory.removeFirst(phaseHistory.count - 1000)
        }
    }

    /// Reset collector for new backup session
    func reset() {
        phaseHistory.removeAll()
        currentPhaseMetrics = nil
        throughputHistory.reset()
        throughputStats = nil
        throughputTrend = .insufficient
        predictiveETA = nil
    }
}