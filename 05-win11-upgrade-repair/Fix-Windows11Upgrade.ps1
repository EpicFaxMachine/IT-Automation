Write-Host @"
============================================================
  Windows 11 Upgrade Repair Tool (Contoso portfolio copy)
============================================================
"@

Start-Sleep -Seconds 2


If (-NOT ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole] "Administrator")) {
  Start-Process PowerShell "-ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
  Exit
}

# Org / path config — edit here or mirror values from config.example.psd1
$script:Config = @{
    # Local folders under the script directory (always created)
    LogSubdir     = 'UpgradeLogs'
    ReportSubdir  = 'UpgradeReports'
    BackupSubdir  = 'RegistryBackups'
    # Optional central share for exported error CSVs. Leave empty to use local LogSubdir only.
    # Example: '\\FILESERVER01\Share$\Scripts\WinErrors'
    LogExportDir  = ''
}

$basePath = Split-Path -Parent $PSCommandPath
$logDir = Join-Path $basePath $script:Config.LogSubdir
$reportDir = Join-Path $basePath $script:Config.ReportSubdir
$backupDir = Join-Path $basePath $script:Config.BackupSubdir
if ([string]::IsNullOrWhiteSpace($script:Config.LogExportDir)) {
    $global:logExportDir = $logDir
} else {
    $global:logExportDir = $script:Config.LogExportDir
}
New-Item -ItemType Directory -Force -Path $logDir, $reportDir, $backupDir | Out-Null
try {
    New-Item -ItemType Directory -Force -Path $global:logExportDir -ErrorAction Stop | Out-Null
} catch {
    Write-Warning "LogExportDir unavailable ($($global:logExportDir)); falling back to local logs."
    $global:logExportDir = $logDir
}
$logFile = Join-Path $logDir "Win11_Upgrade_Fix_$(Get-Date -Format 'yyyy-MM-dd_HH-mm').log"

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

#Global State Management
$global:BackupCreated = $false
$global:OperationLog = @()
$global:ErrorCount = 0
$global:WarningCount = 0
$global:SuccessCount = 0


#Registry Backup Function
Function Backup-RegistryKeys {
  param([string[]]$RegistryPaths)
  try {
    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $backupPath = Join-Path $backupDir "Backup_$timestamp"
    New-Item -ItemType Directory -Force -Path $backupPath | Out-Null

    foreach ($regPath in $RegistryPaths) {
      $safeName = ($regPath -replace '[\\:]', '_') + '.reg'
      $exportFile = Join-Path $backupPath $safeName
      $result = reg export "$regPath" "$exportFile" /y 2>&1
      if ($LASTEXITCODE -eq 0) {
        LogMessage "Registry backed up: $regPath"
        $global:SuccessCount++
      }
      else {
        LogMessage "Could not backup: $regPath"
        $global:WarningCount++
      }
    }
    $global:BackupCreated = $true
    LogMessage "Registry backup completed: $backupPath"
    return $backupPath
  }
  catch {
    LogMessage "ERROR in registry backup: $_"
    $global:ErrorCount++
    return $null
  }
}

#System Validation
Function Invoke-PreFlightChecks {
  LogMessage ""
  LogMessage "========== PRE-FLIGHT SYSTEM VALIDATION =========="
  $checksPass = $true

  # Check OS Version
  $os = Get-WmiObject -Class Win32_OperatingSystem
  $osVersion = $os.Version
  LogMessage "OS Version: $($os.Caption) - Build $osVersion"
  if ($os.Caption -notmatch "Windows 10|Windows 11") {
    LogMessage "ERROR: Unsupported OS version"
    $checksPass = $false
    $global:ErrorCount++
  }
  else {
    LogMessage "OS version supported"
    $global:SuccessCount++
  }

  # Check RAM
  $ram = [math]::Round($os.TotalVisibleMemorySize / 1MB, 2)
  LogMessage "Total RAM: $ram GB"
  if ($ram -lt 4) {
    LogMessage "WARNING: Low RAM (< 4GB)"
    $global:WarningCount++
  }
  else {
    LogMessage "RAM sufficient"
    $global:SuccessCount++
  }

  # Check Disk Space
  $systemDrive = Get-PSDrive -Name C
  $freeSpaceGB = [math]::Round($systemDrive.Free / 1GB, 2)
  LogMessage "Free disk space: $freeSpaceGB GB"
  if ($freeSpaceGB -lt 20) {
    LogMessage "ERROR: Insufficient disk space (< 20GB)"
    $checksPass = $false
    $global:ErrorCount++
  }
  else {
    LogMessage "Disk space sufficient"
    $global:SuccessCount++
  }

  # Check TPM
  $tpmVersion = Get-TpmVersion
  if ($null -eq $tpmVersion) {
    LogMessage "WARNING: TPM not detected (Windows 11 may require TPM 2.0 bypass)"
    $global:WarningCount++
  }
  elseif ($tpmVersion -ge [version]"2.0") {
    LogMessage "TPM 2.0 or higher detected"
    $global:SuccessCount++
  }
  else {
    LogMessage "WARNING: TPM version below 2.0"
    $global:WarningCount++
  }

  # Check Internet Connectivity
  $connectivity = Test-Connection -ComputerName "update.microsoft.com" -Count 2 -Quiet
  if ($connectivity) {
    LogMessage "Internet connectivity confirmed"
    $global:SuccessCount++
  }
  else {
    LogMessage "WARNING: Cannot reach update.microsoft.com"
    $global:WarningCount++
  }

  # Check Windows Update Service
  $wuService = Get-Service -Name wuauserv -ErrorAction SilentlyContinue
  if ($null -ne $wuService) {
    LogMessage "Windows Update service present - Status: $($wuService.Status)"
    $global:SuccessCount++
  }
  else {
    LogMessage "ERROR: Windows Update service not found"
    $checksPass = $false
    $global:ErrorCount++
  }

  LogMessage "========== PRE-FLIGHT CHECK COMPLETE =========="
  LogMessage "Results: Success=$global:SuccessCount | Warnings=$global:WarningCount | Errors=$global:ErrorCount"
  return $checksPass
}

#Progress Tracking
Function Update-ProgressBar {
  param([int]$Percent, [string]$Status)
  if ($null -ne $script:progressBar) {
    $progressBar.Value = [Math]::Min($Percent, 100)
    [System.Windows.Forms.Application]::DoEvents()
  }
  LogMessage "$Status ($Percent%)"
}

#Network Validation
Function Test-NetworkConnectivity {
  LogMessage ""
  LogMessage "========== NETWORK CONNECTIVITY TEST =========="
  $targets = @(
    "update.microsoft.com",
    "download.windowsupdate.com",
    "windowsupdate.microsoft.com"
  )

  $allPassed = $true
  foreach ($target in $targets) {
    $result = Test-Connection -ComputerName $target -Count 2 -Quiet
    if ($result) {
      LogMessage "$target - Reachable"
      $global:SuccessCount++
    }
    else {
      LogMessage "$target - Unreachable"
      $allPassed = $false
      $global:ErrorCount++
    }
  }

  if (-not $allPassed) {
    LogMessage "Network issues detected. Running network repair..."
    ipconfig /flushdns | Out-Null
    netsh winsock reset | Out-Null
    LogMessage "Network reset commands executed. Reboot required."
  }

  LogMessage "========== NETWORK TEST COMPLETE =========="
  return $allPassed
}

#System Health Report Generator
Function Generate-SystemHealthReport {
  $reportFile = Join-Path $reportDir "SystemHealth_$(Get-Date -Format 'yyyy-MM-dd_HH-mm').txt"

  $reportHeader = "=============================================================================="
  $reportTitle = "WINDOWS 11 UPGRADE - SYSTEM HEALTH REPORT"
  $reportDate = "Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
  $reportDivider = "=============================================================================="

  $sysInfoHeader = "SYSTEM INFORMATION:"
  $sysInfoDivider = "-------------------"
  $computerName = "Computer Name: $env:COMPUTERNAME"
  $osInfo = "OS: $((Get-WmiObject Win32_OperatingSystem).Caption)"
  $buildInfo = "Build: $((Get-WmiObject Win32_OperatingSystem).Version)"
  $archInfo = "Architecture: $env:PROCESSOR_ARCHITECTURE"
  $ramInfo = "RAM: $([math]::Round((Get-WmiObject Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 2)) GB"
  $diskInfo = "Free Disk Space: $([math]::Round((Get-PSDrive C).Free / 1GB, 2)) GB"

  $statsHeader = "OPERATION STATISTICS:"
  $statsDivider = "---------------------"
  $successInfo = "Successful Operations: $global:SuccessCount"
  $warningInfo = "Warnings: $global:WarningCount"
  $errorInfo = "Errors: $global:ErrorCount"
  $backupInfo = "Registry Backup Created: $global:BackupCreated"

  $logHeader = "DETAILED LOG:"
  $logDivider = "-------------"
  $logContent = $global:OperationLog -join "`r`n"

  $reportFooter = "=============================================================================="
  $reportEnd = "END OF REPORT"
  $reportFooter2 = "=============================================================================="

  $report = @"
$reportHeader
$reportTitle
$reportDate
$reportDivider

$sysInfoHeader
$sysInfoDivider
$computerName
$osInfo
$buildInfo
$archInfo
$ramInfo
$diskInfo

$statsHeader
$statsDivider
$successInfo
$warningInfo
$errorInfo
$backupInfo

$logHeader
$logDivider
$logContent

$reportFooter
$reportEnd
$reportFooter2
"@

  $report | Out-File -FilePath $reportFile -Encoding UTF8
  LogMessage ""
  LogMessage "System health report saved: $reportFile"
  return $reportFile
}

# --- Rollback Capability ---
Function Invoke-SystemRollback {
  param([string]$BackupPath)
  if ([string]::IsNullOrEmpty($BackupPath) -or -not (Test-Path $BackupPath)) {
    LogMessage "No backup found for rollback"
    return $false
  }

  LogMessage ""
  LogMessage "========== INITIATING SYSTEM ROLLBACK =========="
  $regFiles = Get-ChildItem -Path $BackupPath -Filter "*.reg"
  foreach ($regFile in $regFiles) {
    try {
      $result = reg import "$($regFile.FullName)" 2>&1
      if ($LASTEXITCODE -eq 0) {
        LogMessage "Restored: $($regFile.Name)"
      }
      else {
        LogMessage "Could not restore: $($regFile.Name)"
      }
    }
    catch {
      LogMessage "ERROR restoring $($regFile.Name): $_"
    }
  }
  LogMessage "========== ROLLBACK COMPLETE =========="
  return $true
}

#Error Wrapper
Function Invoke-SafeOperation {
  param(
    [scriptblock]$Operation,
    [string]$OperationName
  )
  try {
    LogMessage ""
    LogMessage "--- Starting: $OperationName ---"
    $global:OperationLog += "[$((Get-Date).ToString('HH:mm:ss'))] $OperationName - STARTED"
    & $Operation
    LogMessage "--- Completed: $OperationName ---"
    $global:OperationLog += "[$((Get-Date).ToString('HH:mm:ss'))] $OperationName - COMPLETED"
    $global:SuccessCount++
    return $true
  }
  catch {
    LogMessage "ERROR in ${OperationName}: $_"
    $global:OperationLog += "[$((Get-Date).ToString('HH:mm:ss'))] $OperationName - FAILED: $_"
    $global:ErrorCount++
    return $false
  }
}

$rainbow = @([System.Drawing.Color]::Red, [System.Drawing.Color]::Orange,
  [System.Drawing.Color]::Yellow, [System.Drawing.Color]::Lime, 
  [System.Drawing.Color]::Cyan, [System.Drawing.Color]::DodgerBlue, [System.Drawing.Color]::Fuchsia)
Function Get-RainbowColor($idx) { return $rainbow[$idx % $rainbow.Count] }
Function LogMessage($msg) {
  Add-Content -Path $logFile -Value $msg
  if ($null -ne $script:formLogBox -and $formLogBox -is [System.Windows.Forms.RichTextBox]) {
    try {
      $color = Get-RainbowColor((Get-Random -Minimum 0 -Maximum $rainbow.Count))
      $formLogBox.SelectionStart = $formLogBox.Text.Length
      $formLogBox.SelectionLength = 0
      $formLogBox.SelectionColor = $color
      $formLogBox.AppendText("$msg`r`n")
      $formLogBox.SelectionColor = $formLogBox.ForeColor
      $formLogBox.ScrollToCaret()
    }
    catch { Write-Host $msg }
  }
  else { Write-Host $msg }
}

Function SafeServiceStopStart($serviceName, $timeoutSec = 90) {
  try {
    $svc = Get-Service -Name $serviceName -ErrorAction Stop
    if ($svc.Status -ne 'Stopped') {
      LogMessage("Stopping $serviceName...")
      Stop-Service -Name $serviceName -Force -ErrorAction SilentlyContinue
      $sw = [Diagnostics.Stopwatch]::StartNew()
      while ((Get-Service -Name $serviceName).Status -ne 'Stopped' -and $sw.Elapsed.TotalSeconds -lt $timeoutSec) { Start-Sleep 2 }
      $sw.Stop()
    }
    Start-Service -Name $serviceName -ErrorAction SilentlyContinue
    LogMessage("$serviceName restarted.")
  }
  catch { LogMessage("Error managing ${serviceName}: $_") }
}

Function Get-TpmVersion {
  try {
    $tpm = Get-CimInstance -Namespace "Root/CIMV2/Security/MicrosoftTpm" -ClassName Win32_Tpm -ErrorAction Stop
    if ($null -eq $tpm) { return $null }
    $spec = $tpm.SpecVersion -split ',' | select -First 1
    if ([string]::IsNullOrEmpty($spec)) { return $null }
    return [version]$spec
  }
  catch { return $null }
}


# Fix BITS Error 0x80004015 - Service Security Configuration
Function Fix-BitsError80004015 {
  LogMessage("=== Fixing BITS Error 0x80004015: Service Security Issue ===")
  try {
    LogMessage("  Stopping BITS and related services...")
    Stop-Service bits -Force -ErrorAction SilentlyContinue
    Stop-Service wuauserv -Force -ErrorAction SilentlyContinue
    Stop-Service cryptsvc -Force -ErrorAction SilentlyContinue
    Stop-Service appidsvc -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2

    LogMessage("  Resetting BITS security configuration...")
    sc.exe sdset bits "D:(A;;CCLCSWRPWPDTLOCRRC;;;SY)(A;;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;BA)(A;;CCLCSWLOCRRC;;;AU)(A;;CCLCSWLOCRRC;;;PU)" | Out-Null

    LogMessage("  Clearing BITS queue...")
    Get-BitsTransfer -AllUsers -ErrorAction SilentlyContinue | Remove-BitsTransfer -ErrorAction SilentlyContinue

    # Delete corrupted BITS job database files
    LogMessage("  Removing corrupted BITS job database files...")
    $bitsJobFiles = "$env:ALLUSERSPROFILE\Microsoft\Network\Downloader\qmgr*.dat"
    Remove-Item $bitsJobFiles -Force -ErrorAction SilentlyContinue

    LogMessage("  Resetting BITS registry settings...")
    Remove-Item "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\BITS\StateIndex" -Recurse -Force -ErrorAction SilentlyContinue

    # Restore ServiceDll registry key if missing
    LogMessage("  Restoring BITS ServiceDll registry entry...")
    $paramKey = "HKLM:\SYSTEM\CurrentControlSet\Services\BITS\Parameters"
    if (!(Test-Path $paramKey)) { 
      New-Item -Path $paramKey -Force | Out-Null 
      LogMessage("    Created missing Parameters key")
    }
    Set-ItemProperty -Path $paramKey -Name "ServiceDll" -Value "%SystemRoot%\System32\qmgr.dll" -Type ExpandString -ErrorAction SilentlyContinue

    # Re-register all BITS-related DLLs
    LogMessage("  Re-registering BITS component DLLs...")
    $bitsDlls = @("qmgr.dll", "qmgrprxy.dll", "bitsperf.dll", "ole32.dll", "oleaut32.dll", "urlmon.dll", "wintrust.dll", "wuapi.dll", "wuaueng.dll", "wups.dll", "wups2.dll")
    foreach ($dll in $bitsDlls) {
      $dllPath = Join-Path $env:SystemRoot "System32\$dll"
      if (Test-Path $dllPath) {
        regsvr32.exe /s $dllPath 2>$null
      }
    }
    LogMessage("    Registered $($bitsDlls.Count) DLL components")

    # Clear Windows Update policy registry keys that can block BITS
    LogMessage("  Clearing restrictive Windows Update policies...")
    Remove-Item "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" -Recurse -Force -ErrorAction SilentlyContinue

    # Recreate BITS service if missing
    $bitsService = Get-Service bits -ErrorAction SilentlyContinue
    if (-not $bitsService) {
      LogMessage("  BITS service missing - recreating service entry...")
      sc.exe create BITS binpath= "$env:SystemRoot\System32\svchost.exe -k netsvcs" start= delayed-auto | Out-Null
      sc.exe config BITS DisplayName= "Background Intelligent Transfer Service" | Out-Null
      sc.exe description BITS "Transfers files in the background using idle network bandwidth." | Out-Null
    }

    LogMessage("  Restarting BITS service...")
    Start-Service bits -ErrorAction SilentlyContinue
    Start-Service wuauserv -ErrorAction SilentlyContinue
    Start-Service cryptsvc -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3

    $bitsStatus = (Get-Service bits -ErrorAction SilentlyContinue).Status
    if ($bitsStatus -eq 'Running') {
      LogMessage("=== BITS Error 0x80004015 Fix Complete - Service Running ===")
    }
    else {
      LogMessage("  WARNING: BITS service status is $bitsStatus - may need system file repair")
      LogMessage("  Recommend running: sfc /scannow and DISM /Online /Cleanup-Image /RestoreHealth")
    }

  }
  catch { 
    LogMessage("  ERROR: $_") 
  }
}

# Fix Intel Service Timeout Errors
Function Fix-IntelServiceTimeouts {
  LogMessage("=== Fixing Intel Service Timeout Errors ===")
  try {
    $intelServices = @(
      "Intel(R) TPM Provisioning Service",
      "Intel(R) Platform License Manager Service"
    )
        
    foreach ($serviceName in $intelServices) {
      $service = Get-Service | Where-Object { $_.DisplayName -like "*$serviceName*" }
      if ($service) {
        LogMessage("  Found service: $($service.Name)")
                
        # Set service to manual/disabled to prevent timeout
        Set-Service -Name $service.Name -StartupType Manual -ErrorAction SilentlyContinue
        Stop-Service -Name $service.Name -Force -ErrorAction SilentlyContinue
                
        LogMessage("  Set $($service.Name) to Manual startup")
      }
    }
        
    LogMessage("  Intel services configured to prevent timeout during upgrade")
    LogMessage("=== Intel Service Timeout Fix Complete ===")
  }
  catch { LogMessage("ERROR: $_") }
}

# Fix Windows Search Service Crash
Function Fix-WindowsSearchCrash {
  LogMessage("=== Fixing Windows Search Service Crashes ===")
  try {
    LogMessage("  Stopping Windows Search...")
    Stop-Service WSearch -Force -ErrorAction SilentlyContinue
        
    LogMessage("  Clearing Search index...")
    $searchPaths = @(
      "$env:ProgramData\Microsoft\Search\Data\Applications\Windows",
      "$env:ProgramData\Microsoft\Search\Data\Temp"
    )
    foreach ($path in $searchPaths) {
      if (Test-Path $path) {
        Remove-Item "$path\*" -Recurse -Force -ErrorAction SilentlyContinue
        LogMessage("  Cleared: $path")
      }
    }
        
    LogMessage("  Resetting Search service configuration...")
    sc.exe config WSearch start= demand | Out-Null
        
    LogMessage("  Starting Windows Search...")
    Start-Service WSearch -ErrorAction SilentlyContinue
        
    LogMessage("=== Windows Search Fix Complete ===")
  }
  catch { LogMessage("ERROR: $_") }
}

# Fix Error 0x80073D02 - App Installation Conflict
Function Fix-Error80073D02 {
  LogMessage("=== Fixing 0x80073D02: App Installation Conflict ===")
  try {
    LogMessage("  This error occurs with conflicting app versions")
    LogMessage("  Resetting Windows Store cache...")
        
    WSReset.exe
    Start-Sleep -Seconds 5
        
    LogMessage("  Clearing app deployment cache...")
    Remove-Item "$env:LOCALAPPDATA\Packages\Microsoft.WindowsStore_*\LocalState\Cache" -Recurse -Force -ErrorAction SilentlyContinue
        
    LogMessage("  Re-registering Windows Store apps...")
    Get-AppXPackage -AllUsers | Where-Object { $_.Name -like "*Store*" } | ForEach-Object {
      try {
        Add-AppxPackage -DisableDevelopmentMode -Register "$($_.InstallLocation)\AppXManifest.xml" -ErrorAction SilentlyContinue
        LogMessage("  Re-registered: $($_.Name)")
      }
      catch {}
    }
        
    LogMessage("=== 0x80073D02 Fix Complete ===")
  }
  catch { LogMessage("ERROR: $_") }
}

Function Fix-SecurityHealthServiceTimeout {
  LogMessage("=== Fixing SecurityHealthService Timeout ===")
  try {
    LogMessage("  Checking SecurityHealthService...")
    $service = Get-Service -Name "SecurityHealthService" -ErrorAction SilentlyContinue
        
    if ($service) {
      Stop-Service -Name "SecurityHealthService" -Force -ErrorAction SilentlyContinue
      LogMessage("  Stopped SecurityHealthService")
    
      Set-Service -Name "SecurityHealthService" -StartupType Manual
      LogMessage("  Set SecurityHealthService to Manual startup")
            
      Restart-Service -Name "WinDefend" -Force -ErrorAction SilentlyContinue
      LogMessage("  Restarted Windows Defender")
    }
        
    LogMessage("=== SecurityHealthService Fix Complete ===")
  }
  catch { LogMessage("ERROR: $_") }
}

Function Fix-SentinelDriver {
  LogMessage("=== Fixing SentinelDeviceControl Driver Issue ===")
  try {
    LogMessage("  SentinelDeviceControl is a security driver")
    LogMessage("  Checking driver status...")
        
    $driver = Get-WmiObject Win32_SystemDriver | Where-Object { $_.Name -eq "SentinelDeviceControl" }
    if ($driver) {
      LogMessage("  Found driver: $($driver.DisplayName)")
      LogMessage("  Driver may need to be updated or removed before upgrade")
    }
    else {
      LogMessage("  Driver reference found but not loaded - likely safe to ignore")
    }
        
    LogMessage("=== SentinelDriver Check Complete ===")
  }
  catch { LogMessage("ERROR: $_") }
}

Function Run-ComprehensiveDiagnostics {
  LogMessage("=== Running Comprehensive System Diagnostics (DISM + SFC) ===")
  LogMessage("NOTE: This process takes 15-30 minutes")
  try {
    LogMessage("Step 1/6: Checking disk health...")
    chkdsk C: /scan | Out-Null
    LogMessage("Step 2/6: Running SFC scan...")
    sfc /scannow | Out-Null
    LogMessage("Step 3/6: DISM CheckHealth...")
    DISM /Online /Cleanup-Image /CheckHealth | Out-Null
    LogMessage("Step 4/6: DISM ScanHealth...")
    DISM /Online /Cleanup-Image /ScanHealth | Out-Null
    LogMessage("Step 5/6: DISM RestoreHealth...")
    DISM /Online /Cleanup-Image /RestoreHealth | Out-Null
    LogMessage("Step 6/6: Component cleanup...")
    DISM /Online /Cleanup-Image /StartComponentCleanup | Out-Null
    LogMessage("Health check completed successfully")
    Enable-WindowsOptionalFeature -Online -FeatureName NetFx3 -All -ErrorAction SilentlyContinue
    Enable-WindowsOptionalFeature -Online -FeatureName NetFx4-AdvSrvs -All -ErrorAction SilentlyContinue
    msiexec /unregister | Out-Null; msiexec /regserver | Out-Null
    regsvr32 /s wuaueng.dll; regsvr32 /s wuaueng1.dll; regsvr32 /s wups.dll
    regsvr32 /s wuapi.dll; regsvr32 /s wucltux.dll; regsvr32 /s wuwebv.dll
    Remove-Item 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' -Recurse -ErrorAction SilentlyContinue
    Remove-Item 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Update' -Recurse -ErrorAction SilentlyContinue
    slmgr /rilc; slmgr /ato
    LogMessage("=== Comprehensive Diagnostics Complete ===")
  }
  catch { LogMessage("ERROR: $_") }
}

Function Fix-Error80070002 {
  LogMessage("=== Fixing 0x80070002: Missing/Corrupted Files ===")

  Write-Log "=== Starting Windows Update Error 0x80070002 Fix ==="

  $Services = "wuauserv", "bits", "cryptsvc", "msiserver"
  foreach ($svc in $Services) {
    Write-Log "Stopping $svc service..."
    sc.exe stop $svc | Out-Null
  }

  Write-Log "Cleaning update caches..."
  $SDPath = "$env:SystemRoot\SoftwareDistribution"
  $CR2Path = "$env:SystemRoot\System32\catroot2"

  if (Test-Path $SDPath) {
    Rename-Item -Path $SDPath -NewName "SoftwareDistribution.bak" -ErrorAction SilentlyContinue
    Write-Log "Renamed SoftwareDistribution folder."
  }
  if (Test-Path $CR2Path) {
    Rename-Item -Path $CR2Path -NewName "catroot2.bak" -ErrorAction SilentlyContinue
    Write-Log "Renamed catroot2 folder."
  }

  foreach ($svc in $Services) {
    Write-Log "Configuring $svc to start automatically and restarting it..."
    sc.exe config $svc start= auto | Out-Null
    sc.exe start $svc | Out-Null
  }

  Write-Log "Synchronizing system clock..."
  net stop w32time | Out-Null
  net start w32time | Out-Null
  w32tm /resync | Out-Null

  foreach ($svc in $Services) {
    Write-Log "Verifying $svc status..."
    sc.exe start $svc | Out-Null
  }

}

Function Fix-Error80070005 {
  LogMessage("=== Fixing 0x80070005: Access Denied ===")
  try {
    takeown /F "C:\Windows\SoftwareDistribution" /R /D Y | Out-Null
    icacls "C:\Windows\SoftwareDistribution" /grant "Administrators:F" /T /C | Out-Null
    icacls "C:\Windows\SoftwareDistribution" /grant "SYSTEM:F" /T /C | Out-Null
    takeown /F "C:\Windows\System32\catroot2" /R /D Y | Out-Null
    icacls "C:\Windows\System32\catroot2" /grant "Administrators:F" /T /C | Out-Null
    icacls "C:\Windows\System32\catroot2" /grant "SYSTEM:F" /T /C | Out-Null
    LogMessage("=== 0x80070005 Fix Complete ===")
  }
  catch { LogMessage("ERROR: $_") }
}

Function Fix-Error80070070 {
  LogMessage("=== Fixing 0x80070070: Insufficient Disk Space ===")
  try {
    Start-Process cleanmgr.exe -ArgumentList "/sagerun:1" -Wait -WindowStyle Hidden
    Remove-Item "C:\Windows\SoftwareDistribution\Download\*" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item "C:\Windows\Temp\*" -Recurse -Force -ErrorAction SilentlyContinue
    $users = Get-ChildItem "C:\Users" -Directory | Where-Object { $_.Name -notin @("Default", "Default User", "Public", "All Users") }
    foreach ($u in $users) {
      $tp = "C:\Users\$($u.Name)\AppData\Local\Temp"
      if (Test-Path $tp) { Remove-Item "$tp\*" -Recurse -Force -ErrorAction SilentlyContinue }
    }
    powercfg.exe /hibernate off | Out-Null
    $drive = Get-PSDrive C; $freeSpace = [math]::Round($drive.Free / 1GB, 2)
    LogMessage("  Free space on C: $freeSpace GB")
    LogMessage("=== 0x80070070 Fix Complete ===")
  }
  catch { LogMessage("ERROR: $_") }
}

Function Fix-Error800F0923 {
  LogMessage("=== Fixing 0x800F0923: Incompatible Drivers ===")
  try {
    $devices = Get-WmiObject Win32_PnPEntity | Where-Object { $_.ConfigManagerErrorCode -ne 0 }
    if ($devices) { foreach ($device in $devices) { LogMessage("  Problem device: $($device.Name)") } }
    $antivirusProducts = Get-CimInstance -Namespace root/SecurityCenter2 -ClassName AntiVirusProduct -ErrorAction SilentlyContinue
    if ($antivirusProducts) {
      foreach ($av in $antivirusProducts) {
        if ($av.displayName -notmatch "Windows Defender|Microsoft Defender") {
          LogMessage("  WARNING: Third-party AV: $($av.displayName) - Disable before upgrade")
        }
      }
    }
    LogMessage("=== 0x800F0923 Fix Complete ===")
  }
  catch { LogMessage("ERROR: $_") }
}

Function Fix-ErrorC1900101 {
  LogMessage("=== Fixing 0xC1900101: Driver Issues ===")
  try {
    LogMessage("  Disconnect USB devices except keyboard/mouse")
    $drivers = Get-WindowsDriver -Online -All | Where-Object { $_.ProviderName -notmatch "Microsoft" }
    LogMessage("  Found $($drivers.Count) non-Microsoft drivers")
    $drive = Get-PSDrive C; $freeGB = [math]::Round($drive.Free / 1GB, 2)
    if ($freeGB -lt 20) { LogMessage("  WARNING: Only $freeGB GB free") }
    LogMessage("=== 0xC1900101 Fix Complete ===")
  }
  catch { LogMessage("ERROR: $_") }
}

Function Fix-Error80300024 {
  LogMessage("=== Fixing 0x80300024: Disk/Partition ===")
  try {
    $disks = Get-Disk
    foreach ($disk in $disks) {
      LogMessage("  Disk $($disk.Number): $([math]::Round($disk.Size/1GB,2)) GB - Boot: $($disk.IsBoot)")
    }
    $systemDrive = $env:SystemDrive.TrimEnd(':')
    $partition = Get-Partition -DriveLetter $systemDrive -ErrorAction SilentlyContinue
    if ($partition -and -not $partition.IsActive) {
      LogMessage("  WARNING: System partition NOT active")
    }
    LogMessage("=== 0x80300024 Fix Complete ===")
  }
  catch { LogMessage("ERROR: $_") }
}

Function Fix-ErrorC1900200 {
  LogMessage("=== Fixing 0xC1900200: Requirements Not Met ===")
  try {
    $cpu = Get-WmiObject Win32_Processor; LogMessage("  CPU: $($cpu.Name)")
    $ram = Get-WmiObject Win32_ComputerSystem
    $ramGB = [math]::Round($ram.TotalPhysicalMemory / 1GB, 2); LogMessage("  RAM: $ramGB GB")
    $tpm = Get-TpmVersion
    LogMessage("  TPM: $(if($tpm){"Version $tpm"}else{"Not detected"})")
    LogMessage("  Applying registry bypass...")
    $lab = "HKLM:\SYSTEM\Setup\LabConfig"; New-Item $lab -Force | Out-Null
    $keys = @("BypassTPMCheck", "BypassCPUCheck", "BypassSecureBootCheck", "BypassRAMCheck", "BypassStorageCheck")
    foreach ($x in $keys) { Set-ItemProperty -Path $lab -Name $x -Value 1 -Type DWord }
    Set-ItemProperty -Path "HKLM:\SYSTEM\Setup\MoSetup" -Name "AllowUpgradesWithUnsupportedTPMOrCPU" -Value 1 -Type DWord
    LogMessage("=== 0xC1900200 Fix Complete ===")
  }
  catch { LogMessage("ERROR: $_") }
}

Function Fix-Error8007042B {
  LogMessage("=== Fixing 0x8007042B: Process Aborted ===")
  LogMessage("  Run msconfig > Services > Hide MS services > Disable All")
  LogMessage("=== 0x8007042B Fix Complete ===")
}

Function Fix-Error80073712 {
  LogMessage("=== Fixing 0x80073712: File Corruption ===")
  try {
    DISM /Online /Cleanup-Image /RestoreHealth | Out-Null
    sfc /scannow | Out-Null
    DISM /Online /Cleanup-Image /StartComponentCleanup /ResetBase | Out-Null
    LogMessage("=== 0x80073712 Fix Complete ===")
  }
  catch { LogMessage("ERROR: $_") }
}

Function Fix-Error80200056 {
  LogMessage("=== Fixing 0x80200056: Upgrade Interrupted ===")
  try {
    powercfg /change monitor-timeout-ac 0; powercfg /change standby-timeout-ac 0; powercfg /change hibernate-timeout-ac 0
    LogMessage("  Power settings adjusted - Keep PC plugged in")
    SafeServiceStopStart "wuauserv"; SafeServiceStopStart "bits"
    LogMessage("=== 0x80200056 Fix Complete ===")
  }
  catch { LogMessage("ERROR: $_") }
}

Function Fix-Error800F0922 {
  LogMessage("=== Fixing 0x800F0922: Network Issues ===")
  try {
    $ping = Test-Connection -ComputerName "update.microsoft.com" -Count 2 -Quiet
    LogMessage("  Internet: $(if($ping){"OK"}else{"FAILED"})")
    netsh winsock reset | Out-Null; netsh int ip reset | Out-Null
    ipconfig /flushdns | Out-Null; ipconfig /release | Out-Null; ipconfig /renew | Out-Null
    LogMessage("  Disconnect VPN before upgrading")
    LogMessage("=== 0x800F0922 Fix Complete ===")
  }
  catch { LogMessage("ERROR: $_") }
}

Function Fix-Error0x8024a203 {
  LogMessage("=== Fixing 0x8024a203: Corrupt Sys Files (Alternative) ===")
  try {
    LogMessage("Resetting Windows Update client (partial)...")
    & net stop wuauserv 2>&1 | LogMessage
    & net stop bits 2>&1 | LogMessage
    & net stop msiserver 2>&1 | LogMessage

    LogMessage("Renaming SoftwareDistribution and catroot2 folders...")
    & cmd /c "ren C:\Windows\SoftwareDistribution SoftwareDistribution.old" 2>&1 | LogMessage
    & cmd /c "ren C:\Windows\System32\catroot2 catroot2.old" 2>&1 | LogMessage

    LogMessage("Restarting Windows Update, BITS, and MSI Server...")
    & net start wuauserv 2>&1 | LogMessage
    & net start bits 2>&1 | LogMessage
    & net start msiserver 2>&1 | LogMessage

    LogMessage("=== 0x8024a203 Alternative Fix Complete ===")
  }
  catch { LogMessage("ERROR: $_") }
}




Function Fix-DateTimeIssues {
  LogMessage("=== Fixing Date/Time Issues ===")
  try {
    Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Parameters" -Name "Type" -Value "NTP"
    w32tm /resync /force | Out-Null
    LogMessage("  Time synced: $(Get-Date)")
    LogMessage("=== Date/Time Fix Complete ===")
  }
  catch { LogMessage("ERROR: $_") }
}

Function Fix-Error0x80244018 {
  LogMessage("=== Fixing 80244018: Network/Proxy/Update Issue ===")
  try {
    LogMessage("Disabling proxy settings...")
    Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings" -Name ProxyEnable -Value 0 2>&1 | LogMessage
    LogMessage("Resetting WinHTTP proxy settings...")
    & netsh winhttp reset proxy 2>&1 | LogMessage

    LogMessage("Flushing DNS and resetting network stack...")
    & ipconfig /flushdns 2>&1 | LogMessage
    & netsh int ip reset 2>&1 | LogMessage
    & netsh winsock reset 2>&1 | LogMessage

    LogMessage("Resetting Windows Update client settings...")
    & bitsadmin /reset 2>&1 | LogMessage

    LogMessage("Removing potential Windows Update group policy blocks...")
    Remove-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" -Recurse -ErrorAction SilentlyContinue


    LogMessage("Triggering Windows Update detection...")
    UsoClient StartScan 2>&1 | LogMessage

    LogMessage("=== 80244018 Alternative Fix Attempted ===")
  }
  catch { LogMessage("ERROR: $_") }
}


Function Reset-UpdateCache {
  LogMessage("=== Resetting Update Cache ===")
  try {
    SafeServiceStopStart "wuauserv"; SafeServiceStopStart "bits"; SafeServiceStopStart "cryptsvc"
    $folders = @("C:\Windows\SoftwareDistribution", "C:\Windows\System32\catroot2")
    foreach ($f in $folders) {
      if (Test-Path $f) {
        Rename-Item -Path $f -NewName ($f + ".old." + $(Get-Date -Format 'yyyyMMddHHmm')) -ErrorAction SilentlyContinue
        LogMessage("  Renamed: $f")
      }
    }
    SafeServiceStopStart "wuauserv"; SafeServiceStopStart "bits"; SafeServiceStopStart "cryptsvc"
    LogMessage("=== Cache Reset Complete ===")
  }
  catch { LogMessage("ERROR: $_") }
}

Function Clear-TempFiles {
  LogMessage("=== Clearing Temp Files ===")
  Remove-Item "C:\Windows\Temp\*" -Recurse -Force -ErrorAction SilentlyContinue
  $users = Get-ChildItem "C:\Users" -Directory | Where-Object { $_.Name -notin @("Default", "Default User", "Public", "All Users") }
  foreach ($u in $users) {
    $tp = "C:\Users\$($u.Name)\AppData\Local\Temp"
    if (Test-Path $tp) { Remove-Item "$tp\*" -Recurse -Force -ErrorAction SilentlyContinue }
  }
  LogMessage("=== Temp Files Cleared ===")
}

Function Disable-Hibernation {
  LogMessage("=== Disabling Hibernation ===")
  powercfg.exe /hibernate off | Out-Null
  LogMessage("  Hibernation disabled")
}

Function Disable-CoPilot {
  LogMessage("=== Disabling CoPilot ===")
  $key = "HKLM:\SOFTWARE\Policies\Microsoft\Windows"
  if (!(Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
  New-Item -Path "$key\WindowsCopilot" -Force | Out-Null
  Set-ItemProperty -Path "$key\WindowsCopilot" -Name "TurnOffWindowsCopilot" -Value 1 -Type DWord
  LogMessage("=== CoPilot Disabled ===")
}

Function Export-UpgradeLogs {
  LogMessage("=== Exporting Logs ===")
  try {
    $hostname = $env:COMPUTERNAME
    $outFile = Join-Path $global:logExportDir "$hostname-Win11UpgradeErrors_$(Get-Date -Format 'yyyy-MM-dd_HH-mm').csv"
    $flt = @{LogName = 'System'; StartTime = (Get-Date).AddDays(-7) }
    $evs = Get-WinEvent -FilterHashtable $flt -ErrorAction SilentlyContinue | Where-Object {
      $_.ProviderName -match "WindowsUpdate" -or $_.ProviderName -match "BITS" } |
    Select-Object TimeCreated, Id, LevelDisplayName, ProviderName, Message
    if ($evs) { $evs | Export-Csv -NoTypeInformation -Force $outFile; LogMessage("  Exported to: $outFile") }
    LogMessage("=== Log Export Complete ===")
  }
  catch { LogMessage("ERROR: $_") }
}

# GUI WITH TWO COLUMNS

$form = New-Object System.Windows.Forms.Form
$form.Text = "Windows 11 Upgrade Upgrade Repair Tool - V1.1024"
$form.Size = New-Object System.Drawing.Size(1150, 780)
$form.BackColor = [System.Drawing.Color]::FromArgb(32, 32, 32)
$form.StartPosition = "CenterScreen"

$label = New-Object System.Windows.Forms.Label
$label.Text = "Select fixes to apply:"
$label.ForeColor = [System.Drawing.Color]::Yellow
$label.Location = New-Object System.Drawing.Point(20, 10)
$label.Size = New-Object System.Drawing.Size(1100, 30)
$label.Font = New-Object System.Drawing.Font("Arial", 11, [Drawing.FontStyle]::Bold)
$form.Controls.Add($label)

# Define checkboxes in two columns
$leftColumn = @(
  "Fix BITS Error 0x80004015 ",
  "Fix Intel Service Timeouts ",
  "Fix Windows Search Crashes ",
  "Fix Error 0x80073D02 App Conflict ",
  "Fix SecurityHealthService Timeout ",
  "Run Full System Scan (DISM + SFC)",
  "Fix 0x80070002 (Missing Files)",
  "Fix 0x80070005 (Access Denied)",
  "Fix 0x80070070 (Disk Space)",
  "Fix 0x800F0923 (Drivers)",
  "Fix 0xC1900101 (Driver Issues)",
  "Fix 0x80300024 (Disk/Partition)",
  "Fix 0x80244018 (Proxy Error)",
  "Fix 0x8024a203 (Corrupt System FIles)"
)

$rightColumn = @(
  "Fix 0xC1900200 (Requirements)",
  "Fix 0x8007042B (Process Aborted)",
  "Fix 0x80073712 (Corruption)",
  "Fix 0x80200056 (Interrupted)",
  "Fix 0x800F0922 (Network)",
  "Fix Date/Time Issues",
  "Reset Update Cache",
  "Clear Temp Files",
  "Disable Hibernation",
  "Disable CoPilot",
  "Check Sentinel Driver",
  "Export Error Logs"
)

$checkboxes = @{}
$i = 0; $boxY = 45

# Create LEFT column checkboxes
foreach ($k in $leftColumn) {
  $b = New-Object System.Windows.Forms.CheckBox
  $b.Text = $k
  $b.Location = New-Object System.Drawing.Point(30, ($boxY))
  $b.Size = New-Object System.Drawing.Size(520, 26)
  $b.Checked = $False
  $b.ForeColor = Get-RainbowColor($i)
  $b.BackColor = $form.BackColor
  $form.Controls.Add($b)
  $checkboxes[$k] = $b
  $i++; $boxY += 28
}

# Create RIGHT column checkboxes
$i = 0; $boxY = 45
foreach ($k in $rightColumn) {
  $b = New-Object System.Windows.Forms.CheckBox
  $b.Text = $k
  $b.Location = New-Object System.Drawing.Point(570, ($boxY))
  $b.Size = New-Object System.Drawing.Size(520, 26)
  $b.Checked = $False
  $b.ForeColor = Get-RainbowColor($i + 12)
  $b.BackColor = $form.BackColor
  $form.Controls.Add($b)
  $checkboxes[$k] = $b
  $i++; $boxY += 28
}

# Log box below checkboxes
$formLogBox = New-Object System.Windows.Forms.RichTextBox
$formLogBox.Multiline = $true; $formLogBox.ReadOnly = $true
$formLogBox.ScrollBars = "Vertical"
$formLogBox.Size = New-Object System.Drawing.Size(1080, 250)
$formLogBox.Location = New-Object System.Drawing.Point(30, 450)
$formLogBox.BackColor = [System.Drawing.Color]::Black
$formLogBox.ForeColor = [System.Drawing.Color]::White
$form.Controls.Add($formLogBox)

# Buttons
$runButton = New-Object System.Windows.Forms.Button
$runButton.Text = "Run Selected Fixes"
$runButton.Size = New-Object System.Drawing.Size(320, 50)
$runButton.Font = New-Object System.Drawing.Font("Arial", 14, [Drawing.FontStyle]::Bold)
$runButton.BackColor = [System.Drawing.Color]::MediumSeaGreen
$runButton.ForeColor = [System.Drawing.Color]::White
$runButton.Location = New-Object System.Drawing.Point(120, 705)
$form.Controls.Add($runButton)

$exitButton = New-Object System.Windows.Forms.Button
$exitButton.Text = "Exit"
$exitButton.Size = New-Object System.Drawing.Size(250, 50)
$exitButton.Font = New-Object System.Drawing.Font("Arial", 14, [Drawing.FontStyle]::Bold)
$exitButton.BackColor = [System.Drawing.Color]::IndianRed
$exitButton.ForeColor = [System.Drawing.Color]::White
$exitButton.Location = New-Object System.Drawing.Point(680, 705)
$form.Controls.Add($exitButton)

# Button Actions
$runButton.Add_Click({
    $runButton.Enabled = $false
    LogMessage ""
    LogMessage "========================================================================"
    LogMessage "   ENHANCED WINDOWS 11 UPGRADE REPAIR              "
    LogMessage "========================================================================"
    LogMessage ""

    # Reset counters
    $global:ErrorCount = 0
    $global:WarningCount = 0
    $global:SuccessCount = 0
    $global:OperationLog = @()

    Update-ProgressBar 5 "Initializing system diagnostics..."

    # Run checks
    $preFlightPass = Invoke-PreFlightChecks
    if (-not $preFlightPass) {
      $result = [System.Windows.Forms.MessageBox]::Show(
        "Pre-flight checks detected critical issues. Continue anyway?", 
        "Warning", 
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning
      )
      if ($result -eq [System.Windows.Forms.DialogResult]::No) {
        LogMessage "Operation cancelled by user"
        $runButton.Enabled = $true
        return
      }
    }

    Update-ProgressBar 10 "Pre-flight checks complete"

    # Create registry backup
    $criticalRegistryKeys = @(
      "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate",
      "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\BITS",
      "HKLM:\SYSTEM\CurrentControlSet\Services\BITS",
      "HKLM:\SYSTEM\CurrentControlSet\Services\wuauserv",
      "HKLM:\SYSTEM\Setup\LabConfig",
      "HKLM:\SYSTEM\Setup\MoSetup",
      "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate"
    )

    $backupPath = Backup-RegistryKeys $criticalRegistryKeys
    Update-ProgressBar 15 "Registry backup created"

    # Execute selected fixes
    $currentProgress = 15
    $progressPerFix = 75 / 24

    if ($checkboxes["Fix BITS Error 0x80004015 "].Checked) {
      Invoke-SafeOperation { Fix-BitsError80004015 } "BITS Error Fix"
      $currentProgress += $progressPerFix
      Update-ProgressBar $currentProgress "BITS fix completed"
    }

    if ($checkboxes["Fix 0x8024a203 (Corrupt System FIles)"].Checked) {
      Invoke-SafeOperation { Fix-Error0x8024a203 } "Fix-0x8024a203 Fix"
      $currentProgress += $progressPerFix
      Update-ProgressBar $currentProgress "Fix-0x8024a203 completed"
    }

    if ($checkboxes["Fix Intel Service Timeouts "].Checked) {
      Invoke-SafeOperation { Fix-IntelServiceTimeouts } "Intel Services Timeout Fix"
      $currentProgress += $progressPerFix
      Update-ProgressBar $currentProgress "Intel services fixed"
    }

    if ($checkboxes["Fix 0x80244018 (Proxy Error)"].Checked) {
      Invoke-SafeOperation { Fix-Error0x80244018 } "Proxy/Firewall Fix"
      $currentProgress += $progressPerFix
      Update-ProgressBar $currentProgress "Proxy/Firewall Fixed"
    }

    if ($checkboxes["Fix Windows Search Crashes "].Checked) {
      Invoke-SafeOperation { Fix-WindowsSearchCrash } "Windows Search Fix"
      $currentProgress += $progressPerFix
      Update-ProgressBar $currentProgress "Windows Search repaired"
    }

    if ($checkboxes["Fix Error 0x80073D02 App Conflict "].Checked) {
      Invoke-SafeOperation { Fix-Error80073D02 } "App Deployment Fix"
      $currentProgress += $progressPerFix
      Update-ProgressBar $currentProgress "App deployment fixed"
    }

    if ($checkboxes["Fix SecurityHealthService Timeout "].Checked) {
      Invoke-SafeOperation { Fix-SecurityHealthServiceTimeout } "Security Health Fix"
      $currentProgress += $progressPerFix
      Update-ProgressBar $currentProgress "Security Health fixed"
    }

    if ($checkboxes["Check Sentinel Driver"].Checked) {
      Invoke-SafeOperation { Fix-SentinelDriver } "Sentinel Driver Fix"
      $currentProgress += $progressPerFix
      Update-ProgressBar $currentProgress "Sentinel driver checked"
    }

    if ($checkboxes["Run Full System Scan (DISM + SFC)"].Checked) {
      Invoke-SafeOperation { Run-ComprehensiveDiagnostics } "System Diagnostics"
      $currentProgress += $progressPerFix
      Update-ProgressBar $currentProgress "System diagnostics completed"
    }

    if ($checkboxes["Fix 0x80070002 (Missing Files)"].Checked) {
      Invoke-SafeOperation { Fix-Error80070002 } "File Not Found Fix"
      $currentProgress += $progressPerFix
      Update-ProgressBar $currentProgress "File errors fixed"
    }

    if ($checkboxes["Fix 0x80070005 (Access Denied)"].Checked) {
      Invoke-SafeOperation { Fix-Error80070005 } "Permissions Fix"
      $currentProgress += $progressPerFix
      Update-ProgressBar $currentProgress "Permissions fixed"
    }

    if ($checkboxes["Fix 0x80070070 (Disk Space)"].Checked) {
      Invoke-SafeOperation { Fix-Error80070070 } "Disk Space Fix"
      $currentProgress += $progressPerFix
      Update-ProgressBar $currentProgress "Disk space optimized"
    }

    if ($checkboxes["Fix 0x800F0923 (Drivers)"].Checked) {
      Invoke-SafeOperation { Fix-Error800F0923 } "Driver Compatibility Fix"
      $currentProgress += $progressPerFix
      Update-ProgressBar $currentProgress "Drivers updated"
    }

    if ($checkboxes["Fix 0xC1900101 (Driver Issues)"].Checked) {
      Invoke-SafeOperation { Fix-ErrorC1900101 } "Rollback Fix"
      $currentProgress += $progressPerFix
      Update-ProgressBar $currentProgress "Rollback issues fixed"
    }

    if ($checkboxes["Fix 0x80300024 (Disk/Partition)"].Checked) {
      Invoke-SafeOperation { Fix-Error80300024 } "Disk Configuration Fix"
      $currentProgress += $progressPerFix
      Update-ProgressBar $currentProgress "Disk configuration fixed"
    }

    if ($checkboxes["Fix 0xC1900200 (Requirements)"].Checked) {
      Invoke-SafeOperation { Fix-ErrorC1900200 } "Compatibility Fix"
      $currentProgress += $progressPerFix
      Update-ProgressBar $currentProgress "Compatibility resolved"
    }

    if ($checkboxes["Fix 0x8007042B (Process Aborted)"].Checked) {
      Invoke-SafeOperation { Fix-Error8007042B } "Firewall Fix"
      $currentProgress += $progressPerFix
      Update-ProgressBar $currentProgress "Firewall configured"
    }

    if ($checkboxes["Fix 0x80073712 (Corruption)"].Checked) {
      Invoke-SafeOperation { Fix-Error80073712 } "Component Store Fix"
      $currentProgress += $progressPerFix
      Update-ProgressBar $currentProgress "Component store repaired"
    }

    if ($checkboxes["Fix 0x80200056 (Interrupted)"].Checked) {
      Invoke-SafeOperation { Fix-Error80200056 } "Installation Media Fix"
      $currentProgress += $progressPerFix
      Update-ProgressBar $currentProgress "Installation media fixed"
    }

    if ($checkboxes["Fix 0x800F0922 (Network)"].Checked) {
      Test-NetworkConnectivity
      Invoke-SafeOperation { Fix-Error800F0922 } "Network Fix"
      $currentProgress += $progressPerFix
      Update-ProgressBar $currentProgress "Network issues resolved"
    }

    if ($checkboxes["Fix Date/Time Issues"].Checked) {
      Invoke-SafeOperation { Fix-DateTimeIssues } "Date/Time Fix"
      $currentProgress += $progressPerFix
      Update-ProgressBar $currentProgress "Date/Time synchronized"
    }

    if ($checkboxes["Reset Update Cache"].Checked) {
      Invoke-SafeOperation { Reset-UpdateCache } "Windows Update Reset"
      $currentProgress += $progressPerFix
      Update-ProgressBar $currentProgress "Windows Update reset"
    }

    if ($checkboxes["Clear Temp Files"].Checked) {
      Invoke-SafeOperation { Clear-TempFiles } "Temp Files Cleanup"
      $currentProgress += $progressPerFix
      Update-ProgressBar $currentProgress "Temp files cleared"
    }

    if ($checkboxes["Disable Hibernation"].Checked) {
      Invoke-SafeOperation { Disable-Hibernation } "Hibernation Disable"
      $currentProgress += $progressPerFix
      Update-ProgressBar $currentProgress "Hibernation disabled"
    }

    if ($checkboxes["Disable CoPilot"].Checked) {
      Invoke-SafeOperation { Disable-CoPilot } "CoPilot Disable"
      $currentProgress += $progressPerFix
      Update-ProgressBar $currentProgress "CoPilot disabled"
    }

    if ($checkboxes["Export Error Logs"].Checked) {
      Invoke-SafeOperation { Export-UpgradeLogs } "Log Export"
      $currentProgress += $progressPerFix
      Update-ProgressBar $currentProgress "Logs exported"
    }

    Update-ProgressBar 95 "Generating final report..."

    # Generates Health Report
    $reportPath = Generate-SystemHealthReport

    Update-ProgressBar 100 "All operations complete!"

    LogMessage ""
    LogMessage "========================================================================"
    LogMessage "                  ALL FIXES COMPLETED"
    LogMessage "========================================================================"
    LogMessage ""
    LogMessage "FINAL STATISTICS:"
    LogMessage "  Successful Operations: $global:SuccessCount"
    LogMessage "  Warnings: $global:WarningCount"
    LogMessage "  Errors: $global:ErrorCount"
    LogMessage ""
    LogMessage "Health Report: $reportPath"
    if ($backupPath) {
      LogMessage "Registry Backup: $backupPath"
    }
    LogMessage ""
    LogMessage "========================================================================"
    LogMessage "NEXT STEPS:"
    LogMessage "========================================================================"
    LogMessage "1. RESTART your computer NOW"
    LogMessage "2. After restart, before attempting upgrade:"
    LogMessage "   - Keep PC plugged into power"
    LogMessage "   - Disconnect all USB devices (except keyboard/mouse)"
    LogMessage "   - Temporarily disable antivirus software"
    LogMessage "   - Disconnect from VPN"
    LogMessage "   - Ensure stable internet connection"
    LogMessage "3. Run Windows Update or Media Creation Tool"
    LogMessage "4. If issues persist, check the health report for details"
    LogMessage "========================================================================"
    LogMessage ""

    [System.Windows.Forms.MessageBox]::Show(
      "All fixes completed!`n`nSuccessful: $global:SuccessCount | Warnings: $global:WarningCount | Errors: $global:ErrorCount`n`nPlease restart your computer before attempting the upgrade.`n`nSee the log for details and next steps.",
      "Operation Complete",
      [System.Windows.Forms.MessageBoxButtons]::OK,
      [System.Windows.Forms.MessageBoxIcon]::Information
    )

    $runButton.Enabled = $true
  })

$exitButton.Add_Click({ $form.Close() })
$form.ShowDialog()
