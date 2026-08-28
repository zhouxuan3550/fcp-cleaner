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
- Final Cut Pro 12.3 或更高版本（使用 Workflow Extension 时）
- [Apple Workflow Extension SDK](https://developer.apple.com/download/all/?q=WorkflowExtensions)（开发构建时需要）

## 本地开发

```bash
swift test
xcodegen generate --spec project.yml
xcodebuild -project FCPLibraryCleaner.xcodeproj -scheme FCP-Cleaner build
```

Xcode 构建会同时生成主程序、快捷指令元数据和 Final Cut Pro Workflow Extension。安装后可从 Final Cut Pro 的扩展入口识别当前资源库，并在 FCP Cleaner 中打开；实际清理仍由主程序执行完整预检。

生成 universal2 安装包：

```bash
./release.sh <版本号> <构建号>
```

## 安全说明

FCP Cleaner 不会永久删除文件。清理范围由 `FCPStructureRules` 的精确白名单限定；任何不符合已验证 FCP 目录结构的内容都不会被清理。仍建议在清理前关闭正在使用目标资源库的 Final Cut Pro。

## 许可证

本项目为**源码可见（Source Available）**，不是 OSI 定义的开源软件。除 GitHub
公开仓库服务条款及适用法律不可排除的权利外，未经版权所有者事先明确书面授权，
不得编译、运行、使用、复制、修改、分发、商用或创建衍生作品。

申请授权请通过本仓库联系版权所有者。完整条款见
[FCP Cleaner Source Code License 1.0](LICENSE)。

该协议自 `4.0.0` 起适用；此前已按 MIT 发布的版本仍遵循各自随附的原协议，
已经授予的旧版本许可不会被本协议追溯撤销。
