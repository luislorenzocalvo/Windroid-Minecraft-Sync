# Changelog

All notable changes to this project will be documented in this file.

## [0.3.1] - 2026-11-26

### Added
- **Optional `rclone` Windows Sync (`MinecraftSync_Bidireccional_v031.ps1`):** Added an alternative Windows PowerShell script that performs the same `Backup`, `Publish`, and `Import` workflow directly through `rclone` (`onedrive:`) instead of relying on the Windows OneDrive desktop client / File Explorer folder.
- **Server-Side Upload Verification:** `MinecraftSync_Bidireccional_v031.ps1` verifies remote file sizes and `quickxor` hashes before publishing `.READY` to `releases`, and archives `.mcworld`, `.manifest.json`, and `.READY` remotely into `incoming/processed` via `rclone moveto`.

### Notes
- `MinecraftSync_Bidireccional.ps1` (File Explorer / OneDrive desktop folder) remains available as the default zero-setup Windows option; `MinecraftSync_Bidireccional_v031.ps1` is optional and requires installing and configuring `rclone` on Windows (`onedrive:` remote).

## [0.3.0] - 2026-11-26

### Added
- **Android Exporter (`exportar_minecraft_v03.sh`):** Added clean staging before copy, Minecraft running process check via Shizuku (`rish`), `.manifest.json` generation with `SHA-256` and `size_bytes`, remote `SHA-256` verification via `rclone`, and final `.READY` marker publication.
- **Verified Windows Import (`MinecraftSync_Bidireccional.ps1`):** Automatic `incoming` imports now require `.READY` and validate `size_bytes` and `SHA-256` before touching the active world.
- **Dedicated `ImportRecovery`:** Atomically creates/replaces an `ImportRecovery` backup prior to overwriting the world on Windows.
- **Aligned `Publish` Contract:** Windows `Publish` now generates `.mcworld.manifest.json` and `.mcworld.READY` in `releases`.

### Changed
- **Clean Archiving:** Windows `Import` moves `.mcworld`, `.manifest.json`, and `.READY` together into `incoming/processed`.
- **Reliable ZIP Extraction:** Replaced `Expand-Archive` with `System.IO.Compression.ZipFile::ExtractToDirectory`.
- **Portability:** Replaced personal paths/identifiers with generic placeholders and translated all script comments to English.

## [0.2.0] - 2026-10-29

### Added
- **Android Export Automation:** Implemented automated world export and OneDrive upload from Android using Termux and Shizuku.

### Changed
- The Android export workflow no longer requires manually copying, zipping, and renaming folders to `.mcworld`.

### Notes
- Due to ongoing technical limitations on Android (Scoped Storage), downloading and importing `.mcworld` files into the game, as well as deleting old local backups on the device, still require manual execution.
