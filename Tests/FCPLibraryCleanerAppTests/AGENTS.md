# FCPLibraryCleanerAppTests/
> L2 | Parent: /AGENTS.md

测试只使用临时资源库和注入服务。不得访问或清理用户真实项目。

APFSSnapshotGuardTests.swift: 验证快照条件与失败回退。
AppIntentsTests.swift: 验证只读快捷指令入口。
CleanupCoordinatorTests.swift: 验证执行结果、吞吐记录和 Event 路径预选。
CleanupHistoryFileTests.swift: 验证历史文件持久化。
CleanupTransactionJournalTests.swift: 验证中断清理事务记录。
DashboardRankingTests.swift: 验证总览推荐排序。
DiagnosticsExporterTests.swift: 验证诊断导出与路径脱敏。
FSEventsCheckpointTests.swift: 验证增量缓存检查点。
IgnoreAndSnoozeTests.swift: 验证忽略与延后提醒状态。
LibraryScanQueueTests.swift: 验证扫描请求调度。
LibrarySizeTrendTests.swift: 验证体积历史与增长计算。
LibraryStoreStateMachineTests.swift: 验证扫描状态切换与取消。
OrphanCacheDiscoveryTests.swift: 验证只读孤立缓存识别。
ScanResultCacheTests.swift: 验证扫描结果缓存写入与复用。
ScheduledCheckTests.swift: 验证定时检查调度。
TrashPurgeJournalTests.swift: 验证定向删除的中断日志。
TrashPurgeServiceTests.swift: 验证临时样本上的定向删除约束。
VolumeHotPlugTests.swift: 验证磁盘断开与重连状态。
WorkflowCallbackTests.swift: 验证 Workflow Extension 回调状态。

[PROTOCOL]: Update this header on change, then check AGENTS.md
