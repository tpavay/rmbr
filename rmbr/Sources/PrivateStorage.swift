import Foundation

/// Directories rmbr is willing to write to.
///
/// Everything rmbr keeps on disk describes the person's library or the coordinates they
/// visited, and the settled rule is that none of it leaves the device. Backup exclusion
/// is therefore a precondition for writing rather than a best effort: the flag is set and
/// then read back, and a directory that cannot be confirmed excluded is not offered at
/// all, so the stores that depend on it refuse to persist instead of quietly producing a
/// file that a backup could copy away.
enum PrivateStorage {
    static func excludedDirectory(named name: String) -> URL? {
        guard let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        return excluding(support.appendingPathComponent(name, isDirectory: true))
    }

    static func excluding(_ directory: URL) -> URL? {
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            var mutable = directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try mutable.setResourceValues(values)
            let confirmed = try directory
                .resourceValues(forKeys: [.isExcludedFromBackupKey])
                .isExcludedFromBackup
            guard confirmed == true else {
                discard(directory)
                return nil
            }
            return directory
        } catch {
            discard(directory)
            return nil
        }
    }

    /// Removes what an earlier run may already have written here.
    ///
    /// Refusing the next write is not enough on a device that once wrote these files
    /// without the exclusion holding: whatever is already on disk would stay
    /// backup-eligible. Everything in these directories is rmbr's own reproducible
    /// record, so deleting it costs a rebuild and nothing else.
    private static func discard(_ directory: URL) {
        try? FileManager.default.removeItem(at: directory)
    }
}

/// Why something rmbr wanted to keep was not written.
enum PrivateStorageFailure: Error, Sendable {
    /// No directory could be confirmed excluded from backup, so nothing was written.
    case notExcludedFromBackup
}
