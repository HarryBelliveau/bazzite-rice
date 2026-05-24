#!/usr/bin/env bash
# Launch the keybinds cheatsheet and auto-close it as soon as it loses focus.
# Hyprland has no native "close on focus lost" windowrule, so we poll
# `hyprctl activewindow` and close the kitty window when something else
# takes focus. Polling is cheap (~10/s) and avoids needing socat/nc.
#
# Bound from hyprland.conf via SUPER+\.

set -euo pipefail

CLASS=keybinds-cheatsheet
CHEAT_FILE="$HOME/.config/hypr/keybinds.txt"

# Toggle behavior: if one is already open, close it instead of stacking.
if hyprctl clients -j 2>/dev/null | grep -q "\"class\": \"$CLASS\""; then
    hyprctl dispatch closewindow "^($CLASS)$" >/dev/null
    exit 0
fi

kitty --class="$CLASS" -- less "$CHEAT_FILE" &
kitty_pid=$!

# Wait for the window to actually appear and become focused so we don't
# immediately fire the "lost focus" branch.
for _ in {1..50}; do
    cur=$(hyprctl activewindow -j 2>/dev/null | grep -oP '"class":\s*"\K[^"]+' || true)
    [[ "$cur" == "$CLASS" ]] && break
    sleep 0.05
done

# Poll focus. As soon as the active class is no longer the cheatsheet (and the
# cheatsheet window still exists), close it. Also exits cleanly if the user
# closes it manually with q/Esc.
(
    while kill -0 "$kitty_pid" 2>/dev/null; do
        cur=$(hyprctl activewindow -j 2>/dev/null | grep -oP '"class":\s*"\K[^"]+' || true)
        if [[ -n "$cur" && "$cur" != "$CLASS" ]]; then
            hyprctl dispatch closewindow "^($CLASS)$" >/dev/null 2>&1 || true
            break
        fi
        sleep 0.1
    done
) &
watcher_pid=$!

wait "$kitty_pid" 2>/dev/null || true
kill "$watcher_pid" 2>/dev/null || true
