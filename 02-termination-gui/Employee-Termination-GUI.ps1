Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms
$script:Config = @{
    Domain                 = "contoso.com"
    AdRootDn               = "DC=contoso,DC=com"
    AdminUser              = "CONTOSO\administrator"
    PasswordFile           = "C:\Windows\powershellSession.txt"
    OktaDomain             = "https://YOUR_ORG.okta.com"   # or set via config.example.psd1; never commit a real org URL with tokens
    OktaTokenEnvVar        = "OKTA_API_TOKEN"                              # system/user environment variable name
    OktaTokenFile          = "C:\Scripts\Offboarding\okta_token.txt"   # optional fallback (DPAPI-encrypted or plain)
    AzureSyncServer        = "AADSYNC01"
    DomainController       = "DC01.contoso.com"
    DisabledUsersOU        = "OU=Disabled Users,DC=contoso,DC=com"
    EvaultGroup            = "Journal-FormerEmployees-DeleteAllEmails"
    GroupExportPath        = "C:\Scripts\Offboarding\UserGroups"
    TerminatedCsv          = "C:\Scripts\Offboarding\TerminatedUsers.csv"
    TranscriptLog          = "C:\Scripts\Offboarding\ScriptLogs.txt"
    PrimaryMailDomain      = "contoso.com"

    # Optional offboarding ticket email — OFF by default for the portfolio copy
    TicketEmail            = @{
        Enabled    = $false
        To         = "helpdesk@contoso.com"
        From       = "offboarding@contoso.com"
        SmtpServer = "smtp.contoso.com"
        SubjectTpl = "{0} Offboarding Tasks"   # {0} = display name
    }

    GraphScopes            = @(
        "User.Read.All",
        "Organization.Read.All",
        "Directory.ReadWrite.All"
    )
    LicenseSkuMap          = [ordered]@{
        '6fd2c87f-b296-42f0-b197-1e91e994b900' = 'Office 365 E3'
        '4b585984-651b-448a-9e53-3b10f069cf7f' = 'Office 365 F3'
        '18181a46-0d4e-45cd-891e-60aabd171b4e' = 'Office 365 E1'
        '4b9405b0-7788-4568-add1-99614e613b69' = 'Exchange Online Plan 1'
        '19ec0d23-8335-4cbd-94ac-6050e30712fa' = 'Exchange Online Plan 2'
    }
    Plan2SkuId             = '4b9405b0-7788-4568-add1-99614e613b69'
}

#--------------------------------------------------------------------
# XAML - GUI definition
#--------------------------------------------------------------------
[xml]$xaml = @"
<Window
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    Title="Employee Termination Tool" Height="940" Width="900"
    WindowStartupLocation="CenterScreen" Background="#1E1E1E">
    <Window.Resources>
        <Style TargetType="Label">
            <Setter Property="Foreground" Value="#E0E0E0"/>
            <Setter Property="FontSize" Value="12"/>
        </Style>
        <Style TargetType="TextBlock">
            <Setter Property="Foreground" Value="#E0E0E0"/>
        </Style>
        <Style TargetType="Button">
            <Setter Property="Background" Value="#0E639C"/>
            <Setter Property="Foreground" Value="White"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Padding" Value="10,6"/>
            <Setter Property="FontSize" Value="12"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Margin" Value="4"/>
        </Style>
        <Style TargetType="TextBox">
            <Setter Property="Background" Value="#2D2D30"/>
            <Setter Property="Foreground" Value="#E0E0E0"/>
            <Setter Property="BorderBrush" Value="#3F3F46"/>
            <Setter Property="Padding" Value="4"/>
            <Setter Property="FontSize" Value="12"/>
        </Style>
        <Style TargetType="ComboBox">
            <Setter Property="Padding" Value="4"/>
            <Setter Property="FontSize" Value="12"/>
        </Style>
        <Style TargetType="CheckBox">
            <Setter Property="Foreground" Value="#E0E0E0"/>
            <Setter Property="FontSize" Value="12"/>
            <Setter Property="Margin" Value="4"/>
        </Style>
        <Style TargetType="GroupBox">
            <Setter Property="Foreground" Value="#C0C0C0"/>
            <Setter Property="BorderBrush" Value="#3F3F46"/>
            <Setter Property="Margin" Value="6"/>
            <Setter Property="Padding" Value="6"/>
        </Style>
    </Window.Resources>

    <Grid Margin="10">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <!-- Header -->
        <TextBlock Grid.Row="0" Text="Employee Termination / Offboarding Tool"
                   FontSize="20" FontWeight="Bold" Foreground="#4EC9B0" Margin="4,0,4,10"/>

        <!-- Search -->
        <GroupBox Grid.Row="1" Header="1. Find User">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <Label Grid.Column="0" Content="First name:" VerticalAlignment="Center"/>
                <TextBox Grid.Column="1" Name="txtFirst" Margin="4" VerticalAlignment="Center"/>
                <Label Grid.Column="2" Content="Last name:" VerticalAlignment="Center"/>
                <TextBox Grid.Column="3" Name="txtLast" Margin="4" VerticalAlignment="Center"/>
                <Button Grid.Column="4" Name="btnSearch" Content="Search AD" Width="100"/>
            </Grid>
        </GroupBox>

        <!-- Selection + Options -->
        <GroupBox Grid.Row="2" Header="2. Select User &amp; Options">
            <Grid>
                <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                </Grid.RowDefinitions>
                <Grid Grid.Row="0">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="Auto"/>
                        <ColumnDefinition Width="*"/>
                    </Grid.ColumnDefinitions>
                    <Label Grid.Column="0" Content="Matched user:" VerticalAlignment="Center"/>
                    <ComboBox Grid.Column="1" Name="cmbUsers" Margin="4" IsEnabled="False"/>
                </Grid>
                <TextBlock Grid.Row="1" Name="txtUserInfo" Margin="4,6" TextWrapping="Wrap"
                           Foreground="#DCDCAA" Text="No user selected."/>
                <Grid Grid.Row="2">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="Auto"/>
                        <ColumnDefinition Width="Auto"/>
                        <ColumnDefinition Width="*"/>
                    </Grid.ColumnDefinitions>
                    <CheckBox Grid.Column="0" Name="chkForward" Content="Forward email to manager" VerticalAlignment="Center"/>
                    <Label Grid.Column="1" Content="Manager acct:" VerticalAlignment="Center"/>
                    <TextBox Grid.Column="2" Name="txtManager" Margin="4" IsEnabled="False"
                             ToolTip="Manager's login, e.g. aserna" VerticalAlignment="Center"/>
                </Grid>
                <Grid Grid.Row="3">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="Auto"/>
                        <ColumnDefinition Width="Auto"/>
                        <ColumnDefinition Width="Auto"/>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="Auto"/>
                    </Grid.ColumnDefinitions>
                    <Label Grid.Column="0" Content="License action:" VerticalAlignment="Center"/>
                    <ComboBox Grid.Column="1" Name="cmbLicense" Width="260" Margin="4" VerticalAlignment="Center">
                        <ComboBoxItem Content="None (leave licenses as-is)" IsSelected="True"/>
                        <ComboBoxItem Content="Remove all licenses"/>
                        <ComboBoxItem Content="Remove all + assign Plan 1"/>
                    </ComboBox>
                    <Label Grid.Column="2" Content="Plan 1 SkuId:" VerticalAlignment="Center"/>
                    <TextBox Grid.Column="3" Name="txtPlan2Sku" Margin="4" IsEnabled="False"
                             ToolTip="SkuId (GUID) of the Plan 1 license to assign" VerticalAlignment="Center"/>
                    <Button Grid.Column="4" Name="btnCheckLicense" Content="Check Licenses" Width="120"
                            IsEnabled="False" ToolTip="Connect to Graph and show this user's currently-assigned licenses"/>
                </Grid>
                <Border Grid.Row="4" Margin="4,2,4,4" BorderBrush="#3F3F46" BorderThickness="1" Background="#252526">
                    <TextBox Name="txtLicenseInfo" IsReadOnly="True" TextWrapping="Wrap" MinHeight="72"
                             Background="Transparent" BorderThickness="0" Foreground="#9CDCFE"
                             FontFamily="Consolas" Text="Licenses not checked. Click 'Check Licenses' to connect to Graph and view current assignments."/>
                </Border>
                <Grid Grid.Row="5" Margin="0,4,0,0">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="Auto"/>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="Auto"/>
                    </Grid.ColumnDefinitions>
                    <Label Grid.Column="0" Content="Okta access:" VerticalAlignment="Center"/>
                    <CheckBox Grid.Column="1" Name="chkTicketEmail" VerticalAlignment="Center" Margin="4,0,0,0"
                              Content="Send offboarding ticket email"
                              ToolTip="Sends a plain offboarding ticket email when TicketEmail.Enabled is true in config. Disabled by default in this portfolio copy."/>
                    <Button Grid.Column="2" Name="btnCheckOkta" Content="Check Okta" Width="120"
                            IsEnabled="False" ToolTip="List this user's Okta apps and groups before terminating"/>
                </Grid>
                <Border Grid.Row="6" Margin="4,2,4,4" BorderBrush="#3F3F46" BorderThickness="1" Background="#252526">
                    <TextBox Name="txtOktaInfo" IsReadOnly="True" TextWrapping="Wrap" MinHeight="72"
                             Background="Transparent" BorderThickness="0" Foreground="#9CDCFE"
                             FontFamily="Consolas" Text="Okta not checked. Click 'Check Okta' to list this user's assigned apps and groups."/>
                </Border>
            </Grid>
        </GroupBox>

        <!-- Log -->
        <GroupBox Grid.Row="3" Header="Activity Log">
            <TextBox Name="txtLog" IsReadOnly="True" TextWrapping="Wrap"
                     VerticalScrollBarVisibility="Auto" FontFamily="Consolas"
                     Background="#0C0C0C" Foreground="#CCCCCC"/>
        </GroupBox>

        <!-- Actions -->
        <Grid Grid.Row="4">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
                <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <ProgressBar Grid.Column="0" Name="prog" Height="20" Margin="4"
                         IsIndeterminate="False" Foreground="#0E639C" Background="#2D2D30"/>
            <Button Grid.Column="1" Name="btnTerminate" Content="Terminate User" Width="140"
                    Background="#A1260D" IsEnabled="False" FontWeight="Bold"/>
            <Button Grid.Column="2" Name="btnClose" Content="Close" Width="90" Background="#3F3F46"/>
        </Grid>
    </Grid>
</Window>
"@

#--------------------------------------------------------------------
# Load the window
#--------------------------------------------------------------------
$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)

# Grab named controls
$txtFirst     = $window.FindName("txtFirst")
$txtLast      = $window.FindName("txtLast")
$btnSearch    = $window.FindName("btnSearch")
$cmbUsers     = $window.FindName("cmbUsers")
$txtUserInfo  = $window.FindName("txtUserInfo")
$chkForward   = $window.FindName("chkForward")
$txtManager   = $window.FindName("txtManager")
$cmbLicense   = $window.FindName("cmbLicense")
$txtPlan2Sku  = $window.FindName("txtPlan2Sku")
$btnCheckLicense = $window.FindName("btnCheckLicense")
$txtLicenseInfo  = $window.FindName("txtLicenseInfo")
$chkTicketEmail = $window.FindName("chkTicketEmail")
$btnCheckOkta = $window.FindName("btnCheckOkta")
$txtOktaInfo  = $window.FindName("txtOktaInfo")
$txtLog       = $window.FindName("txtLog")
$prog         = $window.FindName("prog")
$btnTerminate = $window.FindName("btnTerminate")
$btnClose     = $window.FindName("btnClose")

# Pre-fill the Plan 1 SKU field with the configured default (editable by operator)
$txtPlan2Sku.Text = $script:Config.Plan2SkuId

#--------------------------------------------------------------------
# Shared state
#--------------------------------------------------------------------
$script:MatchedUsers = @()   # array of PSObjects with SamAccountName / Name
$script:SelectedSam  = $null
$script:Runspace     = $null
$script:PowerShell   = $null
$script:GraphConnected = $false   # tracks whether the MAIN session has a live Graph connection (for the pre-flight check)

#--------------------------------------------------------------------
# Logging helper (thread-safe append to the log pane)
#--------------------------------------------------------------------
function Write-Log {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )
    $stamp = (Get-Date).ToString("HH:mm:ss")
    $line  = "[$stamp][$Level] $Message"
    $txtLog.Dispatcher.Invoke([action]{
        $txtLog.AppendText("$line`r`n")
        $txtLog.ScrollToEnd()
    }, "Normal")
}

#--------------------------------------------------------------------
# Okta token loader (replaces hardcoded token)
#--------------------------------------------------------------------
function Get-OktaToken {
    # 1) Preferred: read from environment variable (Machine, then User, then Process scope)
    $envName = $script:Config.OktaTokenEnvVar
    foreach ($scope in @('Machine','User','Process')) {
        try {
            $val = [System.Environment]::GetEnvironmentVariable($envName, $scope)
            if (-not [string]::IsNullOrWhiteSpace($val)) {
                Write-Log "Loaded Okta token from '$envName' environment variable ($scope scope)."
                return $val.Trim()
            }
        } catch {}
    }

    # 2) Fallback: encrypted/plain token file
    if (Test-Path $script:Config.OktaTokenFile) {
        try {
            $raw = Get-Content $script:Config.OktaTokenFile -Raw
            # If it was saved with ConvertFrom-SecureString, decrypt it
            try {
                $sec = $raw | ConvertTo-SecureString -ErrorAction Stop
                $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
                $token = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
                [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
                return $token.Trim()
            } catch {
                return $raw.Trim()   # plain text token
            }
        } catch {
            Write-Log "Could not read Okta token file: $($_.Exception.Message)" "WARN"
        }
    }
    # 3) Last resort: prompt the operator for it
    $token = [Microsoft.VisualBasic.Interaction]::InputBox(
        "Okta API token not found in the '$envName' environment variable or on disk. Enter it to continue (SSWS token).",
        "Okta API Token", "")
    return $token
}

#--------------------------------------------------------------------
# Microsoft Graph connection (mirrors the new-hire tool's Connect-OrgGraph)
# Interactive/delegated sign-in with the SAME scopes the new-hire script uses.
# Used by the 'Check Licenses' pre-flight on the main session.
#--------------------------------------------------------------------
function Ensure-GraphModule {
    $required = @('Microsoft.Graph.Authentication','Microsoft.Graph.Users','Microsoft.Graph.Identity.DirectoryManagement')
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

    # Same scopes as the new-hire tool (Connect-OrgGraph)
    $scopes = $script:Config.GraphScopes
    Connect-MgGraph -Scopes $scopes -NoWelcome
    $ctx = Get-MgContext
    if (-not $ctx) {
        throw 'Graph connection did not return a context.'
    }

    $script:GraphConnected = $true
    Write-Log "GRAPH CONNECTED - Tenant='$($ctx.TenantId)' Account='$($ctx.Account)'"
    return $ctx
}

#--------------------------------------------------------------------
# Connect to services (AD / Microsoft Graph / Exchange Online)
# NOTE: Actual connection happens inside the worker runspace; this helper is
# kept for reference / manual use from the main session.
#--------------------------------------------------------------------
function Connect-Services {
    Write-Log "Importing modules..."
    Import-Module ActiveDirectory          -ErrorAction Stop
    Import-Module Microsoft.Graph          -ErrorAction SilentlyContinue
    Import-Module ExchangeOnlineManagement -ErrorAction SilentlyContinue

    # TLS hardening (matches original SecureProtocols reg tweak intent)
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    Write-Log "Connecting to Microsoft Graph / Exchange Online..."
    try { Connect-MgGraph -Scopes $script:Config.GraphScopes -NoWelcome -ErrorAction Stop } catch { Write-Log "Connect-MgGraph: $($_.Exception.Message)" "WARN" }
    try { Connect-ExchangeOnline -ShowBanner:$false -ErrorAction Stop } catch { Write-Log "Connect-ExchangeOnline: $($_.Exception.Message)" "WARN" }
    Write-Log "Service connection attempt complete."
}

#====================================================================
# EVENT: Search AD
#====================================================================
$btnSearch.Add_Click({
    $first = $txtFirst.Text.Trim()
    $last  = $txtLast.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($first) -and [string]::IsNullOrWhiteSpace($last)) {
        [System.Windows.MessageBox]::Show("Enter a first and/or last name to search.","Missing input",'OK','Warning') | Out-Null
        return
    }

    $cmbUsers.Items.Clear()
    $cmbUsers.IsEnabled = $false
    $btnTerminate.IsEnabled = $false
    $txtUserInfo.Text = "Searching..."
    Write-Log "Searching AD for '$first $last'..."

    try {
        Import-Module ActiveDirectory -ErrorAction Stop
        $f = if ($first) { $first } else { "*" }
        $l = if ($last)  { $last }  else { "*" }
        $script:MatchedUsers = @(Get-ADUser -Filter "GivenName -like '$f' -and Surname -like '$l'" `
            -Properties SamAccountName, Name, EmailAddress, Title, Department, Enabled)

        if ($script:MatchedUsers.Count -eq 0) {
            $txtUserInfo.Text = "No users found with that name."
            Write-Log "No users found." "WARN"
            return
        }

        foreach ($u in $script:MatchedUsers) {
            [void]$cmbUsers.Items.Add("$($u.Name)  ($($u.SamAccountName))")
        }
        $cmbUsers.IsEnabled = $true
        $cmbUsers.SelectedIndex = 0
        Write-Log "Found $($script:MatchedUsers.Count) match(es)."
    }
    catch {
        $txtUserInfo.Text = "Search failed."
        Write-Log "AD search error: $($_.Exception.Message)" "ERROR"
        [System.Windows.MessageBox]::Show("AD search failed:`n$($_.Exception.Message)","Error",'OK','Error') | Out-Null
    }
})

#====================================================================
# EVENT: User selection changed
#====================================================================
$cmbUsers.Add_SelectionChanged({
    $idx = $cmbUsers.SelectedIndex
    if ($idx -lt 0 -or $idx -ge $script:MatchedUsers.Count) { return }
    $u = $script:MatchedUsers[$idx]
    $script:SelectedSam = $u.SamAccountName
    $enabledText = if ($u.Enabled) { "Enabled" } else { "Disabled" }
    $txtUserInfo.Text = "Name: $($u.Name)`nSAM: $($u.SamAccountName)`nEmail: $($u.EmailAddress)`nTitle: $($u.Title)`nDept: $($u.Department)`nStatus: $enabledText"
    $btnTerminate.IsEnabled = $true
    $btnCheckLicense.IsEnabled = $true
    $btnCheckOkta.IsEnabled = $true
    # Reset the license readout for the newly-selected user
    $txtLicenseInfo.Foreground = '#9CDCFE'
    $txtLicenseInfo.Text = "Licenses not checked for this user. Click 'Check Licenses' to view current assignments."
    # Reset the Okta readout for the newly-selected user
    $txtOktaInfo.Foreground = '#9CDCFE'
    $txtOktaInfo.Text = "Okta not checked for this user. Click 'Check Okta' to list assigned apps and groups."
    $chkTicketEmail.IsChecked = $false
})

#====================================================================
# EVENT: Forward checkbox toggles manager field
#====================================================================
$chkForward.Add_Checked({   $txtManager.IsEnabled = $true })
$chkForward.Add_Unchecked({ $txtManager.IsEnabled = $false; $txtManager.Text = "" })

#====================================================================
# EVENT: License action dropdown - enable SKU field only for "assign Plan 1"
#====================================================================
$cmbLicense.Add_SelectionChanged({
    # Index 2 = "Remove all + assign Plan 1"
    if ($cmbLicense.SelectedIndex -eq 2) {
        $txtPlan2Sku.IsEnabled = $true
        if ([string]::IsNullOrWhiteSpace($txtPlan2Sku.Text)) { $txtPlan2Sku.Text = $script:Config.Plan2SkuId }
    } else {
        $txtPlan2Sku.IsEnabled = $false
    }
})

#====================================================================
# EVENT: Check Licenses (pre-flight) - connect Graph + show what the user has
#====================================================================
# This runs on the MAIN session (not the worker runspace) so you can review
# assignments BEFORE committing to a termination. It connects to Graph on the
# first click (interactive sign-in) and reuses that session afterwards; the
# 'Check Licenses' button doubles as a Graph refresh/connect button.
$btnCheckLicense.Add_Click({
    if (-not $script:SelectedSam) {
        [System.Windows.MessageBox]::Show("Select a user first.","No user",'OK','Warning') | Out-Null
        return
    }

    $btnCheckLicense.IsEnabled = $false
    $btnCheckLicense.Content    = "Checking..."
    $txtLicenseInfo.Foreground  = '#9CDCFE'
    $txtLicenseInfo.Text        = "Connecting to Microsoft Graph and reading licenses..."
    # Let the UI repaint before the (potentially blocking) Graph calls
    [System.Windows.Forms.Application]::DoEvents()

    try {
        # 1+2) Connect (or refresh) Graph using the SAME routine and scopes as the
        #      new-hire tool (Connect-OrgGraph). Verify the context is live each
        #      time so a dropped/expired session re-prompts instead of silently failing.
        $ctx = $null
        try { $ctx = Get-MgContext } catch { $ctx = $null }
        if (-not $ctx -or -not $script:GraphConnected) {
            Write-Log "Connecting to Microsoft Graph for license pre-flight (interactive sign-in may prompt)..."
            $ctx = Connect-OrgGraph
        } else {
            Write-Log "Reusing existing Microsoft Graph session ($($ctx.Account))."
        }

        # 3) Resolve the user in AD (for email/UPN), then in Entra via Graph
        Import-Module ActiveDirectory -ErrorAction Stop
        $adUser    = Get-ADUser -Identity $script:SelectedSam -Properties EmailAddress, Name -ErrorAction Stop
        $userEmail = $adUser.EmailAddress
        $upn       = "$($script:SelectedSam)@$($script:Config.Domain)"

        $mgUser = $null
        if ($userEmail) {
            $mgUser = Get-MgUser -Filter "userPrincipalName eq '$userEmail'" -ErrorAction SilentlyContinue
            if (-not $mgUser) { $mgUser = Get-MgUser -Filter "mail eq '$userEmail'" -ErrorAction SilentlyContinue }
        }
        if (-not $mgUser) { $mgUser = Get-MgUser -Filter "userPrincipalName eq '$upn'" -ErrorAction SilentlyContinue }

        if (-not $mgUser) {
            $txtLicenseInfo.Foreground = '#F48771'
            $txtLicenseInfo.Text = "Could not find an Entra (Azure AD) account for $($adUser.Name) [$userEmail / $upn]. They may already be deprovisioned, or the UPN differs from AD."
            Write-Log "License pre-flight: no Graph user resolved for '$($script:SelectedSam)'." "WARN"
            return
        }

        # 4) Read directly-assigned licenses (show friendly name + part number, no SKU GUID)
        $skus = @(Get-MgUserLicenseDetail -UserId $mgUser.Id -ErrorAction Stop)
        if ($skus.Count -eq 0) {
            $header = "NO directly-assigned licenses found for $($mgUser.UserPrincipalName)."
            $txtLicenseInfo.Foreground = '#DCDCAA'
            Write-Log "License pre-flight: $($mgUser.UserPrincipalName) has no directly-assigned licenses."
        } else {
            $lines = foreach ($s in $skus) {
                $friendly = $script:Config.LicenseSkuMap[$s.SkuId]
                if (-not $friendly) { $friendly = $s.SkuPartNumber }
                "  * $friendly  [$($s.SkuPartNumber)]"
            }
            $header = "$($mgUser.UserPrincipalName) has $($skus.Count) directly-assigned license(s):`r`n" + ($lines -join "`r`n")
            $txtLicenseInfo.Foreground = '#9CDCFE'
            Write-Log "License pre-flight: $($mgUser.UserPrincipalName) has $($skus.Count) license(s) assigned."
        }

        # 5) Tenant availability for the Plan 1 SKU (matches the new-hire 'DisplayName: Available' format)
        $availText = ""
        try {
            $plan2 = $txtPlan2Sku.Text.Trim()
            if ([string]::IsNullOrWhiteSpace($plan2)) { $plan2 = $script:Config.Plan2SkuId }
            $subs  = Get-MgSubscribedSku -All -ErrorAction Stop
            $match = $subs | Where-Object { $_.SkuId -eq $plan2 -or $_.SkuPartNumber -eq $plan2 }
            if ($match) {
                $enabled   = [int]$match.PrepaidUnits.Enabled
                $consumed  = [int]$match.ConsumedUnits
                $available = $enabled - $consumed
                $friendly  = $script:Config.LicenseSkuMap[[string]$match.SkuId]
                if (-not $friendly) { $friendly = $match.SkuPartNumber }
                $availText = "`r`n`r`nPlan 1 availability -> {0}: {1} available ({2} of {3} used)" -f $friendly, $available, $consumed, $enabled
                Write-Log ("Plan 1 availability - {0}: {1} available ({2}/{3} used)." -f $friendly, $available, $consumed, $enabled)
                if ($available -le 0) { $availText += "  [!] No seats free" }
            } else {
                $availText = "`r`n`r`nPlan 1 availability -> SKU '$plan2' not found in tenant inventory."
                Write-Log "Plan 1 availability: SKU '$plan2' not found in tenant inventory." "WARN"
            }
        } catch {
            $availText = "`r`n`r`nPlan 1 availability -> could not query: $($_.Exception.Message)"
            Write-Log "Plan 1 availability query failed: $($_.Exception.Message)" "WARN"
        }

        $groupNote = "`r`n(Note: group-based licenses are not shown here - those clear when the user is removed from the licensing group during termination.)"
        $txtLicenseInfo.Text = $header + $availText + $groupNote
    }
    catch {
        $txtLicenseInfo.Foreground = '#F48771'
        $txtLicenseInfo.Text = "License check failed: $($_.Exception.Message)"
        Write-Log "License pre-flight failed: $($_.Exception.Message)" "ERROR"
        # Force a reconnect on the next click if the session looks broken
        $script:GraphConnected = $false
    }
    finally {
        $btnCheckLicense.Content   = "Check Licenses"
        $btnCheckLicense.IsEnabled = $true
    }
})

#====================================================================
# EVENT: Check Okta (pre-flight) - list this user's apps + groups
#====================================================================
$btnCheckOkta.Add_Click({
    if (-not $script:SelectedSam) {
        [System.Windows.MessageBox]::Show("Select a user first.","No user",'OK','Warning') | Out-Null
        return
    }

    $btnCheckOkta.IsEnabled = $false
    $btnCheckOkta.Content    = "Checking..."
    $txtOktaInfo.Foreground  = '#9CDCFE'
    $txtOktaInfo.Text        = "Loading Okta token and querying assigned apps and groups..."
    [System.Windows.Forms.Application]::DoEvents()

    try {
        $oktaToken = Get-OktaToken
        if ([string]::IsNullOrWhiteSpace($oktaToken)) {
            $txtOktaInfo.Foreground = '#F48771'
            $txtOktaInfo.Text = "No Okta API token available - cannot check Okta access."
            Write-Log "Okta pre-flight: no token available." "WARN"
            return
        }
        $headers = @{
            Authorization  = "SSWS $oktaToken"
            Accept         = "application/json"
            "Content-Type" = "application/json"
        }

        # Resolve the Okta user by SAM (login). Mirrors the worker's lookup.
        $oktaUser = $null
        try {
            $oktaUser = Invoke-RestMethod -Uri "$($script:Config.OktaDomain)/api/v1/users/$($script:SelectedSam)" -Headers $headers -Method Get -ErrorAction Stop
        } catch {
            $txtOktaInfo.Foreground = '#DCDCAA'
            $txtOktaInfo.Text = "No Okta account found for '$($script:SelectedSam)' (they may already be deactivated), or the login differs. `r`nDetails: $($_.Exception.Message)"
            Write-Log "Okta pre-flight: no user resolved for '$($script:SelectedSam)'." "WARN"
            return
        }
        $oktaId = $oktaUser.id
        $status = $oktaUser.status
        Write-Log "Okta pre-flight: user $oktaId (status $status)."

        # Enumerate assigned apps
        $appNames = @()
        try {
            $oktaApps = Invoke-RestMethod -Uri "$($script:Config.OktaDomain)/api/v1/apps?filter=user.id+eq+%22$oktaId%22&limit=200" -Headers $headers -Method Get -ErrorAction Stop
            foreach ($app in $oktaApps) { if ($app.label) { $appNames += [string]$app.label } }
        } catch { Write-Log "Okta pre-flight app enumeration: $($_.Exception.Message)" "WARN" }

        # Enumerate group memberships
        $groupNames = @()
        try {
            $oktaGroups = Invoke-RestMethod -Uri "$($script:Config.OktaDomain)/api/v1/users/$oktaId/groups" -Headers $headers -Method Get -ErrorAction Stop
            foreach ($g in $oktaGroups) { if ($g.profile.name) { $groupNames += [string]$g.profile.name } }
        } catch { Write-Log "Okta pre-flight group retrieval: $($_.Exception.Message)" "WARN" }

        $appLines = foreach ($n in ($appNames | Sort-Object -Unique)) { "  * $n" }
        $groupLines = foreach ($n in ($groupNames | Sort-Object -Unique)) { "  * $n" }

        $sb = New-Object System.Text.StringBuilder
        [void]$sb.AppendLine("Okta account: $oktaId  (status: $status)")
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine("Assigned apps ($($appNames.Count)):")
        if ($appLines) { [void]$sb.AppendLine(($appLines -join "`r`n")) } else { [void]$sb.AppendLine("  (none)") }
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine("Group memberships ($($groupNames.Count)):")
        if ($groupLines) { [void]$sb.AppendLine(($groupLines -join "`r`n")) } else { [void]$sb.AppendLine("  (none)") }

        $txtOktaInfo.Foreground = '#9CDCFE'
        $txtOktaInfo.Text = $sb.ToString().TrimEnd()
        Write-Log "Okta pre-flight: $($appNames.Count) apps, $($groupNames.Count) groups."
    }
    catch {
        $txtOktaInfo.Foreground = '#F48771'
        $txtOktaInfo.Text = "Okta check failed: $($_.Exception.Message)"
        Write-Log "Okta pre-flight failed: $($_.Exception.Message)" "ERROR"
    }
    finally {
        $btnCheckOkta.Content   = "Check Okta"
        $btnCheckOkta.IsEnabled = $true
    }
})

#====================================================================
# EVENT: Close
#====================================================================
$btnClose.Add_Click({
    if ($script:PowerShell) {
        try { $script:PowerShell.Stop() } catch {}
        try { $script:PowerShell.Dispose() } catch {}
    }
    if ($script:Runspace) { try { $script:Runspace.Close() } catch {} }
    $window.Close()
})

#====================================================================
# EVENT: Terminate
#====================================================================
$btnTerminate.Add_Click({
    if (-not $script:SelectedSam) {
        [System.Windows.MessageBox]::Show("Select a user first.","No user",'OK','Warning') | Out-Null
        return
    }

    $forward = $chkForward.IsChecked
    $manager = $txtManager.Text.Trim()
    if ($forward -and [string]::IsNullOrWhiteSpace($manager)) {
        [System.Windows.MessageBox]::Show("Enter the manager's account for forwarding, or uncheck the forward option.","Manager required",'OK','Warning') | Out-Null
        return
    }

    # License action: 0 = none, 1 = remove all, 2 = remove all + assign Plan 1
    $licenseAction = [int]$cmbLicense.SelectedIndex
    $plan2Sku      = $txtPlan2Sku.Text.Trim()
    # Optional ticket email (only if TicketEmail.Enabled in config AND checkbox ticked)
    $sendTicket = [bool]($script:Config.TicketEmail.Enabled -and $chkTicketEmail.IsChecked)
    if ($licenseAction -eq 2 -and [string]::IsNullOrWhiteSpace($plan2Sku)) {
        [System.Windows.MessageBox]::Show("Enter the Plan 1 SkuId to assign, or choose a different license action.","SKU required",'OK','Warning') | Out-Null
        return
    }

    # If a license action is selected, make sure the operator has run the pre-flight
    # check first (so they can see what's actually assigned before committing).
    if ($licenseAction -gt 0) {
        $info = $txtLicenseInfo.Text
        $checked = ($info -match 'directly-assigned license' -or $info -match 'NO directly-assigned')
        if (-not $checked) {
            $r = [System.Windows.MessageBox]::Show(
                "You picked a license action but haven't run 'Check Licenses' for this user yet.`n`nRun the check now so you can review what's assigned before terminating?`n`n(Yes = stop and let me check first, No = proceed anyway)",
                "Verify licenses first?", 'YesNo', 'Warning')
            if ($r -eq 'Yes') { Write-Log "Termination paused - run 'Check Licenses' to review assignments first." "WARN"; return }
        }
        elseif ($info -match 'NO directly-assigned') {
            $r = [System.Windows.MessageBox]::Show(
                "The last license check showed NO directly-assigned licenses for this user, but you selected a license action.`n`nProceed with the termination anyway?",
                "No licenses assigned", 'YesNo', 'Warning')
            if ($r -ne 'Yes') { Write-Log "Termination cancelled - no licenses to act on." "WARN"; return }
        }
    }

    # Describe the chosen license action for the confirmation dialog
    $licenseText = switch ($licenseAction) {
        1       { "remove ALL assigned licenses" }
        2       { "remove ALL licenses and assign Plan 1 ($plan2Sku)" }
        default { "leave licenses unchanged" }
    }
    $ticketText = if ($sendTicket) { "send an offboarding ticket email to $($script:Config.TicketEmail.To)" } else { "skip the offboarding ticket email" }

    $confirm = [System.Windows.MessageBox]::Show(
        "This will reset the password, remove ALL group memberships (AD/Azure/Okta), disable the account, $licenseText, $ticketText, and offboard:`n`n$($script:SelectedSam)`n`nContinue?",
        "Confirm Termination", 'YesNo', 'Warning')
    if ($confirm -ne 'Yes') { Write-Log "Termination cancelled by operator." "WARN"; return }

    # Okta token (prompted/loaded, not hardcoded)
    $oktaToken = Get-OktaToken
    if ([string]::IsNullOrWhiteSpace($oktaToken)) {
        Write-Log "No Okta token provided - Okta steps will be skipped." "WARN"
    }

    # Lock the UI while running
    $btnTerminate.IsEnabled = $false
    $btnSearch.IsEnabled    = $false
    $prog.IsIndeterminate   = $true
    Write-Log "=== Starting termination for $($script:SelectedSam) ===" "INFO"

    # Build the worker scriptblock. Runs on a background runspace.
    $worker = {
        param($sam, $forward, $managerUser, $oktaToken, $licenseAction, $plan2Sku, $sendTicket, $cfg, $logCallback)

        function WL { param($m,$lvl="INFO") $logCallback.Invoke($m,$lvl) }

        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

            # --- 0. Import modules INSIDE this runspace (isolated session) ---
            # The runspace does not inherit modules or connections from the main GUI session,
            # so everything Graph/Exchange/AD needs must be imported and connected here.
            # NOTE: AzureAD and MSOnline were RETIRED by Microsoft (2025) and no longer work;
            # all Azure/M365 directory operations now go through the Microsoft Graph SDK.
            WL "Importing required modules in worker session..."
            # Microsoft.Graph.Users.Actions is intentionally NOT imported - it backed
            # Send-MgUserMail, which we dropped so the worker stays on the new-hire scopes.
            foreach ($m in @('ActiveDirectory','Microsoft.Graph.Authentication','Microsoft.Graph.Users','Microsoft.Graph.Groups','Microsoft.Graph.Identity.DirectoryManagement','ExchangeOnlineManagement')) {
                try {
                    Import-Module $m -ErrorAction Stop
                    WL "Imported module: $m"
                } catch {
                    WL "Module '$m' failed to import: $($_.Exception.Message)" "ERROR"
                    if ($m -in @('ActiveDirectory','Microsoft.Graph.Authentication','Microsoft.Graph.Users','Microsoft.Graph.Groups')) {
                        throw "Required module '$m' is not available. Install RSAT + Microsoft.Graph and retry."
                    }
                }
            }

            # --- 0b. Connect to services INSIDE this runspace (interactive sign-in) ---
            WL "Connecting to Microsoft Graph / Exchange Online (interactive sign-in may prompt)..."
            try {
                Connect-MgGraph -Scopes $cfg.GraphScopes -NoWelcome -ErrorAction Stop
                $ctx = Get-MgContext
                WL "Connected to Microsoft Graph as $($ctx.Account)."
            }
            catch { WL "Connect-MgGraph FAILED: $($_.Exception.Message)" "ERROR"; throw "Cannot continue without a Microsoft Graph connection." }
            try { Connect-ExchangeOnline -ShowBanner:$false -ErrorAction Stop; WL "Connected to Exchange Online." }
            catch { WL "Connect-ExchangeOnline: $($_.Exception.Message)" "WARN" }

            $o365Account   = "$sam@$($cfg.Domain)"
            $userInfo      = Get-ADUser -Identity $sam -Properties EmailAddress, Name, GivenName, Surname
            $userEmail     = $userInfo.EmailAddress

            # Resolve the Azure AD (Entra) user via Graph. Try AD email first, then the built UPN.
            $mgUser = $null
            if ($userEmail) {
                $mgUser = Get-MgUser -Filter "userPrincipalName eq '$userEmail'" -ErrorAction SilentlyContinue
                if (-not $mgUser) { $mgUser = Get-MgUser -Filter "mail eq '$userEmail'" -ErrorAction SilentlyContinue }
            }
            if (-not $mgUser) {
                $mgUser = Get-MgUser -Filter "userPrincipalName eq '$o365Account'" -ErrorAction SilentlyContinue
            }
            $objectID = $mgUser.Id
            if ($objectID) { WL "Resolved Entra (Graph) user object: $objectID" } else { WL "Could not resolve Graph user for '$userEmail' / '$o365Account'." "WARN" }

            # --- 1. Reset password (random 15 chars + complexity suffix) ---
            $randomPassword = -join (33..126 | ForEach-Object {[char]$_} | Get-Random -Count 15)
            $randomPassword += "1Q!"
            $newPassword = ConvertTo-SecureString -String $randomPassword -AsPlainText -Force
            Set-ADAccountPassword -Identity $sam -NewPassword $newPassword -Reset
            WL "Password reset successfully."

            # --- 2. Export current group memberships to CSV ---
            try {
                if (-not (Test-Path $cfg.GroupExportPath)) { New-Item -ItemType Directory -Path $cfg.GroupExportPath -Force | Out-Null }
                Get-ADPrincipalGroupMembership $sam | Select-Object name |
                    Export-Csv -Path (Join-Path $cfg.GroupExportPath "$sam.csv") -NoTypeInformation
                WL "Exported group memberships to CSV."
            } catch { WL "Group export failed: $($_.Exception.Message)" "WARN" }

            # --- 3. Remove all AD group memberships ---
            Get-ADUser -Identity $sam -Properties MemberOf | ForEach-Object {
                $_.MemberOf | ForEach-Object {
                    try { Remove-ADGroupMember -Identity $_ -Members $sam -Confirm:$false } catch {}
                }
            }
            WL "Removed AD group memberships."

            # --- 4. Add to Evault container + set as primary group ---
            try {
                Add-ADGroupMember -Identity $cfg.EvaultGroup -Members $sam
                $newPrimaryGroup = Get-ADGroup $cfg.EvaultGroup -Properties @("primaryGroupToken")
                Get-ADUser $sam | Set-ADUser -Replace @{primaryGroupID=$newPrimaryGroup.primaryGroupToken}
                Remove-ADGroupMember -Identity "Domain Users" -Members $sam -Confirm:$false
                WL "Added to Evault group and set as primary; removed from Domain Users."
            } catch { WL "Evault/primary group step: $($_.Exception.Message)" "WARN" }

            # --- 5. Clear Organization tab fields ---
            try {
                Set-ADUser -Identity $sam -Clear Title, Department, Company, Manager
                WL "Cleared Organization tab fields."
            } catch { WL "Clear org fields: $($_.Exception.Message)" "WARN" }

            # --- 6. Email forwarding to manager (optional) ---
            if ($forward -and $managerUser) {
                try {
                    $managersAccount = "$managerUser@$($cfg.Domain)"
                    Set-Mailbox -Identity $o365Account -ForwardingSMTPAddress $managersAccount -DeliverToMailboxAndForward $true
                    Add-MailboxPermission -Identity "$sam@$($cfg.PrimaryMailDomain)" -User "$managerUser@$($cfg.PrimaryMailDomain)" -AccessRights 'FullAccess' -InheritanceType 'All' -AutoMapping $false | Out-Null
                    WL "Configured forwarding + full-access for manager '$managerUser'."

                    WL "Waiting 30s before Azure sync..."
                    Start-Sleep -Seconds 30
                    WL "Triggering Azure AD delta sync..."
                    $sync = Invoke-Command -ComputerName $cfg.AzureSyncServer -ScriptBlock { Start-ADSyncSyncCycle -PolicyType Delta } -ErrorAction SilentlyContinue
                    if (-not $sync) {
                        WL "A sync may already be running. Waiting 60s then retrying..." "WARN"
                        Start-Sleep -Seconds 60
                        Invoke-Command -ComputerName $cfg.AzureSyncServer -ScriptBlock { Start-ADSyncSyncCycle -PolicyType Delta } -ErrorAction SilentlyContinue
                    }
                } catch { WL "Forwarding step: $($_.Exception.Message)" "WARN" }
            }

            # --- 7. Remove Azure AD (Entra) / M365 group memberships via Microsoft Graph ---
            if ($objectID) {
                try {
                    $ConfirmPreference = 'None'
                    # Get group memberships only (filter out directory roles / admin units)
                    $memberships = Get-MgUserMemberOf -UserId $objectID -All -ErrorAction Stop |
                        Where-Object { $_.AdditionalProperties['@odata.type'] -eq '#microsoft.graph.group' }

                    foreach ($m in $memberships) {
                        $props       = $m.AdditionalProperties
                        $displayName = $props['displayName']
                        $groupId     = $m.Id
                        $groupTypes  = @($props['groupTypes'])
                        $mailEnabled = [bool]$props['mailEnabled']
                        $secEnabled  = [bool]$props['securityEnabled']

                        if ($displayName -eq "All users") { WL "Skipped group: All users"; continue }

                        try {
                            if ($groupTypes -contains "DynamicMembership") {
                                WL "Skipped dynamic group: $displayName"
                            }
                            elseif ($groupTypes -contains "Unified") {
                                # Microsoft 365 group - use Exchange Online cmdlet
                                Remove-UnifiedGroupLinks -Identity $groupId -LinkType Members -Links $o365Account -Confirm:$false -ErrorAction Stop
                                WL "Removed from M365 Group: $displayName"
                            }
                            elseif ($mailEnabled -and -not $secEnabled) {
                                # Mail-enabled (distribution) group - managed in Exchange Online
                                Remove-DistributionGroupMember -Identity $displayName -Member $o365Account -Confirm:$false -ErrorAction Stop
                                WL "Removed from distribution group: $displayName"
                            }
                            else {
                                # Security or M365 security group - remove membership reference via Graph
                                Remove-MgGroupMemberByRef -GroupId $groupId -DirectoryObjectId $objectID -ErrorAction Stop
                                WL "Removed from Entra group: $displayName"
                            }
                        } catch {
                            # Last-ditch fallback: try distribution-group removal in case type detection missed
                            try {
                                Remove-DistributionGroupMember -Identity $displayName -Member $o365Account -Confirm:$false -ErrorAction Stop
                                WL "Removed from mail-enabled/distribution group (fallback): $displayName"
                            } catch { WL "Error removing from group '$displayName': $($_.Exception.Message)" "WARN" }
                        }
                    }
                    WL "Removed from all Entra/M365 groups except 'All users'."
                } catch { WL "Graph group removal: $($_.Exception.Message)" "WARN" }
            } else {
                WL "Skipping Entra group removal - no Graph user object resolved." "WARN"
            }

            # --- 8. Hide mailbox, set delete-by date, disable, revoke tokens ---
            try { Set-ADUser $sam -Replace @{msExchHideFromAddressLists="TRUE"}; WL "Hid mailbox from address lists." } catch { WL "Hide mailbox: $($_.Exception.Message)" "WARN" }
            try {
                $deleteByDate = Get-Date (Get-Date).AddDays(90) -Format D
                Get-ADUser $sam | Set-ADUser -Replace @{description="Delete by $deleteByDate"}
                WL "Set delete-by date: $deleteByDate"
            } catch { WL "Delete-by date: $($_.Exception.Message)" "WARN" }

            Disable-ADAccount -Identity $sam
            WL "AD account disabled."

            if ($objectID) {
                try { Revoke-MgUserSignInSession -UserId $objectID -ErrorAction Stop | Out-Null; WL "Revoked all Office 365 sign-in sessions / refresh tokens." }
                catch { WL "Token revoke: $($_.Exception.Message)" "WARN" }
            }

            # --- 8b. License detection + action (F3/E3/etc.) ---
            # licenseAction: 0 = none, 1 = remove all, 2 = remove all + assign Plan 1
            if ($objectID -and $licenseAction -gt 0) {
                try {
                    # Detect and log what the user currently has assigned
                    $currentSkus = @(Get-MgUserLicenseDetail -UserId $objectID -ErrorAction Stop)
                    if ($currentSkus.Count -gt 0) {
                        foreach ($s in $currentSkus) {
                            $friendly = $cfg.LicenseSkuMap[$s.SkuId]
                            if (-not $friendly) { $friendly = $s.SkuPartNumber }
                            WL "Current license: $friendly ($($s.SkuPartNumber) / $($s.SkuId))"
                        }
                    } else {
                        WL "User has no directly-assigned licenses."
                    }

                    $removeSkuIds = @($currentSkus | Select-Object -ExpandProperty SkuId)

                    if ($licenseAction -eq 2) {
                        # Remove all existing + assign the specified Plan 1 SKU.
                        # Resolve the Plan 1 SkuId against tenant inventory to confirm availability.
                        $targetSkuId = $plan2Sku
                        try {
                            $subs = Get-MgSubscribedSku -All -ErrorAction Stop
                            $match = $subs | Where-Object { $_.SkuId -eq $plan2Sku -or $_.SkuPartNumber -eq $plan2Sku }
                            if ($match) {
                                $targetSkuId = $match.SkuId
                                $avail = $match.PrepaidUnits.Enabled - $match.ConsumedUnits
                                $planFriendly = $cfg.LicenseSkuMap[$targetSkuId]; if (-not $planFriendly) { $planFriendly = $match.SkuPartNumber }
                                WL "Plan 1 target resolved: $planFriendly ($($match.SkuPartNumber)); $avail seat(s) available."
                                if ($avail -le 0) { WL "WARNING: no available seats for the target Plan 1 SKU; assignment may fail." "WARN" }
                            } else {
                                WL "Plan 1 SkuId '$plan2Sku' not found in tenant inventory; attempting assignment as-is." "WARN"
                            }
                        } catch { WL "Could not query subscribed SKUs: $($_.Exception.Message). Attempting assignment as-is." "WARN" }

                        # Don't remove the SKU we're about to assign (in case it's already present)
                        $removeSkuIds = @($removeSkuIds | Where-Object { $_ -ne $targetSkuId })
                        try {
                            Set-MgUserLicense -UserId $objectID -AddLicenses @(@{ SkuId = $targetSkuId }) -RemoveLicenses $removeSkuIds -ErrorAction Stop | Out-Null
                            WL "Removed $($removeSkuIds.Count) license(s) and assigned Plan 1 ($targetSkuId)." "SUCCESS"
                        } catch { WL "License remove+assign failed: $($_.Exception.Message)" "ERROR" }
                    }
                    else {
                        # licenseAction -eq 1: remove all existing licenses only
                        if ($removeSkuIds.Count -gt 0) {
                            try {
                                Set-MgUserLicense -UserId $objectID -AddLicenses @() -RemoveLicenses $removeSkuIds -ErrorAction Stop | Out-Null
                                WL "Removed all $($removeSkuIds.Count) assigned license(s)." "SUCCESS"
                            } catch { WL "License removal failed: $($_.Exception.Message)" "ERROR" }
                        } else {
                            WL "No directly-assigned licenses to remove."
                        }
                    }
                } catch { WL "License step: $($_.Exception.Message)" "WARN" }
            }
            elseif ($licenseAction -gt 0) {
                WL "Skipping license action - no Graph user object resolved." "WARN"
            }

            WL "Waiting 60s then forcing Azure sync..."
            Start-Sleep -Seconds 60
            try { Invoke-Command -ComputerName $cfg.AzureSyncServer -ScriptBlock { Start-ADSyncSyncCycle -PolicyType Delta } -ErrorAction SilentlyContinue } catch {}

            # --- 9. Move to Disabled Users OU ---
            try { Get-ADUser $sam | Move-ADObject -TargetPath $cfg.DisabledUsersOU; WL "Moved to Disabled Users OU." }
            catch { WL "Move OU: $($_.Exception.Message)" "WARN" }

            # --- 10. Okta: find user, remove from groups, deactivate ---
            if ($oktaToken) {
                $headers = @{
                    Authorization  = "SSWS $oktaToken"
                    Accept         = "application/json"
                    "Content-Type" = "application/json"
                }
                try {
                    $oktaUser = Invoke-RestMethod -Uri "$($cfg.OktaDomain)/api/v1/users/$sam" -Headers $headers -Method Get
                    $oktaId = $oktaUser.id
                    WL "Okta user found: $oktaId"

                    try {
                        $oktaGroups = Invoke-RestMethod -Uri "$($cfg.OktaDomain)/api/v1/users/$oktaId/groups" -Headers $headers -Method Get
                        foreach ($g in $oktaGroups) {
                            try {
                                Invoke-RestMethod -Uri "$($cfg.OktaDomain)/api/v1/groups/$($g.id)/users/$oktaId" -Headers $headers -Method Delete | Out-Null
                                WL "Okta: removed from group '$($g.profile.name)'"
                            } catch { WL "Okta group remove '$($g.profile.name)': $($_.Exception.Message)" "WARN" }
                        }
                    } catch { WL "Okta group retrieval: $($_.Exception.Message)" "WARN" }
                    try {
                        Invoke-RestMethod -Uri "$($cfg.OktaDomain)/api/v1/users/$oktaId/lifecycle/deactivate" -Headers $headers -Method Post | Out-Null
                        WL "Okta user deactivated."
                    } catch { WL "Okta deactivate: $($_.Exception.Message)" "WARN" }
                } catch { WL "Okta user lookup failed: $($_.Exception.Message)" "WARN" }
            } else {
                WL "Okta steps skipped (no token)."
            }

            # --- 11. Append to terminated-users CSV ---
            try {
                $csvDir = Split-Path $cfg.TerminatedCsv -Parent
                if (-not (Test-Path $csvDir)) { New-Item -ItemType Directory -Path $csvDir -Force | Out-Null }
                $date = Get-Date
                Add-Content -Path $cfg.TerminatedCsv -Value "$($userInfo.GivenName),$($userInfo.Surname),$o365Account,$date"
                WL "Logged to terminated-users CSV."
            } catch { WL "CSV log: $($_.Exception.Message)" "WARN" }

            # --- 12. Force domain controller sync ---
            try {
                cmd /c "repadmin /syncall $($cfg.DomainController) $($cfg.AdRootDn) /force" | Out-Null
                WL "Forced domain controller sync."
            } catch { WL "DC sync: $($_.Exception.Message)" "WARN" }

            # --- 13. Optional offboarding ticket email ---
            if ($sendTicket -and $cfg.TicketEmail.Enabled) {
                $termedName = $userInfo.Name
                $subject = ($cfg.TicketEmail.SubjectTpl -f $termedName)
                $body = @(
                    "An employee has been offboarded. Please complete any follow-up access removals.",
                    "",
                    "Terminated User Details:",
                    "  Name:        $termedName",
                    "  SAM Account: $sam",
                    "  Email:       $userEmail",
                    "  UPN:         $o365Account",
                    "  Offboarded:  $(Get-Date -Format 'f')",
                    "",
                    "(Generated by the Employee Termination Tool.)"
                ) -join "`r`n"

                try {
                    Send-MailMessage -To $cfg.TicketEmail.To -From $cfg.TicketEmail.From `
                        -Subject $subject -Body $body -SmtpServer $cfg.TicketEmail.SmtpServer -ErrorAction Stop
                    WL "Offboarding ticket email sent to $($cfg.TicketEmail.To) (subject: '$subject')." "SUCCESS"
                } catch {
                    WL "Ticket email FAILED. Open manually -> To: $($cfg.TicketEmail.To), Subject: '$subject'. Error: $($_.Exception.Message)" "ERROR"
                }
            } else {
                WL "Offboarding ticket email skipped (disabled in config or unchecked)."
            }

            WL "=== Termination complete for $sam ===" "SUCCESS"
        }
        catch {
            WL "FATAL: $($_.Exception.Message)" "ERROR"
        }
    }

    # Thread-safe log callback the runspace can invoke
    $logCallback = [action[string,string]]{
        param($m,$lvl)
        $txtLog.Dispatcher.Invoke([action]{
            $stamp = (Get-Date).ToString("HH:mm:ss")
            $txtLog.AppendText("[$stamp][$lvl] $m`r`n")
            $txtLog.ScrollToEnd()
        }, "Normal")
    }

    # Spin up runspace
    $script:Runspace = [runspacefactory]::CreateRunspace()
    $script:Runspace.ApartmentState = "STA"
    $script:Runspace.ThreadOptions  = "ReuseThread"
    $script:Runspace.Open()

    $script:PowerShell = [powershell]::Create()
    $script:PowerShell.Runspace = $script:Runspace
    [void]$script:PowerShell.AddScript($worker).AddArgument($script:SelectedSam).
        AddArgument([bool]$forward).AddArgument($manager).AddArgument($oktaToken).
        AddArgument($licenseAction).AddArgument($plan2Sku).AddArgument($sendTicket).
        AddArgument($script:Config).AddArgument($logCallback)

    $handle = $script:PowerShell.BeginInvoke()

    # Poll for completion on the UI thread without blocking
    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(500)
    $timer.Add_Tick({
        if ($handle.IsCompleted) {
            $timer.Stop()
            try { $script:PowerShell.EndInvoke($handle) } catch { Write-Log "Runspace error: $($_.Exception.Message)" "ERROR" }
            try { $script:PowerShell.Dispose() } catch {}
            try { $script:Runspace.Close() } catch {}
            $script:PowerShell = $null
            $script:Runspace   = $null
            $prog.IsIndeterminate = $false
            $btnSearch.IsEnabled  = $true
            $btnTerminate.IsEnabled = $true
            Write-Log "Ready." "INFO"
        }
    })
    $timer.Start()
})

#--------------------------------------------------------------------
# Startup
#--------------------------------------------------------------------
Add-Type -AssemblyName Microsoft.VisualBasic
Write-Log "Employee Termination Tool started."
Write-Log "Fill in a name and click 'Search AD' to begin."

# Show window
[void]$window.ShowDialog()
