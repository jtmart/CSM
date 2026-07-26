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

### Terminal setup scripts (see docs/WINDOWS_TERMINAL_SETUP.md)
The load-bearing three, chained by `install-terminal-setup.ps1` on a fresh machine:

- **fix-terminal-startup.ps1** — Windows: fastfetch probe/disk hygiene, oh-my-posh upgrade checks off, Claude Code permission-rule rewrite (`Write(**)`/`NotebookEdit(**)` → `Edit(**)`, `Glob(**)` → `Read(**)`).
- **fix-psmux-drain.ps1** — the stray-character fix: pwsh-profile input drain for Alacritty/psmux panes (gated on `ALACRITTY=1`).
- **fix-terminal-startup.sh** — same fastfetch/omp hygiene inside WSL (string-aware JSONC parsing).

All idempotent with timestamped backups; `.ps1` need PowerShell 7+.

```powershell
pwsh -ExecutionPolicy Bypass -File scripts/install-terminal-setup.ps1   # everything, in order
```

Historical/situational: `speed-terminal-startup.ps1/.sh` (oh-my-posh init caching is the useful part; the fastfetch splash caching half is NOT recommended — non-tty fastfetch degrades glyphs and doubles up, see `revert-splash-cache.ps1` which undoes it) and `finalize-terminal-setup.ps1` (post-investigation cleanup + replication-folder deploy).

## Usage
Scripts are run from the project root:
```bash
node scripts/<script>.mjs
```
