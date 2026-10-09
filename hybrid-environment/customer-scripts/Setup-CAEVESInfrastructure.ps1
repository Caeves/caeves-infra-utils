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
# Parameters (Azure service principal). Any that are not supplied are prompted for:
#   -TenantId      Azure tenant ID (GUID)
#   -ClientId      Service principal application (client) ID (GUID)
#   -ClientSecret  Service principal client secret (SecureString)
#   -ConfigureOnly Skip the prerequisites and run only the CAEVES configuration. Used to resume a
#                  run, and by the script itself to continue in PowerShell 7. SPN details are
#                  taken from the AZURE_* environment variables when not supplied.
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
    [switch]$ConfigureOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# =============================================
# SCRIPT-SCOPED CONSTANTS (CAEVES configuration)
# =============================================
# The environment name is used to select the appropriate CAEVES installer manifest and set the DOTNET_ENVIRONMENT variable.
$Script:EnvironmentName = 'Production'

$Script:CaevesRoot = 'C:\CAEVES'
$Script:LogPath = 'C:\CAEVES\Logs'
$Script:ConfigFile = 'C:\CAEVES\ConfigParameters.json'
$Script:LogFile = $Script:LogPath + '\OnPrem-Deployment.log'
$Script:BootMarker = 'C:\CAEVES\boot.complete'
$Script:TempPath = 'C:\Temp'
$Script:CacheDirPath = 'G:\Cache'
$Script:MaxSnapshotCount = 500
$Script:MetadataVolume = 'F:\'

$Script:SnapshotsLabel = 'Snapshots'
$Script:MaxSize = 'UNBOUNDED'
$Script:MoveExistingShadowStorage = $false

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

enum EnvironmentType {
    Development
    Staging
    Production
}

# =============================================
# FUNCTION DEFINITIONS - Server prerequisites
# =============================================

function Harden-System {
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

function Configure-WallpaperAndUI {
    Write-Log "Configuring Wallpaper"
    $wallpaper = "C:\WINDOWS\OEM\CAEVES-wallpaper.jpg"
    Invoke-WebRequest -Uri "https://caeveswebassets.blob.core.windows.net/caevesbuildimage/CAEVES-Windows-BG-2025-small.jpg" -OutFile $wallpaper
    Set-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name Wallpaper -Value $wallpaper
    Set-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name WallpaperStyle -Value 0
    Set-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name TileWallpaper -Value 0
    RUNDLL32.EXE user32.dll, UpdatePerUserSystemParameters
}

function Replace-DefaultWallpaper {
    Write-Log "Replacing default Windows wallpapers"

    $CustomWallpaper = "C:\Windows\OEM\CAEVES-wallpaper.jpg"
    $WallpaperMainFolder = "C:\Windows\Web\Wallpaper\Windows"
    $Wallpaper4KFolder = "C:\Windows\Web\4K\Wallpaper\Windows"
    $MainWallpaperFile = Join-Path $WallpaperMainFolder "img0.jpg"

    # --- MAIN WALLPAPER FOLDER ---
    Write-Log "=== Processing main wallpaper folder ==="
    Grant-AdminAccess -TargetPath $WallpaperMainFolder

    Get-ChildItem $WallpaperMainFolder -File | ForEach-Object {
        Write-Log "Deleting file: $($_.Name)"
        Remove-Item $_.FullName -Force
    }

    if (Test-Path $CustomWallpaper) {
        Copy-Item $CustomWallpaper $MainWallpaperFile -Force
        Write-Log "Copied custom wallpaper to $MainWallpaperFile"
    }
    else {
        Write-Warning "Custom wallpaper not found at $CustomWallpaper"
    }

    # --- 4K WALLPAPER FOLDER ---
    Write-Log "=== Processing 4K wallpaper folder ==="
    Grant-AdminAccess -TargetPath $Wallpaper4KFolder

    Get-ChildItem $Wallpaper4KFolder -File | ForEach-Object {
        Write-Log "Deleting file: $($_.Name)"
        Remove-Item $_.FullName -Force
    }

    if (Test-Path $CustomWallpaper) {
        Copy-Item $CustomWallpaper $Wallpaper4KFolder -Force
        Write-Log "Copied custom wallpaper into 4K wallpaper folder"
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
            Write-Log "DOTNET_ENVIRONMENT set to '$EnvironmentName'. Skipping MSI installation in development environment."
            $manifestUrl = " https://buildrepoprod.blob.core.windows.net/artifacts/CAEVES.FCG.App/branch/manifest.json"
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

function Install-CAEVESInstance {
    Write-Log "Installing CAEVES Instance Software"

    $msiUrl = "https://buildrepoprod.blob.core.windows.net/artifacts-prod/CAEVES.FCG.App/production/2.4/2.4.37.16381/CAEVES.FCG.App_Release_2.4.37.16381_2026-06-10_09-58.msi"
    $msiFile = "C:\Temp\CAEVES.FCG.App.msi"

    Write-Log "  Downloading CAEVES Instance MSI..."
    Invoke-WebRequest -Uri $msiUrl -OutFile $msiFile

    if (Test-Path $msiFile) {
        Write-Log "  Installing CAEVES Instance (silent)..."
        $msiArgs = "/i `"$msiFile`" /quiet /norestart /log `"C:\Temp\CAEVES-Install.log`""
        $installer = Start-Process msiexec.exe -ArgumentList $msiArgs -Wait -NoNewWindow -PassThru

        # Verify installation succeeded (0 = success, 3010 = success, reboot required)
        if ($installer.ExitCode -in 0, 3010) {
            Write-Log "  CAEVES Instance installed successfully"
        }
        else {
            throw "CAEVES Instance installer failed with exit code $($installer.ExitCode). Check the install log at C:\Temp\CAEVES-Install.log"
        }
    }
    else {
        Write-Warning "  CAEVES Instance MSI download failed - file not found at $msiFile"
    }
}



function Create-DesktopShortcuts {
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

function Initialize-CaevesModulePath {
    # The Caeves module is installed under the PowerShell 7 module folder; make sure it is searched.
    $modulePath = 'C:\Program Files\PowerShell\Modules'
    if ($env:PSModulePath -notlike "*$modulePath*") {
        $env:PSModulePath = "$modulePath;$env:PSModulePath"
    }
}

function Initialize-ConfigFile {
    # ConfigParameters.json is downloaded alongside this script; stage it where provisioning expects it.
    if (Test-Path $Script:ConfigFile) {
        Write-Log "Using existing config file: $($Script:ConfigFile)"
        return
    }

    if ($PSScriptRoot) {
        $source = Join-Path $PSScriptRoot 'ConfigParameters.json'
        if (Test-Path $source) {
            Copy-Item -Path $source -Destination $Script:ConfigFile -Force
            Write-Log "Copied $source to $($Script:ConfigFile)"
            return
        }
    }

    throw "ConfigParameters.json not found. Download it from your storage account into the same folder as this script (or to $($Script:ConfigFile)) and run the script again."
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

function Initialize-CaevesDataDisks {
    Write-Log 'Initializing data disks with custom partitioning...'

    # Safe to re-run: if the volumes from a previous run exist, there is nothing to initialize.
    $existingMetadata = Get-CimInstance -ClassName Win32_Volume -Filter "Label='Metadata'"
    $existingCache = Get-CimInstance -ClassName Win32_Volume -Filter "Label='Cache'"
    if ($existingMetadata -and $existingCache) {
        Write-Log 'Metadata and Cache volumes already exist. Skipping disk initialization.'
        return
    }

    # Get-Disk directly via IsBoot is faster than traversing Get-Partition | Get-Disk
    $allDisks = Get-Disk
    $osDisk = $allDisks | Where-Object { $_.IsBoot -eq $true }
    $dataDisks = $allDisks | Where-Object { $_.Number -ne $osDisk.Number -and $_.PartitionStyle -eq 'RAW' }

    if ($dataDisks.Count -lt 2) {
        Write-Log "Expected 2 uninitialized data disks. Found $($dataDisks.Count). Skipping initialization." -Level WARN
        exit 1
    }

    # Log disk locations for diagnostics
    $dataDisks | ForEach-Object { Write-Log "Disk $($_.Number) Location: '$($_.Location)'" }

    # Identify disks by LUN (works on WS2022 with SCSI controller: "...LUN 0", "...LUN 1")
    $fixedDisk = $dataDisks | Where-Object { $_.Location -match "LUN\s*0\b" }
    $sliderDisk = $dataDisks | Where-Object { $_.Location -match "LUN\s*1\b" }

    # Fallback for WS2025 Azure Edition (NVMe controller reports a different Location format)
    # Azure guarantees data disks are enumerated in LUN-attachment order, so sort by disk number.
    if (-not $fixedDisk -or -not $sliderDisk) {
        Write-Log "LUN-based disk identification failed (Location format may differ on this OS). Falling back to disk-number ordering." -Level WARN
        $sortedDisks = $dataDisks | Sort-Object -Property Number
        $fixedDisk = $sortedDisks[0]   # lowest disk number = LUN 0
        $sliderDisk = $sortedDisks[1]   # next disk number  = LUN 1
    }

    if (-not $fixedDisk -or -not $sliderDisk) {
        Write-Log "Could not identify both fixed and slider disks correctly. Skipping initialization." -Level WARN
        exit 1
    }

    # Initialize GPT
    Initialize-Disk -Number $fixedDisk.Number  -PartitionStyle GPT -PassThru | Out-Null
    Initialize-Disk -Number $sliderDisk.Number -PartitionStyle GPT -PassThru | Out-Null

    # Refresh after initialization
    $fixedDisk = Get-Disk -Number $fixedDisk.Number
    $sliderDisk = Get-Disk -Number $sliderDisk.Number

    Write-Log "Fixed  Disk (LUN 0): Disk $($fixedDisk.Number),  $([math]::Round($fixedDisk.Size / 1GB, 1))GB"
    Write-Log "Slider Disk (LUN 1): Disk $($sliderDisk.Number), $([math]::Round($sliderDisk.Size / 1GB, 1))GB"

    # --- Fixed disk: 90% Snapshots (no letter) + 10% Metadata (F:) ---
    $fixedSize = $fixedDisk.Size
    $snapshotSize = [math]::Floor($fixedSize * 0.90) - 1000000000   # leave 1 GB unallocated
    $metadataSize = [math]::Floor($fixedSize * 0.10)

    $volSnapshot = New-Partition -DiskNumber $fixedDisk.Number -Size $snapshotSize
    Format-Volume -Partition $volSnapshot -FileSystem NTFS -NewFileSystemLabel 'Snapshots' -Confirm:$false | Out-Null

    $volMetadata = New-Partition -DiskNumber $fixedDisk.Number -Size $metadataSize -DriveLetter F
    Format-Volume -Partition $volMetadata -FileSystem NTFS -NewFileSystemLabel 'Metadata'  -Confirm:$false | Out-Null

    # --- Slider disk: Cache (G:) ---
    $volCache = New-Partition -DiskNumber $sliderDisk.Number -UseMaximumSize -DriveLetter G
    Format-Volume -Partition $volCache -FileSystem NTFS -NewFileSystemLabel 'Cache' -Confirm:$false | Out-Null

    Write-Log "Fixed  disk partitioned: F: (Metadata $([math]::Round($metadataSize/1GB,1))GB), unlabelled (Snapshots $([math]::Round($snapshotSize/1GB,1))GB)"
    Write-Log "Slider disk partitioned: G: (Cache $([math]::Round($sliderDisk.Size/1GB,1))GB)"
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
    New-Item -Path $Script:TempPath    -ItemType Directory -Force | Out-Null
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
    $Script:MetaSnapFrequency = Get-ConfigProperty -Object $params -Name 'metaSnapFrequency'
    $Script:MetaSnapDailyTime = Get-ConfigProperty -Object $params -Name 'metaSnapDailyTime'
    $Script:MetaSnapWeeklyDay = Get-ConfigProperty -Object $params -Name 'metaSnapWeeklyDay'
    $Script:MetaSnapWeeklyTime = Get-ConfigProperty -Object $params -Name 'metaSnapWeeklyTime'
    $Script:MetaSnapMonthlyWeekday = Get-ConfigProperty -Object $params -Name 'metaSnapMonthlyWeekday'
    $Script:MetaSnapMonthlyTime = Get-ConfigProperty -Object $params -Name 'metaSnapMonthlyTime'
    $Script:MetaForceSnapMonthly = ConvertTo-ScriptBool (Get-ConfigProperty -Object $params -Name 'metaForceSnapMonthly')

    $environment = Get-ConfigProperty -Object $params -Name 'environment'
    if (-not [string]::IsNullOrWhiteSpace($environment)) {
        $Script:EnvironmentName = $environment
    }

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
    Write-Log "[Add-FCGStorageConfiguration] Storage configuration for '$($Script:StorageAccountName)' added successfully.`n`n"

    # License
    Set-FCGSaasSubscriptionId -SubscriptionId $Script:SaasSubscriptionId
    Write-Log "[Set-FCGSaasSubscriptionId] SaaSSubscriptionID set to: $($Script:SaasSubscriptionId) `n`n"

    # Migration mode
    Set-FCGPurgeOnFlush -Value 1
    Write-Log "[Set-FCGPurgeOnFlush] PurgeOnFlush set to 1.`n`n"

    # Snapshot frequency
    Set-FCGSnapshotFrequency -Value $Script:MetaSnapFrequency
    Write-Log "[Set-FCGSnapshotFrequency] Snapshot frequency set to: $($Script:MetaSnapFrequency) `n`n"

    # Cache folder and volume configuration
    Set-FCGCacheFolderPath -Path $Script:CacheDirPath
    Write-Log "[Set-FCGCacheFolderPath] Cache folder path set: $($Script:CacheDirPath) `n`n"

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

    # Start services
    sc.exe config "fcgmf" start= system
    Start-Service -Name 'fcgmf'

    Start-Service -Name 'FileCloudGatewayService'
    Write-Log "Services started: fcgmf, FileCloudGatewayService"
    Write-Log "CAEVES FCG Agent configured successfully."
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
        Orchestrates the full CAEVES hybrid first-boot provisioning sequence.
        Requires ConfigParameters.json to already exist at $Script:ConfigFile.
    #>

    # --- Setup: directories ---
    Initialize-CaevesDirectories

    try {
        Write-Log '===== CAEVES Hybrid Provisioning Started ====='
        Assert-Administrator

        # Step 1: First-boot gate
        if (Test-Path $Script:BootMarker) {
            Write-Log 'CAEVES already provisioned (boot.complete marker found). Exiting.'
            exit 4
        }

        Write-Log 'Running CAEVES first-boot provisioning...'

        # Step 3a: Partition data disks and set permissions on Metadata volume for the FCG Agent
        Initialize-CaevesDataDisks
        Set-PermissionsToMetadataVolume

        # Step 3: Load configuration from ConfigParameters.json into $Script: variables
        Import-CaevesConfiguration

        $storageConnectionString = "DefaultEndpointsProtocol=https;AccountName=$($Script:StorageAccountName);AccountKey=$($Script:StorageAccountKey);EndpointSuffix=core.windows.net"

        # Step 4: Environment variables
        Set-Environment -Environment $Script:EnvironmentName

        # Step 5: Configure CAEVES FCG Agent
        Set-CaevesAgentConfiguration -StorageConnectionString $storageConnectionString

        # Step 6: VSS registry tuning
        Set-VssMaxShadowCopies -MaxCount $Script:MaxSnapshotCount

        # Step 7: Metrics & billing
        Update-StorageCapacityAsync -Environment $Script:EnvironmentName

        # Step 8: VSS shadow storage routing
        Initialize-VssShadowStorage -MetadataVolume $Script:MetadataVolume.TrimEnd('\') -SnapshotsLabel $Script:SnapshotsLabel -MaxSize $Script:MaxSize

        # Step 9: Initialize snapshot schedule tasks based on configuration
        Initialize-SnapshotTasks

        # Step 10: Mark first boot complete
        New-Item -ItemType File -Path $Script:BootMarker -Force | Out-Null
        Write-Log "First-boot provisioning complete. Marker written at $($Script:BootMarker)."

        Write-Log '========== CAEVES Hybrid Provisioning Completed Successfully =========='
    }
    catch {
        Write-DetailedError -ErrorRecord $_
        exit 1
    }
}

# =============================================
# MAIN EXECUTION
# =============================================

# Create C:\CAEVES\Logs before the first Write-Log so every message reaches the log file.
Initialize-CaevesDirectories
Write-Log "===== CAEVES Hybrid Server Setup Started ====="

# --- Inputs: gather everything up front so the long install below never stalls on a prompt ---
Initialize-ConfigFile

if ($ConfigureOnly) {
    # Resuming or relaunched in PowerShell 7: SPN details come from the environment, never the command line.
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

# --- Phase 1: Server prerequisites ---
if (-not $ConfigureOnly) {
    New-Item -Path "C:\WINDOWS\OEM" -ItemType Directory -Force | Out-Null

    Harden-System
    Remove-WirelessLANService
    Configure-WallpaperAndUI
    Replace-DefaultWallpaper
    Install-Dependencies
    Install-CAEVESInstance
    Start-WindowsServerUpdate -Install
    Create-DesktopShortcuts

    Write-Log "Prerequisites and CAEVES software installation complete."
}

# --- Phase 2: CAEVES configuration (reads C:\CAEVES\ConfigParameters.json) ---
Initialize-CaevesModulePath

# The Caeves module needs PowerShell 7. PowerShell 7 is installed in Phase 1, so if this run started
# in Windows PowerShell, continue the configuration in pwsh.
if ($PSVersionTable.PSVersion.Major -lt 7) {
    $pwsh = 'C:\Program Files\PowerShell\7\pwsh.exe'
    if (-not (Test-Path $pwsh)) {
        throw "PowerShell 7 was not found at $pwsh. Check that the PowerShell installer in Phase 1 completed."
    }
    Write-Log "Continuing the CAEVES configuration in PowerShell 7..."
    & $pwsh -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -ConfigureOnly
    exit $LASTEXITCODE
}

if (-not (Get-Module -ListAvailable -Name Caeves)) {
    throw "The Caeves PowerShell module was not found. Check that the CAEVES software installed correctly (C:\Temp\CAEVES-Install.log)."
}

Invoke-CaevesProvisioning
