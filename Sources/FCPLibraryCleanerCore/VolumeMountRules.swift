import Foundation

/// Pure path predicates for external-volume hot-plug handling.
public enum VolumeMountRules {
    /// True when `recordPath` lives on the volume mounted at `volumePath`.
    /// Root-level volume paths match everything beneath them; sibling volumes never match.
    public static func residesOnVolume(recordPath: String, volumePath: String) -> Bool {
        let record = standardized(recordPath)
        let volume = standardized(volumePath)
        if record == volume { return true }
        let prefix = volume.hasSuffix("/") ? volume : volume + "/"
        return record.hasPrefix(prefix)
    }

    private static func standardized(_ path: String) -> String {
        var path = path
        if path.count > 1 && path.hasSuffix("/") {
            path = String(path.dropLast())
        }
        return path
    }
}
