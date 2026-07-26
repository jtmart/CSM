<#
.SYNOPSIS
  Startup speed pass for the Windows-side shells, companion to
  speed-terminal-startup.sh. Two transforms in the PowerShell profile(s):

  1. fastfetch -> cached splash. The saved output of the previous run prints
     instantly (pure color codes, zero cost) while fastfetch regenerates the
     cache in the background writing to a FILE - so it never queries the
     terminal (this is also what removes the last source of stray characters
     like "7f7f\" leaking onto the first prompt).

  2. oh-my-posh init -> cached init script. 'oh-my-posh init pwsh ... |
     Invoke-Expression' spawns oh-my-posh synchronously on every shell start
     just to print an init script that rarely changes. Cache it and
     dot-source the file instead. (Delete %LOCALAPPDATA%\ftsu-omp-init.ps1
     after changing your omp theme.)

  Conservative: each transform only fires when it finds exactly the simple,
  common form of the line; anything unusual is left alone and reported.
  Idempotent; edited files get timestamped .bak-* siblings.

.EXAMPLE
  pwsh -ExecutionPolicy Bypass -File .\speed-terminal-startup.ps1 -DryRun
  pwsh -ExecutionPolicy Bypass -File .\speed-terminal-startup.ps1
#>
[CmdletBinding()]
param(
  [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

function Note([string]$Message) { Write-Host "  $Message" }

$SplashTemplate = @'

# --- fastfetch cached splash (speed-terminal-startup) ---
# Instant splash from the previous run's output; regenerated in the
# background into a file, so fastfetch never queries the terminal.
$__ftsuSplash = Join-Path $env:LOCALAPPDATA 'ftsu-splash.txt'
if (Test-Path $__ftsuSplash) { [Console]::Out.Write([IO.File]::ReadAllText($__ftsuSplash)) }
Start-Process -FilePath cmd.exe -WindowStyle Hidden -ArgumentList "/c __FFCMD__ --pipe false > ""$__ftsuSplash.new"" 2>nul && move /y ""$__ftsuSplash.new"" ""$__ftsuSplash"" >nul"
# --- end fastfetch cached splash ---
'@

$OmpTemplate = @'
$__ftsuOmp = Join-Path $env:LOCALAPPDATA 'ftsu-omp-init.ps1'
if (-not (Test-Path $__ftsuOmp)) { __OMPCMD__ --print | Set-Content -Path $__ftsuOmp -Encoding utf8 }
. $__ftsuOmp   # cached oh-my-posh init; delete the file after changing your theme
'@

function Update-Profile([string]$Path) {
  Write-Host "`n== $Path ==" -ForegroundColor Cyan
  if (-not (Test-Path $Path)) { Write-Host '  not present - skipped'; return }

  $lines = [System.Collections.Generic.List[string]](Get-Content $Path)
  $changed = $false
  $raw = $lines -join "`n"

  # --- 1. fastfetch -> cached splash --------------------------------------
  if ($raw -match 'ftsu-splash') {
    Note 'fastfetch: already cached'
  }
  else {
    $ffIdx = @(0..($lines.Count - 1) | Where-Object { $lines[$_] -match '^\s*fastfetch(\s|$)' })
    if ($ffIdx.Count -eq 1) {
      $i = $ffIdx[0]
      $cmd = $lines[$i].Trim()
      $lines[$i] = "# moved to cached splash below (speed-terminal-startup): $cmd"
      $lines.AddRange([string[]]($SplashTemplate.Replace('__FFCMD__', $cmd) -split "`n"))
      Note "fastfetch: cached splash installed (was: $cmd)"
      Note 'note: first new shell after this has no splash yet; it appears from the 2nd on'
      $changed = $true
    }
    elseif ($ffIdx.Count -eq 0) { Note 'fastfetch: no simple invocation found - skipped' }
    else { Note "fastfetch: $($ffIdx.Count) invocations found - ambiguous, left alone" }
  }

  # --- 2. oh-my-posh init -> cached init script ---------------------------
  if ($raw -match 'ftsu-omp-init') {
    Note 'oh-my-posh: already cached'
  }
  else {
    $ompIdx = @(0..($lines.Count - 1) | Where-Object {
        $lines[$_] -match '^\s*(&\s*)?oh-my-posh\s+init\s+\S+.*\|\s*Invoke-Expression\s*$'
      })
    if ($ompIdx.Count -eq 1) {
      $i = $ompIdx[0]
      $orig = $lines[$i].Trim()
      $initCmd = ($orig -replace '\|\s*Invoke-Expression\s*$', '').Trim()
      $block = @("# replaced by cached init (speed-terminal-startup): $orig")
      $block += ($OmpTemplate.Replace('__OMPCMD__', $initCmd) -split "`n")
      $lines.RemoveAt($i)
      $lines.InsertRange($i, [string[]]$block)
      Note "oh-my-posh: cached init installed (was: $orig)"
      $changed = $true
    }
    elseif ($ompIdx.Count -eq 0) { Note 'oh-my-posh: no standard init line found - skipped' }
    else { Note "oh-my-posh: $($ompIdx.Count) init lines found - ambiguous, left alone" }
  }

  if ($changed -and -not $DryRun) {
    # Backup into LOCALAPPDATA rather than next to the profile: OneDrive-synced
    # folders can fail Copy-Item on placeholder files.
    $bakDir = Join-Path $env:LOCALAPPDATA 'ftsu-backups'
    if (-not (Test-Path $bakDir)) { New-Item -ItemType Directory -Path $bakDir -Force | Out-Null }
    $bak = Join-Path $bakDir "$(Split-Path $Path -Leaf).bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    Set-Content -Path $bak -Value $raw -Encoding utf8
    Set-Content -Path $Path -Value ($lines -join [Environment]::NewLine) -Encoding utf8
    Note "rewrote $Path (backup: $bak)"
  }
  elseif ($changed) {
    Note '(dry run - not written)'
  }
}

if ($DryRun) { Write-Host "DRY RUN - no files will be modified`n" -ForegroundColor Yellow }

$profiles = @($PROFILE.CurrentUserAllHosts, $PROFILE.CurrentUserCurrentHost) | Select-Object -Unique
foreach ($p in $profiles) { Update-Profile $p }

Write-Host "`nDone. The FIRST new shell still pays full cost (builds the caches); judge the"
Write-Host 'second one. This also removes the last way fastfetch could query the terminal.'
