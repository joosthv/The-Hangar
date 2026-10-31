# End-to-end tests for Jetstream Hangar. Runs a second hangar instance (port 48339, its own data folder and a
# temporary Community folder) against a mock GitHub Releases API (tests\mockserver.ps1, port 8766).
# Nothing in the real Community folder or the real hangar settings is touched.
# Usage: powershell -File tests\run_tests.ps1
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.IO.Compression.FileSystem
$hangarRoot = Split-Path $PSScriptRoot -Parent
$exe = Join-Path $hangarRoot "dist\JetstreamHangar.exe"
$mock = Join-Path $PSScriptRoot "mock"
$T = Join-Path $env:TEMP ("hangar_test_" + [guid]::NewGuid().ToString("N").Substring(0, 8))
$data = Join-Path $T "data"; $community = Join-Path $T "Community"
$port = 48339; $base = "http://localhost:$port"
$results = New-Object System.Collections.Generic.List[string]; $fails = 0
function Check($cond, $msg) { if ($cond) { $script:results.Add("  PASS  $msg") } else { $script:results.Add("  FAIL  $msg"); $script:fails++ } }
function Section($name) { $script:results.Add("[$name]") }

# ---- HTTP helper that returns status + parsed JSON for any status code ----
function Call($method, $path, $body, $contentType) {
    $req = [Net.HttpWebRequest]::Create("$base$path"); $req.Method = $method; $req.Timeout = 60000
    if ($body -ne $null) {
        $req.ContentType = if ($contentType) { $contentType } else { "application/json" }
        $b = [Text.Encoding]::UTF8.GetBytes($body); $s = $req.GetRequestStream(); $s.Write($b, 0, $b.Length); $s.Close()
    }
    try { $resp = $req.GetResponse() } catch [Net.WebException] { $resp = $_.Exception.Response; if ($resp -eq $null) { return @{ status = 0; text = ""; json = $null; headers = $null } } }
    $text = (New-Object IO.StreamReader($resp.GetResponseStream())).ReadToEnd()
    $json = $null; try { $json = $text | ConvertFrom-Json } catch { }
    $r = @{ status = [int]$resp.StatusCode; text = $text; json = $json; headers = $resp.Headers }; $resp.Close(); return $r
}
function WaitJob() {
    for ($i = 0; $i -lt 200; $i++) { $j = (Call GET "/api/job").json; if ($j.state -ne "running") { return $j }; Start-Sleep -Milliseconds 200 }
    return (Call GET "/api/job").json
}
function Utf8NoBom($path, $text) { [IO.File]::WriteAllText($path, $text, (New-Object Text.UTF8Encoding $false)) }

# ---- fake packages and the mock GitHub ----
function MakeZip($pkg, $version, [switch]$noManifest, [switch]$flat) {
    $src = Join-Path $T ("src_" + $pkg + "_" + $version); $dir = if ($flat) { $src } else { Join-Path $src $pkg }
    New-Item -ItemType Directory -Force (Join-Path $dir "SimObjects") | Out-Null
    if (-not $noManifest) { Utf8NoBom (Join-Path $dir "manifest.json") ('{ "content_type": "AIRCRAFT", "title": "' + $pkg + '", "package_version": "' + $version + '" }') }
    Utf8NoBom (Join-Path $dir "SimObjects\version.txt") $version
    $zip = Join-Path $mock "dl\$pkg-$version.zip"
    if (Test-Path $zip) { Remove-Item $zip }
    [IO.Compression.ZipFile]::CreateFromDirectory($src, $zip)
    return $zip
}
function Sha($file) { (Get-FileHash $file -Algorithm SHA256).Hash.ToLowerInvariant() }
function Asset($name, $size) { @{ name = $name; size = $size; browser_download_url = "http://localhost:8766/dl/$name"; url = "http://localhost:8766/api/assetapi/$name" } }
function Release($tag, $assets, [switch]$draft, [switch]$pre) { @{ tag_name = $tag; name = $tag; body = "Notes for $tag"; draft = [bool]$draft; prerelease = [bool]$pre; published_at = "2026-10-31T10:00:00Z"; assets = @($assets) } }
function WriteReleases($repo, $releases) { $d = Join-Path $mock "api\repos\$repo"; New-Item -ItemType Directory -Force $d | Out-Null; Utf8NoBom (Join-Path $d "releases") (ConvertTo-Json @($releases) -Depth 6) }

if (Test-Path $mock) { Remove-Item $mock -Recurse -Force }
New-Item -ItemType Directory -Force (Join-Path $mock "dl"), $data, $community | Out-Null
$a11 = MakeZip "test-pkg-a" "1.1.0"; $a20 = MakeZip "test-pkg-a" "2.0.0-beta"
Utf8NoBom "$a11.sha256" ((Sha $a11) + "  test-pkg-a-1.1.0.zip")
WriteReleases "test\a" @(
    (Release "at3-v9.0.0" @(Asset "test-pkg-a-1.1.0.zip" 1) -draft),
    (Release "at3-v2.0.0-beta" @(Asset "test-pkg-a-2.0.0-beta.zip" (Get-Item $a20).Length) -pre),
    (Release "other-v5.0.0" @(Asset "other.zip" 1)),
    (Release "at3-v1.1.0" @((Asset "test-pkg-a-1.1.0.zip" (Get-Item $a11).Length), (Asset "test-pkg-a-1.1.0.zip.sha256" 64))),
    (Release "at3-v1.0.0" @(Asset "test-pkg-a-1.0.0.zip" 1)))
$b = MakeZip "test-pkg-b" "1.0.0" -noManifest
WriteReleases "test\b" @((Release "at3-v1.0.0" @(Asset "test-pkg-b-1.0.0.zip" (Get-Item $b).Length)))
$c = MakeZip "test-pkg-c" "1.0.0"
Utf8NoBom "$c.sha256" ("0" * 64)
WriteReleases "test\c" @((Release "at3-v1.0.0" @((Asset "test-pkg-c-1.0.0.zip" (Get-Item $c).Length), (Asset "test-pkg-c-1.0.0.zip.sha256" 64))))
WriteReleases "test\d" @()
$e = MakeZip "test-pkg-e" "3.2.1" -flat
WriteReleases "test\e" @((Release "v3.2.1" @(Asset "test-pkg-e-3.2.1.zip" (Get-Item $e).Length)))
$cat = @{ version = 1; aircraft = @(
    @{ id = "a"; name = "Aircraft A"; package = "test-pkg-a"; github = "test/a"; tagPrefix = "at3-v"; assetPrefix = "test-pkg-a" },
    @{ id = "b"; name = "Aircraft B"; package = "test-pkg-b"; github = "test/b"; tagPrefix = "at3-v" },
    @{ id = "c"; name = "Aircraft C"; package = "test-pkg-c"; github = "test/c"; tagPrefix = "at3-v" },
    @{ id = "d"; name = "Aircraft D"; package = "test-pkg-d"; github = "test/d"; tagPrefix = "at3-v" },
    @{ id = "e"; name = "Aircraft E"; package = "test-pkg-e"; github = "test/e"; tagPrefix = "" }) }
Utf8NoBom (Join-Path $mock "catalog.json") (ConvertTo-Json $cat -Depth 5)
# aircraft A 1.0.0 is already installed, with a file the new version no longer has
$preA = Join-Path $community "test-pkg-a"; New-Item -ItemType Directory -Force $preA | Out-Null
Utf8NoBom (Join-Path $preA "manifest.json") '{ "content_type": "AIRCRAFT", "package_version": "1.0.0" }'
Utf8NoBom (Join-Path $preA "old_only.txt") "old"
Utf8NoBom (Join-Path $data "settings.json") (ConvertTo-Json @{ catalogUrl = "http://localhost:8766/catalog.json"; communityOverride = $community; githubApiBase = "http://localhost:8766/api"; githubToken = "secret-token-xyz"; checkHours = 24; prerelease = $false; autoUpdate = $false; selfUpdate = $false; hangarRepo = "test/none" })
$realSecrets = Join-Path $env:APPDATA "JetstreamHangar\secrets.json"
if (Test-Path $realSecrets) { Copy-Item $realSecrets (Join-Path $data "secrets.json") }

# ---- start the mock GitHub and the test instance ----
$mockProc = Start-Process powershell -ArgumentList "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", (Join-Path $PSScriptRoot "mockserver.ps1"), "-Port", "8766", "-Root", $mock -WindowStyle Hidden -PassThru
Start-Sleep -Milliseconds 800
$env:JETSTREAM_HANGAR_PORT = "$port"; $env:JETSTREAM_HANGAR_DATA = $data
$proc = Start-Process $exe -ArgumentList "--background" -PassThru
Remove-Item Env:JETSTREAM_HANGAR_PORT, Env:JETSTREAM_HANGAR_DATA
try {
    for ($i = 0; $i -lt 50; $i++) { if ((Call GET "/api/ping").status -eq 200) { break }; Start-Sleep -Milliseconds 200 }

    Section "service"
    $p = Call GET "/api/ping"; Check ($p.status -eq 200 -and $p.json.app -eq "Jetstream Hangar") "ping"
    $s = (Call GET "/api/status").json
    Check ($s.communityOk -and $s.community -eq $community) "Community override used ($($s.community))"
    $o = Call OPTIONS "/api/ping"; Check ($o.status -eq 204 -and $o.headers["Access-Control-Allow-Origin"] -eq "*") "CORS preflight for the EFB"
    $ui = Call GET "/"; Check ($ui.status -eq 200 -and $ui.text -match "Jetstream Hangar") "web UI served"
    Check ((Call GET "/app.js").status -eq 200) "app.js served"
    Check ((Call GET "/nope.html").status -eq 404) "unknown file 404"
    Check ((Call GET "/api/nope").status -eq 404) "unknown API 404"
    $set = (Call GET "/api/settings").json
    Check ($set.githubToken -eq "set" -and $set.githubToken -ne "secret-token-xyz") "GitHub token never returned to the UI"

    Section "catalogue and release selection"
    $cat = (Call GET "/api/catalog?refresh=1").json
    $A = $cat | ? id -eq "a"; $B = $cat | ? id -eq "b"; $D = $cat | ? id -eq "d"; $E = $cat | ? id -eq "e"
    Check ($A.installedVersion -eq "1.0.0" -and $A.latestVersion -eq "1.1.0") "A: installed 1.0.0, latest 1.1.0 (draft, pre-release and other tags ignored)"
    Check ($A.updateAvailable -eq $true) "A: update available"
    Check ($A.release.sha256Url -match "sha256") "A: checksum asset found"
    Check ($B.installed -eq $false -and $B.latestVersion -eq "1.0.0") "B: not installed, release found"
    Check ($D.releaseError -match "No release") "D: no release yet ($($D.releaseError))"
    Check ($E.latestVersion -eq "3.2.1") "E: tag without prefix (v3.2.1)"

    Section "install and update"
    Remove-Item (Join-Path $mock "requests.log") -ErrorAction SilentlyContinue
    $r = Call POST "/api/install" '{"id":"a"}'; Check ($r.status -eq 202) "update A accepted"
    $r2 = Call POST "/api/install" '{"id":"e"}'; Check ($r2.status -eq 409 -and $r2.json.error -match "Another installation") "second job refused while one runs"
    $j = WaitJob; Check ($j.state -eq "done") "update A finished ($($j.message))"
    $man = Get-Content (Join-Path $community "test-pkg-a\manifest.json") -Raw | ConvertFrom-Json
    Check ($man.package_version -eq "1.1.0") "A is now 1.1.0"
    $log = Get-Content (Join-Path $mock "requests.log") -ErrorAction SilentlyContinue
    Check ($log -contains "api/assetapi/test-pkg-a-1.1.0.zip auth") "private-repo path: asset requested from the asset API with the token"
    Check (($log | ? { $_ -like "dl/*" -and $_ -like "* auth" }).Count -eq 0) "the token is never sent to the file host after the redirect"
    Check (-not (Test-Path (Join-Path $community "test-pkg-a\old_only.txt"))) "files of the old version removed"
    Check ((Get-ChildItem $community -Directory -Force | ? Name -like ".hangar_*").Count -eq 0) "no temporary folders left"
    $A2 = (Call GET "/api/catalog").json | ? id -eq "a"; Check ($A2.updateAvailable -eq $false) "A up to date afterwards"
    $r = Call POST "/api/install" '{"id":"e"}'; $j = WaitJob
    Check ($j.state -eq "done" -and (Test-Path (Join-Path $community "test-pkg-e\manifest.json"))) "E installed from a zip without a top folder"
    $r = Call POST "/api/install" '{"id":"a"}'; $j = WaitJob; Check ($j.state -eq "done") "reinstall of the same version works"

    Section "failures leave the Community folder intact"
    $r = Call POST "/api/install" '{"id":"b"}'; $j = WaitJob
    Check ($j.state -eq "error" -and $j.message -match "manifest") "B: zip without manifest rejected ($($j.message))"
    Check (-not (Test-Path (Join-Path $community "test-pkg-b"))) "B: nothing installed"
    $r = Call POST "/api/install" '{"id":"c"}'; $j = WaitJob
    Check ($j.state -eq "error" -and $j.message -match "Checksum") "C: checksum mismatch rejected"
    Check (-not (Test-Path (Join-Path $community "test-pkg-c"))) "C: nothing installed"
    $r = Call POST "/api/install" '{"id":"d"}'; Check ($r.status -eq 409 -and $r.json.error -match "No release") "D: install refused without a release"
    $r = Call POST "/api/install" '{"id":"zzz"}'; Check ($r.status -eq 409 -and $r.json.error -match "Unknown") "unknown aircraft refused"
    Check ((Get-ChildItem $community -Directory -Force | ? Name -like ".hangar_*").Count -eq 0) "no temporary folders left after failures"

    Section "pre-release channel"
    Call POST "/api/settings" '{"prerelease":true}' | Out-Null
    $A3 = (Call GET "/api/catalog?refresh=1").json | ? id -eq "a"; Check ($A3.latestVersion -eq "2.0.0-beta") "with pre-releases on: 2.0.0-beta offered"
    Call POST "/api/settings" '{"prerelease":false}' | Out-Null
    $A4 = (Call GET "/api/catalog?refresh=1").json | ? id -eq "a"; Check ($A4.latestVersion -eq "1.1.0") "pre-releases off again: 1.1.0"

    Section "uninstall"
    New-Item -ItemType Directory -Force (Join-Path $community "test-pkg-b") | Out-Null
    $r = Call POST "/api/uninstall" '{"id":"b"}'; Check ($r.status -eq 409 -and (Test-Path (Join-Path $community "test-pkg-b"))) "folder without manifest.json is never deleted"
    $r = Call POST "/api/uninstall" '{"id":"a"}'; Check ($r.status -eq 200 -and -not (Test-Path (Join-Path $community "test-pkg-a"))) "A uninstalled"
    $r = Call POST "/api/uninstall" '{"id":"a"}'; Check ($r.status -eq 409 -and $r.json.error -match "Not installed") "uninstall twice: not installed"

    Section "EFB technical state sync"
    $r = Call POST "/api/aircraft/aero-at3/state" '{"oil":2.9,"tyres":{"n":2.5,"l":1.4,"r":2.5},"log":[]}'; Check ($r.status -eq 200) "state stored"
    $g = Call GET "/api/aircraft/aero-at3/state"; Check ($g.status -eq 200 -and $g.json.oil -eq 2.9 -and $g.json._seen) "state read back with sync time"
    $r = Call POST "/api/aircraft/aero-at3/state" '{not json'; Check ($r.status -eq 400) "invalid JSON rejected"
    Check ((Call GET "/api/aircraft/unknown/state").status -eq 404) "unknown aircraft state 404"
    Check ((Call GET "/api/aircraft/..%2F..%2Fsettings/state").status -eq 404) "path traversal in the id is not routed"

    Section "Navigraph proxy"
    Check ((Call GET "/api/navigraph/token").status -eq 405) "token endpoint is POST only"
    if (Test-Path (Join-Path $data "secrets.json")) {
        $bytes = New-Object byte[] 32; (New-Object Security.Cryptography.RNGCryptoServiceProvider).GetBytes($bytes)
        $b64 = { param($x) [Convert]::ToBase64String($x).TrimEnd('=').Replace('+', '-').Replace('/', '_') }
        $verifier = & $b64 $bytes
        $challenge = & $b64 ([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::ASCII.GetBytes($verifier)))
        $form = "code_challenge=$challenge&code_challenge_method=S256&scope=" + [Uri]::EscapeDataString("openid fmsdata charts:index:read offline_access") + "&client_secret=EVIL"
        $r = Call POST "/api/navigraph/deviceauthorization" $form "application/x-www-form-urlencoded"
        Check ($r.status -eq 200 -and $r.json.device_code -and $r.json.user_code) "real Navigraph device authorization through the proxy (user code $($r.json.user_code))"
        $r = Call POST "/api/navigraph/token" ("grant_type=" + [Uri]::EscapeDataString("urn:ietf:params:oauth:grant-type:device_code") + "&device_code=$($r.json.device_code)&code_verifier=$verifier&scope=" + [Uri]::EscapeDataString("openid fmsdata charts:index:read offline_access")) "application/x-www-form-urlencoded"
        Check ($r.status -eq 400 -and @("authorization_pending", "slow_down") -contains $r.json.error) "token poll answers like the device flow expects ($($r.json.error))"
    } else { Check $false "no secrets.json - Navigraph proxy not tested" }

    # ================= automatic updates =================
    function StartInstance($exePath, $settings) {
        Utf8NoBom (Join-Path $data "settings.json") (ConvertTo-Json $settings)
        $env:JETSTREAM_HANGAR_PORT = "$port"; $env:JETSTREAM_HANGAR_DATA = $data
        $pp = Start-Process $exePath -ArgumentList "--background" -PassThru
        Remove-Item Env:JETSTREAM_HANGAR_PORT, Env:JETSTREAM_HANGAR_DATA
        for ($i = 0; $i -lt 50; $i++) { if ((Call GET "/api/ping").status -eq 200) { break }; Start-Sleep -Milliseconds 200 }
        return $pp
    }
    function StopAll() { Get-Process JetstreamHangar -ErrorAction SilentlyContinue | ? { $_.Path -like "$T*" -or $_.Id -eq $proc.Id } | Stop-Process -Force -ErrorAction SilentlyContinue; Start-Sleep -Milliseconds 500 }
    function WaitUntil($cond, $seconds) { for ($i = 0; $i -lt $seconds * 5; $i++) { if (& $cond) { return $true }; Start-Sleep -Milliseconds 200 }; return $false }
    $baseSettings = @{ catalogUrl = "http://localhost:8766/catalog.json"; communityOverride = $community; githubApiBase = "http://localhost:8766/api"; githubToken = "secret-token-xyz"; checkHours = 24; prerelease = $false; startDelayMs = 200; simPollSeconds = 2; hangarRepo = "test/none" }
    $runDir = Join-Path $T "run"; New-Item -ItemType Directory -Force $runDir | Out-Null
    Copy-Item $exe (Join-Path $runDir "JetstreamHangar.exe")

    Section "aircraft auto-update (waits for MSFS)"
    StopAll
    Remove-Item (Join-Path $community "test-pkg-a") -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force $preA | Out-Null
    Utf8NoBom (Join-Path $preA "manifest.json") '{ "content_type": "AIRCRAFT", "package_version": "1.0.0" }'
    $fakeSim = Join-Path $T "FlightSimulator2024.exe"; Copy-Item "$env:SystemRoot\System32\timeout.exe" $fakeSim
    $sim = Start-Process $fakeSim -ArgumentList "/t", "60", "/nobreak" -WindowStyle Hidden -PassThru
    $s1 = $baseSettings.Clone(); $s1.autoUpdate = $true; $s1.selfUpdate = $false
    $p1 = StartInstance (Join-Path $runDir "JetstreamHangar.exe") $s1
    $st = $null; $waited = WaitUntil { $script:st = (Call GET "/api/status").json; $st.waiting -contains "Aircraft A" } 10
    Check $waited "update waits while MSFS runs (status: $($st.waiting -join ', '))"
    Check ((Get-Content (Join-Path $preA "manifest.json") -Raw | ConvertFrom-Json).package_version -eq "1.0.0") "nothing installed while MSFS runs"
    $r = Call POST "/api/install" '{"id":"a"}'; Check ($r.status -eq 409 -and $r.json.error -match "Close Microsoft Flight Simulator") "manual install refused while MSFS runs"
    Stop-Process -Id $sim.Id -Force
    $done = WaitUntil { (Get-Content (Join-Path $preA "manifest.json") -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json).package_version -eq "1.1.0" } 20
    Check $done "installed automatically once MSFS was closed"
    Check (((Call GET "/api/status").json.waiting).Count -eq 0) "nothing waiting afterwards"
    StopAll

    Section "aircraft auto-update at start (MSFS closed)"
    Remove-Item $preA -Recurse -Force; New-Item -ItemType Directory -Force $preA | Out-Null
    Utf8NoBom (Join-Path $preA "manifest.json") '{ "content_type": "AIRCRAFT", "package_version": "1.0.0" }'
    $p2 = StartInstance (Join-Path $runDir "JetstreamHangar.exe") $s1
    $done = WaitUntil { (Get-Content (Join-Path $preA "manifest.json") -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json).package_version -eq "1.1.0" } 15
    Check $done "new release installed right after start, without any click"
    Check (-not (Test-Path (Join-Path $community "test-pkg-b\manifest.json")) -and -not (Test-Path (Join-Path $community "test-pkg-c"))) "aircraft that are not installed are not installed automatically"
    StopAll

    Section "hangar self-update"
    $b999 = Join-Path $T "b999"
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $hangarRoot "build.ps1") -Version 9.9.9 -OutDir $b999 | Out-Null
    Copy-Item (Join-Path $b999 "JetstreamHangar.exe") (Join-Path $mock "dl\JetstreamHangar.exe")
    $newHash = Sha (Join-Path $b999 "JetstreamHangar.exe")
    Utf8NoBom (Join-Path $mock "dl\JetstreamHangar.exe.sha256") "$newHash  JetstreamHangar.exe"
    WriteReleases "test\hangar" @(
        (Release "hangar-v9.9.9" @((Asset "JetstreamHangar.exe" (Get-Item (Join-Path $b999 "JetstreamHangar.exe")).Length), (Asset "JetstreamHangar.exe.sha256" 64))),
        (Release "hangar-v0.9.0" @(Asset "JetstreamHangar.exe" 1)),
        (Release "at3-v7.0.0" @(Asset "test-pkg-a-7.0.0.zip" 1)))
    $s2 = $baseSettings.Clone(); $s2.autoUpdate = $false; $s2.selfUpdate = $true; $s2.hangarRepo = "test/hangar"
    $p3 = StartInstance (Join-Path $runDir "JetstreamHangar.exe") $s2
    $v = $null; $ok999 = WaitUntil { $script:v = (Call GET "/api/ping").json.version; $v -eq "9.9.9" } 25
    Check $ok999 "restarted as version 9.9.9 by itself (now $v)"
    Check ((Sha (Join-Path $runDir "JetstreamHangar.exe")) -eq $newHash) "the exe on disk is the new build"
    Check (WaitUntil { -not (Test-Path (Join-Path $runDir "JetstreamHangar.exe.old")) } 10) "old exe cleaned up"
    Check (-not (Test-Path (Join-Path $runDir "JetstreamHangar.new.exe"))) "no download left behind"
    Start-Sleep -Seconds 3
    Check ((Call GET "/api/ping").json.version -eq "9.9.9" -and @(Get-Process JetstreamHangar -ErrorAction SilentlyContinue | ? { $_.Path -like "$runDir*" }).Count -eq 1) "exactly one instance runs, no update loop"
    StopAll

    Section "hangar self-update with a bad checksum"
    $runDir2 = Join-Path $T "run2"; New-Item -ItemType Directory -Force $runDir2 | Out-Null; Copy-Item $exe (Join-Path $runDir2 "JetstreamHangar.exe")
    $oldHash = Sha (Join-Path $runDir2 "JetstreamHangar.exe")
    Copy-Item (Join-Path $b999 "JetstreamHangar.exe") (Join-Path $mock "dl\JetstreamHangarBad.exe")
    Utf8NoBom (Join-Path $mock "dl\JetstreamHangarBad.exe.sha256") ("0" * 64)
    WriteReleases "test\hangarbad" @((Release "hangar-v9.9.9" @((Asset "JetstreamHangarBad.exe" 1), (Asset "JetstreamHangarBad.exe.sha256" 64))))
    $s3 = $s2.Clone(); $s3.hangarRepo = "test/hangarbad"
    $p4 = StartInstance (Join-Path $runDir2 "JetstreamHangar.exe") $s3
    $st = $null; $err = WaitUntil { $script:st = (Call GET "/api/status").json; $st.selfUpdate.state -eq "error" } 15
    Check ($err -and $st.selfUpdate.message -match "checksum") "corrupt update rejected ($($st.selfUpdate.message))"
    Check ((Call GET "/api/ping").json.version -eq "1.0.0" -and (Sha (Join-Path $runDir2 "JetstreamHangar.exe")) -eq $oldHash) "still running the original, exe untouched"
    Check (-not (Test-Path (Join-Path $runDir2 "JetstreamHangar.new.exe"))) "bad download deleted"
    StopAll}
finally {
    try { Stop-Process -Id $proc.Id -Force } catch { }
    Get-Process JetstreamHangar -ErrorAction SilentlyContinue | ? { $_.Path -like "$T*" } | Stop-Process -Force -ErrorAction SilentlyContinue
    Get-Process FlightSimulator2024 -ErrorAction SilentlyContinue | ? { $_.Path -like "$T*" } | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 500
    try { Stop-Process -Id $mockProc.Id -Force } catch { }
    Start-Sleep -Milliseconds 300
    Remove-Item $T -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item $mock -Recurse -Force -ErrorAction SilentlyContinue
}
$head = "Jetstream Hangar end-to-end tests - $(Get-Date -Format s)", "$($results.Count) lines, $fails failed", ""
$out = ($head + $results) -join "`r`n"
[IO.File]::WriteAllText((Join-Path $PSScriptRoot "results.txt"), $out)
$out
