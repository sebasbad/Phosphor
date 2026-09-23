import SwiftUI

/// View for selective app data exclusion before running iOS backups (Issue #4).
/// Can be presented as a standalone sheet or embedded inside BackupPreflightSheet.
struct AppExclusionView: View {
    let udid: String
    @Binding var configuration: DeviceBackupConfiguration
    var onDismiss: () -> Void

    @StateObject private var appManager = AppManager()

    @State private var apps: [AppBackupTarget] = []
    @State private var isLoading = true
    @State private var searchText = ""
    @State private var sortOption: SortOption = .sizeDescending
    @State private var excludedBundleIds: Set<String> = []
    @State private var excludeMediaAbove50MB: Bool = false

    enum SortOption: String, CaseIterable, Identifiable {
        case sizeDescending = "Largest Data First"
        case nameAscending = "Name (A-Z)"

        var id: String { rawValue }
    }

    var filteredApps: [AppBackupTarget] {
        var result = apps
        if !searchText.isEmpty {
            result = result.filter {
                $0.displayName.localizedCaseInsensitiveContains(searchText) ||
                $0.id.localizedCaseInsensitiveContains(searchText)
            }
        }
        switch sortOption {
        case .sizeDescending:
            return result.sorted {
                if $0.dynamicDiskBytes != $1.dynamicDiskBytes {
                    return $0.dynamicDiskBytes > $1.dynamicDiskBytes
                }
                return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
        case .nameAscending:
            return result.sorted {
                $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
        }
    }

    var totalExcludedBytes: Int64 {
        apps.filter { excludedBundleIds.contains($0.id) }
            .reduce(0) { $0 + $1.dynamicDiskBytes }
    }

    var formattedSavings: String {
        ByteCountFormatter.string(fromByteCount: totalExcludedBytes, countStyle: .file)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Button {
                    saveAndDismiss()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Options")
                            .font(.system(size: 13))
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.brandAccent)

                Spacer()

                VStack(spacing: 2) {
                    Text("Selective App Data Exclusion")
                        .font(.headline.weight(.semibold))
                    Text("Exclude bulky app caches or media from backup")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Done") {
                    saveAndDismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 12)

            // Reassurance & Savings Banner
            HStack(spacing: 12) {
                Image(systemName: "checkmark.shield.fill")
                    .font(.title3)
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text("System Data & Accounts are Always Protected")
                        .font(.caption.bold())
                        .foregroundStyle(.primary)
                    Text("Contacts, Keychain passwords, Messages, and System Settings are never excluded.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if totalExcludedBytes > 0 {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(excludedBundleIds.count) apps excluded")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text("Saving \(formattedSavings)")
                            .font(.caption.bold())
                            .foregroundStyle(Color.brandAccent)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.brandAccent.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding(12)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 20)
            .padding(.bottom, 12)

            // Controls: Search, Sort & Presets
            HStack(spacing: 12) {
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Filter apps...", text: $searchText)
                        .textFieldStyle(.plain)
                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))

                Picker("Sort", selection: $sortOption) {
                    ForEach(SortOption.allCases) { opt in
                        Text(opt.rawValue).tag(opt)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 170)

                Menu("Presets") {
                    Button("Exclude Apps > 5 GB") {
                        excludeAppsAbove(bytes: 5 * 1024 * 1024 * 1024)
                    }
                    Button("Exclude Apps > 1 GB") {
                        excludeAppsAbove(bytes: 1 * 1024 * 1024 * 1024)
                    }
                    Divider()
                    Button("Select All (Exclude All Apps)") {
                        excludedBundleIds = Set(apps.map(\.id))
                    }
                    Button("Clear All Exclusions") {
                        excludedBundleIds.removeAll()
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)

            Divider()

            // App List
            if isLoading {
                VStack(spacing: 16) {
                    ProgressView()
                    Text("Inspecting app storage footprints...")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredApps.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "app.badge.checkmark")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                    Text("No applications found")
                        .font(.headline)
                    Text("Try clearing the search query.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(filteredApps) { app in
                        HStack(spacing: 12) {
                            Toggle("", isOn: Binding(
                                get: { excludedBundleIds.contains(app.id) },
                                set: { isExcluded in
                                    if isExcluded {
                                        excludedBundleIds.insert(app.id)
                                    } else {
                                        excludedBundleIds.remove(app.id)
                                    }
                                }
                            ))
                            .labelsHidden()

                            Image(systemName: app.isSystemApp ? "apple.logo" : "app.fill")
                                .font(.title3)
                                .foregroundStyle(app.isSystemApp ? .secondary : Color.brandAccent)
                                .frame(width: 28, height: 28)

                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(app.displayName)
                                        .font(.system(size: 13, weight: .semibold))
                                    if app.isSystemApp {
                                        Text("System")
                                            .font(.system(size: 9, weight: .bold))
                                            .padding(.horizontal, 4)
                                            .padding(.vertical, 1)
                                            .background(Color.secondary.opacity(0.15), in: Capsule())
                                    }
                                }
                                Text(app.id)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            VStack(alignment: .trailing, spacing: 2) {
                                Text(app.formattedDynamicSize)
                                    .font(.system(size: 12, weight: .bold, design: .rounded))
                                    .foregroundStyle(app.dynamicDiskBytes > 1_000_000_000 ? .orange : .primary)
                                Text("Data & Cache")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
                .listStyle(.inset)
            }
        }
        .task {
            loadApps()
        }
    }

    private func loadApps() {
        excludedBundleIds = configuration.excludedBundleIds
        excludeMediaAbove50MB = configuration.excludeMediaAbove50MB

        Task {
            let targets = await appManager.listInstalledAppsWithSizes(udid: udid)
            await MainActor.run {
                self.apps = targets
                self.isLoading = false
            }
        }
    }

    private func excludeAppsAbove(bytes: Int64) {
        for app in apps where !app.isSystemApp && app.dynamicDiskBytes >= bytes {
            excludedBundleIds.insert(app.id)
        }
    }

    private func saveAndDismiss() {
        configuration.excludedBundleIds = excludedBundleIds
        configuration.excludeMediaAbove50MB = excludeMediaAbove50MB
        configuration.save(for: udid)
        onDismiss()
    }
}

/// Modal sheet wrapper for selective app data exclusion before running iOS backups (Issue #4).
struct AppExclusionSheet: View {
    let udid: String
    @Binding var configuration: DeviceBackupConfiguration
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        AppExclusionView(
            udid: udid,
            configuration: $configuration,
            onDismiss: {
                dismiss()
            }
        )
        .frame(minWidth: 550, idealWidth: 620, minHeight: 480, idealHeight: 560)
    }
}
