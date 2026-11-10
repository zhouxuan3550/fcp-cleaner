import AppKit
import Darwin
import Foundation

/// Detects whether FCP currently has the given Library open.
///
/// FCP exposes no public per-Library lock API; its open database handles give a
/// reliable process-level signal without blocking unrelated Libraries merely
/// because FCP is running. Every failure mode — spawn error, non-zero exit, or
/// timeout — fails CLOSED (treated as "in use") so an unprobeable system never
/// waves a cleanup through.
public struct LibraryUseDetector: Sendable {
    private let lsofPath: String
    private let timeoutSeconds: Double

    public init() {
        self.init(lsofPath: "/usr/sbin/lsof", timeoutSeconds: 10)
    }

    /// Injectable for deterministic tests.
    public init(lsofPath: String, timeoutSeconds: Double) {
        self.lsofPath = lsofPath
        self.timeoutSeconds = max(0.1, timeoutSeconds)
    }

    public func libraryIsInUse(_ libraryURL: URL) -> Bool {
        let applications = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.FinalCut")
        guard !applications.isEmpty else { return false }
        let libraryPath = libraryURL.standardizedFileURL.path

        for application in applications {
            if detectInUse(processIdentifier: application.processIdentifier, libraryPath: libraryPath) {
                return true
            }
        }
        return false
    }

    /// Single-process inspection. Internal so tests can drive failure modes
    /// (missing binary, hanging tool) without a live Final Cut Pro instance.
    func detectInUse(processIdentifier: pid_t, libraryPath: String) -> Bool {
        if let result = Self.inspectProcess(processIdentifier: processIdentifier, libraryPath: libraryPath) {
            return result
        }
        final class LockedBuffer: @unchecked Sendable {
            private let lock = NSLock()
            private var data = Data()
            func append(_ chunk: Data) {
                lock.lock()
                data.append(chunk)
                lock.unlock()
            }
            var current: Data {
                lock.lock()
                defer { lock.unlock() }
                return data
            }
        }

        let process = Process()
        let terminated = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in terminated.signal() }
        let buffer = LockedBuffer()
        let output = Pipe()
        output.fileHandleForReading.readabilityHandler = { handle in
            buffer.append(handle.availableData)
        }
        process.executableURL = URL(fileURLWithPath: lsofPath)
        process.arguments = ["-a", "-p", String(processIdentifier), "-Fn"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            // 无法启动检查进程 = 状态不可知，宁可阻断本次清理。
            return true
        }

        if terminated.wait(timeout: .now() + timeoutSeconds) == .timedOut {
            // 超时同样按“占用”处理。
            if process.isRunning { process.terminate() }
            output.fileHandleForReading.readabilityHandler = nil
            return true
        }
        output.fileHandleForReading.readabilityHandler = nil
        buffer.append(output.fileHandleForReading.readDataToEndOfFile())

        guard process.terminationStatus == 0,
              let text = String(data: buffer.current, encoding: .utf8) else {
            return true
        }
        let paths = [libraryPath, Self.canonicalPath(libraryPath)].compactMap { $0 }
        return text.split(separator: "\n").contains(where: { line in
            guard line.first == "n" else { return false }
            let path = String(line.dropFirst())
            return paths.contains { path == $0 || path.hasPrefix($0 + "/") }
        })
    }

    private static func canonicalPath(_ path: String) -> String? {
        var resolvedPath = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard path.withCString({ realpath($0, &resolvedPath) }) != nil else { return nil }
        return String(bytes: resolvedPath.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, encoding: .utf8)
    }

    /// Inspect descriptors, current/root directories and mapped files. A nil
    /// result means the inspection could not establish a complete answer.
    static func inspectProcess(processIdentifier: pid_t, libraryPath: String) -> Bool? {
        guard let canonical = canonicalPath(libraryPath), let start = processStart(processIdentifier) else { return nil }
        let descriptors = openFileDescriptorMatches(processIdentifier: processIdentifier, libraryPath: canonical)
        if descriptors == true { return true }
        let directories = processDirectoriesMatch(processIdentifier: processIdentifier, libraryPath: canonical)
        if directories == true { return true }
        let mapped = mappedFileMatches(processIdentifier: processIdentifier, libraryPath: canonical)
        if mapped == true { return true }
        guard descriptors == false, directories == false, mapped == false,
              let end = processStart(processIdentifier), start == end else { return nil }
        return false
    }

    private static func processStart(_ pid: pid_t) -> [UInt64]? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return [info.pbi_start_tvsec, info.pbi_start_tvusec]
    }

    private static func pathMatches(_ path: String, libraryPath: String) -> Bool {
        path == libraryPath || path.hasPrefix(libraryPath + "/")
    }

    private static func decodedPath<T>(_ path: inout T) -> String? {
        withUnsafeBytes(of: &path) { bytes in
            guard let end = bytes.firstIndex(of: 0) else { return nil }
            return String(bytes: bytes[..<end], encoding: .utf8)
        }
    }

    static func processDirectoriesMatch(processIdentifier: pid_t, libraryPath: String) -> Bool? {
        guard let canonical = canonicalPath(libraryPath) else { return nil }
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(processIdentifier, PROC_PIDVNODEPATHINFO, 0, &info, size) == size,
              let current = decodedPath(&info.pvi_cdir.vip_path), !current.isEmpty,
              let root = decodedPath(&info.pvi_rdir.vip_path) else { return nil }
        return pathMatches(current, libraryPath: canonical) || (!root.isEmpty && pathMatches(root, libraryPath: canonical))
    }

    static func mappedFileMatches(processIdentifier: pid_t, libraryPath: String) -> Bool? {
        guard let canonical = canonicalPath(libraryPath) else { return nil }
        let started = ContinuousClock.now
        var address: UInt64 = 0
        var regions = 0
        while regions < 100_000 {
            if regions.isMultiple(of: 64), ContinuousClock.now - started > .seconds(3) { return nil }
            var info = proc_regionwithpathinfo()
            let size = Int32(MemoryLayout<proc_regionwithpathinfo>.size)
            errno = 0
            let bytes = proc_pidinfo(processIdentifier, PROC_PIDREGIONPATHINFO, address, &info, size)
            if bytes == 0, errno == EINVAL, regions > 0 { return false }
            guard bytes == size, let path = decodedPath(&info.prp_vip.vip_path) else { return nil }
            if !path.isEmpty, pathMatches(path, libraryPath: canonical) { return true }
            if path.isEmpty, info.prp_vip.vip_vi.vi_stat.vst_ino != 0 { return nil }
            let base = info.prp_prinfo.pri_address
            let length = info.prp_prinfo.pri_size
            let (next, overflow) = base.addingReportingOverflow(length)
            guard length > 0, !overflow, next > address else { return nil }
            address = next
            regions += 1
        }
        return nil
    }

    /// nil means the kernel could not provide a complete, stable descriptor list.
    static func openFileDescriptorMatches(processIdentifier: pid_t, libraryPath: String) -> Bool? {
        guard let canonicalLibraryPath = canonicalPath(libraryPath) else { return nil }
        let elementSize = MemoryLayout<proc_fdinfo>.stride
        let bytesNeeded = proc_pidinfo(processIdentifier, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytesNeeded > 0 else { return nil }
        let capacity = Int(bytesNeeded) / elementSize + 32
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: capacity)
        let byteCapacity = capacity * elementSize
        guard byteCapacity <= Int(Int32.max) else { return nil }
        let bytesRead = descriptors.withUnsafeMutableBytes {
            proc_pidinfo(processIdentifier, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count))
        }
        guard bytesRead > 0, Int(bytesRead) < byteCapacity, Int(bytesRead) % elementSize == 0 else { return nil }
        var incomplete = false
        for descriptor in descriptors.prefix(Int(bytesRead) / elementSize) where descriptor.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
            var details = vnode_fdinfowithpath()
            let count = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
            let read = withUnsafeMutablePointer(to: &details) {
                proc_pidfdinfo(processIdentifier, descriptor.proc_fd, PROC_PIDFDVNODEPATHINFO, $0, count)
            }
            guard read == count else { incomplete = true; continue }
            let path: String? = withUnsafeBytes(of: &details.pvip.vip_path) { bytes in
                guard let end = bytes.firstIndex(of: 0), end > 0 else { return nil }
                return String(bytes: bytes[..<end], encoding: .utf8)
            }
            guard let path else { incomplete = true; continue }
            if path == canonicalLibraryPath || path.hasPrefix(canonicalLibraryPath + "/") { return true }
        }
        return incomplete ? nil : false
    }
}
