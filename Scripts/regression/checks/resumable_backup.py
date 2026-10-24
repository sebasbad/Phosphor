from __future__ import annotations

from pathlib import Path


def read(root: Path, rel: str) -> str:
    return (root / rel).read_text()


def assert_contains(text: str, needle: str, message: str) -> None:
    assert needle in text, message


def test_backup_manager_has_resume_and_sanitization_helpers(root: Path) -> None:
    src = (
        read(root, "Sources/Phosphor/Services/BackupManager.swift")
        + "\n"
        + read(root, "Sources/Phosphor/Services/BackupManager+Resumable.swift")
    )
    assert_contains(src, "case resumeBackup", "RecoveryAction must support resumeBackup")
    assert_contains(src, "func resumeIncompleteBackup", "BackupManager must implement resumeIncompleteBackup")
    assert_contains(src, "static func incompleteBackupHasPayloadData", "BackupManager must detect payload data in incomplete backups")
    assert_contains(src, "static func sanitizeIncompleteBackup", "BackupManager must provide metadata and WAL sanitization")
    assert_contains(src, "sqlite3_wal_checkpoint_v2", "Sanitization must checkpoint SQLite WAL frames before resumption")
    assert_contains(src, "PropertyListSerialization.propertyList", "Sanitization must validate plist stubs")


def test_backup_view_model_and_ui_support_resumable_backups(root: Path) -> None:
    vm_src = read(root, "Sources/Phosphor/ViewModels/BackupViewModel.swift")
    list_src = read(root, "Sources/Phosphor/Views/Backup/BackupListView.swift")

    assert_contains(vm_src, "func resumeBackup(udid: String", "BackupViewModel must expose resumeBackup")
    assert_contains(vm_src, "func resumeBackup(for issue:", "BackupViewModel must handle resumeBackup recovery actions")
    assert_contains(vm_src, "isResume: true", "Resume requests must set isResume flag")
    assert_contains(vm_src, "manager.resumeIncompleteBackup", "Worker must invoke resumeIncompleteBackup when isResume is true")

    assert_contains(list_src, "case .resumeBackup:", "BackupListView must handle resumeBackup recovery action")
    assert_contains(list_src, '"Resume Backup"', "BackupListView must show Resume Backup title")
    assert_contains(list_src, "secondaryActionTitle: issue.recoveryAction == .resumeBackup ? \"Delete & Start Fresh\" : nil", "BackupIssueSheet must offer Delete & Start Fresh as secondary action")


def test_readiness_center_supports_resumable_backups(root: Path) -> None:
    service_src = read(root, "Sources/Phosphor/Services/ReadinessService.swift")
    view_src = read(root, "Sources/Phosphor/Views/Readiness/ReadinessCenterView.swift")

    assert_contains(service_src, "case resumeBackup", "ReadinessOperation must support resumeBackup")
    assert_contains(service_src, "Incomplete Backup (Resumable)", "ReadinessService must title resumable backups distinctively")
    assert_contains(service_src, "BackupManager.incompleteBackupHasPayloadData", "ReadinessService must verify payload presence for resumability")

    assert_contains(view_src, 'Label("Resume Backup", systemImage: "play.circle.fill")', "ReadinessCenterView must offer Resume Backup button")
    assert_contains(view_src, "case .resumeBackup", "ReadinessCenterView must handle resumeBackup recovery operation")
    assert_contains(view_src, "backupVM.resumeBackup", "ReadinessCenterView must call backupVM.resumeBackup")


def test_upstream_feedback_invariants(root: Path) -> None:
    tracker = read(root, "Sources/Phosphor/Utilities/FinalizationProgressTracker.swift")
    assert "593_000" not in tracker, "FinalizationProgressTracker must not hardcode test-device file counts"
    assert "remBuckets * 3" not in tracker, "FinalizationProgressTracker must compute verification ETA from observed bucket rate"

    shell = read(root, "Sources/Phosphor/Utilities/Shell.swift")
    assert "500_000_000" not in shell, "cancelAndWait must not force-kill after 0.5s"
    assert_contains(shell, "Date().addingTimeInterval(streamTerminationGrace)", "cancelAndWait must give cooperative tools up to streamTerminationGrace before SIGKILL")

    manager = read(root, "Sources/Phosphor/Services/BackupManager.swift")
    vm = read(root, "Sources/Phosphor/ViewModels/BackupViewModel.swift")
    assert 'lower.contains("pin")' not in manager and 'lower.contains("pin")' not in vm, "passcode prompt detection must not match 'Skipping' via bare 'pin' substring"


def test_backup_health_state_metadata_guard_and_quarantine(root: Path) -> None:
    model = read(root, "Sources/Phosphor/Models/BackupInfo.swift")
    resumable = read(root, "Sources/Phosphor/Services/BackupManager+Resumable.swift")
    manager = read(root, "Sources/Phosphor/Services/BackupManager.swift")
    list_view = read(root, "Sources/Phosphor/Views/Backup/BackupListView.swift")

    assert_contains(model, "enum HealthState", "BackupInfo must define deterministic HealthState (.complete, .paused, .broken)")
    assert_contains(model, "static func computeHealthState", "BackupInfo must compute healthState from manifest, payload buckets, and SnapshotState")
    assert_contains(resumable, r'".\(udid)-phosphor-guard-bkp"', "Metadata rollback guard must use .<UDID>-phosphor-guard-bkp")
    assert_contains(resumable, '"-phosphor-quarantine-bkp-"', "Sanitization quarantine must use <UDID>-phosphor-quarantine-bkp-<timestamp>")
    assert_contains(resumable, '"-phosphor-broken-bkp-"', "Broken backup repair quarantine must use <UDID>-phosphor-broken-bkp-<timestamp>")
    assert_contains(manager, r'"\(udid)-phosphor-bkp-\(timestamp)"', "Archived full backups must use <UDID>-phosphor-bkp-<timestamp>")
    assert_contains(model, "var isArchivedSnapshot: Bool", "BackupInfo must distinguish archived snapshots from the active UDID slot")
    assert_contains(list_view, 'StatusChip(text: "Archived"', "Archived snapshots must display an Archived status chip")
    assert_contains(resumable, "static func stageMetadataGuard", "BackupManager must stage metadata guard before running backup tools")
    assert_contains(resumable, "static func restoreMetadataGuardIfNeeded", "BackupManager must restore clobbered metadata when backup aborts")
    assert_contains(resumable, "static func quarantineBrokenBackup", "BackupManager must quarantine broken backup folders non-destructively")
    assert_contains(manager, "if isAuxiliaryBackupDirectoryName(item) { continue }", "discoverBackups must ignore guard and quarantine directories")
    assert_contains(list_view, 'StatusChip(text: "Complete"', "Complete backups must display Complete health badge")
    assert_contains(list_view, 'StatusChip(text: "Paused"', "Paused backups must display Paused health badge")
    assert_contains(list_view, 'StatusChip(text: "Broken"', "Broken backups must display Broken health badge")
    assert_contains(list_view, 'return "Backing Up"', "Active backups must display Backing Up chip instead of static health badges")
    assert_contains(list_view, "backupVM.backups.contains { !$0.isArchivedSnapshot && $0.udid == udid }", "hasBackupRow must ignore archived snapshots so active backups are not suppressed")
    assert_contains(resumable, "static func latestBackupDiskActivityDate", "BackupManager must track disk modification timestamps during active backups")
    assert_contains(list_view, 'Button("Repair", action: onRepair)', "Broken backups must offer a Repair action")
    assert_contains(list_view, ".disabled(!isDeviceConnected)", "Resume and Repair actions must be disabled when the device is disconnected")


