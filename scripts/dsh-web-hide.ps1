<#
.SYNOPSIS
    Hidden lifecycle manager for the DeepSeek Harness desktop shortcut.

.DESCRIPTION
    Launched without a visible window by dsh-web.vbs. Prefers the published
    WebView2 host; when that executable is missing it falls back to starting
    the dsh web server hidden (--no-open), waiting for http://127.0.0.1:3080
    to answer, and opening it as an Edge Web App. When that window closes the
    server this launch spawned is stopped, so closing the window stops dsh.

    If port 3080 already serves a previous dsh, no second server is started:
    the script only opens the window and stops nothing on exit — a pre-existing
    dsh on port 3080 keeps running. That is the same ServerLease ownership the
    WebView2 host uses.

    Paths are resolved by scripts/dsh-shell-common.ps1: the dsh checkout comes
    from $env:DSH_REPO_ROOT, then dsh-shell.config.json, then auto-detection of
    sibling directories. Progress and errors append to $env:TEMP\dsh-web.log.
#>

$ErrorActionPreference = 'Stop'

$scriptDir = $PSScriptRoot
. (Join-Path $scriptDir 'dsh-shell-common.ps1')

$shellRoot = Get-ShellRoot -FromDirectory $scriptDir
$url = 'http://127.0.0.1:3080'
$icoPath = Join-Path $shellRoot 'assets\favicon.ico'
$edgeProfile = Join-Path $env:TEMP ('dsh-edge-' + [guid]::NewGuid().ToString('N'))
$edgeShortcut = Join-Path $edgeProfile 'DeepSeek Harness.lnk'
# Taskbar application identity: the Edge app window presents as its own
# taskbar app (black-whale icon, pinnable) instead of an Edge window.
$aumid = 'DeepSeekAI.DeepSeekHarness'

Write-ShellLog "start: shell=$shellRoot"

$dshRepoRoot = Resolve-DshRepoRoot -ShellRoot $shellRoot
if ($null -eq $dshRepoRoot) {
  Write-ShellLog 'ERROR: could not locate the dsh checkout (apps/cli/lib/bin.js). Set $env:DSH_REPO_ROOT or dshRepoRoot in dsh-shell.config.json.'
  exit 1
}
$binJs = Join-Path $dshRepoRoot 'apps\cli\lib\bin.js'
Write-ShellLog "dsh checkout: $dshRepoRoot"

# Prefer the native host once it has been published. It owns server startup,
# the WebView2 window, and shutdown; the Edge path below remains a fallback
# while the native host is not built on this checkout.
$webViewShell = Get-WebView2ShellPath -ShellRoot $shellRoot
if (Test-Path -LiteralPath $webViewShell) {
  Write-ShellLog "starting WebView2 shell: $webViewShell"
  $shellProcess = Start-Process -FilePath $webViewShell -ArgumentList $url -PassThru -Wait
  Write-ShellLog "WebView2 shell exited with code $($shellProcess.ExitCode)"
  exit $shellProcess.ExitCode
}

Write-ShellLog "WebView2 shell not published at $webViewShell; falling back to Edge app mode"

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
    Write-ShellLog "taskbar identity registered: $aumid"
  }
  catch {
    Write-ShellLog "WARNING: taskbar identity registration failed: $($_.Exception.Message)"
  }
}

function New-EdgeAppShortcut {
  param([string]$Path)
  $shell = New-Object -ComObject WScript.Shell
  $shortcut = $shell.CreateShortcut($Path)
  $shortcut.TargetPath = $edge
  # --app keeps the launch in an independent app-mode window.
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

$edge = Find-EdgeExecutable
if ($null -eq $edge) {
  Write-ShellLog 'ERROR: Microsoft Edge not found; cannot open the app window.'
  exit 1
}

# --- Server lifecycle (ServerLease semantics) ------------------------------
# Prefer the existing server on 3080 (a previous dsh is running). Otherwise
# start a fresh hidden node server and wait for it to answer. Only a server
# this launch spawned is stopped when the window closes; a pre-existing dsh
# on 3080 keeps running, matching the WebView2 host's ServerLease.
$existingPid = Get-PortOwnerPid -Port 3080
$ownedPid = $null
if ($null -ne $existingPid) {
  Write-ShellLog "port 3080 already served by PID $existingPid; reusing existing dsh"
}
else {
  Write-ShellLog "starting hidden node server: $binJs"
  $ownedProcess = Start-Process -FilePath 'node' `
    -ArgumentList @("$binJs", 'web', '--no-open') `
    -WindowStyle Hidden -PassThru
  $ownedPid = $ownedProcess.Id
  Write-ShellLog "node started PID=$ownedPid"

  $deadline = (Get-Date).AddSeconds(30)
  while (-not (Test-WebUrlReady -Url $url)) {
    if ((Get-Date) -gt $deadline) {
      Write-ShellLog 'ERROR: server did not become ready within 30s'
      if ($null -ne $ownedPid) { Stop-Process -Id $ownedPid -Force -ErrorAction SilentlyContinue }
      exit 1
    }
    Start-Sleep -Milliseconds 500
  }
  Write-ShellLog 'server ready'
}

Register-TaskbarIdentity

try {
  # Launch through a shortcut carrying the custom icon. Starting msedge.exe
  # directly makes the shell use Edge's executable icon for the taskbar button,
  # even when the app window has a custom AUMID.
  New-Item -ItemType Directory -Path $edgeProfile -Force | Out-Null
  New-EdgeAppShortcut -Path $edgeShortcut
  $edgeProc = Start-Process -FilePath $edgeShortcut -PassThru
  Set-EdgeWindowIcon -ProcessId $edgeProc.Id -IconPath $icoPath
  Write-ShellLog "edge window PID=$($edgeProc.Id); waiting for it to close"
  $edgeProc.WaitForExit()
  if ($null -ne $ownedPid) {
    Write-ShellLog "edge window closed; stopping spawned dsh server PID=$ownedPid"
  }
  else {
    Write-ShellLog 'edge window closed; pre-existing dsh server on port 3080 keeps running'
  }
}
finally {
  # Stop only what this launch spawned; never kill a pre-existing dsh.
  if ($null -ne $ownedPid) {
    Stop-Process -Id $ownedPid -Force -ErrorAction SilentlyContinue
  }
  Remove-Item -LiteralPath $edgeProfile -Recurse -Force -ErrorAction SilentlyContinue
  Write-ShellLog 'done'
}
