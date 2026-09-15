<#
.SYNOPSIS
    Keep the dsh web profile's @deepseek-ai junctions in sync with the checkout.

.DESCRIPTION
    The web profile resolves core packages through directory junctions:

        %USERPROFILE%\.dsh\profiles\node_modules\@deepseek-ai\<pkg>
            -> <dsh checkout>\apps\cli\node_modules\@deepseek-ai\dsh-web-app\node_modules\@deepseek-ai\<pkg>

    That junction set is a snapshot: it is built once and never grows by itself.
    When upstream adds a package to the web-app bundle, the checkout gains the
    source but the profile keeps its old link list, so the package's service is
    never provided and every plugin injecting it hangs as "pending".

    This script diffs the two directories and creates the missing junctions with
    the same rules the profile installer uses. It never deletes or overwrites an
    existing link; dangling links (target gone, e.g. after a rename) are only
    reported.

    Cost: a HEAD marker skips the whole scan unless the dsh checkout changed, so
    an ordinary launch pays nothing.

.PARAMETER Apply
    Create the missing junctions. Without it the script only reports.

.PARAMETER Force
    Ignore the HEAD marker and rescan even when nothing changed.

.PARAMETER RemoveDangling
    Delete junctions whose target no longer exists, i.e. packages upstream
    removed or renamed. Requires -Apply. This is safe: whenever the package
    returns to the bundle, this script recreates the link.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\sync-profile-links.ps1

    # Actually create the missing links:
    powershell -ExecutionPolicy Bypass -File scripts\sync-profile-links.ps1 -Apply

.NOTES
    Dot-source this file to reuse Sync-ProfileLinks from another script; it does
    not run automatically in that case.
#>

[CmdletBinding()]
param(
  [switch]$Apply,
  [switch]$Force,
  [switch]$RemoveDangling
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'dsh-shell-common.ps1')

function Get-DshHead {
  param([string]$DshRoot)
  # Read .git directly: spawning git costs ~150 ms, and this runs on every launch.
  try {
    $gitDir = Join-Path $DshRoot '.git'
    if (Test-Path -LiteralPath $gitDir -PathType Leaf) {
      # Worktree / submodule: .git is a file pointing at the real git directory.
      $pointer = Get-Content -LiteralPath $gitDir -Raw -ErrorAction Stop
      if ($pointer -match 'gitdir:\s*(.+)') { $gitDir = $Matches[1].Trim() }
    }

    $headPath = Join-Path $gitDir 'HEAD'
    if (-not (Test-Path -LiteralPath $headPath)) { throw 'HEAD file is missing' }

    $head = (Get-Content -LiteralPath $headPath -Raw).Trim()
    if ($head -match '^ref:\s*(.+)') {
      $ref = $Matches[1].Trim()
      $refPath = Join-Path $gitDir $ref
      if (Test-Path -LiteralPath $refPath) { return (Get-Content -LiteralPath $refPath -Raw).Trim() }

      $packedPath = Join-Path $gitDir 'packed-refs'
      if (Test-Path -LiteralPath $packedPath) {
        foreach ($line in (Get-Content -LiteralPath $packedPath)) {
          if ($line -match '^(\S+)\s+(\S+)$' -and $Matches[2] -eq $ref) { return $Matches[1] }
        }
      }
      throw "cannot resolve ref $ref"
    }

    return $head
  }
  catch {
    # Fall back to git (unusual layouts); a null head just means "always rescan".
    try {
      $head = (git -C $DshRoot rev-parse HEAD 2>$null)
      if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($head)) { return $head.Trim() }
    }
    catch {
      # git unavailable: rescan every time.
    }
    return $null
  }
}

function Sync-ProfileLinks {
  [CmdletBinding()]
  param(
    [switch]$Apply,
    [switch]$Force,
    [switch]$RemoveDangling
  )

  $shellRoot = Get-ShellRoot -FromDirectory $PSScriptRoot
  $dshRoot = Resolve-DshRepoRoot -ShellRoot $shellRoot
  if ([string]::IsNullOrWhiteSpace($dshRoot)) {
    Write-ShellLog 'sync-profile-links: dsh checkout not found; skipped'
    return
  }

  # Reach the bundle through its CANONICAL directory. Its node_modules entries
  # are relative symlinks, and Windows resolves a relative target against the
  # path as written: through the apps\cli junction they point at a directory
  # that does not exist, while through the real directory they resolve.
  $webAppPath = Join-Path $dshRoot 'apps\cli\node_modules\@deepseek-ai\dsh-web-app'
  if (-not (Test-Path -LiteralPath $webAppPath)) {
    Write-ShellLog "sync-profile-links: bundle package not found at $webAppPath; skipped"
    return
  }
  $webAppReal = (Get-Item -LiteralPath $webAppPath -Force).Target
  if ([string]::IsNullOrWhiteSpace($webAppReal) -or -not (Test-Path -LiteralPath $webAppReal)) {
    $webAppReal = $webAppPath
  }
  $sourceDir = Join-Path $webAppReal 'node_modules\@deepseek-ai'
  if (-not (Test-Path -LiteralPath $sourceDir)) {
    Write-ShellLog "sync-profile-links: bundle directory not found at $sourceDir; skipped"
    return
  }

  $linkDir = Join-Path $env:USERPROFILE '.dsh\profiles\node_modules\@deepseek-ai'

  # Fast path: the checkout has not moved since the last successful sync.
  $markerPath = Join-Path $env:TEMP 'dsh-profile-links-head.txt'
  $head = Get-DshHead -DshRoot $dshRoot
  if (-not $Force -and $head -and (Test-Path -LiteralPath $markerPath)) {
    $marker = (Get-Content -LiteralPath $markerPath -Raw -ErrorAction SilentlyContinue)
    if (($marker | ForEach-Object { $_.Trim() }) -eq $head) {
      Write-ShellLog "sync-profile-links: up to date at $($head.Substring(0, 12)); skipped"
      return
    }
  }

  # Only entries that actually resolve to a package are usable; a broken
  # relative link must never be propagated into the profile.
  $available = @()
  $unusable = @()
  foreach ($item in (Get-ChildItem -LiteralPath $sourceDir -Directory -Force -ErrorAction SilentlyContinue)) {
    if (Test-Path -LiteralPath (Join-Path $item.FullName 'package.json')) { $available += $item.Name }
    else { $unusable += $item.Name }
  }
  if ($available.Count -eq 0) {
    Write-ShellLog 'sync-profile-links: no usable bundle packages; skipped'
    return
  }
  foreach ($name in $unusable) {
    Write-Host "sync-profile-links: unusable in bundle (not linked) $name"
  }

  if (-not (Test-Path -LiteralPath $linkDir)) {
    if ($Apply) { New-Item -ItemType Directory -Path $linkDir -Force | Out-Null }
    else { Write-Host "sync-profile-links: would create $linkDir" }
  }

  $existing = @(Get-ChildItem -LiteralPath $linkDir -Force -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
  $missing = @($available | Where-Object { $existing -notcontains $_ })

  # A link whose target has vanished (package removed or renamed upstream).
  $danglingItems = @(
    Get-ChildItem -LiteralPath $linkDir -Force -ErrorAction SilentlyContinue |
      Where-Object { $_.LinkType -and -not [string]::IsNullOrWhiteSpace($_.Target) -and -not (Test-Path -LiteralPath $_.Target) }
  )
  $dangling = @($danglingItems | Select-Object -ExpandProperty Name)

  foreach ($name in $missing) {
    $target = Join-Path $sourceDir $name
    $link = Join-Path $linkDir $name
    if ($Apply) {
      New-Item -ItemType Junction -Path $link -Target $target | Out-Null
      Write-Host "sync-profile-links: linked $name"
    }
    else {
      Write-Host "sync-profile-links: missing $name"
    }
  }

  # A link that exists but resolves to nothing must be rebuilt. This is the
  # Windows relative-symlink trap: earlier runs linked through the apps\cli
  # junction, where the bundle's relative targets point nowhere.
  $repaired = 0
  foreach ($item in (Get-ChildItem -LiteralPath $linkDir -Force -ErrorAction SilentlyContinue)) {
    if ($available -notcontains $item.Name) { continue }
    if (Test-Path -LiteralPath (Join-Path $item.FullName 'package.json')) { continue }
    if (-not $Apply) {
      Write-Host "sync-profile-links: would repair $($item.Name)"
      continue
    }
    try {
      [System.IO.Directory]::Delete($item.FullName, $false)
      New-Item -ItemType Junction -Path $item.FullName -Target (Join-Path $sourceDir $item.Name) | Out-Null
      $repaired++
      Write-Host "sync-profile-links: repaired $($item.Name)"
    }
    catch {
      Write-Host "sync-profile-links: cannot repair $($item.Name): $($_.Exception.Message)"
    }
  }

  # Pruning only happens once the checkout resolved above, so an unavailable
  # drive can never make every link look dangling and get deleted.
  $removed = 0
  foreach ($item in $danglingItems) {
    if ($Apply -and $RemoveDangling) {
      try {
        [System.IO.Directory]::Delete($item.FullName, $false)
        $removed++
        Write-Host "sync-profile-links: removed dangling $($item.Name)"
        continue
      }
      catch {
        Write-Host "sync-profile-links: cannot remove dangling $($item.Name): $($_.Exception.Message)"
      }
    }
    Write-Host "sync-profile-links: dangling link (not removed) $($item.Name)"
  }

  $verb = if ($Apply) { 'linked' } else { 'missing' }
  Write-ShellLog "sync-profile-links: $verb $($missing.Count) of $($available.Count) packages; repaired=$repaired; dangling=$($dangling.Count); removed=$removed; unusable=$($unusable.Count)"
  if ($dangling.Count -gt 0) {
    Write-ShellLog "sync-profile-links: dangling: $($dangling -join ', ')"
  }

  if ($Apply -and $head) {
    Set-Content -LiteralPath $markerPath -Value $head -Encoding ASCII
  }
}

# Only run when invoked as a script; dot-sourcing just imports the function.
if ($MyInvocation.InvocationName -ne '.') {
  Sync-ProfileLinks -Apply:$Apply -Force:$Force -RemoveDangling:$RemoveDangling
}
