Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:Root = Split-Path $PSScriptRoot -Parent
$script:Rules = Get-Content -LiteralPath (Join-Path $script:Root 'rules/apps.json') -Raw -Encoding UTF8 | ConvertFrom-Json

function Get-RMDataDirectory {
    param([string]$DataDirectory)
    if (-not $DataDirectory) { $DataDirectory = Join-Path $env:LOCALAPPDATA 'ResearchMode' }
    [IO.Path]::GetFullPath($DataDirectory)
}

function Read-RMJson {
    param([string]$Path)
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        $json = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
        # PowerShell 7.5+ otherwise converts ISO timestamps to DateTime objects,
        # which changes string comparisons and can lose the timezone on coercion.
        if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) {
            ConvertFrom-Json -InputObject $json -DateKind String
        } else { ConvertFrom-Json -InputObject $json }
    }
}

function Write-RMJson {
    param([Parameter(Mandatory)]$Value, [Parameter(Mandatory)][string]$Path)
    $directory = Split-Path $Path -Parent
    if (-not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
    $temporary = Join-Path $directory ([IO.Path]::GetRandomFileName())
    try {
        $text = ConvertTo-Json -InputObject $Value -Depth 20
        [IO.File]::WriteAllText($temporary, $text, (New-Object Text.UTF8Encoding($false)))
        Move-Item -LiteralPath $temporary -Destination $Path -Force
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
    }
}

function Get-RMHash {
    param([string]$Text)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Get-RMMemory {
    $os = Get-CimInstance Win32_OperatingSystem
    [pscustomobject]@{
        TotalMB = [math]::Round($os.TotalVisibleMemorySize / 1024, 1)
        AvailableMB = [math]::Round($os.FreePhysicalMemory / 1024, 1)
        UsedMB = [math]::Round(($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) / 1024, 1)
    }
}

function Get-RMServiceExecutable {
    param([string]$Command)
    if ($Command -match '^\s*"([^"]+\.exe)"') { return $Matches[1] }
    if ($Command -match '^\s*(.+?\.exe)(?:\s|$)') { return $Matches[1] }
    return ''
}

function Get-RMStartStamp {
    param([DateTime]$Time)
    # CIM rounds down to microseconds; Process.StartTime exposes 100 ns ticks.
    $Time.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss.ffffff'Z'", [Globalization.CultureInfo]::InvariantCulture)
}

function Get-RMProtectedProcessIds {
    param([object[]]$Processes, [int]$CurrentId = $PID)
    $map = @{}
    foreach ($process in $Processes) { $map[[int]$process.ProcessId] = $process }
    $seen = @{}
    $cursor = $CurrentId
    while ($map.ContainsKey($cursor) -and -not $seen.ContainsKey($cursor)) {
        $seen[$cursor] = $true
        $parent = [int]$map[$cursor].ParentProcessId
        if ($parent -le 0 -or $parent -eq $cursor) { break }
        $cursor = $parent
    }
    @($seen.Keys)
}

function Get-RMClassification {
    param([string]$Name, [string]$Path, [object[]]$Services = @(), [bool]$IsAncestor = $false)
    $classification = 'review'
    $reason = '用途未核实；默认不选择。请确认工作内容及未保存数据。'
    $methods = @('close', 'terminate')
    $ruleId = ''
    $rule = @($script:Rules | Where-Object { @($_.executables) -contains $Name } | Select-Object -First 1)
    if ($rule.Count) {
        $classification = $rule[0].classification
        $reason = $rule[0].reason
        $methods = @($rule[0].methods)
        $ruleId = $rule[0].id
    }
    if ($Services.Count) {
        $methods = @('service')
        $classification = 'review'
        $reason = '后台服务；需要确认依赖、权限和影响。不会修改启动类型。'
        if ($rule.Count) { $reason = $rule[0].reason + ' ' + $reason }
        if ($rule.Count -and $rule[0].classification -eq 'manual') {
            $classification = 'manual'; $methods = @()
            $reason = $rule[0].reason
        }
    }
    $essential = $Name -match '^(System|Idle|Registry|Memory Compression|Secure System|svchost|services|lsass|LsaIso|csrss|smss|wininit|winlogon|dwm|explorer|WUDFHost|fontdrvhost|NVDisplay\.Container|nvcontainer|amdfendrsr|RtkAudUService64|audiodg|LenovoUtilityService|FnHotkeyUtility|FnHotkeyCapsLKNumLK)(\.exe)?$'
    $workload = $Name -match '^(python(w|[0-9.]*)?|jupyter.*|ipython|matlab|R|Rscript|rsession|rstudio|stata.*|julia|vmmem.*|wsl.*|docker.*|torchrun)(\.exe)?$'
    $windowsPath = $false
    if ($Path -and $env:WINDIR) { $windowsPath = $Path.StartsWith(($env:WINDIR.TrimEnd('\') + '\'), [StringComparison]::OrdinalIgnoreCase) }
    # Only these identified optional services may be considered inside Windows directories.
    $optionalWindowsService = $Services.Count -eq 1 -and @('TobiiRGB', 'NahimicService') -contains $Services[0].Name
    $optionalWindowsApp = $ruleId -eq 'task-manager'
    if ($essential -or $workload -or $IsAncestor -or ($windowsPath -and -not $optionalWindowsService -and -not $optionalWindowsApp)) {
        $classification = 'protected'; $methods = @()
        $reason = '系统、驱动、科研运行环境或本工具的执行链；本版本不操作。'
    } elseif (-not $Path -and -not $Services.Count -and $classification -ne 'manual') {
        $classification = 'unresolved'; $methods = @()
        $reason = '无法读取程序路径，不能核实身份；默认不操作。'
    }
    if ($Services.Count -gt 1) {
        $classification = 'protected'; $methods = @()
        $reason = '多个服务共享此进程；本版本不自动停止共享服务进程。'
    }
    [pscustomobject]@{ Classification = $classification; Reason = $reason; Methods = @($methods); RuleId = $ruleId }
}

function Get-RMSnapshot {
    if ($env:OS -ne 'Windows_NT') { throw 'ResearchMode 目前只支持 Windows。' }
    $processes = @(Get-CimInstance Win32_Process)
    $services = @(Get-CimInstance Win32_Service | Where-Object { $_.State -eq 'Running' -and $_.ProcessId -gt 0 })
    $live = @{}
    foreach ($p in Get-Process) { $live[[int]$p.Id] = $p }
    $protectedIds = @(Get-RMProtectedProcessIds -Processes $processes)
    $records = foreach ($p in $processes) {
        $attached = @($services | Where-Object { $_.ProcessId -eq $p.ProcessId })
        $path = [string]$p.ExecutablePath
        if (-not $path -and $attached.Count -eq 1) { $path = Get-RMServiceExecutable $attached[0].PathName }
        $resident = 0.0; $window = ''; $parentName = ''
        if ($live.ContainsKey([int]$p.ProcessId)) {
            $resident = [math]::Round($live[[int]$p.ProcessId].WorkingSet64 / 1MB, 1)
            $window = $live[[int]$p.ProcessId].MainWindowTitle
        }
        $parent = @($processes | Where-Object { $_.ProcessId -eq $p.ParentProcessId } | Select-Object -First 1)
        if ($parent.Count) { $parentName = $parent[0].Name }
        $start = ''
        if ($p.CreationDate) { $start = Get-RMStartStamp $p.CreationDate }
        [pscustomobject]@{
            Key = if ($path) { $path.ToLowerInvariant() } else { 'unresolved:' + $p.Name.ToLowerInvariant() }
            Name = $p.Name; Path = $path; ProcessId = [int]$p.ProcessId; ParentId = [int]$p.ParentProcessId
            ParentName = $parentName; StartedUtc = $start; ResidentMB = $resident; Window = $window
            Services = @($attached | ForEach-Object { [pscustomobject]@{ Name = $_.Name; DisplayName = $_.DisplayName; PathName = $_.PathName; StartMode = $_.StartMode } })
            IsAncestor = $protectedIds -contains [int]$p.ProcessId
        }
    }
    $apps = foreach ($group in @($records | Group-Object Key)) {
        $members = @($group.Group)
        $first = $members[0]
        $appServices = @($members | ForEach-Object { $_.Services } | Sort-Object Name -Unique)
        $policy = Get-RMClassification -Name $first.Name -Path $first.Path -Services $appServices -IsAncestor (@($members | Where-Object IsAncestor).Count -gt 0)
        $publisher = ''; $label = $first.Name
        if ($first.Path -and (Test-Path -LiteralPath $first.Path -PathType Leaf)) {
            try {
                $info = (Get-Item -LiteralPath $first.Path).VersionInfo
                $publisher = [string]$info.CompanyName
                if ($info.ProductName) { $label = $info.ProductName }
            } catch { }
        }
        [pscustomobject]@{
            Id = (Get-RMHash $group.Name).Substring(0, 12); Label = $label; Name = $first.Name
            ExePath = $first.Path; Publisher = $publisher; RuleId = $policy.RuleId
            Classification = $policy.Classification; Reason = $policy.Reason; Methods = @($policy.Methods)
            ResidentMB = [math]::Round(($members | Measure-Object ResidentMB -Sum).Sum, 1)
            ProcessCount = $members.Count; Processes = @($members | Select-Object ProcessId, ParentId, ParentName, StartedUtc, Window)
            Services = @($appServices)
        }
    }
    [pscustomobject]@{
        SchemaVersion = 1; CapturedUtc = [DateTime]::UtcNow.ToString('o'); Memory = Get-RMMemory
        ProcessCount = $processes.Count; Apps = @($apps | Sort-Object ResidentMB -Descending)
    }
}

function Get-RMFingerprint {
    param($App)
    if (-not $App.ExePath -or -not (Test-Path -LiteralPath $App.ExePath -PathType Leaf)) {
        throw "无法核实文件身份：$($App.Name)。请以适当权限重新扫描，或手动处理。"
    }
    $fileHash = (Get-FileHash -LiteralPath $App.ExePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $serviceIdentity = @($App.Services | Sort-Object Name | ForEach-Object { $_.Name + '|' + $_.PathName }) -join "`n"
    Get-RMHash ($App.ExePath.ToLowerInvariant() + '|' + $fileHash + '|' + $serviceIdentity)
}

function Get-RMApprovals {
    param([string]$DataDirectory)
    $directory = Get-RMDataDirectory $DataDirectory
    $value = Read-RMJson (Join-Path $directory 'approvals.json')
    if ($value) { @($value) }
}

function Remove-RMApproval {
    param([string]$Id, [string]$DataDirectory)
    $directory = Get-RMDataDirectory $DataDirectory
    $remaining = @(Get-RMApprovals $directory | Where-Object { $_.Id -ne $Id })
    Write-RMJson -Value $remaining -Path (Join-Path $directory 'approvals.json')
}

function New-RMPlan {
    [CmdletBinding()]
    param(
        [string[]]$Ids = @(), [ValidateSet('close', 'terminate', 'service')][string]$Method = 'close',
        [switch]$UseSaved, [switch]$Remember, [string]$DataDirectory, $Snapshot
    )
    $directory = Get-RMDataDirectory $DataDirectory
    if (-not $Snapshot) { $Snapshot = Get-RMSnapshot }
    $selected = @()
    if ($UseSaved) {
        foreach ($approval in @(Get-RMApprovals $directory)) {
            $match = @($Snapshot.Apps | Where-Object { $_.Id -eq $approval.Id })
            if (-not $match.Count) { continue }
            try { $fingerprint = Get-RMFingerprint $match[0] } catch { Write-Warning $_.Exception.Message; continue }
            if ($fingerprint -ne $approval.Fingerprint) { Write-Warning "$($match[0].Name) 文件或服务配置已变化，需要重新审查。"; continue }
            if (@($match[0].Methods) -notcontains $approval.Method) { continue }
            $selected += [pscustomobject]@{ App = $match[0]; Method = $approval.Method }
        }
    } else {
        if (-not $Ids.Count) { throw '请选择至少一个应用 Id。' }
        foreach ($id in @($Ids | Select-Object -Unique)) {
            $match = @($Snapshot.Apps | Where-Object { $_.Id -eq $id })
            if ($match.Count -ne 1) { throw "应用 $id 已退出或不存在，请重新扫描。" }
            if (@($match[0].Methods) -notcontains $Method) { throw "$($match[0].Name) 不支持 $Method；分类：$($match[0].Classification)。" }
            $selected += [pscustomobject]@{ App = $match[0]; Method = $Method }
        }
    }
    if (-not $selected.Count) { throw '当前没有身份匹配且允许执行的已批准项目。' }
    $actions = @($selected | ForEach-Object {
        [pscustomobject]@{
            Id = $_.App.Id; Label = $_.App.Label; Name = $_.App.Name; ExePath = $_.App.ExePath
            Method = $_.Method; Fingerprint = Get-RMFingerprint $_.App
            Processes = @($_.App.Processes); Services = @($_.App.Services); Reason = $_.App.Reason
        }
    })
    $plan = [pscustomobject]@{
        SchemaVersion = 1; PlanId = [Guid]::NewGuid().ToString('N'); CreatedUtc = [DateTime]::UtcNow.ToString('o')
        ExpiresUtc = [DateTime]::UtcNow.AddMinutes(15).ToString('o'); Remember = [bool]$Remember
        MemoryBefore = $Snapshot.Memory; Actions = $actions
    }
    $path = Join-Path (Join-Path $directory 'plans') ($plan.PlanId + '.json')
    Write-RMJson -Value $plan -Path $path
    [pscustomobject]@{ Path = $path; Plan = $plan; PlanHash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash }
}

function Assert-RMActionIdentity {
    param($Action, $App)
    if (-not $App -or $App.Id -ne $Action.Id) { throw '应用已退出或身份不匹配。' }
    if (@($App.Methods) -notcontains $Action.Method) { throw '当前策略不允许此动作，可能涉及系统或执行链。' }
    if ((Get-RMFingerprint $App) -ne $Action.Fingerprint) { throw '文件或服务配置已变化，请重新审查。' }
    if ($Action.ExePath -ne $App.ExePath) { throw '程序路径不匹配。' }
    if (-not @($Action.Processes).Count) { throw '方案没有记录进程身份。' }
    foreach ($p in @($Action.Processes)) {
        if (-not $p.StartedUtc) { throw '方案缺少进程启动时间，不能执行。' }
        $current = @($App.Processes | Where-Object { $_.ProcessId -eq $p.ProcessId -and $_.StartedUtc -eq $p.StartedUtc })
        if ($current.Count -ne 1) { throw '进程已重启或退出，请重新扫描，避免误用旧 PID。' }
    }
    # New instances were never reviewed. Do not let stopping a service affect them.
    if ($Action.Method -eq 'service' -and @($App.Processes).Count -ne @($Action.Processes).Count) {
        throw '服务进程集合已变化，请重新审查。'
    }
    $plannedServices = @($Action.Services | Sort-Object Name | ForEach-Object { $_.Name + '|' + $_.PathName }) -join "`n"
    $actualServices = @($App.Services | Sort-Object Name | ForEach-Object { $_.Name + '|' + $_.PathName }) -join "`n"
    if ($plannedServices -ne $actualServices) { throw '方案中的服务集合与当前程序不匹配。' }
}

function Assert-RMServiceStop {
    param($Service, [object[]]$RunningDependents = @())
    if ($Service.Status -ne 'Running') { throw '服务已不是运行状态。' }
    if (-not $Service.CanStop) { throw '服务不接受停止请求，请使用厂商支持的方式手动处理。' }
    if ($RunningDependents.Count) { throw ('有运行中的依赖服务，未批准连带停止：' + (($RunningDependents | ForEach-Object Name) -join ', ')) }
}

function Stop-RMAction {
    param($Action)
    if ($Action.Method -eq 'service') {
        if (@($Action.Services).Count -ne 1) { throw '只允许单独停止一个非共享服务。' }
        $expected = $Action.Services[0]
        $cim = Get-CimInstance Win32_Service | Where-Object { $_.Name -eq $expected.Name }
        if (-not $cim -or $cim.PathName -ne $expected.PathName) { throw '服务身份已变化。' }
        $matched = @($Action.Processes | Where-Object { $_.ProcessId -eq $cim.ProcessId })
        if (-not $matched.Count) { throw '服务已重启，请重新扫描。' }
        $service = Get-Service | Where-Object { $_.Name -eq $expected.Name }
        Assert-RMServiceStop -Service $service -RunningDependents @($service.DependentServices | Where-Object Status -eq 'Running')
        Stop-Service -InputObject $service -ErrorAction Stop
        $service.WaitForStatus([ServiceProcess.ServiceControllerStatus]::Stopped, [TimeSpan]::FromSeconds(8))
        return [pscustomobject]@{ State = 'stopped'; Detail = '服务已停止。'; RestoreKind = 'service' }
    }
    $requested = 0; $details = @()
    foreach ($expected in @($Action.Processes)) {
        $process = Get-Process -Id $expected.ProcessId -ErrorAction SilentlyContinue
        if (-not $process) { continue }
        try {
            if ((Get-RMStartStamp $process.StartTime) -ne $expected.StartedUtc) { throw 'PID 已被另一个进程复用。' }
            if ($process.Path -ne $Action.ExePath) { throw '进程路径已变化。' }
            if ($Action.Method -eq 'terminate') { $process.Kill(); $requested++ }
            elseif ($process.MainWindowHandle -ne [IntPtr]::Zero) {
                if ($process.CloseMainWindow()) { $requested++ }
            }
        } catch { $details += $_.Exception.Message }
    }
    if (-not $requested) {
        return [pscustomobject]@{ State = 'not-stopped'; Detail = ('没有发出退出请求。托盘程序可能需要手动退出。 ' + ($details -join '; ')); RestoreKind = 'none' }
    }
    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    $remaining = @()
    do {
        $remaining = @($Action.Processes | Where-Object {
            $p = Get-Process -Id $_.ProcessId -ErrorAction SilentlyContinue
            if ($p) { try { (Get-RMStartStamp $p.StartTime) -eq $_.StartedUtc } catch { $true } }
        })
        if (-not $remaining.Count) { break }
        Start-Sleep -Milliseconds 200
    } while ([DateTime]::UtcNow -lt $deadline)
    $state = 'stopped'; $restore = 'app'; $detail = '已审查的进程已退出；恢复只能重新启动程序，不恢复窗口或未保存内容。'
    if ($remaining.Count) { $state = 'partial'; $restore = 'none'; $detail = '部分进程仍在运行，可能有保存提示、托盘驻留或权限限制；请手动检查。' }
    [pscustomobject]@{ State = $state; Detail = ($detail + ' ' + ($details -join '; ')).Trim(); RestoreKind = $restore }
}

function Invoke-RMPlan {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$PlanPath, [switch]$Approved, [string]$PlanHash, [string]$DataDirectory)
    $directory = Get-RMDataDirectory $DataDirectory
    $plan = Read-RMJson $PlanPath
    if (-not $plan -or $plan.SchemaVersion -ne 1 -or $plan.PlanId -notmatch '^[a-f0-9]{32}$') { throw '不是有效的 ResearchMode 方案。' }
    if ([DateTime]::Parse($plan.ExpiresUtc).ToUniversalTime() -lt [DateTime]::UtcNow) { throw '方案已过期（15 分钟），请重新扫描审查。' }
    if (-not @($plan.Actions).Count) { throw '空方案。' }
    $journalPath = Join-Path (Join-Path $directory 'sessions') ($plan.PlanId + '.json')
    if (Test-Path -LiteralPath $journalPath) { throw '此方案已经执行过。请检查会话记录，不重复执行。' }
    if (-not $Approved -and -not $WhatIfPreference) { throw '请先审查方案，再显式传入 -Approved。菜单会在执行前询问。' }
    if (-not $WhatIfPreference -and (-not $PlanHash -or (Get-FileHash -LiteralPath $PlanPath -Algorithm SHA256).Hash -ne $PlanHash)) {
        throw '必须提供审查时的 -PlanHash；方案文件有变化时需要重新审查。'
    }
    $snapshot = Get-RMSnapshot
    # Preflight the complete plan before any mutation.
    foreach ($action in @($plan.Actions)) {
        $match = @($snapshot.Apps | Where-Object Id -eq $action.Id)
        if ($match.Count -ne 1) { throw "$($action.Name) 不再运行，请重新扫描。" }
        Assert-RMActionIdentity $action $match[0]
    }
    if ($WhatIfPreference) {
        foreach ($action in @($plan.Actions)) { $null = $PSCmdlet.ShouldProcess($action.Name, $action.Method) }
        return [pscustomobject]@{ WhatIf = $true; ActionCount = @($plan.Actions).Count }
    }
    $journal = [pscustomobject]@{
        SchemaVersion = 1; SessionId = $plan.PlanId; StartedUtc = [DateTime]::UtcNow.ToString('o'); FinishedUtc = ''
        MemoryBefore = $snapshot.Memory; MemoryAfter = $null; AvailableDeltaMB = 0; Actions = @()
    }
    Write-RMJson $journal $journalPath
    foreach ($action in @($plan.Actions)) {
        if (-not $PSCmdlet.ShouldProcess($action.Name, $action.Method)) { continue }
        $record = [pscustomobject]@{ Action = $action; State = 'pending'; Detail = ''; RestoreKind = 'none'; Restored = $false; RestoreDetail = '' }
        $journal.Actions += $record
        Write-RMJson $journal $journalPath
        try {
            # Re-check immediately before each operation; earlier exits can change later apps.
            $fresh = Get-RMSnapshot
            $match = @($fresh.Apps | Where-Object Id -eq $action.Id)
            if ($match.Count -ne 1) { throw '程序状态已变化，跳过。' }
            Assert-RMActionIdentity $action $match[0]
            $record.State = 'acting'
            Write-RMJson $journal $journalPath
            $result = Stop-RMAction $action
            $record.State = $result.State; $record.Detail = $result.Detail; $record.RestoreKind = $result.RestoreKind
            if ($plan.Remember) {
                $approvals = @(Get-RMApprovals $directory | Where-Object Id -ne $action.Id)
                $approvals += [pscustomobject]@{ Id = $action.Id; Name = $action.Name; Fingerprint = $action.Fingerprint; Method = $action.Method; ApprovedUtc = [DateTime]::UtcNow.ToString('o') }
                Write-RMJson $approvals (Join-Path $directory 'approvals.json')
            }
        } catch { $record.State = 'failed'; $record.Detail = $_.Exception.Message }
        Write-RMJson $journal $journalPath
    }
    $journal.MemoryAfter = Get-RMMemory
    $journal.AvailableDeltaMB = [math]::Round($journal.MemoryAfter.AvailableMB - $journal.MemoryBefore.AvailableMB, 1)
    $journal.FinishedUtc = [DateTime]::UtcNow.ToString('o')
    Write-RMJson $journal $journalPath
    [pscustomobject]@{ Path = $journalPath; Session = $journal }
}

function Restore-RMSession {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$SessionPath, [switch]$Approved)
    $journal = Read-RMJson $SessionPath
    if (-not $journal -or $journal.SchemaVersion -ne 1 -or $journal.SessionId -notmatch '^[a-f0-9]{32}$') { throw '不是有效的会话记录。' }
    if (-not $Approved -and -not $WhatIfPreference) { throw '请先审查会话的恢复项目，再传入 -Approved。' }
    foreach ($record in @($journal.Actions)) {
        if ($record.Restored -or $record.State -ne 'stopped' -or $record.RestoreKind -eq 'none') { continue }
        $action = $record.Action
        if (-not $PSCmdlet.ShouldProcess($action.Name, '尝试重新启动')) { continue }
        try {
            if ((Get-RMFingerprint $action) -ne $action.Fingerprint) { throw '程序文件或记录已变化，请手动检查后启动。' }
            if ($record.RestoreKind -eq 'service') {
                if (@($action.Services).Count -ne 1) { throw '服务记录不明确，请手动恢复。' }
                $expected = $action.Services[0]
                $cim = Get-CimInstance Win32_Service | Where-Object { $_.Name -eq $expected.Name }
                if (-not $cim -or $cim.PathName -ne $expected.PathName) { throw '服务配置已变化，请手动恢复。' }
                $service = Get-Service | Where-Object { $_.Name -eq $expected.Name }
                if ($service.Status -ne 'Running') {
                    Start-Service -InputObject $service
                    $service.WaitForStatus([ServiceProcess.ServiceControllerStatus]::Running, [TimeSpan]::FromSeconds(8))
                }
                $record.RestoreDetail = '服务已运行。'
            } elseif ($record.RestoreKind -eq 'app') {
                $current = @(Get-CimInstance Win32_Process | Where-Object { $_.ExecutablePath -eq $action.ExePath })
                if ($current.Count) { $record.RestoreDetail = '程序已在运行，未重复启动。' }
                else {
                    $newProcess = Start-Process -FilePath $action.ExePath -WorkingDirectory (Split-Path $action.ExePath -Parent) -PassThru -WindowStyle Hidden
                    Start-Sleep -Milliseconds 800
                    $newProcess.Refresh()
                    if ($newProcess.HasExited) { throw '启动进程已退出；可能转交给其他实例，请手动确认。' }
                    $record.RestoreDetail = '已重新启动；请手动恢复原文件、窗口和任务上下文。'
                }
            } else { throw '未知恢复类型。' }
            $record.Restored = $true
        } catch { $record.RestoreDetail = $_.Exception.Message }
        Write-RMJson $journal $SessionPath
    }
    $journal
}

function Export-RMReport {
    param([Parameter(Mandatory)]$Snapshot, [Parameter(Mandatory)][string]$Path)
    $rows = foreach ($app in @($Snapshot.Apps)) {
        $cells = @($app.Label, $app.Name, $app.ResidentMB, $app.ProcessCount, $app.Classification, $app.Reason, $app.ExePath, $app.Id) |
            ForEach-Object { '<td>' + [Net.WebUtility]::HtmlEncode([string]$_) + '</td>' }
        '<tr>' + ($cells -join '') + '</tr>'
    }
    $html = @"
<!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>ResearchMode 扫描报告</title><style>
body{font:15px/1.6 system-ui,sans-serif;background:#f5f7fa;color:#172534;margin:32px}h1{margin-bottom:4px}p{max-width:960px}
.summary{display:flex;gap:16px;flex-wrap:wrap;margin:24px 0}.card{background:white;padding:16px 24px;border-radius:12px;border:1px solid #dfe5eb}
.table{overflow:auto;background:white;border:1px solid #dfe5eb;border-radius:12px}table{border-collapse:collapse;width:100%}th,td{text-align:left;padding:12px;border-bottom:1px solid #e7ecf0;vertical-align:top}th{background:#eaf0f7;white-space:nowrap}td:nth-child(7){word-break:break-all;min-width:240px}td:nth-child(6){min-width:260px}code{background:#eaf0f7;padding:2px 5px}
</style><h1>ResearchMode · 科研模式</h1><p>本地扫描报告 · $([Net.WebUtility]::HtmlEncode($Snapshot.CapturedUtc))</p>
<div class="summary"><div class="card">可用内存 <b>$($Snapshot.Memory.AvailableMB) MB</b></div><div class="card">已用内存 <b>$($Snapshot.Memory.UsedMB) MB</b></div><div class="card">进程 <b>$($Snapshot.ProcessCount)</b></div></div>
<p>candidate＝可审查候选，review＝需要核实，keep＝建议保留，manual＝通过厂商入口手动处理，protected＝本版本不操作，unresolved＝身份不可读。所有候选均需审查批准。数值是驻留工作集，可能含共享页面，不能直接相加为总占用或预计释放量。</p>
<div class="table"><table><thead><tr><th>应用</th><th>进程名</th><th>内存 MB</th><th>进程数</th><th>分类</th><th>依据／影响</th><th>本机路径</th><th>Id</th></tr></thead><tbody>$($rows -join "`n")</tbody></table></div>
<p>此报告包含本机路径。分享前请自行脱敏；工具不会上传报告。该报告只读，不能从网页执行关闭操作。</p></html>
"@
    $directory = Split-Path ([IO.Path]::GetFullPath($Path)) -Parent
    if (-not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
    [IO.File]::WriteAllText([IO.Path]::GetFullPath($Path), $html, (New-Object Text.UTF8Encoding($false)))
    [IO.Path]::GetFullPath($Path)
}

Export-ModuleMember -Function Get-RMDataDirectory, Get-RMSnapshot, New-RMPlan, Invoke-RMPlan, Restore-RMSession, Export-RMReport, Get-RMApprovals, Remove-RMApproval
