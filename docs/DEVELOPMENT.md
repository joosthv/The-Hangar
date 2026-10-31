# Jetstream Hangar - developer documentation

## 1. Structure
| Path | Content |
| --- | --- |
| `src/Hangar.cs` | everything: tray app (`Hangar`), `Settings`, `Community`, `Autostart`, `GitHub`, `Library`, `Sync`, `Api`, `SelfUpdate` |
| `web/` | UI (index.html, app.js, style.css), embedded as resources `web.<file>`; a `web` folder next to the exe overrides them (UI development) |
| `catalog.json` | aircraft catalogue; read by running hangars from raw.githubusercontent.com (no API rate limit) |
| `VERSION` | version compiled in by `build.ps1` (generated class `HangarBuild`) |
| `tests/` | `run_tests.ps1` end-to-end suite, `mockserver.ps1` mock GitHub |

## 2. Runtime
- Single instance per port (mutex `JetstreamHangar_SingleInstance_<port>`); a second start opens the UI.
- `HttpListener` on `http://localhost:48330/` (env `JETSTREAM_HANGAR_PORT`), data in `%APPDATA%\JetstreamHangar`
  (env `JETSTREAM_HANGAR_DATA`): `settings.json`, `secrets.json`, `state\<aircraft>.json`.
- Arguments: none = open the UI; `--background` = tray only (autostart); `--updated <pid>` = started by a self-update.

### Settings (`settings.json`)
| Key | Default | Use |
| --- | --- | --- |
| `catalogUrl` | `https://raw.githubusercontent.com/joosthv/The-Hangar/main/catalog.json` | catalogue; the 1.0.0/1.0.1 default (contents API) is migrated on start. A contents-API URL still works (private repos with a token) but counts against the rate limit |
| `communityOverride` | empty | otherwise detected from `UserCfg.opt` (`InstalledPackagesPath`) |
| `githubToken` | empty | needed while repositories are private; never returned by the API (`"set"`) |
| `checkHours` | 6 | update check interval |
| `prerelease` | false | include pre-release tags |
| `autoUpdate` | true | install aircraft updates automatically |
| `selfUpdate` | true | update the hangar from `hangarRepo` |
| `hangarRepo` | `joosthv/The-Hangar` | where `hangar-v<version>` releases live |
| `githubApiBase`, `startDelayMs`, `simPollSeconds` | - | test hooks (mock API, faster start, sim polling) |

### Catalogue entry
`id`, `name`, `manufacturer`, `description`, `image`, `package` (Community folder name), `github` (owner/repo),
`tagPrefix` (e.g. `at3-v`), `assetPrefix` (zip asset name prefix, default = package).

### Release selection (`GitHub.LatestRelease`)
Newest non-draft release (pre-releases only with the setting) whose tag starts with the prefix and that carries an
asset `<assetPrefix>*.zip` (hangar: `JetstreamHangar*.exe`); a `<asset>.sha256` asset is verified when present.
Versions are compared numerically (`Library.ParseVersion`).

### Install (`Library.Install`)
Download (asset API + manual redirect when a token is set, so the token never reaches the file host) -> checksum ->
refuse if MSFS started meanwhile -> unpack -> find `manifest.json` (zip root or package folder) -> move to
`.hangar_new_<pkg>` -> rename the old folder to `.hangar_old_<pkg>` -> move the new one in -> delete the old one;
rollback on failure. One job at a time (`/api/job`).

### Update loop
At start (after `startDelayMs`) and every `checkHours`: self-update first, then aircraft. Installed aircraft with a
newer release install automatically; while MSFS runs they are listed in `Library.Waiting` and the sim is polled
every `simPollSeconds` (60) until it closes.

### Self-update (`SelfUpdate`)
Release `hangar-v<version>` with `JetstreamHangar.exe` (+ `.sha256`). Download to `JetstreamHangar.new.exe`, verify,
rename the running exe to `.exe.old` (Windows allows renaming a running exe), move the new one in, start it with
`--updated <pid>`, exit. The new process waits for the old pid, deletes `.old`, notifies.

### Install / uninstall (`Installer`)
Started from anywhere but `%LOCALAPPDATA%\Programs\JetstreamHangar\` (and without `portable.txt` / `--portable`):
ask a running copy to quit (`POST /api/quit`), copy the exe (+ catalog.json), Start menu + desktop shortcut
(WScript.Shell, late bound), Apps & Features key `HKCU\...\Uninstall\JetstreamHangar` (UninstallString
`--uninstall`), autostart on first install, start the installed copy. `--uninstall [--quiet]` reverses it and
removes the folder through a short-lived hidden cmd. Test overrides: `JETSTREAM_HANGAR_INSTALLDIR`, `_SHORTCUTS`,
`_REGKEY` (also used for the autostart value name).

### Robustness
Unhandled exceptions are logged (`hangar.log`); the update loop catches every error per iteration (1.0.0 crashed
when the catalogue was unreachable).
`GitHub.GetText` keeps every answer in `%APPDATA%\JetstreamHangar\cache\<sha1(url)>.json` with its ETag and sends
`If-None-Match` next time (304 = unchanged). On a 403/429 rate limit or a network error the cached body is used and
`GitHub.Notice` (status field `githubNotice`, shown on the Library page) explains it; a 404 never falls back. Without
a token GitHub allows 60 API requests per hour per IP - test runs and `gh` calls on this PC count too. Tests: mock
flag file `tests\mock\ratelimit`.

### Navigraph account (`NavigraphAuth`)
Device-authorization flow with PKCE run by the hangar (`POST /api/navigraph/login`). Polling only while a client
watches: every `GET /api/navigraph/session` is a heartbeat; without one for `navigraphHeartbeatSeconds` (20) the
sign-in stops. authorization_pending / slow_down (+5 s) / access_denied / expired_token (new code) as in the docs; the
token request always carries `scope`. Refresh token stored DPAPI-encrypted in `navigraph.dat` and rotated on every
refresh; `GET /api/navigraph/access` returns a valid access token (refreshing when needed) to the sim only.
`navigraphIdentity` setting = identity base URL (tests point it at the mock server).
Client credentials: `secrets.json` first, else `navigraph-client.dat` (DPAPI) entered on the Library page
(`POST /api/navigraph/credentials {clientId, clientSecret}`, page origin only; empty values remove it). Note for
Claude: files written from the sandboxed shell under `%APPDATA%` may not be visible to the real hangar process
(that is why 1.0.1/1.0.2 said "not configured"); check from a normal process (a .bat started through explorer.exe).

### Community overview (`CommunityScan`)
`GET /api/community[?refresh=1]`: every package folder (skips `.hangar_*`), manifest fields, airports from
`ContentHistory.json` items of type Airport (root or `ContentInfo\**`), otherwise a guess from the folder name
(first part = developer, skipped), linked folders (reparse points) flagged. Cached 60 s.
`type` is the kind shown in the UI: `NAVDATA` (navdata / navigraph-nav / nav-base / nav-jepp / AIRAC in name or
title, no airports), `AIRPORT` (scenery with airports), `SCENERY` (other scenery), else the manifest type;
`contentType` keeps the manifest value. World map: `GET /api/airports?icao=A,B` returns positions from OurAirports
`airports.csv` (setting `airportsUrl`, downloaded to the data folder, refreshed after 90 days, loaded in the
background: `status` loading/ready/unavailable). The page draws them with Leaflet 1.9.4 (cdnjs) on OpenStreetMap
tiles darkened by CSS (CARTO tiles need a key now).
`Community.SimRunning` ignores `FlightSimulator*` processes started by the SDK package tool (`BuildAssetPackages`
on the command line, read with WMI, cached per pid).
Release lists: remembered per aircraft, re-read after `releaseCacheSeconds` (600) or after 60 s when the installed
version is newer than the remembered latest one.

### Update checks
`Hangar.CheckEverything`: self-update first (applied when `selfUpdate` is on or the user pressed "update"),
then the aircraft. `POST /api/check-updates` (page button, tray item), `POST /api/self-update` (force).
`SelfUpdate.Status`: state idle/current/available/updating/error, current, latest, checked.

## 3. HTTP API
| Method | Path | |
| --- | --- | --- |
| GET | `/api/ping` | app, version, navigraph configured |
| GET | `/api/status` | community, simRunning, autoUpdate, waiting, selfUpdate status |
| GET | `/api/catalog[?refresh=1]` | aircraft with installed / latest version, release, state |
| GET | `/api/job` | install progress |
| POST | `/api/install`, `/api/uninstall` | `{ "id": "..." }` |
| GET/POST | `/api/settings` | see table above |
| POST | `/api/open-community` | opens Explorer |
| GET | `/api/community[?refresh=1]` | Community folder overview |
| GET | `/api/airports?icao=EHAM,LIRQ` | airport positions for the world map |
| POST | `/api/navigraph/credentials` | Navigraph API client id + secret (page only) |
| POST | `/api/open-package` | `{ "folder": "..." }` opens a package folder (must be inside Community) |
| POST | `/api/check-updates`, `/api/self-update` | update checks (see above) |
| GET | `/api/navigraph/session` | sign-in state (+ code while waiting); also the heartbeat |
| POST | `/api/navigraph/login`, `/cancel`, `/logout` | sim or hangar page only |
| GET | `/api/navigraph/access` | access token, sim or hangar page only |
| GET/POST | `/api/aircraft/<id>/state` | EFB technical state |
| POST | `/api/navigraph/deviceauthorization`, `/api/navigraph/token` | form-encoded; client id/secret added here; refresh grants go to `/connect/token/` |
All `/api/*` responses allow cross-origin calls (the EFB runs in the sim's browser), but only `/api/ping`,
`/api/navigraph/*` and `/api/aircraft/*` accept any origin. Everything else requires the hangar page's own origin
(`http://localhost:48330`) or, for scripts without an Origin, GET or the header `X-Hangar: 1`. The Host header must
be localhost (DNS rebinding); Windows' HTTP layer already answers foreign hosts with 400.

## 4. Tests (`tests/run_tests.ps1`)
Builds fake packages and a mock Releases API (draft, pre-release, other tags, broken zip, bad checksum, no release,
zip without top folder, hangar 9.9.9 build), starts a second instance and checks: service and UI, release
selection, install/update/reinstall, failures leave Community intact, pre-release channel, uninstall safety, state
sync, Navigraph proxy (real request to Navigraph when `secrets.json` exists), the private-repo download path (token
only to the API), auto-update waiting for a stand-in `FlightSimulator2024.exe`, auto-update at start, self-update to
9.9.9 and a rejected corrupt self-update.

## 5. Open items
- The-Hangar is public: it holds the catalogue, the hangar releases (`hangar-v*`) and the aircraft releases
  (`at3-v*`, ...), so no user needs a token. Aircraft source repositories (e.g. joosthv/aircraft_at3) stay private.
- Code signing of the exe (SmartScreen), an installer, aircraft images in the catalogue, download resume.
