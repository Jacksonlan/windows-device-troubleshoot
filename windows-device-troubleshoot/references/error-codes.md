# 设备管理器错误码与 NTSTATUS 对照

设备管理器「常规」页显示的代码是十进制；`ProblemStatus` 是十六进制 NTSTATUS。两者不是一回事，混用会误判。

## 常见代码

| 代码 | 常量 | 含义 | 首要排查方向 |
|---|---|---|---|
| 1 | CM_PROB_NOT_CONFIGURED | 未安装驱动 | 安装驱动包 |
| 10 | CM_PROB_FAILED_START | 设备无法启动 | 电源管理、固件状态、驱动与硬件不匹配 |
| 12 | CM_PROB_OUT_OF_MEMORY | 资源不足 | 释放资源、检查内存映射冲突 |
| 18 | CM_PROB_REINSTALL | 需重新安装驱动 | 卸载后重扫硬件 |
| 28 | CM_PROB_FAILED_INSTALL | 驱动未安装 | 检查 INF、安装日志 |
| 31 | CM_PROB_FAILED_ADD | 驱动加载失败（服务创建失败） | 服务键冲突、驱动文件缺失 |
| 32 | CM_PROB_DISABLED | 被禁用（软件） | `Enable-PnpDevice` 或设备管理器启用 |
| 37 | CM_PROB_FAILED_DRIVER_ENTRY | 驱动初始化失败 | 驱动版本/硬件不匹配 |
| 39 | CM_PROB_DRIVER_FAILED_LOAD | 驱动损坏或缺失 | 校验签名与文件完整性 |
| 41 | CM_PROB_DRIVER_FAILED_PRIOR_UNLOAD | 驱动卸载残留 | 重启，必要时清残留服务键 |
| 43 | CM_PROB_DRIVER_FAILED_SLEEP | 驱动报告设备故障 | 断电重置、固件、硬件接触 |
| 45 | CM_PROB_PHANTOM | 设备当前未连接 | 非故障，是未接设备的历史记录 |
| **48** | **CM_PROB_DRIVER_BLOCKED** | **驱动被阻止加载** | **见下节，不要只换驱动** |
| 52 | CM_PROB_UNSIGNED_DRIVER | 驱动签名无法验证 | 签名链、安全启动、WHQL |

## 代码 48 专项

官方定义：驱动被 Windows 驱动程序保护机制阻止，因为它已知有兼容问题。

关键在于区分 `ProblemStatus`：

| ProblemStatus | 含义 | 真实原因 |
|---|---|---|
| `0xC000036B` | STATUS_DRIVER_BLOCKED | 真的在微软阻止列表里（驱动版本被点名） |
| `0xC000036C` | STATUS_DRIVER_BLOCKED_CRITICAL | 严重的已知不兼容驱动 |
| `0xC0000022` | STATUS_ACCESS_DENIED | **不是黑名单问题**。PnP 在「配置设备」阶段就被拒绝，驱动根本还没开始加载 |

遇到 `0xC0000022` 时的排查顺序（每条都要有明确结论，不要跳过）：

1. **变更归因**（优先级最高）
   - `Kernel-Boot` 事件 153：该次启动 VBS 是启用还是关闭
   - 对比故障前后的启动记录，找出状态翻转的那一次
   - 对照最近安装的更新及其**生效时间**（安装 ≠ 生效，累积更新要重启才生效）

2. **是否只有这一个设备**
   ```powershell
   Get-PnpDevice | Where-Object {$_.Status -eq 'Error'} | Select-Object Class, FriendlyName, Problem
   ```
   只有单个设备 → 与该设备绑定的东西有关（驱动、过滤驱动、固件状态）
   多个设备同时报错 → 系统级策略（VBS、WDAC、安全软件）

3. **驱动阻止列表**
   ```powershell
   # 注意：策略文件内字符串是 UTF-16LE，ASCII 扫描会漏
   $u16 = [Text.Encoding]::Unicode.GetString([IO.File]::ReadAllBytes('C:\Windows\System32\CodeIntegrity\driversipolicy.p7b'))
   if ($u16 -match 'Realtek') { '命中' }
   ```
   同时确认开关：
   ```powershell
   Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Config' -Value VulnerableDriverBlocklistEnable
   ```

4. **权限**
   依次检查 `Services\<服务名>`、`Control\Class\{类GUID}\<序号>`、`Enum\<设备实例>` 的 ACL 与属主，并与同类正常设备对照。全部正常就可以彻底排除权限。

5. **代码完整性日志**
   ```powershell
   Get-WinEvent -LogName 'Microsoft-Windows-CodeIntegrity/Operational' -MaxEvents 60 |
     Where-Object { $_.Id -ne 3116 } | Select-Object TimeCreated, Id, Message
   ```
   事件 3084 出现 `WHQL driver enforcement for this boot session` 说明本次启动启用了 WHQL 驱动强制，这通常与 VBS 启用同时发生。
   事件 3099 会列出已激活的策略名，看到 `Virtualization Based Security Policy` 即确认 VBS 策略在生效。

## VBS 相关判断命令

```powershell
# 注册表开关
Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard' |
  Select-Object EnableVirtualizationBasedSecurity, RequireMicrosoftSignedBootChain, WasEnabledBy

# 运行状态（SecurityServicesRunning 含 2 表示内存完整性在运行）
Get-CimInstance -Namespace root\Microsoft\Windows\DeviceGuard -ClassName Win32_DeviceGuard |
  Select-Object VirtualizationBasedSecurityStatus, SecurityServicesRunning, CodeIntegrityPolicyEnforcementStatus

# VBS 启停历史（按日期对比，这是找触发点最有效的手段）
Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='Microsoft-Windows-Kernel-Boot'; Id=153} |
  Select-Object TimeCreated, @{n='VBS';e={ if($_.Message -match 'disabled'){'已关闭'} else {'已启用'} }}
```

`CodeIntegrityPolicyEnforcementStatus = 2` 表示策略处于强制状态；`SecurityServicesRunning = {0}` 表示内存完整性并未真正运行，此时关闭 VBS 不会影响任何在用的虚拟化功能。
