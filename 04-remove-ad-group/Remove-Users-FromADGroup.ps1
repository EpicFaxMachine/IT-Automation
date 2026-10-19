[CmdletBinding(SupportsShouldProcess = $true)]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Safety default: preview mode unless the caller passes -WhatIf:$false
# (SupportsShouldProcess still honors an explicit -WhatIf / -Confirm.)
if (-not $PSBoundParameters.ContainsKey('WhatIf')) {
    $WhatIfPreference = $true
    Write-Host "WhatIf default ON — no memberships will be changed. Pass -WhatIf:`$false to apply." -ForegroundColor Yellow
}

$EmailRegex = '(?i)(?<![A-Z0-9._%+\-])([A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,})(?![A-Z0-9._%+\-])'

function Ensure-ADModule {
    if (-not (Get-Module ActiveDirectory -ListAvailable)) {
        throw "ActiveDirectory module not found. Install RSAT: Active Directory tools."
    }
    Import-Module ActiveDirectory -ErrorAction Stop
}

function Add-EmailsFromText {
    param(
        [System.Collections.Generic.List[string]]$Target,
        [string]$Text
    )
    if ([string]::IsNullOrWhiteSpace($Text)) { return }
    foreach ($m in [System.Text.RegularExpressions.Regex]::Matches($Text, $EmailRegex)) {
        $Target.Add($m.Groups[1].Value.ToLowerInvariant())
    }
}

function Extract-EmailsFromObjects {
    param([Parameter(Mandatory)][object[]]$Rows)
    $found = New-Object System.Collections.Generic.List[string]
    foreach ($row in $Rows) {
        foreach ($prop in $row.PSObject.Properties) {
            Add-EmailsFromText -Target $found -Text ([string]$prop.Value)
        }
    }
    return $found
}

function Extract-EmailsFrom2DArray {
    param([Parameter(Mandatory)]$Values2D)
    $found = New-Object System.Collections.Generic.List[string]
    if (-not ($Values2D -and $Values2D.GetType().IsArray -and $Values2D.Rank -eq 2)) { return @() }
    $rows = $Values2D.GetLength(0)
    $cols = $Values2D.GetLength(1)
    for ($r = 1; $r -le $rows; $r++) {
        for ($c = 1; $c -le $cols; $c++) {
            Add-EmailsFromText -Target $found -Text ([string]$Values2D[$r, $c])
        }
    }
    return $found
}

function Read-Emails-FromFile {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $ext = [IO.Path]::GetExtension($Path).ToLowerInvariant()

    if ($ext -eq '.csv') {
        $rows = Import-Csv -Path $Path
        if (-not $rows) { return @() }
        return Extract-EmailsFromObjects -Rows $rows
    }

    if ($ext -in @('.xlsx','.xls')) {

        $importExcelAvailable = $false
        try {
            Import-Module ImportExcel -ErrorAction Stop
            $importExcelAvailable = $true
        } catch { $importExcelAvailable = $false }

        if ($importExcelAvailable -and (Get-Command Import-Excel -ErrorAction SilentlyContinue)) {

            $data = Import-Excel -Path $Path -WorksheetName (Get-ExcelSheetInfo -Path $Path | Select-Object -First 1 -ExpandProperty Name)
            if (-not $data) {
                $data = Import-Excel -Path $Path
            }
            if ($data) {
                return Extract-EmailsFromObjects -Rows $data
            }
        }

        $excel = $null; $wb = $null; $ws = $null
        try {
            $excel = New-Object -ComObject Excel.Application
            $excel.Visible = $false
            $wb = $excel.Workbooks.Open($Path, $false, $true)
            $ws = $wb.Worksheets.Item(1)
            $values = $ws.UsedRange.Value2
            return Extract-EmailsFrom2DArray -Values2D $values
        }
        finally {
            if ($wb) { $wb.Close($true) | Out-Null }
            if ($excel) { $excel.Quit() | Out-Null }
            if ($ws) { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($ws) }
            if ($wb) { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($wb) }
            if ($excel) { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($excel) }
            [GC]::Collect(); [GC]::WaitForPendingFinalizers()
        }
    }

    throw "Unsupported file type '$ext'. Please select a .xlsx, .xls, or .csv file."
}

function Get-User-ByEmail {
    param(
        [Parameter(Mandatory)]
        [string]$Email
    )

    $user = Get-ADUser -Filter "mail -eq '$Email'" -Properties mail -ErrorAction SilentlyContinue
    if (-not $user) {
        $user = Get-ADUser -Filter "userPrincipalName -eq '$Email'" -Properties userPrincipalName -ErrorAction SilentlyContinue
    }
    return $user
}

function Pick-SpreadsheetFile {
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
    if ([System.Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
        Write-Host "Tip: For the best file dialog behavior, run PowerShell in STA mode (Windows PowerShell is STA by default; for PowerShell 7 use 'pwsh -STA')." -ForegroundColor DarkYellow
    }
    try {
        $ofd = New-Object System.Windows.Forms.OpenFileDialog
        $ofd.Title = "Select the spreadsheet with emails"
        $ofd.Filter = "All supported (*.xlsx;*.xls;*.csv)|*.xlsx;*.xls;*.csv|Excel Workbook (*.xlsx)|*.xlsx|Excel 97-2003 (*.xls)|*.xls|CSV (*.csv)|*.csv|All files (*.*)|*.*"
        $ofd.FilterIndex = 1
        $ofd.Multiselect = $false
        $ofd.CheckFileExists = $true
        $ofd.InitialDirectory = [Environment]::GetFolderPath('Desktop')

        $res = $ofd.ShowDialog()
        if ($res -eq [System.Windows.Forms.DialogResult]::OK -and -not [string]::IsNullOrWhiteSpace($ofd.FileName)) {
            return $ofd.FileName
        }
        throw "No file selected."
    }
    catch {
        Write-Host "GUI picker unavailable or canceled. Enter the full path to your .xlsx/.xls/.csv:" -ForegroundColor Yellow
        $manual = Read-Host "Path"
        if ([string]::IsNullOrWhiteSpace($manual)) { throw "No file provided." }
        return (Resolve-Path -Path $manual -ErrorAction Stop).Path
    }
}

try {
    Ensure-ADModule

    $groupName = Read-Host "Enter the AD group name to remove members from"
    if ([string]::IsNullOrWhiteSpace($groupName)) { throw "Group name cannot be empty." }
    $group = Get-ADGroup -Identity $groupName -ErrorAction Stop

    $filePath = Pick-SpreadsheetFile
    Write-Host "Reading emails from: $filePath" -ForegroundColor Cyan

    $emails = Read-Emails-FromFile -Path $filePath

    $emails = $emails |
        Where-Object { $_ -and ($_ -match $EmailRegex) } |
        ForEach-Object { $_.ToLowerInvariant() } |
        Sort-Object -Unique

    if (-not $emails -or $emails.Count -eq 0) { throw "No email addresses were detected in the file." }
    Write-Host "Found $($emails.Count) unique email(s)..." -ForegroundColor Green

    $removed   = 0
    $notFound  = New-Object System.Collections.Generic.List[string]
    $notMember = New-Object System.Collections.Generic.List[string]
    $failed    = New-Object System.Collections.Generic.List[string]

    $i = 0
    foreach ($email in $emails) {
        $i++
        Write-Progress -Activity "Processing..." -Status "[$i/$($emails.Count)] $email" -PercentComplete (($i / $emails.Count) * 100)

        try {
            $user = Get-User-ByEmail -Email $email
            if (-not $user) {
                $notFound.Add($email) | Out-Null
                continue
            }

            $isMember = $false
            try {
                $isMember = (Get-ADGroupMember -Identity $group -Recursive | Where-Object { $_.DistinguishedName -eq $user.DistinguishedName }) -ne $null
            }
            catch {

                $isMember = (Get-ADUser -Identity $user.DistinguishedName -Properties memberOf).memberOf -contains $group.DistinguishedName
            }

            if (-not $isMember) {
                $notMember.Add($email) | Out-Null
                continue
            }

            $target = "$($user.SamAccountName) ($email)"
            if ($PSCmdlet.ShouldProcess($target, "Remove from group '$($group.Name)'")) {
                Remove-ADGroupMember -Identity $group -Members $user -Confirm:$false -ErrorAction Stop
                $removed++
                Write-Host "Removed: $target" -ForegroundColor Yellow
            }
        }
        catch {
            $failed.Add("$email :: $($_.Exception.Message)") | Out-Null
        }
    }

    Write-Progress -Activity "Processing..." -Completed

    Write-Host ""
    Write-Host "=== Summary for group '$($group.Name)' ===" -ForegroundColor Cyan
    Write-Host ("Removed: {0}" -f $removed) -ForegroundColor Green
    if ($notMember.Count -gt 0) {
        Write-Host ("Not a member: {0}" -f $notMember.Count) -ForegroundColor DarkYellow
    }
    if ($notFound.Count -gt 0) {
        Write-Host ("Email not found in AD: {0}" -f $notFound.Count) -ForegroundColor Red
    }
    if ($failed.Count -gt 0) {
        Write-Host ("Failed: {0}" -f $failed.Count) -ForegroundColor Red
    }

    if ($notMember.Count -gt 0) {
        Write-Host "`n-- Not a member --"
        $notMember | ForEach-Object { Write-Host "  $_" }
    }
    if ($notFound.Count -gt 0) {
        Write-Host "`n-- Not found in AD --"
        $notFound | ForEach-Object { Write-Host "  $_" }
    }
    if ($failed.Count -gt 0) {
        Write-Host "`n-- Failed --"
        $failed | ForEach-Object { Write-Host "  $_" }
    }

    Write-Host "`nTip: re-run with -WhatIf to preview, or without -WhatIf (and confirm) to apply." -ForegroundColor DarkGray
}
catch {
    Write-Error $_
}
