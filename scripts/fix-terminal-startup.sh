#!/usr/bin/env bash
# fix-terminal-startup.sh
#
# Unix-side companion to fix-terminal-startup.ps1. Run INSIDE the shell
# environment tmux uses (WSL, MSYS2, Git Bash) - that environment has its own
# fastfetch config and rc files, so the Windows-side fixes don't reach it and
# stray characters like "7f7f\" (the tail of a terminal color-query reply,
# ending in the ST terminator's literal backslash) still leak onto the first
# prompt there.
#
# What it does:
#   - fastfetch: pin an explicit logo type, set general.detectVersion false,
#     drop the terminaltheme module (OSC 10/11 color query) if present
#   - bash/zsh: install a once-per-session hook that drains pending terminal
#     replies right before the first prompt accepts input (catches any
#     remaining emitter, including queries relayed oddly through tmux)
#   - oh-my-posh: disable the upgrade notice and auto-upgrade network checks
#
# Idempotent - safe to re-run. Edited files get timestamped .bak-* siblings.
#
# Usage:
#   bash fix-terminal-startup.sh --dry-run   # preview
#   bash fix-terminal-startup.sh             # apply

set -u
DRY=0
[ "${1:-}" = "--dry-run" ] && DRY=1 && printf 'DRY RUN - no files will be modified\n'

say() { printf '  %s\n' "$*"; }
hdr() { printf '\n== %s ==\n' "$*"; }

# --- 1. fastfetch ----------------------------------------------------------

hdr "fastfetch"
CFG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/fastfetch"
CFG=""
for f in "$CFG_DIR/config.jsonc" "$CFG_DIR/config.json"; do
  [ -f "$f" ] && CFG="$f" && break
done

if [ -z "$CFG" ]; then
  CFG="$CFG_DIR/config.jsonc"
  if [ "$DRY" = 0 ]; then
    mkdir -p "$CFG_DIR"
    cat > "$CFG" <<'EOF'
{
  "$schema": "https://github.com/fastfetch-cli/fastfetch/raw/dev/doc/json_schema.json",
  "logo": { "type": "builtin" },
  "general": { "detectVersion": false }
}
EOF
  fi
  say "created $CFG (explicit logo type, detectVersion off)"
elif command -v python3 >/dev/null 2>&1; then
  python3 - "$CFG" "$DRY" <<'PYEOF'
import datetime, json, re, shutil, sys
path, dry = sys.argv[1], sys.argv[2] == "1"
raw = open(path).read()
try:
    cfg = json.loads(re.sub(r"^\s*//.*$", "", raw, flags=re.M))
except ValueError:
    print("  could not parse %s - edit manually: logo.type explicit, general.detectVersion=false" % path)
    sys.exit(0)
changed = []
logo = cfg.get("logo")
if logo is None:
    cfg["logo"] = {"type": "builtin"}
    changed.append("logo: none configured -> pinned type 'builtin'")
elif isinstance(logo, str):
    t = "file" if "/" in logo or "\\" in logo else "builtin"
    cfg["logo"] = {"source": logo, "type": t}
    changed.append("logo: string -> { source, type: '%s' }" % t)
elif logo.get("type") in (None, "auto"):
    logo["type"] = "file" if logo.get("source") else "builtin"
    changed.append("logo: pinned type '%s'" % logo["type"])
general = cfg.setdefault("general", {})
if general.get("detectVersion") is not False:
    general["detectVersion"] = False
    changed.append("general: set detectVersion: false")
mods = cfg.get("modules")
if isinstance(mods, list):
    kept = [m for m in mods
            if not (m == "terminaltheme" or (isinstance(m, dict) and m.get("type") == "terminaltheme"))]
    if len(kept) != len(mods):
        cfg["modules"] = kept
        changed.append("modules: removed terminaltheme (OSC 10/11 color query)")
if changed and not dry:
    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    shutil.copy(path, path + ".bak-" + stamp)
    with open(path, "w") as fh:
        json.dump(cfg, fh, indent=2)
        fh.write("\n")
    print("  backup: %s.bak-%s" % (path, stamp))
print("\n".join("  " + c for c in changed) if changed else "  %s - already clean" % path)
PYEOF
else
  say "config exists but python3 is missing - edit $CFG manually:"
  say "  set logo.type explicitly, general.detectVersion=false, remove any terminaltheme module"
fi

# --- 2. bash/zsh: drain late terminal replies before the first prompt ------

MARKER="# --- startup-input-drain (fix-terminal-startup) ---"

install_bash_drain() {
  local rc="$1"
  if [ -f "$rc" ] && grep -qF "$MARKER" "$rc"; then
    say "$rc - already installed"
    return
  fi
  if [ "$DRY" = 0 ]; then
    cat >> "$rc" <<'EOF'

# --- startup-input-drain (fix-terminal-startup) ---
# Startup programs (fastfetch, oh-my-posh, ...) may query the terminal with
# escape sequences; the reply can arrive after the prompt is ready and leak
# onto the input line as junk like "7f7f\". Drain it once, at the first prompt.
__ftsu_drain_input() {
  local _k
  while IFS= read -r -s -t 0.05 -n 1 _k 2>/dev/null; do :; done
  PROMPT_COMMAND="${PROMPT_COMMAND//__ftsu_drain_input; /}"
}
case "${PROMPT_COMMAND:-}" in
  *__ftsu_drain_input*) ;;
  *) PROMPT_COMMAND="__ftsu_drain_input; ${PROMPT_COMMAND:-}" ;;
esac
# --- end startup-input-drain ---
EOF
  fi
  say "installed drain hook in $rc"
}

install_zsh_drain() {
  local rc="$1"
  if [ -f "$rc" ] && grep -qF "$MARKER" "$rc"; then
    say "$rc - already installed"
    return
  fi
  if [ "$DRY" = 0 ]; then
    cat >> "$rc" <<'EOF'

# --- startup-input-drain (fix-terminal-startup) ---
# Startup programs (fastfetch, oh-my-posh, ...) may query the terminal with
# escape sequences; the reply can arrive after the prompt is ready and leak
# onto the input line as junk like "7f7f\". Drain it once, at the first prompt.
__ftsu_drain_input() {
  local _k
  while read -s -t 0.05 -k 1 _k 2>/dev/null; do :; done
  precmd_functions=(${precmd_functions:#__ftsu_drain_input})
}
if [[ " ${precmd_functions[*]:-} " != *" __ftsu_drain_input "* ]]; then
  precmd_functions+=(__ftsu_drain_input)
fi
# --- end startup-input-drain ---
EOF
  fi
  say "installed drain hook in $rc"
}

hdr "shell startup hooks"
did_rc=0
[ -f "$HOME/.bashrc" ] && install_bash_drain "$HOME/.bashrc" && did_rc=1
[ -f "$HOME/.zshrc" ] && install_zsh_drain "$HOME/.zshrc" && did_rc=1
if [ "$did_rc" = 0 ]; then
  install_bash_drain "$HOME/.bashrc"
fi

# --- 3. oh-my-posh ---------------------------------------------------------

hdr "oh-my-posh"
if command -v oh-my-posh >/dev/null 2>&1; then
  if [ "$DRY" = 0 ]; then
    oh-my-posh disable notice >/dev/null 2>&1
    # the subcommand is 'upgrade' on current versions, 'autoupgrade' on older
    oh-my-posh disable upgrade >/dev/null 2>&1 || oh-my-posh disable autoupgrade >/dev/null 2>&1
    say "disabled upgrade notice and auto-upgrade startup checks"
  else
    say "would run: oh-my-posh disable notice; oh-my-posh disable upgrade"
  fi
else
  say "oh-my-posh not on PATH - skipped"
fi

printf '\nDone. Open a new tmux window/pane (or restart tmux) to verify the stray characters are gone.\n'
