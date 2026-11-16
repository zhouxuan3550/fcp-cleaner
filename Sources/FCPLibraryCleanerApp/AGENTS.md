# FCPLibraryCleanerApp/
> L2 | Parent: /AGENTS.md

主窗口从 `FCPLibraryCleanerApp` 进入 `ContentView`。`LibraryStore` 汇集扫描、发现和清理状态。视图只能调用 Store 的安全入口，不直接删除资源库文件。

APFSSnapshotGuard.swift: 清理前创建并核对 APFS 快照。
AppIntents.swift: 暴露只读快捷指令入口。
BrandLinksView.swift: 品牌及外部链接视图。
ButtonStyles.swift: 共用按钮样式与减少动态效果适配。
CleanupCoordinator.swift: 协调单库和批量清理，并转发逐项执行进度。
CleanupHistoryStore.swift: 持久化清理历史。
CleanupSummaryModels.swift: 清理摘要与展示状态模型。
CleanupThroughputStore.swift: 按磁盘保存清理吞吐样本。
CleanupTransactionJournal.swift: 记录可恢复的清理事务。
ContentView.swift: 组合主窗口、弹窗和通知浮层。
DashboardView.swift: 汇总卷压力和清理推荐。
DesignTokens.swift: 颜色、字体、布局及兼容玻璃效果。
DiagnosticsExporter.swift: 导出诊断资料。
FCPLibraryCleanerApp.swift: 注册主窗口、设置窗口、历史窗口、菜单栏及键盘命令。
FSEventsCheckpoint.swift: 保存卷日志检查点。
FSEventsHistoryProbe.swift: 校验历史事件能否支持缓存复用。
FSEventsLiveLease.swift: 监听缓存复用后的迟到事件。
FinderServiceProvider.swift: 与 Finder 服务交互。
LibraryScanQueue.swift: 调度多资源库扫描请求。
LibrarySizeTrend.swift: 保存资源库体积趋势。
LibraryStore+Cleanup.swift: 清理预检、Event 预选、确认与执行状态流。
LibraryStore+Discovery.swift: 发现与载入资源库。
LibraryStore+LiveCache.swift: 处理实时缓存失效和清理通知队列。
LibraryStore+Orphans.swift: 收集只读孤立缓存信息。
LibraryStore+Scanning.swift: 启动扫描、合并进度和保存结果。
LibraryStore.swift: 定义资源库记录、筛选、清理进度与通知队列状态。
Localizable.xcstrings: 界面简体中文源文案和英文翻译。
NotificationController.swift: 发送系统通知。
OrphanCacheDiscovery.swift: 在工作目录查找疑似孤立缓存。
ScanProgressCoalescer.swift: 合并高频扫描进度。
ScanResultCache.swift: 持久化扫描结果与 FSEvents 检查点。
ScheduledCheckController.swift: 管理定期检查。
SecurityScopedBookmarkManager.swift: 保存和恢复目录访问权限。
TrashPurgeJournal.swift: 记录定向清空废纸篓的恢复信息。
TrashPurgeService.swift: 执行经确认的定向清空。
UpdateController.swift: 管理 Sparkle 更新。
ViewsConfirmationSheets.swift: 显示单库、批量清理确认与结果。
ViewsHeader.swift: 标题栏及全局导航控件。
ViewsLibraryDetail.swift: 展示概览、明细、单库记录、Event 操作入口和固定清理栏。
ViewsSettingsAndHistory.swift: 独立设置与全局历史窗口内容。
ViewsSidebar.swift: 资源库筛选、方向键选择、扫描进度和批量操作。
VolumeMountMonitor.swift: 监视挂载状态。
WorkDirectoryMonitor.swift: 监视工作目录变化。

[PROTOCOL]: Update this header on change, then check AGENTS.md
