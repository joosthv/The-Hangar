# Working on Jetstream Hangar (for Claude Code)

Desktop companion for Joost's MSFS 2024 aircraft: installs and auto-updates aircraft from GitHub Releases, updates
itself, and is the local backend of the aircraft EFBs. Read `docs/DEVELOPMENT.md` before changing behaviour.

## Ground rules
- C# 5 only (.NET Framework 4 `csc`): no string interpolation, no `?.`, no expression-bodied members, no `nameof`.
  JSON with `JavaScriptSerializer` - nested arrays may come back as ArrayList: always read them with `Library.Arr()`.
- Never put secrets in this repository: Navigraph credentials are in `%APPDATA%\JetstreamHangar\secrets.json`.
  The GitHub token (user setting) may only be sent to the GitHub API, never to download hosts.
- Never touch a Community folder that is not ours: installs only replace the package folder named in the catalogue,
  uninstall only removes folders with a `manifest.json`, nothing happens while MSFS runs.
- Every behaviour change gets an end-to-end test in `tests/run_tests.ps1` (it runs a second instance on port 48339
  with its own data folder against `tests/mockserver.ps1`; it must never use the real settings or Community folder).

## Commands
```
powershell -File build.ps1 [-Version x.y.z] [-OutDir dir]   # -> dist\JetstreamHangar.exe (version from VERSION)
powershell -File tests\run_tests.ps1                        # end-to-end, writes tests\results.txt (must be 0 failed)
$env:GITHUB_TOKEN = (gh auth token); powershell -File release.ps1 -Version x.y.z   # needs a CHANGELOG.md section
```

## Definition of done
Build succeeds, `tests\run_tests.ps1` reports 0 failed, `CHANGELOG.md` updated under `[Unreleased]`, README updated if
the user-facing behaviour changed. Releasing (`hangar-vx.y.z`) makes every running hangar update itself - ask first.
