# Windows 设备故障诊断技能

> 一个给 AI 助手用的技能包：诊断 Windows「设备管理器报错、驱动装了还是不行」这类疑难故障。
> 核心不是教你换驱动，而是教你**找变更**——大多数查不出的设备故障，都源于某次重启后才生效的系统级开关。

[![Windows](https://img.shields.io/badge/Windows-10%201903%2B%20%7C%2011-0078D4)](https://www.microsoft.com/windows)
[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE)](https://microsoft.com/powershell)
[![License](https://img.shields.io/badge/License-MIT-green)](LICENSE)

---

## 为什么做这个

真实案例：一台笔记本的板载网卡突然不能用了，设备管理器报 **代码 48（驱动被阻止）**。插上网线毫无反应，`ipconfig` 里连「以太网」这一项都没有。

前后换了 **4 个不同年代的驱动**（2015 / 2017 / 2020 / 2026 全新建签 WHQL 版），每次都报同一个错误码。网上能搜到的方案——重装驱动、卸载设备、网络重置、`sfc`、`DISM`、改注册表权限——全部无效。

真正的原因，是安装了一个安全更新后**系统在重启时启用了 VBS（基于虚拟化的安全）**，VBS 激活了 WHQL 驱动强制策略，Realtek 网卡在系统「配置设备」阶段就被拒绝，驱动根本没有进入加载流程。

判断依据只有一处：开机日志里 VBS 的状态，在某个时间点从「已关闭」变成了「已启用」，而那个时间点正好是故障开始的时间。

**这个技能就是把这条推理链固化下来**，让 AI 助手遇到同类问题时，先做变更归因，而不是陪着用户一起换驱动。

---

## 覆盖哪些系统问题

### 系统范围

| 范围 | 说明 |
|---|---|
| Windows 11 | 全版本（21H2 ~ 26H2，含 26300 系列） |
| Windows 10 | 1903 及以上 |
| Windows Server | 2019 / 2022 部分适用 |
| 运行环境 | PowerShell 5.1+（系统自带）；部分查询需管理员权限 |
| 不适用 | Windows 7 / 8.1、macOS、Linux、需要拆机换件的硬件损坏 |

### 设备类型

有线网卡、无线网卡、蓝牙、声卡、USB 控制器与集线器、显卡、摄像头、HID 输入设备、打印机端口、其他 PCIe 设备。

### 错误码

`10` `12` `18` `28` `31` `37` `39` `41` `43` `45` `48` `52`

其中 **43 和 48 是重点**——这两个最容易被误判成「驱动坏了」，实际多数是策略层、权限层或固件状态的问题，换驱动不可能解决。

### 典型现象

| 现象 | 说明 |
|---|---|
| 插网线毫无反应 | 设备未启动，系统连网络接口都没有创建 |
| 设备管理器黄色感叹号 | 需要看 `Problem` + `ProblemStatus` 才能定位 |
| 驱动装了好几遍，错误码不变 | 拦截发生在驱动加载之前 |
| 昨天能用，今天不行 | 最值钱的线索，指向某次重启后生效的变更 |
| Wi-Fi 能上，网线不行 | 两块独立硬件，问题只在线卡侧 |
| 网口灯完全不亮 | 物理层未工作，软件无解 |

更多组合见 [`references/supported-issues.md`](windows-device-troubleshoot/references/supported-issues.md)。

---

## 安装

技能本质是一个目录，放到 WorkBuddy 的技能目录即可。

**方式一：克隆后复制**

```bash
git clone https://github.com/<your-name>/windows-device-troubleshoot.git
cp -r windows-device-troubleshoot/windows-device-troubleshoot ~/.workbuddy/skills/
```

**方式二：直接拷贝目录**

把仓库里的 `windows-device-troubleshoot/` 整个文件夹放进 `~/.workbuddy/skills/`，重启客户端，在「设置 → 技能」里确认已启用。

**验证安装**

```powershell
powershell -ExecutionPolicy Bypass -File "$HOME\.workbuddy\skills\windows-device-troubleshoot\scripts\diag-device.ps1"
```

能输出八节诊断报告就说明装好了。

---

## 使用

### 交给 AI 助手（推荐）

装好之后直接描述现象即可，技能会自动触发：

- 「我插了网线但是显示没有有线网络」
- 「设备管理器里网卡报代码 48，驱动重装了好几次都没用」
- 「昨天还能用今天突然不行了」
- 「Wi-Fi 正常但网线不通，网口灯也不亮」

### 直接跑诊断脚本

只读操作，不修改任何系统设置：

```powershell
# 自动选中第一个报错的设备
powershell -ExecutionPolicy Bypass -File diag-device.ps1

# 指定设备
powershell -ExecutionPolicy Bypass -File diag-device.ps1 `
  -InstanceId "PCI\VEN_10EC&DEV_8168&SUBSYS_11001D05&REV_15\01000000684CE00000"

# 报告同时存文件
powershell -ExecutionPolicy Bypass -File diag-device.ps1 -OutputPath .\report.txt
```

报告包含八节：错误设备清单、目标设备详情、网络适配器与 IP、VBS 与内核隔离状态、**VBS 启停历史**、代码完整性事件、最近安装的更新、判定建议。

其中「VBS 启停历史」是最有价值的一节——按启动时间列出每次开机时 VBS 是启用还是关闭，一眼就能看出故障是从哪次启动开始的。

### 修复脚本

`scripts/fix-disable-vbs.cmd` 用于关闭 VBS / WHQL 驱动强制，**自提权、先备份、可回退**：

- 自动请求管理员权限
- 修改前把注册表导出到桌面 `vbs-backup.reg`
- 提示 BitLocker 风险
- 配套 `undo-vbs.cmd` 一键还原

> ⚠️ 如果 C 盘启用了 BitLocker，修改启动配置后可能要求输入恢复密钥。执行前请先确认手上有密钥。
> ⚠️ 如果你在用 WSL2、Hyper-V、Windows 沙盒或 Docker Desktop，关闭 VBS 会影响它们，请自行权衡。

---

## 目录结构

```
windows-device-troubleshoot/
├── SKILL.md                          # 技能主体：核心原则、六层模型、五步工作流
├── references/
│   ├── error-codes.md                # 错误码 1~52 对照 + 代码 48 专项
│   ├── supported-issues.md           # 问题矩阵：现象 / 错误码 / 成因层 / 非目标
│   ├── diagnostic-playbook.md        # 逐条命令与判读标准
│   └── case-vbs-driver-block.md      # 真实判例：更新启用 VBS 导致网卡被拒
└── scripts/
    ├── diag-device.ps1               # 一键只读诊断，八节报告
    ├── fix-disable-vbs.cmd           # 关闭 VBS，自提权 + 备份
    └── undo-vbs.cmd                  # 还原 VBS 设置
```

---

## 方法论速览

### 六层排查模型

设备报错只是表象，原因落在六层之一。判断落在哪一层，比急着动手更重要。

| 层 | 典型表现 | 判据 |
|---|---|---|
| 驱动层 | 版本旧、签名无效、INF 损坏 | 换新版后错误码变化 |
| 策略层 | VBS、WDAC、驱动阻止列表、Smart App Control | 换任何驱动都报同一码 |
| 权限层 | 注册表 ACL、DriverStore 权限 | 与同类正常设备权限不同 |
| 冲突层 | 抓包驱动、虚拟网卡、杀软、反作弊 | 安全模式下恢复正常 |
| 资源层 | 电源管理、PCIe 状态、固件残留 | 断电重置后恢复 |
| 硬件层 | 接触、供电、PHY 芯片 | 灯不亮 + 断电重置无效 |

### 五步工作流

1. **一次采集事实** —— 跑 `diag-device.ps1`，别零散地一条条查
2. **三问分诊** —— 设备启动了吗？错误码是什么？什么时候开始坏的？
3. **识别变更归因场景** —— 满足条件就别在驱动层打转
4. **按类修复** —— 每层有对应动作，且都能回退
5. **验证闭环** —— 读真实状态，不是问用户「好了吗」

### 代码 48 的关键分辨

| `ProblemStatus` | 含义 | 真实原因 |
|---|---|---|
| `0xC000036B` | 完整性阻止 | 真在微软驱动阻止列表里 |
| `0xC0000022` | **拒绝访问** | PnP 配置阶段就被拒，驱动**没有**进入加载流程 |

后者换驱动 100% 无效。这是本技能最有价值的一条判断。

---

## 实战踩坑记录

写 Windows 排障脚本时会反复踩到这几条，都固化进技能里了：

1. **`.cmd` / `.bat` 必须用纯 ASCII，或严格使用 GBK 编码 + CRLF。** UTF-8 中文的批处理会被 cmd 按 GBK 解析，乱码字节被当成命令执行，报一串「不是内部或外部命令」。最稳的做法是脚本消息用英文，中文解释放在对话里。
   ```bash
   iconv -f UTF-8 -t GBK src.txt | sed 's/$/\r/' > out.cmd
   ```
2. **`.ps1` 在 Windows PowerShell 5.1 下默认按 GBK 读取。** 含中文时文件必须带 UTF-8 BOM，否则中文全乱码。
3. **不要假设脚本能直接运行。** `Get-ExecutionPolicy -List` 全为 `Undefined` 意味着默认 `Restricted`，`.ps1` 会被拒绝执行。
4. **`driversipolicy.p7b`、`.cip` 等代码完整性策略文件内字符串是 UTF-16LE。** 用 ASCII 正则扫描必然漏检，会得出「黑名单里没有该厂商」的错误结论。
5. **用户说「还是不行」时先验证是否真的执行了。** 读注册表值、驱动绑定、日志时间戳，确认操作生效，再决定下一步。

---

## 免责声明

`diag-device.ps1` 为**只读**操作。修复脚本会修改注册表与启动配置，虽然提供回退方案，仍请自行评估风险并提前备份重要数据。本技能不构成对硬件故障的诊断结论，硬件问题请以厂商检测为准。

## License

[MIT](LICENSE)
