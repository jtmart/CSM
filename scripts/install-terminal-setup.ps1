<#
.SYNOPSIS
  One-shot orchestrator for replicating the terminal setup on a new Windows
  machine. Intended to live (with its sibling scripts) in the replication
  store: C:\Users\<user>\Dropbox\Sync\add-templates\terminal-startup\

  Runs, in order:
    1. fix-terminal-startup.ps1    (Windows: probes off, Clink drain, Claude rules)
    2. speed-terminal-startup.ps1  (Windows: cached splash + cached omp init)
    3. fix-terminal-startup.sh     (inside WSL, if wsl is available)
    4. speed-terminal-startup.sh   (inside WSL, if wsl is available)

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

Write-Host "=== 1/4 Windows fixes ===" -ForegroundColor Green
pwsh -ExecutionPolicy Bypass -File (Join-Path $here 'fix-terminal-startup.ps1')

Write-Host "`n=== 2/4 Windows speed pass ===" -ForegroundColor Green
pwsh -ExecutionPolicy Bypass -File (Join-Path $here 'speed-terminal-startup.ps1')

if (Get-Command wsl -ErrorAction SilentlyContinue) {
  $wslHere = (wsl wslpath -a "$here" 2>$null | Select-Object -First 1)
  if ($LASTEXITCODE -eq 0 -and $wslHere) {
    Write-Host "`n=== 3/4 WSL fixes ===" -ForegroundColor Green
    wsl -e bash "$wslHere/fix-terminal-startup.sh"
    Write-Host "`n=== 4/4 WSL speed pass ===" -ForegroundColor Green
    wsl -e bash "$wslHere/speed-terminal-startup.sh"
  }
  else {
    Write-Host "`nWSL present but wslpath failed - run the .sh scripts manually inside WSL." -ForegroundColor Yellow
  }
}
else {
  Write-Host "`nNo WSL detected - skipped the Unix-side scripts." -ForegroundColor Yellow
}

Write-Host "`nDone. Open TWO new terminal tabs - the first rebuilds caches, judge the second." -ForegroundColor Green
