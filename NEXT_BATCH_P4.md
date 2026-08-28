# 下一批次需求（P4：效率与自动化，共 8 项）

> 2026-08-28 由用户下达。新会话按序号实施，每项独立提交。注意标 ⚡ 的已有基础。
>
> **2026-08-28 实施完毕**：8 项全部交付，每项独立提交，75 项测试全绿。
> 提交对照：1)`adc8c2b` 2)`2be557a` 3)`a5505ee` 4)`5290c3b` 5)`67808ae` 6)`4b4ac25` 7)`af893d9` 8)`f990b16`。
> 注意：P4-6 的三个 AppIntent 已实现，但 Shortcuts 发现依赖构建期元数据提取（SPM 路径缺 Swift const values），
> 与 Quick Action 同样依赖 Xcode 工程迁移，详见 QUICK_ACTION_EVALUATION.md §5。

1. **外置盘热插拔**：`DDDiskSpace`/`NSWorkspace.willUnmount` 或 IOKit 检测挂载；挂载→对库内资源库入队增量扫描；卸载→保留 `LibraryRecord`（已有 `lastKnownCleanableSize` 兜底），重连后复用书签自动恢复。与 `VolumeAccessReport` 诊断联动。
2. **忽略与稍后**：`LibraryRecord.ignoredUntil: Date?` + 目录级忽略集（存 UserDefaults）；被忽略的库从 waiting 过滤并显示在新的「已忽略」筛选；行操作「7 天内不再提醒」。禁止忽略 Original Media 相关——仅作用发现层。
3. **定时检查**：`Timer`/`Task.sleep` 周期（日/周）跑 `discoverLibraries()+scan`，完成后仅发通知（复用 `NotificationController`），**绝不自动清理**（产品红线）。
4. **空间趋势**：复用 `CleanupHistoryStore` 累计值 + 新增轻量 `sizeSamples`（每库每日一点，UserDefaults JSON）；UI 在详情面板加"周增长"徽标，列表突出增长最快者。
5. ⚡ **Finder 快速操作**：Services 项「使用 FCP Cleaner 扫描」已存在（见交接文档 §3.1）；本项只补 Quick Action 扩展评估，非从零。
6. **Shortcuts**：App Intents（`ScannedWorkDirs`/`ScanLibrary`/`ShowCleanableSpace` 三个 AppIntent），macOS 15 AppIntents 框架，只读操作为主。
7. ⚡ **清理事务增强**：`failedCleanupPlan.retryingItemsNotCompleted` + 「重试失败项」按钮已存在；本项补：中断（崩溃/断电）后重启时依据 `CleanupHistoryStore` 的 trashedItems 与重扫差集自动重建待清计划，入口放历史页。
8. **诊断包**：菜单项「导出诊断信息」→ NSSavePanel 输出 zip：近 1h os.log（`log show --predicate subsystem=="com.fcplibrarycleaner"` 脱敏路径 hash 已内建）、`VolumeAccessReport` 全量、书签状态、最近失败原因（CleanupHistoryStore）。

## 验收与纪律
- 每项配测试（Core 可测逻辑优先）；监控类功能不得引入主线程 I/O。
- 红线不变：不扩白名单、不自动删除、trashItem only。
- 发布走 `release.sh` + `Scripts/publish_appcast.sh` 闸门。
