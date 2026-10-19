Distribution group migration — operator notes (Contoso portfolio copy)
======================================================================

Overview
--------
Migrate distribution groups from on-premises Exchange to Exchange Online.
Export members, remove the on-prem group, wait for directory sync, recreate
in Exchange Online, and re-add members from the CSV.

Prerequisites
-------------
- On-prem Exchange admin rights (EMS or remote PowerShell session)
- Exchange Online admin account (MFA / Okta push as required by your tenant)
- PowerShell 5.1+ with ExchangeOnlineManagement module
- Writable MigrationWorkDir (default C:\Scripts\MigrationProject)

Typical on-prem session
-----------------------
  $Credential = Get-Credential
  $Session = New-PSSession -ConfigurationName Microsoft.Exchange `
      -ConnectionUri http://MAIL01.contoso.com/PowerShell/ `
      -Credential $Credential
  Import-PSSession $Session -DisableNameChecking

Exchange Online
---------------
  Connect-ExchangeOnline -UserPrincipalName admin@contoso.com -ShowProgress $false

Member CSV
----------
  Import-Csv "C:\Scripts\MigrationProject\<GroupName>.csv"
  ForEach ($User in $Userslist) {
      Add-DistributionGroupMember -Identity $Email `
          -Member $User.PrimarySmtpAddress -BypassSecurityGroupManagerCheck
  }

Disclaimer
----------
Adapt hostnames, UPNs, and paths to your environment. Test on a disposable
group before migrating production distribution lists.
