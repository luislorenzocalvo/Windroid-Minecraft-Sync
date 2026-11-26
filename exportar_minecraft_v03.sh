#!/data/data/com.termux/files/usr/bin/bash
set -Eeuo pipefail

# ============================================================
# Minecraft Sync - Android Exporter v0.3
# Requirements: Termux, zip, unzip, sha256sum, rclone, and Shizuku
# ============================================================

# ---------- CONFIGURATION ----------
# Replace YOUR_WORLD_FOLDER with the actual world folder name
# inside minecraftWorlds.
SOURCE="/storage/emulated/0/Android/data/com.mojang.minecraftpe/files/games/com.mojang/minecraftWorlds/YOUR_WORLD_FOLDER"

# Display name used by Minecraft Sync.
WORLD_NAME="YOUR_WORLD_NAME"

# Remote OneDrive folder. The "onedrive:" remote must exist in rclone.
DEST="onedrive:MinecraftSync/YOUR_WORLD_NAME/incoming"

BASE="$HOME/storage/downloads/MinecraftSync"
WORK="$HOME/MinecraftSync/work"

# Shared Android staging folder so Shizuku can copy files to Termux-accessible storage.
STAGE="/storage/emulated/0/Download/MinecraftSync/tmp/world"

# ---------- FUNCTIONS ----------
log() {
    printf '[MinecraftSync] %s\n' "$*"
}

die() {
    printf '[ERROR] %s\n' "$*" >&2
    exit 1
}

cleanup() {
    # Remove only private temporary files created by this script.
    rm -rf -- "$WORK/world"
}
trap cleanup EXIT

on_error() {
    local code=$?
    printf '[ERROR] La exportación ha fallado (línea %s, código %s).\n' \
        "${BASH_LINENO[0]:-desconocida}" "$code" >&2
    exit "$code"
}
trap on_error ERR

# Escape strings for safe JSON output.
json_escape() {
    local value=$1
    value=${value//\\/\\\\}
    value=${value//\"/\\\"}
    value=${value//$'\n'/\\n}
    value=${value//$'\r'/\\r}
    value=${value//$'\t'/\\t}
    printf '%s' "$value"
}

# Quote arguments safely for the shell invoked through rish.
shell_quote() {
    printf '%q' "$1"
}

# ---------- VALIDATION ----------
[[ "$SOURCE" != *"YOUR_WORLD_FOLDER"* ]] ||
    die "Configura SOURCE con el nombre real de la carpeta del mundo."

[[ "$WORLD_NAME" != "YOUR_WORLD_NAME" ]] ||
    die "Configura WORLD_NAME con el nombre del mundo."

[[ "$DEST" != *"YOUR_WORLD_NAME"* ]] ||
    die "Configura DEST con la ruta remota correspondiente al mundo."

RISH="$HOME/bin/rish"

[[ -x "$RISH" ]] || die "No se encuentra rish ejecutable en $RISH."
command -v zip >/dev/null 2>&1 || die "Falta zip. Instálalo con: pkg install zip"
command -v unzip >/dev/null 2>&1 || die "Falta unzip. Instálalo con: pkg install unzip"
command -v sha256sum >/dev/null 2>&1 || die "Falta sha256sum."
command -v rclone >/dev/null 2>&1 || die "No se encuentra rclone."

mkdir -p "$BASE" "$WORK"

log "Comprobando conexión con OneDrive..."
rclone lsd onedrive: >/dev/null ||
    die "No se puede acceder al remoto onedrive:. Comprueba rclone."

log "Comprobando que Minecraft está cerrado..."
PROCESS_LIST=$(sh "$RISH" -c "ps -A" 2>/dev/null) ||
    die "No se pudo consultar la lista de procesos mediante Shizuku."

if printf '%s\n' "$PROCESS_LIST" | grep -q 'com\.mojang\.minecraftpe'; then
    die "Minecraft parece estar abierto. Ciérralo completamente y vuelve a ejecutar el script."
fi

log "Comprobando que el mundo existe..."
SOURCE_Q=$(shell_quote "$SOURCE")
sh "$RISH" -c \
    "test -f ${SOURCE_Q}/level.dat && test -d ${SOURCE_Q}/db" ||
    die "No se encuentra el mundo o faltan level.dat/db."

# Unique export identifier based on current timestamp.
STAMP=$(date '+%Y-%m-%d_%H-%M-%S')
FILENAME="Minecraft_Android_${STAMP}.mcworld"
OUT="$BASE/$FILENAME"
MANIFEST="$BASE/${FILENAME}.manifest.json"
READY="$BASE/${FILENAME}.READY"

REMOTE_FILE="${DEST%/}/$FILENAME"
REMOTE_MANIFEST="${DEST%/}/$(basename "$MANIFEST")"
REMOTE_READY="${DEST%/}/$(basename "$READY")"

# ---------- WORLD COPY ----------
log "Preparando directorios temporales..."
rm -rf -- "$WORK/world"
mkdir -p "$WORK/world"

# Always clean STAGE before copying to avoid mixing leftover files from previous exports.
log "Limpiando la carpeta intermedia de Android..."
STAGE_Q=$(shell_quote "$STAGE")
sh "$RISH" -c "rm -rf -- ${STAGE_Q} && mkdir -p -- ${STAGE_Q}" ||
    die "No se pudo limpiar/crear la carpeta intermedia mediante Shizuku."

log "Copiando el mundo desde Android..."
sh "$RISH" -c \
    "cp -a -- ${SOURCE_Q}/. ${STAGE_Q}/" ||
    die "Shizuku no pudo copiar el mundo a Downloads."

log "Copiando el mundo al almacenamiento privado de Termux..."
STAGE_TERMUX="$HOME/storage/downloads/MinecraftSync/tmp/world"
[[ -d "$STAGE_TERMUX" ]] ||
    die "No aparece la carpeta compartida en Termux: $STAGE_TERMUX"

cp -a "$STAGE_TERMUX/." "$WORK/world/"

[[ -f "$WORK/world/level.dat" ]] ||
    die "La copia no contiene level.dat."
[[ -d "$WORK/world/db" ]] ||
    die "La copia no contiene la carpeta db."

# ---------- .MCWORLD PACKAGING ----------
log "Creando el archivo .mcworld..."
rm -f -- "$OUT"
(
    cd "$WORK/world"
    zip -qr "$OUT" .
)

log "Comprobando el contenido del .mcworld..."
unzip -t "$OUT" >/dev/null ||
    die "El archivo .mcworld no supera la comprobación ZIP."

FILE_SIZE=$(wc -c < "$OUT" | tr -d '[:space:]')
FILE_SHA256=$(sha256sum "$OUT" | awk '{print $1}')
CREATED_AT=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

# ---------- MANIFEST ----------
log "Generando manifest..."
WORLD_NAME_JSON=$(json_escape "$WORLD_NAME")
FILENAME_JSON=$(json_escape "$FILENAME")
SOURCE_FOLDER_JSON=$(json_escape "$(basename "$SOURCE")")

cat > "$MANIFEST" <<EOF
{
  "schema_version": 1,
  "operation": "android_export",
  "created_at": "$CREATED_AT",
  "platform": "android",
  "world": {
    "name": "$WORLD_NAME_JSON",
    "folder_name": "$SOURCE_FOLDER_JSON"
  },
  "snapshot": {
    "filename": "$FILENAME_JSON",
    "size_bytes": $FILE_SIZE,
    "sha256": "$FILE_SHA256",
    "format": "mcworld"
  }
}
EOF

# ---------- UPLOAD AND VERIFICATION ----------
log "Creando directorio remoto..."
rclone mkdir "$DEST"

log "Subiendo .mcworld..."
rclone copyto "$OUT" "$REMOTE_FILE"

log "Verificando el archivo remoto mediante SHA-256..."
REMOTE_SHA256=$(rclone cat "$REMOTE_FILE" | sha256sum | awk '{print $1}')
[[ "$REMOTE_SHA256" == "$FILE_SHA256" ]] ||
    die "El SHA-256 remoto no coincide. No se publicará READY."

log "Subiendo manifest..."
rclone copyto "$MANIFEST" "$REMOTE_MANIFEST"

# Verify the uploaded manifest content as well.
LOCAL_MANIFEST_SHA256=$(sha256sum "$MANIFEST" | awk '{print $1}')
REMOTE_MANIFEST_SHA256=$(rclone cat "$REMOTE_MANIFEST" | sha256sum | awk '{print $1}')
[[ "$REMOTE_MANIFEST_SHA256" == "$LOCAL_MANIFEST_SHA256" ]] ||
    die "El SHA-256 remoto del manifest no coincide."

# READY is always published last. Its presence confirms the package and manifest
# were uploaded and the remote .mcworld passed SHA-256 verification.
cat > "$READY" <<EOF
{
  "status": "READY",
  "schema_version": 1,
  "filename": "$FILENAME_JSON",
  "sha256": "$FILE_SHA256",
  "manifest": "$(json_escape "$(basename "$MANIFEST")")",
  "created_at": "$CREATED_AT"
}
EOF

log "Publicando marcador READY..."
rclone copyto "$READY" "$REMOTE_READY"

log "Exportación completada correctamente."
printf '\n'
printf 'Mundo:       %s\n' "$WORLD_NAME"
printf 'Archivo:     %s\n' "$OUT"
printf 'Tamaño:      %s bytes\n' "$FILE_SIZE"
printf 'SHA-256:     %s\n' "$FILE_SHA256"
printf 'Destino:     %s\n' "$DEST"
printf 'Manifest:    %s\n' "$REMOTE_MANIFEST"
printf 'READY:       %s\n' "$REMOTE_READY"