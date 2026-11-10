import Darwin
import DiskArbitration
import Foundation
import IOKit

private final class VolumeProfileCache: @unchecked Sendable {
    static let shared = VolumeProfileCache()
    private let lock = NSLock()
    private var profiles: [String: VolumeScanProfile] = [:]

    func profile(for key: String, make: () -> VolumeScanProfile) -> VolumeScanProfile {
        lock.lock()
        defer { lock.unlock() }
        if let profile = profiles[key] { return profile }
        let profile = make()
        profiles[key] = profile
        return profile
    }
}

struct VolumeScanProfile: Sendable, Equatable {
    enum Kind: Sendable { case internalDisk, solidState, rotational, network, unknown }
    let id: String
    let kind: Kind
    let traversalLimit: Int

    static func classify(local: Bool, internalDisk: Bool?, medium: String?, solidState: Bool?) -> Kind {
        guard local else { return .network }
        if internalDisk == true { return .internalDisk }
        if solidState == true || medium == "Solid State" { return .solidState }
        if solidState == false || medium == "Rotational" { return .rotational }
        return .unknown
    }

    static func limit(for kind: Kind) -> Int {
        switch kind {
        case .internalDisk, .solidState: 24
        case .rotational, .network, .unknown: 1
        }
    }

    /// Resolves the actual filesystem used by a cache directory, including
    /// external caches located on a different volume from the library.
    static func resolve(_ url: URL) throws -> VolumeScanProfile {
        var info = statfs()
        guard statfs(url.path, &info) == 0 else { throw CleanupError.volumeOffline(url) }
        let mount = withUnsafeBytes(of: &info.f_mntonname) {
            String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
        }
        let local = info.f_flags & UInt32(MNT_LOCAL) != 0
        // Include the kernel filesystem identity so a different volume mounted at
        // the same path is classified again. Resolve once for concurrent scans.
        let filesystemID = withUnsafeBytes(of: &info.f_fsid) { Data($0).base64EncodedString() }
        let cacheKey = mount + ":" + filesystemID
        return VolumeProfileCache.shared.profile(for: cacheKey) {
            resolveMount(mount, local: local)
        }
    }

    private static func resolveMount(_ mount: String, local: Bool) -> VolumeScanProfile {
        guard local else {
            return VolumeScanProfile(id: "network:" + mount, kind: .network, traversalLimit: 1)
        }
        guard let session = DASessionCreate(kCFAllocatorDefault),
              let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, URL(fileURLWithPath: mount, isDirectory: true) as CFURL),
              let description = DADiskCopyDescription(disk) as? [String: Any] else {
            return VolumeScanProfile(id: "mount:" + mount, kind: .unknown, traversalLimit: 1)
        }
        let internalDisk = (description[kDADiskDescriptionDeviceInternalKey as String] as? NSNumber)?.boolValue
        let physicalPath = description[kDADiskDescriptionDevicePathKey as String] as? String
        let media = DADiskCopyIOMedia(disk)
        var medium: String?
        var solidState: Bool?
        if media != 0 {
            defer { IOObjectRelease(media) }
            let options = IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
            if let characteristics = IORegistryEntrySearchCFProperty(media, kIOServicePlane, "Device Characteristics" as CFString, kCFAllocatorDefault, options) as? [String: Any] {
                medium = characteristics["Medium Type"] as? String
                solidState = (characteristics["Solid State"] as? NSNumber)?.boolValue
            }
        }
        let kind = classify(local: true, internalDisk: internalDisk, medium: medium, solidState: solidState)
        let id = physicalPath.map { "device:" + $0 } ?? "mount:" + mount
        return VolumeScanProfile(id: id, kind: kind, traversalLimit: limit(for: kind))
    }
}
