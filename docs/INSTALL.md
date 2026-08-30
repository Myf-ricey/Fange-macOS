# 饭格安装指南

## 系统要求

- macOS 13 Ventura 或更高版本
- Apple Silicon 或 Intel Mac

## 安装

1. 打开项目的 [GitHub Releases](https://github.com/Myf-ricey/Fange-macOS/releases/tag/v0.1.0-beta.2)。
2. 下载 `Fange-v0.1.0-beta.2-macOS-universal.zip`。
3. 解压 ZIP，把“饭格.app”拖入“应用程序”。

## 当前 Beta 的首次打开方式

当前版本尚未取得 Apple Developer ID 公证，因此直接双击时 macOS 可能阻止启动。

请按以下步骤操作：

1. 双击“饭格.app”尝试启动一次，让 macOS 显示安全提醒；
2. 打开“系统设置 → 隐私与安全性”；
3. 向下滚动到“安全性”，找到关于饭格被阻止的提示，点按“仍要打开”；
4. 在再次出现的对话框中确认“打开”，并按系统要求输入登录密码。

“仍要打开”通常只会在尝试启动后的一小时内显示。确认后，饭格会被保存为此 Mac 的安全性例外项目，之后可以正常双击启动。这是 macOS 提供的逐 App 确认方式；不要关闭 Gatekeeper，也不需要执行 `xattr`、`spctl --master-disable` 等降低系统安全性的命令。

## Finder 自动化权限

首次使用吸附功能时，允许饭格控制 Finder。权限入口通常位于：

```text
系统设置 → 隐私与安全性 → 自动化 → 饭格 → Finder
```

如果曾经拒绝权限，请退出饭格，在这里重新允许后再启动。

## 卸载

1. 从菜单栏退出饭格；
2. 在设置里关闭登录时自动启动；
3. 删除“应用程序”里的饭格；
4. 如需清空设置，再删除 `~/Library/Application Support/DesktopRegions/regions.json`。
