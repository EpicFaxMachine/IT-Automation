# IT Automation Toolkit

PowerShell automation for a **~2,000-user hybrid identity environment**: on-prem Active Directory, Exchange Online / Microsoft 365, and Okta — plus Windows client repair and store / server log collection helpers.

These are **sanitized portfolio copies**. Employer names, internal domains, server names, OU paths, ticket mailboxes, and secrets are Contoso-style placeholders. Logic matches the production tools; values do not.

## Contents

| Folder | Script | Summary |
|--------|--------|---------|
| `01-newhire-gui/` | `New-Hire-Onboarding-GUI.ps1` | WinForms — employee/contractor onboarding, config-driven depts, group mirror, Graph licenses |
| `02-termination-gui/` | `Employee-Termination-GUI.ps1` | WPF — multi-step offboarding across AD, M365, Okta; optional ticket email (off by default) |
| `03-audit-90day/` | `Audit-90Day-NoLogins.ps1` | Cross-system inactive-account audit → Excel |
| `04-remove-ad-group/` | `Remove-Users-FromADGroup.ps1` | Bulk remove users (CSV/XLSX emails) from an AD group (`-WhatIf` default) |
| `05-win11-upgrade-repair/` | `Fix-Windows11Upgrade.ps1` | WinForms — selectable Windows 11 upgrade blockers / repairs + health report |
| `06-pos-log-collector/` | `Collect-StoreRegisterLogs.ps1` | WPF — store register / HQ POS & payment log collection → zip |
| `07-dl-migration/` | `FinalMigrationScript.ps1` | Console — migrate distribution groups on-prem Exchange → Exchange Online |
| `08-mailbox-access-gui/` | `MailboxAccess_GUI.ps1` | WinForms — Full Access / Send As / Send on Behalf grants (Force Sync off by default) |
| `09-eventlog-collector-gui/` | `EventLog-Collector-GUI.ps1` | WinForms — remote Error/Warning event export → CSV |

Each folder has the `.ps1` (UTF-8 **with BOM**, CRLF), `config.example.psd1`, and `README.md`. Shared GUI screenshots live in `screenshots/` (placeholders noted per tool until captured).

## Design themes

- **Hybrid identity**: AD as source of truth, Graph for licenses, Okta for SSO last-login / deactivate
- **Operator-friendly GUIs** for hire/term/mailbox/logs; console scripts for audits, bulk cleanup, and DL migration
- **Secrets stay out of code**: Okta via `OKTA_API_TOKEN`; Graph / EXO via interactive connect
- **Safe defaults where practical**: group-removal defaults to WhatIf; ticket email disabled; mailbox Force Sync off; Win11 log export local-only unless you set a share

## Requirements (overview)

- Windows admin workstation with RSAT Active Directory (identity tools)
- PowerShell 5.1+
- Microsoft Graph PowerShell SDK (hire/term/audit license pieces)
- Exchange Online Management module (mailbox / DL tools)
- Okta API token in the environment for Okta steps
- Optional: `ImportExcel` for spreadsheet I/O; remote admin shares for store log collection

## Getting started

1. Clone into a lab or jump host.
2. Copy `config.example.psd1` values into each script’s config block (do **not** commit real values).
3. Replace Contoso placeholders (`contoso.com`, `DC01`, `OU=...,DC=contoso,DC=com`, `https://YOUR_ORG.okta.com`, `POS-AOM01`, `AADSYNC01`).
4. Run against a **test OU / test user / test host** first.

## Disclaimer

Built for demonstration and portfolio review. Adapt carefully before production use. You are responsible for rights, change control, and data handling in your environment.

## Author

Jose Padilla — IT / systems administration automation.
