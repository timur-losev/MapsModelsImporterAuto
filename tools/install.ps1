<#
.SYNOPSIS
Copy this working copy's add-on source over an installed MapsModelsImporter.

.DESCRIPTION
For iterating on Windows: edit here, run this, restart Blender. Only the
.py/.toml/.md/.txt files are copied, so the bin/ directory already in the
add-on folder — RenderDoc's python module and its DLLs — is left alone.

Blender caches google_maps.py at startup, so a restart is needed for changes
to it. The extraction half (google_maps_rd.py, rdcompat.py, rdutils.py,
meshdata.py) runs in a subprocess and is re-read on every import.

On Linux use tools/mmi instead, which mounts the add-on in place.

.EXAMPLE
tools\install.ps1
tools\install.ps1 -BlenderVersion 4.4
tools\install.ps1 -Target 'D:\path\to\MapsModelsImporter'
#>
param(
    [string]$BlenderVersion = "4.5",
    [string]$Target
)

$ErrorActionPreference = "Stop"
$source = Join-Path (Split-Path $PSScriptRoot -Parent) "blender\MapsModelsImporter"

if (-not (Test-Path $source)) {
    throw "No add-on source at '$source'. Run this from a checkout of the repository."
}

if (-not $Target) {
    $Target = Join-Path $env:APPDATA "Blender Foundation\Blender\$BlenderVersion\scripts\addons\MapsModelsImporter"
}

if (-not (Test-Path $Target)) {
    throw "Nothing installed at '$Target'. Install the add-on once the normal way, so that its bin/ directory with renderdoc.pyd is in place, then run this again."
}
if (-not (Test-Path (Join-Path $Target "bin"))) {
    Write-Warning "'$Target' has no bin/ directory. RenderDoc's python module must be reachable some other way - see the add-on preferences."
}

$copied = 0
Get-ChildItem $source -File |
    Where-Object { $_.Extension -in ".py", ".toml", ".md", ".txt" } |
    ForEach-Object {
        Copy-Item $_.FullName -Destination $Target -Force
        $copied++
    }

Get-ChildItem $Target -Directory -Filter "__pycache__" -Recurse -ErrorAction SilentlyContinue |
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

Write-Host "Copied $copied files to $Target"
Write-Host "Restart Blender to pick up google_maps.py."
