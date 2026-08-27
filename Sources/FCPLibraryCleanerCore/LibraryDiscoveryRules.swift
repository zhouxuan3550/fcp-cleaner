import Foundation

/// Pure predicates governing automatic `.fcpbundle` discovery eligibility.
public enum LibraryDiscoveryRules {
    /// Spotlight results are only accepted on locally mounted volumes that are
    /// not Time Machine backup stores; user-chosen work directories bypass this
    /// gate but still need a recognizable library database.
    public static func allowsSpotlightDiscovery(localMount: Bool, timeMachineBackup: Bool) -> Bool {
        localMount && !timeMachineBackup
    }

    public static func allowsSpotlightDiscovery(localMount: Bool, volumeName: String) -> Bool {
        allowsSpotlightDiscovery(
            localMount: localMount,
            timeMachineBackup: describesTimeMachineVolume(lastPathComponent: volumeName)
        )
    }

    public static func describesTimeMachineVolume(lastPathComponent: String) -> Bool {
        let name = lastPathComponent
        return name.hasPrefix("com.apple.TimeMachine")
            || name.hasPrefix("Time Machine")
            || name == "Backups.backupdb"
    }
}
