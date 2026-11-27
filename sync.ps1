# Copies the CURRENT versions of the extensions into this repo, from the .lua/package.json files installed in
# Aseprite (%APPDATA%\Aseprite\extensions\<name>). Then review `git diff` and commit. Add a new extension to the list.
$ErrorActionPreference = "Stop"
$here = $PSScriptRoot

$extensions = @("color-reducer", "live-outline")

$aseExt = Join-Path $env:APPDATA "Aseprite\extensions"
foreach ($e in $extensions) {
    $src = Join-Path $aseExt $e
    if (-not (Test-Path $src)) { Write-Warning "extension not installed: $src"; continue }
    $dst = Join-Path $here $e
    New-Item -ItemType Directory -Force $dst | Out-Null
    # only the extension's own files: README.md and pack.py live here, Aseprite's __pref/__info are runtime state
    Get-ChildItem $src -File | Where-Object { $_.Name -eq "package.json" -or $_.Extension -eq ".lua" } |
        Where-Object { $_.Name -ne "__pref.lua" } | Copy-Item -Destination $dst -Force
    Write-Host "extension $e"
}
Write-Host "`nDone. Review with: git -C `"$here`" status"
