# Jetstream Hangar

Installs, updates and removes aircraft in the Microsoft Flight Simulator 2024 Community folder, and is the local
backend for the aircraft EFBs (Navigraph sign-in, technical state). A tray app with a web interface on
`http://localhost:48330`.

## Install
Download `JetstreamHangar.exe` from the [latest release](https://github.com/joosthv/The-Hangar/releases/latest)
(the newest `hangar-v*` release) and run it. It installs itself (no administrator rights): Start menu and desktop
shortcut, Apps & Features entry, start with Windows. It then lives in the tray (Windows 11: hidden icons ^) and keeps
itself and your aircraft up to date. Remove it through Apps & Features.

## Aircraft catalogue
`catalog.json` in this repository lists the aircraft. Each entry points at the GitHub repository whose releases carry
the package - normally this public repository (aircraft source code lives in private repositories, only the release
zips are published here):

```json
{
  "id": "aero-at3",
  "name": "Aero AT-3 R100",
  "manufacturer": "Aero Sp. z o.o.",
  "description": "...",
  "package": "aero-aircraft-at3",
  "github": "joosthv/The-Hangar",
  "tagPrefix": "at3-v",
  "assetPrefix": "aero-aircraft-at3",
  "image": ""
}
```
A release qualifies when its tag starts with `tagPrefix` and it has a zip asset starting with `assetPrefix`. The zip
holds the package folder (or its files) with `manifest.json`; a `<zip>.sha256` asset is verified when present.
Add an aircraft by adding an entry - no code change needed.

## Install / update
Download, verify the checksum, unpack next to the Community folder, then swap folders (rollback on failure).
Refused while MSFS runs. Uninstall only removes folders that contain a `manifest.json`.

## EFB backend
| Endpoint | Use |
| --- | --- |
| `GET /api/ping` | EFB detects the hangar |
| `POST /api/navigraph/deviceauthorization`, `/api/navigraph/token` | Navigraph device flow; the hangar adds its own Navigraph client (built into release builds); users only sign in with the QR code / link |
| `GET/POST /api/aircraft/<id>/state` | technical state synced by the EFB, shown on the aircraft card |

## Build and test
```
powershell -File build.ps1            # -> dist\JetstreamHangar.exe
powershell -File tests\run_tests.ps1  # end-to-end, against a mock GitHub and a temporary Community folder
```
Settings and data: `%APPDATA%\JetstreamHangar` (`settings.json`, `secrets.json`, `state\`). A GitHub token is only
needed while repositories are private; it is sent to api.github.com only, never to the download host.
