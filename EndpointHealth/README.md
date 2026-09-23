# Endpoint Health — collector + dashboards

Lightweight Windows endpoint telemetry: event-log errors, resource usage, and
boot/logon durations, sampled every 10 minutes into local HTML dashboards.

Part of the [digital-employee-experience](../) repo. The source of truth is this
folder; `C:\ProgramData\EndpointHealth` is a deployment target that
`Install-EndpointHealthTask.ps1` writes to. Edit here, re-run the installer, and
check the collector version it prints — a browser `-1` suffix on a downloaded
script is the usual reason an "update" changes nothing.

Two pages, both fed by the same data files:

| Page | Purpose |
|---|---|
| **`index.html`** | Front page — *Capital Group Digital Employee Experience*. One tile per machine, healthy or unhealthy at a glance. Start here. |
| **`dashboard.html`** | Drill-down for a single machine — charts, process rankings, full event log. Reached by clicking a tile. |

## Front page — live, no refreshing

The page **updates itself in place every 20 seconds** — no reload, no scroll jump,
no losing your selected window. A green pip in the corner shows it is polling; the
tile flashes briefly when new data lands, and goes amber if the data files stop
being readable. Switching tabs away and back forces an immediate catch-up poll.

How it works, given a page opened from `file://` cannot `fetch()` a sibling file:
the collector writes **`status.js`**, a payload of about 1 KB carrying only the last
hour of what the health rule needs, and the page re-injects it as a `<script>` with
a changing query string to get past the cache. Re-fetching the multi-megabyte
`data.js` on a timer would have been worse than the reload it replaces.

If `status.js` is missing — a collector older than v1.3.0 — the page falls back to
`data.js`/`perf.js` and still works, just with a heavier poll.

### "It looks like I still have to reload"

Almost always one of three things, and the page now tells you which:

1. **The pip in the corner reads `polled Ns ago` and counts up**, resetting every 20
   seconds. If it is ticking, the page *is* reading the files — there was simply
   nothing new to paint. The collector only runs every 10 minutes, so between runs a
   live page and a frozen one look identical. That counter is the difference.
2. **The line at the bottom of the "How health is determined" card** spells out the
   source, the read count, and when the data last actually changed. If it says
   `status.js not found`, the collector on that machine is still pre-1.3.0 — deploy
   the new `Get-EndpointHealth.ps1` and wait one cycle.
3. **Compare** that "data last changed" time with `lastRunUtc` inside `status.js` on
   disk. If the file is newer than the page thinks, the browser is serving a cached
   copy — tell me and I will switch the cache-buster approach.

### The health rule

A machine is **Healthy** when, in the selected evaluation window, neither of these
fired:

1. **A breached threshold** from `Microsoft-Windows-Diagnosis-PLA/Operational` —
   High CPU, Low CPU clock speeds, Low memory, or High disk activity.
2. **An application crash or hang** — `Application Error` (event 1000) or
   `Application Hang` (event 1002).
3. **A system crash** — an unexpected shutdown (`Kernel-Power` 41, `EventLog` 6008)
   or a bugcheck (1001 from the system-error-reporting provider).

Anything else is **Unhealthy**. Two states only. Uptime and the Reliability index are
reported but do **not** affect the badge.

### Three sections

| Section | Rows |
|---|---|
| **Breached thresholds** | High CPU · Low CPU clock speeds · Low memory · High disk activity |
| **System health** | System crashes · Uptime · Windows Reliability (score, verdict and 28-day chart) |
| **Application health** | Application crashes · Application hangs |

Each carries a count chip — *All clear*, *4 of 4*, *1 crash*, *2 issues*. Every row is
always present, including the clear ones, so the tile keeps the same shape whatever
the machine is doing.

**Uptime and Reliability render as measurements, not verdicts** — a grey dot rather
than a tick — and neither colours the System health chip; only crashes do. A green
tick against "up 2d 5h" would claim a judgement the page has no basis for, since
there is no threshold saying what a good uptime is.

### How the threshold categories are told apart

Every PLA alert arrives on the same channel with the same event ID, so the four
categories are separated by matching the **counter named in the alert message**:

| Category | Matches counters like |
|---|---|
| High CPU | `% Processor Time`, `% User/Privileged/DPC Time`, `Processor Queue Length` |
| Low CPU clock speeds | anything naming `Frequency` — `Processor Frequency`, `Actual Frequency`, `% of Maximum Frequency` — plus `Processor Performance` and throttling wording |
| Low memory | `Available MBytes`, `Pages/sec`, `Committed Bytes`, `Paging File` |
| High disk activity | `LogicalDisk`, `PhysicalDisk`, `Avg. Disk sec/Transfer`, `Idle Time` |

Matching runs in a deliberately different order from display — `MATCH_ORDER`, right
below `ALERT_KINDS`. Your own endpoint emits
`\Processor Information(_Total)\Actual Frequency`, which contains the word
"processor", so the clock-speed patterns are tested **before** the CPU-load ones;
otherwise that alert lands under High CPU. Confirmed against your real `status.js`.

An alert matching none of the four falls into an **Other threshold** row that only
appears when it has something in it, so an unanticipated counter still turns the
tile red rather than vanishing.

**System crashes need the same care.** Event ID 1001 in the System log is used by
several providers, so a bare ID match would report Service Control Manager messages
as blue screens. The collector requires 1001 *and* a provider matching
`bugcheck|systemerror`; 41 and 6008 match on ID alone. Verified with a decoy
`Service Control Manager` 1001 in the same log — correctly ignored.

### The tile also shows

- **The signed-in user.** The collector runs as SYSTEM, so `$env:USERNAME` would
  read `SYSTEM`; this comes from `Win32_ComputerSystem.UserName`, which is the
  interactive console user. It is empty when nobody is signed in, and also when the
  only sessions are RDP — the tile says "No user signed in" in both cases.
- **Windows Reliability, with its history** — Reliability Monitor's System
  Stability Index (0–10) from `Win32_ReliabilityStabilityMetrics`, shown as today's
  number plus a **daily line for the ~28 days Windows retains**, with a dashed
  baseline at the 7-day average.

  The history is the point. A 6.1 on its own tells you nothing; the question is
  whether the machine has been at 9 all month or at 6 all month. So alongside the
  chart the tile states the comparison in words — *Sharp drop from the recent
  average*, *Below*, *In line*, *Above* — with the delta against the prior 7 days.
  The baseline deliberately **excludes today**, so a bad day is measured against
  recent normal rather than against an average it is dragging down.

  Verified against four shapes: a steady 9.1 reads "in line"; a fall to 2.4 after a
  9.2 week reads "sharp drop"; a machine that has sat at 6.0 for a month reads "in
  line" rather than crying wolf; and a recovering machine reads "above".

  Hovering any day shows its date and score. Only the latest point and the worst
  day are labelled directly — a number on all 28 would be unreadable.

  It is shown as a measurement, **not** a pass/fail, and does not drive the badge:
  it is a trailing daily figure, so it says nothing about the last ten minutes.
  The whole history arrives in the same query as the latest value, so there is
  nothing to accumulate — a fresh install has the full month immediately. The class
  is comparatively slow and only changes daily, so it is cached in `state.json` and
  re-queried at most hourly. `-RelHistoryDays` caps how much is published (default
  30; Windows only keeps ~28).

  If it reads "Not available", Reliability Monitor has no data — usually because
  the `\Microsoft\Windows\RAC\RacTask` scheduled task is disabled. Enable it and
  the index starts populating within a day.

Machine specs (cores, RAM, OS) and the live CPU/memory figures are deliberately not
on this page — they are one click away in the drill-down.

**Evaluation window** is a dropdown: last 10 minutes (default), 30 minutes, or
1 hour. Changing it re-evaluates instantly against data already in the page — no
refetch — and the choice is remembered between visits, like the drill-down's Range
control. 1 hour is the ceiling because that is how much history `status.js` carries;
to go further, raise `-StatusWindowMinutes` on the collector and add the option to
the `selWindow` dropdown in `index.html`. The page detects the mismatch and says so
rather than silently under-reporting.

### Two things to check before trusting the green

**PLA alerts only exist if you have an Alert-type Data Collector Set.** A DCS that
writes `.blg` counter logs (like the one currently running on DELL-PM16) never
writes an alert event, so all three rows will sit at "None" forever and the tile
will be green no matter how pegged the machine is. One alert collector can carry
all three thresholds:

```powershell
logman create alert "CG-DEX-Alerts" `
  -th "\Processor Information(_Total)\% Processor Time>85" `
     "\Processor Information(_Total)\% of Maximum Frequency<70" `
     "\Memory\Available MBytes<1024" `
     "\LogicalDisk(_Total)\Avg. Disk sec/Transfer>0.025" `
  -si 00:01:00 --v
logman start "CG-DEX-Alerts"
```

Tune those four numbers to your fleet — 85% CPU, running below 70% of rated clock,
under 1 GB free, and 25 ms disk latency are starting points, not recommendations.

`% of Maximum Frequency` is the one worth explaining: it catches a machine that is
*thermally or power-plan throttled* — pegged at a fraction of its rated clock while
CPU utilisation looks unremarkable. That is a classic "my laptop is slow" complaint
that a CPU-load threshold alone never sees.

Then breach it deliberately once and confirm an event appears:

```powershell
Get-WinEvent -LogName Microsoft-Windows-Diagnosis-PLA/Operational -MaxEvents 20 |
  Select-Object TimeCreated, Id, LevelDisplayName, Message | Format-List
```

**The alert event ID is not hard-coded**, because it varies by Windows build and I
could not verify yours from here. Note this also means a *counter* I have not
matched lands in "Other" rather than its proper row — check the message wording
once your first real alert fires. The page treats a PLA event as an alert when it
is Warning-or-worse *or* its message reads like a threshold notification
(`alert`, `threshold`, `exceeded`, `above`, `below`, `limit`). Once the command
above shows you the real ID, pin it for precision — near the top of the script
block in `index.html`:

```js
var PLA_ALERT_IDS = [2031];     // whatever ID your build actually uses
```

### If a tile does not appear

A tile that cannot be built now renders as a **visible error tile** carrying the
hostname and the failure, rather than disappearing. Before 1.6.1 a single malformed
field threw out of the render and left the fleet grid empty with no explanation —
the page looked broken with no clue why. It cannot do that again.

The field that caused it is worth recording: upgrading a collector from &le;1.5 to
1.6.0 left `RelAt` warm but `RelHist` unwritten, and `@($null)` in PowerShell is a
one-element array *containing* null, which serialises to `[null]`. The page then
did `p[0]` on that null and threw. Fixed on both sides — the collector strips nulls
and re-queries whenever the history is empty regardless of the cache, and the page
tolerates every shape `relHist` has ever had:

| Shape | From |
|---|---|
| `[{t,v},...]` | 1.6.1 onward — unambiguous at any length |
| `[[t,v],...]` | 1.5.0–1.6.0 |
| `[t,v]` | the same with one day of history; `ConvertTo-Json` flattens a one-element array of pairs |
| `[null]` | the upgrade bug above |

### Stale data

If the collector hasn't reported in 30 minutes the tile shows an amber notice
saying the verdict reflects the last report rather than current conditions. It
does not become a third colour — you asked for two states — but a silently green
tile on a machine that stopped reporting an hour ago would be worse than useless.

### Adding a second machine

Built for one, as specified, but the rendering runs over a list. To add machines
later, the smallest change is: give each endpoint its own subfolder of data files,
load each `meta.js`/`data.js`/`perf.js` under a namespace, and push one entry per
machine into the `machines` array in `index.html`. The tile markup, the rule and
the roll-up counts already handle N.

## How data gets into the dashboard

There is no import step, no database, and no web server. The collector writes
JavaScript files next to `dashboard.html`, and the page loads them with plain
`<script src>` tags:

```
C:\ProgramData\EndpointHealth\
    index.html         <- you open this
    dashboard.html     <- the drill-down it links to
    data.js            <- EH.push({...})  per event         (written by the collector)
    perf.js            <- EHP.push({...}) per usage sample   (written by the collector)
    status.js          <- ~1 KB front-page payload, polled every 20s
    meta.js            <- one line: host, cores, uptime, last run
    events.ndjson      <- durable event store, one JSON object per line
    perf.ndjson        <- durable usage store
    state.json         <- watermarks + per-process CPU baselines
    collector.log      <- the collector's own log
```

**Keep all the files in one folder and double-click `index.html`.** The front page
updates itself every 20 seconds without reloading; the drill-down still does a full
refresh every 5 minutes. Both have a Reload button.

### Time ranges

The Range dropdown offers 1 / 4 / 6 / 12 / 24 hours, 2–5 days, 1–5 weeks and
1 month. Your choice is remembered between visits. Chart bucket sizes and axis
label formats are both derived from the range, so the event timeline stays at
20–48 bars whether you're looking at an hour or five weeks. (The usage charts
never bucket — they always plot every raw sample.)

Two things worth knowing:

- **"1 day" is not listed** because it is the same window as "24 hours". Say the
  word if you'd rather have both entries anyway.
- **5 weeks is 35 days, which is longer than the default 30-day retention.**
  Selecting it shows a banner saying so; to actually keep that much history,
  reinstall with `-RetentionDays 35`.

Why `.js` and not the `.ndjson` directly: a page opened from `file://` is blocked
from `fetch()`-ing a sibling file, but it is allowed to load a sibling *script*.
The `.js` files are the same data wearing a hat the browser will let through. The
`.ndjson` files are the real store — point Power BI, Splunk, or anything else at
those.

## Install

From an elevated PowerShell prompt, in the folder containing all three files:

```powershell
.\Install-EndpointHealthTask.ps1
```

That copies `Get-EndpointHealth.ps1`, `index.html` and `dashboard.html` to
`C:\ProgramData\EndpointHealth`, registers **EndpointHealth-Collector** to run
every 10 minutes as SYSTEM, and kicks off the first run.

```powershell
.\Install-EndpointHealthTask.ps1 -IntervalMinutes 5 -RetentionDays 7
.\Install-EndpointHealthTask.ps1 -Uninstall      # removes the task, keeps the data
.\Get-EndpointHealth.ps1 -DataPath C:\Temp\EH -Verbose   # run by hand while testing
```

## What it collects

### Event logs

| Source | Filter | Fields |
|---|---|---|
| Application | Level 1 (Critical) + 2 (Error) | level, UTC timestamp, source, event ID |
| System | Level 1 (Critical) + 2 (Error) | level, UTC timestamp, source, event ID |
| Microsoft-Windows-Diagnosis-PLA/Operational | all levels | + message (trimmed to 400 chars) |

Messages are deliberately **not** pulled for Application/System — rendering an
event message is the expensive part of `Get-WinEvent`. Restrict the PLA channel
with `-PlaLevels 1,2,3` if its informational entries turn out to be noise.

### Resource usage — one `Get-Counter` call per run

The dashboard charts **CPU**, **memory** and **disk activity**, three panes across,
plotting every raw 10-minute sample with a dot on each one — no bucketing, no averaging. The x
axis is a real time scale (position comes from the timestamp, not an array index),
so a gap in collection shows as a break in the line rather than a straight line
drawn through hours that were never sampled. Hovering snaps the crosshair to the
nearest actual sample and shows its real timestamp.

That is ~144 points over 24 hours, ~1,000 over 7 days and ~4,300 over 30 days. The
dots shrink as density rises; at 30 days they necessarily read as a textured band
rather than countable marks. Both the line and the dots are drawn as a single
`<path>` each (a zero-length subpath with a round linecap renders as a dot), so a
30-day chart is 2 SVG nodes instead of 4,300.

#### How disk busy % is derived (1.7.0)

The disk pane plots `dskPct`, and it is deliberately **not** `% Disk Time`, which
is the counter everyone reaches for first and the wrong one twice over:

- On the `_Total` instance it is a **sum across the disks**, so a two-disk machine
  happily reports 180% and the pane would be pinned to the top of the axis.
- Even with a single disk it is derived from the queue length rather than measured,
  so it overshoots on its own.

`% Idle Time` is measured directly and is **averaged** across instances, so the
figure charted is:

```
dskPct = clamp(100 - % Idle Time, 0, 100)
```

which is what "how much of the interval was the disk actually working" means.
`% Disk Time` is still collected and used as a fallback, clamped to 100, for the
rare build that doesn't expose idle time.

Because `dskPct` arrived in 1.7.0, samples collected by an older build have no
value for it. The pane says so — *"Not recorded in this range — needs collector
1.7.0 or later"* — rather than drawing an empty chart that looks broken. It fills
in as new samples land; a 30-day range stops showing the notice about 30 days
after the upgrade.

The collector also records disk latency, disk queue length and network throughput
into `perf.ndjson`. They aren't charted, but they ride along in the same single
`Get-Counter` call, so keeping them costs nothing and means the history is already
there if you ever want a pane back. To stop collecting them entirely, pass
`-CounterPaths` with just the three you want:

```powershell
-CounterPaths '\Processor Information(_Total)\% Processor Time',
              '\Memory\Available MBytes',
              '\LogicalDisk(_Total)\% Idle Time'
```

Two samples a second apart, because rate counters need a delta and a single read
can legitimately return zero.

### Top processes — two panes

**Top 10 by CPU** on the left, **top 10 by memory** on the right — each sitting
directly under the chart it belongs to, so the CPU column and the memory column
read top to bottom. These are genuinely different lists: the process burning CPU
is usually not the one holding memory (audiodg, dwm, SearchIndexer and TiWorker
show up on one, Code and chrome on the other), which is the whole reason there are
two panes.

The CPU pane labels percentages only. A `1.3 GB` sitting next to a percentage
makes the bar look like it measures memory; working set is still one hover away in
the row tooltip. The memory pane keeps its CPU figure, since `473 MB · 2.2%` reads
unambiguously — say the word if you want that stripped too.

Processes are grouped by name and summed across instances; `×12` means twelve
processes of that name. Bar colour matches the chart above it — orange for memory,
blue for CPU.

CPU % is a **true interval average**, not an instantaneous reading: cumulative CPU
seconds are diffed against the previous run's baseline in `state.json`, divided by
elapsed wall time and logical core count. The CPU pane therefore needs two runs
before it has anything to show, and says so until then.

The collector stores the **union** of the two top-10 sets rather than two separate
arrays — they overlap heavily, so the union is typically 12–16 entries instead of
20, which keeps roughly a quarter of the bytes out of the store. Each pane re-ranks
that one array by its own metric. `-TopProcessCount` changes the depth of both.

**Click any point on the CPU or memory chart** and the process pane rewinds to that
moment — the top processes as they were in that sample, with the CPU each used over
the interval ending there. The selected sample is marked on both charts, and both
headline figures switch to its values so CPU, memory and processes always describe
the same instant. Click the same point again, or use **Back to latest**, to return.
Changing the range drops a selection that falls outside the new window.

This is the main way to answer "what was running when it spiked": find the spike,
click it, read the process list.

### Boot and logon

Event IDs 100 / 200 / 300 from `Microsoft-Windows-Diagnostics-Performance/Operational`
— total boot time, main-path vs post-boot split, logon duration, user wait, profile
processing. Field names vary across Windows builds, so the collector reads every
named field from the event XML and keeps the ones that look like durations rather
than assuming a fixed schema. These records only appear after a restart or sign-in.

## Why it does not read C:\PerfLogs\*.blg

Measured on a real machine with a Data Collector Set running: **786 KB written in
60 seconds — about 45 MB/hour, 1.08 GB/day, per endpoint.** Two `.blg` files had
already hit a 300 MB cap and rolled. The volume comes from wildcard instances:
`Process(*)\Private Bytes` / `Virtual Bytes` and `GPU Engine(*)\Utilization
Percentage`, where a single GPU produces dozens of `phys_0_eng_N_engtype_*`
instances per process handle.

Re-scanning a 300 MB binary log every 10 minutes to recover the last 10 minutes is
orders of magnitude more expensive than sampling the same counters live.
`Import-Counter` pulls the whole file into memory; `relog.exe -b/-e` is far better
but still scans the log, and the log keeps growing. So this collector samples the
counters directly and never touches `C:\PerfLogs`.

Worth fixing separately: if a Data Collector Set is running fleet-wide at that
rate, the monitoring costs more than whatever it is measuring. Drop the
`Process(*)` and `GPU Engine(*)` wildcards, raise the sample interval, and set
Data Manager to actually delete old logs.

## How duplicates are prevented

Two different things people mean by "duplicate", both handled:

1. **Re-collecting the same event across runs.** Each log's last `EventRecordID`
   is persisted in `state.json`. Every run queries a window starting 5 minutes
   before the last event seen (events can land slightly out of order) and then
   discards anything at or below the watermark. A cleared event log is detected —
   record IDs restart at 1 — and the watermark resets instead of going deaf.
2. **The same error repeating 400 times.** The dashboard's default table view
   collapses identical *log + source + event ID* into one row with a count and
   first/last seen. Switch to **Every event** for the raw list.

## Cost

A quiet run is one indexed `Get-WinEvent` query per log, one `Get-Counter` sample
(about a second, mostly the deliberate 1-second dwell), a `Get-Process`
enumeration, and an append of a few hundred bytes. The only expensive operation is
the retention trim, which rewrites the stores; it is rate-limited to once every 12
hours rather than running on all 144 daily executions. At 30 days a typical
workstation lands in single-digit MB — roughly 0.5% of what the `.blg` approach
writes in a single day.

## Notes / gotchas

- **Counter paths are localised** by Windows display language. The defaults are
  the English names; on a non-English build pass `-CounterPaths` with the
  localised paths, or the sample is skipped and logged as a warning.
- `Set-StrictMode` is deliberately pinned at **1.0**. At `Latest`, a function whose
  output stream is empty returns `$null`, and `$null.Count` becomes a fatal error
  on any quiet run.
- Timestamps are stored UTC and rendered in the viewer's local time. The collector
  never compares a bare string to a date: `ConvertFrom-Json` silently re-hydrates
  ISO timestamps into `DateTime` objects, which is why parsing goes through
  `ConvertTo-Utc`.
- Chart buckets are aligned to *local* hour/midnight boundaries, so axis labels
  match the clock on the wall and survive DST.
- Delete `state.json` to force a re-seed (it pulls the last 24 hours, or whatever
  `-InitialLookbackHours` says).
- To view another machine's data, copy its `data.js`, `perf.js` and `meta.js` next
  to a copy of `dashboard.html`.
- `-SkipPerf` collects events only, if you want the event half on a machine where
  PerfMon counters are unavailable or restricted.
