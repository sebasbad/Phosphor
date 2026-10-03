import SwiftUI
import AppKit

struct BackupStateNotice: View {
    let title: String
    let detail: String
    let icon: String
    let tint: Color

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(12)
        .background(tint.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

struct BackupIssueSheet: View {
    let issue: BackupManager.BackupFailure
    let primaryActionTitle: String?
    let primaryAction: () -> Void
    var secondaryActionTitle: String? = nil
    var secondaryAction: (() -> Void)? = nil
    let dismiss: () -> Void
    @State private var showTechnicalDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.system(size: 24))
                VStack(alignment: .leading, spacing: 6) {
                    Text(issue.title)
                        .font(.title3.weight(.semibold))
                    Text(issue.message)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            if let details = issue.technicalDetails, !details.isEmpty {
                DisclosureGroup("Technical details", isExpanded: $showTechnicalDetails) {
                    ScrollView {
                        Text(details)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                    .frame(minHeight: 90, maxHeight: 220)
                    .background(Color.secondary.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }

            HStack {
                if let secondaryActionTitle, let secondaryAction {
                    Button(secondaryActionTitle, role: .destructive) {
                        secondaryAction()
                    }
                }
                Spacer()
                Button("Cancel") { dismiss() }
                if let primaryActionTitle {
                    Button(primaryActionTitle, role: issue.recoveryAction == .deleteIncompleteAndRunFull ? .destructive : nil) {
                        primaryAction()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}

/// Live diagnosis for a stalled or failing backup.
struct BackupDiagnosisSheet: View {
    let udid: String
    let text: String
    let dismiss: () -> Void
    @EnvironmentObject private var backupVM: BackupViewModel
    @State private var liveText: String = ""
    @State private var refreshTimer: Timer?

    private var currentText: String {
        if !liveText.isEmpty { return liveText }
        return text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "stethoscope")
                    .foregroundStyle(.orange)
                    .font(.system(size: 24))
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text("Backup Diagnosis")
                            .font(.title3.weight(.semibold))
                        if backupVM.isBackupActive(for: udid) {
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(Color.green)
                                    .frame(width: 7, height: 7)
                                Text("Live (Updating 1s)")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    Text("What Phosphor last observed for this backup.")
                        .foregroundStyle(.secondary)
                }
            }

            ScrollView {
                Text(currentText)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(minHeight: 160, maxHeight: 360)
            .background(Color.secondary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            HStack {
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(currentText, forType: .string)
                }
                Spacer()
                Button("Done") {
                    refreshTimer?.invalidate()
                    refreshTimer = nil
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 560)
        .onAppear {
            liveText = backupVM.diagnosisText(for: udid) ?? text
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
                Task { @MainActor in
                    if let updated = backupVM.diagnosisText(for: udid) {
                        liveText = updated
                    }
                }
            }
        }
        .onDisappear {
            refreshTimer?.invalidate()
            refreshTimer = nil
        }
    }
}
