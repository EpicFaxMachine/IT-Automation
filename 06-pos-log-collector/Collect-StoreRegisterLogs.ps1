Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName System.Windows.Forms

#--------------------------------------------------------------------
# Config — edit here or mirror from config.example.psd1
#--------------------------------------------------------------------
$script:Config = @{
    # Hostname pattern for store registers: POS-<StoreNumber>-01, POS-<StoreNumber>-02, ...
    RegisterNamePattern = 'POS-{0}-{1:00}'   # {0}=store number, {1}=register index
    MaxRegisters        = 10

    # Relative paths under each register's C$ admin share (generic POS / payment folders)
    RegisterPosLogRel     = 'POS\Logs'
    RegisterPaymentLogRel = 'POS\Payment\Logs'
    RegisterPaymentSdkRel = 'PaymentSDK\Logs'

    # Central / HQ log sources (Contoso placeholders — replace with your hosts/paths)
    HqPosAuditUnc = '\\POS-AOM01\d$\POS\AuditExport'
    HqCrmLogUnc   = '\\POS-CRM01\c$\ProgramData\PosCrm\Logs'
}

#############################
# Functions                 #
#############################

function Get-StoreRegisters {
    param(
        [Parameter(Mandatory)]
        [string]$StoreNumber,
        [int]$MaxRegisters = $script:Config.MaxRegisters
    )

    $results = @()

    for ($i = 1; $i -le $MaxRegisters; $i++) {
        $computer = $script:Config.RegisterNamePattern -f $StoreNumber, $i
        $posLogs  = "\\$computer\c$\$($script:Config.RegisterPosLogRel)"

        if (Test-Path -Path $posLogs) {
            $results += [pscustomobject]@{
                ComputerName   = $computer
                PosLogsUNC     = $posLogs
                PaymentUNC     = "\\$computer\c$\$($script:Config.RegisterPaymentLogRel)"
                PaymentSdkUNC  = "\\$computer\c$\$($script:Config.RegisterPaymentSdkRel)"
            }
        }
    }

    return $results
}

function Get-LogFilesFromSource {
    param(
        [Parameter(Mandatory)]
        [string]$SourcePath,
        [int]$DaysBack
    )

    if (-not (Test-Path $SourcePath)) {
        return @()
    }

    $cutoff = (Get-Date).AddDays(-1 * $DaysBack)
    Get-ChildItem -Path $SourcePath -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -ge $cutoff }
}

function Show-FolderBrowser {
    param(
        [string]$InitialDirectory = [Environment]::GetFolderPath('Desktop')
    )

    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.SelectedPath = $InitialDirectory
    $dialog.Description = 'Select destination folder for collected logs'
    $dialog.ShowNewFolderButton = $true

    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        return $dialog.SelectedPath
    }
    return $null
}

#############################
# XAML UI                   #
#############################

$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Store Register Log Collector" Height="430" Width="650"
        WindowStartupLocation="CenterScreen"
        ResizeMode="CanResizeWithGrip">
    <Grid Margin="10">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <Grid.ColumnDefinitions>
            <ColumnDefinition Width="2*"/>
            <ColumnDefinition Width="2*"/>
            <ColumnDefinition Width="2*"/>
        </Grid.ColumnDefinitions>

        <Label Grid.Row="0" Grid.Column="0" Margin="0,0,5,5"
               VerticalAlignment="Center" Content="Store number:"/>
        <TextBox x:Name="txtStore"
                 Grid.Row="0" Grid.Column="1" Margin="0,0,5,5"
                 VerticalAlignment="Center" Width="120"/>
        <Button x:Name="btnLoadRegs"
                Grid.Row="0" Grid.Column="2" Margin="0,0,0,5"
                HorizontalAlignment="Left" Width="120"
                Content="Load Registers"/>

        <GroupBox Grid.Row="1" Grid.ColumnSpan="3" Header="Store registers"
                  Margin="0,0,0,5">
            <Grid>
                <Grid.RowDefinitions>
                    <RowDefinition Height="*"/>
                    <RowDefinition Height="Auto"/>
                </Grid.RowDefinitions>

                <ListBox x:Name="lbRegisters"
                         Grid.Row="0"
                         Margin="5"
                         SelectionMode="Extended"/>

                <StackPanel Grid.Row="1" Orientation="Horizontal" Margin="5,0,5,5">
                    <CheckBox x:Name="chkRegisters"
                              Content="Include POS logs on selected registers"
                              VerticalAlignment="Center" IsChecked="True"/>
                    <TextBlock Text="  (Ctrl/Shift-click to choose multiple registers)"
                               VerticalAlignment="Center"
                               Margin="10,0,0,0" />
                </StackPanel>
            </Grid>
        </GroupBox>

        <GroupBox Grid.Row="2" Grid.ColumnSpan="3" Header="Log sources"
                  Margin="0,0,0,5">
            <Grid Margin="5">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>
                <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                </Grid.RowDefinitions>

                <CheckBox x:Name="chkAOM"
                          Grid.Row="0" Grid.Column="0"
                          Margin="0,0,0,5"
                          Content="HQ POS audit export"/>

                <CheckBox x:Name="chkPaymentSdk"
                          Grid.Row="0" Grid.Column="1"
                          Margin="10,0,0,5"
                          Content="Payment SDK logs on registers"/>

                <CheckBox x:Name="chkPayment"
                          Grid.Row="1" Grid.Column="0"
                          Margin="0,0,0,5"
                          Content="Payment logs on registers"/>

                <CheckBox x:Name="chkCRM"
                          Grid.Row="1" Grid.Column="1"
                          Margin="10,0,0,5"
                          Content="HQ CRM / POS CRM logs"/>
            </Grid>
        </GroupBox>

        <StackPanel Grid.Row="3" Grid.ColumnSpan="3" Orientation="Horizontal" Margin="0,0,0,5">
            <Label Content="How far back (days):" VerticalAlignment="Center" Margin="0,0,5,0"/>
            <TextBox x:Name="txtDaysBack"
                     Width="50"
                     VerticalAlignment="Center"
                     Text="7"/>
            <TextBlock Text="  (files modified within last N days)" VerticalAlignment="Center" Margin="5,0,0,0"/>
        </StackPanel>

        <Label Grid.Row="4" Grid.Column="0" Margin="0,0,5,5"
               VerticalAlignment="Center" Content="Output folder:"/>
        <TextBox x:Name="txtOutput"
                 Grid.Row="4" Grid.Column="1" Margin="0,0,5,5"
                 VerticalAlignment="Center"/>
        <Button x:Name="btnBrowseOutput"
                Grid.Row="4" Grid.Column="2" Margin="0,0,0,5"
                HorizontalAlignment="Left" Width="120"
                Content="Browse..."/>

        <StackPanel Grid.Row="5" Grid.ColumnSpan="3"
                    Orientation="Horizontal"
                    HorizontalAlignment="Right" Margin="0,10,0,0">
            <TextBlock x:Name="txtStatus"
                       VerticalAlignment="Center"
                       Margin="0,0,10,0"
                       Foreground="DarkGreen"
                       Text="Ready."/>
            <Button x:Name="btnCollect"
                    Width="130"
                    Content="Collect Logs"/>
        </StackPanel>

    </Grid>
</Window>
"@

#############################
# Load XAML                 #
#############################

$StringReader = New-Object System.IO.StringReader $xaml
$XmlReader    = [System.Xml.XmlReader]::Create($StringReader)
$Window       = [Windows.Markup.XamlReader]::Load($XmlReader)

$txtStore        = $Window.FindName('txtStore')
$btnLoadRegs     = $Window.FindName('btnLoadRegs')
$lbRegisters     = $Window.FindName('lbRegisters')
$chkRegisters    = $Window.FindName('chkRegisters')
$chkAOM          = $Window.FindName('chkAOM')
$chkPaymentSdk   = $Window.FindName('chkPaymentSdk')
$chkPayment      = $Window.FindName('chkPayment')
$chkCRM          = $Window.FindName('chkCRM')
$txtDaysBack     = $Window.FindName('txtDaysBack')
$txtOutput       = $Window.FindName('txtOutput')
$btnBrowseOutput = $Window.FindName('btnBrowseOutput')
$btnCollect      = $Window.FindName('btnCollect')
$txtStatus       = $Window.FindName('txtStatus')

#############################
# Event wiring              #
#############################

$btnLoadRegs.Add_Click({
    $lbRegisters.Items.Clear()
    $store = $txtStore.Text.Trim()

    if ([string]::IsNullOrWhiteSpace($store)) {
        [System.Windows.MessageBox]::Show("Enter a store number (e.g. 00012).","Store number")
        return
    }

    $regs = Get-StoreRegisters -StoreNumber $store
    if (-not $regs -or $regs.Count -eq 0) {
        [System.Windows.MessageBox]::Show("No registers found via C$ for store $store.","Registers")
        return
    }

    foreach ($r in $regs) {
        $item = New-Object System.Windows.Controls.ListBoxItem
        $item.Content = $r.ComputerName
        $item.Tag     = $r
        [void]$lbRegisters.Items.Add($item)
    }

    $txtStatus.Text = "Loaded $($regs.Count) registers for store $store (via C$)."
})

$btnBrowseOutput.Add_Click({
    $path = Show-FolderBrowser -InitialDirectory ([Environment]::GetFolderPath('Desktop'))
    if ($path) {
        $txtOutput.Text = $path
    }
})

$btnCollect.Add_Click({
    $destRoot = $txtOutput.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($destRoot) -or -not (Test-Path $destRoot)) {
        [System.Windows.MessageBox]::Show("Specify a valid output folder.","Output folder")
        return
    }

    $daysBack = 7
    if (-not [int]::TryParse($txtDaysBack.Text, [ref]$daysBack) -or $daysBack -le 0) {
        [System.Windows.MessageBox]::Show("Enter a valid number of days (positive integer).","How far back")
        return
    }

    $txtStatus.Text = "Collecting logs..."
    $Window.Cursor = 'Wait'

    try {
        $allFiles = @()

        if ($chkAOM.IsChecked) {
            $allFiles += Get-LogFilesFromSource -SourcePath $script:Config.HqPosAuditUnc -DaysBack $daysBack
        }
        if ($chkCRM.IsChecked) {
            $allFiles += Get-LogFilesFromSource -SourcePath $script:Config.HqCrmLogUnc -DaysBack $daysBack
        }

        if ($lbRegisters.SelectedItems.Count -gt 0) {
            foreach ($item in $lbRegisters.SelectedItems) {
                $regInfo = [pscustomobject]$item.Tag

                if ($chkRegisters.IsChecked) {
                    $allFiles += Get-LogFilesFromSource -SourcePath $regInfo.PosLogsUNC -DaysBack $daysBack
                }
                if ($chkPayment.IsChecked) {
                    $allFiles += Get-LogFilesFromSource -SourcePath $regInfo.PaymentUNC -DaysBack $daysBack
                }
                if ($chkPaymentSdk.IsChecked) {
                    $allFiles += Get-LogFilesFromSource -SourcePath $regInfo.PaymentSdkUNC -DaysBack $daysBack
                }
            }
        }

        if (-not $allFiles -or $allFiles.Count -eq 0) {
            $txtStatus.Text = "No files found in last $daysBack days."
            return
        }

        $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
        $staging   = Join-Path $destRoot "CollectedLogs_$timestamp"
        New-Item -ItemType Directory -Path $staging -Force | Out-Null

        foreach ($f in $allFiles) {
            $safeName = $f.FullName -replace '[:\\]', '_'
            $destFile = Join-Path $staging $safeName
            Copy-Item -LiteralPath $f.FullName -Destination $destFile -Force -ErrorAction SilentlyContinue
        }

        $zipPath = Join-Path $destRoot "Logs_$timestamp.zip"
        Compress-Archive -Path (Join-Path $staging '*') -DestinationPath $zipPath -CompressionLevel Optimal -Force

        $txtStatus.Text = "Log collection complete. Zip: $zipPath"
    }
    catch {
        $txtStatus.Text = "Error collecting logs: $($_.Exception.Message)"
        [System.Windows.MessageBox]::Show("Error collecting logs: $($_.Exception.Message)","Error")
    }
    finally {
        $Window.Cursor = 'Arrow'
    }
})

#############################
# Run UI                    #
#############################

[void]$Window.ShowDialog()
