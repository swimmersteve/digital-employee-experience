<#
.SYNOPSIS
    Registers (or re-registers) the endpoint health collector as a scheduled task
    that runs every 10 minutes as SYSTEM.

.PARAMETER InstallPath
    Where the collector + dashboard live. The script copies itself alongside if run
    from elsewhere. Default C:\ProgramData\EndpointHealth.

.PARAMETER IntervalMinutes
    Repetition interval. Default 10.

.PARAMETER TaskName
    Default 'EndpointHealth-Collector'.

.PARAMETER Uninstall
    Remove the task (leaves collected data in place).

.EXAMPLE
    # From an elevated PowerShell prompt, in the folder containing the scripts:
    .\Install-EndpointHealthTask.ps1

.EXAMPLE
    .\Install-EndpointHealthTask.ps1 -Uninstall

.NOTES
    Must be run elevated. Task runs as SYSTEM so it can read all three logs
    regardless of who is signed in.
#>
[CmdletBinding()]
param(
    [string] $InstallPath     = (Join-Path $env:ProgramData 'EndpointHealth'),
    [int]    $IntervalMinutes = 10,
    [string] $TaskName        = 'EndpointHealth-Collector',
    [int]    $RetentionDays   = 30,
    [switch] $Uninstall
)

Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'

# --- Survive being pasted into a console ----------------------------------
# When this file is PASTED into a PowerShell window rather than run as a file,
# the param() block above is parsed but never *bound*, so every parameter is
# $null and $MyInvocation.MyCommand.Path is empty. That is what produces
#   Cannot bind argument to parameter 'Path' because it is null
# hundreds of lines later, with no line number attached. Re-apply the defaults
# here so both ways of running work.
# Test-Path variable: rather than the variable itself, because Set-StrictMode
# makes reading an unset variable a terminating error -- which is the very
# state we are trying to recover from. -or short-circuits, so the second half
# is only evaluated once we know the variable exists.
function Test-Unset {
    param([string] $Name)
    if (-not (Test-Path -LiteralPath "variable:$Name")) { return $true }
    $v = (Get-Variable -Name $Name -ValueOnly)
    if ($null -eq $v) { return $true }
    if ($v -is [string] -and [string]::IsNullOrWhiteSpace($v)) { return $true }
    if ($v -is [int]   -and $v -le 0) { return $true }
    return $false
}

$pasted = $false
if (Test-Unset 'InstallPath')     { $InstallPath     = Join-Path $env:ProgramData 'EndpointHealth'; $pasted = $true }
if (Test-Unset 'TaskName')        { $TaskName        = 'EndpointHealth-Collector'; $pasted = $true }
if (Test-Unset 'IntervalMinutes') { $IntervalMinutes = 10 }
if (Test-Unset 'RetentionDays')   { $RetentionDays   = 30 }
if (Test-Unset 'Uninstall')       { $Uninstall       = $false }
if ($pasted) {
    Write-Host "Note: parameter defaults were not bound (this usually means the script was pasted into the console rather than run as a .ps1 file). Using InstallPath=$InstallPath, TaskName=$TaskName." -ForegroundColor Yellow
}

$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()
          ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { throw 'Run this from an elevated PowerShell prompt.' }

if ($Uninstall) {
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Host "Removed scheduled task '$TaskName'. Data in $InstallPath was left alone." -ForegroundColor Yellow
    } else {
        Write-Host "No task named '$TaskName' found." -ForegroundColor Yellow
    }
    return
}

# --- Stage files -----------------------------------------------------------
if (-not (Test-Path -LiteralPath $InstallPath)) {
    New-Item -Path $InstallPath -ItemType Directory -Force | Out-Null
}

# Null when pasted into the console; fall back to the current directory so the
# staging loop below still finds files sitting next to you.
$here = $null
try { if ($MyInvocation.MyCommand.Path) { $here = Split-Path -Parent $MyInvocation.MyCommand.Path } } catch { }
if ([string]::IsNullOrWhiteSpace([string]$here)) { $here = (Get-Location).ProviderPath }
$missing = @()
foreach ($f in @('Get-EndpointHealth.ps1', 'index.html', 'dashboard.html')) {
    $srcFile = Join-Path $here $f
    $dstFile = Join-Path $InstallPath $f
    if ((Test-Path -LiteralPath $srcFile) -and ($srcFile -ne $dstFile)) {
        Copy-Item -LiteralPath $srcFile -Destination $dstFile -Force
        Write-Host "Copied  $f" -ForegroundColor Green
    } elseif (Test-Path -LiteralPath $dstFile) {
        # Silently leaving an older file in place is how you end up running a
        # version you think you replaced, so say so rather than saying nothing.
        $age = (Get-Item -LiteralPath $dstFile).LastWriteTime
        Write-Host "NOT in this folder: $f -- keeping the existing copy from $($age.ToString('yyyy-MM-dd HH:mm'))" -ForegroundColor Yellow
        $missing += $f
    } else {
        Write-Host "MISSING: $f -- not in this folder and not installed" -ForegroundColor Red
        $missing += $f
    }
}

$collector = Join-Path $InstallPath 'Get-EndpointHealth.ps1'
if (-not (Test-Path -LiteralPath $collector)) {
    throw "Get-EndpointHealth.ps1 not found at $collector, and not in $here. Put all four files in one folder and re-run."
}

# Report the collector version actually installed -- the whole point of the
# warning above is that it may not be the one you just downloaded.
$installedVersion = '(unknown)'
try {
    $verLine = Select-String -LiteralPath $collector -Pattern "^\s*\`$ScriptVersion\s*=\s*'([^']+)'" |
               Select-Object -First 1
    if ($verLine) { $installedVersion = $verLine.Matches[0].Groups[1].Value }
} catch { }
Write-Host "Collector version at install path: $installedVersion" -ForegroundColor Cyan
if ($missing.Count -gt 0) {
    Write-Host "  -> $($missing -join ', ') were not refreshed. If you expected a newer version, copy all files into one folder first." -ForegroundColor Yellow
}

# --- Task definition -------------------------------------------------------
$psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
# NB: not $args -- that is a PowerShell automatic variable, and assigning to it
# is both unreliable and confusing to read.
$taskArgs = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden ' +
            "-File `"$collector`" -DataPath `"$InstallPath`" -RetentionDays $RetentionDays"

$action = New-ScheduledTaskAction -Execute $psExe -Argument $taskArgs -WorkingDirectory $InstallPath

# Repeat forever.
#
# [TimeSpan]::MaxValue is the idiom you see everywhere for this, but it serialises
# to P10675199DT2H48M5S and Task Scheduler rejects it outright on some builds:
#   "The task XML contains a value which is incorrectly formatted or out of range.
#    (10,42):Duration:..."
# Task Scheduler's own representation of "indefinitely" is an EMPTY duration, so
# that is what we set. A definite 10-year fallback covers any build that dislikes
# the empty string too.
function New-RepeatingTrigger {
    param([datetime]$At, [int]$EveryMinutes)

    $t = New-ScheduledTaskTrigger -Once -At $At -RepetitionInterval (New-TimeSpan -Minutes $EveryMinutes)
    try { $t.Repetition.Duration = '' } catch { }
    return $t
}

$tNow = New-RepeatingTrigger -At (Get-Date).AddMinutes(1) -EveryMinutes $IntervalMinutes

# A plain at-startup trigger, no repetition of its own: the repeating trigger above
# resumes by itself after a reboot (that is what -StartWhenAvailable is for), so
# this only exists to take one sample soon after boot. Copying a Repetition object
# onto a boot trigger was what dragged the bad duration in here twice over.
$tBoot = New-ScheduledTaskTrigger -AtStartup
$tBoot.Delay = 'PT2M'

$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest

$settings = New-ScheduledTaskSettingsSet `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 5) `
    -StartWhenAvailable `
    -DontStopIfGoingOnBatteries `
    -AllowStartIfOnBatteries `
    -DontStopOnIdleEnd `
    -RestartCount 2 `
    -RestartInterval (New-TimeSpan -Minutes 5)
$settings.Priority = 7   # below normal; this is background telemetry, not urgent work

if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
}

$desc = "Collects Application/System critical+error events, Diagnosis-PLA alerts, a resource " +
        "sample and Windows Reliability every $IntervalMinutes minutes for the endpoint health dashboard."

try {
    Register-ScheduledTask -TaskName $TaskName -Description $desc `
        -Action $action -Trigger @($tNow, $tBoot) -Principal $principal -Settings $settings | Out-Null
    Write-Host "Registered '$TaskName' (every $IntervalMinutes minutes, indefinitely, as SYSTEM)." -ForegroundColor Green
} catch {
    Write-Host "Indefinite repetition was rejected ($($_.Exception.Message.Trim())). Retrying with a 10-year duration." -ForegroundColor Yellow
    $tNow = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
                -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes) `
                -RepetitionDuration (New-TimeSpan -Days 3650)
    Register-ScheduledTask -TaskName $TaskName -Description $desc `
        -Action $action -Trigger @($tNow, $tBoot) -Principal $principal -Settings $settings | Out-Null
    Write-Host "Registered '$TaskName' (every $IntervalMinutes minutes for 10 years, as SYSTEM)." -ForegroundColor Green
}

# --- First run now ---------------------------------------------------------
Start-ScheduledTask -TaskName $TaskName
Start-Sleep -Seconds 8

Write-Host ''
Write-Host "Data folder : $InstallPath"
Write-Host "Front page  : $(Join-Path $InstallPath 'index.html')       (double-click to open)"
Write-Host "Drill-down  : $(Join-Path $InstallPath 'dashboard.html')"
Write-Host ''
if ($InstallPath -and (Test-Path -LiteralPath $InstallPath)) {
    Get-ChildItem -LiteralPath $InstallPath | Select-Object Name, Length, LastWriteTime | Format-Table -AutoSize
} else {
    Write-Host "Could not list $InstallPath -- the folder is not there." -ForegroundColor Yellow
}
