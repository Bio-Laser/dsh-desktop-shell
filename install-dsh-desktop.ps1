<#
.SYNOPSIS
    Install a "DeepSeek Harness" desktop shortcut that launches dsh web in an
    Edge app-mode window, with the official black-whale icon.

.DESCRIPTION
    Runs only on Windows. Resolves msedge.exe from the standard install roots,
    renders apps/web/public/favicon.svg into scripts/desktop/dsh-favicon.ico
    via an Edge headless screenshot (no npm image dependency), and creates a
    "DeepSeek Harness.lnk" on the user's desktop. The shortcut runs
    scripts/desktop/dsh-web.vbs through wscript.exe, which launches the hidden
    lifecycle script scripts/desktop/dsh-web-hide.ps1: it starts dsh web with
    no console window, opens an independent Edge app-mode window, and stops the
    server when that window closes.

    Everything is idempotent: existing .ico/.lnk files are kept unless -Force is
    given. Rerun safely after pulling updates.

.PARAMETER Force
    Overwrite existing scripts/desktop/dsh-favicon.ico and the desktop shortcut
    even when they already exist.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts/install-dsh-desktop.ps1

    # Regenerate every artifact:
    powershell -ExecutionPolicy Bypass -File scripts/install-dsh-desktop.ps1 -Force
#>

[CmdletBinding()]
param(
  [switch]$Force
)

$ErrorActionPreference = 'Stop'

# --- Platform guard ------------------------------------------------------
if ($env:OS -ne 'Windows_NT') {
  Write-Error 'install-dsh-desktop.ps1 requires Windows: the desktop shortcut and Edge app-mode launch are Windows-only.'
  exit 1
}

# --- Repository layout ----------------------------------------------------
# $PSScriptRoot is scripts/; the repo root is one level up, and the artifact
# directory is scripts/desktop/.
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$desktopDir = Join-Path $repoRoot 'scripts\desktop'
$svgPath = Join-Path $repoRoot 'apps\web\public\favicon.svg'
$vbsPath = Join-Path $desktopDir 'dsh-web.vbs'
$hideScriptPath = Join-Path $desktopDir 'dsh-web-hide.ps1'
$icoPath = Join-Path $desktopDir 'dsh-favicon.ico'
$desktopFolder = [Environment]::GetFolderPath('Desktop')
$lnkPath = Join-Path $desktopFolder 'DeepSeek Harness.lnk'
$wscriptPath = Join-Path $env:WINDIR 'System32\wscript.exe'

function Write-Step {
  param([string]$Message)
  Write-Host "install-dsh-desktop: $Message"
}

# --- Edge probe ----------------------------------------------------------
function Find-EdgeExecutable {
  $roots = @(${env:ProgramFiles(x86)}, $env:ProgramFiles, $env:LOCALAPPDATA)
  foreach ($root in $roots) {
    if ([string]::IsNullOrWhiteSpace($root)) { continue }
    $candidate = Join-Path $root 'Microsoft\Edge\Application\msedge.exe'
    if (Test-Path -LiteralPath $candidate) { return $candidate }
  }
  return $null
}

# --- ICO wrap ------------------------------------------------------------
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
  $sizeBytes = [BitConverter]::GetBytes([int]$Png.Length)
  [Array]::Copy($sizeBytes, 0, $ico, 14, 4)
  # imageOffset (bytes 18-21), little-endian
  $offsetBytes = [BitConverter]::GetBytes([int]22)
  [Array]::Copy($offsetBytes, 0, $ico, 18, 4)
  # PNG payload
  [Array]::Copy($Png, 0, $ico, 22, $Png.Length)
  [System.IO.File]::WriteAllBytes($OutPath, $ico)
}

# --- Icon render ---------------------------------------------------------
# Renders the 50x50 favicon.svg at 256px through Edge headless, then wraps
# the PNG in an ICO. A temp HTML page forces the image box to 256x256 so the
# viewBox does not paint at its intrinsic 50px.
function ConvertTo-DesktopIcon {
  param(
    [string]$SvgPath,
    [string]$EdgePath,
    [string]$OutPath
  )
  $tmpRoot = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), 'dsh-desktop-' + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $tmpRoot | Out-Null
  try {
    $svgUri = [uri]$SvgPath
    $html = @(
      '<!doctype html><html><head>',
      '<meta charset="utf-8">',
      '<style>html,body{margin:0;padding:0;overflow:hidden;background:transparent}</style>',
      '</head><body>',
      "<img src=`"$($svgUri.AbsoluteUri)`" width=`"256`" height=`"256`">",
      '</body></html>'
    ) -join ''
    $htmlPath = Join-Path $tmpRoot 'icon.html'
    $pngPath = Join-Path $tmpRoot 'icon.png'
    $profileDir = Join-Path $tmpRoot 'profile'
    [System.IO.File]::WriteAllText($htmlPath, $html, [System.Text.Encoding]::UTF8)

    $htmlUri = [uri]$htmlPath
    # msedge.exe is a GUI-subsystem process: & does not wait for it in
    # Windows PowerShell 5.1, so Start-Process -Wait is required to make the
    # screenshot complete before the PNG is read. Each argument that may
    # contain spaces is quoted explicitly.
    # Start-Process -ArgumentList as a single string splits on spaces, so any
    # value that may contain spaces must be quoted inside the string.
    $quotedProfile = '"' + $profileDir + '"'
    $quotedScreenshot = '"' + $pngPath + '"'
    $edgeArgs = @(
      '--headless=new',
      '--disable-gpu',
      '--no-first-run',
      '--no-default-browser-check',
      '--hide-scrollbars',
      "--user-data-dir=$quotedProfile",
      '--window-size=256,256',
      '--default-background-color=00000000',
      "--screenshot=$quotedScreenshot",
      $htmlUri.AbsoluteUri
    ) -join ' '
    $edgeProcess = Start-Process -FilePath $EdgePath -ArgumentList $edgeArgs -Wait -PassThru -WindowStyle Hidden
    if ($edgeProcess.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $pngPath)) {
      throw "Edge headless screenshot failed (exit $($edgeProcess.ExitCode)) to produce icon.png"
    }

    $png = [System.IO.File]::ReadAllBytes($pngPath)
    $pngMagic = [BitConverter]::ToString($png, 0, 4)
    if ($pngMagic -ne '89-50-4E-47') {
      throw "Edge headless produced a non-PNG file (magic $pngMagic); icon generation aborted"
    }
    New-IcoFromPng -Png $png -OutPath $OutPath
    Write-Step "rendered $OutPath"
  }
  finally {
    Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
  }
}

# --- Hidden launcher .vbs -------------------------------------------------
# The .vbs is committed beside this script; this function (re)writes it so a
# -Force run repairs a missing or corrupted copy. It uses its own directory to
# locate dsh-web-hide.ps1, so the checkout can live anywhere.
function Write-LauncherVbs {
  param([string]$OutPath)
  $lines = @(
    "' Hidden launcher for the DeepSeek Harness desktop shortcut.",
    "' WScript.Shell.Run with window style 0 starts the PowerShell lifecycle",
    "' script with no visible console window.",
    'Option Explicit',
    '',
    'Dim fso, scriptDir, ps1Path, shell',
    'Set fso = CreateObject("Scripting.FileSystemObject")',
    'scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)',
    'ps1Path = fso.BuildPath(scriptDir, "dsh-web-hide.ps1")',
    'If Not fso.FileExists(ps1Path) Then',
    '  WScript.Echo "dsh-web-hide.ps1 not found beside " & WScript.ScriptFullName',
    '  WScript.Quit 1',
    'End If',
    '',
    'Set shell = CreateObject("WScript.Shell")',
    'shell.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & ps1Path & """", 0, False'
  )
  $content = ($lines -join "`n") + "`n"
  # LF matches the committed dsh-web.vbs and the .gitattributes default.
  [System.IO.File]::WriteAllText($OutPath, $content, [System.Text.Encoding]::ASCII)
  Write-Step "wrote $OutPath"
}

# --- Desktop shortcut -----------------------------------------------------
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
  $shortcut.Description = 'Launch the dsh Web GUI in a hidden Edge app-mode window'
  $shortcut.Save()
  Write-Step "created $ShortcutPath"
}

# --- Main ----------------------------------------------------------------
if (-not (Test-Path -LiteralPath $svgPath)) {
  Write-Error "favicon not found at $svgPath; run from a repository checkout."
  exit 1
}

New-Item -ItemType Directory -Path $desktopDir -Force | Out-Null

$edge = Find-EdgeExecutable
if ($null -eq $edge) {
  Write-Error 'Microsoft Edge was not found. edge-app mode requires Edge installed under Program Files or LOCALAPPDATA.'
  exit 1
}

if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
  Write-Warning 'node is not on PATH; the launcher will fail until Node.js is available.'
}

if ((Test-Path -LiteralPath $icoPath) -and -not $Force) {
  Write-Step "dsh-favicon.ico already exists; keep (use -Force to regenerate)"
}
else {
  ConvertTo-DesktopIcon -SvgPath $svgPath -EdgePath $edge -OutPath $icoPath
}

if ((Test-Path -LiteralPath $vbsPath) -and -not $Force) {
  Write-Step "dsh-web.vbs already exists; keep (use -Force to rewrite)"
}
else {
  Write-LauncherVbs -OutPath $vbsPath
}

if (-not (Test-Path -LiteralPath $hideScriptPath)) {
  Write-Error "lifecycle script not found at $hideScriptPath; run from a repository checkout."
  exit 1
}

if ((Test-Path -LiteralPath $lnkPath) -and -not $Force) {
  Write-Step "desktop shortcut already exists; keep (use -Force to recreate)"
}
else {
  # The shortcut targets wscript.exe with the hidden .vbs as its argument; the
  # .vbs resolves the lifecycle script relative to its own directory.
  New-DesktopShortcut -TargetPath $wscriptPath -Arguments """$vbsPath""" `
    -WorkingDirectory $desktopDir -IconPath $icoPath -ShortcutPath $lnkPath
}

Write-Step 'done. Double-click "DeepSeek Harness" on your desktop to launch.'
