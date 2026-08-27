import Testing
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
}
