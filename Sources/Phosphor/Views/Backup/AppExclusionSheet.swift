import SwiftUI

/// View for selective app data exclusion before running iOS backups (Issue #4).
/// Can be presented as a standalone sheet or embedded inside BackupPreflightSheet.
struct AppExclusionView: View {
    let udid: String
    var backupDirectory: String = BackupManager.defaultBackupDir
    @Binding var configuration: DeviceBackupConfiguration
    var onDismiss: () -> Void

    @StateObject private var appManager = AppManager()

    enum ViewTab: String, CaseIterable, Identifiable {
        case byApp = "Applications"
        case fileRules = "File Rules"
        case largestFiles = "Largest Files"

        var id: String { rawValue }
    }

    @State private var selectedTab: ViewTab = .byApp

    // App List State
    @State private var apps: [AppBackupTarget] = []
    @State private var isLoading = true
    @State private var searchText = ""
    @State private var sortOption: SortOption = .sizeDescending
    @State private var excludedBundleIds: Set<String> = []

    // File Rules State
    @State private var excludeMediaAbove50MB: Bool = false
    @State private var excludeAppCaches: Bool = false
    @State private var customPatternInput: String = ""
    @State private var excludedFilePatterns: [String] = []

    // Largest Files Explorer State
    @State private var largestFiles: [BackupManifest.FileEntry] = []
    @State private var isLoadingFiles = false
    @State private var fileSearchText = ""
    @State private var excludedRelativePaths: Set<String> = []
    @State private var manifestAvailable = false

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

    var filteredFiles: [BackupManifest.FileEntry] {
        if fileSearchText.isEmpty {
            return largestFiles
        }
        return largestFiles.filter {
            $0.fileName.localizedCaseInsensitiveContains(fileSearchText) ||
            $0.domain.localizedCaseInsensitiveContains(fileSearchText) ||
            $0.relativePath.localizedCaseInsensitiveContains(fileSearchText)
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
                    Text("Review apps, media rules, and individual file exclusions")
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

            // Reassurance & Architecture Banner
            VStack(alignment: .leading, spacing: 6) {
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

                Divider()

                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Text("iOS Backup Note: App binaries download from App Store. Excluded apps or media skip local payloads and will not transfer to a restored device.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 20)
            .padding(.bottom, 12)

            // Segmented Picker for Modes
            Picker("Mode", selection: $selectedTab) {
                ForEach(ViewTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 20)
            .padding(.bottom, 12)

            Divider()

            // Active Tab Content
            switch selectedTab {
            case .byApp:
                appsTabContent
            case .fileRules:
                fileRulesTabContent
            case .largestFiles:
                largestFilesTabContent
            }
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

                Picker("Sort", selection: $sortOption) {
                    ForEach(SortOption.allCases) { opt in
                        Text(opt.rawValue).tag(opt)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 170)

                Menu("Bulk Actions") {
                    Button("Skip Apps > 5 GB") {
                        excludeAppsAbove(bytes: 5 * 1024 * 1024 * 1024)
                    }
                    Button("Skip Apps > 1 GB") {
                        excludeAppsAbove(bytes: 1 * 1024 * 1024 * 1024)
                    }
                    Divider()
                    Button("Skip All Apps (Exclude All)") {
                        excludedBundleIds = Set(apps.map(\.id))
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

    // MARK: - Tab 2: File Rules

    private var fileRulesTabContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // Rule 1: Media Files Filter
                VStack(alignment: .leading, spacing: 8) {
                    Toggle(isOn: $excludeMediaAbove50MB) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Skip Large Media Files & Videos")
                                .font(.system(size: 13, weight: .semibold))
                            Text("Discards offline movies, videos, and audio binaries (.mp4, .mkv, .mov, .flac) across app sandboxes.")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.checkbox)
                }
                .padding(14)
                .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 10))

                // Rule 2: App Caches Filter
                VStack(alignment: .leading, spacing: 8) {
                    Toggle(isOn: $excludeAppCaches) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Skip App Caches & Temporary Files")
                                .font(.system(size: 13, weight: .semibold))
                            Text("Discards Library/Caches/* and tmp/* folders while preserving user databases, accounts, and settings.")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.checkbox)
                }
                .padding(14)
                .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 10))

                // Rule 3: Custom Pattern Filter
                VStack(alignment: .leading, spacing: 10) {
                    Text("Custom File Patterns to Exclude")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Exclude files matching specific filenames or extensions (e.g. *.iso, *.bin, *offline*).")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    HStack(spacing: 8) {
                        TextField("Pattern (e.g. *.iso, *cache*)", text: $customPatternInput)
                            .textFieldStyle(.roundedBorder)

                        Button("Add Pattern") {
                            let trimmed = customPatternInput.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !trimmed.isEmpty && !excludedFilePatterns.contains(trimmed) {
                                excludedFilePatterns.append(trimmed)
                                customPatternInput = ""
                            }
                        }
                        .disabled(customPatternInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }

                    if !excludedFilePatterns.isEmpty {
                        FlowLayout(spacing: 6) {
                            ForEach(excludedFilePatterns, id: \.self) { pattern in
                                HStack(spacing: 4) {
                                    Text(pattern)
                                        .font(.system(size: 11, design: .monospaced))
                                    Button {
                                        excludedFilePatterns.removeAll { $0 == pattern }
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.system(size: 11))
                                    }
                                    .buttonStyle(.plain)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color.orange.opacity(0.12), in: Capsule())
                                .foregroundStyle(.orange)
                            }
                        }
                        .padding(.top, 4)
                    }
                }
                .padding(14)
                .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 10))

                Spacer()
            }
            .padding(20)
        }
    }

    // MARK: - Tab 3: Largest Files Explorer

    private var largestFilesTabContent: some View {
        VStack(spacing: 0) {
            if isLoadingFiles {
                VStack(spacing: 16) {
                    ProgressView()
                    Text("Reading Manifest database for largest app files...")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !manifestAvailable {
                VStack(spacing: 12) {
                    Image(systemName: "doc.badge.gearshape")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                    Text("No Prior Local Backup Found")
                        .font(.headline)
                    Text("The Largest Files Explorer catalogs files from your existing backup. Run an initial backup or use File Rules to pre-filter media.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredFiles.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                    Text("No Matching Files Found")
                        .font(.headline)
                    Text("Try clearing the search query.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 12) {
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                        TextField("Search files by name or path...", text: $fileSearchText)
                            .textFieldStyle(.plain)
                        if !fileSearchText.isEmpty {
                            Button {
                                fileSearchText = ""
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

                    Text("\(filteredFiles.count) largest files")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)

                Divider()

                List(filteredFiles) { file in
                    HStack(spacing: 10) {
                        let isExcluded = excludedRelativePaths.contains(file.relativePath)
                        Toggle("", isOn: Binding(
                            get: { isExcluded },
                            set: { shouldExclude in
                                if shouldExclude {
                                    excludedRelativePaths.insert(file.relativePath)
                                } else {
                                    excludedRelativePaths.remove(file.relativePath)
                                }
                            }
                        ))
                        .labelsHidden()

                        Image(systemName: fileIcon(for: file.fileName))
                            .font(.title3)
                            .foregroundStyle(Color.brandAccent)
                            .frame(width: 24)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(file.fileName)
                                .font(.system(size: 12, weight: .semibold))
                                .lineLimit(1)
                            Text(file.domain.replacingOccurrences(of: "AppDomain-", with: ""))
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        Spacer()

                        Text(isExcluded ? "Skipped" : "Included")
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(
                                isExcluded ? Color.secondary.opacity(0.12) : Color.green.opacity(0.12),
                                in: RoundedRectangle(cornerRadius: 4)
                            )
                            .foregroundStyle(isExcluded ? Color.secondary : Color.green)

                        Text(ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file))
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundStyle(file.size > 500_000_000 ? .orange : .primary)
                    }
                    .padding(.vertical, 2)
                }
                .listStyle(.inset)
            }
        }
    }

    private func fileIcon(for name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "mp4", "mkv", "mov", "avi", "webm", "m4v":
            return "video.fill"
        case "mp3", "flac", "wav", "m4a":
            return "music.note"
        case "sqlite", "db", "sqlitedb":
            return "cylinder.split.1x2.fill"
        case "plist", "json", "xml":
            return "doc.badge.gearshape"
        case "jpg", "jpeg", "png", "heic":
            return "photo.fill"
        default:
            return "doc.fill"
        }
    }

    private func loadInitialData() {
        excludedBundleIds = configuration.excludedBundleIds
        excludeMediaAbove50MB = configuration.excludeMediaAbove50MB
        excludeAppCaches = configuration.excludeAppCaches
        excludedFilePatterns = configuration.excludedFilePatterns
        excludedRelativePaths = configuration.excludedRelativePaths

        Task {
            let targets = await appManager.listInstalledAppsWithSizes(udid: udid)
            await MainActor.run {
                self.apps = targets
                self.isLoading = false
            }
        }

        loadManifestFiles()
    }

    private func loadManifestFiles() {
        let targetBackupPath = (backupDirectory as NSString).appendingPathComponent(udid)
        guard FileManager.default.fileExists(atPath: (targetBackupPath as NSString).appendingPathComponent("Manifest.db")) else {
            manifestAvailable = false
            return
        }

        isLoadingFiles = true
        Task.detached {
            do {
                let manifest = try BackupManifest(backupPath: targetBackupPath)
                let files = try manifest.largestAppFiles(limit: 100)
                await MainActor.run {
                    self.largestFiles = files
                    self.manifestAvailable = true
                    self.isLoadingFiles = false
                }
            } catch {
                await MainActor.run {
                    self.manifestAvailable = false
                    self.isLoadingFiles = false
                }
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
        configuration.excludeAppCaches = excludeAppCaches
        configuration.excludedFilePatterns = excludedFilePatterns
        configuration.excludedRelativePaths = excludedRelativePaths
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
                get: { isExcluded },
                set: { onToggle($0) }
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

            // Status Badge
            Text(isExcluded ? "Skipped" : "Included")
                .font(.system(size: 10, weight: .bold))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    isExcluded ? Color.secondary.opacity(0.12) : Color.green.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 4)
                )
                .foregroundStyle(isExcluded ? Color.secondary : Color.green)

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

