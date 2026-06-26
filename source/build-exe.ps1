# build-exe.ps1 — compiles the tray app into MOBSW.exe using ps2exe.
# This script lives in source\. Run it on Windows:
#     powershell -ExecutionPolicy Bypass -File source\build-exe.ps1
#
# It reads source\widget-tray.ps1 and writes MOBSW.exe to the PROJECT ROOT
# (one level up), next to server.js / themes / assets. The exe loads everything
# relative to its own folder, so it must sit in the root to find them.

$ErrorActionPreference = "Stop"
$srcDir  = Split-Path -Parent $MyInvocation.MyCommand.Path   # ...\source
$root    = Split-Path -Parent $srcDir                        # project root

# Install ps2exe if it is not already available
if (-not (Get-Module -ListAvailable -Name ps2exe)) {
    Write-Host "Installing ps2exe module..."
    Install-Module ps2exe -Scope CurrentUser -Force
}
Import-Module ps2exe

$src  = Join-Path $srcDir "widget-tray.ps1"
$out  = Join-Path $root   "MOBSW.exe"
$icon = Join-Path $root   "assets\spotobs_on.ico"

Write-Host "Compiling $src -> $out"
Invoke-ps2exe `
    -inputFile   $src `
    -outputFile  $out `
    -iconFile    $icon `
    -noConsole `
    -title       "Music OBS Widget" `
    -description "Now-playing music overlays for OBS" `
    -version     "1.0.0"

Write-Host "Done. Built: $out"
