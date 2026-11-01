# Build the Jetstream Hangar toolbar panel (MSFS 2024 Community package jetstream-hangar-toolbar) with the SDK package
# tool, zip it for the GitHub release (dist\jetstream-hangar-toolbar-<version>.zip, installed by Jetstream Hangar via
# the catalogue entry with autoInstall) and, with -Install, put it in the Community folder for a test. MSFS must be closed.
#   powershell -ExecutionPolicy Bypass -File toolbar\build_toolbar.ps1 [-Install]
param([switch]$Install)
$ErrorActionPreference = "Stop"
$src = $PSScriptRoot
$repo = Split-Path $src -Parent
$name = "jetstream-hangar-toolbar"
$proj = Join-Path $env:USERPROFILE "Documents\JetstreamHangarToolbar"
$tool = "C:\MSFS 2024 SDK\Tools\bin\fspackagetool.exe"
$community = "C:\Users\joost\AppData\Roaming\Microsoft Flight Simulator 2024\Packages\Community\$name"
[xml]$def = Get-Content "$src\PackageDefinitions\$name.xml"
$version = $def.AssetPackage.Version

if (Get-Process FlightSimulator* -ErrorAction SilentlyContinue) { "MSFS is running - close it first"; exit 1 }
robocopy $src $proj /MIR /XD _PackageInt _PackageCache Packages PackagesMetadata tests /XF build_toolbar.ps1 /NFL /NDL /NJH /NJS /NP | Out-Null
Remove-Item "$proj\Packages\$name", "$proj\_PackageInt", "$proj\_PackageCache" -Recurse -Force -ErrorAction SilentlyContinue
$started = Get-Date
& $tool "$proj\JetstreamHangarToolbar.xml" -nopause | Out-Null
$err = "$proj\_PackageInt\_RPTErrors.xml"
if ((Test-Path $err) -and (Get-Item $err).Length -gt 20) {
    "BUILD ERRORS:"
    Select-String -Path $err -Pattern 'Message="([^"]+)"' -AllMatches | % { $_.Matches } | % { $_.Groups[1].Value } | Select -Unique -First 20
    exit 1
}
if ((Get-Item "$proj\_PackageInt\_RPTInputs.xml" -ErrorAction SilentlyContinue).LastWriteTime -lt $started) { "the package tool did not run"; exit 1 }
$built = "$proj\Packages\$name"
if (-not (Test-Path "$built\manifest.json")) { "no package was produced"; exit 1 }
if (-not (Test-Path "$built\InGamePanels\$name.spb")) { "the panel definition (.spb) is missing"; exit 1 }

# layout.json (the command-line tool does not write it), with fresh file times
function Write-Layout($dir) {
    $files = Get-ChildItem $dir -Recurse -File | ? { $_.Name -notin 'layout.json', 'manifest.json' } | Sort-Object FullName
    $now = Get-Date; $files | % { $_.LastWriteTime = $now }
    $items = $files | % { "    {`n      ""path"": ""$($_.FullName.Substring($dir.Length + 1).Replace('\', '/'))"",`n      ""size"": $($_.Length),`n      ""date"": $($_.LastWriteTimeUtc.ToFileTimeUtc())`n    }" }
    $utf8 = New-Object Text.UTF8Encoding $false
    [IO.File]::WriteAllText("$dir\layout.json", "{`n  ""content"": [`n" + ($items -join ",`n") + "`n  ]`n}", $utf8)
    $total = ($files | Measure-Object Length -Sum).Sum
    $m = [regex]::Replace((Get-Content "$dir\manifest.json" -Raw), '"total_package_size": "\d+"', '"total_package_size": "' + $total.ToString().PadLeft(20, '0') + '"')
    [IO.File]::WriteAllText("$dir\manifest.json", $m, $utf8)
    return $files.Count
}
$n = Write-Layout $built

# release zip: the package folder at the top level, as for the aircraft
$dist = Join-Path $repo "dist"; New-Item -ItemType Directory -Force $dist | Out-Null
$zip = Join-Path $dist "$name-$version.zip"
Remove-Item $zip -ErrorAction SilentlyContinue
Add-Type -AssemblyName System.IO.Compression.FileSystem
[IO.Compression.ZipFile]::CreateFromDirectory($built, $zip, [IO.Compression.CompressionLevel]::Optimal, $true)
"built $name ${version}: $n files, $zip"

if ($Install) {
    robocopy $built $community /MIR /IS /IT /NFL /NDL /NJH /NJS /NP | Out-Null
    $n = Write-Layout $community
    "installed: $community ($n files)"
}
