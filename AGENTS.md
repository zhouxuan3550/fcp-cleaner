# FCP Cleaner

Swift 6 + SwiftUI + AppKit + XcodeGen + Swift Package Manager。当前版本 4.3.1。主程序最低 macOS 15.0，Workflow Extension 最低 macOS 15.6。

<directory>
Sources/FCPLibraryCleanerApp/ - 主程序状态、扫描调度、安全清理与界面；详见该目录的 AGENTS.md。
Sources/FCPLibraryCleanerCore/ - 白名单规则、扫描器、指纹和清理引擎；详见该目录的 AGENTS.md。
Sources/fcp-library-scanner/ - 只读命令行工具。
WorkflowExtension/ - Final Cut Pro Workflow Extension。
Tests/ - Core 和 App 层验证；App 测试详见其子目录的 AGENTS.md。
Assets/ - 应用图标与主页素材。
Benchmarks/ - 性能基线及测量说明。
Scripts/ - 构建与发布辅助脚本。
Config/ - 签名与发布配置。
</directory>

<config>
project.yml - XcodeGen 工程定义、版本和扩展 SDK 配置。
Package.swift - Swift Package Manager 目标与 Sparkle 精确版本。
PROJECT_HANDOFF_ZH.md - 产品安全边界、发布流程和已知风险。
LICENSE - 项目现有授权；修改授权须先取得用户明确同意。
</config>

清理链路只接受 Core 白名单内的确认项。所有扫描展示数据与最终删除决策隔离；清理前必须保持既有预检和指纹复核。界面文案以简体中文为主，并保留英文翻译及 macOS 15 兼容性。

[PROTOCOL]: Update this header on change, then check AGENTS.md
