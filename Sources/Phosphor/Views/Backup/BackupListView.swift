import AppKit
import SwiftUI

/// Lists all discovered iOS backups with metadata. Allows creating new backups and managing existing ones.
struct BackupListView: View {

    @EnvironmentObject var deviceVM: DeviceViewModel
    @EnvironmentObject var backupVM: BackupViewModel
    var onBrowseBackup: () -> Void = {}
    @State private var showDeleteConfirm = false
    @State private var backupToDelete: BackupInfo?
    @State private var showImportArchive = false
    @State private var archiveProgress: String?
    @State private var isArchiving = false
    @State private var showScheduleSheet = false
    @State private var showFullWiFiBackupConfirm = false
    @State private var pendingFullWiFiBackupUDID: String?
    @State private var pendingFullWiFiBackupPrefersNetwork = false
    @State private var showIncompleteBackupTrashConfirm = false
    @State private var pendingIncompleteBackupIssue: BackupManager.BackupFailure?
    @State private var cachedIncompleteStats: BackupManager.IncompleteBackupStats?
    @State private var isLoadingIncompleteStats = false
    @State private var showNonResumableCancelConfirm = false
    @State private var pendingCancelActivityUDID: String?
    @State private var diagnosisUDID: String?
    @State private var showDiagnosisSheet = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 14) {
                GradientIconTile(systemName: "externaldrive.fill", color: .blue, size: 40, iconSize: 19)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Backups")
                        .font(.title2.weight(.semibold))
                    Text(backupSummary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                newBackupMenu
                .buttonStyle(.borderedProminent)
                .tint(deviceVM.selectedDevice.map { hasResumableBackup(for: $0) } == true ? .orange : .brandAccent)

                Button {
                    backupVM.loadBackups()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .padding(20)

            Divider()

            backupStateNotice

            if !activeBackupActivities.isEmpty {
                BackupActivityList(
                    activities: activeBackupActivities,
                    devices: deviceVM.devices,
                    onResumeStalled: { act in
                        Task { await backupVM.restartStalledBackup(udid: act.udid, device: deviceVM.devices.first(where: { $0.id == act.udid })) }
                    },
                    onCancel: { act in
                        if act.isNonResumableFinalizationPhase {
                            pendingCancelActivityUDID = act.udid
                            showNonResumableCancelConfirm = true
                        } else {
                            backupVM.cancelBackup(udid: act.udid)
                        }
                    },
                    onDiagnose: { udid in
                        diagnosisUDID = udid
                        showDiagnosisSheet = true
                    }
                )
            }

            if let err = backupVM.loadError, backupVM.backups.isEmpty {
                backupLoadErrorBanner(err)
            }

            if backupVM.backups.isEmpty {
                if let device = deviceVM.selectedDevice, hasResumableBackup(for: device), !backupVM.isBackupActive(for: device.id) {
                    ResumableBackupHeroCard(
                        device: device,
                        onResume: {
                            Task { await backupVM.resumeBackup(udid: device.id, preferNetwork: device.connectionType == .wifi, device: device) }
                        },
                        onDiscard: { path in
                            pendingIncompleteBackupIssue = BackupManager.BackupFailure(
                                title: "Discard Incomplete Backup",
                                message: "Move preserved partial data to Trash and run a fresh backup.",
                                technicalDetails: path,
                                recoveryAction: .deleteIncompleteAndRunFull,
                                udid: device.id,
                                recoveryPath: path
                            )
                            showIncompleteBackupTrashConfirm = true
                        }
                    )
                } else if activeBackupActivities.isEmpty {
                    EmptyStateView(
                        icon: "externaldrive",
                        title: "No Backups Found",
                        subtitle: "Back up your device, or pick an existing backup folder via New Backup -> Open Existing Backup Folder.",
                        action: {
                            guard let device = deviceVM.selectedDevice else { return }
                            startBackup(for: device, incremental: shouldOfferIncremental(for: device))
                        },
                        actionLabel: emptyStateBackupActionLabel,
                        color: .brandAccent
                    )
                } else {
                    Spacer(minLength: 0)
                }
            } else {
                List {
                    ForEach(backupVM.backups) { backup in
                        BackupRow(
                            backup: backup,
                            activity: backupVM.activity(for: backup.udid)
                        ) {
                            if backupVM.openBackupBrowser(backup) {
                                onBrowseBackup()
                            }
                        } onDelete: {
                            backupToDelete = backup
                            showDeleteConfirm = true
                        } onResume: {
                            Task { await backupVM.restartStalledBackup(udid: backup.udid, device: deviceVM.devices.first(where: { $0.id == backup.udid })) }
                        } onPause: {
                            pauseBackupActivity(for: backup.udid)
                        } onDiagnose: {
                            diagnosisUDID = backup.udid
                            showDiagnosisSheet = true
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .alert("Delete Backup?", isPresented: $showDeleteConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                if let backup = backupToDelete {
                    backupVM.deleteBackup(backup)
                }
            }
        } message: {
            if let backup = backupToDelete {
                Text("This will permanently delete \(backup.deviceIdentityLabel) (\(backup.sizeResolved ? backup.sizeString : "size calculating")). This cannot be undone.")
            }
        }
        .alert("Backup", isPresented: $backupVM.showAlert) {
            Button("OK") {}
        } message: {
            Text(backupVM.alertMessage)
        }
        .sheet(item: $backupVM.backupIssue) { issue in
            BackupIssueSheet(
                issue: issue,
                primaryActionTitle: backupIssueActionTitle(for: issue),
                primaryAction: { handleBackupIssueAction(issue) },
                secondaryActionTitle: issue.recoveryAction == .resumeBackup ? "Delete & Start Fresh" : nil,
                secondaryAction: issue.recoveryAction == .resumeBackup ? {
                    pendingIncompleteBackupIssue = issue
                    backupVM.backupIssue = nil
                    showIncompleteBackupTrashConfirm = true
                } : nil,
                dismiss: { backupVM.backupIssue = nil }
            )
        }
        .alert("Move Incomplete Backup to Trash?", isPresented: $showIncompleteBackupTrashConfirm) {
            Button("Move to Trash & Run Full Backup", role: .destructive) {
                if let issue = pendingIncompleteBackupIssue {
                    Task { await backupVM.deleteIncompleteBackupAndRunFull(for: issue) }
                }
                pendingIncompleteBackupIssue = nil
            }
            Button("Cancel", role: .cancel) {
                pendingIncompleteBackupIssue = nil
            }
        } message: {
            Text(incompleteBackupTrashConfirmationMessage)
        }
        .alert("Full Wi-Fi Backup?", isPresented: $showFullWiFiBackupConfirm) {
            Button("Run Full Wi-Fi Backup") {
                if let udid = pendingFullWiFiBackupUDID {
                    let preferNetwork = pendingFullWiFiBackupPrefersNetwork
                    Task { await backupVM.createBackup(udid: udid, incremental: false, preferNetwork: preferNetwork) }
                }
                pendingFullWiFiBackupUDID = nil
                pendingFullWiFiBackupPrefersNetwork = false
            }
            Button("Cancel", role: .cancel) {
                pendingFullWiFiBackupUDID = nil
                pendingFullWiFiBackupPrefersNetwork = false
            }
        } message: {
            Text(fullWiFiBackupConfirmationMessage)
        }
        .alert("Pause Backup During Finalization?", isPresented: $showNonResumableCancelConfirm) {
            Button("Keep Running", role: .cancel) {
                pendingCancelActivityUDID = nil
            }
            Button("Pause and Keep Incomplete") {
                if let udid = pendingCancelActivityUDID {
                    backupVM.cancelBackup(udid: udid)
                }
                pendingCancelActivityUDID = nil
            }
        } message: {
            Text("All files transferred so far are safely preserved on disk. Because the backup is currently consolidating and sealing its files, stopping now will save it as an Incomplete backup. You can click Resume anytime to finish finalization.")
        }
        .sheet(isPresented: $showScheduleSheet) {
            BackupScheduleSheet()
                .frame(width: 480, height: 500)
        }
        .sheet(isPresented: $showDiagnosisSheet) {
            BackupDiagnosisSheet(
                udid: diagnosisUDID ?? "",
                text: diagnosisUDID.flatMap { backupVM.diagnosisText(for: $0) }
                    ?? "No live activity for this device.",
                dismiss: { showDiagnosisSheet = false; diagnosisUDID = nil }
            )
        }
        .onAppear { backupVM.loadBackups() }
    }

    private var newBackupMenu: some View {
        Menu {
            backupCreationButtons

            Divider()

            Button {
                importPhosphorArchive()
            } label: {
                Label("Import .phosphor Archive", systemImage: "square.and.arrow.down")
            }

            Button {
                backupVM.openExistingBackupFolder()
            } label: {
                Label("Open Existing Backup Folder...", systemImage: "folder")
            }

            Divider()

            Button {
                showScheduleSheet = true
            } label: {
                Label("Schedule Backups...", systemImage: "clock")
            }
        } label: {
            if let device = deviceVM.selectedDevice, hasResumableBackup(for: device) {
                Label("Resume Backup", systemImage: "play.circle.fill")
            } else {
                Label("New Backup", systemImage: "plus")
            }
        }
    }

    private var activeBackupActivities: [BackupViewModel.BackupActivity] {
        backupVM.backupActivities.values
            .filter(\.isActive)
            .filter { !hasBackupRow(for: $0.udid) }
            .sorted { lhs, rhs in
                switch (lhs.state, rhs.state) {
                case (.running, .queued): true
                case (.queued, .running): false
                default: lhs.udid < rhs.udid
                }
            }
    }

    /// Pause & Save for a backup rendered inside its persisted row. Finalization
    /// is not resumable, so it needs the same confirmation the activity card shows.
    private func pauseBackupActivity(for udid: String) {
        guard let activity = backupVM.activity(for: udid) else { return }
        if activity.isNonResumableFinalizationPhase {
            pendingCancelActivityUDID = udid
            showNonResumableCancelConfirm = true
        } else {
            backupVM.cancelBackup(udid: udid)
        }
    }

    /// True when a device with an in-flight backup already has a persisted row.
    /// That row renders the activity inline, so the standalone activity card
    /// would be a second surface for the same device.
    private func hasBackupRow(for udid: String) -> Bool {
        backupVM.backups.contains { $0.udid == udid }
    }

    private var backedUpDeviceCount: Int {
        Set(backupVM.backups.map { backup in
            backup.udid.isEmpty ? "backup:\(backup.id)" : "device:\(backup.udid)"
        }).count
    }

    private var backupSummary: String {
        let backupWord = backupVM.backups.count == 1 ? "backup" : "backups"
        let deviceWord = backedUpDeviceCount == 1 ? "device" : "devices"
        return "\(backupVM.backups.count) \(backupWord) across \(backedUpDeviceCount) \(deviceWord) - \(backupVM.totalSize) total"
    }

    private var selectedDeviceBackupIsActive: Bool {
        deviceVM.selectedDevice.map { backupVM.isBackupActive(for: $0.id) } == true
    }


    @ViewBuilder
    private var backupStateNotice: some View {
        if let device = deviceVM.selectedDevice {
            // Suppress banner notice when the empty state already acts as the dedicated resumable hero card
            if backupVM.backups.isEmpty && hasResumableBackup(for: device) {
                EmptyView()
            } else {
                let state = backupState(for: device)
                BackupStateNotice(title: state.title, detail: state.detail, icon: state.icon, tint: state.tint)
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
            }
        }
    }

    private func hasResumableBackup(for device: DeviceInfo) -> Bool {
        if case .incomplete(let path) = BackupManager.backupMetadataHealth(for: device.id) {
            return BackupManager.incompleteBackupHasPayloadData(path)
        }
        return false
    }

    private func backupState(for device: DeviceInfo) -> (title: String, detail: String, icon: String, tint: Color) {
        if hasResumableBackup(for: device) {
            return (
                "Interrupted backup found",
                "Saved files from your previous backup were preserved. Resume will continue transferring where it left off.",
                "pause.circle.fill",
                .orange
            )
        }

        let hasCompleteBackup = shouldOfferIncremental(for: device)
        if device.connectionType == .wifi {
            if hasCompleteBackup {
                return (
                    "Wi-Fi backup ready",
                    "Incremental Wi-Fi backups are available. Keep the device unlocked and on the same network while the backup runs.",
                    "wifi",
                    .blue
                )
            }
            return (
                "First backup must be full",
                "USB is recommended for the first backup. Wi-Fi is supported, but it is slower and more sensitive to sleep, lock, and network interruptions.",
                "externaldrive.badge.plus",
                .orange
            )
        }

        return (
            hasCompleteBackup ? "USB backup ready" : "USB recommended for first backup",
            hasCompleteBackup ? "USB is the fastest and most reliable way to refresh this backup." : "Create a full USB backup first. After that, incremental backups can update only changed files.",
            "cable.connector",
            .green
        )
    }

    @ViewBuilder
    private var backupCreationButtons: some View {
        if let device = deviceVM.selectedDevice, hasResumableBackup(for: device) {
            Button {
                Task { await backupVM.resumeBackup(udid: device.id, preferNetwork: device.connectionType == .wifi, device: device) }
            } label: {
                Label("Resume Saved Backup", systemImage: "play.circle.fill")
            }
            .disabled(deviceVM.selectedDevice == nil)

            Divider()
        }

        if deviceVM.selectedDevice?.connectionType == .wifi {
            if let device = deviceVM.selectedDevice, shouldOfferIncremental(for: device) {
                Button {
                    startBackup(for: device, incremental: true)
                } label: {
                    Label("Incremental Wi-Fi Backup (Recommended)", systemImage: "wifi")
                }
                .disabled(deviceVM.selectedDevice == nil)
            } else {
                Button {
                    guard let device = deviceVM.selectedDevice else { return }
                    startBackup(for: device, incremental: false)
                } label: {
                    Label("First Wi-Fi Backup (Full)", systemImage: "externaldrive.badge.plus")
                }
                .disabled(deviceVM.selectedDevice == nil)
            }

            if let device = deviceVM.selectedDevice, shouldOfferIncremental(for: device) {
                Button {
                    startBackup(for: device, incremental: false)
                } label: {
                    Label("Full Wi-Fi Backup (Slower)", systemImage: "externaldrive.badge.plus")
                }
                .disabled(deviceVM.selectedDevice == nil)
            }
        } else {
            Button {
                guard let device = deviceVM.selectedDevice else { return }
                startBackup(for: device, incremental: false)
            } label: {
                Label("Full USB Backup (Fastest)", systemImage: "externaldrive.badge.plus")
            }
            .disabled(deviceVM.selectedDevice == nil)

            Button {
                guard let device = deviceVM.selectedDevice else { return }
                startBackup(for: device, incremental: true)
            } label: {
                Label("Incremental Backup", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(deviceVM.selectedDevice == nil)
        }
    }

    private func startBackup(for device: DeviceInfo, incremental: Bool) {
        if device.connectionType == .wifi && !incremental {
            pendingFullWiFiBackupUDID = device.id
            pendingFullWiFiBackupPrefersNetwork = true
            showFullWiFiBackupConfirm = true
            return
        }
        Task { await backupVM.createBackup(udid: device.id, incremental: incremental, preferNetwork: device.connectionType == .wifi) }
    }

    private func importPhosphorArchive() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.init(filenameExtension: BackupArchiver.fileExtension)].compactMap { $0 }
        panel.message = "Select a .phosphor backup archive to import"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        isArchiving = true
        archiveProgress = "Importing archive..."

        Task {
            let result = await BackupArchiver.importArchive(from: url.path) { progress in
                archiveProgress = progress
            }
            isArchiving = false
            archiveProgress = nil
            if result != nil {
                backupVM.loadBackups()
                backupVM.alertMessage = "Archive imported"
                backupVM.showAlert = true
            } else {
                backupVM.alertMessage = "Failed to import archive"
                backupVM.showAlert = true
            }
        }
    }

    private var emptyStateBackupActionLabel: String? {
        guard let device = deviceVM.selectedDevice else { return nil }
        if hasResumableBackup(for: device) {
            return "Resume Backup"
        }
        if device.connectionType == .wifi {
            return shouldOfferIncremental(for: device) ? "Create Incremental Wi-Fi Backup" : "Create Full Wi-Fi Backup"
        }
        return "Create Backup"
    }

    private var fullWiFiBackupConfirmationMessage: String {
        guard let device = deviceVM.selectedDevice else {
            return "This device is connected over Wi-Fi. Full backups can be slower and more sensitive to interruptions."
        }
        if shouldOfferIncremental(for: device) {
            return "This device is connected over Wi-Fi. Full backups can be much slower and more sensitive to sleep, lock, and network interruptions. Incremental Wi-Fi Backup is recommended unless you specifically need a full backup."
        }
        return "This is the first backup for this device, so it must be a full backup. USB is recommended for the first backup; Wi-Fi is supported but slower and more sensitive to sleep, lock, and network interruptions."
    }

    private var incompleteBackupTrashConfirmationMessage: String {
        guard let issue = pendingIncompleteBackupIssue else { return "This will move the incomplete backup folder to Trash." }
        let path = issue.recoveryPath ?? issue.technicalDetails ?? "Unknown path"
        let device = issue.udid.map { " for device \($0)" } ?? ""
        return "This will move this incomplete backup folder\(device) to Trash, then run a full backup:\n\n\(path)\n\nPhosphor will not permanently delete the folder. You can restore it from Trash if needed."
    }

    private func backupIssueActionTitle(for issue: BackupManager.BackupFailure) -> String? {
        switch issue.recoveryAction {
        case .resumeBackup:
            return "Resume Backup"
        case .runFullBackup:
            return "Run Full Backup"
        case .deleteIncompleteAndRunFull:
            return "Delete Incomplete Backup & Run Full"
        case .openBackupSettings:
            return "Open Backup Settings"
        case .retry:
            return "Retry"
        case .none:
            return nil
        }
    }

    private func handleBackupIssueAction(_ issue: BackupManager.BackupFailure) {
        switch issue.recoveryAction {
        case .resumeBackup:
            backupVM.backupIssue = nil
            Task { await backupVM.resumeBackup(for: issue) }
        case .runFullBackup:
            backupVM.backupIssue = nil
            Task { await backupVM.runFullBackup(for: issue) }
        case .deleteIncompleteAndRunFull:
            pendingIncompleteBackupIssue = issue
            backupVM.backupIssue = nil
            showIncompleteBackupTrashConfirm = true
        case .openBackupSettings:
            backupVM.backupIssue = nil
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        case .retry:
            Task { await backupVM.retryBackup(for: issue) }
        case .none:
            backupVM.backupIssue = nil
        }
    }

    private func shouldOfferIncremental(for device: DeviceInfo) -> Bool {
        BackupManager.hasExistingBackup(for: device.id) && backupVM.backups.contains { backup in
            backup.udid == device.id || backup.id == device.id
        }
    }


    private func deviceIdentity(for udid: String) -> String {
        let suffix = String(udid.suffix(8))
        guard let device = deviceVM.devices.first(where: { $0.id == udid }) else {
            return "Device · ID …\(suffix)"
        }
        return "\(device.name) · \(device.displayModelName) · ID …\(suffix)"
    }

    @ViewBuilder
    private func backupLoadErrorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.system(size: 16))
            VStack(alignment: .leading, spacing: 4) {
                Text("Cannot read backup directory")
                    .font(.system(size: 13, weight: .semibold))
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
            Button("Pick Folder...") {
                backupVM.openExistingBackupFolder()
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Color.orange.opacity(0.08))
    }
}

