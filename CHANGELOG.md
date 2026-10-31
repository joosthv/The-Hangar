# Changelog - Jetstream Hangar

All notable changes to Jetstream Hangar. Format: [Keep a Changelog](https://keepachangelog.com), versions follow
[Semantic Versioning](https://semver.org). The section of a version is used as its GitHub release notes.

## [Unreleased]
### Changed
- This repository is public and also carries the aircraft releases (`at3-v*`), so no GitHub token is needed;
  aircraft source code stays in private repositories.

## [1.0.0] - 2026-10-31
First release.

### Aircraft library
- Catalogue of aircraft (`catalog.json` in this repository); more aircraft can be added without code changes.
- Install, update, reinstall and uninstall in the MSFS 2024 Community folder; the folder is detected from the
  MSFS settings (Steam and Microsoft Store) and can be overridden.
- Releases from GitHub: the newest non-draft release with the aircraft's tag prefix and zip asset; optional
  pre-release (beta) channel; release notes shown per aircraft.
- Safe install: download, SHA-256 verification, unpack next to the target, folder swap with rollback; refused while
  MSFS runs; uninstall only removes folders that contain a `manifest.json`.

### Automatic updates
- New aircraft releases install automatically at start and on every check (default every 6 hours); while MSFS
  runs the update waits and installs as soon as the sim is closed.
- Jetstream Hangar updates itself from its own releases (`hangar-v<version>`), verified by checksum, and restarts.

### EFB backend
- Local server on http://localhost:48330 for the aircraft EFBs.
- Navigraph device-flow sign-in forwarded with the client credentials kept on this computer (never in the aircraft
  packages).
- Technical state synced from the EFB and shown on the aircraft card (airworthiness, intervals, tyres, log).

### Other
- Tray icon (open, check for updates, quit), optional start with Windows, private repositories supported with a
  GitHub token (sent only to api.github.com).
