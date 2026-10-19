# Distribution Group Migration (On-Prem → Exchange Online)

Console PowerShell workflow that migrates a mail-enabled distribution group from on-premises Exchange to Exchange Online: export members → remove on-prem group → wait for sync → recreate in EXO and re-add members.

## What it does

1. Prompts for a distribution group name / SMTP under your primary mail domain
2. Confirms before destructive steps
3. Exports members to CSV under `MigrationWorkDir`
4. Removes the on-prem group
5. Connects to Exchange Online, waits for the old proxy to free up, creates the cloud group, imports members
6. Optionally loops for another group

## Requirements

- On-prem Exchange Management Shell **or** a remote PowerShell session already imported (see notes below)
- Exchange Online PowerShell module (`ExchangeOnlineManagement`)
- Rights to remove/create distribution groups on both sides
- Azure AD Connect (or equivalent) syncing the deleted on-prem object

## Configuration

Edit `$script:Config` in `FinalMigrationScript.ps1` (see `config.example.psd1`).

| Key | Example |
|-----|---------|
| `PrimaryMailDomain` | `contoso.com` |
| `MigrationWorkDir` | `C:\Scripts\MigrationProject` |
| `ExoAdminUpn` | `admin@contoso.com` |
| `SyncWaitSeconds` | `30` |

### On-prem session (example)

```powershell
$Credential = Get-Credential
$Session = New-PSSession -ConfigurationName Microsoft.Exchange `
    -ConnectionUri http://MAIL01.contoso.com/PowerShell/ `
    -Credential $Credential
Import-PSSession $Session -DisableNameChecking
.\FinalMigrationScript.ps1
```

## Usage

```powershell
Set-ExecutionPolicy -Scope Process Bypass
# Establish on-prem Exchange session first, then:
.\FinalMigrationScript.ps1
```

## Safety notes

- **Destructive**: removes the on-prem distribution group after export — confirm the CSV looks right in a lab first.
- Double-check `PrimaryMailDomain` and `ExoAdminUpn` before production use.
- CSV member lists may contain employee addresses — treat as sensitive.

## Screenshot

![DL Migration console](../screenshots/dl-migration.png)

## Migration notes (scrubbed)

See `README_MigrationNotes.txt` for a short operator checklist adapted from the original runbook.
