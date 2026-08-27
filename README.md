# FCP Cleaner

用于扫描并安全清理 Final Cut Pro `.fcpbundle` 资源库中可重建缓存的原生 macOS 应用。

## 功能

- 自动扫描工作目录及本机中的 FCP 资源库
- 只清理已验证的渲染文件、代理媒体和优化媒体
- 分析文件、原始媒体、资源库数据库和未知目录始终受保护
- 所有清理内容均移入废纸篓，可在应用的清理记录中恢复
- 清理前后验证 FCP 占用状态、磁盘在线和可写状态、数据库快照及文件指纹
- 支持多选批量清理、外置缓存、低空间提醒和清理记录导出

## 要求

- macOS 15.0 或更高版本
- Final Cut Pro 资源库，扩展名为 `.fcpbundle`

## 本地开发

```bash
swift test
swift run FCP-Cleaner
```

## 安全说明

FCP Cleaner 不会永久删除文件。清理范围由 `FCPStructureRules` 的精确白名单限定；任何不符合已验证 FCP 目录结构的内容都不会被清理。仍建议在清理前关闭正在使用目标资源库的 Final Cut Pro。

## 许可证

[MIT](LICENSE)
