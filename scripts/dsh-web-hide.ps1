<#
.SYNOPSIS
    Hidden lifecycle manager for the DeepSeek Harness desktop shortcut.

    .DESCRIPTION
    Launched without a visible window by dsh-web.vbs. Starts the dsh web server
    hidden (--no-open), waits for http://127.0.0.1:3080 to accept, installs and
    opens the URL as an Edge Web App, waits for that window to close, then stops
    the server. Closing the Edge window therefore stops dsh.

    If port 3080 is already serving (a previous dsh is running), no second
    server is started: the script just opens the window, and when the window
    closes it stops only the server this launch spawned — a pre-existing dsh
    on port 3080 keeps running. That is the same ServerLease ownership the
    WebView2 shell uses. Progress and errors append to the log at
    $env:TEMP\dsh-web.log so a silent double-click failure can be diagnosed.
#>

$ErrorActionPreference = 'Stop'

$scriptDir = $PSScriptRoot
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $scriptDir '..\..'))
$binJs = Join-Path $repoRoot 'apps\cli\lib\bin.js'
$webViewShell = Join-Path $repoRoot 'native\webview2-shell\bin\Release\net8.0-windows\win-x64\publish\DeepSeek Harness.exe'
$url = 'http://127.0.0.1:3080'
$logPath = Join-Path $env:TEMP 'dsh-web.log'
$edgeProfile = Join-Path $env:TEMP ('dsh-edge-' + [guid]::NewGuid().ToString('N'))
$edgeShortcut = Join-Path $edgeProfile 'DeepSeek Harness.lnk'
# Taskbar application identity: the Edge app window presents as its own
# taskbar app (black-whale icon, pinnable) instead of an Edge window.
$aumid = 'DeepSeekAI.DeepSeekHarness'
$icoPath = Join-Path $scriptDir 'dsh-favicon.ico'

function Write-Log {
  param([string]$Message)
  $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
  Add-Content -LiteralPath $logPath -Value $line -Encoding UTF8
}

function Find-EdgeExecutable {
  $roots = @(${env:ProgramFiles(x86)}, $env:ProgramFiles, $env:LOCALAPPDATA)
  foreach ($root in $roots) {
    if ([string]::IsNullOrWhiteSpace($root)) { continue }
    $candidate = Join-Path $root 'Microsoft\Edge\Application\msedge.exe'
    if (Test-Path -LiteralPath $candidate) { return $candidate }
  }
  return $null
}

function Get-PortOwnerPid {
  param([int]$Port)
  $connection = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($null -eq $connection) { return $null }
  return $connection.OwningProcess
}

function Test-UrlReady {
  try {
    $response = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 2
    return ($response.StatusCode -eq 200)
  }
  catch {
    return $false
  }
}

# Register the AUMID under HKCU so the Edge app window gets its own taskbar
# identity: the black-whale icon and display name. Idempotent; a registration
# failure (policy, permissions) only logs and never blocks the window.
function Register-TaskbarIdentity {
  try {
    $regPath = "HKCU:\Software\Classes\AppUserModelId\$aumid"
    New-Item -Path $regPath -Force | Out-Null
    Set-ItemProperty -Path $regPath -Name '(Default)' -Value 'DeepSeek Harness'
    # AppUserModelId registrations use DisplayName/IconUri. Keep DefaultIcon
    # as well for older shell versions that resolve the Win32 association.
    Set-ItemProperty -Path $regPath -Name 'DisplayName' -Value 'DeepSeek Harness'
    Set-ItemProperty -Path $regPath -Name 'IconUri' -Value ([uri]$icoPath).AbsoluteUri
    Set-ItemProperty -Path $regPath -Name 'DefaultIcon' -Value $icoPath
    Write-Log "taskbar identity registered: $aumid"
  }
  catch {
    Write-Log "WARNING: taskbar identity registration failed: $($_.Exception.Message)"
  }
}

function New-EdgeAppShortcut {
  param([string]$Path)
  $shell = New-Object -ComObject WScript.Shell
  $shortcut = $shell.CreateShortcut($Path)
  $shortcut.TargetPath = $edge
  # --app keeps the launch in an independent app-mode window. The install-app
  # switch opens a normal browser window on Edge versions that do not support
  # silent installation for a local URL.
  $shortcut.Arguments = "--app=$url --user-data-dir=`"$edgeProfile`" --app-user-model-id=$aumid --no-first-run --no-default-browser-check --disable-extensions"
  $shortcut.WorkingDirectory = Split-Path -Parent $edge
  $shortcut.IconLocation = "$icoPath,0"
  $shortcut.Description = 'DeepSeek Harness Web GUI'
  $shortcut.Save()
}

function Set-EdgeWindowIcon {
  param([int]$ProcessId, [string]$IconPath)
  if (-not (Test-Path -LiteralPath $IconPath)) { return }
  if (-not ('TaskbarIcon' -as [type])) {
    Add-Type @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class TaskbarIcon {
  private const int WM_SETICON = 0x0080;
  private const int ICON_SMALL = 0;
  private const int ICON_BIG = 1;
  private const uint IMAGE_ICON = 1;
  private const uint LR_LOADFROMFILE = 0x00000010;
  private const uint LR_DEFAULTSIZE = 0x00000040;
  private delegate bool EnumWindowsProc(IntPtr hwnd, IntPtr lParam);
  [DllImport("user32.dll")] private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr lParam);
  [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr hwnd);
  [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint processId);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern IntPtr LoadImage(IntPtr instance, string name, uint type, int cx, int cy, uint flags);
  [DllImport("user32.dll")] private static extern IntPtr SendMessage(IntPtr hwnd, int message, IntPtr wParam, IntPtr lParam);
  private static readonly List<IntPtr> handles = new List<IntPtr>();
  public static int SetForProcess(int pid, string path) {
    IntPtr icon = LoadImage(IntPtr.Zero, path, IMAGE_ICON, 0, 0, LR_LOADFROMFILE | LR_DEFAULTSIZE);
    if (icon == IntPtr.Zero) return 0;
    handles.Add(icon);
    int count = 0;
    EnumWindows((hwnd, _) => {
      uint owner;
      GetWindowThreadProcessId(hwnd, out owner);
      if (owner == (uint)pid && IsWindowVisible(hwnd)) {
        SendMessage(hwnd, WM_SETICON, (IntPtr)ICON_BIG, icon);
        SendMessage(hwnd, WM_SETICON, (IntPtr)ICON_SMALL, icon);
        count++;
      }
      return true;
    }, IntPtr.Zero);
    return count;
  }
}
'@
  }
  for ($attempt = 0; $attempt -lt 20; $attempt++) {
    if ([TaskbarIcon]::SetForProcess($ProcessId, $IconPath) -gt 0) { return }
    Start-Sleep -Milliseconds 250
  }
}

Write-Log "start: repo=$repoRoot"

# Prefer the native host once it has been published. It owns server startup,
# the WebView2 window, and shutdown; the Edge path below remains a fallback
# while the native host is not built on this checkout.
if (Test-Path -LiteralPath $webViewShell) {
  Write-Log "starting WebView2 shell: $webViewShell"
  $shellProcess = Start-Process -FilePath $webViewShell -ArgumentList $url -PassThru -Wait
  Write-Log "WebView2 shell exited with code $($shellProcess.ExitCode)"
  exit $shellProcess.ExitCode
}

$edge = Find-EdgeExecutable
if ($null -eq $edge) {
  Write-Log 'ERROR: Microsoft Edge not found; cannot open the app window.'
  exit 1
}

# --- Server lifecycle (ServerLease semantics) ------------------------------
# Prefer the existing server on 3080 (a previous dsh is running). Otherwise
# start a fresh hidden node server and wait for it to accept. Only a server
# this launch spawned is stopped when the window closes; a pre-existing dsh
# on 3080 keeps running, matching the WebView2 shell's ServerLease.
$existingPid = Get-PortOwnerPid -Port 3080
$ownedPid = $null
if ($null -ne $existingPid) {
  Write-Log "port 3080 already served by PID $existingPid; reusing existing dsh"
}
else {
  Write-Log 'starting hidden node server'
  $ownedProcess = Start-Process -FilePath 'node' `
    -ArgumentList @("$binJs", 'web', '--no-open') `
    -WindowStyle Hidden -PassThru
  $ownedPid = $ownedProcess.Id
  Write-Log "node started PID=$ownedPid"

  $deadline = (Get-Date).AddSeconds(30)
  while (-not (Test-UrlReady)) {
    if ((Get-Date) -gt $deadline) {
      Write-Log 'ERROR: server did not become ready within 30s'
      if ($null -ne $ownedPid) { Stop-Process -Id $ownedPid -Force -ErrorAction SilentlyContinue }
      exit 1
    }
    Start-Sleep -Milliseconds 500
  }
  Write-Log 'server ready'
}

# After readiness the port owner must exist. When we spawned it, $ownedPid
# matches; a pre-existing server leaves $ownedPid null (never stop it).
$targetPid = Get-PortOwnerPid -Port 3080
if ($null -eq $targetPid) {
  Write-Log 'ERROR: no process owns port 3080 after readiness; aborting'
  if ($null -ne $ownedPid) { Stop-Process -Id $ownedPid -Force -ErrorAction SilentlyContinue }
  exit 1
}
Write-Log "server owner PID=$targetPid; opening Edge app window"
Register-TaskbarIdentity

try {
  # Independent msedge process with its own profile so WaitForExit observes the
  # real window close instead of the request being handed to a running browser.
  # --app-user-model-id presents the window as the DeepSeek Harness taskbar app.
  # Launch through a shortcut carrying the custom icon. Starting msedge.exe
  # directly makes the shell use Edge's executable icon for the taskbar button,
  # even when the app window has a custom AUMID.
  New-Item -ItemType Directory -Path $edgeProfile -Force | Out-Null
  New-EdgeAppShortcut -Path $edgeShortcut
  $edgeProc = Start-Process -FilePath $edgeShortcut -PassThru
  Set-EdgeWindowIcon -ProcessId $edgeProc.Id -IconPath $icoPath
  Write-Log "edge window PID=$($edgeProc.Id); waiting for it to close"
  $edgeProc.WaitForExit()
  if ($null -ne $ownedPid) {
    Write-Log "edge window closed; stopping spawned dsh server PID=$ownedPid"
  }
  else {
    Write-Log 'edge window closed; pre-existing dsh server on port 3080 keeps running'
  }
}
finally {
  # Stop only what this launch spawned; never kill a pre-existing dsh.
  if ($null -ne $ownedPid) {
    Stop-Process -Id $ownedPid -Force -ErrorAction SilentlyContinue
  }
  Remove-Item -LiteralPath $edgeProfile -Recurse -Force -ErrorAction SilentlyContinue
  Write-Log 'done'
}
