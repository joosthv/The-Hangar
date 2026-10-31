# Jetstream Hangar - developer documentation

## 1. Structure
| Path | Content |
| --- | --- |
| `src/Hangar.cs` | everything: tray app (`Hangar`), `Settings`, `Community`, `Autostart`, `GitHub`, `Library`, `Sync`, `Api`, `SelfUpdate` |
| `web/` | UI (index.html, app.js, style.css), embedded as resources `web.<file>`; a `web` folder next to the exe overrides them (UI development) |
| `catalog.json` | aircraft catalogue; read by running hangars through the GitHub contents API |
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
| `catalogUrl` | `https://api.github.com/repos/joosthv/The-Hangar/contents/catalog.json` | catalogue (contents API: default branch, works for private repos with a token) |
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

## 3. HTTP API
| Method | Path | |
| --- | --- | --- |
| GET | `/api/ping` | app, version, navigraph configured |
| GET | `/api/status` | community, simRunning, autoUpdate, waiting, selfUpdate status |
| GET | `/api/catalog[?refresh=1]` | aircraft with installed / latest version, release, state |
| GET | `/api/job` | install progress |
| POST | `/api/install`, `/api/uninstall` | `{ "id": "..." }` |
| GET/POST | `/api/settings` | see table above |
| GET | `/api/open-community` | opens Explorer |
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
