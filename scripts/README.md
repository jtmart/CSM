# scripts

Utility scripts for the Cross-Session Memory plugin.

## Scripts

### backfill-provenance.mjs
Backfills provenance metadata (`source_kind`, `evidence_strength`, `source_surface`, `source_agent_id`) on existing memories that lack it. Idempotent — safe to re-run.

```bash
node scripts/backfill-provenance.mjs --dry-run  # Preview changes
node scripts/backfill-provenance.mjs             # Apply changes
```

### safe-review-copy.ps1
PowerShell script for safely copying files with review.

### fix-terminal-startup.ps1
One-shot fixer for Windows terminal startup issues: pins fastfetch's logo type and disables its version detection and terminal-theme module so it stops probing the terminal with escape queries (stray characters like `80\` on the prompt line + startup stall), excludes external disks from fastfetch's disk module (USB spin-up delay), installs a Clink Lua hook that drains late terminal-query replies before the first cmd.exe prompt, disables oh-my-posh's startup upgrade-notice/auto-upgrade network checks, and rewrites unmatched Claude Code permission rules (`Write(**)`/`NotebookEdit(**)` → `Edit(**)`, `Glob(**)` → `Read(**)`) in `~/.claude/settings.json`. Idempotent; backs up every file it touches. Requires PowerShell 7+.

```powershell
pwsh -File scripts/fix-terminal-startup.ps1 -DryRun  # Preview changes
pwsh -File scripts/fix-terminal-startup.ps1          # Apply changes
```

### fix-terminal-startup.sh
Unix-side companion for the WSL/MSYS2 environment tmux runs in (its own fastfetch config and rc files): pins fastfetch's probe settings, installs a quiet-window input-drain hook for bash/zsh, disables oh-my-posh's upgrade checks. Idempotent with backups; string-aware JSONC parsing.

```bash
bash scripts/fix-terminal-startup.sh --dry-run  # Preview changes
bash scripts/fix-terminal-startup.sh            # Apply changes
```

### speed-terminal-startup.ps1 / speed-terminal-startup.sh
Startup speed pass: rewrites the PowerShell profile / shell rc so fastfetch prints a cached splash instantly and regenerates it in the background into a file (which also removes its last way to query the terminal — the root cause of stray characters like `7f7f\` at the first prompt), and caches the oh-my-posh init script instead of spawning oh-my-posh every shell start. Conservative (only simple invocation forms are rewritten), idempotent, backups to `%LOCALAPPDATA%\ftsu-backups` / alongside the file. See `docs/WINDOWS_TERMINAL_SETUP.md` for the full story and Windows gotchas (OneDrive profiles, Controlled Folder Access).

```powershell
pwsh -ExecutionPolicy Bypass -File scripts/speed-terminal-startup.ps1
```
```bash
bash scripts/speed-terminal-startup.sh
```

## Usage
Scripts are run from the project root:
```bash
node scripts/<script>.mjs
```
