#!/usr/bin/env bash
# workspace-watcher.sh — listens to Hyprland's event socket and silently moves
# matching windows to their genre workspace as they open.
#
# Hyprland 0.54's windowrule block syntax silently accepts but never applies
# any `workspace=`/`assign=`/`move=` field, so windowrule-based assignment
# does not work in this build. This script is the substitute.
#
# Edit RULES to add patterns. The key is a bash extended regex matched
# against the new window's class; the value is the target workspace number.

set -u

declare -A RULES=(
    # ---- Desktop 1: terminal, file explorer, programming ----
    ['^kitty$']=1
    ['[Nn]autilus']=1
    ['^[Cc]ode$']=1
    ['[Kk]ate']=1
    ['[Tt]ext[Ee]ditor']=1
    ['[Ff]ile[Zz]illa']=1
    ['[Ff]ilelight']=1

    # ---- Desktop 2: web browsers ----
    ['[Ff]irefox']=2
    ['[Vv]ivaldi']=2
    ['[Cc]hromium']=2
    ['[Cc]hrome']=2
    ['[Bb]rave']=2

    # ---- Desktop 3: chat ----
    ['[Dd]iscord']=3
    ['[Vv]esktop']=3
    ['[Ss]lack']=3

    # ---- Desktop 4: spotify + music ----
    ['[Ss]potify']=4

    # ---- Desktop 5: steam / games ----
    ['[Ss]team']=5
    ['[Hh]eroic']=5
    ['[Ll]utris']=5
    ['[Pp]rism']=5
    ['[Pp]oly[Mm][Cc]']=5
    ['[Mm]inecraft']=5
    ['[Mm]odrinth']=5
    ['[Ll]unar[Cc]lient']=5
    ['^osu']=5
    ['[Ss]ober']=5
    ['[Dd]olphin-[Ee]mu']=5
    ['[Pp]roton[Pp]lus']=5
    ['r2modman']=5
    ['[Bb]alatro']=5
    ['protontricks']=5
)

# Skip our own cheatsheet window
SKIP_REGEX='^keybinds-cheatsheet$'

SOCK="${XDG_RUNTIME_DIR}/hypr/${HYPRLAND_INSTANCE_SIGNATURE}/.socket2.sock"

[[ -S "$SOCK" ]] || {
    echo "workspace-watcher: socket not found at $SOCK" >&2
    exit 1
}

# Need socat. If it's missing, fall back to a python one-liner.
if ! command -v socat >/dev/null; then
    echo "workspace-watcher: socat not installed, falling back to python" >&2
    READER=( python3 -c "
import socket, os, sys
s = socket.socket(socket.AF_UNIX)
s.connect(os.environ['SOCK'])
f = s.makefile('r')
for line in f:
    sys.stdout.write(line); sys.stdout.flush()
" )
    SOCK="$SOCK" "${READER[@]}"
else
    socat -u "UNIX-CONNECT:$SOCK" -
fi | while IFS= read -r ev; do
    # Hyprland event format:  openwindow>>ADDRESS,WORKSPACE,CLASS,TITLE
    [[ "$ev" == openwindow* ]] || continue
    payload="${ev#openwindow>>}"
    addr="${payload%%,*}";        rest="${payload#*,}"
    ws="${rest%%,*}";             rest="${rest#*,}"
    class="${rest%%,*}"        # remaining after this is title (may contain commas)

    [[ "$class" =~ $SKIP_REGEX ]] && continue

    for pattern in "${!RULES[@]}"; do
        if [[ "$class" =~ $pattern ]]; then
            target="${RULES[$pattern]}"
            # Don't bother if it's already on the right workspace
            [[ "$ws" == "$target" ]] && break
            hyprctl dispatch movetoworkspacesilent "$target,address:0x$addr" >/dev/null
            break
        fi
    done
done
