# 饭格维护与发布

## 更新完成条件

用户要求更新本项目或上传更新到 GitHub 时，默认完成以下整条流程；用户明确指定只提交源码时按其指定范围执行。

1. 更新源码、回归测试、`VERSION`、`Resources/Info.plist` 和更新说明，并验证版本号与构建号。
2. 将改动推送到 `Myf-ricey/Fange-macOS` 的 `main`。
3. 运行 `Tools/build-release.sh`，用 Keka 生成并测试 Apple Silicon / Intel 通用 ZIP，同时生成 `SHA256SUMS.txt`。
4. 创建与源码提交对应的 `v<VERSION>` GitHub Release，上传 ZIP 和校验文件，并将 Release 发布为非草稿。沿用现有 Beta 渠道；草稿只用于上传资产的准备阶段。
5. 运行 `./Tools/verify-published-update.sh <上一个公开版本>`，验证真实 GitHub 更新源、预期新版本、两个架构的可安装性、旧版到新版的版本比较，以及实际下载后的摘要、归档、签名、应用版本和通用架构。

上述验证通过后，才将更新报告为完成。推送 `main` 本身不触发应用内更新；应用读取 GitHub Releases。

同版本的本机应用应显示已是最新版本。使用验证脚本检查旧版升级路径，保留用户正在运行的应用和桌面配置。

## 打包与公开文件

压缩包使用本机 Keka；需要官方图标时向构建脚本传入有授权的品牌资源目录。版本号、Release 标签、ZIP 内 App 版本须一致，上传资产须满足应用更新器的命名和 SHA-256 规则。流程见 `release/README.md`。

提交源码、测试、说明和发布配置。个人桌面配置、录屏、本地调试备份及临时文件保留在本机。
