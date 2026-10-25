# 饭格隐私说明

生效日期：2026-10-25

## 本机处理的信息

饭格在本机读取 Finder 桌面项目的路径、选中状态和图标坐标，并保存分区外观、位置、绑定、展示方式和排序设置。映射文件夹由用户主动选择；饭格保存其本地访问书签，读取文件名、图标、类型、大小和时间等信息，以展示和排序。

把文件拖入映射分区会将文件实际移动到所选文件夹。可收起分区会临时隐藏对应 Finder 原图标，改由饭格显示；正常退出时恢复原有可见性，异常退出后会根据本地记录在下次启动时恢复。饭格不因显示分区而新建专用存储目录，不自动上传用户文件。

## 网络请求

每次启动会检查一次本项目 GitHub Releases，菜单栏也可手动检查。只有用户选择更新后才下载安装包。请求访问 GitHub API、项目 Release 和 GitHub 下载服务；GitHub 会接收常规 HTTP 请求信息（例如 IP 地址和请求头）。饭格不会在这些请求中附带桌面或映射文件夹的文件、文件名、路径、书签或分区配置。

饭格不创建账号，不包含广告、分析或追踪 SDK，不出售个人数据。

## 系统权限

“自动化 → Finder”用于读取和调整桌面图标位置。桌面、下载、文稿等目录权限用于访问用户选择的文件夹和执行拖入移动。未授权时可在系统设置中允许，或重新选择映射目录。更新安装要求当前 App 所在目录可写；安装失败会保留或恢复旧版。

## 本地数据位置

- 分区配置：`~/Library/Application Support/DesktopRegions/regions.json`
- 临时隐藏记录：`~/Library/Application Support/DesktopRegions/temporary-hidden-items.json`
- 更新下载与安装记录：`~/Library/Caches/DesktopRegions/Updates/`
- 旧版本备份：`~/Library/Application Support/DesktopRegions/UpdateBackups/`
- 更新版本标记等偏好：macOS 为 `com.ricey.desktop-regions` 保存的本地偏好。

重置配置前先从菜单栏正常退出，让原图标恢复显示。随后可删除 `regions.json`；不要在饭格运行时删除临时隐藏记录。
