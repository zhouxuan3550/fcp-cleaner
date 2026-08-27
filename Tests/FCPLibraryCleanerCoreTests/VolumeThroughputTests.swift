import Foundation
import Testing
@testable import FCPLibraryCleanerCore

struct VolumeThroughputTests {
    @Test("samples with non-positive bytes or sub-threshold duration are rejected")
    func rejectsInvalidSamples() {
        var index = CleanupThroughputIndex()
        index.record(volumeID: "disk-a", bytes: -5, seconds: 10)
        index.record(volumeID: "disk-a", bytes: 1_000, seconds: 0.01)

        #expect(index.buckets["disk-a"]?.isEmpty != false)
        #expect(index.averageBytesPerSecond(volumeID: "disk-a") == nil)
    }

    @Test("identical byte rates on separate volumes stay isolated")
    func isolatesVolumes() {
        var index = CleanupThroughputIndex()
        index.record(volumeID: "ssd", bytes: 500_000_000, seconds: 100)
        index.record(volumeID: "usb-hdd", bytes: 500_000_000, seconds: 10_000)

        #expect(index.averageBytesPerSecond(volumeID: "ssd") == 5_000_000)
        #expect(index.averageBytesPerSecond(volumeID: "usb-hdd") == 50_000)
        #expect(index.averageBytesPerSecond(volumeID: "missing") == nil)
    }

    @Test("rolling window keeps only the most recent maxSamplesPerVolume entries")
    func rollsWindowAtMaximum() {
        var index = CleanupThroughputIndex()
        // Twelve rounds of 1 GB / 100 s would give 10 MB/s overall; the dropped pair
        // is deliberately faster so the surviving-window math stays distinguishable.
        for _ in 0..<2 {
            index.record(volumeID: "disk", bytes: 4_000_000_000, seconds: 100)
        }
        for _ in 0..<10 {
            index.record(volumeID: "disk", bytes: 400_000_000, seconds: 100)
        }

        #expect(index.buckets["disk"]?.count == CleanupThroughputIndex.maxSamplesPerVolume)
        let expected = Double(400_000_000 * 10) / 1_000
        #expect(abs((index.averageBytesPerSecond(volumeID: "disk") ?? 0) - expected) < 0.001)
    }

    @Test("average is weighted by each sample's seconds, not sample count")
    func weightsByDuration() {
        var index = CleanupThroughputIndex()
        index.record(volumeID: "disk", bytes: 900, seconds: 90)
        index.record(volumeID: "disk", bytes: 20, seconds: 2)
        index.record(volumeID: "disk", bytes: 40, seconds: 8)

        #expect(abs((index.averageBytesPerSecond(volumeID: "disk") ?? 0) - 9.6) < 0.001)
    }
}
