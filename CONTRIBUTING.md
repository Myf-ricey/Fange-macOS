# 参与贡献

欢迎通过 Issue 和 Pull Request 改进饭格。

## 开始之前

- Bug 报告请说明 macOS 版本、Mac 架构、复现步骤和预期结果；
- 不要上传真实桌面文件、账户信息、完整用户目录或其他敏感数据；
- 不要提交没有明确再分发权的代码、图片、字体或其他第三方内容。

## 本地验证

提交前请运行：

```sh
./test-drag.sh
./test-single-instance.sh
./test-folders.sh
./test-selection.sh
./test-desktop-drop.sh
./test-updates.sh  # 需要 Keka
./build.sh
```

需要验证 Finder 的实际落点时，运行 `FANGE_LIVE_DROP_TEST=1 ./test-desktop-drop.sh`。该检查使用临时桌面替身，并在结束后清理。

## 贡献许可

向本仓库提交贡献，即表示你确认有权提交这些内容，并同意按照 Apache License 2.0 将贡献授权给项目及其用户。品牌和视觉资产仍受 [BRAND_ASSETS.md](BRAND_ASSETS.md) 约束。
