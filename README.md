# ResearchMode · 科研模式

进入 Python / PyTorch 训练前，看看电脑上哪些后台程序值得暂时退出。

**实时扫描 → 解释候选 → 用户审查 → 临时退出 → 验证结果 → 尝试恢复。**

Windows 本地工具，中文交互菜单，可配合 AI skill 使用。无需 Python、Node、AI API 或后台常驻服务。所有扫描、审查记录与日志默认只保存在本机。

![Version](https://img.shields.io/badge/version-0.1.0-2563eb)
![Windows](https://img.shields.io/badge/platform-Windows-0078d4)
![License](https://img.shields.io/badge/license-MIT-green)

## 快速开始

1. 下载仓库 ZIP 并解压，或克隆本仓库。
2. 双击 **`Start-ResearchMode.cmd`**。
3. 选择 **1 扫描并生成报告**，查看完整的本地 HTML 报告。
4. 选择 **2 选择程序生成关闭方案**，输入应用 Id 和动作，审查具体程序、路径与影响后确认。
5. 工作完成后选择 **4 恢复一次会话**。

支持 Windows PowerShell **5.1** 和 PowerShell **7**。启动器优先使用 PATH 中的 `pwsh`，否则使用系统自带的 Windows PowerShell。启动器的 ExecutionPolicy Bypass 只作用于这次脚本进程，不修改系统策略；组织策略仍可能阻止执行。

默认按普通用户权限运行。高权限程序的路径可能无法读取，会标记为 `unresolved`，不自动操作。确实需要管理某个服务时，可自行从已审查的代码以管理员权限启动；工具不会自动提权。

## 可以做什么

- 根据当前真实进程扫描，而非根据安装软件列表猜测。
- 按可执行文件路径合并同一软件的进程，显示内存、发布者、路径、服务关联、父进程和判定依据。
- 针对动态壁纸、手机连接、电脑管家、Tobii、音效、网络和科研工具提供初始识别规则。
- 未知应用保留为“需要核实”，不会自动批准。
- 对每次关闭方案记录 PID、启动时间和文件 SHA-256 身份；软件更新后需重新审查。
- 保存用户明确批准的具体动作，下次科研模式重新扫描后匹配。
- 支持只预演的 `-WhatIf`、15 分钟方案有效期、方案内容哈希校验、执行日志和幂等恢复。
- 不修改开机启动、不卸载软件、不清空工作集、不循环杀进程。

本版的科研上下文是**本地 Python / PyTorch**。计算任务、系统核心、显卡驱动、Windows 内未知组件和本工具的执行链不参与关闭。浏览器、终端、编辑器、代理默认保留或待审查。未来可增加不同任务配置，不应把本地训练策略直接用于远程服务器或音频实验。

## 三种动作

| 动作 | 行为 | 限制 |
|---|---|---|
| `close` | 请求应用正常关闭窗口 | 可能弹出保存提示、拒绝退出或缩到托盘；不会自动升级成强杀 |
| `terminate` | 结束明确批准的进程实例 | 可能丢失未保存内容；菜单要求输入 `FORCE`；不递归结束未经审查的子进程 |
| `service` | 停止一个明确批准的独立服务 | 需要相应权限；有运行中的依赖服务、共享进程或不接受停止请求时拒绝操作；不修改启动类型 |

`candidate` 只是“值得审查”，不保证对任何实验都无影响。发布者字段来自文件元数据，**不是可信签名验证结论**；初始软件名规则只提供建议，批准记录才绑定实际文件身份。

### 卡巴斯基等安全软件

用户可以决定临时暂停或退出安全软件。**默认保留不是禁止用户选择。** 本版把这类软件标记为 `manual`，在报告中解释用途和取舍；实际暂停／退出使用厂商界面，随后手动恢复。本版不会自动操作这类项目，也不会把手动操作记成已经自动恢复。

暂停防护、退出界面、停止服务是不同动作。暂停防护不保证释放内存，不提供绕过自保护的实现。示例操作依据：[卡巴斯基暂停与恢复保护说明](https://support.kaspersky.com/help/kaspersky/win21.5/en-us/70886.htm)；具体入口需核对安装版本。

## 命令行和 skill

在仓库根目录运行以下 PowerShell 示例。使用 Windows PowerShell 5.1 时脚本已包含 UTF-8 BOM，中文可正常读取。

```powershell
# 只读扫描，输出 JSON；不会关闭任何程序
.\ResearchMode.ps1 -Action Scan -Json

# 生成正常关窗方案，Ids 使用扫描得到的真实 Id
$review = .\ResearchMode.ps1 -Action Plan -Ids '替换为应用Id' -Method close -Remember -Json | ConvertFrom-Json
$review.Plan.Actions | Format-List

# 查看整个方案文件，然后只预演（不需要批准）
Get-Content -LiteralPath $review.Path -Encoding UTF8
.\ResearchMode.ps1 -Action Apply -PlanPath $review.Path -WhatIf

# 审查通过后，明确执行刚才的具体方案
$run = .\ResearchMode.ps1 -Action Apply -PlanPath $review.Path -PlanHash $review.PlanHash -Approved -Json | ConvertFrom-Json

# 审查会话中的项目后，尝试重新启动
.\ResearchMode.ps1 -Action Restore -SessionPath $run.Path -WhatIf
.\ResearchMode.ps1 -Action Restore -SessionPath $run.Path -Approved

# 下次：重新扫描，生成匹配本机已批准文件和动作的方案，再按上面方式审查执行
.\ResearchMode.ps1 -Action Plan -UseSaved -Json

# 查看／撤销偏好，列出会话
.\ResearchMode.ps1 -Action Approvals
.\ResearchMode.ps1 -Action Forget -Ids '替换为应用Id'
.\ResearchMode.ps1 -Action Sessions
```

非交互调用的 `-Approved` 表示调用者已取得用户对该方案或对应已保存偏好的授权，**不是自动判断安全的开关**。`PlanHash` 必须来自审查时的方案结果；方案发生变化需要重新审查。同一方案只允许执行一次，执行前也会再次核实当前程序身份。

第一版一次新建方案使用同一种动作；需要不同动作时分别审查生成。保存后的偏好可以合并不同动作。方案中的新启动实例不在原批准范围内，进程退出、重启或文件变化会使相关身份检查失败。

### 安装配套 skill

```powershell
.\Install-Skill.ps1
```

默认安装到 `$CODEX_HOME/skills/research-mode`，未设置时使用 `~/.codex/skills/research-mode`。安装包包含运行脚本的副本，不依赖仓库绝对路径，也不需要把个人日志复制进去。目标已存在时默认拒绝覆盖，明确更新时使用 `-Force`。

安装后可请求：**“使用 $research-mode，扫描当前电脑，为 PyTorch 训练准备一个我能审查的科研模式方案。”**

skill 与独立菜单使用同一套执行逻辑。AI 解释未知程序，用户批准具体选择，脚本负责可验证的动作。

## 数据与恢复边界

默认数据位置：`%LOCALAPPDATA%\ResearchMode`。可用 `-DataDirectory` 指定独立目录。

```text
ResearchMode/
  approvals.json        本机批准偏好
  plans/                待审查方案，15 分钟有效
  sessions/             每步执行和恢复结果
  reports/latest.html   全部应用的只读报告
```

- 报告可能包含用户名、程序路径和窗口标题。分享前自行脱敏；这些数据不应提交到 GitHub。工具不收集完整进程命令行，但服务配置中的启动命令会保存在本地身份记录中。
- 数据文件是本机用户数据，**不是可信的远程任务格式**。不要导入陌生人提供的方案、会话和批准记录，不要用管理员权限运行不可信仓库。
- 恢复仅重新启动成功停止的项目。已在运行的程序不重复启动；文件或服务配置变化时拒绝自动恢复。
- 不会恢复未保存内容、原窗口布局、命令行参数、终端会话或原来的训练上下文。有些程序启动后会把请求交给另一个进程，本版会要求手动确认。
- 部分退出、权限失败、系统自动重启、执行中断等情况会保留日志。`pending` / `acting` 表示未能确认最终状态，需要手动核对，不自动猜测恢复。
- 不常驻监控，不会在程序自动重启后循环结束它。
- 工作集可能包含共享页；前后可用内存差值也受其他活动影响，不把列表总和当作“保证释放量”。

## 开发与验证

```powershell
# 无第三方测试依赖，含真实的一次性进程关闭／恢复测试
.\tests\Test-ResearchMode.ps1

# 仅运行不启动测试进程的检查
.\tests\Test-ResearchMode.ps1 -SkipIntegration
```

集成测试在独立临时目录编译一个一次性等待程序，只结束测试自己创建的程序；不停止本机真实服务或用户应用。测试覆盖批准要求、方案哈希、文件更新、PID 复用、执行链保护、依赖服务、预演、未审查的新实例、已保存偏好、恢复及重复执行。测试编译器使用 Windows .NET Framework 自带的 C# 编译器。

Windows CI 分别在 PowerShell 5.1 和 7 执行测试。新增规则请参考 [贡献指南](CONTRIBUTING.md)，执行边界见 [设计说明](docs/design.md)。

## 开源许可

[MIT](LICENSE)。欢迎贡献经过证据核实的软件识别规则、退出方式和恢复说明。
