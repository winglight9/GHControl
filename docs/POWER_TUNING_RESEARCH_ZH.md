# RX Vega M GH 功耗调节项目调研

调研日期：2026-10-12  
物理目标型号：Intel Hades Canyon / Radeon RX Vega M GH（用户确认）。当前 macOS 暴露的 PCI ID、Registry 属性和驱动 ROM 都可能由 OpenCore/ACPI 注入或替换；应用不使用这些字段判断实体硬件型号。
核心问题：是否存在已经在这块 GH 上跑通、能实际改变 GPU 功耗上限或频率/电压的成熟项目；以及 macOS 是否已有可复用的控制路径。

## 结论摘要

目前找到的证据支持以下判断：

1. **Windows：Hades-VegaM 已由用户确认在 Win10/Win11 上完整适配这套 Hades Canyon / Radeon RX Vega M GH，Adrenalin 中 GPU 功耗、频率等调节可用。** 它不是单独开发的 GPU 控制程序，而是让 AMD 官方驱动/Adrenalin 在 Vega M 上工作的适配方案。若目标是再造 Windows 版面板，优先研究这套已跑通的驱动+Adrenalin；若目标是 macOS，Windows 成功证明这块实体 GH 的控制能力存在，不能直接提供 macOS 控制通道。ADLX 是否可用于该驱动组合仍需按真实驱动/runtime 检查，但它不再是证明 Windows 功耗控制能否工作的前置条件。
2. **Linux：有成熟通用控制软件，且上游 `amdgpu` 对 Vega M 有专用支持。** Linux 内核有一条在 Hades Canyon i7-8809G 上验证过的 Vega M 超频路径；LACT 的硬件表把一般 Vega 的功耗上限和时钟控制列为支持。`amdgpu-clocks` 可通过驱动 sysfs 写入功耗上限和时钟/电压状态，但其 README 也指出部分 AMD APU 上的 Vega 不开放所需接口。PowerUPP 也有图形界面，但其 README 写明面向 Navi 10/6000 系，未覆盖 Polaris 22。Hades Canyon 的 GH 是 Intel 平台上的独立 Polaris 22 GPU，不能仅凭名字推断驱动接口是否开放；仍需实际读取目标驱动节点。没有找到公开报告证明 LACT 或 `amdgpu-clocks` 已在 **GH** 上成功下调功耗上限并测得功耗变化。
3. **macOS 上已经有人用 OpenCore 注入 SoftPowerPlayTable 调整其他 AMD 卡，但没找到 Vega M GH 的实测。** 这是启动时注入，重启后才可能由 AMD 驱动读取；不是即时面板。现有脚本/教程多针对 RX 500、Vega 56/64、RX 6600 等卡，不能直接套用它们的表或数值。新近的 `lemonade-sdk/mac-amdgpu` 也不适用：其 README 目标是 Apple Silicon + Thunderbolt 外置 Radeon AI PRO R9700（`1002:7551`）和 Tahoe 26.2+，并要求 DriverKit entitlement/SIP 配置；不是 Intel Hades Canyon 的 Vega M GH 驱动或控制面板。[仓库硬件要求](https://github.com/lemonade-sdk/mac-amdgpu#hardware-requirements)
4. **CWDDE 有一条静态上闭合到 Polaris 22 SMU 消息的功耗上限写入路径，且本机负载对照已验证控制效果。** `AtiPowerPlayUserClient` type `0x81` 的 selector 2 转发到 CWDDE；command `0x6e` 的 handler 将 dword 左移 8 位后调用 `PHM_SetPackagePowerLimit`，路径通向 SMU message `0x187`。Linux VEGAM/SMU7 setter 对整数瓦数执行同样的 Q8 编码。macOS 后端要求 runtime capability bit `0x4`；若缺失会 no-op。固定 GPU 负载对照下，75 W 请求时 `0x69` 报告功耗读数中位数约 67 W，50 W 请求时约 58 W，支持 50 W 设置实际降低了负载功耗。`0x96` 仍只读 last-set 软件缓存，不是 SMU 当前上限读回；完整采样见 [实测记录](experiments/CWDDE-PACKAGE-LIMIT-LIVE-2026-10-12.md)。
5. **另有一条静态 VID offset setter，不等于绝对电压控制。** CWDDE command `0x51` 要求 16-byte payload；handler 将 payload `+4` 解释为 `IncreaseVoltage` 布尔值、`+8` 解释为 32-bit raw `Value`，并校验其位于运行时 context 提供的 min/max 之间。Polaris22 callback 会把换算值送到 SMU message `0x195`；Linux 上游头文件将 `0x195` 命名为 `PPSMC_MSG_SetVidOffset_1`。静态代码没有证明 `Value` 的单位是 mV，也没有证明本机的运行时 gate、min/max、step 或固件响应。现已把命令 `0x4f`（驱动报告的 min/max/step/default 原始字段）和 `0x50`（方向与 raw value 缓存）接入 GH Control 只读诊断；`0x50` 不是 SMU 硬件读回，setter 在调用 SMU 前先写缓存，所以缓存变化不能证明命令生效。应用不发送 `0x51`，也不把 raw 值标成 mV。
6. **应用范围按实测设置收紧。** `0x6e` handler 本身不校验 min/max；因此不从驱动 ROM 中的 75 W 表项猜可用范围。当前 app 只允许 50–75 W，因为 50 W 有本机负载验证、75 W 是原始缓存基线；30 W 设置没有观察到可靠下降，不开放。`0x7e` / `0x92` 不是 SMU 当前 package cap 读回。OD6 百分比 `0x47` 与 VID offset `0x51` 仍未开放。
7. **selector 5 是另一条尚未闭合的路径，不能与 CWDDE setter 混为一谈。** 它将输入解释为 PowerTune policy/table index，查 32-bit 表项后进入 Baffin service 和 SW-SMU interface 的 `+0x1c0` 间接调用；这个槽仍未解析到 Polaris 22 callback，所以 selector 5 的表项单位仍未知。`AtiAppleMcilServices` 的同偏移槽接收另一种 ABI，不能视作同一函数。VEGAM 专用 SMU7 路径能帮助解释 CWDDE `0x6e` 到 `0x187` 的 Q8 单位，但不能替 selector 5 的 index→表项→硬件限制链路赋单位，也不能代替本机 runtime 结果。[Linux Polaris10 PowerTune 实现](https://codebrowser.dev/linux/linux/drivers/gpu/drm/amd/pm/powerplay/hwmgr/polaris10_powertune.c.html) · [Polaris SMU 消息定义](https://codebrowser.dev/linux/linux/drivers/gpu/drm/amd/pm/powerplay/inc/smu7_ppsmc.h.html)
8. **当前接口状态。** 运行中的系统已有 6 个目标 GPU 子树 `AtiAppServices`，`IOServiceOpen(type 0x81)` 和 open selector 0 成功；应用调用 0x6e 并完成 50 W 负载验证。运行时 ATI revision/capability bit 尚未直接读取，验证依据是功耗遥测对照。AGDC `AtiDeviceControl` 仍因 `kIOReturnNotPermitted (0xe00002e2)` 不可访问；它与已可用的 CWDDE 通道是不同服务。当前控制无需修改 EFI 或重启。

## macOS AMD9500 私有接口静态逆向（2026-10-12）

- **PowerPlay/sPPT 的 ASIC 分发条件已从 macOS 15.5 内核集合反汇编复核；此前文档把 family 下限误读为 `0x7e`，现已更正。** `BaffinSharedController::getFamilyId` 的实现返回 `0x82`。`PECI_SetupInitInfo` 会分别请求 ASIC family、ASIC ID、ATI revision 和 actual/emulated revision；Baffin manager 的 callback 结构将这些值交给 PPLIB。`_PHM_Initialize` 对 family 做 `family - 0x82` 分发表索引；对应 family `0x82` 的分支在 ATI revision `≥ 0x6e` 时选择 `PhwPolaris22_Initialize`。这是静态代码分支证据，不等于已证明运行时实际 revision 达标或 initializer 成功。`AMD9500Controller::getATIRevisionId` 读取 `AtiAsicInfo::getAtiRevisionNum`；诊断中的 Registry `revision-id=00C2` 是另一个公开属性，不能未经验证就当作该 ATI revision。当前仍未确认活动 accelerator 使用的 manager/interface 实例、ATI revision 的运行时返回值、PowerPlay 初始化结果以及实际 sPPT 解析情况。

- `AMDFramebuffer::enableController` 从其 `ATIController`（本机为 AMD9500Controller）读取 `CFG_UUC` 单字节开关；读取对象对应物理 GPU 的 IOPCIDevice property，也会从 `aty_config` 字典复制属性到该 PCI provider。缺失时默认关闭；开关为真时才创建/启动 `AtiAppServices`，type `0x80`/`0x81` 分别对应 `AtiUserClient` / `AtiPowerPlayUserClient`。
- **IOConnect 请求 ABI 与应用接线（2026-10-12 更新）。** `AtiPowerPlayUserClient::methodTemplate` selector 0/1 是零参数 scalar open/close，selector 2 是可变长结构输入/输出。CWDDE 前 16 字节是外层头，命令码位于 `+4`，payload 从 `+16` 开始；零输出 setter 仍传 output-size 指针和 nil output buffer。getter ABI 与受限 setter `0x47` 的逆向记录保持如下；`0x6e` 输入24/输出0，瓦数字段位于偏移 `+20`，已在本机调用并通过负载读数验证。`0x51` 为输入32/输出0，仍未调用。实现位于 `Sources/GHControl/Services/AMDPackagePowerControlService.swift`，端点按目标 IOKit 拓扑关联，不使用注入 PCI ID 选卡。
- **0x47 范围门控（静态复核）。** `0x6d` 与 `0x54` 的百分比范围来自同一个 platform descriptor；要求二者范围/步进一致是合理的 runtime 门槛，但它们不一定等于 Polaris22 context 的 `+0xd80` validator 值。`_PHM_Validate_PowerLevelRequest` 与 common setter 都用该 context 值再次校验幅度，因此不应把驱动公开 ROM 表的 raw `+31` 字段冒充为 validator 上限。当前仍需成功读取真实 OD6 能力与范围；后端也可能因内部运行时 capability 不启用而 no-op。
- **当前实际状态（更新）。** 当前正常启动 macOS 已有 6 个目标 GFX0 子树下的 `AtiAppServices`；每个节点的 `IOServiceOpen(type: 0x81)`、open selector `0` 和只读命令 `0x96` 都返回成功。六个 `0x96` 响应一致，缓存值为 75；这是 last-set 软件缓存，不是当前 SMU 功耗限制或硬件功耗读回。`0x46/0x6d/0x54/0x4f/0x50` 在现有空-payload 请求下都返回 `0xe00002bc`，因此 OD6 百分比和 VID 仍锁定。0x6e 已有实际 setter 与负载对照证据，详见实验记录。
- **端点发现纠正。** 实际 IOService 树中 `AMD9500Controller` 与 framebuffer 是 GFX0 下的兄弟分支；6 个 `AtiAppServices` 分别位于 `ATY,AMD,RadeonFramebuffer@0…@5/AMDFramebufferVIB` 子树。旧代码错误要求 controller 是 ancestor，导致真实 endpoint 全被过滤。修正后按用户确认的目标 GFX0 完整 registry path 关联，排序第一项只用于只读查询。此前对 `AMDFramebuffer` 类调用 type `0x81` 得到 unsupported 的探针并没有测试这些 `AtiAppServices` 节点。
- **AGDC 路径实测。** 目标 GPU 子树中发现 `AtiDeviceControl`，IORegistry 声明的 user-client 类为 `AppleGraphicsDeviceControlClient`。只调用 `IOServiceOpen(service, mach_task_self(), type=0, ...)`，得到 `0xe00002e2` / `kIOReturnNotPermitted`；未调用外部方法、未发送 attribute selector。内核的 `authorizeTask` 静态代码包含 `com.apple.private.applegraphicsdevicecontrol` 与 `com.apple.private.gpuwrangler` entitlement 检查。因而 AGDC 里的 PowerPlay setter 虽然存在于内核代码，普通 GH Control 无法直接访问；目前不能把这条静态路径当成应用可用接口。
- **本机 entitlement 可行性探测。** `IORegistry` 显示现存 AGDC clients 的创建者为 WindowServer；WindowServer 的 Apple 签名包含 `com.apple.private.gpuwrangler`。在临时只调用 `IOServiceOpen` 的探针中嵌入这两个私有 entitlement 并 ad-hoc 签名，AMFI 在进程启动前以 `Restricted entitlements not validated` / `Code signature is invalid` 拒绝执行。故本机不能靠给普通 app 自签 entitlement 获得这条接口；本探针没有打开连接、没有调用 selector、没有写 GPU。
- **公共 IOPM API 排查。** 当前 macOS SDK 的 `IOPM.h` 把 `Graphics_Power_Limits` / `Graphics_Power_Performance` 定义为系统电源状态/限制数据键；`IOPMLib.h` 对应公开接口 `IOPMCopyCPUPowerStatus` 是只读状态复制函数。公开头文件没有配套的 GPU cap、频率或电压 setter，因此这些键不构成第三方应用可用的 Radeon 调节 API。[Apple XNU IOPM.h](https://github.com/apple/darwin-xnu/blob/main/iokit/IOKit/pwr_mgt/IOPM.h)
- **字段来源区分（纠正先前混淆）。** `AtiAsicInfo::getAtiRevisionNum()` 只返回对象字段 `+0x48`；`getPciRevisionId()` 返回另一个字段 `+0x50`。`AtiAsicInfo::refresh()` 明确从 PCI config offset `0x08` 读 1 字节并写入 `+0x50`。所以 Registry 的 `revision-id=00C2` 对应 PCI revision 属性，不能代替 `getAtiRevisionNum()` 的 PPLIB ASIC revision。本机 Registry 另显示 `ATY,intrev=80`，但目前没有代码证据证明它映射到 `AtiAsicInfo+0x48`；这两个值也不能互相替代。PPLIB revision 的运行时值仍未读取。
- **CWDDE 功耗命令（新增反汇编闭环）。** command `0x6e` 对应 `PEM_CWDDEPM_SetPackagePowerLimit`，输入/输出长度分别为 8/0；handler 读取 packet `+4` 的 dword 并 `<<8`，调用 `PHM_SetPackagePowerLimit`。PPLIB 初始化把 `InitInfo` 第一个 dword（family）复制到 context `+8`；通用 setter 对 family `<0x8d` 保留原始参数。`PhwPolaris22_FunctionPointerInitialize` 将 `PhwPolaris22_SetPowerLimit` 写入 package-power-limit callback `+0x16f8`，并将 `PhwPolaris22_GetLastSetPowerLimit` 写入 `+0x18c0`。前者在 bit `0x4` 缺失时直接返回 PP success、不发 SMU 消息也不更新缓存；bit 存在时先写缓存再发 `0x187`。若消息失败，缓存仍会保留请求值。command `0x96` 调用 getter 后把缓存 `>>8` 返回，因此不是 SMU 当前 enforced cap 的硬件读回；实际测试至少需同时检查 CWDDE status 与缓存变化。
- **OD6 VID offset 命令（本轮新增，只静态逆向）。** command `0x51` 的外层输入 16 B、payload 16 B、输出 0 B。handler 从 payload `+4` 取方向布尔值、`+8` 取 raw `Value`；payload `+0/+12` 不被该 handler 使用。setter gate 读取 context flags `flags[0]&0x02` 和 `flags[10]&0x40`；来源/运行时语义尚未确认。`PHM_SetVidOffset` 用 context 中的 min/max 字段做闭区间检查，不做 clamp；随后先缓存 raw value 与方向，再调用 Polaris22 callback slot `+0x14b0`。该 callback 对应 SMU message `0x195`，但消息在 GH 固件上的实际效果未经验证。SMU 参数静态换算式约为 `0x100 ± floor((Value>>1) * 0x14f8b589 / 2^40)`；这不足以认定 `Value` 的单位。命令 `0x4f` 返回含 min/max/default/step 的 24 B 驱动数据，`0x50` 返回缓存的 direction/value；均未在本机 runtime 读到。Linux 上游把 message `0x195` 命名为 `PPSMC_MSG_SetVidOffset_1`，这是命令号交叉佐证，不代表 macOS API 公开或本机固件已验证。
- **功耗 setter 选择。** 瓦数命令 `0x6e` 虽可静态追到 SMU `0x187`，但 handler 不做范围校验，故没有接入 UI。百分比命令 `0x47` 经 `PHM_Validate_PowerLevelRequest` 按驱动 context 限制校验，再到 Polaris22 callback/SMU `0x188`；OD6 `0x54` 能力位与 `0x6d` 范围为软件门槛。`0x47` callback 仍可能在内部能力位不满足时无操作地返回成功；需用当前功耗遥测验证。`0x7e` 和 `0x92` 仍不是硬件当前 package cap 读回。
- **GH Control OD6 功率控制（未开放）。** `0x54`/`0x6d` 当前请求 ABI 未验证，返回 `kIOReturnError`，因此 UI 不提供 OD6 `0x47` 百分比写入；这不影响独立的瓦数 `0x6e` 控制。VID `0x51` 仍未开放。
- **配置读取顺序。** 本机 `ATIController::getConfigProperty()` 先从绑定的 Registry provider 查同名 property；查找失败时，才从 `aty_config` plist 路径按 key 取值。各 persona 的 `CFG_PTPL2_TBL` 不同，因此当前没有证据表明某 persona 的 TBL 就是活动卡所用表。
- **新增 PPLIB getter 候选。** `SW_SMUM_SetPowerLimit` 以 operation `1` 调 RTS 接口表 `+0x1c0`；配对的 `SW_SMUM_GetPowerLimit` 以 operation `2` 调同一个槽，并在成功返回时复制输出值。`Phw_SwSmu_SetPowerLimit` / `Phw_SwSmu_GetPowerLimit` 分别转发到它们。它形成静态 set/get 候选闭环；尚未证明 getter 读的是 SMU 当前执行上限、参数单位、动态接口 provider 是否落到 Polaris22 backend，或 user-client 是否能调用 getter。当前没有执行这两个接口。
- `AtiUserClient` selector 4 是 1 个 scalar 输入、1 个 scalar 输出的 `getAttribute`。本机反汇编将属性 `0x20646773` 映射到 `getPowerLevel`。这不是已确认的瓦数，也不是 power-limit 上限读回。
- selector 5 是 `setAttribute(attr, value)`；属性 `0x20636773` 和 `0x20646773` 都映射到 `AMDFramebuffer::setPowerLimit(uint32)`。value 被当成 PowerTune policy/table index，截为 32 位，经 min/max 检查后索引 `this+0x50` 的 32 位表项，再交给 `BaffinPowerPlayManager`。
- `BaffinPowerPlayManager::setPowerLimit` 从 `+0x98` 接口对象调用 vtable `+0xa0`。已由 HWServices factory、HWLibs factory、`AtiPowerPlayServices` 构造与 vtable address point 静态闭环：该对象的 `+0xa0` 是 `AtiPowerPlayServices::ppAdjustPowerTune(uint32)`。family `0x82` 选择的 service setter 经 helper 把输入原样写入 PowerPlay callback packet 第二个 dword，再由 selector `1` 调用 `obj+8` 指向的 SW-SMU 接口表 `+0x1c0` 槽。当前静态映像不能解析该 slot 的具体 provider，因此链路在间接 callback 处停止。
- `AtiAppleMcilServices::fillServiceCallbacks` 也生成一个大小 `0x358` 的函数表，其 `+0x1c0` 槽指向通用回调描述符分发器（要求输入结构大小字段为 `0x48`，再从结构中取回调函数与上下文）；它与 SW-SMU `PowerControl` 调用约定（`selector`、参数包、输出指针）不兼容。这个 MCIL 表的 `+0x2d0` 槽指向 `gpuPowerControl`，该函数体只有 `xor eax,eax; ret`。这些发现排除了“因为偏移都是 `+0x1c0` 就是同一个 callback”的推断，但没有定位 SW-SMU 对象实际持有的 provider 表。
- `AMDRadeonX4000HWLibs` 中存在 Polaris22 专用 `_PhwPolaris22_SetPowerLimit`，且 `_PhwPolaris22_FunctionPointerInitialize` 将其写入 package-power-limit callback 槽 `+0x16f8`；`_PhwPolaris22_Initialize` 调用该初始化函数。通用 `_PHM_SetPackagePowerLimit` 取该槽并调用。Polaris22 setter 在 context 能力位 `+0x1850` 的 bit `0x4` 置位时，把输入写入 `+0x1840` 的软件缓存，并以消息 `0x187` 将同一输入发送到 SMU；返回值取决于消息 helper 的结果。此静态后端代码存在，但仅凭符号/初始化函数不能证明当前运行时 PP_Instance 确实走过这个 initializer。
- family `0x82` 的 user-client setter 走 `AtiAppleNavi10PowerTuneServices::setPowerTuneLimit` → `_Phw_SwSmu_SetPowerLimit` → `_SW_SMUM_SetPowerLimit` → `_SW_SMUM_PowerControl`。最后一步从 SW-SMU 对象取接口指针，并调用接口表偏移 `+0x1c0` 的函数。`AtiAppleMcilServices` 的同偏移函数表槽接收不同 ABI 的描述结构，不能用来认定 SW-SMU 间接目标；MCIL `gpuPowerControl` 位于 `+0x2d0` 且是返回 0 的短桩，也没有证据证明其被这条路径调用。SW-SMU 目标仍未映射到 Polaris22 callback，也未证明它与另一条 `_PHM_SetPackagePowerLimit` → callback `+0x16f8` 路径汇合。因此 user-client 中的 PowerTune 表项与 Polaris22 的 `0x187` 参数之间没有已证实的换算关系；不能把表项解释为瓦数、SMU 参数或生效上限。
- `setupPowerTuneParameters` 通过 ATIController 的配置属性读取 `CFG_PTPL2_MIN/MAX/TBL`；未观察到这里直接解析 VBIOS 来生成索引表。缺少自定义 TBL 时会根据 min/max 生成递减表。AMD9500Controller 的 `aty_config` 顶层没有这些键，但其 `ATY,Florin`、`ATY,Forrahue`、`ATY,Palena`、`ATY,Sinu`、`ATY,Tolten` 等嵌套人格各自带有不同 `CFG_PTPL2_TBL`。活动人格无法从当前活动控制器的静态属性可靠判定，不能用某一张表推断目标卡的 index→功率映射。
- `populatePowerTuneTable` 的默认索引表算法已从 macOS 15.5 二进制静态反汇编复核：`count` 来自配置的 `CFG_MINPPL/CFG_MAXPPL` 范围，`table[0] = max`；`i > 0` 时 `table[i] = min + trunc((max - min) * (count - 1 - i) / (count - 1))`。非空自定义 `CFG_PTPL2_TBL` 项则按表值使用。这个公式只证明软件表项如何生成，当前 active min/max/count/TBL 均未知；SW-SMU 的 PowerTuneLimit 读取原始 `uint32` 且 getter 未做单位换算，但底层回调和物理单位未知。故不能把 index 或任何表项标为 W，也不能用 VBIOS 的 75 W 去替它赋单位。
- selector 4 属性 `0x20646773` 映射到 `getPowerLevel`；对应 AMD9500Controller 实现对有效输出返回 `kIOReturnUnsupported`，因此这不是可用的当前运行级别读回，更不是 TDP/W 上限。内核中虽有 `getPowerTuneLimit` / `getNearTDPLimit` 等符号，但未找到 user-client 的可达 getter 路由。
- `BaffinPowerPlayManager` 在调用底层接口前就更新软件缓存字段，因此即使后续观察到名为 `hw` 的缓存，也不能把它当作显卡硬件 readback。当前 selector/attribute 路径没有确认的 package-cap getter 或绝对 VDDC scalar setter。另已静态发现相对 VID offset 命令 `0x51`，但它的运行时 flags、range、单位及 GH 固件效果尚未验证；`ppDceClockVoltageRequest` 内部符号本身仍不足以证明公开可用的电压控制入口。
- `getAttribute(0x20646773)` 明确路由到 `getPowerLevel`；`0x20636773` 没有对应的专用 getter。当前 controller 的 `getPowerLevel` 实现对有效输出返回 `kIOReturnUnsupported`。`getPowerTuneLimit` / `getNearTDPLimit` 等内部符号存在，但没有找到它们从已审计 user-client selector 或 `getAttribute` switch 到达的路由；因此不能将其视为可用 cap readback。PerformanceStatistics 的 `Total Power(W)` 是驱动报告的当前功耗读数，不是上限。
- type `0x81` 仅有 3 个 selector：0 open、1 close、2 `cwddePassThrough`。selector 2 将数据交给通用 CWDDE 命令表，该表混有 getter 和 setter，不能作为任意只读通道。静态确认的 getter 候选及长度：`0x69 GetCurrentPower` (12-byte input / 12-byte output，读当前功耗遥测)；`0x7e ODN_GetPowerLimit` (0 / 24 bytes，受 capability gate 控制，偏向 ODN 限制/配置)；`0x92 GetPeakPowerLimit` (0 / 12 bytes，返回值依赖配置和 DPM 状态)。0x7e/0x92 均未证明读取 SMU 当前生效上限；没有调用任何 CWDDE selector。
- 只读探测在打开 `AMDFramebuffer` user client 时收到 `kIOReturnUnsupported`（`0xe00002c7`），连接未创建，因此 selector 4 并未调用。该节点报告 `UserClientEnabled=No`。没有做任何 AMD GPU 参数写入，也没有改权限、尝试其他服务或触发重启。
- 本机自动诊断枚举到 6 个 `AMDFramebuffer` 节点且全部 `UserClientEnabled=false`；`AtiAppServices` 实例数为 0。当前 OpenCore 配置副本和 AMD9500 顶层 `aty_config` 中均未找到 `CFG_UUC`。对 HaC-Mini、WhateverGreen 和 Polaris22Fixup 的公开源码检索也未找到该私有开关或 user-client 用法；静态硬件 callback 的存在不代表本机当前能调用。
- `CFG_UUC` 必须在控制器初始化时已可读才会创建服务；单纯重启不会令当前缺失的开关自动出现。属性到 PCI provider 的传递链已确认，OpenCore `DeviceProperties` 可按设备路径增加属性，布尔 true 会成为单字节 `01`；但当前活动 EFI 的实际路径未确认，且没有独立恢复启动介质。若以后经安全审查配置并重启，目的也只是先验证 user-client 是否创建，不代表 setter 到达 Polaris22 后端或功耗功能已生效。当前没有改配置或重启。

## ADLX 与 Windows 驱动的补充核查（2026-10-12）

- AMD 官方 ADLX 手册定义了逐 GPU 查询 `IsSupportedManualPowerTuning`、读取功耗限制及其范围/默认值、再调用 setter 的接口；它的代码示例只演示 API 用法，没有把 Vega M GH / `1002:694C` 列为已支持型号。继续查 ADLX 仓库、问题记录和公开工具代码，没有找到 GH 上 ADLX 手动功耗调节成功的实机报告。**目前结论是“缺少公开实测”，不是“已证实不支持”。**
- `ProjectPhysX/hw-smi` 的公开代码提到 `694C`，但该项目通过 ADLX 读取遥测（功耗、风扇转速、核心/显存频率等）；源码没有对该设备调用手动功耗 setter。能监控、能识别 ID 不能证明可以改功耗。
- AMD 官方 Adrenalin 指南把 Quiet 预设描述为降低功耗和风扇设置，并说明 Radeon RX Vega 系列可有 Quiet / Balanced / Rage 预设，也描述了 Power Limit (%) 控件；同页同时提醒各 GPU 可用控件不同，示例按 RX 7900 XTX 撰写。它能说明 Windows 面板的功能语义，不能单独证明 GH 驱动暴露了相同控件或可降低到什么范围。
- Intel 的 RX Vega M Graphics Hub 将 Hades Canyon NUC 的 Vega M 驱动下载指向 Intel 下载中心，并把 WattMan/Radeon 调整指南列为参考。因而 ADLX 是否能用还取决于这台 Windows 安装实际运行的 Intel/OEM 或改装 AMD 驱动、其附带的 AMD 用户态组件和当前 ADLX runtime；“ADLX 向后兼容”不是型号级兼容保证。
- Windows 端完整适配和面板可调能力已由用户在目标机确认，不再把它列为待证假设。对本项目最有价值的下一份材料是 Adrenalin 导出的**默认 XML 与每次只修改一个控件后的 XML**，按 Power Limit、核心频率、HBM 频率分别采集；先由 GH Control 做原始差分，再结合面板截图/单位解释字段。ADLX 仍可作为独立的只读交叉检查，但不是验证 Windows 控制能力的前置条件。无论 XML/ADLX 结果如何，它们都不替代 macOS sPPT 验证。
- 这台 Mac 当前把 Windows NTFS 系统卷以只读方式挂载；我据此静态核对了其本地 Windows 文件，没有启动 Windows 或写入该卷。DriverStore 的 `u0393589.inf` 版本为 `31.0.21001.46001`（2023-06-28），其中有 RX Vega M GH 条目；WindowsApps 中的 Radeon Software 包目录版本为 `10.23.10022.0`。这是本机安装文件的记录，不用它替代用户确认的硬件身份。
- 本地 `atiadlxx.dll` 的 PE 导出表包含 `ADL2_OverdriveN_PowerLimit_Get/Set`、`SystemClocksX2_Get/Set`、`MemoryClocksX2_Get/Set`、FanControl 等函数；RadeonSoftware 主程序的静态字符串也包含 `atiadlxx.dll` 和这些 OverdriveN 名称。它强烈指向 Windows 面板通过 AMD 的 ADL2/OverdriveN 用户态层调节，而非一个可以直接移植到 macOS 的控制接口；静态字符串还不等于已完整还原每次按钮点击的调用栈。
- AMD ADL v18.1 文档把 ADL2 OverdriveN 功耗 getter/setter 的参数定义为 `ADLODNPowerLimitSetting`，结构字段包括 `iTDPLimit` 与 `iMaxOperatingTemperature`，但没有给出单位。另一套 ADLX `SetPowerLimit` API 明确使用百分比；不能把 ADLX 的单位直接套到本机 Adrenalin 的 ADL2 调用或 macOS CWDDE 输入。
- 因而 Windows 面板的 `Power Limit (%)` 不能直接换算成 macOS CWDDE `0x6e` 的输入。Linux VEGAM 上游为同一 SMU 消息使用整数瓦数的 Q8 编码，强力支持 macOS 参数按瓦数解释；本机 PowerPlay 表来源、运行时允许范围与实际生效值仍需独立验证。不要把 ADLX 的百分比 API、ADL2 私有接口和 macOS 命令参数混为一套单位。

硬件命名要特别小心：RX Vega M GH 的 PCI ID 是 `1002:694C`，芯片家族是 Polaris 22 XT；GL 是 `694E`，WX Vega M GL 是 `694F`。它们都不是桌面 RX Vega 56/64（Vega 10，常见 ID `687F`）。RX 500、Vega 56/64、6600 XT 的表、时钟和电压数值都不能直接套到 GH。

## 项目比较

| 平台 / 项目 | 能控制什么 | 项目成熟度与证据 | 对 GH 的判断 |
|---|---|---|---|
| Windows：AMD Radeon Software / WattMan | GPU 功耗上限、频率/电压曲线等，具体项随驱动和 GPU 而异 | 非开源；用户已在目标 Hades Canyon / GH 上确认 Hades-VegaM + Adrenalin 的功耗、频率调节完整可用。公开评测也记录用 WattMan 调高功耗上限和 GPU 频率。2018 年 GH 用户报告当时的驱动下调压会立即弹回 750 mV | **Windows 调节能力已由用户在 Win10/Win11 实机确认**；公开评测主要证明提高功耗上限，不证明降低 Power Limit 会减少实际瓦数或风扇噪声。旧驱动下压失败也不等于现行驱动结果 |
| Windows：[`GPUOpen-LibrariesAndSDKs/ADLX`](https://github.com/GPUOpen-LibrariesAndSDKs/ADLX) | 官方 C/C++ SDK，可枚举 GPU 并读取 vendor/device/subsystem/revision ID、PNP 硬件路径；可查询是否支持手动 Power Tuning，读取当前限制、范围和默认值并设置。Manual Power Tuning 的值以**百分比**表示，不是瓦数。Pre-Navi 图形调节接口可读/写频率、电压状态 | AMD 官方 SDK 与公开示例。`IsSupportedManualPowerTuning` 明确返回每张卡的支持状态；官方兼容性说明同时警告“部分 legacy GPU 可能不支持”。SDK 要求兼容的 AMD 驱动；未找到 694C / Hades 的支持记录 | **最优先的 Windows 验证入口，尚非 GH 适配结论。** 枚举所有 GPU 后按 PCI 身份匹配，不能假设列表首张就是 GH；再只运行支持性查询和读值。若 694C 返回支持，再另行评估最小、可恢复的写入验证。ADLX 仅适用于 Windows，不能作为 macOS 控制通道 |
| Windows：[`integralfx/PPTableEditor`](https://github.com/integralfx/PPTableEditor) | 编辑 Windows 注册表中的 Soft PowerPlay Table | 只有 6 个提交、5 个 star、无发布版；README 只称 RX Vega。仓库样例文件叫 `RxVega_M_soft_PowerTable.reg`，但没有附 PCI ID 或 GH/GL 机型证据；原始 Hades 超频讨论明确是 **Vega M GL** | 可研究表格字段和注册表机制；不算成熟 GH 方案 |
| Windows：[`halsafar/Vega64SoftPowerTableEditor`](https://github.com/halsafar/Vega64SoftPowerTableEditor) | C#/GTK 图形界面解析/编辑 Windows Vega SoftPowerTable：核心/显存时钟、电压、PowerTune、风扇表 | 44 次提交、53 stars；README 明确写“Works on VEGA 64 and VEGA 56”，要求把注册表表格导入、修改后应用并重启；作者警告不会检查参数是否合理 | **有可参考的编辑器实现，但只明确支持 Vega 56/64（Vega 10），没有 Vega M / Polaris 22 支持。** 不应套用其表或范围 |
| Windows：[`dumbie/RadeonTuner`](https://github.com/dumbie/RadeonTuner) | AMD Adrenalin 的轻量替代，调节 GPU/风扇和驱动图形设置 | 活跃仓库，有正式版本和数百个 star；README 明确要求 AMD RDNA 或更新架构 | 项目成熟，但 Vega M GH 属于 Polaris 22，不满足 RDNA 最低要求 |
| Windows / Linux：[`sibradzic/upp`](https://github.com/sibradzic/upp) | 解析、导出、编辑 AMD PowerPlay 表；可从离线 Windows 注册表 hive 读取表 | GPL-3.0；支持 Polaris/Vega 家族，但没有列 Polaris 22/Vega M；README 称 Windows 注册表支持“应该可用、需要测试”；它是表编辑 CLI，不负责实时 Apply | 候选解析器/格式参考；要先用本机 GH ROM 验证，不是已确认的 694C 支持 |
| Windows：[`tech-o-stor/OverdriveNTool`](https://github.com/tech-o-stor/OverdriveNTool) | AMD Windows 超频与 SoftPowerPlayTable 编辑 | 仓库列出的支持范围包含 Vega 56/64、Polaris 等，但未列 Vega M；未找到 GH 测试，且没有看到可复用的开源实现许可/完整源码 | 不作为 GH 开源实现依据 |
| Windows：[`leogcry22/Hades-VegaM`](https://github.com/leogcry22/Hades-VegaM) | 给 AMD 显示驱动补入 Vega M / Hades Canyon 硬件匹配，配合官方 Radeon Software / Adrenalin 控制中心使用 | README 明确列出 Hades Canyon、i7-8809G、GH/GL 和“New Radeon Software Options”；**用户确认该适配在 Win10/Win11 完整可用，Adrenalin 的 GPU 功耗、频率等调节功能可用。** 仓库于 2022-07-05 归档。代码树主要是 AMD 驱动 INF、安装 manifest 和截图，并非独立控制程序。INF 记录的驱动版本为 27.20.22025.1006（2021-08-24），把 GH `1002:694C` 的 subsystem `0CF9:8086` / `2073:8086` 映射到 `ati2mtag_VegaM` | **Windows 端已跑通的目标硬件基线。** 它复用 Adrenalin/WattMan，不是新开发一套控制器。仓库本身是 Windows 驱动适配，不能作为 macOS 控制接口；它已归档，仓库内 INF 版本不代表当前软件栈 |
| Linux：上游 [`amdgpu`](https://codebrowser.dev/linux/linux/drivers/gpu/drm/amd/amdgpu/amdgpu_drv.c.html) | `1002:694C` 有明确的 PowerPlay `set_power_limit` 代码路径；hwmon `power1_cap` 以微瓦为单位 | PCI ID 映射为 `CHIP_VEGAM`，随后选择 `vegam_smu_funcs` 和 SMU7 setter；源码将整数瓦左移 8 位后发 `PPSMC_MSG_PkgPwrSetLimit (0x187)`。但外层 PowerPlay wrapper 忽略底层 setter 返回值并缓存请求值，当前没找到在 GH 上写入后以实际功耗变化证明生效的公开记录 | **比普通 Polaris 支持声明更强：上游确实为 694C 接了功耗限制 setter；固件是否接受并生效仍需 GH 实测。** `power1_cap` 写成功/读回缓存不能单独作成功证据 |
| Linux：[`LACT`](https://github.com/ilya-zlobintsev/LACT) | GUI：功耗上限、AMD 电源状态、GPU/显存时钟、电压、遥测和配置档 | 活跃的大型开源项目；支持表把一般 Vega 和 Polaris 的时钟、功耗上限、电源状态列为支持；未列出 Vega M。文档称未列出的 GPU 可能只有监控，集显也可能只支持基础配置 | 最成熟的 Linux GUI 候选，适合在目标机 Linux 环境确认接口和做后续受控验证；没有 GH/694C 专项验收记录 |
| Linux：[`azeam/powerupp`](https://github.com/azeam/powerupp) | UPP 的 GTK 图形界面，编辑并上传 AMD PowerPlay table；所改值可立即生效，另可配置启动脚本保持重启后的设置 | 90 stars、105 次提交；README 明确写支持 Navi 10（RX 5000）和 Big Navi（RX 6000），并标注早期开发、自担风险。README 还记录 Linux 5.10 后调功耗上限需要 `ppfeaturemask`；项目 issue 曾报告 power limit 写入行为回归 | **不是 GH 候选**：目标架构不含 Polaris 22/Vega M。可参考表格编辑与恢复默认值 UX；其 `pp_table` 写入经验只能说明 Linux 驱动路径，不能迁移成 macOS 控制方式 |
| Linux：[`amdgpu-clocks`](https://github.com/sibradzic/amdgpu-clocks) | 通过 `amdgpu` sysfs 配置时钟、电压、可用状态和 `FORCE_POWER_CAP` | GPL-2.0；支持说明覆盖 Polaris/Vega；README 说明部分 AMD APU Vega 不暴露该工具需要的 OverDrive API | 可作为轻量控制脚本参考；Hades Canyon 的 Intel + Vega M GH 组合是否暴露 API 未知，必须读目标驱动节点，尚无 GH 实测 |
| Linux：[`amd-linux-control-center`](https://github.com/cpugod55/amd-linux-control-center) | 新 GUI：GPU 控制、配置档、遥测、风扇和游戏联动 | 当前仍为 0.99.0-rc1，仓库只有 9 个提交、7 个 star；README 正在招募非 RX 6800 XT 用户测试 | 值得观察的新项目，不应称为成熟或已验证 GH 方案 |
| Linux：[`CoreCtrl`](https://gitlab.com/corectrl/corectrl) | AMD GPU 时钟、功耗状态、功耗上限、风扇与应用配置档 | 功能完整，但项目 README 已声明进入 maintenance mode；通用 AMD 支持声明不代表 Vega M GH 单卡验证 | 可参考旧式桌面控制面板；新项目优先看 LACT |
| macOS：[`osy/HaC-Mini`](https://github.com/osy/HaC-Mini) | Hades Canyon 的完整 Hackintosh 支持，包括 Vega M GPU 加速 | 成熟、专用目标机的开源项目；没有提供 GPU PowerPlay 调节器 | 可复用其目标机/驱动适配经验，不是功耗控制仓库 |
| macOS：[`Baio1977/Intel-NUC8i7HN`](https://github.com/Baio1977/Intel-NUC8i7HN) | 针对 NUC8i7HVK、i7-8809G、Vega M GH 的 OpenCore 配置 | 较新的精确目标机配置，README 报告 GPU 加速；其公开 `OC/Config.plist` 未见 `PP_PhmSoftPowerPlayTable` | 证明有现成 GH Hackintosh 配置可参考，但没有功耗表写入/验证证据 |
| macOS：[`klich3/6600XT-on-macOS-with-PowerPlayTable`](https://github.com/klich3/6600XT-on-macOS-with-PowerPlayTable) | 从 Windows/MPT 或 VBIOS 提取/修改 Soft PowerPlay Table，再通过 OpenCore DeviceProperties 或 SSDT 注入 | 有完整操作说明与 MIT 转换脚本；目标卡是 RX 6600 XT，展示重点为 Zero RPM/风扇行为 | 说明 macOS 启动时注入 sPPT 的路径确实存在；不证明 694C 表格式或 Power Limit 生效 |
| macOS：[`klich3/PPT-table-tool`](https://github.com/klich3/PPT-table-tool) | 将 Windows 注册表 dump / PPTable 转为可读文本与 SSDT DSL | MIT；仓库只有少量提交；主要是格式转换，不提供 GPU 参数编辑器 | 可作为表格转换的现成代码参考，不是调功耗软件 |
| macOS：[`corpnewt/PyVega`](https://github.com/corpnewt/PyVega) | Python/Tk GUI 调整 GPU/显存时钟与电压、功耗目标和风扇参数，生成 `PP_PhmSoftPowerPlayTable` 并写入用户选定的 OpenCore/Clover plist | MIT；PyVega 是 VGTab 的 Python fork。源码里的卡型下拉表明确限定 Vega 64/56、Vega FE、液冷版、WX 8200/9100；没有 Vega M。工具对目标 plist 直接写入，不是生成审阅用的独立补丁文件 | 比 Excel 更接近“面板式配置生成器”，但表针对 Vega 10，不是 Vega M GH / Polaris 22；改变需重启，也不是运行时控制器。不能把其表或预设套到 694C |
| macOS：[`CMMChris PowerPlay Table Generators`](https://www.insanelymac.com/forum/topic/340009-tool-radeon-vii-powerplay-table-generator-oc-uv-fan-curve/) | Excel 生成器：按 GPU 生成 OpenCore/Clover 注入所需的 PowerPlay 属性，可修改时钟、电压、Power Limit、TDC、风扇曲线 | 社区多年使用的工具系列，但分别面向 Radeon VII / Vega 20、Vega 64 / Vega 10、RX 5700 / Navi 10；它生成开机表，不是运行时面板 | 是成熟的配置生成器参考；不支持 Polaris 22 / Vega M GH，表格式和字段不能跨代照搬 |
| macOS：[`OC-Little AMD Radeon tweaks`](https://github.com/5T33Z0/OC-Little-Translated/blob/main/Content/11_Graphics/GPU/AMD_Radeon_Tweaks/README.md) | 说明用 `PP_PhmSoftPowerPlayTable` 注入功耗限制、时钟、风扇等表字段 | 覆盖 Polaris RX 500、Vega 56/64、RX 5700 等；没有 Vega M GH 验收 | 适合作为 OpenCore 属性配置参考，不应复用别的 GPU 的表 |
| macOS：[`ZeroRPMBuilder`](https://www.insanelymac.com/forum/topic/363267-zerorpmbuilder-for-macos-amd-zero-rpm-fan-35%C2%B0c-powerplay-patch-generator/) | 原生 app 生成启动时的 Zero RPM / 风扇温度 sPPT 补丁 | 新近发布；未找到公开源码仓库；功能只改风扇启停和温度字段，作者列出的芯片布局不含 Polaris 22 | 不调功耗上限、时钟或电压，也没有 GH 支持；不解决核心需求 |
| Windows/Linux：[`ProjectPhysX/hw-smi`](https://github.com/ProjectPhysX/hw-smi) | ADLX/AMDSMI 遥测：功耗、温度、时钟、风扇等 | 活跃的跨平台监控器；源代码中单独识别 `694C` 以估算 GH 内存带宽，但仓库没有功耗/频率写入功能，也未找到 GH 调参验证 | 可能有遥测参考价值；不解决控制核心需求 |
| Linux：[`Hades-Canyon-Vega-M-GH.conf`](https://gist.github.com/thaddeusc1/527c5bc980029a101caf91720b4010b5) | `lm-sensors` 标签配置，给 amdgpu 的输入、温度、功耗传感器命名为 Vega M GH | 明确面向 Hades Canyon GH 的单文件传感器配置，不是成熟调参仓库，也没有写入控制 | 可作“Linux 有功耗遥测节点”线索；不证明 power cap 可写 |

## 证据分级

### 已有 GH 直接证据

- Linux 上游设备 ID 表将 `1002:694C` 匹配到 `CHIP_VEGAM`，即 RX Vega M GH。
- 上游 Linux 为 VEGAM 使用 SMU7 功耗管理路径；该 setter 把整数瓦数左移 8 位后发送 `PPSMC_MSG_PkgPwrSetLimit (0x187)`。AMD ACPI 头文件将 GPU package power limit 参数明确写为 Q8.8 Watts；Linux `power1_cap` 以微瓦输入，再除以 1,000,000 转成整数瓦后交给 PowerPlay。这三处代码互相吻合，强力支持 macOS `0x6e` 整数参数按瓦数解释；但不证明目标 macOS firmware 已接受写入，也不提供本机安全范围或生效读回。[AMD Q8.8 Watts 定义](https://codebrowser.dev/linux/linux/drivers/gpu/drm/amd/include/amd_acpi.h.html) · [Linux µW→W 转换](https://codebrowser.dev/linux/linux/drivers/gpu/drm/amd/pm/amdgpu_pm.c.html) · [SMU7 setter](https://codebrowser.dev/linux/linux/drivers/gpu/drm/amd/pm/powerplay/hwmgr/smu7_powertune.c.html) · [VEGAM SMU](https://codebrowser.dev/linux/linux/drivers/gpu/drm/amd/pm/powerplay/smumgr/vegam_smumgr.c.html)
- Linux 的 SMU mailbox helper 会检查固件响应，但外层 `pp_set_power_limit()` 忽略底层 setter 的错误码并缓存请求值；`pp_get_power_limit(CURRENT)` 读回该软件缓存。因此 sysfs 写成功和 cap 数值回显都不能证明硬件执行。当前没有找到 GH 上“写 cap 后以功耗/时钟/性能对照证明生效”的公开实测。[`amd_powerplay.c`](https://codebrowser.dev/linux/linux/drivers/gpu/drm/amd/pm/powerplay/amd_powerplay.c.html) · [`smu7_smumgr.c`](https://github.com/torvalds/linux/blob/master/drivers/gpu/drm/amd/pm/powerplay/smumgr/smu7_smumgr.c)
- Linux 上游补丁标题为“fix a crash when overclocking Vega M”，正文写明在 Intel Hades Canyon i7-8809G 上测试。它证明 Vega M 的 PowerPlay/SMU overclock 代码在目标平台上实际运行过；它没有记录 power-cap 写入、降压、瓦数变化或稳定性结果。
- Windows 上 Hades Canyon GH 的实机评测使用 AMD WattMan 调整 GPU 频率和功耗上限。这证明闭源 Windows 驱动提供过该控制能力；不是开源项目的 GH 兼容证据。

### 通用能力，不是 GH 实测

Linux 内核文档定义了 GPU `power1_cap`、`pp_od_clk_voltage` 和 `pp_table` 等接口。接口能否出现、可写范围有多大、VBIOS 是否允许，以及提交后实际功耗是否变化，都由具体 GPU/固件/内核组合决定。LACT 和 `amdgpu-clocks` 都调用这些接口，因此“应用支持 Vega/Polaris”不能替代对这台 GH 读范围、写值、读回和实测功耗的验证。

另有针对 **Vega M GL** 的 Linux 报告显示，`pp_od_clk_voltage` 虽然存在，但时钟范围被限制在接近默认值、电压固定。这不是 GH 结果；它说明不能只看到 sysfs 文件存在就宣称有有效调节空间。

### Windows 开源项目的关键缺口

- AMD 官方 [`ADLX`](https://github.com/GPUOpen-LibrariesAndSDKs/ADLX) 是这一轮新增的关键线索。它不是 WattMan 的逆向私有协议：API 已公开提供 `IsSupportedManualPowerTuning`、功耗限值读取/范围/默认值和 `SetPowerLimit`；官方 C 示例先检查每张 GPU 是否支持，再获取接口和读回范围。`IADLXGPU` 还提供 `VendorId`、`DeviceId`、`SubSystemVendorId`、`SubSystemId`、`RevisionId` 和 `PNPString`，因此探针可枚举全部适配器，按身份选出 694C，而不是假设第一个 GPU 或依赖产品名称。Windows 设备管理器的硬件 ID / PCI 位置应作为交叉核对。频率/电压示例也区分 pre-Navi 与 post-Navi，Vega M 应先检查 pre-Navi 接口族。**但 API 存在不代表旧驱动/GH 可用**：AMD 文档明确写着部分旧 GPU 可能不支持，能力会随已安装驱动和 ADLX 版本变化，且 legacy GPU/driver 的初始化方式也不保证适用。因此应在 Windows 目标系统上做 ADLX 只读探测，记录 PCI identity、驱动版本、支持标志、功耗范围/当前值和接口返回码；读到受支持且数值合理前不调用 setter。
- Windows 还有一个比 `PPTableEditor` 更完整的开源 Vega 桌面卡 GUI：`Vega64SoftPowerTableEditor`。但其 README 限定 Vega 56/64，明确警告不验证参数安全性，并要求重启；这些代码和 Vega 10 表结构仍不能证明适配 Vega M GH。另一个精确到“Vega M”命名的仓库样例 `RxVega_M_soft_PowerTable.reg` 没有 PCI ID，相关 Hades 讨论实测目标是 GL，不能据文件名认定为 GH。
- GH 的 Windows 参数通路已由用户确认可用；公开评测另有 WattMan 调高频率和功耗上限的记录。但用户的目标是降低功耗，现有证据尚未证明把 Power Limit 往下调会按预期降低 GPU 瓦数、温度或 Hades 整机风扇噪声。2018 年一位 GH 用户报告下调电压后立即被重置到 750 mV，AMD/Intel 支持回复没有确认电压调节可用；此记录只约束当时的驱动/版本，首轮仍应先做单项 Power Limit / 频率对照，电压放后。
- 这也改变逆向顺序：如果 Windows 上 ADLX 能为 694C 报出手动功耗支持并读到有效范围，就可先借官方接口做控制原型，无需先拆 Radeon 面板；REA 留作 ADLX 未覆盖项、ADLX 不可用或需要理解面板额外行为时的后续工具。ADLX 结果只证明 Windows AMD 驱动路径，不能直接证明 macOS PowerPlay 表注入可用。
- `PPTableEditor` 的 Hades 社区实测针对 GL；它不是给 GH 保证可用的成熟产品。
- `UPP` 支持 Polaris/Vega 家族表，能从 ROM 提取、解析和修改 Power Limit 等字段，也能导入 Windows registry/MPT；README 没有列出 Polaris 22/Vega M，也没有 694C 样本验证。编辑表 ≠ AMD 驱动接受表 ≠ GPU 应用表 ≠ 降低实际功耗。其 Windows registry 导入支持仍被标为需要测试。
- 用户确认 `Hades-VegaM` 在 Win10/Win11 上对这套目标硬件完整适配，Adrenalin 面板及相关调节功能可用；仓库自身仍没有自有调节 API 或独立控制器。下一步研究 macOS 时，应以 Windows 面板可用设置作为目标行为基线，集中验证 macOS 驱动怎样接收相应 PowerPlay 参数，而不是继续把 Windows 控制能力当作未知。
- `OverdriveNTool` 与 Vega 56/64 的 SoftPowerPlayTable 编辑经验不能直接套到 Vega M。项目未列 694C/GH。
- `RadeonTuner` 虽然是较成熟的 AMD Windows 调节项目，但 README 要求 RDNA 或更新架构；Vega M GH 属于 Polaris 22，不能因为同为 AMD GPU 就假定可用。
- Linux 的 `PowerUPP` 不是可直接拿来控制 GH 的现成答案。它的 README 直接写支持 Navi 10 / Big Navi，值可以写入 `pp_table` 并即时应用，但不持久；持久化依靠开机脚本。它还明确提到内核 5.10 后 power-limit 控制需要额外打开 `ppfeaturemask`，相关 issue 记录过功耗上限写入回归。它适合借鉴表格编辑器流程，不能证明 Polaris 22 接口可用。
- `RxVega_M_soft_PowerTable.reg` 这个文件名只说明样例被作者称作 Vega M，并没有标出 GH/GL 的 PCI ID。找到的 Hades 社区实测帖子明确写的是 Vega M GL，所以不能把它提升为 GH 表证据。

### macOS 现有路径与关键缺口

- Hackintosh 社区已有相对成熟的做法：把 GPU 专用 `PP_PhmSoftPowerPlayTable` 作为 OpenCore `DeviceProperties` 或 SSDT 属性，在启动时提供给 AMD 驱动。RX 6600 XT 的公开指南记录了从 Windows 注册表/VBIOS 导出表、用 UPP 提取/处理、转换为 OpenCore 属性并在 IORegistry 检查属性是否加载的流程。这证明了“macOS 可以消费启动注入的 sPPT”这一通用机制，不代表运行时修改，也不证明 GH 的特定表会被接受。
- 即使 `PP_PhmSoftPowerPlayTable` 能在 IORegistry 中看到，也只证明属性已注入，不能单独证明 AMD 驱动采用了所有字段或实际功耗/频率发生变化。RX 6600 XT 指南记录了某些 Ventura 版本中 Zero RPM 属性存在但行为未改变的情况；因此目标机验证至少要分成“属性到达 → 驱动行为变化 → 实测功耗/频率变化”三步。
- 直接针对 Hades Canyon 的 HaC-Mini 与 Intel-NUC8i7HN 配置仓库解决了 GPU 加速/设备适配，但其公开资料没有提供 GH 的功耗上限、频率/电压编辑器或成功读回证据。检查 Intel-NUC8i7HN 当前公开 `OC/Config.plist`，目标 GPU 属性中有设备伪装/兼容设置和 Polaris22Fixup，但没有 `PP_PhmSoftPowerPlayTable`。
- HaC-Mini 的 Polaris22Fixup 是为了修复 Vega M / Polaris 22 的 macOS Metal 和启动兼容问题；它不是 PowerPlay 控制 kext。该项目的 GPU spoof 文档分别识别 `694C` GH、`694E` GL 和 `694F` WX GL，因此这几个 SKU 的公开配置不能互换。
- HaC-Mini 的 [`SSDT-GpuSpoof`](https://github.com/osy/HaC-Mini/blob/master/ACPI/SSDT-GpuSpoof.asl) 按物理目标区分这些 ID，再将兼容 `device-id` 注入给 macOS 图形驱动。本机 AMD 驱动公开的 64 KiB `ATY,bin_image` 中 PCIR 声明 `1002:694C`，Registry compatible/vendor/subsystem 也报告 `1002:694C / 8086:2073`；Registry `device-id=67DF` 是单独的驱动匹配值。镜像和 Registry 都可能被启动配置注入或替换，因此这些信息只建立目标设备候选，不是原始 PCI 寄存器确认。工具不能因 `67DF` 就使用 RX 570 的 VBIOS/PowerPlay 表；从这份镜像解析的 75 W 表也不能直接叫作实体卡原厂表。
- `PPT-table-tool` 负责格式转换；`ZeroRPMBuilder` 是 macOS 原生表补丁工具，但其公开功能说明明确只改零转速/风扇温度字段，并明确不改功耗上限和时钟。因此二者都不是 Windows Radeon 面板式的功耗管理应用。
- `PyVega` 是更像 GUI 面板的既有工具：源码支持 Vega 56/64、Frontier、WX 8200/9100 等 Vega 10 卡，可调时钟/电压、功耗目标和风扇参数，并导出 `PP_PhmSoftPowerPlayTable`。它将生成的数据直接写入用户选定的 plist，需重启；源码的型号表没有 Vega M GH/Polaris 22。其界面和表格构建逻辑可研究，不能拿预设表/范围冒充 694C 数据。
- CMMChris 的 PowerPlay Excel 生成器同样可作为配置生成参考：用户填参数后导出属性，经 bootloader 注入；不是运行时控制器，公开目标是 Vega 10/20、Navi 10 和部分 Polaris RX 500。名称含 “Vega” 的 Vega 64 generator 是 Vega 10，不是 Vega M 的 Polaris 22。论坛记录也提到 Power Limit 字段在部分 macOS 驱动/配置下效果不明显，需在本卡实测。
- `ZeroRPMBuilder` 不属于 GH 候选：它仅生成风扇启停温度字段，芯片布局列表没有 Polaris 22，且没有找到公开源代码仓库。
- WhateverGreen 公开了 `PP,PP_WorkLoadPolicyMask`，其中 `0x04` 对应 `POWERSAVING_WORKLOAD`。这可以作为低功耗工作负载策略的实验候选，但它不是可设置瓦数的 Power Limit，也没有检索到 Vega M GH 上的功耗实测。

**结论：没找到现成的 1002:694C macOS 调功耗面板；可复用的路径是 sPPT 开机注入。** GH Control 已能从 macOS AMD 驱动公开的 ROM 镜像读取遥测并解析 PowerPlay 表，生成 70 W 候选和该镜像表回退 plist。当前不能确认镜像来源是实体卡原始 ROM，也不能确认候选表被 Apple AMD 驱动采用、实际功耗下降或风扇变化；这些都需在可回退 EFI 上实测。应用不写唯一 EFI。

### 本机实现结果（2026-10-12）

- 从 `AMDRadeonX4000_AMDEllesmereGraphicsAccelerator` 的 `PerformanceStatistics` 实际读到 `Core Clock(MHz)`、`Memory Clock(MHz)`、`Temperature(C)`、`Total Power(W)`、GPU 活动率；应用每 2 秒只读采样。数值由 Apple AMD 驱动报告，不等同于外接功率计测量。
- 从驱动公开的 `ATY,bin_image`（64 KiB，SHA-256 `63cc415b184e20a9580b1cd2657040b13be3c881b1a81008827ce086248bcaaa`）解析到镜像 offset `0x9604` 的 PowerPlay v7.1 表，长度 701 B，PowerTune 子表 rev 4。镜像表声明 `TDP=75 W`、`TDC=90 A`、`MaximumPowerDeliveryLimit=75 W`、`BoostPowerLimit=75 W`、`TjMax=85 °C`；`PowerControlLimit=75` 单独展示且不当作瓦数改写。此数据不证明 ROM 来源或实体卡出厂值。
- 导出的 70 W 候选只改这份镜像的 PowerTune 子表中五个高于目标值的功耗字段：TDP、BatteryPowerLimit、SmallPowerLimit、MaximumPowerDeliveryLimit、BoostPowerLimit。时钟/电压/温度与其他字节保持原样。另有镜像表回退 plist。
- 结构字段布局与 Linux AMD 驱动中的 `ATOM_Polaris_PowerTune_Table` 一致；WhateverGreen 文档确认 AMD `aty_properties` 使用 `PP,` 属性前缀。两项只佐证二进制布局和注入机制，不证明 Apple 驱动在本机采用候选值。[Linux PowerPlay 表结构](https://code.googlesource.com/linux/torvalds/linux/%2B/5a5409d90bd05f87fe5623a749ccfbf3f7c7d400/drivers/gpu/drm/amd/pm/powerplay/hwmgr/pptable_v1_0.h) · [WhateverGreen Radeon FAQ](https://github.com/acidanthera/WhateverGreen/blob/master/Manual/FAQ.Radeon.en.md)
- 本机已有 OpenCore 配置副本指向 `PciRoot(0x0)/Pci(0x1,0x0)/Pci(0x0,0x0)`。当前 EFI 分区没有成功只读挂载，应用不会推断该副本就是正在启动的配置，也不会改写它。
- 当前缺少的关键实测仍是：单独 EFI 的实际启动/恢复、注入属性读回、负载下功耗上限是否改变、GPU 温度/频率和机箱风扇的前后差异。

## 给 GH Control 的工程建议

1. 将 **降低功耗上限** 作为产品第一控制目标；频率上限作为第二个候选项；先不把电压曲线、风扇曲线纳入首个可写版本。Windows 目标机验证优先用 ADLX 能力探针；它与 macOS 的 sPPT 路径分开评估。
2. 参考顺序：
   - Linux 写入/读回/错误处理：`LACT` 和 `amdgpu-clocks`。
   - 表格式解析：`UPP`，但注意 GPL-3.0 的代码复用要求；若不希望引入 GPL 依赖，仅把它作为格式文档/对照实现。
   - macOS sPPT 启动注入与配置生成：`klich3/6600XT-on-macOS-with-PowerPlayTable`、`PPT-table-tool`；仅参考注入与格式转换，不复用 6600 XT 的参数。
   - Windows 功耗/频率控件的预期语义：本机 Radeon 面板；不要把 GL 示例表直接当作 GH 表。
3. macOS 的 MVP 控制不能声称使用 LACT 的 Linux 接口。现阶段仅能把表导入、校验、差异预览和配置导出做成可审核流程；在 macOS 上的写入/重启应用，必须等到确认目标驱动接收该 GH 表并有有效读回后再开放。
4. Windows 侧先用 AMD ADLX C 示例或只读探针，枚举全部适配器，并记录各 GPU 的 `VendorId`、`DeviceId`、`SubSystemVendorId`、`SubSystemId`、`RevisionId`、`PNPString`、`DriverPath` 和 BDF/PCI 位置；交叉核对 Windows 设备管理器中的硬件 ID 后，才把真实 `1002:694C` 对应对象用于后续查询。读取其 `IsSupportedManualPowerTuning`、`GetPowerLimit`、`GetPowerLimitRange`、`GetPowerLimitDefault`，并记录 ADLX/AMD 驱动版本、API 值单位（百分比）和返回码；只读成功后再另行设计可恢复写入试验。Linux 侧另记录同一 PCI ID 对应的 sysfs 节点、OD 范围、`power1_cap_min/current/max` 和驱动版本。两平台的证据互相补充，不能把 Windows API 结果直接外推到 macOS。
5. macOS 侧的平行验证应先只读检查当前 EFI/IORegistry 的 GPU 设备路径、现有表属性、驱动版本，并解析 Windows 导出的本机 GH VBIOS/SPPT；生成补丁时先做副本和差异预览，不自动覆盖当前 EFI。重启验证需另备已实测可启动的恢复 EFI。
6. macOS 验收要分别记录属性是否注入、驱动是否采用候选表、负载下实际功耗/时钟是否变化；属性存在本身不算成功。

## 主要来源

- ADLX 的 GPU PCI 身份字段与全卡枚举示例：[`IADLXGPU`](https://gpuopen.com/manuals/adlx/adlx-sdk-references/adlx-interfaces/gpu/iadlxgpu/) · [AMD GPU enumeration C sample](https://gpuopen.com/manuals/adlx/programming-with-adlx/adlx-samples/c-samples/miscellaneous/gpus/)
- Linux `amdgpu` 的 GH 设备匹配：[`amdgpu_drv.c`](https://code.googlesource.com/linux/torvalds/linux/+/826c484166f0f74bd8fc09220f99dc937c9297cf/drivers/gpu/drm/amd/amdgpu/amdgpu_drv.c)
- Hades Canyon 的 Vega M overclock 路径测试：[Linux 内核补丁](https://github.com/torvalds/linux/commit/d1bab3cf71dd3713b34ba5d6e7af13816a4b6941)
- 通用 Linux `amdgpu` 功耗/时钟 sysfs：[Linux 内核文档](https://www.kernel.org/doc/html/latest/gpu/amdgpu/thermal.html)
- LACT 功能与硬件矩阵：[`LACT README`](https://github.com/ilya-zlobintsev/LACT) · [`LACT hardware support`](https://github.com/ilya-zlobintsev/LACT/wiki/Hardware-Support)
- `amdgpu-clocks` 的功耗上限和时钟接口，以及 AMD APU Vega 接口限制：[README](https://github.com/sibradzic/amdgpu-clocks)
- Windows Soft PowerPlay 表编辑：[PPTableEditor README](https://github.com/integralfx/PPTableEditor/blob/master/README.md) · [仓库 Vega M 示例表](https://github.com/integralfx/PPTableEditor/blob/master/RxVega_M_soft_PowerTable.reg) · [UPP](https://github.com/sibradzic/upp)
- Windows Vega 桌面卡 PowerPlay 编辑器（README 限定 Vega 56/64）：[`Vega64SoftPowerTableEditor`](https://github.com/halsafar/Vega64SoftPowerTableEditor)
- Linux PowerPlay 图形编辑器与 power-limit 写入问题记录：[`PowerUPP`](https://github.com/azeam/powerupp) · [内核 5.10 power limit issue](https://github.com/azeam/powerupp/issues/18)
- AMD 官方 Windows 控制 SDK：[`ADLX GitHub`](https://github.com/GPUOpen-LibrariesAndSDKs/ADLX) · [手动功耗接口](https://gpuopen.com/manuals/adlx/adlx-sdk-references/adlx-interfaces/gpu-tuning/iadlxmanualpowertuning/) · [只读能力检查与 C 示例](https://gpuopen.com/manuals/adlx/programming-with-adlx/adlx-samples/c-samples/gpu-tuning/manualpowertuning/) · [旧 GPU/驱动兼容性说明](https://gpuopen.com/manuals/adlx/programming-with-adlx/adlx-programming-guide/specifications/compatibility/) · [pre-Navi 图形调节示例](https://gpuopen.com/manuals/adlx/programming-with-adlx/adlx-samples/c-samples/gpu-tuning/manualgraphictuning/)
- AMD 面板 Quiet / Power Limit 功能语义（具体控件因卡而异）：[官方 GPU Tuning 指南](https://www.amd.com/en/resources/support-articles/faqs/DH3-020.html)
- AMD 官方 ADL OverdriveN 功耗 API：[Get/Set 接口](https://gpuopen-librariesandsdks.github.io/adl/group__OVERDRIVENAPI.html) · [`ADLODNPowerLimitSetting` 字段](https://gpuopen-librariesandsdks.github.io/adl/structADLODNPowerLimitSetting.html)
- Hades Canyon / Vega M 的 Intel 驱动来源与 WattMan 说明入口：[Intel Radeon RX Vega M Graphics Hub](https://www.intel.com/content/www/us/en/support/articles/000092059/graphics.html)
- ADLX 仅用于 `694C` 遥测的公开代码线索：[hw-smi `main.cpp`](https://github.com/ProjectPhysX/hw-smi/blob/master/src/main.cpp)
- PPTableEditor 对应的 Hades Vega M GL 超频实测讨论：[Reddit r/overclocking](https://www.reddit.com/r/overclocking/comments/iogpgm/overclocking_radeon_rx_vega_m_gl_on_hades_canyon/)
- 其他成熟度相邻的 AMD 调节仓库：[RadeonTuner（仅 RDNA+）](https://github.com/dumbie/RadeonTuner) · [amd-linux-control-center（RC 阶段）](https://github.com/cpugod55/amd-linux-control-center)
- Hades 驱动安装适配：[Hades-VegaM](https://github.com/leogcry22/Hades-VegaM)
- `Hades-VegaM` 对应版本与硬件匹配：[`U0371001.inf`](https://github.com/leogcry22/Hades-VegaM/blob/master/Packages/Drivers/Display/WT6A_INF/U0371001.inf)（`1002:694C` 条目与 2021 年驱动版本）
- Windows Win10/Win11 上 Hades-VegaM 的完整适配及 Adrenalin 调节功能：本项目用户已确认；仓库公开 README 另列 Hades Canyon、i7-8809G、GH/GL 与新版 Radeon Software 选项
- Vega M GL Linux OD 范围限制案例：[Ubuntu bug 邮件记录](https://mail-archive.com/desktop-packages%40lists.launchpad.net/msg610244.html)
- Hades Canyon / Vega M GH WattMan 调校实测：[GamersNexus Hades Canyon review](https://gamersnexus.net/hwreviews/3282-hades-canyon-review-intel-amd-pressure-nvidia-nuc8i7hvk)
- GH 在 WattMan 下调压回弹的旧版驱动报告：[Intel Community: Radeon Vega M GH in Hades Canyon](https://community.intel.com/t5/Graphics/Radeon-Vega-M-GH-in-Hades-Canyon/td-p/601004)
- Hades Canyon macOS 支持：[HaC-Mini](https://github.com/osy/HaC-Mini) · [NUC8i7HVK Vega M GH OpenCore 配置](https://github.com/Baio1977/Intel-NUC8i7HN) · [公开 Config.plist](https://github.com/Baio1977/Intel-NUC8i7HN/blob/main/OC/Config.plist)
- 精确 Polaris 22 macOS 补丁与 ID 区分：[Polaris22Fixup](https://github.com/osy/Polaris22Fixup) · [HaC-Mini Metal driver notes](https://github.com/osy/HaC-Mini/blob/master/details/metal-driver-fix.md) · [HaC-Mini SSDT-GpuSpoof](https://github.com/osy/HaC-Mini/blob/master/ACPI/SSDT-GpuSpoof.asl) · [HaC-Mini OpenCore config](https://github.com/osy/HaC-Mini/blob/master/OC/config.plist)
- macOS sPPT 注入案例与转换工具：[RX 6600 XT OpenCore sPPT 指南](https://github.com/klich3/6600XT-on-macOS-with-PowerPlayTable) · [PPT-table-tool](https://github.com/klich3/PPT-table-tool) · [WhateverGreen Radeon / workload policy 文档](https://github.com/acidanthera/WhateverGreen/blob/master/Manual/FAQ.Radeon.en.md)
- 近期 macOS DriverKit AMD 驱动项目（仅 Apple Silicon / TB 外置 R9700，不覆盖 Vega M GH）：[`lemonade-sdk/mac-amdgpu`](https://github.com/lemonade-sdk/mac-amdgpu)
- macOS PowerPlay 表生成器及目标型号：[Radeon VII / Vega 20 Generator](https://www.insanelymac.com/forum/topic/340009-tool-radeon-vii-powerplay-table-generator-oc-uv-fan-curve/) · [Vega 64 / Vega 10 Generator](https://www.hackintosh-forum.de/forum/thread/39923-tool-vega-64-powerplaytable-generator/) · [OC-Little 型号目录](https://github.com/5T33Z0/OC-Little-Translated/blob/main/Content/11_Graphics/GPU/AMD_Radeon_Tweaks/README.md)
- macOS GUI PowerPlay 生成器 PyVega：[`README / 目标卡型`](https://github.com/corpnewt/PyVega) · [GUI 卡型表与 plist 输出实现](https://github.com/corpnewt/PyVega/blob/master/PyVega.py)
- macOS 风扇表生成器（不调功耗）：[ZeroRPMBuilder 功能说明](https://www.insanelymac.com/forum/topic/363267-zerorpmbuilder-for-macos-amd-zero-rpm-fan-35%C2%B0c-powerplay-patch-generator/)
- macOS 通用 Radeon PowerPlay 说明：[OC-Little AMD Radeon tweaks](https://github.com/5T33Z0/OC-Little-Translated/blob/main/Content/11_Graphics/GPU/AMD_Radeon_Tweaks/README.md)
- REA 是逆向分析工具链，不是显卡调节仓库：[morluto/rea](https://github.com/morluto/rea)
- Hades Canyon GH 的 Linux 传感器标签配置（仅遥测线索）：[Hades-Canyon-Vega-M-GH.conf](https://gist.github.com/thaddeusc1/527c5bc980029a101caf91720b4010b5)
- 精确 694C 识别与遥测代码（不含调参写入）：[hw-smi GPU device map](https://github.com/ProjectPhysX/hw-smi/blob/master/src/main.cpp)
