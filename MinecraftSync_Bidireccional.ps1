[CmdletBinding()]
param(
    [ValidateSet("Backup", "Publish", "Import")]
    [string]$Action = "Backup",

    # Optional for Import. If omitted, the most recent .mcworld in 'incoming' is used.
    [string]$ImportFile,

    # $true by default. Use -CreateLocalBackup $false to skip it.
    [bool]$CreateLocalBackup = $true,

    # Number of local copies to keep.
    [ValidateRange(1, 100)]
    [int]$KeepLocalBackups = 3,

    # Cleanup confirmation, whether to delete old worlds automatically or not.
    [bool]$ConfirmCleanup = $true

)

$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# CONFIGURATION: Paths for this installation
# ---------------------------------------------------------------------------
# Replace these placeholders with your actual Windows username and World Folder name
$WorldPath = 'C:\Users\YOUR_USERNAME\AppData\Local\Packages\Microsoft.MinecraftUWP_8wekyb3d8bbwe\LocalState\games\com.mojang\minecraftWorlds\YOUR_WORLD_FOLDER'
# In some cases (like mine), the world folder is in 'C:\Users\YOUR_USERNAME\AppData\Roaming\Minecraft Bedrock\Users\A_RANDOM_NUMBER\games\com.mojang\minecraftWorlds\YOUR_WORLD_FOLDER'
# To see wich one you have, just search in both, first in the LocalState path, and if you don't find it, search in the Roaming path.
$CloudWorld = 'C:\Users\YOUR_USERNAME\OneDrive\MinecraftSync\YOUR_WORLD_NAME' #You have to create this folder in your OneDrive before running the script. It will be used to store the .mcworld files and the manifest.json file.
$LocalBackups = Join-Path $env:USERPROFILE 'Downloads\MinecraftSync_Backups' #You can change this to any folder you want, but it is recommended to use a folder that is not synchronized with OneDrive, to avoid conflicts and accidental deletions.
$Releases = Join-Path $CloudWorld 'releases'
$Incoming = Join-Path $CloudWorld 'incoming'

# ---------------------------------------------------------------------------
# FUNCTIONS
# ---------------------------------------------------------------------------
function Assert-World {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw "Directory does not exist: $Path"
    }

    if (-not (Test-Path -LiteralPath (Join-Path $Path 'level.dat') -PathType Leaf) -or
        -not (Test-Path -LiteralPath (Join-Path $Path 'db') -PathType Container)) {
        throw "The directory does not appear to contain a valid Bedrock world (expected level.dat and db): $Path"
    }
}

function Get-RelativeFileList {
    param([Parameter(Mandatory)][string]$Path)

    $Root = (Get-Item -LiteralPath $Path).FullName.TrimEnd('\')
    $Files = Get-ChildItem -LiteralPath $Root -File -Recurse -Force |
        ForEach-Object {
            [PSCustomObject]@{
                RelativePath = $_.FullName.Substring($Root.Length).TrimStart('\')
                Length       = $_.Length
            }
        } |
        Sort-Object RelativePath

    return @($Files)
}

function Get-WorldFingerprint {
    param([Parameter(Mandatory)][string]$Path)

    Assert-World -Path $Path
    $Files = Get-RelativeFileList -Path $Path

    if ($Files.Count -eq 0) {
        throw "No files found in: $Path"
    }

    $Rows = foreach ($File in $Files) {
        $FullPath = Join-Path $Path $File.RelativePath
        $Hash = (Get-FileHash -LiteralPath $FullPath -Algorithm SHA256).Hash

        [PSCustomObject]@{
            Path   = $File.RelativePath
            Length = $File.Length
            SHA256 = $Hash
        }
    }

    return @($Rows)
}

function Assert-WorldsMatch {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination
    )

    Write-Host "Verifying files and their SHA-256 hashes..."
    $SourceRows = @(Get-WorldFingerprint -Path $Source)
    $DestinationRows = @(Get-WorldFingerprint -Path $Destination)

    if ($SourceRows.Count -ne $DestinationRows.Count) {
        throw "Verification failed: the number of files does not match."
    }

    for ($i = 0; $i -lt $SourceRows.Count; $i++) {
        if ($SourceRows[$i].Path -cne $DestinationRows[$i].Path -or
            $SourceRows[$i].Length -ne $DestinationRows[$i].Length -or
            $SourceRows[$i].SHA256 -cne $DestinationRows[$i].SHA256) {
            throw "Verification failed on file: $($SourceRows[$i].Path)"
        }
    }

    Write-Host "Verification successful: $($SourceRows.Count) files checked." -ForegroundColor Green
}

function Copy-World {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination
    )

    Assert-World -Path $Source

    # Do not reuse a destination folder: it might contain old files.
    if (Test-Path -LiteralPath $Destination) {
        throw "Destination folder already exists; it will not be overwritten: $Destination"
    }

    $Parent = Split-Path -Parent $Destination
    New-Item -ItemType Directory -Path $Parent -Force | Out-Null
    New-Item -ItemType Directory -Path $Destination | Out-Null

    # Robocopy: /E subdirectories; /COPY:DAT basic metadata;
    # /DCOPY:DAT directory metadata; /XJ avoids following junctions.
    & robocopy $Source $Destination /E /COPY:DAT /DCOPY:DAT /R:2 /W:2 /XJ /NFL /NDL /NP
    $Code = $LASTEXITCODE

    # In Robocopy, codes 0-7 do not represent a fatal error. 
    if ($Code -ge 8) {
        throw "Robocopy failed with code $Code."
    }

    Assert-World -Path $Destination
    Assert-WorldsMatch -Source $Source -Destination $Destination
}

function Remove-OldLocalBackups {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][int]$Keep,
        [Parameter(Mandatory)][bool]$ConfirmCleanup
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        return
    }

    # Only consider folders that look like a world backup and have a date name format.
    $Folders = @(
        Get-ChildItem -LiteralPath $Path -Directory |
        Where-Object {
            $_.Name -match '^\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}(-\d+)?$' -and
            (Test-Path -LiteralPath (Join-Path $_.FullName 'level.dat') -PathType Leaf) -and
            (Test-Path -LiteralPath (Join-Path $_.FullName 'db') -PathType Container)
        } |
        Sort-Object Name -Descending
    )

    if ($Folders.Count -le $Keep) {
        return
    }

    $OldFolders = @($Folders | Select-Object -Skip $Keep)

    if ($OldFolders.Count -eq 0) {
        Write-Host "No old backups to delete."
        return
    }

    Write-Host "Backups to keep: $Keep"
    Write-Host "Backups exceeding the limit: $($OldFolders.Count)"

    if ($ConfirmCleanup) {
        $Answer = Read-Host "Delete the $($OldFolders.Count) old backups? Type YES to delete all; any other response will keep them"

        if ($Answer -cne 'YES') {
            Write-Host "Cleanup cancelled. All old backups have been kept."
            return
        }
    }

    foreach ($Folder in $OldFolders) {
        Remove-Item -LiteralPath $Folder.FullName -Recurse -Force
        Write-Host "Backup deleted: $($Folder.Name)" -ForegroundColor Yellow
    }

    Write-Host "Cleanup completed."
}

function Find-WorldRoot {
    param([Parameter(Mandatory)][string]$Path)

    if ((Test-Path -LiteralPath (Join-Path $Path 'level.dat') -PathType Leaf) -and
        (Test-Path -LiteralPath (Join-Path $Path 'db') -PathType Container)) {
        return (Get-Item -LiteralPath $Path).FullName
    }

    $Candidates = @(
        Get-ChildItem -LiteralPath $Path -Directory -Recurse -Force -ErrorAction SilentlyContinue |
        Where-Object {
            (Test-Path -LiteralPath (Join-Path $_.FullName 'level.dat') -PathType Leaf) -and
            (Test-Path -LiteralPath (Join-Path $_.FullName 'db') -PathType Container)
        }
    )

    if ($Candidates.Count -eq 0) {
        throw "The archive does not contain a recognizable Bedrock world (level.dat and db not found)."
    }
    if ($Candidates.Count -gt 1) {
        throw "The archive contains more than one folder that looks like a world. It will not be imported to avoid choosing the wrong one."
    }
    return $Candidates[0].FullName
}

function New-VerifiedMcworld {
    param(
        [Parameter(Mandatory)][string]$SourceWorld,
        [Parameter(Mandatory)][string]$DestinationFile,
        [Parameter(Mandatory)][string]$WorkRoot
    )

    Assert-World -Path $SourceWorld
    if (Test-Path -LiteralPath $DestinationFile) {
        throw "Destination file already exists; it will not be overwritten: $DestinationFile"
    }

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $ZipPath = [System.IO.Path]::ChangeExtension($DestinationFile, '.zip')
    $VerifyPath = Join-Path $WorkRoot ('verify_mcworld_' + [guid]::NewGuid().ToString('N'))
    try {
        [System.IO.Compression.ZipFile]::CreateFromDirectory(
            $SourceWorld,
            $ZipPath,
            [System.IO.Compression.CompressionLevel]::Optimal,
            $false
        )

        # The temporary .zip is renamed to .mcworld after verification.
        Expand-Archive -LiteralPath $ZipPath -DestinationPath $VerifyPath -ErrorAction Stop
        $VerifiedRoot = Find-WorldRoot -Path $VerifyPath
        Assert-WorldsMatch -Source $SourceWorld -Destination $VerifiedRoot
        Move-Item -LiteralPath $ZipPath -Destination $DestinationFile
        Write-Host ".mcworld file created and verified: $DestinationFile" -ForegroundColor Green
    }
    finally {
        if (Test-Path -LiteralPath $ZipPath) {
            Remove-Item -LiteralPath $ZipPath -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path -LiteralPath $VerifyPath) {
            Remove-Item -LiteralPath $VerifyPath -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-McworldSource {
    param([string]$RequestedFile, [Parameter(Mandatory)][string]$IncomingPath)

    if (-not [string]::IsNullOrWhiteSpace($RequestedFile)) {
        $Resolved = (Resolve-Path -LiteralPath $RequestedFile -ErrorAction Stop).Path
        if (-not (Test-Path -LiteralPath $Resolved -PathType Leaf) -or
            [System.IO.Path]::GetExtension($Resolved) -ine '.mcworld') {
            throw "ImportFile must point to a valid .mcworld file: $RequestedFile"
        }
        return $Resolved
    }

    if (-not (Test-Path -LiteralPath $IncomingPath -PathType Container)) {
        New-Item -ItemType Directory -Path $IncomingPath -Force | Out-Null
    }
    $Files = @(Get-ChildItem -LiteralPath $IncomingPath -File -Filter '*.mcworld' |
        Sort-Object LastWriteTime -Descending)
    if ($Files.Count -eq 0) {
        throw "No .mcworld files found in '$IncomingPath'. Copy the Android export there or use -ImportFile with a specific path."
    }
    return $Files[0].FullName
}

function Import-McworldSafely {
    param(
        [Parameter(Mandatory)][string]$ArchivePath,
        [Parameter(Mandatory)][string]$DestinationWorld,
        [Parameter(Mandatory)][string]$WorkRoot,
        [Parameter(Mandatory)][string]$Stamp
    )

    $Parent = Split-Path -Parent $DestinationWorld
    $StageRoot = Join-Path $Parent ('.minecraft_import_' + $Stamp)
    $ExtractRoot = Join-Path $StageRoot 'extracted'
    $StageWorld = Join-Path $StageRoot 'validated_world'
    $ZipPath = Join-Path $StageRoot 'source.zip'
    $PreviousWorld = Join-Path $Parent ('.minecraft_previous_' + $Stamp)
    $OriginalMoved = $false
    $NewWorldInstalled = $false

    if (Test-Path -LiteralPath $StageRoot) {
        throw "A temporary import folder already exists: $StageRoot"
    }
    New-Item -ItemType Directory -Path $ExtractRoot -Force | Out-Null
    try {
        # Expand-Archive requires .zip; the .mcworld content is also a ZIP.
        Copy-Item -LiteralPath $ArchivePath -Destination $ZipPath
        Expand-Archive -LiteralPath $ZipPath -DestinationPath $ExtractRoot -ErrorAction Stop
        $SourceRoot = Find-WorldRoot -Path $ExtractRoot
        Copy-World -Source $SourceRoot -Destination $StageWorld

        # Full validation before touching the current world.
        Assert-World -Path $StageWorld
        $null = Get-WorldFingerprint -Path $StageWorld

        # The previous world is already backed up in LocalBackups; it is temporarily renamed
        # so it can be restored if the installation fails.
        Move-Item -LiteralPath $DestinationWorld -Destination $PreviousWorld
        $OriginalMoved = $true
        try {
            Copy-World -Source $StageWorld -Destination $DestinationWorld
            $NewWorldInstalled = $true
            Assert-WorldsMatch -Source $StageWorld -Destination $DestinationWorld
        }
        catch {
            # Since the destination was missing after moving the original, any
            # folder that appeared here is a partial installation and can be removed.
            if ($OriginalMoved -and (Test-Path -LiteralPath $DestinationWorld)) {
                Remove-Item -LiteralPath $DestinationWorld -Recurse -Force -ErrorAction SilentlyContinue
            }
            if ($OriginalMoved -and (Test-Path -LiteralPath $PreviousWorld)) {
                Move-Item -LiteralPath $PreviousWorld -Destination $DestinationWorld
                $OriginalMoved = $false
            }
            throw
        }

        # The previous folder is only deleted after verifying the installation; the dated
        # backup in LocalBackups remains available for recovery.
        if (Test-Path -LiteralPath $PreviousWorld) {
            Remove-Item -LiteralPath $PreviousWorld -Recurse -Force
            $OriginalMoved = $false
        }
        Write-Host "Import completed and verified: $DestinationWorld" -ForegroundColor Green
    }
    catch {
        if ($OriginalMoved -and (Test-Path -LiteralPath $PreviousWorld) -and
            -not (Test-Path -LiteralPath $DestinationWorld)) {
            Move-Item -LiteralPath $PreviousWorld -Destination $DestinationWorld -ErrorAction SilentlyContinue
        }
        throw
    }
    finally {
        if (Test-Path -LiteralPath $StageRoot) {
            Remove-Item -LiteralPath $StageRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# ---------------------------------------------------------------------------
# MAIN OPERATION
# ---------------------------------------------------------------------------
$BackupPath = $null
$TempBackupPath = $null
$TempMcworldPath = $null
$FinalMcworldPath = $null
$ManifestTemp = $null
$ManifestPath = $null

try {
    Write-Host "Action: $Action"
    # Import always requires a backup, even if -CreateLocalBackup $false is passed.
    $MustCreateLocalBackup = $CreateLocalBackup -or ($Action -eq 'Import')
    Write-Host "Local backup: $MustCreateLocalBackup"

    Assert-World -Path $WorldPath

    # Basic check. The process name may vary depending on the version.
    $GameProcesses = @(
        Get-Process -Name 'Minecraft.Windows', 'Minecraft' -ErrorAction SilentlyContinue
    )
    if ($GameProcesses.Count -gt 0) {
        throw "It looks like Minecraft is still open. Close the game completely before continuing."
    }

    $Stamp = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss-fff'
    if ($MustCreateLocalBackup) {
        New-Item -ItemType Directory -Path $LocalBackups -Force | Out-Null
        $TempBackupPath = Join-Path $LocalBackups ('.pending_' + $Stamp)
        $BackupPath = Join-Path $LocalBackups $Stamp

        Write-Host "Creating temporary local backup..."
        Copy-World -Source $WorldPath -Destination $TempBackupPath
        Move-Item -LiteralPath $TempBackupPath -Destination $BackupPath
        $TempBackupPath = $null
        Write-Host "Local backup created and verified: $BackupPath" -ForegroundColor Green
    }

    if ($Action -eq 'Publish') {
        if (-not (Test-Path -LiteralPath $CloudWorld -PathType Container)) {
            throw "Configured destination folder not found: $CloudWorld"
        }
        New-Item -ItemType Directory -Path $Releases -Force | Out-Null

        $VersionName = 'MyWorld_version_' + $Stamp
        $FinalMcworldPath = Join-Path $Releases ($VersionName + '.mcworld')
        $TempMcworldPath = Join-Path $Releases ('.pending_' + $VersionName + '.mcworld')
        $ManifestPath = Join-Path $Releases ($VersionName + '.json')
        $ManifestTemp = Join-Path $Releases ('.' + $VersionName + '.json.pending')
        
        if ((Test-Path -LiteralPath $FinalMcworldPath) -or
            (Test-Path -LiteralPath $TempMcworldPath) -or
            (Test-Path -LiteralPath $ManifestPath) -or
            (Test-Path -LiteralPath $ManifestTemp)) {
            throw "A path for this operation already exists. It will not be overwritten: $VersionName"
        }

        if ($MustCreateLocalBackup) { $PublishSource = $BackupPath } else { $PublishSource = $WorldPath }
        try {
            Write-Host "Creating verified .mcworld in OneDrive..."
            New-VerifiedMcworld -SourceWorld $PublishSource -DestinationFile $TempMcworldPath -WorkRoot $env:TEMP
            $Manifest = [ordered]@{
                version      = $VersionName
                created      = (Get-Date).ToUniversalTime().ToString('o')
                source       = 'windows'
                world_folder = 'MyWorld'
                archive      = (Split-Path -Leaf $FinalMcworldPath)
                verified     = $true
                note         = 'Locally verified .mcworld file; OneDrive synchronization must be confirmed separately.'
            }
            $Manifest | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $ManifestTemp -Encoding UTF8
            Move-Item -LiteralPath $TempMcworldPath -Destination $FinalMcworldPath
            $TempMcworldPath = $null
            Move-Item -LiteralPath $ManifestTemp -Destination $ManifestPath
            $ManifestTemp = $null
            Write-Host "Release created: $FinalMcworldPath" -ForegroundColor Green
            Write-Warning "This confirms the file in the local OneDrive folder, not that the cloud upload has finished."
        }
        catch {
            if ($TempMcworldPath -and (Test-Path -LiteralPath $TempMcworldPath)) {
                Remove-Item -LiteralPath $TempMcworldPath -Force -ErrorAction SilentlyContinue
            }
            if ($ManifestTemp -and (Test-Path -LiteralPath $ManifestTemp)) {
                Remove-Item -LiteralPath $ManifestTemp -Force -ErrorAction SilentlyContinue
            }
            throw
        }
    }
    elseif ($Action -eq 'Import') {
        if (-not (Test-Path -LiteralPath $CloudWorld -PathType Container)) {
            throw "Configured OneDrive folder not found: $CloudWorld"
        }
        $SourceArchive = Get-McworldSource -RequestedFile $ImportFile -IncomingPath $Incoming
        Write-Host "File to import: $SourceArchive"
        Write-Host "Backup is created. Validating the file before replacing the world..."
        Import-McworldSafely -ArchivePath $SourceArchive -DestinationWorld $WorldPath -WorkRoot $env:TEMP -Stamp $Stamp

        # After a successful import, archive the input .mcworld to avoid
        # importing it again accidentally on the next run.
        if ([string]::IsNullOrWhiteSpace($ImportFile) -and
            (Test-Path -LiteralPath $SourceArchive) -and
            ((Split-Path -Parent $SourceArchive) -eq (Get-Item -LiteralPath $Incoming).FullName)) {
            $Processed = Join-Path $Incoming 'processed'
            New-Item -ItemType Directory -Path $Processed -Force | Out-Null
            $ProcessedName = Join-Path $Processed (([System.IO.Path]::GetFileNameWithoutExtension($SourceArchive)) + '_' + $Stamp + '.mcworld')
            try {
                Move-Item -LiteralPath $SourceArchive -Destination $ProcessedName -ErrorAction Stop
                Write-Host "Export archived at: $ProcessedName"
            }
            catch {
                Write-Warning "The world was imported successfully, but the .mcworld could not be moved to processed. Avoid re-importing that file: $($_.Exception.Message)"
            }
        }
    }

    if ($MustCreateLocalBackup) {
        Remove-OldLocalBackups -Path $LocalBackups -Keep $KeepLocalBackups -ConfirmCleanup $ConfirmCleanup
    }

    Write-Host "Operation completed." -ForegroundColor Green
}
catch {
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    if ($TempBackupPath -and (Test-Path -LiteralPath $TempBackupPath)) {
        Remove-Item -LiteralPath $TempBackupPath -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "The incomplete temporary local backup has been removed."
    }
    if ($TempMcworldPath -and (Test-Path -LiteralPath $TempMcworldPath)) {
        Remove-Item -LiteralPath $TempMcworldPath -Force -ErrorAction SilentlyContinue
        Write-Host "The incomplete temporary .mcworld file has been removed."
    }
    if ($ManifestTemp -and (Test-Path -LiteralPath $ManifestTemp)) {
        Remove-Item -LiteralPath $ManifestTemp -Force -ErrorAction SilentlyContinue
    }
    exit 1
}