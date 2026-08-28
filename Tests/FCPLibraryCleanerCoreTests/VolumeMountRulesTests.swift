import Testing
import FCPLibraryCleanerCore

@Suite("VolumeMountRulesTests")
struct VolumeMountRulesTests {
    @Test("nested paths live on their volume")
    func nestedMatch() {
        #expect(VolumeMountRules.residesOnVolume(
            recordPath: "/Volumes/RAID/Work/采访项目.fcpbundle",
            volumePath: "/Volumes/RAID"
        ))
    }

    @Test("exact volume path counts as residing on the volume")
    func exactMatch() {
        #expect(VolumeMountRules.residesOnVolume(
            recordPath: "/Volumes/RAID",
            volumePath: "/Volumes/RAID"
        ))
    }

    @Test("shared volume prefix does not imply same volume")
    func siblingVolumesDoNotMatch() {
        #expect(!VolumeMountRules.residesOnVolume(
            recordPath: "/Volumes/RAID-BACKUP/Work/项目.fcpbundle",
            volumePath: "/Volumes/RAID"
        ))
        #expect(!VolumeMountRules.residesOnVolume(
            recordPath: "/Volumes/RAID2/项目.fcpbundle",
            volumePath: "/Volumes/RAID"
        ))
    }

    @Test("internal disk is never matched by an external volume mount")
    func internalDiskDoesNotMatch() {
        #expect(!VolumeMountRules.residesOnVolume(
            recordPath: "/Users/editor/Movies/素材库.fcpbundle",
            volumePath: "/Volumes/RAID"
        ))
    }

    @Test("trailing slash on either side is tolerated")
    func trailingSlashTolerated() {
        #expect(VolumeMountRules.residesOnVolume(
            recordPath: "/Volumes/RAID/项目.fcpbundle",
            volumePath: "/Volumes/RAID/"
        ))
    }
}
