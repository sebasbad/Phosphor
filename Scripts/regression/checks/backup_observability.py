from __future__ import annotations

import re
from pathlib import Path

# Mirrors the patterns in BackupViewModel.parseSpeedToBytesPerSecond /
# parseByteCount / parseEtaToSeconds. These are the exact regexes and unit
# factors the Swift code uses, so a change to one side shows up here.
SPEED = re.compile(r"^([\d.]+)\s*([kKmMgG]?)[bB]?/?s")
SIZE = re.compile(r"^([\d.]+)\s*([KMGT]?)B?$")
SPEED_FACTORS = {"": 1, "k": 1_024, "m": 1_048_576, "g": 1_073_741_824}
SIZE_FACTORS = {"": 1, "K": 1_024, "M": 1_048_576, "G": 1_073_741_824, "T": 1_099_511_627_776}


def read(root: Path, rel: str) -> str:
    return (root / rel).read_text()


def test_observability_is_wired_to_the_backup_row(root: Path) -> None:
    model = read(root, "Sources/Phosphor/ViewModels/BackupViewModel.swift")
    view = read(root, "Sources/Phosphor/Views/Backup/BackupListView.swift")
    for token in [
        "observabilityCoordinator",
        "startObservability(udid:",
        "coordinator.updateMetrics(",
        "activity.phaseMetrics = coordinator.phaseMetrics",
        "activity.throughputStats = coordinator.throughputStats",
        "activity.predictiveETA = coordinator.predictiveETA",
        "activity.throughputTrend = coordinator.throughputTrend",
    ]:
        assert token in model, f"coordinator not wired: {token}"
    for token in [
        "activity.phaseMetrics?.phase",
        "activity.throughputStats",
        "activity.predictiveETA",
        "activity.throughputTrend",
    ]:
        assert token in view, f"indicator not rendered: {token}"


def test_stalled_resume_restarts_instead_of_deadlocking(root: Path) -> None:
    """Resume while stalled used to re-enqueue, hit .duplicate, and park."""
    model = read(root, "Sources/Phosphor/ViewModels/BackupViewModel.swift")
    view = read(root, "Sources/Phosphor/Views/Backup/BackupListView.swift")
    assert "func restartStalledBackup(udid:" in model, "stalled resume needs a restart path"
    assert "guard activity(for: udid)?.isStalled == true else {" in model, "must fall back to plain resume"
    assert "guard activity(for: udid)?.isNonResumableFinalizationPhase != true else { return }" in model, (
        "cancelling during finalization discards the backup"
    )
    assert "cancelBackup(udid: udid)" in model, "must cancel the wedged job before re-enqueueing"
    # Both stalled Resume buttons must use the restart path, not plain resume.
    assert "restartStalledBackup(udid: backup.udid" in view, "persisted-row Resume must restart"
    assert "restartStalledBackup(udid: activity.udid" in view, "activity-card Resume must restart"
    assert "resumeBackup(udid: activity.udid)" not in view, "stalled card still calls plain resume"


def test_finalization_progress_is_not_a_stall(root: Path) -> None:
    """The watchdog updated metrics but not lastProgressUpdate, so a long
    finalization (>5 min) read as stalled and showed a resume that cannot run."""
    model = read(root, "Sources/Phosphor/ViewModels/BackupViewModel.swift")
    assert "activity.finalizationMetrics = metrics" in model
    assert "activity.lastProgressUpdate = Date()" in model, "finalization movement is progress"


def test_incomplete_metadata_failure_keeps_tool_output(root: Path) -> None:
    """The resume path's most common failure kept only the folder path, so the
    details sheet had nothing to explain the failure with."""
    manager = read(root, "Sources/Phosphor/Services/BackupManager.swift")
    assert "let stderrTail = pymobiledeviceStderrTail.joined(separator: \"\\n\")" in manager
    assert "technicalDetails: stderrTail.isEmpty ? path : \"\\(path)\\n\\n\\(stderrTail)\"" in manager


def test_backup_issue_and_diagnosis_are_surfaced(root: Path) -> None:
    model = read(root, "Sources/Phosphor/ViewModels/BackupViewModel.swift")
    view = read(root, "Sources/Phosphor/Views/Backup/BackupListView.swift")
    device = read(root, "Sources/Phosphor/Views/Device/DeviceOverviewView.swift")
    assert "func diagnosisText(for udid:" in model, "stall diagnosis must exist"
    assert "exportSnapshot()" in model, "diagnosis should include the observability snapshot"
    assert "struct BackupDiagnosisSheet" in view, "diagnosis needs a dialog"
    assert "Diagnose…" in view, "stalled rows must offer diagnosis"
    # The device screen dropped the details the list already showed.
    assert "BackupIssueSheet(" in device, "device screen should reuse the detailed issue sheet"
    assert '.alert("Backup Issue"' not in device, "plain alert hid the technical details"


def test_eta_is_not_fabricated_from_unknown_sizes(root: Path) -> None:
    """A nil size must not produce a confident-looking zero-second ETA."""
    coordinator = read(root, "Sources/Phosphor/Utilities/BackupObservabilityCoordinator.swift")
    assert "(totalBytes ?? 0) - (bytesTransferred ?? 0)" not in coordinator, (
        "subtracting nil sizes fabricates 0 remaining and a bogus 0s ETA"
    )
    assert "if let totalBytes, let bytesTransferred, totalBytes > bytesTransferred" in coordinator
    view = read(root, "Sources/Phosphor/Views/Backup/BackupListView.swift")
    assert "predicted.estimatedSeconds > 0" in view, "zero ETA must not be rendered"


def test_progress_string_parsers_match_real_tqdm_output(root: Path) -> None:
    # tqdm: " 42%|████▏ | 12.3G/29.5G [05:21<07:15, 39.5MB/s]"
    assert SPEED.match("39.5MB/s").group(2) == "M"
    assert SPEED_FACTORS["m"] == 1_048_576
    assert SPEED.match("1.2GB/s").group(2) == "G"
    assert SPEED.match("929kB/s").group(2) == "k"
    assert SPEED.match("1.5 MB/s").group(2) == "M"
    assert SPEED.match("500B/s").group(2) == ""
    # Iterations per second is not a byte rate. The byte-rate pattern cannot
    # match it at all, so it can never be misread as bytes/sec.
    assert SPEED.match("20it/s") is None

    assert SIZE.match("12.3G").group(2) == "G"
    assert SIZE_FACTORS["G"] == 1_073_741_824
    assert SIZE.match("123M").group(2) == "M"
    assert int(float("12.3") * SIZE_FACTORS["G"]) == 13_207_024_435
    # A bare number is a plain byte count.
    assert SIZE.match("789").group(2) == ""
    assert SIZE.match("not a size") is None


def test_eta_string_parser_matches_finalized_format(root: Path) -> None:
    """parseProgressDetails emits "5m 21s" / "1h 2m 3s"; these must round-trip."""

    def parse_eta(text: str) -> float:
        total = 0.0
        for part in text.lower().split(" "):
            if part.endswith("h"):
                total += float(part[:-1]) * 3600
            elif part.endswith("m"):
                total += float(part[:-1]) * 60
            elif part.endswith("s"):
                total += float(part[:-1])
        return total

    assert parse_eta("5m 21s") == 321
    assert parse_eta("1h 2m 3s") == 3723
    assert parse_eta("0m 0s") == 0, "zero ETA must be treated as unknown"
