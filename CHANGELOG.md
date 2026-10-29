# Changelog

All notable changes to this project will be documented in this file.

## [0.2.0] - 2026-10-29

### Added
- **Android Export Automation:** Implemented automated world export and OneDrive upload from Android using Termux and Shizuku.

### Changed
- The Android export workflow no longer requires manually copying, zipping, and renaming folders to `.mcworld`.

### Notes
- Due to ongoing technical limitations on Android (Scoped Storage), downloading and importing `.mcworld` files into the game, as well as deleting old local backups on the device, still require manual execution.
