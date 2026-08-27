# FCP Cleaner 项目开发交接文档

> 本文档用于将项目交给其他 AI 编程工具、IDE Agent 或 macOS 开发人员继续维护。  
> 当前代码和本文档是权威依据；早期需求文档中的部分设想已经被后续产品决策替代。

## 1. 项目概况

| 项目 | 当前值 |
| --- | --- |
| 产品名称 | FCP Cleaner |
| 当前版本 | 3.0.1（Build 301） |
| 项目路径 | `/Users/macstudio/Documents/VoxCPM2/FCPLibraryCleaner` |
| 技术栈 | Swift 6、SwiftUI、AppKit、Swift Package Manager |
| 最低系统 | macOS 15.0 |
| 当前架构 | Apple Silicon arm64 |
| Bundle ID | `com.fcpcleaner.app` |
| 更新框架 | Sparkle 2.9.6 |
| 最新安装包 | `Distribution/FCP-Cleaner-3.0.1-arm64.dmg` |
| 自动测试 | 22 项 Core 测试 |

产品用途：扫描 Final Cut Pro 的 `.fcpbundle` 资源库，只清理能够明确确认、可由 FCP 重新生成的渲染文件、代理媒体和优化媒体，并将其移动到 macOS 废纸篓。

## 2. 当前产品原则

以下规则优先级高于任何功能需求。

1. 只清理白名单中确认过的目录结构。
2. 无法 100% 确认的数据一律保留。
3. 永远不使用永久删除，必须使用 `FileManager.trashItem()`。
4. 不删除原始媒体、外链媒体、数据库、Timeline、Event、Project 或元数据。
5. 分析文件目前只识别、统计和保护，不参与清理。
6. 清理前检查资源库占用、磁盘在线状态、只读状态和文件变化。
7. 执行移动前再次计算完整指纹，防止扫描后内容发生变化。
8. 单个资源库可清理空间低于固定的 500 MB 时自动跳过。

禁止清理的典型内容：

- `CurrentVersion.flexolibrary`
- `CurrentVersion.fcpevent`
- `CurrentVersion.fcpproject`
- `Original Media`
- Event、Project、Timeline、Keyword、Role、Marker 数据
- Multicam、Compound Clip、Sync Clip 数据
- XML 和任何未知数据库
- 符号链接指向的原始媒体
- 结构无法确认的目录

## 3. 当前已实现功能

### 3.1 资源库发现与导入

- 自动使用 Spotlight 搜索本机 `.fcpbundle`。
- 设置一个或多个工作目录后，只递归扫描这些目录。
- 支持 `NSOpenPanel` 多选资源库。
- 支持拖放 `.fcpbundle`。
- 支持双击空白区域选择资源库。
- Finder 右键服务：`使用 FCP Cleaner 扫描`。
- 支持系统“打开方式”将资源库交给 FCP Cleaner。
- 使用安全作用域书签保存资源库和工作目录权限。

### 3.2 扫描与分类

当前允许清理的分类只有：

- Render Files / 渲染文件
- Proxy Media / 代理媒体
- Optimized Media / 优化媒体

当前精确白名单路径：

```text
Library.fcpbundle/
├── Shared Render Files
├── Shared Proxy Media
├── Shared Optimized Media
└── Event Name/
    ├── CurrentVersion.fcpevent
    ├── Render Files
    ├── Transcoded Media/Proxy Media
    ├── Transcoded Media/High Quality Media
    └── Optimized Media
```

只有包含 `CurrentVersion.fcpevent` 的目录才被视为有效 Event。

分析文件的以下位置会被识别，但始终受到保护：

```text
Event Name/Analysis Files
Event Name/Audio Analysis Files
```

### 3.3 外置缓存

- 只通过资源库根目录的 `.fcpcache` 符号链接定位外置缓存。
- `.fcpcache` 必须解析为资源库外部的真实目录。
- 只识别与已验证 Event 同名目录下的白名单路径。
- 不会因为目录名称中出现 `Render Files` 就进行清理。
- 清理前会再次验证 `.fcpcache` 指向没有改变。

### 3.4 增量扫描

- 扫描结果保存在用户缓存目录。
- 使用 Library 数据库快照和已确认生成目录指纹判断缓存是否仍然有效。
- 自动扫描和普通刷新优先复用有效缓存。
- 设置中提供“完整重新扫描”。
- 3.0.1 开始，文件指纹在扫描阶段写入 `CacheItem`，点击清理不再重新遍历大型目录。

### 3.5 批量选择和清理

- 支持资源库多选、全选和取消全选。
- 支持按磁盘切换资源库列表。
- 资源库按钮同时承担当前详情切换和批量选择。
- 批量按钮显示：`正在检查 x/y`、`正在清理 x/y`。
- 批量清理按资源库顺序执行，不并发移动同一外置盘的数据。
- 所有移动完成后才统一排队重新扫描，避免与清理争抢磁盘 I/O。

### 3.6 风险检测

确认前进行轻量预检：

- 资源库是否存在。
- 资源库和清理目录所在卷是否在线。
- 卷是否只读。
- 父目录是否可写。
- 资源库结构是否仍然匹配白名单。
- FCP 是否正在使用目标资源库。
- Library/Event 数据库是否发生变化。

执行每个清理项目之前：

- 再次检查磁盘和资源库状态。
- 再次检查 FCP 占用。
- 再次检查核心数据库。
- 重新计算完整目录指纹并和扫描结果比较。
- 只有全部通过才调用 `trashItem()`。

FCP 占用检测使用 `NSRunningApplication` 和 `/usr/sbin/lsof`，只阻止 FCP 当前实际打开的目标资源库，不会因为 FCP 打开其他 Library 就全部阻止。

### 3.7 其他功能

- 30、90、180 天未使用资源库筛选。
- 可调磁盘剩余空间预警，默认 100 GB。
- 每 15 分钟检查磁盘，低空间时最多每 6 小时触发一次增量扫描。
- 系统清理完成通知和低空间通知。
- 菜单栏显示可清理空间，提供打开、扫描、清理和退出。
- 清理历史最多保留 200 条。
- 历史记录支持在废纸篓中显示和恢复。
- 恢复前检测 FCP 占用、目标路径冲突和写入权限。
- 中文深色紧凑界面。
- 应用图标使用用户提供的紫色三星扫帚图，页眉使用独立矢量清理标记。

## 4. 已取消或替代的早期需求

其他开发工具不要按照早期文档重新实现以下内容：

- 不再提供 Safe、Standard、Maximum 多档模式。
- 当前只有一套“最大安全清理”标准。
- 不提供分类复选框，确认的三个分类全部参与清理。
- 不清理 Analysis Files、Optical Flow、Stabilization、Thumbnail 或 Waveform。
- 不永久删除文件。
- 不显示大量介绍性文案。
- 产品名称已经从 `FCP Library Cleaner` 改为 `FCP Cleaner`。

如需扩大白名单，必须先取得真实 FCP 目录样本、增加精确结构规则、执行前校验和对应自动测试。禁止仅凭目录名称扩展清理范围。

## 5. 项目结构

```text
FCPLibraryCleaner/
├── Package.swift
├── Package.resolved
├── Assets/
│   ├── FCP-Cleaner-Icon-1024.png
│   ├── FCP-Cleaner-Icon-Full-1024.png
│   ├── FCP-Cleaner-Pen-Logo-Crop.png
│   ├── FCP-Cleaner.iconset/
│   └── FCP-Cleaner.icns
├── Sources/
│   ├── FCPLibraryCleanerCore/
│   ├── FCPLibraryCleanerApp/
│   └── fcp-library-scanner/
├── Tests/
│   └── FCPLibraryCleanerCoreTests/
└── Distribution/
    ├── FCP Cleaner.app/
    └── FCP-Cleaner-3.0.1-arm64.dmg
```

### 5.1 Core 模块

| 文件 | 作用 |
| --- | --- |
| `Models.swift` | 扫描结果、缓存分类、错误和快照模型 |
| `FCPStructureRules.swift` | 内部和外置缓存的精确白名单规则 |
| `CacheClassifier.swift` | 根据规则定位候选目录 |
| `LibraryScanner.swift` | 只读扫描、体积统计、指纹和进度 |
| `CleanupPlan.swift` | 从扫描结果生成不可变清理计划 |
| `CleanupEngine.swift` | 预检、最终复核和移入废纸篓 |
| `LibraryUseDetector.swift` | 使用 `lsof` 检查目标资源库占用 |
| `LibraryInspector.swift` | 生成安全检查目录树 |
| `ScanControl.swift` | 扫描取消控制 |

### 5.2 App 模块

| 文件 | 作用 |
| --- | --- |
| `FCPLibraryCleanerApp.swift` | SwiftUI App、菜单命令和菜单栏入口 |
| `ContentView.swift` | 主界面、设置、历史和全部 UI 组件 |
| `LibraryStore.swift` | 主状态、扫描队列、批量清理和磁盘监控 |
| `ScanResultCache.swift` | 增量扫描结果缓存 |
| `SecurityScopedBookmarkManager.swift` | 权限书签和最近资源库 |
| `CleanupHistoryStore.swift` | 清理历史、废纸篓定位和恢复 |
| `NotificationController.swift` | 系统通知 |
| `FinderServiceProvider.swift` | Finder 服务和系统打开文件处理 |
| `UpdateController.swift` | Sparkle 更新入口 |

## 6. 核心数据流

```text
发现/选择 .fcpbundle
        ↓
LibraryStore 加入扫描队列（最多 3 个并发）
        ↓
ScanResultCache 检查 LibraryChangeToken
        ↓
缓存有效：复用结果
缓存无效：LibraryScanner 完整扫描
        ↓
CacheItem 保存体积、规则、存储位置和 FileFingerprint
        ↓
用户单选或多选，点击清理
        ↓
CleanupPlan 直接复用扫描指纹，不重新遍历目录
        ↓
CleanupEngine 轻量预检
        ↓
用户确认移入废纸篓
        ↓
每个条目执行最终完整指纹验证
        ↓
FileManager.trashItem()
        ↓
保存历史、通知、批量结束后重新扫描
```

## 7. 关键模型约束

### `CacheItem`

必须包含：

- URL
- 分类
- 分配大小和逻辑大小
- 检测置信度
- 规则 ID
- `.library` 或 `.external` 存储类型
- 扫描时计算的 `FileFingerprint`

### `FileFingerprint`

当前由以下数据组成：

- 分配大小
- 逻辑大小
- 文件条目数量
- 路径、大小、修改时间和 inode 的稳定签名

它不是密码学哈希，目标是判断同一清理计划中的目录是否发生变化。

### `CleanupPlan`

- 必须由已完成的 `LibraryScanResult` 创建。
- 只能包含 `.confirmed` 且位于白名单分类中的条目。
- 计划创建不得重新遍历大型目录。
- 重试计划只能保留没有成功移入废纸篓的条目。

## 8. 状态和持久化

| 数据 | 存储位置 |
| --- | --- |
| 最近资源库书签 | `UserDefaults`：`recentLibraryBookmarks` |
| 工作目录书签 | `UserDefaults`：`workDirectoryBookmarks` |
| 通知开关 | `UserDefaults`：`notificationsEnabled` |
| 磁盘预警阈值 | `UserDefaults`：`lowSpaceWarningGB` |
| 扫描缓存 | `~/Library/Caches/com.fcpcleaner.app/ScanResults/` |
| 清理历史 | `~/Library/Application Support/com.fcpcleaner.app/CleanupHistory.json` |

修改 `CacheItem`、`LibraryScanResult` 或指纹结构后，旧扫描缓存可能无法解码。当前策略是缓存失效后自动完整重扫，不迁移危险的旧结构。

## 9. UI 和交互要求

- 所有用户界面使用简体中文，产品名除外。
- 保持深色、紧凑、低文字密度。
- 不增加大段功能介绍和营销文案。
- 主流程按钮必须有明确状态，不能表现为无响应。
- 批量准备显示 `正在检查 x/y`。
- 批量执行显示 `正在清理 x/y`。
- 错误通知必须显示第一条真实 `localizedDescription`，不能只显示“1 项失败”。
- 已清理并低于 500 MB 的资源库应从“待清理”列表移除。
- 磁盘摘要按钮必须可以切换，并保持其他磁盘按钮可见。
- 应用图标不得重新生成或替换用户提供的图案。

## 10. 构建和测试

### 开发构建

```bash
cd /Users/macstudio/Documents/VoxCPM2/FCPLibraryCleaner
swift build
```

### 运行测试

```bash
swift test
```

当前基线：22 项测试全部通过。

测试重点包括：

- 只识别确认过的 Event 路径。
- 永不跟随 Original Media 外链。
- 外置 `.fcpcache` 只识别有效 Event。
- 外置链接变化会使清理失败。
- 扫描后候选目录或数据库变化会被阻止。
- FCP 使用其他资源库不会阻止目标清理。
- FCP 在预检后打开目标资源库会停止清理。
- 离线资源库返回明确错误。
- 清理计划直接复用扫描阶段指纹。
- 成功移动后能够获得真实废纸篓路径。

### 发布构建

```bash
swift build -c release --product FCP-Cleaner
```

Swift Package 不会自动生成完整 `.app`，当前发布流程使用：

```text
Distribution/FCP Cleaner.app
```

作为 App Bundle 模板，更新以下内容：

1. 将 Release 可执行文件复制到 `Contents/MacOS/FCP-Cleaner`。
2. 将 `.build/arm64-apple-macosx/release/Sparkle.framework` 复制到 `Contents/Frameworks/`。
3. 将 `Assets/FCP-Cleaner.icns` 复制到 `Contents/Resources/`。
4. 确认存在 `@executable_path/../Frameworks` rpath。
5. 清除扩展属性并签名。
6. 创建带 Applications 软链接的 DMG。

关键命令：

```bash
install_name_tool -add_rpath '@executable_path/../Frameworks' \
  'Distribution/FCP Cleaner.app/Contents/MacOS/FCP-Cleaner'

xattr -cr 'Distribution/FCP Cleaner.app'
codesign --force --deep --sign - 'Distribution/FCP Cleaner.app'
codesign --verify --deep --strict --verbose=1 'Distribution/FCP Cleaner.app'
```

发布前必须更新 `Info.plist`：

- `CFBundleShortVersionString`
- `CFBundleVersion`

## 11. Sparkle 状态

- 当前依赖 Sparkle 2.9.6。
- Public EdDSA Key 已写入 App `Info.plist`。
- 当前没有有效的公开 `SUFeedURL`。
- 不要使用父目录 VoxCPM 项目的 GitHub Remote 作为更新源，该 Remote 与本项目无关。
- 私钥由 Sparkle 工具存储在本机钥匙串中，不要把私钥写入代码或文档。

## 12. 当前限制和技术债务

1. 当前 DMG 只有 arm64，没有 Intel 通用版本。
2. 当前使用 ad-hoc 签名，没有 Apple Developer ID 公证。
3. 没有 Xcode 工程，App Bundle 和 DMG 打包是手工流程。
4. 没有完整 SwiftUI 自动化测试，现有测试主要覆盖 Core 安全逻辑。
5. Finder 功能使用 macOS Services，不是独立 Finder Sync Extension。
6. FCP 没有公开的单资源库锁 API，占用检测依赖 `lsof`。
7. 外置缓存结构目前只支持 `.fcpcache` 明确链接，不猜测其他目录。
8. Library 总大小只表示资源库包自身大小，外置缓存会单独计入可清理空间。
9. 大型资源库完整扫描和最终指纹复核仍然需要遍历文件元数据，这是安全要求，不能简单移除。
10. 项目目录位于另一个大型项目目录中，目前不是独立 Git 仓库。

## 13. 发布验收清单

每次交付前必须完成：

- [ ] `swift test` 全部通过。
- [ ] 单选清理确认框正常出现。
- [ ] 多选和全选后，批量确认框正常出现。
- [ ] 批量准备和执行显示进度。
- [ ] FCP 打开目标资源库时清理被阻止并显示具体原因。
- [ ] FCP 只打开其他资源库时不误阻止。
- [ ] 外置盘在线、可写和废纸篓移动正常。
- [ ] 磁盘切换后列表可点击。
- [ ] 清理历史和恢复入口正常。
- [ ] Finder 服务已注册。
- [ ] 菜单栏入口存在。
- [ ] App 版本号和 Build 号正确。
- [ ] Sparkle Framework 存在且 rpath 正确。
- [ ] `codesign --verify --deep --strict` 通过。
- [ ] DMG 能以只读方式挂载。
- [ ] 包内可执行文件为预期架构。

## 14. 给其他 AI 编程工具的启动提示词

可以将下面内容连同本文件一起提供给其他开发工具：

```text
你正在维护一个原生 macOS SwiftUI 应用 FCP Cleaner。

项目路径：/Users/macstudio/Documents/VoxCPM2/FCPLibraryCleaner

开始工作前请完整阅读 PROJECT_HANDOFF_ZH.md，并检查当前源码，不要仅依据早期需求文档开发。

最高优先级是数据安全：只允许清理 FCPStructureRules 中精确白名单匹配、confidence 为 confirmed 的 Render Files、Proxy Media 和 Optimized Media。禁止删除 Original Media、数据库、分析文件和未知结构。所有清理必须使用 FileManager.trashItem()，并在执行前检查 FCP 占用、磁盘状态、数据库快照和完整文件指纹。

当前 UI 必须保持简体中文、深色、紧凑，不要增加大量说明文字。应用图标必须继续使用 Assets 中用户提供的紫色三星扫帚图。

修改前先运行 swift test。完成后补充对应测试，确保全部测试通过，再构建 App 和 DMG。不要触碰同级 VoxCPM2 项目的无关文件，也不要使用其 Git Remote 发布本项目。
```

## 15. 建议的后续工程化工作

按优先级建议：

1. 将项目迁移为独立 Git 仓库。
2. 创建正式 Xcode 工程和可重复的 Release 脚本。
3. 配置 Developer ID、Hardened Runtime 和 Apple Notarization。
4. 增加 LibraryStore 和 SwiftUI 批量清理 UI 自动化测试。
5. 增加真实外置 APFS、HFS+、ExFAT 卷的集成测试矩阵。
6. 建立独立更新服务器并配置 `SUFeedURL`。
7. 构建 universal2 版本并验证 Intel macOS 15。

