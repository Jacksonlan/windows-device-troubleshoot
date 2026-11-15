# 诊断命令清单与判读标准

脚本不可用时按顺序手工执行。每条命令后面标注了「看到什么 → 说明什么」。

## 一、设备事实

```powershell
Get-PnpDevice -ErrorAction SilentlyContinue |
  Where-Object {$_.Status -eq 'Error'} |
  Select-Object Class, FriendlyName, Problem, InstanceId | Format-Table -AutoSize -Wrap
```
- 只有一条 → 单设备问题，重点查该设备的驱动与绑定
- 多条同类设备 → 系统级策略
- 多条跨类设备 → 全局策略或安全软件

```powershell
$d = Get-PnpDevice -Class Net | Where-Object {$_.InstanceId -like 'PCI\VEN_10EC&DEV_8168*'}
foreach($p in 'DEVPKEY_Device_DriverInfPath','DEVPKEY_Device_DriverVersion',
              'DEVPKEY_Device_DriverDate','DEVPKEY_Device_Service',
              'DEVPKEY_Device_ProblemCode','DEVPKEY_Device_ProblemStatus'){
  $v = Get-PnpDeviceProperty -InstanceId $d.InstanceId -KeyName $p -ErrorAction SilentlyContinue
  "{0,-32} = {1}" -f $p, $v.Data
}
```
- `ProblemStatus` 转十六进制看：`[Convert]::ToString(3221225506,16)` → `C0000022`
- 驱动版本很新但错误不变 → 问题不在驱动

## 二、链路与接口

```powershell
Get-NetAdapter | Select-Object Name, Status, LinkSpeed, MediaConnectionState, MacAddress
Get-NetIPAddress -AddressFamily IPv4 | Select-Object InterfaceAlias, IPAddress, PrefixOrigin
```
- 适配器列表里没有该网卡 → 设备未启动，系统未创建接口
- `Status = Up` 但 `LinkSpeed = 100Mbps` 而网卡是千兆 → 线材或对端口问题，不是驱动故障

## 三、故障起始时间

```powershell
Get-WinEvent -FilterHashtable @{LogName='Microsoft-Windows-Kernel-PnP/Configuration'; Id=411} -ErrorAction SilentlyContinue |
  Where-Object {$_.Message -match '8168'} |
  Group-Object {$_.TimeCreated.ToString('yyyy-MM-dd')} |
  Sort-Object Name | Select-Object Count, Name
```
- 事件只集中在某一天 → 那天有触发动作
- 事件 411 的正文会写明「问题: 0x30 / 问题状态: 0xC0000022」，即代码 48 + 拒绝访问

## 四、变更归因（最关键）

```powershell
# 1) VBS 启停历史，按启动次数对比
Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='Microsoft-Windows-Kernel-Boot'; Id=153} -MaxEvents 12 |
  Select-Object TimeCreated, @{n='VBS';e={ if($_.Message -match 'disabled'){'已关闭'} else {'已启用'} }}

# 2) 最近安装的更新及时间
Get-CimInstance Win32_QuickFixEngineering | Sort-Object InstalledOn -Descending |
  Select-Object -First 10 HotFixID, InstalledOn

# 3) 更新安装事件（能看出是安装时间还是生效时间）
Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='Microsoft-Windows-WindowsUpdateClient'; StartTime=(Get-Date).AddDays(-5)} |
  Where-Object {$_.Id -in 19,43} | Select-Object TimeCreated, Id, @{n='M';e={($_.Message -split "`r`n")[0]}} | Format-Table -Wrap

# 4) 开机次数与安全模式判断
Get-CimInstance Win32_OperatingSystem | Select-Object LastBootUpTime
Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='Microsoft-Windows-Kernel-Boot'} -MaxEvents 20 |
  Where-Object {$_.Id -in 20,21,26,27,153} | Select-Object TimeCreated, Id
```
判读要点：**累积更新安装完成 ≠ 生效**。装完不重启，系统仍按旧配置运行；直到重启，新驱动的策略（如 VBS）才开始生效。这正是「昨天能用、今天不行」的典型成因。

## 五、代码完整性

```powershell
Get-WinEvent -FilterHashtable @{LogName='Microsoft-Windows-CodeIntegrity/Operational'; StartTime=(Get-Date).AddDays(-1)} -ErrorAction SilentlyContinue |
  Where-Object {$_.Id -ne 3116} | Select-Object TimeCreated, Id, Message | Format-List
```
- 3084 → 本次启动启用了 WHQL 驱动强制
- 3099 → 列出已激活策略，出现 `Virtualization Based Security Policy` 即 VBS 在生效
- 完全没有事件 → 拦截不在签名层，转向权限与硬件

## 六、权限对照

```powershell
# 与同类正常设备对照，两个键结构应基本一致
$base='HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e972-e325-11ce-bfc1-08002be10318}'
Get-ChildItem $base | ForEach-Object {
  $p = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
  "{0} : {1} : {2}" -f $_.PSChildName, $p.DriverDesc, $p.InfPath
}
(Get-Acl "$base\0003").Access | Select-Object IdentityReference, RegistryRights
(Get-Acl 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard').Owner
```
- 故障设备与正常设备的键权限不同 → 权限问题
- 完全一致 → 排除权限，不要在这上面继续花时间

## 七、安全模式验证（决定性）

安全模式会禁用 VBS 与绝大多数第三方驱动。进去后看同一设备：

| 安全模式表现 | 结论 |
|---|---|
| 不再报错 | 第三方驱动、过滤器或 VBS 冲突 → 逐个解绑定位 |
| 仍然报错 | 系统层或硬件层 → 断电重置、BIOS、售后 |

进入方式：按住 Shift 点开始菜单「重启」→ 疑难解答 → 高级选项 → 启动设置 → 重启 → 按 4。不要指望用户改 `msconfig`，步骤太多容易走偏。

## 八、断电重置（笔记本特有）

关机 → 拔电源适配器 → 长按电源键 30 秒 → 插回开机。清掉 PCIe 设备与电源管理的残留状态，可解决一批「设备在但拒绝启动」的情况，零风险。
