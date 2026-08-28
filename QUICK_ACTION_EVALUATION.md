# Finder Quick Action 扩展评估（P4-5）

> 结论先行：**近期不做 Quick Action 扩展，保留现有 Services 入口。**
> 本文档记录评估依据与未来启用前提，供后续决策直接引用，避免重复调研。

## 1. 现状（已覆盖的能力）

| 入口 | 实现方式 | 状态 |
| --- | --- | --- |
| Finder 右键 → 服务 → 使用 FCP Cleaner 扫描 | `Info.plist` NSServices + `FinderServiceProvider.scanLibraries` | ✅ 已上线 |
| 双击 / 系统打开方式 | `CFBundleDocumentTypes`（`com.apple.finalcutprolibrary`，Alternate）+ `application(_:openFiles:)` | ✅ 已上线 |
| 拖放到主窗口 | `.onDrop(.fileURL)` | ✅ 已上线 |
| 自动发现 | 工作目录 FSEvents + Spotlight | ✅ 已上线 |
| 自动化入口 | App Intents 三个只读意图（P4-6） | ✅ 本批次新增 |

Quick Action 相比现有 Services 项的增量只有两点：右键**一级**「快速操作」菜单、预览窗格底部按钮。没有新能力。

## 2. Quick Action 的技术形态

macOS 的 Quick Action 本质是 **Action Extension（.appex）**，扩展点 `NSExtensionPointIdentifier = com.apple.services`：

- 需要独立编译的 appex bundle（自己的可执行文件 + `Info.plist` NSExtension 字典 + 激活规则声明接受的内容类型）。
- 安装位置：宿主 App 的 `Contents/PlugIns/`。
- 用户需在 系统设置 → 通用 → 登录项与扩展 → Finder 中**手动启用一次**。
- 由系统（Finder/预览面板）作为宿主加载运行，与主 App 不共享进程。

## 3. 本项目当前的阻碍

1. **构建体系**：项目是纯 SPM（`Package.swift`），SPM 不支持 extension target，`swift build` 产不出 appex。手工拼 appex（swiftc + 手写 plist）可行但脱离 Xcode 后无法用模板调试，`release.sh` 也要追加 PlugIns 装配与签名顺序（先 appex 后宿主）。
2. **签名与分发**：当前 ad-hoc 签名、无 Developer ID 公证（交接文档 §12.1）。Quick Action 由系统进程加载，未公证 appex 的 Gatekeeper 风险显著高于宿主 App；现有 Services 走宿主 App 进程，无此问题。
3. **代码复用陷阱**：appex 不能直接链接整个 `FCPLibraryCleanerApp` 可执行目标（体积、初始化副作用、App Nap/菜单栏依赖）。正确做法是 appex 只做一件事——把选中的 `.fcpbundle` 通过 `NSWorkspace.open(_:withApplicationAt:)` 交回宿主 App，复用已验证的 `application(_:openFiles:)` 链路。这层薄壳本身代码量很小，难点全在工程化（见 §4）。

## 4. 若未来启用，需要的前置条件（按顺序）

1. 迁移到正式 Xcode 工程（或 xcodebuild 脚本化工程），保留 SPM 包作为源码组织。
2. 配置 Developer ID + Hardened Runtime + 公证（交接文档 §15.3）。
3. 新建 Action Extension target：`NSExtensionPointIdentifier = com.apple.services`；`NSExtensionActivationRule` 用 `LSItemContentTypes = [com.apple.finalcutprolibrary]` 并限制数量上限。
4. appex 壳实现仅做转发（NSWorkspace 交给宿主），**不得**在扩展进程内跑扫描/清理逻辑——扫描 UI 与安全预检只存在于宿主 App。
5. `release.sh`：装配 `Contents/PlugIns/`、调整 codesign 顺序、`codesign --verify --deep --strict`、公证后重新验证 Quick Action 注册。
6. 首次启用引导：README/更新说明中写明"系统设置 → Finder 扩展中启用"。

## 5. 关联限制：Shortcuts App Intents 的元数据提取（P4-6 实测）

P4-6 已交付三个只读 AppIntent（`ScannedWorkDirs`/`ScanLibrary`/`ShowCleanableSpace`，含 `AppShortcutsProvider`）。但 Shortcuts 能否"看到"这些意图取决于构建期的 App Intents 元数据提取：

- `appintentsmetadataprocessor`（本机 Xcode 26.3 已确认存在）需要 Swift 编译器产出的 stringsdata **和** const values；实测本仓库 `swift build --arch arm64 --arch x86_64`（xcbuild 路径）会产出 stringsdata，但**不产出 const values**（Xcode 由 `ENABLE_APP_INTENTS_METADATA_EXTRACTION` 等构建设置控制）。
- 尝试经 `-Xswiftc -Xfrontend -emit-const-value-patterns` 补齐时，SwiftPM 参数传递存在缺陷（复数参数组合直接解析失败/崩溃）。社区结论一致：SPM 直接构建的 App，Shortcuts 无法自动发现其意图（参考 Apple Developer Forums "AppIntents don't show up in Shortcuts app when in SPM package"）。
- 因此：意图代码已就位并可被程序化调用（`perform()` 有测试覆盖），但在迁移到 Xcode 工程并开启元数据提取构建阶段之前，Shortcuts App 内不会列出它们。该项与 Quick Action 共享同一触发条件，已列入 §4 前置清单的第 1、3 步。

## 6. 决策记录

- 2026-08-28：评估结论为**暂不实现**。触发重估条件：完成 Xcode 工程迁移且具备公证能力后，或出现明确用户反馈"服务二级菜单找不到"时再立项。
- 过渡期自动化需求由 App Intents / Shortcuts（P4-6）与现有 Services 项覆盖。
