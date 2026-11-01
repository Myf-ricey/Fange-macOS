# Release 文件

下载 ZIP 与 `SHA256SUMS.txt` 由 `Tools/build-release.sh` 本地构建，输出到 `release/v<版本>/`，不提交到 Git 历史。脚本编译 Apple Silicon / Intel 两个架构，以 Keka 创建并测试 ZIP。

```sh
./Tools/build-release.sh
```

默认构建不含官方品牌图片。维护者生成官方发行包时，可把具有使用授权的 `FangeAppIcon.icns` 与 `FangeTitle.png` 放在外部目录，并运行：

```sh
./Tools/build-release.sh /path/to/authorized/brand-resources
```

当前使用 ad-hoc 签名，构建成功不代表已完成 Developer ID 签名或 Apple 公证。

## 发布到应用可检查的状态

应用读取 `Myf-ricey/Fange-macOS` 的 GitHub Releases。每次更新按以下流程完成：

1. 更新源码、测试、版本号和发布说明，测试通过后推送 `main`。
2. 用上述脚本构建通用 ZIP 和 `SHA256SUMS.txt`，确认 Keka 归档测试与本地摘要校验通过。
3. 以 `v<VERSION>` 为标签创建 Release，目标为本次源码提交。可先创建草稿上传两个资产，资产就绪后发布为非草稿，沿用当前 Beta 渠道。
4. 发布后运行：

```sh
./Tools/verify-published-update.sh <上一个公开版本>
```

例如发布 0.2.6 后运行 `./Tools/verify-published-update.sh 0.2.5`。脚本要求更新器实际检出与 `VERSION` 一致的标签，验证 Apple Silicon / Intel 的更新可安装性和旧版升级关系，并从真实更新源下载安装包，校验 SHA-256、归档、应用签名、版本与通用架构。

5. 核对 README 的版本和下载链接与已发布资产一致，再报告更新完成。

如果 GitHub 元数据或下载端点尚未就绪，保留发布任务并重试检查，直到上述验证通过。同版本本机应用显示已是最新版本属于正常结果。
