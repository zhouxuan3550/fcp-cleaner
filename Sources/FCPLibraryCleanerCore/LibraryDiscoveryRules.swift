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

/// 纯谓词：资源库级"稍后提醒"与目录级忽略集（仅作用于自动发现与列表分层）。
/// 忽略绝不进入清理链路：CleanupPlan/CleanupEngine 不读取任何忽略状态，
/// 白名单与 trashItem 行为不受影响。
public enum LibraryIgnoreRules {
    public static let defaultSnoozeDays = 7

    /// `until` 在当前时刻之后视为忽略中；过期后自动回到正常分层。
    public static func isSnoozed(until: Date?, now: Date = Date()) -> Bool {
        guard let until else { return false }
        return until > now
    }

    /// 资源库路径位于任一被忽略目录内部（严格子路径，目录本身相等不算）。
    public static func isInsideIgnoredDirectory(recordPath: String, directoryPaths: [String]) -> Bool {
        let record = recordPath.standardizedFilePath
        return directoryPaths.contains { directory in
            let prefix = directory.standardizedFilePath.hasSuffix("/")
                ? directory.standardizedFilePath
                : directory.standardizedFilePath + "/"
            return record.hasPrefix(prefix)
        }
    }
}

extension String {
    /// 展开波浪号，供纯路径比较使用（不触碰文件系统）。
    public var standardizedFilePath: String {
        (self as NSString).expandingTildeInPath
    }
}
