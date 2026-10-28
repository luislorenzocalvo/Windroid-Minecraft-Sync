# Windroid-Minecraft-Sync

# 🌍 Windroid Minecraft Sync (WMSync)

![License](https://img.shields.io/badge/License-GPL_v3-blue.svg)
![Status](https://img.shields.io/badge/Status-Early_Development-orange.svg)
![PowerShell](https://img.shields.io/badge/PowerShell-%235391FE.svg?style=flat&logo=powershell&logoColor=white)

**Windroid Minecraft Sync** is an automation tool designed to import, export, and bidirectionally sync Minecraft worlds between Windows and Android devices.

> **⚠️ Current Status:** This project is in its early stages of development. Currently, the core functionality operates via a standalone PowerShell script (`.ps1`) for only Windows environments.

## ⚠️ Important Requirement

**A OneDrive account (and the Windows desktop client) is strictly required** for the automation processes to work.

## How to Use

At the moment, the workflow operates differently depending on your platform:
Since the project is in early development, you only need to download and run the script on your Windows machine.

### 💻 Windows (Automated)
1. Download the main `.ps1` file from this repository.
2. Open PowerShell in the folder where you downloaded it.
3. If this is your first time running scripts on your machine, you might need to grant execution permissions. Run this command as Administrator:
   ```powershell
   Set-ExecutionPolicy RemoteSigned -Scope CurrentUser
   ```
4. Depending on what you want to do, use one of these:
   * `.\MinecraftSync_Bidireccional.ps1 -Action Backup`
   * `.\MinecraftSync_Bidireccional.ps1 -Action Publish`
   * `.\MinecraftSync_Bidireccional.ps1 -Action Import`

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
### 📱 Android (Manual Workaround)
Due to current Android file system restrictions, syncing on mobile requires a manual process for now.

**📥 To Import a world to Android:**
1. Manually download the `.mcworld` file from your OneDrive app.
2. Tap to open the downloaded file (just like any regular file). This will automatically launch Minecraft and start importing the world.

**📤 To Export a world from Android:**
1. Use a file manager app to navigate to your Minecraft worlds folder (usually located at `Android/data/com.mojang.minecraftpe/files/games/com.mojang/minecraftWorlds`).
2. Copy your specific world folder and paste it into a different directory *outside* of `Android/data` (for example, your Documents or Downloads folder).
3. Open this newly copied folder and **select all the files inside it**.
4. Compress the selected files into a `.zip` archive.
5. Rename the file extension from `.zip` to `.mcworld`.
6. Upload this newly created `.mcworld` file to your OneDrive so the Windows script can detect it.


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

## ✨ Features (Current Phase - Windows)

*   **☁️ OneDrive Integration:** Syncs directly using the OneDrive desktop client. Can upload from a local backup folder or straight from the active Minecraft world directory.
*   **💾 Local Backups & Retention:** Creates local copies of selected worlds. You can configure the maximum number of retained copies (default is 3, can be disabled entirely).
*   **🧹 Automated Cleanup:** Deletes older backups when the limit is exceeded. By default, it asks for confirmation, but it can be set to silent automatic deletion.
*   **📦 `.mcworld` Automation:** Automatically downloads, extracts, and imports `.mcworld` files directly into the Minecraft `minecraftWorlds` folder.
*   **🛡️ File Integrity Checks:** Validates all files by comparing them against the local copy before executing any import or export process.
*   **📅 Timestamp Versioning:** Uploads and local backups are automatically renamed with their creation date and time for clean chronological sorting.
*   **📄 JSON Metadata:** Generates a `.json` file alongside uploads containing the timestamp and detailed upload data.
*   **🦺 Failsafe Backups (WIP):** Automatically generates a temporary safety copy during uploads and imports to prevent data loss. *(Note: This feature is currently under review to optimize OneDrive storage limits).*

## 📱 Android Support (To Be Implemented)

> **DISCLAIMER:** Due to Android 11+ security policies (Scoped Storage), access to the `Android/data` folder is heavily restricted.
*   **Current State:** Android synchronization must be done **manually** using third-party file explorer apps that can bypass or grant access to the `Android/data` directories.
*   **Future Goal:** Ongoing research to bypass or adapt to these restrictions in order to fully automate the Android side of the sync process.
