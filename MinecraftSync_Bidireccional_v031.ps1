[CmdletBinding()]
param(
    [ValidateSet("Backup", "Publish", "Import")]
    [string]$Action = "Backup",

    # Optional for Import. If omitted, queries OneDrive (incoming) via rclone.
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
# CONFIGURATION: replace placeholders with your local paths and rclone remote
# ---------------------------------------------------------------------------
$WorldPath = 'C:\Users\YourUser\AppData\Roaming\Minecraft Bedrock\Users\YOUR_USER_ID\games\com.mojang\minecraftWorlds\YOUR_WORLD_FOLDER'
$WorldName = 'YOUR_WORLD_NAME'
$LocalBackups = Join-Path $env:USERPROFILE "Documents\MinecraftBackups\$WorldName\initial"
$ImportRecovery = Join-Path (Split-Path -Parent $LocalBackups) 'ImportRecovery'

# rclone configuration (must match Android: onedrive:MinecraftSync/YOUR_WORLD_NAME)
$RcloneExe = 'rclone'
$RcloneRemote = 'onedrive:'
$RemoteWorld = "${RcloneRemote}MinecraftSync/$WorldName"
$RemoteReleases = "$RemoteWorld/releases"
$RemoteIncoming = "$RemoteWorld/incoming"
$RemoteProcessed = "$RemoteIncoming/processed"

# ---------------------------------------------------------------------------
# WORLD & VERIFICATION FUNCTIONS
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

    if (Test-Path -LiteralPath $Destination) {
        throw "La carpeta de destino ya existe; no se sobrescribirá: $Destination"
    }

    $Parent = Split-Path -Parent $Destination
    New-Item -ItemType Directory -Path $Parent -Force | Out-Null
    New-Item -ItemType Directory -Path $Destination | Out-Null

    & robocopy $Source $Destination /E /COPY:DAT /DCOPY:DAT /R:2 /W:2 /XJ /NFL /NDL /NP
    $Code = $LASTEXITCODE

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

# ---------------------------------------------------------------------------
# RCLONE FUNCTIONS
# ---------------------------------------------------------------------------
function Invoke-Rclone {
    param([Parameter(Mandatory)][string[]]$Arguments)

    $Output = & $RcloneExe @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        $Joined = ($Output | Out-String).Trim()
        throw "Error de rclone ($($Arguments[0])): $Joined"
    }
    return $Output
}

function Assert-RcloneReady {
    $Cmd = Get-Command $RcloneExe -ErrorAction SilentlyContinue
    if (-not $Cmd) {
        throw "No se encuentra '$RcloneExe' en el PATH. Instala rclone en Windows y configura el remoto '$RcloneRemote'."
    }

    Write-Host "Comprobando conexión con OneDrive mediante rclone ($RcloneRemote)..."
    $null = Invoke-Rclone -Arguments @('lsd', $RcloneRemote)
}

function Assert-RemoteFileMatchesLocal {
    param(
        [Parameter(Mandatory)][string]$LocalFile,
        [Parameter(Mandatory)][string]$RemoteFile
    )

    $LocalSize = (Get-Item -LiteralPath $LocalFile).Length
    $RemoteInfoRaw = Invoke-Rclone -Arguments @('lsjson', $RemoteFile)
    $RemoteInfo = ($RemoteInfoRaw | Out-String) | ConvertFrom-Json
    if ($RemoteInfo -is [array]) { $RemoteInfo = $RemoteInfo[0] }

    if ($null -eq $RemoteInfo -or ([int64]$RemoteInfo.Size -ne $LocalSize)) {
        throw "El tamaño remoto de '$RemoteFile' no coincide con el archivo local ($LocalSize bytes)."
    }

    # If the remote supports quickxor (OneDrive), compare server-side hash without re-downloading.
    $LocalHashOut = & $RcloneExe hashsum quickxor $LocalFile 2>$null
    $LocalCode = $LASTEXITCODE
    $RemoteHashOut = & $RcloneExe hashsum quickxor $RemoteFile 2>$null
    $RemoteCode = $LASTEXITCODE

    if ($LocalCode -eq 0 -and $RemoteCode -eq 0 -and $LocalHashOut -and $RemoteHashOut) {
        $LocalQx = (($LocalHashOut | Select-Object -First 1) -split '\s+')[0]
        $RemoteQx = (($RemoteHashOut | Select-Object -First 1) -split '\s+')[0]
        if ($LocalQx -and $RemoteQx -and ($LocalQx -ine $RemoteQx)) {
            throw "El hash QuickXor remoto no coincide para '$RemoteFile'."
        }
    }
}

function Get-RemoteIncomingPackage {
    param(
        [Parameter(Mandatory)][string]$RemoteDir,
        [Parameter(Mandatory)][string]$LocalStageDir
    )

    $RawJson = Invoke-Rclone -Arguments @('lsjson', $RemoteDir, '--files-only')
    $TextJson = ($RawJson | Out-String).Trim()
    if ([string]::IsNullOrWhiteSpace($TextJson) -or $TextJson -eq '[]') {
        throw "No hay archivos en '$RemoteDir'."
    }

    $Parsed = ConvertFrom-Json -InputObject $TextJson
    $Entries = if ($Parsed -is [System.Array]) { $Parsed } else { @($Parsed) }
    $ByName = @{}
    foreach ($Entry in $Entries) {
        $ByName[$Entry.Name] = $Entry
    }

    $Mcworlds = @($Entries | Where-Object { $_.Name -like '*.mcworld' } | Sort-Object ModTime -Descending)
    if ($Mcworlds.Count -eq 0) {
        throw "No hay archivos .mcworld en '$RemoteDir'."
    }

    $ReadyCandidates = New-Object System.Collections.Generic.List[object]
    $Skipped = New-Object System.Collections.Generic.List[string]

    foreach ($Item in $Mcworlds) {
        $ReadyName = "$($Item.Name).READY"
        if ($ByName.ContainsKey($ReadyName)) {
            $ManifestName = "$($Item.Name).manifest.json"
            $ReadyCandidates.Add([PSCustomObject]@{
                McworldName  = $Item.Name
                ManifestName = $(if ($ByName.ContainsKey($ManifestName)) { $ManifestName } else { $null })
                ReadyName    = $ReadyName
            })
        }
        else {
            $Skipped.Add($Item.Name)
        }
    }

    if ($ReadyCandidates.Count -eq 0) {
        throw "Hay archivos .mcworld en '$RemoteDir' ($($Skipped -join ', ')), pero ninguno tiene marcador .READY."
    }
    if ($Skipped.Count -gt 0) {
        Write-Warning "Se ignoraron paquetes remotos sin .READY: $($Skipped -join ', ')"
    }

    $Selected = $ReadyCandidates[0]
    New-Item -ItemType Directory -Path $LocalStageDir -Force | Out-Null

    $LocalMcworld = Join-Path $LocalStageDir $Selected.McworldName
    $LocalReady = Join-Path $LocalStageDir $Selected.ReadyName
    $LocalManifest = $(if ($Selected.ManifestName) { Join-Path $LocalStageDir $Selected.ManifestName } else { $null })

    Write-Host "Descargando paquete desde OneDrive: $($Selected.McworldName)..."
    $null = Invoke-Rclone -Arguments @('copyto', "$RemoteDir/$($Selected.McworldName)", $LocalMcworld)
    $null = Invoke-Rclone -Arguments @('copyto', "$RemoteDir/$($Selected.ReadyName)", $LocalReady)
    if ($LocalManifest) {
        $null = Invoke-Rclone -Arguments @('copyto', "$RemoteDir/$($Selected.ManifestName)", $LocalManifest)
    }

    Test-McworldPackageIntegrity -ArchivePath $LocalMcworld -ManifestPath $LocalManifest -ReadyPath $LocalReady

    return [PSCustomObject]@{
        ArchivePath      = $LocalMcworld
        ManifestPath     = $LocalManifest
        ReadyPath        = $LocalReady
        RemoteMcworld    = "$RemoteDir/$($Selected.McworldName)"
        RemoteManifest   = $(if ($Selected.ManifestName) { "$RemoteDir/$($Selected.ManifestName)" } else { $null })
        RemoteReady      = "$RemoteDir/$($Selected.ReadyName)"
        McworldName      = $Selected.McworldName
        IsFromRemote     = $true
    }
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

        Assert-World -Path $StageWorld
        $null = Get-WorldFingerprint -Path $StageWorld

        Move-Item -LiteralPath $DestinationWorld -Destination $PreviousWorld
        $OriginalMoved = $true
        try {
            Copy-World -Source $StageWorld -Destination $DestinationWorld
            Assert-WorldsMatch -Source $StageWorld -Destination $DestinationWorld
        }
        catch {
            if ($OriginalMoved -and (Test-Path -LiteralPath $DestinationWorld)) {
                Remove-Item -LiteralPath $DestinationWorld -Recurse -Force -ErrorAction SilentlyContinue
            }
            if ($OriginalMoved -and (Test-Path -LiteralPath $PreviousWorld)) {
                Move-Item -LiteralPath $PreviousWorld -Destination $DestinationWorld
                $OriginalMoved = $false
            }
            throw
        }

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
$WorkStageDir = $null

try {
    Write-Host "Acción: $Action (v0.3.1 rclone)"
    Write-Host "Backup local: $CreateLocalBackup"

    Assert-World -Path $WorldPath

    $GameProcesses = @(
        Get-Process -Name 'Minecraft.Windows', 'Minecraft' -ErrorAction SilentlyContinue
    )
    if ($GameProcesses.Count -gt 0) {
        throw "Parece que Minecraft sigue abierto. Cierra el juego completamente antes de continuar."
    }

    if ($Action -eq 'Publish' -or ($Action -eq 'Import' -and [string]::IsNullOrWhiteSpace($ImportFile))) {
        Assert-RcloneReady
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
        $WorkStageDir = Join-Path $env:TEMP ('MinecraftSync_Publish_' + $Stamp)
        New-Item -ItemType Directory -Path $WorkStageDir -Force | Out-Null

        $VersionName = "${WorldName}_version_${Stamp}"
        $McworldLeaf = "$VersionName.mcworld"
        $ManifestLeaf = "$McworldLeaf.manifest.json"
        $ReadyLeaf = "$McworldLeaf.READY"

        $LocalMcworld = Join-Path $WorkStageDir $McworldLeaf
        $LocalManifest = Join-Path $WorkStageDir $ManifestLeaf
        $LocalReady = Join-Path $WorkStageDir $ReadyLeaf

        if ($CreateLocalBackup) { $PublishSource = $BackupPath } else { $PublishSource = $WorldPath }

        Write-Host "Creando .mcworld verificado localmente..."
        New-VerifiedMcworld -SourceWorld $PublishSource -DestinationFile $LocalMcworld -WorkRoot $WorkStageDir

        $FileSize = (Get-Item -LiteralPath $LocalMcworld).Length
        $FileSha256 = (Get-FileHash -LiteralPath $LocalMcworld -Algorithm SHA256).Hash.ToLowerInvariant()
        $CreatedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')

        $Manifest = [ordered]@{
            schema_version = 1
            operation      = 'windows_publish'
            created_at     = $CreatedAt
            platform       = 'windows'
            world          = [ordered]@{
                name        = $WorldName
                folder_name = (Split-Path -Leaf $WorldPath)
            }
            snapshot       = [ordered]@{
                filename   = $McworldLeaf
                size_bytes = $FileSize
                sha256     = $FileSha256
                format     = 'mcworld'
            }
        }
        $Manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $LocalManifest -Encoding UTF8

        $ReadyPayload = [ordered]@{
            status         = 'READY'
            schema_version = 1
            filename       = $McworldLeaf
            sha256         = $FileSha256
            manifest       = $ManifestLeaf
            created_at     = $CreatedAt
        }
        $ReadyPayload | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $LocalReady -Encoding UTF8

        Write-Host "Creando directorio remoto en OneDrive..."
        $null = Invoke-Rclone -Arguments @('mkdir', $RemoteReleases)

        $RemoteMcworld = "$RemoteReleases/$McworldLeaf"
        $RemoteManifest = "$RemoteReleases/$ManifestLeaf"
        $RemoteReady = "$RemoteReleases/$ReadyLeaf"

        Write-Host "Subiendo .mcworld a OneDrive..."
        $null = Invoke-Rclone -Arguments @('copyto', $LocalMcworld, $RemoteMcworld)
        Assert-RemoteFileMatchesLocal -LocalFile $LocalMcworld -RemoteFile $RemoteMcworld

        Write-Host "Subiendo manifest.json..."
        $null = Invoke-Rclone -Arguments @('copyto', $LocalManifest, $RemoteManifest)
        Assert-RemoteFileMatchesLocal -LocalFile $LocalManifest -RemoteFile $RemoteManifest

        Write-Host "Publicando marcador READY..."
        $null = Invoke-Rclone -Arguments @('copyto', $LocalReady, $RemoteReady)
        Assert-RemoteFileMatchesLocal -LocalFile $LocalReady -RemoteFile $RemoteReady

        Write-Host "Publicación completada y verificada en OneDrive: $RemoteMcworld" -ForegroundColor Green
    }
    elseif ($Action -eq 'Import') {
        $WorkStageDir = Join-Path $env:TEMP ('MinecraftSync_Import_' + $Stamp)
        if (-not [string]::IsNullOrWhiteSpace($ImportFile)) {
            $Resolved = (Resolve-Path -LiteralPath $ImportFile -ErrorAction Stop).Path
            if (-not (Test-Path -LiteralPath $Resolved -PathType Leaf) -or
                [System.IO.Path]::GetExtension($Resolved) -ine '.mcworld') {
                throw "ImportFile debe apuntar a un archivo .mcworld válido: $ImportFile"
            }
            $SideManifest = "$Resolved.manifest.json"
            $SideReady = "$Resolved.READY"
            Test-McworldPackageIntegrity -ArchivePath $Resolved `
                -ManifestPath ($(if (Test-Path -LiteralPath $SideManifest -PathType Leaf) { $SideManifest } else { $null })) `
                -ReadyPath ($(if (Test-Path -LiteralPath $SideReady -PathType Leaf) { $SideReady } else { $null }))
            $SourcePkg = [PSCustomObject]@{
                ArchivePath  = $Resolved
                IsFromRemote = $false
            }
        }
        else {
            $SourcePkg = Get-RemoteIncomingPackage -RemoteDir $RemoteIncoming -LocalStageDir $WorkStageDir
        }

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
        Import-McworldSafely -ArchivePath $SourcePkg.ArchivePath -DestinationWorld $WorldPath -WorkRoot $env:TEMP -Stamp $Stamp

        if ($SourcePkg.IsFromRemote) {
            try {
                $null = Invoke-Rclone -Arguments @('mkdir', $RemoteProcessed)
                $BaseLeaf = [System.IO.Path]::GetFileNameWithoutExtension($SourcePkg.McworldName) + '_' + $Stamp + '.mcworld'
                $null = Invoke-Rclone -Arguments @('moveto', $SourcePkg.RemoteMcworld, "$RemoteProcessed/$BaseLeaf")
                if ($SourcePkg.RemoteManifest) {
                    $null = Invoke-Rclone -Arguments @('moveto', $SourcePkg.RemoteManifest, "$RemoteProcessed/$BaseLeaf.manifest.json")
                }
                if ($SourcePkg.RemoteReady) {
                    $null = Invoke-Rclone -Arguments @('moveto', $SourcePkg.RemoteReady, "$RemoteProcessed/$BaseLeaf.READY")
                }
                Write-Host "Paquete remoto archivado en: $RemoteProcessed/$BaseLeaf"
            }
            catch {
                Write-Warning "El mundo se importó correctamente, pero no se pudo archivar en OneDrive ($RemoteProcessed): $($_.Exception.Message)"
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
    }
    if ($TempRecoveryPath -and (Test-Path -LiteralPath $TempRecoveryPath)) {
        Remove-Item -LiteralPath $TempRecoveryPath -Recurse -Force -ErrorAction SilentlyContinue
    }
    exit 1
}
finally {
    if ($WorkStageDir -and (Test-Path -LiteralPath $WorkStageDir)) {
        Remove-Item -LiteralPath $WorkStageDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}