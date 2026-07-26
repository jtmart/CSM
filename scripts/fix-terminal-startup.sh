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

def strip_jsonc(s):
    # Remove // and /* */ comments and trailing commas, respecting strings.
    out, i, n, in_str, esc = [], 0, len(s), False, False
    while i < n:
        c = s[i]
        if in_str:
            out.append(c)
            if esc:
                esc = False
            elif c == "\\":
                esc = True
            elif c == '"':
                in_str = False
            i += 1
        elif c == '"':
            in_str = True
            out.append(c)
            i += 1
        elif c == "/" and i + 1 < n and s[i + 1] == "/":
            while i < n and s[i] != "\n":
                i += 1
        elif c == "/" and i + 1 < n and s[i + 1] == "*":
            i += 2
            while i + 1 < n and not (s[i] == "*" and s[i + 1] == "/"):
                i += 1
            i += 2
        elif c == ",":
            j = i + 1
            while j < n and s[j] in " \t\r\n":
                j += 1
            # also skip comments between the comma and a closing bracket
            k = j
            while k + 1 < n and s[k] == "/" and s[k + 1] in "/*":
                if s[k + 1] == "/":
                    while k < n and s[k] != "\n":
                        k += 1
                else:
                    k += 2
                    while k + 1 < n and not (s[k] == "*" and s[k + 1] == "/"):
                        k += 1
                    k += 2
                while k < n and s[k] in " \t\r\n":
                    k += 1
            if k < n and s[k] in "}]":
                i += 1  # trailing comma - drop it
            else:
                out.append(c)
                i += 1
        else:
            out.append(c)
            i += 1
    return "".join(out)

try:
    cfg = json.loads(strip_jsonc(raw))
except ValueError as e:
    print("  could not parse %s (%s) - edit manually: logo.type explicit, general.detectVersion=false" % (path, e))
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

# v2: quiet-window drain. The v1 loop gave up after a single 50ms gap, so a
# reply relayed by tmux in two chunks got half-eaten and the tail still
# leaked. v2 keeps draining until ~200ms of continuous silence (bounded).
MARKER_OLD="# --- startup-input-drain (fix-terminal-startup) ---"
MARKER="# --- startup-input-drain v2 (fix-terminal-startup) ---"
MARKER_END="# --- end startup-input-drain ---"

remove_old_block() {
  local rc="$1"
  [ -f "$rc" ] && grep -qF "$MARKER_OLD" "$rc" || return 1
  if [ "$DRY" = 0 ]; then
    cp "$rc" "$rc.bak-$(date +%Y%m%d-%H%M%S)"
    sed -i "\|^$MARKER_OLD\$|,\|^$MARKER_END\$|d" "$rc"
  fi
  say "removed v1 drain hook from $rc"
}

install_bash_drain() {
  local rc="$1"
  if [ -f "$rc" ] && grep -qF "$MARKER" "$rc"; then
    say "$rc - already installed"
    return
  fi
  remove_old_block "$rc" || true
  if [ "$DRY" = 0 ]; then
    cat >> "$rc" <<'EOF'

# --- startup-input-drain v2 (fix-terminal-startup) ---
# Startup programs (fastfetch, oh-my-posh, ...) may query the terminal with
# escape sequences; the reply can arrive after the prompt is ready - possibly
# in chunks, via tmux - and leak onto the input line as junk like "80\".
# Drain until the line has been quiet for ~200ms, once, at the first prompt.
__ftsu_drain_input() {
  local _k _quiet=0 _got=0
  while [ "$_quiet" -lt 2 ] && [ "$_got" -lt 512 ]; do
    if IFS= read -r -s -t 0.1 -n 1 _k 2>/dev/null; then
      _got=$((_got + 1)); _quiet=0
    else
      _quiet=$((_quiet + 1))
    fi
  done
  PROMPT_COMMAND="${PROMPT_COMMAND//__ftsu_drain_input; /}"
}
case "${PROMPT_COMMAND:-}" in
  *__ftsu_drain_input*) ;;
  *) PROMPT_COMMAND="__ftsu_drain_input; ${PROMPT_COMMAND:-}" ;;
esac
# --- end startup-input-drain ---
EOF
  fi
  say "installed v2 drain hook in $rc"
}

install_zsh_drain() {
  local rc="$1"
  if [ -f "$rc" ] && grep -qF "$MARKER" "$rc"; then
    say "$rc - already installed"
    return
  fi
  remove_old_block "$rc" || true
  if [ "$DRY" = 0 ]; then
    cat >> "$rc" <<'EOF'

# --- startup-input-drain v2 (fix-terminal-startup) ---
# Startup programs (fastfetch, oh-my-posh, ...) may query the terminal with
# escape sequences; the reply can arrive after the prompt is ready - possibly
# in chunks, via tmux - and leak onto the input line as junk like "80\".
# Drain until the line has been quiet for ~200ms, once, at the first prompt.
__ftsu_drain_input() {
  local _k _quiet=0 _got=0
  while [ "$_quiet" -lt 2 ] && [ "$_got" -lt 512 ]; do
    if read -s -t 0.1 -k 1 _k 2>/dev/null; then
      _got=$((_got + 1)); _quiet=0
    else
      _quiet=$((_quiet + 1))
    fi
  done
  precmd_functions=(${precmd_functions:#__ftsu_drain_input})
}
if [[ " ${precmd_functions[*]:-} " != *" __ftsu_drain_input "* ]]; then
  precmd_functions+=(__ftsu_drain_input)
fi
# --- end startup-input-drain ---
EOF
  fi
  say "installed v2 drain hook in $rc"
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
