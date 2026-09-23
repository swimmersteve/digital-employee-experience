<#
.SYNOPSIS
    Lightweight endpoint health collector. Pulls new Critical/Error events from the
    Application and System logs, everything from Microsoft-Windows-Diagnosis-PLA/Operational,
    a resource-usage sample, the top processes by memory and by CPU, and boot/logon
    durations.
    De-duplicates against the previous run and maintains a rolling store plus the JS
    payloads the local HTML dashboard reads.

.DESCRIPTION
    Designed to run every 10 minutes from Task Scheduler. Each run is incremental:
    a watermark (the last EventRecordID seen per log) is persisted in state.json so
    nothing is ever written twice, even if the schedule slips or a run overlaps.

    Deliberately does NOT read C:\PerfLogs\*.blg. A Data Collector Set writing
    wildcard Process(*) / GPU Engine(*) counters produces on the order of a gigabyte
    a day, and re-scanning a 300 MB binary log every 10 minutes to recover the last
    10 minutes is orders of magnitude more expensive than sampling the same counters
    live. Get-Counter costs about a second per run.

    Output files, all under -DataPath (default C:\ProgramData\EndpointHealth):
      events.ndjson  Event store, one JSON object per line, rolling retention.
      data.js        Append-only mirror of events.ndjson for the dashboard.
      perf.ndjson    Usage samples + boot/logon records, same rolling retention.
      perf.js        Append-only mirror of perf.ndjson for the dashboard.
      meta.js        Tiny header rewritten each run: host, uptime, last run, counters.
      status.js      Small front-page payload, rewritten each run; index.html polls it.
                     Carries the signed-in user and the Reliability index as well.
      state.json     Watermarks and per-process CPU baselines.
      collector.log  Rolling operational log for the collector itself.

.PARAMETER DataPath
    Directory for all output. Created if missing.

.PARAMETER RetentionDays
    Rolling window kept in the stores. Default 30.

.PARAMETER InitialLookbackHours
    On the very first run (no state.json), how far back to seed. Default 24.

.PARAMETER MaxEventsPerLog
    Safety cap per log per run so a noisy machine can't produce a huge write.

.PARAMETER PlaLevels
    Levels to keep from the Diagnosis-PLA channel. Default is all levels.
    Pass 1,2,3 to restrict to Critical/Error/Warning.

.PARAMETER TopProcessCount
    How many processes (grouped by name) to record per sample, for EACH ranking.
    Default 10, i.e. the top 10 by memory plus the top 10 by CPU, de-duplicated.

.PARAMETER CounterPaths
    Override the performance counters sampled. Counter paths are LOCALISED by
    Windows display language -- the defaults are the English names. On a non-English
    build, pass the localised paths here or the sample is skipped (and logged).

.PARAMETER StatusWindowMinutes
    How much recent history status.js carries for the front page. Default 60.
    The front page's evaluation window cannot exceed this, so raise it if you add
    a longer option to the picker.

.PARAMETER RelHistoryDays
    How many days of Windows Reliability history to publish. Default 30. Reliability
    Monitor itself only retains about 28 days, so asking for more simply yields what
    it has.

.PARAMETER SkipPerf
    Collect events only; no Get-Counter sample, no process list.

.EXAMPLE
    .\Get-EndpointHealth.ps1
    .\Get-EndpointHealth.ps1 -DataPath D:\Health -RetentionDays 7 -Verbose
    .\Get-EndpointHealth.ps1 -SkipPerf -TopProcessCount 10

.NOTES
    Version 1.6.1  |  Requires PowerShell 5.1+  |  Run elevated / as SYSTEM.
#>
[CmdletBinding()]
param(
    [string]   $DataPath             = (Join-Path $env:ProgramData 'EndpointHealth'),
    [int]      $RetentionDays        = 30,
    [int]      $InitialLookbackHours = 24,
    [int]      $MaxEventsPerLog      = 1000,
    [int[]]    $PlaLevels            = @(),
    [int]      $MessageMaxChars      = 400,
    [int]      $TopProcessCount      = 10,
    [string[]] $CounterPaths         = @(),
    [int]      $StatusWindowMinutes  = 60,
    [int]      $RelHistoryDays       = 30,
    [switch]   $SkipPerf
)

# StrictMode 1.0 catches the useful mistake (an undefined variable) without making
# every $null.Count on a quiet run a fatal error. Do not raise this to Latest/3.0
# unless you also re-audit every .Count in the script -- PowerShell returns $null,
# not an empty array, from a function whose output stream is empty.
Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'

$ScriptVersion = '1.7.0'
$PlaLogName    = 'Microsoft-Windows-Diagnosis-PLA/Operational'
$DiagPerfLog   = 'Microsoft-Windows-Diagnostics-Performance/Operational'

# Boot / shutdown / logon performance summary events in the Diagnostics-Performance
# channel. The interesting numbers live in named EventData fields, so rather than
# hard-coding a field list per ID we keep every named field whose name looks like a
# duration -- that survives the differences between Windows builds.
$DiagPerfIds   = @(100, 200, 300)

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
if (-not (Test-Path -LiteralPath $DataPath)) {
    New-Item -Path $DataPath -ItemType Directory -Force | Out-Null
}
$EventsFile = Join-Path $DataPath 'events.ndjson'
$DataJsFile = Join-Path $DataPath 'data.js'
$PerfFile   = Join-Path $DataPath 'perf.ndjson'
$PerfJsFile = Join-Path $DataPath 'perf.js'
$MetaJsFile = Join-Path $DataPath 'meta.js'
$StatusJsFile = Join-Path $DataPath 'status.js'
$StateFile  = Join-Path $DataPath 'state.json'
$LogFile    = Join-Path $DataPath 'collector.log'

$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$RunStart  = Get-Date

function ConvertTo-Utc {
    <#
      Normalises a timestamp to a UTC DateTime, whatever form it arrives in.

      This must NOT be typed [string]: ConvertFrom-Json silently re-hydrates any
      ISO-8601-looking string into a [datetime], so values read back out of
      state.json and the ndjson stores are DateTime objects, not strings. Coercing
      those to string uses the current culture, loses the zone, and the resulting
      window lands hours in the future -- which quietly stops collection dead.
    #>
    param($Value, [datetime]$Default)

    if ($null -eq $Value) { return $Default }

    if ($Value -is [datetime]) {
        if ($Value.Kind -eq [System.DateTimeKind]::Unspecified) {
            # We only ever write UTC, so treat an unlabelled value as UTC.
            return [datetime]::SpecifyKind($Value, [System.DateTimeKind]::Utc)
        }
        return $Value.ToUniversalTime()
    }
    if ($Value -is [datetimeoffset]) { return $Value.UtcDateTime }

    $s = [string]$Value
    if ([string]::IsNullOrWhiteSpace($s)) { return $Default }
    try {
        return ([datetime]::Parse($s, [System.Globalization.CultureInfo]::InvariantCulture,
                [System.Globalization.DateTimeStyles]::RoundtripKind)).ToUniversalTime()
    } catch { return $Default }
}

function Get-UtcStamp { param([datetime]$When = (Get-Date)) $When.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }

function Write-Log {
    param([string]$Message, [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level = 'INFO')
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Write-Verbose $line
    try { [System.IO.File]::AppendAllLines($LogFile, [string[]]@($line), $Utf8NoBom) } catch { }
}

# ---------------------------------------------------------------------------
# State (watermarks + per-process CPU baselines)
# ---------------------------------------------------------------------------
function Get-CollectorState {
    if (Test-Path -LiteralPath $StateFile) {
        try {
            $raw = Get-Content -LiteralPath $StateFile -Raw -Encoding UTF8
            if ($raw.Trim()) { return ($raw | ConvertFrom-Json) }
        } catch {
            Write-Log "state.json unreadable ($($_.Exception.Message)); re-seeding." 'WARN'
        }
    }
    return $null
}

function Save-CollectorState {
    param($State)
    ($State | ConvertTo-Json -Depth 6 -Compress) |
        Set-Content -LiteralPath $StateFile -Encoding UTF8 -Force
}

function Set-StateProperty {
    param($Object, [string]$Name, $Value)
    if ($Object.PSObject.Properties.Name -contains $Name) { $Object.$Name = $Value }
    else { Add-Member -InputObject $Object -NotePropertyName $Name -NotePropertyValue $Value }
}

function Get-StateProperty {
    param($Object, [string]$Name, $Default = $null)
    if ($Object -and ($Object.PSObject.Properties.Name -contains $Name)) { return $Object.$Name }
    return $Default
}

$state = Get-CollectorState
if (-not $state) {
    $seed  = $RunStart.AddHours(-1 * [Math]::Abs($InitialLookbackHours))
    $state = [pscustomobject]@{
        Version     = $ScriptVersion
        FirstRunUtc = (Get-UtcStamp $RunStart)
        LastRunUtc  = $null
        LastTrimUtc = $null
        ProcCpu     = [pscustomobject]@{}
        ProcCpuAt   = $null
        Logs        = [pscustomobject]@{}
    }
    foreach ($ln in @('Application', 'System', $PlaLogName, $DiagPerfLog)) {
        Add-Member -InputObject $state.Logs -NotePropertyName $ln -NotePropertyValue ([pscustomobject]@{
            LastRecordId = [int64]0
            LastTimeUtc  = (Get-UtcStamp $seed)
        })
    }
    Write-Log "No prior state. Seeding from $($seed.ToString('u'))."
}

function Get-LogState {
    param([string]$LogName)
    if (-not ($state.Logs.PSObject.Properties.Name -contains $LogName)) {
        Add-Member -InputObject $state.Logs -NotePropertyName $LogName -NotePropertyValue ([pscustomobject]@{
            LastRecordId = [int64]0
            LastTimeUtc  = (Get-UtcStamp $RunStart.AddHours(-1 * [Math]::Abs($InitialLookbackHours)))
        })
    }
    return $state.Logs.$LogName
}

# ---------------------------------------------------------------------------
# Event collection
# ---------------------------------------------------------------------------
$LevelNames = @{ 0 = 'Information'; 1 = 'Critical'; 2 = 'Error'; 3 = 'Warning'; 4 = 'Information'; 5 = 'Verbose' }

function Get-NewLogEvents {
    <#
      Returns new events from one log, de-duplicated by EventRecordID.
      Query window = watermark time minus a 5-minute overlap (events can be written
      slightly out of order); the RecordID filter is what actually guarantees no dupes.

      NOTE ON RETURN VALUES: a function whose output stream is empty yields $null,
      not an empty array. Every call site therefore wraps the call in @().
    #>
    param(
        [Parameter(Mandatory)][string] $LogName,
        [int[]]  $Levels,
        [int[]]  $Ids,
        [switch] $IncludeMessage,
        [switch] $IncludeData
    )

    $ls        = Get-LogState -LogName $LogName
    $startTime = (ConvertTo-Utc -Value $ls.LastTimeUtc -Default $RunStart.ToUniversalTime().AddHours(-24)).ToLocalTime().AddMinutes(-5)
    $lastId    = [int64]$ls.LastRecordId

    $filter = @{ LogName = $LogName; StartTime = $startTime }
    if ($Levels -and @($Levels).Count -gt 0) { $filter['Level'] = $Levels }
    if ($Ids    -and @($Ids).Count    -gt 0) { $filter['Id']    = $Ids }

    $raw = @()
    try {
        $raw = @(Get-WinEvent -FilterHashtable $filter -MaxEvents $MaxEventsPerLog -ErrorAction Stop)
    } catch [System.Exception] {
        # "No events were found" is the normal quiet case, not a failure.
        if ($_.Exception.Message -notmatch 'No events were found') {
            Write-Log "Query failed for '$LogName': $($_.Exception.Message)" 'WARN'
        }
        return @()
    }

    if ($raw.Count -eq 0) { return @() }

    # Log-cleared detection: record IDs restart at 1, so the watermark is stale.
    $maxId = ($raw | Measure-Object -Property RecordId -Maximum).Maximum
    if ($maxId -lt $lastId) {
        Write-Log "'$LogName' appears to have been cleared (max RecordId $maxId < watermark $lastId). Resetting watermark." 'WARN'
        $lastId = 0
    }

    $new = @($raw | Where-Object { $_.RecordId -gt $lastId } | Sort-Object RecordId)
    if ($new.Count -eq 0) { return @() }

    $out = New-Object System.Collections.Generic.List[object]
    foreach ($e in $new) {
        $lvl = if ($LevelNames.ContainsKey([int]$e.Level)) { $LevelNames[[int]$e.Level] } else { "Level$($e.Level)" }

        $rec = [ordered]@{
            t   = (Get-UtcStamp $e.TimeCreated)
            log = $LogName
            lvl = $lvl
            src = $e.ProviderName
            id  = [int]$e.Id
            rid = [int64]$e.RecordId
        }

        if ($IncludeMessage) {
            $msg = $null
            try { $msg = $e.Message } catch { $msg = $null }
            if ($msg) {
                $msg = ($msg -replace '\s+', ' ').Trim()
                if ($msg.Length -gt $MessageMaxChars) { $msg = $msg.Substring(0, $MessageMaxChars) + '...' }
            }
            $rec['msg'] = $msg
        }

        if ($IncludeData) {
            # Pull the named EventData fields straight out of the event XML. Field
            # names differ across Windows builds, so take them all rather than
            # assuming a fixed schema, and keep only numeric ones.
            $data = [ordered]@{}
            try {
                $xml = [xml]$e.ToXml()
                foreach ($d in @($xml.Event.EventData.Data)) {
                    if (-not $d) { continue }
                    $name = [string]$d.Name
                    $val  = [string]$d.'#text'
                    if ([string]::IsNullOrWhiteSpace($name)) { continue }
                    $num = 0L
                    if ([int64]::TryParse($val, [ref]$num)) { $data[$name] = $num }
                }
            } catch { Write-Log "Could not parse EventData for $LogName/$($e.Id): $($_.Exception.Message)" 'WARN' }
            $rec['data'] = [pscustomobject]$data
        }

        $out.Add([pscustomobject]$rec)
    }

    # Advance the watermark.
    $ls.LastRecordId = [int64](($new | Measure-Object -Property RecordId -Maximum).Maximum)
    $ls.LastTimeUtc  = (Get-UtcStamp ($new | Measure-Object -Property TimeCreated -Maximum).Maximum)

    if ($raw.Count -ge $MaxEventsPerLog) {
        Write-Log "'$LogName' hit the $MaxEventsPerLog-event cap this run; remaining events roll into the next run." 'WARN'
    }

    return $out.ToArray()
}

$collected = New-Object System.Collections.Generic.List[object]

foreach ($log in @('Application', 'System')) {
    $ev = @(Get-NewLogEvents -LogName $log -Levels @(1, 2))     # 1 = Critical, 2 = Error
    if ($ev.Count -gt 0) { $collected.AddRange([object[]]$ev) }
    Write-Log "$log : $($ev.Count) new critical/error event(s)."
}

$plaEvents = @(Get-NewLogEvents -LogName $PlaLogName -Levels $PlaLevels -IncludeMessage)
if ($plaEvents.Count -gt 0) { $collected.AddRange([object[]]$plaEvents) }
Write-Log "$PlaLogName : $($plaEvents.Count) new event(s)."

# ---------------------------------------------------------------------------
# Machine facts (also feeds the memory-percentage calculation below)
# ---------------------------------------------------------------------------
$os         = $null
$lastBoot   = $null
$totalMemMB = $null
try {
    $os         = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
    $lastBoot   = (Get-UtcStamp $os.LastBootUpTime)
    $totalMemMB = [math]::Round($os.TotalVisibleMemorySize / 1KB, 0)
} catch { Write-Log "Could not read Win32_OperatingSystem: $($_.Exception.Message)" 'WARN' }

$cores = 1
try { $cores = [int]$env:NUMBER_OF_PROCESSORS } catch { }
if ($cores -lt 1) { $cores = 1 }

# Who is actually signed in. The task runs as SYSTEM, so $env:USERNAME is useless
# here -- Win32_ComputerSystem.UserName is the interactive console user, and is
# empty when nobody is signed in or when the only sessions are RDP.
$consoleUser = $null
try {
    $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
    if ($cs.UserName) { $consoleUser = [string]$cs.UserName }
} catch { Write-Log "Could not read the console user: $($_.Exception.Message)" 'WARN' }

# Windows Reliability Monitor's System Stability Index (0-10, one value per day).
# Win32_ReliabilityStabilityMetrics is comparatively slow, and the number only
# changes daily, so it is cached in state and re-queried at most hourly.
$relScore = Get-StateProperty -Object $state -Name 'RelScore'
$relDate  = Get-StateProperty -Object $state -Name 'RelDate'
$relAt    = ConvertTo-Utc -Value (Get-StateProperty -Object $state -Name 'RelAt') -Default ([datetime]::MinValue)

$relHist  = Get-StateProperty -Object $state -Name 'RelHist'

# Re-query when the cache is cold OR when there is no history yet. Upgrading from a
# version that cached RelScore but not RelHist would otherwise sit on a warm
# timestamp and never fetch the history at all.
$relStale = ($relAt -lt $RunStart.ToUniversalTime().AddHours(-1)) -or
            (@($relHist | Where-Object { $null -ne $_ }).Count -eq 0)

if ($relStale) {
    try {
        # The class already retains roughly 28 days of daily values, so the whole
        # history comes back in the same query as the latest one -- there is nothing
        # to accumulate over time.
        $rows = @(Get-CimInstance -ClassName Win32_ReliabilityStabilityMetrics -ErrorAction Stop |
                  Where-Object { $null -ne $_.SystemStabilityIndex })

        if ($rows.Count -gt 0) {
            # Collapse to one value per day: some builds emit more than one row a day.
            $byDay = [ordered]@{}
            foreach ($r in $rows) {
                $d = ConvertTo-Utc -Value $r.TimeGenerated -Default ([datetime]::MinValue)
                if ($d -eq [datetime]::MinValue) { continue }
                $key = $d.ToString('yyyy-MM-dd')
                $byDay[$key] = [pscustomobject]@{ t = $d; v = [math]::Round([double]$r.SystemStabilityIndex, 2) }
            }

            $ordered = @($byDay.Values | Sort-Object t)
            if ($ordered.Count -gt $RelHistoryDays) {
                $ordered = @($ordered[($ordered.Count - $RelHistoryDays)..($ordered.Count - 1)])
            }

            # Objects, not [t,v] pairs: ConvertTo-Json flattens a ONE-element array
            # of pairs from [[t,v]] to [t,v], which the page then cannot tell from a
            # single pair. {t,v} has no such ambiguity at any length.
            $acc = New-Object System.Collections.Generic.List[object]
            foreach ($p in $ordered) {
                $acc.Add([pscustomobject][ordered]@{
                    t = [int64]([DateTimeOffset]$p.t).ToUnixTimeSeconds()
                    v = [double]$p.v
                })
            }
            $relHist = $acc.ToArray()

            $newest  = $ordered[$ordered.Count - 1]
            $relScore = [math]::Round([double]$newest.v, 1)
            $relDate  = (Get-UtcStamp $newest.t)
            Write-Log "Reliability index $relScore (as of $relDate); $($relHist.Count) day(s) of history."
        } else {
            Write-Log 'Reliability metrics returned no rows. The RacTask scheduled task may be disabled.' 'WARN'
        }
    } catch {
        Write-Log "Reliability metrics unavailable: $($_.Exception.Message)" 'WARN'
    }
    Set-StateProperty -Object $state -Name 'RelAt' -Value (Get-UtcStamp $RunStart)
}
Set-StateProperty -Object $state -Name 'RelScore' -Value $relScore
Set-StateProperty -Object $state -Name 'RelDate'  -Value $relDate
Set-StateProperty -Object $state -Name 'RelHist'  -Value $relHist

# ---------------------------------------------------------------------------
# Performance sample
# ---------------------------------------------------------------------------
$perfRecords = New-Object System.Collections.Generic.List[object]

function Get-SampleValue {
    param($Samples, [string]$Pattern, [switch]$Sum)
    $hits = @($Samples | Where-Object { $_.Path -like $Pattern })
    if ($hits.Count -eq 0) { return $null }
    if ($Sum) { return ($hits | Measure-Object -Property CookedValue -Sum).Sum }
    return $hits[0].CookedValue
}

function Get-PerfSample {
    $paths = @(
        '\Processor Information(_Total)\% Processor Time'
        '\Memory\Available MBytes'
        '\LogicalDisk(_Total)\% Idle Time'
        '\LogicalDisk(_Total)\% Disk Time'
        '\LogicalDisk(_Total)\Avg. Disk sec/Transfer'
        '\LogicalDisk(_Total)\Current Disk Queue Length'
        '\Network Interface(*)\Bytes Total/sec'
    )
    if ($CounterPaths -and @($CounterPaths).Count -gt 0) { $paths = @($CounterPaths) }

    # Two samples one second apart: rate counters (% Processor Time especially) need
    # a delta, and a single-sample read can legitimately come back as zero.
    $samples = @()
    try {
        $r = @(Get-Counter -Counter $paths -SampleInterval 1 -MaxSamples 2 -ErrorAction Stop)
        $samples = @($r[-1].CounterSamples)
    } catch {
        # One bad path shouldn't cost the whole sample -- retry individually.
        Write-Log "Bulk Get-Counter failed ($($_.Exception.Message)); retrying per counter." 'WARN'
        $acc = New-Object System.Collections.Generic.List[object]
        foreach ($p in $paths) {
            try {
                $one = @(Get-Counter -Counter $p -SampleInterval 1 -MaxSamples 2 -ErrorAction Stop)
                $acc.AddRange([object[]]@($one[-1].CounterSamples))
            } catch {
                Write-Log "Counter unavailable: $p" 'WARN'
            }
        }
        $samples = @($acc.ToArray())
    }

    if ($samples.Count -eq 0) {
        Write-Log 'No performance counters could be read. On a non-English Windows build, pass localised paths via -CounterPaths.' 'WARN'
        return $null
    }

    $availMB = Get-SampleValue -Samples $samples -Pattern '*\available mbytes'
    $diskSec = Get-SampleValue -Samples $samples -Pattern '*\avg. disk sec/transfer'
    $netBps  = @($samples | Where-Object {
                    $_.Path -like '*\bytes total/sec' -and
                    $_.InstanceName -notmatch 'loopback|isatap|teredo|pseudo|filter'
                } | Measure-Object -Property CookedValue -Sum).Sum

    $rec = [ordered]@{
        k   = 'p'
        t   = (Get-UtcStamp $RunStart)
        cpu = $null; memMB = $null; memPct = $null
        dskPct = $null; dskMs = $null; dskQ = $null; netKBs = $null
    }

    $cpu = Get-SampleValue -Samples $samples -Pattern '*\% processor time'
    if ($null -ne $cpu)     { $rec['cpu']    = [math]::Round([double]$cpu, 1) }
    if ($null -ne $availMB) { $rec['memMB']  = [math]::Round([double]$availMB, 0) }
    if (($null -ne $availMB) -and $totalMemMB) {
        $rec['memPct'] = [math]::Round((1 - ([double]$availMB / $totalMemMB)) * 100, 1)
    }
    # Disk busy percentage.
    #
    # '% Disk Time' is the obvious counter and the wrong one: on the _Total
    # instance it is a SUM across the disks, so a two-disk machine reads 180%,
    # and it is derived from the queue length so it overshoots on its own even
    # with one disk. '% Idle Time' is measured directly and averaged across
    # instances, so 100 - idle is the figure that actually means "how much of
    # the interval was this disk working". % Disk Time is kept only as the
    # fallback for builds that do not expose idle time, clamped on the way out.
    $idlePct = Get-SampleValue -Samples $samples -Pattern '*\% idle time'
    $busyPct = Get-SampleValue -Samples $samples -Pattern '*\% disk time'
    $busy    = $null
    if ($null -ne $idlePct)     { $busy = 100 - [double]$idlePct }
    elseif ($null -ne $busyPct) { $busy = [double]$busyPct }
    if ($null -ne $busy) {
        if ($busy -lt 0)   { $busy = 0 }
        if ($busy -gt 100) { $busy = 100 }
        $rec['dskPct'] = [math]::Round($busy, 1)
    }

    if ($null -ne $diskSec) { $rec['dskMs']  = [math]::Round([double]$diskSec * 1000, 2) }   # seconds -> ms
    $dq = Get-SampleValue -Samples $samples -Pattern '*\current disk queue length'
    if ($null -ne $dq)      { $rec['dskQ']   = [math]::Round([double]$dq, 2) }
    if ($null -ne $netBps)  { $rec['netKBs'] = [math]::Round([double]$netBps / 1KB, 1) }

    return [pscustomobject]$rec
}

function Get-TopProcesses {
    <#
      Groups processes by name and returns the UNION of the top N by working set
      and the top N by CPU, so the dashboard can rank either way from one list.
      The two sets overlap heavily but not completely -- the process burning CPU
      is often not the one holding memory, which is the whole reason both panes
      exist. Storing the union rather than two separate arrays keeps roughly a
      quarter of the bytes out of the store.

      CPU percentage is a true interval figure: cumulative CPU seconds are diffed
      against the previous run's baseline held in state.json, divided by elapsed
      wall time and logical core count. An instantaneous per-process CPU reading
      would be noise. It is $null until there is a baseline to diff against.
    #>
    param([int]$Top = 10)

    $now = @()
    try {
        $now = @(Get-Process -ErrorAction SilentlyContinue |
                 Group-Object -Property ProcessName |
                 ForEach-Object {
                     [pscustomobject]@{
                         n   = $_.Name
                         ws  = [math]::Round((($_.Group | Measure-Object -Property WorkingSet64 -Sum -ErrorAction SilentlyContinue).Sum) / 1MB, 1)
                         cpu = [double](($_.Group | Measure-Object -Property CPU -Sum -ErrorAction SilentlyContinue).Sum)
                         c   = $_.Count
                     }
                 })
    } catch {
        Write-Log "Get-Process failed: $($_.Exception.Message)" 'WARN'
        return @()
    }
    if ($now.Count -eq 0) { return @() }

    $prevMap  = Get-StateProperty -Object $state -Name 'ProcCpu'
    $prevAt   = ConvertTo-Utc -Value (Get-StateProperty -Object $state -Name 'ProcCpuAt') -Default ([datetime]::MinValue)
    $elapsed  = ($RunStart.ToUniversalTime() - $prevAt).TotalSeconds
    $canDelta = ($prevAt -gt [datetime]::MinValue) -and ($elapsed -gt 5) -and ($elapsed -lt 7200)

    # Interval CPU% for EVERY process first -- ranking by CPU is impossible if the
    # delta is only computed for the processes that happen to lead on memory.
    foreach ($p in $now) {
        $pct = $null
        if ($canDelta -and $prevMap -and ($prevMap.PSObject.Properties.Name -contains $p.n)) {
            $delta = [double]$p.cpu - [double]$prevMap.$($p.n)
            if ($delta -ge 0) { $pct = [math]::Round(($delta / $elapsed / $cores) * 100, 1) }
        }
        Add-Member -InputObject $p -NotePropertyName 'pct' -NotePropertyValue $pct
    }

    # NB: do not name these $top. PowerShell variable names are case-insensitive,
    # so $top and the $Top parameter are one and the same slot -- assigning to it
    # would overwrite the parameter with an array in the middle of its own use.
    $byMem = @($now | Sort-Object -Property ws -Descending | Select-Object -First $Top)
    $byCpu = @()
    if ($canDelta) {
        $byCpu = @($now | Where-Object { $null -ne $_.pct -and $_.pct -gt 0 } |
                   Sort-Object -Property pct -Descending | Select-Object -First $Top)
    }

    $seen = @{}
    $out  = New-Object System.Collections.Generic.List[object]
    foreach ($p in (@($byMem) + @($byCpu))) {
        if ($seen.ContainsKey($p.n)) { continue }
        $seen[$p.n] = $true
        $out.Add([pscustomobject][ordered]@{ n = $p.n; ws = $p.ws; c = $p.c; cpu = $p.pct })
    }

    # Refresh the baseline. Bound it: only processes that have actually used CPU,
    # capped, so state.json can't creep.
    $newMap = [ordered]@{}
    foreach ($p in @($now | Where-Object { $_.cpu -gt 0 } | Sort-Object -Property cpu -Descending | Select-Object -First 200)) {
        $newMap[$p.n] = [math]::Round([double]$p.cpu, 2)
    }
    Set-StateProperty -Object $state -Name 'ProcCpu'   -Value ([pscustomobject]$newMap)
    Set-StateProperty -Object $state -Name 'ProcCpuAt' -Value (Get-UtcStamp $RunStart)

    return $out.ToArray()
}

if (-not $SkipPerf) {
    $sample = Get-PerfSample
    $procs  = @(Get-TopProcesses -Top $TopProcessCount)
    if ($sample) {
        Add-Member -InputObject $sample -NotePropertyName 'procs' -NotePropertyValue $procs
        $perfRecords.Add($sample)
        Write-Log ("Perf: cpu={0}% mem={1}% disk={2}% ({3}ms) net={4}KB/s procs={5}" -f `
                   $sample.cpu, $sample.memPct, $sample.dskPct, $sample.dskMs, $sample.netKBs, $procs.Count)
    }
} else {
    Write-Log 'Perf sampling skipped (-SkipPerf).'
}

# ---------------------------------------------------------------------------
# Boot / shutdown / logon durations
# ---------------------------------------------------------------------------
$DurationFields = @('BootTime','MainPathBootTime','BootPostBootTime','ShutdownTime',
                    'LogonTime','UserLogonWaitTime','UserProfileProcessingTime',
                    'MachineProfileProcessingTime','TotalTime','Duration')

$bootEvents = @(Get-NewLogEvents -LogName $DiagPerfLog -Ids $DiagPerfIds -IncludeData)
foreach ($b in $bootEvents) {
    $kind = switch ([int]$b.id) { 100 { 'boot' } 200 { 'shutdown' } 300 { 'logon' } default { "id$($b.id)" } }
    $rec  = [ordered]@{ k = 'b'; t = $b.t; kind = $kind; id = [int]$b.id }
    $any  = $false
    foreach ($f in $DurationFields) {
        if ($b.data -and ($b.data.PSObject.Properties.Name -contains $f)) {
            $rec[$f] = [int64]$b.data.$f
            $any = $true
        }
    }
    if (-not $any) { continue }      # nothing measurable in this one
    $perfRecords.Add([pscustomobject]$rec)
}
Write-Log "$DiagPerfLog : $($bootEvents.Count) new boot/logon record(s)."

# ---------------------------------------------------------------------------
# Append
# ---------------------------------------------------------------------------
function Add-Records {
    param($Records, [string]$NdjsonPath, [string]$JsPath, [string]$PushVar)
    $items = @($Records)
    if ($items.Count -eq 0) { return 0 }
    $nd = New-Object System.Collections.Generic.List[string]
    $js = New-Object System.Collections.Generic.List[string]
    foreach ($r in $items) {
        $json = $r | ConvertTo-Json -Compress -Depth 5
        $nd.Add($json)
        $js.Add("$PushVar.push($json);")
    }
    [System.IO.File]::AppendAllLines($NdjsonPath, [string[]]$nd, $Utf8NoBom)
    [System.IO.File]::AppendAllLines($JsPath,     [string[]]$js, $Utf8NoBom)
    return $items.Count
}

$sorted = @()
if ($collected.Count -gt 0) { $sorted = @($collected.ToArray() | Sort-Object t, rid) }
$null = Add-Records -Records $sorted -NdjsonPath $EventsFile -JsPath $DataJsFile -PushVar 'EH'

$perfSorted = @()
if ($perfRecords.Count -gt 0) { $perfSorted = @($perfRecords.ToArray() | Sort-Object t) }
$null = Add-Records -Records $perfSorted -NdjsonPath $PerfFile -JsPath $PerfJsFile -PushVar 'EHP'

# ---------------------------------------------------------------------------
# Retention trim (at most once every 12h -- rewriting the stores every 10 minutes
# would be the single heaviest thing this script does)
# ---------------------------------------------------------------------------
function Invoke-Trim {
    param([string]$NdjsonPath, [string]$JsPath, [string]$PushVar, [datetime]$CutoffUtc)

    if (-not (Test-Path -LiteralPath $NdjsonPath)) { return }
    $tmpNd = "$NdjsonPath.tmp"
    $tmpJs = "$JsPath.tmp"
    $kept = 0; $dropped = 0
    try {
        $swNd = New-Object System.IO.StreamWriter($tmpNd, $false, $Utf8NoBom)
        $swJs = New-Object System.IO.StreamWriter($tmpJs, $false, $Utf8NoBom)
        try {
            foreach ($line in [System.IO.File]::ReadLines($NdjsonPath)) {
                if (-not $line.Trim()) { continue }
                $keep = $true
                try {
                    $o = $line | ConvertFrom-Json
                    if ((ConvertTo-Utc -Value $o.t -Default ([datetime]::MinValue)) -lt $CutoffUtc) { $keep = $false }
                } catch { $keep = $false }   # unparseable line, drop it
                if ($keep) { $swNd.WriteLine($line); $swJs.WriteLine("$PushVar.push($line);"); $kept++ }
                else       { $dropped++ }
            }
        } finally { $swNd.Dispose(); $swJs.Dispose() }

        Move-Item -LiteralPath $tmpNd -Destination $NdjsonPath -Force
        Move-Item -LiteralPath $tmpJs -Destination $JsPath -Force
        Write-Log "Trim $(Split-Path $NdjsonPath -Leaf): kept $kept, dropped $dropped."
    } catch {
        Write-Log "Trim failed for $NdjsonPath : $($_.Exception.Message)" 'ERROR'
        foreach ($t in @($tmpNd, $tmpJs)) { if (Test-Path -LiteralPath $t) { Remove-Item -LiteralPath $t -Force -ErrorAction SilentlyContinue } }
    }
}

$needTrim = $true
$lastTrim = Get-StateProperty -Object $state -Name 'LastTrimUtc'
if ($lastTrim) {
    $needTrim = (ConvertTo-Utc -Value $lastTrim -Default ([datetime]::MinValue)) -lt $RunStart.ToUniversalTime().AddHours(-12)
}

if ($needTrim) {
    $cutoff = $RunStart.ToUniversalTime().AddDays(-1 * [Math]::Abs($RetentionDays))
    Invoke-Trim -NdjsonPath $EventsFile -JsPath $DataJsFile -PushVar 'EH'  -CutoffUtc $cutoff
    Invoke-Trim -NdjsonPath $PerfFile   -JsPath $PerfJsFile -PushVar 'EHP' -CutoffUtc $cutoff
    Set-StateProperty -Object $state -Name 'LastTrimUtc' -Value (Get-UtcStamp $RunStart)
}

# Keep the collector's own log from growing forever.
if (Test-Path -LiteralPath $LogFile) {
    $li = Get-Item -LiteralPath $LogFile
    if ($li.Length -gt 1MB) {
        $tail = Get-Content -LiteralPath $LogFile -Tail 2000
        Set-Content -LiteralPath $LogFile -Value $tail -Encoding UTF8 -Force
    }
}

# ---------------------------------------------------------------------------
# Status payload for the front page
#
# index.html polls this file every 30 seconds and repaints without reloading, so
# it must stay small -- re-fetching a multi-megabyte data.js on a timer would be
# worse than the reload it replaces. It carries the last 60 minutes of only the
# things the health rule needs, leaving the rule itself in the page.
# ---------------------------------------------------------------------------
function Write-StatusFile {
    $cutoff   = $RunStart.ToUniversalTime().AddMinutes(-1 * [Math]::Abs($StatusWindowMinutes))
    $pla      = New-Object System.Collections.Generic.List[object]
    $crash    = New-Object System.Collections.Generic.List[object]
    $syscrash = New-Object System.Collections.Generic.List[object]
    $spark    = New-Object System.Collections.Generic.List[object]
    $lastBootRec = $null

    # Tail reads only -- never re-parse the whole store for this.
    if (Test-Path -LiteralPath $EventsFile) {
        foreach ($line in @(Get-Content -LiteralPath $EventsFile -Tail 400 -ErrorAction SilentlyContinue)) {
            if (-not $line.Trim()) { continue }
            $o = $null
            try { $o = $line | ConvertFrom-Json } catch { continue }
            $t = ConvertTo-Utc -Value $o.t -Default ([datetime]::MinValue)
            if ($t -lt $cutoff) { continue }

            if ($o.log -eq $PlaLogName) {
                $m = $null
                if ($o.PSObject.Properties.Name -contains 'msg') { $m = $o.msg }
                if ($m -and $m.Length -gt 200) { $m = $m.Substring(0, 200) }
                $pla.Add([pscustomobject][ordered]@{ t = (Get-UtcStamp $t); lvl = $o.lvl; id = [int]$o.id; msg = $m })
            }
            elseif ($o.log -eq 'Application' -and
                    ((($o.src -eq 'Application Error') -and ([int]$o.id -eq 1000)) -or
                     (($o.src -eq 'Application Hang')  -and ([int]$o.id -eq 1002)))) {
                $crash.Add([pscustomobject][ordered]@{ t = (Get-UtcStamp $t); src = $o.src; id = [int]$o.id })
            }
            elseif ($o.log -eq 'System') {
                # Machine-level crashes: an unexpected shutdown (Kernel-Power 41 /
                # EventLog 6008) or a bugcheck (1001 from the error-reporting
                # provider -- ID 1001 alone is too common to match blind).
                $id = [int]$o.id
                $isSys = ($id -eq 41 -or $id -eq 6008 -or
                          ($id -eq 1001 -and ($o.src -match 'bugcheck|systemerror')))
                if ($isSys) {
                    $kind = switch ($id) { 41 { 'Unexpected shutdown' } 6008 { 'Unexpected shutdown' }
                                           1001 { 'Bugcheck (blue screen)' } default { 'System error' } }
                    $syscrash.Add([pscustomobject][ordered]@{ t = (Get-UtcStamp $t); src = $o.src; id = $id; kind = $kind })
                }
            }
        }
    }

    if (Test-Path -LiteralPath $PerfFile) {
        # Wider tail than the spark needs: the most recent boot record can be days
        # old, and the front page wants it regardless of the status window.
        foreach ($line in @(Get-Content -LiteralPath $PerfFile -Tail 300 -ErrorAction SilentlyContinue)) {
            if (-not $line.Trim()) { continue }
            $o = $null
            try { $o = $line | ConvertFrom-Json } catch { continue }
            $t = ConvertTo-Utc -Value $o.t -Default ([datetime]::MinValue)
            if ($t -eq [datetime]::MinValue) { continue }

            if ($o.k -eq 'b' -and $o.kind -eq 'boot') {
                $bt = $null
                if ($o.PSObject.Properties.Name -contains 'BootTime') { $bt = [int64]$o.BootTime }
                if ($null -ne $bt) {
                    $lastBootRec = [pscustomobject][ordered]@{
                        t    = (Get-UtcStamp $t)
                        ms   = $bt
                        main = $(if ($o.PSObject.Properties.Name -contains 'MainPathBootTime') { [int64]$o.MainPathBootTime } else { $null })
                        post = $(if ($o.PSObject.Properties.Name -contains 'BootPostBootTime') { [int64]$o.BootPostBootTime } else { $null })
                    }
                }
                continue
            }

            if ($o.k -ne 'p') { continue }
            if ($t -lt $cutoff) { continue }
            if ($null -eq $o.cpu) { continue }
            $spark.Add(@([int64]([DateTimeOffset]$t).ToUnixTimeSeconds(), [double]$o.cpu))
        }
    }

    $latest = $null
    if ($perfSorted.Count -gt 0) { $latest = $perfSorted[$perfSorted.Count - 1] }

    $status = [pscustomobject][ordered]@{
        host        = $env:COMPUTERNAME
        user        = $consoleUser
        os          = if ($os) { $os.Caption } else { $null }
        cores       = $cores
        totalMemMB  = $totalMemMB
        relScore    = $relScore
        relDate     = $relDate
        # @($null) is a one-element array CONTAINING null, which serialises to
        # [null] and crashed the front page. Strip nulls so an absent history is [].
        relHist     = @($relHist | Where-Object { $null -ne $_ })
        lastBootUtc = $lastBoot
        lastRunUtc  = (Get-UtcStamp $RunStart)
        version     = $ScriptVersion
        cpu         = if ($latest) { $latest.cpu }    else { $null }
        memPct      = if ($latest) { $latest.memPct } else { $null }
        memMB       = if ($latest) { $latest.memMB }  else { $null }
        windowMin   = [Math]::Abs($StatusWindowMinutes)
        spark       = $spark.ToArray()
        pla         = $pla.ToArray()
        crash       = $crash.ToArray()
        syscrash    = $syscrash.ToArray()
        boot        = $lastBootRec
    }

    $json = $status | ConvertTo-Json -Compress -Depth 5
    [System.IO.File]::WriteAllText($StatusJsFile, "EH_STATUS = $json;$([Environment]::NewLine)", $Utf8NoBom)
    Write-Log ("status.js: {0} PLA, {1} app crash, {2} system crash, {3} spark point(s), {4} bytes." -f `
               $pla.Count, $crash.Count, $syscrash.Count, $spark.Count, $json.Length)
}

# ---------------------------------------------------------------------------
# Meta payload for the dashboard
# ---------------------------------------------------------------------------
$storeBytes = 0
foreach ($f in @($EventsFile, $PerfFile)) {
    if (Test-Path -LiteralPath $f) { $storeBytes += (Get-Item -LiteralPath $f).Length }
}

$meta = [pscustomobject][ordered]@{
    host          = $env:COMPUTERNAME
    user          = $consoleUser
    relScore      = $relScore
    relDate       = $relDate
    os            = if ($os) { $os.Caption } else { $null }
    build         = if ($os) { $os.Version } else { $null }
    cores         = $cores
    totalMemMB    = $totalMemMB
    lastBootUtc   = $lastBoot
    lastRunUtc    = (Get-UtcStamp $RunStart)
    runMs         = [int]((Get-Date) - $RunStart).TotalMilliseconds
    newThisRun    = $sorted.Count
    newPerfRuns   = $perfSorted.Count
    retentionDays = $RetentionDays
    storeKB       = [math]::Round($storeBytes / 1KB, 1)
    version       = $ScriptVersion
}
$metaJson = ($meta | ConvertTo-Json -Compress -Depth 3)
[System.IO.File]::WriteAllText($MetaJsFile, "EH_META = $metaJson;$([Environment]::NewLine)", $Utf8NoBom)

# ---------------------------------------------------------------------------
Write-StatusFile

Set-StateProperty -Object $state -Name 'LastRunUtc' -Value (Get-UtcStamp $RunStart)
Set-StateProperty -Object $state -Name 'Version'    -Value $ScriptVersion
Save-CollectorState -State $state

Write-Log ("Run complete: {0} event(s), {1} perf record(s), {2} ms; store {3} KB." -f `
           $sorted.Count, $perfSorted.Count, $meta.runMs, $meta.storeKB)
