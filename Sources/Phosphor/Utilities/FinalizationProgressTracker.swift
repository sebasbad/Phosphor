import Foundation

/// Lightweight, non-blocking inspector that measures file reorganization progress,
/// migration rate, and dynamic ETA during the `SnapshotState == 'moving'` finalization phase.
final class FinalizationProgressTracker: @unchecked Sendable {

    struct Metrics: Equatable {
        let filesMoved: Int
        let filesRemaining: Int
        let totalFiles: Int
        let phaseFraction: Double
        let speedFilesPerSec: Double?
        let etaSeconds: TimeInterval?

        var formattedSpeed: String? {
            guard let speed = speedFilesPerSec, speed > 0.1 else { return nil }
            return "\(Int(speed)) files/s"
        }

        var formattedETA: String? {
            guard let eta = etaSeconds, eta > 0 else { return nil }
            let total = Int(eta)
            let m = (total / 60) % 60
            let h = total / 3600
            let s = total % 60
            if h > 0 {
                return "\(h)h \(m)m"
            } else if m > 0 {
                return "\(m)m \(s)s"
            } else {
                return "\(s)s"
            }
        }
    }

    private let backupDirectory: String
    private let udid: String
    private var lastSampleEpoch: TimeInterval?
    private var lastFilesMoved: Int?

    init(backupDirectory: String, udid: String) {
        self.backupDirectory = backupDirectory
        self.udid = udid
    }

    /// Samples hash bucket `00` in root vs `Snapshot/00` to calculate statistical progression.
    /// Fast APFS directory read takes < 30ms and does not add I/O pressure.
    func sampleMetrics() -> Metrics? {
        let deviceDir = (backupDirectory as NSString).appendingPathComponent(udid)
        let rootBucket = (deviceDir as NSString).appendingPathComponent("00")
        let snapBucket = ((deviceDir as NSString).appendingPathComponent("Snapshot") as NSString).appendingPathComponent("00")

        let fm = FileManager.default
        guard fm.fileExists(atPath: rootBucket) || fm.fileExists(atPath: snapBucket) else {
            return nil
        }

        let rootCount = (try? fm.contentsOfDirectory(atPath: rootBucket).count) ?? 0
        let snapCount = (try? fm.contentsOfDirectory(atPath: snapBucket).count) ?? 0
        let totalSample = rootCount + snapCount
        guard totalSample > 0 else { return nil }

        // Extrapolate across all 256 hash buckets (00 through ff)
        let filesMoved = rootCount * 256
        let filesRemaining = snapCount * 256
        let totalFiles = totalSample * 256
        let phaseFraction = Double(rootCount) / Double(totalSample)

        let now = Date().timeIntervalSince1970
        var speed: Double?
        var eta: TimeInterval?

        if let prevEpoch = lastSampleEpoch, let prevMoved = lastFilesMoved {
            let dt = now - prevEpoch
            let dMoved = filesMoved - prevMoved
            if dt >= 2.0 && dMoved >= 0 {
                let currentSpeed = Double(dMoved) / dt
                if currentSpeed > 0.1 {
                    speed = currentSpeed
                    eta = Double(filesRemaining) / currentSpeed
                }
            }
        }

        lastSampleEpoch = now
        lastFilesMoved = filesMoved

        return Metrics(
            filesMoved: filesMoved,
            filesRemaining: filesRemaining,
            totalFiles: totalFiles,
            phaseFraction: phaseFraction,
            speedFilesPerSec: speed,
            etaSeconds: eta
        )
    }
}
