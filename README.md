# Digital Employee Experience

Internal tooling for measuring and improving the day-to-day experience of using a
managed Windows endpoint — the things that make a machine feel slow, unreliable or
broken to the person sitting in front of it, measured rather than guessed at.

Everything here is designed to run on a normal corporate endpoint with no agent, no
server, no database and no network dependency. A scheduled task writes plain text
files next to an HTML page, and the page reads them straight off the filesystem.

## What's in here

| Folder | What it is |
|---|---|
| [`EndpointHealth/`](EndpointHealth/) | Endpoint health collector and dashboards. A PowerShell task samples event-log errors, resource usage, PLA threshold alerts and boot/logon timings every 10 minutes; two local HTML pages render it. |

## EndpointHealth at a glance

```
EndpointHealth/
├── Get-EndpointHealth.ps1           the collector — runs every 10 min as SYSTEM
├── Install-EndpointHealthTask.ps1   registers the scheduled task
├── index.html                       front page: one tile per machine, live
├── dashboard.html                   drill-down: charts, processes, event log
└── README.md                        full documentation
```

Install from an **elevated** PowerShell prompt, with all four files in one folder:

```powershell
.\Install-EndpointHealthTask.ps1
```

That stages the files to `C:\ProgramData\EndpointHealth`, registers the task, runs
it once, and prints the collector version it actually installed. Open
`C:\ProgramData\EndpointHealth\index.html` to see the result.

See [`EndpointHealth/README.md`](EndpointHealth/README.md) for the health rule,
the threshold-alert setup, data formats, sizing and troubleshooting.

## Repo conventions

**Source lives here; data does not.** The repo holds only the scripts and pages.
Everything the collector produces — `events.ndjson`, `perf.ndjson`, `data.js`,
`perf.js`, `status.js`, `meta.js`, `state.json`, `collector.log` — is written to the
install path at runtime and is ignored by git. Never commit a collected data file:
it contains the machine name, the signed-in user and a running list of what they
have open.

**The install path is a deployment target, not a working copy.** Edit here, then
re-run the installer to push the change out. Editing
`C:\ProgramData\EndpointHealth\*.ps1` in place means the next install silently
overwrites it.

**Watch out for browser `-1` suffixes.** Downloading an updated script into a folder
that already has one produces `Get-EndpointHealth-1.ps1`, which the installer does
not recognise — it copies nothing and you keep running the old version. The
installer prints the installed collector version on every run for exactly this
reason; check it.

## Requirements

- Windows 10/11 or Server 2016+
- PowerShell 5.1 (the scripts avoid anything 7-only)
- Local administrator rights to register the scheduled task
- Any modern browser to view the pages — they are opened from `file://`, so no web
  server is involved

Non-English Windows builds localise performance counter names; pass
`-CounterPaths` with the localised paths if the collector logs that no counters
could be read.
