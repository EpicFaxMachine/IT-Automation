# Event Log Collector GUI

Dark-mode WinForms tool that pulls Error/Warning events from remote Windows hosts (`System` + `Application` by default) for the last N days and writes one CSV per host.

## What it does

- Accepts hostnames (one per line or comma-separated)
- Queries via `Get-WinEvent -ComputerName`
- Exports `TimeCreated`, `Id`, level, log, provider, machine, message

## Requirements

- Windows admin workstation
- PowerShell 5.1+ (WinForms)
- Rights / firewall for remote event log access (RPC / WinRM as configured in your environment)

## Configuration

Edit `$script:Config` in `EventLog-Collector-GUI.ps1` (see `config.example.psd1`).

| Key | Example |
|-----|---------|
| `LogNames` | `System`, `Application` |
| `LevelsToInclude` | `2` (Error), `3` (Warning) |
| `DefaultHosts` | Contoso placeholders `APP01`, `APP02` |

## Usage

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\EventLog-Collector-GUI.ps1
```

Set days back, output folder, hosts → Run.

## Safety notes

- Read-only against event logs; still treat exported CSVs as sensitive.
- Replace default hostnames before pointing at production.

## Screenshot

![Event Log Collector GUI](../screenshots/eventlog-collector-gui.png)
