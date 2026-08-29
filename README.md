# 饭格 Fange

<p align="center">
  <img src="assets/fange-icon.png" width="168" alt="饭格 App 图标">
</p>

<p align="center"><strong>桌面清爽，做事顺手。</strong></p>

<p align="center">原生 macOS 桌面分区整理工具 · 全功能免费 · 闭源发布</p>

饭格在 Finder 桌面图标下方创建可自由定制的整理分区。文件仍然由 Finder 管理，照常双击、拖动和打开；饭格只负责让图标归位，让桌面更清楚、更顺手。

> 当前版本：`0.1.0 Beta`。全部功能免费，无广告、无账号、无订阅。

<p align="center">
  <img src="assets/poster.png" width="640" alt="饭格核心功能海报">
</p>

## 下载

前往 [GitHub Releases](https://github.com/Myf-ricey/Fange-macOS/releases/tag/v0.1.0-beta) 下载，或使用[直接下载链接](https://github.com/Myf-ricey/Fange-macOS/releases/download/v0.1.0-beta/Fange-v0.1.0-macOS-universal.zip)：

```text
Fange-v0.1.0-macOS-universal.zip
```

支持 Apple Silicon 与 Intel Mac，系统要求 macOS 13 Ventura 或更高版本。

## 核心特色

### 界面简洁

分区位于 Finder 图标下方，不替换图标、不创建隐藏文件夹，也不改变熟悉的桌面操作方式。

### 风格自由

支持 mac 原生、叠层玻璃、胶片、金属、陶瓷、织物、纸张、全息、液态铬、光刻电路等多种材质，还可以调整颜色、渐变、透明度、边框、标题和间距。

三个代表性搭配：

- **AI**：光刻电路 + 石墨渐层，冷色科技感。
- **实用工具**：叠层玻璃 + 墨黑标签，简洁沉稳。
- **学业**：云龙纤维纸 + 纸签标签，温和清晰。

### 操作便捷

- 把桌面图标拖入分区，松手后自动吸附到最近空位。
- 图标与分区保持绑定，移动或缩放分区后仍会整齐归位。
- 分区大小、位置、数量、行列和图标间距都可自由调整。
- 支持一键按文件类型整理桌面图标。
- 常驻菜单栏，可选择登录时自动启动。

### 全功能免费

当前公开版本不区分基础版和高级版，没有功能付费墙。

## 安装方法

1. 从 Releases 下载 ZIP 并解压。
2. 把“饭格.app”拖入“应用程序”。
3. 当前 Beta 尚未完成 Apple Developer ID 公证。首次启动请在 Finder 中右键“饭格.app”，选择“打开”，再确认一次“打开”。不要关闭 Gatekeeper，也不需要运行解除安全限制的命令。
4. 首次整理图标时，macOS 会询问是否允许饭格控制 Finder，请选择允许。

更详细的安装和权限说明见 [安装指南](docs/INSTALL.md)。

## 快速使用

1. 启动饭格，点击菜单栏饭碗图标打开设置。
2. 在普通模式下，把 Finder 桌面图标拖入分区即可吸附。
3. 开启“编辑模式”，可拖动分区或从右下角调整大小。
4. 使用 `+` 新建分区，通过“更多”调整材质、标题、行列和间距。
5. 如需批量整理，可从菜单选择“自动按类型整理桌面…”。

完整说明见 [使用指南](docs/USER_GUIDE.md)。

## 隐私

饭格不联网，不收集分析数据，不上传文件。它只在本机读取 Finder 桌面图标的位置和路径，并把分区设置保存在本地。详见 [隐私说明](PRIVACY.md)。

## 源代码与许可

饭格目前采用闭源发布。GitHub 仓库用于提供官方下载、版本说明和问题反馈，不包含源代码。用户可以免费下载安装官方二进制，但不能修改、重新打包、转售或冒充官方版本。详见 [专有软件许可](LICENSE.md)。

## 反馈

- 使用疑问：查看 [常见问题](docs/FAQ.md)
- Bug 或功能建议：提交 GitHub Issue
- 安全问题：查看 [安全说明](SECURITY.md)
