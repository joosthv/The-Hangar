# Changelog - Jetstream Hangar

All notable changes to Jetstream Hangar. Format: [Keep a Changelog](https://keepachangelog.com), versions follow
[Semantic Versioning](https://semver.org). The section of a version is used as its GitHub release notes.

## [Unreleased]

## [1.0.5] - 2026-11-01
### Added
- **The hangar**: every aircraft is shown standing in the Jetstream Virtual GA hangar at a small airfield (steel hangar
  with sliding doors, workbench, tool chest, shelving, compressor, tow bar and chocks), on the fleet page and as the
  header of its aircraft page.
- **Aircraft page** (click the aircraft or "Open aircraft page"): the aeroplane in its hangar, with
  - **Maintenance**: every interval and quantity on a colour bar against its limits (100 h inspection, oil change,
    plugs, carb sync, air filter, engine time to TBO, oil MIN/MAX, coolant, battery, engine condition, tyres, brake
    pads), airworthiness and open defects;
  - **Flight log**: date, departure and arrival airfield (named from the airport list), off / on times, block and air
    time, landings, maximum altitude, totals;
  - **Technical log**: the complete log with filters (maintenance, defects, exceedances, notes);
  - **Failures**: random failure rate (Off / Realistic / Increased / Training), carburettor icing on/off, arm any
    failure now or within x minutes (random moment), disarm, active failures reported by the aircraft, workshop
    repair.
- API: `/api/aircraft/<id>/settings` (aircraft reads, hangar page writes), `/failures`, `/disarm`, `/repair`,
  `/api/airports/nearest`.

## [1.0.4] - 2026-10-31
### Changed
- **New look** in the Jetstream Virtual style: sidebar with the compass rose and a system-status panel (annunciator
  lights), IBM Plex type, slate colours, version / download figures as a data strip, release notes formatted from the
  changelog, a calmer technical-state table, grouped settings. Works in narrow windows too.
- Scenery shows the airport name next to each ICAO code.
- **Navigraph: just sign in.** The hangar brings its own Navigraph API client, so the Library page only offers
  "Sign in" with a QR code, a link and the code to confirm - no client ID or secret to enter.

### Fixed
- The aircraft picture was cropped on the card; it is now shown whole.

## [1.0.3] - 2026-10-31
### Added
- **Navigraph setup on the Library page**: enter the client ID and secret of the Navigraph API client once; they are
  stored encrypted for your Windows account (DPAPI). Then "Sign in" works as before. Replaces "Not available in this
  installation".
- **Scenery world map**: "World map" shows every airport of your Community folder on a map (OpenStreetMap), with
  ICAO labels and the package per airport. Positions come from the public OurAirports list, downloaded once
  (about 12 MB) into the data folder.
- Aircraft image on the catalogue card (Aero AT-3).

### Changed
- Scenery opens on **Airports**; navigation data (Navigraph nav-base / Jeppesen, AIRAC) has its own "Nav data" type
  and scenery without airports (GSX and similar) is "Other scenery".

### Fixed
- "MSFS running" while it was not: the SDK package tool starts the sim headless to build packages; that no longer
  counts.
- "Installed 1.1.0, latest 1.0.0": the remembered release list is read again after 10 minutes, and after a minute
  when the installed version is newer than the latest known one.

## [1.0.2] - 2026-10-31
### Added
- **Navigraph account in the hangar**: sign in once on the Library page (link, QR code and user code); the sign-in
  is kept encrypted (Windows DPAPI) and the aircraft EFBs get their chart tokens from the hangar - no sign-in in the
  cockpit. A sign-in started in an EFB is run by the hangar too, so there is one Navigraph session.
- **Scenery tab**: everything in the Community folder - scenery with its airports (ICAO, from ContentHistory.json or
  guessed from the folder name), creator, version, size, linked folders and broken packages; search and type filter,
  open a package folder.
- The running version is shown in the header, with its update state ("up to date", "available - click to update",
  "updating").
- New logo and app / tray icon: the Jetstream Virtual compass rose; tagline in the header.

### Changed
- "Check for updates" (page and tray) checks Jetstream Hangar itself first, then the aircraft. With self-update off a
  newer hangar is reported with an update button instead of being ignored.

### Fixed
- Navigraph credentials missed at start-up (EFB backend not ready) are now read again when needed.
- "Could not load the catalogue: (403)": the catalogue is now read from raw.githubusercontent.com, which does not
  count against GitHub's limit of 60 API requests per hour (existing settings are migrated). GitHub answers are kept
  on disk with their ETag, so unchanged release lists cost a 304; when GitHub refuses or cannot be reached, the last
  known versions are shown with a notice ("GitHub rate limit reached until hh:mm").

### Security
- Navigraph tokens and sign-in actions are only available to the sim and the hangar page; other web pages are
  refused and the refusal is logged.

## [1.0.1] - 2026-10-31
### Fixed
- Crash a few seconds after start when GitHub or the catalogue could not be reached (the tray icon never appeared).
  Update checks now catch every error, log it and try again later.

### Added
- Installs itself on first start: program folder `%LOCALAPPDATA%\Programs\JetstreamHangar`, Start menu and desktop
  shortcuts, Apps & Features entry with uninstaller, start with Windows (tray). Running a newer download upgrades the
  installed copy.
- App icon, and a notice on first start that the hangar lives in the tray.
- `%APPDATA%\JetstreamHangar\hangar.log` with starts, installs, updates and errors.

### Changed
- This repository is public and also carries the aircraft releases (`at3-v*`), so no GitHub token is needed;
  aircraft source code stays in private repositories.

### Security
- Management calls (install, uninstall, settings, quit) are only accepted from the hangar's own page or local
  scripts, so other web pages cannot drive the hangar; the EFB endpoints stay open. Requests with a foreign Host
  header are refused (DNS rebinding).
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
