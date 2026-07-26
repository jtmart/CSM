<#
.SYNOPSIS
  One-shot orchestrator for replicating the terminal setup on a new Windows
  machine. Intended to live (with its sibling scripts) in the replication
  store: C:\Users\<user>\Dropbox\Sync\add-templates\terminal-startup\

  Runs, in order:
    1. fix-terminal-startup.ps1  (Windows: fastfetch/omp probes off, Claude rules)
    2. fix-psmux-drain.ps1       (pwsh profile drain for Alacritty/psmux panes)
    3. fix-terminal-startup.sh   (inside WSL, if wsl is available)

  Notes for a fresh machine:
  - If the PowerShell profile lives under OneDrive\Documents and Controlled
    Folder Access is on, allow pwsh first (admin):
      Add-MpPreference -ControlledFolderAccessAllowedApplications (Get-Command pwsh.exe).Source
  - Everything is idempotent; re-running after fixing a blocker is safe.

.EXAMPLE
  pwsh -ExecutionPolicy Bypass -File .\install-terminal-setup.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

# Dropbox/browser downloads may carry Mark-of-the-Web; clear it up front.
Get-ChildItem $here -File | Unblock-File -ErrorAction SilentlyContinue

Write-Host "=== 1/3 Windows fixes ===" -ForegroundColor Green
pwsh -ExecutionPolicy Bypass -File (Join-Path $here 'fix-terminal-startup.ps1')

Write-Host "`n=== 2/3 psmux drain (pwsh profile) ===" -ForegroundColor Green
pwsh -ExecutionPolicy Bypass -File (Join-Path $here 'fix-psmux-drain.ps1')

if (Get-Command wsl -ErrorAction SilentlyContinue) {
  $wslHere = (wsl wslpath -a "$here" 2>$null | Select-Object -First 1)
  if ($LASTEXITCODE -eq 0 -and $wslHere) {
    Write-Host "`n=== 3/3 WSL fixes ===" -ForegroundColor Green
    wsl -e bash "$wslHere/fix-terminal-startup.sh"
  }
  else {
    Write-Host "`nWSL present but wslpath failed - run the .sh scripts manually inside WSL." -ForegroundColor Yellow
  }
}
else {
  Write-Host "`nNo WSL detected - skipped the Unix-side scripts." -ForegroundColor Yellow
}

Write-Host "`nDone. Open TWO new terminal tabs - the first rebuilds caches, judge the second." -ForegroundColor Green
