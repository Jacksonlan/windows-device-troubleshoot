---
name: windows-device-troubleshoot
description: 诊断 Windows 设备管理器中"设备无法启动/被阻止"类故障，覆盖网卡、无线网卡、声卡、蓝牙、USB 控制器等设备报代码 10/12/28/31/39/43/48/52 或黄色感叹号、插网线无反应、驱动反复重装无效的场景。当用户提到设备管理器有感叹号、网卡不能用、插网线没反应、代码 48、驱动被阻止、重装驱动还是不行、昨天能用今天不行时使用。核心方法是先做变更归因（对比故障前后 VBS、Windows 更新、快速启动等系统级开关的差异），再逐层排除，避免无效地反复更换驱动。
agent_created: true
---

# Windows 设备故障诊断

## 核心原则

1. **不要先换驱动。** 同一设备换 3 个以上驱动版本仍报同一错误码时，问题一定不在驱动本身。继续换是浪费时间。
2. **先判断设备"是否启动"。** 设备没启动时，系统连网络接口都不会创建——`ipconfig` 里看不到该适配器、插线没有任何反应、网口灯不亮，这些现象都是"设备未启动"的结果，不是原因。
3. **追溯变更。** "昨天能用今天不行"是最有价值的线索。设备故障几乎总有触发点：一次更新、一次重启、一个安全特性开关。找到那个点，问题就解了。
4. **验证用户是否真的执行了。** 用户说"还是不行"时，先读状态（注册表值、驱动绑定、日志时间戳）确认操作生效，再决定下一步。重复给同一方案是无效沟通。

## 适用场景与目标问题

### 系统范围

| 范围 | 说明 |
|---|---|
| Windows 11 | 全版本适用（21H2 ~ 26H2，含 26300 系列） |
| Windows 10 | 1903 及以上（VBS / WDAC 相关判断在此版本后有效） |
| Windows Server | 2019 / 2022 部分适用，无内核隔离界面时按注册表判断 |
| 运行环境 | 需要 PowerShell 5.1+（系统自带），部分查询需管理员权限 |
| 不适用 | Windows 7 / 8.1；macOS / Linux；需要拆机换件的纯硬件故障 |

### 覆盖的设备类型

有线网卡、无线网卡、蓝牙、声卡、USB 控制器与集线器、显卡、摄像头、HID 输入设备、打印机端口、其他 PCIe 设备。

### 覆盖的错误码

10 / 12 / 18 / 28 / 31 / 37 / 39 / 41 / 43 / 45 / 48 / 52，逐个含义与处置见 `references/error-codes.md`。

其中 **43 和 48 是本技能的重点**——这两个最容易被误判成「驱动坏了」，实际上多数是策略层、权限层或固件状态的问题，换驱动不可能解决。

### 六层排查模型

设备报错只是表象，真正的原因落在以下六层之一。判断落在哪一层，比急着动手更重要。

| 层 | 典型表现 | 判据 |
|---|---|---|
| 驱动层 | 驱动版本旧、签名无效、INF 损坏 | 换新版后错误码变化 |
| 策略层 | VBS / 内核隔离、WDAC、驱动阻止列表、Smart App Control、设备安装限制 | 换任何驱动都报同一码，且多个设备同时异常 |
| 权限层 | 注册表 ACL、DriverStore 权限、服务键属主异常 | 同类正常设备的键权限与之不同 |
| 冲突层 | 过滤器驱动、虚拟网卡、杀软、反作弊驱动 | 安全模式下恢复正常 |
| 资源层 | 电源管理、PCIe 配置空间状态、固件残留 | 断电重置后恢复 |
| 硬件层 | 接口接触、供电、PHY 芯片 | 网口灯不亮、断电重置无效、安全模式仍报错 |

### 用户常见表述（触发语）

「插网线没反应」「设备管理器有黄色感叹号」「代码 48 / 43」「驱动装了好几遍还是不行」「昨天还能用今天不行了」「Wi-Fi 能上网但网线不行」「网卡灯不亮」「设备被阻止」。

完整的问题矩阵（现象 → 成因 → 处置）见 `references/supported-issues.md`。

## 工作流

### 第 1 步：一次采集全部事实

运行诊断脚本，不要零散地一条条查：

```powershell
powershell -ExecutionPolicy Bypass -File "<skill_dir>/scripts/diag-device.ps1"
```

指定设备（更精确）：

```powershell
powershell -ExecutionPolicy Bypass -File "<skill_dir>/scripts/diag-device.ps1" -InstanceId "PCI\VEN_10EC&DEV_8168&SUBSYS_11001D05&REV_15\01000000684CE00000"
```

脚本输出七块内容：设备清单与错误码、目标设备驱动详情、网络链路与 IP、VBS/内核隔离状态、VBS 启停历史、代码完整性事件、最近系统更新。

若脚本无法运行（执行策略或权限限制），按 `references/diagnostic-playbook.md` 手动逐条执行，该文件列出每条命令及其判读标准。

### 第 2 步：三问分诊

| 问题 | 判据 | 含义 |
|---|---|---|
| 设备启动了吗 | `Status` 是否 `OK`；适配器是否出现在 `Get-NetAdapter` | 未启动 → 所有上层现象都是结果 |
| 错误码是什么 | `Problem` + `ProblemStatus`（十六进制） | 决定走哪条排查路径 |
| 什么时候开始坏的 | 故障事件时间 vs 更新时间 vs 启动时间 | 决定是否走变更归因 |

错误码含义与对应处置见 `references/error-codes.md`。

### 第 3 步：识别"变更归因"场景

满足下列任意两条，直接跳到 `references/case-vbs-driver-block.md` 的检查清单，不要继续在驱动层打转：

- 用户明确说"之前能用"
- 换了 3 个以上驱动版本，错误码完全不变
- 同一类设备里其他设备正常（排除整类注册表损坏）
- 驱动黑名单、ACL、第三方杀软都查不出问题
- `ProblemStatus` 是 `0xC0000022`（拒绝访问）而不是 `0xC000036B`（完整性阻止）

该案例覆盖的完整链条：**2026-11 安全更新在重启后启用 VBS → 激活 WHQL 驱动强制 → Realtek 网卡被拒 → 代码 48**。判断依据是启动日志事件 153 的 VBS 状态按日期对比。

### 第 4 步：按类修复

| 场景 | 处置 | 可回退 |
|---|---|---|
| VBS/内核隔离拦截 | 运行 `scripts/fix-disable-vbs.cmd`，重启 | 是，`scripts/undo-vbs.cmd` |
| 驱动版本过旧或被吊销 | 装厂商最新版，用 `pnputil /add-driver x.inf /install` | 是 |
| 注册表配置损坏 | 移除设备节点后重扫硬件 | 是，系统会重建 |
| 过滤器驱动冲突 | 在安全模式验证，再逐个解绑 | 是 |
| 权限/ACL 异常 | 对照同类正常设备的键权限 | 需先备份 |
| 硬件或固件层 | 断电重置 → 安全模式验证 → 联系售后 | — |

在给出任何修改启动配置或注册表的方案前，**先确认 BitLocker 状态**。`manage-bde -status` 需要管理员权限，非管理员会报"拒绝访问"，此时要明确告知用户去系统设置里确认，不能默认它是关闭的。

### 第 5 步：验证闭环

修复后读取真实状态，不要只问用户"好了吗"：

```powershell
Get-PnpDevice -Class Net | Where-Object {$_.Problem -ne 'CM_PROB_NONE'} | Select-Object FriendlyName, Problem
Get-NetAdapter | Select-Object Name, Status, LinkSpeed
```

链路速度为 100 Mbps 而网卡是千兆时，提示换六类线或换路由器千兆口，而不是当成故障。

## 交付脚本时的硬性规范

这几条是实战中反复踩到的坑，直接决定用户能不能跑通：

1. **`.cmd` / `.bat` 必须用纯 ASCII，或严格使用 GBK 编码 + CRLF 换行。**
   UTF-8 中文的批处理会被 cmd 按 GBK 解析，乱码字节被当成命令执行，报一串"不是内部或外部命令"。最稳的做法是消息用简短英文，由对话里的中文解释承担说明职责。
   ```bash
   iconv -f UTF-8 -t GBK src.txt | sed 's/$/\r/' > out.cmd
   ```
2. **`.ps1` 在 Windows PowerShell 5.1 下默认按 GBK 读取。** 含中文时文件必须带 UTF-8 BOM，否则中文变乱码。无 BOM 时改用英文输出。
3. **不要假设脚本能双击运行。** 先查 `Get-ExecutionPolicy -List`，全为 `Undefined` 意味着默认 `Restricted`，`.ps1` 会被拒绝执行。此时改用 `.cmd`，或在命令行里带 `-ExecutionPolicy Bypass`。
4. **需要管理员权限的脚本要自提权**，否则用户双击后静默失败，只看到窗口一闪而过：
   ```bat
   net session >nul 2>&1
   if errorlevel 1 (
       powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
       exit /b
   )
   ```
5. **修改前先备份**：`reg export "<key>" "%USERPROFILE%\Desktop\backup.reg" /y`，并在回复里告诉用户备份位置和还原方法。
6. **避免在批处理里用 `for /f` 解析中文输出**，编码问题会让整段命令连同后面的语句一起崩掉。

## 排查技巧备忘

- `driversipolicy.p7b`、`.cip` 等代码完整性策略文件内的字符串是 **UTF-16LE**。用 ASCII 正则扫描会漏检，必须双编码解码：
  ```powershell
  $u16 = [Text.Encoding]::Unicode.GetString([IO.File]::ReadAllBytes($path))
  ```
- 设备管理器里的代码是十进制，`ProblemStatus` 是十六进制 NTSTATUS。两者含义不同，不要混为一谈（代码 48 对应 `0xC000036B`，而 `0xC0000022` 是"拒绝访问"，指向另一类原因）。
- 判断故障首次发生时间：`Microsoft-Windows-Kernel-PnP/Configuration` 事件 411，按日期分组统计。
- 判断上次是否真的重启过、以及是否进了安全模式：`Win32_OperatingSystem.LastBootUpTime` + `Microsoft-Windows-Kernel-Boot` 事件 20/21/26/27。
- 用户长期不执行操作时，改为给**单步、零命令行**的动作（图形界面点几下），而不是继续产出新脚本。

## Resources

- `scripts/diag-device.ps1`：一次性采集全部诊断事实，输出分块报告
- `scripts/fix-disable-vbs.cmd`：关闭 VBS / WHQL 驱动强制，自提权，含 BitLocker 提醒
- `scripts/undo-vbs.cmd`：还原 VBS 设置的配套脚本
- `references/error-codes.md`：设备管理器错误码与 NTSTATUS 对照表
- `references/supported-issues.md`：支持的问题矩阵（现象 / 错误码 / 成因层 / 处置 / 非目标）
- `references/diagnostic-playbook.md`：逐步命令清单与判读标准
- `references/case-vbs-driver-block.md`：VBS 启用导致驱动被阻止的完整判例
