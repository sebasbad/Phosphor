import SwiftUI

/// View for selective app data exclusion before running iOS backups (Issue #4).
/// Can be presented as a standalone sheet or embedded inside BackupPreflightSheet.
struct AppExclusionView: View {
    let udid: String
    var backupDirectory: String = BackupManager.defaultBackupDir
    @Binding var configuration: DeviceBackupConfiguration
    var onDismiss: () -> Void

    @StateObject private var appManager = AppManager()

    // App List State
    @State private var apps: [AppBackupTarget] = []
    @State private var isLoading = true
    @State private var searchText = ""
    @State private var sortOption: SortOption = .sizeDescending
    @State private var showAppleApps: Bool = false
    @State private var excludedBundleIds: Set<String> = []

    enum SortOption: String, CaseIterable, Identifiable {
        case sizeDescending = "Largest Total Size"
        case dynamicDescending = "Largest Data/Cache"
        case nameAscending = "Name (A-Z)"

        var id: String { rawValue }
    }

    var filteredApps: [AppBackupTarget] {
        var result = apps
        if !showAppleApps {
            result = result.filter { !$0.isSystemApp }
        }
        if !searchText.isEmpty {
            result = result.filter {
                $0.displayName.localizedCaseInsensitiveContains(searchText) ||
                $0.id.localizedCaseInsensitiveContains(searchText)
            }
        }
        switch sortOption {
        case .sizeDescending:
            return result.sorted {
                let s0 = $0.dynamicDiskBytes + $0.staticDiskBytes
                let s1 = $1.dynamicDiskBytes + $1.staticDiskBytes
                if s0 != s1 { return s0 > s1 }
                return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
        case .dynamicDescending:
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
                    Text("Profile Details & Custom Inclusions")
                        .font(.headline.weight(.semibold))
                    Text("System passwords, Keychain, and Messages are always included.")
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

            Divider()

            appsTabContent
        }
        .task {
            loadInitialData()
        }
    }

    // MARK: - Tab 1: By Application

    private var appsTabContent: some View {
        VStack(spacing: 0) {
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

                Toggle(isOn: $showAppleApps) {
                    Text("Apple Apps")
                        .font(.system(size: 11))
                }
                .toggleStyle(.checkbox)
                .help("Show pre-installed Apple stock applications")

                Picker("Sort", selection: $sortOption) {
                    ForEach(SortOption.allCases) { opt in
                        Text(opt.rawValue).tag(opt)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 170)

                Menu("Bulk Actions") {
                    Button("Exclude Apps > 5 GB") {
                        excludeAppsAbove(bytes: 5 * 1024 * 1024 * 1024)
                    }
                    Button("Exclude Apps > 2 GB") {
                        excludeAppsAbove(bytes: 2 * 1024 * 1024 * 1024)
                    }
                    Button("Exclude Apps > 1 GB") {
                        excludeAppsAbove(bytes: 1 * 1024 * 1024 * 1024)
                    }
                    Button("Exclude Apps > 500 MB") {
                        excludeAppsAbove(bytes: 500 * 1024 * 1024)
                    }
                    Button("Exclude Apps > 100 MB") {
                        excludeAppsAbove(bytes: 100 * 1024 * 1024)
                    }
                    Divider()
                    Button("Exclude All User Apps") {
                        let userApps = apps.filter { !$0.isSystemApp }
                        excludedBundleIds.formUnion(userApps.map(\.id))
                    }
                    Button("Exclude All Listed Apps") {
                        excludedBundleIds = Set(filteredApps.map(\.id))
                    }
                    Button("Include All Apps (Reset)") {
                        excludedBundleIds.removeAll()
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)

            Divider()

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
                List(filteredApps) { app in
                    AppRowView(
                        app: app,
                        isExcluded: excludedBundleIds.contains(app.id),
                        onToggle: { isExcluded in
                            if isExcluded {
                                excludedBundleIds.insert(app.id)
                            } else {
                                excludedBundleIds.remove(app.id)
                            }
                        }
                    )
                }
                .listStyle(.inset)
            }
        }
    }

    private func loadInitialData() {
        excludedBundleIds = configuration.excludedBundleIds

        Task {
            let targets = await appManager.listInstalledAppsWithSizes(udid: udid)
            await MainActor.run {
                self.apps = targets
                self.isLoading = false
            }
        }
    }

    private func excludeAppsAbove(bytes: Int64) {
        for app in apps {
            if !showAppleApps && app.isSystemApp { continue }
            let totalBytes = app.dynamicDiskBytes + app.staticDiskBytes
            if totalBytes >= bytes || app.dynamicDiskBytes >= bytes {
                excludedBundleIds.insert(app.id)
            }
        }
    }

    private func saveAndDismiss() {
        configuration.excludedBundleIds = excludedBundleIds
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

/// Extracted row view for an application target in the backup inclusion/exclusion list.
struct AppRowView: View {
    let app: AppBackupTarget
    let isExcluded: Bool
    let onToggle: (Bool) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Toggle("", isOn: Binding(
                get: { !isExcluded },
                set: { isIncluded in onToggle(!isIncluded) }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()

            Image(systemName: app.isSystemApp ? "apple.logo" : "app.fill")
                .font(.title3)
                .foregroundStyle(isExcluded ? Color.secondary.opacity(0.6) : (app.isSystemApp ? Color.secondary : Color.brandAccent))
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(app.displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(isExcluded ? .secondary : .primary)
                    if app.isSystemApp {
                        Text("Apple")
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.15), in: Capsule())
                    }
                    if isExcluded {
                        Text("Excluded from backup")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
                Text(app.id)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(app.formattedDynamicSize)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(isExcluded ? Color.secondary : (app.dynamicDiskBytes > 1_000_000_000 ? Color.orange : Color.primary))
                Text(app.staticDiskBytes > 0 ? "Total: \(app.formattedTotalSize)" : "Data & Cache")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }
}

