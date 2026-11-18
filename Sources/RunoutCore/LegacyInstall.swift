import Foundation

/// Carries an install of 1.0, when the app was called "Usage Bar", over to the current names.
public enum LegacyInstall {
    public static let bundleID = "local.usage-bar"
    /// Folder names under `~/.config` and `~/Library/Application Support`.
    public static let configFolder = "usage-bar"
    public static let supportFolder = "UsageBar"
    /// Settings that must not carry over: the login item belongs to the old bundle, so the new
    /// one has to register itself once more.
    static let skippedSettings: Set<String> = ["loginItemInitialized"]

    /// Moves `legacy` to `current` unless `current` already exists. Returns whether it moved.
    @discardableResult
    public static func move(_ legacy: URL, to current: URL, fileManager: FileManager = .default) -> Bool {
        guard fileManager.fileExists(atPath: legacy.path), !fileManager.fileExists(atPath: current.path) else {
            return false
        }
        do {
            try fileManager.createDirectory(at: current.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.moveItem(at: legacy, to: current)
            return true
        } catch {
            return false
        }
    }

    /// The legacy settings that `current` has no value for yet.
    public static func settingsToCopy(from legacy: [String: Any], into current: [String: Any]) -> [String: Any] {
        legacy.filter { current[$0.key] == nil && !skippedSettings.contains($0.key) }
    }
}
