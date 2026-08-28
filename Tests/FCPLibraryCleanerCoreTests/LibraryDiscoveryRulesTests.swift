import Testing
import Foundation
@testable import FCPLibraryCleanerCore

struct LibraryDiscoveryRulesTests {
    @Test("spotlight results require a local mount outside Time Machine stores")
    func gatesSpotlightCandidates() {
        #expect(LibraryDiscoveryRules.allowsSpotlightDiscovery(localMount: true, timeMachineBackup: false))
        #expect(!LibraryDiscoveryRules.allowsSpotlightDiscovery(localMount: false, timeMachineBackup: false))
        #expect(!LibraryDiscoveryRules.allowsSpotlightDiscovery(localMount: true, timeMachineBackup: true))
        #expect(!LibraryDiscoveryRules.allowsSpotlightDiscovery(localMount: false, timeMachineBackup: true))
    }

    @Test("recognizes Time Machine volume naming variants")
    func detectsBackupVolumes() {
        #expect(LibraryDiscoveryRules.describesTimeMachineVolume(lastPathComponent: "com.apple.TimeMachineBackups.London"))
        #expect(LibraryDiscoveryRules.describesTimeMachineVolume(lastPathComponent: "Time Machine 备份"))
        #expect(LibraryDiscoveryRules.describesTimeMachineVolume(lastPathComponent: "Backups.backupdb"))
        #expect(!LibraryDiscoveryRules.describesTimeMachineVolume(lastPathComponent: "LaCie"))
        #expect(!LibraryDiscoveryRules.describesTimeMachineVolume(lastPathComponent: "工程备份"))
    }

    @Test("volume names are evaluated instead of library package names")
    func gatesVolumeNames() {
        #expect(!LibraryDiscoveryRules.allowsSpotlightDiscovery(localMount: true, volumeName: "Time Machine"))
        #expect(LibraryDiscoveryRules.allowsSpotlightDiscovery(localMount: true, volumeName: "Media SSD"))
    }

    @Test("snooze expires automatically at the deadline")
    func snoozeWindow() {
        let now = Date()
        #expect(!LibraryIgnoreRules.isSnoozed(until: nil, now: now))
        #expect(LibraryIgnoreRules.isSnoozed(until: now.addingTimeInterval(60), now: now))
        #expect(!LibraryIgnoreRules.isSnoozed(until: now.addingTimeInterval(-1), now: now))
    }

    @Test("directory ignore matches only strict descendants")
    func directoryIgnoreMembership() {
        let ignored = ["/Volumes/RAID/旧项目"]
        #expect(LibraryIgnoreRules.isInsideIgnoredDirectory(
            recordPath: "/Volumes/RAID/旧项目/采访.fcpbundle",
            directoryPaths: ignored
        ))
        #expect(!LibraryIgnoreRules.isInsideIgnoredDirectory(
            recordPath: "/Volumes/RAID/旧项目",
            directoryPaths: ignored
        ))
        #expect(!LibraryIgnoreRules.isInsideIgnoredDirectory(
            recordPath: "/Volumes/RAID/旧项目备份/采访.fcpbundle",
            directoryPaths: ignored
        ))
        #expect(!LibraryIgnoreRules.isInsideIgnoredDirectory(
            recordPath: "/Users/editor/Movies/素材.fcpbundle",
            directoryPaths: ignored
        ))
    }

    @Test("row snooze defaults to seven days")
    func defaultSnoozeIsOneWeek() {
        #expect(LibraryIgnoreRules.defaultSnoozeDays == 7)
    }
}
