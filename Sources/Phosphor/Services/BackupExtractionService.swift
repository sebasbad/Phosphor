import Foundation

/// Handles selective file and domain extraction from iOS backup manifests.
enum BackupExtractionService {

    /// Build the destination path for one manifest entry, relative to the chosen folder.
    static func extractionRelativePath(for entry: BackupManifest.FileEntry) -> String {
        var safeDomain = entry.domain
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        if safeDomain == "." || safeDomain == ".." || safeDomain.isEmpty {
            safeDomain = "_"
        }
        var components = [safeDomain]
        let relativeComponents = entry.relativePath
            .split(separator: "/")
            .map(String.init)
            .filter { !$0.isEmpty && $0 != "." && $0 != ".." }
        components += relativeComponents

        if relativeComponents.isEmpty || entry.relativePath.hasSuffix("/") {
            components.append(entry.fileName)
        }
        return components.joined(separator: "/")
    }

    /// Extract selected file entries from a backup to a local destination directory.
    static func extractFiles(
        from backup: BackupInfo,
        entries: [BackupManifest.FileEntry],
        to destination: String,
        onError: ((String) -> Void)? = nil
    ) throws -> Int {
        let manifest = try BackupManifest(backupPath: backup.path)
        var extracted = 0

        let root = URL(fileURLWithPath: destination, isDirectory: true)
        let fm = FileManager.default

        for entry in entries where entry.isFile {
            guard let destination = try? SafeExtractionPath.prepareDestination(
                root: root,
                relativePath: extractionRelativePath(for: entry),
                fileManager: fm
            ) else {
                onError?("Refusing to extract \(entry.fileName) outside the destination folder.")
                continue
            }
            do {
                try manifest.extractFile(entry, to: destination.path)
                extracted += 1
            } catch {
                onError?("Failed to extract \(entry.fileName): \(error.localizedDescription)")
            }
        }

        return extracted
    }

    /// Extract all files in a specific domain to a local destination directory.
    static func extractDomain(
        from backup: BackupInfo,
        domain: String,
        to destination: String,
        onError: ((String) -> Void)? = nil
    ) throws -> Int {
        let manifest = try BackupManifest(backupPath: backup.path)
        let files = try manifest.files(inDomain: domain)
        return try extractFiles(from: backup, entries: files, to: destination, onError: onError)
    }
}
