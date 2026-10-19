Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Web
Import-Module ActiveDirectory -ErrorAction Stop

# =============================================================================
# ORGANIZATION CONFIG — edit these for your environment (see config.example.psd1)
# Portfolio copy uses Contoso placeholders. No real tenant values live here.
# =============================================================================
$script:OrgConfig = @{
    AdDomain              = 'contoso.com'
    PrimaryMailDomain     = 'contoso.com'
    ContractorMailDomain  = 'contractors.contoso.com'
    OnMicrosoftDomain     = 'contoso.mail.onmicrosoft.com'
    AdRootDn              = 'DC=contoso,DC=com'
    DomainUsersOu         = 'OU=Domain Users,DC=contoso,DC=com'
    ContractorOu          = 'OU=Contractors,OU=Domain Users,DC=contoso,DC=com'
    ContractorOktaOu      = 'OU=Okta Enabled,OU=Contractors,OU=Domain Users,DC=contoso,DC=com'
    ContractorO365Group   = 'Contractors-O365'
    ContractorsGroup      = 'Contractors'
    LogRoot               = 'C:\Scripts'
    OrgDisplayName        = 'Contoso'
    X400Org               = 'CONTOSO'
    X400Private           = 'CONTOSO'
    # Dropdown keys -> OU placement (edit / extend for your org)
    Departments           = [ordered]@{
        'IT'           = @{ Dept = 'IT';           Desc = 'Information Technology'; Path = 'OU=Users,OU=IT,OU=Domain Users,DC=contoso,DC=com' }
        'HR'           = @{ Dept = 'HR';           Desc = 'Human Resources';         Path = 'OU=Users,OU=HR,OU=Domain Users,DC=contoso,DC=com' }
        'Finance'      = @{ Dept = 'Finance';      Desc = 'Finance';                 Path = 'OU=Users,OU=Finance,OU=Domain Users,DC=contoso,DC=com' }
        'Sales'        = @{ Dept = 'Sales';        Desc = 'Sales';                   Path = 'OU=Users,OU=Sales,OU=Domain Users,DC=contoso,DC=com' }
        'Operations'   = @{ Dept = 'Operations';   Desc = 'Operations';              Path = 'OU=Users,OU=Operations,OU=Domain Users,DC=contoso,DC=com' }
        'Contractors'  = @{ Dept = 'Contractors';  Desc = 'Contractor';              Path = 'OU=Users,OU=Contractors,OU=Domain Users,DC=contoso,DC=com' }
    }
}


Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings" `
    -Name "SecureProtocols" -Value 0xA80

$script:LogRoot = $script:OrgConfig.LogRoot
if (-not (Test-Path $script:LogRoot)) {
    New-Item -Path $script:LogRoot -ItemType Directory -Force | Out-Null
}
$script:TranscriptPath = Join-Path $script:LogRoot 'new_hire_Logs.txt'
Start-Transcript -Path $script:TranscriptPath -Append

$script:GraphConnected = $false
$script:LicenseCache = @()
$script:ResolvedManager = $null
$script:ResolvedMirrorUser = $null
$script:AllowedAdminMirrorGroups = @()
$script:ResolvedConManager = $null
$script:ResolvedConMirrorUser = $null
$script:AllowedConAdminMirrorGroups = @()

function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Write-Host "[$timestamp] $Message"
}

function Append-Output {
    param([string]$Message)
    if ($null -ne $script:txtOutput -and -not $script:txtOutput.IsDisposed) {
        $script:txtOutput.AppendText("$Message`r`n")
    }
}

function New-RandomPassword {
    param([int]$Length = 15, [int]$NonAlphanumeric = 3)
    $base = [System.Web.Security.Membership]::GeneratePassword($Length, $NonAlphanumeric)
    $rand = Get-Random -Minimum 0 -Maximum 100
    "$base$rand"
}

function Get-DeptConfig {
    param([string]$Key)
    if ([string]::IsNullOrWhiteSpace($Key)) { return $null }
    $map = $script:OrgConfig.Departments
    if ($map.Contains($Key)) { return $map[$Key] }
    return $null
}

function Get-UniqueSamAccountName {
    param([string]$FirstName, [string]$LastName)
    for ($i = 1; $i -le $FirstName.Length; $i++) {
        $candidate = ($FirstName.Substring(0, $i) + $LastName).ToLower()
        if (-not (Get-ADUser -Filter "sAMAccountName -eq '$candidate'")) {
            return $candidate
        }
    }
    return $null
}

function Set-UserProxyAddresses {
    param(
        [string]$SamAccountName,
        [string]$LastName,
        [string]$FirstName,
        [string]$PrimarySmtp
    )
    $proxies = @(
        "X400:C=US;A= ;P=$($script:OrgConfig.X400Private);O=$($script:OrgConfig.X400Org);S=$LastName;G=$FirstName;",
        "smtp:$SamAccountName@$($script:OrgConfig.OnMicrosoftDomain)",
        "SMTP:$PrimarySmtp"
    )
    foreach ($addr in $proxies) {
        Set-ADUser -Identity $SamAccountName -Add @{ ProxyAddresses = $addr } -ErrorAction SilentlyContinue
    }
}

function Get-UserByAnyIdentity {
    param([string]$Identity)
    if ([string]::IsNullOrWhiteSpace($Identity)) { return $null }
    $Identity = $Identity.Trim()
    $user = $null
    try { $user = Get-ADUser -Identity $Identity -Properties MemberOf, Manager, Title -ErrorAction Stop } catch {}
    if (-not $user) {
        try { $user = Get-ADUser -Filter "SamAccountName -eq '$Identity'" -Properties MemberOf, Manager, Title -ErrorAction Stop } catch {}
    }
    if (-not $user) {
        try { $user = Get-ADUser -Filter "UserPrincipalName -eq '$Identity'" -Properties MemberOf, Manager, Title -ErrorAction Stop } catch {}
    }
    if (-not $user) {
        try { $user = Get-ADUser -Filter "mail -eq '$Identity'" -Properties MemberOf, Manager, Title -ErrorAction Stop } catch {}
    }
    return $user
}

function Get-MirrorSourceGroups {
    param([string]$SourceIdentity)
    if ([string]::IsNullOrWhiteSpace($SourceIdentity)) { return @() }

    $sourceUser = Get-UserByAnyIdentity -Identity $SourceIdentity
    if (-not $sourceUser) {
        throw "Mirror user '$SourceIdentity' was not found in Active Directory."
    }

    $excludedNames = @('Domain Users','Denied RODC Password Replication Group','Users')
    $groups = @()

    foreach ($groupDn in @($sourceUser.MemberOf)) {
        try {
            $group = Get-ADGroup -Identity $groupDn -Properties Name -ErrorAction Stop
            if ($excludedNames -contains $group.Name) { continue }
            $groups += [pscustomobject]@{
                Name              = $group.Name
                DistinguishedName = $group.DistinguishedName
                IsAdminLike       = ($group.Name -match '(?i)admin')
            }
        }
        catch {
            Write-Log "GROUP ENUM WARNING - Could not inspect '$groupDn' : $($_.Exception.Message)"
        }
    }

    return @($groups | Sort-Object Name -Unique)
}

function Show-AdminGroupReviewDialog {
    param([object[]]$Groups)

    $adminLikeGroups = @($Groups | Where-Object { $_.IsAdminLike })
    if (-not $adminLikeGroups.Count) { return @() }

    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = 'Review Admin-like Mirror Groups'
    $dialog.Size = New-Object System.Drawing.Size(520, 420)
    $dialog.StartPosition = 'CenterParent'
    $dialog.FormBorderStyle = 'FixedDialog'
    $dialog.MaximizeBox = $false
    $dialog.MinimizeBox = $false
    $dialog.TopMost = $true

    $lblInfo = New-Object System.Windows.Forms.Label
    $lblInfo.Text = 'These groups contain "Admin" in the name. Check only the groups you want to mirror.'
    $lblInfo.Location = New-Object System.Drawing.Point(12, 12)
    $lblInfo.Size = New-Object System.Drawing.Size(480, 40)

    $checkedList = New-Object System.Windows.Forms.CheckedListBox
    $checkedList.Location = New-Object System.Drawing.Point(12, 60)
    $checkedList.Size = New-Object System.Drawing.Size(480, 250)
    $checkedList.CheckOnClick = $true

    foreach ($g in $adminLikeGroups) {
        [void]$checkedList.Items.Add($g.Name, $false)
    }

    $btnSelectAll = New-Object System.Windows.Forms.Button
    $btnSelectAll.Text = 'Select All'
    $btnSelectAll.Location = New-Object System.Drawing.Point(12, 325)
    $btnSelectAll.Size = New-Object System.Drawing.Size(80, 28)
    $btnSelectAll.Add_Click({
        for ($i = 0; $i -lt $checkedList.Items.Count; $i++) { $checkedList.SetItemChecked($i, $true) }
    })

    $btnClearAll = New-Object System.Windows.Forms.Button
    $btnClearAll.Text = 'Clear All'
    $btnClearAll.Location = New-Object System.Drawing.Point(98, 325)
    $btnClearAll.Size = New-Object System.Drawing.Size(80, 28)
    $btnClearAll.Add_Click({
        for ($i = 0; $i -lt $checkedList.Items.Count; $i++) { $checkedList.SetItemChecked($i, $false) }
    })

    $btnOk = New-Object System.Windows.Forms.Button
    $btnOk.Text = 'OK'
    $btnOk.Location = New-Object System.Drawing.Point(336, 325)
    $btnOk.Size = New-Object System.Drawing.Size(75, 28)
    $btnOk.DialogResult = [System.Windows.Forms.DialogResult]::OK

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = 'Cancel'
    $btnCancel.Location = New-Object System.Drawing.Point(417, 325)
    $btnCancel.Size = New-Object System.Drawing.Size(75, 28)
    $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel

    $dialog.Controls.AddRange(@($lblInfo, $checkedList, $btnSelectAll, $btnClearAll, $btnOk, $btnCancel))
    $dialog.AcceptButton = $btnOk
    $dialog.CancelButton = $btnCancel

    $result = $dialog.ShowDialog()
    if ($result -ne [System.Windows.Forms.DialogResult]::OK) {
        throw 'Mirror group review was cancelled.'
    }

    $selected = @()
    foreach ($item in $checkedList.CheckedItems) { $selected += [string]$item }
    return $selected
}

function Copy-MirrorUserGroups {
    param(
        [string]$SourceIdentity,
        [string]$TargetSamAccountName,
        [string[]]$AllowedAdminGroupNames
    )

    if ([string]::IsNullOrWhiteSpace($SourceIdentity)) { return @() }

    $sourceGroups = @(Get-MirrorSourceGroups -SourceIdentity $SourceIdentity)
    $targetUser = Get-ADUser -Identity $TargetSamAccountName -Properties MemberOf -ErrorAction Stop
    $addedGroups = @()

    foreach ($group in $sourceGroups) {
        try {
            if ($group.IsAdminLike -and ($AllowedAdminGroupNames -notcontains $group.Name)) {
                Write-Log "GROUP MIRROR SKIP - Skipping admin-like group '$($group.Name)' for '$TargetSamAccountName'"
                continue
            }
            Add-ADGroupMember -Identity $group.DistinguishedName -Members $targetUser.SamAccountName -ErrorAction Stop
            $addedGroups += $group.Name
        }
        catch {
            Write-Log "GROUP MIRROR WARNING - Could not add '$TargetSamAccountName' to '$($group.Name)' : $($_.Exception.Message)"
        }
    }

    return $addedGroups
}

function Resolve-UserForDisplay {
    param([string]$Identity)

    if ([string]::IsNullOrWhiteSpace($Identity)) { return $null }

    $user = Get-UserByAnyIdentity -Identity $Identity
    if (-not $user) {
        throw "User '$Identity' was not found in Active Directory."
    }

    $fullUser = Get-ADUser -Identity $user.DistinguishedName -Properties DisplayName, Mail, UserPrincipalName, SamAccountName, Enabled -ErrorAction Stop
    [pscustomobject]@{
        DisplayName    = $fullUser.DisplayName
        SamAccountName = $fullUser.SamAccountName
        UPN            = $fullUser.UserPrincipalName
        Mail           = $fullUser.Mail
        Enabled        = $fullUser.Enabled
        DN             = $fullUser.DistinguishedName
    }
}

function Ensure-GraphModule {
    $required = @('Microsoft.Graph.Authentication', 'Microsoft.Graph.Users', 'Microsoft.Graph.Identity.DirectoryManagement')
    foreach ($moduleName in $required) {
        if (-not (Get-Module -ListAvailable -Name $moduleName)) {
            throw "Required Graph module '$moduleName' is not installed. Install Microsoft Graph PowerShell modules first."
        }
    }
}

function Connect-OrgGraph {
    Ensure-GraphModule
    Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
    Import-Module Microsoft.Graph.Users -ErrorAction Stop
    Import-Module Microsoft.Graph.Identity.DirectoryManagement -ErrorAction Stop

    $scopes = @('User.Read.All','Organization.Read.All','Directory.ReadWrite.All')
    Connect-MgGraph -Scopes $scopes -NoWelcome
    $ctx = Get-MgContext
    if (-not $ctx) {
        throw 'Graph connection did not return a context.'
    }

    $script:GraphConnected = $true
    Write-Log "GRAPH CONNECTED - Tenant='$($ctx.TenantId)' Account='$($ctx.Account)'"
    return $ctx
}

function Get-LicenseInventory {
    if (-not $script:GraphConnected) {
        throw 'Graph is not connected. Use Refresh Licenses first.'
    }

    $allowedSkuMap = [ordered]@{
        '6fd2c87f-b296-42f0-b197-1e91e994b900' = 'Office 365 E3'
        '4b585984-651b-448a-9e53-3b10f069cf7f' = 'Office 365 F3'
        '18181a46-0d4e-45cd-891e-60aabd171b4e' = 'Office 365 E1'
        '4b9405b0-7788-4568-add1-99614e613b69' = 'Exchange Online Plan 1'
    }

    $raw = Get-MgSubscribedSku -All
    $inventory = foreach ($sku in $raw) {
        $skuId = [string]$sku.SkuId
        if (-not $allowedSkuMap.Contains($skuId)) {
            continue
        }

        $enabled = [int]$sku.PrepaidUnits.Enabled
        $consumed = [int]$sku.ConsumedUnits
        $available = $enabled - $consumed
        [pscustomobject]@{
            SkuId          = $skuId
            SkuPartNumber  = [string]$sku.SkuPartNumber
            DisplayName    = [string]$allowedSkuMap[$skuId]
            Enabled        = $enabled
            Consumed       = $consumed
            Available      = $available
            IsPreferred    = $true
        }
    }

    $script:LicenseCache = @($inventory | Sort-Object DisplayName)
    return $script:LicenseCache
}

function Refresh-LicenseDropdown {
    param(
        [System.Windows.Forms.ComboBox]$ComboBox,
        [System.Windows.Forms.Label]$StatusLabel
    )

    $licenses = @(Get-LicenseInventory)

    foreach ($license in $licenses) {
        if (-not $license.PSObject.Properties['DisplayName'] -or -not $license.PSObject.Properties['SkuId']) {
            throw 'License inventory contains an invalid item. Refresh failed.'
        }
    }

    $ComboBox.DataSource = $null
    $ComboBox.Items.Clear()

    foreach ($license in $licenses) {
        [void]$ComboBox.Items.Add([string]$license.DisplayName)
    }

    $ComboBox.Tag = $licenses

    if ($ComboBox.Items.Count -gt 0) {
        $ComboBox.SelectedIndex = 0
    }

    $preferredSummary = @($licenses | Where-Object { $_.IsPreferred } | ForEach-Object { "{0}: {1}" -f $_.DisplayName, $_.Available })
    if ($preferredSummary.Count -gt 0) {
        $StatusLabel.Text = ('Available: ' + ($preferredSummary -join ' | '))
    }
    else {
        $StatusLabel.Text = 'Available: no license inventory returned'
    }
}

function Update-LicenseAvailabilityLabel {
    param(
        [System.Windows.Forms.ComboBox]$ComboBox,
        [System.Windows.Forms.Label]$StatusLabel
    )

    $licenses = @($ComboBox.Tag)
    if ($ComboBox.SelectedIndex -ge 0 -and $ComboBox.SelectedIndex -lt $licenses.Count) {
        $selected = $licenses[$ComboBox.SelectedIndex]
        $available = if ($null -ne $selected.Available) { [string]$selected.Available } else { 'unknown' }
        $StatusLabel.Text = "Selected: $($selected.DisplayName) | Available: $available"
    }
    elseif ($licenses.Count -gt 0) {
        $preferredSummary = @($licenses | ForEach-Object { "{0}: {1}" -f $_.DisplayName, $_.Available })
        $StatusLabel.Text = ('Available: ' + ($preferredSummary -join ' | '))
    }
    else {
        $StatusLabel.Text = 'Available: no license inventory returned'
    }
}

function Wait-ForCloudUser {
    param(
        [string]$UserPrincipalName,
        [int]$TimeoutSeconds = 600,
        [int]$PollSeconds = 15
    )

    if (-not $script:GraphConnected) {
        throw 'Graph is not connected. Use Refresh Licenses first.'
    }

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        try {
            $user = Get-MgUser -UserId $UserPrincipalName -Property Id,UserPrincipalName,UsageLocation -ErrorAction Stop
            if ($user) { return $user }
        }
        catch {}
        Start-Sleep -Seconds $PollSeconds
    } while ((Get-Date) -lt $deadline)

    throw "Cloud user '$UserPrincipalName' was not found within $TimeoutSeconds seconds after sync."
}

function Set-CloudUsageLocation {
    param(
        [string]$UserPrincipalName,
        [string]$UsageLocation = 'US'
    )

    Update-MgUser -UserId $UserPrincipalName -UsageLocation $UsageLocation -ErrorAction Stop
    Write-Log "GRAPH USER UPDATE - Set UsageLocation='$UsageLocation' for '$UserPrincipalName'"
}

function Assign-LicenseToCloudUser {
    param(
        [string]$UserPrincipalName,
        [string]$SkuId
    )

    $license = $script:LicenseCache | Where-Object { $_.SkuId -eq $SkuId } | Select-Object -First 1
    if (-not $license) {
        throw 'Selected license SKU was not found in the current cache. Refresh licenses and try again.'
    }
    if ($license.Available -le 0) {
        throw "No seats available for '$($license.DisplayName)'."
    }

    $addLicenses = @(@{ SkuId = $SkuId })
    $removeLicenses = @()
    Set-MgUserLicense -UserId $UserPrincipalName -AddLicenses $addLicenses -RemoveLicenses $removeLicenses -ErrorAction Stop
    Write-Log "LICENSE ASSIGNED - User='$UserPrincipalName' Sku='$($license.DisplayName)'"
    return $license
}


function Copy-CloudGroupMembership {
    param(
        [Parameter(Mandatory)]
        [string]$SourceUserPrincipalName,

        [Parameter(Mandatory)]
        [string]$TargetUserPrincipalName
    )

    if (-not $script:GraphConnected) {
        throw 'Graph is not connected. Connect to Microsoft Graph first.'
    }

    $sourceUser = Get-MgUser -UserId $SourceUserPrincipalName -Property Id,DisplayName,UserPrincipalName -ErrorAction Stop
    $targetUser = Get-MgUser -UserId $TargetUserPrincipalName -Property Id,DisplayName,UserPrincipalName -ErrorAction Stop

    $sourceGroups = @(Get-MgUserMemberOfAsGroup -UserId $sourceUser.Id -All -Property Id,DisplayName,GroupTypes,MailEnabled,SecurityEnabled,OnPremisesSyncEnabled,MembershipRule -ErrorAction Stop)
    $targetGroups = @(Get-MgUserMemberOfAsGroup -UserId $targetUser.Id -All -Property Id -ErrorAction SilentlyContinue)

    $targetGroupIds = @{}
    foreach ($group in $targetGroups) {
        $targetGroupIds[[string]$group.Id] = $true
    }

    $results = foreach ($group in $sourceGroups) {
        $groupId = [string]$group.Id
        $displayName = [string]$group.DisplayName
        $groupTypes = @($group.GroupTypes)
        $isDynamic = (-not [string]::IsNullOrWhiteSpace([string]$group.MembershipRule)) -or ($groupTypes -contains 'DynamicMembership')
        $isUnified = $groupTypes -contains 'Unified'
        $isSynced = [bool]$group.OnPremisesSyncEnabled
        $isMailEnabled = [bool]$group.MailEnabled
        $isSecurityEnabled = [bool]$group.SecurityEnabled

        if ($targetGroupIds.ContainsKey($groupId)) {
            [pscustomobject]@{
                GroupDisplayName = $displayName
                GroupId          = $groupId
                Status           = 'SkippedAlreadyMember'
                Reason           = 'Target user is already a member'
            }
            continue
        }

        if ($isDynamic) {
            [pscustomobject]@{
                GroupDisplayName = $displayName
                GroupId          = $groupId
                Status           = 'SkippedDynamic'
                Reason           = 'Dynamic membership group'
            }
            continue
        }

        if ($isSynced) {
            [pscustomobject]@{
                GroupDisplayName = $displayName
                GroupId          = $groupId
                Status           = 'SkippedSynced'
                Reason           = 'On-prem synced group; manage from AD'
            }
            continue
        }

        if ($isMailEnabled -and -not $isSecurityEnabled -and -not $isUnified) {
            [pscustomobject]@{
                GroupDisplayName = $displayName
                GroupId          = $groupId
                Status           = 'SkippedMailOnly'
                Reason           = 'Mail-only group; handle in Exchange flow'
            }
            continue
        }

        try {
            $body = @{
                '@odata.id' = "https://graph.microsoft.com/v1.0/directoryObjects/$($targetUser.Id)"
            }

            New-MgGroupMemberByRef -GroupId $groupId -BodyParameter $body -ErrorAction Stop | Out-Null

            [pscustomobject]@{
                GroupDisplayName = $displayName
                GroupId          = $groupId
                Status           = 'Added'
                Reason           = ''
            }
        }
        catch {
            [pscustomobject]@{
                GroupDisplayName = $displayName
                GroupId          = $groupId
                Status           = 'Failed'
                Reason           = $_.Exception.Message
            }
        }
    }

    return $results
}

function Invoke-DeltaSync {
    try {
        Invoke-Command -ComputerName AADSYNC01 -ScriptBlock { Start-ADSyncSyncCycle -PolicyType Delta } -ErrorAction Stop | Out-Null
        Write-Log 'SYNC - Azure AD Connect delta sync triggered successfully'
        return $true
    }
    catch {
        Write-Log "SYNC WARNING - $($_.Exception.Message)"
        return $false
    }
}

function New-OrgEmployee {
    param(
        [string]$FirstName,
        [string]$LastName,
        [string]$PersonalEmail,
        [hashtable]$DeptConfig,
        [string]$JobTitle,
        [string]$ManagerDN,
        [string]$MirrorFromDN,
        [string[]]$AllowedAdminMirrorGroups
    )

    $fullName = "$FirstName $LastName"
    $plain = New-RandomPassword
    $secure = ConvertTo-SecureString $plain -AsPlainText -Force
    $sam = Get-UniqueSamAccountName -FirstName $FirstName -LastName $LastName
    if (-not $sam) { throw "Unable to find unique sAMAccountName for $fullName" }

    $upn = "$sam@$($script:OrgConfig.AdDomain)"
    $primarySmtp = "$sam@$($script:OrgConfig.PrimaryMailDomain)"

    $newUserParams = @{
        Name                  = $fullName
        GivenName             = $FirstName
        Surname               = $LastName
        SamAccountName        = $sam
        UserPrincipalName     = $upn
        Path                  = $DeptConfig.Path
        DisplayName           = $fullName
        Enabled               = $true
        ChangePasswordAtLogon = $true
        AccountPassword       = $secure
        HomePage              = $PersonalEmail
    }
    if (-not [string]::IsNullOrWhiteSpace($JobTitle)) { $newUserParams['Title'] = $JobTitle.Trim() }
    if (-not [string]::IsNullOrWhiteSpace($ManagerDN)) { $newUserParams['Manager'] = $ManagerDN }

    New-ADUser @newUserParams
    Set-UserProxyAddresses -SamAccountName $sam -LastName $LastName -FirstName $FirstName -PrimarySmtp $primarySmtp
    Set-ADUser -Identity $sam -Email $primarySmtp

    $mirroredGroups = @()
    if (-not [string]::IsNullOrWhiteSpace($MirrorFromDN)) {
        $mirroredGroups = Copy-MirrorUserGroups -SourceIdentity $MirrorFromDN -TargetSamAccountName $sam -AllowedAdminGroupNames $AllowedAdminMirrorGroups
    }
    $syncTriggered = Invoke-DeltaSync
    Write-Log "EMPLOYEE - $fullName dept='$($DeptConfig.Dept)' title='$JobTitle' manager='$ManagerDN'"

    [pscustomobject]@{
        SamAccountName    = $sam
        UPN               = $upn
        GeneratedPassword = $plain
        MirroredGroups    = $mirroredGroups
        SyncTriggered     = $syncTriggered
    }
}

function New-OrgContractor {
    param(
        [string]$FirstName,
        [string]$LastName,
        [string]$EmailDomain,
        [string]$PersonalEmail,
        [string]$JobTitle,
        [string]$ManagerDN,
        [string]$MirrorFromDN,
        [string[]]$AllowedAdminMirrorGroups
    )

    $fullName = "$FirstName $LastName"
    $plain = New-RandomPassword
    $secure = ConvertTo-SecureString $plain -AsPlainText -Force
    $sam = Get-UniqueSamAccountName -FirstName $FirstName -LastName $LastName
    if (-not $sam) { throw "Unable to find unique sAMAccountName for contractor $fullName" }

    $upn = "$sam@$($script:OrgConfig.AdDomain)"
    $primaryEmail = "$sam@$EmailDomain"

    $newUserParams = @{
        Name                  = $fullName
        GivenName             = $FirstName
        Surname               = $LastName
        SamAccountName        = $sam
        UserPrincipalName     = $upn
        DisplayName           = $fullName
        Enabled               = $true
        ChangePasswordAtLogon = $true
        AccountPassword       = $secure
        Path                  = $script:OrgConfig.ContractorOu
        Description           = 'Contractor'
    }
    if (-not [string]::IsNullOrWhiteSpace($PersonalEmail)) { $newUserParams['HomePage'] = $PersonalEmail.Trim() }
    if (-not [string]::IsNullOrWhiteSpace($JobTitle)) { $newUserParams['Title'] = $JobTitle.Trim() }
    if (-not [string]::IsNullOrWhiteSpace($ManagerDN)) { $newUserParams['Manager'] = $ManagerDN }

    New-ADUser @newUserParams
    Set-UserProxyAddresses -SamAccountName $sam -LastName $LastName -FirstName $FirstName -PrimarySmtp $primaryEmail

    Move-ADObject -Identity (Get-ADUser -Identity $sam).DistinguishedName -TargetPath $script:OrgConfig.ContractorOktaOu
    Add-ADGroupMember -Identity $script:OrgConfig.ContractorO365Group -Members $sam -ErrorAction Stop

    $contractorsGroup = Get-ADGroup -Identity $script:OrgConfig.ContractorsGroup -Properties primaryGroupToken -ErrorAction Stop
    Add-ADGroupMember -Identity $contractorsGroup.DistinguishedName -Members $sam -ErrorAction Stop
    Set-ADUser -Identity $sam -Replace @{ primaryGroupID = $contractorsGroup.primaryGroupToken } -ErrorAction Stop
    Remove-ADGroupMember -Identity 'Domain Users' -Members $sam -Confirm:$false -ErrorAction Stop

    $mirroredGroups = @()
    if (-not [string]::IsNullOrWhiteSpace($MirrorFromDN)) {
        $mirroredGroups = Copy-MirrorUserGroups -SourceIdentity $MirrorFromDN -TargetSamAccountName $sam -AllowedAdminGroupNames $AllowedAdminMirrorGroups
    }
    $syncTriggered = Invoke-DeltaSync
    Write-Log "CONTRACTOR - $fullName domain='$EmailDomain' title='$JobTitle' manager='$ManagerDN'"

    [pscustomobject]@{
        SamAccountName    = $sam
        UPN               = $upn
        PrimaryEmail      = $primaryEmail
        GeneratedPassword = $plain
        MirroredGroups    = $mirroredGroups
        SyncTriggered     = $syncTriggered
    }
}

$form = New-Object System.Windows.Forms.Form
$form.Text = 'New Hire / Contractor Onboarding'
$form.Size = New-Object System.Drawing.Size(760, 720)
$form.StartPosition = 'CenterScreen'
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)

$lblBanner = New-Object System.Windows.Forms.Label
$lblBanner.Text = 'CONTOSO'
$lblBanner.Font = New-Object System.Drawing.Font('Segoe UI', 16, [System.Drawing.FontStyle]::Bold)
$lblBanner.ForeColor = [System.Drawing.Color]::White
$lblBanner.BackColor = [System.Drawing.Color]::SteelBlue
$lblBanner.TextAlign = 'MiddleCenter'
$lblBanner.Dock = 'Top'
$lblBanner.Height = 46
$form.Controls.Add($lblBanner)

$grpType = New-Object System.Windows.Forms.GroupBox
$grpType.Text = 'User Type'
$grpType.Location = New-Object System.Drawing.Point(12, 60)
$grpType.Size = New-Object System.Drawing.Size(320, 95)

$rbEmployee = New-Object System.Windows.Forms.RadioButton
$rbEmployee.Text = 'Employee'
$rbEmployee.Location = New-Object System.Drawing.Point(16, 28)
$rbEmployee.Size = New-Object System.Drawing.Size(220, 24)
$rbEmployee.Checked = $true

$rbContractor = New-Object System.Windows.Forms.RadioButton
$rbContractor.Text = 'Contractor / Consultant'
$rbContractor.Location = New-Object System.Drawing.Point(16, 58)
$rbContractor.Size = New-Object System.Drawing.Size(220, 24)

$grpType.Controls.AddRange(@($rbEmployee, $rbContractor))
$form.Controls.Add($grpType)

$btnGraphConnect = New-Object System.Windows.Forms.Button
$btnGraphConnect.Text = 'Refresh Licenses'
$btnGraphConnect.Location = New-Object System.Drawing.Point(538, 82)
$btnGraphConnect.Size = New-Object System.Drawing.Size(110, 32)
$form.Controls.Add($btnGraphConnect)

$btnClose = New-Object System.Windows.Forms.Button
$btnClose.Text = 'Close'
$btnClose.Location = New-Object System.Drawing.Point(640, 82)
$btnClose.Size = New-Object System.Drawing.Size(92, 32)
$form.Controls.Add($btnClose)

$panelEmp = New-Object System.Windows.Forms.GroupBox
$panelEmp.Text = 'Employee Details'
$panelEmp.Location = New-Object System.Drawing.Point(12, 170)
$panelEmp.Size = New-Object System.Drawing.Size(720, 355)

$lblDept = New-Object System.Windows.Forms.Label
$lblDept.Text = 'Department:'
$lblDept.Location = New-Object System.Drawing.Point(18, 34)
$lblDept.Size = New-Object System.Drawing.Size(90, 22)

$cmbDept = New-Object System.Windows.Forms.ComboBox
$cmbDept.Location = New-Object System.Drawing.Point(118, 30)
$cmbDept.Size = New-Object System.Drawing.Size(290, 28)
$cmbDept.DropDownStyle = 'DropDownList'
$cmbDept.IntegralHeight = $false
$cmbDept.DropDownHeight = 300
$cmbDept.Items.AddRange(@([string[]]$script:OrgConfig.Departments.Keys))
$cmbDept.SelectedIndex = 0

$lblFirst = New-Object System.Windows.Forms.Label
$lblFirst.Text = 'First Name:'
$lblFirst.Location = New-Object System.Drawing.Point(18, 74)
$lblFirst.Size = New-Object System.Drawing.Size(90, 22)
$txtFirst = New-Object System.Windows.Forms.TextBox
$txtFirst.Location = New-Object System.Drawing.Point(118, 70)
$txtFirst.Size = New-Object System.Drawing.Size(190, 26)

$lblLast = New-Object System.Windows.Forms.Label
$lblLast.Text = 'Last Name:'
$lblLast.Location = New-Object System.Drawing.Point(340, 74)
$lblLast.Size = New-Object System.Drawing.Size(90, 22)
$txtLast = New-Object System.Windows.Forms.TextBox
$txtLast.Location = New-Object System.Drawing.Point(440, 70)
$txtLast.Size = New-Object System.Drawing.Size(190, 26)

$lblJobTitle = New-Object System.Windows.Forms.Label
$lblJobTitle.Text = 'Job Title:'
$lblJobTitle.Location = New-Object System.Drawing.Point(18, 114)
$lblJobTitle.Size = New-Object System.Drawing.Size(90, 22)
$txtJobTitle = New-Object System.Windows.Forms.TextBox
$txtJobTitle.Location = New-Object System.Drawing.Point(118, 110)
$txtJobTitle.Size = New-Object System.Drawing.Size(190, 26)

$lblManager = New-Object System.Windows.Forms.Label
$lblManager.Text = 'Manager:'
$lblManager.Location = New-Object System.Drawing.Point(340, 114)
$lblManager.Size = New-Object System.Drawing.Size(90, 22)
$txtManager = New-Object System.Windows.Forms.TextBox
$txtManager.Location = New-Object System.Drawing.Point(440, 110)
$txtManager.Size = New-Object System.Drawing.Size(135, 26)

$btnResolveManager = New-Object System.Windows.Forms.Button
$btnResolveManager.Text = 'Check'
$btnResolveManager.Location = New-Object System.Drawing.Point(582, 109)
$btnResolveManager.Size = New-Object System.Drawing.Size(72, 28)

$lblManagerResolved = New-Object System.Windows.Forms.Label
$lblManagerResolved.Text = ''
$lblManagerResolved.Location = New-Object System.Drawing.Point(440, 140)
$lblManagerResolved.Size = New-Object System.Drawing.Size(250, 18)
$lblManagerResolved.Font = New-Object System.Drawing.Font('Segoe UI', 8)
$lblManagerResolved.ForeColor = [System.Drawing.Color]::DarkGreen

$lblMirrorUser = New-Object System.Windows.Forms.Label
$lblMirrorUser.Text = 'User to Mirror:'
$lblMirrorUser.Location = New-Object System.Drawing.Point(18, 174)
$lblMirrorUser.Size = New-Object System.Drawing.Size(90, 22)
$txtMirrorUser = New-Object System.Windows.Forms.TextBox
$txtMirrorUser.Location = New-Object System.Drawing.Point(118, 170)
$txtMirrorUser.Size = New-Object System.Drawing.Size(320, 26)

$btnResolveMirror = New-Object System.Windows.Forms.Button
$btnResolveMirror.Text = 'Check'
$btnResolveMirror.Location = New-Object System.Drawing.Point(474, 168)
$btnResolveMirror.Size = New-Object System.Drawing.Size(72, 28)

$lblMirrorResolved = New-Object System.Windows.Forms.Label
$lblMirrorResolved.Text = ''
$lblMirrorResolved.Location = New-Object System.Drawing.Point(118, 200)
$lblMirrorResolved.Size = New-Object System.Drawing.Size(520, 18)
$lblMirrorResolved.Font = New-Object System.Drawing.Font('Segoe UI', 8)
$lblMirrorResolved.ForeColor = [System.Drawing.Color]::DarkGreen

$lblPersonal = New-Object System.Windows.Forms.Label
$lblPersonal.Text = 'Personal Email:'
$lblPersonal.Location = New-Object System.Drawing.Point(18, 228)
$lblPersonal.Size = New-Object System.Drawing.Size(90, 22)
$txtPersonal = New-Object System.Windows.Forms.TextBox
$txtPersonal.Location = New-Object System.Drawing.Point(118, 224)
$txtPersonal.Size = New-Object System.Drawing.Size(350, 26)

$grpEmpLicense = New-Object System.Windows.Forms.GroupBox
$grpEmpLicense.Text = 'Microsoft 365 License'
$grpEmpLicense.Location = New-Object System.Drawing.Point(18, 264)
$grpEmpLicense.Size = New-Object System.Drawing.Size(672, 92)

$chkEmpAssignLicense = New-Object System.Windows.Forms.CheckBox
$chkEmpAssignLicense.Text = 'Assign selected license after sync'
$chkEmpAssignLicense.Location = New-Object System.Drawing.Point(14, 30)
$chkEmpAssignLicense.Size = New-Object System.Drawing.Size(230, 24)

$cmbEmpLicense = New-Object System.Windows.Forms.ComboBox
$cmbEmpLicense.Location = New-Object System.Drawing.Point(250, 27)
$cmbEmpLicense.Size = New-Object System.Drawing.Size(210, 28)
$cmbEmpLicense.DropDownStyle = 'DropDownList'

$lblEmpLicenseStatus = New-Object System.Windows.Forms.Label
$lblEmpLicenseStatus.Text = 'Available: connect to Graph to load SKUs'
$lblEmpLicenseStatus.Location = New-Object System.Drawing.Point(250, 58)
$lblEmpLicenseStatus.Size = New-Object System.Drawing.Size(410, 18)

$grpEmpLicense.Controls.AddRange(@($chkEmpAssignLicense, $cmbEmpLicense, $lblEmpLicenseStatus))

$panelEmp.Controls.AddRange(@(
    $lblDept, $cmbDept,
    $lblFirst, $txtFirst,
    $lblLast, $txtLast,
    $lblJobTitle, $txtJobTitle,
    $lblManager, $txtManager, $btnResolveManager, $lblManagerResolved,
    $lblMirrorUser, $txtMirrorUser, $btnResolveMirror, $lblMirrorResolved,
    $lblPersonal, $txtPersonal,
    $grpEmpLicense
))
$form.Controls.Add($panelEmp)

$panelCon = New-Object System.Windows.Forms.GroupBox
$panelCon.Text = 'Contractor Details'
$panelCon.Location = New-Object System.Drawing.Point(12, 170)
$panelCon.Size = New-Object System.Drawing.Size(720, 355)
$panelCon.Visible = $false

$lblCFirst = New-Object System.Windows.Forms.Label
$lblCFirst.Text = 'First Name:'
$lblCFirst.Location = New-Object System.Drawing.Point(18, 34)
$lblCFirst.Size = New-Object System.Drawing.Size(90, 22)
$txtCFirst = New-Object System.Windows.Forms.TextBox
$txtCFirst.Location = New-Object System.Drawing.Point(118, 30)
$txtCFirst.Size = New-Object System.Drawing.Size(190, 26)

$lblCLast = New-Object System.Windows.Forms.Label
$lblCLast.Text = 'Last Name:'
$lblCLast.Location = New-Object System.Drawing.Point(346, 34)
$lblCLast.Size = New-Object System.Drawing.Size(90, 22)
$txtCLast = New-Object System.Windows.Forms.TextBox
$txtCLast.Location = New-Object System.Drawing.Point(446, 30)
$txtCLast.Size = New-Object System.Drawing.Size(190, 26)

$lblCJobTitle = New-Object System.Windows.Forms.Label
$lblCJobTitle.Text = 'Job Title:'
$lblCJobTitle.Location = New-Object System.Drawing.Point(18, 74)
$lblCJobTitle.Size = New-Object System.Drawing.Size(90, 22)
$txtCJobTitle = New-Object System.Windows.Forms.TextBox
$txtCJobTitle.Location = New-Object System.Drawing.Point(118, 70)
$txtCJobTitle.Size = New-Object System.Drawing.Size(190, 26)

$lblConManager = New-Object System.Windows.Forms.Label
$lblConManager.Text = 'Manager:'
$lblConManager.Location = New-Object System.Drawing.Point(340, 74)
$lblConManager.Size = New-Object System.Drawing.Size(90, 22)
$txtConManager = New-Object System.Windows.Forms.TextBox
$txtConManager.Location = New-Object System.Drawing.Point(440, 70)
$txtConManager.Size = New-Object System.Drawing.Size(135, 26)

$btnConResolveManager = New-Object System.Windows.Forms.Button
$btnConResolveManager.Text = 'Check'
$btnConResolveManager.Location = New-Object System.Drawing.Point(582, 69)
$btnConResolveManager.Size = New-Object System.Drawing.Size(72, 28)

$lblConManagerResolved = New-Object System.Windows.Forms.Label
$lblConManagerResolved.Text = ''
$lblConManagerResolved.Location = New-Object System.Drawing.Point(440, 96)
$lblConManagerResolved.Size = New-Object System.Drawing.Size(250, 18)
$lblConManagerResolved.Font = New-Object System.Drawing.Font('Segoe UI', 8)
$lblConManagerResolved.ForeColor = [System.Drawing.Color]::DarkGreen

$lblConMirrorUser = New-Object System.Windows.Forms.Label
$lblConMirrorUser.Text = 'User to Mirror:'
$lblConMirrorUser.Location = New-Object System.Drawing.Point(18, 124)
$lblConMirrorUser.Size = New-Object System.Drawing.Size(90, 22)
$txtConMirrorUser = New-Object System.Windows.Forms.TextBox
$txtConMirrorUser.Location = New-Object System.Drawing.Point(118, 120)
$txtConMirrorUser.Size = New-Object System.Drawing.Size(320, 26)

$btnConResolveMirror = New-Object System.Windows.Forms.Button
$btnConResolveMirror.Text = 'Check'
$btnConResolveMirror.Location = New-Object System.Drawing.Point(474, 118)
$btnConResolveMirror.Size = New-Object System.Drawing.Size(72, 28)

$lblConMirrorResolved = New-Object System.Windows.Forms.Label
$lblConMirrorResolved.Text = ''
$lblConMirrorResolved.Location = New-Object System.Drawing.Point(118, 146)
$lblConMirrorResolved.Size = New-Object System.Drawing.Size(520, 18)
$lblConMirrorResolved.Font = New-Object System.Drawing.Font('Segoe UI', 8)
$lblConMirrorResolved.ForeColor = [System.Drawing.Color]::DarkGreen

$lblCPersonal = New-Object System.Windows.Forms.Label
$lblCPersonal.Text = 'Personal Email:'
$lblCPersonal.Location = New-Object System.Drawing.Point(18, 176)
$lblCPersonal.Size = New-Object System.Drawing.Size(90, 22)
$txtCPersonal = New-Object System.Windows.Forms.TextBox
$txtCPersonal.Location = New-Object System.Drawing.Point(118, 172)
$txtCPersonal.Size = New-Object System.Drawing.Size(350, 26)

$grpEmailType = New-Object System.Windows.Forms.GroupBox
$grpEmailType.Text = 'Email Type'
$grpEmailType.Location = New-Object System.Drawing.Point(18, 208)
$grpEmailType.Size = New-Object System.Drawing.Size(300, 68)

$rbEmailPrimary = New-Object System.Windows.Forms.RadioButton
$rbEmailPrimary.Text = '@contoso.com'
$rbEmailPrimary.Location = New-Object System.Drawing.Point(16, 20)
$rbEmailPrimary.Size = New-Object System.Drawing.Size(220, 24)
$rbEmailPrimary.Checked = $true

$rbEmailExt = New-Object System.Windows.Forms.RadioButton
$rbEmailExt.Text = '@contractors.contoso.com'
$rbEmailExt.Location = New-Object System.Drawing.Point(16, 44)
$rbEmailExt.Size = New-Object System.Drawing.Size(220, 24)

$grpEmailType.Controls.AddRange(@($rbEmailPrimary, $rbEmailExt))

$grpConLicense = New-Object System.Windows.Forms.GroupBox
$grpConLicense.Text = 'Microsoft 365 License'
$grpConLicense.Location = New-Object System.Drawing.Point(18, 282)
$grpConLicense.Size = New-Object System.Drawing.Size(672, 72)

$chkConAssignLicense = New-Object System.Windows.Forms.CheckBox
$chkConAssignLicense.Text = 'Assign selected license after sync'
$chkConAssignLicense.Location = New-Object System.Drawing.Point(14, 26)
$chkConAssignLicense.Size = New-Object System.Drawing.Size(230, 24)

$cmbConLicense = New-Object System.Windows.Forms.ComboBox
$cmbConLicense.Location = New-Object System.Drawing.Point(250, 23)
$cmbConLicense.Size = New-Object System.Drawing.Size(210, 28)
$cmbConLicense.DropDownStyle = 'DropDownList'

$lblConLicenseStatus = New-Object System.Windows.Forms.Label
$lblConLicenseStatus.Text = 'Available: connect to Graph to load SKUs'
$lblConLicenseStatus.Location = New-Object System.Drawing.Point(250, 54)
$lblConLicenseStatus.Size = New-Object System.Drawing.Size(410, 18)

$grpConLicense.Controls.AddRange(@($chkConAssignLicense, $cmbConLicense, $lblConLicenseStatus))

$panelCon.Controls.AddRange(@(
    $lblCFirst, $txtCFirst,
    $lblCLast, $txtCLast,
    $lblCJobTitle, $txtCJobTitle,
    $lblConManager, $txtConManager, $btnConResolveManager, $lblConManagerResolved,
    $lblConMirrorUser, $txtConMirrorUser, $btnConResolveMirror, $lblConMirrorResolved,
    $lblCPersonal, $txtCPersonal,
    $grpEmailType, $grpConLicense
))
$form.Controls.Add($panelCon)

$script:txtOutput = New-Object System.Windows.Forms.TextBox
$script:txtOutput.Location = New-Object System.Drawing.Point(12, 540)
$script:txtOutput.Size = New-Object System.Drawing.Size(720, 125)
$script:txtOutput.Multiline = $true
$script:txtOutput.ScrollBars = 'Vertical'
$script:txtOutput.Font = New-Object System.Drawing.Font('Consolas', 9)
$form.Controls.Add($script:txtOutput)

$btnCreate = New-Object System.Windows.Forms.Button
$btnCreate.Text = 'Create User'
$btnCreate.Location = New-Object System.Drawing.Point(430, 82)
$btnCreate.Size = New-Object System.Drawing.Size(100, 32)
$form.Controls.Add($btnCreate)

$rbEmployee.Add_CheckedChanged({ if ($rbEmployee.Checked) { $panelEmp.Visible = $true; $panelCon.Visible = $false } })
$rbContractor.Add_CheckedChanged({ if ($rbContractor.Checked) { $panelEmp.Visible = $false; $panelCon.Visible = $true } })
$btnClose.Add_Click({ $form.Close() })

$btnResolveManager.Add_Click({
    try {
        if ([string]::IsNullOrWhiteSpace($txtManager.Text)) {
            $script:ResolvedManager = $null
            $lblManagerResolved.Text = ''
            return
        }
        $resolved = Resolve-UserForDisplay -Identity $txtManager.Text.Trim()
        $script:ResolvedManager = $resolved
        $script:ResolvedManagerDN = $resolved.DN
        $lblManagerResolved.ForeColor = [System.Drawing.Color]::DarkGreen
        $lblManagerResolved.Text = "Resolved: $($resolved.DisplayName) [$($resolved.SamAccountName)]"
    }
    catch {
        $script:ResolvedManager = $null
        $lblManagerResolved.ForeColor = [System.Drawing.Color]::DarkRed
        $lblManagerResolved.Text = 'Manager not found'
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Manager lookup failed', 'OK', 'Error') | Out-Null
    }
})

$btnResolveMirror.Add_Click({
    try {
        if ([string]::IsNullOrWhiteSpace($txtMirrorUser.Text)) {
            $script:ResolvedMirrorUser = $null
            $lblMirrorResolved.Text = ''
            return
        }
        $resolved = Resolve-UserForDisplay -Identity $txtMirrorUser.Text.Trim()
        $script:ResolvedMirrorUser = $resolved
        $script:ResolvedMirrorUserDN = $resolved.DN
        $groups = @(Get-MirrorSourceGroups -SourceIdentity $txtMirrorUser.Text.Trim())
        $adminGroups = @($groups | Where-Object { $_.IsAdminLike } | Select-Object -ExpandProperty Name)
        if ($adminGroups.Count -gt 0) {
            $script:AllowedAdminMirrorGroups = @(Show-AdminGroupReviewDialog -Groups $groups)
            $lblMirrorResolved.ForeColor = [System.Drawing.Color]::DarkGreen
            $lblMirrorResolved.Text = "Resolved: $($resolved.DisplayName) [$($resolved.SamAccountName)] - Admin groups selected: $($script:AllowedAdminMirrorGroups.Count)/$($adminGroups.Count)"
        }
        else {
            $script:AllowedAdminMirrorGroups = @()
            $lblMirrorResolved.ForeColor = [System.Drawing.Color]::DarkGreen
            $lblMirrorResolved.Text = "Resolved: $($resolved.DisplayName) [$($resolved.SamAccountName)]"
        }
    }
    catch {
        $script:ResolvedMirrorUser = $null
        $lblMirrorResolved.ForeColor = [System.Drawing.Color]::DarkRed
        $lblMirrorResolved.Text = 'Mirror user not found'
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Mirror user lookup failed', 'OK', 'Error') | Out-Null
    }
})

$txtManager.Add_TextChanged({
    if ($script:ResolvedManager -and $txtManager.Text.Trim() -eq $script:ResolvedManager.SamAccountName) { return }
    $script:ResolvedManager = $null
    $lblManagerResolved.Text = ''
    $lblManagerResolved.ForeColor = [System.Drawing.Color]::DarkGreen
})

$txtMirrorUser.Add_TextChanged({
    if ($script:ResolvedMirrorUser -and $txtMirrorUser.Text.Trim() -eq $script:ResolvedMirrorUser.SamAccountName) { return }
    $script:ResolvedMirrorUser = $null
    $script:AllowedAdminMirrorGroups = @()
    $lblMirrorResolved.Text = ''
    $lblMirrorResolved.ForeColor = [System.Drawing.Color]::DarkGreen
})

$btnConResolveManager.Add_Click({
    try {
        if ([string]::IsNullOrWhiteSpace($txtConManager.Text)) {
            $script:ResolvedConManager = $null
            $lblConManagerResolved.Text = ''
            return
        }
        $resolved = Resolve-UserForDisplay -Identity $txtConManager.Text.Trim()
        $script:ResolvedConManager = $resolved
        $script:ResolvedConManagerDN = $resolved.DN
        $lblConManagerResolved.ForeColor = [System.Drawing.Color]::DarkGreen
        $lblConManagerResolved.Text = "Resolved: $($resolved.DisplayName) [$($resolved.SamAccountName)]"
    }
    catch {
        $script:ResolvedConManager = $null
        $lblConManagerResolved.ForeColor = [System.Drawing.Color]::DarkRed
        $lblConManagerResolved.Text = 'Manager not found'
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Manager lookup failed', 'OK', 'Error') | Out-Null
    }
})

$btnConResolveMirror.Add_Click({
    try {
        if ([string]::IsNullOrWhiteSpace($txtConMirrorUser.Text)) {
            $script:ResolvedConMirrorUser = $null
            $lblConMirrorResolved.Text = ''
            return
        }
        $resolved = Resolve-UserForDisplay -Identity $txtConMirrorUser.Text.Trim()
        $script:ResolvedConMirrorUser = $resolved
        $script:ResolvedConMirrorUserDN = $resolved.DN
        $groups = @(Get-MirrorSourceGroups -SourceIdentity $txtConMirrorUser.Text.Trim())
        $adminGroups = @($groups | Where-Object { $_.IsAdminLike } | Select-Object -ExpandProperty Name)
        if ($adminGroups.Count -gt 0) {
            $script:AllowedConAdminMirrorGroups = @(Show-AdminGroupReviewDialog -Groups $groups)
            $lblConMirrorResolved.ForeColor = [System.Drawing.Color]::DarkGreen
            $lblConMirrorResolved.Text = "Resolved: $($resolved.DisplayName) [$($resolved.SamAccountName)] - Admin groups selected: $($script:AllowedConAdminMirrorGroups.Count)/$($adminGroups.Count)"
        }
        else {
            $script:AllowedConAdminMirrorGroups = @()
            $lblConMirrorResolved.ForeColor = [System.Drawing.Color]::DarkGreen
            $lblConMirrorResolved.Text = "Resolved: $($resolved.DisplayName) [$($resolved.SamAccountName)]"
        }
    }
    catch {
        $script:ResolvedConMirrorUser = $null
        $lblConMirrorResolved.ForeColor = [System.Drawing.Color]::DarkRed
        $lblConMirrorResolved.Text = 'Mirror user not found'
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Mirror user lookup failed', 'OK', 'Error') | Out-Null
    }
})

$txtConManager.Add_TextChanged({
    if ($script:ResolvedConManager -and $txtConManager.Text.Trim() -eq $script:ResolvedConManager.SamAccountName) { return }
    $script:ResolvedConManager = $null
    $lblConManagerResolved.Text = ''
    $lblConManagerResolved.ForeColor = [System.Drawing.Color]::DarkGreen
})

$txtConMirrorUser.Add_TextChanged({
    if ($script:ResolvedConMirrorUser -and $txtConMirrorUser.Text.Trim() -eq $script:ResolvedConMirrorUser.SamAccountName) { return }
    $script:ResolvedConMirrorUser = $null
    $script:AllowedConAdminMirrorGroups = @()
    $lblConMirrorResolved.Text = ''
    $lblConMirrorResolved.ForeColor = [System.Drawing.Color]::DarkGreen
})

$btnGraphConnect.Add_Click({
    try {
        Append-Output 'Connecting to Microsoft Graph and refreshing license inventory...'
        Connect-OrgGraph | Out-Null
        Refresh-LicenseDropdown -ComboBox $cmbEmpLicense -StatusLabel $lblEmpLicenseStatus
        Refresh-LicenseDropdown -ComboBox $cmbConLicense -StatusLabel $lblConLicenseStatus
        Update-LicenseAvailabilityLabel -ComboBox $cmbEmpLicense -StatusLabel $lblEmpLicenseStatus
        Update-LicenseAvailabilityLabel -ComboBox $cmbConLicense -StatusLabel $lblConLicenseStatus
        Append-Output 'License inventory refreshed.'
        Append-Output 'Tip: if Graph binding fails, close all PowerShell windows and reopen the tool in a clean session.'
    }
    catch {
        Append-Output ("ERROR: {0}" -f $_.Exception.Message)
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Graph license refresh failed', 'OK', 'Error') | Out-Null
    }
})

$cmbEmpLicense.Add_SelectedIndexChanged({ Update-LicenseAvailabilityLabel -ComboBox $cmbEmpLicense -StatusLabel $lblEmpLicenseStatus })
$cmbConLicense.Add_SelectedIndexChanged({ Update-LicenseAvailabilityLabel -ComboBox $cmbConLicense -StatusLabel $lblConLicenseStatus })

$btnCreate.Add_Click({
    try {
        $script:txtOutput.Clear()
        if ($rbEmployee.Checked) {
            if (-not $txtFirst.Text.Trim() -or -not $txtLast.Text.Trim() -or -not $txtPersonal.Text.Trim()) {
                [System.Windows.Forms.MessageBox]::Show('Please fill the required employee fields (First, Last, Personal Email). Job Title and User to Mirror are optional.', 'Missing data', 'OK', 'Error') | Out-Null
                return
            }

            if ($chkEmpAssignLicense.Checked -and $cmbEmpLicense.SelectedIndex -lt 0) {
                [System.Windows.Forms.MessageBox]::Show('Select a license or clear the assignment checkbox.', 'Missing license', 'OK', 'Error') | Out-Null
                return
            }

            if ($txtManager.Text.Trim() -and -not $script:ResolvedManager) {
                [System.Windows.Forms.MessageBox]::Show('Manager username was not resolved. Click Check or clear the field.', 'Blocked', 'OK', 'Error') | Out-Null
                return
            }
            if ($txtMirrorUser.Text.Trim() -and -not $script:ResolvedMirrorUser) {
                [System.Windows.Forms.MessageBox]::Show('Mirror user was not resolved. Click Check or clear the field.', 'Blocked', 'OK', 'Error') | Out-Null
                return
            }

            $cfg = Get-DeptConfig -Key ([string]$cmbDept.SelectedItem)
            if (-not $cfg) {
                [System.Windows.Forms.MessageBox]::Show('Unknown department selected.', 'Error', 'OK', 'Error') | Out-Null
                return
            }

            $resolvedManagerLine = if ($txtManager.Text.Trim()) {
                if (-not $script:ResolvedManager) {
                    $script:ResolvedManager = Resolve-UserForDisplay -Identity $txtManager.Text.Trim()
                    $lblManagerResolved.ForeColor = [System.Drawing.Color]::DarkGreen
                    $lblManagerResolved.Text = "Resolved: $($script:ResolvedManager.DisplayName) [$($script:ResolvedManager.SamAccountName)]"
                }
                "Manager Resolved: $($script:ResolvedManager.DisplayName) [$($script:ResolvedManager.SamAccountName)]"
            } else {
                'Manager Resolved: <blank>'
            }

            $resolvedMirrorLine = if ($txtMirrorUser.Text.Trim()) {
                if (-not $script:ResolvedMirrorUser) {
                    $script:ResolvedMirrorUser = Resolve-UserForDisplay -Identity $txtMirrorUser.Text.Trim()
                    $lblMirrorResolved.ForeColor = [System.Drawing.Color]::DarkGreen
                    $lblMirrorResolved.Text = "Resolved: $($script:ResolvedMirrorUser.DisplayName) [$($script:ResolvedMirrorUser.SamAccountName)]"
                }
                $groups = @(Get-MirrorSourceGroups -SourceIdentity $txtMirrorUser.Text.Trim())
                $adminGroups = @($groups | Where-Object { $_.IsAdminLike } | Select-Object -ExpandProperty Name)
                if ($adminGroups.Count -gt 0 -and $script:AllowedAdminMirrorGroups.Count -eq 0) {
                    $script:AllowedAdminMirrorGroups = @(Show-AdminGroupReviewDialog -Groups $groups)
                }
                "Mirror Resolved: $($script:ResolvedMirrorUser.DisplayName) [$($script:ResolvedMirrorUser.SamAccountName)] | Admin groups selected: $($script:AllowedAdminMirrorGroups.Count)"
            } else {
                'Mirror Resolved: <blank>'
            }

            $licenseLine = if ($chkEmpAssignLicense.Checked -and $cmbEmpLicense.SelectedIndex -ge 0) {
                $empSelectedLicense = @($cmbEmpLicense.Tag)[$cmbEmpLicense.SelectedIndex]
                "License: $($empSelectedLicense.DisplayName)"
            } else {
                'License: <none>'
            }

            $confirmMessage = "Please check the spelling before creating the new hire.`r`n`r`nName: {0} {1}`r`nDepartment: {2}`r`nPersonal Email: {3}`r`nJob Title: {4}`r`n{5}`r`n{6}`r`n{7}`r`n`r`nCreate this new hire?" -f $txtFirst.Text.Trim(), $txtLast.Text.Trim(), [string]$cmbDept.SelectedItem, $txtPersonal.Text.Trim(), $txtJobTitle.Text.Trim(), $resolvedManagerLine, $resolvedMirrorLine, $licenseLine
            $confirmResult = [System.Windows.Forms.MessageBox]::Show($confirmMessage, 'Confirm New Hire', 'YesNo', 'Question')
            if ($confirmResult -ne [System.Windows.Forms.DialogResult]::Yes) { return }

            $managerDN = if ($script:ResolvedManager) { $script:ResolvedManagerDN } else { $null }
            $mirrorDN  = if ($script:ResolvedMirrorUser) { $script:ResolvedMirrorUserDN } else { $null }

            $result = New-OrgEmployee -FirstName $txtFirst.Text.Trim() -LastName $txtLast.Text.Trim() -PersonalEmail $txtPersonal.Text.Trim() -DeptConfig $cfg -JobTitle $txtJobTitle.Text.Trim() -ManagerDN $managerDN -MirrorFromDN $mirrorDN -AllowedAdminMirrorGroups $script:AllowedAdminMirrorGroups

            Write-Log "EMPLOYEE CREATED - Name='$($txtFirst.Text.Trim()) $($txtLast.Text.Trim())', SamAccountName='$($result.SamAccountName)', UPN='$($result.UPN)'"
            Append-Output 'Employee created:'
            Append-Output (("  Name           : {0} {1}" -f $txtFirst.Text.Trim(), $txtLast.Text.Trim()))
            Append-Output (("  Department     : {0}" -f [string]$cmbDept.SelectedItem))
            Append-Output (("  Username       : {0}" -f $result.SamAccountName))
            Append-Output (("  UPN            : {0}" -f $result.UPN))
            Append-Output (("  Temp Password  : {0}" -f $result.GeneratedPassword))
            Append-Output (("  Sync Triggered : {0}" -f $result.SyncTriggered))
            if ($txtJobTitle.Text.Trim()) { Append-Output (("  Job Title      : {0}" -f $txtJobTitle.Text.Trim())) }
            if ($txtManager.Text.Trim()) { Append-Output (("  Manager        : {0}" -f $txtManager.Text.Trim())) }
            if ($txtMirrorUser.Text.Trim()) {
                Append-Output (("  Mirrored From  : {0}" -f $txtMirrorUser.Text.Trim()))
                Append-Output (("  Groups Added   : {0}" -f (($result.MirroredGroups | Sort-Object -Unique) -join ', ')))
            }

            if ($chkEmpAssignLicense.Checked) {
                if (-not $script:GraphConnected) {
                    throw 'Graph is not connected. Click Refresh Licenses before assigning a license.'
                }
                $selectedLicense = @($cmbEmpLicense.Tag)[$cmbEmpLicense.SelectedIndex]
                Append-Output 'Waiting for cloud user to appear after sync...'
                $cloudUser = Wait-ForCloudUser -UserPrincipalName $result.UPN
                if (-not $cloudUser.UsageLocation) {
                    Set-CloudUsageLocation -UserPrincipalName $result.UPN -UsageLocation 'US'
                }
                $assigned = Assign-LicenseToCloudUser -UserPrincipalName $result.UPN -SkuId $selectedLicense.SkuId
                Refresh-LicenseDropdown -ComboBox $cmbEmpLicense -StatusLabel $lblEmpLicenseStatus
                Refresh-LicenseDropdown -ComboBox $cmbConLicense -StatusLabel $lblConLicenseStatus
                Append-Output (("  License Assigned: {0}" -f $assigned.DisplayName))
            }
        }
        else {
            if (-not $txtCFirst.Text.Trim() -or -not $txtCLast.Text.Trim()) {
                [System.Windows.Forms.MessageBox]::Show('Please fill contractor first and last name.', 'Missing data', 'OK', 'Error') | Out-Null
                return
            }

            if ($chkConAssignLicense.Checked -and $cmbConLicense.SelectedIndex -lt 0) {
                [System.Windows.Forms.MessageBox]::Show('Select a contractor license or clear the assignment checkbox.', 'Missing license', 'OK', 'Error') | Out-Null
                return
            }

            if ($txtConManager.Text.Trim() -and -not $script:ResolvedConManager) {
                [System.Windows.Forms.MessageBox]::Show('Contractor manager username was not resolved. Click Check or clear the field.', 'Blocked', 'OK', 'Error') | Out-Null
                return
            }
            if ($txtConMirrorUser.Text.Trim() -and -not $script:ResolvedConMirrorUser) {
                [System.Windows.Forms.MessageBox]::Show('Contractor mirror user was not resolved. Click Check or clear the field.', 'Blocked', 'OK', 'Error') | Out-Null
                return
            }

            $resolvedConManagerLine = if ($txtConManager.Text.Trim()) {
                if (-not $script:ResolvedConManager) {
                    $script:ResolvedConManager = Resolve-UserForDisplay -Identity $txtConManager.Text.Trim()
                    $lblConManagerResolved.ForeColor = [System.Drawing.Color]::DarkGreen
                    $lblConManagerResolved.Text = "Resolved: $($script:ResolvedConManager.DisplayName) [$($script:ResolvedConManager.SamAccountName)]"
                }
                "Manager Resolved: $($script:ResolvedConManager.DisplayName) [$($script:ResolvedConManager.SamAccountName)]"
            } else {
                'Manager Resolved: <blank>'
            }

            $resolvedConMirrorLine = if ($txtConMirrorUser.Text.Trim()) {
                if (-not $script:ResolvedConMirrorUser) {
                    $script:ResolvedConMirrorUser = Resolve-UserForDisplay -Identity $txtConMirrorUser.Text.Trim()
                    $lblConMirrorResolved.ForeColor = [System.Drawing.Color]::DarkGreen
                    $lblConMirrorResolved.Text = "Resolved: $($script:ResolvedConMirrorUser.DisplayName) [$($script:ResolvedConMirrorUser.SamAccountName)]"
                }
                $groups = @(Get-MirrorSourceGroups -SourceIdentity $txtConMirrorUser.Text.Trim())
                $adminGroups = @($groups | Where-Object { $_.IsAdminLike } | Select-Object -ExpandProperty Name)
                if ($adminGroups.Count -gt 0 -and $script:AllowedConAdminMirrorGroups.Count -eq 0) {
                    $script:AllowedConAdminMirrorGroups = @(Show-AdminGroupReviewDialog -Groups $groups)
                }
                "Mirror Resolved: $($script:ResolvedConMirrorUser.DisplayName) [$($script:ResolvedConMirrorUser.SamAccountName)] | Admin groups selected: $($script:AllowedConAdminMirrorGroups.Count)"
            } else {
                'Mirror Resolved: <blank>'
            }

            $domain = if ($rbEmailExt.Checked) { $script:OrgConfig.ContractorMailDomain } else { $script:OrgConfig.PrimaryMailDomain }
            $licenseLine = if ($chkConAssignLicense.Checked -and $cmbConLicense.SelectedIndex -ge 0) {
                $conSelectedLicense = @($cmbConLicense.Tag)[$cmbConLicense.SelectedIndex]
                "License: $($conSelectedLicense.DisplayName)"
            } else {
                'License: <none>'
            }
            $confirmMessage = "Please check the spelling before creating the contractor.`r`n`r`nName: {0} {1}`r`nEmail Domain: {2}`r`nPersonal Email: {3}`r`nJob Title: {4}`r`n{5}`r`n{6}`r`n{7}`r`n`r`nCreate this contractor?" -f $txtCFirst.Text.Trim(), $txtCLast.Text.Trim(), $domain, $txtCPersonal.Text.Trim(), $txtCJobTitle.Text.Trim(), $resolvedConManagerLine, $resolvedConMirrorLine, $licenseLine
            $confirmResult = [System.Windows.Forms.MessageBox]::Show($confirmMessage, 'Confirm Contractor', 'YesNo', 'Question')
            if ($confirmResult -ne [System.Windows.Forms.DialogResult]::Yes) { return }

            $conManagerDN = if ($script:ResolvedConManager) { $script:ResolvedConManagerDN } else { $null }
            $conMirrorDN  = if ($script:ResolvedConMirrorUser) { $script:ResolvedConMirrorUserDN } else { $null }

            $result = New-OrgContractor -FirstName $txtCFirst.Text.Trim() -LastName $txtCLast.Text.Trim() -EmailDomain $domain -PersonalEmail $txtCPersonal.Text.Trim() -JobTitle $txtCJobTitle.Text.Trim() -ManagerDN $conManagerDN -MirrorFromDN $conMirrorDN -AllowedAdminMirrorGroups $script:AllowedConAdminMirrorGroups

            Write-Log "CONTRACTOR CREATED - Name='$($txtCFirst.Text.Trim()) $($txtCLast.Text.Trim())', SamAccountName='$($result.SamAccountName)', UPN='$($result.UPN)', PrimaryEmail='$($result.PrimaryEmail)'"
            Append-Output 'Contractor created:'
            Append-Output (("  Name           : {0} {1}" -f $txtCFirst.Text.Trim(), $txtCLast.Text.Trim()))
            Append-Output (("  Email Domain   : {0}" -f $domain))
            Append-Output (("  Username       : {0}" -f $result.SamAccountName))
            Append-Output (("  UPN            : {0}" -f $result.UPN))
            Append-Output (("  Temp Password  : {0}" -f $result.GeneratedPassword))
            Append-Output (("  Sync Triggered : {0}" -f $result.SyncTriggered))
            if ($txtCJobTitle.Text.Trim()) { Append-Output (("  Job Title      : {0}" -f $txtCJobTitle.Text.Trim())) }
            if ($txtCPersonal.Text.Trim()) { Append-Output (("  Personal Email : {0}" -f $txtCPersonal.Text.Trim())) }
            if ($txtConManager.Text.Trim()) { Append-Output (("  Manager        : {0}" -f $txtConManager.Text.Trim())) }
            if ($txtConMirrorUser.Text.Trim()) {
                Append-Output (("  Mirrored From  : {0}" -f $txtConMirrorUser.Text.Trim()))
                Append-Output (("  Groups Added   : {0}" -f (($result.MirroredGroups | Sort-Object -Unique) -join ', ')))
            }

            if ($chkConAssignLicense.Checked) {
                if (-not $script:GraphConnected) {
                    throw 'Graph is not connected. Click Refresh Licenses before assigning a license.'
                }
                $selectedLicense = @($cmbConLicense.Tag)[$cmbConLicense.SelectedIndex]
                Append-Output 'Waiting for cloud contractor user to appear after sync...'
                $cloudUser = Wait-ForCloudUser -UserPrincipalName $result.UPN
                if (-not $cloudUser.UsageLocation) {
                    Set-CloudUsageLocation -UserPrincipalName $result.UPN -UsageLocation 'US'
                }
                $assigned = Assign-LicenseToCloudUser -UserPrincipalName $result.UPN -SkuId $selectedLicense.SkuId
                Refresh-LicenseDropdown -ComboBox $cmbEmpLicense -StatusLabel $lblEmpLicenseStatus
                Refresh-LicenseDropdown -ComboBox $cmbConLicense -StatusLabel $lblConLicenseStatus
                Append-Output (("  License Assigned: {0}" -f $assigned.DisplayName))
            }
        }
    }
    catch {
        Write-Log "ERROR - $($_.Exception.Message)"
        Append-Output (("ERROR: {0}" -f $_.Exception.Message))
    }
})

$script:LastActivity = Get-Date
function Reset-InactivityTimer { $script:LastActivity = Get-Date }

$form.Add_Shown({
    $script:txtOutput.Clear()
    Append-Output 'Session notice:'
    Append-Output '- The window will close automatically after 1 minute of inactivity.'
    Append-Output '- Use Refresh Licenses to connect to Graph and load seat counts.'
    Append-Output ('- Debug transcript path: ' + $script:TranscriptPath)
    Append-Output ''
    Reset-InactivityTimer
})

$controlsToTrack = @(
    $form,
    $txtFirst, $txtLast, $txtJobTitle, $txtManager, $txtMirrorUser, $txtPersonal, $cmbDept,
    $btnResolveManager, $btnResolveMirror,
    $txtCFirst, $txtCLast,
    $txtConManager, $btnConResolveManager,
    $txtConMirrorUser, $btnConResolveMirror,
    $rbEmployee, $rbContractor,
    $rbEmailPrimary, $rbEmailExt,
    $txtCJobTitle, $txtCPersonal,
    $chkEmpAssignLicense, $chkConAssignLicense,
    $cmbEmpLicense, $cmbConLicense,
    $btnGraphConnect, $btnCreate, $btnClose
)

foreach ($ctrl in $controlsToTrack) {
    if ($null -ne $ctrl) {
        try { $ctrl.Add_Click({ Reset-InactivityTimer }) } catch {}
        try { $ctrl.Add_KeyDown({ Reset-InactivityTimer }) } catch {}
        try { $ctrl.Add_TextChanged({ Reset-InactivityTimer }) } catch {}
        try { $ctrl.Add_CheckedChanged({ Reset-InactivityTimer }) } catch {}
        try { $ctrl.Add_SelectedIndexChanged({ Reset-InactivityTimer }) } catch {}
        try { $ctrl.Add_MouseMove({ Reset-InactivityTimer }) } catch {}
    }
}

$idleTimer = New-Object System.Windows.Forms.Timer
$idleTimer.Interval = 1000
$idleTimer.Add_Tick({
    $idleMinutes = ((Get-Date) - $script:LastActivity).TotalMinutes
    if ($idleMinutes -ge 1) {
        $idleTimer.Stop()
        Write-Log 'SESSION TIMEOUT - Closing form after 1 minute of inactivity'
        if ($null -ne $script:txtOutput -and -not $script:txtOutput.IsDisposed) {
            Append-Output 'WARNING: Session timed out after 1 minute of inactivity. Closing window...'
        }
        $form.Close()
    }
})

$form.Add_FormClosed({
    if ($null -ne $idleTimer) {
        $idleTimer.Stop()
        $idleTimer.Dispose()
    }
})

$idleTimer.Start()
[void]$form.ShowDialog()
Stop-Transcript
exit
