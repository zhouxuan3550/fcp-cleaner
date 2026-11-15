import Foundation
import Testing
import FCPLibraryCleanerCore
@testable import FCPLibraryCleanerApp

@MainActor
struct DashboardRankingTests {
    /// 造一个达到 200MB 门槛、位于指定卷、指定久未使用与体积的候选。
    private func record(named: String, ageDays: Double, volume: URL, allocatedSize: Int64 = 300_000_000) -> LibraryRecord {
        let url = volume.appendingPathComponent("\(named).fcpbundle")
        let record = LibraryRecord(url: url)
        let item = CacheItem(
            url: url.appendingPathComponent("Render Files"),
            category: .renderFiles,
            allocatedSize: allocatedSize,
            logicalSize: allocatedSize,
            confidence: .confirmed,
            ruleID: "event.render-files",
            fingerprint: FileFingerprint(allocatedSize: allocatedSize, logicalSize: allocatedSize, entryCount: 1, contentsSignature: 0))
        record.scanResult = LibraryScanResult(
            libraryURL: url,
            totalAllocatedSize: 300_000_000,
            totalLogicalSize: 300_000_000,
            coreDataSnapshots: [],
            cacheItems: [item],
            observedCacheItems: [],
            protectedItems: [],
            issues: [])
        record.lastActivity = Date(timeIntervalSinceNow: -ageDays * 86_400)
        return record
    }

    @Test("排序综合久未使用与卷压力：老库+紧卷排在新鲜库+富余卷之前")
    func multiFactorRanking() throws {
        let store = LibraryStore()
        let tightVolume = URL(fileURLWithPath: "/tmp/fcpc-top3-tight")
        let roomyVolume = URL(fileURLWithPath: "/tmp/fcpc-top3-roomy")

        let oldOnTight = record(named: "old-tight", ageDays: 200, volume: tightVolume)
        let freshOnRoomy = record(named: "fresh-roomy", ageDays: 1, volume: roomyVolume)
        store.libraries = [freshOnRoomy, oldOnTight]

        let pressures = [
            LibraryStore.VolumePressure(id: tightVolume, name: "紧", available: 5_000_000_000, cleanable: 0),
            LibraryStore.VolumePressure(id: roomyVolume, name: "富余", available: 100_000_000_000, cleanable: 0),
        ]

        let top = store.topCleanupCandidates(pressures: pressures)

        #expect(top.count == 2)
        #expect(top.first?.displayName == "old-tight")
    }

    @Test("同级龄下体积主导：大库排前")
    func sizeDominatesAtSameAge() throws {
        let store = LibraryStore()
        let volume = URL(fileURLWithPath: "/tmp/fcpc-top3-same")

        let big = record(named: "big", ageDays: 200, volume: volume, allocatedSize: 900_000_000)
        let small = record(named: "small", ageDays: 200, volume: volume, allocatedSize: 210_000_000)
        store.libraries = [small, big]

        let top = store.topCleanupCandidates(pressures: [])

        #expect(top.first?.displayName == "big")
    }

    @Test("久未使用权重比值封顶 7 倍：体积差超过 7 倍时新鲜大库仍排前")
    func recencyWeightIsBounded() throws {
        let store = LibraryStore()
        let volume = URL(fileURLWithPath: "/tmp/fcpc-top3-bound")

        let oldTiny = record(named: "old-tiny", ageDays: 365, volume: volume, allocatedSize: 210_000_000)
        let freshHuge = record(named: "fresh-huge", ageDays: 0, volume: volume, allocatedSize: 2_000_000_000)
        store.libraries = [oldTiny, freshHuge]

        let top = store.topCleanupCandidates(pressures: [])

        #expect(top.first?.displayName == "fresh-huge")
    }
}
