<#
.SYNOPSIS
  One-shot fixer for two Windows terminal startup issues:

  1. Stray characters (e.g. "7f7f\") on the prompt line and a slow first paint.
     fastfetch's logo type defaults to "auto", which probes the terminal for
     image-protocol support with escape-sequence queries. conhost/cmd.exe never
     answers them, so fastfetch stalls waiting for a reply and the partial
     response leaks onto the input line as junk. Pinning an explicit logo type
     skips the probe entirely; version detection (general.detectVersion) and
     the terminal-theme module (OSC 10/11 color query) are further probe
     sources and are disabled/removed. External disks (a sleeping USB drive
     has to spin up before it can report capacity) are excluded from the disk
     module for the same reason. oh-my-posh's upgrade notice and auto-upgrade
     do network version checks on startup; both get disabled. Finally, a Clink
     Lua hook is installed that drains any still-pending terminal reply right
     before the first cmd.exe prompt accepts input, which kills the symptom
     even if some other program emits a query.

  2. Claude Code CLI startup warnings about permission allow rules:
       Write(**)        -> not matched; file checks only honor Edit(path)
       NotebookEdit(**) -> not matched; file checks only honor Edit(path)
       Glob(**)         -> not matched; file checks only honor Read(path)
     Rules in ~/.claude/settings.json (and settings.local.json) are rewritten
     to the forms Claude Code actually matches, then deduplicated.

  Idempotent - safe to re-run. Every file it rewrites gets a timestamped
  .bak-* sibling first. Requires PowerShell 7+ (JSONC parsing).

.EXAMPLE
  pwsh -File scripts/fix-terminal-startup.ps1 -DryRun   # preview only
  pwsh -File scripts/fix-terminal-startup.ps1           # apply
#>
[CmdletBinding()]
param(
  [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion.Major -lt 7) {
  throw 'PowerShell 7+ is required (JSONC config files need its JSON parser). Run with pwsh, not powershell.'
}

$script:Changes = [System.Collections.Generic.List[string]]::new()

function Note([string]$Message) {
  $script:Changes.Add($Message)
  Write-Host "  $Message"
}

function Save-Json([string]$Path, $Object) {
  if (Test-Path $Path) {
    $backup = "$Path.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    if (-not $DryRun) { Copy-Item $Path $backup }
    Note "backup: $backup"
  }
  if (-not $DryRun) {
    $dir = Split-Path $Path -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $Object | ConvertTo-Json -Depth 100 | Set-Content -Path $Path -Encoding utf8
  }
}

# --- 1. Claude Code permission rules --------------------------------------

function Repair-ClaudeSettings {
  Write-Host "`n== Claude Code settings ==" -ForegroundColor Cyan
  $files = @(
    (Join-Path $HOME '.claude/settings.json'),
    (Join-Path $HOME '.claude/settings.local.json')
  ) | Where-Object { Test-Path $_ }

  if (-not $files) { Write-Host '  no ~/.claude settings files found - nothing to do'; return }

  foreach ($file in $files) {
    $json = Get-Content $file -Raw | ConvertFrom-Json
    if ($null -eq $json.permissions) { Write-Host "  $file - no permissions block, skipped"; continue }

    $changed = $false
    foreach ($list in 'allow', 'deny', 'ask') {
      $rules = $json.permissions.$list
      if ($null -eq $rules) { continue }

      $mapped = foreach ($rule in @($rules)) {
        $new = $rule -replace '^(Write|NotebookEdit)\(', 'Edit(' -replace '^Glob\(', 'Read('
        if ($new -ne $rule) {
          $changed = $true
          Note "$list`: '$rule' -> '$new'"
        }
        $new
      }
      $deduped = @($mapped | Select-Object -Unique)
      if ($deduped.Count -ne @($mapped).Count) {
        $changed = $true
        Note "$list`: removed $(@($mapped).Count - $deduped.Count) duplicate rule(s) after rewrite"
      }
      $json.permissions.$list = $deduped
    }

    if ($changed) {
      Save-Json $file $json
      Note "rewrote $file"
    }
    else {
      Write-Host "  $file - already clean"
    }
  }
}

# --- 2. fastfetch ----------------------------------------------------------

function Find-FastfetchConfig {
  $candidates = @()
  if ($env:XDG_CONFIG_HOME) { $candidates += Join-Path $env:XDG_CONFIG_HOME 'fastfetch' }
  $candidates += (Join-Path $HOME '.config/fastfetch')
  if ($env:LOCALAPPDATA) { $candidates += Join-Path $env:LOCALAPPDATA 'fastfetch' }
  if ($env:APPDATA) { $candidates += Join-Path $env:APPDATA 'fastfetch' }
  foreach ($dir in $candidates) {
    foreach ($name in 'config.jsonc', 'config.json') {
      $path = Join-Path $dir $name
      if (Test-Path $path) { return $path }
    }
  }
  return $null
}

function Repair-FastfetchConfig {
  Write-Host "`n== fastfetch ==" -ForegroundColor Cyan
  $path = Find-FastfetchConfig

  if (-not $path) {
    # No config: the escape-probe still happens via the "auto" default, so
    # create a minimal config that pins the logo type. CLI flags in a shell
    # profile still override this, so a custom logo passed as an argument
    # keeps working.
    $path = Join-Path $HOME '.config/fastfetch/config.jsonc'
    $config = [pscustomobject]@{
      '$schema' = 'https://github.com/fastfetch-cli/fastfetch/raw/dev/doc/json_schema.json'
      logo      = [pscustomobject]@{ type = 'builtin' }
      general   = [pscustomobject]@{ detectVersion = $false }
    }
    Save-Json $path $config
    Note "created $path with an explicit logo type (was relying on 'auto' defaults)"
    Write-Host "  note: if startup is still slow, the disk module querying the external USB drive is the"
    Write-Host "  likely cause - add a modules list with { `"type`": `"disk`", `"showExternal`": false }."
    return
  }

  # PS7's ConvertFrom-Json tolerates JSONC comments; rewriting drops them
  # (the .bak keeps the original).
  $config = Get-Content $path -Raw | ConvertFrom-Json
  $changed = $false

  # Pin the logo type so fastfetch never probes the terminal.
  $logo = $config.logo
  if ($null -eq $logo) {
    $config | Add-Member -NotePropertyName logo -NotePropertyValue ([pscustomobject]@{ type = 'builtin' }) -Force
    Note "logo: none configured -> pinned type 'builtin'"
    $changed = $true
  }
  elseif ($logo -is [string]) {
    $type = if ((Test-Path $logo) -or $logo -match '[\\/]') { 'file' } else { 'builtin' }
    $config.logo = [pscustomobject]@{ source = $logo; type = $type }
    Note "logo: string '$logo' -> { source, type: '$type' }"
    $changed = $true
  }
  elseif ($null -eq $logo.type -or $logo.type -eq 'auto') {
    $oldType = if ($null -eq $logo.type) { 'unset' } else { 'auto' }
    $source = $logo.source
    $type = if ($source -and ((Test-Path $source) -or $source -match '[\\/]')) { 'file' } else { 'builtin' }
    $logo | Add-Member -NotePropertyName type -NotePropertyValue $type -Force
    Note "logo: type was '$oldType' -> pinned '$type'"
    $changed = $true
  }
  else {
    Write-Host "  logo type already explicit ('$($logo.type)')"
  }

  # detectVersion (default true) enables version-specific detection paths that
  # can query the terminal with escape sequences.
  if ($null -eq $config.general) {
    $config | Add-Member -NotePropertyName general -NotePropertyValue ([pscustomobject]@{ detectVersion = $false }) -Force
    Note 'general: added { detectVersion: false }'
    $changed = $true
  }
  elseif ($config.general.detectVersion -ne $false) {
    $config.general | Add-Member -NotePropertyName detectVersion -NotePropertyValue $false -Force
    Note 'general: set detectVersion: false'
    $changed = $true
  }

  # The terminal-theme module asks the terminal for its colors via OSC 10/11 -
  # exactly the kind of query whose reply leaks onto the prompt.
  if ($config.modules) {
    $kept = @($config.modules | Where-Object {
        -not (($_ -is [string] -and $_ -match '^terminaltheme$') -or
              ($_ -isnot [string] -and $_.type -match '^terminaltheme$'))
      })
    if ($kept.Count -ne @($config.modules).Count) {
      $config.modules = $kept
      Note 'modules: removed terminaltheme (queries terminal colors via OSC 10/11)'
      $changed = $true
    }
  }

  # Keep external/USB disks out of the disk module - a sleeping drive can
  # take seconds to spin up just to report capacity.
  if ($config.modules) {
    $modules = foreach ($module in $config.modules) {
      if ($module -is [string] -and $module -eq 'disk') {
        $changed = $true
        Note "modules: 'disk' -> { type: 'disk', showExternal: false }"
        [pscustomobject]@{ type = 'disk'; showExternal = $false }
      }
      elseif ($module -isnot [string] -and $module.type -eq 'disk' -and $null -eq $module.showExternal) {
        $changed = $true
        Note "modules: disk -> added showExternal: false"
        $module | Add-Member -NotePropertyName showExternal -NotePropertyValue $false -Force
        $module
      }
      else { $module }
    }
    $config.modules = @($modules)
  }

  if ($changed) {
    Save-Json $path $config
    Note "rewrote $path"
  }
  else {
    Write-Host "  $path - already clean"
  }
}

# --- 3. Clink: drain late terminal replies before the first prompt ---------

$ClinkDrainLua = @'
-- zz-flush-startup-input.lua
-- Startup programs (fastfetch, oh-my-posh, ...) may query the terminal with
-- escape sequences. In fast GPU terminals (Alacritty, WezTerm) the reply can
-- arrive after the prompt is already accepting input and leaks onto the line
-- as junk like "80\". Drain pending input once, at the first prompt.
local done = false
clink.onbeginedit(function ()
  if done then return end
  done = true
  local ok = pcall(function ()
    if not (console and console.checkinput and console.readinput) then return end
    local deadline = os.clock() + 0.30
    while os.clock() < deadline and console.checkinput(0.05) do
      console.readinput()
    end
  end)
end)
'@

function Install-ClinkStartupDrain {
  Write-Host "`n== Clink (cmd.exe prompt) ==" -ForegroundColor Cyan
  $profileDir = if ($env:CLINK_PROFILE) { $env:CLINK_PROFILE }
  elseif ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'clink' }
  else { $null }
  if (-not $profileDir) { Write-Host '  no LOCALAPPDATA/CLINK_PROFILE - skipped'; return }

  $luaPath = Join-Path $profileDir 'zz-flush-startup-input.lua'
  if ((Test-Path $luaPath) -and ((Get-Content $luaPath -Raw).Trim() -eq $ClinkDrainLua.Trim())) {
    Write-Host "  $luaPath - already installed"
    return
  }
  if (-not $DryRun) {
    if (-not (Test-Path $profileDir)) { New-Item -ItemType Directory -Path $profileDir -Force | Out-Null }
    Set-Content -Path $luaPath -Value $ClinkDrainLua -Encoding utf8
  }
  Note "installed $luaPath (drains pending terminal replies at the first cmd prompt)"
}

# --- 4. oh-my-posh ---------------------------------------------------------

function Disable-OmpStartupChecks {
  Write-Host "`n== oh-my-posh ==" -ForegroundColor Cyan
  if (-not (Get-Command oh-my-posh -ErrorAction SilentlyContinue)) {
    Write-Host '  oh-my-posh not on PATH - skipped'
    return
  }
  if ($DryRun) {
    Write-Host '  would run: oh-my-posh disable notice; oh-my-posh disable upgrade'
    return
  }
  oh-my-posh disable notice
  # the subcommand is 'upgrade' on current versions, 'autoupgrade' on older ones
  $null = & oh-my-posh disable upgrade 2>&1
  if ($LASTEXITCODE -ne 0) { $null = & oh-my-posh disable autoupgrade 2>&1 }
  if ($LASTEXITCODE -eq 0) {
    Note 'disabled oh-my-posh upgrade notice and auto-upgrade startup checks'
  }
  else {
    Write-Host '  could not disable auto-upgrade (unrecognized CLI syntax); notice disabled'
  }
}

# --- run -------------------------------------------------------------------

if ($DryRun) { Write-Host "DRY RUN - no files will be modified`n" -ForegroundColor Yellow }

Repair-ClaudeSettings
Repair-FastfetchConfig
Install-ClinkStartupDrain
Disable-OmpStartupChecks

Write-Host "`n== summary ==" -ForegroundColor Cyan
if ($script:Changes.Count -eq 0) {
  Write-Host '  nothing needed changing'
}
else {
  Write-Host "  $($script:Changes.Count) change(s)$(if ($DryRun) { ' (dry run - none applied)' })"
  Write-Host '  open a new terminal tab to verify: no stray characters, faster startup,'
  Write-Host '  and no permission-rule warnings when launching claude.'
}
