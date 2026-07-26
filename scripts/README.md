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
One-shot fixer for Windows terminal startup issues: pins fastfetch's logo type so it stops probing the terminal with escape queries (stray characters on the prompt line + startup stall), excludes external disks from fastfetch's disk module (USB spin-up delay), disables oh-my-posh's startup upgrade-notice network check, and rewrites unmatched Claude Code permission rules (`Write(**)`/`NotebookEdit(**)` → `Edit(**)`, `Glob(**)` → `Read(**)`) in `~/.claude/settings.json`. Idempotent; backs up every file it touches. Requires PowerShell 7+.

```powershell
pwsh -File scripts/fix-terminal-startup.ps1 -DryRun  # Preview changes
pwsh -File scripts/fix-terminal-startup.ps1          # Apply changes
```

## Usage
Scripts are run from the project root:
```bash
node scripts/<script>.mjs
```
