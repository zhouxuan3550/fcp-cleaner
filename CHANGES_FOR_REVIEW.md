# FCP Cleaner 修改审查报告

> 供外部工具/开发者评审。本文档汇总本会话对 `/Users/macstudio/Documents/VoxCPM2/FCPLibraryCleaner` 的全部修改，按主题分组，附提交哈希、设计决策与验证方式。评审时建议对照 `git log` 与 `git show <hash>` 逐项核对。

## 一、会话起点与终点

| | 会话开始 | 当前 |
| --- | --- | --- |
| 版本 | 3.1.0（2 个提交，DMG 手工打包） | 3.9.1（7 个 Release 已上线） |
| 测试 | 22 项 Core 测试 | 46 项测试 / 8 个测试套件（新增 App 层测试目标） |
| 更新分发 | 无 SUFeedURL，Sparkle 摆设 | feed 已上线，五个历史版本全签名 |
| 文档 | 交接文档多处过时 | 与现实同步 |

## 二、变更总览（按提交）

### A. 正确性修复（P0）

| 提交 | 内容 |
| --- | --- |
| `65c4b92` | ① `LibraryStore.remove()` 现在会清出扫描队列并取消运行中扫描（此前移除扫描中的库会占用并发槽位）；② `lastError` 拆分为 `scanError`/`cleanupError`，侧栏区分「扫描失败」与「预检未通过」（此前 FCP 占用导致的预检失败会被误标为扫描失败）；③ ⌘R/⌘⌫/⌘A 菜单命令增加响应式禁用态（`canRescanSelectedLibrary` 等三个计算属性），消灭"按了没反应"；④ 删除死代码 `requestPrimaryClean` |
| `e68523d` | `FCPStructureRules.candidateLocation` 补 6 组测试：共享缓存、事件名推导、多级路径剥离、`external.` 前缀两种、未知 ruleID 返回 nil |

### B. 性能

| 提交 | 内容 |
| --- | --- |
| `60ce507` | 清理耗时预估按卷分桶。新增 Core 类型 `CleanupThroughputIndex`（Sendable/Codable，按卷 UUID 滚动窗口 10 样本），替换原先"所有盘混算一个全局平均"的旧实现（外置机械盘的预估曾被内置 SSD 样本污染得严重乐观）。批量预估 = 逐条目求和，任一卷缺样本则整体隐藏。持久化 key 升级为 `cleanupThroughputIndexV2`，有意丢弃旧数据避免导入跨卷污染 |
| `cf7ef8b` | 新增 `ScanProgressCoalescer`（NSLock 保护的合并器）：扫描器回调仍逐步触发，但主线程跳转被限制为每 100 ms 至多一次。尾部被抑制的进度刻意不补发（扫描结束会换结果视图，取消有独立通道） |
| `2bb739a` | 低空间评估与发现候选校验（fileExists/statfs/数据库存在性）移出主线程至 utility 任务，仅状态应用回 MainActor；加 `isEvaluatingLowSpace` 重入防护。网络工作目录不再可能冻结 UI |
| `8866924` | Spotlight `DidUpdate` 高频事件触发 merge 时，已入库 URL 直接放行，不再对全部已知库重复跑三次文件系统调用（101 库时每次事件约省 300 次调用）；零新库时跳过重排与书签回写 |

### C. 数据安全加固

| 提交 | 内容 |
| --- | --- |
| `83a0b10` | 对抗性夹具测试 5 组（全链路 扫描→计划→执行）：① Render Files 内藏指向 Original Media 的软链——链接随目录进废纸篓、目标媒体存活；② 扫描后把 Render Files 换成指向 Original Media 的软链——该条目被拒、兄弟条目隔离推进、原片完好；③ 扫描后事件改名——零删除；④ 仿白名单干扰目录（`Render Files Old` 等）进保护清单且绝不被清理；⑤ 不可读子树使扫描保守失败 |
| `dba22ef` | 卷身份绑定：`RecentLibraryMetadata` 增加可选 `volumeUUIDRaw`；恢复时同路径 UUID 不同则拒绝复活旧条目（防止异盘同名库继承上一块盘的元数据）。旧档案缺字段时可选解码，向后兼容 |
| `5a12c5e` | `LibraryUseDetector` 加 10 秒超时（原先 `readDataToEndOfFile` 可永久阻塞），可注入 lsofPath/timeout；启动失败/非零退出/超时一律按"被占用"处理（fail-closed）。3 组失败模式测试注入假二进制，无需真实 FCP |
| `a7ed90a` | 扫描缓存条目加显式 `schemaVersion`（当前 2）：旧缓存缺键解码失败自动全量重扫——把隐式解码崩溃变成显式版本门槛 |
| `79d6cf4` | 取消传播测试：首个进度回调即取消，断言 3 秒墙钟内以 `CancellationError` 收场 |

### D. 可靠性

| 提交 | 内容 |
| --- | --- |
| `0b0adbd` | 扫描/批量清理/单库清理三个 Task 包 `beginActivity(.userInitiatedAllowingIdleSystemSleep)` 防 App Nap 节流；`directorySize` 每 30 秒打 os.log 心跳（路径隐私掩码），区分"慢"与"死" |

### E. 发布体系

| 提交 | 内容 |
| --- | --- |
| `38c793d` 等 | Sparkle 依赖 `from:` → `exact: "2.9.6"`；`release.sh` 自动清理历史 staging；旧 DMG 归档至 `Distribution/archive/`；两份文档同步现实（universal2、自动打包、SUFeedURL、独立仓库、测试基线） |
| `12c76e2` | `Scripts/publish_appcast.sh`：推 gh-pages 前强制校验每个 enclosure 有 EdDSA 签名、HEAD 200、最新 sparkle:version 匹配、无重复版本（本会话中它实际拦截过一次合并失误）。`Scripts/fs_matrix.sh`：APFS/HFS+/ExFAT 稀疏镜像矩阵，断言三格式清理项同为 3 且原片存活 |
| 发布流程 | v3.5.0 → v3.9.1 六个 tag + GitHub Release，appcast 经闸门部署 gh-pages，feed 实测逐版本验证 |

### F. 产品能力与 UX

| 提交 | 内容 |
| --- | --- |
| `7248d3a` | Spotlight 收紧：statfs 本地卷判定 + Time Machine 卷排除 + 候选必须含资源库数据库；来源标识「工作目录/本机发现」持久化 |
| `8435dac` | 外置盘诊断区块：在线/只读/断开三态探针（后台执行）+ 上次可访问时间 + 「重新授权」重铸安全作用域书签（校验所选与原库一致） |
| `3f1b6b8` | 设置层级重排（新增「当前资源库」分组头显示库名——此前逐库操作悬在全局设置中间）；每个工作目录行显示发现状态（发现 N 个 / 未发现 .fcpbundle / 无法访问，枚举失败不再静默）；关于页署名 B 站 调色师手册 |
| `0c8a10d` | ContentView（1700+ 行）拆为 Views{Header,Sidebar,LibraryDetail,ConfirmationSheets,SettingsAndHistory}.swift，仅保留根视图、`shortPath` 与两个共享扩展；同提交新增「在 Finder 中显示」「拷贝资源库路径」（详情右键 + 设置） |
| `aa4762e` | P2 三项：① `WorkDirectoryMonitor` FSEvents 监听工作目录，5 秒防抖触发去重发现（只读、不追踪用户媒体）；② 设置「扫描健康」分组（总数/已扫描/缓存复用/失败名单/待扫描）；③ 清理后空间回收校验——重扫实测降幅低于计划释放 90% 时提示"空间统计待系统刷新" |

### G. 已尝试并回退（重要，供评审关注）

**扫描器单次归因遍历优化**：意图将候选目录指纹遍历与全库体积遍历合并（理论省近一半扫描 syscall）。实现后指纹等价性测试（归因聚合 vs `CleanupPlan.fingerprint` 直接遍历逐条比对）抓到偏差，一轮修补后仍有 14 处失败，遂整体 `git checkout` 回退。**回退后 46/46 全绿，未上线任何可疑代码**。留下的验收标准：等价性逐条比对测试 + 既有真实清理测试网。注意 FNV 签名累加为环绕加法（顺序无关）这一点已验证可行，偏差根源在别处未定位。

## 三、测试体系（46 项 / 8 套件）

| 套件 | 覆盖 |
| --- | --- |
| LibraryScannerTests（既有 22 项） | 白名单、外链不跟随、指纹、占用检测、取消 |
| AdversarialLibraryTests | 五类敌意文件系统形态全链路 |
| FCPStructureRulesTests | candidateLocation 全分支 |
| VolumeThroughputTests | 分桶/隔离/滚动窗口/加权均值 |
| LibraryDiscoveryRulesTests | 本地卷/TM 卷谓词 |
| LibraryUseDetectorTests | lsof 三种失败模式（注入式） |
| ScanCancellationTests | 取消 3 秒墙钟 |
| FCPLibraryCleanerAppTests（新目标） | 证实 executable 可 @testable 导入；外观映射、门槛拒收 |

## 四、评审建议重点

1. `LibraryStore.swift` 的 `merge/validateCandidates/applyValidatedCandidates` 异步拆分（S4）——注意 merge 变为 fire-and-forget Task 后与 `discoveryRunID` 防竞态的交互
2. `LibraryUseDetector.detectInUse` 的超时轮询与 LockedBuffer 模式
3. `AdversarialLibraryTests` 的断言是否充分（尤其 post-scan swap 的兄弟条目隔离语义）
4. 发布闸门 `Scripts/publish_appcast.sh` 的 bash/python 混合实现

## 五、已知遗留

- Developer ID 签名与公证：需用户提供 Apple 开发者账号，`release.sh` 一行可切换
- 扫描器单遍历优化：见上文 G，等价性测试已就位作验收闸
- LibraryStore 深层状态机测试：需 init 级依赖注入（隔离 UserDefaults/书签），接缝已验证可行
