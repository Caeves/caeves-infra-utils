#Requires -RunAsAdministrator
# -----------------------------------------------------------------------------------------------------
# Setup-CAEVESInfrastructure.ps1
# Single script the customer runs to provision and configure a Windows Server 2025 host for
# CAEVES hybrid / on-prem deployment. No Hyper-V template image is built or exported - the
# customer provisions their own server and runs this script directly on it.
#
# Distribution: this script and ConfigParameters.json are stored in the customer's storage account.
# Download both into the same folder on the server, then run this script as Administrator.
#
# Parameters (Azure service principal). Any that are not supplied are prompted for on the first run and
# saved to C:\CAEVES\Config\spn-settings.json (client secret encrypted with Windows DPAPI for the current account),
# so later runs do not ask again. Passing a value on the command line replaces the saved one:
#   -TenantId      Azure tenant ID (GUID)
#   -ClientId      Service principal application (client) ID (GUID)
#   -ClientSecret  Service principal client secret (SecureString)
#   -ConfigureOnly Skip the prerequisites and run only the CAEVES configuration. Used to resume a
#                  run, and by the script itself to continue in PowerShell 7. SPN details are
#                  taken from the AZURE_* environment variables when not supplied.
#   -ResetProgress Forget the recorded progress and run every step again from the start.
#   -FromStep      Run again from the named step onwards (see $Script:Phase1Steps / $Script:Phase2Steps).
#   -NoRestart     Do not restart the server after the prerequisites. The script stops instead (exit code 3010);
#                  restart, sign in and run it again to continue with the CAEVES configuration.
#
# Restart: after the prerequisites the server restarts (30 seconds' notice, Ctrl+C cancels). A one-time scheduled
# task then continues the setup in PowerShell 7 when the same administrator signs in again.
#
# Generated files: everything the script creates is kept in C:\CAEVES\Config (staged ConfigParameters.json,
# setup-state.json, spn-settings.json, disk-layout.json, boot.complete). Logs are in C:\CAEVES\Logs.
#
# Progress: every completed step is recorded in C:\CAEVES\Config\setup-state.json. If a run fails, run the
# script again the same way and it resumes at the step that failed.
#
# Merged from:
#   - Build-CAEVESHyperVImage-2025.ps1   (server prerequisites - sysprep/image-capture steps removed)
#   - the earlier Setup-HybridConfiguration.ps1 v1.1 (CAEVES configuration - Archana Patil)
#
# Domain join is the customer's own responsibility and is out of scope for this script.
# -----------------------------------------------------------------------------------------------------

[CmdletBinding()]
param (
    [string]$TenantId,
    [string]$ClientId,
    [SecureString]$ClientSecret,
    [switch]$ConfigureOnly,
    [switch]$ResetProgress,
    [string]$FromStep,
    [switch]$NoRestart
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# =============================================
# SCRIPT-SCOPED CONSTANTS (CAEVES configuration)
# =============================================
$Script:EnvironmentName = $null   # resolved from ConfigParameters.json by Resolve-CaevesEnvironment

$Script:CaevesRoot = 'C:\CAEVES'
$Script:LogPath = 'C:\CAEVES\Logs'
# Every file the script generates (staged config, progress, saved credentials, disk choice, marker) lives here.
$Script:ConfigPath = 'C:\CAEVES\Config'
$Script:ConfigFile = 'C:\CAEVES\Config\ConfigParameters.json'
$Script:LogFile = $Script:LogPath + '\OnPrem-Deployment.log'
$Script:BootMarker = 'C:\CAEVES\Config\boot.complete'
$Script:DiskLayoutFile = 'C:\CAEVES\Config\disk-layout.json'
$Script:StateFile = 'C:\CAEVES\Config\setup-state.json'
$Script:SpnFile = 'C:\CAEVES\Config\spn-settings.json'
$Script:TempPath = 'C:\Temp'
$Script:CacheDirPath = 'G:\Cache'
$Script:MaxSnapshotCount = 500
$Script:MetadataVolume = 'F:\'

$Script:SnapshotsLabel = 'Snapshots'
$Script:MaxSize = 'UNBOUNDED'
$Script:MoveExistingShadowStorage = $false

# Checkpointed setup steps, in run order. A re-run skips the steps recorded as completed in $Script:StateFile.
# Step names are stored in that file, so keep them stable even if the functions behind them are renamed.
$Script:Phase1Steps = @('HardenSystem', 'RemoveWirelessLAN', 'SetWallpaper', 'UpdateDefaultWallpaper',
    'InstallDependencies', 'InstallCaevesSoftware', 'WindowsUpdate', 'DesktopShortcuts', 'RestartForPhase2')
$Script:Phase2Steps = @('DataDisks', 'MetadataPermissions', 'SetEnvironment', 'AgentConfiguration', 'StartServices',
    'VssMaxShadowCopies', 'BillingInit', 'VssShadowStorage', 'SnapshotTasks')

# Built from ConfigParameters.json on every run (never stored in the state file).
$Script:StorageConnectionString = $null

# One-time scheduled task that continues the setup in PowerShell 7 after the restart between the two phases.
$Script:ResumeTaskName = 'CAEVES-Setup-Resume'
$Script:PwshPath = 'C:\Program Files\PowerShell\7\pwsh.exe'
$Script:RestartRequested = $false

# Populated by Import-CaevesConfiguration from ConfigParameters.json
$Script:StorageAccountName = $null
$Script:StorageAccountKey = $null
$Script:StorageAccountResourceId = $null
$Script:ContainerName = $null
$Script:SnapshotsContainerName = $null
$Script:ConfigContainerName = $null
$Script:TableName = $null
$Script:ProcessTableName = $null
$Script:CaevesConfigTableName = $null
$Script:queueName = $null
$Script:SaasOfferId = $null
$Script:SaasSubscriptionId = $null
$Script:PurchaserId = $null
$Script:AzureSubscriptionId = $null
$Script:Location = $null
$Script:MetaSnapFrequency = $null
$Script:EnableDailySnapshot = $null
$Script:MetaSnapDailyTime = $null
$Script:EnableWeeklySnapshot = $null
$Script:MetaSnapWeeklyDay = $null
$Script:MetaSnapWeeklyTime = $null
$Script:EnableMonthlySnapshot = $null
$Script:MetaSnapMonthlyWeekday = $null
$Script:MetaSnapMonthlyTime = $null
$Script:MetaForceSnapMonthly = $null
# Optional: serial numbers of the two CAEVES data disks. Needed when the server has more than two empty disks.
$Script:FixedDiskSerial = $null
$Script:SliderDiskSerial = $null

enum EnvironmentType {
    Development
    Staging
    Production
}

# =============================================
# FUNCTION DEFINITIONS - Server prerequisites
# =============================================

function Set-SystemHardening {
    Write-Log "Hardening System"
    fsutil behavior set disableencryption 1
    reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" /v EnableLUA /t REG_DWORD /d 0 /f
}

function Remove-WirelessLANService {
    Write-Log "Removing Wireless LAN Service feature"

    # Check if the feature is installed before attempting removal
    $feature = Get-WindowsFeature -Name "Wireless-Networking" -ErrorAction SilentlyContinue
    if ($feature -and $feature.Installed) {
        Write-Log "  Wireless LAN Service is installed - removing..."
        Remove-WindowsFeature -Name "Wireless-Networking" -Remove
        Write-Log "  Wireless LAN Service removed successfully"
    }
    else {
        # Fallback: try via DISM for the WlanSvc capability
        Write-Log "  Feature not found via Get-WindowsFeature - checking via DISM..."
        $dismResult = dism /Online /Get-FeatureInfo /FeatureName:WirelessNetworking 2>&1
        if ($dismResult -match "State : Enabled") {
            Write-Log "  Disabling Wireless Networking via DISM..."
            dism /Online /Disable-Feature /FeatureName:WirelessNetworking /Remove
            Write-Log "  Wireless Networking disabled and payload removed via DISM"
        }
        else {
            Write-Log "  Wireless LAN Service is not installed - skipping"
        }
    }

    # Also stop and disable the WlanSvc service if it exists
    $wlanSvc = Get-Service -Name "WlanSvc" -ErrorAction SilentlyContinue
    if ($wlanSvc) {
        Write-Log "  Stopping and disabling WlanSvc service..."
        Stop-Service -Name "WlanSvc" -Force -ErrorAction SilentlyContinue
        Set-Service -Name "WlanSvc" -StartupType Disabled -ErrorAction SilentlyContinue
        Write-Log "  WlanSvc service disabled"
    }
}

function Set-WallpaperAndUI {
    Write-Log "Configuring Wallpaper"
    $wallpaper = "C:\WINDOWS\OEM\CAEVES-wallpaper.jpg"
    Invoke-WebRequest -Uri "https://caeveswebassets.blob.core.windows.net/caevesbuildimage/CAEVES-Windows-BG-2025-small.jpg" -OutFile $wallpaper
    Set-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name Wallpaper -Value $wallpaper
    Set-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name WallpaperStyle -Value 0
    Set-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name TileWallpaper -Value 0
    RUNDLL32.EXE user32.dll, UpdatePerUserSystemParameters
}

function Update-DefaultWallpaper {
    Write-Log "Updating default Windows wallpapers"

    $CustomWallpaper = "C:\Windows\OEM\CAEVES-wallpaper.jpg"
    $WallpaperMainFolder = "C:\Windows\Web\Wallpaper\Windows"
    $Wallpaper4KFolder = "C:\Windows\Web\4K\Wallpaper\Windows"
    $MainWallpaperFile = Join-Path $WallpaperMainFolder "img0.jpg"

    # Check the replacement before deleting anything: without it the defaults would be removed and nothing put back.
    if (-not (Test-Path $CustomWallpaper -PathType Leaf)) {
        Write-Log "Custom wallpaper not found at $CustomWallpaper. Keeping the default Windows wallpapers." -Level WARN
        return
    }

    # --- MAIN WALLPAPER FOLDER ---
    Write-Log "=== Processing main wallpaper folder ==="
    Grant-AdminAccess -TargetPath $WallpaperMainFolder

    Get-ChildItem $WallpaperMainFolder -File | ForEach-Object {
        Write-Log "Deleting file: $($_.Name)"
        Remove-Item $_.FullName -Force
    }

    Copy-Item $CustomWallpaper $MainWallpaperFile -Force
    Write-Log "Copied custom wallpaper to $MainWallpaperFile"

    # --- 4K WALLPAPER FOLDER ---
    if (Test-Path $Wallpaper4KFolder) {
        Write-Log "=== Processing 4K wallpaper folder ==="
        Grant-AdminAccess -TargetPath $Wallpaper4KFolder

        Get-ChildItem $Wallpaper4KFolder -File | ForEach-Object {
            Write-Log "Deleting file: $($_.Name)"
            Remove-Item $_.FullName -Force
        }

        Copy-Item $CustomWallpaper $Wallpaper4KFolder -Force
        Write-Log "Copied custom wallpaper into 4K wallpaper folder"
    }
    else {
        Write-Log "4K wallpaper folder not found at $Wallpaper4KFolder. Skipping." -Level WARN
    }

    Write-Log "Wallpaper replacement completed successfully!"
}

function Grant-AdminAccess {
    param ([string]$TargetPath)
    Write-Log "Taking ownership and granting permissions for: $TargetPath"
    takeown /F $TargetPath /A /R /D Y | Out-Null
    icacls $TargetPath /grant Administrators:F /T | Out-Null
}

function Install-Dependencies {
    Write-Log "Downloading Dependencies"

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    $downloads = @(
        "https://aka.ms/vs/17/release/vc_redist.x64.exe",
        "https://builds.dotnet.microsoft.com/dotnet/aspnetcore/Runtime/8.0.29/aspnetcore-runtime-8.0.29-win-x64.exe",
        "https://builds.dotnet.microsoft.com/dotnet/WindowsDesktop/8.0.29/windowsdesktop-runtime-8.0.29-win-x64.exe",
        "https://builds.dotnet.microsoft.com/dotnet/Runtime/8.0.29/dotnet-runtime-8.0.29-win-x64.exe",
        "https://github.com/PowerShell/PowerShell/releases/download/v7.5.3/PowerShell-7.5.3-win-x64.msi"
    )
    $downloads | ForEach-Object {
        $file = "C:\Temp\" + [System.IO.Path]::GetFileName($_)
        Invoke-WebRequest $_ -OutFile $file
        Write-Log "Installing Dependency: $file"
        Start-Process -FilePath $file -ArgumentList "/quiet" -Wait
    }
}

#-------------------------------------------------------------------------------------------------
# Install CAEVES software
#-------------------------------------------------------------------------------------------------
function Install-CaevesSoftware {
    <#
    .SYNOPSIS
        Sets the deployment environment variable, downloads and silently installs the CAEVES MSI.
    #>
    Write-Log 'Installing CAEVES software...'
    $isManifestUrlSet = $true
    $EnvironmentName = $Script:EnvironmentName

    switch ($EnvironmentName) {
        'Development' {
            Write-Log "DOTNET_ENVIRONMENT set to '$EnvironmentName'. Proceeding with MSI installation in development environment."
            $manifestUrl = " https://buildrepoprod.blob.core.windows.net/artifacts/CAEVES.FCG.App/main/manifest.json"
        }
        'Staging' {
            Write-Log "DOTNET_ENVIRONMENT set to '$EnvironmentName'. Proceeding with MSI installation with staging manifest."
            $manifestUrl = "https://buildrepoprod.blob.core.windows.net/artifacts-stage/CAEVES.FCG.App/staging/manifest.json"
        }        
        'Production' {
            Write-Log "DOTNET_ENVIRONMENT set to '$EnvironmentName'. Proceeding with MSI installation."
            $manifestUrl = "https://buildrepoprod.blob.core.windows.net/artifacts-prod/CAEVES.FCG.App/production/manifest.json"
        }
        Default {
            $isManifestUrlSet = $false
            Write-Log "Unrecognized DOTNET_ENVIRONMENT '$EnvironmentName'. No manifest URL configured for this environment." -Level ERROR
        }
    }    

    if ($isManifestUrlSet) {        
        $response = Invoke-WebRequest -Uri $manifestUrl -UseBasicParsing
        $stream = $response.RawContentStream
        $reader = New-Object System.IO.StreamReader($stream, $true)  # auto-detect encoding
        $content = $reader.ReadToEnd()
        $manifest = $content | ConvertFrom-Json
        $msiUrl = $manifest.installer.url
    }
    else {
        throw "Unrecognized DOTNET_ENVIRONMENT '$EnvironmentName' - no manifest URL configured. Update the environment switch in Install-CaevesSoftware to add support for this environment."
    }

    # Set the DOTNET_ENVIRONMENT environment variable for the machine
    [System.Environment]::SetEnvironmentVariable('DOTNET_ENVIRONMENT', $EnvironmentName, 'Machine')

    # Download and install the CAEVES MSI
    $file = Join-Path $Script:TempPath ([System.IO.Path]::GetFileName($msiUrl))
    Write-Log "Downloading: $msiUrl"
    Invoke-WebRequest -Uri $msiUrl -OutFile $file
    Write-Log "Installing : $file"
    Start-Process -FilePath $file -ArgumentList '/quiet' -Wait

    # Set the CAEVESEnabled environment variable to True
    [System.Environment]::SetEnvironmentVariable('CAEVESEnabled', 'True', 'Machine')
    Write-Log 'CAEVES software installed and CAEVESEnabled environment variable set to True.'
}

function New-DesktopShortcuts {
    Write-Log "Creating Desktop Shortcuts"

    Write-Log "Downloading CAEVES icon"
    $iconfile = "C:\WINDOWS\OEM\CAEVESicon.ico"
    Invoke-WebRequest -Uri "https://caeveswebassets.blob.core.windows.net/caevesbuildimage/CAEVESicon.ico" -OutFile $iconfile

    $WshShell = New-Object -ComObject WScript.Shell
    $shortcuts = @(
        @{Name = "CAEVES Configuration"; Target = "C:\Program Files\Caeves\FCGUI\FCGConfigUI.exe"; WorkingDirectory = "C:\Program Files\Caeves\FCGUI" },
        @{Name = "CAEVES Knowledge Base"; Target = "https://kb.caeves.com" },
        @{Name = "CAEVES Customer Support"; Target = "https://www.caeves.com/support" }
    )
    foreach ($s in $shortcuts) {
        $lnk = "$env:PUBLIC\Desktop\$($s.Name).lnk"
        $shortcut = $WshShell.CreateShortcut($lnk)
        $shortcut.IconLocation = "C:\WINDOWS\OEM\CAEVESicon.ico"
        $shortcut.TargetPath = $s.Target
        $shortcut.Save()
    }

    @"
sc start fcgmf
sc start FileCloudGatewayService
"@ | Out-File -Encoding ASCII "C:\CAEVES\Start-CAEVES.cmd"
}

function Start-WindowsServerUpdate {
    [CmdletBinding()]
    param (
        [switch]$Install,
        [switch]$AutoReboot
    )

    # Ensure PSWindowsUpdate is installed
    if (-not (Get-Module -ListAvailable -Name PSWindowsUpdate)) {
        Write-Log "Installing PSWindowsUpdate module..."
        Install-PackageProvider -Name NuGet -Force
        Install-Module -Name PSWindowsUpdate -Force -AllowClobber
    }

    Import-Module PSWindowsUpdate

    Write-Log "Checking for available Windows Updates ..."
    $updates = Get-WindowsUpdate -AcceptAll -IgnoreReboot

    if ($updates.Count -eq 0) {
        Write-Log "No Windows Updates available."
        return
    }

    Write-Log "$($updates.Count) update(s) found."

    if ($Install) {
        Write-Log "Installing Windows Updates ..."
        Install-WindowsUpdate -AcceptAll -IgnoreReboot -Confirm:$false

        if ($AutoReboot) {
            Write-Log "Rebooting system after Windows Updates ..." -Level WARN
            Restart-Computer -Force
        }
        else {
            Write-Log "Windows Updates installed. Reboot required manually if needed." -Level WARN
        }
    }
    else {
        Write-Log "Use -Install to install updates. No changes made."
    }
}

# =============================================
# FUNCTION DEFINITIONS - Inputs (service principal and config file)
# =============================================

function Read-SpnValue {
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [string]$Current,
        [switch]$Guid
    )

    $guidPattern = '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$'
    $value = $Current
    while ([string]::IsNullOrWhiteSpace($value) -or ($Guid -and $value.Trim() -notmatch $guidPattern)) {
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            Write-Warning "That does not look like a valid GUID. Please try again."
        }
        $value = Read-Host -Prompt $Prompt
    }
    return $value.Trim()
}

function Read-SpnSecret {
    param([SecureString]$Current)

    while ($null -eq $Current -or $Current.Length -eq 0) {
        $Current = Read-Host -Prompt 'Service principal client secret' -AsSecureString
    }
    return $Current
}

function Set-AzureServicePrincipalEnvironment {
    param(
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][string]$ClientId,
        [Parameter(Mandatory)][SecureString]$ClientSecret
    )

    Write-Log "Applying Azure service principal environment variables"

    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($ClientSecret)
    try { $plainSecret = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }

    # Machine scope persists across reboots; the process-scope copy makes them available to this run.
    $values = [ordered]@{
        AZURE_TENANT_ID     = $TenantId
        AZURE_CLIENT_ID     = $ClientId
        AZURE_CLIENT_SECRET = $plainSecret
    }
    foreach ($name in $values.Keys) {
        [System.Environment]::SetEnvironmentVariable($name, $values[$name], 'Machine')
        [System.Environment]::SetEnvironmentVariable($name, $values[$name], 'Process')
    }

    # The secret is never written to the console or the log.
    Write-Log "  AZURE_TENANT_ID     = $TenantId"
    Write-Log "  AZURE_CLIENT_ID     = $ClientId"
    Write-Log "  AZURE_CLIENT_SECRET = ****(masked)"
}

function Get-SavedSpnSettings {
    <#
    .SYNOPSIS
        Returns the service principal details saved by an earlier run, or $null when there are none.
        ClientSecret is $null when it cannot be decrypted (DPAPI: only the account that saved it can read it).
    #>
    if (-not (Test-Path $Script:SpnFile)) { return $null }

    try {
        $saved = Get-Content -Path $Script:SpnFile -Raw | ConvertFrom-Json
    }
    catch {
        Write-Log "Could not read $($Script:SpnFile) ($($_.Exception.Message)). You will be asked for the service principal details again." -Level WARN
        return $null
    }

    $secret = $null
    $encrypted = Get-ConfigProperty -Object $saved -Name 'ClientSecret'
    if (-not [string]::IsNullOrWhiteSpace($encrypted)) {
        try {
            $secret = ConvertTo-SecureString -String $encrypted
        }
        catch {
            Write-Log "The saved client secret could not be decrypted. It can only be read by the Windows account that saved it ($(Get-ConfigProperty -Object $saved -Name 'SavedBy')). You will be asked for it again." -Level WARN
        }
    }

    Write-Log "Using service principal details saved in $($Script:SpnFile) (saved by $(Get-ConfigProperty -Object $saved -Name 'SavedBy') at $(Get-ConfigProperty -Object $saved -Name 'SavedAt'))."
    return @{
        TenantId     = Get-ConfigProperty -Object $saved -Name 'TenantId'
        ClientId     = Get-ConfigProperty -Object $saved -Name 'ClientId'
        ClientSecret = $secret
    }
}

function Save-SpnSettings {
    param(
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][string]$ClientId,
        [Parameter(Mandatory)][SecureString]$ClientSecret
    )

    # Without -Key, ConvertFrom-SecureString encrypts with DPAPI: readable only by this account on this server.
    [ordered]@{
        TenantId     = $TenantId
        ClientId     = $ClientId
        ClientSecret = ConvertFrom-SecureString -SecureString $ClientSecret
        SavedBy      = "$env:USERDOMAIN\$env:USERNAME"
        SavedAt      = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    } | ConvertTo-Json | Out-File -FilePath $Script:SpnFile -Encoding UTF8

    # Limit the file to Administrators (S-1-5-32-544) and SYSTEM (S-1-5-18); SIDs work on any OS language.
    icacls $Script:SpnFile /inheritance:r /grant:r '*S-1-5-32-544:F' '*S-1-5-18:F' | Out-Null

    Write-Log "Service principal details saved to $($Script:SpnFile) (client secret encrypted for $env:USERDOMAIN\$env:USERNAME)."
}

function Initialize-CaevesModulePath {
    # The Caeves module is installed under the PowerShell 7 module folder; make sure it is searched.
    $modulePath = 'C:\Program Files\PowerShell\Modules'
    if ($env:PSModulePath -notlike "*$modulePath*") {
        $env:PSModulePath = "$modulePath;$env:PSModulePath"
    }
}

function Initialize-ConfigFile {
    # ConfigParameters.json is downloaded alongside this script; stage it where provisioning expects it.
    # A changed copy next to the script replaces the staged one, so a corrected config is used on a re-run.
    $source = $null
    if ($PSScriptRoot) {
        $candidate = Join-Path $PSScriptRoot 'ConfigParameters.json'
        if (Test-Path $candidate) { $source = $candidate }
    }
    if (-not $source) {
        # Earlier versions staged the config directly in C:\CAEVES.
        $legacy = Join-Path $Script:CaevesRoot 'ConfigParameters.json'
        if (Test-Path $legacy) { $source = $legacy }
    }

    if ($source -and -not (Test-Path $Script:ConfigFile)) {
        Copy-Item -Path $source -Destination $Script:ConfigFile -Force
        Write-Log "Copied $source to $($Script:ConfigFile)"
        return
    }

    if ($source -and (Get-FileHash -Path $source).Hash -ne (Get-FileHash -Path $Script:ConfigFile).Hash) {
        Copy-Item -Path $source -Destination $Script:ConfigFile -Force
        Write-Log "$source differs from the staged config. Copied it to $($Script:ConfigFile)." -Level WARN
        return
    }

    if (Test-Path $Script:ConfigFile) {
        Write-Log "Using existing config file: $($Script:ConfigFile)"
        return
    }

    throw "ConfigParameters.json not found. Download it from your storage account into the same folder as this script (or to $($Script:ConfigFile)) and run the script again."
}

function Resolve-CaevesEnvironment {
    $params = Get-Content $Script:ConfigFile -Raw | ConvertFrom-Json
    $value = Get-ConfigProperty -Object $params -Name 'environment'
    if ([string]::IsNullOrWhiteSpace($value)) {
        throw "'environment' is missing in $($Script:ConfigFile). Expected Development, Staging or Production."
    }
    try { $Script:EnvironmentName = ([EnvironmentType]$value.Trim()).ToString() }
    catch { throw "Invalid environment '$value' in $($Script:ConfigFile). Expected Development, Staging or Production." }
    Write-Log "Environment resolved from config: $($Script:EnvironmentName)"
}

# =============================================
# FUNCTION DEFINITIONS - Progress tracking (checkpoint / resume)
# =============================================

function Get-SetupState {
    # Every property is always present: StrictMode throws when reading a missing one.
    $state = [pscustomobject]@{
        CompletedSteps  = @()
        FailedStep      = $null
        LastError       = $null
        LastRun         = $null
        ConfigHash      = $null
        EnvironmentName = $null
    }

    if (Test-Path $Script:StateFile) {
        try {
            $saved = Get-Content -Path $Script:StateFile -Raw | ConvertFrom-Json
            foreach ($p in $saved.PSObject.Properties) {
                if ($state.PSObject.Properties[$p.Name]) { $state.($p.Name) = $p.Value }
            }
        }
        catch {
            # Every step is safe to run again, so an unreadable state file only costs time.
            Write-Log "Could not read $($Script:StateFile) ($($_.Exception.Message)). Starting from the first step." -Level WARN
        }
    }

    $state.CompletedSteps = @($state.CompletedSteps | Where-Object { $_ })
    return $state
}

function Save-SetupState {
    param([Parameter(Mandatory)]$State)

    $State.LastRun = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $State | ConvertTo-Json | Out-File -FilePath $Script:StateFile -Encoding UTF8
}

function Invoke-SetupStep {
    <#
    .SYNOPSIS
        Runs one setup step unless an earlier run already completed it, and records the result.
        -AlwaysRun is for steps that only load values into memory; they are never recorded as completed.
    #>
    param(
        [Parameter(Mandatory, Position = 0)][string]$Name,
        [Parameter(Mandatory, Position = 1)][scriptblock]$Action,
        [switch]$AlwaysRun
    )

    if (-not $AlwaysRun -and $Name -notin ($Script:Phase1Steps + $Script:Phase2Steps)) {
        throw "Invoke-SetupStep: '$Name' is not listed in `$Script:Phase1Steps or `$Script:Phase2Steps."
    }

    $state = Get-SetupState
    if (-not $AlwaysRun -and $Name -in $state.CompletedSteps) {
        Write-Log "[$Name] Already completed in an earlier run. Skipping."
        return
    }

    Write-Log "[$Name] Starting..."
    try {
        & $Action
    }
    catch {
        $state = Get-SetupState
        $state.FailedStep = $Name
        $state.LastError = $_.Exception.Message
        Save-SetupState -State $state
        throw
    }

    $state = Get-SetupState
    if (-not $AlwaysRun -and $Name -notin $state.CompletedSteps) {
        $state.CompletedSteps = @($state.CompletedSteps) + $Name
    }
    $state.FailedStep = $null
    $state.LastError = $null
    Save-SetupState -State $state
    Write-Log "[$Name] Completed."
}

function Reset-SetupProgress {
    # -ResetProgress: forget everything so every step runs again. disk-layout.json is kept on purpose:
    # the DataDisks step checks the disks themselves and skips the ones that are already partitioned.
    foreach ($file in @($Script:StateFile, $Script:BootMarker)) {
        if (Test-Path $file) {
            Remove-Item -Path $file -Force
            Write-Log "Removed $file"
        }
    }
    Write-Log 'Progress reset. All steps will run again.' -Level WARN
}

function Set-SetupStartStep {
    # -FromStep: forget the named step and every step after it, so the run continues from there.
    param([Parameter(Mandatory)][string]$StepName)

    $allSteps = @($Script:Phase1Steps + $Script:Phase2Steps)
    $match = $allSteps | Where-Object { $_ -eq $StepName } | Select-Object -First 1   # -eq is case-insensitive
    if (-not $match) {
        throw "Unknown step '$StepName' for -FromStep. Valid steps, in order: $($allSteps -join ', ')"
    }
    $index = [array]::IndexOf($allSteps, $match)

    $rerun = $allSteps[$index..($allSteps.Count - 1)]
    $state = Get-SetupState
    $state.CompletedSteps = @($state.CompletedSteps | Where-Object { $_ -notin $rerun })
    Save-SetupState -State $state

    if (Test-Path $Script:BootMarker) {
        Remove-Item -Path $Script:BootMarker -Force
        Write-Log "Removed $($Script:BootMarker) so the run can continue."
    }
    Write-Log "Running again from step '$($allSteps[$index])': $($rerun -join ', ')" -Level WARN
}

function Sync-SetupStateWithConfig {
    # A changed ConfigParameters.json must be applied again: forget the configuration steps, and the
    # CAEVES software install as well when the environment (and therefore the installer) changed.
    $state = Get-SetupState
    $hash = (Get-FileHash -Path $Script:ConfigFile -Algorithm SHA256).Hash

    if ($state.ConfigHash -and $state.ConfigHash -ne $hash) {
        Write-Log 'ConfigParameters.json has changed since the last run. The CAEVES configuration steps will run again.' -Level WARN
        $rerun = @($Script:Phase2Steps)
        if ($state.EnvironmentName -and $state.EnvironmentName -ne $Script:EnvironmentName) {
            Write-Log "Environment changed from '$($state.EnvironmentName)' to '$($Script:EnvironmentName)'. The CAEVES software will be installed again." -Level WARN
            $rerun += 'InstallCaevesSoftware'
        }
        $state.CompletedSteps = @($state.CompletedSteps | Where-Object { $_ -notin $rerun })
    }

    $state.ConfigHash = $hash
    $state.EnvironmentName = $Script:EnvironmentName
    Save-SetupState -State $state
}

function Register-CaevesResumeTask {
    <#
    .SYNOPSIS
        Registers a one-time task that continues the setup in PowerShell 7 when the current administrator signs in
        again after the restart. It runs as the same account, so the saved client secret can still be decrypted.
    #>
    if (-not (Test-Path $Script:PwshPath)) {
        throw "PowerShell 7 was not found at $($Script:PwshPath). Check that the PowerShell installer in Phase 1 completed."
    }

    $user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    # -NoExit keeps the window open so the result can be read; -ExecutionPolicy Bypass because the script is unsigned.
    $action = New-ScheduledTaskAction -Execute $Script:PwshPath `
        -Argument "-NoProfile -NoExit -ExecutionPolicy Bypass -File `"$PSCommandPath`" -ConfigureOnly"
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
    $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest

    Register-ScheduledTask -TaskName $Script:ResumeTaskName -Action $action -Trigger $trigger -Principal $principal `
        -Description 'Continues the CAEVES hybrid setup after the restart. Removed automatically when it runs.' -Force | Out-Null
    Write-Log "Registered scheduled task '$($Script:ResumeTaskName)': the setup continues in PowerShell 7 when $user signs in after the restart."
}

function Remove-CaevesResumeTask {
    # Removed as soon as the script starts again, so a later reboot never re-runs the setup on its own.
    if (Get-ScheduledTask -TaskName $Script:ResumeTaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $Script:ResumeTaskName -Confirm:$false
        Write-Log "Removed the one-time scheduled task '$($Script:ResumeTaskName)'."
    }
}

function Write-SetupProgressSummary {
    $state = Get-SetupState
    $total = $Script:Phase1Steps.Count + $Script:Phase2Steps.Count
    if ($state.CompletedSteps.Count -eq 0 -and -not $state.FailedStep) {
        Write-Log "Starting setup from the first step ($total steps)."
        return
    }

    Write-Log "Resuming setup: $($state.CompletedSteps.Count) of $total steps already completed ($($state.CompletedSteps -join ', '))."
    if ($state.FailedStep) {
        Write-Log "The last run (at $($state.LastRun)) failed at step '$($state.FailedStep)': $($state.LastError)" -Level WARN
    }
}


# =============================================
# FUNCTION DEFINITIONS - CAEVES configuration
# (from the earlier Setup-HybridConfiguration.ps1 v1.1 - Archana Patil)
# =============================================

function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'DEBUG')][string]$Level = 'INFO'
    )
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $entry = "[$timestamp] [$Level] $Message"

    $color = switch ($Level) {
        'INFO' { 'Cyan' }
        'WARN' { 'Yellow' }
        'ERROR' { 'Red' }
        'DEBUG' { 'Gray' }
    }
    Write-Host $entry -ForegroundColor $color
    try {
        Add-Content -Path $Script:LogFile -Value $entry -ErrorAction Stop
    }
    catch {
        Write-Host "  (could not write to $($Script:LogFile): $($_.Exception.Message))" -ForegroundColor DarkGray
    }
}

function Select-CaevesDataDisks {
    <#
    .SYNOPSIS
        Picks the fixed and slider disks, so the script never has to guess which of the customer's disks it may format:
          - fixedDiskSerial / sliderDiskSerial set in ConfigParameters.json: exactly those two disks.
          - otherwise: exactly two RAW (never-initialized) disks must be present.
    #>
    $rawDisks = @(Get-Disk |
        Where-Object { -not $_.IsBoot -and -not $_.IsSystem -and $_.PartitionStyle -eq 'RAW' } |
        Sort-Object -Property Number)

    foreach ($d in $rawDisks) {
        Write-Log "RAW disk found: Disk $($d.Number) | $([math]::Round($d.Size / 1GB, 1))GB | $($d.FriendlyName) | Serial='$($d.SerialNumber)' | Location='$($d.Location)'"
    }

    $hasFixedSerial = -not [string]::IsNullOrWhiteSpace($Script:FixedDiskSerial)
    $hasSliderSerial = -not [string]::IsNullOrWhiteSpace($Script:SliderDiskSerial)
    if ($hasFixedSerial -ne $hasSliderSerial) {
        throw "Set both fixedDiskSerial and sliderDiskSerial in ConfigParameters.json, or neither."
    }
    if ($hasFixedSerial) {
        $fixed = Get-CaevesDiskBySerial -Serial $Script:FixedDiskSerial -Role 'fixed'
        $slider = Get-CaevesDiskBySerial -Serial $Script:SliderDiskSerial -Role 'slider'
        if ($fixed.Number -eq $slider.Number) {
            throw "fixedDiskSerial and sliderDiskSerial in ConfigParameters.json point to the same disk (Disk $($fixed.Number)). They must name two different disks."
        }
        Write-Log "Disks selected by serial number from ConfigParameters.json: fixed = Disk $($fixed.Number), slider = Disk $($slider.Number)"
        return @{ Fixed = $fixed; Slider = $slider }
    }

    if ($rawDisks.Count -ne 2) {
        throw "Expected exactly 2 uninitialized (RAW) data disks, found $($rawDisks.Count). CAEVES needs one empty disk for Snapshots/Metadata and one for Cache. Either make sure only those two disks are uninitialized, or set fixedDiskSerial and sliderDiskSerial in ConfigParameters.json to the serial numbers listed above, then run the script again."
    }

    # Identify disks by LUN (works with SCSI controllers: "...LUN 0", "...LUN 1").
    $lun0 = @($rawDisks | Where-Object { $_.Location -match 'LUN\s*0\b' })
    $lun1 = @($rawDisks | Where-Object { $_.Location -match 'LUN\s*1\b' })
    if ($lun0.Count -eq 1 -and $lun1.Count -eq 1) {
        return @{ Fixed = $lun0[0]; Slider = $lun1[0] }
    }

    # Hyper-V and many SAS controllers report every disk as LUN 0 on a different target, and NVMe reports no LUN.
    Write-Log "LUN-based disk identification is ambiguous (LUN 0 matches: $($lun0.Count), LUN 1 matches: $($lun1.Count)). Falling back to disk-number order (lowest = fixed)." -Level WARN
    return @{ Fixed = $rawDisks[0]; Slider = $rawDisks[1] }
}

function Get-CaevesDiskBySerial {
    <#
    .SYNOPSIS
        Finds the one disk with the given serial number (case-insensitive, surrounding spaces ignored)
        and checks it is safe to format: not a boot/system disk, and still uninitialized (RAW).
    #>
    param(
        [Parameter(Mandatory)][string]$Serial,
        [Parameter(Mandatory)][string]$Role
    )

    $wanted = $Serial.Trim()
    $found = @(Get-Disk | Where-Object { $_.SerialNumber -and $_.SerialNumber.Trim() -eq $wanted })

    if ($found.Count -eq 0) {
        throw "No disk with serial number '$wanted' ($Role disk, from ConfigParameters.json) was found. Check the serial numbers in the 'RAW disk found' lines above."
    }
    if ($found.Count -gt 1) {
        throw "$($found.Count) disks have serial number '$wanted' ($Role disk). The serial number must identify a single disk."
    }

    $disk = $found[0]
    if ($disk.IsBoot -or $disk.IsSystem) {
        throw "The $Role disk with serial number '$wanted' is a boot/system disk (Disk $($disk.Number)). It will not be used."
    }
    if ($disk.PartitionStyle -ne 'RAW') {
        throw "The $Role disk with serial number '$wanted' (Disk $($disk.Number)) is already initialized ($($disk.PartitionStyle)). CAEVES only formats empty (RAW) disks. Check the serial number, or clear the disk if it is really meant for CAEVES."
    }
    return $disk
}

function Get-CaevesRecordedDisk {
    <#
    .SYNOPSIS
        Finds a disk recorded in the disk layout file, by UniqueId (stable across reboots) or by number as a fallback.
    #>
    param(
        [string]$UniqueId,
        [int]$Number,
        [Parameter(Mandatory)][string]$Role
    )

    if (-not [string]::IsNullOrWhiteSpace($UniqueId)) {
        $disk = @(Get-Disk | Where-Object { $_.UniqueId -eq $UniqueId })
    }
    else {
        $disk = @(Get-Disk | Where-Object { $_.Number -eq $Number })
    }

    if ($disk.Count -ne 1) {
        throw "The $Role disk recorded in $($Script:DiskLayoutFile) (UniqueId='$UniqueId', Number=$Number) was not found. If the disks were replaced, clear any incomplete CAEVES disks, delete that file and run the script again."
    }
    if ($disk[0].IsBoot -or $disk[0].IsSystem) {
        throw "The $Role disk recorded in $($Script:DiskLayoutFile) is now a boot/system disk (Disk $($disk[0].Number)). It will not be touched."
    }
    return $disk[0]
}

function Test-CaevesDiskComplete {
    <#
    .SYNOPSIS
        Returns $true when every expected volume label is present on the given disk.
    #>
    param(
        [Parameter(Mandatory)]$Disk,
        [Parameter(Mandatory)][string[]]$Labels
    )

    if ($Disk.PartitionStyle -eq 'RAW') { return $false }

    $present = @(Get-Partition -DiskNumber $Disk.Number -ErrorAction SilentlyContinue |
        Get-Volume -ErrorAction SilentlyContinue |
        Where-Object { $_.FileSystemLabel -in $Labels } |
        ForEach-Object { $_.FileSystemLabel } |
        Select-Object -Unique)
    return ($present.Count -eq $Labels.Count)
}

function Reset-CaevesDisk {
    <#
    .SYNOPSIS
        Brings a selected disk to an empty GPT state. Only called for the two disks recorded in the layout file.
    #>
    param([Parameter(Mandatory)]$Disk)

    if ($Disk.IsOffline) { Set-Disk -Number $Disk.Number -IsOffline $false }
    if ($Disk.IsReadOnly) { Set-Disk -Number $Disk.Number -IsReadOnly $false }

    if ($Disk.PartitionStyle -ne 'RAW') {
        # The disk was RAW when it was selected, so anything on it was left by an earlier, incomplete run.
        Write-Log "Disk $($Disk.Number) has an incomplete CAEVES layout from a previous run. Clearing it and partitioning again." -Level WARN
        Clear-Disk -Number $Disk.Number -RemoveData -RemoveOEM -Confirm:$false
    }

    Initialize-Disk -Number $Disk.Number -PartitionStyle GPT | Out-Null
    return Get-Disk -Number $Disk.Number
}

function New-CaevesFixedDiskLayout {
    # Fixed disk: 90% Snapshots (no letter) + 10% Metadata (F:)
    param([Parameter(Mandatory)]$Disk)

    Write-Log "Fixed  Disk: Disk $($Disk.Number), $([math]::Round($Disk.Size / 1GB, 1))GB"

    $fixedSize = $Disk.Size
    $snapshotSize = [math]::Floor($fixedSize * 0.90) - 1000000000   # leave 1 GB unallocated
    $metadataSize = [math]::Floor($fixedSize * 0.10)

    $volSnapshot = New-Partition -DiskNumber $Disk.Number -Size $snapshotSize
    Format-Volume -Partition $volSnapshot -FileSystem NTFS -NewFileSystemLabel 'Snapshots' -Confirm:$false | Out-Null

    $volMetadata = New-Partition -DiskNumber $Disk.Number -Size $metadataSize -DriveLetter F
    Format-Volume -Partition $volMetadata -FileSystem NTFS -NewFileSystemLabel 'Metadata'  -Confirm:$false | Out-Null

    Write-Log "Fixed  disk partitioned: F: (Metadata $([math]::Round($metadataSize/1GB,1))GB), unlabelled (Snapshots $([math]::Round($snapshotSize/1GB,1))GB)"
}

function New-CaevesSliderDiskLayout {
    # Slider disk: Cache (G:)
    param([Parameter(Mandatory)]$Disk)

    Write-Log "Slider Disk: Disk $($Disk.Number), $([math]::Round($Disk.Size / 1GB, 1))GB"

    $volCache = New-Partition -DiskNumber $Disk.Number -UseMaximumSize -DriveLetter G
    Format-Volume -Partition $volCache -FileSystem NTFS -NewFileSystemLabel 'Cache' -Confirm:$false | Out-Null

    Write-Log "Slider disk partitioned: G: (Cache $([math]::Round($Disk.Size/1GB,1))GB)"
}

function Initialize-CaevesDataDisks {
    Write-Log 'Initializing data disks with custom partitioning...'

    $fixedLabels = @('Snapshots', 'Metadata')
    $sliderLabels = @('Cache')
    $caevesLabels = $fixedLabels + $sliderLabels

    if (Test-Path $Script:DiskLayoutFile) {
        # A previous run already chose the disks: resume with exactly those two and nothing else.
        $layout = Get-Content -Path $Script:DiskLayoutFile -Raw | ConvertFrom-Json
        $fixedDisk = Get-CaevesRecordedDisk -UniqueId $layout.FixedUniqueId -Number $layout.FixedNumber -Role 'fixed'
        $sliderDisk = Get-CaevesRecordedDisk -UniqueId $layout.SliderUniqueId -Number $layout.SliderNumber -Role 'slider'
        Write-Log "Using the disks recorded in $($Script:DiskLayoutFile): fixed = Disk $($fixedDisk.Number), slider = Disk $($sliderDisk.Number)"

        # The config may name different disks than an earlier run chose; never continue on disks the config does not name.
        foreach ($check in @(@{ Role = 'fixed'; Disk = $fixedDisk; Serial = $Script:FixedDiskSerial },
                @{ Role = 'slider'; Disk = $sliderDisk; Serial = $Script:SliderDiskSerial })) {
            if ([string]::IsNullOrWhiteSpace($check.Serial)) { continue }
            $recordedSerial = if ($check.Disk.SerialNumber) { $check.Disk.SerialNumber.Trim() } else { '' }
            if ($recordedSerial -ne $check.Serial.Trim()) {
                throw "The $($check.Role) disk recorded in $($Script:DiskLayoutFile) (Disk $($check.Disk.Number), serial '$recordedSerial') is not the one named in ConfigParameters.json (serial '$($check.Serial.Trim())'). If the config is right, clear any partly set up CAEVES disk, delete $($Script:DiskLayoutFile) and run the script again."
            }
        }
    }
    else {
        # Hosts partitioned by an earlier version of this script have volumes but no layout file.
        $existingLabels = @(Get-CimInstance -ClassName Win32_Volume |
            Where-Object { $_.Label -in $caevesLabels } |
            ForEach-Object { $_.Label } |
            Select-Object -Unique)

        if ($existingLabels.Count -eq $caevesLabels.Count) {
            Write-Log 'Snapshots, Metadata and Cache volumes already exist. Skipping disk initialization.'
            return
        }
        if ($existingLabels.Count -gt 0) {
            throw "Found only some CAEVES volumes ($($existingLabels -join ', ')) and no $($Script:DiskLayoutFile) recording which disks they are on. Clear the incomplete CAEVES disks manually (Clear-Disk) and run the script again."
        }

        $selection = Select-CaevesDataDisks
        $fixedDisk = $selection.Fixed
        $sliderDisk = $selection.Slider

        # Record the choice before touching any disk, so a re-run after a failure works on the same two disks.
        [ordered]@{
            FixedNumber    = $fixedDisk.Number
            FixedUniqueId  = $fixedDisk.UniqueId
            SliderNumber   = $sliderDisk.Number
            SliderUniqueId = $sliderDisk.UniqueId
            RecordedAt     = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        } | ConvertTo-Json | Out-File -FilePath $Script:DiskLayoutFile -Encoding UTF8
        Write-Log "Disk selection recorded in $($Script:DiskLayoutFile): fixed = Disk $($fixedDisk.Number), slider = Disk $($sliderDisk.Number)"
    }

    # Each disk is finished independently, so a failure on one disk does not force the other to be redone.
    if (Test-CaevesDiskComplete -Disk $fixedDisk -Labels $fixedLabels) {
        Write-Log "Fixed disk (Disk $($fixedDisk.Number)) already has its Snapshots and Metadata volumes. Skipping."
    }
    else {
        $fixedDisk = Reset-CaevesDisk -Disk $fixedDisk
        New-CaevesFixedDiskLayout -Disk $fixedDisk
    }

    if (Test-CaevesDiskComplete -Disk $sliderDisk -Labels $sliderLabels) {
        Write-Log "Slider disk (Disk $($sliderDisk.Number)) already has its Cache volume. Skipping."
    }
    else {
        $sliderDisk = Reset-CaevesDisk -Disk $sliderDisk
        New-CaevesSliderDiskLayout -Disk $sliderDisk
    }
}

# Note: The Metadata volume will be used for CAEVES configuration and must be accessible by the CAEVES service process, which runs under the Local Service account.
#       By default, newly formatted volumes grant full access to Administrators and SYSTEM, but only read & execute permissions to Local Service.
#       We need to grant Local Service full control over the Metadata volume (F:) to ensure CAEVES can read/write its configuration and state.
function Set-PermissionsToMetadataVolume {
    try {
        Write-Log 'Checking for F: drive...'

        $timeout = 300
        $elapsed = 0

        while (!(Test-Path "F:\")) {
            if ($elapsed -ge $timeout) {
                throw "F: drive not available within timeout."
            }
            Start-Sleep -Seconds 5
            $elapsed += 5
        }

        Write-Log 'F: drive found. Applying Metadata volume ACL...'

        # /inheritance:d removes inherited ACEs; explicit grants are required afterwards.
        # Local Service is the CAEVES service account and needs full control on F:.
        $result = icacls F:\ /inheritance:d /t /c
        Write-Log ($result -join [Environment]::NewLine) -Level DEBUG
    }
    catch {
        Write-Error "Failed to apply permissions: $_"
    }
}

function Assert-Administrator {
    $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($currentIdentity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Please run this script in an elevated PowerShell (Run as Administrator)."
    }
}

function Get-ConfigProperty {
    param(
        [Parameter(Mandatory)]$Object,
        [Parameter(Mandatory)][string]$Name
    )
    $prop = $Object.PSObject.Properties[$Name]
    if ($prop) { return $prop.Value }
    return $null
}

function ConvertTo-ScriptBool {
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [bool]) { return $Value }
    $s = [string]$Value
    if ([string]::IsNullOrWhiteSpace($s)) { return $null }
    if ($s -eq 'true' -or $s -eq '1') { return $true }
    if ($s -eq 'false' -or $s -eq '0') { return $false }
    return $null
}

function Get-VolumeByLabel {
    param([Parameter(Mandatory)][string]$Label)
    $vols = Get-CimInstance -ClassName Win32_Volume -Filter "Label='$Label'"
    if (-not $vols) { throw "No volume with label '$Label' was found." }
    if ($vols.Count -gt 1) {
        throw "Multiple volumes with label '$Label' were found. Please ensure the label is unique."
    }
    return $vols
}

function Get-VolumeBySpecifier {
    <#
    Accepts:
      - Drive letter (e.g. "F:")
      - Volume GUID path (e.g. "\\?\Volume{GUID}\")
  #>
    param([Parameter(Mandatory)][string]$Specifier)

    Write-Log "Resolving volume for specifier '$Specifier'..."
    if ($Specifier -match '^[A-Za-z]:$') {
        $drive = $Specifier.ToUpper()
        $vol = Get-CimInstance Win32_Volume | Where-Object { $_.DriveLetter -eq $drive }
        if (-not $vol) { throw "No volume with drive letter $drive was found." }
        return $vol
    }

    if ($Specifier -like '\\?\Volume{*}\') {
        $guid = $Specifier
        $vol = Get-CimInstance Win32_Volume | Where-Object { $_.DeviceID -eq $guid }
        if (-not $vol) { throw "No volume with GUID '$guid' was found." }
        return $vol
    }

    throw "Unsupported MetadataVolume specifier '$Specifier'. Use a drive letter (e.g., 'F:') or a Volume GUID path (\\?\Volume{GUID}\)."
}

function Normalize-VolumeGuid {
    param([Parameter(Mandatory)][string]$DeviceId)
    # Ensure it ends with a backslash, as vssadmin accepts that form.
    if ($DeviceId.EndsWith('\')) { return $DeviceId }
    return "$DeviceId\"
}

function Invoke-VssAdmin {
    param([Parameter(Mandatory)][string[]]$ArgumentList)

    $exe = Join-Path $env:SystemRoot 'System32\vssadmin.exe'

    Write-Verbose ("Running: {0} {1}" -f $exe, ($ArgumentList -join ' '))
    $output = & $exe @ArgumentList 2>&1
    $exit = $LASTEXITCODE
    [PSCustomObject]@{
        ExitCode = $exit
        Output   = ($output -join [Environment]::NewLine)
    }
}

function Get-ShadowStorageInfo {
    param([Parameter(Mandatory)][string]$ForSpec)

    $res = Invoke-VssAdmin -ArgumentList @('list', 'shadowstorage', "/for=$ForSpec")
    return $res.Output
}

function ShadowStorageExistsOn {
    <#
    Returns:
      - $true  if the metadata volume already uses the given /on target
      - $false if not
  #>
    param(
        [Parameter(Mandatory)][string]$ForSpec,
        [Parameter(Mandatory)][string]$OnSpec
    )

    $info = Get-ShadowStorageInfo -ForSpec $ForSpec
    if (-not $info) { return $false }

    # Look for the "Shadow Copy Storage volume:" line containing the OnSpec (GUID or drive)
    $normalizedOn = $OnSpec.TrimEnd('\').ToLowerInvariant()
    foreach ($line in ($info -split "`r?`n")) {
        if ($line -match 'Shadow Copy Storage volume:\s*(.+)$') {
            $found = $Matches[1].Trim().TrimEnd('\').ToLowerInvariant()
            if ($found -eq $normalizedOn) { return $true }
        }
    }
    return $false
}

function Initialize-VssShadowStorage {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)][string]$MetadataVolume,
        [Parameter(Mandatory)][string]$SnapshotsLabel,
        [Parameter(Mandatory)][string]$MaxSize
    )
    Write-Log "Locating Snapshots volume by label '$SnapshotsLabel'..."
    $snapshotVolume = Get-VolumeByLabel -Label $SnapshotsLabel
    $snapshotGuid = Normalize-VolumeGuid -DeviceId $snapshotVolume.DeviceID
    Write-Log "Snapshots volume GUID: $snapshotGuid"

    Write-Log "Resolving metadata volume '$MetadataVolume'..."
    $metadVolume = Get-VolumeBySpecifier -Specifier $MetadataVolume
    $metadataGuid = Normalize-VolumeGuid -DeviceId $metadVolume.DeviceID
    Write-Log "Metadata volume GUID: $metadataGuid"

    Set-ShadowStorage -ForSpec $metadataGuid -OnSpec $snapshotGuid -MaxSize $MaxSize
}

function Set-ShadowStorage {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)][string]$ForSpec,
        [Parameter(Mandatory)][string]$OnSpec,
        [Parameter(Mandatory)][string]$MaxSize,
        [bool]$MoveExistingShadowStorage = $false
    )
    try {
        # Try to create (idempotent-ish). If it already exists, vssadmin returns a nonzero exit;
        # we'll then try resize, and as a last resort (if requested) delete+add.
        Write-Log "Configuring shadow storage (VSS) for metadata volume..."

        $alreadyThere = ShadowStorageExistsOn -ForSpec $forSpec -OnSpec $onSpec

        if (-not $alreadyThere) {
            Write-Log "No existing shadow storage on the Snapshots volume for $forSpec."
            Write-Log "Attempting: vssadmin add shadowstorage /for=$forSpec /on=$onSpec /maxsize=$MaxSize"
            if ($PSCmdlet.ShouldProcess("VSS shadow storage for $forSpec", "add on $onSpec (maxsize=$MaxSize)")) {
                $add = Invoke-VssAdmin -ArgumentList @('add', 'shadowstorage', "/for=$forSpec", "/on=$onSpec", "/maxsize=$MaxSize")
                if ($add.ExitCode -eq 0) {
                    Write-Log "Shadow storage association created."
                }
                else {
                    Write-Log "Add failed (exit $($add.ExitCode)). Trying resize (may also move storage if supported)." -Level WARN
                    Write-Verbose $add.Output

                    if ($PSCmdlet.ShouldProcess("VSS shadow storage for $forSpec", "resize on $onSpec (maxsize=$MaxSize)")) {
                        $resize = Invoke-VssAdmin -ArgumentList @('resize', 'shadowstorage', "/for=$forSpec", "/on=$onSpec", "/maxsize=$MaxSize")
                        if ($resize.ExitCode -eq 0) {
                            Write-Log "Shadow storage resized (and/or moved) successfully."
                        }
                        else {
                            Write-Log "Resize failed (exit $($resize.ExitCode))." -Level WARN
                            Write-Verbose $resize.Output

                            if ($MoveExistingShadowStorage) {
                                Write-Log "About to delete existing shadow storage for $forSpec and recreate it on $onSpec." -Level WARN
                                if ($PSCmdlet.ShouldProcess("VSS shadow storage for $forSpec", "DELETE and re-ADD on $onSpec (this deletes existing shadow copies)")) {
                                    $del = Invoke-VssAdmin -ArgumentList @('delete', 'shadowstorage', "/for=$forSpec")
                                    if ($del.ExitCode -eq 0) {
                                        $add2 = Invoke-VssAdmin -ArgumentList @('add', 'shadowstorage', "/for=$forSpec", "/on=$onSpec", "/maxsize=$MaxSize")
                                        if ($add2.ExitCode -eq 0) {
                                            Write-Log "Shadow storage moved to Snapshots volume."
                                        }
                                        else {
                                            throw "Failed to re-create shadow storage after deletion. Output:`n$($add2.Output)"
                                        }
                                    }
                                    else {
                                        throw "Failed to delete existing shadow storage. Output:`n$($del.Output)"
                                    }
                                }
                            }
                            else {
                                Write-Log "Existing shadow storage could not be moved automatically. Re-run with -MoveExistingShadowStorage to force a delete+add (this will delete existing shadow copies)." -Level WARN
                            }
                        }
                    }
                }
            }
        }
        else {
            Write-Log "Shadow storage for $forSpec is already set to the Snapshots volume. Ensuring max size..."
            if ($PSCmdlet.ShouldProcess("VSS shadow storage for $forSpec", "resize (maxsize=$MaxSize)")) {
                $resize2 = Invoke-VssAdmin -ArgumentList @('resize', 'shadowstorage', "/for=$forSpec", "/on=$onSpec", "/maxsize=$MaxSize")
                if ($resize2.ExitCode -eq 0) {
                    Write-Log "Shadow storage size verified/updated."
                }
                else {
                    Write-Log "Resize returned exit $($resize2.ExitCode). Output:`n$($resize2.Output)" -Level WARN
                }
            }
        }

        Write-Log "Result for metadata volume: $(Get-ShadowStorageInfo -ForSpec $forSpec)"
        Write-Log "VSS shadow storage configuration complete."

    }
    catch {
        throw
    }
}

function Initialize-SnapshotTasks {

    $schedules = @()

    # Set up scheduled tasks for snapshots if retention values are set
    Write-Log "Configuring snapshot schedules based on provided parameters..."

    # Daily
    if ($Script:EnableDailySnapshot) {
        $schedules += @{
            Type = "Daily"
            Time = $Script:MetaSnapDailyTime
        }
        Write-Log "Daily    : Enabled=$($Script:EnableDailySnapshot), Time=$($Script:MetaSnapDailyTime)"
    }

    # Weekly
    if ($Script:EnableWeeklySnapshot) {
        $schedules += @{
            Type    = "Weekly"
            WeekDay = $Script:MetaSnapWeeklyDay
            Time    = $Script:MetaSnapWeeklyTime
        }
        Write-Log "Weekly   : Enabled=$($Script:EnableWeeklySnapshot),  Day=$($Script:MetaSnapWeeklyDay), Time=$($Script:MetaSnapWeeklyTime)"
    }

    # Monthly
    if ($Script:EnableMonthlySnapshot) {
        # Parse value like "LastSunday", "FirstMonday", etc.
        if ($Script:MetaSnapMonthlyWeekday -match '^(First|Second|Third|Fourth|Last)(Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday)$') {
            $weekText = $matches[1]
            $dayText = $matches[2]

            $weekMap = @{
                First  = 1
                Second = 2
                Third  = 3
                Fourth = 4
                Last   = -1
            }
            $weekOfMonth = $weekMap[$weekText]

            $schedules += @{
                Type        = "Monthly"
                WeekDay     = $dayText
                WeekOfMonth = $weekOfMonth
                Time        = $Script:MetaSnapMonthlyTime
                ForceSnap   = $Script:MetaForceSnapMonthly
            }
            Write-Log "Monthly  : Enabled=$($Script:EnableMonthlySnapshot), Weekday=$($Script:MetaSnapMonthlyWeekday), Time=$($Script:MetaSnapMonthlyTime), ForceSnap=$($Script:MetaForceSnapMonthly)"
        }
        else {
            throw "Invalid Monthly Weekday format: $($Script:MetaSnapMonthlyWeekday)"
        }
    }

    if ($schedules.Count -eq 0) {
        Write-Log 'No snapshot schedules enabled. Skipping New-FCGSnapshotScheduler.' -Level WARN
        return
    }

    New-FCGSnapshotScheduler -Name "FCGSnapshotPolicy" -Schedules $schedules
    Write-Log "Snapshot scheduling configuration complete."
}

function Initialize-CaevesDirectories {
    New-Item -Path $Script:CaevesRoot  -ItemType Directory -Force | Out-Null
    New-Item -Path $Script:LogPath     -ItemType Directory -Force | Out-Null
    New-Item -Path $Script:ConfigPath  -ItemType Directory -Force | Out-Null
    New-Item -Path $Script:TempPath    -ItemType Directory -Force | Out-Null
}

function Move-LegacyCaevesFiles {
    <#
    .SYNOPSIS
        Earlier versions of this script wrote their generated files directly into C:\CAEVES. Move them into
        C:\CAEVES\Config so a server that already ran keeps its progress, saved credentials, disk choice and marker.
        ConfigParameters.json is not moved: in C:\CAEVES it is usually the downloaded original, which
        Initialize-ConfigFile copies into the Config folder.
    #>
    $files = @(
        @{ Old = Join-Path $Script:CaevesRoot 'setup-state.json'; New = $Script:StateFile },
        @{ Old = Join-Path $Script:CaevesRoot 'spn-settings.json'; New = $Script:SpnFile },
        @{ Old = Join-Path $Script:CaevesRoot 'disk-layout.json'; New = $Script:DiskLayoutFile },
        @{ Old = Join-Path $Script:CaevesRoot 'boot.complete'; New = $Script:BootMarker }
    )
    foreach ($f in $files) {
        if (-not (Test-Path $f.Old)) { continue }
        if (Test-Path $f.New) {
            Write-Log "Both $($f.Old) and $($f.New) exist. Using $($f.New); the old file is left in place." -Level WARN
            continue
        }
        # Move-Item on the same volume keeps the file's permissions (spn-settings.json is limited to Administrators/SYSTEM).
        Move-Item -Path $f.Old -Destination $f.New
        Write-Log "Moved $($f.Old) to $($f.New)"
    }
}

function Import-CaevesConfiguration {
    <#
    .SYNOPSIS
        Reads ConfigParameters.json and populates $Script: variables for the rest of the script.
    #>
    if (-not (Test-Path $Script:ConfigFile)) {
        throw "Config file not found: $($Script:ConfigFile)"
    }

    $params = Get-Content $Script:ConfigFile | ConvertFrom-Json
    Write-Log "Configuration loaded from: $($Script:ConfigFile)"

    $Script:StorageAccountName = Get-ConfigProperty -Object $params -Name 'storageAccountName'
    $Script:StorageAccountKey = Get-ConfigProperty -Object $params -Name 'StorageAccountKey'
    if ([string]::IsNullOrWhiteSpace($Script:StorageAccountKey)) {
        $Script:StorageAccountKey = Get-ConfigProperty -Object $params -Name 'storageAccountKey'
    }
    $Script:StorageAccountResourceId = Get-ConfigProperty -Object $params -Name 'storageAccountResourceId'
    $Script:ContainerName = Get-ConfigProperty -Object $params -Name 'containerName'
    $Script:SnapshotsContainerName = Get-ConfigProperty -Object $params -Name 'snapshotsContainerName'
    $Script:ConfigContainerName = Get-ConfigProperty -Object $params -Name 'configContainerName'
    $Script:TableName = Get-ConfigProperty -Object $params -Name 'tableName'
    $Script:ProcessTableName = Get-ConfigProperty -Object $params -Name 'metadataProcessTableName'
    $Script:CaevesConfigTableName = Get-ConfigProperty -Object $params -Name 'caevesConfigTableName'
    $Script:QueueName = Get-ConfigProperty -Object $params -Name 'queueName'
    $Script:SaasOfferId = Get-ConfigProperty -Object $params -Name 'saasOfferId'
    $Script:SaasSubscriptionId = Get-ConfigProperty -Object $params -Name 'saasSubscriptionId'
    $Script:PurchaserId = Get-ConfigProperty -Object $params -Name 'purchaserId'
    $Script:AzureSubscriptionId = Get-ConfigProperty -Object $params -Name 'azureSubscriptionId'
    $Script:Location = Get-ConfigProperty -Object $params -Name 'location'
    $Script:FixedDiskSerial = Get-ConfigProperty -Object $params -Name 'fixedDiskSerial'
    $Script:SliderDiskSerial = Get-ConfigProperty -Object $params -Name 'sliderDiskSerial'
    $Script:MetaSnapFrequency = Get-ConfigProperty -Object $params -Name 'metaSnapFrequency'
    $Script:MetaSnapDailyTime = Get-ConfigProperty -Object $params -Name 'metaSnapDailyTime'
    $Script:MetaSnapWeeklyDay = Get-ConfigProperty -Object $params -Name 'metaSnapWeeklyDay'
    $Script:MetaSnapWeeklyTime = Get-ConfigProperty -Object $params -Name 'metaSnapWeeklyTime'
    $Script:MetaSnapMonthlyWeekday = Get-ConfigProperty -Object $params -Name 'metaSnapMonthlyWeekday'
    $Script:MetaSnapMonthlyTime = Get-ConfigProperty -Object $params -Name 'metaSnapMonthlyTime'
    $Script:MetaForceSnapMonthly = ConvertTo-ScriptBool (Get-ConfigProperty -Object $params -Name 'metaForceSnapMonthly')

    $enableDaily = ConvertTo-ScriptBool (Get-ConfigProperty -Object $params -Name 'enableDailySnapshot')
    $enableWeekly = ConvertTo-ScriptBool (Get-ConfigProperty -Object $params -Name 'enableWeeklySnapshot')
    $enableMonthly = ConvertTo-ScriptBool (Get-ConfigProperty -Object $params -Name 'enableMonthlySnapshot')

    # JSON boolean false is a real value - do not treat it as "missing".
    if ($null -ne $enableDaily) {
        $Script:EnableDailySnapshot = $enableDaily
    }
    else {
        $Script:EnableDailySnapshot = -not [string]::IsNullOrWhiteSpace($Script:MetaSnapDailyTime)
    }

    if ($null -ne $enableWeekly) {
        $Script:EnableWeeklySnapshot = $enableWeekly
    }
    else {
        $Script:EnableWeeklySnapshot = -not [string]::IsNullOrWhiteSpace($Script:MetaSnapWeeklyDay)
    }

    if ($null -ne $enableMonthly) {
        $Script:EnableMonthlySnapshot = $enableMonthly
    }
    else {
        $Script:EnableMonthlySnapshot = -not [string]::IsNullOrWhiteSpace($Script:MetaSnapMonthlyWeekday)
    }

    $missing = @()
    if ([string]::IsNullOrWhiteSpace($Script:StorageAccountName)) { $missing += 'storageAccountName' }
    if ([string]::IsNullOrWhiteSpace($Script:StorageAccountKey)) { $missing += 'StorageAccountKey' }
    if ([string]::IsNullOrWhiteSpace($Script:ContainerName)) { $missing += 'containerName' }
    if ($null -eq $Script:MetaSnapFrequency) { $missing += 'metaSnapFrequency' }
    if ($missing.Count -gt 0) {
        throw "Config file is missing required field(s): $($missing -join ', ')"
    }
}

function Set-Environment {
    param(
        [string]$Environment = $Script:EnvironmentName
    )

    $envString = ([EnvironmentType]$Environment).ToString()
    Write-Log "Setting environment to $envString"
    $Script:EnvironmentName = $envString

    [System.Environment]::SetEnvironmentVariable('DOTNET_ENVIRONMENT', $envString, 'Machine')
    [System.Environment]::SetEnvironmentVariable('CAEVESEnabled', 'True', 'Machine')
}

function Set-CaevesAgentConfiguration {
    <#
    .SYNOPSIS
        Configures the CAEVES FCG Agent registry keys and starts the required services using Caeves module cmdlets.
    #>
    param ([string] $StorageConnectionString)

    Write-Log 'Configuring CAEVES FCG Agent...'

    if (-not (Get-Module -Name Caeves)) {
        Import-Module -Name Caeves
    }

    # Storage configuration
    $storageParams = @{
        Name                     = $Script:StorageAccountName
        StorageAccountName       = $Script:StorageAccountName
        StorageType              = 'azureblob'
        StorageConnectionString  = $StorageConnectionString
        ContainerName            = $Script:ContainerName
        SnapshotsContainerName   = $Script:SnapshotsContainerName
        StorageAccountResourceId = $Script:StorageAccountResourceId
    }
    if (-not [string]::IsNullOrWhiteSpace($Script:TableName)) { $storageParams['MetadataTableName'] = $Script:TableName }
    if (-not [string]::IsNullOrWhiteSpace($Script:ProcessTableName)) { $storageParams['MetadataProcessTableName'] = $Script:ProcessTableName }
    if (-not [string]::IsNullOrWhiteSpace($Script:CaevesConfigTableName)) { $storageParams['CaevesConfigTableName'] = $Script:CaevesConfigTableName }
    if (-not [string]::IsNullOrWhiteSpace($Script:QueueName)) {
        # Older builds of the Caeves module do not have a -QueueName parameter.
        if ((Get-Command Add-FCGStorageConfiguration).Parameters.ContainsKey('QueueName')) {
            $storageParams['QueueName'] = $Script:QueueName
        }
        else {
            Write-Log "The installed Caeves module does not support QueueName, so queueName '$($Script:QueueName)' from ConfigParameters.json was NOT applied. A newer CAEVES build may be required." -Level WARN
        }
    }

    Add-FCGStorageConfiguration @storageParams
    Write-Log "[Add-FCGStorageConfiguration] Storage configuration for '$($Script:StorageAccountName)' added successfully.`n"

    # License
    Set-FCGSaasSubscriptionId -SubscriptionId $Script:SaasSubscriptionId
    Write-Log "[Set-FCGSaasSubscriptionId] SaaSSubscriptionID set to: $($Script:SaasSubscriptionId) `n"

    # Migration mode
    Set-FCGPurgeOnFlush -Value 1
    Write-Log "[Set-FCGPurgeOnFlush] PurgeOnFlush set to 1.`n"

    # Snapshot frequency
    Set-FCGSnapshotFrequency -Value $Script:MetaSnapFrequency
    Write-Log "[Set-FCGSnapshotFrequency] Snapshot frequency set to: $($Script:MetaSnapFrequency) `n"

    # Cache folder and volume configuration
    Set-FCGCacheFolderPath -Path $Script:CacheDirPath
    Write-Log "[Set-FCGCacheFolderPath] Cache folder path set: $($Script:CacheDirPath) `n"

    # Log Metadata volume info
    $metaVolume = Get-CimInstance -ClassName Win32_Volume | Where-Object { $_.Label -eq 'Metadata' }
    if ($metaVolume) {
        Write-Log "Metadata volume : $($metaVolume.DriveLetter) | FS=$($metaVolume.FileSystem) | GUID=$($metaVolume.DeviceID)"
    }
    else {
        Write-Log "Metadata volume (label=Metadata) not found via CIM." -Level WARN
    }

    Add-FCGVolumeConfiguration -MetadataVolume $Script:MetadataVolume -PrimaryEndpoint $Script:StorageAccountName -SecondaryEndpoint $Script:StorageAccountName
    Write-Log "[Add-FCGVolumeConfiguration] Volume configuration for $($Script:MetadataVolume) added. Primary and secondary endpoints set to $($Script:StorageAccountName).`n`n"

    Write-Log "CAEVES FCG Agent configured successfully."
}

function Start-CaevesServices {
    <#
    .SYNOPSIS
        Starts the CAEVES filter driver and gateway service. Kept out of Set-CaevesAgentConfiguration so a service
        that fails to start can be retried without repeating the configuration cmdlets, which cannot run twice.
    #>
    Write-Log 'Starting CAEVES services...'

    sc.exe config "fcgmf" start= system | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "sc.exe config fcgmf failed with exit code $LASTEXITCODE. Check that the CAEVES software is installed."
    }
    Start-Service -Name 'fcgmf'

    $startRequestedAt = Get-Date
    try {
        Start-Service -Name 'FileCloudGatewayService'
    }
    catch {
        # "Cannot start service" hides the reason; the event log has it.
        Write-CaevesServiceDiagnostics -Since $startRequestedAt.AddMinutes(-1)
        throw
    }
    Write-Log "Services started: fcgmf, FileCloudGatewayService"
}

function Write-CaevesServiceDiagnostics {
    param([Parameter(Mandatory)][datetime]$Since)

    Write-Log 'FileCloudGatewayService did not start. Related event log entries:' -Level ERROR
    $events = @()
    $events += @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Service Control Manager'; StartTime = $Since } -ErrorAction SilentlyContinue |
        Where-Object { $_.Message -match 'FileCloudGateway' })
    $events += @(Get-WinEvent -FilterHashtable @{ LogName = 'Application'; Level = 1, 2; StartTime = $Since } -ErrorAction SilentlyContinue)

    if ($events.Count -eq 0) {
        Write-Log '  (no related entries found in the System or Application log)' -Level ERROR
        return
    }
    foreach ($e in ($events | Sort-Object TimeCreated)) {
        $text = (@("$($e.Message)" -split "`r?`n" | Where-Object { $_.Trim() }) | Select-Object -First 5) -join ' | '
        Write-Log "  [$($e.LogName)] $($e.ProviderName) (event $($e.Id)): $text" -Level ERROR
    }
}

function Set-VssMaxShadowCopies {
    <#
    .SYNOPSIS
        Sets the MaxShadowCopies registry DWORD (default $Script:MaxSnapshotCount) under VSS\Settings.
    #>
    param ([int] $MaxCount = $Script:MaxSnapshotCount)

    Write-Log "Setting MaxShadowCopies = $MaxCount..."
    $regPath = 'HKLM:\System\CurrentControlSet\Services\VSS\Settings'
    if (-not (Test-Path $regPath)) {
        New-Item -Path $regPath -Force | Out-Null
    }
    New-ItemProperty -Path $regPath -Name 'MaxShadowCopies' -Value $MaxCount -PropertyType DWord -Force | Out-Null
    Write-Log "MaxShadowCopies set to $MaxCount."
}

function Update-StorageCapacityAsync {
    param(
        [string]$Environment = $Script:EnvironmentName
    )

    # Construct JSON payload
    $payload = @{
        action             = "init"
        marketplaceid      = $Script:SaasSubscriptionId
        storageaccountname = $Script:StorageAccountName
    } | ConvertTo-Json -Depth 3
    Write-Log "[UpdateStorageCapacityAsync] Constructed Payload: $payload" -Level DEBUG

    # Construct endpoint URL
    switch ($Environment) {
        Development { $uri = "https://caevessaashelperfunc-dev.azurewebsites.net/api/UpsertCaevesCapacityMetrics?code=DK9f11RSFzokW-gATliApXTfciuejRMxX4FU7lUPw2JHAzFuoFd6GA==" }
        Staging { $uri = "https://caeves-saashelper-stg.azurewebsites.net/api/UpsertCaevesCapacityMetrics?code=D_DZN0bKCy1Z0LtdbGoxBWW-2VfrhxQiZujJOXd3QW32AzFuiwv7zA==" }
        Production { $uri = "https://caeves-saashelper.azurewebsites.net/api/UpsertCaevesCapacityMetrics?code=HRMdSWn7FlTxAtbqSf6V9a4HIXQdKBRDrE_j4vUr4zsdAzFuC2m_JA==" }
    }

    # Send POST request
    try {
        Write-Log "[UpdateStorageCapacityAsync] Invoking Capacity metrics update endpoint."
        $response = Invoke-RestMethod -Uri $uri -Method Post -Body $payload -Headers @{"Content-Type" = "application/json" }
        Write-Log "[UpdateStorageCapacityAsync] Update successful."
    }
    catch {
        Write-Log "[UpdateStorageCapacityAsync] Request failed: $_" -Level ERROR
    }
}

function Write-DetailedError {
    param([Parameter(Mandatory)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord)

    Write-Log "========== ERROR START =========="  -Level ERROR
    Write-Log "Message        : $($ErrorRecord.Exception.Message)" -Level ERROR
    Write-Log "Type           : $($ErrorRecord.Exception.GetType().FullName)" -Level ERROR

    if ($ErrorRecord.Exception.InnerException) {
        Write-Log "Inner Exception: $($ErrorRecord.Exception.InnerException.Message)" -Level ERROR
    }

    Write-Log "Category       : $($ErrorRecord.CategoryInfo)" -Level ERROR
    Write-Log "Target Object  : $($ErrorRecord.TargetObject)" -Level ERROR
    Write-Log "FQID           : $($ErrorRecord.FullyQualifiedErrorId)" -Level ERROR
    Write-Log "Line           : $($ErrorRecord.InvocationInfo.ScriptLineNumber)" -Level ERROR
    Write-Log "Command        : $($ErrorRecord.InvocationInfo.MyCommand)" -Level ERROR
    Write-Log "Position       : $($ErrorRecord.InvocationInfo.PositionMessage)" -Level ERROR
    Write-Log "Stack Trace    : $($ErrorRecord.ScriptStackTrace)" -Level ERROR
    Write-Log "========== ERROR END ==========" -Level ERROR
}

function Invoke-CaevesProvisioning {
    <#
    .SYNOPSIS
        Orchestrates the CAEVES hybrid first-boot configuration (Phase 2).
        Each step is checkpointed, so a re-run continues at the step that failed.
        Errors are logged by the main execution block.
    #>
    Write-Log '===== CAEVES Hybrid Provisioning Started ====='
    Assert-Administrator

    # Step 1: Load ConfigParameters.json into $Script: variables. It only fills memory, so it runs every time,
    # and a missing field fails here before any disk is touched.
    Invoke-SetupStep 'LoadConfiguration' {
        Import-CaevesConfiguration
        $Script:StorageConnectionString = "DefaultEndpointsProtocol=https;AccountName=$($Script:StorageAccountName);AccountKey=$($Script:StorageAccountKey);EndpointSuffix=core.windows.net"
    } -AlwaysRun

    # Step 2: Partition data disks and set permissions on Metadata volume for the FCG Agent
    Invoke-SetupStep 'DataDisks' { Initialize-CaevesDataDisks }
    Invoke-SetupStep 'MetadataPermissions' { Set-PermissionsToMetadataVolume }

    # Step 3: Environment variables
    Invoke-SetupStep 'SetEnvironment' { Set-Environment -Environment $Script:EnvironmentName }

    # Step 4: Configure CAEVES FCG Agent
    Invoke-SetupStep 'AgentConfiguration' { Set-CaevesAgentConfiguration -StorageConnectionString $Script:StorageConnectionString }
    Invoke-SetupStep 'StartServices' { Start-CaevesServices }

    # Step 5: VSS registry tuning
    Invoke-SetupStep 'VssMaxShadowCopies' { Set-VssMaxShadowCopies -MaxCount $Script:MaxSnapshotCount }

    # Step 6: Metrics & billing
    Invoke-SetupStep 'BillingInit' { Update-StorageCapacityAsync -Environment $Script:EnvironmentName }

    # Step 7: VSS shadow storage routing
    Invoke-SetupStep 'VssShadowStorage' { Initialize-VssShadowStorage -MetadataVolume $Script:MetadataVolume.TrimEnd('\') -SnapshotsLabel $Script:SnapshotsLabel -MaxSize $Script:MaxSize }

    # Step 8: Initialize snapshot schedule tasks based on configuration
    Invoke-SetupStep 'SnapshotTasks' { Initialize-SnapshotTasks }

    # Step 9: Mark first boot complete
    New-Item -ItemType File -Path $Script:BootMarker -Force | Out-Null
    Write-Log "First-boot provisioning complete. Marker written at $($Script:BootMarker)."

    Write-Log '========== CAEVES Hybrid Provisioning Completed Successfully =========='
}

# =============================================
# MAIN EXECUTION
# =============================================

# Create C:\CAEVES\Logs before the first Write-Log so every message reaches the log file.
Initialize-CaevesDirectories
Write-Log "===== CAEVES Hybrid Server Setup Started ====="

# Recorded in the error log so a failure shows which part of the setup it came from.
$phase = 'Startup'

try {
    # --- Files generated by earlier versions directly in C:\CAEVES move into C:\CAEVES\Config ---
    Move-LegacyCaevesFiles

    # --- Resumed after the restart (or started by hand): the one-time resume task is no longer needed ---
    Remove-CaevesResumeTask

    # --- Progress options: applied before the first-boot gate, so they can also re-open a finished setup ---
    if ($ResetProgress) {
        if ($FromStep) { Write-Log "-ResetProgress was given, so -FromStep '$FromStep' is ignored." -Level WARN }
        Reset-SetupProgress
    }
    elseif ($FromStep) {
        Set-SetupStartStep -StepName $FromStep
    }

    # --- First-boot gate: checked before anything else so a re-run on a provisioned host changes nothing ---
    if (Test-Path $Script:BootMarker) {
        Write-Log "CAEVES already provisioned (boot.complete marker found at $($Script:BootMarker)). Nothing to do. Exiting."
        Write-Log "To run steps again use -FromStep <step> or -ResetProgress."
        exit 4
    }

    # --- Inputs: gather everything up front so the long install below never stalls on a prompt ---
    $phase = 'Inputs'
    Initialize-ConfigFile
    Resolve-CaevesEnvironment
    Sync-SetupStateWithConfig
    Write-SetupProgressSummary

    # SPN details, in order: command line, values saved by an earlier run, then (resume / PowerShell 7 relaunch)
    # the AZURE_* environment variables. Only what is still missing is prompted for.
    $savedSpn = Get-SavedSpnSettings
    if ($savedSpn) {
        if (-not $TenantId) { $TenantId = $savedSpn.TenantId }
        if (-not $ClientId) { $ClientId = $savedSpn.ClientId }
        if ($null -eq $ClientSecret) { $ClientSecret = $savedSpn.ClientSecret }
    }

    if ($ConfigureOnly) {
        if (-not $TenantId) { $TenantId = $env:AZURE_TENANT_ID }
        if (-not $ClientId) { $ClientId = $env:AZURE_CLIENT_ID }
        if ($null -eq $ClientSecret -and $env:AZURE_CLIENT_SECRET) {
            $ClientSecret = ConvertTo-SecureString $env:AZURE_CLIENT_SECRET -AsPlainText -Force
        }
    }

    $TenantId = Read-SpnValue -Prompt 'Azure tenant ID (GUID)' -Current $TenantId -Guid
    $ClientId = Read-SpnValue -Prompt 'Service principal client (application) ID (GUID)' -Current $ClientId -Guid
    $ClientSecret = Read-SpnSecret -Current $ClientSecret
    Set-AzureServicePrincipalEnvironment -TenantId $TenantId -ClientId $ClientId -ClientSecret $ClientSecret

    # Save on the first run, and again whenever a value was entered or passed that differs from the saved one.
    $spnChanged = (-not $savedSpn) -or
    ($TenantId -ne $savedSpn.TenantId) -or
    ($ClientId -ne $savedSpn.ClientId) -or
    (-not [object]::ReferenceEquals($ClientSecret, $savedSpn.ClientSecret))
    if ($spnChanged) {
        Save-SpnSettings -TenantId $TenantId -ClientId $ClientId -ClientSecret $ClientSecret
    }

    # --- Phase 1: Server prerequisites ---
    if (-not $ConfigureOnly) {
        $phase = 'Phase 1 (server prerequisites)'
        New-Item -Path "C:\WINDOWS\OEM" -ItemType Directory -Force | Out-Null

        Invoke-SetupStep 'HardenSystem' { Set-SystemHardening }
        Invoke-SetupStep 'RemoveWirelessLAN' { Remove-WirelessLANService }
        Invoke-SetupStep 'SetWallpaper' { Set-WallpaperAndUI }
        Invoke-SetupStep 'UpdateDefaultWallpaper' { Update-DefaultWallpaper }
        Invoke-SetupStep 'InstallDependencies' { Install-Dependencies }
        Invoke-SetupStep 'InstallCaevesSoftware' { Install-CaevesSoftware }
        Invoke-SetupStep 'WindowsUpdate' { Start-WindowsServerUpdate -Install }
        Invoke-SetupStep 'DesktopShortcuts' { New-DesktopShortcuts }

        # Restart between the phases: Windows Update can finish, and services only see the new machine
        # environment variables (AZURE_*, DOTNET_ENVIRONMENT) after a restart. The step is recorded as completed
        # before the restart, so the run after the restart goes straight to Phase 2.
        Invoke-SetupStep 'RestartForPhase2' {
            if (-not $NoRestart) { Register-CaevesResumeTask }
            $Script:RestartRequested = $true
        }

        Write-Log "Prerequisites and CAEVES software installation complete."

        if ($Script:RestartRequested) {
            if ($NoRestart) {
                Write-Log '-NoRestart: the server was not restarted. Restart it, sign in and run this script again to continue with the CAEVES configuration.' -Level WARN
                exit 3010
            }

            Write-Log 'Restarting the server in 30 seconds. Sign in again with the same account afterwards and the setup continues automatically in PowerShell 7.' -Level WARN
            Write-Log 'Press Ctrl+C now to cancel the automatic restart. The setup then continues when you restart the server and sign in.' -Level WARN
            Start-Sleep -Seconds 30
            Write-Log 'Restarting now.'
            Restart-Computer -Force
            exit 0   # Restart-Computer returns before the shutdown; stop here so Phase 2 does not start
        }
    }

    # --- Phase 2: CAEVES configuration (reads C:\CAEVES\Config\ConfigParameters.json) ---
    $phase = 'Phase 2 (CAEVES configuration)'
    Initialize-CaevesModulePath

    # The Caeves module needs PowerShell 7. After the restart the resume task starts the script in pwsh directly;
    # when it is started by hand in Windows PowerShell, continue the configuration in pwsh.
    if ($PSVersionTable.PSVersion.Major -lt 7) {
        if (-not (Test-Path $Script:PwshPath)) {
            throw "PowerShell 7 was not found at $($Script:PwshPath). Check that the PowerShell installer in Phase 1 completed."
        }
        Write-Log "Continuing the CAEVES configuration in PowerShell 7..."
        & $Script:PwshPath -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -ConfigureOnly
        exit $LASTEXITCODE
    }

    if (-not (Get-Module -ListAvailable -Name Caeves)) {
        throw "The Caeves PowerShell module was not found. Check that the CAEVES software installed correctly (C:\Temp\CAEVES-Install.log)."
    }

    Invoke-CaevesProvisioning
}
catch {
    Write-Log "CAEVES Hybrid Server Setup failed during: $phase" -Level ERROR
    Write-DetailedError -ErrorRecord $_

    $failedStep = $null
    try { $failedStep = (Get-SetupState).FailedStep } catch { }
    if ($failedStep) {
        Write-Log "Progress is saved in $($Script:StateFile). Fix the problem and run this script again: it resumes at step '$failedStep'." -Level ERROR
    }
    else {
        Write-Log "Fix the problem and run this script again. Steps that already completed are skipped." -Level ERROR
    }
    exit 1
}
