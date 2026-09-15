<#
.SYNOPSIS
    Regenerate assets/favicon.ico from assets/icon-256.png.

.DESCRIPTION
    assets/icon-256.png is the single source of truth for the DeepSeek Harness
    icon. This script wraps it in a Vista+ ICO container (one PNG entry) so the
    desktop shortcut and the WebView2 executable share one icon.

    Requires no image library: the ICO container is 22 bytes of header followed
    by the PNG payload verbatim.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\build-desktop-icon.ps1
#>

[CmdletBinding()]
param(
  [switch]$Force
)

$ErrorActionPreference = 'Stop'

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$pngPath = Join-Path $repoRoot 'assets\icon-256.png'
$icoPath = Join-Path $repoRoot 'assets\favicon.ico'

# ICO with one PNG entry (Vista+): ICONDIR (6 bytes) + ICONDIRENTRY (16 bytes)
# + the PNG payload. width=0/height=0 mean 256px; imageOffset is 22.
function New-IcoFromPng {
  param(
    [byte[]]$Png,
    [string]$OutPath
  )
  $ico = [byte[]]::new(22 + $Png.Length)
  # ICONDIR: reserved(0) type=1 count=1
  $ico[2] = 1
  $ico[4] = 1
  # ICONDIRENTRY: width=0 height=0 colorCount=0 reserved=0
  # planes=1 (bytes 10-11), bitCount=32 (bytes 12-13)
  $ico[10] = 1
  $ico[12] = 32
  # bytesInRes (bytes 14-17), little-endian
  [Array]::Copy([BitConverter]::GetBytes([int]$Png.Length), 0, $ico, 14, 4)
  # imageOffset (bytes 18-21), little-endian
  [Array]::Copy([BitConverter]::GetBytes([int]22), 0, $ico, 18, 4)
  # PNG payload
  [Array]::Copy($Png, 0, $ico, 22, $Png.Length)
  [System.IO.File]::WriteAllBytes($OutPath, $ico)
}

if (-not (Test-Path -LiteralPath $pngPath)) {
  Write-Error "icon source not found at $pngPath"
  exit 1
}

if ((Test-Path -LiteralPath $icoPath) -and -not $Force) {
  Write-Host "build-desktop-icon: $icoPath already exists; keep (use -Force to regenerate)"
  exit 0
}

$png = [System.IO.File]::ReadAllBytes($pngPath)
$magic = [BitConverter]::ToString($png, 0, 4)
if ($magic -ne '89-50-4E-47') {
  Write-Error "$pngPath is not a PNG file (magic $magic)"
  exit 1
}

New-IcoFromPng -Png $png -OutPath $icoPath
Write-Host "build-desktop-icon: wrote $icoPath"
