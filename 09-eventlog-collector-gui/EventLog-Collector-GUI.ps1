Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

#--------------------------------------------------------------------
# Config — edit here or mirror from config.example.psd1
#--------------------------------------------------------------------
$script:Config = @{
    LogNames        = @('System', 'Application')
    # WinEvent Level: 2 = Error, 3 = Warning
    LevelsToInclude = @(2, 3)
    DefaultDaysBack = 7
    # Contoso placeholder hosts shown in the form (replace / clear as needed)
    DefaultHosts    = @('APP01', 'APP02')
}

$LogNames = $script:Config.LogNames
$LevelsToInclude = $script:Config.LevelsToInclude

# Dark mode colors
$DarkBackground = [System.Drawing.Color]::FromArgb(30,30,30)
$DarkPanel      = [System.Drawing.Color]::FromArgb(45,45,45)
$DarkText       = [System.Drawing.Color]::WhiteSmoke
$DarkInputBack  = [System.Drawing.Color]::FromArgb(50,50,50)

$form               = New-Object System.Windows.Forms.Form
$form.Text          = 'Event Log Collector'
$form.Size          = New-Object System.Drawing.Size(650,360)
$form.StartPosition = 'CenterScreen'
$form.Topmost       = $true
$form.BackColor     = $DarkBackground
$form.ForeColor     = $DarkText

$lblDays            = New-Object System.Windows.Forms.Label
$lblDays.Text       = 'Days back:'
$lblDays.Location   = New-Object System.Drawing.Point(20,20)
$lblDays.AutoSize   = $true
$lblDays.ForeColor  = $DarkText
$form.Controls.Add($lblDays)

$txtDays            = New-Object System.Windows.Forms.TextBox
$txtDays.Location   = New-Object System.Drawing.Point(120,18)
$txtDays.Size       = New-Object System.Drawing.Size(60,20)
$txtDays.Text       = [string]$script:Config.DefaultDaysBack
$txtDays.BackColor  = $DarkInputBack
$txtDays.ForeColor  = $DarkText
$form.Controls.Add($txtDays)

$lblFolder          = New-Object System.Windows.Forms.Label
$lblFolder.Text     = 'Output folder:'
$lblFolder.Location = New-Object System.Drawing.Point(20,60)
$lblFolder.AutoSize = $true
$lblFolder.ForeColor = $DarkText
$form.Controls.Add($lblFolder)

$txtFolder          = New-Object System.Windows.Forms.TextBox
$txtFolder.Location = New-Object System.Drawing.Point(120,58)
$txtFolder.Size     = New-Object System.Drawing.Size(360,20)
$txtFolder.Text     = [Environment]::GetFolderPath('Desktop')
$txtFolder.BackColor = $DarkInputBack
$txtFolder.ForeColor = $DarkText
$form.Controls.Add($txtFolder)

$btnBrowse          = New-Object System.Windows.Forms.Button
$btnBrowse.Text     = 'Browse...'
$btnBrowse.Location = New-Object System.Drawing.Point(490,56)
$btnBrowse.Size     = New-Object System.Drawing.Size(75,23)
$btnBrowse.BackColor = $DarkPanel
$btnBrowse.ForeColor = $DarkText
$form.Controls.Add($btnBrowse)

$lblServers             = New-Object System.Windows.Forms.Label
$lblServers.Text        = 'Host names (one per line or comma-separated):'
$lblServers.Location    = New-Object System.Drawing.Point(20,95)
$lblServers.AutoSize    = $true
$lblServers.ForeColor   = $DarkText
$form.Controls.Add($lblServers)

$txtServers             = New-Object System.Windows.Forms.TextBox
$txtServers.Location    = New-Object System.Drawing.Point(20,115)
$txtServers.Size        = New-Object System.Drawing.Size(260,120)
$txtServers.Multiline   = $true
$txtServers.ScrollBars  = 'Vertical'
$txtServers.Text        = ($script:Config.DefaultHosts -join "`r`n")
$txtServers.BackColor   = $DarkInputBack
$txtServers.ForeColor   = $DarkText
$form.Controls.Add($txtServers)

$txtStatus              = New-Object System.Windows.Forms.TextBox
$txtStatus.Location     = New-Object System.Drawing.Point(300,115)
$txtStatus.Size         = New-Object System.Drawing.Size(265,120)
$txtStatus.Multiline    = $true
$txtStatus.ScrollBars   = 'Vertical'
$txtStatus.ReadOnly     = $true
$txtStatus.BackColor    = $DarkPanel
$txtStatus.ForeColor    = $DarkText
$form.Controls.Add($txtStatus)

$btnRun             = New-Object System.Windows.Forms.Button
$btnRun.Text        = 'Run'
$btnRun.Location    = New-Object System.Drawing.Point(390,260)
$btnRun.Size        = New-Object System.Drawing.Size(80,25)
$btnRun.BackColor   = $DarkPanel
$btnRun.ForeColor   = $DarkText
$form.Controls.Add($btnRun)

$btnClose           = New-Object System.Windows.Forms.Button
$btnClose.Text      = 'Close'
$btnClose.Location  = New-Object System.Drawing.Point(485,260)
$btnClose.Size      = New-Object System.Drawing.Size(80,25)
$btnClose.BackColor = $DarkPanel
$btnClose.ForeColor = $DarkText
$form.Controls.Add($btnClose)

$folderBrowser = New-Object System.Windows.Forms.FolderBrowserDialog

function Add-StatusLine {
    param(
        [string]$Text
    )
    $txtStatus.AppendText($Text + "`r`n")
}

$btnBrowse.Add_Click({
    if ($folderBrowser.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $txtFolder.Text = $folderBrowser.SelectedPath
    }
})

$btnClose.Add_Click({
    $form.Close()
})

$btnRun.Add_Click({
    $txtStatus.Clear()

    $tmp = 0
    if (-not [int]::TryParse($txtDays.Text, [ref]$tmp)) {
        Add-StatusLine 'Days back must be a number.'
        return
    }

    $daysBack = [int]$txtDays.Text
    if ($daysBack -le 0) {
        Add-StatusLine 'Days back must be greater than 0.'
        return
    }

    $outFolder = $txtFolder.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($outFolder)) {
        Add-StatusLine 'Please select an output folder.'
        return
    }
    if (-not (Test-Path -Path $outFolder)) {
        try {
            New-Item -Path $outFolder -ItemType Directory -Force | Out-Null
        } catch {
            Add-StatusLine ("Failed to create output folder: {0}" -f $outFolder)
            return
        }
    }

    $rawServers = $txtServers.Text -split "[`,\n\r]" |
                  ForEach-Object { $_.Trim() } |
                  Where-Object { $_ -ne '' } |
                  Select-Object -Unique

    if (-not $rawServers -or $rawServers.Count -eq 0) {
        Add-StatusLine 'Please enter at least one host name.'
        return
    }

    $Servers = $rawServers

    $startTime = (Get-Date).AddDays(-$daysBack)
    Add-StatusLine "Collecting logs since $startTime ..."
    Add-StatusLine ("Hosts: {0}" -f ($Servers -join ', '))

    foreach ($server in $Servers) {
        Add-StatusLine ("Host: {0}" -f $server)
        $allEvents = @()

        foreach ($log in $LogNames) {
            Add-StatusLine ("  Log: {0}" -f $log)
            try {
                $filterHash = @{
                    LogName   = $log
                    StartTime = $startTime
                    Level     = $LevelsToInclude
                }

                $events = Get-WinEvent -ComputerName $server -FilterHashtable $filterHash -ErrorAction Stop
                if ($events) {
                    $allEvents += $events
                    Add-StatusLine ("    Retrieved {0} events." -f $events.Count)
                } else {
                    Add-StatusLine '    No events found.'
                }
            } catch {
                Add-StatusLine ("    ERROR reading {0} on {1}: {2}" -f $log, $server, $_.Exception.Message)
            }
        }

        if ($allEvents.Count -gt 0) {
            $safeServer = $server -replace '[\\/:*?"<>|]', '_'
            $fileName   = "{0}_{1:yyyyMMdd_HHmmss}.csv" -f $safeServer, (Get-Date)
            $fullPath   = Join-Path $outFolder $fileName

            $allEvents |
                Select-Object TimeCreated, Id, LevelDisplayName, LogName, ProviderName, MachineName, Message |
                Sort-Object TimeCreated |
                Export-Csv -Path $fullPath -NoTypeInformation -Encoding UTF8

            Add-StatusLine ("  Saved {0} events to {1}" -f $allEvents.Count, $fullPath)
        } else {
            Add-StatusLine "  No matching events for $server."
        }
    }

    Add-StatusLine 'Done.'
})

[void]$form.ShowDialog()
