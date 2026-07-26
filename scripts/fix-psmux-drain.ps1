<#
.SYNOPSIS
  Installs the psmux input drain into the PowerShell profile.

  Root cause (finally pinned): Alacritty tabs run
    cmd /c psmux new-session pwsh.exe -NoLogo
  psmux (tmux-for-Windows) queries the host terminal at attach; Alacritty's
  reply is forwarded into the inner pwsh pane, where its tail renders as
  stray input like "7f7f\". There is no psmux option to disable the query,
  and every earlier drain hook lived in the wrong shell (bash/zsh/Clink) -
  the inner shell here is pwsh, which had none.

  This appends a guarded block to the end of the PowerShell profile that,
  ONLY when running under Alacritty ($env:ALACRITTY = '1', set by the
  Alacritty config), drains pending console input until it has been quiet
  for ~200ms - once right after the profile finishes, and once more at the
  first prompt render (wrapping the existing prompt function). Windows
  Terminal and other hosts are untouched.

  Idempotent; keeps a backup in %LOCALAPPDATA%\ftsu-backups.

.EXAMPLE
  pwsh -ExecutionPolicy Bypass -File .\fix-psmux-drain.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$Block = @'

# --- psmux startup input drain (fix-terminal-startup) ---
# psmux queries the host terminal at attach; the reply is forwarded into
# this pane and its tail renders as stray input like "7f7f\". Drain pending
# input until ~200ms of quiet - after profile load and at the first prompt.
if ($env:ALACRITTY -eq '1') {
  function global:__ftsu_drain {
    try {
      $quiet = 0; $got = 0
      while ($quiet -lt 2 -and $got -lt 512) {
        if ([Console]::KeyAvailable) { [void][Console]::ReadKey($true); $got++; $quiet = 0 }
        else { Start-Sleep -Milliseconds 100; $quiet++ }
      }
    } catch { }
  }
  __ftsu_drain
  $global:__ftsuPrevPrompt = $function:prompt
  function global:prompt {
    if (-not $global:__ftsuDrained) { $global:__ftsuDrained = $true; __ftsu_drain }
    & $global:__ftsuPrevPrompt
  }
}
# --- end psmux startup input drain ---
'@

$path = $PROFILE.CurrentUserCurrentHost
Write-Host "== $path ==" -ForegroundColor Cyan

if ((Test-Path $path) -and ((Get-Content $path -Raw) -match 'psmux startup input drain')) {
  Write-Host '  already installed'
  return
}

if (Test-Path $path) {
  $bakDir = Join-Path $env:LOCALAPPDATA 'ftsu-backups'
  if (-not (Test-Path $bakDir)) { New-Item -ItemType Directory -Path $bakDir -Force | Out-Null }
  $bak = Join-Path $bakDir "$(Split-Path $path -Leaf).bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
  Copy-Item $path $bak
  Write-Host "  backup: $bak"
}
else {
  $dir = Split-Path $path -Parent
  if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
}

Add-Content -Path $path -Value $Block -Encoding utf8
Write-Host '  installed psmux drain (active only when ALACRITTY=1; Windows Terminal unaffected)'
Write-Host ''
Write-Host 'Open a new Alacritty tab (psmux) to verify the stray characters are gone.' -ForegroundColor Green
Write-Host 'Cost: up to ~200ms once at the first prompt of each psmux pane only.'
