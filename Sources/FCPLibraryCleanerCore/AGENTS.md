# FCPLibraryCleanerCore/
> L2 | Parent: /AGENTS.md

Core 识别 FCP 结构并计算指纹。App 只通过计划和清理引擎执行移动；未知结构不得进入计划。

BulkDirectoryWalker.swift: 批量读取目录元数据并回退兼容遍历。
CacheClassifier.swift: 按白名单区分缓存与受保护内容。
CleanupEngine.swift: 清理前逐项复核并移入废纸篓，发送只读进度。
CleanupPlan.swift: 生成清理计划和持久文件指纹。
CleanupThroughputIndex.swift: 按磁盘归纳历史清理吞吐。
FCPStructureRules.swift: 定义库级和 Event 级候选路径规则。
LibraryDiscoveryRules.swift: 验证资源库发现候选。
LibraryInspector.swift: 只读遍历并输出目录报告。
LibraryScanner.swift: 扫描资源库与外置缓存，聚合候选结果。
LibraryUseDetector.swift: 检查目标资源库是否被 Final Cut Pro 使用。
Models.swift: 定义跨模块扫描、候选和清理数据模型。
ReclaimableSpaceEstimate.swift: 估算 APFS 独占可释放空间。
ScanControl.swift: 传播扫描取消请求。
TrashItemSnapshot.swift: 记录废纸篓条目身份以支持后续核对。
VolumeMountRules.swift: 核对挂载卷和文件系统状态。
VolumeScanProfile.swift: 按设备特征确定扫描额度。
VolumeTraversalScheduler.swift: 按卷共享目录遍历并发预算。

[PROTOCOL]: Update this header on change, then check AGENTS.md
