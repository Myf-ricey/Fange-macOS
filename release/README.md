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
