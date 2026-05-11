# -----------------------------------------------------------------------------------------------------
# CAEVES-VMExtension.ps1
# -----------------------------------------------------------------------------------------------------
# CAEVES Configuration Script for Azure Deployment
# This script should be hosted in your storage account and called by CustomScriptExtension
# 0.9.6 - June 6, 2025 - Jaap van Duijvenbode
# -----------------------------------------------------------------------------------------------------

param(
    [Parameter(Mandatory = $true)]
    [string]$vmName,

    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $true)]
    [string]$subscriptionId,

    [Parameter(Mandatory = $true)]
    [string]$StorageAccountName,
    
    [Parameter(Mandatory = $true)]
    [string]$StorageAccountKey,

    [Parameter(Mandatory = $true)]
    [string]$StorageAccountResourceId,

    [Parameter(Mandatory = $true)]
    [string]$ContainerName,
    
    [Parameter(Mandatory = $true)]
    [string]$SnapshotsContainerName,

    [Parameter(Mandatory = $true)]
    [string]$TableName,

    [Parameter(Mandatory = $true)]
    [string]$ProcessTableName,

    [Parameter(Mandatory = $true)]
    [string]$CaevesConfigTableName,    

    [Parameter(Mandatory = $true)]
    [string]$SaasOfferId,

    [Parameter(Mandatory = $true)]
    [string]$SaasSubscriptionId,

    [Parameter(Mandatory = $true)]
    [string]$AzureSubscriptionId,

    [Parameter(Mandatory = $true)]
    [string]$PurchaserId,
    [string]$EnableDomainJoin,
    [string]$AdFQDN,
    [string]$OrganizationalUnit,
    [int]$VssHourlyRetention,
    [int]$VssDailyRetention,
    [int]$VssMonthlyRetention,
    [int]$VssYearlyRetention,
    [int]$MetaSnapFrequency,
    [string]$MetaSnapDailyTime,
    [string]$MetaSnapWeeklyDay,
    [string]$MetaSnapWeeklyTime,
    [string]$MetaSnapMonthlyWeekday,
    [string]$MetaSnapMonthlyTime
)

# Set up logging
$logPath = "C:\CAEVES\Logs"
$configPath = "C:\CAEVES\Config"

# Create directories
New-Item -Path "C:\CAEVES" -ItemType Directory -Force | Out-Null
New-Item -Path $logPath -ItemType Directory -Force | Out-Null
New-Item -Path $configPath -ItemType Directory -Force | Out-Null

# Start logging
Start-Transcript -Path "$logPath\Azure-Deployment.log" -Append

try {
    Write-Host "Starting CAEVES configuration..." -ForegroundColor Green
    
    # Build storage connection string
    $storageConnectionString = "DefaultEndpointsProtocol=https;AccountName=$StorageAccountName;AccountKey=$StorageAccountKey;EndpointSuffix=core.windows.net"
    
    # Create configuration object
    $config = @{
        SaasOfferId             = $SaasOfferId
        SaasSubscriptionId      = $SaasSubscriptionId
        AzureSubscriptionId     = $AzureSubscriptionId
        PurchaserId             = $PurchaserId
        VMName                  = $vmName
        ResourceGroupName       = $ResourceGroupName
        SubscriptionId          = $subscriptionId
        StorageAccountName      = $StorageAccountName
        StorageConnectionString = $storageConnectionString
        StorageAccountResourceId = $StorageAccountResourceId
        ContainerName           = $ContainerName
        SnapshotsContainerName  = $SnapshotsContainerName        
        TableName               = $TableName
        ProcessTableName        = $ProcessTableName
        CaevesConfigTableName   = $CaevesConfigTableName
        EnableDomainJoin        = $EnableDomainJoin
        AdFQDN                  = $AdFQDN
        VssHourlyRetention      = $VssHourlyRetention
        VssDailyRetention       = $VssDailyRetention
        VssMonthlyRetention     = $VssMonthlyRetention
        VssYearlyRetention      = $VssYearlyRetention
        MetaSnapFrequency       = $MetaSnapFrequency
        MetaSnapDailyTime       = $MetaSnapDailyTime
        MetaSnapWeeklyDay       = $MetaSnapWeeklyDay
        MetaSnapWeeklyTime      = $MetaSnapWeeklyTime
        MetaSnapMonthlyWeekday  = $MetaSnapMonthlyWeekday
        MetaSnapMonthlyTime     = $MetaSnapMonthlyTime
        OrganizationalUnit      = $OrganizationalUnit
        DeploymentDate          = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    }
        
    # Save configuration to JSON file
    $config | ConvertTo-Json -Depth 10 | Out-File -FilePath "$configPath\FCGConfig.json" -Encoding UTF8
    
    Write-Host "Configuration file created successfully at: $configPath\FCGConfig.json" -ForegroundColor Green
    
    # Validate storage account connectivity
    Write-Host "Validating storage account connectivity..." -ForegroundColor Yellow
    
    $context = New-AzStorageContext -StorageAccountName $StorageAccountName -StorageAccountKey $StorageAccountKey
    
    # Check if container exists
    $container = Get-AzStorageContainer -Name $ContainerName -Context $context -ErrorAction SilentlyContinue
    if (-not $container) {
        Write-Warning "Container '$ContainerName' not found. It may be created by another process."
    }
    else {
        Write-Host "Container '$ContainerName' validated successfully." -ForegroundColor Green
    }

    # Check if snapshot container exists
    $container = Get-AzStorageContainer -Name $SnapshotsContainerName -Context $context -ErrorAction SilentlyContinue
    if (-not $container) {
        Write-Warning "Container '$SnapshotsContainerName' not found. It may be created by another process."
    }
    else {
        Write-Host "Container '$SnapshotsContainerName' validated successfully." -ForegroundColor Green
    }
    
    # Check if table exists
    $table = Get-AzStorageTable -Name $TableName -Context $context -ErrorAction SilentlyContinue
    if (-not $table) {
        Write-Warning "Table '$TableName' not found. It may be created by another process."
    }
    else {
        Write-Host "Table '$TableName' validated successfully." -ForegroundColor Green
    }

    # Check if table exists
    $processTable = Get-AzStorageTable -Name $ProcessTableName -Context $context -ErrorAction SilentlyContinue
    if (-not $processTable) {
        Write-Warning "Table '$ProcessTableName' not found. It may be created by another process."
    }
    else {
        Write-Host "Table '$ProcessTableName' validated successfully." -ForegroundColor Green
    }
    
    # Check if CAEVES Config table exists
    $caevesConfigTable = Get-AzStorageTable -Name $CaevesConfigTableName -Context $context -ErrorAction SilentlyContinue
    if (-not $caevesConfigTable) {
        Write-Warning "Table '$CaevesConfigTableName' not found. It may be created by another process."
    }
    else {
        Write-Host "Table '$CaevesConfigTableName' validated successfully." -ForegroundColor Green
    }
    
    # -------------------------------------------------------------------------------------------------------------
    # Main First Boot Functions: Put all functions here
    # 0.9.6 - June 6, 2025 - Jaap van Duijvenbode
    # 0.9.7 - October 17, 2025 - Archana Patil - Adjusted Data Disk Initialization for new partitioning scheme
    # -------------------------------------------------------------------------------------------------------------

        function Initialize-DataDisks {
        Write-Output "Initializing data disks with custom partitioning..."

        # Get the OS disk
        $osDisk = Get-Partition | Where-Object { $_.DriveLetter -eq "C" } | Get-Disk

        # Get all uninitialized (RAW) data disks excluding OS disk
        $dataDisks = Get-Disk | Where-Object { $_.Number -ne $osDisk.Number -and $_.PartitionStyle -eq 'RAW' }

        if ($dataDisks.Count -lt 2) {
            Write-Warning "Expected 2 uninitialized data disks. Found $($dataDisks.Count). Skipping initialization."
            return
        }

		# Identify disks by LUN
        $fixedDisk = $dataDisks | Where-Object { $_.Location -match "LUN 0" }
        $sliderDisk = $dataDisks | Where-Object { $_.Location -match "LUN 1" }

        # Optional: Display the disks
        Write-Output "Fixed Disk (LUN 0): $($fixedDisk.Number)"
        Write-Output "Slider Disk (LUN 1): $($sliderDisk.Number)"

        # Identify fixed and slider disks
        #$fixedDisk = $dataDisks | Where-Object { $_.Number -eq 1 }
        #$sliderDisk = $dataDisks | Where-Object { $_.Number -eq 2 }

        if (-not $fixedDisk -or -not $sliderDisk) {
            Write-Warning "Could not identify both fixed and slider disks correctly. Skipping initialization."
            return
        }

        # Initialize both disks
        Initialize-Disk -Number $fixedDisk.Number -PartitionStyle GPT -PassThru | Out-Null
        Initialize-Disk -Number $sliderDisk.Number -PartitionStyle GPT -PassThru | Out-Null

        # Refresh disk objects
        $fixedDisk = Get-Disk -Number $fixedDisk.Number
        $sliderDisk = Get-Disk -Number $sliderDisk.Number

		Write-Output "Fixed Disk (LUN 0): $($fixedDisk.Number) : size of disk : $($fixedDisk.Size) "
        Write-Output "Slider Disk (LUN 1): $($sliderDisk.Number) : size of disk : $($sliderDisk.Size) "

        # --- Fixed Disk (1024GB): Metadata + Snapshots ---
        $fixedSize = $fixedDisk.Size
        $metadataSize = [math]::Floor($fixedSize * 0.10)
        $snapshotSize = [math]::Floor($fixedSize * 0.90) - 1000000000  # Leave 1GB unallocated

        # Create Snapshots partition (no drive letter)
        $volSnapshot = New-Partition -DiskNumber $fixedDisk.Number -Size $snapshotSize
        Format-Volume -Partition $volSnapshot -FileSystem NTFS -NewFileSystemLabel "Snapshots" -Confirm:$false

        # Create Metadata partition (F:)
        $volMetadata = New-Partition -DiskNumber $fixedDisk.Number -Size $metadataSize -DriveLetter F
        Format-Volume -Partition $volMetadata -FileSystem NTFS -NewFileSystemLabel "Metadata" -Confirm:$false        

        # --- Slider Disk: Cache (G:) ---
        $volCache = New-Partition -DiskNumber $sliderDisk.Number -UseMaximumSize -DriveLetter G
        Format-Volume -Partition $volCache -FileSystem NTFS -NewFileSystemLabel "Cache" -Confirm:$false

        Write-Output "Disks initialized:"
        Write-Output "Fixed Disk (1024GB): F: (Metadata), No letter (Snapshots) Size : $($fixedDisk.Size)"
        Write-Output "Slider Disk (128GB–8192GB): G: (Cache) Size : $($sliderDisk.Size)"
    }    

    # Function to get IV for AES encryption
    function Get-IV {
        return [System.Convert]::FromBase64String("SFIkMnBJakhSJDJwSWoxMg==") # 16 bytes
    }
    function Get-LegalKey {
        param (
            [string]$Key,
            [System.Security.Cryptography.SymmetricAlgorithm]$CryptoAlgorithm
        )

        $sTemp = $null
        $lessSize = 0
        $moreSize = 128

        while (($Key.Length * 8) -gt $moreSize) {
            $lessSize = $moreSize
            $moreSize += 64
        }

        $sTemp = $Key.PadRight($moreSize / 8, ' ')

        # Convert the secret key to a byte array
        return [System.Text.Encoding]::ASCII.GetBytes($sTemp)
    }
    function Encrypt-String {
        param (
            [string]$PlainText
        )

        $aes = [System.Security.Cryptography.Aes]::Create()
        $aes.Key = Get-LegalKey "36C032E6"
        $aes.IV = Get-IV

        $memoryStream = New-Object System.IO.MemoryStream
        $encryptor = $aes.CreateEncryptor()

        $cryptoStream = New-Object System.Security.Cryptography.CryptoStream ( $memoryStream, $encryptor, [System.Security.Cryptography.CryptoStreamMode]::Write)

        $plainBytes = [System.Text.Encoding]::UTF8.GetBytes($PlainText)
        $cryptoStream.Write($plainBytes, 0, $plainBytes.Length)
        $cryptoStream.FlushFinalBlock()

        $cryptoStream.Close()
        $aes.Dispose()
        $encryptedBytes = $memoryStream.ToArray()
        $memoryStream.Close()

        return [Convert]::ToBase64String($encryptedBytes)
    }

    # -------------------------------------------------------------------------------------------------------------
    # Main First Boot Execution: Partitioning Data Disk, Re-applying Wallpaper, Installing CAEVES Software
    # 0.9.6 - June 6, 2025 - Jaap van Duijvenbode
    # -------------------------------------------------------------------------------------------------------------

    $marker = "C:\CAEVES\boot.complete"
    if (Test-Path $marker) {
        Write-Output "CAEVES already provisioned. Exiting."
        exit 0
    }

    Write-Output "Running CAEVES first boot provisioning..."

    # Step 1: Initialize disk
    Initialize-DataDisks

    # Step 2: Re-apply wallpaper (optional)
    # Define desired wallpaper settings

    $wallpaper = "C:\WINDOWS\OEM\CAEVES-wallpaper.jpg"
    Invoke-WebRequest -Uri "https://caeveswebassets.blob.core.windows.net/caevesbuildimage/CAEVES-Windows-BG-2025.jpg" -OutFile $wallpaper 

    $wallpaperPath = 'C:\Windows\OEM\CAEVES-wallpaper.jpg'
    $wallpaperStyle = '0'  # 0 = Centered

    # Enumerate all user SIDs in HKEY_USERS
    $usersRoot = 'Registry::HKEY_USERS'
    Get-ChildItem -Path $usersRoot | ForEach-Object {
        $sid = $_.PSChildName

        # Skip default/system profiles
        if ($sid -match '^S-1-5-21-\d+-\d+-\d+-\d+$') {
            $desktopKeyPath = "$usersRoot\$sid\Control Panel\Desktop"

            try {
                if (Test-Path -Path $desktopKeyPath) {
                    Set-ItemProperty -Path $desktopKeyPath -Name 'Wallpaper' -Value $wallpaperPath
                    Set-ItemProperty -Path $desktopKeyPath -Name 'WallpaperStyle' -Value $wallpaperStyle
                    Write-Output "Updated wallpaper settings for user SID: $sid"
                }
                else {
                    Write-Warning "Desktop key not found for SID: $sid"
                }
            }
            catch {
                Write-Error "Failed to update settings for SID: $sid. Error: $_"
            }
        }
    }

    # OPTIONAL: Apply wallpaper immediately for current user session
    Add-Type @"
using System.Runtime.InteropServices;
public class NativeMethods {
    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool SystemParametersInfo(int uAction, int uParam, string lpvParam, int fuWinIni);
}
"@

    $SPI_SETDESKWALLPAPER = 0x0014
    $SPIF_UPDATEINIFILE = 0x01
    $SPIF_SENDCHANGE = 0x02

    $result = [NativeMethods]::SystemParametersInfo($SPI_SETDESKWALLPAPER, 0, $wallpaperPath, $SPIF_UPDATEINIFILE -bor $SPIF_SENDCHANGE)
    if ($result) {
        Write-Output "Wallpaper applied to current session."
    }
    else {
        Write-Warning "Wallpaper update failed for current session."
    } 

    # Updating Deskop Icon for FCGUI Working Directory
    $WshShell = New-Object -ComObject WScript.Shell
    $shortcut = $WshShell.CreateShortcut("$env:PUBLIC\Desktop\CAEVES Configuration.lnk")
    $shortcut.WorkingDirectory = "C:\Program Files\Caeves\FCGUI"
    $shortcut.Save()

    # Suppress Network Location Prompt on First Login

    # Disable Server Manager on Login

    # Step 3: Install CAEVES software
	# Set environment variable to respective environment. 
    Write-Host "Setting environment to Production"
    [System.Environment]::SetEnvironmentVariable("DOTNET_ENVIRONMENT", "Production", "Machine")

    # Download CAEVES software
    Write-Host "Downloading CAEVES software"
    $downloads = @(
        "https://caeveswebassets.blob.core.windows.net/caevesbuildimage/build/CAEVES.FCG.App_Release.msi"
    )

    # Initiate the installation
    $downloads | ForEach-Object {
        $file = "C:\Temp\" + [System.IO.Path]::GetFileName($_)
        Invoke-WebRequest $_ -OutFile $file
        Write-Host "Installing CAEVES software: $file"
        Start-Process -FilePath $file -ArgumentList "/quiet" -Wait
    }

    # Step 4: Optional environment variable
    [System.Environment]::SetEnvironmentVariable("CAEVESEnabled", "True", "Machine")

    # Step 5: Mark setup complete
    New-Item -ItemType File -Path $marker -Force
    Write-Output "CAEVES first boot complete."

    # -------------------------------------------------------------------------------------------------------------
    # Configure CAEVES FCG Agent on the customer's provisioned VM instance using C:\CAEVES\Config\FCGConfig.json
    # 0.9.6 - June 6, 2025 - Jaap van Duijvenbode
    # -------------------------------------------------------------------------------------------------------------

    $paramFile = "C:\CAEVES\Config\FCGConfig.json"

    if (Test-Path $paramFile) {
        $params = Get-Content $paramFile | ConvertFrom-Json
        $storageaccount = $params.StorageAccountName
        
        Write-Output "Configuring Storage Account: $storageaccount";

        $container = $params.ContainerName

        Write-Output "Configuring Storage Container: $container";

        $connectionstring = $params.StorageConnectionString
        $encryptedconnectionstring = Encrypt-String $connectionstring

        Write-Host "Encrypted Connection String : $encryptedconnectionstring"
         
        Write-Output "Configuring Storage Connection: $connectionstring";

        $metasnapfrequency = $params.MetaSnapFrequency
        $metasnapfrequency = $metasnapfrequency * 60

        Write-Output "Configuring Metadata Snapshot Frequency: $metasnapfrequency";

        $table = $params.TableName
        Write-Output "Configuring Azure Table: $table";

        $processTable = $params.ProcessTableName
        Write-Output "Configuring Azure Table: $processTable";

        # Base key
        $baseKey = 'HKLM:\SOFTWARE\Caeves'

        # Ensure base structure
        New-Item -Path $baseKey -Force | Out-Null
        New-Item -Path "$baseKey\GatewayConfig" -Force | Out-Null
        New-Item -Path "$baseKey\GatewayConfig\BEConfig" -Force | Out-Null
        New-Item -Path "$baseKey\GatewayConfig\BEConfig\$storageaccount" -Force | Out-Null
        New-Item -Path "$baseKey\GatewayConfig\DirtyLog" -Force | Out-Null
        New-Item -Path "$baseKey\GatewayConfig\FlushLog" -Force | Out-Null
        New-Item -Path "$baseKey\GatewayConfig\FSConfig" -Force | Out-Null
        New-Item -Path "$baseKey\GatewayConfig\VolumeConfig" -Force | Out-Null
        New-Item -Path "$baseKey\GatewayConfig\LicenseConfig" -Force | Out-Null

        #Set License parameters
        Set-ItemProperty -Path "$baseKey\GatewayConfig\LicenseConfig" -Name "SaasSubscriptionId" -Value "$SaasSubscriptionId"

        # Set values for Storage Account
        Set-ItemProperty -Path "$baseKey\GatewayConfig\BEConfig\$storageaccount" -Name "StorageConnectionString" -Value "$encryptedconnectionstring"
        Set-ItemProperty -Path "$baseKey\GatewayConfig\BEConfig\$storageaccount" -Name "ContainerName" -Value "$container"
        Set-ItemProperty -Path "$baseKey\GatewayConfig\BEConfig\$storageaccount" -Name "StorageType" -Value "azureblob"
        Set-ItemProperty -Path "$baseKey\GatewayConfig\BEConfig\$storageaccount" -Name "HealthSymbol" -Value "success"
        Set-ItemProperty -Path "$baseKey\GatewayConfig\BEConfig\$storageaccount" -Name "SnapshotsContainerName" -Value "$SnapshotsContainerName"
        Set-ItemProperty -Path "$baseKey\GatewayConfig\BEConfig\$storageaccount" -Name "MetadataTableName" -Value "$table"        
        Set-ItemProperty -Path "$baseKey\GatewayConfig\BEConfig\$storageaccount" -Name "MetadataTableNameQueue" -Value "$processTable"
        Set-ItemProperty -Path "$baseKey\GatewayConfig\BEConfig\$storageaccount" -Name "CaevesConfigTableName" -Value "$CaevesConfigTableName"

        Write-Output "Storage Account Resource ID : $StorageAccountResourceId"
        Set-ItemProperty -Path "$baseKey\GatewayConfig\BEConfig\$storageaccount" -Name "StorageAccountResourceId" -Value $StorageAccountResourceId -Type String -Force
		Set-ItemProperty -Path "$baseKey\GatewayConfig\BEConfig\$storageaccount" -Name "StorageAccountName" -Value "$storageaccount"

        #Set FSConfig values
        Set-ItemProperty -Path "$baseKey\GatewayConfig\FSConfig" -Name "PurgeOnFlush" -Value 1 -Type DWord        

		# Set VolumeConfig CacheCleanerSchedulerFrequency (DWORD: 480)
        #Set-ItemProperty -Path "$baseKey\GatewayConfig\FSConfig" -Name "CacheCleanerSchedulerFrequency" -Value $CacheCleanerSchedulerFrequency -Type DWord

        # Set VolumeConfig MetaSnapSchedulerFrequency (DWORD: 480)
        Set-ItemProperty -Path "$baseKey\GatewayConfig\VolumeConfig" -Name "MetaSnapSchedulerFrequency" -Value $metasnapfrequency -Type DWord

        # Set F: as Metadata Volume in ADS using FCGMFMarkVolumeAsMetadataVolume
        Write-Output "Configuring Volume Mapping & Cache: F: + G:\Cache\";

        # Define the functions from the DLL

        [Environment]::SetEnvironmentVariable("PATH", [Environment]::GetEnvironmentVariable("PATH", "User") + ";C:\Program Files\CAEVES\FCGAgent\", "User")

        Add-Type -MemberDefinition @"
    [DllImport("C:\\Program Files\\Caeves\\FCGAgent\\fcgmfmetadatahelper.dll", CharSet = CharSet.Unicode, CallingConvention = CallingConvention.Cdecl)]
    public static extern uint FCGMFMarkVolumeAsMetadataVolume(
     [InAttribute()] [MarshalAsAttribute(UnmanagedType.LPWStr)]
     string volName, 

     [InAttribute()] [MarshalAsAttribute(UnmanagedType.LPWStr)]
     string volGuid,

     [InAttribute()] [MarshalAsAttribute(UnmanagedType.LPWStr)]
     string topLevelDirName,

     [InAttribute()] [MarshalAsAttribute(UnmanagedType.LPWStr)]
     string cacheDirName);

    [DllImport("C:\\Program Files\\Caeves\\FCGAgent\\fcgmfmetadatahelper.dll", CharSet = CharSet.Unicode, CallingConvention = CallingConvention.Cdecl)]
    public static extern uint FCGMFSetGlobalCacheDirectory(
     [InAttribute()] [MarshalAsAttribute(UnmanagedType.LPWStr)]
     string cacheDirPath);
"@ -Name "FCGLibV3" -Namespace "FCGNamespace"

        # Call the function FCGMFMarkVolumeAsMetadataVolume
        $volume = Get-WmiObject -Class Win32_Volume | Where-Object { $_.Label -eq "Metadata" }
        if ($volume) {
            Write-Host "Drive Letter: $($volume.DriveLetter)" -ForegroundColor Yellow
            Write-Host "Label: $($volume.Label)" -ForegroundColor Yellow
            Write-Host "File System: $($volume.FileSystem)" -ForegroundColor Yellow
            Write-Host "Volume GUID: $($volume.DeviceID)"  -ForegroundColor Cyan
        }
        else {
            Write-Warning "F: drive not found using WMI method"
        }

        $volName = "F:"
        $volGuid = $volGuid = [guid]::NewGuid().ToString()
        $topLevelDirName = "FCGContainer"
        $cacheDirPath = "G:\Cache"

        $result = [FCGNamespace.FCGLibV3]::FCGMFMarkVolumeAsMetadataVolume($volName, $volGuid, $topLevelDirName, "")
        if ($result -eq 0) {
            Write-Output "Success"
        }
        Write-Output "Result of FCGMFMarkVolumeAsMetadataVolume: $result"

        # Call the function FCGMFSetGlobalCacheDirectory
        $resultOfSetDirectory = [FCGNamespace.FCGLibV3]::FCGMFSetGlobalCacheDirectory($cacheDirPath)
        if ($resultOfSetDirectory -eq 0) {
            Write-Output "Global Cache Directory set successfully."
        }
        Write-Output "Result of FCGMFSetGlobalCacheDirectory: $resultOfSetDirectory" 

        # Set FSConfig CacheFolder
        Set-ItemProperty -Path "$baseKey\GatewayConfig\FSConfig" -Name "CacheFolder" -Value "G:\Cache"

        # Set VolumeConfig\F: keys
        New-Item -Path "$baseKey\GatewayConfig\VolumeConfig\F:" -Force | Out-Null
        Set-ItemProperty -Path "$baseKey\GatewayConfig\VolumeConfig\F:" -Name "PrimaryAlias" -Value "$StorageAccountName"
        Set-ItemProperty -Path "$baseKey\GatewayConfig\VolumeConfig\F:" -Name "SecondaryAlias" -Value @($StorageAccountName) -Type MultiString

        # Create FCGContainer folder on F:\ and CACHE folder on G:\
        New-Item -ItemType Directory -Path F:\FCGContainer -Force | Out-Null
        New-Item -ItemType Directory -Path F:\FCGContainer\$StorageAccountName -Force | Out-Null   
        New-Item -ItemType Directory -Path G:\Cache -Force | Out-Null 

        # Create SMB file share \\...\CAEVES-[storageaccount] and optional NFS export
        $shareName = "CAEVES-$StorageAccountName"
        $sharePath = "F:\FCGContainer\$StorageAccountName\"
        New-SmbShare -Name $shareName -Path $sharePath -FullAccess "Everyone" -Description "CAEVES Share for $StorageAccountName"
        
        # Manually Start FCG Agent and FCG MF
        Start-Service -Name fcgmf
        Start-Service -Name FileCloudGatewayService 
        
        Write-Host "CAEVES Registry keys and Service Controls created/updated successfully."

    }

    # -------------------------------------------------------------------------------------------------------------
    # Update the registy value for Maximum Shadow Copy count  : November 17, 2025  - Archana Patil
    # -------------------------------------------------------------------------------------------------------------

    # Define the registry path and key details
    $regPath = "HKLM:\System\CurrentControlSet\Services\VSS\Settings"
    $keyName = "MaxShadowCopies"
    $keyValue = 512

    # Create the registry path if it doesn't exist
    if (-not (Test-Path $regPath)) {
        New-Item -Path $regPath -Force | Out-Null
    }

    # Create or update the DWORD value
    New-ItemProperty -Path $regPath -Name $keyName -Value $keyValue -PropertyType DWord -Force | Out-Null

    # Verify the change
    Write-Output "Registry key updated successfully:"
    Get-ItemProperty -Path $regPath | Select-Object $keyName	

    # -------------------------------------------------------------------------------------------------------------
    # Create record in CAEVES Metrics & Billing Table  : June 12, 2025  - Jaap van Duijvenbode
    # Updated Metering API call : September 7, 2025 - Archana Patil
    # -------------------------------------------------------------------------------------------------------------
    
	# Construct JSON payload
	$payload = @{
        action             = "init"
        marketplaceid      = $SaasSubscriptionId
		storageaccountname = $StorageAccountName
	} | ConvertTo-Json -Depth 3
	Write-Host "[UpdateStorageCapacityAsync] Constructed Payload: $payload"

	# Construct endpoint URL
	$uri = "https://caeves-saashelper.azurewebsites.net/api/UpsertCaevesCapacityMetrics?code=HRMdSWn7FlTxAtbqSf6V9a4HIXQdKBRDrE_j4vUr4zsdAzFuC2m_JA=="

	# Send POST request
	try {
		Write-Host "[UpdateStorageCapacityAsync] Invoking Capacity metrics update endpoint."
		$response = Invoke-RestMethod -Uri $uri -Method Post -Body $payload -Headers @{"Content-Type" = "application/json" }
		Write-Host "[UpdateStorageCapacityAsync] Update successful."
    }
    catch {
		Write-Error "[UpdateStorageCapacityAsync] Request failed: $_"
	}

    # -------------------------------------------------------------------------------------------------------------
    # Configure CAEVES Snapshot Schedules
    # June 6, 2025  - Jaap van Duijvenbode
    # -------------------------------------------------------------------------------------------------------------

    $MetadataVolume = $volName
    $SnapshotsLabel = 'Snapshots'
    $MaxSize = 'UNBOUNDED'
    $MoveExistingShadowStorage = $false

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

    function Current-ShadowStorageInfo {
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

        $info = Current-ShadowStorageInfo -ForSpec $ForSpec
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

    try {
        Assert-Administrator

        Write-Host "Locating Snapshots volume by label '$SnapshotsLabel'..." -ForegroundColor Cyan
        $snapVol = Get-VolumeByLabel -Label $SnapshotsLabel
        $snapGuid = Normalize-VolumeGuid -DeviceId $snapVol.DeviceID
        Write-Host "Snapshots volume GUID: $snapGuid"

        if ($AssignSIfMissing -and -not $snapVol.DriveLetter) {
            Write-Host "Assigning drive letter S: to Snapshots volume..." -ForegroundColor Cyan
            # Ensure S: is available
            if (Get-CimInstance Win32_Volume | Where-Object { $_.DriveLetter -eq 'S:' }) {
                Write-Warning "Drive letter S: is already in use. Skipping letter assignment."
            }
            else {
                if ($PSCmdlet.ShouldProcess("Snapshots volume $($snapVol.DeviceID)", "AddMountPoint S:\")) {
                    $null = Invoke-CimMethod -InputObject $snapVol -MethodName AddMountPoint -Arguments @{ Directory = 'S:\' }
                    Write-Host "Assigned drive letter S: to the Snapshots volume."
                }
            }
        }

        Write-Host "Resolving metadata volume '$MetadataVolume'..." -ForegroundColor Cyan
        $metaVol = Get-VolumeBySpecifier -Specifier $MetadataVolume
        $metaGuid = Normalize-VolumeGuid -DeviceId $metaVol.DeviceID
        Write-Host "Metadata volume GUID: $metaGuid"

        $forSpec = $metaGuid
        $onSpec = $snapGuid

        # Try to create (idempotent-ish). If it already exists, vssadmin returns a nonzero exit;
        # we'll then try resize, and as a last resort (if requested) delete+add.
        Write-Host "Configuring shadow storage (VSS) for metadata volume..." -ForegroundColor Cyan

        $alreadyThere = ShadowStorageExistsOn -ForSpec $forSpec -OnSpec $onSpec

        if (-not $alreadyThere) {
            Write-Host "No existing shadow storage on the Snapshots volume for $forSpec."
            Write-Host "Attempting: vssadmin add shadowstorage /for=$forSpec /on=$onSpec /maxsize=$MaxSize"
            if ($PSCmdlet.ShouldProcess("VSS shadow storage for $forSpec", "add on $onSpec (maxsize=$MaxSize)")) {
                $add = Invoke-VssAdmin -ArgumentList @('add', 'shadowstorage', "/for=$forSpec", "/on=$onSpec", "/maxsize=$MaxSize")
                if ($add.ExitCode -eq 0) {
                    Write-Host "Shadow storage association created." -ForegroundColor Green
                }
                else {
                    Write-Warning "Add failed (exit $($add.ExitCode)). Trying resize (may also move storage if supported)."
                    Write-Verbose $add.Output

                    if ($PSCmdlet.ShouldProcess("VSS shadow storage for $forSpec", "resize on $onSpec (maxsize=$MaxSize)")) {
                        $resize = Invoke-VssAdmin -ArgumentList @('resize', 'shadowstorage', "/for=$forSpec", "/on=$onSpec", "/maxsize=$MaxSize")
                        if ($resize.ExitCode -eq 0) {
                            Write-Host "Shadow storage resized (and/or moved) successfully." -ForegroundColor Green
                        }
                        else {
                            Write-Warning "Resize failed (exit $($resize.ExitCode))."
                            Write-Verbose $resize.Output

                            if ($MoveExistingShadowStorage) {
                                Write-Warning "About to delete existing shadow storage for $forSpec and recreate it on $onSpec."
                                if ($PSCmdlet.ShouldProcess("VSS shadow storage for $forSpec", "DELETE and re-ADD on $onSpec (this deletes existing shadow copies)")) {
                                    $del = Invoke-VssAdmin -ArgumentList @('delete', 'shadowstorage', "/for=$forSpec")
                                    if ($del.ExitCode -eq 0) {
                                        $add2 = Invoke-VssAdmin -ArgumentList @('add', 'shadowstorage', "/for=$forSpec", "/on=$onSpec", "/maxsize=$MaxSize")
                                        if ($add2.ExitCode -eq 0) {
                                            Write-Host "Shadow storage moved to Snapshots volume." -ForegroundColor Green
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
                                Write-Warning "Existing shadow storage could not be moved automatically. Re-run with -MoveExistingShadowStorage to force a delete+add (this will delete existing shadow copies)."
                            }
                        }
                    }
                }
            }
        }
        else {
            Write-Host "Shadow storage for $forSpec is already set to the Snapshots volume. Ensuring max size..." -ForegroundColor Yellow
            if ($PSCmdlet.ShouldProcess("VSS shadow storage for $forSpec", "resize (maxsize=$MaxSize)")) {
                $resize2 = Invoke-VssAdmin -ArgumentList @('resize', 'shadowstorage', "/for=$forSpec", "/on=$onSpec", "/maxsize=$MaxSize")
                if ($resize2.ExitCode -eq 0) {
                    Write-Host "Shadow storage size verified/updated." -ForegroundColor Green
                }
                else {
                    Write-Warning "Resize returned exit $($resize2.ExitCode). Output:`n$($resize2.Output)"
                }
            }
        }

        Write-Host ""
        Write-Host "Result for metadata volume:" -ForegroundColor Cyan
        Write-Host (Current-ShadowStorageInfo -ForSpec $forSpec)
        Write-Host "Done."
    }
    catch {
        Write-Error $_.Exception.Message
        throw
    } 

    # Set up scheduled tasks for snapshots if retention values are set
    if ($VssHourlyRetention -gt 0 -or $VssDailyRetention -gt 0) {
        Write-Host "Setting up VSS snapshot schedules..." -ForegroundColor Yellow
        # Add your VSS scheduling logic here
    }

  
    Write-Host "CAEVES configuration completed successfully!" -ForegroundColor Green
    
}
catch {
    Write-Error "Error during configuration: $_"
    Write-Error $_.Exception.StackTrace
    exit 1
}
finally {
    Stop-Transcript
}

exit 0
