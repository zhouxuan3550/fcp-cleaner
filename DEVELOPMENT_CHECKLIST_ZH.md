# FCP Cleaner 开发清单

更新日期：2026-08-27（第二轮执行后复核）。本文以当前公开仓库 `main` 为准。

## 已核对的状态

- 3.5.0 源码已提交并推送；`v3.5.0` 注释 tag 已创建并推送，且已建立同名 GitHub Release 并挂载 DMG。
- 清理并发入口和批量清理结果摘要已修复。
- 最低清理门槛为固定 200 MB，是已记录的产品决定。
- 当前 App 包已配置 `SUFeedURL`，Sparkle 依赖已在 Package.swift 钉死 exact 2.9.6。
- 更新地址 `https://zhouxuan3550.github.io/fcp-cleaner/appcast.xml` 已返回 HTTP 200，内容含 EdDSA 签名；剩余仅“干净安装旧版本实测发现更新”一项人工验证。
- 当前 Core 有 34 项测试；App 层状态逻辑尚无自动化测试（吞吐分桶与发现规则谓词已在 Core 覆盖）。

## P0：正确性与发布阻塞

- [x] 给 3.5.0 创建并推送带注释的 `v3.5.0` tag。
  - 验收：tag 指向 `Release FCP Cleaner 3.5.0` 提交，GitHub Release 使用同一 tag。
- [x] 移除资源库时取消扫描队列和运行中的扫描。
- [x] 分离扫描错误与清理前检查错误。
- [x] 让 `Cmd-R`、清理和扫描菜单命令具备可见禁用状态或用户反馈。
- [x] 补齐 `FCPStructureRules.candidateLocation` 测试。
- [ ] 接通 Sparkle 发布闭环，或在完成前隐藏更新功能。
  - 已完成：GitHub Release v3.5.0 挂载 DMG；EdDSA 签名 appcast 部署到 gh-pages 并启用 Pages；feed 实测 HTTP 200 且 enclosure 可下载。
  - 剩余：干净安装旧版本实测“发现更新→下载→安装”的人工验证。

## P1：性能与外置盘可靠性

- [x] 为清理耗时预估按卷分桶。
- [x] 节流扫描进度更新。
- [x] 收紧 Spotlight 自动发现并提供结果来源。
- [x] 增加外置盘权限与在线状态诊断。

## P2：产品能力

- [ ] 为工作目录增加低成本的目录变更监听。
  - 原则：发现新的 `.fcpbundle` 时加入扫描队列；不自动清理，不追踪用户媒体内容。
  - 验收：工作目录中新建或挂载资源库后，应用在合理延迟内提示发现结果。
- [ ] 增加“扫描健康度”视图。
  - 内容：上次扫描时间、扫描耗时、跳过原因、不可访问资源库和可释放空间变化。
  - 验收：用户无需查看日志即可判断自动扫描是否真正完成。
- [ ] 提供清理后空间回收校验。
  - 实现：重扫结束后显示计划释放量与实际扫描差异；超过阈值时标记“空间统计待系统刷新”，避免误报。
  - 验收：APFS 延迟回收或废纸篓仍占空间时，界面不会承诺错误的立即可用容量。
- [ ] 优化 Finder 集成。
  - 实现：保留现有 Service，并增加“在 Finder 中显示资源库”“复制资源库路径”；若 macOS 支持，评估 Quick Action。
  - 验收：从 Finder 选中 `.fcpbundle` 可稳定打开并定位到 FCP Cleaner。

## P3：工程健康与发布卫生

- [x] 删除无调用方的 `requestPrimaryClean`，或接入为唯一主清理入口。
- [ ] 抽取 `LibraryStore` 的发现、扫描队列、清理协调和磁盘监控职责。
- [ ] 将 `ContentView` 按 Header、Sidebar、Library Detail、Confirmation Sheets、History 拆分文件。
- [ ] 为 App 状态增加测试。（部分：吞吐分桶、发现规则谓词已在 Core 测试覆盖；Store 状态机测试依赖上述抽取）
- [x] 固化依赖版本策略。
- [x] 同步 `PROJECT_HANDOFF_ZH.md`。
- [x] 清理 `Distribution/` 的历史 staging 和重复 DMG。

## 执行记录（2026-08-27 第二轮）

| 项目 | 提交 | 说明 |
| --- | --- | --- |
| v3.5.0 tag + Release | （tag） | 注释 tag 推送；Release 挂载 universal DMG |
| 生命周期修复组 | `65c4b92` | 移除取消扫描 / scanError·cleanupError 拆分 / 菜单禁用态 / 删死代码 |
| candidateLocation 测试 | `e68523d` | 共享缓存、事件名推导、external 前缀、未知 ID（+6 用例）|
| 按卷吞吐分桶 | `60ce507` | Core CleanupThroughputIndex + 卷 UUID 键控持久化（+4 用例）|
| 进度节流 | `cf7ef8b` | ScanProgressCoalescer，~100 ms 主线程合并 |
| 发现收紧 | `7248d3a` | statfs 本地卷判定 + TM 排除 + 数据库预校验 + 来源标签（+2 用例）|
| 外置盘诊断 | `8435dac` | 设置弹窗诊断区块、重授权、上次可访问时间 |
| 工程卫生 | 本轮收尾提交 | Sparkle exact 2.9.6 / staging 清理 / 旧 DMG 归档 archive/ / 双文档同步 |

测试基线由 22 提升到 34，全部通过。P2 四项产品能力尚未开始。

## 暂不建议做

- 不增加“清理级别”或让用户选择目录类别。产品定位是固定的最大安全清理，白名单策略应保持单一且可审计。
- 不自动执行清理。自动发现和自动扫描可以开启，但移动文件到废纸篓必须经过用户确认。
- 不在未完成签名、公证和更新托管前宣传 Sparkle 自动更新可用。
