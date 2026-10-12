# CWDDE 只读实机探测（2026-10-12）

## 环境

- macOS 15.5，x86_64。
- 目标 GPU 由用户确认为 Radeon RX Vega M GH；查询按 live IOService 树中的目标路径关联：
  `IOService:/AppleACPIPlatformExpert/PCI0@0/AppleACPIPCI/PEG0@1/IOPP/GFX0@0`
- 本记录中的探针只调用 `IOServiceOpen(type: 0x81)`、AMD open/close scalar selector `0/1`，以及以下固定只读 CWDDE getter。没有调用任何 setter。

## 端点拓扑

live IOService 树下有 6 个 `AtiAppServices`：

```text
GFX0@0/ATY,AMD,RadeonFramebuffer@0/AMDFramebufferVIB/AMDNDRVService
GFX0@0/ATY,AMD,RadeonFramebuffer@1/AMDFramebufferVIB/AMDNDRVService
GFX0@0/ATY,AMD,RadeonFramebuffer@2/AMDFramebufferVIB/AMDNDRVService
GFX0@0/ATY,AMD,RadeonFramebuffer@3/AMDFramebufferVIB/AMDNDRVService
GFX0@0/ATY,AMD,RadeonFramebuffer@4/AMDFramebufferVIB/AMDNDRVService
GFX0@0/ATY,AMD,RadeonFramebuffer@5/AMDFramebufferVIB/AMDNDRVService
```

`AMD9500Controller` 是 `GFX0@0` 下的兄弟节点，不是上述 service 的 ancestor。旧程序因为检查 `AMD9500Controller` ancestor 而把 6 个有效节点全过滤掉。它们代表一张 GPU 的多个 framebuffer 分支，不是六张 GPU。

## 探针 ABI

对每个 endpoint 逐个执行：

1. `IOServiceOpen(service, mach_task_self(), 0x81, &connection)`。
2. `IOConnectCallScalarMethod(connection, selector: 0, no arguments)`。
3. selector 2 输入 16 字节：dword `16` 位于 `+0`，命令码位于 `+4`；输出 buffer 容量和 output-size 都设为对应命令的固定长度。
4. 仅对成功打开的连接调用 close selector 1，然后 `IOServiceClose`。

## 结果

六个 endpoint 的 `IOServiceOpen(type 0x81)` 和 open selector 0 均返回 `0x0`。

| CWDDE | 输出容量 | IOReturn（六个节点一致） | 返回长度 | 原始数据/说明 |
|---|---:|---:|---:|---|
| `0x46` | 12 | `0xe00002bc` | 12 | 输出未被驱动改写 |
| `0x6d` | 24 | `0xe00002bc` | 24 | 输出未被驱动改写 |
| `0x54` | 64 | `0xe00002bc` | 64 | 输出未被驱动改写 |
| `0x4f` | 24 | `0xe00002bc` | 24 | 输出未被驱动改写 |
| `0x50` | 16 | `0xe00002bc` | 16 | 输出未被驱动改写 |
| `0x96` | 8 | `0x0` | 8 | `00 00 00 00 4B 00 00 00`，偏移 `+4` 的值为十进制 `75` |

`0xe00002bc` 是 `kIOReturnError`，不是 `kIOReturnBadArgument`。目前无法仅凭此错误推断是请求尺寸、内层 payload、驱动 runtime gate 还是 getter 本身不可用；这些 getter 的输入 ABI 仍需从 macOS 15.5 驱动处理路径进一步确认。

`0x96` 的首 dword 为零，不是响应长度；应用旧代码把它当作 `8` 并丢弃成功结果。现已改为验证 8 字节响应、首 dword 为零，再解析偏移 `+4` 的缓存值。值 `75` 是驱动 last-set 软件缓存，不是当前实际功耗、SMU cap 或硬件读回，也不标注单位。

## 当前实施边界

- app 按目标 GFX0 path 发现端点；对排序第一项进行只读调用，并在界面报告匹配到的 endpoint 总数。
- `0x46/0x6d/0x54/0x4f/0x50` 查询仍失败，能力、范围和电压参数没有可信读数。
- 没有执行 `0x47`、`0x51` 或 `0x6e`；没有 GPU 写入或已验证的功耗/电压变化。
- live Registry 显示 `CFG_UUC=01`，而已核对的内置 EFI config 未注入该属性；属性来源尚未确定。

