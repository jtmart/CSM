#!/usr/bin/env bash
# speed-terminal-startup.sh
#
# Startup speed pass for the Unix-side shell (WSL/MSYS2), companion to
# speed-terminal-startup.ps1. Two transforms in ~/.bashrc (and ~/.zshrc if
# present):
#
#   1. fastfetch -> cached splash. The saved output of the previous run is
#      printed instantly (pure SGR color codes, zero cost), while fastfetch
#      regenerates the cache in the background writing to a FILE - so it
#      never touches the terminal. Besides the speed, this removes the last
#      way fastfetch could query the terminal, which is what leaks reply
#      fragments like "7f7f\" onto the first prompt inside tmux.
#
#   2. oh-my-posh init -> cached init script. 'eval "$(oh-my-posh init ...)"'
#      spawns oh-my-posh synchronously on every shell start just to print an
#      init script that rarely changes. Cache it and source the file instead.
#      (Delete ~/.cache/ftsu-omp-init.* after changing your omp theme.)
#
# Conservative: each transform only fires when it finds exactly the simple,
# common form of the line; anything unusual is left alone and reported.
# Idempotent; edited files get timestamped .bak-* siblings.
#
# Usage:
#   bash speed-terminal-startup.sh --dry-run   # preview
#   bash speed-terminal-startup.sh             # apply

set -u
DRY=0
[ "${1:-}" = "--dry-run" ] && DRY=1 && printf 'DRY RUN - no files will be modified\n'

say() { printf '  %s\n' "$*"; }
hdr() { printf '\n== %s ==\n' "$*"; }

backup() {
  [ "$DRY" = 0 ] && cp "$1" "$1.bak-$(date +%Y%m%d-%H%M%S)"
}

process_rc() {
  local rc="$1" shell="$2"
  hdr "$rc"
  [ -f "$rc" ] || { say 'not present - skipped'; return; }
  local backed_up=0

  # --- 1. fastfetch -> cached splash --------------------------------------
  if grep -q 'ftsu-splash' "$rc"; then
    say 'fastfetch: already cached'
  else
    local ff_lines
    ff_lines=$(grep -n '^[[:space:]]*fastfetch\([[:space:]].*\)\{0,1\}$' "$rc" | head -5)
    local ff_count
    ff_count=$(printf '%s' "$ff_lines" | grep -c . || true)
    if [ "$ff_count" = 1 ]; then
      local lineno cmd
      lineno=${ff_lines%%:*}
      cmd=$(sed -n "${lineno}p" "$rc" | sed 's/^[[:space:]]*//')
      if [ "$DRY" = 0 ]; then
        backup "$rc"; backed_up=1
        sed -i "${lineno}s|^|# moved to cached splash below (speed-terminal-startup): |" "$rc"
        cat >> "$rc" <<EOF

# --- fastfetch cached splash (speed-terminal-startup) ---
# Instant splash from the previous run's output; regenerated in the
# background into a file, so fastfetch never queries the terminal.
__ftsu_splash="\$HOME/.cache/ftsu-splash"
[ -f "\$__ftsu_splash" ] && cat "\$__ftsu_splash"
( command mkdir -p "\$HOME/.cache" && $cmd --pipe false > "\$__ftsu_splash.new" 2>/dev/null \\
    && command mv -f "\$__ftsu_splash.new" "\$__ftsu_splash" & ) 2>/dev/null
# --- end fastfetch cached splash ---
EOF
      fi
      say "fastfetch: cached splash installed (was: $cmd)"
      say 'note: first new shell after this has no splash yet; it appears from the 2nd on'
    elif [ "$ff_count" = 0 ]; then
      say 'fastfetch: no simple invocation found - skipped'
    else
      say "fastfetch: $ff_count invocations found - ambiguous, left alone"
    fi
  fi

  # --- 2. oh-my-posh init -> cached init script ---------------------------
  if grep -q 'ftsu-omp-init' "$rc"; then
    say 'oh-my-posh: already cached'
  else
    local omp_lines
    omp_lines=$(grep -n 'eval[[:space:]]*"\$(oh-my-posh init' "$rc" | head -5)
    local omp_count
    omp_count=$(printf '%s' "$omp_lines" | grep -c . || true)
    if [ "$omp_count" = 1 ]; then
      local lineno line inner
      lineno=${omp_lines%%:*}
      line=$(sed -n "${lineno}p" "$rc")
      inner=$(printf '%s' "$line" | sed 's/.*\$(\(oh-my-posh init[^)]*\)).*/\1/')
      if [ "$DRY" = 0 ]; then
        [ "$backed_up" = 1 ] || { backup "$rc"; backed_up=1; }
        cat > "$rc.ftsu-tmp" <<EOF
__ftsu_omp="\$HOME/.cache/ftsu-omp-init.$shell"
if [ ! -f "\$__ftsu_omp" ]; then
  command mkdir -p "\$HOME/.cache"
  $inner --print > "\$__ftsu_omp" 2>/dev/null || rm -f "\$__ftsu_omp"
fi
if [ -f "\$__ftsu_omp" ]; then
  source "\$__ftsu_omp"   # cached; delete the file after changing your theme
else
  $line
fi
EOF
        sed -i "${lineno}r $rc.ftsu-tmp" "$rc"
        sed -i "${lineno}s|^|# replaced by cached init below (speed-terminal-startup): |" "$rc"
        rm -f "$rc.ftsu-tmp"
      fi
      say "oh-my-posh: cached init installed (was: $(printf '%s' "$line" | sed 's/^[[:space:]]*//'))"
    elif [ "$omp_count" = 0 ]; then
      say 'oh-my-posh: no standard eval-init line found - skipped'
    else
      say "oh-my-posh: $omp_count init lines found - ambiguous, left alone"
    fi
  fi
}

process_rc "$HOME/.bashrc" bash
[ -f "$HOME/.zshrc" ] && process_rc "$HOME/.zshrc" zsh

printf '\nDone. The FIRST new shell still pays full cost (builds the caches); the second\nis the one to judge. If the tmux stray characters persist even now, the emitter\nis oh-my-posh itself rather than fastfetch - tell Claude and it gets chased.\n'
