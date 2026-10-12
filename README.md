# GH Control

**A macOS power-limit utility for the Radeon RX Vega M GH in Intel Hades Canyon.** GH Control sends a tested GPU package-power limit request through the AMD driver and displays the driver's live telemetry. It is a focused power-limit control, not a full Radeon Adrenalin replacement.

## Important performance warning

**Setting the limit too low can reduce performance and make the system lag or stutter.** Start at 75 W, then try 70 W in a repeatable workload. Increase the limit or restore 75 W if you notice lag. The value is a requested high-load power target, not a fixed consumption value or a guaranteed hardware readback.

## Features

- Runtime GPU package-power limit from **50 W to 75 W** in 5 W steps, with Apply and Restore 75 W actions.
- Live AMD-driver readings for GPU power, temperature, core clock, and memory clock.
- Compact main screen; driver, Registry, PowerPlay, voltage and OD6 diagnostics remain available under **GPU Connection**.
- Menu bar icon that opens the main window, follows the macOS light/dark appearance, and can run without a Dock icon.
- No login-item or automatic-start option. Closing the window leaves the app available from the menu bar.
- Bilingual interface and installation instructions.

## Hardware control and limitations

The runtime control uses Apple's private AMD `AtiAppServices` / CWDDE interface: user-client type `0x81`, selector `2`, command `0x6e`. On the target machine, fixed-load comparisons showed the driver's reported GPU power median falling from about 67 W at a 75 W request to about 58 W at a 50 W request. Only the 50 W, 60 W and 75 W points were compared under load; other slider values have not each received a separate stress test.

The driver-record value comes from command `0x96` and is the driver's last-set software cache, **not an independent hardware power-cap readback**. Live power is reported by the AMD driver and may exceed the requested target. The GPU driver continues to manage voltage and frequency automatically. GH Control does not expose voltage offsets, manual frequency curves, fan control, or a guaranteed fan-noise reduction. Whole-system fan behavior remains under firmware control.

This app depends on a private, macOS-version-specific AMD driver interface and is intended for the RX Vega M GH setup for which it was validated. It does not modify EFI, NVRAM, VBIOS, or driver files and does not require a restart. PowerPlay boot-time candidates and Windows Adrenalin profile comparisons are retained in the technical connection area; they are separate from the runtime slider.

## Install

1. Download and double-click `GHControl-0.7.0.dmg`.
2. Drag `GHControl.app` onto the **Applications** shortcut in the opened window.
3. Open GH Control. If macOS blocks the first launch because the app is not signed/notarized, Control-click it in Applications, choose **Open**, and confirm.

This build is not signed with an Apple Developer ID and is not notarized. The DMG includes the same first-launch instructions.

## Build and run from source

Requires macOS 13 or later and Swift toolchain provided by Xcode Command Line Tools.

```sh
./script/build_and_run.sh
```

Build the `.app` without launching it:

```sh
./script/build_and_run.sh --build-only
```

Build the app and create the drag-to-Applications disk image in `dist/`:

```sh
./script/build_and_run.sh --package
```

## 中文说明

GH Control 是面向 Intel Hades Canyon 冥王峡谷中 **Radeon RX Vega M GH** 的 macOS 功耗上限工具。它通过 AMD 驱动已验证的接口设置 GPU package power limit，并显示驱动实时遥测。它专注于功耗上限，不是完整复刻 Windows Radeon Adrenalin 面板。

### 重要：功耗设置过低会导致卡顿

**功耗上限过低可能降低性能，使系统卡顿或掉帧。** 建议先用 75 W，再在相同负载下尝试 70 W；若出现卡顿，请提高数值或恢复 75 W。滑杆设置的是高负载功耗目标，不是固定耗电值，也不是保证准确的硬件上限读回。

### 功能

- 运行时 GPU 功耗上限：**50–75 W**，每档 5 W，支持应用设置和恢复 75 W。
- 显示 AMD 驱动报告的 GPU 实时功耗、温度、核心频率和显存频率。
- 首页聚焦滑杆与实时状态；驱动、Registry、PowerPlay、电压和 OD6 诊断放在“显卡连接”栏目。
- 菜单栏单色图标点击后打开主窗口；界面跟随 macOS 浅色/深色外观，可关闭 Dock 图标。
- 不提供登录项或开机自启动。关闭窗口后，应用继续留在菜单栏运行。
- 界面和安装说明提供中英文。

### 硬件控制与限制

运行时控制通过 Apple 私有 AMD `AtiAppServices` / CWDDE 接口下发：user-client type `0x81`、selector `2`、命令 `0x6e`。在目标机器的固定负载对照中，75 W 请求对应的驱动实时功耗中位数约为 67 W，50 W 请求约为 58 W。负载对照点为 50 W、60 W 和 75 W；滑杆其他档位尚未逐一做独立压力测试。

“驱动记录”来自命令 `0x96`，是驱动最后一次设置值的软件缓存，**不是独立的硬件功耗上限回读**。实时功耗由 AMD 驱动报告，可能高于请求值。电压和频率仍由 GPU 驱动自动管理。GH Control 不提供电压偏移、手动频率曲线、风扇控制，也不保证风扇一定降速；整机风扇仍由固件管理。

应用依赖 macOS 版本相关的 AMD 私有驱动接口，面向经过验证的 RX Vega M GH 配置。本应用不会修改 EFI、NVRAM、显卡 VBIOS 或驱动文件，也不要求重启。“显卡连接”中的 PowerPlay 启动配置候选和 Windows Adrenalin 配置对比属于独立的技术功能，不等于首页的运行时滑杆。

### 安装

1. 下载并双击打开 `GHControl-0.7.0.dmg`。
2. 将 `GHControl.app` 拖入窗口中的 **Applications（应用程序）** 快捷方式。
3. 打开 GH Control。如果 macOS 因应用未签名/公证而拦截首次启动，请在“应用程序”中按住 Control 键并点击应用，选择“打开”，再确认。

此版本没有 Apple Developer ID 签名，也没有经过公证。DMG 内含相同的首次启动说明。

### 从源代码构建

需要 macOS 13 或更新版本，以及由 Xcode Command Line Tools 提供的 Swift 工具链。

```sh
./script/build_and_run.sh
```

只构建 `.app`，不启动：

```sh
./script/build_and_run.sh --build-only
```

构建应用并生成可拖入“应用程序”的 DMG：

```sh
./script/build_and_run.sh --package
```

## Project documents

- [Product and kernel design (Chinese)](docs/PRODUCT_SPEC_ZH.md)
- [Power-tuning repository research (Chinese)](docs/POWER_TUNING_RESEARCH_ZH.md)
- [Runtime package-power validation notes (Chinese)](experiments/CWDDE-PACKAGE-LIMIT-LIVE-2026-10-12.md)
