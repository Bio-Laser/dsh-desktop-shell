<#
.SYNOPSIS
    Shared path resolution and logging helpers for the DeepSeek Harness desktop shell.

.DESCRIPTION
    The installer (install-dsh-desktop.ps1) and the hidden lifecycle script
    (dsh-web-hide.ps1) both need the same two locations:

      - the shell checkout root (this repository), and
      - the dsh checkout root that owns apps/cli/lib/bin.js.

    Resolution order for the dsh checkout:

      1. $env:DSH_REPO_ROOT
      2. dshRepoRoot in dsh-shell.config.json (machine-local, gitignored)
      3. auto-detection: sibling directories of this shell that contain
         apps/cli/lib/bin.js
      4. walking up from each candidate root

    Every helper is location-independent: nothing here hardcodes a drive,
    a username, or a checkout name.
#>

$script:ShellLogPath = Join-Path $env:TEMP 'dsh-web.log'

function Write-ShellLog {
  param([string]$Message)
  $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
  Add-Content -LiteralPath $script:ShellLogPath -Value $line -Encoding UTF8
}

<# Walks up from a directory to find this shell's checkout root. #>
function Get-ShellRoot {
  param([string]$FromDirectory)
  $directory = [System.IO.DirectoryInfo]$FromDirectory
  while ($null -ne $directory) {
    $hasGit = Test-Path -LiteralPath (Join-Path $directory.FullName '.git')
    $hasConfig = Test-Path -LiteralPath (Join-Path $directory.FullName 'dsh-shell.config.json')
    if ($hasGit -or $hasConfig) { return $directory.FullName }
    $directory = $directory.Parent
  }
  return $FromDirectory
}

function Get-DshConfigValue {
  param(
    [string]$ShellRoot,
    [string]$Name
  )
  $configPath = Join-Path $ShellRoot 'dsh-shell.config.json'
  if (-not (Test-Path -LiteralPath $configPath)) { return $null }
  try {
    $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
    return $config.$Name
  }
  catch {
    Write-ShellLog "WARNING: could not read $configPath : $($_.Exception.Message)"
    return $null
  }
}

<# Resolves the dsh checkout root, or returns $null when it cannot be found. #>
function Resolve-DshRepoRoot {
  param([string]$ShellRoot)

  $candidates = New-Object System.Collections.Generic.List[string]

  $envRoot = $env:DSH_REPO_ROOT
  if (-not [string]::IsNullOrWhiteSpace($envRoot)) { $candidates.Add($envRoot) }

  $configRoot = Get-DshConfigValue -ShellRoot $ShellRoot -Name 'dshRepoRoot'
  if (-not [string]::IsNullOrWhiteSpace($configRoot)) { $candidates.Add($configRoot) }

  # Auto-detection: any sibling of this shell checkout that looks like dsh.
  $shellParent = Split-Path -Parent $ShellRoot
  if (-not [string]::IsNullOrWhiteSpace($shellParent) -and (Test-Path -LiteralPath $shellParent)) {
    Get-ChildItem -LiteralPath $shellParent -Directory -ErrorAction SilentlyContinue |
      ForEach-Object { $candidates.Add($_.FullName) }
  }

  foreach ($candidate in $candidates) {
    if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
    $binJs = Join-Path $candidate 'apps\cli\lib\bin.js'
    if (Test-Path -LiteralPath $binJs) {
      return (Resolve-Path -LiteralPath $candidate).ProviderPath
    }
  }

  return $null
}

<# Locates the published WebView2 host, tolerating any net8.0-windows* TFM folder. #>
function Get-WebView2ShellPath {
  param([string]$ShellRoot)
  $pattern = Join-Path $ShellRoot 'webview2-shell\bin\Release\net8.0-windows*\win-x64\publish\DeepSeek Harness.exe'
  $match = Get-ChildItem -Path $pattern -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1
  if ($null -ne $match) { return $match.FullName }

  # Not published yet: return the expected path so callers can report it.
  return (Join-Path $ShellRoot 'webview2-shell\bin\Release\net8.0-windows10.0.17763.0\win-x64\publish\DeepSeek Harness.exe')
}

<#
    Whether an HTTP server answers on the URL. ANY response counts, including
    the bearer-token fence's 401: the response alone proves the server is up.
    This matches the WebView2 host's readiness rule.
#>
function Test-WebUrlReady {
  param(
    [string]$Url,
    [int]$TimeoutSec = 2
  )
  try {
    Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec $TimeoutSec | Out-Null
    return $true
  }
  catch {
    # Invoke-WebRequest throws on any non-2xx status; a response object means
    # the server answered (401 = bearer fence), while $null means nothing
    # is listening or the request timed out.
    return ($null -ne $_.Exception.Response)
  }
}
