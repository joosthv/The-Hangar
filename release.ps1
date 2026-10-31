# Release Jetstream Hangar: build with the version, write JetstreamHangar.exe + .sha256 to dist\release, and with the
# environment variable GITHUB_TOKEN publish them as release "hangar-v<version>" on github.com/<Repo>.
# Running hangars find it on their next check and update themselves.
#   powershell -File release.ps1 -Version 1.0.1 [-Notes "text"] [-Repo joosthv/The-Hangar]
param([Parameter(Mandatory = $true)][string]$Version, [string]$Notes = "", [string]$Repo = "joosthv/The-Hangar")
$ErrorActionPreference = "Stop"
if ($Version -notmatch '^\d+\.\d+\.\d+$') { throw "Version must look like 1.2.3" }
$here = $PSScriptRoot; $out = Join-Path $here "dist\release"
Set-Content (Join-Path $here "VERSION") -Value $Version -Encoding ASCII
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $here "build.ps1") -Version $Version -OutDir $out
$exe = Join-Path $out "JetstreamHangar.exe"
$sha = (Get-FileHash $exe -Algorithm SHA256).Hash.ToLowerInvariant()
[IO.File]::WriteAllText("$exe.sha256", "$sha  JetstreamHangar.exe`n")
"exe: $exe  sha256 $sha"
if ($env:GITHUB_TOKEN) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $h = @{ Authorization = "Bearer $env:GITHUB_TOKEN"; Accept = "application/vnd.github+json"; "User-Agent" = "hangar-release" }
    $body = @{ tag_name = "hangar-v$Version"; name = "Jetstream Hangar $Version"; body = $(if ($Notes) { $Notes } else { "Jetstream Hangar $Version" }) } | ConvertTo-Json
    $rel = Invoke-RestMethod -Method POST -Uri "https://api.github.com/repos/$Repo/releases" -Headers $h -Body $body -ContentType "application/json"
    $up = $rel.upload_url -replace '\{.*\}$', ''
    foreach ($f in @($exe, "$exe.sha256")) { Invoke-RestMethod -Method POST -Uri "$($up)?name=$([Uri]::EscapeDataString((Split-Path $f -Leaf)))" -Headers $h -InFile $f -ContentType "application/octet-stream" | Out-Null; "uploaded $(Split-Path $f -Leaf)" }
    "release: $($rel.html_url)"
} else { "Not published (no GITHUB_TOKEN): create release hangar-v$Version on github.com/$Repo and attach both files." }
