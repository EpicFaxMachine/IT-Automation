# IT Automation Toolkit

PowerShell automation for a **~2,000-user hybrid identity environment**: on-prem Active Directory, Exchange Online / Microsoft 365, and Okta.

These are **sanitized portfolio copies**. Employer names, internal domains, server names, OU paths, ticket mailboxes, and secrets are Contoso-style placeholders. Logic matches the production tools; values do not.

## Contents

| Folder | Script | Summary |
|--------|--------|---------|
| `01-newhire-gui/` | `New-Hire-Onboarding-GUI.ps1` | WinForms — employee/contractor onboarding, config-driven depts, group mirror, Graph licenses |
| `02-termination-gui/` | `Employee-Termination-GUI.ps1` | WPF — multi-step offboarding across AD, M365, Okta; optional ticket email (off by default) |
| `03-audit-90day/` | `Audit-90Day-NoLogins.ps1` | Cross-system inactive-account audit → Excel |
| `04-remove-ad-group/` | `Remove-Users-FromADGroup.ps1` | Bulk remove users (CSV/XLSX emails) from an AD group (`-WhatIf` default) |

Each folder has the `.ps1` (UTF-8 **with BOM**, CRLF), `config.example.psd1`, and `README.md`. Shared GUI screenshots live in `screenshots/`.

## Design themes

- **Hybrid identity**: AD as source of truth, Graph for licenses, Okta for SSO last-login / deactivate
- **Operator-friendly GUIs** for hire/term; console scripts for audits and bulk cleanup
- **Secrets stay out of code**: Okta via `OKTA_API_TOKEN`; Graph via interactive connect
- **Safe defaults where practical**: group-removal defaults to WhatIf; ticket email disabled until you flip config

## Requirements (overview)

- Windows admin workstation with RSAT Active Directory
- PowerShell 5.1+
- Microsoft Graph PowerShell SDK (hire/term/audit license pieces)
- Okta API token in the environment for Okta steps
- Optional: `ImportExcel` for spreadsheet I/O

## Getting started

1. Clone into a lab or jump host.
2. Copy `config.example.psd1` values into each script’s config block (do **not** commit real values).
3. Replace Contoso placeholders (`contoso.com`, `DC01`, `OU=...,DC=contoso,DC=com`, `https://YOUR_ORG.okta.com`).
4. Run against a **test OU / test user** first.

## Disclaimer

Built for demonstration and portfolio review. Adapt carefully before production use. You are responsible for rights, change control, and data handling in your environment.

## Author

Jose Padilla — IT / systems administration automation.
