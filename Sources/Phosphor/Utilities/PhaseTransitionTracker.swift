import Foundation
import OSLog

/// Tracks phase transitions with timestamps, durations, and metadata
/// Provides phase timeline visualization and duration analysis
final class PhaseTransitionTracker: @unchecked Sendable {

    // MARK: - State

    private var _transitions: [PhaseTransitionRecord] = []
    private var phaseStartTimes: [String: Date] = [:]
    private let logger = Logger(subsystem: "com.phosphor.backup", category: "phase-tracker")

    // MARK: - Public API

    /// Record a phase transition
    func recordTransition(from: String, to: String, metadata: [String: String]? = nil) {
        let now = Date()
        let fromStartTime = phaseStartTimes[from] ?? Date()
        let duration = from == to ? nil : now.timeIntervalSince(fromStartTime)

        let transition = PhaseTransitionRecord(
            from: BackupPhase(rawValue: from) ?? .detecting,
            to: BackupPhase(rawValue: to) ?? .detecting,
            timestamp: now,
            duration: from == to ? nil : duration,
            metadata: metadata
        )

        // Update tracking
        if from != to {
            phaseStartTimes[to] = Date()
        }

        _transitions.append(transition)

        logger.info("Phase transition: \(from) → \(to)\(duration.map { " (\(Self.formatDuration($0)))" } ?? "")")
    }

    /// Get all recorded transitions
    var transitions: [PhaseTransitionRecord] {
        _transitions
    }

    /// Get duration stats for a phase
    func durationStats(for phase: String) -> PhaseDurationStats? {
        nil
    }

    /// Get all phase durations
    var allPhaseDurations: [String: TimeInterval] {
        [:]
    }

    /// Get total backup duration
    var totalDuration: TimeInterval {
        0
    }

    /// Reset tracker for new backup session
    func reset() {
        _transitions.removeAll()
        phaseStartTimes.removeAll()
    }

    // MARK: - Private

    static func formatDuration(_ interval: TimeInterval) -> String {
        let total = Int(interval)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return "\(h)h \(m)m \(Int(interval.truncatingRemainder(dividingBy: 60)))s" }
        if m > 0 { return "\(m)m \(s)s" }
        return "\(Int(interval))s"
    }
}