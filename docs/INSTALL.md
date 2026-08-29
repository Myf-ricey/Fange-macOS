# 饭格安装指南

## 系统要求

- macOS 13 Ventura 或更高版本
- Apple Silicon 或 Intel Mac

## 安装

1. 打开项目的 [GitHub Releases](https://github.com/Myf-ricey/Fange-macOS/releases/tag/v0.1.0-beta)。
2. 下载 `Fange-v0.1.0-macOS-universal.zip`。
3. 解压 ZIP，把“饭格.app”拖入“应用程序”。

## 当前 Beta 的首次打开方式

当前版本尚未取得 Apple Developer ID 公证，因此直接双击时 macOS 可能阻止启动。

请在 Finder 中：

1. 右键“饭格.app”；
2. 选择“打开”；
3. 在系统对话框中再次选择“打开”。

这是 macOS 为未公证 App 提供的逐 App 确认方式。不要关闭 Gatekeeper，也不需要执行 `xattr`、`spctl --master-disable` 等降低系统安全性的命令。

## Finder 自动化权限

首次吸附或自动整理时，允许饭格控制 Finder。权限入口通常位于：

```text
系统设置 → 隐私与安全性 → 自动化 → 饭格 → Finder
```

如果曾经拒绝权限，请退出饭格，在这里重新允许后再启动。

## 卸载

1. 从菜单栏退出饭格；
2. 在设置里关闭登录时自动启动；
3. 删除“应用程序”里的饭格；
4. 如需清空设置，再删除 `~/Library/Application Support/DesktopRegions/regions.json`。
