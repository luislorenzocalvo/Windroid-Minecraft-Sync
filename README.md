# Windroid-Minecraft-Sync

# 🌍 Windroid Minecraft Sync (WMSync)

![License](https://img.shields.io/badge/License-GPL_v3-blue.svg)
![Status](https://img.shields.io/badge/Status-Early_Development-orange.svg)
![PowerShell](https://img.shields.io/badge/PowerShell-%235391FE.svg?style=flat&logo=powershell&logoColor=white)

**Windroid Minecraft Sync** is an automation tool designed to import, export, and bidirectionally sync Minecraft worlds between Windows and Android devices.

> **⚠️ Current Status:** This project is in its early stages of development. Currently, the core functionality operates via a standalone PowerShell script (`.ps1`) for only Windows environments. On Android you need some apps and the use of a terminal.

## ⚠️ Important Requirement

**A OneDrive account (and the Windows desktop client) is strictly required** for the automation processes to work. (I will try to use a open source alternative in the future)

## How to Use

At the moment, the workflow operates differently depending on your platform:
Since the project is in early development, you only need to download and run the script on your Windows machine.

### 💻 Windows (Automated)
1. Download the main `.ps1` file from this repository.
2. Open PowerShell in the folder where you downloaded it.
3. If this is your first time running scripts on your machine, you might need to grant execution permissions. Run this command as Administrator:
   ```powershell
   Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
   ```
4. Depending on what you want to do, use one of these:
   * `.\MinecraftSync_Bidireccional.ps1 -Action Backup`
   * `.\MinecraftSync_Bidireccional.ps1 -Action Publish`
   * `.\MinecraftSync_Bidireccional.ps1 -Action Import`

If it gave you an error, put this:
   ```powershell
   Unblock-File -Path ".\MinecraftSync_Bidireccional.ps1"
   ```
You can modify the parameters with VS Code or any other text editor by opening the `.ps1` file and changing the `param` block, or use flags directly in the console:
* `-KeepLocalBackups X`: to change the maximum number of local backups. For example:
  ```powershell
  .\MinecraftSync_Bidireccional.ps1 -Action Publish -KeepLocalBackups 5
  ```
* `-CreateLocalBackup $false` / `$true`: to enable or disable local backups.
* `-ConfirmCleanup $true` / `$false`: to require confirmation or to automatically delete any local backup past the `KeepLocalBackups` limit.
* You can also import a specific file by running:
  ```powershell
  .\MinecraftSync_Bidireccional.ps1 -Action Import -ImportFile "C:\Users\USER\OneDrive\MinecraftSync\WorldName\incoming\mi_mundo.mcworld"
  ```
### 📱 Android (Automated Export & Manual Import)

Thanks to **Shizuku** and **Termux**, exporting your Minecraft worlds on Android is now automated!

#### 📤 Automated Export Setup

1. **Install Shizuku:**
   Download and install Shizuku from the [official Shizuku website](https://shizuku.rikka.app/). Follow the on-screen instructions to start the service (using Wireless Debugging, ADB, or Root).

2. **Install Termux & Link with Shizuku:**
   Download [Termux(https://github.com/termux)] and configure it to work alongside Shizuku following the official documentation.

3. **Install Dependencies & Configure Rclone:**
   Open Termux and run the following commands:
   * Update your packages:
     ```bash
     pkg update
     ```
   * Install `zip` (for compressing worlds) and `rclone` (for syncing with OneDrive):
     ```bash
     pkg install zip rclone
     ```
   * Start the OneDrive configuration setup:
     ```bash
     rclone config
     ```

4. **Set Up the OneDrive Remote in Rclone:**
   * Type `n` to create a **New remote**.
   * Name it: `onedrive`
   * Select **OneDrive** as the storage type.
   * Press `Enter` on `client_id` and `client_secret` to leave them blank.
   * Choose **OneDrive Personal**.
   * Select `Type in driveID (advanced)` when prompted.
   * Select to continue via broser, when the browser opens, log in with your Microsoft account to authorize access.
   * Press `Enter` to accept the default options for all remaining prompts.
   * Test your connection by running:
     ```bash
     rclone lsd onedrive:
     ```
     *(If configured correctly, this will list your OneDrive root directories).*

5. **Run the Export Script:**
   Copy the `exportar_minecraft.txt` script attached in the latest Release, move it to your home directory, and execute:
   ```bash
   ~/exportar_minecraft.sh
   ```
   *If everything is set up correctly, the world backup will be generated and automatically uploaded to your OneDrive `incoming` folder!*

---

#### 📥 Manual Import (Android)
Due to Android's current file system restrictions, importing worlds to your mobile device remains a manual step:

1. Download the `.mcworld` file from your OneDrive app.
2. Tap to open the downloaded file in your file manager.
3. Minecraft will launch automatically and begin importing the world into your game.


## 📂 Folder Structure & Paths

Currently, the project operates using a specific folder tree. You can customize these base locations inside the `.ps1` script. 
*Note: The script automatically creates all necessary subfolders, except for the base `MinecraftSync/YourWorldName` folder in your OneDrive, which you must create manually beforehand.*

**💻 Local Windows Structure:**
*   `[Your_Choice_Path]/YourWorldName/initial/`: This is where local backups are stored. The script generates folders here named with the exact timestamp of their creation, keeping them neatly sorted by date.

**☁️ OneDrive Structure:**
*   `[OneDrive_Root]/MinecraftSync/YourWorldName/`: The main cloud directory containing the following subfolders:
    *   `backups/`: A space where you can manually place extra backups just in case.
    *   `Concurrent/`: Currently inactive. The future goal is to store the "active" version here, or a JSON file tracking the most up-to-date world, useful if multiple people need to download the latest version.
    *   `releases/`: Where Windows automatically uploads its `.mcworld` exports (named by date).
    *   `incoming/`: Where you must manually upload your Android `.mcworld` exports.
    *   `incoming/processed/`: When Windows successfully imports a world from the `incoming` folder, it moves the file here to prevent re-importing the same file twice.

## ✨ Features (Current Phase)

### 💻 Windows
*   **☁️ OneDrive Integration:** Syncs directly using the OneDrive desktop client. Can upload from a local backup folder or straight from the active Minecraft world directory.
*   **💾 Local Backups & Retention:** Creates local copies of selected worlds. You can configure the maximum number of retained copies (default is 3, can be disabled entirely).
*   **🧹 Automated Cleanup:** Deletes older backups when the limit is exceeded. By default, it asks for confirmation, but it can be set to silent automatic deletion.
*   **📦 `.mcworld` Automation:** Automatically downloads, extracts, and imports `.mcworld` files directly into the Minecraft `minecraftWorlds` folder.
*   **🛡️ File Integrity Checks:** Validates all files by comparing them against the local copy before executing any import or export process.
*   **📅 Timestamp Versioning:** Uploads and local backups are automatically renamed with their creation date and time for clean chronological sorting.
*   **📄 JSON Metadata:** Generates a `.json` file alongside uploads containing the timestamp and detailed upload data.
*   **🦺 Failsafe Backups (WIP):** Automatically generates a temporary safety copy during uploads and imports to prevent data loss. *(Note: This feature is currently under review to optimize OneDrive storage limits).*

### 📱 Android
* **🤖 Automated Export (Termux + Shizuku):** Uses `rish` (Shizuku) and `rclone` to automatically copy, compress into `.mcworld`, and upload your selected world directly to OneDrive's `incoming` folder.
* **🔓 Scoped Storage Bypass:** Accesses restricted `Android/data` directories seamlessly without requiring full device root.
* **🛡️ Integrity Verification:** Validates essential Bedrock structure (`level.dat` and `db`) and tests ZIP integrity before executing the cloud upload.
* **📥 Manual Import (OS Limitation):** Easily import worlds by tapping the downloaded `.mcworld` file to automatically launch Minecraft and trigger its native importer.

## 📱 Android Support (To Be Implemented)
*   **Future Goal:** Ongoing research to bypass or adapt to restrictions in order to fully automate the Android side of the sync process.
