# Store Register Log Collector

WPF (XAML) PowerShell GUI that discovers store register PCs by name pattern, pulls recent POS / payment log files over admin shares (`C$`), optionally includes HQ audit and CRM log shares, and zips the result.

Based on the more complete of two internal prototypes (`More_XAMLTesting.ps1` vs `Testing_XAML.PS1`): days-back filter, staging + zip, and per-register POS / payment / payment-SDK paths.

## What it does

- Loads reachable registers for a store number (`POS-<store>-01` …)
- Collects files modified within N days from selected sources
- Copies into a staging folder and compresses to `Logs_<timestamp>.zip`

## Requirements

- Windows admin workstation with network access to register / HQ hosts
- PowerShell 5.1+ (WPF / WinForms assemblies)
- Rights to `C$` (and configured UNC shares) on target machines

## Configuration

Edit `$script:Config` in `Collect-StoreRegisterLogs.ps1` (see `config.example.psd1`).

| Key | Purpose |
|-----|---------|
| `RegisterNamePattern` | Hostname template for store registers |
| `Register*Rel` | Paths under each register `C$` (generic POS / payment folders) |
| `HqPosAuditUnc` / `HqCrmLogUnc` | Contoso placeholder UNCs for central logs |

Vendor-specific product folder names from the original environment were replaced with generic Contoso paths.

## Usage

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\Collect-StoreRegisterLogs.ps1
```

Enter a store number → Load Registers → select sources → Collect Logs.

## Safety notes

- Reads and copies log files only; does not modify POS software.
- Log content may include tender / PII — handle zips as sensitive.
- Confirm UNC paths and register naming before pointing at production.

## Screenshot

![Store Register Log Collector](../screenshots/pos-log-collector.png)
