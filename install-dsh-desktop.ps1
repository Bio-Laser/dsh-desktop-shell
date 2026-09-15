<#
.SYNOPSIS
    Install a "DeepSeek Harness" desktop shortcut that launches the desktop shell.

.DESCRIPTION
    Runs only on Windows. The shortcut targets wscript.exe with
    scripts/dsh-web.vbs as its argument; the .vbs hides the lifecycle script
    scripts/dsh-web-hide.ps1, which prefers the published WebView2 host and
    falls back to an Edge app-mode window.

    The icon comes from assets/favicon.ico, the single icon artifact shared
    with the WebView2 executable. Regenerate it from assets/icon-256.png with
    scripts/build-desktop-icon.ps1 -Force.

    Everything is idempotent: the shortcut is kept unless -Force is given.
    Rerun safely after pulling updates.

.PARAMETER Force
    Recreate the desktop shortcut even when it already exists.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File install-dsh-desktop.ps1

    # Recreate the shortcut:
    powershell -ExecutionPolicy Bypass -File install-dsh-desktop.ps1 -Force
#>

[CmdletBinding()]
param(
  [switch]$Force
)

$ErrorActionPreference = 'Stop'

# --- Platform guard ------------------------------------------------------
if ($env:OS -ne 'Windows_NT') {
  Write-Error 'install-dsh-desktop.ps1 requires Windows: the desktop shortcut and app-mode launch are Windows-only.'
  exit 1
}

# --- Repository layout ----------------------------------------------------
# This script lives at the repository root; scripts/ and assets/ sit beside it.
. (Join-Path $PSScriptRoot 'scripts\dsh-shell-common.ps1')

$shellRoot = Get-ShellRoot -FromDirectory $PSScriptRoot
$scriptDir = Join-Path $shellRoot 'scripts'
$icoPath = Join-Path $shellRoot 'assets\favicon.ico'
$vbsPath = Join-Path $scriptDir 'dsh-web.vbs'
$hideScriptPath = Join-Path $scriptDir 'dsh-web-hide.ps1'
$desktopFolder = [Environment]::GetFolderPath('Desktop')
$lnkPath = Join-Path $desktopFolder 'DeepSeek Harness.lnk'
$wscriptPath = Join-Path $env:WINDIR 'System32\wscript.exe'

function Write-Step {
  param([string]$Message)
  Write-Host "install-dsh-desktop: $Message"
}

function New-DesktopShortcut {
  param(
    [string]$TargetPath,
    [string]$Arguments,
    [string]$WorkingDirectory,
    [string]$IconPath,
    [string]$ShortcutPath
  )
  $shell = New-Object -ComObject WScript.Shell
  $shortcut = $shell.CreateShortcut($ShortcutPath)
  $shortcut.TargetPath = $TargetPath
  $shortcut.Arguments = $Arguments
  $shortcut.WorkingDirectory = $WorkingDirectory
  $shortcut.IconLocation = "$IconPath,0"
  $shortcut.Description = 'Launch the DeepSeek Harness desktop shell'
  $shortcut.Save()
  Write-Step "created $ShortcutPath"
}

# --- Main ----------------------------------------------------------------
Write-Step "shell root: $shellRoot"

foreach ($required in @($vbsPath, $hideScriptPath)) {
  if (-not (Test-Path -LiteralPath $required)) {
    Write-Error "required file not found: $required (run from a repository checkout)"
    exit 1
  }
}

if (-not (Test-Path -LiteralPath $icoPath)) {
  Write-Error "icon not found at $icoPath; run scripts\build-desktop-icon.ps1 to generate it."
  exit 1
}

if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
  Write-Warning 'node is not on PATH; the launcher will fail until Node.js is available.'
}

$dshRepoRoot = Resolve-DshRepoRoot -ShellRoot $shellRoot
if ($null -eq $dshRepoRoot) {
  Write-Warning 'Could not locate the dsh checkout. Set $env:DSH_REPO_ROOT or dshRepoRoot in dsh-shell.config.json before launching.'
}
else {
  Write-Step "dsh checkout: $dshRepoRoot"
}

$webViewShell = Get-WebView2ShellPath -ShellRoot $shellRoot
if (-not (Test-Path -LiteralPath $webViewShell)) {
  Write-Warning "WebView2 host not published yet ($webViewShell); the launcher will fall back to Edge app mode. Run: dotnet publish webview2-shell\WebView2Shell.csproj -c Release -r win-x64"
}

if ((Test-Path -LiteralPath $lnkPath) -and -not $Force) {
  Write-Step "desktop shortcut already exists; keep (use -Force to recreate)"
}
else {
  # The shortcut targets wscript.exe with the hidden .vbs as its argument; the
  # .vbs resolves the lifecycle script relative to its own directory.
  New-DesktopShortcut -TargetPath $wscriptPath -Arguments """$vbsPath""" `
    -WorkingDirectory $scriptDir -IconPath $icoPath -ShortcutPath $lnkPath
}

Write-Step 'done. Double-click "DeepSeek Harness" on your desktop to launch.'
