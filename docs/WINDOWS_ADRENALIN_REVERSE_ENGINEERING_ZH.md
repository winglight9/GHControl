# Windows Adrenalin / WattMan 调压调用链逆向记录

调查日期：2026-10-12  
目标设备：本机 Windows 安装中的 Radeon RX Vega M GH，PCI `1002:694C`，Subsystem `8086:2073`。  
边界：只读取已挂载的 Windows 分区和 AMD SDK；没有启动 Windows、改动驱动/注册表、调用调参 API 或写入硬件。

## 结论

**本机 Windows 驱动包含时钟/VDDC 状态写入路径，也包含单独的功耗上限写入路径。** 这不是只看见 ADL 导出名：下文把本机 DLL 中的 setter、驱动私有请求、以及 AMD KMD 分发表中的接收 handler 对上了。静态分析证明驱动实现了这些写入入口；本次没有运行 Windows 或实际写硬件，因此不声称本机这一刻实际成功改值。

**这条 API 不能直接移植成 macOS 控制功能。** 本机 Windows 使用 AMD 的 `atiadlxx.dll` 和配套 Windows 内核驱动；ADL 官方也说明它主要包装 AMD 私有 API。macOS 需要单独找到 Apple AMD 驱动中接受相同调节语义的受支持入口。目前 macOS 侧还没有证实可写的 VDDC setter。

## 本机 Windows 样本身份

Windows 卷当前挂载在 `/Volumes/Untitled`，因此可以在 macOS 中只读检查它的文件。驱动包位于：

`/Volumes/Untitled/Windows/System32/DriverStore/FileRepository/u0393589.inf_amd64_a8d3c2a28863af26`

- INF 将 `PCI\VEN_1002&DEV_694C&SUBSYS_20738086&REV_C0` 映射到 `ati2mtag_VegaM`，对应本机目标 `1002:694C / 8086:2073`。
- INF 的驱动版本为 `31.0.21001.46001`（2023-06-28）。这是这份本机安装包的版本，不代表 AMD 当前最新版本。
- 配套文件夹 `B393381` 含 `amdkmdag.sys` 与 `atiadlxx.dll`。Radeon Software 包版本为 `10.23.10022.0`，应用是 x64 Qt 6 / WebEngine。
- 本次分析的 `amdkmdag.sys` SHA-256：`dc15b6d5d1498793fc5a2590266b81cef1ceb5e3906a498a1cf6b51a6986b952`（99,609,512 字节）。

这些身份信息来自实际 DriverStore INF 和文件，而不是仅凭界面显示名称或注入的 macOS `model` / `device-id` 推测。

## 已证实的 Windows 调参模型

安装的 `atiadlxx.dll` 导出以下 ADL 接口：

- `ADL2_OverdriveN_SystemClocksX2_Get/Set`
- `ADL2_OverdriveN_MemoryClocksX2_Get/Set`
- `ADL2_OverdriveN_PowerLimit_Get/Set`
- `ADL2_OverdriveN_SettingsExt_Get/Set`

AMD 官方 ADL SDK 的 `ADLODNPerformanceLevelsX2` 为每个性能状态定义了 `iClock`、`iVddc`、`iEnabled`、`iControl` 字段；`ADLODNPowerLimitSetting` 则单独定义 `iMode`、`iTDPLimit`、`iMaxOperatingTemperature`。因此时钟状态/VDDC 和功耗上限是两类不同的控制量。SDK 头文件把 `iVddc` 标为 VDDC，但此处没有把字段单位擅自推断成 mV。

REA/Ghidra 已成功定点反编译本机 `atiadlxx.dll` 中的 `ADL2_OverdriveN_SystemClocksX2_Set`（函数地址 `0x1800d0460`，函数体 `0x1800d0460–0x1800d0969`；DLL SHA-256 `aab58dba6595933e68e40da87117cb06912c11137c829523b0e7244afeaa5ea2`；REA evidence ID `ev_62eeae479f6de4005fbfeee626e18c4835e3a4642390ba580ba57fe450006e09`）。伪代码显示它检查 Overdrive 能力和驱动报告的性能档数量，按每档 16 字节复制调用者给出的状态数组，再进入内部 `SendX2` / `ADL2_Send` 路径。兼容旧驱动的分支还会查询 `Software\\AMD\\CN` 下的 `ShowAllDPMLevels_NA` 值；观察到的是读取，不是写注册表。反汇编可见 `0xC00077`、`0xC00079` 等内部请求标识，但它们不是公开 ADL 合约，不能当作稳定的第三方驱动协议。

Radeon Software 可执行文件中还存在 `wattman_ui_component`、`GetGpuVoltageModel`、`GetPowerLimitModel`、`autoUVTargetVoltage` 和对应 ADL 符号文本。这证明应用包包含 WattMan/电压/功耗相关实现线索；**尚未通过运行时跟踪证明某个具体滑杆事件最终调用了哪一个导出函数**。REA/Ghidra 对整个 34 MB Qt 主程序的字符串搜索超过了工具的单次 330 秒限制；相比之下，较小的 ADL DLL 和目标 setter 已成功完成函数级反编译。因而 DLL 的 setter 调用链已有静态证据，Adrenalin UI 事件到 setter 的精确映射仍待运行时观察。

## 从 ADL setter 到 AMD 内核驱动

对本机 `atiadlxx.dll` 和配套 `amdkmdag.sys` 做静态反汇编后，接口链可还原为：

```text
Adrenalin UI（具体控件到 API 的动态映射尚未跟踪）
  → ADL OverdriveN Set 导出
  → ADL2_Send / ADL2_SendX2
  → 通过 gdi32 动态解析的 D3DKMTEscape，携带 AMD 私有数据
  → Windows 图形内核转交 AMD KMD 的 escape 分发器
  → 按私有命令号查表、校验缓冲区长度、调用 AMD PowerPlay handler
```

ADL 的通信 helper 从 `gdi32.dll` 动态解析 `D3DKMTEscape`，然后把私有请求缓冲区送入该调用。微软文档定义 `D3DKMTEscape` 为 UMD/client 与 KMD 之间交换数据的接口；`D3DKMT_ESCAPE_DRIVERPRIVATE` 的 payload 由硬件厂商定义，并且仅在用户态与内核态驱动紧密配套时可用。这与 AMD DLL、KMD 必须同版本配套的静态观察相符。[D3DKMTEscape 文档](https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/d3dkmthk/nf-d3dkmthk-d3dkmtescape)；[D3DKMT_ESCAPE 文档](https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/d3dkmthk/ns-d3dkmthk-_d3dkmt_escape)

在这份 `amdkmdag.sys` 中，私有分发器按请求低 16 位查找 descriptor，并要求请求长度匹配表项后才调用 handler。针对相关命令查到的表项如下：

| ADL API | 私有命令 | 本机 KMD 表项 | KMD handler / 结果 |
|---|---|---|---|
| `ADL2_OverdriveN_SystemClocksX2_Set` | `0xC00077`（准备/查询） | `0x77`：8 字节输入、28 字节输出 | `0x14161EFBC` |
| `ADL2_OverdriveN_SystemClocksX2_Set` | `0xC00079`（性能状态写入） | `0x79`：28 字节输入、无输出 | `0x14161FB30`；handler 会校验 PowerPlay/ODN 状态并处理该性能状态请求。具体各字段如何换算到底层硬件寄存器尚未完全解出。 |
| `ADL2_OverdriveN_PowerLimit_Set` | `0xC0007F` | `0x7F`：24 字节输入、无输出 | `0x141620DD8`，随后调用 `0x141625B20`；失败分支引用明确的 `PHM_ODN_SetPowerLimit FAILED.` 错误字符串。 |

功耗上限这一条有额外的内核侧证据：`0x141620DD8` 从请求字段构造内部数据，经过参数与当前 PowerPlay 状态检查后调用 `0x141625B20`；该 helper 再进入下游 PowerPlay helper `0x141644C9C`。调用失败时，父 handler 走 `PHM_ODN_SetPowerLimit FAILED.` 日志分支。结合 ADL 的 `ADLODNPowerLimitSetting` 结构和 `0xC0007F` 的 24 字节输入长度，可以确认这不是普通查询，而是实际的功耗上限设置处理路径。字段单位和硬件最终如何执行，不能仅凭这段静态代码推断。

时钟/VDDC setter 在 ADL 侧按每个性能档复制 `iClock`、`iVddc`、`iEnabled`、`iControl`，随后发出 `0xC00079`；KMD 对应表项要求 28 字节输入。KMD 包含 `ODN_SetSystemClockLevels` 及逐档 clock/VDDC 的诊断字符串，和这条请求的语义吻合。这里能确认有 per-level 调节入口，但无法据此断言任意电压值都会被 GH 固件接受，也没有从反汇编完整恢复所有字段单位、边界或电压偏移算法。

以上私有命令和缓冲区大小只适用于本机这份 AMD Windows 驱动构建。它们依赖配套的 Windows KMD、WDDM adapter/context 句柄及 escape 结构；不能直接从 macOS 用户态发送，也不能把 `0xC00079` / `0xC0007F` 当成 macOS 的接口。

### 这轮逆向能回答什么

- **Windows 驱动端确实实现了调参写入通道**：包括逐性能档时钟/VDDC 和独立功耗上限。驱动私有请求已对到 KMD 的分发表和具体 handler，不是根据面板截图推测。
- **本次没有验证一次真实写入是否成功**：没有运行 Windows、调用 ADL setter 或观察 GPU 遥测前后变化。handler 中存在校验和失败分支，具体值仍可能因能力标志、固件、当前驱动状态而被拒绝。
- **Adrenalin 哪个滑杆调用哪个 setter 尚未动态跟踪**：静态证据证明 DLL API 和内核写路径存在，但没有在 Windows 里逐项操作 UI 并采集函数参数。
- **macOS 能否控制仍是另一项问题**：Windows 的私有 D3DKMT escape 协议无法移植到 macOS。它确认硬件/PowerPlay 有可调语义，但不证明 Apple AMD 驱动公开或保留了同等写入口。

### 证据强度

| 判断 | 证据 | 置信度 |
|---|---|---|
| Windows 驱动包匹配本机 `1002:694C / 8086:2073` | 本机 DriverStore INF 精确匹配 | 高 |
| 配套 ADL DLL 有时钟/VDDC 状态与 Power Limit 的 Get/Set API | DLL 导出表 + AMD 公开 SDK 结构 | 高 |
| ADL 私有请求进入本机 AMD KMD | `D3DKMTEscape` 通信 helper、KMD 私有分发表、请求长度检查及目标 handler 均有静态证据 | 高 |
| Power Limit 请求进入 ODN 设置处理路径 | `0xC0007F` → KMD `0x7F` 表项/handler → `PHM_ODN_SetPowerLimit FAILED.` 失败日志路径；静态证据，不代表本次实际调用成功 | 高 |
| 调压请求进入 per-level ODN 处理路径 | `0xC00079` → KMD `0x79` 表项/handler，ADL 结构逐档含 `iVddc`，KMD 含对应 ODN/clock/VDDC 诊断字符串 | 高 |
| Adrenalin 某个指定 UI 操作调用了哪个 setter、实参是什么 | 主程序字符串与 DLL API 提供线索；尚无动态跟踪/单控件差分 | 未完成 |
| macOS 能否经相同 API 调压 | ADL 是 Windows 驱动栈；macOS 需独立 Apple 驱动路径 | 不能据此声称支持 |

## 对 macOS 实现的影响

1. 将 Windows 的控制模型映射为三个独立概念：**功耗上限、GPU 时钟状态、每状态 VDDC**。不把一个滑杆值混作瓦数或电压。
2. 不调用 Windows `atiadlxx.dll`，也不复制未知的 `0xC000xx` 请求格式。它们只属于对应 AMD Windows 驱动版本的内部实现。
3. 本机 macOS 逆向已找到 AMD PowerPlay/UserClient 相关对象，但尚未找到一个经目标驱动验证的 VDDC 写入入口。`PowerPlay` 属性可读不等于属性可以安全写入；发现兼容 PCI ID 也不等于控制通道已连通。
4. 若运行时写入口最终不存在，最接近的 macOS 路径是研究**本机 GH 自己的 PowerPlay 表**及启动时 `PP_PowerPlayTable` 注入。这需要重启，属于启动配置方案，不是 Adrenalin 式实时控制。只有先验证该卡实际读取的表、补丁差异和可恢复启动 EFI，才应进入写入验证。

## 还需要 Windows 会话吗？

**继续做静态逆向不需要切换到 Windows。** 本机挂载的 Windows 卷已有 Radeon Software、适配 INF、ADL DLL 和 AMD 内核驱动文件，足以确认 Windows 端 API/数据模型。

若之后要把“某个 UI 滑杆”精确映射到“导出函数与实际参数”，再需要 Windows 中做一次运行时采集：记录默认调优状态，并且每次只改一个项目后记录状态差分，或跟踪对应 ADL API 调用。那个结果仍只说明 Windows 的确切行为，不能代替 macOS 写入入口验证。

## 来源

- [AMD 官方 ADL SDK 仓库及文档](https://github.com/GPUOpen-LibrariesAndSDKs/display-library)
- [AMD 官方 ADL 结构定义](https://github.com/GPUOpen-LibrariesAndSDKs/display-library/blob/master/include/adl_structures.h)
- [AMD 官方 ADL 文档：ADL 与驱动 API](https://github.com/GPUOpen-LibrariesAndSDKs/display-library/blob/master/Public-Documents/README.md)
- [REA 项目](https://github.com/morluto/rea)：本次在本机使用 Ghidra provider 对 Radeon Software / ADL DLL 做静态分析；大主程序的完整分析受到单次超时限制。
- [Hades-VegaM 驱动适配仓库](https://github.com/leogcry22/Hades-VegaM)：Windows Vega M 驱动/Adrenalin 适配背景。
