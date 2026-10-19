# 90-Day Inactive Account Audit

Cross-checks Active Directory, Microsoft Graph (licenses), and Okta to find people-accounts with no interactive login in N days (default 90), then writes an Excel report.

## What it does

1. Pulls AD users whose `LastLogonDate` is older than the cutoff (or never)
2. Filters out service / shared / vendor-style accounts via OU, SAM, and name patterns
3. Enriches each row with Graph-assigned license SKUs
4. Builds an Okta user cache (SSWS token from env) and joins last login + status
5. Exports `InactiveUsers_90Days.xlsx` with conditional highlight hints

## Requirements

- **ActiveDirectory** module
- **Microsoft.Graph.Users** (Graph sign-in with user-read rights)
- **ImportExcel** (or Excel COM) for `.xlsx` — `Install-Module ImportExcel`
- Environment variable **`OKTA_API_TOKEN`** — never hardcode
- Network access to your Okta org URL

## Configuration

Edit `$script:AuditConfig` (see `config.example.psd1`):

| Key | Placeholder |
|-----|-------------|
| `OktaDomain` | `https://YOUR_ORG.okta.com` |
| `OktaTokenEnvVar` | `OKTA_API_TOKEN` |
| `AlternateMailDomains` | `contoso.com`, `contractors.contoso.com` |
| `DaysInactive` | `90` |
| `OutputDir` / `OutputFileName` | `C:\Temp` / `InactiveUsers_90Days.xlsx` |

Tune `$NonPersonOUFragments` / SAM / name patterns for your org.

## Usage

```powershell
$env:OKTA_API_TOKEN = '<from password manager>'
Connect-MgGraph -Scopes 'User.Read.All','Organization.Read.All'

.\Audit-90Day-NoLogins.ps1
```

Read-only against directories. Review the Excel before acting on any account.

## Safety notes

- **Read-only** audit — does not disable or delete accounts.
- Treat the export as sensitive (names, UPNs, license data).
- Use a least-privilege Okta token (read users).

## Screenshot

![Report screenshot placeholder](screenshot-placeholder.png)

_Add a redacted Excel / console screenshot before publishing._
