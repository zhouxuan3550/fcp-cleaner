import Foundation
import FCPLibraryCleanerCore

@main
struct FCPLibraryScannerCLI {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard let path = arguments.first, !["--help", "-h"].contains(path) else {
            print("用法：fcp-library-scanner <资源库.fcpbundle> [--json] [--dry-run]")
            print("只读扫描，不会删除或移动文件。")
            return
        }

        do {
            let result = try await LibraryScanner().scan(libraryURL: URL(fileURLWithPath: path))
            let dryRun = arguments.contains("--dry-run")
            let plan = dryRun
                ? try CleanupPlan(scanResult: result, categories: Set(CacheCategory.cleanableCases))
                : nil
            if arguments.contains("--json") {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                if let plan {
                    print(String(decoding: try encoder.encode(DryRunReport(scan: result, plan: plan)), as: UTF8.self))
                } else {
                    print(String(decoding: try encoder.encode(result), as: UTF8.self))
                }
            } else {
                print(HumanReport.render(result, plan: plan))
            }
        } catch {
            fputs("错误：\(error.localizedDescription)\n", stderr)
            Foundation.exit(1)
        }
    }
}

private enum HumanReport {
    static func render(_ result: LibraryScanResult, plan: CleanupPlan?) -> String {
        var lines = [
            "Library: \(result.libraryURL.lastPathComponent)",
            "Allocated size: \(format(result.totalAllocatedSize))",
            "Confirmed cleanable: \(format(result.confirmedCleanableSize))",
            "",
            "Confirmed candidates (read-only):",
        ]
        if result.cacheItems.isEmpty {
            lines.append("  None")
        } else {
            for item in result.cacheItems {
                lines.append("  \(item.category.displayName): \(format(item.allocatedSize))")
                lines.append("    \(item.url.path)")
                lines.append("    Rule: \(item.ruleID), confidence: \(item.confidence.rawValue)")
            }
        }
        lines.append("Protected entries: \(result.protectedItems.count)")
        lines.append("Scan issues: \(result.issues.count)")
        if let plan {
            lines.append("")
            lines.append("Dry Run: \(plan.entries.count) 项，\(format(plan.spaceToFree))")
            for entry in plan.entries {
                lines.append("  \(entry.item.category.displayName): \(entry.item.url.path)")
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

private struct DryRunReport: Codable {
    let scan: LibraryScanResult
    let plan: CleanupPlan
}
