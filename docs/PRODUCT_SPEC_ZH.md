# GH Control 产品与内核设计文档

版本：0.7.0 开发预览  
更新日期：2026-10-12  
目标平台：macOS Hackintosh · Intel Hades Canyon · Radeon RX Vega M GH  
状态：可运行开发版；目标 GPU 下发现 6 个 `AtiAppServices`，程序通过 type `0x81` selector 2 调用 CWDDE `0x6e` 设置 package power limit。固定 GPU 负载对照下，50 W 设置时驱动报告的当前功耗读数中位数约从 67 W 降到 58 W。应用滑杆限定在 50–75 W，负载对照点为 50、60、75 W，中间档位没有逐项压力测试；`0x96` 仍只是驱动缓存，不是硬件上限读回。OD6 百分比 `0x47` 和 VID offset `0x51` 均未开放。

## 1. 产品目标

GH Control 是一个独立 macOS GPU 调节工具，目标是把 Windows Radeon 软件中对本机确实适用的 GPU 功耗和性能状态设置，转成可审查、可回退的 macOS 配置。首要目标是降低不必要的 GPU 功耗与热量，尽可能减轻 Hades Canyon 整机风扇的升速压力。

本产品控制对象是 Radeon RX Vega M GH 的 GPU PowerPlay 状态；机箱风扇仍由 Hades Canyon 主板/EC 控制。GPU 功耗降低可能间接降低热负载，但不代表软件直接控制 NUC 风扇曲线。

### 成功标准

1. 型号以用户确认的 Radeon RX Vega M GH 为准；PCI ID、I/O Registry 属性与驱动 ROM 只作运行时线索，不作为实体硬件身份判断。
2. 明确显示实际加载的驱动、GPU 节点、PowerPlay 表来源与控制能力。
3. 任何可应用设置都能由驱动读回，并由 GPU 遥测或受控负载验证。
4. 已知可启动的主 EFI 必须保持不变；后续实验只允许写入经物理启动验证的独立测试 EFI，且由用户通过一次性启动菜单选择。
5. 第一版不开放未验证参数。未来只允许开放有驱动读回和硬件效果证据的 PowerPlay 字段；重启提示必须明确且由用户决定。

## 2. 目标用户与需求

- 用户在 Hades Canyon Hackintosh 上使用 Radeon RX Vega M GH。
- 用户希望有类似 Radeon 面板的 GPU 功耗/频率调节入口，减少 macOS 下 GPU 热负载和风扇突然提速。
- 用户接受重启应用配置，但不接受让主系统失去启动能力。
- 界面与说明必须区分 GPU 功耗控制、显卡风扇控制、主板风扇控制。

## 3. 产品范围

### MVP 计划功能

- 用户确认目标型号与 AMD9500Controller 运行时驱动栈连接诊断。
- 只读 GPU 遥测：核心/显存频率、温度、功耗；字段必须来自实际驱动或明确标为不可用。
- 导入/读取原始 PowerPlay 数据，保留原始副本与哈希。
- package power limit 通过固定的 CWDDE `0x6e` packet 在运行时设置；首版滑杆限定为 50–75 W，负载对照点是 50、60、75 W，中间档位未逐项压力测试。`0x96` 缓存查询成功本身不足以证明硬件生效，效果依据同一 GPU 负载下的实时功耗对照。注入的 PCI/Registry ID 不参与服务选取。
- 对修改值做边界与表格式校验，显示变更对比。
- 导出 OpenCore `DeviceProperties` 补丁和回滚数据。
- 在独立可恢复启动介质验证前，禁止自动改写正在使用的 EFI。

### 当前开发版已实现

- 通过 IOKit 定位唯一最具体的 AMD graphics accelerator / PowerPlay 节点；不依据 PCI ID、Registry model 或 ROM PCIR 字段推断硬件型号。当前目标 RX Vega M GH 来自用户确认。
- 扫描目标 GPU 节点及有限深度子节点中的 AMD/IOAccelerator 服务和 `PP_*` / `ATY,SCLK` / `ATY,MCLK` 属性；读取匹配的 `kmutil showloaded` 扩展清单。
- 概览与驱动连接页按本机扫描结果展示；JSON 诊断报告自动写入本机缓存，不要求用户手动导出。
- 可导入两份 Windows Adrenalin XML，显示叶字段的新增、删除和变化，支持搜索；字段保持原样，不猜测语义。
- 已从驱动公开的 `ATY,bin_image` 解析出 64 KiB 镜像及其中 701 B 的 ATOM PowerPlay v7.1 表、rev 4 Polaris PowerTune 子表；记录镜像和 PowerPlay 表 SHA-256。镜像内容本身不证明它来自实体卡 ROM。
- 已用 IOKit 每两秒读取 `AMDRadeonX4000_AMDEllesmereGraphicsAccelerator` 的 `PerformanceStatistics`，界面显示驱动报告的功耗、温度、核心/显存频率与 GPU 活动率。
- 已实现 50–75 W 运行时功耗上限滑杆、应用按钮和恢复 75 W 按钮；写入前要求目标 endpoint 和 `0x96` 缓存查询可用，写入后显示驱动缓存与实时功耗。固定 GPU 负载对照中，50 W 设置的驱动报告功耗读数中位数约为 58 W，对照 75 W 时约为 67 W。
- 对驱动公开镜像中声明 TDP 75 W 的表，生成 70 W 候选 plist：只改 TDP、BatteryPowerLimit、SmallPowerLimit、MaximumPowerDeliveryLimit、BoostPowerLimit 中高于目标的字段；其他字节原样保留。另可导出该镜像表用于回退；不称其为已核实的实体卡原厂表。
- plist 使用 WhateverGreen `PP,` 前缀并指向本机配置副本中已有的 GPU 路径；用户仍需对照当前 EFI 后手动合并。
- 只读探测目标 GPU 下的 `AtiDeviceControl` / `AppleGraphicsDeviceControlClient`：记录 IOKit 路径、声明的 user-client 类及 `IOServiceOpen(type 0)` 返回码；不调用任何 AGDC selector。当前本机返回 `kIOReturnNotPermitted (0xe00002e2)`。
- CWDDE `0x6e` setter 已真实调用，并通过负载下功耗变化验证 50 W 档有效；`0x96` 仍只回读软件缓存，不是硬件 cap。OD6 `0x47` 百分比控制和 VID `0x51` 电压偏移尚未验证或开放。PowerPlay 启动配置候选仍需独立验证；内置 EFI 未修改。

### MVP 不包含

- 主板 EC 风扇曲线或 RPM 直接控制。
- 显卡 VBIOS 刷写。
- 直接 PCI/MMIO/SMU 寄存器写入；不使用未验证的寄存器地址。应用只通过 Apple AMD 驱动 CWDDE `0x6e` 设置功耗，不直接访问硬件寄存器；未开放 `0x47` 百分比和 `0x51` VID setter。
- 伪造实时遥测、自动超频、自动加压或跨设备通用参数。
- 实时内核钩子、任意 AMDRadeonX4000 私有调用或新内核驱动。

## 4. Windows Radeon 面板到 macOS 的映射

产品目标按用户在这台机器上的直接经验定义：Windows Radeon 面板能调 GPU 功耗、频率等参数。Intel 对 NUC8i7HVK / RX Vega M GH 的官方说明明确提到 Radeon 控制面板可调整频率（MHz 或百分比）；AMD 通用 WattMan 文档提醒各 GPU 可用功能并不相同。精确字段仍应以这台 Windows 安装上实际出现的面板控件/可导出配置为准，再逐项核对 macOS PowerPlay 表字段和读回。

| Radeon 面板概念 | macOS 方案 | MVP 预期生效方式 |
|---|---|---|
| 功耗上限 | PowerPlay 配置预设 + CWDDE `0x6e` | 50–75 W 运行时设置即时下发；表候选仍需重启后验证 |
| GPU P-state 核心频率 | Hades Canyon WattMan 的频率状态/曲线，对应字段需从本机原始表确认 | 仅开放本机表包含、驱动接受且有读回证据的状态 |
| GPU 电压 | WattMan 上可调曲线；macOS 映射和字段含义待核对 | 默认不开放；需要电压读回、温度/功耗观测及稳定性验证 |
| HBM 频率 | GH 对应的 HBM 状态/频率字段 | 只有本机表明确支持且读回可核验时开放 |
| Power Limit / 功耗目标 | 已实测 CWDDE `0x6e` package power limit | 滑杆限定 50–75 W；负载对照点为 50、60、75 W。显示实时功耗，不将 `0x96` 软件缓存当作硬件限值 |
| Fan curve / Zero RPM | 不归本产品首版直接控制 | Hades 整机风扇由主板/EC 策略控制，GPU 功耗调低仅可能间接减热 |

“安静”配置首版原则是降低 GPU 峰值功耗/性能状态，不提供未经验证的强制最低频率。电压调整和风扇曲线调节要等到精确硬件、表结构和读回链路确认后再评估。

公开的 GH / Hades Canyon WattMan 评测主要展示提高功耗上限和 GPU 频率；这尚未证明降低 Power Limit 会让这台机器的实际 GPU 功耗或整机风扇声下降。首个控制实验必须先确认 Windows ADLX 或面板给出的**可降低范围**，再做最小幅度、可恢复的单项比较；电压暂不列入首轮。

## 5. 技术判断与假设

### 目标 GPU 与黑苹果驱动呈现的区别

本项目的物理目标型号 Radeon RX Vega M GH 由用户确认。macOS 上看到的 `device-id=67DF`、`AMD Radeon RX 570`、I/O Registry 的 `compatible`/subsystem 值，以及驱动公开的 `ATY,bin_image` 都属于启动后的驱动呈现数据；黑苹果可以注入或替换它们。应用不使用这些字段判断实体型号：它们只以“驱动/Registry 呈现线索”展示。目标驱动节点按 accelerator 类名、PowerPlay 表属性和 I/O Registry 拓扑定位。`67DF` 说明当前驱动匹配路径，不说明物理芯片是 RX 570。

WhateverGreen 文档规定 `PP,` 前缀会把属性传入 AMD `aty_properties`，源码在合并时剥掉此前缀。因此本项目生成的 `PP,PP_PhmSoftPowerPlayTable` 是 WEG 属性合并形式，最终键名为 `PP_PhmSoftPowerPlayTable`；社区直接放在其他层级的同名属性写法不能与它混为一谈。WhateverGreen FAQ 还说明移动 AMD GPU 可以由 EFI 注入 `ATY,bin_image` VBIOS，这正是不能把 macOS 当前暴露的镜像当作未经修改实体 ROM 的原因。公开案例与 Apple 15.5 PowerPlay 库中确有 sPPT parser，只证明通用机制和解析代码存在，不证明 Hades / Vega M GH 的当前 `67DF` 匹配路径会采用表或接受任意字段。[WEG Radeon FAQ](https://github.com/acidanthera/WhateverGreen/blob/master/Manual/FAQ.Radeon.en.md) · [WEG 属性合并实现](https://github.com/acidanthera/WhateverGreen/blob/master/WhateverGreen/kern_rad.cpp)

UPP 可解析或修改一些 AMD PowerPlay 表，但对 Polaris/Vega 的结构识别不构成本机驱动支持证明。本机加载清单出现 Polaris22Fixup 1.4.0；该插件源码声明的最高支持版本为 Ventura，而当前系统是 macOS 15.5，故不能仅凭它出现在清单中就认定补丁有效。

因此，首选验证方向是：**保持主 EFI 不动，先取得可核验的实体卡 ROM/PowerPlay 数据，再在独立测试 EFI 上验证属性是否到达 Radeon 驱动并改变可读回的 GPU 状态。** 这是一条启动时配置路径，不等同于 Windows WattMan 即时写入。当前应用解析的是 macOS 驱动公开镜像里的表；镜像来源、驱动是否接受候选值和实际瓦数变化都尚未验证。

### 5.1 本机只读核验记录（2026-10-12）

| 项目 | 本机观察结果 | 结论与边界 |
|---|---|---|
| GPU I/O Registry 节点 | `IOService:/AppleACPIPlatformExpert/PCI0@0/AppleACPIPCI/PEG0@1/IOPP/GFX0@0`；ACPI 路径 `_SB/PCI0/PEG0/PEGP` | 与 Hades Canyon Vega M GH 的 PCI 节点相符 |
| 驱动公开镜像 | 从 GPU 节点 `ATY,bin_image` 读取 PCIR 头：offset `0x244`，vendor `0x1002`、device `0x694C`；声明镜像长度 `65024` B 且 checksum 为 `0` | 镜像字符串还标有 `VEGAM XT`；`ATY,bin_image` 可能来自启动加载或替换的 ROM，不能单独证明实体卡 ROM 身份 |
| Registry 交叉线索 | `compatible` 含 `pci1002,694c`；Registry vendor `0x1002`；subsystem vendor `0x8086`、subsystem `0x2073` | 与用户确认的 Hades Vega M GH 目标相符，但应用不靠它选择目标；这些都是启动后的 I/O Registry 属性，可能受 OpenCore/ACPI 注入，不等于直接读取 PCI config-space |
| 驱动匹配 ID | Registry `device-id=<df670000>`，即 `0x67DF` | 工作区的 OpenCore 配置副本在该设备路径下将此值注入给图形驱动做兼容匹配；活动 EFI 未确认。不能据此认定芯片是 RX 570，也不用于选择 PowerPlay/VBIOS 数据 |
| AMD 图形服务 | `AMD9500Controller`、`AMDRadeonX4000`、`AMDFramebuffer` 与 `IOAccelerator` 已加载/连接 | 硬件加速链确实存在；不能推出有 GPU 参数写入接口 |
| Hackintosh kext | Lilu 1.7.2、WhateverGreen 1.7.1d7、Polaris22Fixup 1.4.0 出现在加载清单 | 仅确认清单状态；Polaris22Fixup 源码声明最高支持 Ventura，本机 15.5 超出范围，不能假设插件补丁运行 |
| PowerPlay 属性 | `PP_PowerPlayEnabled=1`、SCLK/MCLK DPM tuning 属性、`PP_EnablePerDPM=1` 可见 | DPM/PowerPlay 通路的属性存在，不代表软表已注入或写值生效 |
| 已注入软 PowerPlay 表 | 当前 Registry 中未发现 `PP_PhmSoftPowerPlayTable` / `PP_PowerPlayTable` / `PowerPlayTable` | 这是初次只读扫描结果；应用从驱动公开镜像解析到一张表，但不能据此证明 ROM 来源、软表注入或驱动采纳 |
| runtime setter / readback | 目标 GPU 子树有 6 个 `AtiAppServices`；type `0x81` selector 2 可调用 CWDDE `0x6e`。固定 GPU 负载下，75 W 请求的 `0x69` 驱动读数中位数约 67 W，50 W 请求约 58 W。`0x96` 返回软件缓存，非硬件限值回读；30 W 未证明有效，故应用范围限制为 50–75 W | 当前有可用的 package-power 控制和负载效果证据；没有独立 SMU cap readback，电压和 OD6 百分比仍不可用 |
| GPU 遥测 | 后续直接读取 AMD 加速器 `PerformanceStatistics`，可取得功耗、温度、核心/显存频率和活动率 | 应用每 2 秒读取并显示；这是驱动报告值，不是外接功率计 |
| EFI / 启动恢复 | 本机 EFI 分区尝试只读挂载失败；配置副本里能核对 GPU DeviceProperties 路径，但未测试独立启动介质 | 当前启动配置保持未改；候选 plist 只导出，不直接写入 |

macOS 的 I/O Registry 与 `system_profiler` 将设备显示为 `AMD Radeon RX 570`，并报告 `device-id=67DF`；本机 OpenCore 配置副本确有该兼容 ID 注入。这个显示名反映 Apple AMD 驱动匹配后的标签，不代表实体 GPU 是 RX 570。WhateverGreen 文档还明确说明，AMD 移动 GPU 可以由 EFI 注入 `ATY,bin_image` VBIOS，所以即使镜像 PCIR 与 HBM2 字符串都指向 Vega M，也不能把它当作 raw PCI 读回或固件来源认证。checksum 只校验镜像完整性，不校验真实性。

Apple 15.5 AMD PowerPlay 库二进制含 `PP_PhmSoftPowerPlayTable` registry parser 和 Polaris 22 DPM/PowerPlay 符号；当前活动加速器类却是 `AMDEllesmereGraphicsAccelerator`，因为驱动按注入的 `67DF` 兼容路径匹配。二进制中同时存在这些代码，不证明本机 GH 选择 Polaris 22 backend，也不证明解析的表会改变功耗。当前 I/O Registry 没有 sPPT 属性。

本项目已在运行时通过驱动 CWDDE 测试 package power limit；测试中使用了 GPU 压力负载，但未修改 PCI/MMIO、EFI 或触发重启。macOS 当前显示的 ROM 和 Registry 字段可能受启动配置影响，因此不用于确认或反推硬件型号。项目目标 RX Vega M GH 以用户确认的信息为准；本机扫描结果用于描述驱动实际呈现与连接状态。本机 AMD 控制器和 IOAccelerator attach 只证明当前 macOS 图形驱动链路已连接，不能替代 PCI 硬件身份读取。

### 5.2 Windows/Linux/macOS 调节仓库调研（2026-10-12）

功耗上限是本产品的核心控制目标。仓库盘点找到 Linux 上较成熟的通用 AMD 工具：LACT 的支持表把一般 Vega 的时钟、功耗上限、电源状态和风扇控制列为可用；`amdgpu-clocks` 通过 amdgpu sysfs 设置功耗上限和时钟/电压状态。不过两者都没有 GH/`1002:694C` 的功耗降低实测。`amdgpu-clocks` 还特别说明部分 AMD APU 上的 Vega 不开放其所需接口；Hades Canyon 的 Vega M GH 是 Intel 平台上的独立 Polaris 22 GPU，不能仅凭这条说明推断接口有或没有，仍要看目标 Linux 驱动实际暴露的节点。上游 `amdgpu` 明确匹配 `1002:694C`，并有在 Hades Canyon i7-8809G 上验证 Vega M 超频代码路径的内核补丁，但没有证明 GH 上功耗上限写入成功或测得降瓦数。

Windows 侧没有找到有 GH/694C 实机记录的第三方调功耗软件。新找到的 AMD 官方 ADLX SDK 暴露了手动功耗调节能力查询、当前值/范围/默认值读取和设置接口，并有 pre-Navi 图形调节示例；不过 AMD 明确提醒部分旧卡可能不支持，尚未找到 694C 的 ADLX 实测。这提供了一个比逆向 WattMan 更直接的 Windows 只读验证办法：在本机 Windows 下确认 ADLX 枚举到的真实 GPU、`IsSupportedManualPowerTuning` 返回值和功耗范围，再决定是否进行可恢复的写入试验。它不能作为 macOS 调控接口。

补查 AMD 官方 Adrenalin 指南后确认，面板的 Quiet 预设通常意在降低功耗/风扇设置，Power Limit 控件使用百分比；官方也明确控件因 GPU 而异，其示例并非 Vega M GH。Intel 的 Vega M Graphics Hub 将 Hades Canyon NUC 驱动指向 Intel 下载渠道并列出 WattMan 指南。公开资料没有给出这台 NUC 的 ADLX 兼容结果；其他 AMD 卡经 ADLX 读到功耗或转速，也只证明遥测，不能当成 `694C` 有功耗 setter 的证据。详细出处和核查过程见[功耗控制项目调研](POWER_TUNING_RESEARCH_ZH.md)。

`leogcry22/Hades-VegaM` 是 Windows 侧已跑通的 GH 适配先例。用户确认它在 Win10/Win11 上完整适配，AMD Adrenalin 中 GPU 功耗、频率等调节功能可用；它通过修改 AMD 驱动适配目标硬件，不是另写一套控制器。仓库 INF 明确包含物理 `1002:694C` GH 条目，README 也列出 Hades Canyon 和新版 Radeon Software 选项。仓库已在 2022 年归档，因此把这套 Windows 面板能力作为功能基线；macOS 驱动能否消费等价设置仍是待验证的核心问题。详细适配记录见[功耗控制项目调研](POWER_TUNING_RESEARCH_ZH.md)。

补查到的 Windows `Vega64SoftPowerTableEditor` 是桌面 Vega 56/64 的开源 GUI，README 没有 Vega M / Polaris 22 支持；Linux `PowerUPP` 有 PowerPlay 表编辑界面，但 README 只列 Navi 10/6000 系列。两者有可借鉴的 UI、表格编辑和恢复默认值思路，均不是这块 GH 的现成控制方案。ADLX 的 Power Limit API 用百分比表示目标值，不是直接以瓦数为单位，因此只读探针也必须把单位按 API 原样记下来。

ADLX 探针应枚举全部 GPU，而不是取列表第一项；按 `VendorId`、`DeviceId`、子系统 ID、revision 和 `PNPString` 匹配 `1002:694C`，并与 Windows 设备管理器硬件 ID / PCI 位置交叉核对，再查询支持标志和范围。探针只读，不调用 `SetPowerLimit` 或任何频率/电压 setter。

macOS 社区已通过 OpenCore 的 `PP_PhmSoftPowerPlayTable` 属性注入其他 AMD 卡的 Soft PowerPlay Table，设置在启动时交给 AMD 驱动；这不是运行时控制面板。公开指南覆盖 RX 500、Vega 56/64、RX 6600 等，没有找到 1002:694C 的功耗调节验收。HaC-Mini 和较新的 NUC8i7HVK 配置仓库都能作为 Hades Canyon GPU 驱动/设备适配参考，但没有提供 GH 功耗控制实现；后一仓库公开的 `OC/Config.plist` 未含 `PP_PhmSoftPowerPlayTable`。`PPT-table-tool` 只做表格转换，`ZeroRPMBuilder` 只改风扇字段，不满足功耗上限核心需求。

目前没有找到一个成熟仓库能直接给 macOS 上的这块 GH 提供类似 Windows Radeon 面板的功耗滑杆。更像面板的 macOS 先例是 MIT 的 PyVega：可调 Vega 10 系卡的频率、电压、功耗目标和风扇参数，并生成启动注入表，但源码明确只列 Vega 56/64、Frontier、WX 8200/9100，没有 Polaris 22 / Vega M GH；它还会直接改所选 plist，需重启。CMMChris 的 Excel 生成器也是启动表配置工具，目标为其他 GPU 世代。REA 是逆向分析工具链，不是 GPU 控制软件；在逆向 Radeon 面板前，应先用 ADLX 对 Windows 下的 694C 做只读能力探测，确认是否已有官方 API 可用；REA 留给 ADLX 不支持或需要解释额外面板行为时。短期 macOS 路线仍是读取这块 GH 自己的 ROM/PowerPlay 表，借 UPP 等现成工具解析，再评估能否生成最小差异的 OpenCore 启动属性；这条路径尚需证明当前驱动接受该表、设置有效且能恢复。所有既有表和调值都必须按目标 GPU 与 ROM 版本核验，不套用 GL、RX 500、Vega 56/64 或 6600 XT 数据。完整证据矩阵、项目成熟度与证据分级见[功耗控制项目调研](POWER_TUNING_RESEARCH_ZH.md)。

### 真实硬件连接验证清单（最高优先级）

1. 分开记录驱动公开镜像、Registry 线索与 macOS 驱动匹配身份：当前 `ATY,bin_image` 的 PCIR 声明 `1002:694C`，Registry compatible/vendor/subsystem (`8086:2073`) 与之相符；`device-id=67DF` 是驱动匹配值。镜像和 Registry 属性都可能被启动配置影响，所以产品只把它们标成候选线索；最终身份需要 Windows/Linux 原始 PCI config-space 或设备管理器硬件 ID 交叉验证。
2. 找到 GPU PCI 服务的完整 I/O Registry 路径，确认它绑定的控制器/加速器服务。
3. 从已加载内核扩展清单与服务属性确认 `Lilu`、`WhateverGreen`、`Polaris22Fixup`、Apple AMD 控制器的实际版本与 attach 状态。
4. 查明 PowerPlay 表是来自 VBIOS、OpenCore 注入还是 Windows 导出的软表；保存只读副本并计算哈希。
5. 校验表的 magic/header/version/长度/校验方式与目标驱动支持；拒绝未知版本或长度不符的表。
6. 在未写入任何设置时，记录驱动读回的 GPU 频率/温度/功耗可用性，检查多次读取一致性。
7. 只有前六步都通过，才制作与原表差异最小的候选设置；先在副本 EFI 中启动，并分三层核验：属性确实注入、AMD 驱动确实采用候选表、负载下功耗/频率读数确实改变。单独看到 IORegistry 属性不算控制成功。

如果第 2–5 步不能证明 PowerPlay 数据实际到达目标 GPU 驱动节点，应用保持诊断/配置导出模式，不展示直接覆盖 EFI 的“应用”按钮。当前已确认 AMD 加速驱动绑定，但未确认可写的 PowerPlay 数据到达/读回。

Windows 交叉验证先走 AMD ADLX 的只读能力探测：确认 SDK 枚举出的设备 PCI 身份是 `1002:694C`，记录 AMD 驱动与 ADLX 版本，再查询 `IsSupportedManualPowerTuning`、当前功耗限制、允许范围和默认值，并保存每次 API 调用的返回码。只有设备身份和范围都可信、支持标志为真，才单独审查是否进行可恢复的写入试验。AMD 文档警告部分 legacy GPU 不受支持，因此即使同一台机器上的 Radeon 面板能调，也不能预设 ADLX 一定暴露该接口；ADLX 成功也仅证明 Windows 路径，不替代 macOS 侧验证。

## 6. 内核级架构

### 6.1 分层

```text
SwiftUI App (无特权)
  ├─ TargetAndDriverTopology：采用用户确认的型号，读取 IOKit 驱动节点拓扑
  ├─ DriverStatus：读取 kext/service 状态、属性和可用遥测
  ├─ PowerPlayParser：解析 VBIOS / soft PowerPlay 表，严格检查格式
  ├─ ProfileEngine：基于已确认字段创建差异化预设
  ├─ ConfigExporter：生成 OpenCore DeviceProperties 补丁及回滚包
  └─ SafetyGate：检查 PCI ID、表版本、备份与恢复启动状态

OpenCore 启动注入 (仅候选；目前 UI 不执行)
  └─ DeviceProperties -> 目标 GPU PCI 路径 -> PP, aty_properties
       └─ 特定软 PowerPlay 表属性是否能被本机 driver 接受：待验证

macOS AMD GPU 驱动链
  ├─ Apple AMDRadeonX4000 / 匹配的 AMD 控制器
  ├─ Polaris22Fixup（本机清单有 1.4.0；上游声明最高 Ventura，15.5 上是否运行待核实）
  └─ GPU firmware/SMU/PowerPlay 执行硬件允许的动态状态
```

### 6.2 MVP 内核策略

- 不开发新的内核扩展作为首版必要条件。
- 对 CWDDE 使用固定封装，不接受任意 opcode 或用户自定义 packet。当前仅开放经本机实测的 `0x6e` package-power setter，且限制在 50–75 W；其它 setter 均不可达。
- 不从用户态直接写 PCI 配置空间、BAR/MMIO、SMU mailbox 或显卡寄存器。
- OpenCore 启动时属性注入是已知的候选调参路径；UI 不直接写当前 EFI。WhateverGreen 文档明确 `PP,` 是把对应属性传入 AMD `aty_properties` 的通用机制，也记录了 workload policy 配置；这并未证明 PowerPlay 软表适用于本机。
- 当前最小候选项可研究 `PP_WorkLoadPolicyMask=0x04` (POWERSAVING_WORKLOAD)，但它是 workload 优化策略，不等于 WattMan 的 frequency/voltage/power-limit 面板；只有本机读回与风扇/温度效果可对照后才考虑导出。
- 使用现存 GPU 驱动做 PowerPlay 解析/执行；PowerPlay 表是显卡固件策略数据，不是主板风扇 EC 指令。
- 采集与验证接口先只读；设备身份、驱动版本或表格式不匹配时立即 fail closed。

### 6.3 实时功耗接口与运行时验证

Apple 没有向普通 macOS 应用公开 AMD GPU 调节 API；GH Control 使用本机 AMD 驱动私有 CWDDE 通道。AGDC `AtiDeviceControl` 对普通应用仍返回 `kIOReturnNotPermitted (0xe00002e2)`。目标 GFX0 子树有 6 个 `AtiAppServices`；`IOServiceOpen(type 0x81)`、open selector `0`、CWDDE `0x96` 查询和 `0x6e` 写入均已连通。OD6 能力/范围与 VID getter 尚未打通，所以只开放单独验证过的瓦数命令，不开放百分比或电压。

本机 macOS 15 AMD9500 二进制中已静态闭合一条不同于 selector 5 的功耗上限路径：`AtiPowerPlayUserClient` type `0x81` selector 2 → CWDDE command `0x6e` → `PHM_SetPackagePowerLimit` → family `0x82` PPLIB backend callback `+0x16f8` → `PhwPolaris22_SetPowerLimit` → SMU message `0x187`。command `0x6e` 把 packet `+4` 的 dword 左移 8 位；family `0x82` 的通用 PHM setter保留该 Q8 数值。Linux VEGAM/SMU7 上游也将整数功率值左移 8 位后发送 `0x187`。本机固定负载测试进一步证明请求 50 W 时驱动报告的实时功耗明显下降；详见 [实测记录](../experiments/CWDDE-PACKAGE-LIMIT-LIVE-2026-10-12.md)。后端仍要求运行时 capability bit `0x4` 和 ATI revision `≥0x6e`；缓存与调用返回码不是硬件上限读回，因此 UI 只开放测试过的 50–75 W，并持续显示实时功耗遥测。

selector 5 仍是另一条未闭合路径：输入是 PowerTune policy/table index，查 32-bit 表项后进入 Baffin service 和 SW-SMU `+0x1c0` 间接调用，尚未证明它连到 Polaris22 callback；selector 5 的表项单位仍未知。`PhwPolaris22_GetLastSetPowerLimit` 及 CWDDE command `0x96` 只读/返回软件缓存；setter 在发 SMU 消息前就更新该缓存，因此不是当前 enforced cap 的独立硬件读回。`getPowerLevel` 返回 `kIOReturnUnsupported`。CWDDE selector 2 同时含 getter/setter；`0x69`、`0x7e`、`0x92` 尚无证据可读回当前 SMU cap。

当前 live IOKit 树显示 `AMD9500Controller` 是 GFX0 下的节点，而 6 个 `AtiAppServices` 分别位于 `ATY,AMD,RadeonFramebuffer@0…@5/AMDFramebufferVIB` 分支；控制器不是 user-client 的祖先。旧版程序因强制检查祖先而把真实 endpoint 全部过滤掉。修正后按目标 GPU 完整 registry path 关联服务，排序第一项只用于只读查询；六个 endpoint 的 `0x96` 都返回相同值。

- 已实测 `0x96` 请求输入 16 字节、输出容量 8 字节，IOKit 返回成功、实际输出 8 字节；原始响应为 `00 00 00 00 4B 00 00 00`，其中缓存值为 75。此前应用把响应首 dword 错当作长度 8，因此丢弃了这个成功值；现已修正为检查首 dword 为零并读取偏移 `+4`。其他 getter 的空-payload 请求仍报 `0xe00002bc`；`0x6e` 则已通过 24-byte setter packet 调用并经负载对照验证。OD6 `0x47` / VID `0x51` 没有发送。

- 静态反汇编显示 `CFG_UUC` 是 AMD9500 服务创建路径上的开关。当前内置 EFI 配置没有注入该键，但 live GFX0 Registry 报告 `CFG_UUC=01` 且服务已存在；该 Registry 值的来源尚未确定。因此不再把“需修改 EFI 添加 CFG_UUC”作为服务发现前置条件，也不应仅凭该属性认定来源或因果关系。
- `AtiPowerPlayUserClient` 的 selector 2 经 `BaffinPowerPlayManager::cwddePassThrough` 转发到通用 CWDDE handler 表。命令 `0x69` (12/12 bytes) 是当前功耗遥测候选；`0x7e` (0/24) 是 capability-gated ODN 限制/配置查询；`0x92` (0/12) 是依赖配置和 DPM 状态的 peak-limit 查询。它们没有证明读取 SMU 当前生效上限，因此暂不标为 cap readback。selector 2 同时可以发 setter 命令，应用只允许未来以固定 allowlist 和长度封装 getter，不暴露通用 packet 输入。
- Linux VEGAM/SMU7 上游用整数瓦数编码为 Q8 后发送 `0x187`，这强力支持 CWDDE `0x6e` 用户整数的瓦数语义；本机 macOS 允许范围及实际生效仍未测。selector 5 的路径仍未解析，不能借此推断它的单位。AMD9500 根 `aty_config` 没有 `CFG_PTPL2_*`，静态嵌套人格表不能直接认作本卡活动表。capability bit `0x4` 缺失时 setter 会 no-op 并返回 success；bit 存在时 setter 先更新缓存再发消息，getter 因而不是硬件 readback。
- 当前 controller 的 `getPowerLevel` 返回 `kIOReturnUnsupported`，不是可用索引或功耗读回；selector attribute 中没有发现 `getPowerTuneLimit` / `getNearTDPLimit` 的可达 getter 路由。PerformanceStatistics 的 `Total Power(W)` 是当前功耗读数，不是 cap。没有确认的功耗上限 readback，也未在 selector/attribute 路径中找到手动 VDDC scalar setter。
- 2026-10-12 外置 U 盘 EFI 测试失败：F10 选 USB 后黑屏数秒并落入 Windows。失败候选相对正常启动 EFI 只改了 `CFG_UUC=01` 和 `LauncherOption Full→Disabled`；具体导致失败的阶段未确定。U 盘配置已恢复到与内置 EFI 相同的基线哈希 `295db589df29de64c5ae424a53491ada51414a1d4e0bd5e227d966d57480f83b`；内置 EFI 未修改。当前 macOS 已有 6 个服务，进一步调试 CWDDE 不需要再次改 EFI。
- 即使未来服务创建成功，也不能直接把 selector 5 接到 70 W 滑杆；还需要恢复 index→表项→硬件限制的实际语义，并证明真实功耗读回/负载变化。没有这些证据前不发送 setter。
- 若使用内核 patch/hook，需按 macOS build 版本维护签名/二进制特征，处理 SIP/AMFI/Kernel Collection 与 kext 加载约束。
- 每条写入必须有读回验证、原值快照、失败回滚、GPU reset/睡眠唤醒语义与版本门禁。
- 只有有明确接口证据且在同一硬件上实测成功，才把它纳入后续版本；禁止通过猜寄存器偏移实现。

此路径复杂、易受 macOS 更新影响；除非启动时 PowerPlay 注入不能覆盖产品需要的核心用例，否则不建议进入首版。

## 7. 启动与恢复安全（硬性要求）

用户接受未来由其自行决定是否重启，但没有授权应用或助手当前重启。产品必须将“主系统仍可恢复启动”作为启动时注入方案的发布门槛。

### 安全设计

1. 本审核版不读写 EFI/NVRAM/VBIOS，不发起重启；任何重启都由用户明确决定并操作。
2. 产品无法对硬件故障或固件故障承诺“任何情况都绝不启动失败”；可提供的工程保证是：不修改已知可启动的主 EFI，不更改固件默认启动顺序，应用也不主动重启。
3. 第一版控制实验只导出配置差异。之后必须准备整份主 EFI 的离线备份，并留有与主启动盘物理分离的测试 EFI。
4. 用户先用主机固件的一次性启动菜单手动启动测试介质，证明它本身能够启动并可回到原系统；软件不能把软件回滚当成 pre-boot recovery。
5. 仅在恢复介质验证通过后，才在测试 EFI 上逐个试最小改动。每次启动前确认 BIOS 的默认启动项仍指向主 EFI；测试 EFI 出错时，下一次从启动菜单选回主 EFI。
6. plist 生成必须写新文件、以匹配版本的 `ocvalidate` 校验，再执行 plist 语法校验、哈希和人工差异审查；ocvalidate 只能查 OpenCore 配置规范，不能保证 GPU patch 启动成功。
7. 当前已知可启动主 EFI 永不作为“自动回滚”目标写入；如果用户未来明确选择写入主 EFI，必须先重新审视该操作对“不让主系统启动失败”要求是否可接受，不能把它藏在 Apply 按钮中。
8. 应用前后的配置文件和 PowerPlay 表必须可逐字节恢复；驱动/PCI ID/表版本任一变化时 fail closed。回滚软件只能恢复文件，不能解决 pre-boot 卡死，所以恢复启动介质是先决条件。

### 绝不接受的设计

- 把唯一启动 EFI 原地覆盖后立即要求重启。
- 修改/刷写 GPU VBIOS 作为 profile Apply 步骤。
- 无法验证原始 EFI 备份、没有独立恢复启动路径仍继续应用。
- 没有驱动读回而声称 GPU 设置成功。
- 软件界面展示假温度/假功耗/假频率或虚构的控制状态。

## 8. UI/交互

- 主窗口：概览、GPU 调节、配置方案、驱动连接四个分区。
- 概览显示用户确认的目标型号、当前驱动节点拓扑和控制通道状态；注入 ID 只作线索，未实现的遥测明确显示“未采集”。
- 硬件尚未通过核验时，调节项锁定并解释缺失证据。
- 每个参数显示“当前驱动值 / 目标值 / 来源 / 需不需要重启”。
- 应用页提供差异预览、备份目标、测试启动介质状态和恢复操作。
- 任何候选配置需显示“可能启动时加载，需要重启”；只有具体属性通过本机验证后才能说确定。
- 当前开发预览在 GH Control 主窗口；硬件页和配置差分页读取本机运行时输入，OD6 功率百分比写入只在能力位与范围检查通过后开放，profile 应用仍锁定。

## 9. 数据与隐私

- PCI ID、驱动 bundle/version、PowerPlay 表 hash 与当前配置保存在本机。
- 默认不上传遥测、EFI 或 VBIOS。
- 日志中不记录序列号、系统 UUID、用户目录或 EFI 文件内容。
- 导出的 PowerPlay 表和 EFI 备份由用户明确选择目录，显式标记其敏感性。

## 10. 版本路线与验收

### V0.1：只读发现与差分（已实现，待用户验收）

- SwiftUI 界面、IOKit PCI/服务发现、匹配扩展清单、PowerPlay 属性摘要、自动 JSON 诊断缓存、Adrenalin XML 原始字段差分。
- 只读；没有 EFI/GPU 写操作，也没有遥测采样。
- 编译目标 macOS 13 及以上；本版构建成功，尚未在用户审核前做实际 XML 样本适配或视觉验收。

### V0.2：遥测与启动配置候选（已实现代码，待本机界面核验）

- AMD 驱动 PerformanceStatistics 实时遥测。
- 从 AMD 驱动公开的 `ATY,bin_image` 解析 PowerPlay 表，生成 70 W 候选与镜像基准表回退 plist；ROM 来源未核验。
- 验收后续仍需在可回退 EFI 上验证驱动是否采用表、GPU 实测功耗是否受限，以及风扇行为是否变化。

### 本轮实现状态（2026-10-12）

- 已实现驱动公开镜像中 PowerPlay v7.1 / PowerTune rev 4 解析、镜像哈希记录、实时 AMD 驱动遥测和 70 W 候选 plist 导出；未验证实体 ROM 来源、驱动采纳与瓦数效果。
- macOS 驱动二进制中 selector 5 的 index→表项→Baffin service→SW-SMU `+0x1c0` 路径仍未解析到 Polaris22 callback；CWDDE command `0x6e` 则已静态闭合到通用 PHM setter、Polaris22 callback `+0x16f8` 和 SMU 消息 `0x187`。当前运行时已连接 6 个 `AtiAppServices`；`0x96` 读到 75 的 last-set 软件缓存。OD6/VID 只读命令仍报 `kIOReturnError`，参数请求 ABI 需要继续逆向。0x6e 的负载实测见单独实验记录；当前 app 已接入 50–75 W 控件。
- 70 W sPPT 候选没有在当前驱动中实测生效；此路径需要重启。当前 EFI 未修改，未执行重启，启动恢复路径也未验证。

### V0.3：配置生成器（不自动应用）

- 只允许已验证表格式。
- 生成差异、OpenCore 补丁、备份/恢复材料。
- 验收：无写 EFI；原表可字节级恢复；候选表通过 parser 和格式校验。

### V0.4：独立 EFI 启动验证

- 在外部/独立启动介质上测试；原 EFI 不变。
- 先验证默认等价表，再验证最小幅度低功耗设置。
- 验收：可启动、GPU attach、显存/核心遥测有响应、复原启动路径可用；睡眠/唤醒至少完成一次验证。

### V1：安全配置应用

- 只有所有恢复与驱动 readback 门槛通过，才提供 profile apply。
- 明确提示需重启；不承诺瞬时应用。
- 应用失败时保留原启动项并提供可操作恢复说明。

### V2：运行时面板评估

- 研究并验证运行时驱动接口；只有接口稳定、支持版本明确、具备读回/回滚才开放即时调节。

## 11. 关键来源

- AMD WattMan 功能与型号差异：[AMD 官方说明](https://www.amd.com/en/resources/support-articles/faqs/DH-020.html)
- Windows 下 NUC8i7HVK / Vega M GH Radeon 面板频率控件：[Intel 官方支持说明](https://www.intel.com/content/www/us/en/support/articles/000037829/intel-nuc.html)
- Hades Canyon 平台配备 Radeon RX Vega M GH：[Intel 官方规格](https://www.intel.com/content/dam/support/us/en/documents/mini-pcs/nuc-kits/NUC8i7HVK_TechProdSpec.pdf)
- macOS AMD GPU 属性与 PowerPlay workload 属性：[WhateverGreen Radeon FAQ](https://github.com/acidanthera/WhateverGreen/blob/master/Manual/FAQ.Radeon.en.md)
- OpenCore `DeviceProperties.Add` 设备路径与属性值格式：[官方 Configuration reference](https://github.com/acidanthera/OpenCorePkg/blob/master/Docs/Configuration.tex)
- IOKit 打开 user client 的服务要求：[Apple IOServiceOpen](https://developer.apple.com/documentation/iokit/1514515-ioserviceopen)
- WhateverGreen 对 `PP,` 属性的 AMD `aty_properties` 注入实现：[kern_rad.cpp](https://github.com/acidanthera/WhateverGreen/blob/master/WhateverGreen/kern_rad.cpp)
- Polaris 22 macOS 驱动补丁与其声明版本上限：[Polaris22Fixup README](https://github.com/osy/Polaris22Fixup) · [插件配置源码](https://github.com/osy/Polaris22Fixup/blob/master/Polaris22Fixup/kern_start.cpp#L1299-L1324)
- Hades Canyon 区分 694C/694E/694F 并注入图形驱动匹配 ID 的 SSDT：[HaC-Mini SSDT-GpuSpoof](https://github.com/osy/HaC-Mini/blob/master/ACPI/SSDT-GpuSpoof.asl)
- macOS PowerPlay 表生成器参考（目标不是 Vega M GH）：[CMMChris Radeon VII / Vega 20 Generator](https://www.insanelymac.com/forum/topic/340009-tool-radeon-vii-powerplay-table-generator-oc-uv-fan-curve/) · [Vega 64 / Vega 10 Generator](https://www.hackintosh-forum.de/forum/thread/39923-tool-vega-64-powerplaytable-generator/)
- 更像面板的启动配置生成器 PyVega（源码只列 Vega 10 卡型）：[corpnewt/PyVega](https://github.com/corpnewt/PyVega) · [型号表与 plist 写入实现](https://github.com/corpnewt/PyVega/blob/master/PyVega.py)
- PowerPlay 表解析/编辑参考实现：[UPP](https://github.com/sibradzic/upp)
- AMD 官方 Windows 功耗/频率接口与旧 GPU 兼容性：[ADLX SDK](https://github.com/GPUOpen-LibrariesAndSDKs/ADLX) · [Manual Power Tuning API](https://gpuopen.com/manuals/adlx/adlx-sdk-references/adlx-interfaces/gpu-tuning/iadlxmanualpowertuning/) · [C 只读能力查询示例](https://gpuopen.com/manuals/adlx/programming-with-adlx/adlx-samples/c-samples/gpu-tuning/manualpowertuning/) · [兼容性说明](https://gpuopen.com/manuals/adlx/programming-with-adlx/adlx-programming-guide/specifications/compatibility/)
- REA 逆向分析工具（并非 GPU 调控仓库）：[morluto/rea](https://github.com/morluto/rea)
- Windows/Linux AMD 功耗调节项目比较：[开源项目调研](POWER_TUNING_RESEARCH_ZH.md)
- OpenCore 配置校验说明：[ocvalidate](https://github.com/acidanthera/OpenCorePkg/blob/master/Utilities/ocvalidate/README.md)
- NUC EC 监测与整机风扇控制的边界：[HaC-Mini #553](https://github.com/osy/HaC-Mini/issues/553)

当前运行 GPU 节点中的 VBIOS PCIR 头（offset `0x244`）声明 `1002:694C`，65024 B ROM 镜像 checksum 为 `0`，完整 VBIOS 哈希为 `63cc415b...bcaaa`；Registry compatible 同样报告 `pci1002,694c`，Registry subsystem 为 `8086:2073`，而 registry `device-id=67DF`。镜像与 Registry 字段一致，但二者都可能来自注入/替换；这不认证实体硬件身份，也不是 raw PCI config-space 读回。AMD 驱动 attach、PowerPlay v7.1 表解析和实时遥测已通过本机只读检查；raw PCI config space、私有 runtime user-client、瓦数写入/读回和独立恢复启动仍未验证。
