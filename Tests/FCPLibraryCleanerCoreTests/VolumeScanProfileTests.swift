import Foundation
import Testing
@testable import FCPLibraryCleanerCore

struct VolumeScanProfileTests {
    @Test("network and rotational volumes receive conservative limits")
    func classification() {
        #expect(VolumeScanProfile.classify(local: false, internalDisk: true, medium: "Solid State", solidState: true) == .network)
        #expect(VolumeScanProfile.classify(local: true, internalDisk: true, medium: nil, solidState: nil) == .internalDisk)
        #expect(VolumeScanProfile.classify(local: true, internalDisk: false, medium: "Solid State", solidState: nil) == .solidState)
        #expect(VolumeScanProfile.classify(local: true, internalDisk: false, medium: "Rotational", solidState: nil) == .rotational)
        #expect(VolumeScanProfile.classify(local: true, internalDisk: false, medium: nil, solidState: nil) == .unknown)
        #expect(VolumeScanProfile.limit(for: .network) == 1)
        #expect(VolumeScanProfile.limit(for: .rotational) == 1)
        #expect(VolumeScanProfile.limit(for: .solidState) >= 8)
    }

    @Test("actual mounted volume yields a usable identity")
    func mountedVolume() throws {
        let profile = try VolumeScanProfile.resolve(FileManager.default.temporaryDirectory)
        #expect(!profile.id.isEmpty)
        #expect(profile.traversalLimit > 0)
        let sibling = try VolumeScanProfile.resolve(FileManager.default.temporaryDirectory.deletingLastPathComponent())
        #expect(profile.id == sibling.id)
        #expect(profile.kind == sibling.kind)
    }

    @Test("optional physical volumes receive their expected scan limits")
    func physicalVolumes() throws {
        let environment = ProcessInfo.processInfo.environment
        if let path = environment["FCP_TEST_EXTERNAL_SSD"] {
            let profile = try VolumeScanProfile.resolve(URL(fileURLWithPath: path))
            #expect(profile.kind == .solidState)
            #expect(profile.traversalLimit >= 8)
        }
        if let path = environment["FCP_TEST_EXTERNAL_ROTATIONAL"] {
            let profile = try VolumeScanProfile.resolve(URL(fileURLWithPath: path))
            #expect(profile.kind == .rotational || profile.kind == .unknown)
            #expect(profile.traversalLimit == 1)
        }
    }
}
