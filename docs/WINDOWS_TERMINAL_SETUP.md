# Windows Terminal Setup — Startup Fixes (RESOLVED July 2026)

Reference for replicating the terminal stack (Alacritty → psmux → pwsh, with
fastfetch + oh-my-posh; WSL alongside) on a new Windows machine, and the
record of the July 2026 investigation into two startup problems:

1. **Stray characters on the first prompt line** (`7f7f\`, `80\`) in
   Alacritty/psmux panes, plus slow startup.
2. **Claude Code CLI startup warnings** about unmatched permission rules.

Canonical replication copies live in
`C:\Users\jtm\Dropbox\Sync\add-templates\terminal-startup\`. On a new machine
run `install.ps1` from that folder — it chains everything below.

## The three scripts that matter

| Script | What it does |
|---|---|
| `fix-terminal-startup.ps1` | Windows side: rewrites unmatched Claude Code permission rules (`Write(**)`/`NotebookEdit(**)` → `Edit(**)`, `Glob(**)` → `Read(**)`) in `~\.claude\settings.json`; pins fastfetch's `logo.type`, sets `general.detectVersion: false`, drops the `terminaltheme` module, excludes external USB disks (`showExternal: false` — spin-up stalls); disables oh-my-posh's upgrade notice/auto-upgrade network checks. |
| `fix-psmux-drain.ps1` | **The stray-character fix.** Appends a drain block to the pwsh profile, active only when `$env:ALACRITTY` is `1`: swallows pending console input until ~200ms of quiet, after profile load and at the first prompt render. |
| `fix-terminal-startup.sh` | Same fastfetch/oh-my-posh hygiene inside WSL (separate home, separate configs). Run from a WSL shell or let `install.ps1` do it via `wsl`. |

All are idempotent and keep timestamped backups.

## Root cause of the stray characters

The fragments were the tail of a terminal escape-query **reply** (ending in
the ST terminator `ESC \`, whose backslash renders literally). The emitter was
**psmux**: Alacritty launches every tab as
`cmd /c psmux new-session pwsh.exe -NoLogo` (see `alacritty.toml`
`[terminal.shell]`), and psmux queries the host terminal at attach. Alacritty's
reply is forwarded into the inner pwsh pane after the prompt is live, so its
tail lands on the input line. psmux has no option to suppress the query
([configuration docs](https://github.com/psmux/psmux/blob/master/docs/configuration.md)),
hence the drain on the receiving side.

Diagnosis lessons, for the next mystery like this:

- **Identify the pane's inner shell first.** fastfetch reported "Shell: CMD"
  (the launcher), but the shell attached to the pane was pwsh via psmux. Drain
  hooks only work in the shell that owns the input line — hooks installed in
  bash/zsh/Clink along the way could never fire here (there is no Clink and no
  cmd AutoRun in this setup at all; the cmd-tab prompt is oh-my-posh inside
  psmux-hosted pwsh).
- Reply-capable GPU terminals (Alacritty) answer queries **late and out of
  order** ([alacritty#4872](https://github.com/alacritty/alacritty/issues/4872)),
  so time-boxed drains can lose the race; drain at the first prompt render and
  keep going until the line is quiet.
- The leak only reproduces in terminals that answer queries — plain conhost
  windows stay clean, which localizes the emitter to the tab's startup chain.

Things that reduced probing but were **not** the leak: fastfetch's `auto`
logo detection, `detectVersion`, the `terminaltheme` module, oh-my-posh's
upgrade checks. Worth keeping off anyway (startup cost, fewer moving parts).

## What was tried and rolled back

- **Cached fastfetch splash** (print previous run's output, regenerate in
  background): a non-tty fastfetch falls back to `?` placeholder glyphs, and
  the cache doubles up with other fastfetch invocations in the startup chain.
  Reverted (`revert-splash-cache.ps1`). The **oh-my-posh init cache** part of
  the speed pass works fine and is kept: init script cached to
  `%LOCALAPPDATA%\ftsu-omp-init.ps1` / `~/.cache/ftsu-omp-init.*` — delete
  after changing the omp theme.
- **Clink drain hook** and **bash/zsh rc drain hooks**: wrong shell for this
  setup (see above); removed by `finalize-terminal-setup.ps1` cleanup.

## Windows gotchas (fresh-install checklist)

- **PowerShell profile lives under OneDrive** (`OneDrive\Documents\PowerShell`):
  `Copy-Item` onto placeholders can fail (write backups to `%LOCALAPPDATA%`),
  and **Controlled Folder Access** blocks pwsh writes to Documents with
  *Access to the path is denied*. One-time unblock from an admin PowerShell:

  ```powershell
  Add-MpPreference -ControlledFolderAccessAllowedApplications (Get-Command pwsh.exe).Source
  ```

  (A manual `Copy-Item` doesn't bypass CFA — pwsh is still the blocked app;
  Notepad is allowed if pasting over the profile manually.)
- **Downloaded scripts carry Mark-of-the-Web**: `Unblock-File` or
  `pwsh -ExecutionPolicy Bypass -File …`.
- **WSL is a separate config universe**: its own `~/.config/fastfetch`,
  `~/.bashrc`, oh-my-posh install. Run the `.sh` there.
- **fastfetch configs are JSONC** (inline `//`, `/* */`, trailing commas) —
  the `.sh` carries a string-aware parser; PS7's `ConvertFrom-Json` copes.
- oh-my-posh CLI drift: `disable upgrade` (current) vs `disable autoupgrade`
  (older). Scripts try both.
- Claude Code file-permission rules only match `Edit(path)` / `Read(path)`
  forms — `Write(**)`, `NotebookEdit(**)`, `Glob(**)` are ignored with a
  startup warning.

## Artifact locations

| Artifact | Windows | WSL |
|---|---|---|
| psmux drain | marked block at end of `$PROFILE` | — |
| oh-my-posh init cache | `%LOCALAPPDATA%\ftsu-omp-init.ps1` | `~/.cache/ftsu-omp-init.*` |
| Profile backups | `%LOCALAPPDATA%\ftsu-backups\` | `<file>.bak-<timestamp>` |
