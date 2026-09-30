import SwiftUI

/// Reusable sheet for actionable backup issues, failures, and recovery steps.
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
