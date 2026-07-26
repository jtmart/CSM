# Windows Terminal Setup — Startup Fixes & Speed Pass

Reference for setting up a fresh Windows machine (Surface / Windows 11) with
the fastfetch + oh-my-posh + Clink + Alacritty/tmux(WSL) terminal stack, and
for avoiding the two classes of startup problems this repo's scripts solve:

1. **Stray characters on the first prompt line** (e.g. `7f7f\`, `80\`) plus a
   slow first paint.
2. **Claude Code CLI startup warnings** about unmatched permission rules.

Resolved July 2026; scripts live in `scripts/`. Canonical replication copies
live in `C:\Users\jtm\Dropbox\Sync\add-templates\terminal-startup\` — on a new
machine, run `install.ps1` from that folder and it chains all four scripts
(Windows side, then the WSL side via `wsl`).

## TL;DR for a fresh install

Run these once, in order (all idempotent, all keep timestamped backups):

```powershell
# Windows side (PowerShell 7+):
pwsh -ExecutionPolicy Bypass -File .\scripts\fix-terminal-startup.ps1
pwsh -ExecutionPolicy Bypass -File .\scripts\speed-terminal-startup.ps1
```

```bash
# Unix side — run INSIDE the WSL/MSYS2 shell that tmux uses:
bash scripts/fix-terminal-startup.sh
bash scripts/speed-terminal-startup.sh
```

Judge results from the **second** new shell (the first one rebuilds caches).

## Root causes, in the order they were eliminated

### Stray characters + slow startup

The fragments (`7f7f\`, `80\`) are the tail of a terminal escape-query
**reply** — they end in the ST terminator (`ESC \`), whose backslash renders
literally when the reply lands on the input line instead of being read by
whoever asked. Reply-capable GPU terminals (Alacritty, WezTerm) answer such
queries; plain conhost doesn't, which is why the leak never appeared in a bare
PowerShell window. Alacritty can also answer queries **out of order and
late** ([alacritty#4872](https://github.com/alacritty/alacritty/issues/4872)),
which is why input-drain hooks alone proved insufficient — the reply can
outlive any reasonable drain window. The durable fix is to stop the queries,
not catch them.

Query sources eliminated, in order:

| Source | Fix | Script |
|---|---|---|
| fastfetch `logo.type: auto` (image-protocol probe) | pin explicit `logo.type` | fix-…​.ps1/.sh |
| fastfetch `general.detectVersion` (default true) | set `false` | fix-…​.ps1/.sh |
| fastfetch `terminaltheme` module (OSC 10/11 color query) | remove module | fix-…​.ps1/.sh |
| oh-my-posh upgrade notice + auto-upgrade (network checks; `disable upgrade` on current CLIs, `autoupgrade` on older) | `oh-my-posh disable notice/upgrade` | fix-…​.ps1/.sh |
| fastfetch running against the tty at all | cached splash: print previous run's output instantly, regenerate in background **into a file** (a non-tty fastfetch cannot query anything) | speed-…​.ps1/.sh |
| prompt-time emitters (Clink async prompt / oh-my-posh render) | drain hooks as belt-and-suspenders: Clink lua + bash `PROMPT_COMMAND` / zsh `precmd`, quiet-window strategy | fix-…​.ps1/.sh |

Extra latency sources also fixed:

- **External USB disks** in fastfetch's disk module force a spin-up wait:
  `"showExternal": false`.
- **oh-my-posh init spawn** on every shell start: the init script is cached to
  a file and dot-sourced/sourced (`speed-terminal-startup.*`). After changing
  the omp theme, delete `ftsu-omp-init.*` from `%LOCALAPPDATA%` (Windows) or
  `~/.cache` (WSL) to regenerate.

**The final culprit on this setup was psmux.** Alacritty launches every tab as
`cmd /c psmux new-session pwsh.exe -NoLogo` — psmux (tmux-for-Windows) queries
the host terminal at attach, and Alacritty's reply is forwarded into the inner
pwsh pane where its tail renders as stray input. psmux has no option to
disable the query, so the fix is `fix-psmux-drain.ps1`: a drain block at the
end of the PowerShell profile, active only when `$env:ALACRITTY` is `1` (set
by the Alacritty config), that swallows pending input until ~200ms of quiet
after profile load and again at the first prompt render. Diagnosis lesson:
identify the *inner shell* of the leaking tab first (here fastfetch reported
"Shell: CMD" but the pane shell was pwsh via psmux) — drain hooks only work
if they live in that shell. Note there is no Clink and no cmd AutoRun in this
setup; the fancy cmd-tab prompt comes from oh-my-posh inside the psmux-hosted
pwsh.

### Claude Code permission-rule warnings

Claude Code's file permission checks only match `Edit(path)` and `Read(path)`
rule forms. Rules written as `Write(**)`, `NotebookEdit(**)`, or `Glob(**)` in
`~/.claude/settings.json` are ignored and produce startup warnings. The fixer
rewrites them (`Write`/`NotebookEdit` → `Edit`, `Glob` → `Read`) and dedupes.

## Windows gotchas discovered along the way

- **PowerShell profile lives under OneDrive**
  (`C:\Users\<user>\OneDrive\Documents\PowerShell\…`). Two write hazards:
  - `Copy-Item` onto a OneDrive placeholder can fail with *Could not find
    file* — write backups to `%LOCALAPPDATA%\ftsu-backups` instead.
  - **Controlled Folder Access** (Windows Security → Ransomware protection)
    blocks pwsh writes to Documents with *Access to the path is denied*.
    One-time unblock from an **admin** PowerShell, then re-run:

    ```powershell
    Add-MpPreference -ControlledFolderAccessAllowedApplications (Get-Command pwsh.exe).Source
    ```

    A manual `Copy-Item` does **not** work around CFA (pwsh is still the
    blocked app); Notepad is allowed if you prefer pasting over the profile.
- **Downloaded scripts are Mark-of-the-Web-blocked**: `Unblock-File x.ps1`
  or run with `pwsh -ExecutionPolicy Bypass -File x.ps1`.
- **The tmux environment is a separate machine** as far as configs go: WSL has
  its own `~/.config/fastfetch/`, `~/.bashrc`, and oh-my-posh install.
  Windows-side fixes do not reach it; run the `.sh` variants inside WSL.
- **fastfetch configs are JSONC**: inline `//`, `/* */`, and trailing commas
  are all legal — parse accordingly (`fix-terminal-startup.sh` carries a
  string-aware stripper; PowerShell 7's `ConvertFrom-Json` copes natively).
- oh-my-posh CLI syntax drift: `disable autoupgrade` (old) vs
  `disable upgrade` (current). The scripts try both.

## Cache & artifact locations

| Artifact | Windows | WSL |
|---|---|---|
| fastfetch splash cache | `%LOCALAPPDATA%\ftsu-splash.txt` | `~/.cache/ftsu-splash` |
| oh-my-posh init cache | `%LOCALAPPDATA%\ftsu-omp-init.ps1` | `~/.cache/ftsu-omp-init.bash` / `.zsh` |
| Profile backups | `%LOCALAPPDATA%\ftsu-backups\` | `<file>.bak-<timestamp>` next to the file |
| Clink drain hook | `%LOCALAPPDATA%\clink\zz-flush-startup-input.lua` | — |
| rc drain hooks | — | marked blocks in `~/.bashrc` / `~/.zshrc` |
