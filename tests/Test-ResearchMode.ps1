#requires -Version 5.1
[CmdletBinding()]
param([switch]$SkipIntegration)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'src/ResearchMode.psm1') -Force -DisableNameChecking
$module = Get-Module ResearchMode
$script:passed = 0
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('ResearchModeTests-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $scratch | Out-Null
$helperPath = Join-Path $scratch 'ResearchModeProbe.exe'

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "FAIL: $Message" }
    $script:passed++
    Write-Host "PASS: $Message" -ForegroundColor Green
}
function Assert-Throws {
    param([scriptblock]$Block, [string]$Message)
    $caught = $false
    try { & $Block | Out-Null } catch { $caught = $true }
    Assert-True $caught $Message
}
function Get-ProbeCount {
    @(Get-CimInstance Win32_Process | Where-Object { $_.ExecutablePath -eq $helperPath }).Count
}
function Start-Probe {
    $process = Start-Process -FilePath $helperPath -WindowStyle Hidden -PassThru
    Start-Sleep -Milliseconds 350
    $process.Refresh()
    if ($process.HasExited) { throw 'Disposable helper did not start.' }
    $process
}

try {
    $parsed = Get-ChildItem -LiteralPath $root -Recurse -File | Where-Object { $_.Extension -in @('.ps1', '.psm1') }
    foreach ($file in $parsed) {
        $tokens = $null; $errors = $null
        [Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors) | Out-Null
        Assert-True (@($errors).Count -eq 0) ("PowerShell parses " + $file.Name)
    }
    $policy = & $module { Get-RMClassification -Name 'python.exe' -Path 'D:\env\python.exe' }
    Assert-True ($policy.Classification -eq 'protected' -and $policy.Methods.Count -eq 0) 'Python workloads cannot be selected'
    $policy = & $module { Get-RMClassification -Name 'svchost.exe' -Path 'C:\x\svchost.exe' }
    Assert-True ($policy.Classification -eq 'protected') 'System service host cannot be selected by spoofed location'
    $policy = & $module { Get-RMClassification -Name 'wallpaper32.exe' -Path 'D:\Steam\wallpaper32.exe' }
    Assert-True ($policy.Classification -eq 'candidate' -and $policy.Methods -contains 'terminate') 'Wallpaper is a reviewable candidate, including explicit force option'
    $policy = & $module { Get-RMClassification -Name 'avp.exe' -Path '' }
    Assert-True ($policy.Classification -eq 'manual' -and $policy.Methods.Count -eq 0) 'Security software stays explainable without an accessible path'
    $policy = & $module { Get-RMClassification -Name 'unknown.exe' -Path '' }
    Assert-True ($policy.Classification -eq 'unresolved' -and $policy.Methods.Count -eq 0) 'Unreadable identities cannot be operated on'
    $policy = & $module { Get-RMClassification -Name 'wallpaper32.exe' -Path 'D:\app.exe' -IsAncestor $true }
    Assert-True ($policy.Classification -eq 'protected') 'Current execution ancestry overrides optional application rules'
    $policy = & $module {
        Get-RMClassification -Name 'unknown.exe' -Path (Join-Path $env:WINDIR 'System32\unknown.exe')
    }
    Assert-True ($policy.Classification -eq 'protected') 'Unknown Windows components are excluded'
    $policy = & $module {
        Get-RMClassification -Name 'platform_runtime_RGB_service.exe' -Path (Join-Path $env:WINDIR 'System32\drivers\tobii.exe') -Services @([pscustomobject]@{Name='TobiiRGB'})
    }
    Assert-True ($policy.Classification -eq 'review' -and $policy.Methods[0] -eq 'service') 'Identified Tobii service is reviewable, not misclassified as lighting'
    $policy = & $module {
        Get-RMClassification -Name 'app.exe' -Path 'D:\app.exe' -Services @([pscustomobject]@{Name='A'},[pscustomobject]@{Name='B'})
    }
    Assert-True ($policy.Classification -eq 'protected') 'Shared service processes are excluded'
    $ancestors = & $module {
        $p = @([pscustomobject]@{ProcessId=10;ParentProcessId=20},[pscustomobject]@{ProcessId=20;ParentProcessId=10})
        Get-RMProtectedProcessIds -Processes $p -CurrentId 10
    }
    Assert-True (@($ancestors).Count -eq 2) 'Ancestry traversal tolerates cycles in a snapshot'
    Assert-Throws { & $module { Assert-RMServiceStop ([pscustomobject]@{Status='Running';CanStop=$true}) @([pscustomobject]@{Name='Dependent'}) } } 'Running service dependents block stop'
    Assert-Throws { & $module { Assert-RMServiceStop ([pscustomobject]@{Status='Running';CanStop=$false}) @() } } 'Protected services do not fall back to killing'

    $fakeFile = Join-Path $scratch 'identity.exe'
    [IO.File]::WriteAllText($fakeFile, 'version one')
    $app = [pscustomobject]@{
        Id='test-id'; Name='identity.exe'; Label='<script>alert(1)</script>'; ExePath=$fakeFile
        Methods=@('terminate'); Classification='review'; Reason='test & explain'; Services=@()
        ResidentMB=1; ProcessCount=1; Processes=@([pscustomobject]@{ProcessId=999;StartedUtc='2026-01-01T00:00:00.0000000Z'})
    }
    $fingerprint = & $module { param($a) Get-RMFingerprint $a } $app
    $action = [pscustomobject]@{Id=$app.Id;Name=$app.Name;ExePath=$app.ExePath;Method='terminate';Fingerprint=$fingerprint;Processes=$app.Processes;Services=@()}
    $app.Processes = @([pscustomobject]@{ProcessId=999;StartedUtc='2026-01-02T00:00:00.0000000Z'})
    Assert-Throws { & $module {param($a,$b) Assert-RMActionIdentity $a $b} $action $app } 'Reused PID with a different start time is rejected'
    $app.Processes = $action.Processes
    [IO.File]::WriteAllText($fakeFile, 'version two')
    Assert-Throws { & $module {param($a,$b) Assert-RMActionIdentity $a $b} $action $app } 'File changes invalidate reviewed identity'
    $app.Processes = $action.Processes
    $htmlPath = Join-Path $scratch 'report.html'
    $fakeSnapshot = [pscustomobject]@{CapturedUtc='now';Memory=[pscustomobject]@{AvailableMB=1;UsedMB=2};ProcessCount=1;Apps=@($app)}
    Export-RMReport $fakeSnapshot $htmlPath | Out-Null
    $html = [IO.File]::ReadAllText($htmlPath)
    Assert-True ($html.Contains('&lt;script&gt;') -and -not $html.Contains('<script>alert')) 'HTML report escapes application-controlled text'
    $fakeData = Join-Path $scratch 'fake-data'
    & $module {param($dir,$fp) Write-RMJson @([pscustomobject]@{Id='test-id';Name='identity.exe';Method='terminate';Fingerprint=$fp;ApprovedUtc='now'}) (Join-Path $dir 'approvals.json')} $fakeData $fingerprint
    Assert-Throws { New-RMPlan -Snapshot $fakeSnapshot -UseSaved -DataDirectory $fakeData -WarningAction SilentlyContinue } 'Saved approval is invalidated by changed executable contents'
    Remove-RMApproval -Id 'test-id' -DataDirectory $fakeData
    Assert-True (@(Get-RMApprovals $fakeData).Count -eq 0) 'Revoking the last approval persists an empty list'
    $dateFile = Join-Path $scratch 'date.json'
    & $module {param($p) Write-RMJson ([pscustomobject]@{Time=[DateTime]::UtcNow.ToString('o')}) $p} $dateFile
    $dateValue = & $module {param($p) Read-RMJson $p} $dateFile
    Assert-True ($dateValue.Time -is [string] -and $dateValue.Time.EndsWith('Z')) 'Journal ISO timestamps retain their UTC string identity across PowerShell versions'
    $stampMatch = & $module {
        $time = [DateTime]::UtcNow
        (Get-RMStartStamp $time) -eq (Get-RMStartStamp ($time.AddTicks(-($time.Ticks % 10))))
    }
    Assert-True $stampMatch 'CIM and Process start times compare at their common microsecond precision'

    if (-not $SkipIntegration) {
        $source = Join-Path $scratch 'Probe.cs'
        [IO.File]::WriteAllText($source, 'using System.Threading; class ResearchModeProbe { static void Main() { Thread.Sleep(1800000); } }')
        $compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
        if (-not (Test-Path -LiteralPath $compiler)) { throw "Missing integration-test compiler: $compiler" }
        & $compiler /nologo /target:exe "/out:$helperPath" $source
        if ($LASTEXITCODE -ne 0) { throw 'Disposable helper compilation failed.' }
        $first = Start-Probe
        $snapshot = Get-RMSnapshot
        $found = @($snapshot.Apps | Where-Object ExePath -eq $helperPath)
        Assert-True ($found.Count -eq 1) 'Live scan discovers the disposable helper by path'
        $data = Join-Path $scratch 'state'
        $normal = New-RMPlan -Ids @($found[0].Id) -Method close -Snapshot $snapshot -DataDirectory $data
        $normalRun = Invoke-RMPlan -PlanPath $normal.Path -PlanHash $normal.PlanHash -Approved -DataDirectory $data -Confirm:$false
        $first.Refresh()
        Assert-True (-not $first.HasExited -and $normalRun.Session.Actions[0].State -eq 'not-stopped') 'Normal close never escalates to force for an application without a window'
        $plan = New-RMPlan -Ids @($found[0].Id) -Method terminate -Remember -Snapshot $snapshot -DataDirectory $data
        Assert-Throws { Invoke-RMPlan -PlanPath $plan.Path -PlanHash $plan.PlanHash -DataDirectory $data } 'Apply requires explicit authorization'
        Assert-Throws { Invoke-RMPlan -PlanPath $plan.Path -PlanHash 'wrong-hash' -Approved -DataDirectory $data } 'Apply rejects an unreviewed or changed plan file'
        Invoke-RMPlan -PlanPath $plan.Path -DataDirectory $data -WhatIf | Out-Null
        $first.Refresh()
        Assert-True (-not $first.HasExited) 'WhatIf leaves the live process running'
        $previewSession = Join-Path (Join-Path $data 'sessions') ($plan.Plan.PlanId + '.json')
        Assert-True (-not (Test-Path -LiteralPath $previewSession)) 'WhatIf writes no execution journal'
        $second = Start-Probe
        $run = Invoke-RMPlan -PlanPath $plan.Path -PlanHash $plan.PlanHash -Approved -DataDirectory $data -Confirm:$false
        $first.Refresh(); $second.Refresh()
        Assert-True ($first.HasExited -and -not $second.HasExited) 'Only reviewed instances stop; a newly started instance survives'
        Assert-True ($run.Session.Actions[0].State -eq 'stopped') 'Successful stop is recorded'
        Assert-True (@(Get-RMApprovals $data).Count -eq 1) 'Explicit remember preference is stored'
        Assert-Throws { Invoke-RMPlan -PlanPath $plan.Path -PlanHash $plan.PlanHash -Approved -DataDirectory $data } 'A consumed plan cannot execute twice'
        Restore-RMSession -SessionPath $run.Path -Approved -Confirm:$false | Out-Null
        Assert-True ((Get-ProbeCount) -eq 1) 'Restore does not duplicate an already running application'
        $next = New-RMPlan -UseSaved -DataDirectory $data
        $run2 = Invoke-RMPlan -PlanPath $next.Path -PlanHash $next.PlanHash -Approved -DataDirectory $data -Confirm:$false
        Assert-True ((Get-ProbeCount) -eq 0) 'Saved approval selects a fresh instance of the same verified binary'
        Assert-Throws { Restore-RMSession -SessionPath $run2.Path } 'Restore requires authorization too'
        Restore-RMSession -SessionPath $run2.Path -WhatIf | Out-Null
        Assert-True ((Get-ProbeCount) -eq 0) 'Restore WhatIf starts no process'
        $restored = Restore-RMSession -SessionPath $run2.Path -Approved -Confirm:$false
        Assert-True ($restored.Actions[0].Restored -and (Get-ProbeCount) -eq 1) 'Restore really restarts the stopped helper'
        Restore-RMSession -SessionPath $run2.Path -Approved -Confirm:$false | Out-Null
        Assert-True ((Get-ProbeCount) -eq 1) 'Repeated restore is idempotent'
        $stale = New-RMPlan -UseSaved -DataDirectory $data
        Get-CimInstance Win32_Process | Where-Object ExecutablePath -eq $helperPath | ForEach-Object {
            $probe = Get-Process -Id $_.ProcessId
            $probe.Kill()
            if (-not $probe.WaitForExit(5000)) { throw 'Test helper did not exit.' }
        }
        Assert-Throws { Invoke-RMPlan -PlanPath $stale.Path -PlanHash $stale.PlanHash -Approved -DataDirectory $data } 'Exited targets invalidate the old plan before execution'
        $expired = Get-Content -LiteralPath $stale.Path -Raw -Encoding UTF8 | ConvertFrom-Json
        $expired.ExpiresUtc = [DateTime]::UtcNow.AddMinutes(-1).ToString('o')
        & $module {param($v,$p) Write-RMJson $v $p} $expired $stale.Path
        Assert-Throws { Invoke-RMPlan -PlanPath $stale.Path -Approved -DataDirectory $data } 'Expired plans require a new scan'
    }
    Write-Host "`n$script:passed checks passed on PowerShell $($PSVersionTable.PSVersion)." -ForegroundColor Cyan
} finally {
    # Only helpers created under this test's unique directory may be stopped.
    Get-CimInstance Win32_Process | Where-Object { $_.ExecutablePath -eq $helperPath } | ForEach-Object { Stop-Process -Id $_.ProcessId -ErrorAction SilentlyContinue }
    $resolved = [IO.Path]::GetFullPath($scratch)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if ($resolved.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -and (Split-Path $resolved -Leaf) -like 'ResearchModeTests-*') {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
