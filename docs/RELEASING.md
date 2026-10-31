# Releasing Jetstream Hangar and how users install it (step by step)

## How users get and keep the hangar
1. They download `JetstreamHangar.exe` from the latest `hangar-v*` release on
   https://github.com/joosthv/The-Hangar/releases and run it (Windows SmartScreen may warn: "More info" > "Run anyway",
   the exe is not code-signed yet).
2. First start from a download folder = **install**: the exe copies itself to
   `%LOCALAPPDATA%\Programs\JetstreamHangar\`, creates Start menu and desktop shortcuts, registers in
   Apps & Features (uninstaller), enables start with Windows (tray only), starts the installed copy and exits.
   No administrator rights needed. A notice says it lives in the tray (Windows 11: hidden icons ^).
3. From then on it **updates itself**: at start and every 6 h it looks for a newer `hangar-v*` release with
   `JetstreamHangar.exe` (+ `.sha256`), verifies it, renames the running exe to `.old`, puts the new exe in place,
   restarts (`--updated <pid>`) and removes the old file. Apps & Features shows the new version.
4. Uninstall: Apps & Features > Jetstream Hangar (runs `--uninstall`): stops the running copy, removes shortcuts,
   autostart, the Apps & Features entry and the program folder. Aircraft and settings stay.
Developer builds (`dist\`, with `portable.txt`) run in place and never install themselves; `--portable` does the same.

## Release checklist
1. Change done: `powershell -File build.ps1` builds, `powershell -File tests\run_tests.ps1` reports **0 failed**
   (100+ checks incl. install/uninstall and self-update). Check `tests\results.txt`.
2. Version (semantic versioning, numeric only: `x.y.z`): bug fix = patch, feature = minor.
3. `CHANGELOG.md`: rename `## [Unreleased]` to `## [x.y.z] - YYYY-MM-DD`, add a new empty `## [Unreleased]`.
4. Commit and push: `git add -A; git commit -m "Release x.y.z"; git push`.
5. Publish:
   ```
   $env:GITHUB_TOKEN = (gh auth token)
   powershell -File release.ps1 -Version x.y.z
   Remove-Item Env:GITHUB_TOKEN
   ```
   Writes `VERSION`, builds with `-Release` (no portable marker) into `dist\release`, writes the `.sha256`, takes the
   notes from `CHANGELOG.md` and creates release `hangar-vx.y.z` with both files. Commit the changed `VERSION`.
6. Verify: `gh release view hangar-vx.y.z --repo joosthv/The-Hangar`; a running older hangar updates within its
   next check (tray > "Check for updates" or restart) - `%APPDATA%\JetstreamHangar\hangar.log` shows
   "started (installed) after self-update".

## Catalogue changes (no new hangar version needed)
Edit `catalog.json` (add an aircraft, change a description), commit, push to `main`. Running hangars read it through
the GitHub contents API on their next catalogue refresh (cached 10 minutes).

## When a release is bad
- Stop it: `gh release edit hangar-vx.y.z --repo joosthv/The-Hangar --draft` (drafts are ignored).
- Fix forward with a higher version. A hangar that cannot start properly still self-updates as long as its update
  loop runs; a release must never break the update loop - keep `SelfUpdate` and `UpdateLoop` changes minimal and
  covered by `tests\run_tests.ps1`.
- A corrupt download is rejected by the checksum; the running exe is only replaced after verification.

## Diagnostics
`%APPDATA%\JetstreamHangar\hangar.log` (start, install, update, errors, crashes). The Windows event log
(Application, "Application Error" / "CLR20r3" for JetstreamHangar.exe) shows crashes from before logging existed.
