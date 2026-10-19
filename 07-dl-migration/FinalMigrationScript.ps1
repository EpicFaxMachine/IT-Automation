#--------------------------------------------------------------------
# Distribution group migration — on-prem Exchange → Exchange Online
# Assumes an on-prem Exchange Management Shell / remote session is
# already available for Get-/Remove-DistributionGroup* cmdlets.
# See README.md for the Contoso on-prem session example.
#--------------------------------------------------------------------

$script:Config = @{
    PrimaryMailDomain = 'contoso.com'
    # Folder for member CSV export/import between on-prem remove and cloud recreate
    MigrationWorkDir  = 'C:\Scripts\MigrationProject'
    # UPN used for Connect-ExchangeOnline (interactive / MFA)
    ExoAdminUpn       = 'admin@contoso.com'
    # Seconds to wait after on-prem remove so Azure AD Connect can sync
    SyncWaitSeconds   = 30
    OrgDisplayName    = 'Contoso'
}

if (-not (Test-Path -LiteralPath $script:Config.MigrationWorkDir)) {
    New-Item -ItemType Directory -Path $script:Config.MigrationWorkDir -Force | Out-Null
}

$Credential = Get-Credential -Message 'On-prem Exchange admin credential (if needed for your session)'

function Display-NameBoxed {
    param (
        [string]$Name
    )

    $consoleWidth = $Host.UI.RawUI.WindowSize.Width
    if ($consoleWidth -lt 20) { $consoleWidth = 80 }
    $nameLength = $Name.Length
    $padding = [Math]::Max(0, [int](($consoleWidth - $nameLength - 4) / 2))

    $topBorder = '*' * $consoleWidth
    $middleLine = '* ' + (' ' * $padding) + $Name + (' ' * $padding) + ' *'
    $bottomBorder = '*' * $consoleWidth

    Write-Host $topBorder
    Write-Host $middleLine
    Write-Host $bottomBorder
}

Display-NameBoxed -Name $script:Config.OrgDisplayName

do {
    do {
        $Name = Read-Host -Prompt "`n Enter the Name for the Distribution Group"
        $Email = "$Name@$($script:Config.PrimaryMailDomain)"

        $existingGroup = Get-DistributionGroup -Identity $Email -ErrorAction SilentlyContinue

        if (-not $existingGroup) {
            Write-Host "The group '$Email' does not exist on the Exchange Server."
        } else {
            Write-Host 'Distro Exists!!'
        }
    } while (-not $existingGroup)

    do {
        $Check = Read-Host -Prompt "`n Are you sure you want to migrate this distro? Y = Yes N = No"

        if ($Check -eq 'N') {
            Write-Host 'Cancelled. Closing...'
            Start-Sleep -Seconds 2
            Exit 0
        } elseif ($Check -eq 'Y') {
            $csvPath = Join-Path $script:Config.MigrationWorkDir "$Name.csv"
            Get-DistributionGroupMember -Identity $Name |
                Export-Csv -Path $csvPath -NoTypeInformation
            Remove-DistributionGroup -Identity $Email
            Write-Host 'Distro has been removed from the on-prem environment.'
        } else {
            Write-Host "PLEASE INPUT 'Y' or 'N'"
        }
    } while ($Check -ne 'N' -and $Check -ne 'Y')

    Write-Host 'Connecting to Exchange Online'
    Write-Host 'Ensure Azure AD Connect has synced (waiting)...'
    Start-Sleep -Seconds $script:Config.SyncWaitSeconds

    Connect-ExchangeOnline -UserPrincipalName $script:Config.ExoAdminUpn -ShowProgress $false

    $proxyAddress = "SMTP:$Name@$($script:Config.PrimaryMailDomain)"

    do {
        $existingRecipient = Get-Recipient -Filter "EmailAddresses -eq '$proxyAddress'"
        if (-not $existingRecipient) {
            New-DistributionGroup -Name $Name -Alias $Name -PrimarySmtpAddress $Email -Type 'Distribution'
            $csvPath = Join-Path $script:Config.MigrationWorkDir "$Name.csv"
            $Userslist = Import-Csv $csvPath
            foreach ($User in $Userslist) {
                Add-DistributionGroupMember -Identity $Email -Member $User.PrimarySmtpAddress -BypassSecurityGroupManagerCheck
            }
            break
        } else {
            Write-Host 'Waiting for proxy address to be available.'
            Start-Sleep -Seconds 10
        }
    } while ($true)

    Disconnect-ExchangeOnline -Confirm:$false

    do {
        $Continue = Read-Host -Prompt 'Do you want to migrate another Distro? Y = Yes N = No'
        if ($Continue -ne 'Y' -and $Continue -ne 'N') {
            Write-Host 'PLEASE INPUT Y OR N!!'
        }
    } while ($Continue -ne 'N' -and $Continue -ne 'Y')

} while ($Continue -eq 'Y')

Write-Host 'All DONE!! Distribution group migration complete.'
Start-Sleep -Seconds 2
Write-Host 'Closing in 3...'
Start-Sleep -Seconds 1
Write-Host '2...'
Start-Sleep -Seconds 1
Write-Host '1...'
Start-Sleep -Seconds 1
Exit 0
