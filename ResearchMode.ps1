#requires -Version 5.1
[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet('Menu', 'Scan', 'Plan', 'Apply', 'Restore', 'Approvals', 'Forget', 'Sessions')][string]$Action = 'Menu',
    [string[]]$Ids = @(),
    [ValidateSet('close', 'terminate', 'service')][string]$Method = 'close',
    [string]$PlanPath, [string]$PlanHash, [string]$SessionPath, [string]$DataDirectory,
    [switch]$UseSaved, [switch]$Remember, [switch]$Approved, [switch]$Json
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'src/ResearchMode.psm1') -Force -DisableNameChecking
$DataDirectory = Get-RMDataDirectory $DataDirectory

function Show-RMSnapshot {
    param($Snapshot, [int]$Limit = 0)
    Write-Host ("`n内存：可用 {0:N2} GB / 共 {1:N2} GB；{2} 个进程" -f ($Snapshot.Memory.AvailableMB / 1024), ($Snapshot.Memory.TotalMB / 1024), $Snapshot.ProcessCount) -ForegroundColor Cyan
    $apps = @($Snapshot.Apps)
    if ($Limit -gt 0) { $apps = @($apps | Select-Object -First $Limit) }
    $apps | Select-Object Id, @{n='进程';e={$_.Name}}, @{n='内存MB';e={$_.ResidentMB}}, @{n='数量';e={$_.ProcessCount}}, @{n='分类';e={$_.Classification}}, @{n='动作';e={$_.Methods -join '/'}} | Format-Table -AutoSize | Out-Host
    Write-Host 'candidate 可审查候选；review 待核实；keep 建议保留；manual 厂商手动处理；protected 本版本不操作；unresolved 身份不可读。'
    Write-Host '驻留内存含共享页面，不能直接相加，也不等于可释放量。扫描本身也会产生少量临时占用。'
}

function Show-RMPlan {
    param($Result)
    Write-Host "`n请审查以下方案（15 分钟内有效）：" -ForegroundColor Yellow
    foreach ($item in @($Result.Plan.Actions)) {
        Write-Host ("`n{0} [{1}]" -f $item.Name, $item.Method) -ForegroundColor Cyan
        Write-Host "路径：$($item.ExePath)"
        Write-Host "影响：$($item.Reason)"
        Write-Host "进程：$((@($item.Processes) | ForEach-Object ProcessId) -join ', ')"
        if ($item.Method -eq 'terminate') { Write-Host '强制结束：可能丢失未保存内容。此动作需要明确批准。' -ForegroundColor Yellow }
        foreach ($service in @($item.Services)) { Write-Host "服务：$($service.Name)；启动方式保持 $($service.StartMode)" }
    }
    Write-Host "`n恢复仅尝试重启；不能恢复未保存内容、原窗口或命令行参数。"
    Write-Host "方案：$($Result.Path)"
    Write-Host "PlanHash：$($Result.PlanHash)"
    Write-Host "保存为下次偏好：$($Result.Plan.Remember)"
}

function Show-RMSession {
    param($Result)
    $Result.Session.Actions | Select-Object @{n='程序';e={$_.Action.Name}}, State, Detail | Format-Table -Wrap | Out-Host
    Write-Host ("可用内存变化：{0:+0.0;-0.0;0} MB（含同时发生的其他系统活动，不能全部归因于关闭操作）" -f $Result.Session.AvailableDeltaMB)
    Write-Host "会话记录：$($Result.Path)"
}

function Get-RMSessionFiles {
    if (Test-Path -LiteralPath (Join-Path $DataDirectory 'sessions')) {
        @(Get-ChildItem -LiteralPath (Join-Path $DataDirectory 'sessions') -Filter '*.json' | Sort-Object LastWriteTime -Descending)
    }
}

function Start-RMMenu {
    Write-Host "`nResearchMode 0.1.0 · 科研模式" -ForegroundColor Cyan
    Write-Host '面向本地 Python / PyTorch。默认保留计算任务、显卡驱动和执行本工具的程序。'
    Write-Host "本机数据目录：$DataDirectory"
    while ($true) {
        Write-Host "`n1 扫描并生成报告   2 选择程序生成关闭方案   3 使用已保存的批准偏好"
        Write-Host '4 恢复一次会话     5 查看／撤销批准记录     0 退出'
        $choice = Read-Host '请选择'
        try {
            switch ($choice) {
                '1' {
                    $snapshot = Get-RMSnapshot
                    Show-RMSnapshot $snapshot 35
                    $report = Export-RMReport $snapshot (Join-Path $DataDirectory 'reports/latest.html')
                    Write-Host "全部应用的只读报告：$report"
                    Write-Host '报告包含本机路径，分享前请脱敏。'
                }
                { $_ -in @('2', '3') } {
                    $usePreferences = $choice -eq '3'
                    $snapshot = Get-RMSnapshot
                    $chosenIds = @(); $chosenMethod = 'close'; $rememberChoice = $false
                    if (-not $usePreferences) {
                        Show-RMSnapshot $snapshot
                        $inputIds = Read-Host '输入要审查的 Id，多个用逗号分隔；留空取消'
                        if (-not $inputIds.Trim()) { continue }
                        $chosenIds = @($inputIds.Split(',') | ForEach-Object Trim | Where-Object { $_ })
                        Write-Host 'close 正常关窗（托盘应用可能仍运行）；terminate 强制结束；service 停止单个服务。'
                        $chosenMethod = Read-Host '输入一个动作 close / terminate / service'
                        if ($chosenMethod -notin @('close', 'terminate', 'service')) { throw '动作无效。' }
                        $rememberChoice = (Read-Host '本次批准是否保存为下次偏好？输入 YES 保存，其余不保存') -ceq 'YES'
                    }
                    $result = New-RMPlan -Snapshot $snapshot -Ids $chosenIds -Method $chosenMethod -UseSaved:$usePreferences -Remember:$rememberChoice -DataDirectory $DataDirectory
                    Show-RMPlan $result
                    $confirmation = 'APPLY'
                    if (@($result.Plan.Actions | Where-Object Method -eq 'terminate').Count) { $confirmation = 'FORCE' }
                    if ((Read-Host "确认执行上述具体方案请输入 $confirmation，其余取消") -ceq $confirmation) {
                        $execution = Invoke-RMPlan -PlanPath $result.Path -PlanHash $result.PlanHash -Approved -DataDirectory $DataDirectory
                        Show-RMSession $execution
                    }
                }
                '4' {
                    $files = @(Get-RMSessionFiles)
                    if (-not $files.Count) { Write-Host '没有会话。'; continue }
                    for ($i = 0; $i -lt $files.Count; $i++) { Write-Host "$($i + 1)  $($files[$i].Name)  $($files[$i].LastWriteTime)" }
                    $number = 0
                    if (-not [int]::TryParse((Read-Host '选择会话编号；0 取消'), [ref]$number) -or $number -lt 1 -or $number -gt $files.Count) { continue }
                    $file = $files[$number - 1].FullName
                    $session = Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json
                    $session.Actions | Select-Object @{n='程序';e={$_.Action.Name}}, State, RestoreKind, Restored, RestoreDetail | Format-Table -Wrap | Out-Host
                    if ((Read-Host '只重启本工具已停止的项目；输入 RESTORE 确认') -ceq 'RESTORE') {
                        $restored = Restore-RMSession -SessionPath $file -Approved
                        $restored.Actions | Select-Object @{n='程序';e={$_.Action.Name}}, Restored, RestoreDetail | Format-Table -Wrap | Out-Host
                    }
                }
                '5' {
                    @(Get-RMApprovals $DataDirectory) | Format-Table Id, Name, Method, ApprovedUtc | Out-Host
                    $id = Read-Host '输入要撤销的 Id；留空返回'
                    if ($id.Trim()) { Remove-RMApproval -Id $id.Trim() -DataDirectory $DataDirectory; Write-Host '已撤销。' }
                }
                '0' { return }
                default { Write-Host '请输入菜单编号。' }
            }
        } catch { Write-Host $_.Exception.Message -ForegroundColor Red }
    }
}

try {
    switch ($Action) {
        'Menu' {
            if ($WhatIfPreference) { throw '菜单不支持全局 WhatIf；请对 Apply 或 Restore 使用 -WhatIf。' }
            Start-RMMenu
        }
        'Scan' {
            $snapshot = Get-RMSnapshot
            if ($Json) { ConvertTo-Json -InputObject $snapshot -Depth 15 }
            else { Show-RMSnapshot $snapshot; Export-RMReport $snapshot (Join-Path $DataDirectory 'reports/latest.html') }
        }
        'Plan' {
            $result = New-RMPlan -Ids $Ids -Method $Method -UseSaved:$UseSaved -Remember:$Remember -DataDirectory $DataDirectory
            if ($Json) { ConvertTo-Json -InputObject $result -Depth 15 } else { Show-RMPlan $result }
        }
        'Apply' {
            if (-not $PlanPath) { throw '需要 -PlanPath。' }
            $result = Invoke-RMPlan -PlanPath $PlanPath -PlanHash $PlanHash -Approved:$Approved -DataDirectory $DataDirectory -WhatIf:$WhatIfPreference
            if ($Json -or $WhatIfPreference) { ConvertTo-Json -InputObject $result -Depth 15 } else { Show-RMSession $result }
        }
        'Restore' {
            if (-not $SessionPath) { throw '需要 -SessionPath。' }
            $result = Restore-RMSession -SessionPath $SessionPath -Approved:$Approved -WhatIf:$WhatIfPreference
            if ($Json) { ConvertTo-Json -InputObject $result -Depth 15 }
            else { $result.Actions | Select-Object @{n='程序';e={$_.Action.Name}}, Restored, RestoreDetail | Format-Table -Wrap | Out-Host }
        }
        'Approvals' {
            $result = @(Get-RMApprovals $DataDirectory)
            if ($Json) { ConvertTo-Json -InputObject $result -Depth 10 } else { $result | Format-Table -AutoSize | Out-Host }
        }
        'Forget' {
            if (-not $Ids.Count) { throw '需要 -Ids。' }
            foreach ($id in $Ids) { if ($PSCmdlet.ShouldProcess($id, '撤销批准偏好')) { Remove-RMApproval $id $DataDirectory } }
        }
        'Sessions' {
            $result = @(Get-RMSessionFiles | Select-Object Name, FullName, LastWriteTime)
            if ($Json) { ConvertTo-Json -InputObject $result -Depth 10 } else { $result | Format-Table -AutoSize | Out-Host }
        }
    }
} catch { Write-Error $_.Exception.Message; exit 1 }
