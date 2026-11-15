# 判例：VBS 启用导致网卡驱动被阻止（代码 48）

真实案例，可作为同类问题的诊断模板。

## 故障现象

- 笔记本板载有线网卡 `Realtek PCIe GbE Family Controller`（`PCI\VEN_10EC&DEV_8168`）
- 插上网线毫无反应，`ipconfig` 里根本没有「以太网」这一项
- 设备管理器报 **代码 48**，`ProblemStatus = 0xC0000022`
- 同一台机器的 Wi-Fi 正常上网
- 用户一句话描述：**昨天还能用，今天不行了**

## 无效的排查（共计 4 个驱动版本）

| 尝试 | 结果 |
|---|---|
| 2020 年 OEM 驱动 10.43.723.2020 | 48 |
| 系统自带 `rtcx21x64.inf` 1.0.0.14（2017） | 48 |
| Realtek 官方 2026 年 WHQL 11.031.50（多个 INF 变体） | 48 |

同时排除了：WDAC 策略（ASCII + UTF-16 双编码扫描均无命中）、CodeIntegrity 拦截事件（空白）、`Services`/`Class`/`Enum` 键 ACL 与属主（正常）、设备安装限制策略（未配置）、第三方杀软（仅 Defender）、网络绑定过滤器（Npcap / VMware Bridge）。

**结论：驱动版本不是变量。** 三个不同年代的驱动报同一个错误，说明拦截发生在驱动加载之前。

## 关键转折：从"换什么"转向"变了什么"

用户提供了时间线索"昨天能用今天不行"，由此检查启动日志中的 VBS 状态：

```powershell
Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='Microsoft-Windows-Kernel-Boot'; Id=153} -MaxEvents 20 |
  Select-Object TimeCreated, @{n='VBS';e={ if($_.Message -match 'disabled'){'已关闭'} else {'已启用'} }}
```

结果按日期排列：

| 启动时间 | VBS |
|---|---|
| 11-13 14:04 / 23:34 / 23:35 | 已关闭 |
| **11-14 13:31（故障前一天）** | **已关闭** |
| **11-15 15:46 起（当天每次启动）** | **已启用** |

再对照更新安装记录：

- 11-14 13:33 安装 2026-11 安全更新 KB5132061
- 系统从 11-14 13:31 启动后持续运行 31 小时未重启
- 11-15 15:46 首次重启 → **更新此刻才真正生效，同一刻 VBS 被启用**

> KB 编号以事件日志（`WindowsUpdateClient` 事件 19/43）的记录为准。`Get-CimInstance Win32_QuickFixEngineering` 列出的是当前"存活"的更新，累积更新会被后续版本取代，编号可能对不上，不要据此否定结论。

代码完整性日志印证：

```
Id 3084: Code Integrity will enable WHQL driver enforcement for this boot session.
Id 3099: Refreshed and activated Code Integrity policy
         {a072029f-...} Microsoft Windows Virtualization Based Security Policy
```

`Win32_DeviceGuard.CodeIntegrityPolicyEnforcementStatus = 2`（强制），而 `SecurityServicesRunning = {0}`（内存完整性并未运行）。

## 根因

**累积更新在重启后启用了 VBS**，VBS 激活「WHQL 驱动强制」策略，Realtek 网卡在 PnP「配置设备」阶段被拒绝（`0xC0000022` 拒绝访问），驱动完全没有进入加载流程，因此系统连网络接口都不创建——这就是插线毫无反应、`ipconfig` 看不到网卡的直接原因。

全系统仅此一个设备受影响，所以不是全局策略损坏，而是该设备的驱动不满足新策略。

## 修复

```
reg add "HKLM\SYSTEM\CurrentControlSet\Control\DeviceGuard" /v EnableVirtualizationBasedSecurity /t REG_DWORD /d 0 /f
reg add "HKLM\SYSTEM\CurrentControlSet\Control\DeviceGuard" /v RequireMicrosoftSignedBootChain /t REG_DWORD /d 0 /f
bcdedit /set hypervisorlaunchtype off
```

重启后：

```
网卡状态      = OK（无错误码）
链路          = Up / Connected
IP            = 192.168.2.8
VBS（新启动）= 已关闭
```

回退命令：把两个值改回 `1`，并 `bcdedit /set hypervisorlaunchtype auto`。

## 可直接复用的推理链

1. 设备报错但换驱动无效 → 拦截在驱动之外
2. 用户说"以前能用" → 找故障前后的系统级差异
3. 查 VBS 启停历史（事件 153）→ 找到状态翻转的那次启动
4. 对照更新安装时间与重启时间 → 确认是哪个更新、何时生效
5. 关闭该特性验证 → 恢复即闭环

## 后续维护提醒

Windows 后续更新有可能再次启用 VBS。若同一现象复发，重跑关闭脚本即可。该机器的 `SecurityServicesRunning` 为空，说明没有组件依赖 VBS，关闭无副作用；若用户使用 WSL2、Hyper-V 或 Windows 沙盒，关闭前需说明影响。

## 附带发现

`C:\Windows\System32\CodeIntegrity\driversipolicy.p7b` 内含 `Realtek Semiconductor Corp.` 签名条目。该文件字符串为 UTF-16LE，用 ASCII 正则扫描不会命中——排查驱动黑名单时必须双编码解码，否则会得出"黑名单里没有该厂商"的错误结论。
