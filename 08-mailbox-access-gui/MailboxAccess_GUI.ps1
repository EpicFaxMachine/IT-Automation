Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

[System.Windows.Forms.Application]::EnableVisualStyles()

#--------------------------------------------------------------------
# Config — edit here or mirror from config.example.psd1
#--------------------------------------------------------------------
$script:Config = @{
    PrimaryMailDomain = 'contoso.com'
    # Azure AD Connect / Entra Connect sync server (WinRM). Used only if "Force Sync" is checked.
    AzureSyncServer   = 'AADSYNC01'
    # Portfolio default: sync checkbox OFF so a lab run does not trigger production delta sync.
    ForceSyncDefault  = $false
}

function Show-Message {
    param(
        [string]$Text,
        [string]$Title = 'Mailbox Access GUI',
        [System.Windows.Forms.MessageBoxIcon]$Icon = [System.Windows.Forms.MessageBoxIcon]::Information
    )
    [System.Windows.Forms.MessageBox]::Show($Text, $Title, [System.Windows.Forms.MessageBoxButtons]::OK, $Icon) | Out-Null
}

function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $script:txtLog.AppendText("[$timestamp] $Message`r`n")
}

function Normalize-Identity {
    param([string]$Value)
    $v = ($Value | ForEach-Object { $_.Trim() })
    if ([string]::IsNullOrWhiteSpace($v)) { return $null }
    return $v
}

function To-OrgEmail {
    param([string]$Value)
    $v = Normalize-Identity $Value
    if ([string]::IsNullOrWhiteSpace($v)) { return $null }
    if ($v -match '@') { return $v }
    return "$v@$($script:Config.PrimaryMailDomain)"
}

function Ensure-ExchangeModule {
    try {
        $module = Get-Module ExchangeOnlineManagement -ListAvailable | Sort-Object Version -Descending | Select-Object -First 1
        if (-not $module) {
            Write-Log 'ExchangeOnlineManagement module not found. Installing CurrentUser scope...'
            Install-Module ExchangeOnlineManagement -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
            $module = Get-Module ExchangeOnlineManagement -ListAvailable | Sort-Object Version -Descending | Select-Object -First 1
        }

        if (-not $module) {
            throw 'ExchangeOnlineManagement module could not be installed.'
        }

        Import-Module ExchangeOnlineManagement -MinimumVersion $module.Version -Force -ErrorAction Stop
        Write-Log "Loaded ExchangeOnlineManagement $($module.Version)"
        return $true
    }
    catch {
        Write-Log "Module load/install failed: $($_.Exception.Message)"
        Show-Message "Could not load ExchangeOnlineManagement.`r`n$($_.Exception.Message)" 'Module Error' ([System.Windows.Forms.MessageBoxIcon]::Error)
        return $false
    }
}

function Connect-ExchangeSafely {
    if (-not (Ensure-ExchangeModule)) { return $false }

    try {
        Write-Log 'Attempting Exchange Online interactive sign-in.'
        Connect-ExchangeOnline -ShowBanner:$true
        Write-Log 'Connected to Exchange Online using interactive sign-in.'
        return $true
    }
    catch {
        Write-Log "Interactive sign-in failed: $($_.Exception.Message)"
    }

    try {
        Write-Log 'Attempting Exchange Online device authentication fallback.'
        Connect-ExchangeOnline -Device -ShowBanner:$false -ErrorAction Stop
        Write-Log 'Connected to Exchange Online using device authentication.'
        return $true
    }
    catch {
        Write-Log "Device sign-in failed: $($_.Exception.Message)"
        Show-Message "Exchange Online connection failed.`r`n$($_.Exception.Message)" 'Connection Error' ([System.Windows.Forms.MessageBoxIcon]::Error)
        return $false
    }
}

function Test-ExchangeConnection {
    try {
        Get-EXOMailbox -ResultSize 1 -ErrorAction Stop | Out-Null
        return $true
    }
    catch {
        try {
            Get-Recipient -ResultSize 1 -ErrorAction Stop | Out-Null
            return $true
        }
        catch {
            return $false
        }
    }
}

function Get-ValidatedRecipient {
    param([string]$Identity)

    $normalized = Normalize-Identity $Identity
    if ([string]::IsNullOrWhiteSpace($normalized)) { return $null }

    $candidate = Get-Recipient -Identity $normalized -ErrorAction SilentlyContinue
    if (-not $candidate -and $normalized -notmatch '@') {
        $candidate = Get-Recipient -Identity (To-OrgEmail $normalized) -ErrorAction SilentlyContinue
    }
    return $candidate
}

function Get-InputLists {
    $requestors = @($script:txtRequestors.Lines | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $mailboxes  = @($script:txtMailboxes.Lines  | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

    [PSCustomObject]@{
        Requestors = $requestors
        Mailboxes  = $mailboxes
    }
}

function Get-SelectedPermissions {
    $selected = @()
    if ($script:chkFullAccess.Checked) { $selected += 'Full Access' }
    if ($script:chkSendAs.Checked) { $selected += 'Send As' }
    if ($script:chkSendOnBehalf.Checked) { $selected += 'Send on Behalf' }
    return $selected
}

function Preview-Assignments {
    $data = Get-InputLists
    $permissions = Get-SelectedPermissions

    if ($data.Requestors.Count -eq 0) {
        Show-Message 'Enter at least one user who needs access.' 'Validation' ([System.Windows.Forms.MessageBoxIcon]::Warning)
        return
    }
    if ($data.Mailboxes.Count -eq 0) {
        Show-Message 'Enter at least one mailbox to grant access to.' 'Validation' ([System.Windows.Forms.MessageBoxIcon]::Warning)
        return
    }
    if ($permissions.Count -eq 0) {
        Show-Message 'Select at least one permission to apply.' 'Validation' ([System.Windows.Forms.MessageBoxIcon]::Warning)
        return
    }

    $mailboxAccess = if ($script:rbDesktop.Checked) { 'Desktop / Automapping ON' } else { 'Web / Automapping OFF' }

    $summary = @()
    $summary += "Users getting access: $($data.Requestors.Count)"
    $summary += ($data.Requestors | ForEach-Object { "  - $_" })
    $summary += ''
    $summary += "Mailboxes being granted: $($data.Mailboxes.Count)"
    $summary += ($data.Mailboxes | ForEach-Object { "  - $_" })
    $summary += ''
    $summary += "Mailbox access type: $mailboxAccess"
    $summary += 'Permissions:'
    $summary += ($permissions | ForEach-Object { "  - $_" })
    $summary += "AAD Connect sync after changes: $($script:chkSync.Checked)"
    $summary += ''
    $summary += "Total user/mailbox combinations: $($data.Requestors.Count * $data.Mailboxes.Count)"

    Show-Message ($summary -join "`r`n") 'Preview' ([System.Windows.Forms.MessageBoxIcon]::Information)
}

$form = New-Object System.Windows.Forms.Form
$form.Text = 'Mailbox Access GUI - One Step'
$form.Size = New-Object System.Drawing.Size(940, 790)
$form.StartPosition = 'CenterScreen'
$form.TopMost = $false
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)

$btnConnect = New-Object System.Windows.Forms.Button
$btnConnect.Location = New-Object System.Drawing.Point(20,20)
$btnConnect.Size = New-Object System.Drawing.Size(180,32)
$btnConnect.Text = 'Connect Exchange Online'
$form.Controls.Add($btnConnect)

$lblConn = New-Object System.Windows.Forms.Label
$lblConn.Location = New-Object System.Drawing.Point(220,26)
$lblConn.Size = New-Object System.Drawing.Size(620,20)
$lblConn.Text = 'Connection status: Not connected'
$form.Controls.Add($lblConn)

$lblHint = New-Object System.Windows.Forms.Label
$lblHint.Location = New-Object System.Drawing.Point(20,60)
$lblHint.Size = New-Object System.Drawing.Size(860,20)
$lblHint.Text = 'Click "Connect Exchange Online" first.'
$form.Controls.Add($lblHint)

$lblRequestors = New-Object System.Windows.Forms.Label
$lblRequestors.Location = New-Object System.Drawing.Point(20,100)
$lblRequestors.Size = New-Object System.Drawing.Size(390,20)
$lblRequestors.Text = 'Users getting access (one per line):'
$form.Controls.Add($lblRequestors)

$script:txtRequestors = New-Object System.Windows.Forms.TextBox
$script:txtRequestors.Location = New-Object System.Drawing.Point(20,125)
$script:txtRequestors.Multiline = $true
$script:txtRequestors.ScrollBars = 'Vertical'
$script:txtRequestors.Size = New-Object System.Drawing.Size(400,190)
$form.Controls.Add($script:txtRequestors)

$lblMailboxes = New-Object System.Windows.Forms.Label
$lblMailboxes.Location = New-Object System.Drawing.Point(470,100)
$lblMailboxes.Size = New-Object System.Drawing.Size(390,20)
$lblMailboxes.Text = 'Mailboxes to grant access to (one per line):'
$form.Controls.Add($lblMailboxes)

$script:txtMailboxes = New-Object System.Windows.Forms.TextBox
$script:txtMailboxes.Location = New-Object System.Drawing.Point(470,125)
$script:txtMailboxes.Multiline = $true
$script:txtMailboxes.ScrollBars = 'Vertical'
$script:txtMailboxes.Size = New-Object System.Drawing.Size(400,190)
$form.Controls.Add($script:txtMailboxes)

$grpMailbox = New-Object System.Windows.Forms.GroupBox
$grpMailbox.Location = New-Object System.Drawing.Point(20,340)
$grpMailbox.Size = New-Object System.Drawing.Size(400,130)
$grpMailbox.Text = 'Mailbox Access Type'
$form.Controls.Add($grpMailbox)

$script:rbDesktop = New-Object System.Windows.Forms.RadioButton
$script:rbDesktop.Location = New-Object System.Drawing.Point(15,30)
$script:rbDesktop.Size = New-Object System.Drawing.Size(320,20)
$script:rbDesktop.Text = 'Desktop'
$script:rbDesktop.Checked = $true
$grpMailbox.Controls.Add($script:rbDesktop)

$script:rbWeb = New-Object System.Windows.Forms.RadioButton
$script:rbWeb.Location = New-Object System.Drawing.Point(15,60)
$script:rbWeb.Size = New-Object System.Drawing.Size(320,20)
$script:rbWeb.Text = 'Web'
$grpMailbox.Controls.Add($script:rbWeb)

$grpPerms = New-Object System.Windows.Forms.GroupBox
$grpPerms.Location = New-Object System.Drawing.Point(470,340)
$grpPerms.Size = New-Object System.Drawing.Size(400,130)
$grpPerms.Text = 'Permissions to Apply'
$form.Controls.Add($grpPerms)

$script:chkFullAccess = New-Object System.Windows.Forms.CheckBox
$script:chkFullAccess.Location = New-Object System.Drawing.Point(15,30)
$script:chkFullAccess.Size = New-Object System.Drawing.Size(180,20)
$script:chkFullAccess.Text = 'Full Access'
$script:chkFullAccess.Checked = $true
$grpPerms.Controls.Add($script:chkFullAccess)

$script:chkSendAs = New-Object System.Windows.Forms.CheckBox
$script:chkSendAs.Location = New-Object System.Drawing.Point(15,60)
$script:chkSendAs.Size = New-Object System.Drawing.Size(180,20)
$script:chkSendAs.Text = 'Send As'
$grpPerms.Controls.Add($script:chkSendAs)

$script:chkSendOnBehalf = New-Object System.Windows.Forms.CheckBox
$script:chkSendOnBehalf.Location = New-Object System.Drawing.Point(15,90)
$script:chkSendOnBehalf.Size = New-Object System.Drawing.Size(180,20)
$script:chkSendOnBehalf.Text = 'Send on Behalf'
$grpPerms.Controls.Add($script:chkSendOnBehalf)

$script:chkSync = New-Object System.Windows.Forms.CheckBox
$script:chkSync.Location = New-Object System.Drawing.Point(20,490)
$script:chkSync.Size = New-Object System.Drawing.Size(350,20)
$script:chkSync.Text = 'Force Sync Azure AD Connect'
$script:chkSync.Checked = [bool]$script:Config.ForceSyncDefault
$form.Controls.Add($script:chkSync)

$btnPreview = New-Object System.Windows.Forms.Button
$btnPreview.Location = New-Object System.Drawing.Point(20,525)
$btnPreview.Size = New-Object System.Drawing.Size(140,32)
$btnPreview.Text = 'Preview Actions'
$form.Controls.Add($btnPreview)

$btnGrant = New-Object System.Windows.Forms.Button
$btnGrant.Location = New-Object System.Drawing.Point(180,525)
$btnGrant.Size = New-Object System.Drawing.Size(140,32)
$btnGrant.Text = 'Grant Access'
$form.Controls.Add($btnGrant)

$btnClear = New-Object System.Windows.Forms.Button
$btnClear.Location = New-Object System.Drawing.Point(340,525)
$btnClear.Size = New-Object System.Drawing.Size(140,32)
$btnClear.Text = 'Clear'
$form.Controls.Add($btnClear)

$lblLog = New-Object System.Windows.Forms.Label
$lblLog.Location = New-Object System.Drawing.Point(20,575)
$lblLog.Size = New-Object System.Drawing.Size(200,20)
$lblLog.Text = 'Output / Validation Log:'
$form.Controls.Add($lblLog)

$script:txtLog = New-Object System.Windows.Forms.TextBox
$script:txtLog.Location = New-Object System.Drawing.Point(20,600)
$script:txtLog.Multiline = $true
$script:txtLog.ScrollBars = 'Vertical'
$script:txtLog.ReadOnly = $true
$script:txtLog.Size = New-Object System.Drawing.Size(850,145)
$form.Controls.Add($script:txtLog)

$btnConnect.Add_Click({
    if (Connect-ExchangeSafely) {
        $lblConn.Text = 'Connection status: Connected to Exchange Online'
        Show-Message 'Connected to Exchange Online.' 'Connected' ([System.Windows.Forms.MessageBoxIcon]::Information)
    }
    else {
        $lblConn.Text = 'Connection status: Connection failed'
    }
})

$btnPreview.Add_Click({ Preview-Assignments })

$btnClear.Add_Click({
    $script:txtRequestors.Clear()
    $script:txtMailboxes.Clear()
    $script:txtLog.Clear()
    Write-Log 'Cleared form fields.'
})

$btnGrant.Add_Click({
    if (-not (Test-ExchangeConnection)) {
        Show-Message 'Connect to Exchange Online first.' 'Validation' ([System.Windows.Forms.MessageBoxIcon]::Warning)
        return
    }

    $data = Get-InputLists
    $permissions = Get-SelectedPermissions

    if ($data.Requestors.Count -eq 0 -or $data.Mailboxes.Count -eq 0) {
        Show-Message 'Enter at least one requestor and one mailbox.' 'Validation' ([System.Windows.Forms.MessageBoxIcon]::Warning)
        return
    }
    if ($permissions.Count -eq 0) {
        Show-Message 'Select at least one permission to apply.' 'Validation' ([System.Windows.Forms.MessageBoxIcon]::Warning)
        return
    }

    $confirmText = "This will process $($data.Requestors.Count * $data.Mailboxes.Count) mailbox combination(s). Continue?"
    $confirm = [System.Windows.Forms.MessageBox]::Show($confirmText, 'Confirm Changes', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
    if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) { return }

    foreach ($requestorInput in $data.Requestors) {
        $requestorRecipient = Get-ValidatedRecipient -Identity $requestorInput
        if (-not $requestorRecipient) {
            Write-Log "Requestor not found: $requestorInput"
            continue
        }

        $requestorName = $requestorRecipient.PrimarySmtpAddress.ToString()
        Write-Log "Validated requestor: $requestorInput -> $requestorName"

        foreach ($mailboxInput in $data.Mailboxes) {
            $mailboxRecipient = Get-ValidatedRecipient -Identity $mailboxInput
            if (-not $mailboxRecipient) {
                Write-Log "Mailbox not found: $mailboxInput"
                continue
            }

            $requesteeName = $mailboxRecipient.PrimarySmtpAddress.ToString()
            Write-Log "Validated mailbox: $mailboxInput -> $requesteeName"

            if ($script:chkFullAccess.Checked) {
                try {
                    if ($script:rbDesktop.Checked) {
                        Add-MailboxPermission -Identity $requesteeName -User $requestorName -AccessRights FullAccess -InheritanceType All -AutoMapping:$true -ErrorAction Stop
                        Write-Log "Added Full Access (Automapping ON): $requestorName -> $requesteeName"
                    }
                    else {
                        Add-MailboxPermission -Identity $requesteeName -User $requestorName -AccessRights FullAccess -InheritanceType All -AutoMapping:$false -ErrorAction Stop
                        Write-Log "Added Full Access (Automapping OFF): $requestorName -> $requesteeName"
                    }
                }
                catch {
                    Write-Log "Failed Full Access for $requestorName -> $requesteeName : $($_.Exception.Message)"
                }
            }

            if ($script:chkSendAs.Checked) {
                try {
                    Add-RecipientPermission -Identity $requesteeName -AccessRights SendAs -Trustee $requestorName -Confirm:$false -ErrorAction Stop
                    Write-Log "Added Send As: $requestorName -> $requesteeName"
                }
                catch {
                    Write-Log "Failed Send As for $requestorName -> $requesteeName : $($_.Exception.Message)"
                }
            }

            if ($script:chkSendOnBehalf.Checked) {
                try {
                    Set-Mailbox -Identity $requesteeName -GrantSendOnBehalfTo @{Add=$requestorName} -ErrorAction Stop
                    Write-Log "Added Send on Behalf: $requestorName -> $requesteeName"
                }
                catch {
                    Write-Log "Failed Send on Behalf for $requestorName -> $requesteeName : $($_.Exception.Message)"
                }
            }
        }
    }

    if ($script:chkSync.Checked) {
        try {
            Invoke-Command -ComputerName $script:Config.AzureSyncServer -ScriptBlock { Start-ADSyncSyncCycle -PolicyType Delta } -ErrorAction Stop
            Write-Log "Triggered Azure AD Connect delta sync on $($script:Config.AzureSyncServer)."
        }
        catch {
            Write-Log "Failed to start Azure AD Connect sync: $($_.Exception.Message)"
        }
    }

    Show-Message 'Processing complete. Review the log for details.' 'Complete' ([System.Windows.Forms.MessageBoxIcon]::Information)
})

[void]$form.ShowDialog()
