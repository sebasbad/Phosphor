import Foundation

/// Serializes Manifest.db access off the main actor. All SQLite queries and any
/// FileManager stat calls for size resolution run inside the actor's executor,
/// leaving the UI free from disk I/O.
actor ManifestQueryStore {
    private let manifest: BackupManifest

    init(manifest: BackupManifest) {
        self.manifest = manifest
    }

    func domains() throws -> [String] {
        try manifest.domains()
    }

    func files(inDomain domain: String) throws -> [BackupManifest.FileEntry] {
        try manifest.files(inDomain: domain)
    }

    func children(ofPath path: String, inDomain domain: String) throws -> [BackupManifest.FileEntry] {
        try manifest.children(ofPath: path, inDomain: domain)
    }

    func search(_ query: String) throws -> [BackupManifest.FileEntry] {
        try manifest.search(query)
    }

    /// Resolve on-disk sizes for one chunk. Callers drive chunking from the
    /// main actor so they can splice updates into the published array and
    /// react to cancellation without the store holding a closure.
    func resolveSizes(for slice: [BackupManifest.FileEntry]) throws -> [BackupManifest.FileEntry] {
        try Task.checkCancellation()
        return manifest.resolvingSizes(for: slice)
    }

    func readablePath(for entry: BackupManifest.FileEntry) throws -> String {
        try Task.checkCancellation()
        return try manifest.readablePath(for: entry)
    }

    func extractFile(_ entry: BackupManifest.FileEntry, to destination: String) throws {
        try manifest.extractFile(entry, to: destination)
    }
}
