<p align="center">
  <a href="README.md">English</a> · <a href="README.zh-CN.md">简体中文</a>
</p>

# macOS 系统状态小组件（SystemWidget）

一款运行在 macOS 桌面上的实时系统监控小组件：CPU、内存、存储、电池，每秒刷新，一目了然。

![macOS](https://img.shields.io/badge/macOS-15%2B-333333?logo=apple&logoColor=white)
![Swift](https://img.shields.io/badge/Swift-6-orange?logo=swift&logoColor=white)
![License](https://img.shields.io/badge/License-MIT-yellow.svg)

## 下载

可以在 [Releases](https://github.com/zoryabc/macos-system-status-widget/releases) 页面下载打包好的版本，无需本地构建：下载 zip、解压后直接打开 `SystemWidget.app` 即可。

> 为什么不用系统自带的 WidgetKit？
>
> WidgetKit 小组件无法高频刷新（通常十几分钟才更新一次），不适合实时监控。
> 本项目改用无边框浮动窗口实现，才能做到每秒刷新真实数据。

## 功能特性

- 实时显示 CPU、内存、存储、电池状态，每秒刷新
- CPU 最近 45 秒使用曲线（Activity Monitor 风格）
- 负载均值（1/5/15 分钟）与系统运行时间
- 电池剩余时间估算与充放电功率显示（放电/充电状态自动识别）
- 实时网络速率（上下行）、网络名称与本机 IP
- 「深色 / 浅色」两套外观预设，菜单栏一键切换，选择自动记忆
- 「开机自启」开关，登录时自动启动
- 点击穿透，不挡桌面操作；位置自动记忆
- 纯本地应用，无任何网络请求，数据全部来自本机

## 环境要求

- macOS 15.0 或更高版本
- Apple Silicon（M 系列）或 Intel Mac
- 构建需要 Xcode 或 Command Line Tools（`xcode-select --install`）

## 快速开始

```bash
git clone https://github.com/zoryabc/macos-system-status-widget.git
cd macos-system-status-widget
./build.sh
open build/SystemWidget.app
```

也可以直接安装到个人 Applications 文件夹并启用开机自启：

```bash
./install.sh
```

## 使用说明

1. 启动后，小组件默认出现在桌面右上角。
2. 点击菜单栏的仪表盘图标：
   - **移动位置（编辑模式）**：卡片浮动并显示提示，按住拖动调整位置，再点一次恢复锁定。
   - **始终置顶**：让卡片浮在所有窗口之上。
   - **外观预设**：切换深色 / 浅色主题，选择自动记忆。
   - **开机自启**：勾选后登录时自动启动，取消即移除注册。
   - **退出**：退出小组件。
3. 锁定状态下点击穿透卡片，不影响桌面操作；位置会自动记住。

## 从源码构建

```bash
./build.sh
```

构建产物：

- `build/SystemWidget.app` — 小组件本体
- `build/statscli` — 命令行工具，打印一次系统状态用于验证：

```bash
./build/statscli
# CPU:      12%  (10 cores, Apple M4)
# Memory:   72% used  (11.6 / 16.0 GB)
# Disk:     90% used  (205.1 / 228.3 GB)
# Battery:  54% (battery)
```

> 说明：应用使用 ad-hoc 签名（`codesign -`），仅用于本机个人使用，不面向 App Store 分发。

## 项目结构

```text
.
├── Sources/
│   ├── AppEntry.swift   # 界面、桌面窗口、菜单栏控制
│   ├── Stats.swift      # CPU / 内存 / 存储 / 电池数据采集
│   └── main.swift       # 命令行验证工具入口
├── Info.plist
├── build.sh             # 构建脚本
├── install.sh           # 安装到 ~/Applications 并注册开机自启
└── .github/workflows/   # GitHub Actions 构建
```

## 数据来源

| 指标 | 来源 |
| ---- | ---- |
| CPU | Mach `host_processor_info`（总占用 + 每核心） |
| 内存 | `host_statistics64`（active + wired + compressed） |
| 存储 | 根卷文件系统属性 |
| 电池 | IOKit 电源管理（含剩余时间、充放电功率） |
| 网络 | `getifaddrs` 流量计数器（速率）+ SystemConfiguration 主接口 + CoreWLAN SSID |
| 负载 / 运行时间 | `getloadavg` / `kern.boottime` |

## 常见问题

- **卡片不显示**：在菜单栏把「始终置顶」开关一次，强制置前。
- **重新构建后如何更新**：运行 `./install.sh` 会自动替换并重启。
- **如何关闭开机自启**：菜单栏取消「开机自启」，或删除
  `~/Library/LaunchAgents/local.systemwidget.plist`。
- **想调整透明度或外观**：外观在菜单栏「外观预设」中切换；
  具体数值可直接修改 `Sources/AppEntry.swift` 后重新构建。

## 许可证

[MIT](LICENSE)
