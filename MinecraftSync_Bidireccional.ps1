[CmdletBinding()]
param(
    [ValidateSet("Backup", "Publish", "Import")]
    [string]$Action = "Backup",

    # Optional for Import. If omitted, the latest .mcworld with a .READY marker in incoming is used.
    [string]$ImportFile,

    # $true by default. Pass -CreateLocalBackup $false to skip timestamped backups.
    [bool]$CreateLocalBackup = $true,

    # Number of timestamped local backups to keep.
    [ValidateRange(1, 100)]
    [int]$KeepLocalBackups = 3,

    # Prompt before deleting old timestamped backups.
    [bool]$ConfirmCleanup = $true
)

$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# CONFIGURATION: replace placeholders with your local installation paths
# ---------------------------------------------------------------------------
$WorldPath = 'C:\Users\YourUser\AppData\Roaming\Minecraft Bedrock\Users\YOUR_USER_ID\games\com.mojang\minecraftWorlds\YOUR_WORLD_FOLDER'
$CloudWorld = 'C:\Users\YourUser\OneDrive\MinecraftSync\YOUR_WORLD_NAME'
$LocalBackups = Join-Path $env:USERPROFILE 'Documents\MinecraftBackups\YOUR_WORLD_NAME\initial'
$ImportRecovery = Join-Path (Split-Path -Parent $LocalBackups) 'ImportRecovery'
$Releases = Join-Path $CloudWorld 'releases'
$Incoming = Join-Path $CloudWorld 'incoming'

# ---------------------------------------------------------------------------
# FUNCTIONS
# ---------------------------------------------------------------------------
function Assert-World {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw "No existe la carpeta: $Path"
    }

    if (-not (Test-Path -LiteralPath (Join-Path $Path 'level.dat') -PathType Leaf) -or
        -not (Test-Path -LiteralPath (Join-Path $Path 'db') -PathType Container)) {
        throw "La carpeta no parece contener un mundo Bedrock válido (se esperan level.dat y db): $Path"
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
        throw "No se encontraron archivos en: $Path"
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

    Write-Host "Verificando los archivos y sus hashes SHA-256..."
    $SourceRows = @(Get-WorldFingerprint -Path $Source)
    $DestinationRows = @(Get-WorldFingerprint -Path $Destination)

    if ($SourceRows.Count -ne $DestinationRows.Count) {
        throw "La verificación ha fallado: el número de archivos no coincide."
    }

    for ($i = 0; $i -lt $SourceRows.Count; $i++) {
        if ($SourceRows[$i].Path -cne $DestinationRows[$i].Path -or
            $SourceRows[$i].Length -ne $DestinationRows[$i].Length -or
            $SourceRows[$i].SHA256 -cne $DestinationRows[$i].SHA256) {
            throw "La verificación ha fallado en el archivo: $($SourceRows[$i].Path)"
        }
    }

    Write-Host "Verificación correcta: $($SourceRows.Count) archivos comprobados." -ForegroundColor Green
}

function Copy-World {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination
    )

    Assert-World -Path $Source

    # Never reuse an existing destination folder; it could contain stale files.
    if (Test-Path -LiteralPath $Destination) {
        throw "La carpeta de destino ya existe; no se sobrescribirá: $Destination"
    }

    $Parent = Split-Path -Parent $Destination
    New-Item -ItemType Directory -Path $Parent -Force | Out-Null
    New-Item -ItemType Directory -Path $Destination | Out-Null

    # Robocopy flags: /E subdirectories; /COPY:DAT basic file metadata;
    # /DCOPY:DAT directory metadata; /XJ skip junction points.
    & robocopy $Source $Destination /E /COPY:DAT /DCOPY:DAT /R:2 /W:2 /XJ /NFL /NDL /NP
    $Code = $LASTEXITCODE

    # In Robocopy, exit codes 0-7 indicate non-fatal results.
    if ($Code -ge 8) {
        throw "Robocopy ha fallado con el código $Code."
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

    # Only consider timestamped folders that contain a valid Bedrock world.
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
        Write-Host "No hay copias antiguas que eliminar."
        return
    }

    Write-Host "Copias que se conservarán: $Keep"
    Write-Host "Copias que superan el límite: $($OldFolders.Count)"

    if ($ConfirmCleanup) {
        $Answer = Read-Host "¿Eliminar las $($OldFolders.Count) copias antiguas? Escribe SI para borrar todas; cualquier otra respuesta las conservará"

        if ($Answer -cne 'SI') {
            Write-Host "Limpieza cancelada. Se conservan todas las copias antiguas."
            return
        }
    }

    foreach ($Folder in $OldFolders) {
        Remove-Item -LiteralPath $Folder.FullName -Recurse -Force
        Write-Host "Copia eliminada: $($Folder.Name)" -ForegroundColor Yellow
    }

    Write-Host "Limpieza completada."
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
        throw "El archivo no contiene un mundo Bedrock reconocible (no se encuentran level.dat y db)."
    }
    if ($Candidates.Count -gt 1) {
        throw "El archivo contiene más de una carpeta que parece un mundo. No se importará para evitar elegir la incorrecta."
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
        throw "El archivo de destino ya existe; no se sobrescribirá: $DestinationFile"
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

        # Extract and verify every file hash before renaming the temporary .zip to .mcworld.
        [System.IO.Compression.ZipFile]::ExtractToDirectory($ZipPath, $VerifyPath)
        $VerifiedRoot = Find-WorldRoot -Path $VerifyPath
        Assert-WorldsMatch -Source $SourceWorld -Destination $VerifiedRoot
        Move-Item -LiteralPath $ZipPath -Destination $DestinationFile
        Write-Host "Archivo .mcworld creado y verificado: $DestinationFile" -ForegroundColor Green
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

function Test-McworldPackageIntegrity {
    param(
        [Parameter(Mandatory)][string]$ArchivePath,
        [string]$ManifestPath,
        [string]$ReadyPath
    )

    $ExpectedSha256 = $null
    $ExpectedSize = $null

    if ($ReadyPath -and (Test-Path -LiteralPath $ReadyPath -PathType Leaf)) {
        try {
            $ReadyData = Get-Content -LiteralPath $ReadyPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($ReadyData.status -and ($ReadyData.status -ne 'READY')) {
                throw "El marcador READY no tiene estado válido: $($ReadyData.status)"
            }
            if ($ReadyData.sha256) {
                $ExpectedSha256 = [string]$ReadyData.sha256
            }
        }
        catch {
            throw "No se pudo leer o validar el archivo READY '$ReadyPath': $($_.Exception.Message)"
        }
    }

    if ($ManifestPath -and (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
        try {
            $ManifestData = Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($ManifestData.snapshot) {
                if ($ManifestData.snapshot.sha256) {
                    $ManifestSha = [string]$ManifestData.snapshot.sha256
                    if ($ExpectedSha256 -and ($ExpectedSha256 -ine $ManifestSha)) {
                        throw "El SHA-256 de READY y manifest.json no coinciden."
                    }
                    $ExpectedSha256 = $ManifestSha
                }
                if ($null -ne $ManifestData.snapshot.size_bytes) {
                    $ExpectedSize = [int64]$ManifestData.snapshot.size_bytes
                }
            }
        }
        catch {
            throw "No se pudo leer o validar el manifest '$ManifestPath': $($_.Exception.Message)"
        }
    }

    if ($null -ne $ExpectedSize) {
        $ActualSize = (Get-Item -LiteralPath $ArchivePath).Length
        if ($ActualSize -ne $ExpectedSize) {
            throw "El tamaño del .mcworld ($ActualSize bytes) no coincide con el manifest ($ExpectedSize bytes)."
        }
    }

    if ($ExpectedSha256) {
        Write-Host "Verificando SHA-256 del paquete .mcworld..."
        $ActualSha256 = (Get-FileHash -LiteralPath $ArchivePath -Algorithm SHA256).Hash
        if ($ActualSha256 -ine $ExpectedSha256) {
            throw "El SHA-256 del paquete no coincide. Esperado: $ExpectedSha256 | Actual: $ActualSha256"
        }
        Write-Host "SHA-256 del paquete verificado correctamente." -ForegroundColor Green
    }
}

function Get-McworldSource {
    param([string]$RequestedFile, [Parameter(Mandatory)][string]$IncomingPath)

    if (-not [string]::IsNullOrWhiteSpace($RequestedFile)) {
        $Resolved = (Resolve-Path -LiteralPath $RequestedFile -ErrorAction Stop).Path
        if (-not (Test-Path -LiteralPath $Resolved -PathType Leaf) -or
            [System.IO.Path]::GetExtension($Resolved) -ine '.mcworld') {
            throw "ImportFile debe apuntar a un archivo .mcworld válido: $RequestedFile"
        }
        $SidecarManifest = "$Resolved.manifest.json"
        $SidecarReady = "$Resolved.READY"
        $HasManifest = Test-Path -LiteralPath $SidecarManifest -PathType Leaf
        $HasReady = Test-Path -LiteralPath $SidecarReady -PathType Leaf
        Test-McworldPackageIntegrity -ArchivePath $Resolved `
            -ManifestPath ($(if ($HasManifest) { $SidecarManifest } else { $null })) `
            -ReadyPath ($(if ($HasReady) { $SidecarReady } else { $null }))

        return [PSCustomObject]@{
            ArchivePath    = $Resolved
            ManifestPath   = $(if ($HasManifest) { $SidecarManifest } else { $null })
            ReadyPath      = $(if ($HasReady) { $SidecarReady } else { $null })
            IsFromIncoming = $false
        }
    }

    if (-not (Test-Path -LiteralPath $IncomingPath -PathType Container)) {
        New-Item -ItemType Directory -Path $IncomingPath -Force | Out-Null
    }

    $AllMcworlds = @(Get-ChildItem -LiteralPath $IncomingPath -File -Filter '*.mcworld' |
        Sort-Object LastWriteTime -Descending)
    if ($AllMcworlds.Count -eq 0) {
        throw "No hay archivos .mcworld en '$IncomingPath'. Copia ahí la exportación de Android o usa -ImportFile con una ruta concreta."
    }

    $ReadyPackages = New-Object System.Collections.Generic.List[object]
    $SkippedWithoutReady = New-Object System.Collections.Generic.List[string]

    foreach ($File in $AllMcworlds) {
        $CandidateReady = "$($File.FullName).READY"
        $CandidateManifest = "$($File.FullName).manifest.json"
        if (Test-Path -LiteralPath $CandidateReady -PathType Leaf) {
            $ReadyPackages.Add([PSCustomObject]@{
                ArchivePath    = $File.FullName
                ManifestPath   = $(if (Test-Path -LiteralPath $CandidateManifest -PathType Leaf) { $CandidateManifest } else { $null })
                ReadyPath      = $CandidateReady
                LastWriteTime  = $File.LastWriteTime
                IsFromIncoming = $true
            })
        }
        else {
            $SkippedWithoutReady.Add($File.Name)
        }
    }

    if ($ReadyPackages.Count -eq 0) {
        $SkippedList = $SkippedWithoutReady -join ', '
        throw "Hay archivos .mcworld en '$IncomingPath' ($SkippedList), pero ninguno tiene marcador .READY. Espera a que OneDrive termine de sincronizar o verifica la exportación en Android."
    }

    if ($SkippedWithoutReady.Count -gt 0) {
        Write-Warning "Se ignoraron paquetes sin .READY (posible subida/sincronización incompleta): $($SkippedWithoutReady -join ', ')"
    }

    $Selected = $ReadyPackages[0]
    Test-McworldPackageIntegrity -ArchivePath $Selected.ArchivePath `
        -ManifestPath $Selected.ManifestPath `
        -ReadyPath $Selected.ReadyPath

    return $Selected
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

    if (Test-Path -LiteralPath $StageRoot) {
        throw "Ya existe una carpeta temporal de importación: $StageRoot"
    }
    New-Item -ItemType Directory -Path $ExtractRoot -Force | Out-Null
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        Copy-Item -LiteralPath $ArchivePath -Destination $ZipPath
        [System.IO.Compression.ZipFile]::ExtractToDirectory($ZipPath, $ExtractRoot)
        $SourceRoot = Find-WorldRoot -Path $ExtractRoot
        Copy-World -Source $SourceRoot -Destination $StageWorld

        # Full validation before touching the active world folder.
        Assert-World -Path $StageWorld
        $null = Get-WorldFingerprint -Path $StageWorld

        # Move the current world aside temporarily so it can be restored if installation fails.
        Move-Item -LiteralPath $DestinationWorld -Destination $PreviousWorld
        $OriginalMoved = $true
        try {
            Copy-World -Source $StageWorld -Destination $DestinationWorld
            Assert-WorldsMatch -Source $StageWorld -Destination $DestinationWorld
        }
        catch {
            # Since the destination was moved aside, anything at $DestinationWorld is a partial install.
            if ($OriginalMoved -and (Test-Path -LiteralPath $DestinationWorld)) {
                Remove-Item -LiteralPath $DestinationWorld -Recurse -Force -ErrorAction SilentlyContinue
            }
            if ($OriginalMoved -and (Test-Path -LiteralPath $PreviousWorld)) {
                Move-Item -LiteralPath $PreviousWorld -Destination $DestinationWorld
                $OriginalMoved = $false
            }
            throw
        }

        # Delete the temporary previous folder only after the new world is verified.
        if (Test-Path -LiteralPath $PreviousWorld) {
            Remove-Item -LiteralPath $PreviousWorld -Recurse -Force
            $OriginalMoved = $false
        }
        Write-Host "Importación completada y verificada: $DestinationWorld" -ForegroundColor Green
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
# MAIN EXECUTION
# ---------------------------------------------------------------------------
$BackupPath = $null
$TempBackupPath = $null
$TempRecoveryPath = $null
$TempMcworldPath = $null
$FinalMcworldPath = $null
$ManifestTemp = $null
$ManifestPath = $null
$ReadyTemp = $null
$ReadyPath = $null

try {
    Write-Host "Acción: $Action"
    Write-Host "Backup local: $CreateLocalBackup"

    Assert-World -Path $WorldPath

    # Best-effort check; process names may vary across Minecraft Bedrock releases.
    $GameProcesses = @(
        Get-Process -Name 'Minecraft.Windows', 'Minecraft' -ErrorAction SilentlyContinue
    )
    if ($GameProcesses.Count -gt 0) {
        throw "Parece que Minecraft sigue abierto. Cierra el juego completamente antes de continuar."
    }

    $Stamp = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss-fff'
    if ($CreateLocalBackup) {
        New-Item -ItemType Directory -Path $LocalBackups -Force | Out-Null
        $TempBackupPath = Join-Path $LocalBackups ('.pending_' + $Stamp)
        $BackupPath = Join-Path $LocalBackups $Stamp

        Write-Host "Creando copia local temporal..."
        Copy-World -Source $WorldPath -Destination $TempBackupPath
        Move-Item -LiteralPath $TempBackupPath -Destination $BackupPath
        $TempBackupPath = $null
        Write-Host "Copia local creada y verificada: $BackupPath" -ForegroundColor Green
    }

    if ($Action -eq 'Publish') {
        if (-not (Test-Path -LiteralPath $CloudWorld -PathType Container)) {
            throw "No se encuentra la carpeta de destino configurada: $CloudWorld"
        }
        New-Item -ItemType Directory -Path $Releases -Force | Out-Null

        $WorldDisplayName = Split-Path -Leaf $CloudWorld
        $VersionName = "${WorldDisplayName}_version_${Stamp}"
        $McworldLeaf = $VersionName + '.mcworld'
        $FinalMcworldPath = Join-Path $Releases $McworldLeaf
        $TempMcworldPath = Join-Path $Releases ('.pending_' + $McworldLeaf)
        $ManifestLeaf = $McworldLeaf + '.manifest.json'
        $ManifestPath = Join-Path $Releases $ManifestLeaf
        $ManifestTemp = Join-Path $Releases ('.pending_' + $ManifestLeaf)
        $ReadyLeaf = $McworldLeaf + '.READY'
        $ReadyPath = Join-Path $Releases $ReadyLeaf
        $ReadyTemp = Join-Path $Releases ('.pending_' + $ReadyLeaf)

        if ((Test-Path -LiteralPath $FinalMcworldPath) -or
            (Test-Path -LiteralPath $TempMcworldPath) -or
            (Test-Path -LiteralPath $ManifestPath) -or
            (Test-Path -LiteralPath $ManifestTemp) -or
            (Test-Path -LiteralPath $ReadyPath) -or
            (Test-Path -LiteralPath $ReadyTemp)) {
            throw "Ya existe una ruta de esta operación. No se sobrescribirá: $VersionName"
        }

        if ($CreateLocalBackup) { $PublishSource = $BackupPath } else { $PublishSource = $WorldPath }
        try {
            Write-Host "Creando .mcworld verificado en OneDrive..."
            New-VerifiedMcworld -SourceWorld $PublishSource -DestinationFile $TempMcworldPath -WorkRoot $env:TEMP

            $FileSize = (Get-Item -LiteralPath $TempMcworldPath).Length
            $FileSha256 = (Get-FileHash -LiteralPath $TempMcworldPath -Algorithm SHA256).Hash.ToLowerInvariant()
            $CreatedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')

            $Manifest = [ordered]@{
                schema_version = 1
                operation      = 'windows_publish'
                created_at     = $CreatedAt
                platform       = 'windows'
                world          = [ordered]@{
                    name        = $WorldDisplayName
                    folder_name = (Split-Path -Leaf $WorldPath)
                }
                snapshot       = [ordered]@{
                    filename   = $McworldLeaf
                    size_bytes = $FileSize
                    sha256     = $FileSha256
                    format     = 'mcworld'
                }
            }
            $Manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $ManifestTemp -Encoding UTF8

            $ReadyPayload = [ordered]@{
                status         = 'READY'
                schema_version = 1
                filename       = $McworldLeaf
                sha256         = $FileSha256
                manifest       = $ManifestLeaf
                created_at     = $CreatedAt
            }
            $ReadyPayload | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $ReadyTemp -Encoding UTF8

            Move-Item -LiteralPath $TempMcworldPath -Destination $FinalMcworldPath
            $TempMcworldPath = $null
            Move-Item -LiteralPath $ManifestTemp -Destination $ManifestPath
            $ManifestTemp = $null
            Move-Item -LiteralPath $ReadyTemp -Destination $ReadyPath
            $ReadyTemp = $null

            Write-Host "Publicación creada: $FinalMcworldPath" -ForegroundColor Green
            Write-Host "Manifest: $ManifestPath"
            Write-Host "READY: $ReadyPath"
            Write-Warning "Esto confirma los archivos en la carpeta local de OneDrive, no que la subida a la nube haya terminado."
        }
        catch {
            if ($TempMcworldPath -and (Test-Path -LiteralPath $TempMcworldPath)) {
                Remove-Item -LiteralPath $TempMcworldPath -Force -ErrorAction SilentlyContinue
            }
            if ($ManifestTemp -and (Test-Path -LiteralPath $ManifestTemp)) {
                Remove-Item -LiteralPath $ManifestTemp -Force -ErrorAction SilentlyContinue
            }
            if ($ReadyTemp -and (Test-Path -LiteralPath $ReadyTemp)) {
                Remove-Item -LiteralPath $ReadyTemp -Force -ErrorAction SilentlyContinue
            }
            throw
        }
    }
    elseif ($Action -eq 'Import') {
        if (-not (Test-Path -LiteralPath $CloudWorld -PathType Container)) {
            throw "No se encuentra la carpeta de OneDrive configurada: $CloudWorld"
        }
        $SourcePkg = Get-McworldSource -RequestedFile $ImportFile -IncomingPath $Incoming
        $SourceArchive = $SourcePkg.ArchivePath
        Write-Host "Archivo que se va a importar: $SourceArchive"

        # Dedicated ImportRecovery: always replaced atomically before modifying the active world.
        $RecoveryParent = Split-Path -Parent $ImportRecovery
        New-Item -ItemType Directory -Path $RecoveryParent -Force | Out-Null
        $TempRecoveryPath = Join-Path $RecoveryParent ('.pending_ImportRecovery_' + $Stamp)
        Write-Host "Creando/actualizando ImportRecovery..."
        Copy-World -Source $WorldPath -Destination $TempRecoveryPath
        if (Test-Path -LiteralPath $ImportRecovery) {
            Remove-Item -LiteralPath $ImportRecovery -Recurse -Force
        }
        Move-Item -LiteralPath $TempRecoveryPath -Destination $ImportRecovery
        $TempRecoveryPath = $null
        Write-Host "ImportRecovery lista en: $ImportRecovery" -ForegroundColor Green

        Write-Host "Validando e importando el mundo..."
        Import-McworldSafely -ArchivePath $SourceArchive -DestinationWorld $WorldPath -WorkRoot $env:TEMP -Stamp $Stamp

        # After a successful import from incoming, archive .mcworld, manifest, and READY together.
        if ($SourcePkg.IsFromIncoming -and (Test-Path -LiteralPath $SourceArchive)) {
            $Processed = Join-Path $Incoming 'processed'
            New-Item -ItemType Directory -Path $Processed -Force | Out-Null
            $BaseArchiveName = [System.IO.Path]::GetFileNameWithoutExtension($SourceArchive) + '_' + $Stamp + '.mcworld'
            $ProcessedMcworld = Join-Path $Processed $BaseArchiveName
            try {
                Move-Item -LiteralPath $SourceArchive -Destination $ProcessedMcworld -ErrorAction Stop
                if ($SourcePkg.ManifestPath -and (Test-Path -LiteralPath $SourcePkg.ManifestPath)) {
                    Move-Item -LiteralPath $SourcePkg.ManifestPath -Destination ($ProcessedMcworld + '.manifest.json') -ErrorAction Stop
                }
                if ($SourcePkg.ReadyPath -and (Test-Path -LiteralPath $SourcePkg.ReadyPath)) {
                    Move-Item -LiteralPath $SourcePkg.ReadyPath -Destination ($ProcessedMcworld + '.READY') -ErrorAction Stop
                }
                Write-Host "Exportación archivada en: $ProcessedMcworld"
            }
            catch {
                Write-Warning "El mundo se importó correctamente, pero no se pudieron mover todos los archivos a processed: $($_.Exception.Message)"
            }
        }
    }

    if ($CreateLocalBackup) {
        Remove-OldLocalBackups -Path $LocalBackups -Keep $KeepLocalBackups -ConfirmCleanup $ConfirmCleanup
    }

    Write-Host "Operación terminada." -ForegroundColor Green
}
catch {
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    if ($TempBackupPath -and (Test-Path -LiteralPath $TempBackupPath)) {
        Remove-Item -LiteralPath $TempBackupPath -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "Se ha retirado la copia local temporal incompleta."
    }
    if ($TempRecoveryPath -and (Test-Path -LiteralPath $TempRecoveryPath)) {
        Remove-Item -LiteralPath $TempRecoveryPath -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "Se ha retirado la copia ImportRecovery temporal incompleta."
    }
    if ($TempMcworldPath -and (Test-Path -LiteralPath $TempMcworldPath)) {
        Remove-Item -LiteralPath $TempMcworldPath -Force -ErrorAction SilentlyContinue
        Write-Host "Se ha retirado el archivo .mcworld temporal incompleto."
    }
    if ($ManifestTemp -and (Test-Path -LiteralPath $ManifestTemp)) {
        Remove-Item -LiteralPath $ManifestTemp -Force -ErrorAction SilentlyContinue
    }
    if ($ReadyTemp -and (Test-Path -LiteralPath $ReadyTemp)) {
        Remove-Item -LiteralPath $ReadyTemp -Force -ErrorAction SilentlyContinue
    }
    exit 1
}