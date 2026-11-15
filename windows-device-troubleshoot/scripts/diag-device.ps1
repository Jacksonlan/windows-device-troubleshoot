#requires -Version 5.1
<#
.SYNOPSIS
    Windows 设备故障诊断：一次性采集设备错误码、驱动、链路、VBS 状态与变更历史。

.DESCRIPTION
    用于诊断设备管理器中"设备无法启动/被阻止"类故障。输出分节报告，
    并在末尾给出判定建议。只读操作，不修改系统。

.PARAMETER InstanceId
    目标设备的实例 ID。省略时自动选择第一个处于错误状态的设备。

.PARAMETER Class
    设备类名（如 Net、Display、Bluetooth）。与 InstanceId 二选一。

.PARAMETER OutputPath
    可选，把报告同时写入指定文本文件。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File diag-device.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File diag-device.ps1 -InstanceId "PCI\VEN_10EC&DEV_8168&SUBSYS_11001D05&REV_15\01000000684CE00000"
#>
[CmdletBinding()]
param(
    [string]$InstanceId,
    [string]$Class,
    [string]$OutputPath
)

$ErrorActionPreference = 'SilentlyContinue'
$script:lines = New-Object System.Collections.Generic.List[string]

function Out-Line {
    param([string]$Text = '')
    $script:lines.Add($Text)
    [Console]::WriteLine($Text)
}

function Out-Head {
    param([string]$Title)
    Out-Line ''
    Out-Line ('===== ' + $Title + ' ' + ('=' * [Math]::Max(0, 54 - $Title.Length)))
}

Out-Line '=============== Windows 设备故障诊断报告 ==============='
Out-Line ('生成时间 : ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))

$os = Get-CimInstance Win32_OperatingSystem
if ($os) {
    Out-Line ('系统版本 : ' + $os.Caption + ' ' + $os.Version)
    Out-Line ('上次启动 : ' + $os.LastBootUpTime + '   已运行 ' + [string]((Get-Date) - $os.LastBootUpTime))
}
$cs = Get-CimInstance Win32_ComputerSystem
if ($cs) { Out-Line ('机型     : ' + $cs.Manufacturer + ' ' + $cs.Model) }

$ident = [Security.Principal.WindowsIdentity]::GetCurrent()
$prin = New-Object Security.Principal.WindowsPrincipal($ident)
$isAdmin = $prin.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
Out-Line ('管理员   : ' + $isAdmin + '  (为 False 时部分查询会受限)')

# ---------- 1. 处于错误状态的设备 ----------
Out-Head '1. 处于错误状态的设备'
$errDevices = @(Get-PnpDevice | Where-Object { $_.Status -eq 'Error' })
if ($errDevices.Count -eq 0) {
    Out-Line '没有处于错误状态的设备。'
} else {
    Out-Line ('共 ' + $errDevices.Count + ' 个：')
    $errDevices | ForEach-Object {
        Out-Line ('  [' + $_.Class + '] ' + $_.FriendlyName + '  ->  ' + $_.Problem)
        Out-Line ('      ' + $_.InstanceId)
    }
    if ($errDevices.Count -eq 1) {
        Out-Line '提示：只有单个设备报错 -> 问题与该设备的驱动、过滤器或固件状态相关'
    } else {
        Out-Line '提示：多个设备同时报错 -> 考虑系统级策略（VBS / WDAC / 安全软件）'
    }
}

# ---------- 2. 目标设备详情 ----------
Out-Head '2. 目标设备详情'
$targetId = $InstanceId
if (-not $targetId) {
    if ($errDevices.Count -gt 0) {
        $targetId = $errDevices[0].InstanceId
    } elseif ($Class) {
        $first = Get-PnpDevice -Class $Class | Select-Object -First 1
        if ($first) { $targetId = $first.InstanceId }
    }
}

if (-not $targetId) {
    Out-Line '未指定设备，也没有找到错误设备，跳过。'
} else {
    $dev = Get-PnpDevice -InstanceId $targetId
    if ($dev) {
        Out-Line ('名称   : ' + $dev.FriendlyName)
        Out-Line ('类     : ' + $dev.Class)
        Out-Line ('状态   : ' + $dev.Status + '   ' + $dev.Problem)
    }
    Out-Line ('实例ID : ' + $targetId)

    $keys = @(
        'DEVPKEY_Device_DriverInfPath',
        'DEVPKEY_Device_DriverVersion',
        'DEVPKEY_Device_DriverDate',
        'DEVPKEY_Device_DriverProvider',
        'DEVPKEY_Device_Service',
        'DEVPKEY_Device_ProblemCode',
        'DEVPKEY_Device_ProblemStatus'
    )
    foreach ($k in $keys) {
        $p = Get-PnpDeviceProperty -InstanceId $targetId -KeyName $k
        $val = ''
        if ($p) { $val = [string]$p.Data }
        if ($k -eq 'DEVPKEY_Device_ProblemStatus' -and $val) {
            [uint32]$num = 0
            if ([uint32]::TryParse($val, [ref]$num)) {
                $val = $val + '  (0x' + ([Convert]::ToString($num, 16).ToUpper().PadLeft(8, '0')) + ')'
            }
        }
        Out-Line ('  ' + $k.PadRight(34) + '= ' + $val)
    }
    Out-Line '  NTSTATUS 对照: 0xC000036B=完整性阻止  0xC0000022=拒绝访问  0xC000036C=严重不兼容'
}

# ---------- 3. 网络链路 ----------
Out-Head '3. 网络适配器与 IP'
$adapters = @(Get-NetAdapter)
if ($adapters.Count -eq 0) {
    Out-Line 'Get-NetAdapter 无返回。'
} else {
    foreach ($a in $adapters) {
        Out-Line ('  ' + $a.Name + '  |  ' + $a.Status + '  |  ' + $a.LinkSpeed + '  |  ' + $a.MediaConnectionState)
    }
}
$ips = @(Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notlike '127.*' })
foreach ($ip in $ips) {
    Out-Line ('  IP: ' + $ip.InterfaceAlias + '  |  ' + $ip.IPAddress + '/' + $ip.PrefixLength + '  |  ' + $ip.PrefixOrigin)
}
if ($targetId -and $dev -and $dev.Class -eq 'Net') {
    $found = $adapters | Where-Object { $_.InterfaceDescription -and $dev.FriendlyName -and $_.InterfaceDescription -eq $dev.FriendlyName }
    if (-not $found) {
        Out-Line '提示：目标网卡没有出现在适配器列表中 -> 设备未启动，系统未创建网络接口'
    }
}

# ---------- 4. VBS / 内核隔离 ----------
Out-Head '4. VBS 与内核隔离状态'
$dg = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard'
if ($dg) {
    Out-Line ('EnableVirtualizationBasedSecurity = ' + $dg.EnableVirtualizationBasedSecurity)
    Out-Line ('RequireMicrosoftSignedBootChain     = ' + $dg.RequireMicrosoftSignedBootChain)
    Out-Line ('WasEnabledBy                        = ' + $dg.WasEnabledBy)
}
$ciCfg = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Config'
if ($ciCfg) { Out-Line ('VulnerableDriverBlocklistEnable     = ' + $ciCfg.VulnerableDriverBlocklistEnable) }

$winDG = Get-CimInstance -Namespace root\Microsoft\Windows\DeviceGuard -ClassName Win32_DeviceGuard
if ($winDG) {
    Out-Line ('VirtualizationBasedSecurityStatus   = ' + $winDG.VirtualizationBasedSecurityStatus + '  (2=运行中)')
    $svc = ''
    if ($winDG.SecurityServicesRunning) { $svc = ($winDG.SecurityServicesRunning -join ',') }
    Out-Line ('SecurityServicesRunning             = {' + $svc + '}  (2=内存完整性在运行)')
    Out-Line ('CodeIntegrityPolicyEnforcementStatus= ' + $winDG.CodeIntegrityPolicyEnforcementStatus + '  (2=强制)')
}

# ---------- 5. VBS 启停历史 ----------
Out-Head '5. VBS 启停历史（找故障触发点最有效）'
$boots = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Kernel-Boot'; Id = 153 } -MaxEvents 15)
if ($boots.Count -eq 0) {
    Out-Line '无事件 153 记录。'
} else {
    foreach ($b in $boots) {
        $state = '未知'
        if ($b.Message -match 'disabled') { $state = '已关闭' }
        elseif ($b.Message -match 'enabled') { $state = '已启用' }
        Out-Line ('  ' + $b.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss') + '   VBS ' + $state)
    }
    Out-Line '判读：若某次启动后 VBS 由关闭变为启用，且设备故障自该时点开始，即为强关联。'
}

# ---------- 6. 代码完整性事件 ----------
Out-Head '6. 代码完整性事件（近 24 小时）'
$ci = @(Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-CodeIntegrity/Operational'; StartTime = (Get-Date).AddDays(-1) } |
        Where-Object { $_.Id -ne 3116 })
if ($ci.Count -eq 0) {
    Out-Line '无事件（3116 为无关注释）。说明拦截不在签名/完整性层。'
} else {
    $ci | Select-Object -First 8 | ForEach-Object {
        $msg = ($_.Message -replace "`r`n", ' ')
        if ($msg.Length -gt 150) { $msg = $msg.Substring(0, 150) }
        Out-Line ('  ' + $_.TimeCreated.ToString('HH:mm:ss') + '  Id=' + $_.Id + '  ' + $msg)
    }
    Out-Line '判读：3084=本次启动启用 WHQL 驱动强制；3099 出现 Virtualization Based Security Policy 表示 VBS 策略生效。'
}

# ---------- 7. 最近更新 ----------
Out-Head '7. 最近安装的更新'
$hf = @(Get-CimInstance Win32_QuickFixEngineering | Sort-Object InstalledOn -Descending | Select-Object -First 8)
foreach ($h in $hf) {
    Out-Line ('  ' + [string]$h.InstalledOn + '   ' + $h.HotFixID + '   ' + $h.Description)
}
Out-Line '注意：累积更新"安装完成"不等于"已生效"，要重启后才应用。'

# ---------- 8. 判定建议 ----------
Out-Head '8. 判定建议'
$verdict = @()
$blocked = $errDevices | Where-Object {
    $ps = Get-PnpDeviceProperty -InstanceId $_.InstanceId -KeyName 'DEVPKEY_Device_ProblemStatus'
    $ps -and ([string]$ps.Data) -eq '3221225506'
}
if ($blocked) {
    $verdict += '存在 ProblemStatus=0xC0000022（拒绝访问）的代码 48 设备：这不是驱动黑名单问题，PnP 在配置设备阶段即被拒绝，驱动未进入加载流程。'
}
if ($dg -and $dg.EnableVirtualizationBasedSecurity -eq 1) {
    $verdict += 'VBS 当前为启用状态。若设备故障与 VBS 启用发生在同一次启动，可执行 scripts/fix-disable-vbs.cmd 验证（重启生效，可回退）。'
}
if ($errDevices.Count -eq 0) {
    $verdict += '当前没有错误设备，若用户仍报故障，需要复核用户描述的具体现象。'
}
if ($ci.Count -eq 0 -and $errDevices.Count -eq 1) {
    $verdict += '单个设备报错且无完整性事件：优先考虑过滤器驱动冲突、设备固件状态、或者该设备专属的驱动配置损坏。'
}
$verdict += '下一步：若设备"以前能用现在不能"，务必对比第 5 节的 VBS 启停历史与第 7 节的更新安装时间，定位故障触发点。'
foreach ($v in $verdict) { Out-Line ('  - ' + $v) }

Out-Line ''
Out-Line '==================== 报告结束 ===================='

if ($OutputPath) {
    $script:lines | Set-Content -Path $OutputPath -Encoding UTF8
    Write-Host ('报告已保存: ' + $OutputPath)
}
