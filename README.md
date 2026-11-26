# Windroid-Minecraft-Sync

# 🌍 Windroid Minecraft Sync (WMSync)

![License](https://img.shields.io/badge/License-GPL_v3-blue.svg)
![Status](https://img.shields.io/badge/Status-Early_Development-orange.svg)
![PowerShell](https://img.shields.io/badge/PowerShell-%235391FE.svg?style=flat&logo=powershell&logoColor=white)

**Windroid Minecraft Sync** is an automation tool designed to import, export, and bidirectionally sync Minecraft Bedrock worlds between Windows and Android devices using OneDrive as a shared transfer medium.

> **⚠️ Current Status:** This project is in early development (`v0.3.x`). Windows supports `Backup`, `Publish`, and verified `Import` via PowerShell. Android supports verified `Export` via Termux + Shizuku + `rclone`, while automated Android `Import` is planned next.

## ⚠️ Two Windows Sync Options (Choose One)

You can run the Windows side in **two equivalent ways** — both perform the exact same `Backup`, `Publish`, and `Import` workflow with `.manifest.json`, `.READY`, `SHA-256` checks, and `ImportRecovery`:

1. **Standard (File Explorer / OneDrive Desktop Client) — `MinecraftSync_Bidireccional.ps1`**
   - Uses your local Windows OneDrive folder (`C:\Users\YourUser\OneDrive\MinecraftSync\...`).
   - **No extra tools required** beyond the built-in OneDrive desktop client.
2. **Optional (`rclone` CLI) — `MinecraftSync_Bidireccional_v031.ps1`**
   - Talks directly to OneDrive via `rclone` (`onedrive:` remote), without depending on the Windows OneDrive desktop client or File Explorer sync state.
   - Verifies remote file sizes and `quickxor` hashes directly against OneDrive before publishing `.READY`.
   - **Requires installing `rclone` on Windows** (available in `PATH`) and configuring the `onedrive:` remote via `rclone config`.

## How to Use

### 💻 Windows

1. Download either **`MinecraftSync_Bidireccional.ps1`** (OneDrive folder) or **`MinecraftSync_Bidireccional_v031.ps1`** (optional `rclone` version).
2. Edit the configuration block at the top of the script with your local paths and world name (`YourUser`, `YOUR_USER_ID`, `YOUR_WORLD_FOLDER`, `YOUR_WORLD_NAME`).
3. Open PowerShell in the folder where you saved the script.
4. If this is your first time running PowerShell scripts, allow local execution:
   ```powershell
   Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
   ```
   And if Windows blocks the downloaded file:
   ```powershell
   Unblock-File -Path ".\MinecraftSync_Bidireccional.ps1"
   ```
5. Run one of the available actions (substitute `MinecraftSync_Bidireccional_v031.ps1` if using the `rclone` variant):
   * `.\MinecraftSync_Bidireccional.ps1 -Action Backup`
   * `.\MinecraftSync_Bidireccional.ps1 -Action Publish`
   * `.\MinecraftSync_Bidireccional.ps1 -Action Import`

#### Optional Flags
* `-KeepLocalBackups X`: change how many timestamped local backups to keep (default `3`).
* `-CreateLocalBackup $false` / `$true`: skip or enable timestamped local backups (`Import` always creates/updates `ImportRecovery` regardless).
* `-ConfirmCleanup $true` / `$false`: prompt before deleting backups beyond `KeepLocalBackups`.
* `-ImportFile "C:\path\to\world.mcworld"`: import a specific `.mcworld` file directly.

*(If using `MinecraftSync_Bidireccional_v031.ps1`, ensure `rclone` is installed, in your `PATH`, and `rclone lsd onedrive:` succeeds before running `Publish` or `Import`.)*

### 📱 Android (Automated Export & Manual Import)

Thanks to **Shizuku** and **Termux**, exporting your Minecraft worlds on Android is automated and verified!

#### 📤 Automated Export Setup (`exportar_minecraft_v03.sh`)

1. **Install Shizuku:**
   Download and install Shizuku from the [official Shizuku website](https://shizuku.rikka.app/). Start the service (Wireless Debugging, ADB, or Root) and link `rish` into Termux (`~/bin/rish`).

2. **Install Termux & Dependencies:**
   Download [Termux](https://github.com/termux/termux-app), grant storage access (`termux-setup-storage`), and install required packages:
   ```bash
   pkg update
   pkg install zip unzip rclone
   ```

3. **Configure the OneDrive Remote in Rclone:**
   Run `rclone config`, create a new remote named `onedrive` using **Microsoft OneDrive** (`onedrive`), leave `client_id`/`client_secret` blank, sign in with your Microsoft account, and select your personal OneDrive (`OneDrive (personal)`). Test with:
   ```bash
   rclone lsd onedrive:
   ```

4. **Configure and Run `exportar_minecraft_v03.sh`:**
   Edit `SOURCE`, `WORLD_NAME`, and `DEST` at the top of `exportar_minecraft_v03.sh`, make it executable (`chmod +x ~/exportar_minecraft_v03.sh`), and run:
   ```bash
   ~/exportar_minecraft_v03.sh
   ```
   The script checks that Minecraft is closed, cleans staging, packages and tests `.mcworld`, generates `.manifest.json` (`SHA-256` + `size_bytes`), verifies remote `SHA-256` after upload, and publishes `.READY` last.

---

#### 📥 Manual Import (Android)
Automated Android import is planned for the next iteration of `v0.3`. Currently:
1. Download the `.mcworld` file from `releases/` in your OneDrive app.
2. Tap to open the downloaded `.mcworld` file in your file manager.
3. Minecraft will launch automatically and import the world.

## 📂 Folder Structure & Paths

**💻 Local Windows Structure:**
* `[Your_Choice_Path]/YourWorldName/initial/`: Timestamped local backups.
* `[Your_Choice_Path]/YourWorldName/ImportRecovery/`: Dedicated recovery copy created/replaced atomically before every `Import`.

**☁️ OneDrive Structure (`MinecraftSync/YourWorldName/`):**
* `backups/`: Optional manual backup space.
* `Concurrent/`: Reserved for future multi-device state tracking.
* `releases/`: Windows exports (`.mcworld`, `.mcworld.manifest.json`, `.mcworld.READY`).
* `incoming/`: Android exports (`.mcworld`, `.mcworld.manifest.json`, `.mcworld.READY`).
* `incoming/processed/`: Packages archived after a successful Windows `Import` (`.mcworld`, `.manifest.json`, and `.READY` moved together).

## ✨ Features (Current Phase)

### 💻 Windows
* **Two Sync Backends:** Choose between OneDrive desktop folder (`MinecraftSync_Bidireccional.ps1`) or direct `rclone` CLI (`MinecraftSync_Bidireccional_v031.ps1`).
* **`.READY` + `SHA-256` Verified Import:** Only imports packages with a `.READY` marker and verifies `size_bytes` and `SHA-256` before touching the active world.
* **Dedicated `ImportRecovery` & Rollback:** Atomically backs up the current world before replacing it and rolls back automatically on error.
* **Timestamped Local Backups & Retention:** Configurable backup retention with optional confirmation prompt.

### 📱 Android
* **Automated Verified Export (`exportar_minecraft_v03.sh`):** Checks that Minecraft is closed via Shizuku (`rish`), cleans staging, validates `level.dat`/`db/` and ZIP integrity, verifies remote `SHA-256`, and publishes `.manifest.json` + `.READY`.
* **Scoped Storage Access:** Reads `Android/data/com.mojang.minecraftpe/...` via Shizuku without root.
