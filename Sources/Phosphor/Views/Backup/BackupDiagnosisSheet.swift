import SwiftUI

/// Reusable sheet for inspecting diagnosis output of a stalled or failing backup.
struct BackupDiagnosisSheet: View {
    let udid: String
    let text: String
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "stethoscope")
                    .foregroundStyle(.orange)
                    .font(.system(size: 24))
                VStack(alignment: .leading, spacing: 6) {
                    Text("Backup Diagnosis")
                        .font(.title3.weight(.semibold))
                    Text("What Phosphor last observed for this backup.")
                        .foregroundStyle(.secondary)
                }
            }

            ScrollView {
                Text(text)
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
                    NSPasteboard.general.setString(text, forType: .string)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 560)
    }
}
