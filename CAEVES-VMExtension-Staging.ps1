#Requires -RunAsAdministrator
#Requires -Modules Az.Storage
# ============================================================================================================================
# CAEVES-VMExtension-Staging.ps1
# CAEVES Configuration Script for Azure Deployment
# This script is hosted in a storage account and invoked by the Azure CustomScriptExtension.
#
# Version History:
#   0.9.6  - June 6, 2025       - Jaap van Duijvenbode  - Initial release
#   0.9.7  - October 17, 2025   - Archana Patil          - Adjusted Data Disk Initialization for new partitioning scheme
#   2.0.2  - December 8, 2025   - Archana Patil          - Updated to use Caeves module cmdlets
#   2.0.3  - April 6, 2026     - Archana Patil          - Refactored into proper function-based architecture;
#                                                           Added WS2025 NVMe disk identification support
#   2.0.4  - April 8, 2026     - Archana Patil          - Structured logging via Write-Log [YYYY-MM-DD HH:mm:ss] [LEVEL]
# ============================================================================================================================

[CmdletBinding()]
param (
    [Parameter(Mandatory)] [string] $vmName,
    [Parameter(Mandatory)] [string] $ResourceGroupName,
    [Parameter(Mandatory)] [string] $subscriptionId,
    [Parameter(Mandatory)] [string] $StorageAccountName,
    [Parameter(Mandatory)] [string] $StorageAccountKey,
    [Parameter(Mandatory)] [string] $StorageAccountResourceId,
    [Parameter(Mandatory)] [string] $ContainerName,
    [Parameter(Mandatory)] [string] $SnapshotsContainerName,
    [Parameter(Mandatory)] [string] $TableName,
    [Parameter(Mandatory)] [string] $ProcessTableName,
    [Parameter(Mandatory)] [string] $CaevesConfigTableName,
    [Parameter(Mandatory)] [string] $SaasOfferId,
    [Parameter(Mandatory)] [string] $SaasSubscriptionId,
    [Parameter(Mandatory)] [string] $AzureSubscriptionId,
    [Parameter(Mandatory)] [string] $PurchaserId,
    [string] $EnableDomainJoin,
    [string] $AdFQDN,
    [string] $OrganizationalUnit,
    [int]    $MetaSnapFrequency,
    [string] $EnableDailySnapshot,
    [string] $MetaSnapDailyTime,
    [string] $EnableWeeklySnapshot,
    [string] $MetaSnapWeeklyDay,
    [string] $MetaSnapWeeklyTime,
    [string] $EnableMonthlySnapshot,
    [string] $MetaSnapMonthlyWeekday,
    [string] $MetaSnapMonthlyTime,
    [string] $MetaForceSnapMonthly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ================================================================================================
# Script-scoped constants
# ================================================================================================
$Script:CaevesRoot = 'C:\CAEVES'
$Script:LogPath = 'C:\CAEVES\Logs'
$Script:ConfigPath = 'C:\CAEVES\Config'
$Script:ConfigFile = 'C:\CAEVES\Config\FCGConfig.json'
$Script:LogFile = $Script:LogPath + '\Azure-Deployment.log'
$Script:BootMarker = 'C:\CAEVES\boot.complete'
$Script:TempPath = 'C:\Temp'
$Script:CacheDirPath = 'G:\Cache'
$Script:MaxSnapshotCount = 500
$Script:MetadataVolume = 'F:\'
$Script:EnvironmentName = 'Staging'

# ================================================================================================
# Region: Logging
# ================================================================================================
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
    Add-Content -Path $Script:LogFile -Value $entry -ErrorAction SilentlyContinue
}

# ==============================================================================================
# Region: Disk Initialization
# ==============================================================================================
function Initialize-CaevesDataDisks {
    Write-Log 'Initializing data disks with custom partitioning...'

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

# ==============================================================================================
# Region: Permissions Configuration for Metadata Volume
# Note: The Metadata volume will be used for CAEVES configuration and must be accessible by the CAEVES service process, which runs under the Local Service account. 
#       By default, newly formatted volumes grant full access to Administrators and SYSTEM, but only read & execute permissions to Local Service. 
#       We need to grant Local Service full control over the Metadata volume (F:) to ensure CAEVES can read/write its configuration and state.
# ==============================================================================================
function Set-PermissionsToMetadataVolume {
    try {
        Write-Output "Checking for F: drive..."

        $timeout = 300
        $elapsed = 0

        while (!(Test-Path "F:\")) {
            if ($elapsed -ge $timeout) {
                throw "F: drive not available within timeout."
            }
            Start-Sleep -Seconds 5
            $elapsed += 5
        }

        Write-Output "F: drive found. Running icacls..."

        # icacls F:\    : target the root of the Metadata volume
        #/inheritance:d : disable inheritance and remove inherited ACEs (we'll set explicit permissions)
        #/t             : (recursive) Applies the change to *all files and folders inside F:*
        #/c             : (continue on error) Continues execution even if some files throw errors (e.g., locked/system files)
        $result = icacls F:\ /inheritance:d /t /c

        Write-Output $result
        Write-Output "Completed successfully."

    }
    catch {
        Write-Error "Failed to apply permissions: $_"
    }
}

# ===========================================================================================
# Region: AES Encryption Helpers
# ===========================================================================================
function Get-AesIV {
    return [System.Convert]::FromBase64String('SFIkMnBJakhSJDJwSWoxMg==')  # 16 bytes
}

function Get-AesKey {
    param ([string] $RawKey)

    $moreSize = 128
    while (($RawKey.Length * 8) -gt $moreSize) { $moreSize += 64 }
    $padded = $RawKey.PadRight($moreSize / 8, ' ')
    return [System.Text.Encoding]::ASCII.GetBytes($padded)
}

function ConvertTo-EncryptedString {
    param ([Parameter(Mandatory)] [string] $PlainText)

    $aes = [System.Security.Cryptography.Aes]::Create()
    $aes.Key = Get-AesKey '36C032E6'
    $aes.IV = Get-AesIV

    $ms = New-Object System.IO.MemoryStream
    $encryptor = $aes.CreateEncryptor()
    $cs = New-Object System.Security.Cryptography.CryptoStream($ms, $encryptor, [System.Security.Cryptography.CryptoStreamMode]::Write)

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($PlainText)
    $cs.Write($bytes, 0, $bytes.Length)
    $cs.FlushFinalBlock()
    $cs.Close()
    $aes.Dispose()

    $result = [Convert]::ToBase64String($ms.ToArray())
    $ms.Close()
    return $result
}

# ---------------------- HELPER FUNCTIONS -----------------------------------------
# CAEVES Snapshot Scheduling and VSS Shadow Storage Configuration
# Note: This section assumes the Snapshots and Metadata volumes are on the same disk (as configured in Initialize-DataDisks) 
# and that the Snapshots volume is large enough to accommodate shadow storage for the Metadata volume.

function Assert-Administrator {
    $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($currentIdentity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Please run this script in an elevated PowerShell (Run as Administrator)."
    }
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
#---------------------------- END HELPER FUNCTIONS ----------------------------------------------


#-------------------------------------------------------------------------------------------------------------------------------
# Initialize Snapshot Configuration Process: Identify volumes, assign drive letter if needed, and set shadow storage for VSS
#-------------------------------------------------------------------------------------------------------------------------------
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

#------------------------------------------------------------------------------------------
# Set up Shadow Storage for VSS on the Metadata volume, pointing to Snapshots volume
#------------------------------------------------------------------------------------------
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

#-------------------------------------------------------------------------------------------------
# Schedule Snapshot Tasks
#-------------------------------------------------------------------------------------------------
function Initialize-SnapshotTasks {

    $schedules = @()

    # Set up scheduled tasks for snapshots if retention values are set
    Write-Log "Configuring snapshot schedules based on provided parameters..."

    # Daily
    if ($EnableDailySnapshot) {
        $schedules += @{
            Type = "Daily"
            Time = $MetaSnapDailyTime
        }
        Write-Log "Daily    : Enabled=$EnableDailySnapshot, Time=$MetaSnapDailyTime"
    }

    # Weekly
    if ($EnableWeeklySnapshot) {
        $schedules += @{
            Type    = "Weekly"
            WeekDay = $MetaSnapWeeklyDay
            Time    = $MetaSnapWeeklyTime
        }
        Write-Log "Weekly   : Enabled=$EnableWeeklySnapshot,  Day=$MetaSnapWeeklyDay, Time=$MetaSnapWeeklyTime"
    }

    # Monthly
    if ($EnableMonthlySnapshot) {
        # Parse value like "LastSunday", "FirstMonday", etc.
        if ($MetaSnapMonthlyWeekday -match '^(First|Second|Third|Fourth|Last)(Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday)$') {        
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
                Time        = $MetaSnapMonthlyTime
                ForceSnap   = $MetaForceSnapMonthly
            }
            Write-Log "Monthly  : Enabled=$EnableMonthlySnapshot, Weekday=$MetaSnapMonthlyWeekday, Time=$MetaSnapMonthlyTime, ForceSnap=$MetaForceSnapMonthly"
        }
        else {
            throw "Invalid Monthly Weekday format: $MetaSnapMonthlyWeekday"
        }
    }

    New-FCGSnapshotScheduler -Name "FCGSnapshotPolicy" -Schedules $schedules
    Write-Log "Snapshot scheduling configuration complete."
}

# =============================================================================================
# Region: Provisioning Steps
# =============================================================================================
function Initialize-CaevesDirectories {
    New-Item -Path $Script:CaevesRoot  -ItemType Directory -Force | Out-Null
    New-Item -Path $Script:LogPath     -ItemType Directory -Force | Out-Null
    New-Item -Path $Script:ConfigPath  -ItemType Directory -Force | Out-Null
    New-Item -Path $Script:TempPath    -ItemType Directory -Force | Out-Null
}

#-------------------------------------------------------------------------------------------------
# Build the configuration object from parameters and save it to disk for the CAEVES service to consume.
#-------------------------------------------------------------------------------------------------
function Save-CaevesConfiguration {
    <#
    .SYNOPSIS
        Builds the FCGConfig.json from script parameters and writes it to the config directory.
    #>
    param ([string] $StorageConnectionString)

    $config = [ordered]@{
        SaasOfferId              = $SaasOfferId
        SaasSubscriptionId       = $SaasSubscriptionId
        AzureSubscriptionId      = $AzureSubscriptionId
        PurchaserId              = $PurchaserId
        VMName                   = $vmName
        ResourceGroupName        = $ResourceGroupName
        SubscriptionId           = $subscriptionId
        StorageAccountName       = $StorageAccountName
        StorageConnectionString  = $StorageConnectionString
        StorageAccountResourceId = $StorageAccountResourceId
        ContainerName            = $ContainerName
        SnapshotsContainerName   = $SnapshotsContainerName
        TableName                = $TableName
        ProcessTableName         = $ProcessTableName
        CaevesConfigTableName    = $CaevesConfigTableName
        EnableDomainJoin         = $EnableDomainJoin
        AdFQDN                   = $AdFQDN
        OrganizationalUnit       = $OrganizationalUnit
        MetaSnapFrequency        = $MetaSnapFrequency
        EnableDailySnapshot      = $EnableDailySnapshot
        MetaSnapDailyTime        = $MetaSnapDailyTime
        EnableWeeklySnapshot     = $EnableWeeklySnapshot
        MetaSnapWeeklyDay        = $MetaSnapWeeklyDay
        MetaSnapWeeklyTime       = $MetaSnapWeeklyTime
        EnableMonthlySnapshot    = $EnableMonthlySnapshot
        MetaSnapMonthlyWeekday   = $MetaSnapMonthlyWeekday
        MetaSnapMonthlyTime      = $MetaSnapMonthlyTime
        MetaForceSnapMonthly     = $MetaForceSnapMonthly
        DeploymentDate           = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    }

    $config | ConvertTo-Json -Depth 10 | Out-File -FilePath $Script:ConfigFile -Encoding UTF8
    Write-Log "Configuration saved to: $Script:ConfigFile"
}

#-------------------------------------------------------------------------------------------------
# Validate connectivity to Azure Storage resources
#-------------------------------------------------------------------------------------------------
function Test-StorageConnectivity {
    <#
    .SYNOPSIS
        Validates that the required Azure Storage containers and tables exist and are reachable.
    #>

    param (
        [Parameter(Mandatory)]
        $Context   # Removed strong typing (PS7 safe)
    )

    Write-Log 'Validating storage account connectivity...'

    # Validate Containers
    foreach ($name in @($ContainerName, $SnapshotsContainerName)) {
        try {
            $c = Get-AzStorageContainer -Name $name -Context $Context -ErrorAction Stop
            Write-Log "Container '$name' : OK"
        }
        catch {
            Write-Log "Container '$name' not found (may be created by another process)." -Level WARN
        }
    }

    # Validate Tables
    foreach ($name in @($TableName, $ProcessTableName, $CaevesConfigTableName)) {
        try {
            $t = Get-AzStorageTable -Name $name -Context $Context -ErrorAction Stop
            Write-Log "Table '$name' : OK"
        }
        catch {
            Write-Log "Table '$name' not found (may be created by another process)." -Level WARN
        }
    }
    Write-Log "Storage connectivity validation complete."
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

    # Update CAEVES Configuration desktop shortcut
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut("$env:PUBLIC\Desktop\CAEVES Configuration.lnk")
    $shortcut.WorkingDirectory = 'C:\Program Files\Caeves\FCGUI'
    $shortcut.Save()
    Write-Log 'Desktop shortcut updated.'
}

#-------------------------------------------------------------------------------------------------
# Configure CAEVES FCG Agent: Set registry keys, configure storage, and start services
#-------------------------------------------------------------------------------------------------
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
        Name                     = $StorageAccountName
        StorageAccountName       = $StorageAccountName
        StorageType              = 'azureblob'
        StorageConnectionString  = $StorageConnectionString
        ContainerName            = $ContainerName
        SnapshotsContainerName   = $SnapshotsContainerName
        StorageAccountResourceId = $StorageAccountResourceId
    }
    if (-not [string]::IsNullOrWhiteSpace($TableName)) { $storageParams['MetadataTableName'] = $TableName }
    if (-not [string]::IsNullOrWhiteSpace($ProcessTableName)) { $storageParams['MetadataProcessTableName'] = $ProcessTableName }
    if (-not [string]::IsNullOrWhiteSpace($CaevesConfigTableName)) { $storageParams['CaevesConfigTableName'] = $CaevesConfigTableName }

    Add-FCGStorageConfiguration @storageParams
    Write-Log "[Add-FCGStorageConfiguration] Storage configuration for '$StorageAccountName' added successfully.`n`n"

    # License
    Set-FCGSaasSubscriptionId -SubscriptionId $SaasSubscriptionId
    Write-Log "[Set-FCGSaasSubscriptionId] SaaSSubscriptionID set to: $SaasSubscriptionId `n`n"

    # Migration mode
    Set-FCGPurgeOnFlush -Value 1
    Write-Log "[Set-FCGPurgeOnFlush] PurgeOnFlush set to 1.`n`n"

    # Snapshot frequency
    Set-FCGSnapshotFrequency -Value $MetaSnapFrequency
    Write-Log "[Set-FCGSnapshotFrequency] Snapshot frequency set to: $MetaSnapFrequency `n`n"


    # Cache folder and volume configuration
    Set-FCGCacheFolderPath -Path $Script:CacheDirPath
    Write-Log "[Set-FCGCacheFolderPath] Cache folder path set: $Script:CacheDirPath `n`n"

    # Log Metadata volume info
    $metaVolume = Get-CimInstance -ClassName Win32_Volume | Where-Object { $_.Label -eq 'Metadata' }
    if ($metaVolume) {
        Write-Log "Metadata volume : $($metaVolume.DriveLetter) | FS=$($metaVolume.FileSystem) | GUID=$($metaVolume.DeviceID)"
    }
    else {
        Write-Log "Metadata volume (label=Metadata) not found via CIM." -Level WARN
    }

    Add-FCGVolumeConfiguration -MetadataVolume $Script:MetadataVolume -PrimaryEndpoint $StorageAccountName -SecondaryEndpoint $StorageAccountName
    Write-Log "[Add-FCGVolumeConfiguration] Volume configuration for $Script:MetadataVolume added. Primary and secondary endpoints set to $StorageAccountName.`n`n"

    # Start services
    sc.exe config "fcgmf" start= system
    Start-Service -Name 'fcgmf'
    
    Start-Service -Name 'FileCloudGatewayService'
    Write-Log "Services started: fcgmf, FileCloudGatewayService"
    Write-Log "CAEVES FCG Agent configured successfully."
}

#-------------------------------------------------------------------------------------------------
# Configure VSS Shadow Storage: Set the MaxShadowCopies registry value and configure shadow storage for the Metadata volume
#-------------------------------------------------------------------------------------------------
function Set-VssMaxShadowCopies {
    <#
    .SYNOPSIS
        Sets the MaxShadowCopies registry DWORD to 512 under VSS\Settings.
    #>
    param ([int] $MaxCount = 512)

    Write-Log "Setting MaxShadowCopies = $MaxCount..."
    $regPath = 'HKLM:\System\CurrentControlSet\Services\VSS\Settings'
    if (-not (Test-Path $regPath)) {
        New-Item -Path $regPath -Force | Out-Null
    }
    New-ItemProperty -Path $regPath -Name 'MaxShadowCopies' -Value $MaxCount -PropertyType DWord -Force | Out-Null
    Write-Log "MaxShadowCopies set to $MaxCount."
}

#-------------------------------------------------------------------------------------------------
# Create record in CAEVES Metrics & Billing Table 
# ------------------------------------------------------------------------------------------------
function Update-StorageCapacityAsync {
    param(
        [string]$Environment
    )

    # Construct JSON payload
    $payload = @{
        action             = "init"
        marketplaceid      = $saasSubscriptionId
        storageaccountname = $StorageAccountName
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

# ========================================================================================
# Region: Error Handling
# ========================================================================================
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


# ========================================================================================
# Region: Entry Point
# ========================================================================================
function Invoke-CaevesProvisioning {
    <#
    .SYNOPSIS
        Orchestrates the full CAEVES first-boot provisioning sequence.
    #>

    # --- Setup: directories and transcript ---
    Initialize-CaevesDirectories
    Start-Transcript -Path $Script:LogFile -Append

    try {
        Write-Log '===== CAEVES Provisioning Started ====='
        Assert-Administrator

        $storageConnectionString = "DefaultEndpointsProtocol=https;AccountName=$StorageAccountName;AccountKey=$StorageAccountKey;EndpointSuffix=core.windows.net"

        # Step 1: Save configuration file
        Save-CaevesConfiguration -StorageConnectionString $storageConnectionString

        # Step 2: Validate storage connectivity
        Import-Module Az.Storage -Force -ErrorAction Stop
        $storageContext = New-AzStorageContext -StorageAccountName $StorageAccountName -StorageAccountKey $StorageAccountKey
        Test-StorageConnectivity -Context $storageContext

        # Step 3: First-boot gate
        if (Test-Path $Script:BootMarker) {
            Write-Log 'CAEVES already provisioned (boot.complete marker found). Skipping first-boot steps.'
        }
        else {
            Write-Log 'Running CAEVES first-boot provisioning...'

            # Step 3a: Partition data disks and set permissions on Metadata volume for the FCG Agent
            Initialize-CaevesDataDisks
            Set-PermissionsToMetadataVolume

            # Step 3b: Install software
            Install-CaevesSoftware

            # Step 3c: Mark first boot complete
            New-Item -ItemType File -Path $Script:BootMarker -Force | Out-Null
            Write-Log 'First-boot provisioning complete. Marker written.'
        }


        # Step 4: Configure CAEVES FCG Agent (runs on every extension execution)
        if (Test-Path $Script:ConfigFile) {

            Set-CaevesAgentConfiguration -StorageConnectionString $storageConnectionString
        }
        else {
            Write-Log "Config file not found at '$Script:ConfigFile'. Skipping agent configuration." -Level WARN
        }

        # Step 5: VSS registry tuning
        Set-VssMaxShadowCopies -MaxCount $Script:MaxSnapshotCount

        # Step 6: Metrics & billing
        Update-StorageCapacityAsync -Environment $Script:EnvironmentName

        # Step 7: VSS shadow storage routing
        Initialize-VssShadowStorage -MetadataVolume "F:" -SnapshotsLabel "Snapshots" -MaxSize "UNBOUNDED"

        # Step 8: Initialize snapshot schedule tasks based on configuration (if retention is configured)
        Initialize-SnapshotTasks

        Write-Log '========== CAEVES Provisioning Completed Successfully =========='
    }
    catch {
        Write-DetailedError -ErrorRecord $_
        exit 1
    }
    finally {
        Stop-Transcript
    }
}

# ===================================================================
# Script entry point
# ===================================================================
Invoke-CaevesProvisioning
