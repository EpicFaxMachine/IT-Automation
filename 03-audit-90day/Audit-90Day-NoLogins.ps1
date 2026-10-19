Import-Module ActiveDirectory
Import-Module Microsoft.Graph.Users

# =============================================================================
# CONFIG — Contoso placeholders. Copy from config.example.psd1 for real use.
# Okta token MUST come from the environment (never hardcode).
# =============================================================================
$script:AuditConfig = @{
    DaysInactive       = 90
    OutputDir          = 'C:\Temp'
    OutputFileName     = 'InactiveUsers_90Days.xlsx'
    OktaDomain         = 'https://YOUR_ORG.okta.com'   # <OKTA_ORG_URL>
    OktaTokenEnvVar    = 'OKTA_API_TOKEN'
    AlternateMailDomains = @(
        'contoso.com',
        'contractors.contoso.com'
    )
}

$DaysInactive = $script:AuditConfig.DaysInactive

$CutoffDate   = (Get-Date).AddDays(-$DaysInactive)
$CutoffUtc    = (Get-Date).ToUniversalTime().AddDays(-$DaysInactive)

# Output
$outDir  = $script:AuditConfig.OutputDir
if (-not (Test-Path $outDir)) {
    New-Item -Path $outDir -ItemType Directory | Out-Null
}
$outXlsx = Join-Path $outDir $script:AuditConfig.OutputFileName

# ─── Non-Person Filter ────────────────────────────────────────────────────────
# Removes service accounts, shared accounts, vendor/consultant accounts, etc.

$NonPersonOUFragments = @(
    'Service Accounts', 'Servers and Network Accounts', 'Shared Mailbox',
    'FTP Users', 'AzureSync', 'Jira', 'Utility Accounts', 'Operators',
    'Warehouse', 'Distribution', 'Warehouse2', 'Recipients-Do not change',
    'Contractors-Consultants', 'Disabled Consultants', 'ERP Vendor Users',
    'outside vendor', 'Vendor Relations'
)

$NonPersonSAMPatterns = @(
    '^svc_', '^scv_', '^ad_', 'whse', '^wh$', 'operator\d',
    'receiving', 'testphone', '_ftp$', '_sftp$', '-fax\d+$',
    '^orgadmin', '^d2-', 'recadmin', 'shipadmin', 'conferenc',
    'store\d+', '\d'   # any digit in the username portion
)

$NonPersonNamePatterns = @(
    '\bAdmin\b', '\bvpn\b', 'vpn$', '\d',
    'whse', '\bFTP\b', '\bSFTP\b', '-fax\d+', '\bSMTP\b', '\bSSO\b',
    '\bScanner\b', '\bMonitor\b', 'Conference', 'Service Account', 'Shared Mailbox',
    '\bTest\b', '\bTesting\b', '\bTester\b',
    'NoEmail', 'Lockbox', 'Replication', 'Backup',
    'local admin', 'Contractor', 'FTPUser',
    '\(',                   # parenthetical vendor tag: "Name (Vendor)"
    '\bvmware\b', '\bconsultant\b', '\bvendor\b',
    '^agent\b', 'community pc', 'testconsultant'
)

function Test-IsNonPerson {
    param(
        [string]$Name,
        [string]$SamAccountName,
        [string]$UserPrincipalName,
        [string]$OUPath
    )

    $ouL  = if ($OUPath)         { $OUPath.ToLower() }         else { '' }
    $samL = if ($SamAccountName) { $SamAccountName.ToLower() } else { '' }

    $samPrefix = if ($samL -match '@') { ($samL -split '@')[0] } else { $samL }
    $upnPrefix = if ($UserPrincipalName -and $UserPrincipalName -match '@') {
        ($UserPrincipalName.ToLower() -split '@')[0]
    } else { '' }

    foreach ($frag in $NonPersonOUFragments) {
        if ($ouL -like "*$($frag.ToLower())*") { return $true }
    }

    foreach ($pat in $NonPersonSAMPatterns) {
        if ($samPrefix -match $pat) { return $true }
    }

    if ($upnPrefix -match '\d') { return $true }

    foreach ($pat in $NonPersonNamePatterns) {
        if ($Name -match $pat) { return $true }
    }

    return $false
}

# ─── AD ───────────────────────────────────────────────────────────────────────
# AD is the single source of truth. Pull all users inactive > 90 days (or never
# logged in), filter non-persons, then deduplicate to one row per UPN.
Write-Host "=== Getting AD inactive users (>$DaysInactive days) ===" -ForegroundColor Cyan

$adUsersRaw = Get-ADUser -Filter * -Properties LastLogonDate, UserPrincipalName, Enabled, DistinguishedName |
    Where-Object {
        $_.LastLogonDate -lt $CutoffDate -or $null -eq $_.LastLogonDate
    } |
    Select-Object Name, SamAccountName, UserPrincipalName, LastLogonDate, Enabled, DistinguishedName

Write-Host "Found $($adUsersRaw.Count) AD users inactive > $DaysInactive days."

# Filter non-persons
$adUsersFiltered = $adUsersRaw | Where-Object {
    -not (Test-IsNonPerson `
        -Name              $_.Name `
        -SamAccountName    $_.SamAccountName `
        -UserPrincipalName $_.UserPrincipalName `
        -OUPath            $_.DistinguishedName)
}

Write-Host "After non-person filter: $($adUsersFiltered.Count) AD users remain."

# Deduplicate by UPN — keep the record with the most recent LastLogonDate
$adDeduped = @{}
foreach ($u in $adUsersFiltered) {
    $key = if ($u.UserPrincipalName) { $u.UserPrincipalName.ToLower() } else { $u.SamAccountName.ToLower() }
    if (-not $adDeduped.ContainsKey($key)) {
        $adDeduped[$key] = $u
    } else {
        $existing = $adDeduped[$key]
        if ($u.LastLogonDate -and (-not $existing.LastLogonDate -or $u.LastLogonDate -gt $existing.LastLogonDate)) {
            $adDeduped[$key] = $u
        }
    }
}

Write-Host "After dedup: $($adDeduped.Count) unique AD users."

# ─── Licenses (Graph) ─────────────────────────────────────────────────────────
Write-Host "=== Connecting to Microsoft Graph ===" -ForegroundColor Cyan
Connect-MgGraph -Scopes "User.Read.All" | Out-Null

$skuMap = @{
    "18181a46-0d4e-45cd-891e-60aabd171b4e" = "Office 365 E1"
    "36a0f3b3-adb5-49ea-bf66-762134cf063a" = "Microsoft Teams Premium"
    "4b585984-651b-448a-9e53-3b10f069cf7f" = "Office 365 F3"
    "4b9405b0-7788-4568-add1-99614e613b69" = "Exchange Online Plan 1"
    "5b631642-bd26-49fe-bd20-1daaa972ef80" = "Microsoft Power Apps for Developer"
    "639dec6b-bb19-468b-871c-c5c441c4b0cb" = "Copilot for Microsoft 365"
    "6fd2c87f-b296-42f0-b197-1e91e994b900" = "Office 365 E3"
    "a403ebcc-fae0-4ca2-8c8c-7a907fd6c235" = "Microsoft Fabric (Free)"
    "f30db892-07e9-47e9-837c-80727f46fd3d" = "Microsoft Power Automate Free"
    "f8a1db68-be16-40ed-86d5-cb42ce701560" = "Power BI Pro"
}

# Bulk license fetch — single paginated Graph call, result cached by UPN
Write-Host "=== Bulk-fetching licenses from Graph ===" -ForegroundColor Cyan
$licenseCache = @{}
$graphUrl = "https://graph.microsoft.com/v1.0/users?`$select=userPrincipalName,assignedLicenses&`$top=999"

while ($graphUrl) {
    try {
        $graphResp = Invoke-MgGraphRequest -Uri $graphUrl -Method GET -ErrorAction Stop
    } catch {
        Write-Host "Graph license bulk fetch error: $($_.Exception.Message)" -ForegroundColor Red
        break
    }

    foreach ($gUser in $graphResp.value) {
        $upnKey = if ($gUser.userPrincipalName) { $gUser.userPrincipalName.ToLower() } else { $null }
        if (-not $upnKey) { continue }
        if (-not $gUser.assignedLicenses -or $gUser.assignedLicenses.Count -eq 0) { continue }

        $friendlyNames = foreach ($lic in $gUser.assignedLicenses) {
            $id = if ($lic.skuId) { $lic.skuId.ToString() } else { $null }
            if ($id) { if ($skuMap.ContainsKey($id)) { $skuMap[$id] } else { $id } }
        }
        if ($friendlyNames) {
            $licenseCache[$upnKey] = ($friendlyNames | Sort-Object -Unique) -join "; "
        }
    }

    $graphUrl = if ($graphResp.'@odata.nextLink') { $graphResp.'@odata.nextLink' } else { $null }
    if ($graphUrl) { Write-Host "Fetching next Graph license page..." -ForegroundColor DarkGray }
}

Write-Host "License cache built: $($licenseCache.Count) licensed users found."

# ─── Okta — single full pass (cache only) ─────────────────────────────────────
# We only build the full user cache here. No inactive tracking, no secondary list.
# Okta is purely used to look up last login and status for AD users.
$ApiToken   = [Environment]::GetEnvironmentVariable($script:AuditConfig.OktaTokenEnvVar)
$OktaDomain = $script:AuditConfig.OktaDomain

if (-not $ApiToken) {
    Write-Host "OKTA_API_TOKEN environment variable is not set." -ForegroundColor Red
    exit 1
}

$Headers = @{
    Authorization  = "SSWS $ApiToken"
    Accept         = "application/json"
    "Content-Type" = "application/json"
}

Write-Host "=== Fetching all Okta users (cache build) ===" -ForegroundColor Cyan
$oktaAllUsers = @{}   # indexed by email, login, and username prefix

$url = "$OktaDomain/api/v1/users?limit=200"

while ($null -ne $url) {
    try {
        $response = Invoke-WebRequest -Uri $url -Headers $Headers -Method GET -UseBasicParsing
        $users    = $response.Content | ConvertFrom-Json
    } catch {
        Write-Host "Error calling Okta API: $($_.Exception.Message)" -ForegroundColor Red
        break
    }
    if (-not $users) { break }

    foreach ($user in $users) {
        $emailKey  = if ($user.profile.email) { $user.profile.email.ToLower() } else { $null }
        $loginKey  = if ($user.profile.login) { $user.profile.login.ToLower() } else { $null }
        $prefixKey = if ($emailKey)  { $emailKey.Split('@')[0] }
                     elseif ($loginKey) { $loginKey.Split('@')[0] }
                     else { $null }

        # Index under all three keys — first writer wins per key
        foreach ($k in @($emailKey, $loginKey, $prefixKey)) {
            if ($k -and -not $oktaAllUsers.ContainsKey($k)) {
                $oktaAllUsers[$k] = $user
            }
        }
    }

    $nextLink = $null
    if ($response.Headers.Link) {
        foreach ($link in ($response.Headers.Link -split ',')) {
            if ($link -match 'rel="next"' -and $link -match '<([^>]+)>') {
                $nextLink = $matches[1]
            }
        }
    }
    $url = $nextLink
    if ($url) { Write-Host "Fetching next Okta page..." -ForegroundColor DarkGray }
}

Write-Host "Okta cache built: $($oktaAllUsers.Count) entries."

# ─── Okta helper functions ────────────────────────────────────────────────────
function Get-OktaRecord {
    param([string]$Key)
    if (-not $Key) { return $null }
    $keyL = $Key.ToLower()

    # 1. Direct hit (email/login matches AD UPN domain)
    if ($oktaAllUsers.ContainsKey($keyL)) { return $oktaAllUsers[$keyL] }

    # 2. Username prefix — handles alternate mail / UPN domains from AuditConfig
    $prefix = $keyL.Split('@')[0]
    if ($prefix -and $oktaAllUsers.ContainsKey($prefix)) { return $oktaAllUsers[$prefix] }

    # 3. Explicit domain variant fallback
    foreach ($altDomain in @($script:AuditConfig.AlternateMailDomains)) {
        $altKey = "$prefix@$altDomain"
        if ($oktaAllUsers.ContainsKey($altKey)) { return $oktaAllUsers[$altKey] }
    }

    return $null
}

function Get-OktaLastLoginFromRecord {
    param($Rec)
    if (-not $Rec) { return "N/A" }
    if ($Rec.lastLogin) { return [DateTime]::Parse($Rec.lastLogin).ToUniversalTime() }
    return "N/A"
}

function Get-OktaStatusFromRecord {
    param($Rec)
    if (-not $Rec) { return "Not in Okta" }
    if ($Rec.status -in @("ACTIVE", "PROVISIONED")) { return "Enabled" } else { return "Disabled" }
}

# ─── Build output rows — AD drives, Okta enriches ────────────────────────────
Write-Host "=== Building report rows ===" -ForegroundColor Cyan

$reportRows = foreach ($key in $adDeduped.Keys) {
    $u = $adDeduped[$key]

    $upnKey  = if ($u.UserPrincipalName) { $u.UserPrincipalName.ToLower() } else { $null }
    $license = if ($upnKey -and $licenseCache.ContainsKey($upnKey)) { $licenseCache[$upnKey] } else { $null }

    $lookupKey     = if ($u.UserPrincipalName) { $u.UserPrincipalName } else { $u.SamAccountName }
    $oktaRec       = Get-OktaRecord -Key $lookupKey
    $oktaLastLogin = Get-OktaLastLoginFromRecord -Rec $oktaRec
    $oktaStatus    = Get-OktaStatusFromRecord -Rec $oktaRec

    [PSCustomObject]@{
        Name              = $u.Name
        SamAccountName    = $u.SamAccountName
        UserPrincipalName = $u.UserPrincipalName
        ADLastLogonDate   = $u.LastLogonDate
        OktaLastLoginUtc  = $oktaLastLogin
        ADStatus          = if ($u.Enabled) { "Enabled" } else { "Disabled" }
        OktaStatus        = $oktaStatus
        Licenses          = $license
        OUPath            = $u.DistinguishedName
    }
}

# Sort: by Name
$reportRows = $reportRows | Sort-Object Name

Write-Host "Total report rows: $($reportRows.Count)"

# ─── Write Single-Sheet Excel ─────────────────────────────────────────────────
Write-Host "=== Writing Excel: $outXlsx ===" -ForegroundColor Cyan

$excel    = New-Object -ComObject Excel.Application
$excel.Visible       = $false
$excel.DisplayAlerts = $false

$workbook = $excel.Workbooks.Add()
$sheet    = $workbook.Worksheets.Item(1)
$sheet.Name = "Inactive Users (90 Days)"

while ($workbook.Worksheets.Count -gt 1) {
    $workbook.Worksheets.Item($workbook.Worksheets.Count).Delete()
}

$columns = @(
    @{ Header = "Name";              Prop = "Name" }
    @{ Header = "SamAccountName";    Prop = "SamAccountName" }
    @{ Header = "UserPrincipalName"; Prop = "UserPrincipalName" }
    @{ Header = "AD LastLogonDate";  Prop = "ADLastLogonDate" }
    @{ Header = "Okta LastLoginUtc"; Prop = "OktaLastLoginUtc" }
    @{ Header = "ADStatus";          Prop = "ADStatus" }
    @{ Header = "OktaStatus";        Prop = "OktaStatus" }
    @{ Header = "Licenses";          Prop = "Licenses" }
    @{ Header = "OUPath";            Prop = "OUPath" }
)

# Header row
for ($c = 0; $c -lt $columns.Count; $c++) {
    $cell = $sheet.Cells.Item(1, $c + 1)
    $cell.Value2         = $columns[$c].Header
    $cell.Font.Bold      = $true
    $cell.Interior.Color = 0x2E75B6   # blue
    $cell.Font.Color     = 0xFFFFFF   # white
}

# Data rows
for ($r = 0; $r -lt $reportRows.Count; $r++) {
    $row = $reportRows[$r]
    for ($c = 0; $c -lt $columns.Count; $c++) {
        $prop = $columns[$c].Prop
        $val  = $row.$prop

        if ($val -is [DateTime]) {
            $val = $val.ToString("yyyy-MM-dd HH:mm:ss")
        }

        $cell = $sheet.Cells.Item($r + 2, $c + 1)
        $cell.Value2 = if ($null -eq $val) { "" } else { $val }

        # Yellow highlight = AD inactive but Okta still active within 90 days
        # (user may need follow-up — they're logging into Okta but not AD)
        if ($row.OktaStatus -eq "Enabled") {
            $oktaVal = $row.OktaLastLoginUtc
            if ($oktaVal -is [DateTime] -and $oktaVal -gt $CutoffUtc) {
                $cell.Interior.Color = 0xFFF2CC
            }
        }
    }
}

$used = $sheet.UsedRange
$used.EntireColumn.AutoFit() | Out-Null

$sheet.Rows.Item(2).Select() | Out-Null
$excel.ActiveWindow.FreezePanes = $true
$sheet.Rows.Item(1).AutoFilter() | Out-Null

$workbook.SaveAs($outXlsx)
$workbook.Close($false)
$excel.Quit()

[System.Runtime.Interopservices.Marshal]::ReleaseComObject($workbook) | Out-Null
[System.Runtime.Interopservices.Marshal]::ReleaseComObject($excel)    | Out-Null

Write-Host "Done! Report saved to: $outXlsx" -ForegroundColor Green
