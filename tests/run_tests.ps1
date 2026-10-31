# End-to-end tests for Jetstream Hangar. Runs a second hangar instance (port 48339, its own data folder and a
# temporary Community folder) against a mock GitHub Releases API (tests\mockserver.ps1, port 8766).
# Nothing in the real Community folder or the real hangar settings is touched.
# Usage: powershell -File tests\run_tests.ps1
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.IO.Compression.FileSystem
$hangarRoot = Split-Path $PSScriptRoot -Parent
$exe = Join-Path $hangarRoot "dist\JetstreamHangar.exe"
$curVer = (Get-Content (Join-Path $hangarRoot "VERSION") -Raw).Trim()   # version of the build under test
$mock = Join-Path $PSScriptRoot "mock"
$T = Join-Path $env:TEMP ("hangar_test_" + [guid]::NewGuid().ToString("N").Substring(0, 8))
$data = Join-Path $T "data"; $community = Join-Path $T "Community"
$port = 48339; $base = "http://localhost:$port"
$results = New-Object System.Collections.Generic.List[string]; $fails = 0
function Check($cond, $msg) { if ($cond) { $script:results.Add("  PASS  $msg") } else { $script:results.Add("  FAIL  $msg"); $script:fails++ } }
function Section($name) { $script:results.Add("[$name]") }

# ---- HTTP helper that returns status + parsed JSON for any status code ----
function Call($method, $path, $body, $contentType, $origin, $hostHeader) {
    $req = [Net.HttpWebRequest]::Create("$base$path"); $req.Method = $method; $req.Timeout = 60000
    # scripts identify themselves with X-Hangar (browsers cannot send it cross-origin); tests can fake an Origin or Host
    if ($origin) { $req.Headers["Origin"] = $origin } else { $req.Headers["X-Hangar"] = "1" }
    if ($hostHeader) { $req.Host = $hostHeader }
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
$eZip = MakeZip "test-pkg-e" "3.2.1" -flat
WriteReleases "test\e" @((Release "v3.2.1" @(Asset "test-pkg-e-3.2.1.zip" (Get-Item $eZip).Length)))
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

Section "API security (browser pages cannot drive the hangar)"
    $evil = "https://evil.example"
    $r = Call POST "/api/install" '{"id":"e"}' $null $evil; Check ($r.status -eq 403) "install from a foreign web page refused"
    $before = (Call GET "/api/settings").json.catalogUrl
    $r = Call POST "/api/settings" '{"catalogUrl":"https://evil.example/catalog.json"}' $null $evil
    Check ($r.status -eq 403 -and (Call GET "/api/settings").json.catalogUrl -eq $before) "settings change from a foreign web page refused, unchanged"
    Check ((Call POST "/api/quit" "" $null $evil).status -eq 403) "quit from a foreign web page refused"
    Check ((Call POST "/api/open-community" "" $null $evil).status -eq 403) "open folder from a foreign web page refused"
    Check ((Call GET "/api/ping" $null $null $evil).status -eq 200) "EFB endpoint ping open to any origin"
    $r = Call POST "/api/aircraft/aero-at3/state" '{"oil":3}' $null "coui://html_ui"; Check ($r.status -eq 200) "EFB state sync from the sim origin allowed"
    Check (@(400, 403) -contains (Call GET "/api/status" $null $null $null "evil.example:$port").status) "DNS rebinding (foreign Host header) refused (Windows HTTP layer: 400, hangar check: 403)"
    Check ((Call POST "/api/settings" '{"checkHours":24}' $null "http://localhost:$port").status -eq 200) "the hangar page itself may change settings"
    Section "catalogue and release selection"
    $cat = (Call GET "/api/catalog?refresh=1").json
    $A = $cat | ? id -eq "a"; $B = $cat | ? id -eq "b"; $D = $cat | ? id -eq "d"; $E = $cat | ? id -eq "e"
    Check ($A.installedVersion -eq "1.0.0" -and $A.latestVersion -eq "1.1.0") "A: installed 1.0.0, latest 1.1.0 (draft, pre-release and other tags ignored)"
    Check ($A.updateAvailable -eq $true) "A: update available"
    Check ($A.release.sha256Url -match "sha256") "A: checksum asset found"
    Check ($B.installed -eq $false -and $B.latestVersion -eq "1.0.0") "B: not installed, release found"
    Check ($D.releaseError -match "No release") "D: no release yet ($($D.releaseError))"
    Check ($E.latestVersion -eq "3.2.1") "E: tag without prefix (v3.2.1)"

    Section "GitHub rate limit and cache"
    Remove-Item (Join-Path $mock "requests.log") -ErrorAction SilentlyContinue
    $cat2 = (Call GET "/api/catalog?refresh=1").json
    $log = Get-Content (Join-Path $mock "requests.log") -ErrorAction SilentlyContinue
    Check (($log | ? { $_ -like "* 304" }).Count -ge 2 -and ($cat2 | ? id -eq "a").latestVersion -eq "1.1.0") "unchanged catalogue and releases answered with 304 from the cache"
    New-Item -ItemType File -Force (Join-Path $mock "ratelimit") | Out-Null
    $rl = Call GET "/api/catalog?refresh=1"; $A5 = $rl.json | ? id -eq "a"
    Check ($rl.status -eq 200 -and $A5.latestVersion -eq "1.1.0" -and -not $A5.releaseError) "rate limited: last known catalogue and releases still shown"
    $st = (Call GET "/api/status").json
    Check ($st.githubNotice -match "rate limit reached until \d\d:\d\d" -and $st.githubNotice -match "last known") "rate limit notice for the UI ($($st.githubNotice))"
    Call POST "/api/settings" '{"catalogUrl":"http://localhost:8766/fresh/catalog.json"}' | Out-Null
    $rl2 = Call GET "/api/catalog?refresh=1"
    Check ($rl2.status -eq 500 -and $rl2.json.error -match "rate limit reached") "rate limited without a cache: clear error ($($rl2.json.error))"
    Call POST "/api/settings" '{"catalogUrl":"http://localhost:8766/catalog.json"}' | Out-Null
    Remove-Item (Join-Path $mock "ratelimit")
    Call GET "/api/catalog?refresh=1" | Out-Null
    Check ([string]::IsNullOrEmpty((Call GET "/api/status").json.githubNotice)) "notice cleared once GitHub answers again"

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
    Check (WaitUntil { -not (Call GET "/api/status").json.simRunning } 5) "MSFS closed again"
    # the SDK package tool starts the sim headless with "BuildAssetPackages": that is not the sim being flown
    $fakeBuild = Join-Path $T "build\FlightSimulator2024.exe"; New-Item -ItemType Directory -Force (Split-Path $fakeBuild) | Out-Null; Copy-Item "$env:SystemRoot\System32\cmd.exe" $fakeBuild
    $bsim = Start-Process $fakeBuild -ArgumentList '/c "ping -n 20 127.0.0.1 >nul & rem BuildAssetPackages C:\x.xml"' -WindowStyle Hidden -PassThru
    Start-Sleep -Seconds 1
    $stB = (Call GET "/api/status").json
    Check ($stB.simRunning -eq $false) "package build (FlightSimulator2024 BuildAssetPackages) is not counted as MSFS running"
    Stop-Process -Id $bsim.Id -Force -ErrorAction SilentlyContinue
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
    Check ((Call GET "/api/ping").json.version -eq $curVer -and (Sha (Join-Path $runDir2 "JetstreamHangar.exe")) -eq $oldHash) "still running the original, exe untouched"
    Check (-not (Test-Path (Join-Path $runDir2 "JetstreamHangar.new.exe"))) "bad download deleted"
    StopAll
    Section "GitHub unreachable: keeps running"
    StopAll
    $s4 = $baseSettings.Clone(); $s4.catalogUrl = "http://localhost:8766/missing/catalog.json"; $s4.autoUpdate = $true; $s4.selfUpdate = $true; $s4.hangarRepo = "test/missing"
    $p5 = StartInstance (Join-Path $runDir2 "JetstreamHangar.exe") $s4
    Start-Sleep -Seconds 6
    Check ((Call GET "/api/ping").status -eq 200) "still running 6 s after failing update checks"
    $logText = Get-Content (Join-Path $data "hangar.log") -Raw -ErrorAction SilentlyContinue
    Check ($logText -match "catalogue not available|update check failed") "the failure is written to hangar.log"
    $c404 = Call GET "/api/catalog?refresh=1"; Check ($c404.status -eq 500 -and $c404.json.error) "catalogue error reported to the UI ($($c404.json.error))"
    StopAll

    Section "settings of 1.0.1 migrate to the rate-limit free catalogue"
    $s5 = $baseSettings.Clone(); $s5.catalogUrl = "https://api.github.com/repos/joosthv/The-Hangar/contents/catalog.json"; $s5.autoUpdate = $false; $s5.selfUpdate = $false
    $p6 = StartInstance (Join-Path $runDir2 "JetstreamHangar.exe") $s5
    Check ((Call GET "/api/settings").json.catalogUrl -eq "https://raw.githubusercontent.com/joosthv/The-Hangar/main/catalog.json") "old contents-API catalogue URL replaced by raw.githubusercontent.com"
    StopAll

    Section "install, reinstall over a running copy, uninstall"
    $instDir = Join-Path $T "inst"; $scDir = Join-Path $T "shortcuts"; $regName = "JetstreamHangarTest_" + [guid]::NewGuid().ToString("N").Substring(0, 6)
    $dl = Join-Path $T "download"; New-Item -ItemType Directory -Force $dl | Out-Null; Copy-Item $exe (Join-Path $dl "JetstreamHangar.exe")
    Utf8NoBom (Join-Path $data "settings.json") (ConvertTo-Json $s2)
    function WithInstallEnv($block) {
        $env:JETSTREAM_HANGAR_PORT = "$port"; $env:JETSTREAM_HANGAR_DATA = $data; $env:JETSTREAM_HANGAR_INSTALLDIR = $instDir; $env:JETSTREAM_HANGAR_SHORTCUTS = $scDir; $env:JETSTREAM_HANGAR_REGKEY = $regName
        try { & $block } finally { Remove-Item Env:JETSTREAM_HANGAR_PORT, Env:JETSTREAM_HANGAR_DATA, Env:JETSTREAM_HANGAR_INSTALLDIR, Env:JETSTREAM_HANGAR_SHORTCUTS, Env:JETSTREAM_HANGAR_REGKEY -ErrorAction SilentlyContinue }
    }
    $s2b = $s2.Clone(); $s2b.selfUpdate = $false; Utf8NoBom (Join-Path $data "settings.json") (ConvertTo-Json $s2b)
    WithInstallEnv { Start-Process (Join-Path $dl "JetstreamHangar.exe") -ArgumentList "--background" | Out-Null }
    $up = WaitUntil { (Call GET "/api/ping").status -eq 200 } 20
    $instExe = Join-Path $instDir "JetstreamHangar.exe"
    Check ($up -and (Test-Path $instExe)) "downloaded exe installed itself to the program folder"
    Check (@(Get-Process JetstreamHangar -ErrorAction SilentlyContinue | ? { $_.Path -eq $instExe }).Count -eq 1 -and @(Get-Process JetstreamHangar -ErrorAction SilentlyContinue | ? { $_.Path -like "$dl*" }).Count -eq 0) "the installed copy runs, the download copy exited"
    Check ((Test-Path (Join-Path $scDir "Programs\Jetstream Hangar.lnk")) -and (Test-Path (Join-Path $scDir "Desktop\Jetstream Hangar.lnk"))) "Start menu and desktop shortcuts"
    $lnkTarget = (New-Object -ComObject WScript.Shell).CreateShortcut((Join-Path $scDir "Programs\Jetstream Hangar.lnk")).TargetPath
    Check ($lnkTarget -eq $instExe) "shortcut points at the installed exe"
    $uk = Get-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\$regName" -ErrorAction SilentlyContinue
    Check ($uk -and $uk.DisplayVersion -eq $curVer -and $uk.UninstallString -match "--uninstall" -and $uk.InstallLocation -eq $instDir) "Apps & Features entry with uninstaller"
    $run = (Get-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" -ErrorAction SilentlyContinue).$regName
    Check ($run -eq "`"$instExe`" --background") "starts with Windows (tray only)"
    $pid1 = (Get-Process JetstreamHangar | ? { $_.Path -eq $instExe }).Id
    WithInstallEnv { Start-Process (Join-Path $dl "JetstreamHangar.exe") -ArgumentList "--background" | Out-Null }
    $re = WaitUntil { $p = Get-Process JetstreamHangar -ErrorAction SilentlyContinue | ? { $_.Path -eq $instExe }; $p -and $p.Id -ne $pid1 -and (Call GET "/api/ping").status -eq 200 } 25
    Check $re "running again after the download was started once more (old copy quit, exe replaced)"
    Check (@(Get-Process JetstreamHangar -ErrorAction SilentlyContinue | ? { $_.Path -like "$T*" }).Count -eq 1) "exactly one copy runs"
    WithInstallEnv { Start-Process $instExe -ArgumentList "--uninstall", "--quiet" -Wait }
    $gone = WaitUntil { -not (Test-Path $instDir) } 15
    Check ((Call GET "/api/ping").status -ne 200) "uninstall stopped the running copy"
    Check $gone "program folder removed"
    Check (-not (Test-Path (Join-Path $scDir "Programs\Jetstream Hangar.lnk")) -and -not (Test-Path (Join-Path $scDir "Desktop\Jetstream Hangar.lnk"))) "shortcuts removed"
    Check (-not (Test-Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\$regName")) "Apps & Features entry removed"
    Check (-not (Get-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" -ErrorAction SilentlyContinue).$regName) "autostart removed"
    Check (Test-Path (Join-Path $data "settings.json")) "settings kept"
    StopAll
    # ================= Navigraph account held by the hangar (mock identity server) =================
    Section "Navigraph account: sign-in, tokens, refresh rotation, storage"
    StopAll
    $runDir3 = Join-Path $T "run3"; New-Item -ItemType Directory -Force $runDir3 | Out-Null; Copy-Item $exe (Join-Path $runDir3 "JetstreamHangar.exe")
    $exe3 = Join-Path $runDir3 "JetstreamHangar.exe"
    Remove-Item (Join-Path $data "navigraph.dat"), (Join-Path $mock "tokencount"), (Join-Path $mock "identity.log"), (Join-Path $mock "invalidgrant") -ErrorAction SilentlyContinue
    Utf8NoBom (Join-Path $data "secrets.json") '{ "navigraphClientId": "test-id", "navigraphClientSecret": "test-secret" }'
    $sn = $baseSettings.Clone(); $sn.autoUpdate = $false; $sn.selfUpdate = $false; $sn.navigraphIdentity = "http://localhost:8766/identity"; $sn.navigraphHeartbeatSeconds = 3
    $p6 = StartInstance $exe3 $sn
    $page = "http://localhost:$port"
    Check ((Call GET "/api/navigraph/session").json.state -eq "out") "not signed in at first"
    $r = Call GET "/api/navigraph/access"; Check ($r.status -eq 401 -and $r.json.error -eq "not_signed_in") "no token while signed out"
    $r = Call POST "/api/navigraph/login" "" $null $page; Check ($r.status -eq 202) "sign-in started from the hangar page"
    $sawCode = $false
    $in = WaitUntil { $s = (Call GET "/api/navigraph/session").json; if ($s.state -eq "waiting" -and $s.code.user_code -eq "MOCKCODE") { $script:sawCode = $true }; $s.state -eq "in" } 15
    Check $sawCode "code, link and expiry offered while waiting (MOCKCODE)"
    Check $in "signed in after the approval"
    Check (WaitUntil { (Call GET "/api/navigraph/session").json.user -eq "mockpilot" } 5) "user name from userinfo"
    $ilog = Get-Content (Join-Path $mock "identity.log") -ErrorAction SilentlyContinue
    $dev = $ilog | ? { $_ -like "identity/connect/deviceauthorization*" } | Select-Object -First 1
    Check ($dev -match "client_secret=test-secret" -and $dev -match "code_challenge_method=S256" -and $dev -match "code_challenge=[A-Za-z0-9_-]{43}") "device request: credentials added by the hangar, S256 challenge"
    $tok = $ilog | ? { $_ -like "identity/connect/token |*" } | Select-Object -First 1
    Check ($tok -match "code_verifier=[A-Za-z0-9_-]{43}" -and $tok -match "scope=openid") "token poll: PKCE verifier and scope"
    $r = Call GET "/api/navigraph/access"; Check ($r.status -eq 200 -and $r.json.access_token -eq "AT-1" -and $r.json.expires_in -gt 0) "access token for the EFB"
    $dat = Join-Path $data "navigraph.dat"
    Check ((Test-Path $dat) -and -not ([Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($dat)) -match "RT-1")) "refresh token stored encrypted (DPAPI), not in plain text"
    StopAll
    $p7 = StartInstance $exe3 $sn
    Check ((Call GET "/api/navigraph/session").json.state -eq "in") "still signed in after a restart"
    $r = Call GET "/api/navigraph/access"; Check ($r.json.access_token -eq "AT-2") "after the restart: refreshed with the stored token (AT-2)"
    StopAll
    $p8 = StartInstance $exe3 $sn
    $r = Call GET "/api/navigraph/access"; Check ($r.json.access_token -eq "AT-3") "rotated refresh token was stored and used (AT-3)"

    Section "Navigraph account: who may get a token"
    $evil = "https://evil.example"
    Check ((Call GET "/api/navigraph/access" $null $null $evil).status -eq 403) "a web page cannot read the token"
    Check ((Call POST "/api/navigraph/logout" "" $null $evil).status -eq 403) "a web page cannot sign out"
    Check ((Call POST "/api/navigraph/login" "" $null $evil).status -eq 403) "a web page cannot start a sign-in"
    $r = Call GET "/api/navigraph/session" $null $null $evil; Check ($r.status -eq 200 -and $r.text -notmatch "AT-|RT-") "the session state is public but carries no tokens"
    Check ((Call GET "/api/navigraph/access" $null $null "coui://html_ui").json.access_token -eq "AT-3") "the sim (coui:// origin) gets the token"
    $log = Get-Content (Join-Path $data "hangar.log") -Raw; Check ($log -match "refused /api/navigraph/access from origin https://evil.example") "refusals are logged with the origin"

    Section "Navigraph account: heartbeat, sign-out, expired sign-in"
    Remove-Item (Join-Path $mock "tokencount") -ErrorAction SilentlyContinue
    $r = Call POST "/api/navigraph/logout" "" $null $page
    Check ((Call GET "/api/navigraph/session").json.state -eq "out" -and -not (Test-Path $dat)) "sign-out removes the stored sign-in"
    Check ((Call GET "/api/navigraph/access").status -eq 401) "no token after sign-out"
    Utf8NoBom (Join-Path $mock "pending") "1"
    Call POST "/api/navigraph/login" "" $null $page | Out-Null
    Start-Sleep -Seconds 6     # nobody looks at the session (heartbeat 3 s)
    $s = (Call GET "/api/navigraph/session").json
    Check ($s.state -eq "out" -and $s.message -match "closed") "sign-in stops when nobody watches the sign-in screen ($($s.message))"
    $polls = @(Get-Content (Join-Path $mock "identity.log") | ? { $_ -like "identity/connect/token |*" }).Count; Start-Sleep -Seconds 3
    Check (@(Get-Content (Join-Path $mock "identity.log") | ? { $_ -like "identity/connect/token |*" }).Count -eq $polls) "no more token polls after that"
    Call POST "/api/navigraph/login" "" $null $page | Out-Null
    WaitUntil { (Call GET "/api/navigraph/session").json.state -eq "waiting" } 5 | Out-Null
    Call POST "/api/navigraph/cancel" "" $null $page | Out-Null
    Check ((Call GET "/api/navigraph/session").json.state -eq "out") "cancel ends a waiting sign-in"
    Remove-Item (Join-Path $mock "pending"), (Join-Path $mock "tokencount") -ErrorAction SilentlyContinue
    Call POST "/api/navigraph/login" "" $null $page | Out-Null
    WaitUntil { (Call GET "/api/navigraph/session").json.state -eq "in" } 15 | Out-Null
    StopAll; Utf8NoBom (Join-Path $mock "invalidgrant") "1"
    $p9 = StartInstance $exe3 $sn
    $r = Call GET "/api/navigraph/access"; $s = (Call GET "/api/navigraph/session").json
    Check ($r.status -eq 401 -and $s.state -eq "out" -and $s.message -match "expired" -and -not (Test-Path $dat)) "rejected refresh token: signed out cleanly, asked to sign in again"
    Remove-Item (Join-Path $mock "invalidgrant")
    Utf8NoBom (Join-Path $data "secrets.json") '{}'
    StopAll; $p10 = StartInstance $exe3 $sn
    $r = Call POST "/api/navigraph/login" "" $null $page; Check ($r.status -eq 503 -and $r.json.error -eq "navigraph_not_configured") "no credentials installed: clear error"

    Section "Navigraph API client entered on the hangar page"
    $cred = '{"clientId":"ui-client","clientSecret":"ui-secret-123456"}'
    Check ((Call POST "/api/navigraph/credentials" $cred $null "https://evil.example").status -eq 403) "a web page cannot set the credentials"
    Check ((Call POST "/api/navigraph/credentials" $cred $null "coui://html_ui").status -eq 403) "the sim cannot set the credentials"
    $r = Call POST "/api/navigraph/credentials" '{"clientId":"bad id!","clientSecret":"x"}' $null $page; Check ($r.status -eq 400 -and $r.json.error) "invalid credentials rejected ($($r.json.error))"
    $r = Call POST "/api/navigraph/credentials" $cred $null $page; Check ($r.status -eq 200 -and $r.json.configured -eq $true) "credentials stored from the hangar page"
    $cdat = Join-Path $data "navigraph-client.dat"
    Check ((Test-Path $cdat) -and -not ([Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($cdat)) -match "ui-secret")) "stored encrypted (DPAPI), not in plain text"
    Check ((Call GET "/api/settings").text -notmatch "ui-secret" -and (Call GET "/api/navigraph/session").text -notmatch "ui-secret") "the secret is never returned"
    StopAll; $p10b = StartInstance $exe3 $sn
    Check ((Call GET "/api/ping").json.navigraph -eq $true -and (Call GET "/api/navigraph/session").json.configured -eq $true) "configured after a restart (EFB backend ready)"
    Remove-Item (Join-Path $mock "identity.log"), (Join-Path $mock "tokencount") -ErrorAction SilentlyContinue
    Call POST "/api/navigraph/login" "" $null $page | Out-Null
    WaitUntil { (Call GET "/api/navigraph/session").json.state -eq "in" } 15 | Out-Null
    $dev = Get-Content (Join-Path $mock "identity.log") -ErrorAction SilentlyContinue | ? { $_ -like "identity/connect/deviceauthorization*" } | Select-Object -First 1
    Check ($dev -match "client_id=ui-client" -and $dev -match "client_secret=ui-secret-123456") "sign-in uses the entered client"
    Call POST "/api/navigraph/logout" "" $null $page | Out-Null
    $r = Call POST "/api/navigraph/credentials" '{"clientId":"","clientSecret":""}' $null $page; Check ($r.json.configured -eq $false -and -not (Test-Path $cdat)) "empty credentials remove them"
    StopAll

    Section "release list re-read when it is old"
    $sr = $baseSettings.Clone(); $sr.autoUpdate = $false; $sr.selfUpdate = $false; $sr.releaseCacheSeconds = 3
    $p10c = StartInstance $exe3 $sr
    Check (((Call GET "/api/catalog").json | ? id -eq "e").latestVersion -eq "3.2.1") "E: latest 3.2.1"
    WriteReleases "test\e" @((Release "v3.3.0" @(Asset "test-pkg-e-3.3.0.zip" 1)), (Release "v3.2.1" @(Asset "test-pkg-e-3.2.1.zip" (Get-Item $eZip).Length)))
    Check (((Call GET "/api/catalog").json | ? id -eq "e").latestVersion -eq "3.2.1") "remembered while fresh (no GitHub request per page view)"
    Start-Sleep -Seconds 4
    Check (((Call GET "/api/catalog").json | ? id -eq "e").latestVersion -eq "3.3.0") "new release shown without a manual refresh once the list is old"
    WriteReleases "test\e" @((Release "v3.2.1" @(Asset "test-pkg-e-3.2.1.zip" (Get-Item $eZip).Length)))
    StopAll

    # ================= scenery overview =================
    Section "Community folder overview (scenery)"
    $sc = Join-Path $T "SceneryCommunity"; New-Item -ItemType Directory -Force $sc | Out-Null
    function Pkg($folder, $type, $title, $hist) {
        $d = Join-Path $sc $folder; New-Item -ItemType Directory -Force $d | Out-Null
        if ($type) { Utf8NoBom (Join-Path $d "manifest.json") ('{ "content_type": "' + $type + '", "title": "' + $title + '", "creator": "Test Studio", "package_version": "1.2.3", "total_package_size": "00000000000104857600" }') }
        if ($hist) { $ci = Join-Path $d "ContentInfo\$folder"; New-Item -ItemType Directory -Force $ci | Out-Null; Utf8NoBom (Join-Path $ci "ContentHistory.json") $hist }
    }
    Pkg "flytampa-eham-amsterdam" "SCENERY" "EHAM Amsterdam" '{ "items": [ { "type": "Airport", "content": "EHAM" }, { "type": "Airport", "content": "ehlE" }, { "type": "Other", "content": "XXXX" } ] }'
    Pkg "orbx-ybbn-brisbane" "SCENERY" "Brisbane" $null
    Pkg "aero-aircraft-at3" "AIRCRAFT" "Aero AT-3" $null
    Pkg "broken-folder" $null $null $null
    Pkg "navigraph-nav-base" "SCENERY" "Navigraph Navdata Base" '{ "items": [ { "type": "Airport", "content": "EGLL" } ] }'
    Pkg "fsdreamteam-gsx-pro" "SCENERY" "GSX Pro" $null
    Utf8NoBom (Join-Path $mock "airports.csv") (@(
        '"id","ident","type","name","latitude_deg","longitude_deg","elevation_ft","continent","iso_country","iso_region","municipality","scheduled_service","icao_code","iata_code","gps_code","local_code"',
        '1,"EHAM","large_airport","Amsterdam Airport Schiphol",52.308601,4.76389,-11,"EU","NL","NL-NH","Amsterdam","yes","EHAM","AMS","EHAM",""',
        '2,"EHLE","medium_airport","Lelystad Airport",52.4603,5.52722,-13,"EU","NL","NL-FL","Lelystad","yes","EHLE","LEY","EHLE",""',
        '3,"XX-1","closed","Old Brisbane, closed",-27.40,153.10,0,"OC","AU","AU-QLD","Brisbane","no","","","YBBN",""',
        '4,"YBBN","large_airport","Brisbane International Airport",-27.384199,153.117004,13,"OC","AU","AU-QLD","Brisbane","yes","YBBN","BNE","YBBN",""') -join "`n")
    New-Item -ItemType Directory -Force (Join-Path $sc ".hangar_new_x") | Out-Null
    $target = Join-Path $T "ExternalScenery"; New-Item -ItemType Directory -Force $target | Out-Null
    Utf8NoBom (Join-Path $target "manifest.json") '{ "content_type": "SCENERY", "title": "Linked Scenery" }'
    cmd /c mklink /J (Join-Path $sc "linked-scenery") $target | Out-Null
    $ss = $baseSettings.Clone(); $ss.communityOverride = $sc; $ss.autoUpdate = $false; $ss.selfUpdate = $false; $ss.airportsUrl = "http://localhost:8766/airports.csv"
    Remove-Item (Join-Path $data "airports.csv") -ErrorAction SilentlyContinue
    $p11 = StartInstance $exe3 $ss
    $scan = (Call GET "/api/community?refresh=1").json
    $byFolder = @{}; $scan.packages | % { $byFolder[$_.folder] = $_ }
    Check ($scan.packages.Count -eq 7) "seven packages, our temporary folder skipped ($($scan.packages.Count))"
    Check ($scan.counts.AIRPORT -eq 2 -and $scan.counts.SCENERY -eq 2 -and $scan.counts.NAVDATA -eq 1 -and $scan.counts.AIRCRAFT -eq 1 -and $scan.counts.UNKNOWN -eq 1) "counted by kind: airports, other scenery, nav data"
    $nv = $byFolder["navigraph-nav-base"]
    Check ($nv.type -eq "NAVDATA" -and $nv.contentType -eq "SCENERY" -and @($nv.airports).Count -eq 0) "Navigraph nav data is not shown as airport scenery"
    Check ($byFolder["fsdreamteam-gsx-pro"].type -eq "SCENERY") "scenery without airports stays 'other scenery'"
    $ap = $null; $ready = WaitUntil { $script:ap = (Call GET "/api/airports?icao=EHAM,ybbn,ZZZZ").json; $ap.status -eq "ready" } 15
    Check $ready "airport list downloaded and loaded in the background ($($ap.status))"
    Check ($ap.airports.EHAM.lat -eq 52.3086 -and $ap.airports.EHAM.lon -eq 4.7639 -and $ap.airports.EHAM.name -eq "Amsterdam Airport Schiphol") "EHAM position and name"
    Check ($ap.airports.YBBN.name -eq "Brisbane International Airport") "open airport wins over a closed one with the same code"
    Check (-not $ap.airports.ZZZZ) "unknown code has no position"
    Check (Test-Path (Join-Path $data "airports.csv")) "airport list kept in the data folder"
    Check ((Call GET "/api/airports?icao=EHAM" $null $null "https://evil.example").status -eq 403) "a web page cannot query the hangar"
    $e = $byFolder["flytampa-eham-amsterdam"]
    Check ((($e.airports) -join ",") -eq "EHAM,EHLE" -and $e.airportsGuessed -eq $false) "airports from ContentHistory.json (EHAM, EHLE; other items ignored)"
    Check ($e.creator -eq "Test Studio" -and $e.version -eq "1.2.3" -and $e.sizeMB -eq 100) "creator, version and size from the manifest"
    $y = $byFolder["orbx-ybbn-brisbane"]; Check ((($y.airports) -join ",") -eq "YBBN" -and $y.airportsGuessed -eq $true) "ICAO guessed from the folder name and marked as a guess"
    Check ($byFolder["broken-folder"].problem -eq "no manifest.json") "folder without a manifest flagged"
    Check ($byFolder["linked-scenery"].linked -eq $true -and $byFolder["linked-scenery"].title -eq "Linked Scenery") "linked folder followed and flagged"
    Check ((Call POST "/api/open-package" '{"folder":"..\\..\\Windows"}').status -eq 400) "open-package refuses paths outside the Community folder"
    Check ((Call POST "/api/open-package" '{"folder":"orbx-ybbn-brisbane"}' $null "https://evil.example").status -eq 403) "a web page cannot open folders"
    StopAll

    # ================= "Check for updates" includes the hangar =================
    Section "Check for updates: the hangar itself first"
    $runDir4 = Join-Path $T "run4"; New-Item -ItemType Directory -Force $runDir4 | Out-Null; Copy-Item $exe (Join-Path $runDir4 "JetstreamHangar.exe")
    $sh = $baseSettings.Clone(); $sh.autoUpdate = $false; $sh.selfUpdate = $false; $sh.hangarRepo = "test/hangar"; $sh.startDelayMs = 600000
    $p12 = StartInstance (Join-Path $runDir4 "JetstreamHangar.exe") $sh
    $st0 = (Call GET "/api/status").json.selfUpdate
    Check ($st0.current -eq $curVer) "status shows the running version ($($st0.current))"
    Check ((Call POST "/api/check-updates" "" $null $page).status -eq 202) "check for updates accepted"
    $av = WaitUntil { (Call GET "/api/status").json.selfUpdate.state -eq "available" } 15
    $st1 = (Call GET "/api/status").json.selfUpdate
    Check ($av -and $st1.latest -eq "9.9.9") "self-update off: the newer hangar is reported, not installed ($($st1.message))"
    Check ((Call GET "/api/ping").json.version -ne "9.9.9") "still the old version until asked"
    Call POST "/api/self-update" "" $null $page | Out-Null
    Check (WaitUntil { (Call GET "/api/ping").json.version -eq "9.9.9" } 25) "update hangar button installs 9.9.9 and restarts"
    StopAll}
finally {
    try { Stop-Process -Id $proc.Id -Force } catch { }
    Get-Process JetstreamHangar -ErrorAction SilentlyContinue | ? { $_.Path -like "$T*" } | Stop-Process -Force -ErrorAction SilentlyContinue
    Get-Process FlightSimulator2024 -ErrorAction SilentlyContinue | ? { $_.Path -like "$T*" } | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 500
    try { Stop-Process -Id $mockProc.Id -Force } catch { }
    Start-Sleep -Milliseconds 300
    # never leave test entries in the user's registry
    if ($regName) { Remove-Item "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\$regName" -Recurse -ErrorAction SilentlyContinue; Remove-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" -Name $regName -ErrorAction SilentlyContinue }
    Remove-Item $T -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item $mock -Recurse -Force -ErrorAction SilentlyContinue
}
$head = "Jetstream Hangar end-to-end tests - $(Get-Date -Format s)", "$($results.Count) lines, $fails failed", ""
$out = ($head + $results) -join "`r`n"
[IO.File]::WriteAllText((Join-Path $PSScriptRoot "results.txt"), $out)
$out
